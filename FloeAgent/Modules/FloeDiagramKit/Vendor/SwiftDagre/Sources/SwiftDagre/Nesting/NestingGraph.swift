// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Nesting graph algorithms for compound node support
/// Based on Sander, "Layout of Compound Directed Graphs"
public enum NestingGraph {

    /// Extended layout options with nesting-specific properties
    public final class NestingOptions {
        /// Root node for nesting
        public var nestingRoot: String?

        /// Factor to multiply ranks for node separation
        public var nodeRankFactor: Int = 1

        public init() {}
    }

    /// Adds dummy nodes for compound graph borders and connects them
    ///
    /// This creates top and bottom border nodes for each compound node,
    /// ensures all cluster nodes are placed between these boundaries,
    /// and ensures the graph is connected.
    public static func run(_ g: DagreGraph) throws -> NestingOptions {
        let options = NestingOptions()

        // Add root dummy node
        let root = GraphUtil.addDummyNode(g, type: .root, prefix: "_root")

        // Calculate tree depths
        let depths = treeDepths(g)

        // Calculate height based on maximum depth
        let maxDepth = depths.values.max() ?? 0
        let height = max(0, maxDepth - 1)
        let nodeSep = 2 * height + 1

        options.nestingRoot = root
        options.nodeRankFactor = nodeSep

        // Store nodeRankFactor on graph options for use by removeEmptyRanks
        // This matches TypeScript: g.graph().nodeRankFactor = nodeSep;
        if let graphOpts = g.graph() as? LayoutOptions {
            graphOpts.nodeRankFactor = nodeSep
        }

        // Multiply minlen by nodeSep to align nodes on non-border ranks
        for edge in g.edges() {
            if let label = g.edge(edge.id) {
                label.minlen *= nodeSep
            }
        }

        // Calculate weight to keep subgraphs vertically compact
        let weight = sumWeights(g) + 1

        // Create border nodes and link them up
        if let children = g.children(nil) {
            for child in children {
                try dfs(g, root: root, nodeSep: nodeSep, weight: weight, height: height, depths: depths, v: child)
            }
        }

        return options
    }

    /// DFS to create border nodes for compound nodes
    private static func dfs(
        _ g: DagreGraph,
        root: String,
        nodeSep: Int,
        weight: Int,
        height: Int,
        depths: [String: Int],
        v: String
    ) throws {
        guard let children = g.children(v), !children.isEmpty else {
            // Leaf node - connect to root
            if v != root {
                let label = DagreEdgeLabel(minlen: nodeSep, weight: 0)
                try g.setEdge(root, v, label: label)
            }
            return
        }

        // Create top and bottom border nodes
        let top = GraphUtil.addBorderNode(g, prefix: "_bt")
        let bottom = GraphUtil.addBorderNode(g, prefix: "_bb")

        if let label = g.node(v) {
            // Set parent for border nodes
            try g.setParent(top, parent: v)
            try g.setParent(bottom, parent: v)

            // Store border node references (single strings, not dictionaries)
            label.borderTop = top
            label.borderBottom = bottom
        }

        // Process children
        for child in children {
            try dfs(g, root: root, nodeSep: nodeSep, weight: weight, height: height, depths: depths, v: child)

            guard let childNode = g.node(child) else { continue }

            let childTop = childNode.borderTop ?? child
            let childBottom = childNode.borderBottom ?? child

            let thisWeight = childNode.borderTop != nil ? weight : 2 * weight
            let childDepth = depths[v] ?? 0
            let minlen = (childTop != childBottom) ? 1 : height - childDepth + 1

            // Edge from top to child's top
            let topLabel = DagreEdgeLabel(minlen: minlen, weight: thisWeight)
            topLabel.nestingEdge = true
            try g.setEdge(top, childTop, label: topLabel)

            // Edge from child's bottom to bottom
            let bottomLabel = DagreEdgeLabel(minlen: minlen, weight: thisWeight)
            bottomLabel.nestingEdge = true
            try g.setEdge(childBottom, bottom, label: bottomLabel)
        }

        // Connect to root if this is a top-level compound node
        if g.parent(v) == nil {
            let depth = depths[v] ?? 0
            let label = DagreEdgeLabel(minlen: height + depth, weight: 0)
            try g.setEdge(root, top, label: label)
        }
    }

    /// Calculates the depth of each node in the compound hierarchy
    private static func treeDepths(_ g: DagreGraph) -> [String: Int] {
        var depths: [String: Int] = [:]

        func dfs(_ v: String, depth: Int) {
            depths[v] = depth

            if let children = g.children(v), !children.isEmpty {
                for child in children {
                    dfs(child, depth: depth + 1)
                }
            }
        }

        // Start from root children
        if let children = g.children(nil) {
            for child in children {
                dfs(child, depth: 1)
            }
        }

        return depths
    }

    /// Sums all edge weights in the graph
    private static func sumWeights(_ g: DagreGraph) -> Int {
        var sum = 0
        for edge in g.edges() {
            if let label = g.edge(edge.id) {
                sum += label.weight
            }
        }
        return sum
    }

    /// Cleans up the nesting graph by removing the root and nesting edges
    public static func cleanup(_ g: DagreGraph, options: NestingOptions) {
        // Remove the nesting root node
        if let root = options.nestingRoot {
            g.removeNode(root)
        }

        // Remove all nesting edges (those marked with nestingEdge: true)
        // These are the edges created between border nodes and child nodes
        for edge in g.edges() {
            if let label = g.edge(edge.id), label.nestingEdge {
                g.removeEdge(edge.v, edge.w, name: edge.name)
            }
        }
    }
}
