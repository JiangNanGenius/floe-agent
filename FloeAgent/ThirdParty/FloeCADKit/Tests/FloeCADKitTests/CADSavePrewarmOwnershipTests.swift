import Foundation
import XCTest
import simd
@testable import FloeCAD

/// E37 save/prewarm ownership boundary, verified through the REAL kernel and
/// REAL B-rep shapes (no fake serializer):
///
///  1. `OCCTKernel.independentSnapshot` preserves the exact analytic geometry
///     and produces byte-identical serialized output (pinned no-triangle
///     format), so the off-main save path persists precisely what the live
///     handle holds.
///  2. The detached prewarm serializer reads only independently-owned
///     snapshots: a live geometry replacement during the suspension cannot
///     leak into the commit; the persisted generation is always the latest.
///  3. A save refused at the existing writeBlock fence after a detached
///     prewarm never adopts a commit (store bytes/revision unchanged) and a
///     later save is byte-exact.
///  4. Save/reopen round-trips the analytic blob byte-for-byte and an
///     unchanged-geometry resave keeps the serialized bytes stable.
///
/// Race order is established by the DEBUG suspension hooks (they fire on the
/// actual detached serializer / prewarm entry), never by sleep/yield guesses.
@MainActor
final class CADSavePrewarmOwnershipTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADSavePrewarmOwnership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in documents {
            document.session.savePrewarmSuspensionForTesting = nil
            document.session.brepSerializationSuspensionForTesting = nil
            document.close()
        }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Fixtures

    private func makeDocument(name: String) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(name)-\(UUID().uuidString).floecad"), name: name)
        documents.append(document)
        return document
    }

    /// One real OCCT solid (a 12×10×8 mm box primitive, volume 960 mm³).
    @discardableResult
    private func addAnalyticBox(_ document: FloeCADDocument, name: String = "Box") throws -> Body {
        let spec = PrimitiveSpec.box(width: 12, depth: 10, height: 8)
        var body = Body(name: name, euclidMesh: .primitive(spec), revision: 0)
        XCTAssertTrue(body.adoptBRep(try XCTUnwrap(OCCTKernel.primitiveShape(spec, placement: .identity))))
        document.session.perform(AddBodyCommand(body: body, title: "Fixture"))
        return try XCTUnwrap(document.session.document.bodies.first { $0.id == body.id })
    }

    private func volume(_ body: Body, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        try OCCTKernel.volume(XCTUnwrap(body.brep, file: file, line: line))
    }

    // MARK: - 1. Snapshot exactness through the real kernel

    func testIndependentSnapshotPreservesExactAnalyticGeometryAndBytes() async throws {
        let document = try await makeDocument(name: "Snapshot")
        let body = try addAnalyticBox(document)
        let handle = try XCTUnwrap(body.brep)

        let snapshot = try XCTUnwrap(OCCTKernel.independentSnapshot(handle),
                                     "a copyable solid must snapshot; callers refuse the off-main path otherwise")

        // Byte-identical persisted representation (pinned, no-triangle format):
        // the off-main save path persists exactly what the live handle holds.
        XCTAssertEqual(OCCTKernel.serialize(snapshot), OCCTKernel.serialize(handle))
        // Exact analytic geometry survives the copy — volume and the
        // planar/cylindrical face histogram are kernel-derived.
        XCTAssertEqual(OCCTKernel.volume(snapshot), 960, accuracy: 1e-6)
        let snapshotTypes = OCCTKernel.faceTypeCounts(snapshot)
        let liveTypes = OCCTKernel.faceTypeCounts(handle)
        XCTAssertEqual(snapshotTypes.planar, liveTypes.planar)
        XCTAssertEqual(snapshotTypes.cylindrical, liveTypes.cylindrical)
        XCTAssertEqual(snapshotTypes.other, liveTypes.other)
        XCTAssertEqual(OCCTKernel.volume(snapshot), OCCTKernel.volume(handle), accuracy: 1e-9)
    }

    // MARK: - 2. Detached serialization vs a live geometry replacement

    func testDetachedPrewarmSurvivesLiveGeometryReplacementAndPersistsLatestGeneration() async throws {
        let document = try await makeDocument(name: "Race")
        let session = document.session
        let original = try addAnalyticBox(document)
        XCTAssertEqual(try volume(original), 960, accuracy: 1e-6)

        // Replace the live body's geometry with a DIFFERENT exact solid while
        // the detached snapshot serializer is in flight. The pre-merge body is
        // snapshotted before this runs, so the serialized bytes can only ever
        // describe the pre-swap generation; the generation guard must then
        // keep those stale bytes out of the cache and the commit.
        session.brepSerializationSuspensionForTesting = { @Sendable in
            await MainActor.run {
                let before = session.document.bodies[0]
                let spec = PrimitiveSpec.box(width: 20, depth: 20, height: 5)
                // ReplaceBodyCommand assigns the next document revision.
                var replacement = Body(id: before.id, name: before.name, euclidMesh: .primitive(spec),
                                       revision: before.meshRevision)
                guard replacement.adoptBRep(OCCTKernel.primitiveShape(spec, placement: .identity)!) else {
                    XCTFail("replacement fixture must adopt its analytic solid")
                    return
                }
                session.perform(ReplaceBodyCommand(title: "Swap", before: before, after: replacement))
            }
        }
        let outcome = await document.save()
        session.brepSerializationSuspensionForTesting = nil
        XCTAssertTrue(outcome.succeeded, outcome.error ?? "")

        // The commit persisted the LATEST generation: 20×20×5 mm = 2000 mm³,
        // never the stale snapshot's 960 mm³ box.
        let swapped = try XCTUnwrap(session.document.bodies.first)
        XCTAssertEqual(try volume(swapped), 2000, accuracy: 1e-6)
        let swappedBytes = try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(swapped.brep)))
        document.close()
        documents.removeAll { $0 === document }

        let reopened = try await FloeCADDocument.open(at: document.url)
        documents.append(reopened)
        let persisted = try XCTUnwrap(reopened.session.document.bodies.first)
        XCTAssertEqual(try volume(persisted), 2000, accuracy: 1e-6)
        XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(persisted.brep)), swappedBytes,
                       "persisted analytic bytes must equal what the real kernel serializes for the live generation")
    }

    // MARK: - 3. Refused save after a detached prewarm adopts no commit

    func testRefusedSaveAfterDetachedPrewarmLeavesStoreUnchangedAndLaterSaveIsExact() async throws {
        let f = try await associativeFixture()
        let session = f.document.session
        // A geometry change (a second analytic solid) makes the prewarm's
        // pending list non-empty, so the detached serializer — and thus the
        // suspension hook below — actually runs on this save.
        let extra = try addAnalyticBox(f.document, name: "Late box")
        XCTAssertEqual(try volume(extra), 960, accuracy: 1e-6)
        let bytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        let revision = f.document.revision

        // Begin a sketch preview (writeBlock) WHILE the detached snapshot
        // serializer is in flight. The save must refuse at the existing
        // writeBlock fence after the prewarm — adopting no cache, no commit.
        var previewToken: DocumentSession.SketchPreviewToken?
        session.brepSerializationSuspensionForTesting = { @Sendable in
            await MainActor.run {
                previewToken = session.beginSketchPreview(sketchID: f.sourceSketch.id)
            }
        }
        let refused = await f.document.save()
        session.brepSerializationSuspensionForTesting = nil
        XCTAssertFalse(refused.succeeded)
        XCTAssertEqual(refused.error, session.writeBlock?.message)
        XCTAssertEqual(refused.revision, revision,
                       "a refused save reports the last committed identity without advancing it")
        XCTAssertEqual(f.document.revision, revision, "a refused save must not advance the store revision")
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes,
                       "a refused save must leave every stored byte unchanged")

        let token = try XCTUnwrap(previewToken)
        XCTAssertTrue(session.cancelSketchPreview(token))
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertGreaterThan(saved.revision, revision)

        f.document.close()
        documents.removeAll { $0 === f.document }
        let reopened = try await FloeCADDocument.open(at: f.document.url)
        documents.append(reopened)
        let source = try XCTUnwrap(reopened.session.document.body(with: f.sourceBody))
        XCTAssertEqual(try volume(source), 12_000, accuracy: 1e-4)
        XCTAssertEqual(try volume(XCTUnwrap(reopened.session.document.bodies
            .first { $0.id == extra.id })), 960, accuracy: 1e-6)
        XCTAssertEqual(reopened.session.document.sketches.first { $0.id == f.sourceSketch.id },
                       f.sourceSketch, "the cancelled preview must not have touched the stored sketch")
    }

    // MARK: - 4. Save/reopen round trip and unchanged-geometry resave

    func testSaveReopenRoundTripsExactBrepAndUnchangedResaveKeepsBytesStable() async throws {
        let document = try await makeDocument(name: "RoundTrip")
        _ = try addAnalyticBox(document)
        let first = await document.save()
        XCTAssertTrue(first.succeeded, first.error ?? "")
        let savedBytes = try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(document.session.document.bodies[0].brep)))
        document.close()
        documents.removeAll { $0 === document }

        let reopened = try await FloeCADDocument.open(at: document.url)
        documents.append(reopened)
        let body = try XCTUnwrap(reopened.session.document.bodies.first)
        XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(body.brep)), savedBytes,
                       "the reopened analytic blob must be byte-identical to what was committed")
        XCTAssertEqual(try volume(body), 960, accuracy: 1e-6)

        // A rename-only edit changes no geometry; a resave must not churn the
        // analytic blob (the serialization contract is content-addressed).
        let renamed = try XCTUnwrap(reopened.session.document.bodies.first)
        reopened.session.perform(RenameItemCommand(item: .body(renamed.id),
                                                   before: renamed.name, after: "Renamed box"))
        let second = await reopened.save()
        XCTAssertTrue(second.succeeded, second.error ?? "")
        XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(reopened.session.document.bodies.first?.brep)),
                       savedBytes)
    }

    func testCloseDuringDetachedPrewarmRefusesLateCommit() async throws {
        let document = try await makeDocument(name: "Closed prewarm")
        _ = try addAnalyticBox(document)
        let bytes = try CADAssociativeFormatFixture.bytes(document.url)
        document.session.brepSerializationSuspensionForTesting = { @Sendable in
            await MainActor.run { document.close() }
        }
        let outcome = await document.save()
        document.session.brepSerializationSuspensionForTesting = nil
        XCTAssertFalse(outcome.succeeded, "a revoked document cannot accept a late save")
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(document.url), bytes)
    }

    func testCloseAndDeleteDuringDetachedPrewarmCannotRecreatePackage() async throws {
        let document = try await makeDocument(name: "Deleted prewarm")
        _ = try addAnalyticBox(document)
        document.session.brepSerializationSuspensionForTesting = { @Sendable in
            await MainActor.run {
                document.close()
                do { try FileManager.default.removeItem(at: document.url) }
                catch { XCTFail("fixture package deletion failed: \(error)") }
            }
        }
        let outcome = await document.save()
        document.session.brepSerializationSuspensionForTesting = nil
        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.url.path),
                       "the late serializer must never resurrect a closed/deleted package")
    }

    // MARK: - Associative fixture (source sketch + offset plane definition)

    private struct AssociativeFixture {
        var document: FloeCADDocument
        var sourceSketch: Sketch
        var sourceBody: BodyID
    }

    private func extrude(_ sketch: Sketch, distance: Double, body: BodyID) -> FeatureNode {
        FeatureNode(name: "Extrusion", kind: .extrude(profile: ProfileRef(sketchID: sketch.id,
            entityIDs: sketch.entities.map(\.id), holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: distance), symmetric: false,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []), outputBodyIDs: [body])
    }

    /// 40×30 mm plate extruded 10 mm (volume 12 000 mm³) plus an offset datum
    /// plane on its top face, so the document has live associations and the
    /// sketch preview fence is exercisable.
    private func associativeFixture() async throws -> AssociativeFixture {
        let document = try await makeDocument(name: "Associative")
        let sketch = Sketch(name: "Source", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(40, 30))])
        let sourceBody = BodyID()
        document.session.recordAndRebuild([extrude(sketch, distance: 10, body: sourceBody)],
                                          extra: [AddSketchCommand(sketch: sketch)], title: "Plate")
        let result = document.nativeQueryJSON(["scope": "faces"])
        XCTAssertTrue(result.isOK, result.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        let face = try XCTUnwrap(rows.first {
            ($0["bodyID"] as? String) == sourceBody.raw.uuidString && (($0["normal"] as? [Double])?[1] ?? 0) > 0.99
        })
        let created = CADParameterService(document: document).handle(action: "datum.offsetPlane.create", args: [
            "body_id": sourceBody.raw.uuidString, "face_index": try XCTUnwrap(face["index"]),
            "query_token": try XCTUnwrap(face["query_token"]), "expression": "5"])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertFalse(document.hasUnsavedChanges)
        return AssociativeFixture(document: document, sourceSketch: sketch, sourceBody: sourceBody)
    }
}
