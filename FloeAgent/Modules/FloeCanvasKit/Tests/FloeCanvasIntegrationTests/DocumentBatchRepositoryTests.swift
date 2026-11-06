import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

final class DocumentBatchRepositoryTests: XCTestCase {
    private func makeSnapshot() -> (CanvasSnapshot, CanvasPageSnapshot) {
        let page = CanvasPageSnapshot(name: "Main")
        let snapshot = CanvasSnapshot(name: "R", pages: [page])
        return (snapshot, page)
    }

    func testInMemoryDocumentCommitUndoRedoAndReplay() async throws {
        let (snapshot, page) = makeSnapshot()
        let repo = InMemoryCanvasRepository(snapshot: snapshot)
        let newPage = CanvasPageSnapshot(name: "Extra")
        let batch = CanvasDocumentBatch(operations: [
            .createPage(newPage, select: true)
        ])
        let receipt = try await repo.commitDocument(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())
        XCTAssertEqual(receipt.revision, 1)
        let loaded = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(loaded.pages.count, 2)
        XCTAssertEqual(loaded.selectedPageID, newPage.id)

        // Identical replay: same receipt, no second mutation.
        let replay = try await repo.commitDocument(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: receipt.requestID)
        XCTAssertEqual(replay.revision, receipt.revision)
        let replayedRevision = try await repo.load(canvasID: snapshot.id).revision
        XCTAssertEqual(replayedRevision, 1)

        // Same request ID, different bytes: hard rejection.
        let otherBatch = CanvasDocumentBatch(operations: [
            .renamePage(pageID: page.id, name: "Other")
        ])
        await XCTAssertThrowsErrorAsync({
            try await repo.commitDocument(
                otherBatch, canvasID: snapshot.id,
                expectedRevision: 0, requestID: receipt.requestID)
        }) { error in
            guard case CanvasKitError.requestIDConflict = error else {
                XCTFail("expected requestIDConflict, got \(error)")
                return
            }
        }

        // One undo unit for the whole document batch.
        let undo = try await repo.undo(
            canvasID: snapshot.id, expectedRevision: 1, requestID: UUID())
        XCTAssertEqual(undo.revision, 2)
        let undone = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(undone.pages.count, 1)
        XCTAssertEqual(undone.selectedPageID, page.id)

        let redo = try await repo.redo(
            canvasID: snapshot.id, expectedRevision: 2, requestID: UUID())
        XCTAssertEqual(redo.revision, 3)
        let redonePages = try await repo.load(canvasID: snapshot.id).pages
        XCTAssertEqual(redonePages.count, 2)
    }

    func testMixedNodeAndFlowCreateDeleteInOneBatchOneUndo() async throws {
        let (snapshot, page) = makeSnapshot()
        let repo = InMemoryCanvasRepository(snapshot: snapshot)
        let flowNode = FlowNode(kind: .source, name: "in")
        let graph = FlowGraph(nodes: [flowNode])
        var card = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("card"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        CanvasFlowCardBinding(graphID: graph.id, nodeID: flowNode.id)
            .applied(to: &card.metadata)

        let create = CanvasDocumentBatch(operations: [
            .insertFlowGraph(pageID: page.id, graph: graph),
            .editPage(CanvasEditBatch(
                pageID: page.id,
                operations: [.insertNode(card)])),
        ])
        let createReceipt = try await repo.commitDocument(
            create, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())
        XCTAssertEqual(createReceipt.revision, 1)
        var loaded = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(loaded.pages[0].flowGraphs.count, 1)
        XCTAssertEqual(loaded.pages[0].nodes.count, 1)

        // Delete card + graph in ONE batch, ONE undo unit.
        let delete = CanvasDocumentBatch(operations: [
            .removeFlowGraph(graphID: graph.id),
            .editPage(CanvasEditBatch(
                pageID: page.id,
                operations: [.removeNode(nodeID: card.id)])),
        ])
        _ = try await repo.commitDocument(
            delete, canvasID: snapshot.id,
            expectedRevision: 1, requestID: UUID())
        loaded = try await repo.load(canvasID: snapshot.id)
        XCTAssertTrue(loaded.pages[0].flowGraphs.isEmpty)
        XCTAssertTrue(loaded.pages[0].nodes.isEmpty)

        // Single undo restores BOTH the card and the graph.
        _ = try await repo.undo(canvasID: snapshot.id)
        loaded = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(loaded.pages[0].flowGraphs.count, 1)
        XCTAssertEqual(loaded.pages[0].nodes.count, 1)
    }

    func testEndOfBatchFailureRollsBackEverything() async throws {
        let (snapshot, page) = makeSnapshot()
        let repo = InMemoryCanvasRepository(snapshot: snapshot)
        let badBatch = CanvasDocumentBatch(operations: [
            .renamePage(pageID: page.id, name: "ShouldNotLand"),
            .deletePage(pageID: page.id),           // last page → violation
        ])
        await XCTAssertThrowsErrorAsync({
            try await repo.commitDocument(
                badBatch, canvasID: snapshot.id,
                expectedRevision: 0, requestID: UUID())
        }) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.contains(where: { $0.reason == .lastPageRemaining }) else {
                XCTFail("expected lastPageRemaining, got \(error)")
                return
            }
        }
        // Revision unchanged and nothing landed.
        let loaded = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(loaded.revision, 0)
        XCTAssertEqual(loaded.pages.count, 1)
    }

    func testFileRepositoryDocumentPersistenceAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-canvas-doc-\(UUID().uuidString)")
        let (snapshot, page) = makeSnapshot()
        let requestID = UUID()
        do {
            let repo = try FileCanvasRepository(root: root)
            try await repo.create(
                canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())
            let graph = FlowGraph(nodes: [FlowNode(kind: .source, name: "in")])
            let receipt = try await repo.commitDocument(
                CanvasDocumentBatch(operations: [
                    .insertFlowGraph(pageID: page.id, graph: graph),
                    .renamePage(pageID: page.id, name: "Renamed"),
                ]),
                canvasID: snapshot.id,
                expectedRevision: 0, requestID: requestID)
            XCTAssertEqual(receipt.revision, 1)

            // Reopen: replay returns the original receipt without mutation.
            let reopened = try FileCanvasRepository(root: root)
            let replay = try await reopened.commitDocument(
                CanvasDocumentBatch(operations: [
                    .insertFlowGraph(pageID: page.id, graph: graph),
                    .renamePage(pageID: page.id, name: "Renamed"),
                ]),
                canvasID: snapshot.id,
                expectedRevision: 0, requestID: requestID)
            XCTAssertEqual(replay.revision, receipt.revision)
            let loaded = try await reopened.load(canvasID: snapshot.id)
            XCTAssertEqual(loaded.revision, 1)
            XCTAssertEqual(loaded.pages[0].name, "Renamed")
            XCTAssertEqual(loaded.pages[0].flowGraphs, [graph])

            // Undo after reopen.
            _ = try await reopened.undo(canvasID: snapshot.id)
            let undone = try await reopened.load(canvasID: snapshot.id)
            XCTAssertEqual(undone.pages[0].name, page.name)
            XCTAssertTrue(undone.pages[0].flowGraphs.isEmpty)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testRequestIDDomainSharedBetweenBatchKinds() async throws {
        // A request ID consumed by a classic commit is rejected for a
        // document batch and vice versa: ONE idempotency domain per store.
        let (snapshot, page) = makeSnapshot()
        let repo = InMemoryCanvasRepository(snapshot: snapshot)
        let node = CanvasNodeSnapshot(
            content: .text("x"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 5, height: 5)))
        let classic = CanvasEditBatch(
            pageID: page.id, operations: [.insertNode(node)])
        let receipt = try await repo.commit(
            classic, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())
        await XCTAssertThrowsErrorAsync({
            try await repo.commitDocument(
                CanvasDocumentBatch(operations: [
                    .renamePage(pageID: page.id, name: "X")
                ]),
                canvasID: snapshot.id,
                expectedRevision: 1, requestID: receipt.requestID)
        }) { error in
            guard case CanvasKitError.requestIDConflict = error else {
                XCTFail("expected requestIDConflict, got \(error)")
                return
            }
        }
    }
}
