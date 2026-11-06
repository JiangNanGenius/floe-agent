import Foundation
import FloeCanvasCore
import FloeCanvasIntegration

// MARK: - Revision keys
//
// A revision key binds a run to its configuration, graph and inputs. The
// whole-graph digest proves recovery identity, but INVALIDATION decisions
// never use it alone: they compare per-node execution signatures and
// per-input digests, then invalidate only the changed nodes and their
// downstream closure. Display-only edits (moving a node, renaming it when
// an explicit nativeKey exists) and edits on unrelated branches reuse the
// previous paid results.

public struct FlowRevisionKey: Hashable, Sendable, Codable {
    public var graphRevision: Int64
    public var graphDigest: String
    public var configurationDigest: String
    /// Digests of declared run inputs, keyed "nodeID.portName".
    public var inputDigests: [String: String]
    /// Host-trusted source digests per source node. These come from the
    /// host's own resolution, never from a card's self-declared revision —
    /// a card cannot grant freshness by claiming one.
    public var sourceDigests: [UUID: String]

    public init(
        graphRevision: Int64,
        graphDigest: String,
        configurationDigest: String,
        inputDigests: [String: String],
        sourceDigests: [UUID: String]
    ) {
        self.graphRevision = graphRevision
        self.graphDigest = graphDigest
        self.configurationDigest = configurationDigest
        self.inputDigests = inputDigests
        self.sourceDigests = sourceDigests
    }
}

public enum FlowRunTerminalStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

public struct FlowRunResult: Sendable {
    public var identity: FlowRunIdentity
    public var revisionKey: FlowRevisionKey
    public var terminalStatus: FlowRunTerminalStatus
    public var records: [FlowStepRecord]
    public var runOutputs: [String: FlowValue]
    public var nodeOutputs: [UUID: [String: FlowValue]]
    /// Debug/trace aid: node → lexical call path within the run.
    public var callPaths: [UUID: String]
    /// True when the host reports the document has moved past the revision
    /// this run bound to; such outputs must be reported stale/unapplied,
    /// never written over a newer revision.
    public var stale: Bool

    public init(
        identity: FlowRunIdentity,
        revisionKey: FlowRevisionKey,
        terminalStatus: FlowRunTerminalStatus,
        records: [FlowStepRecord],
        runOutputs: [String: FlowValue],
        nodeOutputs: [UUID: [String: FlowValue]],
        callPaths: [UUID: String],
        stale: Bool
    ) {
        self.identity = identity
        self.revisionKey = revisionKey
        self.terminalStatus = terminalStatus
        self.records = records
        self.runOutputs = runOutputs
        self.nodeOutputs = nodeOutputs
        self.callPaths = callPaths
        self.stale = stale
    }

    public func isStale(currentCanvasRevision: Int64) -> Bool {
        currentCanvasRevision != identity.canvasRevision
    }
}

/// Reused state for a rerun-style run: the new run explicitly adopts the
/// previous run's valid results; only invalidated nodes (and explicitly
/// retried ones) generate new attempts.
public struct FlowRunSeed: Sendable {
    public var revisionKey: FlowRevisionKey
    public var reusedRecords: [FlowStepRecord]
    public var reusedOutputs: [UUID: [String: FlowValue]]

    public init(
        revisionKey: FlowRevisionKey,
        reusedRecords: [FlowStepRecord],
        reusedOutputs: [UUID: [String: FlowValue]]
    ) {
        self.revisionKey = revisionKey
        self.reusedRecords = reusedRecords
        self.reusedOutputs = reusedOutputs
    }
}

// MARK: - Per-node execution signatures

/// Semantic signature of one node's execution. Two runs may reuse a step
/// result only when the node's signature, its bound inputs and (for source
/// nodes) the host-trusted source digest are all unchanged.
///
/// Included: kind, effective native key (`parameters.nativeKey`, falling
/// back to the node name — the name is execution semantics ONLY when no
/// explicit nativeKey exists), ports (name/type/direction/variadic),
/// parameters, branch predicates, script/API descriptors, subgraph template
/// id/version, body membership and variable-write mappings.
///
/// Excluded: node `position` (pure display) and the display `name` when an
/// explicit `nativeKey` is present.
public enum FlowNodeSignatures {
    public static func signature(of node: FlowNode) throws -> String {
        var object: [String: JSONValue] = [:]
        object["kind"] = .string(node.kind.rawValue)
        // The display name is execution semantics ONLY for transforms that
        // resolve their handler by name (no explicit nativeKey); every
        // other kind ignores it, so renames there never invalidate.
        if node.kind == .transform {
            object["effectiveKey"] = .string(
                node.parameters["nativeKey"]?.flowString ?? node.name)
        }
        object["ports"] = .array(node.ports
            .sorted { $0.name < $1.name }
            .map { port in
                .object([
                    "name": .string(port.name),
                    "type": .string(port.dataType.rawValue),
                    "direction": .string(port.direction.rawValue),
                    "variadic": .bool(port.isVariadic),
                ])
            })
        object["parameters"] = .object(node.parameters)
        if let branches = node.branches {
            let encoded = try branches.map { branch in
                try FlowLiterals.encodeToJSON(branch)
            }
            object["branches"] = .array(encoded.sorted {
                FlowLiterals.describe($0) < FlowLiterals.describe($1)
            })
        }
        if let body = node.bodyNodeIDs {
            object["body"] = .array(body
                .sorted { $0.uuidString < $1.uuidString }
                .map { .string($0.uuidString) })
        }
        if let script = node.script {
            object["script"] = .object([
                "language": .string(script.language),
                "sourceHash": .string(script.sourceHash),
                "entryPoint": script.entryPoint.map(JSONValue.string) ?? .null,
                "signature": .array(script.signature.map { port in
                    .object([
                        "name": .string(port.name),
                        "type": .string(port.dataType.rawValue),
                        "direction": .string(port.direction.rawValue),
                    ])
                }),
            ])
        }
        if let api = node.api {
            object["api"] = .object([
                "endpoint": .string(api.endpoint.absoluteString),
                "method": .string(api.method),
                "credentialHeaders": .array(api.credentialHeaderNames.sorted().map(JSONValue.string)),
                "template": api.requestTemplate ?? .null,
            ])
        }
        if let templateID = node.subgraphTemplateID {
            object["subgraphTemplate"] = .string(templateID.uuidString)
        }
        if let group = node.group {
            object["group"] = .object([
                "id": .string(group.id.uuidString),
                "version": .number("\(group.version)"),
            ])
        }
        let json = JSONValue.object(object)
        let data = try JSONFidelity.serialize(json)
        return FlowDigest.hex(data)
    }
}

// MARK: - Rerun planning

public struct FlowRerunPlan: Sendable {
    /// Nodes whose results may be adopted from the previous run.
    public var reusableNodeIDs: Set<UUID>
    /// Nodes that must execute in the new run (changed + downstream).
    public var invalidatedNodeIDs: Set<UUID>
    /// Root causes: nodes whose signature/inputs/source changed.
    public var changedNodeIDs: Set<UUID>
    public var revisionKey: FlowRevisionKey
    public var seed: FlowRunSeed
}

public enum FlowRerunPlanner {
    /// Compute the partial-rerun plan between a previous completed/failed
    /// run and an edited graph. Old runs are never mutated; the new run
    /// adopts valid results explicitly via the returned seed.
    public static func plan(
        previous: FlowRunResult,
        previousGraph: FlowGraph,
        editedGraph: FlowGraph,
        editedCompiled: CompiledFlow,
        configuration: FlowRunConfiguration
    ) throws -> FlowRerunPlan {
        // First definition wins; a malformed graph with duplicate node IDs
        // must not trap the planner.
        var previousNodes: [UUID: FlowNode] = [:]
        for node in previousGraph.nodes {
            if previousNodes[node.id] == nil { previousNodes[node.id] = node }
        }
        var changed: Set<UUID> = []

        for node in editedGraph.nodes {
            guard let old = previousNodes[node.id] else {
                changed.insert(node.id) // new node must run
                continue
            }
            if try FlowNodeSignatures.signature(of: old)
                != FlowNodeSignatures.signature(of: node) {
                changed.insert(node.id)
            }
        }
        // Nodes removed from the graph simply drop out of the new run.

        // Environmental roots: declared run inputs and host-trusted source
        // digests that changed invalidate the nodes they bind directly.
        let previousInputs = previous.revisionKey.inputDigests
        let newKey = try configuration.revisionKey(graphDigest: editedCompiled.graphDigest)
        for (binding, digest) in newKey.inputDigests
        where previousInputs[binding] != digest {
            let nodeIDString = binding.components(separatedBy: ".").first ?? ""
            if let nodeID = UUID(uuidString: nodeIDString) {
                changed.insert(nodeID)
            }
        }
        for (nodeID, digest) in newKey.sourceDigests
        where previous.revisionKey.sourceDigests[nodeID] != digest {
            changed.insert(nodeID)
        }
        // Configuration digest changes (model selection, parameters) are
        // conservative: they invalidate every node that ran external work.
        if previous.revisionKey.configurationDigest != newKey.configurationDigest {
            for node in editedGraph.nodes
            where node.kind == .customScript || node.kind == .customAPI
                || (node.kind == .transform && node.parameters["nativeKey"] == nil) {
                // Native-keyed transforms are pure and config-independent;
                // name-fallback transforms follow the external rule above.
                if node.kind == .transform && node.parameters["nativeKey"] != nil {
                    continue
                }
                changed.insert(node.id)
            }
        }

        // Downstream closure over the EDITED graph's contracted adjacency.
        let invalidated = downstreamClosure(of: changed, in: editedCompiled)
        let previousOutputs = previous.nodeOutputs
        var reusable: Set<UUID> = []
        var reusedRecords: [FlowStepRecord] = []
        var reusedOutputs: [UUID: [String: FlowValue]] = [:]
        for node in editedGraph.nodes {
            let id = node.id
            guard !invalidated.contains(id), previousNodes[id] != nil else { continue }
            guard let outputs = previousOutputs[id],
                  let record = previous.records
                    .filter({ $0.nodeID == id && $0.status == .succeeded })
                    .sorted(by: { ($0.finishedAt ?? Date.distantPast)
                        < ($1.finishedAt ?? Date.distantPast) })
                    .last else { continue }
            reusable.insert(id)
            reusedRecords.append(record)
            reusedOutputs[id] = outputs
        }

        let seed = FlowRunSeed(
            revisionKey: newKey,
            reusedRecords: reusedRecords,
            reusedOutputs: reusedOutputs)
        return FlowRerunPlan(
            reusableNodeIDs: reusable,
            invalidatedNodeIDs: invalidated,
            changedNodeIDs: changed,
            revisionKey: newKey,
            seed: seed)
    }

    static func downstreamClosure(
        of roots: Set<UUID>,
        in compiled: CompiledFlow
    ) -> Set<UUID> {
        // Rebuild the contracted adjacency the same way the compiler does.
        var ownership: [UUID: UUID] = [:]
        for (loopID, loop) in compiled.loops {
            for bodyID in loop.bodyOrder { ownership[bodyID] = loopID }
        }
        for (batchID, batch) in compiled.batches {
            for bodyID in batch.bodyOrder { ownership[bodyID] = batchID }
        }
        func outermost(_ id: UUID) -> UUID {
            var current = id
            var guardCount = 0
            while let owner = ownership[current], guardCount < compiled.nodes.count {
                current = owner
                guardCount += 1
            }
            return current
        }
        var adjacency: [UUID: [UUID]] = [:]
        var seen = Set<String>()
        for (destination, edges) in compiled.incomingEdges {
            for edge in edges {
                let source = outermost(edge.sourceNodeID)
                let dest = outermost(destination)
                guard source != dest else { continue }
                let key = source.uuidString + "→" + dest.uuidString
                if seen.insert(key).inserted {
                    adjacency[source, default: []].append(dest)
                }
            }
        }
        var closure = roots
        var queue = Array(roots)
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for next in adjacency[current] ?? [] {
                if closure.insert(next).inserted {
                    queue.append(next)
                }
            }
        }
        return closure
    }
}
