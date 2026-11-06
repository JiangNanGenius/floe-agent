// SPDX-License-Identifier: MIT
// SwiftDagre Tests - Order Algorithm Tests

import XCTest
@testable import SwiftDagre

final class OrderTests: XCTestCase {

    // MARK: - Helper

    private func createDagreGraph() -> DagreGraph {
        return DagreGraph(options: GraphOptions(directed: true, multigraph: true, compound: false))
    }

    // MARK: - InitOrder Tests

    func testInitOrderAssignsOrderValues() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 1
        g.node("C")?.rank = 1
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("A", "C", label: DagreEdgeLabel())

        let layering = InitOrder.run(g)

        // Should have 2 layers
        XCTAssertEqual(layering.count, 2)
        XCTAssertEqual(layering[0].count, 1) // A
        XCTAssertEqual(layering[1].count, 2) // B, C
    }

    // MARK: - Order.run Tests

    func testOrderAssignsOrderToNodes() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 1
        g.node("C")?.rank = 1
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("A", "C", label: DagreEdgeLabel())

        try Order.run(g)

        // All nodes should have order values
        XCTAssertNotNil(g.node("A")?.order)
        XCTAssertNotNil(g.node("B")?.order)
        XCTAssertNotNil(g.node("C")?.order)

        // A is alone in its layer, should have order 0
        XCTAssertEqual(g.node("A")?.order, 0)
    }

    func testOrderMinimizesCrossings() throws {
        // Graph where ordering matters for crossings
        //   A   B
        //   |\ /|
        //   | X |
        //   |/ \|
        //   C   D
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 0
        g.node("C")?.rank = 1
        g.node("D")?.rank = 1
        try g.setEdge("A", "C", label: DagreEdgeLabel())
        try g.setEdge("A", "D", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())
        try g.setEdge("B", "D", label: DagreEdgeLabel())

        try Order.run(g)

        // Both layers should have 2 nodes with orders 0 and 1
        let aOrder = g.node("A")?.order ?? -1
        let bOrder = g.node("B")?.order ?? -1
        let cOrder = g.node("C")?.order ?? -1
        let dOrder = g.node("D")?.order ?? -1

        XCTAssertTrue(Set([aOrder, bOrder]) == Set([0, 1]), "A and B should have different orders")
        XCTAssertTrue(Set([cOrder, dOrder]) == Set([0, 1]), "C and D should have different orders")
    }

    func testOrderWithDisableOptimization() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 1
        try g.setEdge("A", "B", label: DagreEdgeLabel())

        try Order.run(g, disableOptimization: true)

        // Should still assign orders (just skip optimization)
        XCTAssertEqual(g.node("A")?.order, 0)
        XCTAssertEqual(g.node("B")?.order, 0)
    }

    func testOrderWithCustomOrderFunction() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 0
        g.node("C")?.rank = 1
        try g.setEdge("A", "C", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())

        // Custom order function that sets specific orders
        try Order.run(g, customOrder: { graph, _ in
            graph.node("A")?.order = 1
            graph.node("B")?.order = 0
            graph.node("C")?.order = 0
        })

        XCTAssertEqual(g.node("A")?.order, 1)
        XCTAssertEqual(g.node("B")?.order, 0)
        XCTAssertEqual(g.node("C")?.order, 0)
    }

    // MARK: - CrossCount Tests

    func testCrossCountNoCrossings() throws {
        // A -> C
        // B -> D
        // No crossings
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 0
        g.node("C")?.rank = 1
        g.node("D")?.rank = 1
        try g.setEdge("A", "C", label: DagreEdgeLabel())
        try g.setEdge("B", "D", label: DagreEdgeLabel())

        let layering = [["A", "B"], ["C", "D"]]
        let count = CrossCount.count(g, layering: layering)

        XCTAssertEqual(count, 0)
    }

    func testCrossCountWithCrossings() throws {
        // A -> D (crosses B -> C)
        // B -> C
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 0
        g.node("C")?.rank = 1
        g.node("D")?.rank = 1
        try g.setEdge("A", "D", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())

        let layering = [["A", "B"], ["C", "D"]]
        let count = CrossCount.count(g, layering: layering)

        XCTAssertEqual(count, 1)
    }

    func testCrossCountMultipleCrossings() throws {
        // Full bipartite: A,B -> C,D
        // A -> C, A -> D, B -> C, B -> D
        // With A before B and C before D: AD crosses BC = 1 crossing
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 0
        g.node("C")?.rank = 1
        g.node("D")?.rank = 1
        try g.setEdge("A", "C", label: DagreEdgeLabel())
        try g.setEdge("A", "D", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())
        try g.setEdge("B", "D", label: DagreEdgeLabel())

        let layering = [["A", "B"], ["C", "D"]]
        let count = CrossCount.count(g, layering: layering)

        // A->D crosses B->C (1 crossing)
        XCTAssertEqual(count, 1)
    }

    func testCrossCountTwoEmptyLayers() {
        let g = createDagreGraph()
        let layering: [[String]] = [[], []]
        let count = CrossCount.count(g, layering: layering)

        XCTAssertEqual(count, 0)
    }

    func testCrossCountSingleLayer() {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 0

        let layering = [["A", "B"]]
        let count = CrossCount.count(g, layering: layering)

        XCTAssertEqual(count, 0)
    }

    // MARK: - Edge Cases

    func testOrderEmptyGraph() throws {
        let g = createDagreGraph()

        try Order.run(g)

        XCTAssertEqual(g.nodeCount(), 0)
    }

    func testOrderSingleNode() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.node("A")?.rank = 0

        try Order.run(g)

        XCTAssertEqual(g.node("A")?.order, 0)
    }

    func testOrderLinearChain() throws {
        // A -> B -> C -> D
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 1
        g.node("C")?.rank = 2
        g.node("D")?.rank = 3
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())
        try g.setEdge("C", "D", label: DagreEdgeLabel())

        try Order.run(g)

        // All should have order 0 (single node per layer)
        XCTAssertEqual(g.node("A")?.order, 0)
        XCTAssertEqual(g.node("B")?.order, 0)
        XCTAssertEqual(g.node("C")?.order, 0)
        XCTAssertEqual(g.node("D")?.order, 0)
    }
}
