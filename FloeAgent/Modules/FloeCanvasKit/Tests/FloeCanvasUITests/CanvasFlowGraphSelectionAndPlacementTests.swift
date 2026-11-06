#if canImport(UIKit)
import XCTest
@testable import FloeCanvasUI
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasFlow

/// P1c same-page multi-graph ownership + run→page output placement
/// regression tests (real runtime, real commits; source-only evidence).
@MainActor
final class CanvasFlowGraphSelectionAndPlacementTests: XCTestCase {
    private actor GraphRecorder {
        var ids: [UUID] = []
        func append(_ id: UUID) { ids.append(id) }
    }

    // MARK: Fixtures

    private func boundCard(
        graphID: UUID,
        nodeID: UUID,
        title: String,
        center: CanvasGeometry.Point
    ) -> CanvasNodeSnapshot {
        var metadata: [String: String] = [:]
        CanvasFlowCardBinding(graphID: graphID, nodeID: nodeID).applied(to: &metadata)
        return CanvasNodeSnapshot(
            kind: .generationTask,
            title: title,
            content: .text(title),
            frame: .init(center: center, size: .init(width: 200, height: 100)),
            metadata: metadata)
    }

    private func twoGraphPage() -> (CanvasPageSnapshot, FlowGraph, FlowGraph, CanvasNodeSnapshot, CanvasNodeSnapshot) {
        let nodeA = FlowNode(kind: .transform, name: "A")
        let graphA = FlowGraph(revision: 0, nodes: [nodeA])
        let nodeB = FlowNode(kind: .transform, name: "B")
        let graphB = FlowGraph(revision: 0, nodes: [nodeB])
        let cardA = boundCard(graphID: graphA.id, nodeID: nodeA.id, title: "A", center: .init(x: 0, y: 0))
        let cardB = boundCard(graphID: graphB.id, nodeID: nodeB.id, title: "B", center: .init(x: 400, y: 0))
        let page = CanvasPageSnapshot(
            name: "P", nodes: [cardA, cardB], flowGraphs: [graphA, graphB])
        return (page, graphA, graphB, cardA, cardB)
    }

    private func makeStore(page: CanvasPageSnapshot) -> (CanvasEditorStore, CanvasSnapshot) {
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        return (store, snapshot)
    }

    private func waitFor(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("waitFor timed out", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    // MARK: Active graph selection

    func testSelectingBoundCardActivatesItsGraphAndCommitKeepsIt() async {
        let (page, graphA, graphB, cardA, cardB) = twoGraphPage()
        let (store, _) = makeStore(page: page)
        await store.load()
        XCTAssertEqual(store.activeFlowGraphID, graphA.id, "first graph is the initial active graph")

        store.select(cardB.id)
        XCTAssertEqual(store.activeFlowGraphID, graphB.id,
                       "selecting a card bound to graph B activates graph B")

        // Any commit triggers a rebuild; the active choice must survive.
        await store.apply(.updateTitle(cardB.id, "B edited"))
        XCTAssertEqual(store.activeFlowGraphID, graphB.id,
                       "rebuild must not reset the active graph to the first one")
        store.select(cardA.id)
        XCTAssertEqual(store.activeFlowGraphID, graphA.id)
    }

    func testSelectFlowGraphValidatesPageOwnership() async {
        let (page, graphA, graphB, _, _) = twoGraphPage()
        let (store, _) = makeStore(page: page)
        await store.load()
        store.selectFlowGraph(graphB.id)
        XCTAssertEqual(store.activeFlowGraphID, graphB.id)
        store.selectFlowGraph(graphA.id)
        XCTAssertEqual(store.activeFlowGraphID, graphA.id)
        // A graph from another page/foreign ID is refused, not adopted.
        store.selectFlowGraph(UUID())
        XCTAssertEqual(store.activeFlowGraphID, graphA.id)
    }

    func testRunDispatchesTheSelectedGraphNotAlwaysTheFirst() async throws {
        let (page, _, graphB, _, cardB) = twoGraphPage()
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let configuredGraphIDs = GraphRecorder()
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot),
                makeFlowRuntime: { FlowRuntimeService(executor: nil) },
                makeRunConfiguration: { snapshot, pageID, graph in
                    await configuredGraphIDs.append(graph.id)
                    return FlowRunConfiguration(
                        identity: FlowRunIdentity(
                            canvasID: snapshot.id,
                            canvasRevision: snapshot.revision,
                            flowGraphID: graph.id,
                            flowGraphRevision: graph.revision,
                            environmentID: ""),
                        pageID: pageID,
                        configurationDigest: "test-digest")
                }))
        await store.load()
        store.select(cardB.id)
        XCTAssertEqual(store.activeFlowGraphID, graphB.id)
        let started = await store.startFlowRun()
        XCTAssertTrue(started)
        let recordedIDs = await configuredGraphIDs.ids
        XCTAssertEqual(recordedIDs, [graphB.id],
                       "run configuration is built from the ACTIVE graph, not the first")
    }

    // MARK: Run output placement

    /// source(constant "hello") → output(resultKey "text")
    /// source(constant table)  → output(resultKey "table")
    /// source(constant list)   → output(resultKey "items") — saved whole as
    /// an editable JSON card (see CanvasRunOutputTransactionTests for the
    /// typed-asset-leaf media cards)
    private func outputGraph() -> FlowGraph {
        func sourceNode(name: String, portName: String, dataType: FlowValueType, literal: JSONValue) -> FlowNode {
            FlowNode(
                kind: .source,
                name: name,
                ports: [FlowPort(name: portName, dataType: dataType, direction: .output)],
                parameters: [
                    "sourceKind": .string("constant"),
                    "literal": literal,
                ])
        }
        func outputNode(name: String, portName: String, dataType: FlowValueType, resultKey: String) -> FlowNode {
            FlowNode(
                kind: .output,
                name: name,
                ports: [FlowPort(name: portName, dataType: dataType, direction: .input)],
                parameters: ["resultKey": .string(resultKey)])
        }
        let textSource = sourceNode(name: "S1", portName: "text", dataType: .string, literal: .string("hello"))
        let textOutput = outputNode(name: "O1", portName: "text", dataType: .string, resultKey: "text")
        let tableSource = sourceNode(
            name: "S2", portName: "table", dataType: .table,
            literal: .object([
                "header": .array([.string("Name")]),
                "rows": .array([.array([.string("value")])]),
            ]))
        let tableOutput = outputNode(name: "O2", portName: "table", dataType: .table, resultKey: "table")
        let listSource = sourceNode(
            name: "S3", portName: "items", dataType: .list,
            literal: .array([
                .string("a"),
                .string("雪"),
                .array([.number("9007199254740993"), .string("b")]),
            ]))
        let listOutput = outputNode(name: "O3", portName: "items", dataType: .list, resultKey: "items")
        let edges = [
            FlowEdge(
                sourceNodeID: textSource.id, sourcePortID: textSource.ports[0].id,
                destinationNodeID: textOutput.id, destinationPortID: textOutput.ports[0].id),
            FlowEdge(
                sourceNodeID: tableSource.id, sourcePortID: tableSource.ports[0].id,
                destinationNodeID: tableOutput.id, destinationPortID: tableOutput.ports[0].id),
            FlowEdge(
                sourceNodeID: listSource.id, sourcePortID: listSource.ports[0].id,
                destinationNodeID: listOutput.id, destinationPortID: listOutput.ports[0].id),
        ]
        return FlowGraph(
            revision: 0,
            nodes: [textSource, textOutput, tableSource, tableOutput, listSource, listOutput],
            edges: edges)
    }

    private func makeRunningStore(
        page: CanvasPageSnapshot
    ) -> CanvasEditorStore {
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        return CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot),
                makeFlowRuntime: { FlowRuntimeService(executor: nil) },
                makeRunConfiguration: { snapshot, pageID, graph in
                    FlowRunConfiguration(
                        identity: FlowRunIdentity(
                            canvasID: snapshot.id,
                            canvasRevision: snapshot.revision,
                            flowGraphID: graph.id,
                            flowGraphRevision: graph.revision,
                            environmentID: ""),
                        pageID: pageID,
                        configurationDigest: "test-digest")
                }))
    }

    private func runToCompletion(_ store: CanvasEditorStore) async -> UUID {
        let started = await store.startFlowRun()
        XCTAssertTrue(started)
        await waitFor(timeout: 10) { store.flowRun?.phase == .completed }
        return try! XCTUnwrap(store.flowRun?.runID)
    }

    func testPlaceRunOutputsCreatesEditableCardsInOneUndoUnit() async throws {
        let graph = outputGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let store = makeRunningStore(page: page)
        await store.load()
        let baseCount = store.page.nodes.count
        let runID = await runToCompletion(store)

        let result = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(result?.placedCount, 3, "text + table + full-list JSON placed")
        XCTAssertEqual(result?.unsupportedCount, 0, "batch list is saved whole, not counted unsupported")
        XCTAssertEqual(result?.committed, true, "placement commit confirmed by the repository")
        XCTAssertEqual(store.page.nodes.count, baseCount + 3)

        let placedNodes = store.page.nodes.filter { $0.createdByRunID == runID }
        XCTAssertEqual(placedNodes.count, 3)
        let textCard = try XCTUnwrap(placedNodes.first(where: {
            $0.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputKey] == "text"
        }))
        guard case .text(let text) = textCard.content else {
            return XCTFail("text output becomes an editable text card")
        }
        XCTAssertEqual(text, "hello")
        let tableCard = try XCTUnwrap(placedNodes.first(where: {
            $0.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputKey] == "table"
        }))
        guard case .table(let header, let rows) = tableCard.content else {
            return XCTFail("table output becomes an editable table card")
        }
        XCTAssertEqual(header, ["Name"])
        XCTAssertEqual(rows, [["value"]])
        // The whole batch list is saved as one editable JSON card — full
        // values, exact Unicode, exact number literals.
        let listCard = try XCTUnwrap(placedNodes.first(where: {
            $0.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputKey] == "items"
        }))
        guard case .code(let language, let source) = listCard.content else {
            return XCTFail("batch list becomes an editable JSON code card")
        }
        XCTAssertEqual(language, "json")
        let parsed = try JSONFidelity.parse(Data(source.utf8))
        guard case .array(let elements) = parsed else {
            return XCTFail("placed list card holds a valid JSON array")
        }
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements[0].stringValue, "a")
        XCTAssertEqual(elements[1].stringValue, "雪", "exact Unicode preserved")
        let nested = try XCTUnwrap(elements[2].arrayValue)
        XCTAssertEqual(nested[0].numberLiteral, "9007199254740993",
                       "exact number literal preserved — no Int64(Double) re-typing")
        XCTAssertEqual(nested[1].stringValue, "b")
        // Real state badge metadata for board presentation.
        XCTAssertNotNil(CanvasRunOutputStateBadge(metadata: tableCard.metadata))
        // One gesture = one undo unit removes every placed card.
        await store.undo()
        XCTAssertEqual(store.page.nodes.count, baseCount, "one undo removes the whole placement")
    }

    func testRepeatedPlacementOfSameRunDeduplicates() async throws {
        let graph = outputGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let store = makeRunningStore(page: page)
        await store.load()
        _ = await runToCompletion(store)

        let first = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(first?.placedCount, 3)
        let countAfterFirst = store.page.nodes.count

        let second = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(second?.placedCount, 0, "same run placement never duplicates paid outputs")
        XCTAssertEqual(second?.alreadyPlacedCount, 3)
        XCTAssertEqual(store.page.nodes.count, countAfterFirst)
    }

    func testPlacementRefusesNewlySelectedPage() async throws {
        let graph = outputGraph()
        let pageA = CanvasPageSnapshot(name: "A", flowGraphs: [graph])
        let pageB = CanvasPageSnapshot(name: "B")
        let snapshot = CanvasSnapshot(name: "s", pages: [pageA, pageB])
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot),
                makeFlowRuntime: { FlowRuntimeService(executor: nil) },
                makeRunConfiguration: { snapshot, pageID, graph in
                    FlowRunConfiguration(
                        identity: FlowRunIdentity(
                            canvasID: snapshot.id,
                            canvasRevision: snapshot.revision,
                            flowGraphID: graph.id,
                            flowGraphRevision: graph.revision,
                            environmentID: ""),
                        pageID: pageID,
                        configurationDigest: "test-digest")
                }))
        await store.load()
        _ = await runToCompletion(store)
        await store.selectPage(pageB.id)
        let result = await store.placeFlowRunOutputsOnPage()
        XCTAssertNil(result, "outputs must never land on a newly selected page")
        XCTAssertNotNil(store.alert)
    }

    func testPlacementRequiresCompletedRun() async throws {
        let graph = outputGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let store = makeRunningStore(page: page)
        await store.load()
        let result = await store.placeFlowRunOutputsOnPage()
        XCTAssertNil(result, "no run bound: actionable alert, no placement")
        XCTAssertNotNil(store.alert)
    }

    // MARK: Run-save (checkpoint) failure plumbing

    func testRunSnapshotCarriesCheckpointFailureAsRealState() {
        let runID = UUID()
        let plain = CanvasFlowRunSnapshot(
            runID: runID,
            graphID: UUID(),
            phase: .completed,
            completedSteps: 1,
            totalUnits: 1,
            pendingReconciliations: 0,
            failureCount: 0,
            events: [],
            stepRecords: [],
            lateDeliveries: [],
            breakpoints: [])
        XCTAssertNil(plain.checkpointFailure, "default is no run-save failure")

        let failed = CanvasFlowRunSnapshot(
            runID: runID,
            graphID: UUID(),
            phase: .completed,
            completedSteps: 1,
            totalUnits: 1,
            pendingReconciliations: 0,
            failureCount: 0,
            checkpointFailure: "disk full",
            events: [],
            stepRecords: [],
            lateDeliveries: [],
            breakpoints: [])
        XCTAssertEqual(failed.checkpointFailure, "disk full",
                       "host-reported run-save failure is real state, never a fake success")
    }

    func testCheckpointFailureStringsLocalized() {
        XCTAssertEqual(
            CanvasStrings(language: .english)[.debuggerCheckpointFailed], "Run save failed")
        XCTAssertEqual(
            CanvasStrings(language: .simplifiedChinese)[.debuggerCheckpointFailed], "运行保存失败")
    }
}

#endif // canImport(UIKit)
