// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Adds edges to a constraint graph to maintain subgraph ordering relationships
public enum AddSubgraphConstraints {

    /// Adds subgraph ordering constraints to a constraint graph
    ///
    /// This tracks the previous child seen for each parent subgraph.
    /// When we see a new child that differs from the previous one,
    /// we add an edge to enforce that ordering relationship.
    ///
    /// - Parameters:
    ///   - g: The layer graph
    ///   - cg: The constraint graph to add edges to
    ///   - vs: The ordered list of nodes
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if edge creation fails
    public static func run<N, E>(
        _ g: Graph<N, E>,
        cg: Graph<Void, Void>,
        vs: [String]
    ) throws {
        var prev: [String: String] = [:]
        var rootPrev: String?

        for v in vs {
            var child = g.parent(v)
            var parent: String?
            var prevChild: String?

            while let currentChild = child {
                parent = g.parent(currentChild)
                if let p = parent {
                    prevChild = prev[p]
                    prev[p] = currentChild
                } else {
                    prevChild = rootPrev
                    rootPrev = currentChild
                }

                if let pc = prevChild, pc != currentChild {
                    try cg.setEdge(pc, currentChild)
                    break
                }

                child = parent
            }
        }
    }
}
