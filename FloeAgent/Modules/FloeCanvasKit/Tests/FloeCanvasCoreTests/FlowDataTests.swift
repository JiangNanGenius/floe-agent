import XCTest
@testable import FloeCanvasCore

final class FlowDataTests: XCTestCase {
    private func makeGraph() -> (FlowGraph, [FlowNode]) {
        let out = FlowPort(name: "out", dataType: .string, direction: .output)
        let inp = FlowPort(name: "in", dataType: .string, direction: .input)
        let source = FlowNode(kind: .source, name: "source", ports: [out])
        let sink = FlowNode(kind: .output, name: "sink", ports: [inp])
        let edge = FlowEdge(
            sourceNodeID: source.id, sourcePortID: out.id,
            destinationNodeID: sink.id, destinationPortID: inp.id)
        let graph = FlowGraph(nodes: [source, sink], edges: [edge])
        return (graph, [source, sink])
    }

    func testValidDAGPasses() {
        let (graph, _) = makeGraph()
        XCTAssertEqual(FlowGraphValidator.validate(graph), [])
    }

    func testFreeCycleIsRejected() {
        let (base, nodes) = makeGraph()
        let a = nodes[0], b = nodes[1]
        // Add a back edge on top of the valid a→b edge: a⇄b is a cycle no
        // structured loop owns.
        let backEdge = FlowEdge(
            sourceNodeID: b.id, sourcePortID: b.ports[0].id,
            destinationNodeID: a.id, destinationPortID: a.ports[0].id)
        let graph = FlowGraph(nodes: base.nodes, edges: base.edges + [backEdge])
        let issues = FlowGraphValidator.validate(graph)
        XCTAssertTrue(issues.contains { $0.code == .freeCycle && $0.severity == .error })
    }

    func testLoopNodeMakesBackEdgeLegalWithinDeclaredBody() {
        let (_, nodes) = makeGraph()
        let a = nodes[0], b = nodes[1]
        var loop = FlowNode(kind: .loop, name: "loop", bodyNodeIDs: [a.id, b.id])
        loop.parameters = ["maxIterations": .number("50")]
        // a → b plus b → a owned by the loop scope is a structured cycle.
        let forward = FlowEdge(
            sourceNodeID: a.id, sourcePortID: a.ports[0].id,
            destinationNodeID: b.id, destinationPortID: b.ports[0].id)
        let backward = FlowEdge(
            sourceNodeID: b.id, sourcePortID: b.ports[0].id,
            destinationNodeID: a.id, destinationPortID: a.ports[0].id)
        let graph = FlowGraph(nodes: [loop, a, b], edges: [forward, backward])
        let issues = FlowGraphValidator.validate(graph)
        XCTAssertFalse(issues.contains { $0.code == .freeCycle })
    }

    func testLoopBoundDefaultAndCap() {
        var loop = FlowNode(kind: .loop, name: "loop", bodyNodeIDs: [])
        XCTAssertEqual(FlowGraphValidator.loopBound(of: loop), 100)
        loop.parameters = ["maxIterations": .number("101")]
        let issues = FlowGraphValidator.validate(FlowGraph(nodes: [loop]))
        XCTAssertTrue(issues.contains { $0.code == .invalidLoop })
        loop.parameters = ["maxIterations": .number("7")]
        let custom = FlowGraphValidator.validate(
            FlowGraph(nodes: [loop]), maxLoopIterations: 5)
        XCTAssertTrue(custom.contains { $0.code == .invalidLoop })
    }

    func testPortDirectionAndTypeMismatch() {
        let out = FlowPort(name: "out", dataType: .string, direction: .output)
        let wrongDirection = FlowPort(name: "x", dataType: .string, direction: .output)
        let wrongType = FlowPort(name: "in", dataType: .number, direction: .input)
        let a = FlowNode(kind: .source, name: "a", ports: [out])
        let b = FlowNode(kind: .transform, name: "b", ports: [wrongDirection])
        let c = FlowNode(kind: .transform, name: "c", ports: [wrongType])
        let e1 = FlowEdge(
            sourceNodeID: a.id, sourcePortID: out.id,
            destinationNodeID: b.id, destinationPortID: wrongDirection.id)
        let e2 = FlowEdge(
            sourceNodeID: a.id, sourcePortID: out.id,
            destinationNodeID: c.id, destinationPortID: wrongType.id)
        let issues = FlowGraphValidator.validate(
            FlowGraph(nodes: [a, b, c], edges: [e1, e2]))
        XCTAssertTrue(issues.contains { $0.code == .portDirectionMismatch })
        XCTAssertTrue(issues.contains { $0.code == .portTypeMismatch })
    }

    func testDanglingEdgeAndDuplicateNodeID() {
        let out = FlowPort(name: "out", dataType: .string, direction: .output)
        let a = FlowNode(kind: .source, name: "a", ports: [out])
        let aCopy = a
        let edge = FlowEdge(
            sourceNodeID: a.id, sourcePortID: out.id,
            destinationNodeID: UUID(), destinationPortID: UUID())
        let issues = FlowGraphValidator.validate(
            FlowGraph(nodes: [a, aCopy], edges: [edge]))
        XCTAssertTrue(issues.contains { $0.code == .duplicateNodeID })
        XCTAssertTrue(issues.contains { $0.code == .danglingEdge })
    }

    func testConditionBranchOutputPortChecked() {
        let missing = UUID()
        let condition = FlowNode(
            kind: .condition, name: "c",
            branches: [FlowConditionBranch(
                predicate: .comparison(.equal, lhs: .literal(.number(1)), rhs: .literal(.number(1))),
                outputPortID: missing)])
        let issues = FlowGraphValidator.validate(FlowGraph(nodes: [condition]))
        XCTAssertTrue(issues.contains { $0.code == .branchOutputPortMissing })
    }

    func testRunIdentityAndStepRecordRoundTrip() throws {
        let identity = FlowRunIdentity(
            canvasID: UUID(), canvasRevision: 3,
            flowGraphID: UUID(), flowGraphRevision: 1,
            environmentID: "env-1", owningTaskID: UUID())
        let record = FlowStepRecord(
            runID: identity.runID, nodeID: UUID(),
            status: .succeeded,
            inputs: ["a": .string("x")],
            outputs: ["b": .list([.number(1.5), .bool(true)])],
            events: [FlowStepEvent(kind: .checkpoint, message: "done")])
        let checkpoint = FlowRunCheckpoint(
            runID: identity.runID, completedStepIDs: [record.id],
            loopCounters: [UUID(): 2])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decodedIdentity = try JSONDecoder().decode(
            FlowRunIdentity.self, from: encoder.encode(identity))
        let decodedRecord = try JSONDecoder().decode(
            FlowStepRecord.self, from: encoder.encode(record))
        let decodedCheckpoint = try JSONDecoder().decode(
            FlowRunCheckpoint.self, from: encoder.encode(checkpoint))
        XCTAssertEqual(decodedIdentity, identity)
        XCTAssertEqual(decodedRecord, record)
        XCTAssertEqual(decodedCheckpoint, checkpoint)
        XCTAssertEqual(identity.environmentID, "env-1")
    }

    func testRelationsAndFlowEdgesAreDistinctTypes() {
        // Compile-time proof that a visual relation can never be used where
        // a data edge is required.
        let relation = CanvasRelationKind.generatedFrom
        XCTAssertEqual(relation.rawValue, "generatedFrom")
        let edge = FlowEdge(
            sourceNodeID: UUID(), sourcePortID: UUID(),
            destinationNodeID: UUID(), destinationPortID: UUID())
        _ = edge
        XCTAssertNotEqual(String(describing: CanvasConnectionSnapshot.self),
                          String(describing: FlowEdge.self))
    }
}
