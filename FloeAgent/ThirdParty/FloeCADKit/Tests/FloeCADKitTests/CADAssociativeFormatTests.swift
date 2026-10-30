import Foundation
import XCTest
import CryptoKit
import Euclid
import simd
@testable import FloeCAD

/// All bytes here are synthetic. Unknown semantic packages are deliberately
/// assembled by this fixture (not by a production writer bypass).
@MainActor
enum CADAssociativeFormatFixture {
    nonisolated enum OpaqueKind: CaseIterable, Equatable { case definitionKind, definitionVersion, supportCase }

    static func plane() throws -> ConstructionPlane {
        let body = BodyID()
        let writer = FeatureID()
        let face = FaceRef(body: BodyRef(producer: writer, bodyID: body), creator: writer,
            role: .boxFace(.pz), signature: FaceSignature(kind: .planar, normal: SIMD3(0, 1, 0),
                centroid: .zero, area: 100, planeOffset: 0))
        let frame = try PlaneAttachmentFrame.make(faceCentroid: .zero, faceNormal: SIMD3(0, 1, 0),
            referenceXAxis: SIMD3(1, 0, 0), anchorPoint: .zero)
        let definition = OffsetPlaneDefinition(source: face,
            sourceVersion: GeometryVersionRef(bodyID: body, writer: writer), distance: Expr(value: 5), attachment: frame)
        return ConstructionPlane(plane: .ground, size: 40, definition: .offset(definition))
    }

    static func basicPackage(at url: URL, drawing: Bool = false) async throws {
        let document = try await FloeCADDocument.create(at: url, name: "Synthetic")
        let spec = PrimitiveSpec.box(width: 10, depth: 12, height: 8)
        var body = Body(name: "Cached solid", euclidMesh: .primitive(spec), revision: 0)
        XCTAssertTrue(body.adoptBRep(try XCTUnwrap(OCCTKernel.primitiveShape(spec, placement: .identity))))
        document.session.perform(AddBodyCommand(body: body, title: "Fixture"))
        document.session.perform(AddConstructionPlaneCommand(plane: ConstructionPlane(plane: .ground, size: 40)))
        document.session.perform(AddSketchCommand(sketch: Sketch(plane: .ground)))
        if drawing {
            let result = CADDrawingService(document: document).handle(action: "standardSheet",
                args: ["bodyID": body.id.raw.uuidString, "title": "Synthetic sheet"])
            XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        }
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
    }

    static func bytes(_ url: URL) throws -> [String: Data] {
        let prefix = url.path + "/"
        let enumeration = try XCTUnwrap(FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in enumeration where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(prefix.count))] = try Data(contentsOf: file)
        }
        return result
    }

    static func manifest(_ url: URL) throws -> CADManifest {
        try JSONDecoder().decode(CADManifest.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
    }

    static func record(_ url: URL) throws -> CADDocumentRecord {
        try JSONDecoder().decode(CADDocumentRecord.self, from: Data(contentsOf: url.appendingPathComponent("document.json")))
    }

    /// Retain the real content/model digest contracts while injecting a future
    /// inline record, so parser compatibility cannot masquerade as integrity.
    static func rewrite(_ url: URL, schema: Int,
                        mutate: (inout CADDocumentRecord) throws -> Void) throws {
        var record = try record(url)
        var manifest = try manifest(url)
        try mutate(&record)
        let data = try JSONEncoder().encode(record)
        var blobs: [String: Data] = [:]
        for (path, bytes) in try bytes(url) where path.hasPrefix("blobs/") && path != "blobs/thumbnail.img" { blobs[path] = bytes }
        var content = SHA256()
        content.update(data: data)
        for (path, bytes) in blobs.sorted(by: { $0.key < $1.key }) {
            content.update(data: Data(path.utf8))
            content.update(data: Data(FileCADDocumentStore.sha256(bytes).utf8))
        }
        if let thumbnail = manifest.thumbnailSHA256 { content.update(data: Data(thumbnail.utf8)) }
        manifest.schemaVersion = schema
        manifest.contentSHA256 = FileCADDocumentStore.hex(content.finalize())
        manifest.modelSHA256 = try FileCADDocumentStore.modelDigest(name: manifest.name, unit: manifest.unit,
            tolerance: manifest.tolerance, document: record, blobs: blobs)
        try data.write(to: url.appendingPathComponent("document.json"))
        try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("manifest.json"))
    }

    static func makeOpaque(_ url: URL, kind: OpaqueKind) throws {
        try rewrite(url, schema: 2) { record in
            if kind == .supportCase {
                var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: record.sketches[0].data) as? [String: Any])
                raw["support"] = ["source": ["futureSupport": ["synthetic": true]]]
                record.sketches[0].data = try JSONSerialization.data(withJSONObject: raw)
                record.sketches[0].sha256 = FileCADDocumentStore.sha256(record.sketches[0].data)
            } else {
                var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plane())) as? [String: Any])
                // Keep the original row's identity and last display plane.
                let original = try XCTUnwrap(JSONSerialization.jsonObject(with: record.planes[0].data) as? [String: Any])
                raw["id"] = original["id"]
                if kind == .definitionKind { raw["definition"] = ["kind": "futureDatum", "synthetic": true] }
                else {
                    var definition = try XCTUnwrap(raw["definition"] as? [String: Any])
                    var offset = try XCTUnwrap(definition["offset"] as? [String: Any])
                    offset["version"] = 2
                    definition["offset"] = offset
                    raw["definition"] = definition
                }
                record.planes[0].data = try JSONSerialization.data(withJSONObject: raw)
                record.planes[0].sha256 = FileCADDocumentStore.sha256(record.planes[0].data)
            }
        }
    }
}

@MainActor
final class CADAssociativeFormatTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DatumFormat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        CADDocumentFaultInjection.beforeCommit = nil
        CADDocumentFaultInjection.beforeCreateSwap = nil
        for document in documents where !document.isClosed { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private func url() -> URL { directory.appendingPathComponent("\(UUID().uuidString).floecad") }
    private func open(_ url: URL) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.open(at: url)
        documents.append(document)
        return document
    }

    func testLegacyPlainCreateMetadataPreviewAndDirectWritesRemainFormatOne() async throws {
        let url = url()
        let document = try await FloeCADDocument.create(at: url, name: "Plain")
        documents.append(document)
        XCTAssertEqual(Project.currentFormatVersion, 2)
        XCTAssertEqual(FileCADDocumentStore.currentSchemaVersion, 2)
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(url).schemaVersion, 1)
        document.project.name = "Metadata only"
        let metadata = await document.save()
        XCTAssertTrue(metadata.succeeded)
        let preview = await document.saveViewportPreview(Data("synthetic preview".utf8))
        XCTAssertTrue(preview.succeeded)
        try document.context.save()
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(url).schemaVersion, 1)
        XCTAssertEqual(document.project.formatVersion, 1)
    }

    func testFirstDefinitionAndSupportSaveAtomicallyRaiseFormatAndNeverDowngrade() async throws {
        let url = url()
        let document = try await FloeCADDocument.create(at: url, name: "Related")
        documents.append(document)
        let plane = try CADAssociativeFormatFixture.plane()
        let sketch = Sketch(plane: .ground, support: PlaneRef(source: .construction(plane.id)))
        document.session.perform(AddConstructionPlaneCommand(plane: plane))
        document.session.perform(AddSketchCommand(sketch: sketch))
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(url).schemaVersion, 2)
        document.close()
        let reopened = try await open(url)
        XCTAssertEqual(reopened.session.document.planes.first?.definition, plane.definition)
        XCTAssertEqual(reopened.session.document.sketches.first?.support, sketch.support)
        reopened.session.preview { value in
            value.planes.removeAll()
            for index in value.sketches.indices { value.sketches[index].support = nil }
        }
        let removed = await reopened.save()
        XCTAssertTrue(removed.succeeded, removed.error ?? "")
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(url).schemaVersion, 2)
        reopened.project.name = "Metadata after removal"
        let asyncResult1 = await reopened.save()
        XCTAssertTrue(asyncResult1.succeeded)
        let asyncResult2 = await reopened.saveViewportPreview(Data("synthetic".utf8))
        XCTAssertTrue(asyncResult2.succeeded)
        try reopened.context.save()
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(url).schemaVersion, 2)
        reopened.close()
        let replacement = try await FloeCADDocument.create(at: url, name: "Replacement", overwrite: true)
        documents.append(replacement)
        XCTAssertEqual(replacement.summary().schemaVersion, 2, "overwrite cannot lower a package's writer floor")
    }

    func testRawPayloadRequirementCannotBeFalsifiedAndDiskUpgradeIsCASFenced() async throws {
        let url = url()
        try await CADAssociativeFormatFixture.basicPackage(at: url)
        let store = FileCADDocumentStore(packageURL: url)
        let project = try store.read()
        let oldBytes = try CADAssociativeFormatFixture.bytes(url)
        let associated = try CADAssociativeFormatFixture.plane()
        project.planes.append(PersistedPlane(planeID: associated.id.raw, planeData: try JSONEncoder().encode(associated)))
        var payload = try store.makePayload(project)
        XCTAssertEqual(payload.schemaVersion, 2)
        payload.schemaVersion = 1
        XCTAssertThrowsError(try store.performWrite(payload))
        XCTAssertThrowsError(try CADModelContext.write(payload, to: store))
        XCTAssertThrowsError(try FileCADDocumentStore.createPackage(at: self.url(), payload: payload, overwrite: false))
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), oldBytes)
        let fresh = Project(name: "Stale metadata")
        var stale = try store.makePayload(fresh)
        stale.schemaVersion = 1
        // Same revision, independently upgraded schema: revision-only CAS is
        // insufficient; the final writer must observe the current disk floor.
        var upgraded = try CADAssociativeFormatFixture.manifest(url)
        upgraded.schemaVersion = 2
        try JSONEncoder().encode(upgraded).write(to: url.appendingPathComponent("manifest.json"))
        let upgradedBytes = try CADAssociativeFormatFixture.bytes(url)
        XCTAssertThrowsError(try store.performWrite(stale))
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), upgradedBytes)
        stale.schemaVersion = 3
        XCTAssertThrowsError(try store.performWrite(stale))
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), upgradedBytes)
    }

    func testFirstFormatUpgradeStagingFailureKeepsCompleteOldThenCompleteNewCommit() async throws {
        let url = url()
        let document = try await FloeCADDocument.create(at: url, name: "Upgrade")
        documents.append(document)
        let before = try CADAssociativeFormatFixture.bytes(url)
        document.session.perform(AddConstructionPlaneCommand(plane: try CADAssociativeFormatFixture.plane()))
        CADDocumentFaultInjection.beforeCommit = { throw NSError(domain: "SyntheticDatumFault", code: 1) }
        let failed = await document.save()
        CADDocumentFaultInjection.beforeCommit = nil
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), before)
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(url).schemaVersion, 1)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(url).schemaVersion, 2)
        XCTAssertEqual(try CADAssociativeFormatFixture.record(url).planes.count, 1)
        let previous = url.appendingPathComponent("previous")
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(previous).schemaVersion, 1)
        XCTAssertTrue(try CADAssociativeFormatFixture.record(previous).planes.isEmpty)
    }

    func testUnknownDefinitionVersionKindAndSupportKeepOriginalBytesAndCachedViewReadOnly() async throws {
        for kind in CADAssociativeFormatFixture.OpaqueKind.allCases {
            let url = url()
            try await CADAssociativeFormatFixture.basicPackage(at: url)
            try CADAssociativeFormatFixture.makeOpaque(url, kind: kind)
            let original = try CADAssociativeFormatFixture.bytes(url)
            let raw = try CADAssociativeFormatFixture.record(url)
            let document = try await open(url)
            XCTAssertTrue(document.isReadOnly)
            XCTAssertEqual(document.summary().schemaVersion, 2, "runtime read-only must not fabricate format 3")
            XCTAssertEqual(document.session.document.bodies.count, 1)
            XCTAssertEqual(document.session.document.planes.count, 1)
            XCTAssertEqual(document.session.document.sketches.count, 1)
            XCTAssertEqual(document.project.planes[0].planeData, raw.planes[0].data)
            XCTAssertEqual(document.project.sketches[0].sketchData, raw.sketches[0].data)
            let generation = document.liveChangeCount
            let bodyCount = document.session.document.bodies.count
            document.session.perform(AddSketchCommand(sketch: Sketch(plane: .ground)))
            document.session.amend(AddSketchCommand(sketch: Sketch(plane: .ground)))
            var previewRan = false
            document.session.preview { _ in previewRan = true }
            document.session.undo()
            document.session.redo()
            XCTAssertFalse(previewRan)
            XCTAssertEqual(document.liveChangeCount, generation)
            XCTAssertEqual(document.session.document.bodies.count, bodyCount)
            XCTAssertFalse(document.executeJSON(Data(#"{"op":"sketch.create","args":{}}"#.utf8)).isOK)
            XCTAssertFalse(document.nativeImportData(Data(), format: "step", fileName: nil, unitScale: nil).isOK)
            document.session.save()
            XCTAssertNotNil(document.session.lastSaveError)
            await document.session.saveAsync()
            XCTAssertNil(document.session.commitNow())
            let asyncResult3 = await document.save()
            XCTAssertFalse(asyncResult3.succeeded)
            let asyncResult4 = await document.saveViewportPreview(Data("synthetic".utf8))
            XCTAssertFalse(asyncResult4.succeeded)
            document.project.name = "Must not persist"
            let asyncResult5 = await document.save()
            XCTAssertFalse(asyncResult5.succeeded)
            let store = FileCADDocumentStore(packageURL: url)
            let loaded = try store.read()
            loaded.hasOpaqueAssociations = false
            loaded.formatVersion = 1
            XCTAssertThrowsError(try store.makePayload(loaded), "real unknown inline bytes override the cleared flag")
            let replacementPayload = try store.makePayload(Project(name: "Bypass flag"))
            XCTAssertThrowsError(try store.performWrite(replacementPayload), "disk semantics are checked even when the payload omits all opaque rows")
            XCTAssertThrowsError(try FileCADDocumentStore.createPackage(at: url, payload: replacementPayload, overwrite: true))
            do {
                _ = try await FloeCADDocument.create(at: url, name: "Bypass", overwrite: true)
                XCTFail("opaque package overwrite must refuse")
            } catch { }
            document.close()
            XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), original)
        }
    }

    func testFutureSchemaAllSaveRoutesRefuseAndOpaqueSemanticsNeverExemptIntegrity() async throws {
        let url = url()
        try await CADAssociativeFormatFixture.basicPackage(at: url)
        try CADAssociativeFormatFixture.rewrite(url, schema: 3) { _ in }
        let before = try CADAssociativeFormatFixture.bytes(url)
        let document = try await open(url)
        XCTAssertTrue(document.isReadOnly)
        let asyncResult6 = await document.save()
        XCTAssertFalse(asyncResult6.succeeded)
        let asyncResult7 = await document.saveViewportPreview(Data("synthetic".utf8))
        XCTAssertFalse(asyncResult7.succeeded)
        XCTAssertThrowsError(try document.context.save())
        let direct = FileCADDocumentStore(packageURL: url)
        _ = try direct.read()
        var payload = try FileCADDocumentStore(packageURL: self.url()).makePayload(Project(name: "Low schema"))
        payload.expectedRevision = direct.revision
        XCTAssertThrowsError(try direct.performWrite(payload))
        document.close()
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), before)
        let opaque = self.url()
        try await CADAssociativeFormatFixture.basicPackage(at: opaque)
        try CADAssociativeFormatFixture.makeOpaque(opaque, kind: .definitionKind)
        var manifest = try CADAssociativeFormatFixture.manifest(opaque)
        manifest.modelSHA256 = String(repeating: "0", count: 64)
        try JSONEncoder().encode(manifest).write(to: opaque.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try FileCADDocumentStore(packageURL: opaque).readWithoutRecovery(), "unknown semantics cannot waive a reconstructible model digest")
        let asyncResult8 = await FloeCADDocument.storedIdentity(at: opaque)
        XCTAssertNil(asyncResult8)
    }

    func testUnencodableNewAssociationFailsBeforeItCanBeSilentlySkipped() async throws {
        let url = url()
        let document = try await FloeCADDocument.create(at: url, name: "Invalid association")
        documents.append(document)
        let bytes = try CADAssociativeFormatFixture.bytes(url)
        var plane = try CADAssociativeFormatFixture.plane()
        guard case var .offset(definition)? = plane.definition else { return XCTFail("fixture must be an offset") }
        definition.distance = Expr(value: .nan)
        plane.definition = .offset(definition)
        document.session.perform(AddConstructionPlaneCommand(plane: plane))
        let saved = await document.save()
        XCTAssertFalse(saved.succeeded, "a save must not omit a new definition after an encoding failure")
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), bytes)
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(url).schemaVersion, 1)
    }

    func testMalformedKnownAssociationIsCorruptNotFutureReadOnly() async throws {
        let url = url()
        try await CADAssociativeFormatFixture.basicPackage(at: url)
        try CADAssociativeFormatFixture.rewrite(url, schema: 2) { record in
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: record.planes[0].data) as? [String: Any])
            raw["definition"] = 42
            record.planes[0].data = try JSONSerialization.data(withJSONObject: raw)
            record.planes[0].sha256 = FileCADDocumentStore.sha256(record.planes[0].data)
        }
        let before = try CADAssociativeFormatFixture.bytes(url)
        XCTAssertThrowsError(try FileCADDocumentStore(packageURL: url).readWithoutRecovery())
        let asyncResult9 = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertNil(asyncResult9)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), before)
    }

    // Fixed source fixture, NOT current supportedVersion+1 and NOT an old
    // binary App run. Extracted from 17eccb68 PersistenceModels.swift:35-43,
    // DocumentSession.swift:699/1058, SketchPlanes.swift:74-112.
    private nonisolated struct SchemaOnePlaneReader: Decodable {
        let id: ConstructionPlaneID
        let plane: SketchPlane
        let size: Double
        let isHidden: Bool
        private enum CodingKeys: String, CodingKey { case id, plane, size, isHidden }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(ConstructionPlaneID.self, forKey: .id)
            plane = try c.decode(SketchPlane.self, forKey: .plane)
            size = try c.decode(Double.self, forKey: .size)
            isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        }
        static func sessionAllowsWrite(schema: Int) -> Bool { !(schema > 1) }
    }
    func testFixedSchemaOneDecoderIgnoresDefinitionButItsSessionGateRefusesFormatTwo() throws {
        let plane = try CADAssociativeFormatFixture.plane()
        let legacy = try JSONDecoder().decode(SchemaOnePlaneReader.self, from: JSONEncoder().encode(plane))
        XCTAssertEqual(legacy.plane, plane.plane)
        XCTAssertEqual(legacy.id, plane.id)
        XCTAssertTrue(SchemaOnePlaneReader.sessionAllowsWrite(schema: 1))
        XCTAssertFalse(SchemaOnePlaneReader.sessionAllowsWrite(schema: 2), "the known old session gate, not an ignored new minWriter field, protects semantics")
    }
}
