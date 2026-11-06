import XCTest
import FloeCanvasCore
import FloeDiagramCore
@testable import FloeCanvasLayout

final class EdgeRoutingTests: XCTestCase {
    func testArrowRelationRoutesBetweenAutomaticAnchors() throws {
        let a = makeNode(center: .init(x: -300, y: 0))
        let b = makeNode(center: .init(x: 300, y: 0))
        let connection = makeConnection(from: a.id, to: b.id, kind: .arrow, label: "rel")
        let page = CanvasPageSnapshot(nodes: [a, b], connections: [connection])
        let index = try CanvasPageLayoutIndex(page: page)
        let routed = try CanvasEdgeRouter.routeRelationEdges(index: index)
        XCTAssertEqual(routed.count, 1)
        let edge = routed[0]
        XCTAssertEqual(edge.id, connection.id)
        XCTAssertEqual(edge.kind, .arrow)
        XCTAssertEqual(edge.label, "rel")
        XCTAssertFalse(edge.isProxy)
        XCTAssertEqual(edge.geometry.start.x, -250, accuracy: 1e-9)
        XCTAssertEqual(edge.geometry.end.x, 250, accuracy: 1e-9)
        XCTAssertEqual(edge.geometry.endArrow, true)
        XCTAssertFalse(edge.geometry.routingFailed)
    }

    func testLineRelationRoutesStraightSegment() throws {
        let a = makeNode(center: .init(x: 0, y: 0))
        let b = makeNode(center: .init(x: 400, y: 0))
        let connection = makeConnection(from: a.id, to: b.id, kind: .line)
        let page = CanvasPageSnapshot(nodes: [a, b], connections: [connection])
        let index = try CanvasPageLayoutIndex(page: page)
        let routed = try CanvasEdgeRouter.routeRelationEdges(index: index)
        XCTAssertEqual(routed[0].geometry.segments, [.line(.init(x: 350, y: 0))])
    }

    func testProxyEdgeRoutesToVisibleCollapsedChip() throws {
        let region = makeRegion(
            center: .init(x: 0, y: 0),
            size: .init(width: 400, height: 400),
            collapsed: true)
        let member = makeNode(center: .init(x: 0, y: 0))
        let outside = makeNode(center: .init(x: 1000, y: 0))
        let connection = makeConnection(from: member.id, to: outside.id, kind: .arrow)
        let page = CanvasPageSnapshot(
            nodes: [member, outside],
            connections: [connection],
            regions: [region])
        let index = try CanvasPageLayoutIndex(page: page)
        let routed = try CanvasEdgeRouter.routeRelationEdges(index: index)
        XCTAssertEqual(routed.count, 1)
        XCTAssertTrue(routed[0].isProxy)
        XCTAssertEqual(routed[0].geometry.start.x, 200, accuracy: 1e-9)
        XCTAssertEqual(routed[0].geometry.end.x, 950, accuracy: 1e-9)
    }

    func testVisibleEdgesFiltersByViewportWithOverscan() throws {
        var nodes: [CanvasNodeSnapshot] = []
        var connections: [CanvasConnectionSnapshot] = []
        var previous: UUID?
        for index in 0..<4 {
            let node = makeNode(center: .init(x: Double(index) * 1000, y: 0))
            nodes.append(node)
            if let previous {
                connections.append(makeConnection(from: previous, to: node.id))
            }
            previous = node.id
        }
        let page = CanvasPageSnapshot(nodes: nodes, connections: connections)
        let index = try CanvasPageLayoutIndex(page: page)
        let routed = try CanvasEdgeRouter.routeRelationEdges(index: index)
        XCTAssertEqual(routed.count, 3)
        // Viewport over the first gap only: only the first edge is visible.
        let visible = CanvasEdgeRouter.visibleEdges(
            routed,
            in: DiagramRect(x: -100, y: -60, width: 700, height: 120),
            overscan: 0)
        XCTAssertEqual(visible.map(\.id), [connections[0].id])
        // Overscan participates: the second edge spans x 1050...1950, so a
        // 500pt overscan reaches it while the third edge stays out.
        let wide = CanvasEdgeRouter.visibleEdges(
            routed,
            in: DiagramRect(x: -100, y: -60, width: 700, height: 120),
            overscan: 500)
        XCTAssertEqual(Set(wide.map(\.id)), Set(connections[0...1].map(\.id)))
    }

    func testRoutingHonoursCancellation() async throws {
        let fixture = makeGridPage(count: 2000, connections: true)
        let index = try CanvasPageLayoutIndex(page: fixture.page)
        let task = Task {
            try CanvasEdgeRouter.routeRelationEdges(index: index)
        }
        task.cancel()
        await XCTAssertThrowsErrorAsync({ try await task.value }) { error in
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
