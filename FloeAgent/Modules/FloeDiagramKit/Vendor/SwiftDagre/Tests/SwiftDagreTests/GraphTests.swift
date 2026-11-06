// SPDX-License-Identifier: MIT
// SwiftDagre Tests

import XCTest
@testable import SwiftDagre

final class GraphTests: XCTestCase {

    // MARK: - Basic Node Operations

    func testSetNodeAndRetrieve() {
        let g = DagreGraph()

        g.setNode("a", label: DagreNodeLabel(width: 100, height: 50))

        XCTAssertTrue(g.hasNode("a"))
        XCTAssertEqual(g.nodeCount(), 1)

        let label = g.node("a")
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.width, 100)
        XCTAssertEqual(label?.height, 50)
    }

    func testRemoveNode() throws {
        let g = DagreGraph()

        g.setNode("a", label: DagreNodeLabel())
        g.setNode("b", label: DagreNodeLabel())
        try g.setEdge("a", "b", label: DagreEdgeLabel())

        XCTAssertEqual(g.nodeCount(), 2)
        XCTAssertEqual(g.edgeCount(), 1)

        g.removeNode("a")

        XCTAssertFalse(g.hasNode("a"))
        XCTAssertEqual(g.nodeCount(), 1)
        XCTAssertEqual(g.edgeCount(), 0) // Edge should be removed too
    }

    func testSourcesAndSinks() throws {
        let g = DagreGraph()

        g.setNode("a", label: DagreNodeLabel())
        g.setNode("b", label: DagreNodeLabel())
        g.setNode("c", label: DagreNodeLabel())
        try g.setEdge("a", "b", label: DagreEdgeLabel())
        try g.setEdge("b", "c", label: DagreEdgeLabel())

        XCTAssertEqual(Set(g.sources()), Set(["a"]))
        XCTAssertEqual(Set(g.sinks()), Set(["c"]))
    }

    // MARK: - Edge Operations

    func testSetEdgeAndRetrieve() throws {
        let g = DagreGraph()

        g.setNode("a", label: DagreNodeLabel())
        g.setNode("b", label: DagreNodeLabel())
        try g.setEdge("a", "b", label: DagreEdgeLabel(minlen: 2, weight: 3))

        XCTAssertTrue(g.hasEdge("a", "b"))
        XCTAssertEqual(g.edgeCount(), 1)

        let label = g.edge("a", "b")
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.minlen, 2)
        XCTAssertEqual(label?.weight, 3)
    }

    func testRemoveEdge() throws {
        let g = DagreGraph()

        g.setNode("a", label: DagreNodeLabel())
        g.setNode("b", label: DagreNodeLabel())
        try g.setEdge("a", "b", label: DagreEdgeLabel())

        XCTAssertEqual(g.edgeCount(), 1)

        g.removeEdge("a", "b")

        XCTAssertFalse(g.hasEdge("a", "b"))
        XCTAssertEqual(g.edgeCount(), 0)
    }

    func testInOutEdges() throws {
        let g = DagreGraph()

        g.setNode("a", label: DagreNodeLabel())
        g.setNode("b", label: DagreNodeLabel())
        g.setNode("c", label: DagreNodeLabel())
        try g.setEdge("a", "b", label: DagreEdgeLabel())
        try g.setEdge("a", "c", label: DagreEdgeLabel())
        try g.setEdge("b", "c", label: DagreEdgeLabel())

        let aOut = g.outEdges("a") ?? []
        XCTAssertEqual(aOut.count, 2)

        let bIn = g.inEdges("b") ?? []
        XCTAssertEqual(bIn.count, 1)

        let cIn = g.inEdges("c") ?? []
        XCTAssertEqual(cIn.count, 2)
    }

    func testPredecessorsSuccessors() throws {
        let g = DagreGraph()

        g.setNode("a", label: DagreNodeLabel())
        g.setNode("b", label: DagreNodeLabel())
        g.setNode("c", label: DagreNodeLabel())
        try g.setEdge("a", "b", label: DagreEdgeLabel())
        try g.setEdge("a", "c", label: DagreEdgeLabel())
        try g.setEdge("b", "c", label: DagreEdgeLabel())

        XCTAssertEqual(Set(g.successors("a") ?? []), Set(["b", "c"]))
        XCTAssertEqual(Set(g.predecessors("c") ?? []), Set(["a", "b"]))
    }

    // MARK: - Compound Graph Operations

    func testCompoundGraphParentChild() {
        let g = DagreGraph(options: GraphOptions(compound: true))

        g.setNode("parent", label: DagreNodeLabel())
        g.setNode("child1", label: DagreNodeLabel())
        g.setNode("child2", label: DagreNodeLabel())

        try! g.setParent("child1", parent: "parent")
        try! g.setParent("child2", parent: "parent")

        XCTAssertEqual(g.parent("child1"), "parent")
        XCTAssertEqual(g.parent("child2"), "parent")
        XCTAssertEqual(Set(g.children("parent") ?? []), Set(["child1", "child2"]))
    }

    func testDescendants() {
        let g = DagreGraph(options: GraphOptions(compound: true))

        g.setNode("root", label: DagreNodeLabel())
        g.setNode("child1", label: DagreNodeLabel())
        g.setNode("child2", label: DagreNodeLabel())
        g.setNode("grandchild", label: DagreNodeLabel())

        try! g.setParent("child1", parent: "root")
        try! g.setParent("child2", parent: "root")
        try! g.setParent("grandchild", parent: "child1")

        let descendants = g.descendants(of: "root")
        XCTAssertEqual(descendants, Set(["child1", "child2", "grandchild"]))
    }

    func testLowestCommonAncestor() {
        let g = DagreGraph(options: GraphOptions(compound: true))

        g.setNode("root", label: DagreNodeLabel())
        g.setNode("a", label: DagreNodeLabel())
        g.setNode("b", label: DagreNodeLabel())
        g.setNode("c", label: DagreNodeLabel())
        g.setNode("d", label: DagreNodeLabel())

        try! g.setParent("a", parent: "root")
        try! g.setParent("b", parent: "root")
        try! g.setParent("c", parent: "a")
        try! g.setParent("d", parent: "a")

        XCTAssertEqual(g.lowestCommonAncestor("c", "d"), "a")
        XCTAssertEqual(g.lowestCommonAncestor("c", "b"), "root")
    }

    func testSetParentCycleDetection() {
        let g = DagreGraph(options: GraphOptions(compound: true))

        g.setNode("a", label: DagreNodeLabel())
        g.setNode("b", label: DagreNodeLabel())
        g.setNode("c", label: DagreNodeLabel())

        try! g.setParent("b", parent: "a")
        try! g.setParent("c", parent: "b")

        // Attempting to set "a" as child of "c" would create a cycle: a -> b -> c -> a
        XCTAssertThrowsError(try g.setParent("a", parent: "c")) { error in
            guard let graphError = error as? GraphError else {
                XCTFail("Expected GraphError, got \(error)")
                return
            }
            if case .cycleDetected(let parent, let child) = graphError {
                XCTAssertEqual(parent, "c")
                XCTAssertEqual(child, "a")
            } else {
                XCTFail("Expected cycleDetected error")
            }
        }

        // Direct self-cycle should also be detected
        XCTAssertThrowsError(try g.setParent("a", parent: "a")) { error in
            guard let graphError = error as? GraphError else {
                XCTFail("Expected GraphError, got \(error)")
                return
            }
            if case .cycleDetected(let parent, let child) = graphError {
                XCTAssertEqual(parent, "a")
                XCTAssertEqual(child, "a")
            } else {
                XCTFail("Expected cycleDetected error")
            }
        }
    }

    // MARK: - Multigraph Operations

    func testMultigraph() throws {
        let g = DagreGraph(options: GraphOptions(multigraph: true))

        g.setNode("a", label: DagreNodeLabel())
        g.setNode("b", label: DagreNodeLabel())
        try g.setEdge("a", "b", label: DagreEdgeLabel(weight: 1), name: "edge1")
        try g.setEdge("a", "b", label: DagreEdgeLabel(weight: 2), name: "edge2")

        XCTAssertEqual(g.edgeCount(), 2)
        XCTAssertEqual(g.edge("a", "b", name: "edge1")?.weight, 1)
        XCTAssertEqual(g.edge("a", "b", name: "edge2")?.weight, 2)
    }
}
