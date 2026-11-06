#if canImport(UIKit)
import XCTest
@testable import FloeCanvasUI
import FloeCanvasCore
import FloeCanvasIntegration

/// Store lifecycle: load, one-gesture-one-commit, repository-owned undo,
/// draft recovery on persistence failure, page switching, scenes, search.
@MainActor
final class CanvasEditorStoreTests: XCTestCase {
    func testSavingStateCoversPendingCommitAndClearsAfterSuccessOrFailure() async throws {
        for failing in [false, true] {
            let snapshot = CanvasTestStubs.snapshot()
            let base = InMemoryCanvasRepository(snapshot: snapshot)
            let held = CanvasTestStubs.HeldCommitStore(base: base)
            let store = CanvasEditorStore(canvasID: snapshot.id,
                services: CanvasEditorServices(documentStore: held))
            await store.load()
            let editing = Task { await store.apply(.insertContent(.text("pending"), title: nil, at: .zero)) }
            await held.waitUntilHeld()
            XCTAssertTrue(store.isMutating)
            XCTAssertEqual(store.revision, 0, "pending writes are not acknowledged")
            await held.release(failing: failing)
            await editing.value
            XCTAssertFalse(store.isMutating)
            XCTAssertEqual(store.revision, failing ? 0 : 1)
            XCTAssertEqual(store.drafts.count, failing ? 1 : 0)
            let history = try await base.historyAvailability(canvasID: snapshot.id)
            XCTAssertEqual(history.undoCount, failing ? 0 : 1)
        }
    }

    func testLoadPublishesSnapshotAndIndex() async {
        let snapshot = CanvasTestStubs.snapshot(nodes: [CanvasTestStubs.textNode("hello")])
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        await store.load()
        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.revision, 0)
        XCTAssertEqual(store.page.nodes.count, 1)
        XCTAssertEqual(store.layoutIndex.nodes.count, 1)
    }

    func testApplyCommandCommitsExactlyOnceAndUndoRestores() async {
        let snapshot = CanvasTestStubs.snapshot()
        let repository = InMemoryCanvasRepository(snapshot: snapshot)
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(documentStore: repository))
        await store.load()
        await store.apply(.insertContent(
            .text("one"), title: nil,
            at: .init(x: 0, y: 0)))
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(store.page.nodes.count, 1)
        await store.undo()
        XCTAssertEqual(store.page.nodes.count, 0)
        await store.redo()
        XCTAssertEqual(store.page.nodes.count, 1)
    }

    func testFailedCommitBecomesRecoverableDraft() async {
        let snapshot = CanvasTestStubs.snapshot()
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let failing = CanvasTestStubs.FailingCommitStore(base: base, failNextCommit: true)
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(documentStore: failing))
        await store.load()
        await store.apply(.insertContent(
            .text("draft"), title: nil, at: .zero))
        XCTAssertEqual(store.revision, 0, "failed commit must not advance revision")
        XCTAssertEqual(store.drafts.count, 1)
        XCTAssertEqual(store.drafts.first?.pageID, store.selectedPageID)
        // Retry replays the same request identity and succeeds once the
        // transient failure clears — exactly one committed node.
        let draft = try? XCTUnwrap(store.drafts.first)
        if let draft {
            await store.retryDraft(draft)
            XCTAssertEqual(store.page.nodes.count, 1)
            XCTAssertTrue(store.drafts.isEmpty)
        }
    }

    /// Lost acknowledgement: the repository committed, then the transport
    /// threw. Retry with the SAME request ID must return the original
    /// receipt — one revision, one undo unit, no duplicate content.
    func testLostAcknowledgementRetryIsIdempotent() async throws {
        let snapshot = CanvasTestStubs.snapshot()
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let lostAck = CanvasTestStubs.LostAckStore(base: base)
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(documentStore: lostAck))
        await store.load()
        await store.apply(.insertContent(
            .text("hello"), title: nil, at: .zero))
        XCTAssertEqual(store.drafts.count, 1, "gesture surfaced as recoverable draft")
        XCTAssertEqual(store.revision, 0, "store could not observe the commit")

        let draft = try XCTUnwrap(store.drafts.first)
        await store.retryDraft(draft)

        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(store.revision, 1, "replay returned the original receipt")
        XCTAssertEqual(store.page.nodes.count, 1, "no duplicate insert")
        let history = try await base.historyAvailability(canvasID: snapshot.id)
        XCTAssertEqual(history.undoCount, 1, "exactly one undo unit for the gesture")
    }

    /// Real CAS conflict: another writer committed in between. Both sides
    /// stay recoverable; the explicit rebase path commits the draft as a
    /// NEW request against the current revision.
    func testRealConflictKeepsBothSidesRecoverableAndRebasesExplicitly() async throws {
        let snapshot = CanvasTestStubs.snapshot()
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(documentStore: base))
        await store.load()

        // Simulate a concurrent writer advancing the revision underneath.
        let concurrent = CanvasDocumentBatch(
            scope: .wholeDocument,
            operations: [.editPage(.init(
                pageID: store.selectedPageID,
                scope: .wholeDocument,
                operations: [.insertNode(CanvasTestStubs.textNode("concurrent"))]))])
        _ = try await base.commitDocument(
            concurrent, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())

        // The store's next gesture is built against its stale revision.
        await store.apply(.insertContent(
            .text("mine"), title: nil, at: .init(x: 500, y: 0)))
        XCTAssertEqual(store.drafts.count, 1)
        let draft = try XCTUnwrap(store.drafts.first)
        XCTAssertTrue(draft.didConflict, "real CAS conflict is marked on the draft")
        XCTAssertEqual(store.page.nodes.count, 1, "current content reloaded")

        await store.rebaseDraft(draft)
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(store.revision, 2)
        XCTAssertEqual(store.page.nodes.count, 2, "both contents survive")
        XCTAssertTrue(store.page.nodes.contains(where: {
            if case .text(let value) = $0.content { return value == "concurrent" }
            return false
        }))
        XCTAssertTrue(store.page.nodes.contains(where: {
            if case .text(let value) = $0.content { return value == "mine" }
            return false
        }))
    }

    func testSelectPageKeepsSelectionOnPageAndRestoresViewport() async {
        let pageA = CanvasPageSnapshot(name: "A")
        let pageB = CanvasPageSnapshot(name: "B")
        let snapshot = CanvasSnapshot(name: "multi", pages: [pageA, pageB])
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        await store.load()
        await store.selectPage(pageB.id)
        XCTAssertEqual(store.selectedPageID, pageB.id)
        XCTAssertEqual(store.snapshot.selectedPageID, pageB.id)
        XCTAssertEqual(store.page.id, pageB.id)
        await store.apply(.insertContent(
            .text("on B"), title: nil, at: .zero))
        XCTAssertEqual(store.snapshot.selectedPageID, pageB.id,
            "the export snapshot follows the active view after a save reload")
        store.selectAll()
        XCTAssertEqual(store.selection.count, 1)
        let revisionBeforeNavigation = store.revision
        await store.selectPage(pageA.id)
        XCTAssertEqual(store.revision, revisionBeforeNavigation, "navigation does not consume a document revision")
        XCTAssertTrue(store.selection.isEmpty, "selection must not leak across pages")
        XCTAssertEqual(store.page.id, pageA.id)
        XCTAssertTrue(store.page.nodes.isEmpty, "B's content must stay on B")
        await store.undo()
        XCTAssertEqual(store.selectedPageID, pageA.id, "undo preserves the current view")
        await store.selectPage(pageB.id)
        XCTAssertTrue(store.page.nodes.isEmpty, "the single undo removes the edit on B, not navigation")
        XCTAssertFalse(store.canUndo)
        XCTAssertTrue(store.canRedo)
    }

    func testFrozenEditorRevisionConflictsEvenAfterStoreReloads() async throws {
        let node = CanvasTestStubs.textNode("original")
        let snapshot = CanvasTestStubs.snapshot(nodes: [node])
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let store = CanvasEditorStore(canvasID: snapshot.id,
            services: .init(documentStore: base))
        await store.load()
        let pageID = store.selectedPageID
        let draftBatch = try CanvasCommandBatchBuilder.makeBatch(.updateContent(node.id, .text("draft")),
            in: store.snapshot, pageID: pageID, selection: [node.id], configuration: store.configuration)
        _ = try await base.commit(.init(pageID: pageID, scope: .wholeDocument,
            operations: [.updateTitle(nodeID: node.id, title: "remote")]),
            canvasID: snapshot.id, expectedRevision: 0, requestID: UUID())
        await store.load()
        XCTAssertEqual(store.revision, 1)
        await store.commit(draftBatch, undoLabel: "Frozen editor", expectedRevision: 0)
        XCTAssertEqual(store.drafts.count, 1)
        XCTAssertEqual(store.drafts.first?.baseRevision, 0)
        XCTAssertEqual(store.page.nodes.first?.content, .text("original"))
        XCTAssertEqual(store.page.nodes.first?.title, "remote")
        await store.rebaseDraft(try XCTUnwrap(store.drafts.first))
        XCTAssertEqual(store.page.nodes.first?.content, .text("draft"))
        XCTAssertEqual(store.page.nodes.first?.title, "remote")
    }

    func testJumpToSceneSelectsFocusedNodesWithoutDuplicating() async throws {
        let node = CanvasTestStubs.textNode("n", center: .init(x: 100, y: 100))
        let page = CanvasPageSnapshot(
            name: "P",
            nodes: [node],
            scenes: [CanvasSceneRecord(
                name: "Overview",
                viewportCenter: .init(x: 100, y: 100),
                viewportScale: 1,
                focusedNodeIDs: [node.id],
                order: 0)])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        await store.load()
        let scene = try XCTUnwrap(store.page.scenes.first)
        store.jumpToScene(scene.id)
        XCTAssertEqual(store.selection, [node.id])
        XCTAssertEqual(store.page.nodes.count, 1, "scene must not duplicate nodes")
    }

    func testSearchFindsTitleThenContent() async {
        let titled = CanvasTestStubs.textNode("body", title: "Alpha")
        let body = CanvasTestStubs.textNode("beta body")
        let snapshot = CanvasTestStubs.snapshot(nodes: [titled, body])
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        await store.load()
        store.updateSearchQuery("alpha")
        XCTAssertEqual(store.searchResults.first?.node.id, titled.id)
        store.updateSearchQuery("beta")
        XCTAssertEqual(store.searchResults.first?.node.id, body.id)
        store.updateSearchQuery("")
        XCTAssertTrue(store.searchResults.isEmpty)
    }

    func testSavePencilDrawingIsWholeDocumentGesture() async {
        let page = CanvasPageSnapshot(name: "P")
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        await store.load()
        await store.savePencilDrawing(Data([0x01, 0x02]))
        XCTAssertEqual(store.revision, 1)
        let reloaded = try? await InMemoryCanvasRepository(
            snapshot: store.snapshot).load(canvasID: snapshot.id)
        XCTAssertEqual(reloaded?.pages.first?.pencilDrawingData?.count, 2)
        await store.undo()
        XCTAssertNil(store.page.pencilDrawingData)
    }
}

#endif // canImport(UIKit)
