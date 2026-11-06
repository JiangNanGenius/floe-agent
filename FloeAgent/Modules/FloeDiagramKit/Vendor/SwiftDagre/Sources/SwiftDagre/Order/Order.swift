// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Order optimization to minimize edge crossings
public enum Order {

    /// Applies heuristics to minimize edge crossings in the graph
    ///
    /// Preconditions:
    ///   1. Graph must be DAG
    ///   2. Graph nodes must be objects with a "rank" attribute
    ///   3. Graph edges must have the "weight" attribute
    ///
    /// Postconditions:
    ///   1. Graph nodes will have an "order" attribute based on the results
    ///
    /// - Parameters:
    ///   - g: The graph to order
    ///   - disableOptimization: Skip the optimization heuristic
    ///   - customOrder: Optional custom order function that overrides the heuristic
    public static func run(
        _ g: DagreGraph,
        disableOptimization: Bool = false,
        customOrder: ((DagreGraph, [[String]]) -> Void)? = nil
    ) throws {
        // Check for custom order function first (matches TypeScript behavior)
        // TypeScript: if (opts && typeof opts.customOrder === 'function') { opts.customOrder(g, order); return; }
        if let customOrder = customOrder {
            let layering = InitOrder.run(g)
            customOrder(g, layering)
            return
        }

        let maxRank = GraphUtil.maxRank(g)

        // Build layer graphs for sweeping
        // downLayerGraphs: ranks 1 to maxRank, using inEdges
        // upLayerGraphs: ranks maxRank-1 down to 0, using outEdges
        let downRanks = maxRank >= 1 ? Array(1...maxRank) : []
        let upRanks = maxRank >= 1 ? Array((0..<maxRank).reversed()) : []

        let downLayerGraphs = try buildLayerGraphs(g, ranks: downRanks, relationship: "inEdges")
        let upLayerGraphs = try buildLayerGraphs(g, ranks: upRanks, relationship: "outEdges")

        // Get initial layering
        var layering = InitOrder.run(g)
        assignOrder(g, layering: layering)

        if disableOptimization {
            return
        }

        // Track best solution
        var bestCC = Int.max
        var bestLayering = layering

        // Iterate until no improvement for 4 consecutive iterations
        var lastBest = 0
        var i = 0

        while lastBest < 4 {
            // Alternate between down-sweep and up-sweep
            // Also alternate bias (i % 4 >= 2)
            let useDownGraphs = (i % 2) == 1
            let biasRight = (i % 4) >= 2

            let layerGraphs = useDownGraphs ? downLayerGraphs : upLayerGraphs
            try sweepLayerGraphs(g, layerGraphs: layerGraphs, biasRight: biasRight)

            // Rebuild layering from current order
            layering = GraphUtil.buildLayerMatrix(g)

            // Count crossings
            let cc = CrossCount.count(g, layering: layering)

            if cc < bestCC {
                lastBest = 0
                bestCC = cc
                bestLayering = layering
            } else {
                lastBest += 1
            }

            i += 1
        }

        // Apply best solution
        assignOrder(g, layering: bestLayering)
    }

    /// Builds layer graphs for all specified ranks
    /// Pre-computes nodes by rank (including compound nodes that span multiple ranks)
    /// to avoid quadratic search during layer graph construction
    private static func buildLayerGraphs(_ g: DagreGraph, ranks: [Int], relationship: String) throws -> [(graph: Graph<BuildLayerGraph.LayerNodeLabel, BuildLayerGraph.LayerEdgeLabel>, root: String)] {
        // Build an index mapping from rank to the nodes with that rank
        // This helps avoid a quadratic search for all nodes with the same rank
        var nodesByRank: [Int: [String]] = [:]

        for v in g.nodes() {
            guard let node = g.node(v) else { continue }

            // Add node to its primary rank
            nodesByRank[node.rank, default: []].append(v)

            // If there is a range of ranks (compound nodes), add to each rank in the range
            // but skip node.rank which has already been added
            if let minRank = node.minRank, let maxRank = node.maxRank {
                for r in minRank...maxRank {
                    if r != node.rank {
                        nodesByRank[r, default: []].append(v)
                    }
                }
            }
        }

        var layerGraphs: [(graph: Graph<BuildLayerGraph.LayerNodeLabel, BuildLayerGraph.LayerEdgeLabel>, root: String)] = []
        for rank in ranks {
            let nodesWithRank = nodesByRank[rank] ?? []
            let result = try BuildLayerGraph.build(g, rank: rank, relationship: relationship, nodesWithRank: nodesWithRank)
            layerGraphs.append((graph: result.graph, root: result.root))
        }
        return layerGraphs
    }

    /// Sweeps through all layer graphs, sorting each one
    /// Updates the main graph's node orders after sorting
    private static func sweepLayerGraphs(
        _ mainGraph: DagreGraph,
        layerGraphs: [(graph: Graph<BuildLayerGraph.LayerNodeLabel, BuildLayerGraph.LayerEdgeLabel>, root: String)],
        biasRight: Bool
    ) throws {
        // Constraint graph tracks ordering relationships between subgraphs
        let cg = Graph<Void, Void>()

        for lg in layerGraphs {
            // CRITICAL: Sync orders from main graph to layer graph before sorting
            // This is necessary because Swift's layer graphs have separate LayerNodeLabel objects,
            // unlike TypeScript where setDefaultNodeLabel returns references to the main graph's nodes.
            // Without this sync, barycenter calculations use stale order values from build time.
            for v in lg.graph.nodes() {
                if let mainOrder = mainGraph.node(v)?.order {
                    lg.graph.node(v)?.order = mainOrder
                }
            }

            let sorted = SortSubgraph.sortLayerGraph(lg.graph, v: lg.root, cg: cg, biasRight: biasRight)

            // Apply order to layer graph nodes AND main graph nodes
            for (i, v) in sorted.vs.enumerated() {
                lg.graph.node(v)?.order = i
                // Also update the main graph's node order
                mainGraph.node(v)?.order = i
            }

            // Add subgraph constraints for next iteration
            try AddSubgraphConstraints.run(lg.graph, cg: cg, vs: sorted.vs)
        }
    }

    /// Assigns order values to nodes based on layering
    private static func assignOrder(_ g: DagreGraph, layering: [[String]]) {
        for layer in layering {
            for (i, v) in layer.enumerated() {
                g.node(v)?.order = i
            }
        }
    }
}
