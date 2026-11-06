// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Configuration options for Graph creation
public struct GraphOptions {
    /// If true, creates a directed graph (edges have direction). Default: true
    public var directed: Bool

    /// If true, allows multiple edges between the same pair of nodes. Default: false
    public var multigraph: Bool

    /// If true, supports hierarchical parent-child node relationships. Default: false
    public var compound: Bool

    public init(
        directed: Bool = true,
        multigraph: Bool = false,
        compound: Bool = false
    ) {
        self.directed = directed
        self.multigraph = multigraph
        self.compound = compound
    }
}
