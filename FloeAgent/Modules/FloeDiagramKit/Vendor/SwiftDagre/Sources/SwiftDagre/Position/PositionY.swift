// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Assigns Y coordinates to nodes based on their rank
public enum PositionY {

    /// Assigns Y coordinates to all nodes
    /// Nodes in each rank are centered vertically within the rank
    public static func run(_ g: DagreGraph, ranksep: Double) {
        let layering = GraphUtil.buildLayerMatrix(g)
        var prevY: Double = 0

        for layer in layering {
            // Find max height in this layer
            var maxHeight: Double = 0
            for v in layer {
                if let label = g.node(v) {
                    maxHeight = max(maxHeight, label.height)
                }
            }

            // Assign Y coordinate to center of rank
            for v in layer {
                if let label = g.node(v) {
                    label.y = prevY + maxHeight / 2
                }
            }

            // Move to next rank
            prevY += maxHeight + ranksep
        }
    }
}
