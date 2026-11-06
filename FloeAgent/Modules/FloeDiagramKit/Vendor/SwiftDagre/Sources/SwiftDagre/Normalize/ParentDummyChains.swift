// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Assigns parents to dummy nodes in compound graphs
/// This ensures dummy nodes (edge segments) are properly placed within the compound hierarchy
enum ParentDummyChains {

    /// Assigns proper parents to dummy nodes based on lowest common ancestor (LCA)
    /// This is essential for compound graphs where edges cross subgraph boundaries
    ///
    /// - Parameters:
    ///   - g: The graph with dummy chains
    ///   - dummyChains: List of first dummy node IDs in each chain
    static func run(_ g: DagreGraph, dummyChains: [String]) throws {
        guard g.isCompound else { return }

        let postorderNums = computePostorder(g)

        for firstDummy in dummyChains {
            guard var node = g.node(firstDummy) else { continue }

            // Get the original edge endpoints
            guard let edgeSource = node.edgeSource,
                  let edgeTarget = node.edgeTarget else { continue }

            // Find the path from source to target through LCA
            let pathData = findPath(g, postorderNums: postorderNums, v: edgeSource, w: edgeTarget)
            let path = pathData.path
            let lca = pathData.lca

            var pathIdx = 0
            var pathV: String? = path.isEmpty ? nil : path[pathIdx]
            var ascending = true
            var v = firstDummy

            // Walk through the dummy chain
            while v != edgeTarget {
                guard let currentNode = g.node(v) else { break }
                node = currentNode

                if ascending {
                    // Walk up the path until we reach LCA or find a subgraph containing this rank
                    // TypeScript: while ((pathV = path[pathIdx]) !== lca && g.node(pathV).maxRank < node.rank)
                    while pathIdx < path.count {
                        let pv = path[pathIdx]  // May be nil
                        if pv == lca { break }  // Reached LCA
                        guard let pvUnwrapped = pv,
                              let pathNode = g.node(pvUnwrapped),
                              let maxRank = pathNode.maxRank,
                              maxRank < node.rank else { break }
                        pathIdx += 1
                    }
                    pathV = pathIdx < path.count ? path[pathIdx] : nil

                    if pathV == lca {
                        ascending = false
                    }
                }

                if !ascending {
                    // Walk down from LCA toward target
                    // TypeScript: while (pathIdx < path.length - 1 && g.node(pathV = path[pathIdx + 1]).minRank <= node.rank)
                    while pathIdx < path.count - 1 {
                        let nextPv = path[pathIdx + 1]
                        guard let nextPvUnwrapped = nextPv,
                              let nextPathNode = g.node(nextPvUnwrapped),
                              let minRank = nextPathNode.minRank,
                              minRank <= node.rank else { break }
                        pathIdx += 1
                    }
                    pathV = pathIdx < path.count ? path[pathIdx] : nil
                }

                // Set the parent of this dummy node (pathV may be nil for root level)
                if let pv = pathV {
                    try g.setParent(v, parent: pv)
                }
                // Note: If pathV is nil, the dummy stays at root level (no parent change needed)

                // Move to next dummy in chain
                guard let successors = g.successors(v), let next = successors.first else { break }
                v = next
            }
        }
    }

    /// Finds the path from v to w through the lowest common ancestor
    /// Returns the full path and the LCA node
    ///
    /// IMPORTANT: This matches TypeScript's behavior where the path includes
    /// the LCA (which may be nil/undefined for root-level nodes). The TypeScript
    /// do-while loop pushes parent BEFORE checking the condition, so even undefined
    /// is included in vPath. This is critical for the ascending/descending logic
    /// in the parent assignment phase.
    private static func findPath(
        _ g: DagreGraph,
        postorderNums: [String: PostorderNumber],
        v: String,
        w: String
    ) -> (path: [String?], lca: String?) {
        var vPath: [String?] = []
        var wPath: [String] = []

        guard let vNums = postorderNums[v],
              let wNums = postorderNums[w] else {
            return ([], nil)
        }

        let low = min(vNums.low, wNums.low)
        let lim = max(vNums.lim, wNums.lim)

        // Traverse up from v to find the LCA
        // TypeScript uses do-while which pushes parent BEFORE checking condition
        // This means even undefined (no parent) gets pushed to vPath
        var parent: String? = v
        repeat {
            parent = g.parent(parent!)
            vPath.append(parent)  // Push parent (could be nil for root level nodes)
        } while parent != nil &&
                (postorderNums[parent!]!.low > low || lim > postorderNums[parent!]!.lim)
        let lca = parent

        // Traverse from w to LCA
        parent = w
        while let p = g.parent(parent!), p != lca {
            parent = p
            wPath.append(p)
        }

        return (path: vPath + wPath.reversed().map { $0 }, lca: lca)
    }

    /// Postorder number for LCA computation
    private struct PostorderNumber {
        let low: Int
        let lim: Int
    }

    /// Computes postorder numbers for all nodes in the compound hierarchy
    private static func computePostorder(_ g: DagreGraph) -> [String: PostorderNumber] {
        var result: [String: PostorderNumber] = [:]
        var counter = 0

        func dfs(_ v: String) {
            let low = counter
            if let children = g.children(v) {
                for child in children {
                    dfs(child)
                }
            }
            result[v] = PostorderNumber(low: low, lim: counter)
            counter += 1
        }

        // Start from root children (nil parent)
        if let rootChildren = g.children(nil) {
            for child in rootChildren {
                dfs(child)
            }
        }

        return result
    }
}

// Safe array subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
