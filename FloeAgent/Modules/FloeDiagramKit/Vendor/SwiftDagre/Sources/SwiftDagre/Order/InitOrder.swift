// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Assigns initial ordering via DFS traversal
public enum InitOrder {

    /// Assigns an initial order value for each node by performing a DFS search
    /// starting from nodes in the first rank.
    ///
    /// Nodes are assigned an order in their rank as they are first visited.
    /// From Gansner, et al., "A Technique for Drawing Directed Graphs."
    ///
    /// Returns a layering matrix with an array per layer, each layer sorted by
    /// the order of its nodes.
    public static func run(_ g: DagreGraph) -> [[String]] {
        var visited = Set<String>()

        // Get simple nodes (non-compound) sorted by rank
        let simpleNodes = g.nodes().filter { g.isLeaf($0) }

        guard let maxRank = simpleNodes.compactMap({ g.node($0)?.rank }).max() else {
            return []
        }

        // Initialize layers
        var layers: [[String]] = Array(repeating: [], count: maxRank + 1)

        func dfs(_ v: String) {
            guard !visited.contains(v) else { return }
            visited.insert(v)

            if let node = g.node(v) {
                let rank = node.rank
                if rank >= 0 && rank < layers.count {
                    layers[rank].append(v)
                }
            }

            // Continue DFS to successors
            if let successors = g.successors(v) {
                for w in successors {
                    dfs(w)
                }
            }
        }

        // Sort nodes by rank and process via DFS
        let orderedVs = simpleNodes.sorted { (a, b) in
            (g.node(a)?.rank ?? 0) < (g.node(b)?.rank ?? 0)
        }

        for v in orderedVs {
            dfs(v)
        }

        return layers
    }
}
