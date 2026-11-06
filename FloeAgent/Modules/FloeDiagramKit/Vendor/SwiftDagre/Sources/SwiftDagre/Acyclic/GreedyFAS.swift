// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Greedy Feedback Arc Set algorithm
/// Uses the Eades, Lin, and Smyth heuristic for finding a minimal feedback arc set
/// This implementation matches the TypeScript dagre implementation exactly.
extension Acyclic {

    /// Greedy FAS algorithm for cycle breaking
    /// Generally produces fewer reversed edges than DFS-FAS
    /// Returns the list of back edges (feedback arc set)
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if edge operations fail
    static func greedyFAS(_ g: DagreGraph) throws -> [Edge] {
        if g.nodeCount() <= 1 {
            return []
        }

        // Build state with aggregated fasGraph
        var state = try FASState(g: g)

        // Run the greedy algorithm to find feedback edges
        let results = doGreedyFAS(&state)

        // Expand multi-edges into individual edges
        // TypeScript: results.flatMap(e => g.outEdges(e.v, e.w))
        var fas: [Edge] = []
        for result in results {
            // Get all edges from result.v to result.w (handles multigraph)
            if let edges = g.outEdges(result.v)?.filter({ $0.w == result.w }) {
                fas.append(contentsOf: edges)
            }
        }

        return fas
    }

    /// Main greedy FAS loop - matches TypeScript doGreedyFAS
    private static func doGreedyFAS(_ state: inout FASState) -> [(v: String, w: String)] {
        var results: [(v: String, w: String)] = []

        while state.fasGraph.nodeCount() > 0 {
            // Remove all sinks (nodes with out=0)
            while let entry = state.sinks.dequeue() {
                state.removeNode(entry, collectPredecessors: false, results: &results)
            }

            // Remove all sources (nodes with in=0)
            while let entry = state.sources.dequeue() {
                state.removeNode(entry, collectPredecessors: false, results: &results)
            }

            // If graph still has nodes, remove the node with max (out - in)
            if state.fasGraph.nodeCount() > 0 {
                // Search from buckets.length-2 down to 1 (skip sources bucket at end and sinks bucket at 0)
                for i in stride(from: state.buckets.count - 2, through: 1, by: -1) {
                    if let entry = state.buckets[i].dequeue() {
                        // Collect predecessor edges when removing non-sink/non-source nodes
                        state.removeNode(entry, collectPredecessors: true, results: &results)
                        break
                    }
                }
            }
        }

        return results
    }
}

// MARK: - FAS State

/// State tracker for greedy FAS algorithm - matches TypeScript structure
private struct FASState {
    /// The simplified graph for FAS computation
    var fasGraph: Graph<FASNodeEntry, Int>

    /// Buckets for node ordering - index 0 is sinks, last index is sources
    var buckets: [FASBucket]

    /// Zero index (where out - in = 0)
    let zeroIdx: Int

    /// Convenience accessors for sinks and sources buckets
    var sinks: FASBucket { buckets[0] }
    var sources: FASBucket { buckets[buckets.count - 1] }

    init(g: DagreGraph) throws {
        // Create FAS graph with node entries
        fasGraph = Graph<FASNodeEntry, Int>()

        var maxIn = 0
        var maxOut = 0

        // Build node order from edges - nodes appear in the order they're first seen in edges
        // This matches TypeScript's insertion order behavior
        var nodeOrder: [String] = []
        var seenNodes = Set<String>()

        // First pass: collect nodes in the order they first appear in edges
        for edge in g.edges() {
            if !seenNodes.contains(edge.v) {
                seenNodes.insert(edge.v)
                nodeOrder.append(edge.v)
            }
            if !seenNodes.contains(edge.w) {
                seenNodes.insert(edge.w)
                nodeOrder.append(edge.w)
            }
        }

        // Add any nodes that have no edges (shouldn't happen normally, but be safe)
        for v in g.nodes() {
            if !seenNodes.contains(v) {
                nodeOrder.append(v)
            }
        }

        // Initialize nodes in the determined order
        for v in nodeOrder {
            fasGraph.setNode(v, label: FASNodeEntry(v: v))
        }

        // Aggregate edges and update in/out degrees
        // TypeScript aggregates parallel edges into single weighted edges
        for edge in g.edges() {
            let weight = g.edge(edge.id)?.weight ?? 1

            // Aggregate weight for parallel edges
            let prevWeight = fasGraph.edge(edge.v, edge.w) ?? 0
            let newWeight = prevWeight + weight
            try fasGraph.setEdge(edge.v, edge.w, label: newWeight)

            // Update node degrees
            if let vEntry = fasGraph.node(edge.v) {
                vEntry.out += weight
                maxOut = max(maxOut, vEntry.out)
            }
            if let wEntry = fasGraph.node(edge.w) {
                wEntry.inDegree += weight
                maxIn = max(maxIn, wEntry.inDegree)
            }
        }

        // Create buckets: range(maxOut + maxIn + 3)
        // Index 0 = sinks (out=0), last index = sources (in=0)
        // Middle indices = out - in + zeroIdx
        let bucketCount = maxOut + maxIn + 3
        zeroIdx = maxIn + 1
        buckets = (0..<bucketCount).map { _ in FASBucket() }

        // Assign nodes to initial buckets IN EDGE-APPEARANCE ORDER
        // This is critical - TypeScript relies on insertion order for bucket assignment
        // When multiple nodes have the same out-in value, the one added first gets dequeued first
        for v in nodeOrder {
            if let entry = fasGraph.node(v) {
                assignBucket(entry)
            }
        }
    }

    /// Assigns a node entry to the appropriate bucket based on its in/out degrees
    mutating func assignBucket(_ entry: FASNodeEntry) {
        if entry.out == 0 {
            // Sink: goes to bucket[0]
            buckets[0].enqueue(entry)
        } else if entry.inDegree == 0 {
            // Source: goes to last bucket
            buckets[buckets.count - 1].enqueue(entry)
        } else {
            // Middle: goes to bucket[out - in + zeroIdx]
            let idx = entry.out - entry.inDegree + zeroIdx
            if idx >= 0 && idx < buckets.count {
                buckets[idx].enqueue(entry)
            }
        }
    }

    /// Removes a node from the FAS graph and updates adjacent nodes
    /// If collectPredecessors is true, adds incoming edges to results (the feedback arc set)
    mutating func removeNode(_ entry: FASNodeEntry, collectPredecessors: Bool, results: inout [(v: String, w: String)]) {
        let v = entry.v

        // Process incoming edges
        if let inEdges = fasGraph.inEdges(v) {
            for edge in inEdges {
                let weight = fasGraph.edge(edge.id) ?? 1

                // Collect predecessor edges as feedback arcs
                if collectPredecessors {
                    results.append((v: edge.v, w: edge.w))
                }

                // Update predecessor's out-degree
                if let uEntry = fasGraph.node(edge.v) {
                    uEntry.out -= weight
                    assignBucket(uEntry)
                }
            }
        }

        // Process outgoing edges
        if let outEdges = fasGraph.outEdges(v) {
            for edge in outEdges {
                let weight = fasGraph.edge(edge.id) ?? 1

                // Update successor's in-degree
                if let wEntry = fasGraph.node(edge.w) {
                    wEntry.inDegree -= weight
                    assignBucket(wEntry)
                }
            }
        }

        // Remove the node from the FAS graph
        fasGraph.removeNode(v)
    }
}

// MARK: - FAS Node Entry

/// Node entry for FAS computation - matches TypeScript { v, in, out }
/// The entry itself contains linked list pointers (like TypeScript's List entries)
/// so it can be unlinked when moved between buckets.
private final class FASNodeEntry {
    let v: String
    var inDegree: Int = 0  // "in" in TypeScript
    var out: Int = 0

    // Linked list pointers for bucket membership
    // These match TypeScript's _prev and _next on list entries
    weak var listPrev: FASNodeEntry?
    var listNext: FASNodeEntry?
    weak var owningBucket: FASBucket?

    init(v: String) {
        self.v = v
    }

    /// Unlinks this entry from its current bucket (if any)
    /// Matches TypeScript's unlink() function
    func unlink() {
        if let prev = listPrev {
            prev.listNext = listNext
        }
        if let next = listNext {
            next.listPrev = listPrev
        }
        owningBucket?.handleUnlink(self)
        listPrev = nil
        listNext = nil
        owningBucket = nil
    }
}

// MARK: - FAS Bucket (Linked List)

/// Simple linked-list bucket for FAS algorithm - matches TypeScript List
/// Uses a sentinel node pattern for simpler edge case handling.
private class FASBucket {
    // Sentinel node (circular linked list)
    private let sentinel = FASNodeEntry(v: "_sentinel")

    init() {
        sentinel.listNext = sentinel
        sentinel.listPrev = sentinel
    }

    func enqueue(_ entry: FASNodeEntry) {
        // If entry is already in a list, unlink it first
        // This matches TypeScript: if (entry._prev && entry._next) { unlink(entry); }
        if entry.listPrev != nil && entry.listNext != nil {
            entry.unlink()
        }

        // Insert at front (after sentinel)
        // TypeScript: entry._next = sentinel._next; sentinel._next._prev = entry;
        //             sentinel._next = entry; entry._prev = sentinel;
        entry.listNext = sentinel.listNext
        sentinel.listNext?.listPrev = entry
        sentinel.listNext = entry
        entry.listPrev = sentinel
        entry.owningBucket = self
    }

    func dequeue() -> FASNodeEntry? {
        // Dequeue from back (before sentinel)
        // TypeScript: let entry = sentinel._prev; if (entry !== sentinel) { unlink(entry); return entry; }
        let entry = sentinel.listPrev
        if entry !== sentinel {
            entry?.unlink()
            return entry
        }
        return nil
    }

    /// Called when an entry is unlinked - update head/tail if needed
    fileprivate func handleUnlink(_ entry: FASNodeEntry) {
        // Nothing special needed with sentinel pattern
    }
}
