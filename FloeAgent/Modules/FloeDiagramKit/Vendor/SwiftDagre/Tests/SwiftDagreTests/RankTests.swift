// SPDX-License-Identifier: MIT
// SwiftDagre Tests - Rank Algorithm Tests

import XCTest
@testable import SwiftDagre

final class RankTests: XCTestCase {

    // MARK: - Helper

    private func createDagreGraph() -> DagreGraph {
        return DagreGraph(options: GraphOptions(directed: true, multigraph: true, compound: false))
    }

    /// Normalizes ranks so that minimum rank is 0
    private func normalizeRanks(_ g: DagreGraph) {
        let minRank = g.nodes().compactMap { g.node($0)?.rank }.min() ?? 0
        for v in g.nodes() {
            if let label = g.node(v) {
                label.rank -= minRank
            }
        }
    }

    // MARK: - Longest Path Tests

    func testLongestPathLinearChain() throws {
        // A -> B -> C -> D
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())
        try g.setEdge("C", "D", label: DagreEdgeLabel())

        LongestPath.run(g)
        normalizeRanks(g)

        // A should be at rank 0, D at rank 3
        XCTAssertEqual(g.node("A")?.rank, 0)
        XCTAssertEqual(g.node("B")?.rank, 1)
        XCTAssertEqual(g.node("C")?.rank, 2)
        XCTAssertEqual(g.node("D")?.rank, 3)
    }

    func testLongestPathDiamond() throws {
        //     B
        //   /   \
        // A       D
        //   \   /
        //     C
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("A", "C", label: DagreEdgeLabel())
        try g.setEdge("B", "D", label: DagreEdgeLabel())
        try g.setEdge("C", "D", label: DagreEdgeLabel())

        LongestPath.run(g)
        normalizeRanks(g)

        // A at rank 0, B and C at rank 1, D at rank 2
        XCTAssertEqual(g.node("A")?.rank, 0)
        XCTAssertEqual(g.node("B")?.rank, 1)
        XCTAssertEqual(g.node("C")?.rank, 1)
        XCTAssertEqual(g.node("D")?.rank, 2)
    }

    func testLongestPathWithMinlen() throws {
        // A -> B with minlen=2
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel(minlen: 2))

        LongestPath.run(g)
        normalizeRanks(g)

        // B should be at least 2 ranks below A
        XCTAssertEqual(g.node("A")?.rank, 0)
        XCTAssertGreaterThanOrEqual(g.node("B")?.rank ?? 0, 2)
    }

    func testLongestPathRelativeOrder() throws {
        // Test that relative ordering is correct without normalization
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())

        LongestPath.run(g)

        let rankA = g.node("A")?.rank ?? 0
        let rankB = g.node("B")?.rank ?? 0
        let rankC = g.node("C")?.rank ?? 0

        // Each edge should span at least minlen=1
        XCTAssertEqual(rankB - rankA, 1)
        XCTAssertEqual(rankC - rankB, 1)
    }

    // MARK: - Network Simplex Tests

    func testNetworkSimplexLinearChain() throws {
        // A -> B -> C
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())

        try NetworkSimplex.run(g)
        normalizeRanks(g)

        // Should produce tight layout
        XCTAssertEqual(g.node("A")?.rank, 0)
        XCTAssertEqual(g.node("B")?.rank, 1)
        XCTAssertEqual(g.node("C")?.rank, 2)
    }

    func testNetworkSimplexOptimizesEdgeLengths() throws {
        // Graph where longest path would give longer edges than necessary
        //   A
        //  / \
        // B   C
        //  \ /
        //   D
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("A", "C", label: DagreEdgeLabel())
        try g.setEdge("B", "D", label: DagreEdgeLabel())
        try g.setEdge("C", "D", label: DagreEdgeLabel())

        try NetworkSimplex.run(g)
        normalizeRanks(g)

        // All edges should have length 1 (tight)
        XCTAssertEqual(g.node("A")?.rank, 0)
        XCTAssertEqual(g.node("B")?.rank, 1)
        XCTAssertEqual(g.node("C")?.rank, 1)
        XCTAssertEqual(g.node("D")?.rank, 2)
    }

    func testNetworkSimplexRelativeRankDifferences() throws {
        // Test that relative differences are correct
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())

        try NetworkSimplex.run(g)

        let rankA = g.node("A")?.rank ?? 0
        let rankB = g.node("B")?.rank ?? 0
        let rankC = g.node("C")?.rank ?? 0

        // Each edge should be tight (span exactly minlen=1)
        XCTAssertEqual(rankB - rankA, 1)
        XCTAssertEqual(rankC - rankB, 1)
    }

    // MARK: - Rank.run Tests

    func testRankWithLongestPathAlgorithm() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())

        try Rank.run(g, algorithm: .longestPath)

        // Check relative ordering
        let rankA = g.node("A")?.rank ?? 0
        let rankB = g.node("B")?.rank ?? 0
        XCTAssertEqual(rankB - rankA, 1)
    }

    func testRankWithNetworkSimplexAlgorithm() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())

        try Rank.run(g, algorithm: .networkSimplex)

        let rankA = g.node("A")?.rank ?? 0
        let rankB = g.node("B")?.rank ?? 0
        XCTAssertEqual(rankB - rankA, 1)
    }

    func testRankWithCustomRanker() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())

        // Custom ranker that assigns arbitrary ranks
        try Rank.run(g, customRanker: { graph in
            graph.node("A")?.rank = 10
            graph.node("B")?.rank = 20
        })

        XCTAssertEqual(g.node("A")?.rank, 10)
        XCTAssertEqual(g.node("B")?.rank, 20)
    }

    func testRankWithNoneAlgorithm() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())

        // Pre-set ranks
        g.node("A")?.rank = 5
        g.node("B")?.rank = 8

        try Rank.run(g, algorithm: .none)

        // Ranks should be unchanged
        XCTAssertEqual(g.node("A")?.rank, 5)
        XCTAssertEqual(g.node("B")?.rank, 8)
    }

    // MARK: - RankUtil Tests

    func testRankUtilSlack() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 3
        try g.setEdge("A", "B", label: DagreEdgeLabel(minlen: 1))

        let edge = g.edges().first!
        let slack = RankUtil.slack(g, edge: edge)

        // slack = rank(B) - rank(A) - minlen = 3 - 0 - 1 = 2
        XCTAssertEqual(slack, 2)
    }

    func testRankUtilIsTight() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 1
        try g.setEdge("A", "B", label: DagreEdgeLabel(minlen: 1))

        let edge = g.edges().first!

        // slack = 1 - 0 - 1 = 0, so edge is tight
        XCTAssertTrue(RankUtil.isTight(g, edge: edge))
    }

    func testRankUtilNotTight() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 3
        try g.setEdge("A", "B", label: DagreEdgeLabel(minlen: 1))

        let edge = g.edges().first!

        // slack = 3 - 0 - 1 = 2 != 0, not tight
        XCTAssertFalse(RankUtil.isTight(g, edge: edge))
    }

    // MARK: - Edge Cases

    func testRankSingleNode() {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())

        LongestPath.run(g)

        XCTAssertEqual(g.node("A")?.rank, 0)
    }

    func testRankDisconnectedNodes() {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        // No edges

        LongestPath.run(g)

        // Both should be sinks, so both at rank 0
        XCTAssertEqual(g.node("A")?.rank, 0)
        XCTAssertEqual(g.node("B")?.rank, 0)
    }

    func testRankParallelPaths() throws {
        // A -> B -> C
        // A -> D -> C
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.setNode("D", label: DagreNodeLabel())
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())
        try g.setEdge("A", "D", label: DagreEdgeLabel())
        try g.setEdge("D", "C", label: DagreEdgeLabel())

        try NetworkSimplex.run(g)
        normalizeRanks(g)

        // A at 0, B and D at 1, C at 2
        XCTAssertEqual(g.node("A")?.rank, 0)
        XCTAssertEqual(g.node("B")?.rank, 1)
        XCTAssertEqual(g.node("D")?.rank, 1)
        XCTAssertEqual(g.node("C")?.rank, 2)
    }
}
