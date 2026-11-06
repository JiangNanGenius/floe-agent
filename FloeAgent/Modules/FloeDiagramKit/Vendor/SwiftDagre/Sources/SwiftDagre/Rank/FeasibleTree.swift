// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Constructs a spanning tree with tight edges
/// Based on Gansner, et al., "A Technique for Drawing Directed Graphs"
public enum FeasibleTree {

    /// Tree node label for tracking parent relationships and cut values
    public final class TreeNodeLabel {
        /// Parent node in the tree
        public var parent: String?

        /// Low value for postorder numbering
        public var low: Int = 0

        /// Lim value for postorder numbering (upper bound)
        public var lim: Int = 0

        public init() {}
    }

    /// Tree edge label for tracking cut values
    public final class TreeEdgeLabel {
        /// Cut value for this tree edge
        public var cutvalue: Int = 0

        public init() {}
    }

    /// Type alias for the tree graph
    public typealias Tree = Graph<TreeNodeLabel, TreeEdgeLabel>

    /// Constructs a feasible spanning tree from the graph
    /// The tree will contain only tight edges (slack = 0)
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if edge operations fail
    public static func build(_ g: DagreGraph) throws -> Tree {
        let t = Tree(options: GraphOptions(directed: false))

        guard let start = g.nodes().first else {
            return t
        }

        let size = g.nodeCount()
        t.setNode(start, label: TreeNodeLabel())

        // Build tight tree, adding edges until all nodes are included
        while try tightTree(t, g) < size {
            guard let edge = findMinSlackEdge(t, g) else { break }

            // Calculate delta to make this edge tight
            let delta = t.hasNode(edge.v) ? RankUtil.slack(g, edge: edge) : -RankUtil.slack(g, edge: edge)
            shiftRanks(t, g, delta: delta)
        }

        return t
    }

    /// Extends the tree by DFS along tight edges
    /// Returns the number of nodes in the tree
    private static func tightTree(_ t: Tree, _ g: DagreGraph) throws -> Int {
        func dfs(_ v: String) throws {
            guard let nodeEdges = g.nodeEdges(v) else { return }

            for edge in nodeEdges {
                let w = (v == edge.v) ? edge.w : edge.v

                // Only add nodes not already in tree, and only via tight edges
                if !t.hasNode(w) && RankUtil.slack(g, edge: edge) == 0 {
                    t.setNode(w, label: TreeNodeLabel())
                    try t.setEdge(v, w, label: TreeEdgeLabel())
                    try dfs(w)
                }
            }
        }

        for v in t.nodes() {
            try dfs(v)
        }

        return t.nodeCount()
    }

    /// Finds the edge with minimum slack that crosses the tree boundary
    private static func findMinSlackEdge(_ t: Tree, _ g: DagreGraph) -> Edge? {
        var minSlack = Int.max
        var minEdge: Edge?

        for edge in g.edges() {
            let vInTree = t.hasNode(edge.v)
            let wInTree = t.hasNode(edge.w)

            // Edge must cross tree boundary (one end in tree, one out)
            if vInTree != wInTree {
                let slack = RankUtil.slack(g, edge: edge)
                if slack < minSlack {
                    minSlack = slack
                    minEdge = edge
                }
            }
        }

        return minEdge
    }

    /// Shifts ranks of all tree nodes by delta
    private static func shiftRanks(_ t: Tree, _ g: DagreGraph, delta: Int) {
        for v in t.nodes() {
            if let label = g.node(v) {
                label.rank += delta
            }
        }
    }
}
