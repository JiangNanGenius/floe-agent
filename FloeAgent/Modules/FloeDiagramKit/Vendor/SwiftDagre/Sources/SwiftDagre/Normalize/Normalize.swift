// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Normalization algorithms for breaking long edges into unit-length segments
public enum Normalize {

    /// Breaks any long edges in the graph into short segments that span 1 rank each
    /// Adds dummy nodes where edges have been split
    ///
    /// Preconditions:
    ///   1. The input graph is a DAG
    ///   2. Each node in the graph has a "rank" property
    ///
    /// Postconditions:
    ///   1. All edges in the graph have a length of 1
    ///   2. Dummy nodes are added where edges have been split into segments
    ///   3. Returns list of first dummies in each chain (for later denormalization)
    /// - Throws: `GraphError` if edge operations fail
    public static func run(_ g: DagreGraph) throws -> [String] {
        var dummyChains: [String] = []

        // Process edges (collect first since we modify during iteration)
        let edges = g.edges()

        for edge in edges {
            try normalizeEdge(g, edge: edge, dummyChains: &dummyChains)
        }

        return dummyChains
    }

    /// Normalizes a single edge by inserting dummy nodes
    /// - Throws: `GraphError` if edge operations fail
    private static func normalizeEdge(_ g: DagreGraph, edge: Edge, dummyChains: inout [String]) throws {
        guard let vLabel = g.node(edge.v),
              let wLabel = g.node(edge.w),
              let edgeLabel = g.edge(edge.id) else { return }

        let vRank = vLabel.rank
        let wRank = wLabel.rank

        // If edge already has length 1, nothing to do
        if wRank == vRank + 1 { return }

        // Remove the original edge
        g.removeEdge(edge.v, edge.w, name: edge.name)

        // Clear points for collecting dummy node positions later
        edgeLabel.points = []

        // Get the label rank (set by removeEdgeLabelProxies)
        let labelRank = edgeLabel.labelRank ?? ((vRank + wRank) / 2)

        // Insert dummy nodes for each intermediate rank
        var currentV = edge.v
        var currentRank = vRank + 1
        var isFirst = true

        while currentRank < wRank {
            // Create dummy node with reference to original edge label and edge object
            // This is critical for denormalization to preserve all edge properties
            let dummyId = GraphUtil.addDummyNode(
                g,
                type: .edge,
                width: 0,
                height: 0,
                rank: currentRank,
                edgeSource: edge.v,
                edgeTarget: edge.w,
                edgeName: edge.name
            )

            let dummyLabel = g.node(dummyId)!

            // Store reference to original edge label and edge object for denormalization
            // This matches TypeScript: attrs = { edgeLabel: edgeLabel, edgeObj: e, ... }
            dummyLabel.edgeLabel = edgeLabel
            dummyLabel.edgeObj = (v: edge.v, w: edge.w, name: edge.name)

            // Check if this is the rank where the edge label should be placed
            if currentRank == labelRank && (edgeLabel.width > 0 || edgeLabel.height > 0) {
                dummyLabel.dummy = .edgeLabel
                dummyLabel.width = edgeLabel.width
                dummyLabel.height = edgeLabel.height
                dummyLabel.labelpos = edgeLabel.labelpos
            }

            // Add edge from current to dummy
            let chainEdgeLabel = DagreEdgeLabel(minlen: 1, weight: edgeLabel.weight)
            try g.setEdge(currentV, dummyId, label: chainEdgeLabel, name: edge.name)

            // Track first dummy in chain
            if isFirst {
                dummyChains.append(dummyId)
                isFirst = false
            }

            currentV = dummyId
            currentRank += 1
        }

        // Add final edge from last dummy to target
        let finalEdgeLabel = DagreEdgeLabel(minlen: 1, weight: edgeLabel.weight)
        try g.setEdge(currentV, edge.w, label: finalEdgeLabel, name: edge.name)
    }
}
