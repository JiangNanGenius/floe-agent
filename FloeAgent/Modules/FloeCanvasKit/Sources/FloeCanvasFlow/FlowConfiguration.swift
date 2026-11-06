import Foundation
import FloeCanvasCore
import FloeCanvasIntegration

// MARK: - Run configuration
//
// One run is bound to an immutable identity (document revision, graph
// revision, environment, owning task), the digests of the definitions it
// was compiled from, and its declared inputs. A restarted runtime compares
// every one of these before adopting prior work.

public struct FlowRunInput: Hashable, Sendable, Codable {
    public var nodeID: UUID
    public var portName: String
    public var value: FlowValue

    public init(nodeID: UUID, portName: String, value: FlowValue) {
        self.nodeID = nodeID
        self.portName = portName
        self.value = value
    }
}

public struct FlowRunConfiguration: Codable, Sendable {
    public var identity: FlowRunIdentity
    /// Page that hosts the flow canvas (defaults to the canvas identity
    /// when the host does not track pages for flows).
    public var pageID: UUID?
    /// Values for input ports that have no in-scope edge
    /// (`CompiledFlow.requiredInputs`).
    public var runInputs: [FlowRunInput]
    /// Digest per source node (`sourceKind == "canvasBinding"`). A changed
    /// source digest marks runs that consumed it for invalidation.
    public var sourceDigests: [UUID: String]
    /// Host-computed digest of the effective run configuration (provider
    /// selection, model parameters, resolved environment record, …).
    public var configurationDigest: String
    /// Upper bound applied to every loop in this run.
    public var maxLoopIterations: Int
    /// Maximum concurrently in-flight steps inside one run.
    public var maxConcurrency: Int
    /// Per-subscriber event buffer capacity.
    public var eventBufferCapacity: Int
    /// Persist a checkpoint after every N completed steps (0 = off).
    public var checkpointEverySteps: Int

    public init(
        identity: FlowRunIdentity,
        pageID: UUID? = nil,
        runInputs: [FlowRunInput] = [],
        sourceDigests: [UUID: String] = [:],
        configurationDigest: String,
        maxLoopIterations: Int = FlowGraph.defaultMaxLoopIterations,
        maxConcurrency: Int = 4,
        eventBufferCapacity: Int = 256,
        checkpointEverySteps: Int = 25
    ) {
        self.identity = identity
        self.pageID = pageID
        self.runInputs = runInputs
        self.sourceDigests = sourceDigests
        self.configurationDigest = configurationDigest
        self.maxLoopIterations = maxLoopIterations
        self.maxConcurrency = maxConcurrency
        self.eventBufferCapacity = eventBufferCapacity
        self.checkpointEverySteps = checkpointEverySteps
    }

    /// The revision key binds a run to configuration + graph + inputs +
    /// sources. Any change produces a different key, which is what the
    /// invalidation engine compares.
    public func revisionKey(graphDigest: String) throws -> FlowRevisionKey {
        var inputDigests: [String: String] = [:]
        for input in runInputs {
            let digest = try FlowDigest.of(input.value)
            inputDigests["\(input.nodeID.uuidString).\(input.portName)"] = digest
        }
        var sources: [UUID: String] = [:]
        for (nodeID, digest) in sourceDigests { sources[nodeID] = digest }
        return FlowRevisionKey(
            graphRevision: identity.flowGraphRevision,
            graphDigest: graphDigest,
            configurationDigest: configurationDigest,
            inputDigests: inputDigests,
            sourceDigests: sources)
    }
}

// MARK: - Native step registry
//
// Pure deterministic native transforms run in-process for qualification and
// for genuinely local work (arithmetic, text, formatting). External model,
// script and API work NEVER runs here — it goes exclusively through the
// injected `CanvasStepExecutor`. The registry key of a node is
// `parameters["nativeKey"]`, falling back to the node name.

public struct FlowNativeStepContext: Sendable {
    public var node: FlowNode
    public var inputs: [String: FlowValue]
    /// Iteration-visible variables (`item`, `itemIndex`, `iteration`,
    /// `carry.*`) as a snapshot for native handlers.
    public var iterationVariables: [String: FlowValue]

    public init(
        node: FlowNode,
        inputs: [String: FlowValue],
        iterationVariables: [String: FlowValue]
    ) {
        self.node = node
        self.inputs = inputs
        self.iterationVariables = iterationVariables
    }

    public func variable(_ name: String) -> FlowValue? { iterationVariables[name] }
}

public typealias FlowNativeStepHandler = @Sendable (FlowNativeStepContext) async throws -> [String: FlowValue]

public struct FlowNativeStepRegistry: Sendable {
    private var handlers: [String: FlowNativeStepHandler]

    public init(handlers: [String: FlowNativeStepHandler] = [:]) {
        self.handlers = handlers
    }

    public mutating func register(_ key: String, handler: @escaping FlowNativeStepHandler) {
        handlers[key] = handler
    }

    public func handler(for key: String) -> FlowNativeStepHandler? {
        handlers[key]
    }

    /// The registry key a node resolves to.
    public func key(for node: FlowNode) -> String {
        node.parameters["nativeKey"]?.flowString ?? node.name
    }
}

// MARK: - Canvas binding resolution (trusted host delegate)

/// Source nodes with `sourceKind == "canvasBinding"` name a binding key
/// that only the host can resolve (a note fragment, an asset, a resolved
/// environment value). The runtime never invents bindings: a missing
/// resolver or an unresolved key yields a true unavailable step result.
public protocol FlowCanvasBindingResolver: Sendable {
    func resolve(canvasBinding name: String, context: CanvasRuntimeContext) async throws -> FlowValue
}

// MARK: - Subgraph templates
//
// The frozen Core `FlowGroupDescriptor` names a template but deliberately
// carries no inner graph. Templates are supplied to the runtime out of
// band: a compiled subgraph node is instantiated against the matching
// template definition below. Template graphs compile recursively under the
// same rules; nested subgraphs are allowed.

/// A reusable, host-registry-defined subgraph template. Explicit `Codable`
/// conformance (synthesized) lets hosts persist template definitions in
/// their own template archives — the frozen canvas snapshot stores only
/// `subgraphTemplateID`, so a document archive alone cannot resurrect a
/// template. Contents are pure definitions: no credentials, no permission
/// grants. Field order and the existing initializer are unchanged; encoding
/// carries the template graph verbatim.
public struct FlowSubgraphTemplate: Sendable, Identifiable, Hashable, Codable {
    public var id: UUID
    public var version: Int
    public var name: String
    /// Template graphs must compile under the same rules; nested
    /// composites (loop/batch/condition/subgraph) are supported and
    /// diagnosed like top-level composites (see FlowRuntimeService).
    public var graph: FlowGraph
    /// Exposed input/output ports of the template (input ports receive the
    /// instance binding, output ports surface the inner results).
    public var exposedPorts: [FlowPort]

    public init(
        id: UUID = UUID(),
        version: Int = 1,
        name: String,
        graph: FlowGraph,
        exposedPorts: [FlowPort] = []
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.graph = graph
        self.exposedPorts = exposedPorts
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(version)
    }

    public static func == (lhs: FlowSubgraphTemplate, rhs: FlowSubgraphTemplate) -> Bool {
        lhs.id == rhs.id && lhs.version == rhs.version
    }
}
