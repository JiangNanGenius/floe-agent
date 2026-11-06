// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Counts edge crossings in a layered graph
/// Based on Barth, et al., "Bilayer Cross Counting"
public enum CrossCount {

    /// Returns the weighted crossing count for the entire layering
    public static func count(_ g: DagreGraph, layering: [[String]]) -> Int {
        var cc = 0
        for i in 1..<layering.count {
            cc += twoLayerCrossCount(g, northLayer: layering[i - 1], southLayer: layering[i])
        }
        return cc
    }

    /// Counts crossings between two adjacent layers
    /// Uses a binary accumulator tree for O(E log N) efficiency
    private static func twoLayerCrossCount(
        _ g: DagreGraph,
        northLayer: [String],
        southLayer: [String]
    ) -> Int {
        guard !southLayer.isEmpty else { return 0 }

        // Build position map for south layer
        var southPos: [String: Int] = [:]
        for (i, v) in southLayer.enumerated() {
            southPos[v] = i
        }

        // Collect all edge entries (sorted by source, then target position)
        var southEntries: [(pos: Int, weight: Int)] = []

        for v in northLayer {
            guard let outEdges = g.outEdges(v) else { continue }

            // Get edges sorted by south position
            var entries: [(pos: Int, weight: Int)] = []
            for edge in outEdges {
                if let pos = southPos[edge.w] {
                    let weight = g.edge(edge.id)?.weight ?? 1
                    entries.append((pos, weight))
                }
            }
            entries.sort { $0.pos < $1.pos }
            southEntries.append(contentsOf: entries)
        }

        guard !southEntries.isEmpty else { return 0 }

        // Build the accumulator tree
        var firstIndex = 1
        while firstIndex < southLayer.count {
            firstIndex <<= 1
        }
        let treeSize = 2 * firstIndex - 1
        firstIndex -= 1
        var tree = Array(repeating: 0, count: treeSize)

        // Calculate weighted crossings using tree
        var cc = 0
        for entry in southEntries {
            var index = entry.pos + firstIndex
            tree[index] += entry.weight

            var weightSum = 0
            while index > 0 {
                if index % 2 == 1 {
                    // Node is a left child, add right sibling
                    weightSum += tree[index + 1]
                }
                index = (index - 1) >> 1
                tree[index] += entry.weight
            }

            cc += entry.weight * weightSum
        }

        return cc
    }
}
