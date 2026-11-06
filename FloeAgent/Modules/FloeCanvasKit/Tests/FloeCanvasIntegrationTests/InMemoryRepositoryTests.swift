import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

private final class FlakySink: CanvasPersistenceSink, @unchecked Sendable {
    enum Failure: Error { case write }
    private let lock = NSLock()
    private var remainingFailures: Int

    init(failures: Int) {
        self.remainingFailures = failures
    }

    private func attempt() throws {
        lock.lock()
        defer { lock.unlock() }
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw Failure.write
        }
    }

    func didCommit(snapshot: CanvasSnapshot, receipt: CanvasCommitReceipt, history: CanvasHistoryState) throws {
        try attempt()
    }
    func didApplyHistory(snapshot: CanvasSnapshot, receipt: CanvasCommitReceipt, history: CanvasHistoryState) throws {
        try attempt()
    }
}

private func makeRepository() -> (InMemoryCanvasRepository, CanvasSnapshot, CanvasEditBatch) {
    let node = CanvasNodeSnapshot(
        content: .text("v1"),
        frame: CanvasGeometry.Frame(center: .zero, size: .init(width: 10, height: 10)))
    let page = CanvasPageSnapshot(nodes: [node])
    let snapshot = CanvasSnapshot(name: "R", pages: [page])
    let batch = CanvasEditBatch(pageID: page.id, operations: [
        .updateContent(nodeID: node.id, content: .text("v2"))
    ])
    return (InMemoryCanvasRepository(snapshot: snapshot), snapshot, batch)
}

final class InMemoryRepositoryTests: XCTestCase {
    func testCommitBumpsRevisionAndConflictsOnStaleExpectation() async throws {
        let (repo, snapshot, batch) = makeRepository()
        let receipt = try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())
        XCTAssertEqual(receipt.revision, 1)

        // Stale window: another session committed; this commit must fail
        // recoverably and leave the store untouched.
        await XCTAssertThrowsErrorAsync({ try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())}) { error in
            guard case CanvasKitError.revisionConflict(let expected, let current) = error else {
                XCTFail("expected revisionConflict, got \(error)")
                return
            }
            XCTAssertEqual(expected, 0)
            XCTAssertEqual(current, 1)
        }
        let current = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(current.revision, 1)
        XCTAssertEqual(try XCTUnwrap(current.selectedPage?.nodes.first).textContent, "v2")
    }

    func testIdenticalReplayDoesNotMutateTwice() async throws {
        let (repo, snapshot, batch) = makeRepository()
        let requestID = UUID()
        let first = try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: requestID)
        let replay = try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: requestID)
        XCTAssertEqual(first, replay)
        let afterReplay = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(afterReplay.revision, 1)
    }

    func testSameRequestIDDifferentBytesRejects() async throws {
        let (repo, snapshot, batch) = makeRepository()
        let requestID = UUID()
        _ = try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: requestID)
        let other = CanvasEditBatch(
            pageID: batch.pageID,
            operations: [.setRegionCollapsed(regionID: UUID(), isCollapsed: true)]
        )
        await XCTAssertThrowsErrorAsync({ try await repo.commit(
            other, canvasID: snapshot.id,
            expectedRevision: 1, requestID: requestID)}) { error in
            guard case CanvasKitError.requestIDConflict(let id) = error else {
                XCTFail("expected requestIDConflict, got \(error)")
                return
            }
            XCTAssertEqual(id, requestID)
        }
    }

    func testUndoRedoStrictSemantics() async throws {
        let (repo, snapshot, batch) = makeRepository()
        _ = try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())

        // Stale expected revision on undo: rejected.
        await XCTAssertThrowsErrorAsync({ try await repo.undo(
            canvasID: snapshot.id, expectedRevision: 0, requestID: UUID())})

        let undoReceipt = try await repo.undo(
            canvasID: snapshot.id, expectedRevision: 1, requestID: UUID())
        XCTAssertEqual(undoReceipt.previousRevision, 1)
        XCTAssertEqual(undoReceipt.revision, 2)
        var current = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(try XCTUnwrap(current.selectedPage?.nodes.first).textContent, "v1")

        // Redo restores the commit; revision only increases.
        let redoReceipt = try await repo.redo(
            canvasID: snapshot.id, expectedRevision: 2, requestID: UUID())
        XCTAssertEqual(redoReceipt.revision, 3)
        current = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(try XCTUnwrap(current.selectedPage?.nodes.first).textContent, "v2")

        // History lists both steps, newest first.
        let history = try await repo.undoHistory(canvasID: snapshot.id)
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history[0].label.hasPrefix("redo:"))
        XCTAssertTrue(history[1].label.hasPrefix("undo:"))
    }

    func testRepeatedUndoRequestReturnsOriginalReceiptWithoutSecondUndo() async throws {
        let (repo, snapshot, batch) = makeRepository()
        _ = try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())
        let requestID = UUID()
        let first = try await repo.undo(
            canvasID: snapshot.id, expectedRevision: 1, requestID: requestID)
        let replay = try await repo.undo(
            canvasID: snapshot.id, expectedRevision: 1, requestID: requestID)
        XCTAssertEqual(first, replay)
        // Still the same content: replay did not undo the redo-less state.
        let current = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(try XCTUnwrap(current.selectedPage?.nodes.first).textContent, "v1")
        XCTAssertEqual(current.revision, 2)
    }

    func testSameRequestIDDifferentHistoryStepRejects() async throws {
        let (repo, snapshot, batch) = makeRepository()
        _ = try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())
        let requestID = UUID()
        _ = try await repo.undo(
            canvasID: snapshot.id, expectedRevision: 1, requestID: requestID)
        await XCTAssertThrowsErrorAsync({ try await repo.redo(
            canvasID: snapshot.id, expectedRevision: 2, requestID: requestID)}) { error in
            guard case CanvasKitError.requestIDConflict = error else {
                XCTFail("expected requestIDConflict, got \(error)")
                return
            }
        }
    }

    func testNewCommitClearsRedoBranch() async throws {
        let (repo, snapshot, batch) = makeRepository()
        _ = try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())
        _ = try await repo.undo(
            canvasID: snapshot.id, expectedRevision: 1, requestID: UUID())
        let newBatch = CanvasEditBatch(pageID: snapshot.selectedPageID, operations: [
            .updateContent(
                nodeID: snapshot.selectedPage!.nodes[0].id,
                content: .text("v3"))
        ])
        _ = try await repo.commit(
            newBatch, canvasID: snapshot.id,
            expectedRevision: 2, requestID: UUID())
        await XCTAssertThrowsErrorAsync({ try await repo.redo(
            canvasID: snapshot.id, expectedRevision: 3, requestID: UUID())}) { error in
            guard case CanvasKitError.missingEntity = error else {
                XCTFail("expected missingEntity (empty redo), got \(error)")
                return
            }
        }
    }

    func testRedoWithEmptyStackFails() async throws {
        let (repo, snapshot, _) = makeRepository()
        await XCTAssertThrowsErrorAsync({ try await repo.redo(
            canvasID: snapshot.id, expectedRevision: 0, requestID: UUID())})
    }

    func testPersistenceFailureRollsBackAndKeepsOriginalRecords() async throws {
        let node = CanvasNodeSnapshot(
            content: .text("v1"),
            frame: CanvasGeometry.Frame(center: .zero, size: .init(width: 1, height: 1)))
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "R", pages: [page])
        let repo = InMemoryCanvasRepository(snapshot: snapshot, sink: FlakySink(failures: 1))
        let batch = CanvasEditBatch(pageID: page.id, operations: [
            .updateContent(nodeID: node.id, content: .text("v2"))
        ])
        await XCTAssertThrowsErrorAsync({ try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())}) { error in
            guard case CanvasKitError.io = error else {
                XCTFail("expected io, got \(error)")
                return
            }
        }
        // Original records intact: same content, same revision, and the
        // request can be retried fresh.
        let current = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(current.revision, 0)
        XCTAssertEqual(try XCTUnwrap(current.selectedPage?.nodes.first).textContent, "v1")
        let retry = try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())
        XCTAssertEqual(retry.revision, 1)
    }

    func testConvenienceUndoUsesCurrentRevision() async throws {
        let (repo, snapshot, batch) = makeRepository()
        _ = try await repo.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())
        let receipt = try await repo.undo(canvasID: snapshot.id)
        XCTAssertEqual(receipt.revision, 2)
    }

    func testEquivalentSelectionScopeEncodesDeterministically() throws {
        // A Set's iteration order varies with insertion order and process;
        // the persisted digest must not.
        let ids = (0..<12).map { _ in UUID() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let shuffled = ids.shuffled()

        let first = CanvasEditBatch(
            pageID: UUID(),
            scope: .selectedNodes(Set(ids)),
            operations: [])
        let second = CanvasEditBatch(
            pageID: first.pageID,
            scope: .selectedNodes(Set(shuffled)),
            operations: [])
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
        XCTAssertEqual(
            try CanvasBatchDigest.hash(first),
            try CanvasBatchDigest.hash(second)
        )

        // Ordered arrays keep order: a different operation list must hash
        // differently.
        let node = CanvasNodeSnapshot(
            content: .text("x"),
            frame: CanvasGeometry.Frame(center: .zero, size: .init(width: 1, height: 1)))
        let third = CanvasEditBatch(
            pageID: first.pageID,
            scope: .selectedNodes(Set(ids)),
            operations: [.insertNode(node)])
        XCTAssertNotEqual(try CanvasBatchDigest.hash(first), try CanvasBatchDigest.hash(third))
    }

    func testReplayAcrossReopenWithEquivalentSelectionAccepted() async throws {
        // File-backed: same request ID + logically identical batch (same
        // selection, different in-memory construction) replays cleanly
        // after reopen instead of being mis-rejected.
        let node = CanvasNodeSnapshot(
            content: .text("scoped"),
            frame: CanvasGeometry.Frame(center: .zero, size: .init(width: 5, height: 5)))
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "Scope", pages: [page])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-scope-replay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try FileCanvasRepository(root: root)
        try await repository.create(
            canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())

        let ids = [node.id, UUID(), UUID()]
        let batch = CanvasEditBatch(
            pageID: page.id,
            scope: .selectedNodes(Set(ids)),
            operations: [.updateContent(nodeID: node.id, content: .text("updated"))])
        let requestID = UUID()
        let receipt = try await repository.commit(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: requestID)

        let reopened = try FileCanvasRepository(root: root)
        let rebuilt = CanvasEditBatch(
            pageID: page.id,
            scope: .selectedNodes(Set(ids.reversed())),
            operations: [.updateContent(nodeID: node.id, content: .text("updated"))])
        let replay = try await reopened.commit(
            rebuilt, canvasID: snapshot.id,
            expectedRevision: 0, requestID: requestID)
        XCTAssertEqual(replay, receipt)
        let final = try await reopened.load(canvasID: snapshot.id)
        XCTAssertEqual(final.revision, 1)
    }
}
