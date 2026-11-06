// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Barycenter heuristic for node ordering
public enum Barycenter {

    /// Result of barycenter calculation for a node
    public struct Entry {
        public let v: String
        public var barycenter: Double?
        public var weight: Int
        /// Original index for tie-breaking in sort (used by sort.js and resolve-conflicts.js)
        public var i: Int

        public init(v: String, barycenter: Double? = nil, weight: Int = 0, i: Int = 0) {
            self.v = v
            self.barycenter = barycenter
            self.weight = weight
            self.i = i
        }
    }

    /// Calculates barycenter values for a set of movable nodes
    /// The barycenter is the weighted average of predecessor orders
    public static func calculate(_ g: DagreGraph, movable: [String]) -> [Entry] {
        return movable.map { v in
            guard let inEdges = g.inEdges(v), !inEdges.isEmpty else {
                return Entry(v: v)
            }

            var sum: Double = 0
            var weight: Int = 0

            for edge in inEdges {
                guard let edgeLabel = g.edge(edge.id),
                      let nodeU = g.node(edge.v) else { continue }

                sum += Double(edgeLabel.weight * nodeU.order)
                weight += edgeLabel.weight
            }

            if weight > 0 {
                return Entry(v: v, barycenter: sum / Double(weight), weight: weight)
            } else {
                return Entry(v: v)
            }
        }
    }

    /// Merges barycenter from a child subgraph into its parent entry
    public static func merge(_ target: inout Entry, with other: Entry) {
        guard let otherBarycenter = other.barycenter else { return }

        if let targetBarycenter = target.barycenter {
            let totalWeight = target.weight + other.weight
            target.barycenter = (targetBarycenter * Double(target.weight) +
                                  otherBarycenter * Double(other.weight)) / Double(totalWeight)
            target.weight = totalWeight
        } else {
            target.barycenter = otherBarycenter
            target.weight = other.weight
        }
    }
}
