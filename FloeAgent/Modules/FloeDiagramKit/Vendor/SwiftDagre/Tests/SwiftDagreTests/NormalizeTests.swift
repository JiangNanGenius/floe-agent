// SPDX-License-Identifier: MIT
// SwiftDagre Tests - Normalize/Denormalize Tests

import XCTest
@testable import SwiftDagre

final class NormalizeTests: XCTestCase {

    // MARK: - Helper

    private func createDagreGraph() -> DagreGraph {
        return DagreGraph(options: GraphOptions(directed: true, multigraph: true, compound: false))
    }

    // MARK: - Normalize Tests

    func testNormalizeUnitLengthEdgeUnchanged() throws {
        // Edge with length 1 should not be split
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 1
        try g.setEdge("A", "B", label: DagreEdgeLabel())

        let dummyChains = try Normalize.run(g)

        // No dummy nodes needed
        XCTAssertEqual(g.nodeCount(), 2)
        XCTAssertTrue(g.hasEdge("A", "B"))
        XCTAssertTrue(dummyChains.isEmpty)
    }

    func testNormalizeLongEdgeCreatedDummyNodes() throws {
        // Edge spanning 3 ranks: 0 -> 3
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 3
        try g.setEdge("A", "B", label: DagreEdgeLabel())

        let dummyChains = try Normalize.run(g)

        // Should create 2 dummy nodes (at ranks 1 and 2)
        XCTAssertEqual(g.nodeCount(), 4, "Should have 2 original + 2 dummy nodes")

        // Original edge should be removed
        XCTAssertFalse(g.hasEdge("A", "B"), "Original long edge should be removed")

        // Should have chain: A -> dummy1 -> dummy2 -> B
        XCTAssertEqual(dummyChains.count, 1, "Should have one dummy chain")

        // Verify dummy nodes have correct dummy type
        let dummyNodes = g.nodes().filter { g.node($0)?.dummy != nil }
        XCTAssertEqual(dummyNodes.count, 2)

        for dummyId in dummyNodes {
            let label = g.node(dummyId)
            XCTAssertEqual(label?.dummy, .edge)
        }
    }

    func testNormalizeDummyNodesHaveCorrectRanks() throws {
        // Edge from rank 0 to rank 4
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 4
        try g.setEdge("A", "B", label: DagreEdgeLabel())

        _ = try Normalize.run(g)

        // Get dummy nodes by rank
        var nodesByRank: [Int: [String]] = [:]
        for v in g.nodes() {
            let rank = g.node(v)?.rank ?? -1
            nodesByRank[rank, default: []].append(v)
        }

        // Should have nodes at ranks 0, 1, 2, 3, 4
        XCTAssertEqual(nodesByRank[0]?.count, 1) // A
        XCTAssertEqual(nodesByRank[1]?.count, 1) // dummy
        XCTAssertEqual(nodesByRank[2]?.count, 1) // dummy
        XCTAssertEqual(nodesByRank[3]?.count, 1) // dummy
        XCTAssertEqual(nodesByRank[4]?.count, 1) // B
    }

    func testNormalizeDummyNodesStoreEdgeReference() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 2
        try g.setEdge("A", "B", label: DagreEdgeLabel())

        _ = try Normalize.run(g)

        // Find the dummy node
        let dummyId = g.nodes().first { g.node($0)?.dummy == .edge }
        XCTAssertNotNil(dummyId)

        if let dummyId = dummyId {
            let dummyLabel = g.node(dummyId)
            XCTAssertEqual(dummyLabel?.edgeSource, "A")
            XCTAssertEqual(dummyLabel?.edgeTarget, "B")
            XCTAssertNotNil(dummyLabel?.edgeLabel)
        }
    }

    func testNormalizeMultipleLongEdges() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.setNode("C", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 2
        g.node("C")?.rank = 2
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("A", "C", label: DagreEdgeLabel())

        let dummyChains = try Normalize.run(g)

        // Should create 2 dummy chains (one for each long edge)
        XCTAssertEqual(dummyChains.count, 2)

        // Should have 2 dummy nodes (one per long edge)
        let dummyNodes = g.nodes().filter { g.node($0)?.dummy == .edge }
        XCTAssertEqual(dummyNodes.count, 2)
    }

    // MARK: - Denormalize Tests

    func testDenormalizeRemovesDummyNodes() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 3
        let edgeLabel = DagreEdgeLabel()
        try g.setEdge("A", "B", label: edgeLabel)

        let dummyChains = try Normalize.run(g)
        XCTAssertEqual(g.nodeCount(), 4, "Should have dummy nodes before denormalize")

        try Normalize.undo(g, dummyChains: dummyChains)

        // Dummy nodes should be removed
        XCTAssertEqual(g.nodeCount(), 2, "Dummy nodes should be removed")

        // Original edge should be restored
        XCTAssertTrue(g.hasEdge("A", "B"), "Original edge should be restored")
    }

    func testDenormalizeCollectsPoints() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 3
        let edgeLabel = DagreEdgeLabel()
        try g.setEdge("A", "B", label: edgeLabel)

        let dummyChains = try Normalize.run(g)

        // Set coordinates on dummy nodes
        for dummyId in dummyChains {
            var currentDummy = dummyId
            var rank = 1
            while let label = g.node(currentDummy), label.dummy != nil {
                label.x = Double(rank * 100)
                label.y = Double(rank * 50)

                // Find next dummy in chain
                if let outEdges = g.outEdges(currentDummy), let nextEdge = outEdges.first {
                    currentDummy = nextEdge.w
                } else {
                    break
                }
                rank += 1
            }
        }

        try Normalize.undo(g, dummyChains: dummyChains)

        // Edge should have points from dummy nodes
        let restoredLabel = g.edge("A", "B")
        XCTAssertNotNil(restoredLabel)
        XCTAssertGreaterThan(restoredLabel?.points.count ?? 0, 0, "Edge should have points")
    }

    // MARK: - Edge Cases

    func testNormalizeEmptyGraph() throws {
        let g = createDagreGraph()

        let dummyChains = try Normalize.run(g)

        XCTAssertTrue(dummyChains.isEmpty)
        XCTAssertEqual(g.nodeCount(), 0)
    }

    func testNormalizeSingleNode() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.node("A")?.rank = 0

        let dummyChains = try Normalize.run(g)

        XCTAssertTrue(dummyChains.isEmpty)
        XCTAssertEqual(g.nodeCount(), 1)
    }

    func testNormalizePreservesEdgeWeight() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel())
        g.setNode("B", label: DagreNodeLabel())
        g.node("A")?.rank = 0
        g.node("B")?.rank = 2
        try g.setEdge("A", "B", label: DagreEdgeLabel(minlen: 1, weight: 5))

        _ = try Normalize.run(g)

        // Check edges in the chain have the original weight
        let dummyId = g.nodes().first { g.node($0)?.dummy == .edge }
        XCTAssertNotNil(dummyId)

        if let dummyId = dummyId {
            let edgeToTarget = g.outEdges(dummyId)?.first { $0.w == "B" }
            XCTAssertNotNil(edgeToTarget)
            XCTAssertEqual(g.edge(edgeToTarget!.id)?.weight, 5)
        }
    }
}
