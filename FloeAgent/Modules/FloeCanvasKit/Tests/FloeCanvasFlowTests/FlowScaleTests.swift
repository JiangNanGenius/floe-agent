import Foundation
import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration
@testable import FloeCanvasFlow

/// Scale checks for the compiler and the deterministic scheduler using
/// thousands of lightweight local nodes. These prove order-of-magnitude
/// behavior of compilation + scheduling only — they are NOT real provider,
/// device or UI performance evidence.
final class FlowScaleTests: XCTestCase {

    /// Linear chain of `count` native steps: const → t1 → … → tN → output.
    private func chainGraph(count: Int) -> FlowGraph {
        let source = GraphFactory.constantSource(literal: .number("0"), type: .number)
        var nodes: [FlowNode] = [source.node]
        var edges: [FlowEdge] = []
        var previous: (FlowNode, FlowPort) = (source.node, source.out)
        for index in 0..<count {
            let step = GraphFactory.transform(
                name: "t\(index)", nativeKey: "noop",
                inputs: [("in", .number)], outputs: [("out", .number)])
            nodes.append(step.node)
            edges.append(GraphFactory.edge(
                from: previous.1, node: previous.0,
                to: step.inPorts[0], node: step.node))
            previous = (step.node, step.outPorts[0])
        }
        let out = GraphFactory.output(inputs: [("in", .number)], resultKey: "final")
        nodes.append(out.node)
        edges.append(GraphFactory.edge(
            from: previous.1, node: previous.0,
            to: out.inPorts[0], node: out.node))
        return FlowGraph(nodes: nodes, edges: edges)
    }

    private func runChain(count: Int, timeLimit: TimeInterval) async throws -> TimeInterval {
        let graph = chainGraph(count: count)
        var registry = FlowNativeStepRegistry()
        registry.register("noop") { _ in ["out": .json(.null)] }
        let runtime = FlowRuntimeService(executor: nil, nativeRegistry: registry)

        let compileStart = Date()
        let compiled = try await runtime.compile(graph)
        let compileTime = Date().timeIntervalSince(compileStart)

        let identity = GraphFactory.makeIdentity()
        let runStart = Date()
        let runID = try await runtime.startRun(
            compiled: compiled,
            configuration: GraphFactory.makeConfiguration(identity: identity))
        let runTime = Date().timeIntervalSince(runStart)

        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .completed)
        XCTAssertLessThan(compileTime, timeLimit,
                          "compile of \(count) nodes took \(compileTime)s")
        XCTAssertLessThan(runTime, timeLimit,
                          "schedule of \(count) nodes took \(runTime)s")
        return compileTime + runTime
    }

    func testChain3000() async throws {
        _ = try await runChain(count: 3_000, timeLimit: 30)
    }

    func testChain10000() async throws {
        _ = try await runChain(count: 10_000, timeLimit: 60)
    }

    /// Diamond fan-out/fan-in at scale exercises the dependent fan-out queue.
    private func diamondGraph(layers: Int) -> FlowGraph {
        let source = GraphFactory.constantSource(literal: .number("1"), type: .number)
        var nodes: [FlowNode] = [source.node]
        var edges: [FlowEdge] = []
        var layer: [(FlowNode, FlowPort)] = [(source.node, source.out)]
        for index in 0..<layers {
            var next: [(FlowNode, FlowPort)] = []
            for (nodeIndex, previous) in layer.enumerated() {
                for fork in 0..<2 {
                    let step = GraphFactory.transform(
                        name: "l\(index)n\(nodeIndex)f\(fork)", nativeKey: "noop",
                        inputs: [("in", .number)], outputs: [("out", .number)])
                    nodes.append(step.node)
                    edges.append(GraphFactory.edge(
                        from: previous.1, node: previous.0,
                        to: step.inPorts[0], node: step.node))
                    next.append((step.node, step.outPorts[0]))
                }
            }
            layer = next
        }
        let outInput = FlowPort(name: "in", dataType: .number,
                                direction: .input, isVariadic: true)
        let out = FlowNode(kind: .output, name: "out", ports: [outInput])
        nodes.append(out)
        for previous in layer {
            edges.append(GraphFactory.edge(
                from: previous.1, node: previous.0,
                to: outInput, node: out))
        }
        return FlowGraph(nodes: nodes, edges: edges)
    }

    func testDiamondLayers7UnderLimit() async throws {
        let graph = diamondGraph(layers: 7) // 254 steps + source + output
        var registry = FlowNativeStepRegistry()
        registry.register("noop") { _ in ["out": .json(.null)] }
        let runtime = FlowRuntimeService(executor: nil, nativeRegistry: registry)
        let start = Date()
        let compiled = try await runtime.compile(graph)
        let runID = try await runtime.startRun(
            compiled: compiled,
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity()))
        let elapsed = Date().timeIntervalSince(start)
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .completed)
        XCTAssertLessThan(elapsed, 30, "diamond schedule took \(elapsed)s")
    }
}
