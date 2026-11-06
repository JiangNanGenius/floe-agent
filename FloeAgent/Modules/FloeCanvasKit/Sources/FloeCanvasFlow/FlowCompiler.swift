import Foundation
import FloeCanvasCore
import FloeCanvasIntegration

// MARK: - Scope selection
//
// A run executes either the whole graph or an explicitly selected node set.
// Selected scopes still validate as structured flow: every selected node's
// required inputs must come from inside the scope or from declared run
// inputs; ordinary canvas relations never participate.

public enum FlowScopeSelection: Hashable, Sendable {
    case wholeGraph
    case selectedNodes(Set<UUID>)
}

// MARK: - Compiler issues
//
// The frozen `CanvasFlowIssue` enum carries the P0 validator's eight codes.
// The strict compiler adds its own actionable codes on top; every issue
// references the node or edge that must be fixed and carries the base
// validator issue when one exists.

public struct FlowCompilerIssue: Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        case baseValidator
        case unknownScopeNode
        case emptyCompositeBody
        case bodyReferencesOutOfScopeNodes
        case bodyNodeClaimedTwice
        case compositeFeedsBody
        case bodyCycle
        case bodyCarryInvalid
        case invalidStopPredicate
        case concurrentVariableWrite
        case outerCycle
        case portTypeMismatch
        case duplicateInputEdge
    }

    public var code: Code
    public var nodeID: UUID?
    public var edgeID: UUID?
    public var detail: String?
    /// Set when this issue wraps a frozen-validator finding.
    public var base: CanvasFlowIssue?

    public init(
        code: Code,
        nodeID: UUID? = nil,
        edgeID: UUID? = nil,
        detail: String? = nil,
        base: CanvasFlowIssue? = nil
    ) {
        self.code = code
        self.nodeID = nodeID
        self.edgeID = edgeID
        self.detail = detail
        self.base = base
    }
}

public enum FlowCompilationError: Error, Hashable, Sendable {
    case failed([FlowCompilerIssue])
}

// MARK: - Compiled structures

/// A validated, deterministically scheduled flow graph. The runtime only
/// consumes compiled graphs; raw `FlowGraph` values must pass the compiler
/// first so scheduling order, loop ownership and variable scoping are fixed
/// before any work is submitted.
public struct CompiledFlow: Sendable {
    public struct LoopBody: Sendable {
        public var loopNodeID: UUID
        /// Deterministic topological order of the body per iteration.
        public var bodyOrder: [UUID]
        /// Edges from body nodes back to the loop node's input ports. The
        /// source output of the last completed iteration feeds the named
        /// loop input port on the next iteration; the value is exposed to
        /// the body as a loop-scope variable named `carry.<portName>`.
        public var carryEdges: [FlowEdge]
        /// Edges from outside the body into body nodes; bound once before
        /// the first iteration.
        public var entryEdges: [FlowEdge]
        /// Edges from body nodes to outside destinations; the last
        /// iteration's values flow out.
        public var exitEdges: [FlowEdge]
        public var bound: Int
        public var stopPredicate: FlowPredicate?
    }

    public struct BatchBody: Sendable {
        public var batchNodeID: UUID
        public var bodyOrder: [UUID]
        public var entryEdges: [FlowEdge]
        public var exitEdges: [FlowEdge]
        /// Variable read at the end of each item execution to build the
        /// per-item results list. Default `itemResult`.
        public var collectVariable: String
    }

    public struct VariablePlan: Sendable {
        /// Variables declared in the graph, grouped by owner node.
        public var byOwner: [UUID: [FlowVariable]]
        /// Variables whose owner is outside the scoped graph resolve in the
        /// run frame.
        public var runLevel: [FlowVariable]
    }

    public let graph: FlowGraph
    public let scope: FlowScopeSelection
    /// Deterministic outer scheduling order over schedulable units (regular
    /// nodes and top-level composites), stable tie-break on UUID. Body
    /// nodes are scheduled by their owning composite.
    public let topoOrder: [UUID]
    public let nodes: [UUID: FlowNode]
    /// Longest-path depth per schedulable unit; equal-depth units are
    /// concurrency-safe.
    public let depth: [UUID: Int]
    public let incomingEdges: [UUID: [FlowEdge]]
    public let outgoingEdges: [UUID: [FlowEdge]]
    public let loops: [UUID: LoopBody]
    public let batches: [UUID: BatchBody]
    public let variables: VariablePlan
    /// Input ports with no in-scope edge; must be bound by run inputs.
    public let requiredInputs: [UUID: [String]]
    /// Canonical digest binding the compiled structure to its graph.
    public let graphDigest: String
    /// Nodes inside any structured body — scheduled by their composite.
    /// Nested composites appear here too (owned by an enclosing body).
    public let bodyNodeIDs: Set<UUID>

    public func node(_ id: UUID) -> FlowNode? { nodes[id] }
}

// MARK: - Compiler

/// Strict compiler over the frozen `FlowGraph` data contract.
///
/// Beyond the P0 `FlowGraphValidator` (a structural approximation), the
/// compiler enforces:
///
/// 1. The outer graph is a DAG with a deterministic scheduling order.
/// 2. Every loop/batch body is owned by exactly one composite node; bodies
///    may not be shared; a body's internal wiring must itself be acyclic
///    each iteration — arbitrary body cycles are NOT blanket-allowed. The
///    only feedback edges permitted are explicit carries back to the owning
///    loop node's input ports.
/// 3. Composite nodes may not feed body nodes directly (loop/batch nodes
///    carry no per-iteration outputs). Nested composites are allowed: a
///    composite inside a body is scheduled by that body's iteration.
/// 4. Required input ports must be satisfiable from in-scope edges or from
///    declared run inputs.
/// 5. Two nodes that may run concurrently (incomparable in the scoped DAG,
///    or co-scheduled inside one body wave) must not write the same
///    variable — concurrent variable writes are rejected at compile time.
public enum FlowGraphCompiler {
    public static func compile(
        _ graph: FlowGraph,
        scope: FlowScopeSelection = .wholeGraph,
        maxLoopIterations: Int = FlowGraph.defaultMaxLoopIterations
    ) throws -> CompiledFlow {
        var issues: [FlowCompilerIssue] = []

        // Layer 1: frozen P0 structural validation, wrapped verbatim.
        // Exception: the base validator has no `.json` wildcard concept and
        // flags json↔concrete edges as type mismatches; the strict layer
        // owns the real compatibility rules (FlowEvaluation.edgeCompatible),
        // so those specific base findings are dropped — genuine mismatches
        // are still reported by Layer 1b.
        for base in FlowGraphValidator.validate(graph, maxLoopIterations: maxLoopIterations)
        where base.severity == .error {
            if base.code == .portTypeMismatch, let edgeID = base.edgeID,
               let edge = graph.edges.first(where: { $0.id == edgeID }),
               let source = graph.nodes.first(where: { $0.id == edge.sourceNodeID }),
               let destination = graph.nodes.first(where: { $0.id == edge.destinationNodeID }),
               let sourcePort = source.ports.first(where: { $0.id == edge.sourcePortID }),
               let destinationPort = destination.ports.first(where: { $0.id == edge.destinationPortID }),
               FlowEvaluation.edgeCompatible(
                    source: sourcePort.dataType,
                    sourceVariadic: sourcePort.isVariadic,
                    destination: destinationPort.dataType,
                    destinationVariadic: destinationPort.isVariadic) {
                continue
            }
            issues.append(.init(code: .baseValidator, base: base))
        }

        let scopedNodeIDs: Set<UUID> = switch scope {
        case .wholeGraph: Set(graph.nodes.map(\.id))
        case .selectedNodes(let ids): ids
        }
        var nodes: [UUID: FlowNode] = [:]
        for node in graph.nodes where scopedNodeIDs.contains(node.id) {
            nodes[node.id] = node
        }
        for id in scopedNodeIDs.sorted(by: { $0.uuidString < $1.uuidString })
        where nodes[id] == nil {
            issues.append(.init(code: .unknownScopeNode, nodeID: id,
                                detail: "scope selects node \(id.uuidString) that is not in the graph"))
        }

        let scopedEdges = graph.edges
            .filter { scopedNodeIDs.contains($0.sourceNodeID) && scopedNodeIDs.contains($0.destinationNodeID) }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        // Layer 1b: strict edge compatibility. The P0 validator is a
        // structural approximation: it waives type checks whenever a
        // variadic port is involved. `isVariadic` only declares aggregation
        // cardinality — it never waives type compatibility. `.json` is the
        // explicit wildcard/projection type (see FlowEvaluation).
        // Carry edges (body → owning loop input port) are feedback wiring,
        // not duplicate bindings: they are exempt from the single-input
        // rule but still type-checked.
        var carryEdgeIDs = Set<UUID>()
        for node in graph.nodes where node.kind == .loop {
            let body = Set(node.bodyNodeIDs ?? [])
            for edge in graph.edges
            where edge.destinationNodeID == node.id && body.contains(edge.sourceNodeID) {
                carryEdgeIDs.insert(edge.id)
            }
        }
        var edgeCountByInputPort: [UUID: Int] = [:]
        for edge in scopedEdges {
            guard let source = nodes[edge.sourceNodeID],
                  let destination = nodes[edge.destinationNodeID],
                  let sourcePort = source.ports.first(where: { $0.id == edge.sourcePortID }),
                  let destinationPort = destination.ports
                    .first(where: { $0.id == edge.destinationPortID }) else {
                continue // dangling endpoints flagged by the base validator
            }
            guard sourcePort.direction == .output, destinationPort.direction == .input else {
                continue // direction errors flagged by the base validator
            }
            if !destinationPort.isVariadic, !carryEdgeIDs.contains(edge.id) {
                let count = (edgeCountByInputPort[edge.destinationPortID] ?? 0) + 1
                edgeCountByInputPort[edge.destinationPortID] = count
                if count > 1 {
                    issues.append(.init(
                        code: .duplicateInputEdge, nodeID: destination.id, edgeID: edge.id,
                        detail: "non-variadic input port '\(destinationPort.name)' of node "
                            + "'\(destination.name)' receives multiple edges"))
                }
            }
            if !FlowEvaluation.edgeCompatible(
                source: sourcePort.dataType,
                sourceVariadic: sourcePort.isVariadic,
                destination: destinationPort.dataType,
                destinationVariadic: destinationPort.isVariadic
            ) {
                let relation = sourcePort.isVariadic || destinationPort.isVariadic
                    ? "element/aggregate" : "direct"
                issues.append(.init(
                    code: .portTypeMismatch, nodeID: destination.id, edgeID: edge.id,
                    detail: "\(relation) type mismatch \(sourcePort.dataType.rawValue)"
                        + (sourcePort.isVariadic ? "…(variadic)" : "")
                        + " → \(destinationPort.dataType.rawValue)"
                        + (destinationPort.isVariadic ? "…(variadic)" : "")))
            }
        }

        // Layer 2: composite ownership analysis (deterministic order).
        var ownership: [UUID: UUID] = [:] // body node → owning composite
        var loops: [UUID: CompiledFlow.LoopBody] = [:]
        var batches: [UUID: CompiledFlow.BatchBody] = [:]

        let composites = nodes.values
            .filter { $0.kind == .loop || $0.kind == .batch }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for node in composites {
            let body = node.bodyNodeIDs ?? []
            let uniqueBody = Set(body)
            if uniqueBody.isEmpty {
                issues.append(.init(code: .emptyCompositeBody, nodeID: node.id,
                                    detail: "\(node.kind.rawValue) declares an empty body"))
                continue
            }
            let missing = uniqueBody.subtracting(nodes.keys)
            if !missing.isEmpty {
                issues.append(.init(code: .bodyReferencesOutOfScopeNodes, nodeID: node.id,
                                    detail: "body references \(missing.count) nodes outside the scope"))
                continue
            }
            for bodyID in uniqueBody.sorted(by: { $0.uuidString < $1.uuidString }) {
                if let existing = ownership[bodyID], existing != node.id {
                    issues.append(.init(code: .bodyNodeClaimedTwice, nodeID: bodyID,
                                        detail: "node is claimed by bodies of \(existing.uuidString) and \(node.id.uuidString)"))
                }
                ownership[bodyID] = node.id
            }

            let bodySet = uniqueBody
            let internalEdges = scopedEdges.filter {
                bodySet.contains($0.sourceNodeID) && bodySet.contains($0.destinationNodeID)
            }
            let toComposite = scopedEdges.filter {
                bodySet.contains($0.sourceNodeID) && $0.destinationNodeID == node.id
            }
            let fromComposite = scopedEdges.filter {
                $0.sourceNodeID == node.id && bodySet.contains($0.destinationNodeID)
            }
            let entryEdges = scopedEdges.filter {
                !bodySet.contains($0.sourceNodeID) && bodySet.contains($0.destinationNodeID)
                    && $0.sourceNodeID != node.id
            }
            let exitEdges = scopedEdges.filter {
                bodySet.contains($0.sourceNodeID) && !bodySet.contains($0.destinationNodeID)
                    && $0.destinationNodeID != node.id
            }

            for edge in fromComposite {
                issues.append(.init(code: .compositeFeedsBody, nodeID: node.id, edgeID: edge.id,
                                    detail: "a \(node.kind.rawValue) node may not feed its own body"))
            }

            // Internal body wiring must be acyclic each iteration. Feedback
            // is allowed ONLY as explicit carries to the owning composite.
            if let cycle = findCycle(nodeIDs: bodySet, edges: internalEdges) {
                issues.append(.init(code: .bodyCycle, nodeID: node.id,
                                    detail: "cycle inside \(node.kind.rawValue) body: "
                                        + cycle.map(\.uuidString).joined(separator: "→")))
            }

            let bodyOrder = topologicalOrder(
                nodes: nodes,
                edges: internalEdges + entryEdges,
                restrictingTo: bodySet)

            if node.kind == .batch {
                for edge in toComposite {
                    issues.append(.init(code: .bodyCarryInvalid, nodeID: node.id, edgeID: edge.id,
                                        detail: "batch items are isolated; bodies may not carry back to the batch node"))
                }
                let collectVariable = node.parameters["collectVariable"]?.flowString ?? "itemResult"
                batches[node.id] = .init(
                    batchNodeID: node.id,
                    bodyOrder: bodyOrder,
                    entryEdges: entryEdges,
                    exitEdges: exitEdges,
                    collectVariable: collectVariable)
            } else {
                let bound = FlowGraphValidator.loopBound(of: node)
                if bound < 1 || bound > maxLoopIterations {
                    issues.append(.init(code: .baseValidator, nodeID: node.id,
                                        detail: "loop bound \(bound) outside 1...\(maxLoopIterations)",
                                        base: .init(severity: .error, code: .invalidLoop, nodeID: node.id)))
                }
                var stopPredicate: FlowPredicate? = nil
                if let predicateJSON = node.parameters["stopWhen"] {
                    do {
                        stopPredicate = try FlowLiterals.decodeFromJSON(predicateJSON, as: FlowPredicate.self)
                    } catch {
                        issues.append(.init(code: .invalidStopPredicate, nodeID: node.id,
                                            detail: "stopWhen must be an encoded FlowPredicate"))
                    }
                }
                loops[node.id] = .init(
                    loopNodeID: node.id,
                    bodyOrder: bodyOrder,
                    carryEdges: toComposite.sorted { $0.id.uuidString < $1.id.uuidString },
                    entryEdges: entryEdges,
                    exitEdges: exitEdges,
                    bound: max(1, min(bound, maxLoopIterations)),
                    stopPredicate: stopPredicate)
            }
        }

        // Outermost composite owner per node (nested composites collapse to
        // the enclosing top-level composite for outer scheduling).
        func outermostOwner(_ id: UUID) -> UUID? {
            var current = id
            var steps = 0
            while let owner = ownership[current] {
                current = owner
                steps += 1
                if steps > nodes.count { break } // defensive; ownership is a DAG
            }
            return current == id ? nil : current
        }

        // Layer 3: required inputs per node. Body nodes are satisfied by
        // internal or entry edges targeting that node; schedulable units by
        // any in-scope contracted edge or by a declared run input.
        var requiredInputs: [UUID: [String]] = [:]
        func requiredPortNames(of node: FlowNode, satisfiedPortIDs: Set<UUID>) -> [String] {
            node.ports
                .filter { $0.direction == .input && !satisfiedPortIDs.contains($0.id) }
                .map(\.name)
                .sorted()
        }
        for node in nodes.values
            .sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where ownership[node.id] == nil {
            let satisfied = Set((scopedEdges.filter { $0.destinationNodeID == node.id })
                .map(\.destinationPortID))
            var required = requiredPortNames(of: node, satisfiedPortIDs: satisfied)
            if let loop = loops[node.id] {
                // Ports fed purely by iteration carries need no outside
                // binding; iteration 0 sees a null initial value.
                let carryNames = Set(loop.carryEdges.compactMap { edge in
                    node.ports.first(where: { $0.id == edge.destinationPortID })?.name
                })
                required = required.filter { !carryNames.contains($0) }
            }
            if !required.isEmpty { requiredInputs[node.id] = required }
        }
        for compositeID in loops.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let loop = loops[compositeID] else { continue }
            let bodySet = Set(loop.bodyOrder)
            let internalEdges = scopedEdges.filter {
                bodySet.contains($0.sourceNodeID) && bodySet.contains($0.destinationNodeID)
            }
            for bodyID in loop.bodyOrder {
                guard let node = nodes[bodyID] else { continue }
                let satisfied = Set(
                    (loop.entryEdges.filter { $0.destinationNodeID == bodyID }
                        + internalEdges.filter { $0.destinationNodeID == bodyID })
                        .map(\.destinationPortID))
                let required = requiredPortNames(of: node, satisfiedPortIDs: satisfied)
                if !required.isEmpty { requiredInputs[bodyID, default: []].append(contentsOf: required) }
            }
        }
        for batchID in batches.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let batch = batches[batchID] else { continue }
            let bodySet = Set(batch.bodyOrder)
            let internalEdges = scopedEdges.filter {
                bodySet.contains($0.sourceNodeID) && bodySet.contains($0.destinationNodeID)
            }
            for bodyID in batch.bodyOrder {
                guard let node = nodes[bodyID] else { continue }
                let satisfied = Set(
                    (batch.entryEdges.filter { $0.destinationNodeID == bodyID }
                        + internalEdges.filter { $0.destinationNodeID == bodyID })
                        .map(\.destinationPortID))
                let required = requiredPortNames(of: node, satisfiedPortIDs: satisfied)
                if !required.isEmpty { requiredInputs[bodyID, default: []].append(contentsOf: required) }
            }
        }

        // Layer 4: variable plan + concurrent write conflicts (on-demand
        // reachability only between actual writer candidates — no full
        // transitive closure, so 10k-node graphs stay cheap).
        var byOwner: [UUID: [FlowVariable]] = [:]
        var runLevel: [FlowVariable] = []
        for variable in graph.variables.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if scopedNodeIDs.contains(variable.ownerNodeID) {
                byOwner[variable.ownerNodeID, default: []].append(variable)
            } else {
                runLevel.append(variable)
            }
        }
        let adjacency = buildAdjacency(scopedEdges)
        for (name, writers) in detectWriteConflicts(
            nodes: nodes,
            adjacency: adjacency,
            ownership: ownership
        ).sorted(by: { $0.key < $1.key }) {
            issues.append(.init(code: .concurrentVariableWrite,
                                detail: "variable '\(name)' is written by concurrently schedulable nodes: "
                                    + writers.map(\.uuidString).joined(separator: ",")))
        }

        // Layer 5: deterministic outer order over schedulable units. Cross-
        // boundary edges (entry/exit) collapse onto their outermost owner so
        // a composite's outside dependencies are honoured before it runs.
        let bodyIDs = Set(ownership.keys)
        let schedulableUnits = Set(nodes.keys).subtracting(bodyIDs)
        var contractedAdjacency: [UUID: [UUID]] = [:]
        var contractedEdgeKeys = Set<String>()
        for edge in scopedEdges {
            let source = outermostOwner(edge.sourceNodeID) ?? edge.sourceNodeID
            let destination = outermostOwner(edge.destinationNodeID) ?? edge.destinationNodeID
            guard source != destination else { continue } // internal to one unit
            let key = source.uuidString + "→" + destination.uuidString
            if contractedEdgeKeys.insert(key).inserted {
                contractedAdjacency[source, default: []].append(destination)
            }
        }
        for key in contractedAdjacency.keys {
            contractedAdjacency[key]?.sort { $0.uuidString < $1.uuidString }
        }
        if findCycle(nodeIDs: schedulableUnits, adjacency: contractedAdjacency) != nil {
            issues.append(.init(code: .outerCycle,
                                detail: "cycle among schedulable units after collapsing composite bodies "
                                    + "(check entry/exit edges across loop or batch bodies)"))
        }
        let topo = topologicalOrder(adjacency: contractedAdjacency, restrictingTo: schedulableUnits)
        let depthMap = longestPathDepth(adjacency: contractedAdjacency, restrictingTo: schedulableUnits)

        if !issues.isEmpty {
            throw FlowCompilationError.failed(issues)
        }

        // A digest failure must surface, never silently continue with a
        // placeholder: the digest is part of the run-bound identity.
        let digest = try FlowDigest.of(graph)

        var incoming: [UUID: [FlowEdge]] = [:]
        var outgoing: [UUID: [FlowEdge]] = [:]
        for edge in scopedEdges {
            incoming[edge.destinationNodeID, default: []].append(edge)
            outgoing[edge.sourceNodeID, default: []].append(edge)
        }

        return CompiledFlow(
            graph: graph,
            scope: scope,
            topoOrder: topo,
            nodes: nodes,
            depth: depthMap,
            incomingEdges: incoming,
            outgoingEdges: outgoing,
            loops: loops,
            batches: batches,
            variables: .init(byOwner: byOwner, runLevel: runLevel),
            requiredInputs: requiredInputs,
            graphDigest: digest,
            bodyNodeIDs: bodyIDs)
    }

    // MARK: Cycle detection (iterative, deterministic, no recursion)

    static func findCycle(nodeIDs: Set<UUID>, edges: [FlowEdge]) -> [UUID]? {
        findCycle(nodeIDs: nodeIDs, adjacency: buildAdjacency(edges))
    }

    static func findCycle(nodeIDs: Set<UUID>, adjacency: [UUID: [UUID]]) -> [UUID]? {
        var state: [UUID: Int] = [:] // 1=in-stack 2=done
        var result: [UUID]? = nil
        let ids = nodeIDs.sorted { $0.uuidString < $1.uuidString }
        for start in ids where result == nil && state[start] == nil {
            // Iterative DFS with an explicit stack of (node, next-child-index).
            var stack: [UUID] = [start]
            var childIndexes: [UUID: Int] = [start: 0]
            state[start] = 1
            while let current = stack.last, result == nil {
                let index = childIndexes[current] ?? 0
                let children = adjacency[current] ?? []
                if index < children.count {
                    childIndexes[current] = index + 1
                    let next = children[index]
                    if state[next] == 1 {
                        if let cycleStart = stack.firstIndex(of: next) {
                            result = Array(stack[cycleStart...])
                        } else {
                            result = [current, next]
                        }
                    } else if state[next] == nil {
                        state[next] = 1
                        stack.append(next)
                        childIndexes[next] = 0
                    }
                } else {
                    state[current] = 2
                    stack.removeLast()
                    childIndexes.removeValue(forKey: current)
                }
            }
        }
        return result
    }

    static func buildAdjacency(_ edges: [FlowEdge]) -> [UUID: [UUID]] {
        var adjacency: [UUID: [UUID]] = [:]
        for edge in edges {
            adjacency[edge.sourceNodeID, default: []].append(edge.destinationNodeID)
        }
        for key in adjacency.keys {
            adjacency[key]?.sort { $0.uuidString < $1.uuidString }
        }
        return adjacency
    }

    /// Deterministic Kahn topological order over an explicit adjacency map.
    /// Selection always takes the smallest UUID among UNVISITED ready
    /// nodes — consumed nodes never re-enter the queue.
    static func topologicalOrder(
        adjacency: [UUID: [UUID]],
        restrictingTo allowed: Set<UUID>
    ) -> [UUID] {
        var indegree: [UUID: Int] = [:]
        for id in allowed { indegree[id] = 0 }
        for (source, destinations) in adjacency {
            guard allowed.contains(source) else { continue }
            for destination in destinations where allowed.contains(destination) {
                indegree[destination, default: 0] += 1
            }
        }
        var unvisitedReady = allowed
            .filter { indegree[$0] == 0 }
            .sorted { $0.uuidString < $1.uuidString }
        var visited = Set<UUID>()
        var order: [UUID] = []
        while !unvisitedReady.isEmpty {
            let current = unvisitedReady.removeFirst()
            guard visited.insert(current).inserted else { continue }
            order.append(current)
            for next in adjacency[current] ?? [] where allowed.contains(next) {
                indegree[next, default: 0] -= 1
                if indegree[next] == 0 {
                    // Sorted insert keeps the ready list minimal-first.
                    let insertion = unvisitedReady.firstIndex {
                        $0.uuidString > next.uuidString
                    } ?? unvisitedReady.count
                    unvisitedReady.insert(next, at: insertion)
                }
            }
        }
        return order
    }

    static func topologicalOrder(
        nodes: [UUID: FlowNode],
        edges: [FlowEdge],
        restrictingTo: Set<UUID>? = nil
    ) -> [UUID] {
        topologicalOrder(
            adjacency: buildAdjacency(edges),
            restrictingTo: restrictingTo ?? Set(nodes.keys))
    }

    static func longestPathDepth(
        adjacency: [UUID: [UUID]],
        restrictingTo allowed: Set<UUID>
    ) -> [UUID: Int] {
        let order = topologicalOrder(adjacency: adjacency, restrictingTo: allowed)
        var depth: [UUID: Int] = [:]
        var incomingSources: [UUID: [UUID]] = [:]
        for (source, destinations) in adjacency {
            for destination in destinations where allowed.contains(destination) {
                incomingSources[destination, default: []].append(source)
            }
        }
        for id in order {
            depth[id] = ((incomingSources[id] ?? []).compactMap { depth[$0] }.max() ?? -1) + 1
        }
        return depth
    }

    // MARK: Variable write conflicts (on-demand reachability)

    /// Two writes conflict when the writing nodes may execute concurrently:
    /// incomparable in the contracted DAG, or co-scheduled in the same body
    /// wave (equal depth with no path between them). Mutually exclusive
    /// condition branches are conservatively treated as concurrent — hosts
    /// should give each branch its own variable scope (owner = branch node).
    static func detectWriteConflicts(
        nodes: [UUID: FlowNode],
        adjacency: [UUID: [UUID]],
        ownership: [UUID: UUID]
    ) -> [String: [UUID]] {
        var writers: [String: [UUID]] = [:]
        for node in nodes.values {
            guard let mapping = node.parameters["writeVariables"]?.flowObject else { continue }
            for key in mapping.keys.sorted() {
                guard let name = mapping[key]?.flowString else { continue }
                writers[name, default: []].append(node.id)
            }
        }
        guard writers.contains(where: { $0.value.count > 1 }) else { return [:] }

        var conflicts: [String: Set<UUID>] = [:]
        for (name, ids) in writers where ids.count > 1 {
            let sorted = ids.sorted { $0.uuidString < $1.uuidString }
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    let a = sorted[i], b = sorted[j]
                    var comparable = isReachable(from: a, to: b, adjacency: adjacency)
                        || isReachable(from: b, to: a, adjacency: adjacency)
                    if !comparable,
                       let ownerA = ownership[a], let ownerB = ownership[b],
                       ownerA != ownerB {
                        comparable = isReachable(from: ownerA, to: ownerB, adjacency: adjacency)
                            || isReachable(from: ownerB, to: ownerA, adjacency: adjacency)
                    }
                    if !comparable {
                        conflicts[name, default: []].formUnion([a, b])
                    }
                }
            }
        }
        return conflicts.mapValues { $0.sorted { $0.uuidString < $1.uuidString } }
    }

    /// BFS reachability on demand — only executed for writer pairs, so
    /// large graphs never pay for a full transitive closure.
    static func isReachable(
        from source: UUID,
        to target: UUID,
        adjacency: [UUID: [UUID]]
    ) -> Bool {
        if source == target { return true }
        var visited: Set<UUID> = [source]
        var queue: [UUID] = [source]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for next in adjacency[current] ?? [] {
                if next == target { return true }
                if visited.insert(next).inserted { queue.append(next) }
            }
        }
        return false
    }
}
