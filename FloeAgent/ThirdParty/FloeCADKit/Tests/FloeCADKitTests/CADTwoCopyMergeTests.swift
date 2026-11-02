import XCTest
import Foundation
import simd
@testable import FloeCAD

/// Real packages, copied common checkpoints and native OCCT feature rebuilds.
/// Authored here for the primary App window; not executed by this private lane.
@MainActor
final class CADTwoCopyMergeTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CADTwoCopies-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        CADDocumentFaultInjection.beforeCommit = nil
        for document in documents { document.close() }
        documents = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Pair {
        let current: FloeCADDocument
        let other: FloeCADDocument
        let base: UUID
        let first: FeatureID
        let second: FeatureID
    }

    private func run(_ document: FloeCADDocument, _ operation: String, _ args: [String: Any]) throws -> [String: Any] {
        let result = document.execute(["op": operation, "args": args])
        XCTAssertTrue(result.isOK, result.message ?? operation)
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
    }
    private func box(_ document: FloeCADDocument, x: Double) throws -> FeatureNode {
        let sketch = try run(document, "sketch.create", ["origin": [x, 0, 0], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]])
        let id = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(document, "sketch.addEntities", ["sketchID": id, "entities": [["kind": "rect", "min": [0, 0], "max": [10, 10]]]])
        _ = try run(document, "feature.extrude", ["sketchID": id, "seedPoint": [5, 5], "distance": 10])
        return try XCTUnwrap(document.session.document.features.nodes.last)
    }
    private func pair(sameBody: Bool = false) async throws -> Pair {
        let current = try await FloeCADDocument.create(at: directory.appendingPathComponent("current.floecad"), name: "Shared design")
        documents.append(current)
        let first = try box(current, x: 0)
        let second: FeatureNode
        if sameBody {
            let body = try XCTUnwrap(first.outputBodyIDs.first)
            second = FeatureNode(name: "Move", kind: .transform(body: BodyRef(producer: first.id, bodyID: body),
                delta: Transform3D(translation: SIMD3(10, 0, 0))), outputBodyIDs: [body])
            current.session.recordAndRebuild([second], title: "Move")
        } else { second = try box(current, x: 100) }
        let version = try await current.createNamedVersion(name: "Shared starting point")
        let otherURL = directory.appendingPathComponent("other.floecad")
        try FileManager.default.copyItem(at: current.url, to: otherURL)
        let other = try await FloeCADDocument.open(at: otherURL)
        documents.append(other)
        return Pair(current: current, other: other, base: version.version.id, first: first.id, second: second.id)
    }
    private func node(_ document: FloeCADDocument, _ id: FeatureID) throws -> FeatureNode {
        try XCTUnwrap(document.session.document.features.node(id))
    }
    private func editedDistance(_ document: FloeCADDocument, _ id: FeatureID, _ value: Double) throws -> FeatureKind {
        guard case let .extrude(profile, plane, _, symmetric, boolean, extra, termination) = try node(document, id).kind else {
            throw CADDocumentError(code: "fixture", message: "Expected the real extrude feature")
        }
        return .extrude(profile: profile, plane: plane, distance: Expr(value: value), symmetric: symmetric,
                        boolean: boolean, extraProfiles: extra, termination: termination)
    }
    private func edit(_ document: FloeCADDocument, _ id: FeatureID, _ value: Double) throws {
        document.session.editFeature(id, to: try editedDistance(document, id, value))
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
    }
    private func distance(_ document: FloeCADDocument, _ id: FeatureID) throws -> Double {
        guard case let .extrude(_, _, value, _, _, _, _) = try node(document, id).kind else {
            throw CADDocumentError(code: "fixture", message: "Expected extrude distance")
        }
        return value.value
    }
    private func save(_ document: FloeCADDocument) async throws {
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "save failed")
        if !saved.succeeded { throw CADDocumentError(code: "fixture_save", message: saved.error ?? "save failed") }
    }
    private func exactFiles(_ root: URL) throws -> [String: Data] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }
    private func failure(code: String? = nil, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected an explicit refusal") }
        catch {
            if let code { XCTAssertEqual((error as? CADDocumentError)?.code, code) }
        }
    }
    private func review(_ p: Pair) async throws -> CADTwoCopyMergeReview {
        try await p.current.compareCopy(at: p.other.url, baseVersionID: p.base)
    }

    func testIndependentFeaturesMergeOneUndoRedoSaveAndReopen() async throws {
        let p = try await pair()
        try edit(p.current, p.first, 20); try await save(p.current)
        try edit(p.other, p.second, 30); try await save(p.other)
        let currentBefore = try exactFiles(p.current.url), sourceBefore = try exactFiles(p.other.url)
        let baseBefore = try exactFiles(p.current.url.appendingPathComponent("versions/\(p.base.uuidString)"))
        let depth = p.current.session.undoStack.undoCommands.count
        let report = try await review(p)
        XCTAssertTrue(report.conflictIDs.isEmpty); XCTAssertTrue(report.unsupportedIDs.isEmpty)
        XCTAssertTrue(report.rows.contains { $0.id == "feature:\(p.first.raw.uuidString)" && $0.status == "current" })
        XCTAssertTrue(report.rows.contains { $0.id == "feature:\(p.second.raw.uuidString)" && $0.status == "incoming" })
        XCTAssertEqual(try exactFiles(p.current.url), currentBefore, "Comparison must write nothing")
        let merged = try await p.current.mergeCopy(planID: report.id)
        XCTAssertTrue(merged.applied)
        XCTAssertEqual(p.current.session.undoStack.undoCommands.count, depth + 1)
        XCTAssertEqual(try distance(p.current, p.first), 20)
        XCTAssertEqual(try distance(p.current, p.second), 30)
        for (id, expected) in [(p.first, 2_000.0), (p.second, 3_000.0)] {
            let bodyID = try XCTUnwrap(try node(p.current, id).outputBodyIDs.first)
            let body = try XCTUnwrap(p.current.session.document.body(with: bodyID))
            XCTAssertNotNil(body.brep, "The merged intent must have real native geometry")
            XCTAssertEqual(MeasureKit.volume(of: body), expected, accuracy: 0.01)
        }
        p.current.session.undo()
        XCTAssertEqual(try distance(p.current, p.first), 20)
        XCTAssertEqual(try distance(p.current, p.second), 10)
        p.current.session.redo()
        XCTAssertEqual(try distance(p.current, p.second), 30)
        try await save(p.current)
        let ids = p.current.session.document.features.nodes.map(\.id)
        p.current.close()
        let reopened = try await FloeCADDocument.open(at: p.current.url); documents.append(reopened)
        XCTAssertEqual(reopened.session.document.features.nodes.map(\.id), ids)
        XCTAssertEqual(try distance(reopened, p.first), 20)
        XCTAssertEqual(try distance(reopened, p.second), 30)
        XCTAssertEqual(try exactFiles(p.other.url), sourceBefore)
        XCTAssertEqual(try exactFiles(reopened.url.appendingPathComponent("versions/\(p.base.uuidString)")), baseBefore)
    }

    func testIndependentFeaturesOnSameBodyRebuildBothIntents() async throws {
        let p = try await pair(sameBody: true)
        try edit(p.current, p.first, 20); try await save(p.current)
        guard case let .transform(ref, _) = try node(p.other, p.second).kind else { return XCTFail("Move fixture") }
        p.other.session.editFeature(p.second, to: .transform(body: ref, delta: Transform3D(translation: SIMD3(50, 0, 0))))
        try await save(p.other)
        let report = try await review(p)
        XCTAssertTrue(report.conflictIDs.isEmpty); XCTAssertTrue(report.unsupportedIDs.isEmpty)
        _ = try await p.current.mergeCopy(planID: report.id)
        let bodyID = try XCTUnwrap(try node(p.current, p.first).outputBodyIDs.first)
        let body = try XCTUnwrap(p.current.session.document.body(with: bodyID))
        let bounds = try XCTUnwrap(MeasureKit.boundingBox(bodies: [body]))
        XCTAssertEqual(bounds.min.x, 50, accuracy: 0.01)
        XCTAssertEqual(MeasureKit.volume(of: body), 2_000, accuracy: 0.01)
        XCTAssertTrue(p.current.session.lastEvalErrors.isEmpty)
    }

    func testSameFeatureDifferentValuesRequireExplicitChoice() async throws {
        let p = try await pair()
        try edit(p.current, p.first, 20); try await save(p.current)
        try edit(p.other, p.first, 30); try await save(p.other)
        let before = try exactFiles(p.current.url)
        let report = try await review(p), key = "feature:\(p.first.raw.uuidString)"
        XCTAssertTrue(report.conflictIDs.contains(key))
        await failure(code: "merge_unresolved_conflicts") { _ = try await p.current.mergeCopy(planID: report.id) }
        XCTAssertEqual(try exactFiles(p.current.url), before)
        XCTAssertEqual(try distance(p.current, p.first), 20)
        _ = try await p.current.mergeCopy(planID: report.id, resolutions: [key: "incoming"])
        XCTAssertEqual(try distance(p.current, p.first), 30)
    }

    func testDeletionVersusEditIsReportedAndNeverSilentlyWins() async throws {
        let p = try await pair()
        try edit(p.current, p.first, 20); try await save(p.current)
        p.other.session.deleteFeature(p.first); try await save(p.other)
        let before = try exactFiles(p.current.url), report = try await review(p)
        XCTAssertTrue(report.conflictIDs.contains("feature:\(p.first.raw.uuidString)"))
        await failure { _ = try await p.current.mergeCopy(planID: report.id) }
        XCTAssertEqual(try exactFiles(p.current.url), before)
    }

    func testCancelLeavesBothCopiesAndUndoUnchangedAndFencesApply() async throws {
        let p = try await pair()
        try edit(p.other, p.second, 30); try await save(p.other)
        let before = try exactFiles(p.current.url), other = try exactFiles(p.other.url)
        let depth = p.current.session.undoStack.undoCommands.count
        let report = try await review(p)
        p.current.cancelCopyMerge(planID: report.id)
        await failure(code: "merge_expired") { _ = try await p.current.mergeCopy(planID: report.id) }
        XCTAssertEqual(p.current.session.undoStack.undoCommands.count, depth)
        XCTAssertEqual(try exactFiles(p.current.url), before); XCTAssertEqual(try exactFiles(p.other.url), other)
    }

    func testStaleSourceAndStaleTargetCannotApply() async throws {
        let p = try await pair()
        try edit(p.other, p.second, 30); try await save(p.other)
        let report = try await review(p), before = try exactFiles(p.current.url)
        try edit(p.other, p.second, 40); try await save(p.other)
        await failure(code: "merge_stale") { _ = try await p.current.mergeCopy(planID: report.id) }
        XCTAssertEqual(try exactFiles(p.current.url), before)
        let next = try await review(p)
        try edit(p.current, p.first, 20)
        await failure(code: "merge_stale") { _ = try await p.current.mergeCopy(planID: next.id) }
        XCTAssertEqual(try distance(p.current, p.first), 20, "Do not discard the newer local edit")
    }

    func testSameCheckpointUUIDWithDifferentVerifiedContentIsNotACommonBase() async throws {
        let p = try await pair()
        try edit(p.other, p.first, 99); try await save(p.other)
        let replacement = try await p.other.createNamedVersion(name: "Different verified content")
        let originalURL = p.other.url.appendingPathComponent("versions/\(p.base.uuidString)")
        let replacementURL = p.other.url.appendingPathComponent("versions/\(replacement.version.id.uuidString)")
        try FileManager.default.removeItem(at: originalURL)
        try FileManager.default.copyItem(at: replacementURL, to: originalURL)
        let recordURL = originalURL.appendingPathComponent("version.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        object["id"] = p.base.uuidString
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: recordURL)
        let before = try exactFiles(p.current.url)
        await failure(code: "merge_base_mismatch") { _ = try await self.review(p) }
        XCTAssertEqual(try exactFiles(p.current.url), before)
    }

    func testDamagedBaseRefusesWithoutRecoveryOrWrite() async throws {
        let p = try await pair()
        let base = p.other.url.appendingPathComponent("versions/\(p.base.uuidString)/document.json")
        try Data("broken checkpoint".utf8).write(to: base)
        let before = try exactFiles(p.current.url), other = try exactFiles(p.other.url)
        await failure(code: "merge_base_unreadable") { _ = try await self.review(p) }
        XCTAssertEqual(try exactFiles(p.current.url), before); XCTAssertEqual(try exactFiles(p.other.url), other)
    }

    func testRealRebuildFailurePreservesTargetBytesUndoAndRedo() async throws {
        let p = try await pair()
        let old = try node(p.other, p.second)
        p.other.session.perform(EditFeatureCommand(featureID: p.second, before: old.kind,
            after: try editedDistance(p.other, p.second, 0)))
        try await save(p.other)
        let before = try exactFiles(p.current.url), depth = p.current.session.undoStack.undoCommands.count
        let redo = p.current.session.undoStack.redoCommands.count
        let report = try await review(p)
        XCTAssertTrue(report.unsupportedIDs.isEmpty,"\(report.rows)")
        await failure(code: "merge_rebuild_failed") { _ = try await p.current.mergeCopy(planID: report.id) }
        XCTAssertEqual(try exactFiles(p.current.url), before)
        XCTAssertEqual(p.current.session.undoStack.undoCommands.count, depth)
        XCTAssertEqual(p.current.session.undoStack.redoCommands.count, redo)
        XCTAssertEqual(try distance(p.current, p.second), 10)
    }

    func testFeatureRenameAfterReopenKeepsBothExactBodyArchivesAndMergesOnlyTheFeature() async throws {
        let p = try await pair()
        let store = FileCADDocumentStore(packageURL: p.other.url)
        let before = try store.verifiedPackage(at: p.other.url)
        let old = try node(p.other, p.second)
        p.other.session.perform(RenameFeatureCommand(featureID: p.second,
            before: old.name, after: "Renamed without changing geometry"))
        try await save(p.other)
        let after = try store.verifiedPackage(at: p.other.url)
        XCTAssertEqual(Set(before.document.bodies.map(\.bodyID)), Set(after.document.bodies.map(\.bodyID)))
        for body in before.document.bodies {
            let actual = try XCTUnwrap(after.document.bodies.first { $0.bodyID == body.bodyID })
            XCTAssertNotNil(body.brepSHA256)
            XCTAssertEqual(actual.brepSHA256, body.brepSHA256)
            XCTAssertEqual(actual.meshSHA256, body.meshSHA256)
        }
        let report = try await review(p)
        XCTAssertEqual(report.rows.map(\.id), ["feature:\(p.second.raw.uuidString)"], "\(report.rows)")
        XCTAssertTrue(report.unsupportedIDs.isEmpty)
        let result = try await p.current.mergeCopy(planID: report.id)
        XCTAssertTrue(result.applied)
        XCTAssertEqual(try node(p.current, p.second).name, "Renamed without changing geometry")
        XCTAssertEqual(try distance(p.current, p.second), 10)
    }

    func testSaveFailureRollsBackOnlyOwnedMerge() async throws {
        let p = try await pair()
        try edit(p.other, p.second, 30); try await save(p.other)
        let report = try await review(p), before = try exactFiles(p.current.url)
        let depth = p.current.session.undoStack.undoCommands.count
        CADDocumentFaultInjection.beforeCommit = { throw NSError(domain: "E35ActualCommitFailure", code: 1) }
        await failure(code: "merge_save_failed") { _ = try await p.current.mergeCopy(planID: report.id) }
        CADDocumentFaultInjection.beforeCommit = nil
        XCTAssertEqual(try exactFiles(p.current.url), before)
        XCTAssertEqual(try distance(p.current, p.second), 10)
        XCTAssertEqual(p.current.session.undoStack.undoCommands.count, depth)
    }

    func testIncomingMaterialChangeIsListedAndRefusedRatherThanDropped() async throws {
        let p = try await pair()
        try edit(p.other, p.second, 30)
        let bodyID = try XCTUnwrap(try node(p.other, p.first).outputBodyIDs.first)
        p.other.session.perform(SetMaterialCommand(bodyIDs: [bodyID], material: BodyMaterialSpec(
            baseColor: SIMD4(0.8, 0.2, 0.1, 1), metallic: 0.5, roughness: 0.3),
            document: p.other.session.document))
        try await save(p.other)
        let report = try await review(p), before = try exactFiles(p.current.url)
        XCTAssertTrue(report.unsupportedIDs.contains("section:appearance"))
        await failure(code: "merge_unsupported") { _ = try await p.current.mergeCopy(planID: report.id) }
        XCTAssertEqual(try exactFiles(p.current.url), before)
    }

    func testClosedOwnerCannotApplyAFormerReview() async throws {
        let p = try await pair()
        try edit(p.other, p.second, 30); try await save(p.other)
        let report = try await review(p), before = try exactFiles(p.current.url)
        p.current.close()
        await failure { _ = try await p.current.mergeCopy(planID: report.id) }
        XCTAssertEqual(try exactFiles(p.current.url), before)
    }

    func testIncomingUVAndTextureChangeCannotBeDiscarded() async throws {
        let p = try await pair()
        try edit(p.other, p.second, 30)
        let id = try XCTUnwrap(try node(p.other, p.first).outputBodyIDs.first)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aFXcAAAAASUVORK5CYII="))
        let material = BodyMaterialSpec(baseColorTexture: png,
            uvMapping: CADMaterialUVMapping(source: .boxProjection, axis: .y,
                scaleMM: SIMD2(25, 10), rotationDegrees: 30))
        p.other.session.perform(SetMaterialCommand(bodyIDs: [id], material: material, document: p.other.session.document))
        try await save(p.other)
        let report = try await review(p), before = try exactFiles(p.current.url), other = try exactFiles(p.other.url)
        XCTAssertTrue(report.unsupportedIDs.contains("section:appearance"))
        await failure(code: "merge_unsupported") { _ = try await p.current.mergeCopy(planID: report.id) }
        XCTAssertEqual(try exactFiles(p.current.url), before); XCTAssertEqual(try exactFiles(p.other.url), other)
    }

    func testNestedSourcePackageRefusesBeforeAnyReadOrSave() async throws {
        let p = try await pair()
        p.other.close()
        let nested = p.current.url.appendingPathComponent("other.floecad")
        try FileManager.default.moveItem(at: p.other.url, to: nested)
        let before = try exactFiles(p.current.url)
        await failure(code: "merge_source") {
            _ = try await p.current.compareCopy(at: nested, baseVersionID: p.base)
        }
        XCTAssertEqual(try exactFiles(p.current.url), before)
    }
}
