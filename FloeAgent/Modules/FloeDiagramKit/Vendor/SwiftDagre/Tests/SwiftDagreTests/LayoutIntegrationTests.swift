// SPDX-License-Identifier: MIT
// SwiftDagre Tests - Layout Integration Tests

import XCTest
@testable import SwiftDagre

/// Integration tests that verify the complete layout pipeline works correctly
/// for various graph topologies.
final class LayoutIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func createGraph(multigraph: Bool = true, compound: Bool = false) -> DagreGraph {
        return DagreGraph(options: GraphOptions(directed: true, multigraph: multigraph, compound: compound))
    }

    private func assertValidCoordinates(_ g: DagreGraph, file: StaticString = #file, line: UInt = #line) {
        for nodeId in g.nodes() {
            guard let label = g.node(nodeId) else {
                XCTFail("Node \(nodeId) should have a label", file: file, line: line)
                continue
            }
            XCTAssertGreaterThanOrEqual(label.x, 0, "Node \(nodeId) x should be non-negative", file: file, line: line)
            XCTAssertGreaterThanOrEqual(label.y, 0, "Node \(nodeId) y should be non-negative", file: file, line: line)
        }
    }

    private func assertNoOverlaps(_ g: DagreGraph, file: StaticString = #file, line: UInt = #line) {
        let nodeIds = g.nodes()
        for i in 0..<nodeIds.count {
            for j in (i+1)..<nodeIds.count {
                let id1 = nodeIds[i]
                let id2 = nodeIds[j]
                guard let n1 = g.node(id1), let n2 = g.node(id2) else { continue }

                let x1 = n1.x
                let y1 = n1.y
                let x2 = n2.x
                let y2 = n2.y

                // Check if bounding boxes overlap (with small tolerance)
                let halfW1 = n1.width / 2
                let halfH1 = n1.height / 2
                let halfW2 = n2.width / 2
                let halfH2 = n2.height / 2

                let xOverlap = abs(x1 - x2) < (halfW1 + halfW2 - 1)
                let yOverlap = abs(y1 - y2) < (halfH1 + halfH2 - 1)

                XCTAssertFalse(xOverlap && yOverlap,
                    "Nodes \(id1) and \(id2) should not overlap. " +
                    "\(id1): (\(x1), \(y1)), \(id2): (\(x2), \(y2))",
                    file: file, line: line)
            }
        }
    }

    private func assertValidEdgePoints(_ g: DagreGraph, file: StaticString = #file, line: UInt = #line) {
        for edge in g.edges() {
            let label = g.edge(edge.id)
            XCTAssertNotNil(label, "Edge \(edge.v)->\(edge.w) should have a label", file: file, line: line)
            XCTAssertGreaterThan(label?.points.count ?? 0, 0,
                "Edge \(edge.v)->\(edge.w) should have points", file: file, line: line)
        }
    }

    // MARK: - Test 1: Linear Chain

    func testLinearChainLayout() throws {
        // A → B → C → D
        let g = createGraph()

        g.setNode("A", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("B", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("C", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("D", label: DagreNodeLabel(width: 50, height: 30))

        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())
        try g.setEdge("C", "D", label: DagreEdgeLabel())

        let options = LayoutOptions()
        options.rankdir = .topBottom
        options.nodesep = 20
        options.ranksep = 40

        try SwiftDagre.layout(g, options: options)

        // Verify valid coordinates
        assertValidCoordinates(g)
        assertNoOverlaps(g)
        assertValidEdgePoints(g)

        // Verify Y increases with rank (top to bottom)
        let yA = g.node("A")?.y ?? 0
        let yB = g.node("B")?.y ?? 0
        let yC = g.node("C")?.y ?? 0
        let yD = g.node("D")?.y ?? 0

        XCTAssertLessThan(yA, yB, "A should be above B")
        XCTAssertLessThan(yB, yC, "B should be above C")
        XCTAssertLessThan(yC, yD, "C should be above D")
    }

    // MARK: - Test 2: Tree Layout

    func testTreeLayout() throws {
        //       Root
        //      / | \
        //     A  B  C
        //    /|  |  |\
        //   D E  F  G H
        let g = createGraph()

        g.setNode("Root", label: DagreNodeLabel(width: 60, height: 30))
        g.setNode("A", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("B", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("C", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("D", label: DagreNodeLabel(width: 40, height: 30))
        g.setNode("E", label: DagreNodeLabel(width: 40, height: 30))
        g.setNode("F", label: DagreNodeLabel(width: 40, height: 30))
        g.setNode("G", label: DagreNodeLabel(width: 40, height: 30))
        g.setNode("H", label: DagreNodeLabel(width: 40, height: 30))

        try g.setEdge("Root", "A", label: DagreEdgeLabel())
        try g.setEdge("Root", "B", label: DagreEdgeLabel())
        try g.setEdge("Root", "C", label: DagreEdgeLabel())
        try g.setEdge("A", "D", label: DagreEdgeLabel())
        try g.setEdge("A", "E", label: DagreEdgeLabel())
        try g.setEdge("B", "F", label: DagreEdgeLabel())
        try g.setEdge("C", "G", label: DagreEdgeLabel())
        try g.setEdge("C", "H", label: DagreEdgeLabel())

        let options = LayoutOptions()
        options.rankdir = .topBottom
        options.nodesep = 20
        options.ranksep = 50

        try SwiftDagre.layout(g, options: options)

        // Verify valid layout
        assertValidCoordinates(g)
        assertNoOverlaps(g)
        assertValidEdgePoints(g)

        // Verify rank ordering
        let yRoot = g.node("Root")?.y ?? 0
        let yA = g.node("A")?.y ?? 0
        let yD = g.node("D")?.y ?? 0

        XCTAssertLessThan(yRoot, yA, "Root should be above A")
        XCTAssertLessThan(yA, yD, "A should be above D")
    }

    // MARK: - Test 3: DAG with Converging Paths (Diamond)

    func testDAGWithConvergingPaths() throws {
        //     A
        //    / \
        //   B   C
        //    \ /
        //     D
        let g = createGraph()

        g.setNode("A", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("B", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("C", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("D", label: DagreNodeLabel(width: 50, height: 30))

        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("A", "C", label: DagreEdgeLabel())
        try g.setEdge("B", "D", label: DagreEdgeLabel())
        try g.setEdge("C", "D", label: DagreEdgeLabel())

        let options = LayoutOptions()
        options.rankdir = .topBottom
        options.nodesep = 30
        options.ranksep = 50

        try SwiftDagre.layout(g, options: options)

        // Verify valid layout
        assertValidCoordinates(g)
        assertNoOverlaps(g)
        assertValidEdgePoints(g)

        // B and C should be at the same Y level (same rank)
        let yB = g.node("B")?.y ?? 0
        let yC = g.node("C")?.y ?? 0
        XCTAssertEqual(yB, yC, accuracy: 1.0, "B and C should be at same rank")

        // B should be left of C or vice versa (different X)
        let xB = g.node("B")?.x ?? 0
        let xC = g.node("C")?.x ?? 0
        XCTAssertNotEqual(xB, xC, "B and C should have different X positions")
    }

    // MARK: - Test 4: Cyclic Graph

    func testCyclicGraphLayout() throws {
        // A → B → C → A (cycle)
        let g = createGraph()

        g.setNode("A", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("B", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("C", label: DagreNodeLabel(width: 50, height: 30))

        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())
        try g.setEdge("C", "A", label: DagreEdgeLabel())

        let options = LayoutOptions()
        options.rankdir = .topBottom
        options.nodesep = 20
        options.ranksep = 40

        // Layout should succeed despite cycle (acyclic transformation)
        try SwiftDagre.layout(g, options: options)

        // Verify valid layout
        assertValidCoordinates(g)
        assertNoOverlaps(g)
        assertValidEdgePoints(g)

        // All 3 edges should exist
        XCTAssertEqual(g.edgeCount(), 3, "Should have 3 edges")
    }

    // MARK: - Test 5: Compound Graph

    func testCompoundGraphLayout() throws {
        // Parent contains Child1 and Child2
        // External → Parent
        // Child1 → Child2
        let g = createGraph(compound: true)

        g.setNode("External", label: DagreNodeLabel(width: 60, height: 30))
        g.setNode("Parent", label: DagreNodeLabel(width: 200, height: 100))
        g.setNode("Child1", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("Child2", label: DagreNodeLabel(width: 50, height: 30))

        try g.setParent("Child1", parent: "Parent")
        try g.setParent("Child2", parent: "Parent")

        try g.setEdge("External", "Parent", label: DagreEdgeLabel())
        try g.setEdge("Child1", "Child2", label: DagreEdgeLabel())

        let options = LayoutOptions()
        options.rankdir = .topBottom
        options.nodesep = 20
        options.ranksep = 40

        try SwiftDagre.layout(g, options: options)

        // Verify valid coordinates for all nodes
        assertValidCoordinates(g)
        assertValidEdgePoints(g)

        // Parent should have valid dimensions after layout
        let parent = g.node("Parent")
        XCTAssertNotNil(parent, "Parent node should exist")
        XCTAssertGreaterThan(parent?.width ?? 0, 0, "Parent should have width")
        XCTAssertGreaterThan(parent?.height ?? 0, 0, "Parent should have height")
    }

    // MARK: - Test 6: Wide Graph

    func testWideGraphLayout() throws {
        // Root with 10 children
        let g = createGraph()

        g.setNode("Root", label: DagreNodeLabel(width: 60, height: 30))

        for i in 1...10 {
            g.setNode("Child\(i)", label: DagreNodeLabel(width: 50, height: 30))
            try g.setEdge("Root", "Child\(i)", label: DagreEdgeLabel())
        }

        let options = LayoutOptions()
        options.rankdir = .topBottom
        options.nodesep = 15
        options.ranksep = 50

        try SwiftDagre.layout(g, options: options)

        // Verify valid layout
        assertValidCoordinates(g)
        assertNoOverlaps(g)
        assertValidEdgePoints(g)

        // All children should be at the same Y level
        var childYs: [Double] = []
        for i in 1...10 {
            if let y = g.node("Child\(i)")?.y {
                childYs.append(y)
            }
        }
        XCTAssertEqual(childYs.count, 10, "All children should have Y coordinates")

        let firstY = childYs[0]
        for y in childYs {
            XCTAssertEqual(y, firstY, accuracy: 1.0, "All children should be at same rank")
        }

        // Root should be above all children
        let rootY = g.node("Root")?.y ?? Double.infinity
        XCTAssertLessThan(rootY, firstY, "Root should be above children")
    }

    // MARK: - Test 7: Left-Right Direction

    func testLeftRightLayout() throws {
        // A → B → C with left-to-right direction
        let g = createGraph()

        g.setNode("A", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("B", label: DagreNodeLabel(width: 50, height: 30))
        g.setNode("C", label: DagreNodeLabel(width: 50, height: 30))

        try g.setEdge("A", "B", label: DagreEdgeLabel())
        try g.setEdge("B", "C", label: DagreEdgeLabel())

        let options = LayoutOptions()
        options.rankdir = .leftRight
        options.nodesep = 20
        options.ranksep = 40

        try SwiftDagre.layout(g, options: options)

        // Verify valid layout
        assertValidCoordinates(g)
        assertNoOverlaps(g)
        assertValidEdgePoints(g)

        // X should increase (left to right)
        let xA = g.node("A")?.x ?? 0
        let xB = g.node("B")?.x ?? 0
        let xC = g.node("C")?.x ?? 0

        XCTAssertLessThan(xA, xB, "A should be left of B")
        XCTAssertLessThan(xB, xC, "B should be left of C")

        // Y should be approximately the same (same rank in LR)
        let yA = g.node("A")?.y ?? 0
        let yB = g.node("B")?.y ?? 0
        let yC = g.node("C")?.y ?? 0

        XCTAssertEqual(yA, yB, accuracy: 1.0, "A and B should have same Y")
        XCTAssertEqual(yB, yC, accuracy: 1.0, "B and C should have same Y")
    }
}
