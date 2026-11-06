// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

#if canImport(Darwin)
import Darwin
#endif

/// Algorithms for making a graph acyclic by detecting and reversing cycle edges
public enum Acyclic {

    /// Counter for generating unique IDs for reversed edges
    private static var reverseIdCounter: Int = 0
    /// Lock for thread-safe counter access (os_unfair_lock for macOS 10.12+ compatibility)
    private static var counterLock = os_unfair_lock()

    /// Generates a unique ID for reversed edges (matches dagrejs's uniqueId("rev"))
    private static func uniqueReverseId() -> String {
        os_unfair_lock_lock(&counterLock)
        defer { os_unfair_lock_unlock(&counterLock) }
        reverseIdCounter += 1
        return "rev\(reverseIdCounter)"
    }

    /// Makes the graph acyclic by reversing edges that form cycles
    /// Uses the specified algorithm (DFS or Greedy)
    /// - Throws: `GraphError` if edge operations fail
    public static func run(_ g: DagreGraph, algorithm: LayoutOptions.AcyclicAlgorithm = .dfs) throws {
        // Get the feedback arc set (edges to reverse)
        let fas: [Edge]
        switch algorithm {
        case .dfs:
            fas = dfsFAS(g)
        case .greedy:
            fas = try greedyFAS(g)
        }

        // Reverse all edges in the feedback arc set
        // This matches TypeScript: fas.forEach(e => { ... g.setEdge(e.w, e.v, label, uniqueId("rev")); })
        for edge in fas {
            try reverseEdge(g, edge: edge)
        }
    }

    /// Undoes the acyclic transformation by reversing the previously reversed edges
    /// Note: This does NOT reverse the points array. Points are already reversed by
    /// reversePointsForReversedEdges() which is called before this function.
    /// The TypeScript version also does not reverse points here.
    /// - Throws: `GraphError` if edge operations fail
    public static func undo(_ g: DagreGraph) throws {
        for edge in g.edges() {
            guard let label = g.edge(edge.id) else { continue }
            if label.reversed {
                // Remove the reversed edge and restore the original
                g.removeEdge(edge.v, edge.w, name: edge.name)

                // Clear the reversed flag and restore the original edge
                // Note: We keep the same label object (don't create a new one)
                // to preserve all properties including points that were already reversed
                label.reversed = false
                let forwardName = label.forwardName
                label.forwardName = nil

                // Restore with the original forward name
                try g.setEdge(edge.w, edge.v, label: label, name: forwardName)
            }
        }
    }

    // MARK: - DFS-based Feedback Arc Set

    /// Uses DFS to find and reverse back edges (edges forming cycles)
    /// Returns the list of back edges (feedback arc set)
    private static func dfsFAS(_ g: DagreGraph) -> [Edge] {
        var fas: [Edge] = []
        var visited = Set<String>()
        var stack = Set<String>()

        func dfs(_ v: String) {
            if visited.contains(v) { return }

            visited.insert(v)
            stack.insert(v)

            if let outEdges = g.outEdges(v) {
                for edge in outEdges {
                    if stack.contains(edge.w) {
                        // Found a back edge - add to feedback arc set
                        fas.append(edge)
                    } else {
                        dfs(edge.w)
                    }
                }
            }

            stack.remove(v)
        }

        // TypeScript (acyclic.js line 51): g.nodes().forEach(dfs)
        // Simply iterate nodes in their stored order
        for v in g.nodes() {
            dfs(v)
        }

        return fas
    }

    /// Reverses an edge in the graph, marking it as reversed
    /// TypeScript reuses the same label object to preserve all properties
    /// - Throws: `GraphError` if edge operations fail
    static func reverseEdge(_ g: DagreGraph, edge: Edge) throws {
        guard let label = g.edge(edge.id) else { return }

        // Remove original edge
        g.removeEdge(edge.v, edge.w, name: edge.name)

        // TypeScript (acyclic.js lines 15-20):
        //   let label = g.edge(e);
        //   g.removeEdge(e);
        //   label.forwardName = e.name;
        //   label.reversed = true;
        //   g.setEdge(e.w, e.v, label, uniqueId("rev"));
        //
        // Reuse the SAME label object to preserve all properties
        label.forwardName = edge.name
        label.reversed = true

        // Use a unique ID for the reversed edge name, matching dagrejs behavior
        // This prevents overwriting an existing edge in the opposite direction
        let revName = uniqueReverseId()
        try g.setEdge(edge.w, edge.v, label: label, name: revName)
    }
}
