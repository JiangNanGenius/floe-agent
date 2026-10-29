//
//  CADMaterialBindingFenceTests.swift
//  FloeCADKitTests
//
//  Private lane-test source. Do NOT compile it in this lane: it is landed for
//  the unified core/primary batch to copy into
//  FloeCADKit/Tests/FloeCADKitTests and run with the real package test target.
//
//  Covers the two material-inspector safety rules added by cad-ui-closure:
//   * a numeric face index is never reused after a mesh rebuild, and an
//     unmatched stale signature refuses the write before any undo record;
//   * a successful Apply merges the live document library and is ONE undo;
//   * one missing body in a whole-body selection refuses the whole apply.
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADMaterialBindingFenceTests: XCTestCase {
    private var workDir: URL!
    private var openDocuments: [FloeCADDocument] = []

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADMaterialFence-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in openDocuments where !document.isClosed {
            document.close()
        }
        openDocuments.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: Helpers

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        let url = workDir.appendingPathComponent("\(name)-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        openDocuments.append(document)
        return document
    }

    private func personalStore() -> CADPersonalMaterialLibraryStore {
        CADPersonalMaterialLibraryStore(
            fileURL: workDir.appendingPathComponent("library-\(UUID().uuidString).json"))
    }

    @discardableResult
    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    /// Real extruded solid with an analytic B-rep, so face material bindings
    /// are representable. The rectangle is offset per call to keep the second
    /// body spatially independent.
    private func makeBox(_ document: FloeCADDocument, name: String,
                         offsetX: Double = 0) throws -> UUID {
        let sketch = try run(document, #"{"op":"sketch.create","args":{"name":"\#(name)"}}"#)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[\(offsetX),0],"max":[\(offsetX + 40),20]}]}}
        """)
        let extrude = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)",
         "seedPoint":[\(offsetX + 20),10],"distance":10}}
        """)
        let raw = try XCTUnwrap((extrude["producedBodyIDs"] as? [String])?.first
            ?? (extrude["changedBodyIDs"] as? [String])?.first,
            "extrude reply carries no body id: \(extrude)")
        return try XCTUnwrap(UUID(uuidString: raw))
    }

    private func body(_ id: UUID, in document: FloeCADDocument) throws -> Body {
        try XCTUnwrap(document.session.document.bodies.first { $0.id.raw == id })
    }

    private func wholeBodyTarget(_ bodies: [Body]) -> CADMaterialTarget {
        CADMaterialTarget(
            bodyIDs: bodies.map(\.id.raw),
            faceBodyID: nil,
            faceIndex: nil,
            bodyNames: bodies.map(\.name),
            isFaceTarget: false,
            note: nil,
            faceIdentity: nil,
            bodyMeshRevisions: Dictionary(uniqueKeysWithValues: bodies.map {
                ($0.id.raw, $0.meshRevision)
            }))
    }

    private func faceTarget(_ body: Body, faceIndex: Int,
                            signature: FaceSignature,
                            meshRevision: UInt64,
                            triangles: [Int] = []) -> CADMaterialTarget {
        CADMaterialTarget(
            bodyIDs: [body.id.raw],
            faceBodyID: body.id.raw,
            faceIndex: faceIndex,
            bodyNames: [body.name],
            isFaceTarget: true,
            note: nil,
            faceIdentity: CADMaterialFaceIdentity(
                signature: signature,
                meshRevision: meshRevision,
                triangles: triangles),
            bodyMeshRevisions: [body.id.raw: meshRevision])
    }

    // MARK: 1. Stale numeric index

    func testStaleNumericFaceIndexIsNeverReusedAfterRebuild() async throws {
        let document = try await makeDocument("StaleIndex")
        let bodyID = try makeBox(document, name: "Box")
        document.session.undoStack.reset()

        let liveBody = try body(bodyID, in: document)
        let candidates = CADFaceMaterialResolver.candidates(for: liveBody)
        XCTAssertGreaterThanOrEqual(candidates.count, 2,
                                    "the solid must expose at least two stable faces")
        let actual = candidates[0]
        let other = candidates[1]
        XCTAssertNotEqual(actual.index, other.index)

        // The index is deliberately the OTHER face's index, while the stable
        // signature is the actually selected face. The mesh generation stamp
        // is old, so Apply must re-resolve by signature and must never keep
        // the stored numeric index.
        let target = faceTarget(liveBody,
                                faceIndex: other.index,
                                signature: actual.signature,
                                meshRevision: liveBody.meshRevision &+ 1)
        let model = CADMaterialDraftModel(document: document, target: target,
                                          personalStore: personalStore())
        defer { model.stopObserving() }

        model.apply()
        XCTAssertNil(model.errorMessage)
        let applied = try XCTUnwrap(
            document.session.document.bodies.first?.materialFaceBindings.first,
            "the uniquely matched face should be bound once")
        XCTAssertTrue(CADMaterialTargetResolver.signaturesMatch(
            applied.key.signature, actual.signature))
        let capturedIndex = try XCTUnwrap(applied.key.capturedIndex)
        XCTAssertEqual(capturedIndex, actual.index,
                       "the stale numeric index must not be reused")
        XCTAssertNotEqual(capturedIndex, other.index)

        // The whole apply (library + face binding) is one undo record.
        XCTAssertTrue(document.session.undoStack.canUndo)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, 1)
        document.session.undo()
        let revertedBody = try body(bodyID, in: document)
        XCTAssertTrue(revertedBody.materialFaceBindings.isEmpty)
        XCTAssertNil(document.session.document.materialLibraryData)
        XCTAssertFalse(document.session.undoStack.canUndo)
    }

    func testUnmatchedStaleFaceSignatureRefusesWrite() async throws {
        let document = try await makeDocument("StaleRefused")
        let bodyID = try makeBox(document, name: "Box")
        document.session.undoStack.reset()

        let liveBody = try body(bodyID, in: document)
        let candidates = CADFaceMaterialResolver.candidates(for: liveBody)
        let actual = try XCTUnwrap(candidates.first)
        // A plausible planar face that no current kernel face can match.
        let unmatched = FaceSignature(kind: .planar,
                                      normal: SIMD3(0, 0, 1),
                                      centroid: SIMD3(1_000_000, 1_000_000, 1_000_000),
                                      area: 12_345,
                                      planeOffset: 1_000_000)
        let target = faceTarget(liveBody,
                                faceIndex: actual.index,
                                signature: unmatched,
                                meshRevision: liveBody.meshRevision &+ 1)
        let model = CADMaterialDraftModel(document: document, target: target,
                                          personalStore: personalStore())
        defer { model.stopObserving() }

        // The same revalidation runs before a transient preview and before
        // Apply. Both must invalidate the stale mapping instead of painting
        // or writing to the old index.
        XCTAssertNotNil(model.refreshTargetBinding())
        XCTAssertNil(model.target.faceIndex)
        XCTAssertNotNil(model.targetError)

        model.apply()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.target.faceIndex)
        XCTAssertFalse(document.session.undoStack.canUndo,
                       "a refused stale target must not create an undo record")
        let unchanged = try body(bodyID, in: document)
        XCTAssertNil(unchanged.material)
        XCTAssertTrue(unchanged.materialFaceBindings.isEmpty)
        XCTAssertNil(document.session.document.materialLibraryData)
    }

    // MARK: 2. Whole-body target must be complete

    func testPartiallyMissingWholeBodyTargetRefusesApply() async throws {
        let document = try await makeDocument("MissingBody")
        let firstID = try makeBox(document, name: "First")
        let secondID = try makeBox(document, name: "Second", offsetX: 100)
        document.session.undoStack.reset()

        let first = try body(firstID, in: document)
        let second = try body(secondID, in: document)
        let target = wholeBodyTarget([first, second])
        let model = CADMaterialDraftModel(document: document, target: target,
                                          personalStore: personalStore())
        defer { model.stopObserving() }

        document.session.perform(DeleteBodiesCommand(
            ids: [second.id], document: document.session.document))
        document.session.undoStack.reset()

        model.apply()
        XCTAssertNotNil(model.errorMessage,
                        "one missing body must fail the whole target")
        XCTAssertFalse(document.session.undoStack.canUndo)
        let unchanged = try body(firstID, in: document)
        XCTAssertNil(unchanged.material)
        XCTAssertTrue(unchanged.materialFaceBindings.isEmpty)
        XCTAssertNil(document.session.document.materialLibraryData)
        XCTAssertNil(document.session.document.bodies.first { $0.id.raw == secondID })
    }

    // MARK: 3. Live library merge + one undo

    func testApplyMergesConcurrentLibraryEntryAndUndoesAsOneStep() async throws {
        let document = try await makeDocument("LibraryMerge")
        let bodyID = try makeBox(document, name: "Box")
        document.session.undoStack.reset()

        let liveBody = try body(bodyID, in: document)
        let target = wholeBodyTarget([liveBody])
        let model = CADMaterialDraftModel(document: document, target: target,
                                          personalStore: personalStore())
        defer { model.stopObserving() }

        // Another editor adds an entry AFTER this inspector opened. Apply
        // must start from the live library, not the stale local snapshot.
        var library = CADMaterialLibraryCodec.decode(
            document.session.document.materialLibraryData)
        let concurrent = CADMaterialDefinition(name: "Concurrent")
        library.upsert(concurrent)
        let beforeConcurrent = document.session.document.materialLibraryData
        let encoded = try XCTUnwrap(CADMaterialLibraryCodec.encode(library))
        document.session.perform(SetMaterialLibraryDataCommand(
            before: beforeConcurrent, after: encoded))
        document.session.undoStack.reset()

        model.apply()
        XCTAssertNil(model.errorMessage)

        let merged = CADMaterialLibraryCodec.decode(
            document.session.document.materialLibraryData)
        XCTAssertNotNil(merged.entry(named: "Concurrent"),
                        "the concurrent entry must survive Apply")
        XCTAssertEqual(merged.entries.count, 2)
        let appliedEntry = try XCTUnwrap(
            merged.entries.first { $0.id != concurrent.id },
            "the applied draft must add its own library entry")
        let appliedBody = try body(bodyID, in: document)
        XCTAssertEqual(appliedBody.material?.materialID,
                       appliedEntry.id.raw.uuidString,
                       "the applied snapshot must reference the final library identity")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, 1,
                       "library + appearance ride in one composite undo")

        document.session.undo()
        let reverted = CADMaterialLibraryCodec.decode(
            document.session.document.materialLibraryData)
        XCTAssertNotNil(reverted.entry(named: "Concurrent"),
                        "one undo must keep the concurrent entry")
        XCTAssertEqual(reverted.entries.count, 1)
        XCTAssertNil(try body(bodyID, in: document).material)
        XCTAssertFalse(document.session.undoStack.canUndo)
    }

    // MARK: 3b. Rename/delete also merge the live library

    @discardableResult
    private func writeLibrary(_ definitions: [CADMaterialDefinition],
                              to document: FloeCADDocument) throws -> CADMaterialLibrary {
        var library = CADMaterialLibraryCodec.decode(
            document.session.document.materialLibraryData)
        for definition in definitions { library.upsert(definition) }
        let before = document.session.document.materialLibraryData
        let encoded = try XCTUnwrap(CADMaterialLibraryCodec.encode(library))
        document.session.perform(SetMaterialLibraryDataCommand(before: before,
                                                               after: encoded))
        return library
    }

    func testRenameAndDeleteMergeLiveLibraryEntries() async throws {
        let document = try await makeDocument("LibraryRename")
        let bodyID = try makeBox(document, name: "Box")
        let liveBody = try body(bodyID, in: document)
        let alpha = CADMaterialDefinition(name: "Alpha")
        let beta = CADMaterialDefinition(name: "Beta")
        try writeLibrary([alpha, beta], to: document)

        let model = CADMaterialDraftModel(document: document,
                                          target: wholeBodyTarget([liveBody]),
                                          personalStore: personalStore())
        defer { model.stopObserving() }

        // Another editor adds a third entry after this inspector opened.
        let concurrent = CADMaterialDefinition(name: "Concurrent")
        try writeLibrary([concurrent], to: document)
        document.session.undoStack.reset()

        XCTAssertNil(model.renameDocumentEntry(alpha.id, to: "Renamed"))
        var live = CADMaterialLibraryCodec.decode(
            document.session.document.materialLibraryData)
        XCTAssertEqual(live.entry(alpha.id)?.name, "Renamed")
        XCTAssertNotNil(live.entry(beta.id))
        XCTAssertNotNil(live.entry(concurrent.id),
                        "rename must not write away a concurrent entry")

        let outcome = model.deleteDocumentEntry(beta.id)
        XCTAssertNil(outcome.error)
        live = CADMaterialLibraryCodec.decode(
            document.session.document.materialLibraryData)
        XCTAssertNil(live.entry(beta.id))
        XCTAssertNotNil(live.entry(alpha.id))
        XCTAssertNotNil(live.entry(concurrent.id),
                        "delete must not write away a concurrent entry")
    }

    // MARK: 4. Presentation assembly-instance identity

    #if canImport(RealityKit)
    func testPresentationCarriesAssemblySourceIdentityForPreview() async throws {
        let document = try await makeDocument("AssemblySource")
        let sourceID = try makeBox(document, name: "Part")
        let source = try body(sourceID, in: document)
        let instanceID = UUID()
        let assembly = CADAssembly(instances: [
            .init(id: instanceID, name: "Placed part", bodyID: source.id.raw,
                  transform: CADTransform(position: SIMD3(140, 20, 30))),
        ])
        document.session.perform(SetAssemblyDataCommand(
            before: document.session.document.assemblyData,
            after: try assembly.encoded()))
        document.session.perform(SetItemVisibilityCommand(
            item: .body(source.id), isHidden: true))

        let scene = CADPresentationSceneBuilder.build(
            snapshot: document.sceneSnapshot(), documentKey: "assembly-source")
        XCTAssertFalse(scene.bodies.contains { $0.id == source.id.raw },
                       "a hidden source body must not add an ordinary entity")
        let placed = try XCTUnwrap(scene.bodies.first { $0.id == instanceID })
        XCTAssertEqual(placed.sourceBodyID, source.id.raw)
        XCTAssertTrue(placed.matchesMaterialTarget([source.id.raw]),
                      "a source-body material target must preview every instance")
        XCTAssertTrue(placed.matchesMaterialTarget([instanceID]))
        XCTAssertFalse(placed.matchesMaterialTarget([UUID()]))
        XCTAssertEqual(placed.transform.columns.3.x, Float(0.14), accuracy: 1e-5)
        XCTAssertEqual(placed.transform.columns.3.y, Float(0.02), accuracy: 1e-5)
        XCTAssertEqual(placed.transform.columns.3.z, Float(0.03), accuracy: 1e-5)
        XCTAssertEqual(placed.mesh.positions.count, source.render.positions.count)
        XCTAssertNotEqual(placed.id, source.id.raw,
                          "entity identity stays the instance ID")
    }
    #endif
}
