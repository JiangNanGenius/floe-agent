// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Entry point for rank assignment algorithms
public enum Rank {

    /// Assigns ranks to all nodes in the graph using the specified algorithm
    /// - Parameters:
    ///   - g: The graph to assign ranks to
    ///   - algorithm: The ranking algorithm to use (default: networkSimplex)
    ///   - customRanker: Optional custom ranking function that overrides the algorithm
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if edge operations fail
    public static func run(
        _ g: DagreGraph,
        algorithm: LayoutOptions.RankingAlgorithm = .networkSimplex,
        customRanker: ((DagreGraph) -> Void)? = nil
    ) throws {
        // Check for custom ranker first (matches TypeScript behavior)
        // TypeScript: if (ranker instanceof Function) { return ranker(g); }
        if let customRanker = customRanker {
            customRanker(g)
            // Note: normalizeRanks is called by Layout.runLayout, not here
            // The TypeScript rank() function does NOT normalize - that happens
            // separately after injectEdgeLabelProxies and removeEmptyRanks
            return
        }

        switch algorithm {
        case .longestPath:
            LongestPath.run(g)

        case .tightTree:
            // Longest path + feasible tree (no full optimization)
            LongestPath.run(g)
            _ = try FeasibleTree.build(g)

        case .networkSimplex:
            try NetworkSimplex.run(g)

        case .none:
            // Skip ranking entirely - assumes ranks are already assigned
            // Matches TypeScript: case "none": break;
            break
        }

        // Note: Do NOT normalize ranks here!
        // TypeScript's rank() function does not normalize ranks.
        // Normalization is done separately in Layout.runLayout AFTER
        // injectEdgeLabelProxies and removeEmptyRanks.
        // This is critical because:
        // 1. makeSpaceForEdgeLabels doubles minlen (1→2)
        // 2. rank() creates ranks with gaps (A=0, B=2, C=4)
        // 3. injectEdgeLabelProxies creates proxies at intermediate ranks
        // 4. removeEmptyRanks removes truly empty ranks
        // 5. normalizeRanks normalizes after removing empty ranks
        // 6. normalize.run creates dummy nodes for long edges
    }
}
