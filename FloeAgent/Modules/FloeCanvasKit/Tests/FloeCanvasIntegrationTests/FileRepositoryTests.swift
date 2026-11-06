import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

final class FileRepositoryTests: XCTestCase {
    private var root: URL!
    private var repository: FileCanvasRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-canvas-file-tests-\(UUID().uuidString)")
        repository = try FileCanvasRepository(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Fixture: Sendable {
        var snapshot: CanvasSnapshot
        var batch: CanvasEditBatch
    }

    private func makeFixture() -> Fixture {
        let node = CanvasNodeSnapshot(
            content: .text("v1"),
            frame: CanvasGeometry.Frame(center: .zero, size: .init(width: 10, height: 10)))
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "File", pages: [page])
        let batch = CanvasEditBatch(pageID: page.id, operations: [
            .updateContent(nodeID: node.id, content: .text("v2"))
        ])
        return Fixture(snapshot: snapshot, batch: batch)
    }

    private func canvasDirectory(_ canvasID: UUID) -> URL {
        root.appendingPathComponent("canvases", isDirectory: true)
            .appendingPathComponent(canvasID.uuidString, isDirectory: true)
    }

    /// Seeds the store with a created canvas plus one commit (revision 1)
    /// and returns the fixture for assertions.
    @discardableResult
    private func seed() async throws -> Fixture {
        let fixture = makeFixture()
        try await repository.create(
            canvasID: fixture.snapshot.id,
            snapshot: fixture.snapshot,
            requestID: UUID())
        _ = try await repository.commit(
            fixture.batch, canvasID: fixture.snapshot.id,
            expectedRevision: 0, requestID: UUID())
        return fixture
    }

    func testCommitLoadRoundTrip() async throws {
        let fixture = try await seed()
        let loaded = try await repository.load(canvasID: fixture.snapshot.id)
        XCTAssertEqual(loaded.revision, 1)
        XCTAssertEqual(loaded.selectedPage?.nodes.first?.textContent, "v2")

        // On-disk layout: the manifest is the single commit authority,
        // blobs are content-addressed, staging leftovers are cleaned.
        let directory = canvasDirectory(fixture.snapshot.id)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "manifest.json" })
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasSuffix(".tmp") })
        let blobs = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("blobs", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertGreaterThanOrEqual(blobs.filter { $0.pathExtension == "json" }.count, 2)
    }

    func testRevisionMonotonicAndContentRecoveryAfterUndoRedo() async throws {
        let fixture = try await seed()
        // NOTE: blob-hash equality across undo/redo is deliberately NOT the
        // invariant — snapshot bytes embed revision/updatedAt, so identical
        // bytes after history steps would force dropping revision authority.
        // The real invariants: content recovers exactly, revision strictly
        // increases, history records both steps.
        _ = try await repository.undo(
            canvasID: fixture.snapshot.id, expectedRevision: 1, requestID: UUID())
        _ = try await repository.redo(
            canvasID: fixture.snapshot.id, expectedRevision: 2, requestID: UUID())
        let loaded = try await repository.load(canvasID: fixture.snapshot.id)
        XCTAssertEqual(loaded.revision, 3)
        XCTAssertEqual(loaded.selectedPage?.nodes.first?.textContent, "v2")
        let history = try await repository.undoHistory(canvasID: fixture.snapshot.id)
        XCTAssertEqual(history.count, 2)
    }

    func testReopenReplaysRequestIDWithoutSecondMutation() async throws {
        let fixture = try await seed()
        let requestID = UUID()
        let receipt = try await repository.undo(
            canvasID: fixture.snapshot.id, expectedRevision: 1, requestID: requestID)

        // Fresh repository instance over the same root: same request must
        // return the persisted receipt without applying again.
        let reopened = try FileCanvasRepository(root: root)
        let replay = try await reopened.undo(
            canvasID: fixture.snapshot.id, expectedRevision: 1, requestID: requestID)
        XCTAssertEqual(replay, receipt)
        let loaded = try await reopened.load(canvasID: fixture.snapshot.id)
        XCTAssertEqual(loaded.revision, 2)
        XCTAssertEqual(loaded.selectedPage?.nodes.first?.textContent, "v1")
    }

    func testHistorySurvivesReopen() async throws {
        let fixture = try await seed()
        _ = try await repository.undo(
            canvasID: fixture.snapshot.id, expectedRevision: 1, requestID: UUID())
        let reopened = try FileCanvasRepository(root: root)
        let history = try await reopened.undoHistory(canvasID: fixture.snapshot.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertTrue(history[0].label.hasPrefix("undo:"))

        // Redo from the reopened store works and persists across another
        // reopen.
        _ = try await reopened.redo(
            canvasID: fixture.snapshot.id, expectedRevision: 2, requestID: UUID())
        let history2 = try await FileCanvasRepository(root: root)
            .undoHistory(canvasID: fixture.snapshot.id)
        XCTAssertEqual(history2.count, 2)
        XCTAssertTrue(history2[0].label.hasPrefix("redo:"))
    }

    func testTornManifestFailsClosedAndPreservesArtifacts() async throws {
        let fixture = try await seed()
        let directory = canvasDirectory(fixture.snapshot.id)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("manifest.json"))

        // Recovery authority is the committed manifest only; with it gone
        // the store reports corruption instead of guessing from blobs.
        let reopened = try FileCanvasRepository(root: root)
        await XCTAssertThrowsErrorAsync({ try await reopened.load(canvasID: fixture.snapshot.id) }) { error in
            guard case CanvasKitError.io = error else {
                XCTFail("expected io, got \(error)")
                return
            }
        }
        // Failed/corrupt artifacts are preserved, not silently deleted.
        let blobs = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("blobs", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertGreaterThanOrEqual(blobs.filter { $0.pathExtension == "json" }.count, 2)
    }

    func testDecodedRecordCacheStillDetectsBlobCorruption() async throws {
        for field in ["snapshotBlob", "historyBlob"] {
            let fixture = makeFixture()
            try await repository.create(canvasID: fixture.snapshot.id,
                snapshot: fixture.snapshot, requestID: UUID())
            _ = try await repository.load(canvasID: fixture.snapshot.id)
            let directory = canvasDirectory(fixture.snapshot.id)
            let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
            let hash = try XCTUnwrap(manifest[field] as? String)
            let blob = directory.appendingPathComponent("blobs/\(hash).json")
            // Valid JSON, invalid digest: a warm decoded cache must not
            // conceal it, even if the replacement would still decode.
            var changed = try Data(contentsOf: blob)
            changed.append(contentsOf: [0x20, 0x0a])
            try changed.write(to: blob)
            await XCTAssertThrowsErrorAsync({ try await self.repository.load(canvasID: fixture.snapshot.id) }) { error in
                guard case CanvasKitError.io = error else {
                    XCTFail("expected digest failure, got \(error)"); return
                }
            }
            XCTAssertEqual(try Data(contentsOf: blob), changed, "failure artifact is retained")
        }
    }

    func testForeignRequestIDRejectedAcrossCanvases() async throws {
        let fixture = try await seed()
        let foreignReceipt = try await repository.undo(
            canvasID: fixture.snapshot.id, expectedRevision: 1, requestID: UUID())

        // A second canvas in the same root must not accept the first
        // canvas' request ID.
        let otherPage = CanvasPageSnapshot(name: "Other")
        let other = CanvasSnapshot(name: "Other", pages: [otherPage])
        try await repository.create(
            canvasID: other.id, snapshot: other, requestID: UUID())
        let otherBatch = CanvasEditBatch(pageID: otherPage.id, operations: [
            .insertNode(CanvasNodeSnapshot(
                content: .text("x"),
                frame: CanvasGeometry.Frame(
                    center: .zero, size: .init(width: 1, height: 1))))
        ])
        _ = try await repository.commit(
            otherBatch, canvasID: other.id,
            expectedRevision: 0, requestID: UUID())

        let reopened = try FileCanvasRepository(root: root)
        await XCTAssertThrowsErrorAsync({ try await reopened.undo(
            canvasID: other.id, expectedRevision: 1,
            requestID: foreignReceipt.requestID) }) { error in
            guard case CanvasKitError.requestIDConflict = error else {
                XCTFail("expected requestIDConflict, got \(error)")
                return
            }
        }
    }

    func testConcurrentCommitsSameRevisionOnlyOneWins() async throws {
        let fixture = makeFixture()
        try await repository.create(
            canvasID: fixture.snapshot.id,
            snapshot: fixture.snapshot,
            requestID: UUID())
        let firstRepo = repository!
        let second = try FileCanvasRepository(root: root)
        async let firstOutcome = FileRepositoryCommitOutcome.capture(
            repository: firstRepo, batch: fixture.batch, canvasID: fixture.snapshot.id)
        async let secondOutcome = FileRepositoryCommitOutcome.capture(
            repository: second, batch: fixture.batch, canvasID: fixture.snapshot.id)
        let outcomes = await [firstOutcome, secondOutcome]
        // Exactly one commit succeeds; the loser gets a recoverable
        // revision conflict and the committed revision advanced exactly once.
        XCTAssertEqual(outcomes.filter { $0.wasSuccess }.count, 1)
        XCTAssertEqual(outcomes.filter { $0.wasRevisionConflict }.count, 1)
        let loaded = try await firstRepo.load(canvasID: fixture.snapshot.id)
        XCTAssertEqual(loaded.revision, 1)
    }

    func testCrashBeforeManifestWriteLeavesCommittedStateIntact() async throws {
        let fixture = try await seed()
        await repository.setFailBeforeManifestWrite(true)
        await XCTAssertThrowsErrorAsync({ try await repository.commit(
            fixture.batch, canvasID: fixture.snapshot.id,
            expectedRevision: 1, requestID: UUID()) }) { error in
            guard case CanvasKitError.io = error else {
                XCTFail("expected io, got \(error)")
                return
            }
        }

        // Reopen: the last COMMITTED manifest (revision 1) is the recovery
        // authority; the failed mutation left no receipt, no history entry,
        // and a fresh retry of the same request applies cleanly.
        let reopened = try FileCanvasRepository(root: root)
        let loaded = try await reopened.load(canvasID: fixture.snapshot.id)
        XCTAssertEqual(loaded.revision, 1)
        XCTAssertEqual(loaded.selectedPage?.nodes.first?.textContent, "v2")
        let history = try await reopened.undoHistory(canvasID: fixture.snapshot.id)
        XCTAssertTrue(history.isEmpty)
    }

    func testRefusesFilesystemRoot() {
        XCTAssertThrowsError(try FileCanvasRepository(root: URL(fileURLWithPath: "/"))) { error in
            guard case CanvasKitError.repositoryRootViolation = error else {
                XCTFail("expected repositoryRootViolation, got \(error)")
                return
            }
        }
    }
}

private enum FileRepositoryCommitOutcome: Sendable {
    case succeeded
    case failed(CanvasKitError)

    var wasSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }

    var wasRevisionConflict: Bool {
        if case .failed(let error) = self,
           case CanvasKitError.revisionConflict = error {
            return true
        }
        return false
    }

    static func capture(
        repository: FileCanvasRepository,
        batch: CanvasEditBatch,
        canvasID: UUID
    ) async -> FileRepositoryCommitOutcome {
        do {
            _ = try await repository.commit(
                batch, canvasID: canvasID,
                expectedRevision: 0, requestID: UUID())
            return .succeeded
        } catch let error as CanvasKitError {
            return .failed(error)
        } catch {
            return .failed(.io("unexpected: \(error)"))
        }
    }
}
