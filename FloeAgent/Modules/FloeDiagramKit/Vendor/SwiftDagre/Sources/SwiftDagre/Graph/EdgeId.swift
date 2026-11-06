// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Uniquely identifies an edge in the graph
/// For multigraphs, includes an optional name to distinguish parallel edges
public struct EdgeId: Hashable, CustomStringConvertible {
    /// Source node ID
    public let v: String

    /// Target node ID
    public let w: String

    /// Optional name for multigraph edges (nil for simple graphs)
    public let name: String?

    public init(v: String, w: String, name: String? = nil) {
        self.v = v
        self.w = w
        self.name = name
    }

    public var description: String {
        if let name = name {
            return "\(v) -> \(w) [\(name)]"
        }
        return "\(v) -> \(w)"
    }

    /// Creates a reversed version of this edge
    public func reversed() -> EdgeId {
        EdgeId(v: w, w: v, name: name)
    }
}

/// Represents an edge with source, target, and optional name
/// Used when returning edge lists from the graph
public struct Edge: Hashable {
    public let v: String
    public let w: String
    public let name: String?

    public init(v: String, w: String, name: String? = nil) {
        self.v = v
        self.w = w
        self.name = name
    }

    public init(_ edgeId: EdgeId) {
        self.v = edgeId.v
        self.w = edgeId.w
        self.name = edgeId.name
    }

    public var id: EdgeId {
        EdgeId(v: v, w: w, name: name)
    }
}
