// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre
// This is a port of graphlib's Graph class

/// Errors that can occur during graph operations
public enum GraphError: Error, CustomStringConvertible {
    case cycleDetected(parent: String, child: String)
    case namedEdgeOnNonMultigraph
    case parentOnNonCompound
    case intersectionAtRectangleCenter

    public var description: String {
        switch self {
        case .cycleDetected(let parent, let child):
            return "Setting \(parent) as parent of \(child) would create a cycle"
        case .namedEdgeOnNonMultigraph:
            return "Cannot set a named edge when isMultigraph = false"
        case .parentOnNonCompound:
            return "Cannot set parent in a non-compound graph"
        case .intersectionAtRectangleCenter:
            return "Not possible to find intersection inside of the rectangle"
        }
    }
}

/// A graph data structure supporting directed/undirected, simple/multigraph, and compound graphs.
/// This is a port of the graphlib Graph class used by dagre.
public final class Graph<NodeLabel, EdgeLabel> {
    // MARK: - Configuration

    public let options: GraphOptions

    /// Whether this is a directed graph
    public var isDirected: Bool { options.directed }

    /// Whether this graph allows multiple edges between the same nodes
    public var isMultigraph: Bool { options.multigraph }

    /// Whether this graph supports parent-child relationships
    public var isCompound: Bool { options.compound }

    // MARK: - Graph-level label

    private var _graphLabel: Any?

    // MARK: - Node storage

    /// Node labels indexed by node ID
    private var _nodes: [String: NodeLabel] = [:]

    /// All nodes that exist in the graph (even those without labels)
    private var _nodeSet: Set<String> = []

    /// Node insertion order for deterministic iteration
    private var _nodeOrder: [String] = []

    // MARK: - Edge storage

    /// Edge labels indexed by EdgeId
    private var _edgeLabels: [EdgeId: EdgeLabel] = [:]

    /// Edge objects for each edge (for returning edge info)
    private var _edgeObjs: [EdgeId: Edge] = [:]

    /// Outgoing edges from each node: node -> [edgeId]
    private var _out: [String: [EdgeId]] = [:]

    /// Incoming edges to each node: node -> [edgeId]
    private var _in: [String: [EdgeId]] = [:]

    /// For multigraphs: node -> node -> count
    private var _edgeCount: Int = 0

    /// Edge insertion order for deterministic iteration
    private var _edgeOrder: [EdgeId] = []

    // MARK: - Compound graph storage (only used when compound = true)

    /// Parent of each node
    private var _parent: [String: String] = [:]

    /// Children of each node (nil key = root children)
    private var _children: [String?: Set<String>] = [nil: []]

    // MARK: - Default label factories

    private var _defaultNodeLabelFn: ((String) -> NodeLabel)?
    private var _defaultEdgeLabelFn: ((String, String, String?) -> EdgeLabel)?

    // MARK: - Initialization

    public init(options: GraphOptions = GraphOptions()) {
        self.options = options
    }

    // MARK: - Graph-level operations

    /// Set the graph-level label
    public func setGraph(_ label: Any?) {
        _graphLabel = label
    }

    /// Get the graph-level label
    public func graph() -> Any? {
        _graphLabel
    }

    /// Set the default node label factory function
    public func setDefaultNodeLabel(_ fn: @escaping (String) -> NodeLabel) {
        _defaultNodeLabelFn = fn
    }

    /// Set the default edge label factory function
    public func setDefaultEdgeLabel(_ fn: @escaping (String, String, String?) -> EdgeLabel) {
        _defaultEdgeLabelFn = fn
    }

    // MARK: - Node operations

    /// Returns the number of nodes in the graph
    public func nodeCount() -> Int {
        _nodeSet.count
    }

    /// Returns all node IDs in the graph (in insertion order for determinism)
    public func nodes() -> [String] {
        _nodeOrder
    }

    /// Returns source nodes (nodes with no in-edges) in insertion order
    public func sources() -> [String] {
        _nodeOrder.filter { node in
            (_in[node] ?? []).isEmpty
        }
    }

    /// Returns sink nodes (nodes with no out-edges) in insertion order
    public func sinks() -> [String] {
        _nodeOrder.filter { node in
            (_out[node] ?? []).isEmpty
        }
    }

    /// Adds a node to the graph with an optional label
    @discardableResult
    public func setNode(_ v: String, label: NodeLabel? = nil) -> Self {
        if _nodeSet.contains(v) {
            // Node exists, update label if provided
            if let label = label {
                _nodes[v] = label
            }
            return self
        }

        // New node
        _nodeSet.insert(v)
        _nodeOrder.append(v)
        if let label = label {
            _nodes[v] = label
        } else if let factory = _defaultNodeLabelFn {
            _nodes[v] = factory(v)
        }

        _in[v] = []
        _out[v] = []

        if isCompound {
            _parent[v] = nil
            _children[v] = []
            _children[nil, default: []].insert(v)
        }

        return self
    }

    /// Returns the label for a node, or nil if the node doesn't exist
    public func node(_ v: String) -> NodeLabel? {
        _nodes[v]
    }

    /// Returns true if the graph contains the node
    public func hasNode(_ v: String) -> Bool {
        _nodeSet.contains(v)
    }

    /// Removes a node and all incident edges from the graph
    @discardableResult
    public func removeNode(_ v: String) -> Self {
        guard _nodeSet.contains(v) else { return self }

        // Remove all incident edges
        if let inEdges = _in[v] {
            for edgeId in inEdges {
                removeEdgeById(edgeId)
            }
        }
        if let outEdges = _out[v] {
            for edgeId in outEdges {
                removeEdgeById(edgeId)
            }
        }

        // Clean up compound structure
        if isCompound {
            // Remove from parent's children
            if let parent = _parent[v] {
                _children[parent]?.remove(v)
            } else {
                _children[nil]?.remove(v)
            }

            // Move children to root (setting parent to nil can never create a cycle)
            if let children = _children[v] {
                for child in children {
                    try? setParent(child, parent: nil)
                }
            }
            _children.removeValue(forKey: v)
            _parent.removeValue(forKey: v)
        }

        _nodeSet.remove(v)
        _nodeOrder.removeAll { $0 == v }
        _nodes.removeValue(forKey: v)
        _in.removeValue(forKey: v)
        _out.removeValue(forKey: v)

        return self
    }

    // MARK: - Edge operations

    /// Returns the number of edges in the graph
    public func edgeCount() -> Int {
        _edgeCount
    }

    /// Returns all edges in the graph (in insertion order for determinism)
    public func edges() -> [Edge] {
        _edgeOrder.compactMap { _edgeObjs[$0] }
    }

    /// Adds an edge to the graph
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if a name is provided but the graph is not a multigraph
    @discardableResult
    public func setEdge(_ v: String, _ w: String, label: EdgeLabel? = nil, name: String? = nil) throws -> Self {
        let edgeId = makeEdgeId(v, w, name)

        // Ensure both nodes exist
        if !hasNode(v) { setNode(v) }
        if !hasNode(w) { setNode(w) }

        if _edgeLabels[edgeId] != nil {
            // Edge exists, update label if provided
            if let label = label {
                _edgeLabels[edgeId] = label
            }
            return self
        }

        // Check multigraph constraints
        // TypeScript: throw new Error("Cannot set a named edge when isMultigraph = false")
        if !isMultigraph && name != nil {
            throw GraphError.namedEdgeOnNonMultigraph
        }

        // New edge
        if let label = label {
            _edgeLabels[edgeId] = label
        } else if let factory = _defaultEdgeLabelFn {
            _edgeLabels[edgeId] = factory(v, w, name)
        }

        _edgeObjs[edgeId] = Edge(edgeId)
        _out[v, default: []].append(edgeId)
        _in[w, default: []].append(edgeId)
        _edgeCount += 1
        _edgeOrder.append(edgeId)

        return self
    }

    /// Adds an edge using an EdgeId
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if a name is provided but the graph is not a multigraph
    @discardableResult
    public func setEdge(_ edge: EdgeId, label: EdgeLabel? = nil) throws -> Self {
        try setEdge(edge.v, edge.w, label: label, name: edge.name)
    }

    /// Returns the label for an edge, or nil if the edge doesn't exist
    public func edge(_ v: String, _ w: String, name: String? = nil) -> EdgeLabel? {
        let edgeId = makeEdgeId(v, w, name)
        return _edgeLabels[edgeId]
    }

    /// Returns the label for an edge using an EdgeId
    public func edge(_ edgeId: EdgeId) -> EdgeLabel? {
        let normalizedId = makeEdgeId(edgeId.v, edgeId.w, edgeId.name)
        return _edgeLabels[normalizedId]
    }

    /// Returns true if the graph contains the edge
    public func hasEdge(_ v: String, _ w: String, name: String? = nil) -> Bool {
        let edgeId = makeEdgeId(v, w, name)
        return _edgeLabels[edgeId] != nil
    }

    /// Returns true if the graph contains the edge
    public func hasEdge(_ edgeId: EdgeId) -> Bool {
        hasEdge(edgeId.v, edgeId.w, name: edgeId.name)
    }

    /// Removes an edge from the graph
    @discardableResult
    public func removeEdge(_ v: String, _ w: String, name: String? = nil) -> Self {
        let edgeId = makeEdgeId(v, w, name)
        removeEdgeById(edgeId)
        return self
    }

    /// Removes an edge using an EdgeId
    @discardableResult
    public func removeEdge(_ edgeId: EdgeId) -> Self {
        removeEdge(edgeId.v, edgeId.w, name: edgeId.name)
    }

    private func removeEdgeById(_ edgeId: EdgeId) {
        guard _edgeLabels[edgeId] != nil else { return }

        _edgeLabels.removeValue(forKey: edgeId)
        _edgeObjs.removeValue(forKey: edgeId)
        _out[edgeId.v]?.removeAll { $0 == edgeId }
        _in[edgeId.w]?.removeAll { $0 == edgeId }
        _edgeOrder.removeAll { $0 == edgeId }
        _edgeCount -= 1
    }

    // MARK: - Edge queries

    /// Returns all edges coming into a node
    public func inEdges(_ v: String, u: String? = nil) -> [Edge]? {
        guard let edges = _in[v] else { return nil }

        if let u = u {
            return edges.filter { $0.v == u }.map { Edge($0) }
        }
        return edges.map { Edge($0) }
    }

    /// Returns all edges going out of a node
    public func outEdges(_ v: String, w: String? = nil) -> [Edge]? {
        guard let edges = _out[v] else { return nil }

        if let w = w {
            return edges.filter { $0.w == w }.map { Edge($0) }
        }
        return edges.map { Edge($0) }
    }

    /// Returns all edges incident to a node (both in and out)
    public func nodeEdges(_ v: String, u: String? = nil) -> [Edge]? {
        guard hasNode(v) else { return nil }

        var result: [Edge] = []
        if let inEdges = inEdges(v, u: u) {
            result.append(contentsOf: inEdges)
        }
        if let outEdges = outEdges(v, w: u) {
            // Avoid duplicates for self-loops
            for edge in outEdges {
                if edge.v != edge.w || !result.contains(edge) {
                    result.append(edge)
                }
            }
        }
        return result
    }

    /// Returns predecessor nodes of v (nodes with edges pointing to v)
    public func predecessors(_ v: String) -> [String]? {
        guard let edges = _in[v] else { return nil }
        var seen = Set<String>()
        var preds: [String] = []
        for edgeId in edges {
            if !seen.contains(edgeId.v) {
                seen.insert(edgeId.v)
                preds.append(edgeId.v)
            }
        }
        return preds
    }

    /// Returns successor nodes of v (nodes with edges from v)
    public func successors(_ v: String) -> [String]? {
        guard let edges = _out[v] else { return nil }
        var seen = Set<String>()
        var succs: [String] = []
        for edgeId in edges {
            if !seen.contains(edgeId.w) {
                seen.insert(edgeId.w)
                succs.append(edgeId.w)
            }
        }
        return succs
    }

    /// Returns all neighbor nodes of v (union of predecessors and successors)
    public func neighbors(_ v: String) -> [String]? {
        guard hasNode(v) else { return nil }
        var seen = Set<String>()
        var result: [String] = []
        if let preds = predecessors(v) {
            for p in preds {
                if !seen.contains(p) {
                    seen.insert(p)
                    result.append(p)
                }
            }
        }
        if let succs = successors(v) {
            for s in succs {
                if !seen.contains(s) {
                    seen.insert(s)
                    result.append(s)
                }
            }
        }
        return result
    }

    /// Returns true if v is a leaf node (no children in compound graph, or just has edges)
    public func isLeaf(_ v: String) -> Bool {
        if isCompound {
            return (_children[v] ?? []).isEmpty
        }
        return true
    }

    // MARK: - Compound graph operations

    /// Sets the parent of a node. Only valid for compound graphs.
    /// - Throws: `GraphError.cycleDetected` if setting this parent would create a cycle
    @discardableResult
    public func setParent(_ v: String, parent: String?) throws -> Self {
        // TypeScript: throw new Error("Cannot set parent in a non-compound graph")
        guard isCompound else { throw GraphError.parentOnNonCompound }

        // Ensure the node exists
        if !hasNode(v) { setNode(v) }

        // Ensure the parent exists (if not nil)
        if let parent = parent, !hasNode(parent) { setNode(parent) }

        // Cycle detection: check if setting this parent would create a cycle
        // TypeScript: for (var ancestor = parent; ancestor !== undefined; ancestor = this.parent(ancestor))
        if let parent = parent {
            var ancestor: String? = parent
            while let current = ancestor {
                if current == v {
                    // TypeScript: throw new Error("Setting " + parent + " as parent of " + v + " would create a cycle")
                    throw GraphError.cycleDetected(parent: parent, child: v)
                }
                ancestor = _parent[current] ?? nil
            }
        }

        // Remove from old parent
        if let oldParent = _parent[v] {
            _children[oldParent]?.remove(v)
        } else {
            _children[nil]?.remove(v)
        }

        // Add to new parent
        _parent[v] = parent
        if let parent = parent {
            _children[parent, default: []].insert(v)
        } else {
            _children[nil, default: []].insert(v)
        }

        return self
    }

    /// Returns the parent of a node, or nil if it has no parent
    public func parent(_ v: String) -> String? {
        guard isCompound else { return nil }
        return _parent[v] ?? nil
    }

    /// Returns the children of a node. Pass nil to get root-level nodes.
    /// Children are returned in their insertion order (subset of nodeOrder).
    public func children(_ v: String? = nil) -> [String]? {
        guard isCompound else {
            if v == nil {
                return nodes()
            }
            return hasNode(v!) ? [] : nil
        }

        let childSet: Set<String>
        if v == nil {
            childSet = _children[nil] ?? []
        } else {
            guard hasNode(v!) else { return nil }
            childSet = _children[v!] ?? []
        }

        // Return children in node insertion order for determinism
        return _nodeOrder.filter { childSet.contains($0) }
    }

    // MARK: - Helper methods

    /// Creates an EdgeId, normalizing for undirected graphs
    private func makeEdgeId(_ v: String, _ w: String, _ name: String?) -> EdgeId {
        if isDirected || v <= w {
            return EdgeId(v: v, w: w, name: isMultigraph ? name : nil)
        } else {
            return EdgeId(v: w, w: v, name: isMultigraph ? name : nil)
        }
    }

    /// Filter edges by a predicate
    public func filterEdges(_ predicate: (Edge) -> Bool) -> [Edge] {
        edges().filter(predicate)
    }
}

// MARK: - Extensions for common operations

extension Graph {
    /// Returns all descendant nodes of v in a compound graph
    public func descendants(of v: String) -> Set<String> {
        guard isCompound else { return [] }

        var result = Set<String>()
        var stack = [v]

        while let current = stack.popLast() {
            if let children = children(current) {
                for child in children {
                    result.insert(child)
                    stack.append(child)
                }
            }
        }

        return result
    }

    /// Returns all ancestor nodes of v in a compound graph
    public func ancestors(of v: String) -> [String] {
        guard isCompound else { return [] }

        var result: [String] = []
        var current = parent(v)

        while let p = current {
            result.append(p)
            current = parent(p)
        }

        return result
    }

    /// Returns the lowest common ancestor of two nodes
    public func lowestCommonAncestor(_ v: String, _ w: String) -> String? {
        guard isCompound else { return nil }

        let vAncestors = Set([v] + ancestors(of: v))
        var current: String? = w

        while let c = current {
            if vAncestors.contains(c) {
                return c
            }
            current = parent(c)
        }

        return nil
    }
}

// MARK: - Copying

extension Graph where NodeLabel: AnyObject, EdgeLabel: AnyObject {
    /// Creates a shallow copy of the graph (shares label references)
    public func copy() throws -> Graph<NodeLabel, EdgeLabel> {
        let g = Graph<NodeLabel, EdgeLabel>(options: options)

        g._graphLabel = _graphLabel

        for v in nodes() {
            g.setNode(v, label: node(v))
        }

        for edge in edges() {
            try g.setEdge(edge.v, edge.w, label: self.edge(edge.id), name: edge.name)
        }

        if isCompound {
            for v in nodes() {
                if let p = parent(v) {
                    try g.setParent(v, parent: p)
                }
            }
        }

        return g
    }

    // MARK: - Additional API Methods (TypeScript graphlib compatibility)

    /// Returns a new graph with nodes filtered by predicate
    /// If parent is rejected, all children are also rejected (compound graphs)
    /// Note: Uses try? for setEdge since options are preserved and this should not fail
    public func filterNodes(_ filter: (String) -> Bool) -> Graph<NodeLabel, EdgeLabel> {
        let g = Graph<NodeLabel, EdgeLabel>(options: options)

        // Copy graph label
        if let label = graph() {
            g.setGraph(label)
        }

        // Copy nodes that pass filter
        for v in nodes() {
            if filter(v) {
                g.setNode(v, label: node(v))
            }
        }

        // Copy edges where both endpoints pass filter (options preserved, should not fail)
        for edge in edges() {
            if g.hasNode(edge.v) && g.hasNode(edge.w) {
                _ = try? g.setEdge(edge.v, edge.w, label: self.edge(edge.id), name: edge.name)
            }
        }

        // Copy parent relationships (only if parent also passed filter)
        if isCompound {
            for v in g.nodes() {
                if let p = parent(v), g.hasNode(p) {
                    _ = try? g.setParent(v, parent: p)
                }
            }
        }

        return g
    }

    /// Batch set multiple nodes with same label
    @discardableResult
    public func setNodes(_ nodes: [String], label: NodeLabel? = nil) -> Self {
        for v in nodes {
            setNode(v, label: label)
        }
        return self
    }

    /// Creates edges along a path of nodes
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if edge creation fails
    @discardableResult
    public func setPath(_ nodes: [String], label: EdgeLabel? = nil) throws -> Self {
        guard nodes.count >= 2 else { return self }
        for i in 0..<(nodes.count - 1) {
            try setEdge(nodes[i], nodes[i + 1], label: label)
        }
        return self
    }

    /// Returns edge as dictionary with v, w, name properties
    public func edgeAsObj(_ edge: Edge) -> [String: String?] {
        return [
            "v": edge.v,
            "w": edge.w,
            "name": edge.name
        ]
    }
}
