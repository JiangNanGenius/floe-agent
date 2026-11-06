import Foundation
import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration
@testable import FloeCanvasFlow

/// Nested structured composites: templates may contain conditions, loops,
/// batches and further subgraphs. Covers scoped instance identities,
/// isolated variables/outputs/attempt IDs, journal recovery for nested
/// external work without duplicate submissions, debug controls inside
/// template bodies, template recursion diagnostics, and the lazy
/// environment policy (local graphs run without one; external submissions
/// refuse honestly instead of falling back to a host interpreter).
final class FlowNestedCompositeTests: XCTestCase {

    private var root: URL!
    private var journal: FlowRunJournal!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-flow-nested-\(UUID().uuidString)")
        journal = try FlowRunJournal(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRuntime(
        executor: (any CanvasStepExecutor)? = nil,
        templates: [FlowSubgraphTemplate] = []
    ) -> FlowRuntimeService {
        FlowRuntimeService(
            executor: executor,
            journal: journal,
            nativeRegistry: TestNativeHandlers.makeRegistry(),
            subgraphTemplates: templates)
    }

    // MARK: Template with condition + loop

    func testNestedLoopRecoveryDoesNotAdoptPreviousOuterIteration() async throws {
        let external = GraphFactory.external(name: "nested external", inputs: [], outputs: [])
        let inner = FlowNode(kind: .loop, name: "inner", parameters: ["maxIterations": .number("2")], bodyNodeIDs: [external.node.id])
        let outer = FlowNode(kind: .loop, name: "outer", parameters: ["maxIterations": .number("2")], bodyNodeIDs: [inner.id])
        let graph = FlowGraph(nodes: [outer, inner, external.node])
        let executor = TestStepExecutor()
        await executor.holdSubmission(number: 3)
        let identity = GraphFactory.makeIdentity()
        let runtime = makeRuntime(executor: executor)
        _ = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(identity: identity))
        let submitted = await executor.submissionCount()
        XCTAssertEqual(submitted, 3, "second outer iteration reaches its first held inner step")
        await runtime.pause(runID: identity.runID)
        let second = makeRuntime(executor: executor)
        try await second.resumeRun(runID: identity.runID)
        let beforeCompletion = await executor.submissionCount()
        XCTAssertEqual(beforeCompletion, 3, "restore queries the held coordinate without advancing or repeating it")
        let attempts = await executor.performedAttemptIDs
        try await executor.complete(attemptID: XCTUnwrap(attempts.last), outcome: .init(status: .succeeded))
        await second.externalStepDidFinish(runID: identity.runID, attemptID: attempts.last!)
        await XCTAssertEventually { await second.status(runID: identity.runID)?.phase == .completed }
        let finalCount = await executor.submissionCount()
        XCTAssertEqual(finalCount, 4, "each of the four nested coordinates executes exactly once")
    }

    func testTemplateContainingConditionAndLoopExecutesBoth() async throws {
        // Template: const(4) → condition(>3) gates a transform; const(4)
        // feeds a carry loop (addOneVar, stopWhen carry.value > 7); the
        // loop exit feeds the template output port "final".
        let source = GraphFactory.constantSource(literal: .number("4"), type: .number)
        let conditionIn = FlowPort(name: "in", dataType: .number, direction: .input)
        let truePort = FlowPort(name: "true", dataType: .bool, direction: .output)
        let condition = FlowNode(
            kind: .condition,
            name: "check",
            ports: [conditionIn, truePort],
            branches: [FlowConditionBranch(
                predicate: .comparison(
                    .greaterThan,
                    lhs: .nodeOutput(nodeID: source.node.id, portName: "out"),
                    rhs: .literal(.number(3))),
                outputPortID: truePort.id)])
        let gated = GraphFactory.transform(
            name: "gated", nativeKey: "noop",
            inputs: [("in", .number), ("gate", .bool)],
            outputs: [("out", .number)])
        let valuePort = FlowPort(name: "value", dataType: .number, direction: .input)
        let finalPort = FlowPort(name: "final", dataType: .number, direction: .output)
        let stopWhen = try FlowLiterals.encodeToJSON(FlowPredicate.comparison(
            .greaterThan,
            lhs: .variable(name: "carry.value"),
            rhs: .literal(.number(7))))
        let step = GraphFactory.transform(
            name: "step", nativeKey: "math.addOneVar",
            inputs: [], outputs: [("out", .number)])
        let loop = FlowNode(
            kind: .loop, name: "counter",
            ports: [valuePort, finalPort],
            parameters: ["stopWhen": stopWhen],
            bodyNodeIDs: [step.node.id])
        let innerOut = GraphFactory.output(inputs: [("final", .number)], resultKey: "final")
        let templateGraph = FlowGraph(nodes: [
            source.node, condition, gated.node, loop, step.node, innerOut.node,
        ], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: conditionIn, node: condition),
            GraphFactory.edge(from: truePort, node: condition,
                              to: gated.inPorts[1], node: gated.node),
            GraphFactory.edge(from: source.out, node: source.node,
                              to: gated.inPorts[0], node: gated.node),
            GraphFactory.edge(from: source.out, node: source.node,
                              to: valuePort, node: loop),
            GraphFactory.edge(from: step.outPorts[0], node: step.node,
                              to: valuePort, node: loop), // carry
            GraphFactory.edge(from: step.outPorts[0], node: step.node,
                              to: innerOut.inPorts[0], node: innerOut.node), // exit
        ])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "conditionLoop", graph: templateGraph,
            exposedPorts: [FlowPort(name: "final", dataType: .number, direction: .output)])

        let subgraphNode = FlowNode(
            kind: .subgraph, name: "inst",
            ports: [FlowPort(name: "final", dataType: .number, direction: .output)],
            subgraphTemplateID: template.id)
        let out = GraphFactory.output(inputs: [("final", .number)], resultKey: "final")
        let graph = FlowGraph(nodes: [subgraphNode, out.node], edges: [
            GraphFactory.edge(from: subgraphNode.ports[0], node: subgraphNode,
                              to: out.inPorts[0], node: out.node),
        ])

        let runtime = makeRuntime(templates: [template])
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let result = await runtime.result(runID: runID)
        // 4 → 5 → 6 → 7 → 8, stop when carry.value > 7.
        XCTAssertEqual(result?.runOutputs["final"], .number(8))
        let records = await runtime.stepRecords(runID: runID)
        XCTAssertEqual(
            records.filter { $0.nodeID == step.node.id && $0.status == .succeeded }.count, 4)
        // The condition inside the template executed and selected its branch.
        XCTAssertTrue(records.contains {
            $0.nodeID == gated.node.id && $0.status == .succeeded
        })
    }

    // MARK: Batch whose body invokes another subgraph

    func testBatchBodyInvokingSubgraphCollectsPerItemResults() async throws {
        // Template "doubleItem": exposed input port "in" (bound to the
        // batch's `item` variable) is doubled; the inner transform writes
        // the batch's `itemResult` collect variable across the instance
        // boundary via the lexical declaration chain.
        let double = GraphFactory.transform(
            name: "double", nativeKey: "math.double",
            inputs: [("in", .number)], outputs: [("out", .number)],
            writeVariables: ["out": "itemResult"])
        let innerOut = GraphFactory.output(
            inputs: [("result", .number)], resultKey: "out")
        let templateGraph = FlowGraph(nodes: [double.node, innerOut.node], edges: [
            GraphFactory.edge(from: double.outPorts[0], node: double.node,
                              to: innerOut.inPorts[0], node: innerOut.node),
        ])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "doubleItem", graph: templateGraph,
            exposedPorts: [FlowPort(name: "out", dataType: .number, direction: .output)])

        let itemsPort = FlowPort(name: "items", dataType: .list, direction: .input)
        let resultsPort = FlowPort(name: "results", dataType: .list, direction: .output)
        let subgraphBody = FlowNode(
            kind: .subgraph, name: "dbl",
            ports: [FlowPort(name: "out", dataType: .number, direction: .output)],
            parameters: ["inputBindings": .object([
                "in": try FlowLiterals.encodeToJSON(FlowOperand.variable(name: "item")),
            ])],
            subgraphTemplateID: template.id)
        let batch = FlowNode(
            kind: .batch, name: "fan",
            ports: [itemsPort, resultsPort],
            parameters: [:],
            bodyNodeIDs: [subgraphBody.id])
        let source = GraphFactory.constantSource(
            literal: .array([.number("1"), .number("2"), .number("3")]),
            type: .list)
        let out = GraphFactory.output(inputs: [("results", .list)], resultKey: "results")
        let itemResult = FlowVariable(name: "itemResult", dataType: .number,
                                      ownerNodeID: batch.id, initial: .number(0))
        let graph = FlowGraph(nodes: [source.node, batch, subgraphBody, out.node],
                              edges: [
                                GraphFactory.edge(from: source.out, node: source.node,
                                                  to: itemsPort, node: batch),
                                GraphFactory.edge(from: resultsPort, node: batch,
                                                  to: out.inPorts[0], node: out.node),
                              ],
                              variables: [itemResult])

        let runtime = makeRuntime(templates: [template])
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .completed)
        let result = await runtime.result(runID: runID)
        XCTAssertEqual(result?.runOutputs["results"], .list([.number(2), .number(4), .number(6)]))
    }

    // MARK: Sibling instances: shared template, isolated state/attempts

    func testSiblingInstancesShareTemplateButIsolateVariablesAndAttempts() async throws {
        let ext = GraphFactory.external(
            name: "ext", inputs: [], outputs: [("out", .string)])
        let bump = GraphFactory.transform(
            name: "bump", nativeKey: "acc.bump",
            inputs: [], outputs: [("acc", .number)],
            writeVariables: ["acc": "acc"])
        let loop = FlowNode(
            kind: .loop, name: "counter",
            ports: [],
            parameters: ["maxIterations": .number("2")],
            bodyNodeIDs: [ext.node.id, bump.node.id])
        let innerOut = GraphFactory.output(inputs: [("acc", .number)], resultKey: "acc")
        let acc = FlowVariable(name: "acc", dataType: .number,
                               ownerNodeID: loop.id, initial: .number(0))
        let templateGraph = FlowGraph(
            nodes: [loop, ext.node, bump.node, innerOut.node],
            edges: [GraphFactory.edge(from: bump.outPorts[0], node: bump.node,
                                      to: innerOut.inPorts[0], node: innerOut.node)],
            variables: [acc])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "bumpTwice", graph: templateGraph,
            exposedPorts: [FlowPort(name: "acc", dataType: .number, direction: .output)])

        func makeInstance() -> FlowNode {
            FlowNode(kind: .subgraph, name: "inst",
                     ports: [FlowPort(name: "acc", dataType: .number, direction: .output)],
                     subgraphTemplateID: template.id)
        }
        let first = makeInstance()
        let second = makeInstance()
        let outA = GraphFactory.output(inputs: [("acc", .number)], resultKey: "a")
        let outB = GraphFactory.output(inputs: [("acc", .number)], resultKey: "b")
        let graph = FlowGraph(nodes: [first, second, outA.node, outB.node], edges: [
            GraphFactory.edge(from: first.ports[0], node: first,
                              to: outA.inPorts[0], node: outA.node),
            GraphFactory.edge(from: second.ports[0], node: second,
                              to: outB.inPorts[0], node: outB.node),
        ])
        let executor = TestStepExecutor { _ in
            .init(status: .succeeded, outputs: ["out": .string("ok")])
        }
        let runtime = makeRuntime(executor: executor, templates: [template])
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let result = await runtime.result(runID: runID)
        XCTAssertEqual(result?.terminalStatus, .completed,
            "Nested records: \(String(describing: result?.records))")
        // Each instance bumped its own loop-scoped `acc` twice.
        XCTAssertEqual(result?.runOutputs["a"], .number(2))
        XCTAssertEqual(result?.runOutputs["b"], .number(2))
        // Two external attempts per instance (one per iteration), each with
        // a distinct, coordinate-deterministic attempt ID.
        let attempts = await executor.performedAttemptIDs
        XCTAssertEqual(attempts.count, 4)
        XCTAssertEqual(Set(attempts).count, 4)
    }

    // MARK: Nested external recovery from the journal (no resubmission)

    func testNestedExternalResumesFromFrozenDefinitionsWithoutResubmission() async throws {
        // No input ports: readiness requires every non-variadic input port to
        // be edge-bound, and this template has no inner source to bind from.
        let ext = GraphFactory.external(
            name: "ext", inputs: [], outputs: [("out", .string)])
        let innerOut = GraphFactory.output(
            inputs: [("in", .string)], resultKey: "text")
        let templateGraph = FlowGraph(nodes: [ext.node, innerOut.node], edges: [
            GraphFactory.edge(from: ext.outPorts[0], node: ext.node,
                              to: innerOut.inPorts[0], node: innerOut.node),
        ])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "scripted", graph: templateGraph,
            exposedPorts: [FlowPort(name: "text", dataType: .string, direction: .output)])
        let subgraphNode = FlowNode(
            kind: .subgraph, name: "inst",
            ports: [FlowPort(name: "text", dataType: .string, direction: .output)],
            subgraphTemplateID: template.id)
        let out = GraphFactory.output(inputs: [("text", .string)], resultKey: "done")
        let graph = FlowGraph(nodes: [subgraphNode, out.node], edges: [
            GraphFactory.edge(from: subgraphNode.ports[0], node: subgraphNode,
                              to: out.inPorts[0], node: out.node),
        ])

        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)

        // Process 1 starts and pauses with the inner attempt held in flight.
        let runtime1 = FlowRuntimeService(
            executor: executor, journal: journal,
            nativeRegistry: TestNativeHandlers.makeRegistry(),
            subgraphTemplates: [template])
        let runTask = Task {
            try await runtime1.startRun(
                compiled: try await runtime1.compile(graph), configuration: configuration)
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime1.pause(runID: identity.runID)
        // `pause` acknowledges only after its checkpoint is durable: assert
        // the crash boundary directly, with no timing fence.
        let journal = self.journal!
        let pauseSnapshot = try await journal.loadCheckpoint(runID: identity.runID)
        XCTAssertEqual(pauseSnapshot?.phase, .paused)

        // Process 2: resumes from the journal WITHOUT any template registry
        // of its own — the frozen definitions must be adopted.
        let runtime2 = FlowRuntimeService(
            executor: executor, journal: journal,
            nativeRegistry: TestNativeHandlers.makeRegistry())
        try await runtime2.resumeRun(runID: identity.runID)
        let resumedSubmissionCount = await executor.submissionCount()
        XCTAssertEqual(resumedSubmissionCount, 1)

        let attempts = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime2.externalStepDidFinish(runID: identity.runID, attemptID: attempts[0])
        await XCTAssertEventually({
            await runtime2.status(runID: identity.runID)?.phase == .completed
        })
        let result = await runtime2.result(runID: identity.runID)
        XCTAssertEqual(result?.runOutputs["done"], .string("ok"))
        let finalSubmissionCount = await executor.submissionCount()
        XCTAssertEqual(finalSubmissionCount, 1)
        _ = runTask
    }

    // MARK: Debug controls inside template bodies

    func testBreakpointInsideTemplatePausesBeforeInnerStep() async throws {
        let a = GraphFactory.transform(
            name: "a", nativeKey: "noop",
            inputs: [], outputs: [("out", .number)])
        let b = GraphFactory.transform(
            name: "b", nativeKey: "noop",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let innerOut = GraphFactory.output(inputs: [("in", .number)], resultKey: "v")
        let templateGraph = FlowGraph(nodes: [a.node, b.node, innerOut.node], edges: [
            GraphFactory.edge(from: a.outPorts[0], node: a.node,
                              to: b.inPorts[0], node: b.node),
            GraphFactory.edge(from: b.outPorts[0], node: b.node,
                              to: innerOut.inPorts[0], node: innerOut.node),
        ])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "chain", graph: templateGraph,
            exposedPorts: [FlowPort(name: "v", dataType: .number, direction: .output)])
        let subgraphNode = FlowNode(
            kind: .subgraph, name: "inst",
            ports: [FlowPort(name: "v", dataType: .number, direction: .output)],
            subgraphTemplateID: template.id)
        let out = GraphFactory.output(inputs: [("v", .number)], resultKey: "v")
        let graph = FlowGraph(nodes: [subgraphNode, out.node], edges: [
            GraphFactory.edge(from: subgraphNode.ports[0], node: subgraphNode,
                              to: out.inPorts[0], node: out.node),
        ])

        let runtime = makeRuntime(templates: [template])
        let runID = GraphFactory.makeIdentity().runID
        await runtime.addBreakpoint(b.node.id, runID: runID)
        try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity(runID: runID)))
        let paused = await runtime.status(runID: runID)
        XCTAssertEqual(paused?.phase, .paused)
        var records = await runtime.stepRecords(runID: runID)
        XCTAssertTrue(records.contains { $0.nodeID == a.node.id && $0.status == .succeeded })
        XCTAssertFalse(records.contains { $0.nodeID == b.node.id })

        await runtime.resume(runID: runID)
        await XCTAssertEventually({
            await runtime.status(runID: runID)?.phase == .completed
        })
        records = await runtime.stepRecords(runID: runID)
        XCTAssertTrue(records.contains { $0.nodeID == b.node.id && $0.status == .succeeded })
        let result = await runtime.result(runID: runID)
        XCTAssertNotNil(result?.runOutputs["v"])
    }

    func testStepPauseAndCancelInsideNestedExternalWork() async throws {
        // Template: ext1 → ext2 (both holdable). Exercises pause with
        // in-flight inner work, deterministic re-entry (the same attempt ID
        // is regenerated, so the driver count stays 1), step-into-composite
        // stopping at the next real runnable step, and cancel fencing.
        // ext1 has no input ports: the template has no inner source, and
        // readiness would otherwise skip it as `missingInput` (ext2's `in`
        // is bound by the ext1 → ext2 edge).
        let ext1 = GraphFactory.external(
            name: "ext1", inputs: [], outputs: [("out", .string)])
        let ext2 = GraphFactory.external(
            name: "ext2", inputs: [("in", .string)], outputs: [("out", .string)])
        let innerOut = GraphFactory.output(
            inputs: [("in", .string)], resultKey: "text")
        let templateGraph = FlowGraph(
            nodes: [ext1.node, ext2.node, innerOut.node],
            edges: [
                GraphFactory.edge(from: ext1.outPorts[0], node: ext1.node,
                                  to: ext2.inPorts[0], node: ext2.node),
                GraphFactory.edge(from: ext2.outPorts[0], node: ext2.node,
                                  to: innerOut.inPorts[0], node: innerOut.node),
            ])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "heldChain", graph: templateGraph,
            exposedPorts: [FlowPort(name: "text", dataType: .string, direction: .output)])
        func makeGraph() -> (FlowGraph, FlowNode) {
            let subgraphNode = FlowNode(
                kind: .subgraph, name: "inst",
                ports: [FlowPort(name: "text", dataType: .string, direction: .output)],
                subgraphTemplateID: template.id)
            let out = GraphFactory.output(inputs: [("text", .string)], resultKey: "done")
            return (FlowGraph(nodes: [subgraphNode, out.node], edges: [
                GraphFactory.edge(from: subgraphNode.ports[0], node: subgraphNode,
                                  to: out.inPorts[0], node: out.node),
            ]), subgraphNode)
        }

        // Phase 1: pause with in-flight inner work, then step.
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let (graph, _) = makeGraph()
        let runtime = FlowRuntimeService(
            executor: executor, journal: journal,
            nativeRegistry: TestNativeHandlers.makeRegistry(),
            subgraphTemplates: [template])
        let identity = GraphFactory.makeIdentity()
        let runTask = Task {
            try await runtime.startRun(
                compiled: try await runtime.compile(graph),
                configuration: GraphFactory.makeConfiguration(identity: identity))
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime.pause(runID: identity.runID)
        var attempts = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime.externalStepDidFinish(runID: identity.runID, attemptID: attempts[0])
        try? await runTask.value
        let phaseAfterStep = await runtime.status(runID: identity.runID)?.phase
        XCTAssertEqual(phaseAfterStep, .paused)
        let ext2Submissions = await executor.submissionCount(forNode: ext2.node.id)
        XCTAssertEqual(ext2Submissions, 0)

        // Step into the composite: the next real runnable step is ext2.
        // ext1 is NOT resubmitted — its attempt coordinate is unchanged, so
        // the regenerated attempt ID dedupes against the driver (the count
        // stays 1 across the composite re-entry).
        await runtime.step(runID: identity.runID)
        await XCTAssertEventually({
            await executor.submissionCount(forNode: ext2.node.id) == 1
        })
        let ext1Submissions = await executor.submissionCount(forNode: ext1.node.id)
        XCTAssertEqual(ext1Submissions, 1)
        attempts = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts.last!,
            outcome: .init(status: .succeeded, outputs: ["out": .string("done")]))
        await runtime.externalStepDidFinish(runID: identity.runID, attemptID: attempts.last!)
        // The exhausted step budget pauses the run before the inner output.
        await XCTAssertEventually({
            await runtime.status(runID: identity.runID)?.phase == .paused
        })

        // Resume to completion: ext1/ext2 results are adopted, no new work.
        await runtime.resume(runID: identity.runID)
        await XCTAssertEventually({
            await runtime.status(runID: identity.runID)?.phase == .completed
        })
        let result = await runtime.result(runID: identity.runID)
        XCTAssertEqual(result?.runOutputs["done"], .string("done"))
        let ext1Final = await executor.submissionCount(forNode: ext1.node.id)
        XCTAssertEqual(ext1Final, 1)
        let ext2Final = await executor.submissionCount(forNode: ext2.node.id)
        XCTAssertEqual(ext2Final, 1)

        // Phase 2: cancel with in-flight inner work — late delivery fenced.
        let (graph2, _) = makeGraph()
        let identity2 = GraphFactory.makeIdentity()
        let runTask2 = Task {
            try await runtime.startRun(
                compiled: try await runtime.compile(graph2),
                configuration: GraphFactory.makeConfiguration(identity: identity2))
        }
        await XCTAssertEventually({ await executor.submissionCount() == 3 })
        await runtime.cancel(runID: identity2.runID)
        let attemptsAll = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attemptsAll.last!,
            outcome: .init(status: .succeeded, outputs: ["out": .string("late")]))
        await runtime.externalStepDidFinish(runID: identity2.runID, attemptID: attemptsAll.last!)
        try? await runTask2.value
        let phase2 = await runtime.status(runID: identity2.runID)?.phase
        XCTAssertEqual(phase2, .cancelled)
        let late = await runtime.lateDeliveries(runID: identity2.runID)
        XCTAssertEqual(late.count, 1)
    }

    func testBypassInsideTemplateSkipsInnerNode() async throws {
        let a = GraphFactory.transform(
            name: "a", nativeKey: "noop",
            inputs: [], outputs: [("out", .number)])
        let b = GraphFactory.transform(
            name: "b", nativeKey: "noop",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let innerOut = GraphFactory.output(inputs: [("in", .number)], resultKey: "v")
        let templateGraph = FlowGraph(nodes: [a.node, b.node, innerOut.node], edges: [
            GraphFactory.edge(from: a.outPorts[0], node: a.node,
                              to: b.inPorts[0], node: b.node),
            GraphFactory.edge(from: b.outPorts[0], node: b.node,
                              to: innerOut.inPorts[0], node: innerOut.node),
        ])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "chain", graph: templateGraph,
            exposedPorts: [FlowPort(name: "v", dataType: .number, direction: .output)])
        let subgraphNode = FlowNode(
            kind: .subgraph, name: "inst",
            ports: [FlowPort(name: "v", dataType: .number, direction: .output)],
            subgraphTemplateID: template.id)
        let out = GraphFactory.output(inputs: [("v", .number)], resultKey: "v")
        let graph = FlowGraph(nodes: [subgraphNode, out.node], edges: [
            GraphFactory.edge(from: subgraphNode.ports[0], node: subgraphNode,
                              to: out.inPorts[0], node: out.node),
        ])
        let runtime = makeRuntime(templates: [template])
        let runID = GraphFactory.makeIdentity().runID
        await runtime.bypass(nodeID: b.node.id, runID: runID)
        try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity(runID: runID)))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .completed)
        let records = await runtime.stepRecords(runID: runID)
        XCTAssertTrue(records.contains {
            $0.nodeID == b.node.id && $0.status == .skipped
                && ($0.error ?? "") == "bypassed"
        })
        // The instance output stays null (its upstream was bypassed) but the
        // run itself completes — skips are not failures.
        let result = await runtime.result(runID: runID)
        XCTAssertEqual(result?.runOutputs["v"], .json(.null))
    }

    func testUnconfirmedNestedSubmissionWaitsForReconcile() async throws {
        // No input ports: the template has no inner source to bind from.
        let ext = GraphFactory.external(
            name: "ext", inputs: [], outputs: [("out", .string)])
        let innerOut = GraphFactory.output(
            inputs: [("in", .string)], resultKey: "text")
        let templateGraph = FlowGraph(nodes: [ext.node, innerOut.node], edges: [
            GraphFactory.edge(from: ext.outPorts[0], node: ext.node,
                              to: innerOut.inPorts[0], node: innerOut.node),
        ])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "scripted", graph: templateGraph,
            exposedPorts: [FlowPort(name: "text", dataType: .string, direction: .output)])
        let subgraphNode = FlowNode(
            kind: .subgraph, name: "inst",
            ports: [FlowPort(name: "text", dataType: .string, direction: .output)],
            subgraphTemplateID: template.id)
        let out = GraphFactory.output(inputs: [("text", .string)], resultKey: "done")
        let graph = FlowGraph(nodes: [subgraphNode, out.node], edges: [
            GraphFactory.edge(from: subgraphNode.ports[0], node: subgraphNode,
                              to: out.inPorts[0], node: out.node),
        ])

        // Pre-mark the inner attempt as unconfirmed using its public
        // deterministic identity (run + node + attempt + instance call path).
        let identity = GraphFactory.makeIdentity()
        let attemptID = FlowDeterministicID.make(name:
            "\(identity.runID.uuidString)|\(ext.node.id.uuidString)|1|/\(subgraphNode.id.uuidString)|-1")
        let executor = TestStepExecutor(unconfirmedAttempts: [attemptID])
        let runtime = makeRuntime(executor: executor, templates: [template])
        let runTask = Task {
            try await runtime.startRun(
                compiled: try await runtime.compile(graph),
                configuration: GraphFactory.makeConfiguration(identity: identity))
        }
        // The run surfaces waitingReconcile and never resubmits.
        await XCTAssertEventually({
            await runtime.status(runID: identity.runID)?.phase == .waitingReconcile
        })
        let submissionsWhileWaiting = await executor.submissionCount()
        XCTAssertEqual(submissionsWhileWaiting, 1)

        try await executor.complete(
            attemptID: attemptID,
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime.externalStepDidFinish(runID: identity.runID, attemptID: attemptID)
        await XCTAssertEventually({
            await runtime.status(runID: identity.runID)?.phase == .completed
        })
        let result = await runtime.result(runID: identity.runID)
        XCTAssertEqual(result?.runOutputs["done"], .string("ok"))
        let finalTotal = await executor.submissionCount()
        XCTAssertEqual(finalTotal, 1)
        _ = runTask
    }

    // MARK: Template validation diagnostics

    func testRecursiveTemplateReferenceIsDiagnosedAtStart() async throws {
        let idA = UUID(), idB = UUID()
        let nodeB = FlowNode(kind: .subgraph, name: "b",
                             ports: [], subgraphTemplateID: idB)
        let templateA = FlowSubgraphTemplate(
            id: idA, name: "A",
            graph: FlowGraph(nodes: [nodeB], edges: []))
        let nodeA = FlowNode(kind: .subgraph, name: "a",
                             ports: [], subgraphTemplateID: idA)
        let templateB = FlowSubgraphTemplate(
            id: idB, name: "B",
            graph: FlowGraph(nodes: [nodeA], edges: []))
        let graph = FlowGraph(nodes: [FlowNode(kind: .subgraph, name: "root",
                                               ports: [], subgraphTemplateID: idA)],
                              edges: [])
        let runtime = makeRuntime(templates: [templateA, templateB])
        await XCTAssertThrowsErrorAsync({
            try await runtime.startRun(
                compiled: try await runtime.compile(graph),
                configuration: GraphFactory.makeConfiguration(
                    identity: GraphFactory.makeIdentity()))
        }) { error in
            guard case FlowRuntimeError.invalidRunConfiguration(let message) = error else {
                XCTFail("expected invalidRunConfiguration, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("recursive"), "message: \(message)")
        }
    }

    func testDuplicateTemplateIDsAreDiagnosedAtStartNotTrapped() async throws {
        let body = GraphFactory.transform(name: "b", nativeKey: "noop",
                                          inputs: [], outputs: [])
        let templateGraph = FlowGraph(nodes: [body.node], edges: [])
        let first = FlowSubgraphTemplate(id: UUID(), name: "one", graph: templateGraph)
        let duplicate = FlowSubgraphTemplate(id: first.id, name: "two", graph: templateGraph)
        let subgraphNode = FlowNode(kind: .subgraph, name: "inst",
                                    ports: [], subgraphTemplateID: first.id)
        let graph = FlowGraph(nodes: [subgraphNode], edges: [])
        let runtime = makeRuntime(templates: [first, duplicate])
        await XCTAssertThrowsErrorAsync({
            try await runtime.startRun(
                compiled: try await runtime.compile(graph),
                configuration: GraphFactory.makeConfiguration(
                    identity: GraphFactory.makeIdentity()))
        }) { error in
            guard case FlowRuntimeError.invalidRunConfiguration(let message) = error else {
                XCTFail("expected invalidRunConfiguration, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("more than once"), "message: \(message)")
        }
    }

    func testCopiedGraphPreservesReusableTemplate() async throws {
        // Self-contained template: const(5) → double → output.
        let source = GraphFactory.constantSource(literal: .number("5"), type: .number)
        let double = GraphFactory.transform(
            name: "double", nativeKey: "math.double",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let innerOut = GraphFactory.output(inputs: [("result", .number)], resultKey: "out")
        let templateGraph = FlowGraph(nodes: [source.node, double.node, innerOut.node], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: double.inPorts[0], node: double.node),
            GraphFactory.edge(from: double.outPorts[0], node: double.node,
                              to: innerOut.inPorts[0], node: innerOut.node),
        ])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "doubleIt", graph: templateGraph,
            exposedPorts: [FlowPort(name: "out", dataType: .number, direction: .output)])
        let subgraphNode = FlowNode(
            kind: .subgraph, name: "inst",
            ports: [FlowPort(name: "out", dataType: .number, direction: .output)],
            subgraphTemplateID: template.id)
        let out = GraphFactory.output(inputs: [("out", .number)], resultKey: "v")
        let graph = FlowGraph(nodes: [subgraphNode, out.node], edges: [
            GraphFactory.edge(from: subgraphNode.ports[0], node: subgraphNode,
                              to: out.inPorts[0], node: out.node),
        ])
        // A byte-identical copy of the graph (new revision) keeps the
        // template reusable; both runs execute independent instances.
        let copied = FlowGraph(id: graph.id, revision: graph.revision + 1,
                               nodes: graph.nodes, edges: graph.edges,
                               variables: graph.variables)
        let runtime = makeRuntime(templates: [template])
        let firstID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let secondID = try await runtime.startRun(
            compiled: try await runtime.compile(copied),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let first = await runtime.result(runID: firstID)
        let second = await runtime.result(runID: secondID)
        // Template source is a constant 5 → doubled → 10 for every copy.
        XCTAssertEqual(first?.runOutputs["v"], .number(10))
        XCTAssertEqual(second?.runOutputs["v"], .number(10))
    }

    // MARK: Lazy environment policy

    func testPureLocalGraphRunsWithEmptyEnvironment() async throws {
        let source = GraphFactory.constantSource(literal: .number("5"), type: .number)
        let double = GraphFactory.transform(
            name: "double", nativeKey: "math.double",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let out = GraphFactory.output(inputs: [("in", .number)], resultKey: "v")
        let graph = FlowGraph(nodes: [source.node, double.node, out.node], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: double.inPorts[0], node: double.node),
            GraphFactory.edge(from: double.outPorts[0], node: double.node,
                              to: out.inPorts[0], node: out.node),
        ])
        let runtime = makeRuntime()
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity(environmentID: "", taskID: nil)))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .completed)
        let result = await runtime.result(runID: runID)
        XCTAssertEqual(result?.runOutputs["v"], .number(10))
    }

    func testExternalStepWithoutEnvironmentFailsHonestlyAndNeverCallsExecutor() async throws {
        let source = GraphFactory.constantSource(literal: .string("go"), type: .string)
        let ext = GraphFactory.external(
            name: "ext", inputs: [("in", .string)], outputs: [("out", .string)])
        let out = GraphFactory.output(inputs: [("in", .string)], resultKey: "v")
        let graph = FlowGraph(nodes: [source.node, ext.node, out.node], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: ext.inPorts[0], node: ext.node),
            GraphFactory.edge(from: ext.outPorts[0], node: ext.node,
                              to: out.inPorts[0], node: out.node),
        ])
        let executor = TestStepExecutor()
        let runtime = makeRuntime(executor: executor)
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity(environmentID: "")))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .failed)
        // The executor never received a call: no host-interpreter fallback.
        let executorCalls = await executor.submissionCount()
        XCTAssertEqual(executorCalls, 0)
        let records = await runtime.stepRecords(runID: runID)
        XCTAssertTrue(records.contains {
            $0.nodeID == ext.node.id && $0.status == .failed
        })
    }

    func testExternalStepWithoutOwningTaskFailsHonestly() async throws {
        let source = GraphFactory.constantSource(literal: .string("go"), type: .string)
        let ext = GraphFactory.external(
            name: "ext", inputs: [("in", .string)], outputs: [("out", .string)])
        let out = GraphFactory.output(inputs: [("in", .string)], resultKey: "v")
        let graph = FlowGraph(nodes: [source.node, ext.node, out.node], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: ext.inPorts[0], node: ext.node),
            GraphFactory.edge(from: ext.outPorts[0], node: ext.node,
                              to: out.inPorts[0], node: out.node),
        ])
        let executor = TestStepExecutor()
        let runtime = makeRuntime(executor: executor)
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity(taskID: nil)))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .failed)
        let executorCallsNoTask = await executor.submissionCount()
        XCTAssertEqual(executorCallsNoTask, 0)
    }

    func testUnselectedExternalBranchDoesNotRequireEnvironment() async throws {
        // The condition does not match, so the external step on the taken
        // branch is never scheduled: an empty environment must not block a
        // run whose selected work is purely local.
        let source = GraphFactory.constantSource(literal: .string("nope"), type: .string)
        let conditionIn = FlowPort(name: "in", dataType: .string, direction: .input)
        let truePort = FlowPort(name: "true", dataType: .bool, direction: .output)
        let condition = FlowNode(
            kind: .condition, name: "check",
            ports: [conditionIn, truePort],
            branches: [FlowConditionBranch(
                predicate: .comparison(
                    .equal,
                    lhs: .nodeOutput(nodeID: source.node.id, portName: "out"),
                    rhs: .literal(.string("hello"))),
                outputPortID: truePort.id)])
        let ext = GraphFactory.external(
            name: "ext", inputs: [("in", .bool)], outputs: [("out", .string)])
        let graph = FlowGraph(nodes: [source.node, condition, ext.node], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: conditionIn, node: condition),
            GraphFactory.edge(from: truePort, node: condition,
                              to: ext.inPorts[0], node: ext.node),
        ])
        let executor = TestStepExecutor()
        let runtime = makeRuntime(executor: executor)
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity(environmentID: "")))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .completed)
        let executorCallsUnselected = await executor.submissionCount()
        XCTAssertEqual(executorCallsUnselected, 0)
        let records = await runtime.stepRecords(runID: runID)
        XCTAssertTrue(records.contains {
            $0.nodeID == ext.node.id && $0.status == .skipped
        })
    }
}
