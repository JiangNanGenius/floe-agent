import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

final class AssistantGuardTests: XCTestCase {
    private func makeFixture() -> (CanvasSnapshot, CanvasPageSnapshot, CanvasNodeSnapshot) {
        let node = CanvasNodeSnapshot(
            content: .text("original"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "G", pages: [page])
        return (snapshot, page, node)
    }

    // MARK: Classic batch guard

    func testWholeDocumentEscalationRejected() throws {
        let (_, page, node) = makeFixture()
        let batch = CanvasEditBatch(
            pageID: page.id, scope: .wholeDocument,
            operations: [.move(nodeID: node.id, center: .init(x: 9, y: 9))])
        let request = CanvasHostEditContext(
            canvasID: UUID(), pageID: page.id, revision: 0,
            selectedNodeIDs: [node.id])
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedBatch(
            batch, request: request)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .scopeEscalation else {
                XCTFail("expected scopeEscalation, got \(error)")
                return
            }
        }
    }

    func testLockChangesDefaultRejectedUnlessExplicitlyAllowed() throws {
        let (_, page, node) = makeFixture()
        let unlock = CanvasEditBatch(
            pageID: page.id,
            scope: .selectedNodes([node.id]),
            operations: [.setLocked(nodeID: node.id, isLocked: false)])
        let request = CanvasHostEditContext(
            canvasID: UUID(), pageID: page.id, revision: 0,
            selectedNodeIDs: [node.id])
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedBatch(
            unlock, request: request)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .lockNotGranted else {
                XCTFail("expected lockNotGranted, got \(error)")
                return
            }
        }
        var allowed = request
        allowed.allowsLockChanges = true
        XCTAssertNoThrow(try CanvasAssistantEditGuard.validatedBatch(
            unlock, request: allowed))
    }

    func testAuthorizedCreationExtendsScopeOnlyWithNewIDs() throws {
        let (_, page, node) = makeFixture()
        let branch = CanvasNodeSnapshot(
            content: .text("branch"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 50, y: 0), size: .init(width: 10, height: 10)))
        let batch = CanvasEditBatch(
            pageID: page.id,
            scope: .selectedNodes([node.id]),
            operations: [.insertNode(branch)])
        var request = CanvasHostEditContext(
            canvasID: UUID(), pageID: page.id, revision: 0,
            selectedNodeIDs: [node.id])
        // Without creation intent: rejected.
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedBatch(
            batch, request: request)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .creationNotGranted else {
                XCTFail("expected creationNotGranted, got \(error)")
                return
            }
        }
        // With creation intent: the new ID joins the effective scope and the
        // engine accepts the insert.
        request.allowsCreation = true
        let validated = try CanvasAssistantEditGuard.validatedBatch(
            batch, request: request)
        let result = try CanvasEditEngine.apply(validated, to: {
            var snapshot = CanvasSnapshot(
                name: "G", pages: [CanvasPageSnapshot(id: page.id, nodes: [node])])
            snapshot.pages[0].id = page.id
            return snapshot
        }())
        XCTAssertEqual(result.snapshot.pages[0].nodes.count, 2)
    }

    func testOrganizationalGestureCannotBypassSelection() throws {
        let (_, page, node) = makeFixture()
        let region = CanvasRegionRecord(
            name: "R",
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 100, height: 100)))
        var snapshot = CanvasSnapshot(
            name: "G", pages: [CanvasPageSnapshot(id: page.id, nodes: [node])])
        snapshot.pages[0].regions = [region]
        let batch = CanvasEditBatch(
            pageID: page.id,
            scope: .selectedNodes([node.id]),
            operations: [.setRegionCollapsed(regionID: region.id, isCollapsed: true)])
        let request = CanvasHostEditContext(
            canvasID: snapshot.id, pageID: page.id, revision: 0,
            selectedNodeIDs: [node.id])
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedBatch(
            batch, request: request)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .scopeEscalation else {
                XCTFail("expected scopeEscalation, got \(error)")
                return
            }
        }
        var granted = request
        granted.grantsWholeDocument = true
        XCTAssertNoThrow(try CanvasAssistantEditGuard.validatedBatch(
            batch, request: granted))
    }

    // MARK: Document proposals

    private func flowDraftProposal(
        pageID: UUID, graph: FlowGraph, card: CanvasNodeSnapshot
    ) -> CanvasAssistantProposal {
        .documentBatch(CanvasDocumentBatch(operations: [
            .insertFlowGraph(pageID: pageID, graph: graph),
            .editPage(CanvasEditBatch(
                pageID: pageID,
                operations: [.insertNode(card)])),
        ]))
    }

    func testSelectionToFlowDraftProposalAcceptedAgainstSnapshot() async throws {
        let (snapshot, page, node) = makeFixture()
        let flowNode = FlowNode(kind: .source, name: "in")
        let graph = FlowGraph(nodes: [flowNode])
        var card = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("draft from selection"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 40, y: 0), size: .init(width: 10, height: 10)))
        CanvasFlowCardBinding(graphID: graph.id, nodeID: flowNode.id)
            .applied(to: &card.metadata)

        let request = CanvasHostEditContext(
            canvasID: snapshot.id, pageID: page.id, revision: 0,
            selectedNodeIDs: [node.id], allowsCreation: true,
            allowsStructuralChanges: true)
        let validated = try CanvasAssistantEditGuard.validatedProposal(
            flowDraftProposal(pageID: page.id, graph: graph, card: card),
            request: request, against: snapshot)
        guard case .documentBatch(let batch) = validated else {
            XCTFail("expected document batch")
            return
        }
        // The committed batch is ONE undo unit and preserves the original.
        let repo = InMemoryCanvasRepository(snapshot: snapshot)
        _ = try await repo.commitDocument(
            batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())
        let loaded = try await repo.load(canvasID: snapshot.id)
        XCTAssertEqual(loaded.pages[0].nodes.count, 2)
        XCTAssertEqual(loaded.pages[0].flowGraphs.count, 1)
    }

    func testCrossPageInsertGraphRejected() throws {
        let (snapshot, page, node) = makeFixture()
        let otherPage = CanvasPageSnapshot(name: "Other")
        var full = snapshot
        full.pages.append(otherPage)
        let graph = FlowGraph(nodes: [FlowNode(kind: .source, name: "in")])
        let request = CanvasHostEditContext(
            canvasID: full.id, pageID: page.id, revision: 0,
            selectedNodeIDs: [node.id], allowsCreation: true,
            allowsStructuralChanges: true)
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedProposal(
            .documentBatch(CanvasDocumentBatch(operations: [
                .insertFlowGraph(pageID: otherPage.id, graph: graph)
            ])),
            request: request, against: full)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .pageMissing else {
                XCTFail("expected pageMissing, got \(error)")
                return
            }
        }
    }

    func testConnectionBetweenTwoUnselectedOriginalsRejected() throws {
        let (snapshot, page, node) = makeFixture()
        let other = CanvasNodeSnapshot(
            content: .text("other"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 30, y: 0), size: .init(width: 10, height: 10)))
        var full = snapshot
        full.pages[0].nodes.append(other)
        let sneaky = CanvasConnectionSnapshot(
            sourceNodeID: node.id, destinationNodeID: other.id)
        let request = CanvasHostEditContext(
            canvasID: full.id, pageID: page.id, revision: 0,
            selectedNodeIDs: [], allowsCreation: true,
            allowsStructuralChanges: true)
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedProposal(
            .documentBatch(CanvasDocumentBatch(operations: [
                .editPage(CanvasEditBatch(
                    pageID: page.id,
                    operations: [.insertConnection(sneaky)]))
            ])),
            request: request, against: full)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .scopeEscalation else {
                XCTFail("expected scopeEscalation, got \(error)")
                return
            }
        }
    }

    func testSelectedFlowInPlaceEditAcceptedAndCommitsAsOneUndo() async throws {
        let (snapshot, page, node) = makeFixture()
        let flowNode = FlowNode(
            kind: .source, name: "in", parameters: ["temperature": .number("1")])
        let graph = FlowGraph(id: UUID(), revision: 0, nodes: [flowNode])
        var card = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("selected card"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        CanvasFlowCardBinding(graphID: graph.id, nodeID: flowNode.id)
            .applied(to: &card.metadata)
        var full = snapshot
        full.pages[0].nodes = [card]
        full.pages[0].flowGraphs = [graph]

        let edited = FlowGraph(
            id: graph.id, revision: 1,
            nodes: [FlowNode(
                id: flowNode.id, kind: .source, name: "in",
                parameters: ["temperature": .number("2")])])
        let request = CanvasHostEditContext(
            canvasID: full.id, pageID: page.id, revision: 0,
            selectedNodeIDs: [card.id], allowsSelectedFlowEdits: true)
        let validated = try CanvasAssistantEditGuard.validatedProposal(
            .documentBatch(CanvasDocumentBatch(operations: [
                .replaceFlowGraph(graph: edited)
            ])),
            request: request, against: full)
        guard case .documentBatch(let batch) = validated else {
            XCTFail("expected document batch")
            return
        }
        let repo = InMemoryCanvasRepository(snapshot: full)
        _ = try await repo.commitDocument(
            batch, canvasID: full.id,
            expectedRevision: 0, requestID: UUID())
        var loaded = try await repo.load(canvasID: full.id)
        XCTAssertEqual(
            loaded.pages[0].flowGraphs[0].nodes[0].parameters["temperature"],
            .number("2"))
        // Single undo restores the original definition.
        _ = try await repo.undo(canvasID: full.id)
        loaded = try await repo.load(canvasID: full.id)
        XCTAssertEqual(
            loaded.pages[0].flowGraphs[0].nodes[0].parameters["temperature"],
            .number("1"))
    }

    func testOutOfScopeGraphDiffRejected() throws {
        let (snapshot, page, node) = makeFixture()
        let boundFlowNode = FlowNode(kind: .source, name: "bound")
        let unboundFlowNode = FlowNode(kind: .transform, name: "unbound")
        let graph = FlowGraph(
            id: UUID(), revision: 0,
            nodes: [boundFlowNode, unboundFlowNode])
        var card = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("card"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        CanvasFlowCardBinding(graphID: graph.id, nodeID: boundFlowNode.id)
            .applied(to: &card.metadata)
        var full = snapshot
        full.pages[0].nodes = [node, card]
        full.pages[0].flowGraphs = [graph]

        // Editing the UNBOUND flow node is rejected even with selected card.
        let edited = FlowGraph(
            id: graph.id, revision: 1,
            nodes: [
                boundFlowNode,
                FlowNode(
                    id: unboundFlowNode.id, kind: .transform, name: "renamed"),
            ])
        let request = CanvasHostEditContext(
            canvasID: full.id, pageID: page.id, revision: 0,
            selectedNodeIDs: [card.id], allowsSelectedFlowEdits: true)
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedProposal(
            .documentBatch(CanvasDocumentBatch(operations: [
                .replaceFlowGraph(graph: edited)
            ])),
            request: request, against: full)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.contains(where: {
                      $0.reason == .invalidReference
                  }) else {
                XCTFail("expected invalidReference, got \(error)")
                return
            }
        }
    }

    func testStaleRevisionRejectedAgainstSnapshot() throws {
        let (snapshot, page, node) = makeFixture()
        let graph = FlowGraph(nodes: [FlowNode(kind: .source, name: "in")])
        let request = CanvasHostEditContext(
            canvasID: snapshot.id, pageID: page.id, revision: 7,
            selectedNodeIDs: [node.id], allowsStructuralChanges: true)
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedProposal(
            .documentBatch(CanvasDocumentBatch(operations: [
                .insertFlowGraph(pageID: page.id, graph: graph)
            ])),
            request: request, against: snapshot)) { error in
            guard case CanvasKitError.revisionConflict(let expected, let current) = error else {
                XCTFail("expected revisionConflict, got \(error)")
                return
            }
            XCTAssertEqual(expected, 7)
            XCTAssertEqual(current, 0)
        }
    }

    func testClassicSnapshotProposalChecksCanvasRevisionAndPage() throws {
        let (snapshot, page, node) = makeFixture()
        let proposal = CanvasAssistantProposal.canvasBatch(CanvasEditBatch(
            pageID: page.id, scope: .selectedNodes([node.id]),
            operations: [.move(nodeID: node.id, center: .init(x: 1, y: 1))]))
        var request = CanvasHostEditContext(canvasID: snapshot.id, pageID: page.id,
            revision: snapshot.revision, selectedNodeIDs: [node.id])
        XCTAssertNoThrow(try CanvasAssistantEditGuard.validatedProposal(proposal, request: request, against: snapshot))
        request.revision += 1
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedProposal(proposal, request: request, against: snapshot))
        request.revision = snapshot.revision
        request.canvasID = UUID()
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedProposal(proposal, request: request, against: snapshot))
        request.canvasID = snapshot.id
        request.pageID = UUID()
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedProposal(proposal, request: request, against: snapshot))
    }

    func testSelectedFlowEditIntentDoesNotGrantCreation() throws {
        let (snapshot, page, node) = makeFixture()
        let request = CanvasHostEditContext(canvasID: snapshot.id, pageID: page.id,
            revision: snapshot.revision, selectedNodeIDs: [node.id], allowsSelectedFlowEdits: true)
        let graph = FlowGraph(nodes: [FlowNode(kind: .source, name: "new")])
        XCTAssertThrowsError(try CanvasAssistantEditGuard.validatedProposal(
            .documentBatch(CanvasDocumentBatch(operations: [.insertFlowGraph(pageID: page.id, graph: graph)])),
            request: request, against: snapshot))
    }

}
