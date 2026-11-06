#if canImport(UIKit)
import XCTest
@testable import FloeCanvasUI
import FloeCanvasCore
import FloeCanvasIntegration

/// Flow step ⇄ canvas card invariants (UI_BRIEF ICH01/ICH06/ICH07):
/// one-batch atomicity, typed-port validation, no unbound fallback after
/// delete, copy remaps binding and never carries active runs.
final class CanvasFlowCardEditingTests: XCTestCase {
    private func pageWithGraph() -> CanvasPageSnapshot {
        CanvasPageSnapshot(name: "P", flowGraphs: [FlowGraph(revision: 0)])
    }

    func testInsertStepCreatesGraphNodeAndBoundCardInOneBatch() throws {
        let page = pageWithGraph()
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let batch = try CanvasFlowGraphEditing.insertStepBatch(
            snapshot: snapshot,
            pageID: page.id,
            kind: .transform,
            name: "T",
            at: .init(x: 10, y: 20),
            cardSize: .init(width: 200, height: 100))
        XCTAssertEqual(batch.operations.count, 2)
        guard case .replaceFlowGraph(let graph) = batch.operations[0] else {
            return XCTFail("expected graph replace")
        }
        XCTAssertEqual(graph.revision, 1)
        XCTAssertEqual(graph.nodes.count, 1)
        guard case .editPage(let pageBatch) = batch.operations[1],
              case .insertNode(let card) = pageBatch.operations.first else {
            return XCTFail("expected card insert")
        }
        XCTAssertEqual(card.kind, .generationTask)
        let binding = CanvasFlowCardBinding(metadata: card.metadata)
        XCTAssertEqual(binding?.graphID, graph.id)
        XCTAssertEqual(binding?.nodeID, graph.nodes.first?.id)
        // End-to-end through the engine: one commit, resolvable binding.
        let result = try CanvasDocumentEditEngine.apply(batch, to: snapshot)
        let appliedPage = result.snapshot.pages[0]
        XCTAssertEqual(appliedPage.flowGraphs.first?.nodes.count, 1)
        XCTAssertEqual(appliedPage.nodes.count, 1)
    }

    func testInsertFirstStepCreatesGraph() throws {
        let page = CanvasPageSnapshot(name: "P")
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let batch = try CanvasFlowGraphEditing.insertStepBatch(
            snapshot: snapshot,
            pageID: page.id,
            kind: .condition,
            name: "C",
            at: .zero,
            cardSize: .init(width: 200, height: 100))
        guard case .insertFlowGraph(_, let graph) = batch.operations[0] else {
            return XCTFail("expected graph insert")
        }
        XCTAssertEqual(graph.nodes.first?.kind, .condition)
        XCTAssertEqual(graph.nodes.first?.branches?.count, 1)
        let engineResult = try CanvasDocumentEditEngine.apply(batch, to: snapshot)
        XCTAssertNotNil(engineResult.snapshot.pages[0].flowGraphs.first)
    }

    func testConnectPortsValidatesDirectionAndType() throws {
        let outPort = FlowPort(
            name: "out", dataType: .string, direction: .output)
        let inString = FlowPort(
            name: "in", dataType: .string, direction: .input)
        let inNumber = FlowPort(
            name: "in", dataType: .number, direction: .input)
        XCTAssertEqual(
            CanvasFlowPortValidator.validate(source: outPort, destination: inString),
            .valid)
        XCTAssertEqual(
            CanvasFlowPortValidator.validate(source: outPort, destination: inNumber),
            .typeMismatch(.string, .number))
        XCTAssertEqual(
            CanvasFlowPortValidator.validate(source: inString, destination: outPort),
            .directionMismatch)
        // .json wildcard is accepted.
        let jsonIn = FlowPort(
            name: "in", dataType: .json, direction: .input)
        XCTAssertEqual(
            CanvasFlowPortValidator.validate(source: outPort, destination: jsonIn),
            .valid)
    }

    func testVariadicOutputRequiresACollectionDestination() {
        let many = FlowPort(name: "many", dataType: .number, direction: .output, isVariadic: true)
        let scalar = FlowPort(name: "one", dataType: .number, direction: .input)
        let list = FlowPort(name: "list", dataType: .list, direction: .input)
        let items = FlowPort(name: "items", dataType: .number, direction: .input, isVariadic: true)
        XCTAssertEqual(CanvasFlowPortValidator.validate(source: many, destination: scalar),
            .typeMismatch(.number, .number))
        XCTAssertEqual(CanvasFlowPortValidator.validate(source: many, destination: list), .valid)
        XCTAssertEqual(CanvasFlowPortValidator.validate(source: many, destination: items), .valid)
    }

    func testDefinitionEditPreservesCardsAndCreatesAndRemovesBindingsAtomically() throws {
        let page = CanvasPageSnapshot(name: "Definition")
        let blank = CanvasSnapshot(name: "Definition", pages: [page])
        let initial = try CanvasFlowGraphEditing.insertStepBatch(snapshot: blank,
            pageID: page.id, kind: .source, name: "Original", at: .zero,
            cardSize: .init(width: 240, height: 140))
        let base = try CanvasDocumentEditEngine.apply(initial, to: blank).snapshot
        let originalCard = try XCTUnwrap(base.pages[0].nodes.first)
        var definition = try XCTUnwrap(base.pages[0].flowGraphs.first)
        definition.nodes[0].name = "Renamed"
        let added = FlowNode(kind: .transform, name: "Added",
            parameters: ["nativeKey": .string("offline.echo")])
        definition.nodes.append(added)
        definition.revision = 999 // the builder owns the next revision
        let batch = try CanvasFlowGraphEditing.replaceDefinitionBatch(
            snapshot: base, pageID: page.id, definition: definition)
        let edited = try CanvasDocumentEditEngine.apply(batch, to: base).snapshot
        XCTAssertEqual(edited.pages[0].flowGraphs[0].revision, 1)
        XCTAssertEqual(edited.pages[0].nodes.first { $0.id == originalCard.id }?.frame, originalCard.frame)
        XCTAssertEqual(edited.pages[0].nodes.first { $0.id == originalCard.id }?.title, "Renamed")
        XCTAssertEqual(edited.pages[0].nodes.first { $0.id == originalCard.id }?.content,
            .shape(kind: .roundedRectangle, text: "Renamed"))
        XCTAssertTrue(edited.pages[0].nodes.contains {
            CanvasFlowCardBinding(metadata: $0.metadata)?.nodeID == added.id
        })
        definition = edited.pages[0].flowGraphs[0]
        definition.nodes.removeFirst()
        let remove = try CanvasFlowGraphEditing.replaceDefinitionBatch(
            snapshot: edited, pageID: page.id, definition: definition)
        let final = try CanvasDocumentEditEngine.apply(remove, to: edited).snapshot
        XCTAssertFalse(final.pages[0].nodes.contains { $0.id == originalCard.id })
        XCTAssertEqual(final.pages[0].nodes.count, 1)
        XCTAssertEqual(final.pages[0].flowGraphs[0].nodes, [added])
    }

    func testDefinitionEditingCannotBypassLockedFlowCards() throws {
        let step = FlowNode(kind: .source, name: "Source")
        var graph = FlowGraph(nodes: [step])
        var metadata: [String: String] = [:]
        CanvasFlowCardBinding(graphID: graph.id, nodeID: step.id).applied(to: &metadata)
        let card = CanvasNodeSnapshot(kind: .generationTask, title: "Source",
            content: .text("Source"),
            frame: .init(center: .zero, size: .init(width: 240, height: 140)),
            isLocked: true, metadata: metadata)
        let page = CanvasPageSnapshot(nodes: [card], flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "Locked", pages: [page])
        graph.nodes[0].name = "Changed"
        XCTAssertThrowsError(try CanvasFlowGraphEditing.replaceDefinitionBatch(
            snapshot: snapshot, pageID: page.id, definition: graph))
        XCTAssertEqual(snapshot.pages[0].nodes[0].title, "Source")
    }

    func testDefinitionParameterEditPreservesManualCardTitle() throws {
        let page = CanvasPageSnapshot()
        let blank = CanvasSnapshot(name: "Manual title", pages: [page])
        let initial = try CanvasFlowGraphEditing.insertStepBatch(snapshot: blank, pageID: page.id,
            kind: .source, name: "Source", at: .zero, cardSize: .init(width: 240, height: 140))
        var base = try CanvasDocumentEditEngine.apply(initial, to: blank).snapshot
        base.pages[0].nodes[0].title = "My research note"
        var graph = base.pages[0].flowGraphs[0]
        graph.nodes[0].parameters["literal"] = .number("42")
        let batch = try CanvasFlowGraphEditing.replaceDefinitionBatch(
            snapshot: base, pageID: page.id, definition: graph)
        let saved = try CanvasDocumentEditEngine.apply(batch, to: base).snapshot
        XCTAssertEqual(saved.pages[0].nodes[0].title, "My research note")
    }

    @MainActor
    func testFrozenDefinitionEditCannotOverwriteANewerRevision() async throws {
        let graph = FlowGraph(nodes: [FlowNode(kind: .source, name: "Original")])
        let page = CanvasPageSnapshot(flowGraphs: [graph])
        let base = CanvasSnapshot(name: "CAS", pages: [page])
        let repository = InMemoryCanvasRepository(snapshot: base)
        let store = CanvasEditorStore(canvasID: base.id,
            services: CanvasEditorServices(documentStore: repository))
        await store.load()
        var definition = graph
        definition.nodes[0].name = "Draft"
        let batch = try CanvasFlowGraphEditing.replaceDefinitionBatch(
            snapshot: base, pageID: page.id, definition: definition)
        _ = try await repository.commitDocument(.init(scope: .wholeDocument,
            operations: [.renamePage(pageID: page.id, name: "Remote")]), canvasID: base.id,
            expectedRevision: base.revision, requestID: UUID())
        await store.load()
        await store.commit(batch, undoLabel: "Definition", expectedRevision: base.revision)
        XCTAssertEqual(store.drafts.count, 1)
        let saved = try await repository.load(canvasID: base.id)
        XCTAssertEqual(saved.pages[0].name, "Remote")
        XCTAssertEqual(saved.pages[0].flowGraphs[0], graph)
    }

    func testDeleteFlowCardRemovesNodeEdgesAndCardInOneBatch() throws {
        let graphID = UUID()
        let source = FlowNode(
            kind: .source,
            name: "S",
            ports: [FlowPort(name: "out", dataType: .json, direction: .output)])
        let transform = FlowNode(
            kind: .transform,
            name: "T",
            ports: [
                FlowPort(name: "in", dataType: .json, direction: .input),
                FlowPort(name: "out", dataType: .json, direction: .output),
            ])
        let edge = FlowEdge(
            sourceNodeID: source.id,
            sourcePortID: source.ports[0].id,
            destinationNodeID: transform.id,
            destinationPortID: transform.ports[0].id)
        var metadata: [String: String] = [:]
        CanvasFlowCardBinding(graphID: graphID, nodeID: transform.id)
            .applied(to: &metadata)
        let card = CanvasNodeSnapshot(
            kind: .generationTask,
            title: "T",
            content: .shape(kind: .roundedRectangle, text: "T"),
            frame: .init(center: .zero, size: .init(width: 200, height: 100)),
            metadata: metadata)
        let page = CanvasPageSnapshot(
            name: "P",
            nodes: [card],
            flowGraphs: [FlowGraph(
                id: graphID, revision: 3, nodes: [source, transform], edges: [edge])])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let batch = try CanvasFlowGraphEditing.deleteFlowCardBatch(
            snapshot: snapshot, pageID: page.id, cardNodeID: card.id)
        let result = try CanvasDocumentEditEngine.apply(batch, to: snapshot)
        let applied = result.snapshot.pages[0]
        XCTAssertTrue(applied.nodes.isEmpty, "card must be removed")
        XCTAssertEqual(applied.flowGraphs.first?.nodes.count, 1)
        XCTAssertTrue(applied.flowGraphs.first?.edges.isEmpty ?? false)
        // The deleted flow node must not reappear as an unbound fallback:
        // the graph keeps exactly the surviving node and the card is gone.
        XCTAssertNil(applied.flowGraphs.first?.nodes.first(where: { $0.id == transform.id }))
    }

    func testUpdateNodePrunesEdgesToRemovedPorts() throws {
        let inPort = FlowPort(name: "in", dataType: .json, direction: .input)
        let outPort = FlowPort(name: "out", dataType: .json, direction: .output)
        let nodeA = FlowNode(kind: .transform, name: "A", ports: [outPort])
        let nodeB = FlowNode(
            kind: .transform,
            name: "B",
            ports: [inPort, FlowPort(name: "out", dataType: .json, direction: .output)])
        let edge = FlowEdge(
            sourceNodeID: nodeA.id,
            sourcePortID: outPort.id,
            destinationNodeID: nodeB.id,
            destinationPortID: inPort.id)
        let page = CanvasPageSnapshot(
            name: "P",
            flowGraphs: [FlowGraph(
                revision: 0, nodes: [nodeA, nodeB], edges: [edge])])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        // Node B drops its input port.
        let editedB = FlowNode(
            id: nodeB.id,
            kind: .transform,
            name: "B",
            ports: [FlowPort(name: "out", dataType: .json, direction: .output)])
        let batch = try CanvasFlowGraphEditing.updateNodeBatch(
            snapshot: snapshot, pageID: page.id, node: editedB)
        let result = try CanvasDocumentEditEngine.apply(batch, to: snapshot)
        let applied = result.snapshot.pages[0].flowGraphs[0]
        XCTAssertTrue(applied.edges.isEmpty, "dangling edge must be pruned")
    }

    func testDuplicateCardRemapsBindingAndClearsRunOwnership() throws {
        let graphID = UUID()
        let flowNode = FlowNode(
            kind: .transform,
            name: "T",
            ports: [
                FlowPort(name: "in", dataType: .json, direction: .input),
                FlowPort(name: "out", dataType: .json, direction: .output),
            ],
            position: .init(x: 0, y: 0))
        var metadata: [String: String] = [:]
        CanvasFlowCardBinding(graphID: graphID, nodeID: flowNode.id)
            .applied(to: &metadata)
        var card = CanvasNodeSnapshot(
            kind: .generationTask,
            title: "T",
            content: .shape(kind: .roundedRectangle, text: "T"),
            frame: .init(
                center: .init(x: 100, y: 100),
                size: .init(width: 200, height: 100)),
            metadata: metadata)
        card.createdByRunID = UUID()   // active run must never be copied
        let page = CanvasPageSnapshot(
            name: "P",
            nodes: [card],
            flowGraphs: [FlowGraph(
                id: graphID, revision: 0, nodes: [flowNode], edges: [])])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let plan = try CanvasSelectionDuplicator.plan(
            snapshot: snapshot, pageID: page.id, nodeIDs: [card.id])
        XCTAssertEqual(plan.newNodeIDs.count, 1)
        XCTAssertEqual(plan.flowIDMapping.count, 1)
        let result = try CanvasDocumentEditEngine.apply(plan.batch, to: snapshot)
        let applied = result.snapshot.pages[0]
        XCTAssertEqual(applied.nodes.count, 2)
        XCTAssertEqual(applied.flowGraphs.first?.nodes.count, 2)
        let copy = try XCTUnwrap(applied.nodes.first(where: { $0.id != card.id }))
        XCTAssertNil(copy.createdByRunID)
        let copyBinding = CanvasFlowCardBinding(metadata: copy.metadata)
        XCTAssertEqual(copyBinding?.graphID, graphID)
        XCTAssertNotEqual(copyBinding?.nodeID, flowNode.id)
        XCTAssertTrue(applied.flowGraphs.first?.nodes.contains(
            where: { $0.id == copyBinding?.nodeID }) ?? false)
        // Engine validation guarantees no duplicate (graph,node) binding.
    }
}

#endif // canImport(UIKit)
