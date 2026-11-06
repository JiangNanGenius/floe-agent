// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Utility functions for graph operations
public enum GraphUtil {
    /// Counter for generating unique node IDs
    private static var _nodeIdCounter = 0
    /// Lock for thread-safe counter access (os_unfair_lock for macOS 10.12+ compatibility)
    private static var counterLock = os_unfair_lock()

    /// Generates a unique node ID with a given prefix
    public static func uniqueId(_ prefix: String = "_") -> String {
        os_unfair_lock_lock(&counterLock)
        defer { os_unfair_lock_unlock(&counterLock) }
        _nodeIdCounter += 1
        return "\(prefix)\(_nodeIdCounter)"
    }

    /// Resets the unique ID counter (for testing)
    public static func resetIdCounter() {
        os_unfair_lock_lock(&counterLock)
        defer { os_unfair_lock_unlock(&counterLock) }
        _nodeIdCounter = 0
    }

    /// Adds a dummy node to the graph with the given type and attributes
    @discardableResult
    static func addDummyNode(
        _ g: DagreGraph,
        type: DagreNodeLabel.DummyType,
        width: Double = 0,
        height: Double = 0,
        rank: Int = 0,
        edgeSource: String? = nil,
        edgeTarget: String? = nil,
        edgeName: String? = nil,
        prefix: String = "_d"
    ) -> String {
        let id = uniqueId(prefix)
        let label = DagreNodeLabel(width: width, height: height)
        label.dummy = type
        label.rank = rank
        label.edgeSource = edgeSource
        label.edgeTarget = edgeTarget
        label.edgeName = edgeName
        g.setNode(id, label: label)
        return id
    }

    /// Adds a border node to the graph
    @discardableResult
    public static func addBorderNode(
        _ g: DagreGraph,
        prefix: String,
        rank: Int? = nil,
        order: Int? = nil
    ) -> String {
        let id = uniqueId(prefix)
        let label = DagreNodeLabel(width: 0, height: 0)
        label.dummy = .border
        if let rank = rank { label.rank = rank }
        if let order = order { label.order = order }
        g.setNode(id, label: label)
        return id
    }

    /// Simplifies a multigraph by aggregating parallel edges
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if edge creation fails
    public static func simplify(_ g: DagreGraph) throws -> DagreGraph {
        let simplified = DagreGraph(options: GraphOptions(
            directed: g.isDirected,
            multigraph: false,
            compound: false
        ))

        // Copy graph label
        simplified.setGraph(g.graph())

        // Copy nodes
        for v in g.nodes() {
            simplified.setNode(v, label: g.node(v))
        }

        // Aggregate edges
        for edge in g.edges() {
            if let existing = simplified.edge(edge.v, edge.w) {
                // Aggregate weights
                if let original = g.edge(edge.id) {
                    existing.weight += original.weight
                    existing.minlen = max(existing.minlen, original.minlen)
                }
            } else {
                // Copy edge
                if let label = g.edge(edge.id) {
                    let newLabel = DagreEdgeLabel(minlen: label.minlen, weight: label.weight)
                    try simplified.setEdge(edge.v, edge.w, label: newLabel)
                } else {
                    try simplified.setEdge(edge.v, edge.w, label: DagreEdgeLabel())
                }
            }
        }

        return simplified
    }

    /// Creates a version of the graph without compound structure (only leaf nodes)
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if copying a named edge to a non-multigraph
    public static func asNonCompoundGraph(_ g: DagreGraph) throws -> DagreGraph {
        let result = DagreGraph(options: GraphOptions(
            directed: g.isDirected,
            multigraph: g.isMultigraph,
            compound: false
        ))

        result.setGraph(g.graph())

        // Only copy leaf nodes
        for v in g.nodes() {
            if g.isLeaf(v) {
                result.setNode(v, label: g.node(v))
            }
        }

        // Copy edges between leaf nodes
        for edge in g.edges() {
            if result.hasNode(edge.v) && result.hasNode(edge.w) {
                try result.setEdge(edge.v, edge.w, label: g.edge(edge.id), name: edge.name)
            }
        }

        return result
    }

    /// Builds a 2D matrix of node IDs organized by rank and order
    public static func buildLayerMatrix(_ g: DagreGraph) -> [[String]] {
        // Find max rank
        var maxRank = 0
        for v in g.nodes() {
            if let label = g.node(v) {
                maxRank = max(maxRank, label.rank)
            }
        }

        // Build layers
        var layers: [[String]] = Array(repeating: [], count: maxRank + 1)

        for v in g.nodes() {
            if let label = g.node(v) {
                let rank = label.rank
                // Guard against negative ranks which would cause index out of range
                if rank >= 0 && rank < layers.count {
                    layers[rank].append(v)
                }
            }
        }

        // Sort each layer by order
        for i in 0..<layers.count {
            layers[i].sort { v1, v2 in
                (g.node(v1)?.order ?? 0) < (g.node(v2)?.order ?? 0)
            }
        }

        return layers
    }

    /// Threshold for chunking array operations (matches TypeScript)
    /// Used to prevent call stack overflow on very large graphs
    private static let CHUNKING_THRESHOLD = 65535

    /// Applies a min function with chunking to prevent issues on very large arrays
    /// Matches TypeScript applyWithChunking in lib/util.js lines 222-229
    private static func applyMinWithChunking(_ array: [Int]) -> Int {
        if array.isEmpty { return Int.max }
        if array.count > CHUNKING_THRESHOLD {
            let chunkSize = CHUNKING_THRESHOLD
            var results: [Int] = []
            for i in stride(from: 0, to: array.count, by: chunkSize) {
                let end = Swift.min(i + chunkSize, array.count)
                let chunk = Array(array[i..<end])
                if let chunkMin = chunk.min() {
                    results.append(chunkMin)
                }
            }
            return results.min() ?? Int.max
        }
        return array.min() ?? Int.max
    }

    /// Applies a max function with chunking to prevent issues on very large arrays
    private static func applyMaxWithChunking(_ array: [Int]) -> Int {
        if array.isEmpty { return Int.min }
        if array.count > CHUNKING_THRESHOLD {
            let chunkSize = CHUNKING_THRESHOLD
            var results: [Int] = []
            for i in stride(from: 0, to: array.count, by: chunkSize) {
                let end = Swift.min(i + chunkSize, array.count)
                let chunk = Array(array[i..<end])
                if let chunkMax = chunk.max() {
                    results.append(chunkMax)
                }
            }
            return results.max() ?? Int.min
        }
        return array.max() ?? Int.min
    }

    /// Returns the maximum rank in the graph
    /// Returns Int.min for empty graphs (matches TypeScript Number.MIN_VALUE)
    public static func maxRank(_ g: DagreGraph) -> Int {
        var max = Int.min
        for v in g.nodes() {
            if let label = g.node(v) {
                max = Swift.max(max, label.rank)
            }
        }
        return max
    }

    /// Normalizes ranks so minimum rank is 0
    public static func normalizeRanks(_ g: DagreGraph) {
        var minRank = Int.max
        for v in g.nodes() {
            if let label = g.node(v), label.dummy == nil || label.dummy == .edge || label.dummy == .edgeLabel {
                minRank = min(minRank, label.rank)
            }
        }

        if minRank == Int.max { return }

        for v in g.nodes() {
            if let label = g.node(v) {
                label.rank -= minRank
            }
        }
    }

    /// Removes empty ranks by shifting nodes
    /// Matches TypeScript dagre lib/util.js removeEmptyRanks
    ///
    /// IMPORTANT: In TypeScript, compound nodes (those with children) have rank=undefined.
    /// When Math.min is called with undefined values, it returns NaN, which causes
    /// the entire function to effectively do nothing (all adjusted ranks become NaN,
    /// which don't create valid array indices, resulting in layers.length=0 and delta=0).
    ///
    /// To match TypeScript's behavior exactly, we detect when there are compound nodes
    /// (which would have undefined ranks in TS) and skip the entire function.
    /// This preserves the rank spacing set up by NestingGraph.
    public static func removeEmptyRanks(_ g: DagreGraph) {
        // Check if there are any compound nodes (nodes with children)
        // In TypeScript, these have rank=undefined, which causes Math.min to return NaN,
        // making the entire function do nothing. We match this by early return.
        if g.isCompound {
            for v in g.nodes() {
                if let children = g.children(v), !children.isEmpty {
                    // Found a compound node - skip removeEmptyRanks to match TypeScript
                    // In TypeScript, compound nodes have rank=undefined which causes Math.min
                    // to return NaN, effectively skipping the entire function
                    return
                }
            }
        }

        // Get ranks of all nodes
        var nodeRanks: [Int] = []
        for v in g.nodes() {
            if let label = g.node(v) {
                nodeRanks.append(label.rank)
            }
        }

        // Find minimum rank (offset)
        let offset = nodeRanks.min() ?? 0

        // Build layers array (sparse - some indices may be nil)
        var layers: [[String]?] = []
        for v in g.nodes() {
            if let label = g.node(v) {
                let rank = label.rank - offset
                // Guard against negative ranks
                if rank < 0 { continue }
                // Ensure layers array is large enough
                while layers.count <= rank {
                    layers.append(nil)
                }
                if layers[rank] == nil {
                    layers[rank] = []
                }
                layers[rank]?.append(v)
            }
        }

        // Get nodeRankFactor from graph options
        // This determines which empty ranks to preserve
        // With nodeRankFactor=1 (default), NO empty ranks are removed
        // Matches TypeScript: let nodeRankFactor = g.graph().nodeRankFactor;
        let nodeRankFactor = (g.graph() as? LayoutOptions)?.nodeRankFactor ?? 1

        // Calculate delta (how much to shift ranks)
        var delta = 0
        for (i, vs) in layers.enumerated() {
            if vs == nil {
                // Empty rank
                // TypeScript: if (vs === undefined && i % nodeRankFactor !== 0)
                // With nodeRankFactor=1: i % 1 = 0 for all i, so condition is NEVER true
                // This means NO empty ranks are removed when nodeRankFactor=1
                if nodeRankFactor != 0 && i % nodeRankFactor != 0 {
                    delta -= 1
                }
            } else if delta != 0 {
                // Non-empty rank with accumulated delta - shift nodes
                for v in vs! {
                    if let label = g.node(v) {
                        label.rank += delta
                    }
                }
            }
        }
    }

    /// Returns a map of successor nodes with their edge weights
    public static func successorWeights(_ g: DagreGraph) -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        for v in g.nodes() {
            result[v] = [:]
            if let outEdges = g.outEdges(v) {
                for edge in outEdges {
                    let weight = g.edge(edge.id)?.weight ?? 1
                    result[v]![edge.w, default: 0] += weight
                }
            }
        }
        return result
    }

    /// Returns a map of predecessor nodes with their edge weights
    public static func predecessorWeights(_ g: DagreGraph) -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        for v in g.nodes() {
            result[v] = [:]
            if let inEdges = g.inEdges(v) {
                for edge in inEdges {
                    let weight = g.edge(edge.id)?.weight ?? 1
                    result[v]![edge.v, default: 0] += weight
                }
            }
        }
        return result
    }

    /// Calculate intersection of a line with a rectangle
    /// Returns the point on the rectangle boundary where the line from center to point intersects
    /// Algorithm from: http://math.stackexchange.com/questions/108113/find-edge-between-two-boxes
    /// Matches TypeScript dagre lib/util.js intersectRect exactly
    /// - Throws: `GraphError.intersectionAtRectangleCenter` if the point is at the rectangle center
    public static func intersectRect(
        x: Double, y: Double, width: Double, height: Double,
        point: DagreEdgeLabel.Point
    ) throws -> DagreEdgeLabel.Point {
        let dx = point.x - x
        let dy = point.y - y
        var w = width / 2
        var h = height / 2

        // TypeScript: throw new Error("Not possible to find intersection inside of the rectangle")
        if dx == 0 && dy == 0 {
            throw GraphError.intersectionAtRectangleCenter
        }

        var sx: Double
        var sy: Double

        // TypeScript condition: Math.abs(dy) * w > Math.abs(dx) * h
        // This accounts for rectangle aspect ratio to determine which edge is hit
        if abs(dy) * w > abs(dx) * h {
            // Intersection is top or bottom of rect
            if dy < 0 {
                h = -h
            }
            sx = h * dx / dy
            sy = h
        } else {
            // Intersection is left or right of rect
            if dx < 0 {
                w = -w
            }
            sx = w
            sy = w * dy / dx
        }

        return DagreEdgeLabel.Point(x: x + sx, y: y + sy)
    }
}

// MARK: - Range utilities

extension GraphUtil {
    /// Creates a range of integers
    public static func range(_ limit: Int) -> [Int] {
        Array(0..<limit)
    }

    /// Creates a range of integers
    public static func range(_ start: Int, _ limit: Int) -> [Int] {
        Array(start..<limit)
    }

    /// Creates a range of integers with a step
    public static func range(_ start: Int, _ limit: Int, _ step: Int) -> [Int] {
        guard step != 0 else { return [] }
        var result: [Int] = []
        if step > 0 {
            var i = start
            while i < limit {
                result.append(i)
                i += step
            }
        } else {
            var i = start
            while i > limit {
                result.append(i)
                i += step
            }
        }
        return result
    }
}

// MARK: - Array partitioning

extension Array {
    /// Partitions array into (matching, not matching) based on predicate
    public func partition(_ predicate: (Element) -> Bool) -> (lhs: [Element], rhs: [Element]) {
        var lhs: [Element] = []
        var rhs: [Element] = []
        for element in self {
            if predicate(element) {
                lhs.append(element)
            } else {
                rhs.append(element)
            }
        }
        return (lhs, rhs)
    }
}
