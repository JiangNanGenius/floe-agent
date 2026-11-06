// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Adds border nodes around compound nodes to enable proper dimension calculation
enum AddBorderSegments {

    /// Adds left and right border nodes for each rank spanned by compound nodes.
    /// These border nodes are used to calculate compound node dimensions after positioning.
    static func run(_ g: DagreGraph) throws {
        guard g.isCompound else { return }

        // DFS from root children
        for v in g.children(nil) ?? [] {
            try dfs(g, v: v)
        }
    }

    private static func dfs(_ g: DagreGraph, v: String) throws {
        // Process children first (depth-first)
        if let children = g.children(v) {
            for child in children {
                try dfs(g, v: child)
            }
        }

        guard let node = g.node(v) else { return }

        // Only process compound nodes (those with minRank set)
        guard let minRank = node.minRank, let maxRank = node.maxRank else { return }

        // Create border node arrays
        node.borderLeft = [:]
        node.borderRight = [:]

        // Add border nodes for each rank
        for rank in minRank...maxRank {
            try addBorderNode(g, prop: "borderLeft", prefix: "_bl", sg: v, sgNode: node, rank: rank)
            try addBorderNode(g, prop: "borderRight", prefix: "_br", sg: v, sgNode: node, rank: rank)
        }
    }

    private static func addBorderNode(_ g: DagreGraph, prop: String, prefix: String, sg: String, sgNode: DagreNodeLabel, rank: Int) throws {
        // Add the border node with unique ID
        let curr = GraphUtil.addBorderNode(g, prefix: prefix, rank: rank)

        // Set border type on the node
        if let label = g.node(curr) {
            label.borderType = prop == "borderLeft" ? .left : .right
        }

        // Store in the appropriate border array
        if prop == "borderLeft" {
            sgNode.borderLeft[rank] = curr
        } else {
            sgNode.borderRight[rank] = curr
        }

        // Set parent to the compound node
        try g.setParent(curr, parent: sg)

        // Link to previous border node in the same column (if exists)
        let prevRank = rank - 1
        let prev: String?
        if prop == "borderLeft" {
            prev = sgNode.borderLeft[prevRank]
        } else {
            prev = sgNode.borderRight[prevRank]
        }

        if let prev = prev {
            let edgeLabel = DagreEdgeLabel(minlen: 1, weight: 1)
            try g.setEdge(prev, curr, label: edgeLabel)
        }
    }
}
