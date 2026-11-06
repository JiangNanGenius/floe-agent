import XCTest
import FloeCanvasCore
import FloeDiagramCore
@testable import FloeCanvasLayout

final class FlowEdgeLayoutTests: XCTestCase {
    private func makeFlowNode(
        id: UUID,
        position: CanvasGeometry.Point = .zero,
        ports: [FlowPort]
    ) -> FlowNode {
        FlowNode(id: id, kind: .transform, name: id.uuidString, ports: ports, position: position)
    }

    private func makePort(
        id: UUID,
        name: String,
        type: FlowValueType = .string,
        direction: FlowPortDirection,
        variadic: Bool = false
    ) -> FlowPort {
        FlowPort(id: id, name: name, dataType: type, direction: direction, isVariadic: variadic)
    }

    func testDefaultFrameComesFromPositionWithoutBinding() {
        let node = makeFlowNode(
            id: UUID(),
            position: .init(x: 300, y: 200),
            ports: [])
        let frame = CanvasFlowEdgeLayout.defaultFrame(for: node)
        XCTAssertEqual(frame, DiagramRect(x: 200, y: 150, width: 200, height: 100))
    }

    func testAnchorsFollowDeclarationOrderNotUUIDOrder() throws {
        // Declared order is semantic: inB first (top row), inA second.
        let inB = makePort(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!,
            name: "inB", direction: .input)
        let inA = makePort(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "inA", direction: .input)
        let node = makeFlowNode(id: UUID(), ports: [inB, inA])
        let frame = DiagramRect(x: 0, y: 0, width: 200, height: 100)
        let anchors = CanvasFlowEdgeLayout.anchors(
            for: FlowGraph(nodes: [node]), nodeFrames: [node.id: frame])
        let nodeAnchors = try XCTUnwrap(anchors[node.id])
        XCTAssertEqual(nodeAnchors.count, 2)
        // First declared input sits at the top row (15% of height), NOT
        // sorted to the smallest UUID.
        XCTAssertEqual(nodeAnchors[0].id, inB.id)
        XCTAssertEqual(nodeAnchors[0].position.y, 15, accuracy: 1e-9)
        XCTAssertEqual(nodeAnchors[1].id, inA.id)
        XCTAssertEqual(nodeAnchors[1].position.y, 85, accuracy: 1e-9)
        XCTAssertEqual(nodeAnchors[0].outward, .leading)
    }

    func testRouteEdgesAttachExactDeclaredPortsNotRectMidpoints() throws {
        let o1 = makePort(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
            name: "o1", direction: .output)
        let o2 = makePort(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
            name: "o2", direction: .output)
        let i1 = makePort(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
            name: "i1", direction: .input)
        let i2 = makePort(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!,
            name: "i2", direction: .input)
        let f1 = makeFlowNode(id: UUID(), ports: [o1, o2])
        let f2 = makeFlowNode(id: UUID(), ports: [i1, i2])
        // Crossed pairing: first output → second input.
        let edge = FlowEdge(
            sourceNodeID: f1.id, sourcePortID: o1.id,
            destinationNodeID: f2.id, destinationPortID: i2.id)
        let graph = FlowGraph(nodes: [f1, f2], edges: [edge])
        let frames: [UUID: DiagramRect] = [
            f1.id: DiagramRect(x: -400, y: -50, width: 200, height: 100),
            f2.id: DiagramRect(x: 200, y: -50, width: 200, height: 100),
        ]
        let (routed, issues, hidden) = try CanvasFlowEdgeLayout.routeEdges(
            flowGraph: graph, nodeFrames: frames)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(hidden, 0)
        XCTAssertEqual(routed.count, 1)
        let geometry = routed[0].geometry
        // o1 declared first → top output row (y = -50 + 0.15*100 = -35).
        XCTAssertEqual(geometry.start.x, -200, accuracy: 1e-9)
        XCTAssertEqual(geometry.start.y, -35, accuracy: 1e-9)
        // i2 declared second → bottom input row (y = -50 + 0.85*100 = 35).
        XCTAssertEqual(geometry.end.y, 35, accuracy: 1e-9)
        XCTAssertEqual(geometry.end.x, 200, accuracy: 1e-9)
        // Control points extend horizontally outward from the exact ports
        // (curve reach 0.45 × 400pt = 180pt), preserving the router's shape
        // while re-anchoring endpoints.
        guard case .cubic(let control1, let control2, _)? = geometry.segments.first else {
            XCTFail("expected cubic curve segment")
            return
        }
        XCTAssertEqual(control1.x, -20, accuracy: 1e-6)
        XCTAssertEqual(control1.y, geometry.start.y, accuracy: 1e-9)
        XCTAssertEqual(control2.x, 20, accuracy: 1e-6)
        XCTAssertEqual(control2.y, geometry.end.y, accuracy: 1e-9)
        XCTAssertFalse(geometry.routingFailed)
    }

    func testDirectionAndTypeViolationsAreDiagnosedNotRouted() throws {
        let inputA = makePort(
            id: UUID(), name: "in", direction: .input)
        let inputB = makePort(
            id: UUID(), name: "in2", direction: .input)
        let outString = makePort(
            id: UUID(), name: "out", type: .string, direction: .output)
        let inNumber = makePort(
            id: UUID(), name: "inNum", type: .number, direction: .input)
        let a = makeFlowNode(id: UUID(), ports: [inputA, outString])
        let b = makeFlowNode(id: UUID(), ports: [inputB, inNumber])
        let badDirection = FlowEdge(
            sourceNodeID: a.id, sourcePortID: inputA.id,
            destinationNodeID: b.id, destinationPortID: inputB.id)
        let badType = FlowEdge(
            sourceNodeID: a.id, sourcePortID: outString.id,
            destinationNodeID: b.id, destinationPortID: inNumber.id)
        let graph = FlowGraph(nodes: [a, b], edges: [badDirection, badType])
        let frames: [UUID: DiagramRect] = [
            a.id: DiagramRect(x: 0, y: 0, width: 200, height: 100),
            b.id: DiagramRect(x: 400, y: 0, width: 200, height: 100),
        ]
        let (routed, issues, _) = try CanvasFlowEdgeLayout.routeEdges(
            flowGraph: graph, nodeFrames: frames)
        XCTAssertTrue(routed.isEmpty)
        XCTAssertEqual(Set(issues.map(\.code)), [.flowPortDirectionMismatch, .flowPortTypeMismatch])
    }

    func testVariadicPortsStillDiagnoseMixedTypes() throws {
        // Variadic accepts MANY edges, not ANY type: layout diagnoses the
        // mismatch (the Flow compiler remains the execution authority).
        let out = makePort(id: UUID(), name: "out", type: .string, direction: .output)
        let aggregate = makePort(
            id: UUID(), name: "agg", type: .number, direction: .input, variadic: true)
        let a = makeFlowNode(id: UUID(), ports: [out])
        let b = makeFlowNode(id: UUID(), ports: [aggregate])
        let edge = FlowEdge(
            sourceNodeID: a.id, sourcePortID: out.id,
            destinationNodeID: b.id, destinationPortID: aggregate.id)
        let graph = FlowGraph(nodes: [a, b], edges: [edge])
        let (routed, issues, _) = try CanvasFlowEdgeLayout.routeEdges(
            flowGraph: graph,
            nodeFrames: [
                a.id: DiagramRect(x: 0, y: 0, width: 200, height: 100),
                b.id: DiagramRect(x: 400, y: 0, width: 200, height: 100),
            ])
        XCTAssertTrue(routed.isEmpty)
        XCTAssertEqual(issues.map(\.code), [.flowPortTypeMismatch])
    }

    func testMatchingTypesRouteCleanly() throws {
        let out = makePort(id: UUID(), name: "out", type: .string, direction: .output)
        let input = makePort(id: UUID(), name: "in", type: .string, direction: .input)
        let a = makeFlowNode(id: UUID(), ports: [out])
        let b = makeFlowNode(id: UUID(), ports: [input])
        let edge = FlowEdge(
            sourceNodeID: a.id, sourcePortID: out.id,
            destinationNodeID: b.id, destinationPortID: input.id)
        let graph = FlowGraph(nodes: [a, b], edges: [edge])
        let (routed, issues, _) = try CanvasFlowEdgeLayout.routeEdges(
            flowGraph: graph,
            nodeFrames: [
                a.id: DiagramRect(x: 0, y: 0, width: 200, height: 100),
                b.id: DiagramRect(x: 400, y: 0, width: 200, height: 100),
            ])
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(routed.count, 1)
    }

    func testDuplicateNodeEdgeAndPortIDsFailGracefully() throws {
        let sharedID = UUID()
        let portDup = makePort(id: sharedID, name: "p1", direction: .input)
        let portTwin = makePort(id: sharedID, name: "p2", direction: .output)
        let a = makeFlowNode(id: sharedID, ports: [portDup, portTwin])
        let twin = makeFlowNode(id: sharedID, ports: [])
        let out = makePort(id: UUID(), name: "out", direction: .output)
        let b = makeFlowNode(id: UUID(), ports: [out])
        let edgeID = UUID()
        let e1 = FlowEdge(
            id: edgeID,
            sourceNodeID: b.id, sourcePortID: out.id,
            destinationNodeID: a.id, destinationPortID: sharedID)
        let e2 = FlowEdge(
            id: edgeID,
            sourceNodeID: b.id, sourcePortID: out.id,
            destinationNodeID: a.id, destinationPortID: sharedID)
        let graph = FlowGraph(nodes: [a, twin, b], edges: [e1, e2])
        let (routed, issues, _) = try CanvasFlowEdgeLayout.routeEdges(
            flowGraph: graph,
            nodeFrames: [
                a.id: DiagramRect(x: 400, y: 0, width: 200, height: 100),
                b.id: DiagramRect(x: 0, y: 0, width: 200, height: 100),
            ])
        XCTAssertEqual(Set(issues.map(\.code)), [
            .duplicateFlowNodeID, .duplicateFlowPortID, .duplicateFlowEdgeID])
        // The first port occurrence wins: input port accepted, edge routes.
        XCTAssertEqual(routed.count, 1)
    }

    func testBindingReaderReadsFixedMetadataKeysOnly() {
        let graphID = UUID()
        let nodeID = UUID()
        let card = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("card"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 0, y: 0),
                size: .init(width: 200, height: 100)),
            metadata: [
                CanvasFlowCardBindingKeys.graphID: graphID.uuidString,
                CanvasFlowCardBindingKeys.nodeID: nodeID.uuidString,
            ])
        let notACard = CanvasNodeSnapshot(
            content: .text("plain"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 0, y: 0),
                size: .init(width: 100, height: 100)),
            metadata: [CanvasFlowCardBindingKeys.graphID: graphID.uuidString])
        let bindings = CanvasFlowCardBindingReader.bindings(from: [card, notACard])
        XCTAssertEqual(bindings, [.init(graphID: graphID, nodeID: nodeID, cardNodeID: card.id)])
    }

    func testBoundCardSuppliesDisplayFrameAndCollapseProxyPreservesIdentity() throws {
        let region = makeRegion(
            center: .init(x: 0, y: 0),
            size: .init(width: 600, height: 600),
            collapsed: true)
        let graphID = UUID()
        let flowNodeID = UUID()
        let boundCard = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("card"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 0, y: 0),
                size: .init(width: 200, height: 100)),
            metadata: [
                CanvasFlowCardBindingKeys.graphID: graphID.uuidString,
                CanvasFlowCardBindingKeys.nodeID: flowNodeID.uuidString,
            ])
        let freeNode = makeNode(center: .init(x: 2000, y: 0))
        let page = CanvasPageSnapshot(
            nodes: [boundCard, freeNode],
            regions: [region])

        let outPort = makePort(id: UUID(), name: "out", direction: .output)
        let inPort = makePort(id: UUID(), name: "in", direction: .input)
        let boundFlow = makeFlowNode(id: flowNodeID, ports: [outPort])
        let freeFlow = makeFlowNode(
            id: UUID(), position: .init(x: 2000, y: 0), ports: [inPort])
        let graph = FlowGraph(
            id: graphID,
            nodes: [boundFlow, freeFlow],
            edges: [FlowEdge(
                sourceNodeID: boundFlow.id, sourcePortID: outPort.id,
                destinationNodeID: freeFlow.id, destinationPortID: inPort.id)])

        let index = try CanvasPageLayoutIndex(page: page, flowGraph: graph)
        XCTAssertEqual(index.flowCardBindings.count, 1)
        // The collapsed bound card displays through the region chip.
        XCTAssertEqual(index.flowDisplayRepresentatives[flowNodeID], region.id)
        XCTAssertEqual(index.flowDisplayFrames[flowNodeID], DiagramRect(
            x: -300, y: -300, width: 600, height: 600))
        // The unbound flow node falls back to its position default frame.
        XCTAssertEqual(
            index.flowDisplayFrames[freeFlow.id],
            CanvasFlowEdgeLayout.defaultFrame(for: freeFlow))

        let (routed, issues, hidden) = try CanvasFlowEdgeLayout.routeEdges(
            flowGraph: graph,
            nodeFrames: index.flowDisplayFrames,
            representatives: index.flowDisplayRepresentatives,
            endpointFrames: index.regionFrames)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(hidden, 0)
        XCTAssertEqual(routed.count, 1)
        let edge = routed[0]
        XCTAssertTrue(edge.isProxy)
        // Real identity survives the proxy.
        XCTAssertEqual(edge.sourceNodeID, flowNodeID)
        XCTAssertEqual(edge.destinationNodeID, freeFlow.id)
        XCTAssertEqual(edge.sourcePortID, outPort.id)
        XCTAssertEqual(edge.destinationPortID, inPort.id)
        // Display start attaches at the chip boundary (right side, facing the
        // free node), not at the hidden card port.
        XCTAssertEqual(edge.geometry.start.x, 300, accuracy: 1e-9)
        XCTAssertEqual(edge.geometry.start.y, 0, accuracy: 1e-9)
    }

    func testBothEndpointsCollapsedToSameChipHidesDisplayEdgeOnly() throws {
        let region = makeRegion(
            center: .init(x: 0, y: 0),
            size: .init(width: 600, height: 600),
            collapsed: true)
        let graphID = UUID()
        let cardA = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("A"),
            frame: CanvasGeometry.Frame(
                center: .init(x: -100, y: -100),
                size: .init(width: 200, height: 100)),
            metadata: [
                CanvasFlowCardBindingKeys.graphID: graphID.uuidString,
                CanvasFlowCardBindingKeys.nodeID: "00000000-0000-0000-0000-0000000000E1",
            ])
        let cardB = CanvasNodeSnapshot(
            kind: .generationTask,
            content: .text("B"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 100, y: 100),
                size: .init(width: 200, height: 100)),
            metadata: [
                CanvasFlowCardBindingKeys.graphID: graphID.uuidString,
                CanvasFlowCardBindingKeys.nodeID: "00000000-0000-0000-0000-0000000000E2",
            ])
        let page = CanvasPageSnapshot(nodes: [cardA, cardB], regions: [region])
        let outA = makePort(
            id: UUID(), name: "outA",
            direction: .output)
        let inB = makePort(
            id: UUID(), name: "inB",
            direction: .input)
        let flowA = makeFlowNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!, ports: [outA])
        let flowB = makeFlowNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!, ports: [inB])
        let graph = FlowGraph(
            id: graphID,
            nodes: [flowA, flowB],
            edges: [FlowEdge(
                sourceNodeID: flowA.id, sourcePortID: outA.id,
                destinationNodeID: flowB.id, destinationPortID: inB.id)])
        let index = try CanvasPageLayoutIndex(page: page, flowGraph: graph)
        let (_, _, hidden) = try CanvasFlowEdgeLayout.routeEdges(
            flowGraph: graph,
            nodeFrames: index.flowDisplayFrames,
            representatives: index.flowDisplayRepresentatives,
            endpointFrames: index.regionFrames)
        // Display-internal under full collapse; identity untouched (nothing
        // about the run or the edge record changed).
        XCTAssertEqual(hidden, 1)
    }

    func testPortHitTestUsesConstantScreenTarget() throws {
        let port = makePort(id: UUID(), name: "out", direction: .output)
        let node = makeFlowNode(id: UUID(), ports: [port])
        let frame = DiagramRect(x: 0, y: 0, width: 200, height: 100)
        let anchors = CanvasFlowEdgeLayout.anchors(
            for: FlowGraph(nodes: [node]), nodeFrames: [node.id: frame])
        let anchor = anchors[node.id]![0]
        // 16pt side at zoom 1 → ±8 around the port (200, 50).
        XCTAssertNotNil(CanvasFlowEdgeLayout.hitTestPort(
            [anchor], point: .init(x: 207, y: 50), zoom: 1))
        XCTAssertNil(CanvasFlowEdgeLayout.hitTestPort(
            [anchor], point: .init(x: 209, y: 50), zoom: 1))
        // At zoom 2 the same screen offset is half the world distance:
        // ±8pt screen is ±4 world, so 3.5 hits and 4.5 misses.
        XCTAssertNotNil(CanvasFlowEdgeLayout.hitTestPort(
            [anchor], point: .init(x: 203.5, y: 50), zoom: 2))
        XCTAssertNil(CanvasFlowEdgeLayout.hitTestPort(
            [anchor], point: .init(x: 204.5, y: 50), zoom: 2))
    }
}
