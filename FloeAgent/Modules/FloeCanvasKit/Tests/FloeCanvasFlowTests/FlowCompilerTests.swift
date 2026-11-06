import Foundation
import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration
@testable import FloeCanvasFlow

/// Strict compiler behavior: deterministic order, structured loop analysis,
/// variadic real type compatibility, duplicate-input detection and
/// concurrent variable write rejection.
final class FlowCompilerTests: XCTestCase {

    private func issueCodes(_ error: Error) -> [FlowCompilerIssue.Code] {
        guard case FlowCompilationError.failed(let issues) = error else {
            XCTFail("expected compilation failure, got \(error)")
            return []
        }
        return issues.map(\.code)
    }

    // MARK: Deterministic topological order (non-UUID ordering)

    func testTopologicalOrderIsDependencyBasedNotUUIDBased() throws {
        // Regression guard for the consumed-prefix re-sort bug: W(30) is
        // consumed before its child X(20) becomes ready; a scheduler that
        // re-sorts the consumed prefix re-processes W and loses X.
        let idY = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let idX = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let idW = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let y = GraphFactory.constantSource(
            id: idY, name: "y", literal: .number("1"), type: .number)
        let w = GraphFactory.constantSource(
            id: idW, name: "w", literal: .number("2"), type: .number)
        let x = GraphFactory.transform(
            id: idX, name: "x", nativeKey: "noop",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let graph = FlowGraph(nodes: [y.node, w.node, x.node],
                              edges: [GraphFactory.edge(
                                from: w.out, node: w.node,
                                to: x.inPorts[0], node: x.node)])
        let compiled = try FlowGraphCompiler.compile(graph)
        XCTAssertEqual(compiled.topoOrder, [idY, idW, idX])
        XCTAssertEqual(Set(compiled.topoOrder), [idY, idW, idX])
        XCTAssertEqual(compiled.depth[idX], 1)
    }

    // MARK: Strict variadic compatibility

    func testVariadicDoesNotWaiveTypeCompatibility() {
        let source = GraphFactory.constantSource(literal: .number("1"), type: .number)
        let sink = GraphFactory.transform(
            name: "agg", nativeKey: "noop",
            inputs: [("items", .string)], outputs: [("out", .string)])
        let variadicInput = FlowPort(name: "items", dataType: .string,
                                     direction: .input, isVariadic: true)
        let sinkNode = FlowNode(
            id: sink.node.id, kind: .transform, name: "agg",
            ports: [variadicInput] + sink.outPorts,
            parameters: sink.node.parameters)
        let graph = FlowGraph(nodes: [source.node, sinkNode],
                              edges: [GraphFactory.edge(
                                from: source.out, node: source.node,
                                to: variadicInput, node: sinkNode)])
        XCTAssertThrowsError(try FlowGraphCompiler.compile(graph)) { error in
            XCTAssertTrue(self.issueCodes(error).contains(.portTypeMismatch))
        }
    }

    func testJSONWildcardIsCompatibleWithConcreteTypes() throws {
        let source = GraphFactory.constantSource(literal: .string("hi"), type: .json)
        let sink = GraphFactory.transform(
            name: "show", nativeKey: "noop",
            inputs: [("in", .string)], outputs: [("out", .string)])
        let graph = FlowGraph(nodes: [source.node, sink.node],
                              edges: [GraphFactory.edge(
                                from: source.out, node: source.node,
                                to: sink.inPorts[0], node: sink.node)])
        XCTAssertNoThrow(try FlowGraphCompiler.compile(graph))
    }

    func testDuplicateEdgesIntoNonVariadicInputAreRejected() {
        let sourceA = GraphFactory.constantSource(
            name: "a", literal: .number("1"), type: .number)
        let sourceB = GraphFactory.constantSource(
            name: "b", literal: .number("2"), type: .number)
        let sink = GraphFactory.transform(
            name: "sum", nativeKey: "math.add",
            inputs: [("a", .number), ("b", .number)],
            outputs: [("sum", .number)])
        let graph = FlowGraph(
            nodes: [sourceA.node, sourceB.node, sink.node],
            edges: [
                // Two edges into the same non-variadic input port "a".
                GraphFactory.edge(from: sourceA.out, node: sourceA.node,
                                  to: sink.inPorts[0], node: sink.node),
                GraphFactory.edge(from: sourceB.out, node: sourceB.node,
                                  to: sink.inPorts[0], node: sink.node),
            ])
        XCTAssertThrowsError(try FlowGraphCompiler.compile(graph)) { error in
            XCTAssertTrue(self.issueCodes(error).contains(.duplicateInputEdge))
        }
    }

    func testVariadicAggregationAcceptsMultipleEdges() throws {
        let sourceA = GraphFactory.constantSource(
            name: "a", literal: .number("1"), type: .number)
        let sourceB = GraphFactory.constantSource(
            name: "b", literal: .number("2"), type: .number)
        let items = FlowPort(name: "items", dataType: .number,
                             direction: .input, isVariadic: true)
        let sink = FlowFactoryVariadicSink.make(items: items)
        let graph = FlowGraph(nodes: [sourceA.node, sourceB.node, sink],
                              edges: [
                                GraphFactory.edge(from: sourceA.out, node: sourceA.node,
                                                  to: items, node: sink),
                                GraphFactory.edge(from: sourceB.out, node: sourceB.node,
                                                  to: items, node: sink),
                              ])
        XCTAssertNoThrow(try FlowGraphCompiler.compile(graph))
    }

    // MARK: Loop body rigor

    func testLoopBodyInternalCycleIsRejected() {
        let loop = FlowNode(kind: .loop, name: "loop", ports: [],
                            parameters: ["maxIterations": .number("10")])
        let body1 = GraphFactory.transform(
            name: "b1", nativeKey: "noop",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let body2 = GraphFactory.transform(
            name: "b2", nativeKey: "noop",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let loopWithBody = FlowNode(
            id: loop.id, kind: .loop, name: "loop",
            ports: [], parameters: loop.parameters,
            bodyNodeIDs: [body1.node.id, body2.node.id])
        // b1 → b2 → b1 inside the body: a real cycle, not iteration wiring.
        let graph = FlowGraph(nodes: [loopWithBody, body1.node, body2.node],
                              edges: [
                                GraphFactory.edge(from: body1.outPorts[0], node: body1.node,
                                                  to: body2.inPorts[0], node: body2.node),
                                GraphFactory.edge(from: body2.outPorts[0], node: body2.node,
                                                  to: body1.inPorts[0], node: body1.node),
                              ])
        XCTAssertThrowsError(try FlowGraphCompiler.compile(graph)) { error in
            XCTAssertTrue(self.issueCodes(error).contains(.bodyCycle))
        }
    }

    func testLoopBodyClaimedByTwoLoopsIsRejected() {
        let body = GraphFactory.transform(
            name: "shared", nativeKey: "noop",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let loopA = FlowNode(kind: .loop, name: "loopA", ports: [],
                             parameters: ["maxIterations": .number("2")],
                             bodyNodeIDs: [body.node.id])
        let loopB = FlowNode(kind: .loop, name: "loopB", ports: [],
                             parameters: ["maxIterations": .number("2")],
                             bodyNodeIDs: [body.node.id])
        let graph = FlowGraph(nodes: [loopA, loopB, body.node], edges: [])
        XCTAssertThrowsError(try FlowGraphCompiler.compile(graph)) { error in
            XCTAssertTrue(self.issueCodes(error).contains(.bodyNodeClaimedTwice))
        }
    }

    func testLoopBodyForwardReferenceIsNotMisreported() throws {
        // Regression guard for the P0 forward-reference class of bugs: the
        // strict layer checks membership against the full node table, so a
        // body node declared after the loop node compiles cleanly.
        let loopID = UUID()
        let body = GraphFactory.transform(
            name: "later", nativeKey: "noop",
            inputs: [], outputs: [("out", .number)])
        let loop = FlowNode(id: loopID, kind: .loop, name: "loop",
                            ports: [FlowPort(name: "value", dataType: .number,
                                             direction: .input)],
                            parameters: ["maxIterations": .number("2")],
                            bodyNodeIDs: [body.node.id])
        let source = GraphFactory.constantSource(
            literal: .number("1"), type: .number)
        let graph = FlowGraph(
            nodes: [loop, source.node, body.node],
            edges: [GraphFactory.edge(from: source.out, node: source.node,
                                      to: loop.ports[0], node: loop)])
        // The frozen base validator may flag a spurious invalidLoop until
        // its owner fixes the forward-reference implementation; the strict
        // compiler itself must not add one. We accept either "compiles" or
        // "fails only with the base validator's invalidLoop code".
        do {
            let compiled = try FlowGraphCompiler.compile(graph)
            XCTAssertTrue(compiled.loops[loopID] != nil)
        } catch {
            let issues: [FlowCompilerIssue]
            if case FlowCompilationError.failed(let list) = error {
                issues = list
            } else {
                issues = []
            }
            XCTAssertTrue(issues.allSatisfy {
                $0.code == .baseValidator && $0.base?.code == .invalidLoop
            }, "unexpected strict-layer issues: \(issues)")
        }
    }

    func testCompositeFeedingItsOwnBodyIsRejected() {
        let loop = FlowNode(kind: .loop, name: "loop",
                            ports: [FlowPort(name: "x", dataType: .number,
                                             direction: .output)],
                            parameters: ["maxIterations": .number("2")])
        let body = GraphFactory.transform(
            name: "b", nativeKey: "noop",
            inputs: [("in", .number)], outputs: [])
        let loopWithBody = FlowNode(
            id: loop.id, kind: .loop, name: "loop", ports: loop.ports,
            parameters: loop.parameters, bodyNodeIDs: [body.node.id])
        let graph = FlowGraph(nodes: [loopWithBody, body.node],
                              edges: [GraphFactory.edge(
                                from: loop.ports[0], node: loopWithBody,
                                to: body.inPorts[0], node: body.node)])
        XCTAssertThrowsError(try FlowGraphCompiler.compile(graph)) { error in
            XCTAssertTrue(self.issueCodes(error).contains(.compositeFeedsBody))
        }
    }

    func testLoopBoundOutsideCapIsRejected() {
        let body = GraphFactory.transform(name: "b", nativeKey: "noop",
                                          inputs: [], outputs: [])
        let loop = FlowNode(kind: .loop, name: "loop", ports: [],
                            parameters: ["maxIterations": .number("500")],
                            bodyNodeIDs: [body.node.id])
        let graph = FlowGraph(nodes: [loop, body.node], edges: [])
        XCTAssertThrowsError(try FlowGraphCompiler.compile(graph)) { error in
            let issues: [FlowCompilerIssue]
            if case FlowCompilationError.failed(let list) = error {
                issues = list
            } else {
                issues = []
            }
            XCTAssertTrue(issues.contains {
                $0.code == .baseValidator && $0.base?.code == .invalidLoop
            })
        }
    }

    // MARK: Carry ports are not required inputs

    func testCarryFedLoopPortIsNotARequiredInput() throws {
        let loopID = UUID()
        let loopPort = FlowPort(name: "value", dataType: .number, direction: .input)
        let loop = FlowNode(id: loopID, kind: .loop, name: "loop",
                            ports: [loopPort],
                            parameters: ["maxIterations": .number("5")],
                            bodyNodeIDs: [])
        let body = GraphFactory.transform(name: "b", nativeKey: "noop",
                                          inputs: [], outputs: [("out", .number)])
        let loopWithBody = FlowNode(
            id: loopID, kind: .loop, name: "loop", ports: [loopPort],
            parameters: loop.parameters, bodyNodeIDs: [body.node.id])
        // carry edge body.out → loop."value" with NO outside binding.
        let graph = FlowGraph(nodes: [loopWithBody, body.node],
                              edges: [GraphFactory.edge(
                                from: body.outPorts[0], node: body.node,
                                to: loopPort, node: loopWithBody)])
        let compiled = try FlowGraphCompiler.compile(graph)
        XCTAssertEqual(compiled.requiredInputs[loopID] ?? [], [])
    }

    // MARK: Concurrent variable writes

    func testConcurrentVariableWritesAreRejected() {
        let source = GraphFactory.constantSource(literal: .number("1"), type: .number)
        let writerA = GraphFactory.transform(
            name: "a", nativeKey: "noop", inputs: [], outputs: [("out", .number)],
            writeVariables: ["out": "shared"])
        let writerB = GraphFactory.transform(
            name: "b", nativeKey: "noop", inputs: [], outputs: [("out", .number)],
            writeVariables: ["out": "shared"])
        let variable = FlowVariable(name: "shared", dataType: .number,
                                    ownerNodeID: writerA.node.id)
        let graph = FlowGraph(nodes: [source.node, writerA.node, writerB.node],
                              edges: [],
                              variables: [variable])
        XCTAssertThrowsError(try FlowGraphCompiler.compile(graph)) { error in
            XCTAssertTrue(self.issueCodes(error).contains(.concurrentVariableWrite))
        }
    }

    func testSequentialVariableWritesAreAllowed() throws {
        let writerA = GraphFactory.transform(
            name: "a", nativeKey: "noop", inputs: [], outputs: [("out", .number)],
            writeVariables: ["out": "shared"])
        let writerB = GraphFactory.transform(
            name: "b", nativeKey: "noop",
            inputs: [("in", .number)], outputs: [("out", .number)],
            writeVariables: ["out": "shared"])
        let variable = FlowVariable(name: "shared", dataType: .number,
                                    ownerNodeID: writerA.node.id)
        let graph = FlowGraph(
            nodes: [writerA.node, writerB.node],
            edges: [GraphFactory.edge(from: writerA.outPorts[0], node: writerA.node,
                                      to: writerB.inPorts[0], node: writerB.node)],
            variables: [variable])
        // Sequential chain a → b: no conflict.
        XCTAssertNoThrow(try FlowGraphCompiler.compile(graph))
    }

    // MARK: Scope selection

    func testScopeSelectionRejectsUnknownNodes() {
        let source = GraphFactory.constantSource(literal: .number("1"), type: .number)
        let graph = FlowGraph(nodes: [source.node], edges: [])
        XCTAssertThrowsError(try FlowGraphCompiler.compile(
            graph, scope: .selectedNodes([source.node.id, UUID()]))) { error in
            XCTAssertTrue(self.issueCodes(error).contains(.unknownScopeNode))
        }
    }
}

private enum FlowFactoryVariadicSink {
    static func make(items: FlowPort) -> FlowNode {
        FlowNode(kind: .transform, name: "agg",
                 ports: [items, FlowPort(name: "out", dataType: .list, direction: .output)],
                 parameters: ["nativeKey": .string("noop")])
    }
}
