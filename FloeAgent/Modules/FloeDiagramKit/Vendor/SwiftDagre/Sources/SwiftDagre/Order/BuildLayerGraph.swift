// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Builds a layer graph for a specific rank to use in ordering
///
/// The layer graph contains all base and subgraph nodes from the requested layer
/// in their original hierarchy, along with edges incident on these nodes.
/// For compound nodes, it extracts the specific border node ID for that rank.
public enum BuildLayerGraph {

    /// Node label for layer graph - contains only the data needed for ordering
    public final class LayerNodeLabel {
        public var order: Int = 0
        /// For compound nodes: the specific border node ID at this rank
        public var borderLeft: String?
        public var borderRight: String?

        public init() {}
    }

    /// Edge label for layer graph
    public struct LayerEdgeLabel {
        public var weight: Int

        public init(weight: Int = 1) {
            self.weight = weight
        }
    }

    /// Result containing the layer graph and its root node
    public struct Result {
        public let graph: Graph<LayerNodeLabel, LayerEdgeLabel>
        public let root: String
    }

    /// Builds a layer graph for the given rank
    ///
    /// - Parameters:
    ///   - g: The main graph
    ///   - rank: The rank to build a layer graph for
    ///   - relationship: Either "inEdges" or "outEdges"
    ///   - nodesWithRank: Pre-computed list of nodes that belong to this rank (optional optimization)
    /// - Returns: A layer graph with compound hierarchy preserved and rank-specific border nodes
    public static func build(_ g: DagreGraph, rank: Int, relationship: String, nodesWithRank: [String]? = nil) throws -> Result {
        let root = createRootNode(g)
        let result = Graph<LayerNodeLabel, LayerEdgeLabel>(
            options: GraphOptions(directed: true, multigraph: false, compound: true)
        )

        // CRITICAL: Set default node label factory to copy order from main graph
        // This matches TypeScript: .setDefaultNodeLabel((v) => g.node(v))
        // When edges are added, predecessor nodes from adjacent ranks need their 'order'
        // property so barycenter calculations work correctly
        result.setDefaultNodeLabel { v in
            let label = LayerNodeLabel()
            if let mainNode = g.node(v) {
                label.order = mainNode.order
            }
            return label
        }

        // Use pre-computed nodes if provided, otherwise iterate all nodes
        let nodesToProcess = nodesWithRank ?? g.nodes()

        // Process nodes that belong to this rank
        for v in nodesToProcess {
            guard let node = g.node(v) else { continue }

            // Check if this node belongs to this rank
            // (When nodesWithRank is provided, nodes are already filtered, but we still check)
            let belongsToRank: Bool
            if let minRank = node.minRank, let maxRank = node.maxRank {
                // Compound node spans multiple ranks
                belongsToRank = minRank <= rank && rank <= maxRank
            } else {
                // Regular node has single rank
                belongsToRank = node.rank == rank
            }

            guard belongsToRank else { continue }

            // Add node to layer graph
            let label = LayerNodeLabel()
            label.order = node.order
            result.setNode(v, label: label)

            // Set parent (or root if no parent)
            let parent = g.parent(v) ?? root
            if !result.hasNode(root) {
                result.setNode(root, label: LayerNodeLabel())
            }
            try result.setParent(v, parent: parent)

            // Add edges based on relationship
            let edges: [Edge]?
            if relationship == "inEdges" {
                edges = g.inEdges(v)
            } else {
                edges = g.outEdges(v)
            }

            if let edges = edges {
                for e in edges {
                    let u = e.v == v ? e.w : e.v
                    let edgeWeight = g.edge(e.id)?.weight ?? 1

                    // Aggregate weights for multiple edges between same nodes
                    let existingWeight = result.edge(u, v)?.weight ?? 0
                    try result.setEdge(u, v, label: LayerEdgeLabel(weight: existingWeight + edgeWeight))
                }
            }

            // For compound nodes, set rank-specific border node IDs
            if node.minRank != nil {
                if let borderLeftId = node.borderLeft[rank] {
                    label.borderLeft = borderLeftId
                }
                if let borderRightId = node.borderRight[rank] {
                    label.borderRight = borderRightId
                }
            }
        }

        // Make sure root exists
        if !result.hasNode(root) {
            result.setNode(root, label: LayerNodeLabel())
        }

        return Result(graph: result, root: root)
    }

    /// Creates a unique root node ID
    private static func createRootNode(_ g: DagreGraph) -> String {
        var counter = 0
        var v = "_root\(counter)"
        while g.hasNode(v) {
            counter += 1
            v = "_root\(counter)"
        }
        return v
    }
}
