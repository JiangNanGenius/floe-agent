// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Main entry point for the dagre layout algorithm
public enum SwiftDagreLayout {

    /// Runs the dagre layout algorithm on the graph
    /// Assigns x, y coordinates to all nodes and points to all edges
    /// - Throws: `GraphError` if the layout encounters an invalid graph state
    public static func layout(_ g: DagreGraph, options: LayoutOptions? = nil) throws {
        let opts = options ?? (g.graph() as? LayoutOptions) ?? LayoutOptions()

        // Set up graph options - always ensure the graph has the options object
        // This ensures dimensions can be read back from g.graph() after layout
        g.setGraph(opts)

        // Build an internal layout graph (always multigraph: true, compound: true)
        // This matches dagrejs behavior and allows edge reversals to use unique names
        let layoutGraph = try buildLayoutGraph(g, options: opts)

        // Run the layout pipeline on the internal graph
        try runLayout(layoutGraph, options: opts)

        // Copy results back to the input graph
        updateInputGraph(g, layoutGraph: layoutGraph)
    }

    // MARK: - Build Layout Graph

    /// Constructs a new graph from the input graph for layout
    /// This process copies nodes and edges to an internal multigraph,
    /// which allows edge reversals during acyclic transformation to work correctly
    private static func buildLayoutGraph(_ inputGraph: DagreGraph, options: LayoutOptions) throws -> DagreGraph {
        // Always create a multigraph with compound support for internal layout
        // This is critical for handling bidirectional edges correctly
        let g = Graph<DagreNodeLabel, DagreEdgeLabel>(
            options: GraphOptions(directed: true, multigraph: true, compound: true)
        )

        // Copy graph-level options
        g.setGraph(options)
        // Copy all nodes
        for v in inputGraph.nodes() {
            if let inputLabel = inputGraph.node(v) {
                // Create a copy of the node label
                let newLabel = DagreNodeLabel(width: inputLabel.width, height: inputLabel.height)
                newLabel.rank = inputLabel.rank
                newLabel.order = inputLabel.order
                newLabel.x = inputLabel.x
                newLabel.y = inputLabel.y
                newLabel.dummy = inputLabel.dummy
                newLabel.edgeSource = inputLabel.edgeSource
                newLabel.edgeTarget = inputLabel.edgeTarget
                newLabel.edgeName = inputLabel.edgeName
                newLabel.borderType = inputLabel.borderType
                newLabel.borderTop = inputLabel.borderTop
                newLabel.borderBottom = inputLabel.borderBottom
                newLabel.borderLeft = inputLabel.borderLeft
                newLabel.borderRight = inputLabel.borderRight
                newLabel.minRank = inputLabel.minRank
                newLabel.maxRank = inputLabel.maxRank
                g.setNode(v, label: newLabel)

                // Copy parent relationship for compound graphs
                if inputGraph.isCompound, let parent = inputGraph.parent(v) {
                    try g.setParent(v, parent: parent)
                }
            } else {
                g.setNode(v)
                if inputGraph.isCompound, let parent = inputGraph.parent(v) {
                    try g.setParent(v, parent: parent)
                }
            }
        }

        // Copy all edges
        for edge in inputGraph.edges() {
            if let inputLabel = inputGraph.edge(edge.id) {
                // Create a copy of the edge label
                let newLabel = DagreEdgeLabel(minlen: inputLabel.minlen, weight: inputLabel.weight)
                newLabel.width = inputLabel.width
                newLabel.height = inputLabel.height
                newLabel.labelpos = inputLabel.labelpos
                newLabel.labeloffset = inputLabel.labeloffset
                newLabel.x = inputLabel.x
                newLabel.y = inputLabel.y
                newLabel.points = inputLabel.points
                newLabel.reversed = inputLabel.reversed
                newLabel.forwardName = inputLabel.forwardName
                try g.setEdge(edge.v, edge.w, label: newLabel, name: edge.name)
            } else {
                try g.setEdge(edge.v, edge.w, name: edge.name)
            }
        }

        return g
    }

    /// Copies final layout information from the layout graph back to the input graph
    private static func updateInputGraph(_ inputGraph: DagreGraph, layoutGraph: DagreGraph) {
        // Copy node positions
        for v in inputGraph.nodes() {
            if let inputLabel = inputGraph.node(v),
               let layoutLabel = layoutGraph.node(v) {
                inputLabel.x = layoutLabel.x
                inputLabel.y = layoutLabel.y
                inputLabel.rank = layoutLabel.rank

                // For compound nodes with children, also copy updated dimensions
                // (layoutGraph is always compound, so children() returns an array)
                if let children = layoutGraph.children(v), !children.isEmpty {
                    inputLabel.width = layoutLabel.width
                    inputLabel.height = layoutLabel.height
                }
            }
        }

        // Copy edge points
        for edge in inputGraph.edges() {
            if let inputLabel = inputGraph.edge(edge.id),
               let layoutLabel = layoutGraph.edge(edge.v, edge.w, name: edge.name) {
                inputLabel.points = layoutLabel.points
                inputLabel.x = layoutLabel.x
                inputLabel.y = layoutLabel.y
            }
        }

        // Copy graph dimensions
        if let layoutOpts = layoutGraph.graph() as? LayoutOptions,
           let inputOpts = inputGraph.graph() as? LayoutOptions {
            inputOpts.width = layoutOpts.width
            inputOpts.height = layoutOpts.height
        }
    }

    /// Runs the complete layout pipeline
    /// This follows the exact order of the TypeScript dagre implementation
    private static func runLayout(_ g: DagreGraph, options: LayoutOptions) throws {
        // 1. Make space for edge labels by doubling minlen and halving ranksep
        makeSpaceForEdgeLabels(g, options: options)

        // 2. Remove self-edges temporarily
        let selfEdges = removeSelfEdges(g)

        // 3. Make the graph acyclic by reversing back edges
        try Acyclic.run(g, algorithm: options.acyclicer)

        // 4. Handle compound nodes with nesting graph
        // IMPORTANT: TypeScript dagre ALWAYS runs nestingGraph.run, not just for compound graphs.
        // This sets nodeRankFactor which is used by removeEmptyRanks to preserve intermediate ranks.
        // For simple graphs, nodeRankFactor=1, which prevents ANY empty ranks from being removed.
        // This is critical for maintaining proper rank spacing when minlen is doubled.
        let nestingOptions = try NestingGraph.run(g)

        // 5. Assign ranks to nodes (on non-compound graph)
        let nonCompoundGraph = g.isCompound ? try GraphUtil.asNonCompoundGraph(g) : g
        try Rank.run(nonCompoundGraph, algorithm: options.ranker, customRanker: options.customRanker)

        // Copy ranks back to compound graph
        if g.isCompound {
            for v in nonCompoundGraph.nodes() {
                if let ncLabel = nonCompoundGraph.node(v), let label = g.node(v) {
                    label.rank = ncLabel.rank
                }
            }
        }

        // 5.5. Inject edge label proxy nodes to preserve label ranks during removeEmptyRanks
        injectEdgeLabelProxies(g)

        // 6. Remove empty ranks (must happen before nestingGraph.cleanup)
        GraphUtil.removeEmptyRanks(g)

        // 7. Clean up nesting graph (always runs since we always call NestingGraph.run)
        NestingGraph.cleanup(g, options: nestingOptions)

        // 8. Normalize ranks
        GraphUtil.normalizeRanks(g)

        // 9. Assign min/max ranks to compound nodes (after normalizeRanks)
        assignRankMinMax(g)

        // 9.5. Remove edge label proxy nodes and store labelRank on edges
        removeEdgeLabelProxies(g)

        // 10. Normalize edges (add dummy nodes for long edges)
        let dummyChains = try Normalize.run(g)

        // 11. Parent dummy chains for compound graphs
        if g.isCompound {
            try ParentDummyChains.run(g, dummyChains: dummyChains)
        }

        // 12. Add border segments around compound nodes
        try AddBorderSegments.run(g)

        // 13. Order nodes to minimize edge crossings
        try Order.run(g, customOrder: options.customOrder)

        // 14. Insert self-edges back
        insertSelfEdges(g, selfEdges: selfEdges)

        // 15. Adjust coordinates for rankdir (swap width/height for LR/RL)
        // Note: This happens AFTER order in TypeScript dagre
        adjustCoordinateSystem(g, rankdir: options.rankdir)

        // 16. Assign x, y coordinates
        try Position.run(g, nodesep: options.nodesep, edgesep: options.edgesep, ranksep: options.ranksep, align: options.align)

        // 17. Position self-edges
        try positionSelfEdges(g)

        // 18. Remove border nodes and compute compound node dimensions
        removeBorderNodes(g)

        // 19. Denormalize (remove dummy nodes, collect edge points)
        try Normalize.undo(g, dummyChains: dummyChains)

        // 19.5. Adjust edge label coordinates based on labelpos
        fixupEdgeLabelCoords(g)

        // 20. Undo coordinate system adjustment (swap x/y for LR/RL, negate for BT/RL)
        undoCoordinateSystem(g, rankdir: options.rankdir)

        // 21. Translate graph to origin and apply margins (also calculates dimensions)
        let (width, height) = translateGraph(g, marginx: options.marginx, marginy: options.marginy)

        // 22. Calculate edge-node intersections
        try assignNodeIntersects(g)

        // 23. Reverse points for reversed edges
        reversePointsForReversedEdges(g)

        // 24. Undo acyclic transformation
        try Acyclic.undo(g)

        // 25. Store dimensions calculated by translateGraph (matching dagrejs behavior)
        options.width = width
        options.height = height

        // Also store on the graph object to match TypeScript behavior
        if let graphOpts = g.graph() as? LayoutOptions {
            graphOpts.width = width
            graphOpts.height = height
        }
    }

    // MARK: - Compound Node Support

    /// Assigns minRank and maxRank to compound nodes based on their border nodes
    /// This is called after normalizeRanks and before normalize.run
    private static func assignRankMinMax(_ g: DagreGraph) {
        guard g.isCompound else { return }

        var graphMaxRank = 0

        for v in g.nodes() {
            guard let node = g.node(v) else { continue }

            // If this node has a borderTop, it's a compound node
            // (borderTop is set by NestingGraph.run)
            if let borderTop = node.borderTop,
               let borderBottom = node.borderBottom,
               let topNode = g.node(borderTop),
               let bottomNode = g.node(borderBottom) {
                node.minRank = topNode.rank
                node.maxRank = bottomNode.rank
                graphMaxRank = max(graphMaxRank, bottomNode.rank)
            }
        }

        // Store max rank on graph options
        // Note: LayoutOptions doesn't have maxRank, but it's tracked internally
        // This matches the TS behavior: g.graph().maxRank = maxRank
        _ = g.graph() as? LayoutOptions
    }

    /// Removes border nodes and computes compound node dimensions
    /// This is called after position and before normalize.undo
    private static func removeBorderNodes(_ g: DagreGraph) {
        guard g.isCompound else { return }

        // First pass: compute dimensions from border nodes
        for v in g.nodes() {
            // Only process compound nodes (those with children)
            guard let children = g.children(v), !children.isEmpty else { continue }
            guard let node = g.node(v) else { continue }

            // Get border nodes
            guard let borderTop = node.borderTop,
                  let borderBottom = node.borderBottom,
                  let t = g.node(borderTop),
                  let b = g.node(borderBottom) else {
                continue
            }

            // Get the last border nodes (highest rank) from borderLeft and borderRight
            // In TS: node.borderLeft[node.borderLeft.length - 1]
            // Since we use dictionaries with rank as key, we need to find the max rank
            let maxRank = node.maxRank ?? node.borderLeft.keys.max() ?? 0
            guard let leftId = node.borderLeft[maxRank],
                  let rightId = node.borderRight[maxRank],
                  let l = g.node(leftId),
                  let r = g.node(rightId) else {
                continue
            }

            // Compute dimensions from border positions
            node.width = abs(r.x - l.x)
            node.height = abs(b.y - t.y)
            node.x = l.x + node.width / 2
            node.y = t.y + node.height / 2
        }

        // Second pass: remove all border dummy nodes
        let nodesToRemove = g.nodes().filter { v in
            g.node(v)?.dummy == .border
        }
        for v in nodesToRemove {
            g.removeNode(v)
        }
    }

    // MARK: - Layout Steps

    /// Makes space for edge labels by doubling minlen and halving ranksep
    /// This technique comes from the Gansner paper: to account for edge labels
    /// we split each rank in half by doubling minlen and halving ranksep.
    /// Then we can place labels at these mid-points between nodes.
    private static func makeSpaceForEdgeLabels(_ g: DagreGraph, options: LayoutOptions) {
        // Halve ranksep to make room for edge labels between ranks
        options.ranksep /= 2

        for edge in g.edges() {
            guard let label = g.edge(edge.id) else { continue }

            // Double minlen to create space for edge label
            label.minlen *= 2

            // Add label offset to width/height based on position and direction
            if label.labelpos != .center {
                if options.rankdir == .topBottom || options.rankdir == .bottomTop {
                    label.width += label.labeloffset
                } else {
                    label.height += label.labeloffset
                }
            }
        }
    }

    /// Creates temporary dummy nodes that capture the rank in which each edge's
    /// label is going to, if it has one of non-zero width and height.
    /// We do this so that we can safely remove empty ranks while preserving
    /// balance for the label's position.
    private static func injectEdgeLabelProxies(_ g: DagreGraph) {
        for edge in g.edges() {
            guard let edgeLabel = g.edge(edge.id) else { continue }

            // Only create proxy for edges with labels (non-zero width and height)
            if edgeLabel.width > 0 && edgeLabel.height > 0 {
                guard let vNode = g.node(edge.v),
                      let wNode = g.node(edge.w) else { continue }

                // Calculate the rank at the midpoint between source and target
                let proxyRank = (wNode.rank - vNode.rank) / 2 + vNode.rank

                // Create a dummy node at this rank to preserve it during removeEmptyRanks
                let proxyId = GraphUtil.uniqueId("_ep")
                let proxyLabel = DagreNodeLabel(width: 0, height: 0)
                proxyLabel.dummy = .edgeProxy
                proxyLabel.rank = proxyRank
                proxyLabel.edgeRef = (v: edge.v, w: edge.w, name: edge.name)
                g.setNode(proxyId, label: proxyLabel)
            }
        }
    }

    /// Removes the edge label proxy nodes and stores their rank on the corresponding edge
    /// as labelRank. This rank is used later for positioning the edge label.
    private static func removeEdgeLabelProxies(_ g: DagreGraph) {
        var nodesToRemove: [String] = []

        for v in g.nodes() {
            guard let node = g.node(v) else { continue }

            if node.dummy == .edgeProxy {
                // Get the original edge reference
                if let edgeRef = node.edgeRef {
                    // Store the proxy's rank as the labelRank on the edge
                    if let edgeLabel = g.edge(edgeRef.v, edgeRef.w, name: edgeRef.name) {
                        edgeLabel.labelRank = node.rank
                    }
                }
                nodesToRemove.append(v)
            }
        }

        // Remove proxy nodes
        for v in nodesToRemove {
            g.removeNode(v)
        }
    }

    /// Represents a stored self-edge
    private struct SelfEdge {
        let edge: Edge
        let label: DagreEdgeLabel
    }

    /// Temporarily removes self-edges
    private static func removeSelfEdges(_ g: DagreGraph) -> [String: [SelfEdge]] {
        var selfEdges: [String: [SelfEdge]] = [:]

        for edge in g.edges() {
            if edge.v == edge.w {
                if let label = g.edge(edge.id) {
                    selfEdges[edge.v, default: []].append(SelfEdge(edge: edge, label: label))
                    g.removeEdge(edge.v, edge.w, name: edge.name)
                }
            }
        }

        return selfEdges
    }

    /// Inserts self-edges back into the graph
    /// TypeScript iterates over layer matrix (ordered) and updates node orders
    private static func insertSelfEdges(_ g: DagreGraph, selfEdges: [String: [SelfEdge]]) {
        // Build layer matrix for ordered iteration (matches TypeScript)
        let layers = GraphUtil.buildLayerMatrix(g)

        for layer in layers {
            var orderShift = 0
            for (i, v) in layer.enumerated() {
                guard let nodeLabel = g.node(v) else { continue }

                // Update node order (matches TypeScript: node.order = i + orderShift)
                nodeLabel.order = i + orderShift

                // Insert self-edge dummies for this node
                if let edges = selfEdges[v] {
                    for selfEdge in edges {
                        // Pre-increment orderShift (matches TypeScript: order: i + (++orderShift))
                        orderShift += 1

                        let dummyId = GraphUtil.uniqueId("_se")
                        let dummyLabel = DagreNodeLabel(width: selfEdge.label.width, height: selfEdge.label.height)
                        dummyLabel.rank = nodeLabel.rank
                        dummyLabel.order = i + orderShift
                        dummyLabel.dummy = .selfedge
                        // Store references to original edge and label
                        dummyLabel.edgeObj = (v: selfEdge.edge.v, w: selfEdge.edge.w, name: selfEdge.edge.name)
                        dummyLabel.edgeLabel = selfEdge.label
                        g.setNode(dummyId, label: dummyLabel)
                    }
                }
            }
        }
    }

    /// Positions self-edges around their source node
    /// - Throws: `GraphError` if edge operations fail
    private static func positionSelfEdges(_ g: DagreGraph) throws {
        for v in g.nodes() {
            guard let node = g.node(v), node.dummy == .selfedge,
                  let edgeObj = node.edgeObj,
                  let edgeLabel = node.edgeLabel,
                  let selfNode = g.node(edgeObj.v) else { continue }

            let x = selfNode.x + selfNode.width / 2
            let y = selfNode.y
            let dx = node.x - x
            let dy = selfNode.height / 2

            // Set edge using stored references (matches TypeScript: g.setEdge(node.e, node.label))
            try g.setEdge(edgeObj.v, edgeObj.w, label: edgeLabel, name: edgeObj.name)
            g.removeNode(v)

            // Modify the original label's points (matches TypeScript: node.label.points = [...])
            edgeLabel.points = [
                DagreEdgeLabel.Point(x: x + 2 * dx / 3, y: y - dy),
                DagreEdgeLabel.Point(x: x + 5 * dx / 6, y: y - dy),
                DagreEdgeLabel.Point(x: x + dx, y: y),
                DagreEdgeLabel.Point(x: x + 5 * dx / 6, y: y + dy),
                DagreEdgeLabel.Point(x: x + 2 * dx / 3, y: y + dy)
            ]
            edgeLabel.x = node.x
            edgeLabel.y = node.y
            edgeLabel.hasLabelPosition = true
        }
    }

    /// Translates the graph to origin and applies margins
    /// Returns (width, height) matching dagrejs behavior
    private static func translateGraph(_ g: DagreGraph, marginx: Double, marginy: Double) -> (width: Double, height: Double) {
        var minX = Double.infinity
        var maxX: Double = 0  // Match dagrejs: initialized to 0, not -Infinity
        var minY = Double.infinity
        var maxY: Double = 0  // Match dagrejs: initialized to 0, not -Infinity

        // Helper to find extremes (matches dagrejs getExtremes)
        func getExtremes(x: Double, y: Double, width: Double, height: Double) {
            minX = min(minX, x - width / 2)
            maxX = max(maxX, x + width / 2)
            minY = min(minY, y - height / 2)
            maxY = max(maxY, y + height / 2)
        }

        // Find extremes from nodes
        for v in g.nodes() {
            guard let label = g.node(v) else { continue }
            getExtremes(x: label.x, y: label.y, width: label.width, height: label.height)
        }

        // Find extremes from edge labels
        // TypeScript uses Object.hasOwn(edge, "x") to check if label position was explicitly set
        // We use hasLabelPosition flag for the same purpose
        for edge in g.edges() {
            guard let label = g.edge(edge.id) else { continue }
            if label.hasLabelPosition {
                getExtremes(x: label.x, y: label.y, width: label.width, height: label.height)
            }
        }

        // Match dagrejs exactly:
        // 1. Subtract margin from min
        // 2. Translate by -minX, -minY
        // 3. Width = maxX - minX + marginX (using the modified minX)
        minX -= marginx
        minY -= marginy

        // Apply translation (matches dagrejs: node.x -= minX)
        for v in g.nodes() {
            if let label = g.node(v) {
                label.x -= minX
                label.y -= minY
            }
        }

        for edge in g.edges() {
            if let label = g.edge(edge.id) {
                for i in 0..<label.points.count {
                    label.points[i].x -= minX
                    label.points[i].y -= minY
                }
                if label.hasLabelPosition {
                    label.x -= minX
                    label.y -= minY
                }
            }
        }

        // Match dagrejs: width = maxX - minX + marginX, height = maxY - minY + marginY
        return (maxX - minX + marginx, maxY - minY + marginy)
    }
    /// Assigns edge endpoints to node intersections
    /// - Throws: `GraphError.intersectionAtRectangleCenter` if edge point is at node center
    private static func assignNodeIntersects(_ g: DagreGraph) throws {
        for edge in g.edges() {
            guard let edgeLabel = g.edge(edge.id),
                  let nodeV = g.node(edge.v),
                  let nodeW = g.node(edge.w) else { continue }

            let p1: DagreEdgeLabel.Point
            let p2: DagreEdgeLabel.Point

            if edgeLabel.points.isEmpty {
                p1 = DagreEdgeLabel.Point(x: nodeW.x, y: nodeW.y)
                p2 = DagreEdgeLabel.Point(x: nodeV.x, y: nodeV.y)
            } else {
                p1 = edgeLabel.points[0]
                p2 = edgeLabel.points[edgeLabel.points.count - 1]
            }

            // Calculate intersection with source node
            let startPoint = try GraphUtil.intersectRect(
                x: nodeV.x, y: nodeV.y,
                width: nodeV.width, height: nodeV.height,
                point: p1
            )
            edgeLabel.points.insert(startPoint, at: 0)

            // Calculate intersection with target node
            let endPoint = try GraphUtil.intersectRect(
                x: nodeW.x, y: nodeW.y,
                width: nodeW.width, height: nodeW.height,
                point: p2
            )
            edgeLabel.points.append(endPoint)
        }
    }

    /// Reverses edge points for edges that were reversed during acyclic transformation
    private static func reversePointsForReversedEdges(_ g: DagreGraph) {
        for edge in g.edges() {
            if let label = g.edge(edge.id), label.reversed {
                label.points.reverse()
            }
        }
    }

    /// Adjusts edge label coordinates based on labelpos (l, r, c)
    /// For left/right positioned labels, we need to offset the x coordinate
    /// and restore the original width (which was increased by labeloffset)
    private static func fixupEdgeLabelCoords(_ g: DagreGraph) {
        for edge in g.edges() {
            guard let edgeLabel = g.edge(edge.id) else { continue }

            // Only process edges that have label coordinates set
            // TypeScript: if (Object.hasOwn(edge, "x")) - checks if property exists
            // Swift: use hasLabelPosition flag to track if x/y were explicitly set
            guard edgeLabel.hasLabelPosition else { continue }

            switch edgeLabel.labelpos {
            case .left:
                // Restore original width and offset label to the left
                edgeLabel.width -= edgeLabel.labeloffset
                edgeLabel.x -= edgeLabel.width / 2 + edgeLabel.labeloffset
            case .right:
                // Restore original width and offset label to the right
                edgeLabel.width -= edgeLabel.labeloffset
                edgeLabel.x += edgeLabel.width / 2 + edgeLabel.labeloffset
            case .center:
                // Center labels don't need adjustment
                break
            }
        }
    }

    // MARK: - Coordinate System Transformations

    /// Adjusts the graph for non-TB layouts by swapping dimensions
    /// For LR/RL layouts, we swap width and height so the layout algorithm
    /// treats them as vertical layouts, then we swap back after
    private static func adjustCoordinateSystem(_ g: DagreGraph, rankdir: LayoutOptions.RankDirection) {
        guard rankdir == .leftRight || rankdir == .rightLeft else { return }

        // Swap width and height for all nodes
        for v in g.nodes() {
            if let label = g.node(v) {
                let temp = label.width
                label.width = label.height
                label.height = temp
            }
        }

        // Swap width and height for all edge labels
        for edge in g.edges() {
            if let label = g.edge(edge.id) {
                let temp = label.width
                label.width = label.height
                label.height = temp
            }
        }
    }

    /// Undoes the coordinate system adjustment after layout
    /// Swaps x/y coordinates and applies any necessary negation
    private static func undoCoordinateSystem(_ g: DagreGraph, rankdir: LayoutOptions.RankDirection) {
        switch rankdir {
        case .topBottom:
            // No transformation needed
            break

        case .bottomTop:
            // Negate y coordinates (flip vertically)
            for v in g.nodes() {
                if let label = g.node(v) {
                    label.y = -label.y
                }
            }
            for edge in g.edges() {
                if let label = g.edge(edge.id) {
                    for i in 0..<label.points.count {
                        label.points[i].y = -label.points[i].y
                    }
                    label.y = -label.y
                }
            }

        case .leftRight:
            // Swap x and y, and swap width and height
            for v in g.nodes() {
                if let label = g.node(v) {
                    let tempXY = label.x
                    label.x = label.y
                    label.y = tempXY

                    let tempWH = label.width
                    label.width = label.height
                    label.height = tempWH
                }
            }
            for edge in g.edges() {
                if let label = g.edge(edge.id) {
                    for i in 0..<label.points.count {
                        let temp = label.points[i].x
                        label.points[i].x = label.points[i].y
                        label.points[i].y = temp
                    }
                    let temp = label.x
                    label.x = label.y
                    label.y = temp

                    let tempWH = label.width
                    label.width = label.height
                    label.height = tempWH
                }
            }

        case .rightLeft:
            // Swap x and y, negate x, and swap width and height
            for v in g.nodes() {
                if let label = g.node(v) {
                    let tempXY = label.x
                    label.x = -label.y
                    label.y = tempXY

                    let tempWH = label.width
                    label.width = label.height
                    label.height = tempWH
                }
            }
            for edge in g.edges() {
                if let label = g.edge(edge.id) {
                    for i in 0..<label.points.count {
                        let temp = label.points[i].x
                        label.points[i].x = -label.points[i].y
                        label.points[i].y = temp
                    }
                    let temp = label.x
                    label.x = -label.y
                    label.y = temp

                    let tempWH = label.width
                    label.width = label.height
                    label.height = tempWH
                }
            }
        }
    }
}

// MARK: - Public API convenience

/// Main entry point for layout
/// - Throws: `GraphError` if the layout encounters an invalid graph state
public func layout(_ g: DagreGraph, options: LayoutOptions? = nil) throws {
    try SwiftDagreLayout.layout(g, options: options)
}
