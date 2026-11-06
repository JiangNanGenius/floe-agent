// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Longest path ranking algorithm
/// Assigns ranks by finding the longest path to each node from sources
///
/// This algorithm does not normalize layers because it will be used by other
/// algorithms in most cases. If using this algorithm directly, be sure to
/// run normalize at the end.
public enum LongestPath {

    /// Assigns ranks using longest path algorithm
    /// Matches TypeScript longestPath in rank/util.js lines 31-59
    public static func run(_ g: DagreGraph) {
        var visited = Set<String>()

        func dfs(_ v: String) -> Int {
            guard let label = g.node(v) else { return 0 }

            if visited.contains(v) {
                return label.rank
            }

            visited.insert(v)

            // Get minimum rank based on successors
            var minSuccRank = Int.max
            if let outEdges = g.outEdges(v) {
                for edge in outEdges {
                    let succRank = dfs(edge.w)
                    let minlen = g.edge(edge.id)?.minlen ?? 1
                    minSuccRank = min(minSuccRank, succRank - minlen)
                }
            }

            // If no successors, this is a sink - use rank 0
            // Otherwise, use minimum successor rank - minlen
            let rank = minSuccRank == Int.max ? 0 : minSuccRank
            label.rank = rank

            return rank
        }

        // Process only from source nodes (TypeScript line 58: g.sources().forEach(dfs))
        // Sources are nodes with no incoming edges
        for v in g.sources() {
            _ = dfs(v)
        }

        // NOTE: TypeScript's longestPath does NOT normalize ranks
        // normalization is done elsewhere if needed
    }
}

// MARK: - Rank Utilities

/// Utilities for rank calculations
public enum RankUtil {

    /// Calculates the slack for an edge (how much longer it is than its minlen)
    /// slack = rank(w) - rank(v) - minlen
    public static func slack(_ g: DagreGraph, edge: Edge) -> Int {
        guard let vLabel = g.node(edge.v),
              let wLabel = g.node(edge.w),
              let edgeLabel = g.edge(edge.id) else {
            return 0
        }

        return wLabel.rank - vLabel.rank - edgeLabel.minlen
    }

    /// Returns true if the edge is tight (slack = 0)
    public static func isTight(_ g: DagreGraph, edge: Edge) -> Bool {
        slack(g, edge: edge) == 0
    }

    /// Finds all tight edges in the graph
    public static func tightEdges(_ g: DagreGraph) -> [Edge] {
        g.edges().filter { isTight(g, edge: $0) }
    }
}
