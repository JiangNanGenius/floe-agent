// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Position assignment for nodes in a layered graph
public enum Position {

    /// Assigns x and y coordinates to all nodes
    /// - Throws: `GraphError` if graph operations fail
    public static func run(_ g: DagreGraph, nodesep: Double, edgesep: Double, ranksep: Double, align: LayoutOptions.Alignment? = nil) throws {
        // Create non-compound version for positioning
        let nonCompound = try GraphUtil.asNonCompoundGraph(g)

        // Assign Y coordinates based on rank
        PositionY.run(nonCompound, ranksep: ranksep)

        // Assign X coordinates using Brandes-Kopf
        let xs = try BrandesKopf.positionX(nonCompound, nodesep: nodesep, edgesep: edgesep, align: align)

        // Apply positions back to original graph
        for (v, x) in xs {
            if let label = g.node(v) {
                label.x = x
            }
        }

        // Copy Y positions
        for v in nonCompound.nodes() {
            if let ncLabel = nonCompound.node(v), let label = g.node(v) {
                label.y = ncLabel.y
            }
        }
    }
}
