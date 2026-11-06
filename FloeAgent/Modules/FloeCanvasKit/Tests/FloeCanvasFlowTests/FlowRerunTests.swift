import Foundation
import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration
@testable import FloeCanvasFlow

/// Invalidation and partial rerun: per-node semantic signatures decide
/// reuse, never the whole-graph digest alone. Driver counts prove that
/// paid steps are not repeated for unrelated edits, and geometry-only
/// edits reuse everything.
final class FlowRerunTests: XCTestCase {

    private struct Branches {
        let graph: FlowGraph
        let extA: FlowNode
        let extB: FlowNode
    }

    /// Shared source fans out into two independent external branches.
    private func makeBranches() -> Branches {
        let source = GraphFactory.constantSource(literal: .string("go"), type: .string)
        let extA = GraphFactory.external(
            name: "branchA", inputs: [("in", .string)], outputs: [("out", .string)])
        let extB = GraphFactory.external(
            name: "branchB", inputs: [("in", .string)], outputs: [("out", .string)])
        let outA = GraphFactory.output(inputs: [("in", .string)], resultKey: "a")
        let outB = GraphFactory.output(inputs: [("in", .string)], resultKey: "b")
        let graph = FlowGraph(nodes: [source.node, extA.node, extB.node, outA.node, outB.node],
                              edges: [
                                GraphFactory.edge(from: source.out, node: source.node,
                                                  to: extA.inPorts[0], node: extA.node),
                                GraphFactory.edge(from: source.out, node: source.node,
                                                  to: extB.inPorts[0], node: extB.node),
                                GraphFactory.edge(from: extA.outPorts[0], node: extA.node,
                                                  to: outA.inPorts[0], node: outA.node),
                                GraphFactory.edge(from: extB.outPorts[0], node: extB.node,
                                                  to: outB.inPorts[0], node: outB.node),
                              ])
        return Branches(graph: graph, extA: extA.node, extB: extB.node)
    }

    private static func outcomeForBranch(_ node: FlowNode) -> TestStepExecutor.ScriptedOutcome {
        TestStepExecutor.ScriptedOutcome(
            status: .succeeded,
            outputs: ["out": .string(node.name)])
    }

    func testUnrelatedBranchEditDoesNotRerunValidBranch() async throws {
        let fixture = makeBranches()
        let executor = TestStepExecutor { [extA = fixture.extA, extB = fixture.extB] nodeID in
            if nodeID == extA.id { return Self.outcomeForBranch(extA) }
            if nodeID == extB.id { return Self.outcomeForBranch(extB) }
            return nil
        }
        let runtime = FlowRuntimeService(executor: executor)
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)
        let compiled1 = try await runtime.compile(fixture.graph)
        let runID1 = try await runtime.startRun(compiled: compiled1, configuration: configuration)
        let result1 = await runtime.result(runID: runID1)
        XCTAssertEqual(result1?.runOutputs["a"], .string("branchA"))
        let submissionsBefore = await executor.submissionCount()

        // Edit branch B's script descriptor (semantic change).
        var edited = fixture.graph
        let indexB = edited.nodes.firstIndex(where: { $0.id == fixture.extB.id })!
        edited.nodes[indexB].script = FlowScriptDescriptor(
            language: "bash", sourceHash: "sha256:changed")

        let compiled2 = try await runtime.compile(edited)
        let configuration2 = GraphFactory.makeConfiguration(
            identity: GraphFactory.makeIdentity(flowGraphID: configuration.identity.flowGraphID),
            configurationDigest: configuration.configurationDigest)
        let plan = try FlowRerunPlanner.plan(
            previous: result1!,
            previousGraph: fixture.graph,
            editedGraph: edited,
            editedCompiled: compiled2,
            configuration: configuration2)

        XCTAssertFalse(plan.reusableNodeIDs.contains(fixture.extB.id))
        XCTAssertTrue(plan.reusableNodeIDs.contains(fixture.extA.id))
        XCTAssertTrue(plan.invalidatedNodeIDs.contains(fixture.extB.id))
        XCTAssertFalse(plan.invalidatedNodeIDs.contains(fixture.extA.id))

        let runID2 = try await runtime.startRun(
            compiled: compiled2,
            configuration: configuration2,
            seed: plan.seed)
        let result2 = await runtime.result(runID: runID2)
        XCTAssertEqual(result2?.runOutputs["b"], .string("branchB"))
        let countA = await executor.submissionCount(forNode: fixture.extA.id)
        let countB = await executor.submissionCount(forNode: fixture.extB.id)
        XCTAssertEqual(countA, 1)
        XCTAssertEqual(countB, 2)
        let totalAfter = await executor.submissionCount()
        XCTAssertEqual(totalAfter, submissionsBefore + 1)
    }

    func testPureGeometryEditReusesAllPaidSteps() async throws {
        let fixture = makeBranches()
        let executor = TestStepExecutor { [extA = fixture.extA, extB = fixture.extB] nodeID in
            if nodeID == extA.id { return Self.outcomeForBranch(extA) }
            if nodeID == extB.id { return Self.outcomeForBranch(extB) }
            return nil
        }
        let runtime = FlowRuntimeService(executor: executor)
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)
        let runID1 = try await runtime.startRun(
            compiled: try await runtime.compile(fixture.graph),
            configuration: configuration)
        let result1 = await runtime.result(runID: runID1)
        let submissionsBefore = await executor.submissionCount()

        // Move every node and rename display names: pure display edits.
        var edited = fixture.graph
        for index in edited.nodes.indices {
            edited.nodes[index].position = .init(x: Double(index) * 50, y: 10)
            edited.nodes[index].name += " (moved)"
        }
        let compiled2 = try await runtime.compile(edited)
        let configuration2 = GraphFactory.makeConfiguration(
            identity: GraphFactory.makeIdentity(flowGraphID: configuration.identity.flowGraphID),
            configurationDigest: configuration.configurationDigest)
        let plan = try FlowRerunPlanner.plan(
            previous: result1!,
            previousGraph: fixture.graph,
            editedGraph: edited,
            editedCompiled: compiled2,
            configuration: configuration2)

        XCTAssertEqual(plan.changedNodeIDs, [])
        XCTAssertEqual(plan.invalidatedNodeIDs, [])
        XCTAssertEqual(plan.reusableNodeIDs, Set(edited.nodes.map(\.id)))

        let runID2 = try await runtime.startRun(
            compiled: compiled2, configuration: configuration2, seed: plan.seed)
        let result2 = await runtime.result(runID: runID2)
        XCTAssertEqual(result2?.runOutputs["a"], .string("branchA"))
        let totalAfter = await executor.submissionCount()
        XCTAssertEqual(totalAfter, submissionsBefore)
    }

    func testConfigurationDigestChangeInvalidatesExternalNodesOnly() async throws {
        let fixture = makeBranches()
        let native = GraphFactory.transform(
            name: "local", nativeKey: "noop",
            inputs: [("in", .string)], outputs: [("out", .string)])
        var graph = fixture.graph
        graph.nodes.append(native.node)
        graph.edges.append(GraphFactory.edge(
            from: fixture.extA.ports.first { $0.direction == .output }!, node: fixture.extA,
            to: native.inPorts[0], node: native.node))
        let outC = GraphFactory.output(inputs: [("in", .string)], resultKey: "c")
        graph.nodes.append(outC.node)
        graph.edges.append(GraphFactory.edge(
            from: native.outPorts[0], node: native.node,
            to: outC.inPorts[0], node: outC.node))

        let executor = TestStepExecutor { [extA = fixture.extA, extB = fixture.extB] nodeID in
            if nodeID == extA.id { return Self.outcomeForBranch(extA) }
            if nodeID == extB.id { return Self.outcomeForBranch(extB) }
            return nil
        }
        let runtime = FlowRuntimeService(executor: executor)
        let configuration = GraphFactory.makeConfiguration(identity: GraphFactory.makeIdentity())
        let runID1 = try await runtime.startRun(
            compiled: try await runtime.compile(graph), configuration: configuration)
        let result1 = await runtime.result(runID: runID1)

        let compiled2 = try await runtime.compile(graph)
        let configuration2 = GraphFactory.makeConfiguration(
            identity: GraphFactory.makeIdentity(flowGraphID: configuration.identity.flowGraphID),
            configurationDigest: "config-digest-v2")
        let plan = try FlowRerunPlanner.plan(
            previous: result1!,
            previousGraph: graph,
            editedGraph: graph,
            editedCompiled: compiled2,
            configuration: configuration2)

        // External nodes invalidated by the configuration change; the
        // dependent pure transform also invalidates because its input can change.
        XCTAssertTrue(plan.invalidatedNodeIDs.contains(fixture.extA.id))
        XCTAssertTrue(plan.invalidatedNodeIDs.contains(fixture.extB.id))
        XCTAssertTrue(plan.invalidatedNodeIDs.contains(native.node.id),
            "A pure step must refresh when its external upstream can change")
        XCTAssertFalse(plan.reusableNodeIDs.contains(native.node.id))
    }

    func testRunInputChangeInvalidatesBoundNodeAndDownstream() async throws {
        let prompt = GraphFactory.external(
            name: "prompt", inputs: [("prompt", .string)], outputs: [("out", .string)])
        let out = GraphFactory.output(inputs: [("in", .string)], resultKey: "text")
        let graph = FlowGraph(nodes: [prompt.node, out.node], edges: [
            GraphFactory.edge(from: prompt.outPorts[0], node: prompt.node,
                              to: out.inPorts[0], node: out.node),
        ])
        let executor = TestStepExecutor { _ in
            TestStepExecutor.ScriptedOutcome(status: .succeeded,
                                             outputs: ["out": .string("ok")])
        }
        let runtime = FlowRuntimeService(executor: executor)
        let identity1 = GraphFactory.makeIdentity()
        let config1 = GraphFactory.makeConfiguration(
            identity: identity1,
            runInputs: [.init(nodeID: prompt.node.id, portName: "prompt",
                              value: .string("first"))])
        let runID1 = try await runtime.startRun(
            compiled: try await runtime.compile(graph), configuration: config1)
        let result1 = await runtime.result(runID: runID1)
        let submissionsBefore = await executor.submissionCount()

        let config2 = GraphFactory.makeConfiguration(
            identity: GraphFactory.makeIdentity(flowGraphID: identity1.flowGraphID),
            runInputs: [.init(nodeID: prompt.node.id, portName: "prompt",
                              value: .string("second"))],
            configurationDigest: config1.configurationDigest)
        let compiled2 = try await runtime.compile(graph)
        let plan = try FlowRerunPlanner.plan(
            previous: result1!,
            previousGraph: graph,
            editedGraph: graph,
            editedCompiled: compiled2,
            configuration: config2)
        XCTAssertTrue(plan.changedNodeIDs.contains(prompt.node.id))
        XCTAssertTrue(plan.invalidatedNodeIDs.contains(prompt.node.id))
        XCTAssertTrue(plan.invalidatedNodeIDs.contains(out.node.id))

        let runID2 = try await runtime.startRun(
            compiled: compiled2, configuration: config2, seed: plan.seed)
        _ = await runtime.result(runID: runID2)
        let totalAfter = await executor.submissionCount()
        XCTAssertEqual(totalAfter, submissionsBefore + 1)
    }

    func testStaleResultDetection() async throws {
        let fixture = makeBranches()
        let executor = TestStepExecutor { [extA = fixture.extA, extB = fixture.extB] nodeID in
            if nodeID == extA.id { return Self.outcomeForBranch(extA) }
            if nodeID == extB.id { return Self.outcomeForBranch(extB) }
            return nil
        }
        let runtime = FlowRuntimeService(executor: executor)
        let identity = GraphFactory.makeIdentity(canvasRevision: 7)
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(fixture.graph),
            configuration: GraphFactory.makeConfiguration(identity: identity))
        let result = await runtime.result(runID: runID)
        XCTAssertEqual(result?.isStale(currentCanvasRevision: 7), false)
        XCTAssertEqual(result?.isStale(currentCanvasRevision: 8), true)
    }
}
