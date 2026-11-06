// SPDX-License-Identifier: MIT
// SwiftDagre Tests - Acyclic Algorithm Tests

import XCTest
@testable import SwiftDagre

final class AcyclicTests: XCTestCase {

    // MARK: - Helper

    /// Creates a multigraph for acyclic operations (required because reversed edges use named edges)
    private func createDagreGraph() -> DagreGraph {
        return DagreGraph(options: GraphOptions(directed: true, multigraph: true, compound: false))
    }

    // MARK: - DFS Cycle Detection Tests

    func testDFSNoCycle() throws {
        // Simple DAG: A -> B -> C
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())

        try Acyclic.run(g, algorithm: .dfs)

        // Should still have edges in original direction (no cycle to reverse)
        XCTAssertTrue(g.hasEdge("A", "B"))
        XCTAssertTrue(g.hasEdge("B", "C"))
        XCTAssertFalse(g.hasEdge("B", "A"))
        XCTAssertFalse(g.hasEdge("C", "B"))
    }

    func testDFSSimpleCycle() throws {
        // Cycle: A -> B -> C -> A
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())
        try g.setEdge("C", "A", label: DagreEdgeLabel())

        try Acyclic.run(g, algorithm: .dfs)

        // At least one edge should be reversed to break the cycle
        // The graph should now be acyclic
        // Check that C->A was reversed (back edge)
        let hasOriginalCA = g.hasEdge("C", "A")
        let hasReversedAC = g.edges().contains { $0.v == "A" && $0.w == "C" && (g.edge($0.id)?.reversed ?? false) }

        // Either the original edge exists OR a reversed edge exists
        XCTAssertTrue(!hasOriginalCA || hasReversedAC, "Cycle should be broken")
    }

    func testDFSReversedEdgeMarked() throws {
        // Cycle: A -> B -> A
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "A", label: DagreEdgeLabel())

        try Acyclic.run(g, algorithm: .dfs)

        // Find the reversed edge
        let reversedEdges = g.edges().filter { g.edge($0.id)?.reversed == true }
        XCTAssertEqual(reversedEdges.count, 1, "Exactly one edge should be reversed")
    }

    // MARK: - Greedy FAS Tests

    func testGreedyNoCycle() throws {
        // Simple DAG: A -> B -> C
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())

        try Acyclic.run(g, algorithm: .greedy)

        // Should still have edges in original direction
        XCTAssertTrue(g.hasEdge("A", "B"))
        XCTAssertTrue(g.hasEdge("B", "C"))
    }

    func testGreedySimpleCycle() throws {
        // Cycle: A -> B -> A
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "A", label: DagreEdgeLabel())

        try Acyclic.run(g, algorithm: .greedy)

        // At least one edge should be reversed
        let reversedEdges = g.edges().filter { g.edge($0.id)?.reversed == true }
        XCTAssertGreaterThanOrEqual(reversedEdges.count, 1, "At least one edge should be reversed")
    }

    func testGreedyLargerCycle() throws {
        // Cycle: A -> B -> C -> D -> A
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())
        try g.setEdge("C", "D", label: DagreEdgeLabel())
        try g.setEdge("D", "A", label: DagreEdgeLabel())

        try Acyclic.run(g, algorithm: .greedy)

        // At least one edge should be reversed to break the cycle
        let reversedEdges = g.edges().filter { g.edge($0.id)?.reversed == true }
        XCTAssertGreaterThanOrEqual(reversedEdges.count, 1, "At least one edge should be reversed to break cycle")
    }

    // MARK: - Undo Tests

    func testUndoReversesEdgesBack() throws {
        // Cycle: A -> B -> A
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "A", label: DagreEdgeLabel())

        // Make acyclic
        try Acyclic.run(g, algorithm: .dfs)

        // Verify an edge was reversed
        let reversedEdges = g.edges().filter { g.edge($0.id)?.reversed == true }
        XCTAssertEqual(reversedEdges.count, 1, "One edge should be reversed")

        // Undo the transformation
        try Acyclic.undo(g)

        // No edges should be marked as reversed
        let stillReversed = g.edges().filter { g.edge($0.id)?.reversed == true }
        XCTAssertEqual(stillReversed.count, 0, "No edges should be reversed after undo")
    }

    func testUndoPreservesOriginalStructure() throws {
        // DAG with no cycles
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())

        // Make acyclic (no changes needed)
        try Acyclic.run(g, algorithm: .dfs)

        // Undo
        try Acyclic.undo(g)

        // Original structure preserved
        XCTAssertTrue(g.hasEdge("A", "B"))
        XCTAssertTrue(g.hasEdge("B", "C"))
        XCTAssertEqual(g.edgeCount(), 2)
    }

    // MARK: - Edge Cases

    func testSingleNodeGraph() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())

        try Acyclic.run(g, algorithm: .dfs)
        XCTAssertEqual(g.nodeCount(), 1)
        XCTAssertEqual(g.edgeCount(), 0)
    }

    func testDisconnectedGraph() throws {
        // Two disconnected components
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("C", "D", label: DagreEdgeLabel())

        try Acyclic.run(g, algorithm: .dfs)

        // No cycles, edges unchanged
        XCTAssertTrue(g.hasEdge("A", "B"))
        XCTAssertTrue(g.hasEdge("C", "D"))
        XCTAssertEqual(g.edgeCount(), 2)
    }

    func testMultipleCycles() throws {
        // Two cycles: A -> B -> A and C -> D -> C
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "A", label: DagreEdgeLabel())
        try g.setEdge("C", "D", label: DagreEdgeLabel())
        try g.setEdge("D", "C", label: DagreEdgeLabel())

        try Acyclic.run(g, algorithm: .dfs)

        // At least 2 edges should be reversed (one per cycle)
        let reversedEdges = g.edges().filter { g.edge($0.id)?.reversed == true }
        XCTAssertGreaterThanOrEqual(reversedEdges.count, 2, "At least two edges should be reversed")
    }
}
