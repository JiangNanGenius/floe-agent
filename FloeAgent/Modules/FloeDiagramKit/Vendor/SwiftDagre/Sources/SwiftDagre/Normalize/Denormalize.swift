// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Denormalization algorithms for undoing edge normalization
extension Normalize {

    /// Undoes the normalization by removing dummy nodes and restoring original edges
    /// Collects edge points from dummy node positions
    ///
    /// - Parameters:
    ///   - g: The graph to denormalize
    ///   - dummyChains: List of first dummy node IDs in each chain
    /// - Throws: `GraphError` if edge operations fail
    public static func undo(_ g: DagreGraph, dummyChains: [String]) throws {
        for firstDummy in dummyChains {
            try undoChain(g, firstDummy: firstDummy)
        }
    }

    /// Undoes a single dummy chain
    /// This matches the TypeScript implementation which uses the stored edgeLabel reference
    /// - Throws: `GraphError` if edge operations fail
    private static func undoChain(_ g: DagreGraph, firstDummy: String) throws {
        guard let firstLabel = g.node(firstDummy) else { return }

        // Get the original edge label and edge object references
        // These were stored during normalization
        guard let origLabel = firstLabel.edgeLabel,
              let edgeObj = firstLabel.edgeObj else {
            // Fall back to legacy approach if references not available
            try undoChainLegacy(g, firstDummy: firstDummy, firstLabel: firstLabel)
            return
        }

        // Restore the original edge with its label first (before collecting points)
        // This matches TypeScript: g.setEdge(node.edgeObj, origLabel)
        try g.setEdge(edgeObj.v, edgeObj.w, label: origLabel, name: edgeObj.name)

        var currentV = firstDummy
        var currentLabel = firstLabel

        // Walk through the dummy chain, collecting points and removing dummies
        while currentLabel.dummy != nil {
            // Find successor before removing the node
            guard let successors = g.successors(currentV), let nextV = successors.first else { break }

            // Remove the dummy node
            g.removeNode(currentV)

            // Collect this dummy's position as an edge point
            origLabel.points.append(DagreEdgeLabel.Point(x: currentLabel.x, y: currentLabel.y))

            // If this is an edge-label dummy, capture label position
            if currentLabel.dummy == .edgeLabel {
                origLabel.x = currentLabel.x
                origLabel.y = currentLabel.y
                origLabel.width = currentLabel.width
                origLabel.height = currentLabel.height
                origLabel.hasLabelPosition = true
            }

            // Move to next node
            currentV = nextV
            guard let nextLabel = g.node(currentV) else { break }
            currentLabel = nextLabel
        }
    }

    /// Legacy denormalization for backward compatibility
    /// Used when edgeLabel/edgeObj references are not available
    /// - Throws: `GraphError` if edge operations fail
    private static func undoChainLegacy(_ g: DagreGraph, firstDummy: String, firstLabel: DagreNodeLabel) throws {
        // Get the original edge info from node properties
        guard let edgeSource = firstLabel.edgeSource,
              let edgeTarget = firstLabel.edgeTarget else { return }

        let edgeName = firstLabel.edgeName

        // Collect points from dummy nodes
        var points: [DagreEdgeLabel.Point] = []
        var labelX: Double = 0
        var labelY: Double = 0
        var labelWidth: Double = 0
        var labelHeight: Double = 0
        var hasLabelPosition = false

        var currentV = firstDummy

        while let currentLabel = g.node(currentV), currentLabel.dummy != nil {
            // Find successor
            guard let successors = g.successors(currentV), let nextV = successors.first else { break }

            // Collect this dummy's position as an edge point
            points.append(DagreEdgeLabel.Point(x: currentLabel.x, y: currentLabel.y))

            // If this is an edge-label dummy, capture label info
            if currentLabel.dummy == .edgeLabel {
                labelX = currentLabel.x
                labelY = currentLabel.y
                labelWidth = currentLabel.width
                labelHeight = currentLabel.height
                hasLabelPosition = true
            }

            // Remove the dummy node (this also removes its edges)
            g.removeNode(currentV)

            currentV = nextV
        }

        // Restore the original edge with collected points
        let edgeLabel = DagreEdgeLabel()
        edgeLabel.points = points
        edgeLabel.x = labelX
        edgeLabel.y = labelY
        edgeLabel.width = labelWidth
        edgeLabel.height = labelHeight
        edgeLabel.hasLabelPosition = hasLabelPosition

        try g.setEdge(edgeSource, edgeTarget, label: edgeLabel, name: edgeName)
    }
}
