#if canImport(UIKit)
import XCTest
@testable import FloeCanvasUI
import FloeCanvasCore
import FloeCanvasLayout
import FloeDiagramCore

final class CanvasPresentationIndexTests: XCTestCase {
    func testConnectorCrossingViewportRemainsVisibleWithOffscreenEndpoints() throws {
        let left = CanvasNodeSnapshot(content: .text("left"), frame: .init(
            center: .init(x: -1000, y: 0), size: .init(width: 200, height: 100)))
        let right = CanvasNodeSnapshot(content: .text("right"), frame: .init(
            center: .init(x: 1000, y: 0), size: .init(width: 200, height: 100)))
        let connection = CanvasConnectionSnapshot(sourceNodeID: left.id, destinationNodeID: right.id)
        let layout = try CanvasPageLayoutIndex(page: .init(
            name: "Crossing", nodes: [left, right], connections: [connection]))
        let edges = try CanvasEdgeRouter.routeRelationEdges(index: layout)
        let presentation = CanvasPresentationIndex(layout: layout, relations: edges)
        XCTAssertEqual(presentation.relationEdges(in: .init(x: -50, y: -50, width: 100, height: 100))
            .map(\.id), [connection.id])
        XCTAssertTrue(presentation.relationEdges(in: .init(x: 5000, y: 5000, width: 100, height: 100)).isEmpty)
        XCTAssertTrue(presentation.relationEdges(in: .init(x: .infinity, y: 0, width: 100, height: 100)).isEmpty)
    }

    func testFoldedFlowCardDoesNotExposePortsBehindItsRegion() throws {
        let step = FlowNode(kind: .transform, name: "Hidden", ports: [
            FlowPort(name: "out", dataType: .string, direction: .output)])
        let graph = FlowGraph(nodes: [step])
        var metadata: [String: String] = [:]
        CanvasFlowCardBinding(graphID: graph.id, nodeID: step.id).applied(to: &metadata)
        let card = CanvasNodeSnapshot(kind: .generationTask, content: .text("step"),
            frame: .init(center: .zero, size: .init(width: 200, height: 100)), metadata: metadata)
        let region = CanvasRegionRecord(name: "Folded", frame: .init(
            center: .zero, size: .init(width: 600, height: 400)), isCollapsed: true)
        let page = CanvasPageSnapshot(name: "P", nodes: [card], regions: [region], flowGraphs: [graph])
        let layout = try CanvasPageLayoutIndex(page: page, flowGraph: graph)
        let presentation = CanvasPresentationIndex(layout: layout)
        XCTAssertTrue(presentation.portAnchors(in: .init(x: -1000, y: -1000, width: 2000, height: 2000)).isEmpty)
        var expanded = page
        expanded.regions[0].isCollapsed = false
        let expandedLayout = try CanvasPageLayoutIndex(page: expanded, flowGraph: graph)
        XCTAssertEqual(CanvasPresentationIndex(layout: expandedLayout)
            .portAnchors(in: .init(x: -200, y: -100, width: 400, height: 200)).map(\.id),
            step.ports.map(\.id))
    }
}

#endif // canImport(UIKit)
