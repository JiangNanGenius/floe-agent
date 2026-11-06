import Foundation

// MARK: - Flow data contracts (Core, frozen for the future Flow runtime)
//
// These are pure DATA contracts only: no interpreter, no provider or
// network invocation, no job scheduling. Ordinary canvas relations
// (`CanvasRelationKind`) express how nodes relate; `FlowEdge` expresses an
// executable data flow between typed ports and is the only thing a future
// Flow runtime may schedule.

public enum FlowValueType: String, Codable, Hashable, Sendable, CaseIterable {
    case string, number, bool, list, table, asset, json
}

/// A typed runtime value. `.json` carries a structured payload the future
/// runtime validates lazily; no evaluation happens here.
public enum FlowValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([FlowValue])
    case table(header: [String], rows: [[String]])
    case asset(CanvasAssetLocator)
    case json(JSONValue)

    public var valueType: FlowValueType {
        switch self {
        case .string: return .string
        case .number: return .number
        case .bool: return .bool
        case .list: return .list
        case .table: return .table
        case .asset: return .asset
        case .json: return .json
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, string, number, bool, list, header, rows, asset, json
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(FlowValueType.self, forKey: .type)
        switch type {
        case .string: self = .string(try values.decode(String.self, forKey: .string))
        case .number: self = .number(try values.decode(Double.self, forKey: .number))
        case .bool: self = .bool(try values.decode(Bool.self, forKey: .bool))
        case .list: self = .list(try values.decode([FlowValue].self, forKey: .list))
        case .table:
            self = .table(
                header: try values.decodeIfPresent([String].self, forKey: .header) ?? [],
                rows: try values.decodeIfPresent([[String]].self, forKey: .rows) ?? []
            )
        case .asset: self = .asset(try values.decode(CanvasAssetLocator.self, forKey: .asset))
        case .json: self = .json(try values.decode(JSONValue.self, forKey: .json))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(valueType, forKey: .type)
        switch self {
        case .string(let value): try values.encode(value, forKey: .string)
        case .number(let value): try values.encode(value, forKey: .number)
        case .bool(let value): try values.encode(value, forKey: .bool)
        case .list(let value): try values.encode(value, forKey: .list)
        case .table(let header, let rows):
            try values.encode(header, forKey: .header)
            try values.encode(rows, forKey: .rows)
        case .asset(let value): try values.encode(value, forKey: .asset)
        case .json(let value): try values.encode(value, forKey: .json)
        }
    }
}

public enum FlowPortDirection: String, Codable, Hashable, Sendable {
    case input, output
}

/// A named, typed data port. Ports belong to flow nodes, not to canvas
/// relation endpoints.
public struct FlowPort: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var dataType: FlowValueType
    public var direction: FlowPortDirection
    /// Variadic inputs accept a list of values from many edges.
    public var isVariadic: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        dataType: FlowValueType,
        direction: FlowPortDirection,
        isVariadic: Bool = false
    ) {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.direction = direction
        self.isVariadic = isVariadic
    }
}

/// Structured predicate tree for conditions and loop tests. It is data only;
/// the future runtime evaluates it. Operands reference variables, node
/// outputs, or literals — never free-form code strings here.
public enum FlowPredicate: Codable, Hashable, Sendable {
    public enum Comparator: String, Codable, Hashable, Sendable {
        case equal, notEqual, lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual
        case contains, isEmpty, matchesRegex
    }

    case comparison(Comparator, lhs: FlowOperand, rhs: FlowOperand)
    case and([FlowPredicate])
    case or([FlowPredicate])
    indirect case not(FlowPredicate)

    private enum CodingKeys: String, CodingKey { case kind, comparator, lhs, rhs, predicates }
    private enum Kind: String, Codable { case comparison, and, or, not }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .comparison:
            self = .comparison(
                try values.decode(Comparator.self, forKey: .comparator),
                lhs: try values.decode(FlowOperand.self, forKey: .lhs),
                rhs: try values.decode(FlowOperand.self, forKey: .rhs)
            )
        case .and: self = .and(try values.decode([FlowPredicate].self, forKey: .predicates))
        case .or: self = .or(try values.decode([FlowPredicate].self, forKey: .predicates))
        case .not: self = .not(try values.decode(FlowPredicate.self, forKey: .predicates))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .comparison(let comparator, let lhs, let rhs):
            try values.encode(Kind.comparison, forKey: .kind)
            try values.encode(comparator, forKey: .comparator)
            try values.encode(lhs, forKey: .lhs)
            try values.encode(rhs, forKey: .rhs)
        case .and(let predicates):
            try values.encode(Kind.and, forKey: .kind)
            try values.encode(predicates, forKey: .predicates)
        case .or(let predicates):
            try values.encode(Kind.or, forKey: .kind)
            try values.encode(predicates, forKey: .predicates)
        case .not(let predicate):
            try values.encode(Kind.not, forKey: .kind)
            try values.encode(predicate, forKey: .predicates)
        }
    }
}

public enum FlowOperand: Codable, Hashable, Sendable {
    case literal(FlowValue)
    case variable(name: String)
    case nodeOutput(nodeID: UUID, portName: String)
}

// MARK: - Custom descriptors

/// Declarative custom-node descriptor. Never carries credentials or grants
/// permissions; execution uses the host's resolved Linux environment and
/// jobs lifecycle at runtime.
public struct FlowScriptDescriptor: Codable, Hashable, Sendable {
    public var language: String
    /// Hash of the script source for identity/dedup, not the source itself.
    public var sourceHash: String
    public var entryPoint: String?
    /// Declared input/output names with types.
    public var signature: [FlowPort]

    public init(
        language: String,
        sourceHash: String,
        entryPoint: String? = nil,
        signature: [FlowPort] = []
    ) {
        self.language = language
        self.sourceHash = sourceHash
        self.entryPoint = entryPoint
        self.signature = signature
    }
}

public struct FlowAPIDescriptor: Codable, Hashable, Sendable {
    public var endpoint: URL
    public var method: String
    /// Header NAMES the node expects the runtime to fill from approved
    /// credential storage; values never appear here.
    public var credentialHeaderNames: [String]
    public var requestTemplate: JSONValue?

    public init(
        endpoint: URL,
        method: String = "POST",
        credentialHeaderNames: [String] = [],
        requestTemplate: JSONValue? = nil
    ) {
        self.endpoint = endpoint
        self.method = method
        self.credentialHeaderNames = credentialHeaderNames
        self.requestTemplate = requestTemplate
    }
}

/// A reusable, versioned group template saved from a selection.
public struct FlowGroupDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var version: Int
    public var name: String
    /// Exposed parameters of the template instance.
    public var exposedPorts: [FlowPort]

    public init(
        id: UUID = UUID(),
        version: Int = 1,
        name: String,
        exposedPorts: [FlowPort] = []
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.exposedPorts = exposedPorts
    }
}

// MARK: - Graph

public enum FlowNodeKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Produces host content (asset, source fragment, literal).
    case source
    /// Transforms inputs into outputs.
    case transform
    /// Structured branch with `branches` predicates.
    case condition
    /// Structured iteration. Body wiring lives in the main graph; the loop
    /// node declares which node IDs form its body scope.
    case loop
    /// Fans one input out over a list; one run per element.
    case batch
    /// References a `FlowGroupDescriptor` instance.
    case subgraph
    /// Host-resolved script execution.
    case customScript
    /// Host-resolved API call.
    case customAPI
    /// Terminal consumer (e.g. canvas node materialization).
    case output
}

public struct FlowConditionBranch: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var predicate: FlowPredicate
    /// Output port taken when the predicate holds.
    public var outputPortID: UUID

    public init(id: UUID = UUID(), predicate: FlowPredicate, outputPortID: UUID) {
        self.id = id
        self.predicate = predicate
        self.outputPortID = outputPortID
    }
}

public struct FlowNode: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: FlowNodeKind
    public var name: String
    public var ports: [FlowPort]
    public var parameters: [String: JSONValue]
    /// Condition branches, ordered by priority.
    public var branches: [FlowConditionBranch]?
    /// Loop body scope: node IDs iterated by this loop node.
    public var bodyNodeIDs: [UUID]?
    /// For `.subgraph`, the template instance being referenced.
    public var subgraphTemplateID: UUID?
    public var script: FlowScriptDescriptor?
    public var api: FlowAPIDescriptor?
    /// Group template this node instantiates (`.subgraph`).
    public var group: FlowGroupDescriptor?
    public var position: CanvasGeometry.Point

    public init(
        id: UUID = UUID(),
        kind: FlowNodeKind,
        name: String,
        ports: [FlowPort] = [],
        parameters: [String: JSONValue] = [:],
        branches: [FlowConditionBranch]? = nil,
        bodyNodeIDs: [UUID]? = nil,
        subgraphTemplateID: UUID? = nil,
        script: FlowScriptDescriptor? = nil,
        api: FlowAPIDescriptor? = nil,
        group: FlowGroupDescriptor? = nil,
        position: CanvasGeometry.Point = .zero
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.ports = ports
        self.parameters = parameters
        self.branches = branches
        self.bodyNodeIDs = bodyNodeIDs
        self.subgraphTemplateID = subgraphTemplateID
        self.script = script
        self.api = api
        self.group = group
        self.position = position
    }
}

/// An executable data edge between typed ports. Distinct from
/// `CanvasConnectionSnapshot`, which is a visual/semantic relation.
public struct FlowEdge: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceNodeID: UUID
    public var sourcePortID: UUID
    public var destinationNodeID: UUID
    public var destinationPortID: UUID

    public init(
        id: UUID = UUID(),
        sourceNodeID: UUID,
        sourcePortID: UUID,
        destinationNodeID: UUID,
        destinationPortID: UUID
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.sourcePortID = sourcePortID
        self.destinationNodeID = destinationNodeID
        self.destinationPortID = destinationPortID
    }
}

/// A variable visible inside one node's scope subtree. Resolution walks
/// from the innermost owner outward, so inner scopes shadow outer ones.
public struct FlowVariable: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var dataType: FlowValueType
    public var ownerNodeID: UUID
    public var initial: FlowValue?

    public init(
        id: UUID = UUID(),
        name: String,
        dataType: FlowValueType,
        ownerNodeID: UUID,
        initial: FlowValue? = nil
    ) {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.ownerNodeID = ownerNodeID
        self.initial = initial
    }
}

public struct FlowGraph: Codable, Hashable, Sendable, Identifiable {
    public static let defaultMaxLoopIterations = 100

    public var id: UUID
    public var revision: Int64
    public var nodes: [FlowNode]
    public var edges: [FlowEdge]
    public var variables: [FlowVariable]

    public init(
        id: UUID = UUID(),
        revision: Int64 = 0,
        nodes: [FlowNode] = [],
        edges: [FlowEdge] = [],
        variables: [FlowVariable] = []
    ) {
        self.id = id
        self.revision = revision
        self.nodes = nodes
        self.edges = edges
        self.variables = variables
    }
}

// MARK: - Run identity and records

/// Immutable identity of one run, bound to the exact document revision,
/// graph revision and environment it started on.
public struct FlowRunIdentity: Codable, Hashable, Sendable {
    public var runID: UUID
    public var canvasID: UUID
    public var canvasRevision: Int64
    public var flowGraphID: UUID
    public var flowGraphRevision: Int64
    /// Explicit host environment; files and templates never imply one.
    public var environmentID: String
    public var owningTaskID: UUID?
    public var startedAt: Date

    public init(
        runID: UUID = UUID(),
        canvasID: UUID,
        canvasRevision: Int64,
        flowGraphID: UUID,
        flowGraphRevision: Int64,
        environmentID: String,
        owningTaskID: UUID? = nil,
        startedAt: Date = Date()
    ) {
        self.runID = runID
        self.canvasID = canvasID
        self.canvasRevision = canvasRevision
        self.flowGraphID = flowGraphID
        self.flowGraphRevision = flowGraphRevision
        self.environmentID = environmentID
        self.owningTaskID = owningTaskID
        self.startedAt = startedAt
    }
}

public enum FlowStepStatus: String, Codable, Hashable, Sendable {
    case queued, running, succeeded, failed, cancelled, skipped
}

public struct FlowStepEvent: Codable, Hashable, Sendable, Identifiable {
    public enum EventKind: String, Codable, Hashable, Sendable {
        case log, breakpoint, cancellation, checkpoint
    }

    public var id: UUID
    public var kind: EventKind
    public var message: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: EventKind,
        message: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
    }
}

/// One executed step of one run: exact inputs, outputs, status and events.
public struct FlowStepRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var runID: UUID
    public var nodeID: UUID
    public var attempt: Int
    public var status: FlowStepStatus
    public var inputs: [String: FlowValue]
    public var outputs: [String: FlowValue]
    public var error: String?
    public var events: [FlowStepEvent]
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        runID: UUID,
        nodeID: UUID,
        attempt: Int = 1,
        status: FlowStepStatus = .queued,
        inputs: [String: FlowValue] = [:],
        outputs: [String: FlowValue] = [:],
        error: String? = nil,
        events: [FlowStepEvent] = [],
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.nodeID = nodeID
        self.attempt = attempt
        self.status = status
        self.inputs = inputs
        self.outputs = outputs
        self.error = error
        self.events = events
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// Resumable snapshot of a paused/interrupted run.
public struct FlowRunCheckpoint: Codable, Hashable, Sendable {
    public var runID: UUID
    public var completedStepIDs: [UUID]
    /// Current iteration count per loop node.
    public var loopCounters: [UUID: Int]
    public var capturedAt: Date

    public init(
        runID: UUID,
        completedStepIDs: [UUID] = [],
        loopCounters: [UUID: Int] = [:],
        capturedAt: Date = Date()
    ) {
        self.runID = runID
        self.completedStepIDs = completedStepIDs
        self.loopCounters = loopCounters
        self.capturedAt = capturedAt
    }
}

// MARK: - Validation

public struct CanvasFlowIssue: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Hashable, Sendable {
        case error, warning
    }

    public enum Code: String, Codable, Hashable, Sendable {
        case duplicateNodeID
        case duplicatePortID
        case danglingEdge
        case portDirectionMismatch
        case portTypeMismatch
        /// A cycle exists that is not owned by a structured loop node.
        case freeCycle
        /// A loop node's body contains a node not present in the graph, or
        /// its iteration bound is outside the configured cap.
        case invalidLoop
        case branchOutputPortMissing
    }

    public var severity: Severity
    public var code: Code
    public var nodeID: UUID?
    public var edgeID: UUID?
    public var detail: String?

    public init(
        severity: Severity,
        code: Code,
        nodeID: UUID? = nil,
        edgeID: UUID? = nil,
        detail: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.nodeID = nodeID
        self.edgeID = edgeID
        self.detail = detail
    }
}

/// Structural validator for the data contracts. The outer graph must be a
/// DAG; iteration is only legal through structured `.loop` nodes whose
/// body is declared explicitly. `maxLoopIterations` caps every loop's
/// declared bound (default 100).
public enum FlowGraphValidator {
    public static func validate(
        _ graph: FlowGraph,
        maxLoopIterations: Int = FlowGraph.defaultMaxLoopIterations
    ) -> [CanvasFlowIssue] {
        var issues: [CanvasFlowIssue] = []
        var nodeByID: [UUID: FlowNode] = [:]
        // All node IDs up front: loop bodies reference nodes by ID
        // regardless of declaration order (a body node listed AFTER its
        // loop node is still a valid body member).
        let allNodeIDs = Set(graph.nodes.map(\.id))
        for node in graph.nodes {
            if nodeByID[node.id] != nil {
                issues.append(.init(
                    severity: .error, code: .duplicateNodeID, nodeID: node.id))
            }
            nodeByID[node.id] = node
            var portIDs = Set<UUID>()
            for port in node.ports where !portIDs.insert(port.id).inserted {
                issues.append(.init(
                    severity: .error, code: .duplicatePortID, nodeID: node.id))
            }
            if node.kind == .condition {
                let outputPorts = Set(node.ports
                    .filter { $0.direction == .output }
                    .map(\.id))
                for branch in node.branches ?? []
                where !outputPorts.contains(branch.outputPortID) {
                    issues.append(.init(
                        severity: .error,
                        code: .branchOutputPortMissing,
                        nodeID: node.id,
                        detail: "branch \(branch.id) targets unknown port"))
                }
            }
            if node.kind == .loop {
                let body = Set(node.bodyNodeIDs ?? [])
                let unknown = body.subtracting(allNodeIDs)
                if !unknown.isEmpty {
                    issues.append(.init(
                        severity: .error, code: .invalidLoop, nodeID: node.id,
                        detail: "body references missing nodes: \(unknown.count)"))
                }
                let bound = loopBound(of: node)
                if bound < 1 || bound > maxLoopIterations {
                    issues.append(.init(
                        severity: .error, code: .invalidLoop, nodeID: node.id,
                        detail: "loop bound \(bound) outside 1...\(maxLoopIterations)"))
                }
            }
        }

        // Edge endpoint checks.
        for edge in graph.edges {
            guard let source = nodeByID[edge.sourceNodeID],
                  let destination = nodeByID[edge.destinationNodeID] else {
                issues.append(.init(
                    severity: .error, code: .danglingEdge, edgeID: edge.id))
                continue
            }
            guard let sourcePort = source.ports.first(where: { $0.id == edge.sourcePortID }),
                  let destinationPort = destination.ports.first(where: {
                      $0.id == edge.destinationPortID
                  }) else {
                issues.append(.init(
                    severity: .error, code: .danglingEdge, edgeID: edge.id,
                    detail: "unknown port"))
                continue
            }
            if sourcePort.direction != .output || destinationPort.direction != .input {
                issues.append(.init(
                    severity: .error, code: .portDirectionMismatch, edgeID: edge.id))
            }
            if sourcePort.dataType != destinationPort.dataType
                && sourcePort.dataType != .json && destinationPort.dataType != .json
                && !sourcePort.isVariadic && !destinationPort.isVariadic {
                issues.append(.init(
                    severity: .error, code: .portTypeMismatch, edgeID: edge.id,
                    detail: "\(sourcePort.dataType.rawValue) → \(destinationPort.dataType.rawValue)"))
            }
        }

        // Outer DAG: Kahn topological pass. Loop bodies are validated as
        // internal scopes but back-edges inside a declared loop body are
        // allowed to point at the loop node itself; any other surviving
        // cycle is a free cycle.
        var adjacency: [UUID: [UUID]] = [:]
        var indegree: [UUID: Int] = [:]
        for node in graph.nodes { indegree[node.id] = 0 }
        for edge in graph.edges {
            adjacency[edge.sourceNodeID, default: []].append(edge.destinationNodeID)
            indegree[edge.destinationNodeID, default: 0] += 1
        }
        var queue = graph.nodes.filter { indegree[$0.id] == 0 }.map(\.id)
        var processed = Set<UUID>()
        var cursor = 0
        var mutableIndegree = indegree
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            processed.insert(current)
            for next in adjacency[current] ?? [] {
                mutableIndegree[next, default: 0] -= 1
                if mutableIndegree[next] == 0 { queue.append(next) }
            }
        }
        if processed.count < graph.nodes.count {
            let remaining = Set(graph.nodes.map(\.id)).subtracting(processed)
            let loopNodeIDs = Set(graph.nodes
                .filter { $0.kind == .loop }
                .map(\.id))
            // Nodes inside a declared loop body may carry iteration wiring;
            // any other remaining node is part of a free cycle.
            let loopBodyIDs = loopNodeIDs.union(graph.nodes
                .filter { $0.kind == .loop }
                .flatMap { $0.bodyNodeIDs ?? [] })
            let freeCycleNodes = remaining.subtracting(loopBodyIDs)
            if !freeCycleNodes.isEmpty {
                issues.append(.init(
                    severity: .error, code: .freeCycle,
                    detail: "nodes: \(freeCycleNodes.map(\.uuidString).sorted().joined(separator: ","))"))
            }
        }
        return issues
    }

    /// The declared iteration bound of a loop node; defaults to 100 when
    /// the parameter is absent, matching `FlowGraph.defaultMaxLoopIterations`.
    public static func loopBound(of node: FlowNode) -> Int {
        guard node.kind == .loop,
              let literal = node.parameters["maxIterations"]?.numberLiteral,
              let value = Int64(literal) else {
            return FlowGraph.defaultMaxLoopIterations
        }
        return Int(value)
    }
}
