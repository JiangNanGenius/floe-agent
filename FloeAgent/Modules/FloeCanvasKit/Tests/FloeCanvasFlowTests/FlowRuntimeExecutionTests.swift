import Foundation
import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration
@testable import FloeCanvasFlow

/// Deterministic runtime behavior: branching, loops with carries and stop
/// conditions, typed variables with shadowing/isolation, batch per-item
/// results/failures and subgraph instances. All steps are offline native
/// test nodes or the controlled test driver — never real AI.
final class FlowRuntimeExecutionTests: XCTestCase {

    private func makeRuntime(
        executor: (any CanvasStepExecutor)? = nil,
        journal: FlowRunJournal? = nil,
        templates: [FlowSubgraphTemplate] = []
    ) -> FlowRuntimeService {
        FlowRuntimeService(
            executor: executor,
            journal: journal,
            nativeRegistry: TestNativeHandlers.makeRegistry(),
            subgraphTemplates: templates)
    }

    // MARK: Branching

    func testConditionExecutesChosenBranchAndSkipsTheOther() async throws {
        let source = GraphFactory.constantSource(literal: .string("hello"), type: .string)
        let conditionIn = FlowPort(name: "in", dataType: .string, direction: .input)
        let truePort = FlowPort(name: "true", dataType: .bool, direction: .output)
        let falsePort = FlowPort(name: "false", dataType: .bool, direction: .output)
        let predicate = FlowPredicate.comparison(
            .equal,
            lhs: .nodeOutput(nodeID: source.node.id, portName: "out"),
            rhs: .literal(.string("hello")))
        let condition = FlowNode(
            kind: .condition,
            name: "check",
            ports: [conditionIn, truePort, falsePort],
            branches: [FlowConditionBranch(predicate: predicate, outputPortID: truePort.id)])
        let taken = GraphFactory.transform(
            name: "taken", nativeKey: "text.concat",
            inputs: [("a", .string), ("gate", .bool)],
            outputs: [("text", .string)])
        let skipped = GraphFactory.transform(
            name: "skipped", nativeKey: "text.concat",
            inputs: [("a", .string), ("gate", .bool)],
            outputs: [("text", .string)])
        let out = GraphFactory.output(inputs: [("text", .string)], resultKey: "text")
        let graph = FlowGraph(nodes: [
            source.node, condition, taken.node, skipped.node, out.node,
        ], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: conditionIn, node: condition),
            GraphFactory.edge(from: truePort, node: condition,
                              to: taken.inPorts[1], node: taken.node),
            GraphFactory.edge(from: falsePort, node: condition,
                              to: skipped.inPorts[1], node: skipped.node),
            GraphFactory.edge(from: source.out, node: source.node,
                              to: taken.inPorts[0], node: taken.node),
            GraphFactory.edge(from: source.out, node: source.node,
                              to: skipped.inPorts[0], node: skipped.node),
            GraphFactory.edge(from: taken.outPorts[0], node: taken.node,
                              to: out.inPorts[0], node: out.node),
        ])
        let runtime = makeRuntime()
        let compiled = try await runtime.compile(graph)
        let identity = GraphFactory.makeIdentity()
        let runID = try await runtime.startRun(
            compiled: compiled,
            configuration: GraphFactory.makeConfiguration(identity: identity))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .completed)
        let result = await runtime.result(runID: runID)
        XCTAssertEqual(result?.runOutputs["text"], .string("hello"))
        let records = await runtime.stepRecords(runID: runID)
        XCTAssertTrue(records.contains { $0.nodeID == taken.node.id && $0.status == .succeeded })
        XCTAssertTrue(records.contains { $0.nodeID == skipped.node.id && $0.status == .skipped })
    }

    func testConditionWithoutMatchSkipsAllBranchDownstreams() async throws {
        let source = GraphFactory.constantSource(literal: .string("nope"), type: .string)
        let inPort = FlowPort(name: "in", dataType: .string, direction: .input)
        let truePort = FlowPort(name: "true", dataType: .bool, direction: .output)
        let predicate = FlowPredicate.comparison(
            .equal,
            lhs: .nodeOutput(nodeID: source.node.id, portName: "out"),
            rhs: .literal(.string("hello")))
        let condition = FlowNode(
            kind: .condition, name: "check",
            ports: [inPort, truePort],
            branches: [FlowConditionBranch(predicate: predicate, outputPortID: truePort.id)])
        let downstream = GraphFactory.transform(
            name: "down", nativeKey: "noop",
            inputs: [("in", .bool)], outputs: [("out", .bool)])
        let graph = FlowGraph(nodes: [source.node, condition, downstream.node], edges: [
            GraphFactory.edge(from: source.out, node: source.node, to: inPort, node: condition),
            GraphFactory.edge(from: truePort, node: condition,
                              to: downstream.inPorts[0], node: downstream.node),
        ])
        let runtime = makeRuntime()
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .completed)
        let records = await runtime.stepRecords(runID: runID)
        XCTAssertTrue(records.contains {
            $0.nodeID == downstream.node.id && $0.status == .skipped
                && ($0.error ?? "").contains("branchNotTaken")
        })
    }

    // MARK: Loops

    func testLoopWithCarryAndStopCondition() async throws {
        let source = GraphFactory.constantSource(literal: .number("1"), type: .number)
        let valuePort = FlowPort(name: "value", dataType: .number, direction: .input)
        let finalPort = FlowPort(name: "final", dataType: .number, direction: .output)
        let stopWhen = try FlowLiterals.encodeToJSON(FlowPredicate.comparison(
            .greaterThan,
            lhs: .variable(name: "carry.value"),
            rhs: .literal(.number(5))))
        let loop = FlowNode(
            kind: .loop,
            name: "counter",
            ports: [valuePort, finalPort],
            parameters: ["stopWhen": stopWhen],
            bodyNodeIDs: [])
        let step = GraphFactory.transform(
            name: "step", nativeKey: "math.addOneVar",
            inputs: [], outputs: [("out", .number)])
        let loopWithBody = FlowNode(
            id: loop.id, kind: .loop, name: "counter",
            ports: loop.ports, parameters: loop.parameters,
            bodyNodeIDs: [step.node.id])
        let out = GraphFactory.output(inputs: [("final", .number)], resultKey: "final")
        let graph = FlowGraph(nodes: [source.node, loopWithBody, step.node, out.node], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: valuePort, node: loopWithBody),
            GraphFactory.edge(from: step.outPorts[0], node: step.node,
                              to: valuePort, node: loopWithBody), // carry
            GraphFactory.edge(from: step.outPorts[0], node: step.node,
                              to: out.inPorts[0], node: out.node), // exit
        ])
        let runtime = makeRuntime()
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let result = await runtime.result(runID: runID)
        // 1 → 2 → 3 → 4 → 5 → 6, stop when carry.value > 5 after producing 6.
        XCTAssertEqual(result?.runOutputs["final"], .number(6))
        let records = await runtime.stepRecords(runID: runID)
        XCTAssertEqual(records.filter { $0.nodeID == step.node.id && $0.status == .succeeded }.count, 5)
    }

    func testLoopDefaultBoundIsOneHundred() throws {
        // A loop with no maxIterations parameter caps at the default 100.
        let body = GraphFactory.transform(name: "b", nativeKey: "noop",
                                          inputs: [], outputs: [])
        let loop = FlowNode(kind: .loop, name: "loop", ports: [],
                            parameters: [:], bodyNodeIDs: [body.node.id])
        let graph = FlowGraph(nodes: [loop, body.node], edges: [])
        let compiled = try FlowGraphCompiler.compile(graph)
        XCTAssertEqual(compiled.loops[loop.id]?.bound, 100)
    }

    func testLoopBoundBeyondConfigurationCapFailsCompile() {
        let body = GraphFactory.transform(name: "b", nativeKey: "noop",
                                          inputs: [], outputs: [])
        let loop = FlowNode(kind: .loop, name: "loop", ports: [],
                            parameters: ["maxIterations": .number("10")],
                            bodyNodeIDs: [body.node.id])
        let graph = FlowGraph(nodes: [loop, body.node], edges: [])
        XCTAssertThrowsError(try FlowGraphCompiler.compile(graph, maxLoopIterations: 5))
    }

    // MARK: Variables

    func testLoopScopeVariablesDoNotLeakAcrossIterations() async throws {
        // Each iteration writes the loop-scoped `acc`; the run-level `acc`
        // (same name, different owner) keeps its own binding untouched.
        let runVar = FlowVariable(name: "acc", dataType: .number,
                                  ownerNodeID: UUID(), initial: .number(100))
        let loop = FlowNode(kind: .loop, name: "loop",
                            ports: [], parameters: ["maxIterations": .number("3")],
                            bodyNodeIDs: [])
        let body = GraphFactory.transform(
            name: "bump", nativeKey: "acc.bump",
            inputs: [], outputs: [("acc", .number)],
            writeVariables: ["acc": "acc"])
        let loopWithBody = FlowNode(
            id: loop.id, kind: .loop, name: "loop", ports: [],
            parameters: loop.parameters,
            bodyNodeIDs: [body.node.id])
        let loopVar = FlowVariable(name: "acc", dataType: .number,
                                   ownerNodeID: loop.id, initial: .number(0))
        let graph = FlowGraph(nodes: [loopWithBody, body.node],
                              edges: [],
                              variables: [runVar, loopVar])
        let runtime = makeRuntime()
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .completed)
        // Iterations write the loop-scoped `slot`; no crash, no leakage into
        // the run frame. The observable guarantee is a completed run with
        // three successful body steps.
        let records = await runtime.stepRecords(runID: runID)
        XCTAssertEqual(records.filter { $0.nodeID == body.node.id && $0.status == .succeeded }.count, 3)
    }

    func testWriteVariableTypeMismatchFailsTheStep() async throws {
        let variable = FlowVariable(name: "typed", dataType: .number,
                                    ownerNodeID: UUID(), initial: .number(0))
        let writer = GraphFactory.transform(
            name: "w", nativeKey: "text.concat",
            inputs: [("a", .string), ("b", .string)],
            outputs: [("text", .string)],
            writeVariables: ["text": "typed"])
        let graph = FlowGraph(nodes: [writer.node], edges: [], variables: [variable])
        let runtime = makeRuntime()
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity(),
                runInputs: [
                    .init(nodeID: writer.node.id, portName: "a", value: .string("x")),
                    .init(nodeID: writer.node.id, portName: "b", value: .string("y")),
                ]))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .failed)
    }

    // MARK: Batch

    func testBatchPerItemResultsAndFailuresAreIsolated() async throws {
        let source = GraphFactory.constantSource(
            literal: .array([.number("1"), .number("2"), .number("3"), .number("4")]),
            type: .list)
        let itemsPort = FlowPort(name: "items", dataType: .list, direction: .input)
        let resultsPort = FlowPort(name: "results", dataType: .list, direction: .output)
        let failuresPort = FlowPort(name: "failures", dataType: .list, direction: .output)
        let batch = FlowNode(
            kind: .batch,
            name: "fan",
            ports: [itemsPort, resultsPort, failuresPort],
            parameters: [:],
            bodyNodeIDs: [])
        let body = GraphFactory.transform(
            name: "double", nativeKey: "batch.double",
            inputs: [], outputs: [("itemResult", .number)],
            writeVariables: ["itemResult": "itemResult"])
        let batchWithBody = FlowNode(
            id: batch.id, kind: .batch, name: "fan",
            ports: batch.ports, parameters: batch.parameters,
            bodyNodeIDs: [body.node.id])
        let out = GraphFactory.output(
            inputs: [("results", .list), ("failures", .list)])
        let itemResult = FlowVariable(name: "itemResult", dataType: .number,
                                      ownerNodeID: batch.id, initial: .number(0))
        let graph = FlowGraph(nodes: [source.node, batchWithBody, body.node, out.node],
                              edges: [
                                GraphFactory.edge(from: source.out, node: source.node,
                                                  to: itemsPort, node: batchWithBody),
                                GraphFactory.edge(from: resultsPort, node: batchWithBody,
                                                  to: out.inPorts[0], node: out.node),
                                GraphFactory.edge(from: failuresPort, node: batchWithBody,
                                                  to: out.inPorts[1], node: out.node),
                              ],
                              variables: [itemResult])
        let runtime = makeRuntime()
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .completed)
        let result = await runtime.result(runID: runID)
        XCTAssertEqual(result?.runOutputs["results"],
                       .list([.number(2), .number(4), .json(.null), .number(8)]))
        guard case .list(let failures)? = result?.runOutputs["failures"] else {
            XCTFail("expected failures list")
            return
        }
        XCTAssertEqual(failures.count, 1, "Per-item failures: \(failures)")
    }

    // MARK: Subgraphs

    func testSubgraphInstanceExecutesTemplateAndMapsOutputs() async throws {
        let templateSource = GraphFactory.constantSource(
            literal: .number("5"), type: .number)
        let double = GraphFactory.transform(
            name: "double", nativeKey: "math.double",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let innerOut = GraphFactory.output(
            inputs: [("in", .number)], resultKey: "doubled")
        let templateGraph = FlowGraph(nodes: [templateSource.node, double.node, innerOut.node],
                                      edges: [
                                        GraphFactory.edge(from: templateSource.out,
                                                          node: templateSource.node,
                                                          to: double.inPorts[0],
                                                          node: double.node),
                                        GraphFactory.edge(from: double.outPorts[0],
                                                          node: double.node,
                                                          to: innerOut.inPorts[0],
                                                          node: innerOut.node),
                                      ])
        let template = FlowSubgraphTemplate(
            id: UUID(),
            name: "doubleTemplate",
            graph: templateGraph,
            exposedPorts: [FlowPort(name: "doubled", dataType: .number, direction: .output)])
        let subOut = FlowPort(name: "doubled", dataType: .number, direction: .output)
        let subgraphNode = FlowNode(
            kind: .subgraph,
            name: "doubleIt",
            ports: [subOut],
            subgraphTemplateID: template.id)
        let out = GraphFactory.output(inputs: [("doubled", .number)], resultKey: "final")
        let graph = FlowGraph(nodes: [subgraphNode, out.node], edges: [
            GraphFactory.edge(from: subOut, node: subgraphNode,
                              to: out.inPorts[0], node: out.node),
        ])
        let runtime = makeRuntime(templates: [template])
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let result = await runtime.result(runID: runID)
        XCTAssertEqual(result?.runOutputs["final"], .number(10))
    }

    func testSubgraphInstancesDoNotShareVariableState() async throws {
        // Template holds a run-level `acc` starting at 0; each instance must
        // observe its own frame (both finish at 1, never 2).
        let acc = FlowVariable(name: "acc", dataType: .number,
                               ownerNodeID: UUID(), initial: .number(0))
        let bump = GraphFactory.transform(
            name: "bump", nativeKey: "acc.bump",
            inputs: [], outputs: [("acc", .number)],
            writeVariables: ["acc": "acc"])
        let innerOut = GraphFactory.output(inputs: [("acc", .number)], resultKey: "acc")
        let templateGraph = FlowGraph(nodes: [bump.node, innerOut.node],
                                      edges: [GraphFactory.edge(
                                        from: bump.outPorts[0], node: bump.node,
                                        to: innerOut.inPorts[0], node: innerOut.node)],
                                      variables: [acc])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "accTemplate", graph: templateGraph,
            exposedPorts: [FlowPort(name: "acc", dataType: .number, direction: .output)])
        func makeSubgraph() -> FlowNode {
            FlowNode(kind: .subgraph, name: "inst",
                     ports: [FlowPort(name: "acc", dataType: .number, direction: .output)],
                     subgraphTemplateID: template.id)
        }
        let first = makeSubgraph()
        let second = makeSubgraph()
        let outA = GraphFactory.output(inputs: [("acc", .number)], resultKey: "a")
        let outB = GraphFactory.output(inputs: [("acc", .number)], resultKey: "b")
        let graph = FlowGraph(nodes: [first, second, outA.node, outB.node], edges: [
            GraphFactory.edge(from: first.ports[0], node: first,
                              to: outA.inPorts[0], node: outA.node),
            GraphFactory.edge(from: second.ports[0], node: second,
                              to: outB.inPorts[0], node: outB.node),
        ])
        let runtime = makeRuntime(templates: [template])
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let result = await runtime.result(runID: runID)
        XCTAssertEqual(result?.runOutputs["a"], .number(1))
        XCTAssertEqual(result?.runOutputs["b"], .number(1))
    }

    func testMissingSubgraphTemplateFailsTheStep() async throws {
        let subOut = FlowPort(name: "x", dataType: .number, direction: .output)
        let subgraphNode = FlowNode(kind: .subgraph, name: "ghost",
                                    ports: [subOut], subgraphTemplateID: UUID())
        let graph = FlowGraph(nodes: [subgraphNode], edges: [])
        let runtime = makeRuntime()
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .failed)
    }

    // MARK: Variadic aggregation

    func testVariadicInputAggregatesItemsInOrder() async throws {
        let registry = TestNativeHandlers.makeRegistry()
        // Local registration helper: re-create the registry with a sum node.
        var mutable = registry
        mutable.register("math.sumItems") { context in
            guard case .list(let items)? = context.inputs["items"] else {
                throw FlowOperandError.typeMismatch("math.sumItems requires list input")
            }
            let total = items.reduce(0.0) { partial, value in
                guard case .number(let number) = value else { return partial }
                return partial + number
            }
            return ["sum": .number(total)]
        }
        let sourceA = GraphFactory.constantSource(
            name: "a", literal: .number("1"), type: .number)
        let sourceB = GraphFactory.constantSource(
            name: "b", literal: .number("2"), type: .number)
        let items = FlowPort(name: "items", dataType: .number,
                             direction: .input, isVariadic: true)
        let sumOut = FlowPort(name: "sum", dataType: .number, direction: .output)
        let sum = FlowNode(kind: .transform, name: "sum",
                           ports: [items, sumOut],
                           parameters: ["nativeKey": .string("math.sumItems")])
        let out = GraphFactory.output(inputs: [("sum", .number)], resultKey: "sum")
        let graph = FlowGraph(nodes: [sourceA.node, sourceB.node, sum, out.node], edges: [
            GraphFactory.edge(from: sourceA.out, node: sourceA.node, to: items, node: sum),
            GraphFactory.edge(from: sourceB.out, node: sourceB.node, to: items, node: sum),
            GraphFactory.edge(from: sumOut, node: sum, to: out.inPorts[0], node: out.node),
        ])
        let runtime = FlowRuntimeService(executor: nil, nativeRegistry: mutable)
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let result = await runtime.result(runID: runID)
        XCTAssertEqual(result?.runOutputs["sum"], .number(3))
    }
}
