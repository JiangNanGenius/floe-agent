// SPDX-License-Identifier: MIT
// SwiftDagre Tests - Position Algorithm Tests

import XCTest
@testable import SwiftDagre

final class PositionTests: XCTestCase {

    // MARK: - Helper

    private func createDagreGraph() -> DagreGraph {
        return DagreGraph(options: GraphOptions(directed: true, multigraph: true, compound: false))
    }

    private func setupSimpleGraph() throws -> DagreGraph {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel(width: 100, height: 50))
        g.setNode("B", label: DagreNodeLabel(width: 100, height: 50))
        g.node("A")?.rank = 0
        g.node("A")?.order = 0
        g.node("B")?.rank = 1
        g.node("B")?.order = 0
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        return g
    }

    // MARK: - Position.run Tests

    func testPositionAssignsCoordinates() throws {
        let g = try setupSimpleGraph()

        try Position.run(g, nodesep: 50, edgesep: 20, ranksep: 50)

        // Both nodes should have coordinates
        XCTAssertNotNil(g.node("A")?.x)
        XCTAssertNotNil(g.node("A")?.y)
        XCTAssertNotNil(g.node("B")?.x)
        XCTAssertNotNil(g.node("B")?.y)
    }

    func testPositionYCoordinatesRespectRanksep() throws {
        let g = try setupSimpleGraph()

        try Position.run(g, nodesep: 50, edgesep: 20, ranksep: 100)

        let yA = g.node("A")?.y ?? 0
        let yB = g.node("B")?.y ?? 0

        // B should be below A (higher Y)
        XCTAssertGreaterThan(yB, yA)

        // Distance should include ranksep + half of each node's height
        let expectedMinDistance = 100 + 25 + 25 // ranksep + half heights
        XCTAssertGreaterThanOrEqual(yB - yA, Double(expectedMinDistance - 1))
    }

    func testPositionXCoordinatesRespectNodesep() throws {
        // Two nodes in the same rank with a common parent
        let g = createDagreGraph()
        g.setNode("Root", label: DagreNodeLabel(width: 100, height: 50))
        g.setNode("A", label: DagreNodeLabel(width: 100, height: 50))
        g.setNode("B", label: DagreNodeLabel(width: 100, height: 50))
        g.node("Root")?.rank = 0
        g.node("Root")?.order = 0
        g.node("A")?.rank = 1
        g.node("A")?.order = 0
        g.node("B")?.rank = 1
        g.node("B")?.order = 1
        try g.setEdge("Root", "A", label: DagreEdgeLabel())
        try g.setEdge("Root", "B", label: DagreEdgeLabel())

        try Position.run(g, nodesep: 100, edgesep: 20, ranksep: 50)

        let xA = g.node("A")?.x ?? 0
        let xB = g.node("B")?.x ?? 0

        // B should be to the right of A
        XCTAssertGreaterThan(xB, xA)

        // Distance should include nodesep + half widths of each node
        // center-to-center distance = nodesep + halfWidthA + halfWidthB
        let expectedMinDistance = 100 + 50 + 50 // nodesep + half widths
        XCTAssertGreaterThanOrEqual(xB - xA, Double(expectedMinDistance - 1))
    }

    func testPositionMultipleNodesInRank() throws {
        let g = createDagreGraph()
        g.setNode("Root", label: DagreNodeLabel(width: 50, height: 50))
        g.setNode("A", label: DagreNodeLabel(width: 50, height: 50))
        g.setNode("B", label: DagreNodeLabel(width: 50, height: 50))
        g.setNode("C", label: DagreNodeLabel(width: 50, height: 50))
        g.node("Root")?.rank = 0
        g.node("Root")?.order = 0
        g.node("A")?.rank = 1
        g.node("A")?.order = 0
        g.node("B")?.rank = 1
        g.node("B")?.order = 1
        g.node("C")?.rank = 1
        g.node("C")?.order = 2
        try g.setEdge("Root", "A", label: DagreEdgeLabel())
        try g.setEdge("Root", "B", label: DagreEdgeLabel())
        try g.setEdge("Root", "C", label: DagreEdgeLabel())

        try Position.run(g, nodesep: 50, edgesep: 20, ranksep: 50)

        let xA = g.node("A")?.x ?? 0
        let xB = g.node("B")?.x ?? 0
        let xC = g.node("C")?.x ?? 0

        // Nodes should be in order A < B < C
        XCTAssertLessThan(xA, xB)
        XCTAssertLessThan(xB, xC)
    }

    // MARK: - Alignment Tests

    func testPositionWithUpLeftAlignment() throws {
        let g = try setupSimpleGraph()

        try Position.run(g, nodesep: 50, edgesep: 20, ranksep: 50, align: .upLeft)

        // Should have coordinates
        XCTAssertNotNil(g.node("A")?.x)
        XCTAssertNotNil(g.node("B")?.x)
    }

    func testPositionWithUpRightAlignment() throws {
        let g = try setupSimpleGraph()

        try Position.run(g, nodesep: 50, edgesep: 20, ranksep: 50, align: .upRight)

        XCTAssertNotNil(g.node("A")?.x)
        XCTAssertNotNil(g.node("B")?.x)
    }

    func testPositionWithDownLeftAlignment() throws {
        let g = try setupSimpleGraph()

        try Position.run(g, nodesep: 50, edgesep: 20, ranksep: 50, align: .downLeft)

        XCTAssertNotNil(g.node("A")?.x)
        XCTAssertNotNil(g.node("B")?.x)
    }

    func testPositionWithDownRightAlignment() throws {
        let g = try setupSimpleGraph()

        try Position.run(g, nodesep: 50, edgesep: 20, ranksep: 50, align: .downRight)

        XCTAssertNotNil(g.node("A")?.x)
        XCTAssertNotNil(g.node("B")?.x)
    }

    // MARK: - Edge Cases

    func testPositionSingleNode() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel(width: 100, height: 50))
        g.node("A")?.rank = 0
        g.node("A")?.order = 0

        try Position.run(g, nodesep: 50, edgesep: 20, ranksep: 50)

        // Single node should have coordinates
        XCTAssertNotNil(g.node("A")?.x)
        XCTAssertNotNil(g.node("A")?.y)
    }

    func testPositionDiamondGraph() throws {
        //     A
        //    / \
        //   B   C
        //    \ /
        //     D
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel(width: 50, height: 50))
        g.setNode("B", label: DagreNodeLabel(width: 50, height: 50))
        g.setNode("C", label: DagreNodeLabel(width: 50, height: 50))
        g.setNode("D", label: DagreNodeLabel(width: 50, height: 50))
        g.node("A")?.rank = 0
        g.node("A")?.order = 0
        g.node("B")?.rank = 1
        g.node("B")?.order = 0
        g.node("C")?.rank = 1
        g.node("C")?.order = 1
        g.node("D")?.rank = 2
        g.node("D")?.order = 0
        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("A", "C", label: DagreEdgeLabel())
        try g.setEdge("B", "D", label: DagreEdgeLabel())
        try g.setEdge("C", "D", label: DagreEdgeLabel())

        try Position.run(g, nodesep: 50, edgesep: 20, ranksep: 50)

        let xB = g.node("B")?.x ?? 0
        let xC = g.node("C")?.x ?? 0
        let yA = g.node("A")?.y ?? 0
        let yB = g.node("B")?.y ?? 0
        let yD = g.node("D")?.y ?? 0

        // B should be left of C
        XCTAssertLessThan(xB, xC)

        // Y coordinates should increase: A < B == C < D
        XCTAssertLessThan(yA, yB)
        XCTAssertLessThan(yB, yD)
    }

    func testPositionVariableNodeSizes() throws {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel(width: 200, height: 100))
        g.setNode("B", label: DagreNodeLabel(width: 50, height: 25))
        g.node("A")?.rank = 0
        g.node("A")?.order = 0
        g.node("B")?.rank = 1
        g.node("B")?.order = 0
        try g.setEdge("A", "B", label: DagreEdgeLabel())

        try Position.run(g, nodesep: 50, edgesep: 20, ranksep: 50)

        // Both should have coordinates
        XCTAssertNotNil(g.node("A")?.x)
        XCTAssertNotNil(g.node("B")?.x)
        XCTAssertNotNil(g.node("A")?.y)
        XCTAssertNotNil(g.node("B")?.y)
    }

    // MARK: - PositionY Tests

    func testPositionYBasicAssignment() {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel(width: 50, height: 50))
        g.setNode("B", label: DagreNodeLabel(width: 50, height: 50))
        g.node("A")?.rank = 0
        g.node("B")?.rank = 1

        PositionY.run(g, ranksep: 100)

        // Y coordinates should be assigned
        XCTAssertNotNil(g.node("A")?.y)
        XCTAssertNotNil(g.node("B")?.y)

        // B should have higher Y (lower on screen)
        XCTAssertGreaterThan(g.node("B")?.y ?? 0, g.node("A")?.y ?? 0)
    }

    func testPositionYMultipleRanks() {
        let g = createDagreGraph()
        g.setNode("A", label: DagreNodeLabel(width: 50, height: 50))
        g.setNode("B", label: DagreNodeLabel(width: 50, height: 50))
        g.setNode("C", label: DagreNodeLabel(width: 50, height: 50))
        g.node("A")?.rank = 0
        g.node("B")?.rank = 1
        g.node("C")?.rank = 2

        PositionY.run(g, ranksep: 50)

        let yA = g.node("A")?.y ?? 0
        let yB = g.node("B")?.y ?? 0
        let yC = g.node("C")?.y ?? 0

        XCTAssertLessThan(yA, yB)
        XCTAssertLessThan(yB, yC)
    }
}
