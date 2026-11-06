import XCTest
@testable import FloeCanvasCore

final class FlowBindingTests: XCTestCase {
    func testPersistedLoopBoundDoesNotReplaceExecutionPolicy() throws {
        let body = FlowNode(kind: .transform, name: "body")
        let loop = FlowNode(kind: .loop, name: "loop",
            parameters: ["maxIterations": .number("250")], bodyNodeIDs: [body.id])
        let graph = FlowGraph(nodes: [loop, body])
        let page = CanvasPageSnapshot()
        let snapshot = CanvasSnapshot(name: "Explicit bound", pages: [page])
        let result = try CanvasDocumentEditEngine.apply(.init(scope: .wholeDocument,
            operations: [.insertFlowGraph(pageID: page.id, graph: graph)]), to: snapshot)
        XCTAssertEqual(result.snapshot.pages[0].flowGraphs[0], graph)
        XCTAssertTrue(FlowGraphValidator.validate(graph).contains { $0.code == .invalidLoop })
        XCTAssertFalse(FlowGraphValidator.validate(graph, maxLoopIterations: 250)
            .contains { $0.severity == .error })
    }

    func testJSONProjectionCanBeSavedAsTypedFlow() throws {
        let out = FlowPort(name: "out", dataType: .json, direction: .output)
        let input = FlowPort(name: "in", dataType: .number, direction: .input)
        let source = FlowNode(kind: .source, name: "source", ports: [out])
        let sink = FlowNode(kind: .output, name: "sink", ports: [input])
        let graph = FlowGraph(nodes: [source, sink], edges: [.init(
            sourceNodeID: source.id, sourcePortID: out.id,
            destinationNodeID: sink.id, destinationPortID: input.id)])
        let page = CanvasPageSnapshot()
        let snapshot = CanvasSnapshot(name: "JSON projection", pages: [page])
        let result = try CanvasDocumentEditEngine.apply(.init(scope: .wholeDocument,
            operations: [.insertFlowGraph(pageID: page.id, graph: graph)]), to: snapshot)
        XCTAssertEqual(result.snapshot.pages[0].flowGraphs.first, graph)
    }

    private func makeGraph(
        id: UUID = UUID(), revision: Int64 = 0
    ) -> FlowGraph {
        FlowGraph(id: id, revision: revision)
    }

    // MARK: Page binding + backward compatibility

    func testP0SnapshotsDecodeWithEmptyFlowGraphsAndPencilNil() throws {
        // A page WITHOUT the new fields must decode exactly like P0.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "P0 Page",
          "nodes": [],
          "connections": [],
          "strokes": [],
          "groups": [],
          "regions": [],
          "scenes": [],
          "background": "grid"
        }
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(CanvasPageSnapshot.self, from: json)
        XCTAssertTrue(page.flowGraphs.isEmpty)
        XCTAssertNil(page.pencilDrawingData)

        let roundTrip = try JSONDecoder().decode(
            CanvasPageSnapshot.self,
            from: JSONEncoder().encode(page))
        XCTAssertEqual(roundTrip, page)
    }

    func testFlowGraphInsertReplaceRemoveWithRevisionRules() throws {
        let node = CanvasNodeSnapshot(
            content: .text("source card"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "F", pages: [page])

        let graph = makeGraph()
        var result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .insertFlowGraph(pageID: page.id, graph: graph)
            ]), to: snapshot)
        XCTAssertEqual(result.snapshot.pages[0].flowGraphs, [graph])

        // Replace requires a strictly greater revision.
        let stale = makeGraph(id: graph.id, revision: 0)
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .replaceFlowGraph(graph: stale)
            ]), to: result.snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .staleFlowGraphRevision else {
                XCTFail("expected staleFlowGraphRevision, got \(error)")
                return
            }
        }

        let newer = makeGraph(id: graph.id, revision: 1)
        result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .replaceFlowGraph(graph: newer)
            ]), to: result.snapshot)
        XCTAssertEqual(result.snapshot.pages[0].flowGraphs, [newer])

        result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .removeFlowGraph(graphID: graph.id)
            ]), to: result.snapshot)
        XCTAssertTrue(result.snapshot.pages[0].flowGraphs.isEmpty)
    }

    func testInvalidFlowGraphRejectedOnInsert() {
        let page = CanvasPageSnapshot()
        let snapshot = CanvasSnapshot(name: "F", pages: [page])
        let a = FlowNode(kind: .source, name: "a")
        let b = FlowNode(kind: .output, name: "b")
        let danglingEdge = FlowEdge(
            sourceNodeID: a.id, sourcePortID: UUID(),
            destinationNodeID: b.id, destinationPortID: UUID())
        let badGraph = FlowGraph(nodes: [a, b], edges: [danglingEdge])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .insertFlowGraph(pageID: page.id, graph: badGraph)
            ]), to: snapshot)) { error in
            guard case CanvasKitError.invalidFlowGraph = error else {
                XCTFail("expected invalidFlowGraph, got \(error)")
                return
            }
        }
    }

    // MARK: Source bindings

    func testFlowSourceBindingParametersRoundTrip() {
        let binding = CanvasFlowSourceBinding(
            canvasID: UUID(), pageID: UUID(), nodeID: UUID(),
            usedRevision: 42)
        let parsed = CanvasFlowSourceBinding(parameters: binding.parameters())
        XCTAssertEqual(parsed, binding)
    }

    func testFlowSourceLocatorValidationAgainstCanvas() throws {
        let node = CanvasNodeSnapshot(
            content: .text("card"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "F", pages: [page])

        let sourceNode = FlowNode(
            kind: .source, name: "in",
            parameters: [
                CanvasFlowSourceParameterKey.canvasID:
                    .string(snapshot.id.uuidString),
                CanvasFlowSourceParameterKey.pageID:
                    .string(page.id.uuidString),
                CanvasFlowSourceParameterKey.nodeID:
                    .string(UUID().uuidString), // missing node
            ])
        let graph = FlowGraph(nodes: [sourceNode])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .insertFlowGraph(pageID: page.id, graph: graph)
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.contains(where: { $0.reason == .invalidReference }) else {
                XCTFail("expected invalidReference, got \(error)")
                return
            }
        }
    }

    // MARK: Card bindings

    func testCardAndGraphInsertedInOneBatchValidateAgainstFinalState() throws {
        let flowNode = FlowNode(kind: .source, name: "in")
        let graph = FlowGraph(nodes: [flowNode])
        let page = CanvasPageSnapshot()
        let snapshot = CanvasSnapshot(name: "F", pages: [page])
        var card = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("flow card"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        CanvasFlowCardBinding(graphID: graph.id, nodeID: flowNode.id)
            .applied(to: &card.metadata)

        let result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .insertFlowGraph(pageID: page.id, graph: graph),
                .editPage(CanvasEditBatch(
                    pageID: page.id,
                    operations: [.insertNode(card)])),
            ]), to: snapshot)
        XCTAssertEqual(result.snapshot.pages[0].flowGraphs.count, 1)
        XCTAssertEqual(result.snapshot.pages[0].nodes.count, 1)
        XCTAssertEqual(
            CanvasFlowCardBinding(
                metadata: result.snapshot.pages[0].nodes[0].metadata)?
                .graphID,
            graph.id)
    }

    func testDanglingCardBindingRejectsCommitRecoverably() throws {
        let page = CanvasPageSnapshot()
        let snapshot = CanvasSnapshot(name: "F", pages: [page])
        var card = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("orphan card"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        CanvasFlowCardBinding(graphID: UUID(), nodeID: UUID())
            .applied(to: &card.metadata)
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .editPage(CanvasEditBatch(
                    pageID: page.id,
                    operations: [.insertNode(card)]))
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.contains(where: { $0.reason == .invalidReference }) else {
                XCTFail("expected invalidReference, got \(error)")
                return
            }
        }
        // Legacy generationTask without binding metadata stays unaffected.
        let plainCard = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("legacy"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        let ok = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .editPage(CanvasEditBatch(
                    pageID: page.id,
                    operations: [.insertNode(plainCard)]))
            ]), to: snapshot)
        XCTAssertEqual(ok.snapshot.pages[0].nodes.count, 1)
    }

    func testDuplicateCardBindingPairRejected() throws {
        let flowNode = FlowNode(kind: .source, name: "in")
        let graph = FlowGraph(nodes: [flowNode])
        let page = CanvasPageSnapshot()
        let snapshot = CanvasSnapshot(name: "F", pages: [page])
        func card() -> CanvasNodeSnapshot {
            var c = CanvasNodeSnapshot(
                kind: .generationTask,
                content: .text("card"),
                frame: CanvasGeometry.Frame(
                    center: .zero, size: .init(width: 10, height: 10)))
            CanvasFlowCardBinding(graphID: graph.id, nodeID: flowNode.id)
                .applied(to: &c.metadata)
            return c
        }
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .insertFlowGraph(pageID: page.id, graph: graph),
                .editPage(CanvasEditBatch(
                    pageID: page.id,
                    operations: [.insertNode(card()), .insertNode(card())])),
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.contains(where: { $0.reason == .duplicateID }) else {
                XCTFail("expected duplicateID, got \(error)")
                return
            }
        }
    }

    func testReplaceGraphBoundToLockedCardRejected() throws {
        let flowNode = FlowNode(kind: .source, name: "in")
        let graph = FlowGraph(id: UUID(), revision: 0, nodes: [flowNode])
        var card = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("card"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)),
            isLocked: true)
        CanvasFlowCardBinding(graphID: graph.id, nodeID: flowNode.id)
            .applied(to: &card.metadata)
        let page = CanvasPageSnapshot(nodes: [card], flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "F", pages: [page])
        let newer = FlowGraph(
            id: graph.id, revision: 1,
            nodes: [FlowNode(id: flowNode.id, kind: .source, name: "renamed")])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .replaceFlowGraph(graph: newer)
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.contains(where: { $0.reason == .nodeLocked }) else {
                XCTFail("expected nodeLocked, got \(error)")
                return
            }
        }
    }

    // MARK: Identity copy

    func testCopyRemapsPageGraphsCardBindingsAndSourceLocators() throws {
        let canvasNode = CanvasNodeSnapshot(
            content: .text("card"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        let flowNode = FlowNode(
            kind: .source, name: "in",
            parameters: [
                CanvasFlowSourceParameterKey.canvasID: .string(""),
                CanvasFlowSourceParameterKey.pageID: .string(""),
                CanvasFlowSourceParameterKey.nodeID: .string(""),
            ])
        var graph = FlowGraph(nodes: [flowNode])
        var card = canvasNode
        CanvasFlowCardBinding(graphID: graph.id, nodeID: flowNode.id)
            .applied(to: &card.metadata)
        let page = CanvasPageSnapshot(nodes: [card], flowGraphs: [graph])
        var snapshot = CanvasSnapshot(name: "C", pages: [page])
        // Point the locator at the canvas itself.
        snapshot.pages[0].flowGraphs[0].nodes[0].parameters = CanvasFlowSourceBinding(
            canvasID: snapshot.id, pageID: page.id, nodeID: card.id,
            usedRevision: 3).parameters()

        let result = CanvasIdentityMapper.copy(snapshot)
        let copiedPage = result.snapshot.pages[0]
        let copiedGraph = copiedPage.flowGraphs[0]
        let copiedCard = copiedPage.nodes[0]

        XCTAssertNotEqual(copiedGraph.id, graph.id)
        XCTAssertNotEqual(copiedGraph.nodes[0].id, flowNode.id)
        let copiedBinding = CanvasFlowCardBinding(metadata: copiedCard.metadata)
        XCTAssertEqual(copiedBinding?.graphID, copiedGraph.id)
        XCTAssertEqual(copiedBinding?.nodeID, copiedGraph.nodes[0].id)
        let copiedLocator = CanvasFlowSourceBinding(
            parameters: copiedGraph.nodes[0].parameters)
        XCTAssertEqual(copiedLocator?.canvasID, result.snapshot.id)
        XCTAssertEqual(copiedLocator?.pageID, copiedPage.id)
        XCTAssertEqual(copiedLocator?.nodeID, copiedCard.id)
        XCTAssertNil(copiedCard.createdByRunID)
    }
}

final class FlowValidatorLoopOrderTests: XCTestCase {
    func testLoopNodeFirstBodyDeclaredAfterIsValid() {
        // Regression: bodyNodeIDs must validate against ALL node IDs, not
        // only the nodes visited so far in the validator loop.
        let body = FlowNode(kind: .transform, name: "body")
        let loop = FlowNode(
            kind: .loop, name: "loop",
            ports: [],
            parameters: ["maxIterations": .number("3")],
            bodyNodeIDs: [body.id])
        let graph = FlowGraph(nodes: [loop, body])
        XCTAssertEqual(
            FlowGraphValidator.validate(graph)
                .filter { $0.severity == .error },
            [])
    }
}
