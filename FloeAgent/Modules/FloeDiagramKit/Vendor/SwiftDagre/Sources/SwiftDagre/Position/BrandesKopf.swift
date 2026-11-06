// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Brandes-Kopf algorithm for x-coordinate assignment
/// "Fast and Simple Horizontal Coordinate Assignment"
public enum BrandesKopf {

    /// Alignment data for vertical block formation
    public struct Alignment {
        /// Maps each node to its block root
        public var root: [String: String]
        /// Maps each node to the next node in its block
        public var align: [String: String]

        public init() {
            self.root = [:]
            self.align = [:]
        }
    }

    /// Conflict set for edges that shouldn't be aligned
    public struct Conflicts {
        private var conflicts: [String: Set<String>] = [:]

        public mutating func add(_ v: String, _ w: String) {
            let (smaller, larger) = v < w ? (v, w) : (w, v)
            conflicts[smaller, default: []].insert(larger)
        }

        public func has(_ v: String, _ w: String) -> Bool {
            let (smaller, larger) = v < w ? (v, w) : (w, v)
            return conflicts[smaller]?.contains(larger) ?? false
        }
    }

    /// Computes x-coordinates using the Brandes-Kopf algorithm
    /// Returns x-coordinate for each node
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if edge operations fail
    public static func positionX(_ g: DagreGraph, nodesep: Double, edgesep: Double, align: LayoutOptions.Alignment? = nil) throws -> [String: Double] {
        let layering = GraphUtil.buildLayerMatrix(g)

        // Find type-1 and type-2 conflicts
        var conflicts = Conflicts()
        findType1Conflicts(g, layering: layering, conflicts: &conflicts)
        findType2Conflicts(g, layering: layering, conflicts: &conflicts)

        // Compute 4 alignments (all combinations of up/down, left/right)
        var xss: [String: [String: Double]] = [:]

        for vert in ["u", "d"] {
            let isUp = vert == "u"
            var adjustedLayering = isUp ? layering : Array(layering.reversed())

            for horiz in ["l", "r"] {
                let isLeft = horiz == "l"

                // Reverse layer order for right-biased
                if !isLeft {
                    adjustedLayering = adjustedLayering.map { Array($0.reversed()) }
                }

                // Build alignment
                let neighborFn: (DagreGraph, String) -> [String] = isUp ? predecessorsFn : successorsFn
                let alignment = verticalAlignment(g, layering: adjustedLayering, conflicts: conflicts, neighborFn: neighborFn)

                // Compute x-coordinates
                var xs = try horizontalCompaction(g, layering: adjustedLayering, root: alignment.root, align: alignment.align, reverseSep: !isLeft, nodesep: nodesep, edgesep: edgesep)

                // Flip x-coordinates for right-biased
                if !isLeft {
                    xs = xs.mapValues { -$0 }
                }

                xss[vert + horiz] = xs

                // Restore layering for next iteration
                if !isLeft {
                    adjustedLayering = adjustedLayering.map { Array($0.reversed()) }
                }
            }
        }

        // Find smallest width alignment and align others to it
        let smallestWidth = findSmallestWidthAlignment(g, xss: xss)
        alignCoordinates(&xss, alignTo: smallestWidth)

        // Balance: pick median of 4 alignments (or specific one if requested)
        return balance(xss, align: align)
    }

    // MARK: - Conflict Detection

    private static func predecessorsFn(_ g: DagreGraph, _ v: String) -> [String] {
        g.predecessors(v) ?? []
    }

    private static func successorsFn(_ g: DagreGraph, _ v: String) -> [String] {
        g.successors(v) ?? []
    }

    /// Finds type-1 conflicts (non-inner segment crosses inner segment)
    private static func findType1Conflicts(_ g: DagreGraph, layering: [[String]], conflicts: inout Conflicts) {
        guard layering.count > 1 else { return }

        for i in 1..<layering.count {
            let prevLayer = layering[i - 1]
            let layer = layering[i]

            var k0 = 0
            var scanPos = 0
            let prevLayerLength = prevLayer.count

            for (idx, v) in layer.enumerated() {
                // Find inner segment node (both ends are dummy)
                let w = findOtherInnerSegmentNode(g, v)
                let k1 = w != nil ? (g.node(w!)?.order ?? prevLayerLength) : prevLayerLength

                if w != nil || idx == layer.count - 1 {
                    // Scan for conflicts
                    for scanIdx in scanPos...idx {
                        let scanNode = layer[scanIdx]
                        if let preds = g.predecessors(scanNode) {
                            for u in preds {
                                let uPos = g.node(u)?.order ?? 0
                                let uIsDummy = g.node(u)?.dummy != nil
                                let scanIsDummy = g.node(scanNode)?.dummy != nil

                                if (uPos < k0 || k1 < uPos) && !(uIsDummy && scanIsDummy) {
                                    conflicts.add(u, scanNode)
                                }
                            }
                        }
                    }
                    scanPos = idx + 1
                    k0 = k1
                }
            }
        }
    }

    /// Finds type-2 conflicts (at compound node borders)
    private static func findType2Conflicts(_ g: DagreGraph, layering: [[String]], conflicts: inout Conflicts) {
        guard layering.count > 1 else { return }

        // Inline scan function
        func scan(south: [String], southPos: Int, southEnd: Int, prevNorthBorder: Int, nextNorthBorder: Int) {
            for idx in southPos..<southEnd {
                let v = south[idx]
                if g.node(v)?.dummy != nil {
                    if let preds = g.predecessors(v) {
                        for u in preds {
                            if let uNode = g.node(u), uNode.dummy != nil {
                                if uNode.order < prevNorthBorder || uNode.order > nextNorthBorder {
                                    conflicts.add(u, v)
                                }
                            }
                        }
                    }
                }
            }
        }

        for i in 1..<layering.count {
            let north = layering[i - 1]
            let south = layering[i]

            var prevNorthPos = -1
            var nextNorthPos: Int = 0
            var southPos = 0

            for (southLookahead, v) in south.enumerated() {
                if g.node(v)?.dummy == .border {
                    if let preds = g.predecessors(v), !preds.isEmpty {
                        nextNorthPos = g.node(preds[0])?.order ?? 0
                        scan(south: south, southPos: southPos, southEnd: southLookahead, prevNorthBorder: prevNorthPos, nextNorthBorder: nextNorthPos)
                        southPos = southLookahead
                        prevNorthPos = nextNorthPos
                    }
                }
                // Final scan - called at every iteration per TypeScript line 118
                scan(south: south, southPos: southPos, southEnd: south.count, prevNorthBorder: nextNorthPos, nextNorthBorder: north.count)
            }
        }
    }

    /// Finds the other node in an inner segment (both ends dummy)
    private static func findOtherInnerSegmentNode(_ g: DagreGraph, _ v: String) -> String? {
        guard g.node(v)?.dummy != nil else { return nil }
        return g.predecessors(v)?.first { g.node($0)?.dummy != nil }
    }

    // MARK: - Vertical Alignment

    /// Builds vertical alignment by aligning nodes with their median neighbors
    private static func verticalAlignment(
        _ g: DagreGraph,
        layering: [[String]],
        conflicts: Conflicts,
        neighborFn: (DagreGraph, String) -> [String]
    ) -> Alignment {
        var alignment = Alignment()
        var pos: [String: Int] = [:]

        // Initialize: each node is its own root and points to itself
        for layer in layering {
            for (order, v) in layer.enumerated() {
                alignment.root[v] = v
                alignment.align[v] = v
                pos[v] = order
            }
        }

        // Try to align each node with its median neighbor
        for layer in layering {
            var prevIdx = -1

            for v in layer {
                var neighbors = neighborFn(g, v)
                guard !neighbors.isEmpty else { continue }

                // Sort neighbors by position
                neighbors.sort { (pos[$0] ?? 0) < (pos[$1] ?? 0) }

                // Get median neighbor(s)
                let mp = Double(neighbors.count - 1) / 2.0
                let lower = Int(mp.rounded(.down))
                let upper = Int(mp.rounded(.up))

                for i in lower...upper {
                    let w = neighbors[i]
                    let wPos = pos[w] ?? 0

                    if alignment.align[v] == v && prevIdx < wPos && !conflicts.has(v, w) {
                        // Only align if w has been initialized (is in the layering)
                        if let wRoot = alignment.root[w] {
                            alignment.align[w] = v
                            alignment.align[v] = wRoot
                            alignment.root[v] = wRoot
                            prevIdx = wPos
                        }
                    }
                }
            }
        }

        return alignment
    }

    // MARK: - Horizontal Compaction

    /// Computes x-coordinates via horizontal compaction
    private static func horizontalCompaction(
        _ g: DagreGraph,
        layering: [[String]],
        root: [String: String],
        align: [String: String],
        reverseSep: Bool,
        nodesep: Double,
        edgesep: Double
    ) throws -> [String: Double] {
        var xs: [String: Double] = [:]

        // Build block graph
        let blockGraph = try buildBlockGraph(g, layering: layering, root: root, reverseSep: reverseSep, nodesep: nodesep, edgesep: edgesep)

        // First pass: assign smallest coordinates (left to right)
        var visited = Set<String>()
        var stack = blockGraph.nodes()

        while let elem = stack.popLast() {
            if visited.contains(elem) {
                // Process: set x to max of predecessors
                var x: Double = 0
                if let inEdges = blockGraph.inEdges(elem) {
                    for edge in inEdges {
                        let sep = blockGraph.edge(edge.id) ?? 0
                        x = max(x, (xs[edge.v] ?? 0) + sep)
                    }
                }
                xs[elem] = x
            } else {
                visited.insert(elem)
                stack.append(elem)
                if let preds = blockGraph.predecessors(elem) {
                    stack.append(contentsOf: preds)
                }
            }
        }

        // Second pass: shift blocks to the right where possible
        visited.removeAll()
        stack = blockGraph.nodes()
        let borderType: DagreNodeLabel.BorderType = reverseSep ? .left : .right

        while let elem = stack.popLast() {
            if visited.contains(elem) {
                // Process: shift right if possible
                if let outEdges = blockGraph.outEdges(elem) {
                    var minX = Double.infinity
                    for edge in outEdges {
                        let sep = blockGraph.edge(edge.id) ?? 0
                        minX = min(minX, (xs[edge.w] ?? Double.infinity) - sep)
                    }

                    if minX != Double.infinity {
                        if let nodeLabel = g.node(elem), nodeLabel.borderType != borderType {
                            xs[elem] = max(xs[elem] ?? 0, minX)
                        }
                    }
                }
            } else {
                visited.insert(elem)
                stack.append(elem)
                if let succs = blockGraph.successors(elem) {
                    stack.append(contentsOf: succs)
                }
            }
        }

        // Assign x to all nodes based on their root
        for v in align.keys {
            if let r = root[v] {
                xs[v] = xs[r]
            }
        }

        return xs
    }

    /// Builds a block graph where edges represent separation constraints
    private static func buildBlockGraph(
        _ g: DagreGraph,
        layering: [[String]],
        root: [String: String],
        reverseSep: Bool,
        nodesep: Double,
        edgesep: Double
    ) throws -> Graph<Void, Double> {
        let blockGraph = Graph<Void, Double>()

        for layer in layering {
            var prev: String?
            for v in layer {
                guard let vRoot = root[v] else { continue }
                blockGraph.setNode(vRoot)

                if let u = prev, let uRoot = root[u] {
                    let sep = calculateSeparation(g, v: v, u: u, reverseSep: reverseSep, nodesep: nodesep, edgesep: edgesep)
                    let existing = blockGraph.edge(uRoot, vRoot) ?? 0
                    try blockGraph.setEdge(uRoot, vRoot, label: max(sep, existing))
                }

                prev = v
            }
        }

        return blockGraph
    }

    /// Calculates required separation between two adjacent nodes
    /// Matches TypeScript sep(g, v, w) function at bk.js lines 384-419
    /// Called with calculateSeparation(g, v: currentNode, u: previousNode)
    /// TypeScript: sepFn(g, v, u) where v is current (right), u is previous (left)
    private static func calculateSeparation(
        _ g: DagreGraph,
        v: String,
        u: String,
        reverseSep: Bool,
        nodesep: Double,
        edgesep: Double
    ) -> Double {
        guard let vLabel = g.node(v), let uLabel = g.node(u) else { return 0 }

        var sum: Double = 0
        var delta: Double = 0

        // First parameter (v) - matches TypeScript vLabel processing
        sum += vLabel.width / 2
        if let labelpos = vLabel.labelpos {
            switch labelpos {
            case .left: delta = -vLabel.width / 2
            case .right: delta = vLabel.width / 2
            case .center: break
            }
        }
        if delta != 0 {
            sum += reverseSep ? delta : -delta
        }
        delta = 0

        // Separation (depends on whether nodes are dummies)
        sum += (vLabel.dummy != nil ? edgesep : nodesep) / 2
        sum += (uLabel.dummy != nil ? edgesep : nodesep) / 2

        // Second parameter (u) - matches TypeScript wLabel processing
        sum += uLabel.width / 2
        if let labelpos = uLabel.labelpos {
            switch labelpos {
            case .left: delta = uLabel.width / 2
            case .right: delta = -uLabel.width / 2
            case .center: break
            }
        }
        if delta != 0 {
            sum += reverseSep ? delta : -delta
        }

        return sum
    }

    // MARK: - Alignment and Balancing

    /// Finds the alignment with smallest total width
    private static func findSmallestWidthAlignment(_ g: DagreGraph, xss: [String: [String: Double]]) -> [String: Double] {
        var minWidth = Double.infinity
        var result: [String: Double] = [:]

        for (_, xs) in xss {
            var maxX = -Double.infinity
            var minX = Double.infinity

            for (v, x) in xs {
                let halfWidth = (g.node(v)?.width ?? 0) / 2
                maxX = max(maxX, x + halfWidth)
                minX = min(minX, x - halfWidth)
            }

            let width = maxX - minX
            if width < minWidth {
                minWidth = width
                result = xs
            }
        }

        return result
    }

    /// Aligns all coordinate sets to the smallest width alignment
    private static func alignCoordinates(_ xss: inout [String: [String: Double]], alignTo: [String: Double]) {
        guard !alignTo.isEmpty else { return }

        let alignToMin = alignTo.values.min() ?? 0
        let alignToMax = alignTo.values.max() ?? 0

        for vert in ["u", "d"] {
            for horiz in ["l", "r"] {
                let key = vert + horiz
                guard var xs = xss[key], xs != alignTo else { continue }

                let xsMin = xs.values.min() ?? 0
                let xsMax = xs.values.max() ?? 0

                let delta: Double
                if horiz == "l" {
                    delta = alignToMin - xsMin
                } else {
                    delta = alignToMax - xsMax
                }

                if delta != 0 {
                    xs = xs.mapValues { $0 + delta }
                    xss[key] = xs
                }
            }
        }
    }

    /// Balances x-coordinates by taking median of 4 alignments
    private static func balance(_ xss: [String: [String: Double]], align: LayoutOptions.Alignment?) -> [String: Double] {
        guard let ul = xss["ul"] else { return [:] }

        var result: [String: Double] = [:]

        for v in ul.keys {
            if let specificAlign = align {
                // Use specific alignment
                let key = specificAlign.rawValue.lowercased()
                result[v] = xss[key]?[v] ?? 0
            } else {
                // Take median of 4 values
                var values: [Double] = []
                for (_, xs) in xss {
                    if let x = xs[v] {
                        values.append(x)
                    }
                }
                values.sort()

                // Median of 4 values: average of 2 middle values
                if values.count >= 4 {
                    result[v] = (values[1] + values[2]) / 2
                } else if !values.isEmpty {
                    result[v] = values[values.count / 2]
                }
            }
        }

        return result
    }
}
