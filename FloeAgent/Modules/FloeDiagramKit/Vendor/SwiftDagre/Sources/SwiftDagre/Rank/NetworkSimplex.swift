// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Network simplex algorithm for optimal rank assignment
/// Based on Gansner, et al., "A Technique for Drawing Directed Graphs"
public enum NetworkSimplex {

    /// Runs the network simplex algorithm to assign optimal ranks
    /// The algorithm iteratively improves the initial ranking by finding edges
    /// with negative cut values and replacing them with better alternatives
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if edge operations fail
    public static func run(_ g: DagreGraph) throws {
        // Simplify the graph for the algorithm
        let simplified = try GraphUtil.simplify(g)

        // Initialize ranks using longest path
        LongestPath.run(simplified)

        // Build initial feasible spanning tree
        let t = try FeasibleTree.build(simplified)

        // Initialize low/lim values via postorder DFS
        initLowLimValues(t)

        // Initialize cut values for all tree edges
        initCutValues(t, simplified)

        // Pivot loop: find and replace edges with negative cut values
        while let leaveE = leaveEdge(t) {
            if let enterE = enterEdge(t, simplified, leaveE) {
                try exchangeEdges(t, simplified, leave: leaveE, enter: enterE)
            } else {
                break
            }
        }

        // Copy ranks back to original graph
        for v in g.nodes() {
            if let label = g.node(v), let simplifiedLabel = simplified.node(v) {
                label.rank = simplifiedLabel.rank
            }
        }
    }

    // MARK: - Low/Lim Values

    /// Initializes low and lim values via postorder DFS
    /// These values allow O(1) ancestor/descendant checks
    static func initLowLimValues(_ t: FeasibleTree.Tree, root: String? = nil) {
        let startNode = root ?? t.nodes().first
        guard let start = startNode else { return }

        var visited = Set<String>()
        var counter = 1

        func dfs(_ v: String, parent: String?) -> Int {
            guard let label = t.node(v) else { return counter }

            let low = counter
            visited.insert(v)

            if let neighbors = t.neighbors(v) {
                for w in neighbors {
                    if !visited.contains(w) {
                        counter = dfs(w, parent: v)
                    }
                }
            }

            label.low = low
            label.lim = counter
            counter += 1
            label.parent = parent

            return counter
        }

        _ = dfs(start, parent: nil)
    }

    // MARK: - Cut Values

    /// Initializes cut values for all edges in the tree
    static func initCutValues(_ t: FeasibleTree.Tree, _ g: DagreGraph) {
        // Process nodes in postorder (children before parents)
        let nodes = postorder(t)

        // Skip the last node (root)
        for v in nodes.dropLast() {
            assignCutValue(t, g, v)
        }
    }

    /// Assigns the cut value for the edge between a node and its parent
    private static func assignCutValue(_ t: FeasibleTree.Tree, _ g: DagreGraph, _ child: String) {
        guard let childLabel = t.node(child),
              let parent = childLabel.parent else { return }

        let cutValue = calcCutValue(t, g, child)

        // Find the tree edge between child and parent (undirected)
        if let edgeLabel = t.edge(child, parent) {
            edgeLabel.cutvalue = cutValue
        } else if let edgeLabel = t.edge(parent, child) {
            edgeLabel.cutvalue = cutValue
        }
    }

    /// Calculates the cut value for the edge between child and its parent
    static func calcCutValue(_ t: FeasibleTree.Tree, _ g: DagreGraph, _ child: String) -> Int {
        guard let childLabel = t.node(child),
              let parent = childLabel.parent else { return 0 }

        // Determine the direction of the edge in the original graph
        var childIsTail = true
        var graphEdgeLabel = g.edge(child, parent)

        if graphEdgeLabel == nil {
            childIsTail = false
            graphEdgeLabel = g.edge(parent, child)
        }

        guard let edgeLabel = graphEdgeLabel else { return 0 }

        var cutValue = edgeLabel.weight

        // Process all edges incident to child
        guard let nodeEdges = g.nodeEdges(child) else { return cutValue }

        for e in nodeEdges {
            let isOutEdge = e.v == child
            let other = isOutEdge ? e.w : e.v

            if other != parent {
                let pointsToHead = isOutEdge == childIsTail
                let otherWeight = g.edge(e.id)?.weight ?? 1

                cutValue += pointsToHead ? otherWeight : -otherWeight

                // If there's a tree edge to this other node, factor in its cut value
                if isTreeEdge(t, child, other) {
                    if let otherCutValue = getTreeEdgeCutValue(t, child, other) {
                        cutValue += pointsToHead ? -otherCutValue : otherCutValue
                    }
                }
            }
        }

        return cutValue
    }

    /// Checks if there is a tree edge from u to v
    /// TypeScript only checks one direction: tree.hasEdge(u, v)
    private static func isTreeEdge(_ t: FeasibleTree.Tree, _ u: String, _ v: String) -> Bool {
        t.hasEdge(u, v)
    }

    /// Gets the cut value of the tree edge between u and v
    private static func getTreeEdgeCutValue(_ t: FeasibleTree.Tree, _ u: String, _ v: String) -> Int? {
        if let label = t.edge(u, v) {
            return label.cutvalue
        }
        if let label = t.edge(v, u) {
            return label.cutvalue
        }
        return nil
    }

    // MARK: - Leave Edge

    /// Finds a tree edge with negative cut value (to be removed)
    static func leaveEdge(_ t: FeasibleTree.Tree) -> Edge? {
        for edge in t.edges() {
            if let label = t.edge(edge.id), label.cutvalue < 0 {
                return edge
            }
        }
        return nil
    }

    // MARK: - Enter Edge

    /// Finds the best non-tree edge to add when removing the leave edge
    static func enterEdge(_ t: FeasibleTree.Tree, _ g: DagreGraph, _ edge: Edge) -> Edge? {
        var v = edge.v
        var w = edge.w

        // Ensure v is the tail and w is the head in the original graph
        if !g.hasEdge(v, w) {
            let temp = v
            v = w
            w = temp
        }

        guard let vLabel = t.node(v),
              let wLabel = t.node(w) else { return nil }

        // Determine which side of the edge the root is on
        var tailLabel = vLabel
        var flip = false

        if vLabel.lim > wLabel.lim {
            tailLabel = wLabel
            flip = true
        }

        // Find candidate edges that cross the cut
        let candidates = g.edges().filter { e in
            guard let evLabel = t.node(e.v),
                  let ewLabel = t.node(e.w) else { return false }

            let vIsDescendant = isDescendant(evLabel, of: tailLabel)
            let wIsDescendant = isDescendant(ewLabel, of: tailLabel)

            return flip == vIsDescendant && flip != wIsDescendant
        }

        // Find the candidate with minimum slack
        var minSlack = Int.max
        var result: Edge?

        for candidate in candidates {
            let slack = RankUtil.slack(g, edge: candidate)
            if slack < minSlack {
                minSlack = slack
                result = candidate
            }
        }

        return result
    }

    /// Checks if vLabel is a descendant of rootLabel using low/lim values
    private static func isDescendant(_ vLabel: FeasibleTree.TreeNodeLabel, of rootLabel: FeasibleTree.TreeNodeLabel) -> Bool {
        rootLabel.low <= vLabel.lim && vLabel.lim <= rootLabel.lim
    }

    // MARK: - Exchange Edges

    /// Exchanges edges in the tree: removes leave edge, adds enter edge
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if edge creation fails
    static func exchangeEdges(_ t: FeasibleTree.Tree, _ g: DagreGraph, leave: Edge, enter: Edge) throws {
        // Remove the leaving edge
        t.removeEdge(leave.v, leave.w)
        t.removeEdge(leave.w, leave.v)

        // Add the entering edge
        try t.setEdge(enter.v, enter.w, label: FeasibleTree.TreeEdgeLabel())

        // Reinitialize low/lim values and cut values
        initLowLimValues(t)
        initCutValues(t, g)

        // Update ranks based on the new tree
        updateRanks(t, g)
    }

    /// Updates ranks based on the current tree structure
    /// Matches TypeScript updateRanks in network-simplex.js lines 204-220
    private static func updateRanks(_ t: FeasibleTree.Tree, _ g: DagreGraph) {
        // Find the root - TypeScript line 205: var root = t.nodes().find(v => !g.node(v).parent)
        // Note: TypeScript checks g.node(v).parent (the GRAPH node's parent), not t.node(v).parent
        guard let root = t.nodes().first(where: { g.node($0)?.parent == nil }) else { return }

        // Process nodes in preorder
        let nodes = preorder(t, root: root)

        // Skip the root itself (TypeScript line 207: vs = vs.slice(1))
        for v in nodes.dropFirst() {
            guard let tLabel = t.node(v),
                  let parent = tLabel.parent,
                  let gLabel = g.node(v),
                  let parentGLabel = g.node(parent) else { continue }

            // Find the edge between v and parent in the original graph
            // TypeScript lines 210-218
            var flipped = false
            var edgeLabel = g.edge(v, parent)

            if edgeLabel == nil {
                edgeLabel = g.edge(parent, v)
                flipped = true
            }

            guard let edge = edgeLabel else { continue }

            // TypeScript line 218: g.node(v).rank = g.node(parent).rank + (flipped ? edge.minlen : -edge.minlen)
            gLabel.rank = parentGLabel.rank + (flipped ? edge.minlen : -edge.minlen)
        }
    }

    // MARK: - Tree Traversal

    /// Returns nodes in postorder (children before parents)
    private static func postorder(_ t: FeasibleTree.Tree) -> [String] {
        var result: [String] = []
        var visited = Set<String>()

        guard let start = t.nodes().first else { return result }

        func dfs(_ v: String) {
            visited.insert(v)

            if let neighbors = t.neighbors(v) {
                for w in neighbors where !visited.contains(w) {
                    dfs(w)
                }
            }

            result.append(v)
        }

        dfs(start)
        return result
    }

    /// Returns nodes in preorder (parents before children)
    private static func preorder(_ t: FeasibleTree.Tree, root: String) -> [String] {
        var result: [String] = []
        var visited = Set<String>()

        func dfs(_ v: String) {
            visited.insert(v)
            result.append(v)

            if let neighbors = t.neighbors(v) {
                for w in neighbors where !visited.contains(w) {
                    dfs(w)
                }
            }
        }

        dfs(root)
        return result
    }
}
