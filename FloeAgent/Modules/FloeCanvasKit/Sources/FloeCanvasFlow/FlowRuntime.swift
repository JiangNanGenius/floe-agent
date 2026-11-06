import Foundation
import FloeCanvasCore
import FloeCanvasIntegration

// MARK: - Run-level event history (bounded, coalescing ring)

/// Retained per-run event history: late subscribers replay it before live
/// events. Bounded with in-place coalescing; a terminal event is always
/// kept (oldest non-terminal entries are evicted first).
struct FlowEventHistory: Sendable {
    private(set) var events: [FlowRuntimeEvent] = []
    private var coalesceIndexes: [String: Int] = [:]
    var capacity: Int = 512

    mutating func append(_ event: FlowRuntimeEvent) {
        if let key = event.coalesceKey, let index = coalesceIndexes[key] {
            events[index] = event
            return
        }
        events.append(event)
        if let key = event.coalesceKey {
            coalesceIndexes[key] = events.count - 1
        }
        while events.count > capacity {
            if events.count > 1, let first = events.first, isTerminal(first) {
                events.remove(at: 1)
            } else {
                events.removeFirst()
            }
            rebuildIndexes()
        }
    }

    private func isTerminal(_ event: FlowRuntimeEvent) -> Bool {
        if case .runFinished = event { return true }
        return false
    }

    private mutating func rebuildIndexes() {
        coalesceIndexes.removeAll()
        for (index, event) in events.enumerated() {
            if let key = event.coalesceKey {
                coalesceIndexes[key] = index
            }
        }
    }
}

// MARK: - Run state

struct FlowRunState: Sendable {
    enum UnitStatus: Sendable {
        case pending
        case running
        case succeeded(outputs: [String: FlowValue])
        case failed(error: String)
        case skipped(reason: String)

        var isTerminal: Bool {
            switch self {
            case .succeeded, .failed, .skipped: return true
            case .pending, .running: return false
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    struct InFlightStep: Sendable {
        var attemptID: UUID
        var nodeKey: String
        var generation: Int
        var continuation: CheckedContinuation<CanvasStepQueryResult, Never>?
    }

    var compiled: CompiledFlow
    var configuration: FlowRunConfiguration
    var revisionKey: FlowRevisionKey
    var phase: FlowRunPhase = .running
    var generation: Int = 0
    var frames: [FlowVariableFrame] = []
    var unitStatus: [String: UnitStatus] = [:] // key: "\(callPath)#\(nodeID)"
    var conditionChoices: [String: UUID] = [:]
    var stepRecords: [FlowStepRecord] = []
    var attempts: [UUID: FlowAttemptRecord] = [:]
    var pendingAttempts: Set<UUID> = []
    var inFlight: [UUID: InFlightStep] = [:]
    var breakpoints: Set<UUID> = []
    var pausedBreakpoint: UUID?
    var breakpointSkipOnce: Set<UUID> = []
    var bypassed: Set<UUID> = []
    var loopCounters: [String: Int] = [:]
    var batchProgress: [String: FlowBatchProgressSnapshot] = [:]
    var runOutputs: [String: FlowValue] = [:]
    var completedStepCount: Int = 0
    var stepBudget: Int?
    var history = FlowEventHistory()
    var lateDeliveries: [FlowAttemptRecord] = []
    var failureCount: Int = 0
    var runFailure: String?
    /// Honest record of the first durable-checkpoint write failure. Once set,
    /// the run never schedules new work again (a non-terminal run fails);
    /// already-submitted attempts remain durable for reconcile/adoption.
    var checkpointFailure: String?
    var pumping = false
    var definitionsDigest: String = ""

    func key(callPath: String, nodeID: UUID) -> String {
        "\(callPath)#\(nodeID.uuidString)"
    }

    var graphVariables: [FlowVariable] {
        compiled.variables.runLevel + compiled.variables.byOwner.values.flatMap { $0 }
    }
}

// MARK: - Runtime service

/// Service-owned Flow runtime. All state is actor-isolated; runs survive
/// observer teardown and process restart (via the durable journal). The
/// runtime never executes host code itself: external work goes exclusively
/// through the injected `CanvasStepExecutor`, canvas bindings through the
/// trusted `FlowCanvasBindingResolver`.
///
/// Execution model (deterministic qualification semantics): the scheduler
/// walks the compiled topological order and executes units inline; an
/// external step suspends its unit until the host reports completion
/// (immediate terminal results continue synchronously). Pause stops
/// scheduling at unit boundaries — it never claims to freeze remote
/// inference. A composite (loop/batch/subgraph) that is paused, cancelled
/// or interrupted by an unconfirmed submission resets to pending and
/// re-executes from a deterministic point; attempt IDs are reproducible,
/// so the host-side `(runID, attemptID)` dedupe prevents duplicate paid
/// work across re-executions and restarts.
public actor FlowRuntimeService {
    public nonisolated let nativeRegistry: FlowNativeStepRegistry

    private let executor: (any CanvasStepExecutor)?
    private let journal: FlowRunJournal?
    private let bindingResolver: (any FlowCanvasBindingResolver)?
    /// Registry of reusable template definitions. Mutable so a journal
    /// resume can adopt the FROZEN definitions persisted with the run
    /// (the canvas snapshot stores only template IDs; resume must never
    /// reinterpret whatever templates the host currently holds).
    private var subgraphTemplates: [UUID: FlowSubgraphTemplate]
    /// Template IDs that were declared more than once in the initial
    /// registry. Never traps (`Dictionary(uniqueKeysWithValues:)` would);
    /// diagnosed at run start instead.
    private var duplicateTemplateIDs: Set<UUID> = []
    /// Template compilations, keyed by template + loop bound so runs with
    /// different `maxLoopIterations` never share a stale body analysis.
    private var compiledSubgraphs: [String: CompiledFlow] = [:]
    private var runs: [UUID: FlowRunState] = [:]
    private var eventStreams: [UUID: [ObjectIdentifier: FlowEventStream]] = [:]
    /// Debug intent registered before a run starts (breakpoints/bypass by
    /// node ID); seeded into the run state at startRun.
    private var prestartBreakpoints: [UUID: Set<UUID>] = [:]
    private var prestartBypassed: [UUID: Set<UUID>] = [:]

    public init(
        executor: (any CanvasStepExecutor)?,
        journal: FlowRunJournal? = nil,
        nativeRegistry: FlowNativeStepRegistry = FlowNativeStepRegistry(),
        bindingResolver: (any FlowCanvasBindingResolver)? = nil,
        subgraphTemplates: [FlowSubgraphTemplate] = []
    ) {
        self.executor = executor
        self.journal = journal
        self.nativeRegistry = nativeRegistry
        self.bindingResolver = bindingResolver
        // First definition wins; duplicates are recorded and diagnosed at
        // startRun (a valid entry) instead of trapping here.
        var registry: [UUID: FlowSubgraphTemplate] = [:]
        var duplicates: Set<UUID> = []
        for template in subgraphTemplates {
            if registry[template.id] != nil {
                duplicates.insert(template.id)
            } else {
                registry[template.id] = template
            }
        }
        self.subgraphTemplates = registry
        self.duplicateTemplateIDs = duplicates
    }

    // MARK: Compilation

    public func compile(
        _ graph: FlowGraph,
        scope: FlowScopeSelection = .wholeGraph,
        maxLoopIterations: Int = FlowGraph.defaultMaxLoopIterations
    ) throws -> CompiledFlow {
        try FlowGraphCompiler.compile(graph, scope: scope, maxLoopIterations: maxLoopIterations)
    }

    // MARK: Template registry

    /// Template identity a subgraph node references (explicit reference or
    /// group-descriptor fallback).
    private func referencedTemplateID(of node: FlowNode) -> UUID? {
        node.subgraphTemplateID ?? node.group?.id
    }

    /// Compile (or reuse) a template graph under the given loop bound. The
    /// bound is part of the cache key so runs with different host caps never
    /// share a stale body analysis.
    private func compiledTemplate(
        _ template: FlowSubgraphTemplate,
        maxLoopIterations: Int
    ) throws -> CompiledFlow {
        let key = "\(template.id.uuidString)|\(maxLoopIterations)"
        if let cached = compiledSubgraphs[key] { return cached }
        let compiled = try FlowGraphCompiler.compile(
            template.graph, maxLoopIterations: maxLoopIterations)
        compiledSubgraphs[key] = compiled
        return compiled
    }

    /// Validate the template closure reachable from a run graph BEFORE any
    /// attempt can be submitted:
    /// - every reachable template compiles under the same strict rules as
    ///   the run graph (diagnostics name the template);
    /// - duplicate template declarations are rejected (ambiguous reference)
    ///   instead of trapping;
    /// - the template reference graph must be acyclic — explicit recursion
    ///   is diagnosed with its reference path (iterative DFS, no unbounded
    ///   stack).
    private func validateTemplateClosure(
        of graph: FlowGraph,
        maxLoopIterations: Int
    ) throws {
        func enter(_ templateID: UUID) throws {
            if duplicateTemplateIDs.contains(templateID) {
                throw FlowRuntimeError.invalidRunConfiguration(
                    "subgraph template \(templateID.uuidString) is declared more than once; references are ambiguous")
            }
            guard let template = subgraphTemplates[templateID] else { return }
            do {
                _ = try compiledTemplate(template, maxLoopIterations: maxLoopIterations)
            } catch let error as FlowCompilationError {
                // Re-attribute template compile failures with the template
                // name so hosts can locate the broken definition.
                throw FlowRuntimeError.invalidRunConfiguration(
                    "subgraph template '\(template.name)' (\(templateID.uuidString)) failed to compile: \(error)")
            }
        }
        var referencesByTemplate: [UUID: [UUID]] = [:]
        func references(of templateID: UUID) -> [UUID] {
            if let cached = referencesByTemplate[templateID] { return cached }
            guard let template = subgraphTemplates[templateID] else { return [] }
            let refs = template.graph.nodes.compactMap {
                $0.kind == .subgraph ? referencedTemplateID(of: $0) : nil
            }
            referencesByTemplate[templateID] = refs
            return refs
        }

        enum Color { case visiting, done }
        var color: [UUID: Color] = [:]
        var roots = graph.nodes.compactMap {
            $0.kind == .subgraph ? referencedTemplateID(of: $0) : nil
        }
        roots.sort { $0.uuidString < $1.uuidString }
        for root in roots {
            if color[root] != nil { continue }
            try enter(root)
            var stack: [UUID] = [root]
            var childIndex: [UUID: Int] = [root: 0]
            var path: [UUID] = [root]
            color[root] = .visiting
            while let current = stack.last {
                let refs = references(of: current)
                    .sorted { $0.uuidString < $1.uuidString }
                let index = childIndex[current] ?? 0
                if index < refs.count {
                    childIndex[current] = index + 1
                    let next = refs[index]
                    if color[next] == .visiting {
                        let cyclePath: String
                        if let start = path.firstIndex(of: next) {
                            cyclePath = (path[start...] + [next])
                                .map { $0.uuidString }.joined(separator: " → ")
                        } else {
                            cyclePath = next.uuidString
                        }
                        throw FlowRuntimeError.invalidRunConfiguration(
                            "recursive subgraph template reference: \(cyclePath)")
                    } else if color[next] == nil {
                        try enter(next)
                        color[next] = .visiting
                        path.append(next)
                        stack.append(next)
                        childIndex[next] = 0
                    }
                } else {
                    color[current] = .done
                    path.removeLast()
                    stack.removeLast()
                    childIndex.removeValue(forKey: current)
                }
            }
        }
    }

    // MARK: Events

    /// Observe a run. The stream first replays the retained bounded
    /// history, then live events with `.bufferingNewest` semantics.
    /// Dropping the stream NEVER cancels the run — the runtime is
    /// service-owned.
    public func events(runID: UUID) -> AsyncStream<FlowRuntimeEvent> {
        guard let run = runs[runID] else {
            return AsyncStream { $0.finish() }
        }
        let stream = FlowEventStream(capacity: run.configuration.eventBufferCapacity)
        let id = ObjectIdentifier(stream)
        eventStreams[runID, default: [:]][id] = stream
        let history = run.history.events
        return AsyncStream { continuation in
            let forwarder = Task { [weak stream] in
                guard let stream else {
                    continuation.finish()
                    return
                }
                for (index, event) in history.enumerated() {
                    let terminal = index == history.count - 1
                        && (event.coalesceKey == nil)
                        && (history.last.map { last in
                            if case .runFinished = last { return true }
                            return false
                        } ?? false)
                    stream.append(event, terminal: terminal)
                }
                while let event = await stream.next() {
                    continuation.yield(event)
                    if case .runFinished = event { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self, weak stream] _ in
                forwarder.cancel()
                guard let self, let stream else { return }
                let streamID = ObjectIdentifier(stream)
                Task {
                    await self.removeEventStream(streamID, runID: runID)
                }
            }
            _ = id
        }
    }

    private func removeEventStream(_ id: ObjectIdentifier, runID: UUID) {
        eventStreams[runID]?.removeValue(forKey: id)
    }

    private func emit(_ runID: UUID, _ event: FlowRuntimeEvent, terminal: Bool = false) {
        guard var run = runs[runID] else { return }
        run.history.append(event)
        runs[runID] = run
        for (_, stream) in eventStreams[runID] ?? [:] {
            stream.append(event, terminal: terminal)
        }
    }

    // MARK: Start / resume

    /// Begin a new run over a compiled graph. The identity, digests and
    /// inputs are frozen for the run's lifetime; required inputs must all
    /// be bound by edges or declared run inputs.
    @discardableResult
    public func startRun(
        compiled: CompiledFlow,
        configuration: FlowRunConfiguration,
        seed: FlowRunSeed? = nil
    ) async throws -> UUID {
        let identity = configuration.identity
        // NOTE: no up-front environment requirement. Purely local,
        // deterministic nodes (native-registry transforms, constant
        // sources, conditions, loops, batches, variables, subgraphs of
        // those) run with an empty environment. The requirement is
        // enforced lazily at the single point that would actually submit
        // external script/API work (see `executeExternal`), so unselected
        // branches never demand an environment they would not use.
        let revisionKey = try configuration.revisionKey(graphDigest: compiled.graphDigest)
        if let seed, seed.revisionKey != revisionKey {
            throw FlowRuntimeError.invalidRunConfiguration(
                "seed revision key does not match this configuration")
        }

        var run = FlowRunState(
            compiled: compiled,
            configuration: configuration,
            revisionKey: revisionKey)

        // Run frame: run-level declarations + initial values.
        var runFrame = FlowVariableFrame(
            ownerNodeID: nil,
            declarations: compiled.variables.runLevel)
        for variable in compiled.variables.runLevel {
            runFrame.values[variable.name] = variable.initial ?? defaultValue(for: variable.dataType)
        }
        run.frames = [runFrame]

        // Initialize every schedulable unit as pending.
        for unitID in compiled.topoOrder {
            run.unitStatus[run.key(callPath: "/", nodeID: unitID)] = .pending
        }

        // Validate required inputs are bound.
        var missing: [UUID: [String]] = [:]
        for (nodeID, ports) in compiled.requiredInputs {
            let bound = Set(configuration.runInputs.filter { $0.nodeID == nodeID }.map(\.portName))
            let stillMissing = ports.filter { !bound.contains($0) }
            if !stillMissing.isEmpty { missing[nodeID] = stillMissing }
        }
        if let first = missing.sorted(by: { $0.key.uuidString < $1.key.uuidString }).first {
            throw FlowRuntimeError.missingRequiredInputs(nodeID: first.key, ports: first.value)
        }

        // Validate the reachable template closure before anything is frozen
        // or submitted: strict compilation per template, ambiguous
        // (duplicate) declarations, and template-reference cycles are all
        // diagnosed here at the valid entry.
        try validateTemplateClosure(
            of: compiled.graph, maxLoopIterations: configuration.maxLoopIterations)

        // Debug intent registered before start.
        run.breakpoints = prestartBreakpoints[identity.runID] ?? []
        run.bypassed = prestartBypassed[identity.runID] ?? []
        prestartBreakpoints.removeValue(forKey: identity.runID)
        prestartBypassed.removeValue(forKey: identity.runID)

        // Seed reused state for rerun-style runs.
        if let seed {
            for record in seed.reusedRecords { run.stepRecords.append(record) }
            for (nodeID, outputs) in seed.reusedOutputs {
                run.unitStatus[run.key(callPath: "/", nodeID: nodeID)] = .succeeded(outputs: outputs)
                // Output-node results are the run's deliverables: restore
                // them so a fully-reused run still exposes its outputs.
                if compiled.nodes[nodeID]?.kind == .output {
                    for (name, value) in outputs {
                        run.runOutputs[name] = value
                    }
                }
            }
            run.completedStepCount = seed.reusedRecords.count
        }

        runs[identity.runID] = run

        // Freeze the run definitions and bind their hash BEFORE any attempt
        // can be submitted. A restart rebuilds this exact graph — never
        // whatever the canvas currently holds.
        let definitions = try FlowRunDefinitions(
            identity: identity,
            graph: compiled.graph,
            subgraphTemplates: Array(subgraphTemplates.values),
            configuration: configuration,
            graphDigest: compiled.graphDigest,
            revisionKeyDigest: flowRevisionKeyDigest(revisionKey))
        runs[identity.runID]?.definitionsDigest = definitions.definitionsDigest
        try await journal?.writeDefinitions(definitions)

        try await journal?.writeManifest(.init(
            identity: identity,
            graphDigest: compiled.graphDigest,
            configurationDigest: configuration.configurationDigest,
            revisionKeyDigest: flowRevisionKeyDigest(revisionKey),
            definitionsDigest: definitions.definitionsDigest,
            phase: .running,
            createdAt: identity.startedAt,
            updatedAt: Date()))

        emit(identity.runID, .runStarted(runID: identity.runID, revisionKeyBound: true))
        await checkpoint(identity.runID)
        await pump(identity.runID)
        return identity.runID
    }

    /// Resume a run after a process restart, rebuilding the ORIGINAL
    /// compiled graph from the journal's frozen definitions — the current
    /// canvas state is irrelevant to adoption. The host must re-verify the
    /// original task/environment execution capability before calling this;
    /// importing an archive never revives run permissions by itself.
    public func resumeRun(runID: UUID) async throws {
        guard let journal else { throw FlowRuntimeError.resumeUnavailable(runID) }
        guard let definitions = try await journal.loadDefinitions(runID: runID) else {
            throw FlowRuntimeError.resumeUnavailable(runID)
        }
        guard let manifest = try await journal.loadManifest(runID: runID),
              manifest.definitionsDigest == definitions.definitionsDigest else {
            throw FlowRuntimeError.invalidRunConfiguration(
                "definitions hash is not bound to the manifest; refusing to resume")
        }
        // Adopt the FROZEN template definitions persisted with the run. The
        // canvas snapshot stores only template IDs; resuming must execute
        // the original template graphs, never whatever the host currently
        // holds (which may have been edited or dropped).
        for template in definitions.subgraphTemplates {
            subgraphTemplates[template.id] = template
        }
        duplicateTemplateIDs.subtract(definitions.subgraphTemplates.map(\.id))
        // Template bodies may differ from any cached compilation: recompile.
        compiledSubgraphs.removeAll()
        try validateTemplateClosure(
            of: definitions.graph,
            maxLoopIterations: definitions.configuration.maxLoopIterations)
        let compiled = try FlowGraphCompiler.compile(
            definitions.graph,
            maxLoopIterations: definitions.configuration.maxLoopIterations)
        try await resumeRun(
            runID: runID,
            compiled: compiled,
            configuration: definitions.configuration)
    }

    /// Resume a run after a process restart from the durable journal.
    /// Digests must match exactly; unconfirmed attempts are reconciled by
    /// QUERY — never resubmitted.
    public func resumeRun(
        runID: UUID,
        compiled: CompiledFlow,
        configuration: FlowRunConfiguration
    ) async throws {
        guard let journal else { throw FlowRuntimeError.resumeUnavailable(runID) }
        guard let manifest = try await journal.loadManifest(runID: runID) else {
            throw FlowRuntimeError.resumeUnavailable(runID)
        }
        guard manifest.graphDigest == compiled.graphDigest,
              manifest.configurationDigest == configuration.configurationDigest,
              manifest.identity == configuration.identity else {
            throw FlowRuntimeError.invalidRunConfiguration(
                "journal digests do not match the provided compiled graph/configuration")
        }
        if let definitions = try await journal.loadDefinitions(runID: runID),
           definitions.definitionsDigest != manifest.definitionsDigest {
            throw FlowRuntimeError.invalidRunConfiguration(
                "frozen definitions hash does not match the manifest; refusing to resume")
        }
        guard let snapshot = try await journal.loadCheckpoint(runID: runID) else {
            throw FlowRuntimeError.resumeUnavailable(runID)
        }

        var run = FlowRunState(
            compiled: compiled,
            configuration: configuration,
            revisionKey: try configuration.revisionKey(graphDigest: compiled.graphDigest))
        switch snapshot.phase {
        case .completed, .failed, .cancelled:
            run.phase = snapshot.phase
        default:
            run.phase = .running
        }
        run.generation = snapshot.generation
        run.frames = snapshot.frames.map {
            FlowVariableFrame(ownerNodeID: $0.ownerNodeID, declarations: $0.declarations, values: $0.values)
        }
        if run.frames.isEmpty {
            var runFrame = FlowVariableFrame(declarations: compiled.variables.runLevel)
            for variable in compiled.variables.runLevel {
                runFrame.values[variable.name] = variable.initial ?? defaultValue(for: variable.dataType)
            }
            run.frames = [runFrame]
        }
        for (key, state) in snapshot.nodeStates {
            switch state.kind {
            case .pending: run.unitStatus[key] = .pending
            case .running: run.unitStatus[key] = .running
            case .succeeded: run.unitStatus[key] = .succeeded(outputs: state.outputs)
            case .failed: run.unitStatus[key] = .failed(error: state.error ?? "unknown")
            case .skipped: run.unitStatus[key] = .skipped(reason: state.skipReason ?? "skipped")
            }
        }
        for unitID in compiled.topoOrder
        where run.unitStatus[run.key(callPath: "/", nodeID: unitID)] == nil {
            run.unitStatus[run.key(callPath: "/", nodeID: unitID)] = .pending
        }
        run.stepRecords = snapshot.stepRecords
        run.loopCounters = snapshot.loopCounters
        run.batchProgress = snapshot.batchProgress
        run.breakpoints = Set(snapshot.breakpoints)
        run.bypassed = Set(snapshot.bypassed)
        run.runOutputs = snapshot.runOutputs
        run.completedStepCount = snapshot.completedStepCount
        run.failureCount = run.stepRecords.filter { $0.status == .failed }.count

        // Rebuild attempt records from disk (fail-closed reader).
        let records = try await journal.loadAttempts(runID: runID)
        for record in records { run.attempts[record.attemptID] = record }
        // Coordinate-exact reconciliation. The checkpoint may be STALE with
        // respect to the attempt ledger (a pause can persist a pre-submission
        // view while `executeExternal` is suspended between the in-memory
        // `.running` mark and the durable attempt write). Every non-terminal
        // unit is therefore resolved against the FULL execution coordinate
        // (callPath + nodeID, iteration-tiebroken) — never by node ID alone,
        // which could adopt an unrelated template instance / loop iteration:
        //   - latest record terminal  → adopt it (status, step record,
        //     variable writes); the unit is NEVER re-executed;
        //   - latest record open      → keep the unit running and queue the
        //     attempt for host reconcile (query/adopt, never resubmit);
        //   - no record at coordinate → a stale `.running` marker re-arms to
        //     pending; re-execution regenerates the same deterministic
        //     attempt ID, so host dedupe still prevents duplicate paid work.
        // Terminal units from the checkpoint are immutable facts and are not
        // touched. Frozen graph/config/template definitions remain the
        // authority for everything that still needs to run.
        for (key, status) in run.unitStatus where !status.isTerminal {
            guard let separator = key.lastIndex(of: "#") else { continue }
            let callPath = String(key[..<separator])
            guard let nodeID = UUID(uuidString: String(key[key.index(after: separator)...]))
            else { continue }
            restoreUnitFromAttempts(
                run: &run, key: key, callPath: callPath,
                nodeID: nodeID, compiled: compiled)
        }
        run.failureCount = run.stepRecords.filter { $0.status == .failed }.count
        for pending in snapshot.pendingAttempts {
            run.pendingAttempts.insert(pending.attemptID)
            if run.attempts[pending.attemptID] == nil {
                run.attempts[pending.attemptID] = pending
            }
        }

        runs[runID] = run

        // Query the host for still-unconfirmed attempts: reconcile, never
        // resubmit. Terminal answers are adopted; the rest stay pending.
        for attemptID in run.pendingAttempts.sorted(by: { $0.uuidString < $1.uuidString }) {
            await queryAndReconcile(runID: runID, attemptID: attemptID)
        }

        emit(runID, .resumed(runID: runID))
        if runs[runID]?.phase == .running {
            await pump(runID)
        }
    }

    /// Resolve one non-terminal unit against the durable attempt ledger at
    /// its exact execution coordinate. See the resume reconstruction loop
    /// for the contract. Mutates only the inout run.
    private func restoreUnitFromAttempts(
        run: inout FlowRunState,
        key: String,
        callPath: String,
        nodeID: UUID,
        compiled: CompiledFlow
    ) {
        let coordinateAttempts = run.attempts.values.filter {
            $0.nodeID == nodeID && $0.callPath == callPath
        }
        // Iteration tiebreak, then wall clock: with equal timestamps the
        // higher iteration is the newer execution fact.
        let latest = coordinateAttempts.sorted(by: {
            ($0.iterationIndex ?? -1, $0.updatedAt.timeIntervalSince1970)
                < ($1.iterationIndex ?? -1, $1.updatedAt.timeIntervalSince1970)
        }).last
        guard let latest else {
            if case .running = run.unitStatus[key] {
                run.unitStatus[key] = .pending
            }
            return
        }
        if latest.terminalStatus {
            adoptTerminalRecord(
                run: &run, key: key, record: latest,
                nodeID: nodeID, compiled: compiled)
        } else {
            // `.persisted` is included here on purpose: the record proves the
            // coordinate exists, but the submission outcome is ambiguous
            // (crash between persist and submit). Reconcile queries the host
            // first; a host that never saw the attempt lets the pump re-arm
            // the coordinate (see `refreshUnitStatus`), which regenerates the
            // same deterministic attempt ID — never a second paid call.
            run.unitStatus[key] = .running
            run.pendingAttempts.insert(latest.attemptID)
        }
    }

    /// Adopt a terminal attempt record into one unit: status, step record
    /// and variable writes. Shared by scheduling-time refresh (`refreshUnitStatus`)
    /// and journal resume (`restoreUnitFromAttempts`) so a stale checkpoint can
    /// never lose the persisted outcome or the variable frames it produced.
    private func adoptTerminalRecord(
        run: inout FlowRunState,
        key: String,
        record: FlowAttemptRecord,
        nodeID: UUID,
        compiled: CompiledFlow
    ) {
        switch record.status {
        case .succeeded:
            run.unitStatus[key] = .succeeded(outputs: record.outputs)
        case .failed:
            run.unitStatus[key] = .failed(error: record.error ?? "failed")
            run.failureCount += 1
        case .cancelled:
            run.unitStatus[key] = .skipped(reason: "cancelled")
        default:
            return
        }
        run.stepRecords.append(FlowStepRecord(
            runID: run.configuration.identity.runID,
            nodeID: nodeID,
            attempt: record.attempt,
            status: .init(record.status),
            inputs: record.inputs,
            outputs: record.outputs,
            error: record.error))
        if record.status == .succeeded, let node = definition(nodeID: nodeID, callPath: record.callPath, run: run) {
            try? applyVariableWrites(run: &run, node: node, outputs: record.outputs)
        }
    }

    // MARK: Debug controls

    /// Pause the run: stop scheduling at unit boundaries and acknowledge the
    /// pause ONLY once its checkpoint is durable. The call awaits the journal
    /// write, so when it returns the run can be abandoned (process death) and
    /// a later `resumeRun` deterministically reconstructs the paused state —
    /// no detached-task race between the pause event and the checkpoint.
    /// Source-compatible for callers already using `await`.
    public func pause(runID: UUID) async {
        guard var run = runs[runID], run.phase == .running || run.phase == .stepping || run.phase == .waitingReconcile else { return }
        run.phase = .paused
        runs[runID] = run
        emit(runID, .paused(runID: runID))
        await checkpoint(runID)
    }

    public func resume(runID: UUID) async {
        guard var run = runs[runID], run.phase == .paused else { return }
        run.phase = .running
        run.stepBudget = nil
        if let nodeID = run.pausedBreakpoint { run.breakpointSkipOnce.insert(nodeID) }
        run.pausedBreakpoint = nil
        runs[runID] = run
        emit(runID, .resumed(runID: runID))
        await pump(runID)
    }

    /// Execute exactly one schedulable unit, then pause.
    public func step(runID: UUID) {
        guard var run = runs[runID], run.phase == .paused || run.phase == .running else { return }
        run.phase = .stepping
        if let nodeID = run.pausedBreakpoint { run.breakpointSkipOnce.insert(nodeID) }
        run.pausedBreakpoint = nil
        run.stepBudget = 1
        runs[runID] = run
        Task { await self.pump(runID) }
    }

    public func setBreakpoints(_ nodeIDs: Set<UUID>, runID: UUID) {
        if runs[runID] != nil {
            runs[runID]?.breakpoints = nodeIDs
        } else {
            prestartBreakpoints[runID] = nodeIDs
        }
    }

    public func addBreakpoint(_ nodeID: UUID, runID: UUID) {
        if runs[runID] != nil {
            runs[runID]?.breakpoints.insert(nodeID)
        } else {
            prestartBreakpoints[runID, default: []].insert(nodeID)
        }
    }

    /// Bypass pending units with this node ID (any level): they are
    /// recorded as skipped without execution.
    public func bypass(nodeID: UUID, runID: UUID) {
        if runs[runID] != nil {
            runs[runID]?.bypassed.insert(nodeID)
            Task { await self.pump(runID) }
        } else {
            prestartBypassed[runID, default: []].insert(nodeID)
        }
    }

    public func cancel(runID: UUID) async {
        guard var run = runs[runID],
              run.phase != .completed && run.phase != .failed && run.phase != .cancelled else { return }
        run.phase = .cancelled
        run.generation += 1
        let continuations = run.inFlight.values.compactMap { $0.continuation }
        run.inFlight.removeAll()
        runs[runID] = run
        // The pump never suspends on held external work, so in-flight
        // continuations are normally absent; any straggler resolves as
        // cancelled. The generation bump plus the cleared in-flight
        // registry fence late deliveries: `externalStepDidFinish` records
        // them for recovery instead of touching run state.
        for continuation in continuations {
            continuation.resume(returning: CanvasStepQueryResult(
                attemptID: UUID(), nodeID: UUID(), status: .cancelled))
        }
        try? await executor?.cancelRun(runID: runID)
        emit(runID, .cancelled(runID: runID), terminal: true)
        await checkpoint(runID)
    }

    /// Controlled retry of a failed unit as a NEW attempt (a new attempt ID
    /// is minted, so the host performs new work only for this node).
    public func retry(runID: UUID, nodeID: UUID) async {
        guard var run = runs[runID] else { return }
        let key = run.key(callPath: "/", nodeID: nodeID)
        guard case .failed = run.unitStatus[key] else { return }
        run.unitStatus[key] = .pending
        run.failureCount = max(0, run.failureCount - 1)
        // Un-skip dependents so they re-schedule after the retry.
        let dependents = downstreamKeys(of: nodeID, run: &run)
        for dependent in dependents {
            if case .skipped = run.unitStatus[dependent] {
                run.unitStatus[dependent] = .pending
            }
        }
        runs[runID] = run
        await pump(runID)
    }

    private func downstreamKeys(of nodeID: UUID, run: inout FlowRunState) -> [String] {
        var adjacency: [UUID: [UUID]] = [:]
        var ownership: [UUID: UUID] = [:]
        for (loopID, loop) in run.compiled.loops {
            for bodyID in loop.bodyOrder { ownership[bodyID] = loopID }
        }
        for (batchID, batch) in run.compiled.batches {
            for bodyID in batch.bodyOrder { ownership[bodyID] = batchID }
        }
        func outermost(_ id: UUID) -> UUID {
            var current = id
            var guardCount = 0
            while let owner = ownership[current], guardCount < run.compiled.nodes.count {
                current = owner
                guardCount += 1
            }
            return current
        }
        var seen = Set<String>()
        for (destination, edges) in run.compiled.incomingEdges {
            for edge in edges {
                let source = outermost(edge.sourceNodeID)
                let dest = outermost(destination)
                guard source != dest else { continue }
                let marker = source.uuidString + "→" + dest.uuidString
                if seen.insert(marker).inserted {
                    adjacency[source, default: []].append(dest)
                }
            }
        }
        var closure: Set<UUID> = [nodeID]
        var queue = [nodeID]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for next in adjacency[current] ?? [] where closure.insert(next).inserted {
                queue.append(next)
            }
        }
        return run.unitStatus.keys.filter { key in
            guard let id = UUID(uuidString: key.components(separatedBy: "#").last ?? "") else {
                return false
            }
            return closure.contains(id)
        }
    }

    // MARK: Reconciliation (unknown submissions)

    /// Query the host for one unconfirmed attempt and adopt the answer.
    public func reconcile(runID: UUID, attemptID: UUID) async {
        await queryAndReconcile(runID: runID, attemptID: attemptID)
        await pump(runID)
    }

    /// Host hook: an external step finished; query and adopt its result,
    /// then resume any unit suspended on it.
    public func externalStepDidFinish(runID: UUID, attemptID: UUID) async {
        guard var run = runs[runID] else { return }
        if run.phase == .cancelled {
            // Late delivery after cancellation: `cancel` cleared the
            // in-flight registry and bumped the generation, so this result
            // must never touch scheduling state or unblock downstream work.
            // Record it for recovery instead (generation fence; the
            // pump-free held path has no continuation to fence).
            var late = run.attempts[attemptID] ?? FlowAttemptRecord(
                attemptID: attemptID, runID: runID, nodeID: UUID(), attempt: 0,
                callPath: "/", status: .cancelled)
            late.status = .cancelled
            late.updatedAt = Date()
            run.lateDeliveries.append(late)
            runs[runID] = run
            emit(runID, .lateDeliveryRecorded(runID: runID, attemptID: attemptID,
                                              nodeID: late.nodeID))
            return
        }
        await queryAndReconcile(runID: runID, attemptID: attemptID)
        guard var refreshed = runs[runID] else { return }
        if let inFlight = refreshed.inFlight[attemptID] {
            refreshed.inFlight.removeValue(forKey: attemptID)
            runs[runID] = refreshed
            let record = refreshed.attempts[attemptID]
            let result = CanvasStepQueryResult(
                attemptID: attemptID,
                nodeID: record?.nodeID ?? UUID(),
                status: record.map { CanvasStepQueryStatus($0.status) } ?? .unknown,
                outputs: record?.outputs ?? [:],
                hostTaskBinding: record?.hostTaskBinding,
                error: record?.error)
            // Continuations are never registered by the pump-free held
            // path; this stays as a defensive no-op for contract safety.
            inFlight.continuation?.resume(returning: result)
        } else {
            runs[runID] = refreshed
        }
        if var live = runs[runID], live.phase == .stepping,
           let budget = live.stepBudget, budget <= 0 {
            live.phase = .paused
            live.stepBudget = nil
            runs[runID] = live
            emit(runID, .steppingPaused(runID: runID,
                                       completedNodeID: live.attempts[attemptID]?.nodeID ?? UUID()))
            emit(runID, .paused(runID: runID))
            await checkpoint(runID)
            return
        }
        await pump(runID)
    }

    private func queryAndReconcile(runID: UUID, attemptID: UUID) async {
        guard var run = runs[runID],
              let record = run.attempts[attemptID] else { return }
        guard !record.terminalStatus else { return }
        // A cancelled run never adopts host answers: late results are
        // fenced in `externalStepDidFinish`; reconcile stays a no-op too.
        guard run.phase != .cancelled else { return }
        guard let executor else { return }
        let result: CanvasStepQueryResult
        do {
            result = try await executor.queryStep(attemptID: attemptID, runID: runID)
        } catch {
            // Still unresolvable: stays pending. Never resubmit.
            emit(runID, .reconcileRequired(runID: runID, attemptID: attemptID, nodeID: record.nodeID))
            return
        }
        // Query suspends the actor; retain a concurrent pause/cancel or
        // checkpoint failure instead of restoring the pre-query run copy.
        guard let latest = runs[runID], latest.phase != .cancelled else { return }
        run = latest
        switch result.status {
        case .succeeded, .failed, .cancelled:
            var updated = record
            updated.status = .init(result.status)
            updated.outputs = result.outputs
            updated.error = result.error
            updated.hostTaskBinding = result.hostTaskBinding
            updated.updatedAt = Date()
            run.attempts[attemptID] = updated
            run.pendingAttempts.remove(attemptID)
            if run.phase == .waitingReconcile {
                run.phase = .running
            }
            runs[runID] = run
            try? await journal?.persistAttempt(updated)
            try? await journal?.appendJournal(runID: runID, entry: .attemptUpdated(updated))
            emit(runID, .reconciled(runID: runID, attemptID: attemptID,
                                    status: result.status.rawValue))
            await adoptAttemptIntoUnits(runID: runID, record: updated)
        case .unknown, .queued, .running:
            emit(runID, .reconcileRequired(runID: runID, attemptID: attemptID, nodeID: record.nodeID))
        }
    }

    private func adoptAttemptIntoUnits(runID: UUID, record: FlowAttemptRecord) async {
        guard var run = runs[runID] else { return }
        // Exact execution coordinate: a late callback for one template
        // instance or loop iteration must never adopt into a different
        // coordinate that happens to share the node ID. The in-flight unit
        // for an attempt is always keyed by the record's own callPath.
        let key = run.key(callPath: record.callPath, nodeID: record.nodeID)
        var changedAny = false
        if case .running = run.unitStatus[key] {
            switch record.status {
            case .succeeded:
                run.unitStatus[key] = .succeeded(outputs: record.outputs)
                run.completedStepCount += 1
            case .failed:
                run.unitStatus[key] = .failed(error: record.error ?? "failed")
                run.failureCount += 1
            case .cancelled:
                run.unitStatus[key] = .skipped(reason: "cancelled")
            default:
                runs[runID] = run
                await checkpointIfDue(runID)
                return
            }
            if record.status == .succeeded,
               let node = definition(nodeID: record.nodeID, callPath: record.callPath, run: run) {
                try? applyVariableWrites(run: &run, node: node, outputs: record.outputs)
            }
            changedAny = true
        }
        // Publish the adopted unit before appending to the same run. The
        // old ordering overwrote the appended recovery record afterwards.
        runs[runID] = run
        if changedAny {
            appendRecordForNode(
                runID: runID, nodeID: record.nodeID,
                status: .init(record.status),
                outputs: record.outputs,
                error: record.error,
                attempt: record.attempt)
        }
        await checkpointIfDue(runID)
    }

    // MARK: Status / result

    public struct RunStatusSnapshot: Sendable {
        public var phase: FlowRunPhase
        public var completedSteps: Int
        public var totalUnits: Int
        public var pendingReconciliations: Int
        public var failureCount: Int
        /// First durable-checkpoint write failure, if any. Additive status
        /// field (defaulted); nil for hosts that do not read it.
        public var checkpointFailure: String? = nil
    }

    public func status(runID: UUID) -> RunStatusSnapshot? {
        guard let run = runs[runID] else { return nil }
        return .init(
            phase: run.phase,
            completedSteps: run.completedStepCount,
            totalUnits: run.compiled.topoOrder.count,
            pendingReconciliations: run.pendingAttempts.count,
            failureCount: run.stepRecords.filter { $0.status == .failed }.count,
            checkpointFailure: run.checkpointFailure)
    }

    public func stepRecords(runID: UUID) -> [FlowStepRecord] {
        runs[runID]?.stepRecords ?? []
    }
    public func retainedEvents(runID: UUID) -> [FlowRuntimeEvent] {
        runs[runID]?.history.events ?? []
    }

    public func lateDeliveries(runID: UUID) -> [FlowAttemptRecord] {
        runs[runID]?.lateDeliveries ?? []
    }

    public func result(runID: UUID) -> FlowRunResult? {
        guard let run = runs[runID],
              run.phase == .completed || run.phase == .failed || run.phase == .cancelled else {
            return nil
        }
        return FlowRunResult(
            identity: run.configuration.identity,
            revisionKey: run.revisionKey,
            terminalStatus: FlowRunTerminalStatus(rawValue: run.phase.rawValue) ?? .cancelled,
            records: run.stepRecords,
            runOutputs: run.runOutputs,
            nodeOutputs: currentLevelOutputs(run, callPath: "/"),
            callPaths: [:],
            stale: false)
    }

    private func currentLevelOutputs(
        _ run: FlowRunState,
        callPath: String
    ) -> [UUID: [String: FlowValue]] {
        var outputs: [UUID: [String: FlowValue]] = [:]
        let prefix = "\(callPath)#"
        for (key, status) in run.unitStatus {
            guard key.hasPrefix(prefix), case .succeeded(let values) = status else { continue }
            if let nodeID = UUID(uuidString: key.components(separatedBy: "#").last ?? "") {
                outputs[nodeID] = values
            }
        }
        return outputs
    }

    // MARK: The scheduler

    private func pump(_ runID: UUID) async {
        guard var run = runs[runID] else { return }
        guard run.phase == .running || run.phase == .stepping else { return }
        if run.pumping { return }
        run.pumping = true
        runs[runID] = run

        while true {
            guard var current = runs[runID] else { return }
            if current.phase != .running && current.phase != .stepping { break }

            // Candidate queue: every pending unit is evaluated once; units
            // become ready when their dependencies finish, at which point
            // they are enqueued again by the dependent fan-out below. This
            // keeps scheduling O(V+E) on chains instead of O(V²).
            var queue: [UUID] = current.compiled.topoOrder
            var head = 0
            var madeProgress = false

            while head < queue.count {
                guard var live = runs[runID] else { return }
                guard live.phase == .running || live.phase == .stepping else { break }
                let unitID = queue[head]
                head += 1
                let nodeKey = live.key(callPath: "/", nodeID: unitID)
                refreshUnitStatus(run: &live, nodeID: unitID, callPath: "/",
                                  compiled: live.compiled)
                guard case .pending = live.unitStatus[nodeKey] ?? .pending else { continue }
                runs[runID] = live

                let readiness = self.readiness(
                    run: live,
                    compiled: live.compiled,
                    nodeID: unitID,
                    callPath: "/",
                    exposedInputs: exposedRunInputs(run: live, nodeID: unitID))
                switch readiness {
                case .notReady:
                    continue
                case .skip(let reason):
                    markSkipped(&live, nodeKey: nodeKey, nodeID: unitID, reason: reason)
                    runs[runID] = live
                    emit(runID, .stepSkipped(runID: runID, nodeID: unitID, reason: reason))
                    queue.append(contentsOf: dependentUnits(of: unitID, run: live))
                    madeProgress = true
                case .ready:
                    if live.breakpoints.contains(unitID), live.breakpointSkipOnce.remove(unitID) == nil {
                        live.pausedBreakpoint = unitID
                        live.phase = .paused
                        runs[runID] = live
                        emit(runID, .breakpointHit(runID: runID, nodeID: unitID))
                        await checkpoint(runID)
                        break
                    }
                    if live.bypassed.contains(unitID) {
                        markSkipped(&live, nodeKey: nodeKey, nodeID: unitID, reason: "bypassed")
                        runs[runID] = live
                        emit(runID, .stepSkipped(runID: runID, nodeID: unitID, reason: "bypassed"))
                        queue.append(contentsOf: dependentUnits(of: unitID, run: live))
                        madeProgress = true
                        continue
                    }
                    live.unitStatus[nodeKey] = .running
                    if live.phase == .stepping,
                       let unit = live.compiled.nodes[unitID],
                       unit.kind != .loop && unit.kind != .batch && unit.kind != .subgraph {
                        live.stepBudget = (live.stepBudget ?? 1) - 1
                    }
                    runs[runID] = live
                    madeProgress = true
                    emit(runID, .stepScheduled(runID: runID, nodeID: unitID,
                                               attempt: 1, callPath: "/"))
                    await executeUnit(runID: runID, nodeID: unitID,
                                      callPath: "/", iterationIndex: nil,
                                      compiled: current.compiled)
                    queue.append(contentsOf: dependentUnits(of: unitID, run: live))
                    if let status = runs[runID]?.unitStatus[nodeKey], !status.isTerminal {
                        // A structured scope retains its lexical frame while
                        // external work is outstanding. Re-enter only after
                        // the host callback changes the durable attempt, not
                        // by repeatedly appending the same running unit.
                        if runs[runID]?.pendingAttempts.isEmpty == false,
                           runs[runID]?.phase == .running {
                            runs[runID]?.phase = .waitingReconcile
                        }
                        runs[runID]?.pumping = false
                        return
                    }
                    if let budget = runs[runID]?.stepBudget, budget <= 0,
                       runs[runID]?.phase == .stepping {
                        let allTerminal = current.compiled.topoOrder.allSatisfy { id in
                            (runs[runID]?.unitStatus[runs[runID]!
                                .key(callPath: "/", nodeID: id)])?.isTerminal ?? false
                        }
                        if !allTerminal {
                            runs[runID]?.phase = .paused
                            runs[runID]?.stepBudget = nil
                            emit(runID, .steppingPaused(runID: runID, completedNodeID: unitID))
                            emit(runID, .paused(runID: runID))
                            await checkpoint(runID)
                        }
                    }
                }
            }

            guard let live = runs[runID] else { return }
            if live.phase != .running && live.phase != .stepping { break }
            let anyRunning = live.unitStatus.values.contains { status in
                if case .running = status { return true }
                return false
            }
            if !madeProgress || head >= queue.count {
                if !anyRunning {
                    await finalize(runID)
                } else if !live.pendingAttempts.isEmpty, live.phase == .running {
                    runs[runID]?.phase = .waitingReconcile
                }
                break
            }
        }

        runs[runID]?.pumping = false
    }

    /// Contracted dependents of a root-level unit (skip/failure and
    /// completion both fan out to these candidates).
    private func dependentUnits(of unitID: UUID, run: FlowRunState) -> [UUID] {
        var ownership: [UUID: UUID] = [:]
        for (loopID, loop) in run.compiled.loops {
            for bodyID in loop.bodyOrder { ownership[bodyID] = loopID }
        }
        for (batchID, batch) in run.compiled.batches {
            for bodyID in batch.bodyOrder { ownership[bodyID] = batchID }
        }
        func outermost(_ id: UUID) -> UUID {
            var currentID = id
            var guardCount = 0
            while let owner = ownership[currentID], guardCount < run.compiled.nodes.count {
                currentID = owner
                guardCount += 1
            }
            return currentID
        }
        var seen = Set<UUID>()
        var result: [UUID] = []
        for edge in run.compiled.outgoingEdges[unitID] ?? [] {
            let dependent = outermost(edge.destinationNodeID)
            guard dependent != unitID, seen.insert(dependent).inserted else { continue }
            result.append(dependent)
        }
        return result.sorted { $0.uuidString < $1.uuidString }
    }

    /// A new iteration/item starts a fresh subtree, while immutable attempt
    /// records remain available at their own execution coordinate.
    private func resetNestedState(run: inout FlowRunState, parent: String, nodeID: UUID) {
        let path = nestedCallPath(parent: parent, nodeID: nodeID, run: run)
        func inside(_ key: String) -> Bool {
            key.hasPrefix(path + "#") || key.hasPrefix(path + "/")
        }
        run.unitStatus = run.unitStatus.filter { !inside($0.key) }
        run.conditionChoices = run.conditionChoices.filter { !inside($0.key) }
        run.loopCounters = run.loopCounters.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        run.batchProgress = run.batchProgress.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

    private func nestedCallPath(parent: String, nodeID: UUID, run: FlowRunState) -> String {
        let canonical = (parent == "/" ? "" : parent) + "/\(nodeID.uuidString)"
        let legacy = parent + "/\(nodeID.uuidString)"
        if canonical != legacy,
           run.unitStatus.keys.contains(where: { $0.hasPrefix(legacy + "#") || $0.hasPrefix(legacy + "/") })
            || run.attempts.values.contains(where: { $0.callPath == legacy || $0.callPath.hasPrefix(legacy + "/") }) {
            return legacy
        }
        return canonical
    }

    private func iterationPath(base: String, kind: String, index: Int, run: FlowRunState) -> String {
        // Older lab journals used unsuffixed body paths. Preserve those
        // exact coordinates when continuing them; new runs encode every
        // ancestor iteration, so an inner index can never alias an older
        // outer iteration.
        if run.unitStatus.keys.contains(where: { $0.hasPrefix(base + "#") }) {
            return base
        }
        return base + "/@\(kind)=\(index)"
    }

    private func definition(nodeID: UUID, callPath: String, run: FlowRunState) -> FlowNode? {
        var level = run.compiled
        for component in callPath.split(separator: "/") {
            if component.hasPrefix("@loop=") || component.hasPrefix("@item=") {
                guard let index = Int(component.split(separator: "=").last ?? ""), index >= 0 else { return nil }
                continue
            }
            guard let ownerID = UUID(uuidString: String(component)), let owner = level.nodes[ownerID] else { return nil }
            if owner.kind == .subgraph {
                guard let templateID = referencedTemplateID(of: owner), let template = subgraphTemplates[templateID],
                      let nested = try? compiledTemplate(template, maxLoopIterations: run.configuration.maxLoopIterations) else { return nil }
                level = nested
            }
        }
        return level.nodes[nodeID]
    }

    /// Adopt terminal attempt records for a unit left `.running` by an
    /// interrupted composite or an unconfirmed submission; re-arm it when
    /// no outstanding attempt could still deliver its result. Mutates only
    /// the inout run (no dictionary round-trip).
    private func refreshUnitStatus(
        run: inout FlowRunState,
        nodeID: UUID,
        callPath: String,
        compiled: CompiledFlow
    ) {
        let key = run.key(callPath: callPath, nodeID: nodeID)
        guard case .running = run.unitStatus[key] else { return }
        let nodeAttempts = run.attempts.values
            .filter { $0.nodeID == nodeID && $0.callPath == callPath }
        if let terminal = nodeAttempts.filter({ $0.terminalStatus })
            .sorted(by: {
                ($0.iterationIndex ?? -1, $0.updatedAt.timeIntervalSince1970)
                    < ($1.iterationIndex ?? -1, $1.updatedAt.timeIntervalSince1970)
            }).last {
            adoptTerminalRecord(
                run: &run, key: key, record: terminal,
                nodeID: nodeID, compiled: compiled)
            return
        }
        let ownPath = nestedCallPath(parent: callPath, nodeID: nodeID, run: run)
        let outstanding = nodeAttempts.contains {
            $0.status == .unknown || $0.status == .running || $0.status == .submitted
        } || run.attempts.values.contains {
            // A composite (loop/batch/subgraph) whose inner levels have
            // outstanding attempts is itself still executing: never re-arm
            // it, or the pump would spin re-submitting deduped attempts.
            ($0.callPath == ownPath || $0.callPath.hasPrefix(ownPath + "/"))
                && ($0.status == .unknown || $0.status == .running || $0.status == .submitted)
        }
        if !outstanding {
            run.unitStatus[key] = .pending
        }
    }

    private enum Readiness {
        case ready
        case notReady
        case skip(reason: String)
    }

    private func exposedRunInputs(
        run: FlowRunState,
        nodeID: UUID
    ) -> [String: FlowValue] {
        var values: [String: FlowValue] = [:]
        for input in run.configuration.runInputs where input.nodeID == nodeID {
            values[input.portName] = input.value
        }
        return values
    }

    private func readiness(
        run: FlowRunState,
        compiled: CompiledFlow,
        nodeID: UUID,
        callPath: String,
        exposedInputs: [String: FlowValue]
    ) -> Readiness {
        let nodeKey = run.key(callPath: callPath, nodeID: nodeID)
        if let status = run.unitStatus[nodeKey] {
            if case .pending = status {} else { return .notReady }
        }

        var satisfiedPortValues: [String: FlowValue] = [:]
        let edges = compiled.incomingEdges[nodeID] ?? []
        var waiting = false
        for edge in edges {
            // Carry edges are iteration feedback: they never gate readiness
            // and never deliver values through the port (values flow via the
            // loop-scope `carry.<port>` variable instead).
            if isCarryEdge(edge, compiled: compiled) {
                continue
            }
            let sourceKey = run.key(callPath: callPath, nodeID: edge.sourceNodeID)
            let sourceStatus = run.unitStatus[sourceKey] ?? .pending
            let destinationPort = compiled.nodes[nodeID]?
                .ports.first(where: { $0.id == edge.destinationPortID })
            let destinationVariadic = destinationPort?.isVariadic ?? false
            // A condition only delivers through its selected branch port.
            if let chosen = run.conditionChoices[sourceKey],
               let sourceNode = compiled.nodes[edge.sourceNodeID],
               sourceNode.kind == .condition,
               chosen != edge.sourcePortID {
                // Inert for variadic aggregation (contributes nothing);
                // fatal for a required single-input port.
                if !destinationVariadic {
                    return .skip(reason: "branchNotTaken")
                }
                continue
            }
            switch sourceStatus {
            case .succeeded(let outputs):
                guard let sourcePortName = portName(compiled: compiled, nodeID: edge.sourceNodeID, portID: edge.sourcePortID),
                      let destPortName = destinationPort?.name else {
                    continue
                }
                // Variadic satisfaction is validated during gather; a
                // single non-variadic value is tracked here.
                if !destinationVariadic {
                    satisfiedPortValues[destPortName] = outputs[sourcePortName] ?? .json(.null)
                }
            case .failed:
                // Variadic ports aggregate best-effort: a failed upstream
                // contributes nothing instead of failing the node.
                if !destinationVariadic {
                    return .skip(reason: "upstreamFailed")
                }
            case .skipped:
                if !destinationVariadic {
                    return .skip(reason: "upstreamSkipped")
                }
            default:
                waiting = true
            }
        }
        if waiting { return .notReady }

        for port in compiled.nodes[nodeID]?.ports ?? [] where port.direction == .input {
            if port.isVariadic { continue } // always satisfiable; may aggregate zero items
            if satisfiedPortValues[port.name] != nil { continue }
            if exposedInputs[port.name] != nil {
                satisfiedPortValues[port.name] = exposedInputs[port.name]
                continue
            }
            if compiled.loops[nodeID] != nil,
               loopCarryPortNames(compiled: compiled, loopNodeID: nodeID).contains(port.name) {
                continue // carried; initial value may be null
            }
            if isBoundBySubgraphInputs(compiled: compiled, nodeID: nodeID, portName: port.name) {
                continue
            }
            return .skip(reason: "missingInput:\(port.name)")
        }
        return .ready
    }

    private func isCarryEdge(_ edge: FlowEdge, compiled: CompiledFlow) -> Bool {
        compiled.loops[edge.destinationNodeID]?
            .carryEdges.contains(where: { $0.id == edge.id }) ?? false
    }

    private func portName(compiled: CompiledFlow, nodeID: UUID, portID: UUID) -> String? {
        compiled.nodes[nodeID]?.ports.first(where: { $0.id == portID })?.name
    }

    private func loopCarryPortNames(compiled: CompiledFlow, loopNodeID: UUID) -> Set<String> {
        guard let loop = compiled.loops[loopNodeID],
              let node = compiled.nodes[loopNodeID] else { return [] }
        return Set(loop.carryEdges.compactMap { edge in
            node.ports.first(where: { $0.id == edge.destinationPortID })?.name
        })
    }

    private func isBoundBySubgraphInputs(
        compiled: CompiledFlow,
        nodeID: UUID,
        portName: String
    ) -> Bool {
        guard compiled.nodes[nodeID]?.kind == .subgraph else { return false }
        guard let bindings = compiled.nodes[nodeID]?.parameters["inputBindings"]?.flowObject else {
            return false
        }
        return bindings[portName] != nil
    }

    private func markSkipped(
        _ run: inout FlowRunState,
        nodeKey: String,
        nodeID: UUID,
        reason: String
    ) {
        run.unitStatus[nodeKey] = .skipped(reason: reason)
        run.stepRecords.append(FlowStepRecord(
            runID: run.configuration.identity.runID,
            nodeID: nodeID,
            status: .skipped,
            error: reason))
    }

    // MARK: Unit execution

    /// Execute one schedulable unit at any lexical level.
    /// - `compiled` is the compiled graph the node belongs to (the run graph
    ///   at the root level, a template compilation inside a subgraph).
    /// - `exposed` are instance-bound values (subgraph input bindings) merged
    ///   into input ports that have no in-scope edge.
    /// - `inner` marks execution inside a subgraph instance: output nodes
    ///   feed the instance boundary instead of `runOutputs`.
    private func executeUnit(
        runID: UUID,
        nodeID: UUID,
        callPath: String,
        iterationIndex: Int?,
        compiled: CompiledFlow,
        exposed: [String: FlowValue] = [:],
        inner: Bool = false
    ) async {
        guard let node = compiled.nodes[nodeID] else { return }
        guard var run = runs[runID] else { return }
        let nodeKey = run.key(callPath: callPath, nodeID: nodeID)
        let generation = run.generation

        do {
            switch node.kind {
            case .source:
                let outputs = try await executeSource(runID: runID, node: node)
                try await finalizeUnit(runID: runID, nodeKey: nodeKey, nodeID: nodeID,
                                       generation: generation, outputs: outputs,
                                       inputs: [:])
            case .condition:
                let outputs = try executeCondition(runID: runID, node: node,
                                                   callPath: callPath, compiled: compiled)
                try await finalizeUnit(runID: runID, nodeKey: nodeKey, nodeID: nodeID,
                                       generation: generation, outputs: outputs,
                                       inputs: [:])
            case .loop:
                try await executeLoop(runID: runID, node: node, callPath: callPath,
                                      compiled: compiled, inner: inner)
            case .batch:
                try await executeBatch(runID: runID, node: node, callPath: callPath,
                                       compiled: compiled, inner: inner)
            case .subgraph:
                try await executeSubgraph(runID: runID, node: node, callPath: callPath,
                                          compiled: compiled, iterationIndex: iterationIndex)
            case .output:
                var inputs = try gatherInputs(runID: runID, compiled: compiled,
                                              node: node, callPath: callPath)
                if inner {
                    for (name, value) in exposed where inputs[name] == nil {
                        inputs[name] = value
                    }
                }
                var outputs: [String: FlowValue] = [:]
                if let resultKey = node.parameters["resultKey"]?.flowString {
                    outputs[resultKey] = inputs[resultKey] ?? inputs.values.first ?? .json(.null)
                } else {
                    outputs = inputs
                }
                if !inner {
                    // Root-level outputs are the run's deliverables; inner
                    // (template) outputs are collected by the instance
                    // boundary of the owning subgraph node.
                    for (name, value) in outputs {
                        runs[runID]?.runOutputs[name] = value
                    }
                }
                try await finalizeUnit(runID: runID, nodeKey: nodeKey, nodeID: nodeID,
                                       generation: generation, outputs: outputs,
                                       inputs: inputs)
            case .transform, .customScript, .customAPI:
                var inputs = try gatherInputs(runID: runID, compiled: compiled,
                                              node: node, callPath: callPath)
                if inner {
                    for (name, value) in exposed where inputs[name] == nil {
                        inputs[name] = value
                    }
                }
                if node.kind == .transform,
                   let handler = nativeRegistry.handler(for: nativeRegistry.key(for: node)) {
                    let outputs = try await executeNative(
                        runID: runID, node: node, inputs: inputs, callPath: callPath,
                        iterationIndex: iterationIndex)
                    try await finalizeUnit(runID: runID, nodeKey: nodeKey, nodeID: nodeID,
                                           generation: generation, outputs: outputs,
                                           inputs: inputs)
                } else {
                    try await executeExternal(
                        runID: runID, node: node, inputs: inputs, callPath: callPath,
                        iterationIndex: iterationIndex, generation: generation)
                }
            }
        } catch {
            guard var live = runs[runID], live.generation == generation else { return }
            live.unitStatus[nodeKey] = .failed(error: describe(error))
            live.failureCount += 1
            live.runFailure = describe(error)
            runs[runID] = live
            emit(runID, .stepFailed(runID: runID, nodeID: nodeID, attempt: 1,
                                    error: describe(error)))
            appendRecordForNode(runID: runID, nodeID: nodeID, status: .failed,
                                error: describe(error))
        }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case let error as CanvasKitError:
            switch error {
            case .missingEntity(let message): return "missingEntity: \(message)"
            case .revisionConflict(let expected, let current):
                return "revisionConflict expected \(expected) current \(current)"
            case .requestIDConflict(let id): return "requestIDConflict: \(id.uuidString)"
            case .io(let message): return "io: \(message)"
            default: return String(describing: error)
            }
        default:
            return String(describing: error)
        }
    }

    private func finalizeUnit(
        runID: UUID,
        nodeKey: String,
        nodeID: UUID,
        generation: Int,
        outputs: [String: FlowValue],
        inputs: [String: FlowValue]
    ) async throws {
        guard var run = runs[runID] else { return }
        guard run.generation == generation else { return }
        run.unitStatus[nodeKey] = .succeeded(outputs: outputs)
        run.completedStepCount += 1
        runs[runID] = run
        emit(runID, .stepCompleted(runID: runID, nodeID: nodeID, attempt: 1, outputs: outputs))
        appendRecordForNode(runID: runID, nodeID: nodeID, status: .succeeded,
                            outputs: outputs, inputs: inputs)
        await checkpointIfDue(runID)
    }

    // MARK: Source nodes

    private func executeSource(runID: UUID, node: FlowNode) async throws -> [String: FlowValue] {
        guard let kind = node.parameters["sourceKind"]?.flowString else {
            throw FlowRuntimeError.invalidRunConfiguration(
                "source node \(node.id.uuidString) misses parameters.sourceKind")
        }
        switch kind {
        case "constant":
            guard let literal = node.parameters["literal"] else {
                throw FlowRuntimeError.invalidRunConfiguration(
                    "constant source node \(node.id.uuidString) misses parameters.literal")
            }
            var outputs: [String: FlowValue] = [:]
            for port in node.ports where port.direction == .output {
                outputs[port.name] = try FlowLiterals.value(literal, as: port.dataType)
            }
            return outputs
        case "canvasBinding":
            guard let bindingKey = node.parameters["bindingKey"]?.flowString else {
                throw FlowRuntimeError.invalidRunConfiguration(
                    "canvasBinding source node \(node.id.uuidString) misses parameters.bindingKey")
            }
            guard let resolver = bindingResolver else {
                // Honest unavailable result: no host resolver, no value.
                throw FlowRuntimeError.hostCapabilityUnavailable(
                    "bindingResolverUnavailable for key '\(bindingKey)'")
            }
            guard var run = runs[runID] else { throw FlowRuntimeError.runNotFound(runID) }
            let context = runtimeContext(run: run)
            let value = try await resolver.resolve(canvasBinding: bindingKey, context: context)
            var outputs: [String: FlowValue] = [:]
            for port in node.ports where port.direction == .output {
                guard FlowEvaluation.isCompatible(value, with: port.dataType) else {
                    throw FlowOperandError.typeMismatch(
                        "binding '\(bindingKey)' produced \(value.valueType.rawValue) for port \(port.name) (\(port.dataType.rawValue))")
                }
                outputs[port.name] = value
            }
            return outputs
        default:
            throw FlowRuntimeError.invalidRunConfiguration(
                "unknown sourceKind '\(kind)' on node \(node.id.uuidString)")
        }
    }

    private func runtimeContext(run: FlowRunState) -> CanvasRuntimeContext {
        CanvasRuntimeContext(
            canvasID: run.configuration.identity.canvasID,
            pageID: run.configuration.pageID ?? run.configuration.identity.canvasID,
            revision: run.configuration.identity.canvasRevision,
            owningTaskID: run.configuration.identity.owningTaskID,
            environmentID: run.configuration.identity.environmentID)
    }

    // MARK: Condition nodes

    private func executeCondition(
        runID: UUID,
        node: FlowNode,
        callPath: String,
        compiled: CompiledFlow
    ) throws -> [String: FlowValue] {
        guard var run = runs[runID] else { throw FlowRuntimeError.runNotFound(runID) }
        let nodeKey = run.key(callPath: callPath, nodeID: node.id)
        let branches = (node.branches ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
        var outputs: [String: FlowValue] = [:]
        var chosen: UUID? = nil
        var lastError: Error? = nil
        var evaluated = false
        for branch in branches {
            do {
                let result = try FlowEvaluation.evaluate(
                    branch.predicate,
                    variables: run.frames,
                    nodeOutputs: currentLevelOutputs(run, callPath: callPath),
                    graphVariables: run.graphVariables)
                evaluated = true
                if result {
                    chosen = branch.outputPortID
                    if let portName = portName(compiled: compiled, nodeID: node.id,
                                               portID: branch.outputPortID) {
                        outputs[portName] = .bool(true)
                    }
                    break
                }
            } catch {
                lastError = error
                continue // a failed predicate branch simply does not match
            }
        }
        if !evaluated, let error = lastError {
            throw error
        }
        run.conditionChoices[nodeKey] = chosen ?? UUID()
        runs[runID] = run
        if let chosen {
            emit(runID, .conditionSelected(runID: runID, nodeID: node.id,
                                           branchOutputPortID: chosen))
        }
        return outputs
    }

    // MARK: Loop nodes

    private func executeLoop(
        runID: UUID,
        node: FlowNode,
        callPath: String,
        compiled: CompiledFlow,
        inner: Bool = false
    ) async throws {
        guard var run = runs[runID],
              let loop = compiled.loops[node.id] else {
            throw FlowRuntimeError.runNotFound(runID)
        }
        let inputs = try gatherInputs(runID: runID, compiled: compiled,
                                      node: node, callPath: callPath)
        let loopBasePath = nestedCallPath(parent: callPath, nodeID: node.id, run: run)
        var loopPath = iterationPath(base: loopBasePath, kind: "loop",
            index: run.loopCounters[loopBasePath] ?? 0, run: run)

        // Full reset for failures: every body unit back to pending, the
        // loop frame popped, the iteration counter cleared. Re-entry starts
        // again from iteration 0; terminal attempt coordinates advance the
        // deterministic attempt number, so a controlled retry mints new
        // attempts (deliberate new work).
        func resetAfterFailure() {
            guard var live = runs[runID] else { return }
            for bodyID in loop.bodyOrder {
                live.unitStatus[live.key(callPath: loopPath, nodeID: bodyID)] = .pending
            }
            if live.frames.last?.ownerNodeID == node.id {
                live.frames.removeLast()
            }
            live.loopCounters.removeValue(forKey: loopBasePath)
            live.unitStatus[live.key(callPath: callPath, nodeID: node.id)] = .pending
            runs[runID] = live
        }

        // Interruption reset (pause / cancel / breakpoint / step budget):
        // completed body units in the current iteration are immutable facts
        // and are preserved — re-running them would resubmit paid work — as
        // are units still suspended on outstanding host attempts. The frame
        // and the iteration counter are kept so the resume continues the
        // interrupted iteration at a deterministic point.
        func preserveInterruption() {
            guard var live = runs[runID] else { return }
            for bodyID in loop.bodyOrder {
                let key = live.key(callPath: loopPath, nodeID: bodyID)
                switch live.unitStatus[key] {
                case .succeeded:
                    continue
                case .running:
                    let outstanding = live.attempts.values.contains {
                        $0.nodeID == bodyID && $0.callPath == loopPath
                            && ($0.status == .unknown || $0.status == .running
                                || $0.status == .submitted)
                    }
                    live.unitStatus[key] = outstanding ? .running : .pending
                case .failed, .skipped, .pending, .none:
                    live.unitStatus[key] = .pending
                }
            }
            live.unitStatus[live.key(callPath: callPath, nodeID: node.id)] = .pending
            runs[runID] = live
        }

        var frame = FlowVariableFrame(
            ownerNodeID: node.id,
            declarations: (compiled.variables.byOwner[node.id] ?? []))
        for variable in frame.declarations {
            frame.values[variable.name] = variable.initial ?? defaultValue(for: variable.dataType)
        }
        var implicit = frame.declarations
        // A preserved re-entry after an interruption still owns its frame,
        // which holds the interrupted iteration's carry values: keep it.
        // Reset paths pop the frame, so a fresh push happens only when no
        // frame is owned.
        let ownsFrameAlready = run.frames.contains { $0.ownerNodeID == node.id }
        func setLoopValue(_ name: String, _ value: FlowValue) {
            frame.values[name] = value
            if implicit.contains(where: { $0.name == name }) == false {
                implicit.append(FlowVariable(
                    name: name, dataType: value.valueType, ownerNodeID: node.id))
            }
        }
        for port in node.ports where port.direction == .input {
            setLoopValue("carry.\(port.name)", inputs[port.name] ?? .json(.null))
        }
        setLoopValue("iteration", .number(0))
        frame.declarations = implicit
        if ownsFrameAlready == false {
            run.frames.append(frame)
        }
        runs[runID] = run

        var lastExitValues: [UUID: [String: FlowValue]] = [:]

        do {
            // Resume from the interrupted iteration when the loop is
            // re-entered after a preserved interruption; fresh runs (and
            // failure retries, which clear the counter) start at 0.
            let startIteration = runs[runID]?.loopCounters[loopBasePath] ?? 0
            for iteration in startIteration..<loop.bound {
                guard var live = runs[runID] else { return }
                loopPath = iterationPath(base: loopBasePath, kind: "loop", index: iteration, run: live)
                guard live.phase == .running || live.phase == .stepping else {
                    preserveInterruption()
                    return
                }
                if let frameIndex = live.frames.lastIndex(where: { $0.ownerNodeID == node.id }) {
                    live.frames[frameIndex].values["iteration"] = .number(Double(iteration))
                }
                live.loopCounters[loopBasePath] = iteration
                runs[runID] = live

                await executeLevel(
                    runID: runID,
                    compiled: compiled,
                    order: loop.bodyOrder,
                    callPath: loopPath,
                    exposed: [:],
                    inner: inner,
                    iterationIndex: iteration)

                guard var live = runs[runID] else { return }
                var bodyFailed = false
                var bodyIncomplete = false
                for bodyID in loop.bodyOrder {
                    switch live.unitStatus[live.key(callPath: loopPath, nodeID: bodyID)] {
                    case .failed: bodyFailed = true
                    case .pending, .running, .none: bodyIncomplete = true
                    default: continue
                    }
                }
                if bodyFailed {
                    runs[runID] = live
                    throw FlowRuntimeError.invalidRunConfiguration(
                        "loop body failed at iteration \(iteration)")
                }
                if bodyIncomplete {
                    // Preserve body units suspended on outstanding host
                    // attempts (confirmed in-flight or unconfirmed): the
                    // loop stays `.running` and the pump waits for the
                    // callback/reconcile, mirroring root-level semantics.
                    var hasOutstanding = false
                    for bodyID in loop.bodyOrder {
                        let key = live.key(callPath: loopPath, nodeID: bodyID)
                        guard case .running = live.unitStatus[key] else { continue }
                        let outstanding = live.attempts.values.contains {
                            $0.nodeID == bodyID && $0.callPath == loopPath
                                && ($0.status == .unknown || $0.status == .running
                                    || $0.status == .submitted)
                        }
                        if outstanding {
                            hasOutstanding = true
                        } else {
                            live.unitStatus[key] = .pending
                        }
                    }
                    if hasOutstanding {
                        live.unitStatus[live.key(callPath: callPath, nodeID: node.id)] = .running
                        runs[runID] = live
                        return
                    }
                    // Interrupted (pause/cancel/breakpoint/step): preserve
                    // completed work and resume the interrupted iteration.
                    preserveInterruption()
                    return
                }

                // Capture carries and exit values from this iteration.
                var carryValues: [String: FlowValue] = [:]
                for edge in loop.carryEdges {
                    let sourceKey = live.key(callPath: loopPath, nodeID: edge.sourceNodeID)
                    if case .succeeded(let outputs) = live.unitStatus[sourceKey],
                       let sourcePort = compiled.nodes[edge.sourceNodeID]?
                        .ports.first(where: { $0.id == edge.sourcePortID }),
                       let loopPort = node.ports
                        .first(where: { $0.id == edge.destinationPortID }) {
                        carryValues["carry.\(loopPort.name)"] = outputs[sourcePort.name] ?? .json(.null)
                    }
                }
                lastExitValues = [:]
                for edge in loop.exitEdges {
                    let sourceKey = live.key(callPath: loopPath, nodeID: edge.sourceNodeID)
                    if case .succeeded(let outputs) = live.unitStatus[sourceKey] {
                        lastExitValues[edge.sourceNodeID] = outputs
                    }
                }

                // Reset body states and apply carries for the next round.
                if iteration + 1 < loop.bound {
                    for bodyID in loop.bodyOrder {
                        resetNestedState(run: &live, parent: loopPath, nodeID: bodyID)
                        live.unitStatus[live.key(callPath: loopPath, nodeID: bodyID)] = .pending
                    }
                    if live.frames.last?.ownerNodeID == node.id {
                        for (name, value) in carryValues {
                            live.frames[live.frames.count - 1].values[name] = value
                        }
                    }
                    runs[runID] = live
                }

                emit(runID, .loopIteration(runID: runID, nodeID: node.id, iteration: iteration))
                if let predicate = loop.stopPredicate {
                    let stop = try FlowEvaluation.evaluate(
                        predicate,
                        variables: live.frames,
                        nodeOutputs: currentLevelOutputs(live, callPath: loopPath),
                        graphVariables: live.graphVariables)
                    if stop { break }
                }
                await checkpointIfDue(runID)
            }
        } catch {
            resetAfterFailure()
            throw error
        }
        runs[runID]?.loopCounters.removeValue(forKey: loopBasePath)

        // Exits: the last completed iteration's values flow out.
        var outputs: [String: FlowValue] = [:]
        for port in node.ports where port.direction == .output {
            outputs[port.name] = .json(.null)
        }
        for edge in loop.exitEdges {
            guard let sourcePort = compiled.nodes[edge.sourceNodeID]?
                .ports.first(where: { $0.id == edge.sourcePortID }),
                  let destPort = node.ports.first(where: { $0.id == edge.destinationPortID }) else {
                continue
            }
            if let value = lastExitValues[edge.sourceNodeID]?[sourcePort.name] {
                outputs[destPort.name] = value
            }
        }
        runs[runID]?.frames.removeLast()
        for (bodyID, values) in lastExitValues {
            let exitKey = run.key(callPath: callPath, nodeID: bodyID)
            runs[runID]?.unitStatus[exitKey] = .succeeded(outputs: values)
        }
        guard let live = runs[runID] else { return }
        let nodeKey = live.key(callPath: callPath, nodeID: node.id)
        try await finalizeUnit(runID: runID, nodeKey: nodeKey, nodeID: node.id,
                               generation: live.generation, outputs: outputs,
                               inputs: inputs)
    }

    // MARK: Batch nodes

    private func executeBatch(
        runID: UUID,
        node: FlowNode,
        callPath: String,
        compiled: CompiledFlow,
        inner: Bool = false
    ) async throws {
        guard var run = runs[runID],
              let batch = compiled.batches[node.id] else {
            throw FlowRuntimeError.runNotFound(runID)
        }
        let inputs = try gatherInputs(runID: runID, compiled: compiled,
                                      node: node, callPath: callPath)
        guard case .list(let items) = inputs["items"] else {
            throw FlowOperandError.typeMismatch(
                "batch node \(node.id.uuidString) requires a list input on port 'items'")
        }
        let batchBasePath = nestedCallPath(parent: callPath, nodeID: node.id, run: run)
        var batchPath = batchBasePath

        func interrupt() {
            guard var live = runs[runID] else { return }
            // Keep the active item, completed inner units and lexical frames.
            // Resuming this scope never repeats an already completed item.
            live.unitStatus[live.key(callPath: callPath, nodeID: node.id)] = .pending
            runs[runID] = live
        }

        // Per-batch progress persists across interruptions so a re-entered
        // batch skips completed items instead of resubmitting their work.
        var progress = run.batchProgress[batchBasePath] ?? FlowBatchProgressSnapshot()
        var results = progress.results
        var failures = progress.failures

        for (index, item) in items.enumerated() where index >= progress.nextItemIndex {
            guard var live = runs[runID] else { return }
            batchPath = iterationPath(base: batchBasePath, kind: "item", index: index, run: live)
            guard live.phase == .running || live.phase == .stepping else {
                interrupt()
                return
            }
            // Fresh item execution: reset every body unit except one
            // preserved in-flight unit waiting on an outstanding attempt
            // (its coordinate-deterministic attempt ID dedupes the
            // resubmission).
            let continuingItem = progress.activeItemIndex == index
            if !continuingItem {
                for bodyID in batch.bodyOrder {
                    resetNestedState(run: &live, parent: batchPath, nodeID: bodyID)
                    live.unitStatus[live.key(callPath: batchPath, nodeID: bodyID)] = .pending
                }
            }
            var frame = FlowVariableFrame(
                ownerNodeID: node.id,
                declarations: (compiled.variables.byOwner[node.id] ?? []))
            for variable in frame.declarations {
                frame.values[variable.name] = variable.initial ?? defaultValue(for: variable.dataType)
            }
            frame.values["item"] = item
            frame.values["itemIndex"] = .number(Double(index))
            var declarations = frame.declarations
            for implicit in ["item", "itemIndex"] {
                if declarations.contains(where: { $0.name == implicit }) == false {
                    declarations.append(FlowVariable(
                        name: implicit,
                        dataType: implicit == "item" ? .json : .number,
                        ownerNodeID: node.id))
                }
            }
            frame.declarations = declarations
            // A preserved re-entry still owns its item frame from the
            // previous pass: replace it rather than leaking a duplicate.
            if !continuingItem || !live.frames.contains(where: { $0.ownerNodeID == node.id }) {
                live.frames.append(frame)
            }
            progress.activeItemIndex = index
            live.batchProgress[batchBasePath] = progress
            runs[runID] = live

            await executeLevel(
                runID: runID,
                compiled: compiled,
                order: batch.bodyOrder,
                callPath: batchPath,
                exposed: [:],
                inner: inner,
                iterationIndex: index)

            guard var live = runs[runID] else { return }
            var itemFailed = false
            var itemIncomplete = false
            var failureError = "unknown"
            for bodyID in batch.bodyOrder {
                switch live.unitStatus[live.key(callPath: batchPath, nodeID: bodyID)] {
                case .failed(let error):
                    itemFailed = true
                    failureError = error
                case .pending, .running, .none:
                    itemIncomplete = true
                default:
                    continue
                }
            }
            if itemIncomplete {
                // Preserve body units suspended on outstanding host
                // attempts: the batch stays `.running` and the pump waits
                // for the callback/reconcile (attempt IDs are coordinate-
                // deterministic, so re-entry never duplicates paid items).
                var hasOutstanding = false
                for bodyID in batch.bodyOrder {
                    let key = live.key(callPath: batchPath, nodeID: bodyID)
                    guard case .running = live.unitStatus[key] else { continue }
                    let outstanding = live.attempts.values.contains {
                        $0.nodeID == bodyID && $0.callPath == batchPath
                            && ($0.status == .unknown || $0.status == .running
                                || $0.status == .submitted)
                    }
                    if outstanding {
                        hasOutstanding = true
                    } else {
                        live.unitStatus[key] = .pending
                    }
                }
                if hasOutstanding {
                    live.unitStatus[live.key(callPath: callPath, nodeID: node.id)] = .running
                    runs[runID] = live
                    return
                }
                interrupt()
                return
            }
            if itemFailed {
                // A batch absorbs per-item failures: the item is recorded
                // as failed without failing the whole run.
                live.failureCount = max(0, live.failureCount - 1)
                if live.failureCount == 0 { live.runFailure = nil }
                results.append(.json(.null))
                failures.append(.json(.object([
                    "index": .number("\(index)"),
                    "error": .string(failureError),
                ])))
            } else if let value = live.frames.last?.values[batch.collectVariable] {
                results.append(value)
            } else {
                results.append(.json(.null))
                failures.append(.json(.object([
                    "index": .number("\(index)"),
                    "error": .string("collectVariable '\(batch.collectVariable)' was not written"),
                ])))
            }

            // Advance persisted progress before moving to the next item.
            progress.results = results
            progress.failures = failures
            progress.nextItemIndex = index + 1
            progress.activeItemIndex = nil
            live.batchProgress[batchBasePath] = progress
            // Reset body states for the next item and pop the item frame.
            for bodyID in batch.bodyOrder {
                live.unitStatus[live.key(callPath: batchPath, nodeID: bodyID)] = .pending
            }
            if live.frames.last?.ownerNodeID == node.id {
                live.frames.removeLast()
            }
            runs[runID] = live
            emit(runID, .batchProgress(runID: runID, nodeID: node.id,
                                       completedItems: index + 1, totalItems: items.count))
            await checkpointIfDue(runID)
        }

        var outputs: [String: FlowValue] = ["results": .list(results)]
        if node.ports.contains(where: { $0.direction == .output && $0.name == "failures" }) {
            outputs["failures"] = .list(failures)
        }
        guard var live = runs[runID] else { return }
        // The batch completed: collected progress is no longer needed.
        live.batchProgress.removeValue(forKey: batchBasePath)
        runs[runID] = live
        let nodeKey = live.key(callPath: callPath, nodeID: node.id)
        try await finalizeUnit(runID: runID, nodeKey: nodeKey, nodeID: node.id,
                               generation: live.generation, outputs: outputs,
                               inputs: inputs)
    }

    // MARK: Level execution (loop/batch bodies and subgraph interiors)

    /// Deterministic sequential scheduler for one lexical level: a loop or
    /// batch body for one iteration/instance, or the interior of a subgraph
    /// instance. Returns when every unit in `order` is terminal, or early
    /// on failure / interruption (pause, cancel, breakpoint hit, step
    /// budget exhausted) — leaving non-terminal states for the owning
    /// composite to reset and re-enter deterministically.
    ///
    /// Breakpoints apply at real step boundaries inside bodies: the level
    /// stops before executing the marked unit, the owning composite resets
    /// to pending, and resuming re-enters at a deterministic point (attempt
    /// IDs are reproducible, so host dedupe prevents duplicate paid work).
    /// While stepping, each scheduled unit consumes the step budget and the
    /// level pauses when it is exhausted.
    private func executeLevel(
        runID: UUID,
        compiled: CompiledFlow,
        order: [UUID],
        callPath: String,
        exposed: [String: FlowValue],
        inner: Bool,
        iterationIndex: Int?
    ) async {
        while true {
            guard var run = runs[runID] else { return }
            guard run.phase == .running || run.phase == .stepping else { return }
            var startedAny = false
            var anyFailed = false
            for unitID in order {
                guard var live = runs[runID] else { return }
                let key = live.key(callPath: callPath, nodeID: unitID)
                guard case .pending = live.unitStatus[key] ?? .pending else {
                    if case .failed = live.unitStatus[key] ?? .pending { anyFailed = true }
                    continue
                }
                var unitExposed = exposed
                for input in live.configuration.runInputs where input.nodeID == unitID {
                    unitExposed[input.portName] = input.value
                }
                let readiness = self.readiness(
                    run: live,
                    compiled: compiled,
                    nodeID: unitID,
                    callPath: callPath,
                    exposedInputs: unitExposed)
                switch readiness {
                case .notReady:
                    continue
                case .skip(let reason):
                    markSkipped(&live, nodeKey: key, nodeID: unitID, reason: reason)
                    runs[runID] = live
                    emit(runID, .stepSkipped(runID: runID, nodeID: unitID, reason: reason))
                case .ready:
                    if live.breakpoints.contains(unitID), live.breakpointSkipOnce.remove(unitID) == nil {
                        live.pausedBreakpoint = unitID
                        live.phase = .paused
                        runs[runID] = live
                        emit(runID, .breakpointHit(runID: runID, nodeID: unitID))
                        return
                    }
                    if live.bypassed.contains(unitID) {
                        markSkipped(&live, nodeKey: key, nodeID: unitID, reason: "bypassed")
                        runs[runID] = live
                        emit(runID, .stepSkipped(runID: runID, nodeID: unitID, reason: "bypassed"))
                        continue
                    }
                    live.unitStatus[key] = .running
                    if live.phase == .stepping,
                       let unit = compiled.nodes[unitID],
                       unit.kind != .loop && unit.kind != .batch && unit.kind != .subgraph {
                        live.stepBudget = (live.stepBudget ?? 1) - 1
                    }
                    runs[runID] = live
                    startedAny = true
                    emit(runID, .stepScheduled(runID: runID, nodeID: unitID,
                                               attempt: 1, callPath: callPath))
                    await executeUnit(runID: runID, nodeID: unitID,
                                      callPath: callPath, iterationIndex: iterationIndex,
                                      compiled: compiled, exposed: unitExposed, inner: inner)
                    if let status = runs[runID]?.unitStatus[key], !status.isTerminal {
                        // Park the structured scope at the held unit; a
                        // sibling scope must not inherit its variable frame.
                        return
                    }
                    if let budget = runs[runID]?.stepBudget, budget <= 0,
                       runs[runID]?.phase == .stepping {
                        let allTerminal = order.allSatisfy { id in
                            guard let status = runs[runID]?.unitStatus[
                                runs[runID]!.key(callPath: callPath, nodeID: id)] else {
                                return false
                            }
                            return status.isTerminal
                        }
                        if !allTerminal {
                            runs[runID]?.phase = .paused
                            runs[runID]?.stepBudget = nil
                            emit(runID, .steppingPaused(runID: runID, completedNodeID: unitID))
                            emit(runID, .paused(runID: runID))
                            return
                        }
                    }
                }
            }
            run = runs[runID] ?? run
            for unitID in order {
                if case .failed = run.unitStatus[run.key(callPath: callPath, nodeID: unitID)] {
                    anyFailed = true
                }
            }
            if anyFailed { return }
            let anyActive = order.contains { unitID in
                guard let status = run.unitStatus[run.key(callPath: callPath, nodeID: unitID)] else {
                    return false
                }
                return !status.isTerminal
            }
            if !anyActive || !startedAny { return }
        }
    }

    // MARK: Subgraph nodes

    /// Execute one subgraph instance against its template definition.
    /// Nested structured composites (loop/batch/condition/subgraph) inside
    /// the template run under the same scheduler and debug semantics as
    /// top-level composites, at an isolated call path: instance variables,
    /// outputs and attempt IDs never leak between sibling instances.
    private func executeSubgraph(
        runID: UUID,
        node: FlowNode,
        callPath: String,
        compiled: CompiledFlow,
        iterationIndex: Int?
    ) async throws {
        guard var run = runs[runID] else { throw FlowRuntimeError.runNotFound(runID) }
        guard let templateID = referencedTemplateID(of: node),
              let template = subgraphTemplates[templateID] else {
            throw FlowRuntimeError.invalidRunConfiguration(
                "subgraph node \(node.id.uuidString) references a missing template")
        }
        if duplicateTemplateIDs.contains(templateID) {
            throw FlowRuntimeError.invalidRunConfiguration(
                "subgraph node \(node.id.uuidString) references an ambiguous template \(templateID.uuidString)")
        }
        let inner = try compiledTemplate(
            template, maxLoopIterations: run.configuration.maxLoopIterations)

        // Instance frame (run-level variables of the template graph).
        var frame = FlowVariableFrame(
            ownerNodeID: node.id,
            declarations: inner.variables.runLevel)
        for variable in inner.variables.runLevel {
            frame.values[variable.name] = variable.initial ?? defaultValue(for: variable.dataType)
        }
        // A preserved re-entry still owns its instance frame (it may hold
        // variable writes adopted before the interruption): keep it. Reset
        // paths pop the frame, so a fresh push happens only when unowned.
        if !run.frames.contains(where: { $0.ownerNodeID == node.id }) {
            run.frames.append(frame)
        }
        let instancePath = nestedCallPath(parent: callPath, nodeID: node.id, run: run)
        runs[runID] = run

        // Bind exposed inputs: edges into the subgraph node, run inputs and
        // explicit inputBindings operands (outer-scope evaluation).
        var exposed: [String: FlowValue] = [:]
        let outerRun = run
        for edge in compiled.incomingEdges[node.id] ?? [] {
            let sourceKey = outerRun.key(callPath: callPath, nodeID: edge.sourceNodeID)
            if case .succeeded(let outputs) = outerRun.unitStatus[sourceKey],
               let sourcePort = compiled.nodes[edge.sourceNodeID]?
                .ports.first(where: { $0.id == edge.sourcePortID }),
               let destPort = node.ports.first(where: { $0.id == edge.destinationPortID }),
               let value = outputs[sourcePort.name] {
                exposed[destPort.name] = value
            }
        }
        for input in outerRun.configuration.runInputs where input.nodeID == node.id {
            exposed[input.portName] = input.value
        }
        if let bindings = node.parameters["inputBindings"]?.flowObject {
            for portName in bindings.keys.sorted() {
                guard let operandJSON = bindings[portName] else { continue }
                let operand = try FlowLiterals.decodeFromJSON(operandJSON, as: FlowOperand.self)
                let value = try FlowEvaluation.resolve(
                    operand,
                    variables: outerRun.frames,
                    nodeOutputs: currentLevelOutputs(outerRun, callPath: callPath),
                    graphVariables: outerRun.graphVariables)
                exposed[portName] = value
            }
        }

        // Initialize inner unit states: fresh instances start fully
        // pending. A re-entered instance (controlled retry) re-arms failed
        // and skipped units — a skip may have been `upstreamFailed`, which
        // is no longer true after the retry — while succeeded units stay
        // adopted (attempt dedupe protects external work either way, and
        // readiness/skip propagation recomputes deterministically).
        guard var live = runs[runID] else { return }
        for unitID in inner.topoOrder {
            let key = live.key(callPath: instancePath, nodeID: unitID)
            switch live.unitStatus[key] {
            case .none, .failed, .skipped:
                live.unitStatus[key] = .pending
            case .running:
                // A re-entered instance may find an inner unit still marked
                // running: adopt a terminal result that arrived meanwhile,
                // re-arm when no attempt is outstanding, otherwise wait.
                refreshUnitStatus(run: &live, nodeID: unitID, callPath: instancePath,
                                  compiled: inner)
            case .pending, .succeeded:
                continue
            }
        }
        runs[runID] = live

        await executeLevel(
            runID: runID,
            compiled: inner,
            order: inner.topoOrder,
            callPath: instancePath,
            exposed: exposed,
            inner: true,
            iterationIndex: iterationIndex)

        guard var final = runs[runID] else { return }
        var innerIncomplete = false
        var innerFailure = false
        for unitID in inner.topoOrder {
            if let status = final.unitStatus[final.key(callPath: instancePath, nodeID: unitID)] {
                if !status.isTerminal { innerIncomplete = true }
                if case .failed = status { innerFailure = true }
            }
        }
        if final.phase != .running && final.phase != .stepping {
            // Paused, cancelled or a breakpoint hit mid-subgraph: reset for
            // a deterministic re-entry. Succeeded inner units are immutable
            // facts and are preserved — re-running them would resubmit paid
            // work; units suspended on outstanding attempts stay running so
            // the host callback can still adopt them.
            for unitID in inner.topoOrder {
                let key = final.key(callPath: instancePath, nodeID: unitID)
                switch final.unitStatus[key] {
                case .succeeded:
                    continue
                case .running:
                    let outstanding = final.attempts.values.contains {
                        $0.nodeID == unitID && $0.callPath == instancePath
                            && ($0.status == .unknown || $0.status == .running
                                || $0.status == .submitted)
                    }
                    final.unitStatus[key] = outstanding ? .running : .pending
                default:
                    final.unitStatus[key] = .pending
                }
            }
            final.unitStatus[final.key(callPath: callPath, nodeID: node.id)] = .pending
            runs[runID] = final
            return
        }
        if innerIncomplete {
            // The level returned with unfinished units while the run is
            // still active: units suspended on outstanding host attempts
            // (confirmed in-flight or unconfirmed) are preserved so the
            // host callback/reconcile can adopt them; this unit stays
            // `.running` and the pump waits, mirroring root-level unit
            // semantics. Re-entry after adoption re-arms via
            // `refreshUnitStatus` and continues at a deterministic point.
            var hasOutstanding = false
            for unitID in inner.topoOrder {
                let key = final.key(callPath: instancePath, nodeID: unitID)
                guard case .running = final.unitStatus[key] else { continue }
                let outstanding = final.attempts.values.contains {
                    $0.nodeID == unitID && $0.callPath == instancePath
                        && ($0.status == .unknown || $0.status == .running
                            || $0.status == .submitted)
                }
                if outstanding {
                    hasOutstanding = true
                } else {
                    final.unitStatus[key] = .pending
                }
            }
            if hasOutstanding {
                final.unitStatus[final.key(callPath: callPath, nodeID: node.id)] = .running
                runs[runID] = final
                return
            }
            // Nothing outstanding: deterministic re-entry; succeeded units
            // are still immutable facts and stay adopted.
            for unitID in inner.topoOrder {
                let key = final.key(callPath: instancePath, nodeID: unitID)
                if case .succeeded = final.unitStatus[key] { continue }
                final.unitStatus[key] = .pending
            }
            if final.frames.last?.ownerNodeID == node.id {
                final.frames.removeLast()
            }
            final.unitStatus[final.key(callPath: callPath, nodeID: node.id)] = .pending
            runs[runID] = final
            return
        }
        if innerFailure {
            if final.frames.last?.ownerNodeID == node.id {
                final.frames.removeLast()
            }
            runs[runID] = final
            throw FlowRuntimeError.invalidRunConfiguration(
                "subgraph instance '\(node.name)' (\(node.id.uuidString)) using template '\(template.name)' had a failed inner step")
        }

        // Collect inner `output` node results.
        var outputs: [String: FlowValue] = [:]
        for port in node.ports where port.direction == .output {
            outputs[port.name] = .json(.null)
        }
        for innerNode in inner.graph.nodes where innerNode.kind == .output {
            let key = final.key(callPath: instancePath, nodeID: innerNode.id)
            guard case .succeeded(let values) = final.unitStatus[key] else { continue }
            if let resultKey = innerNode.parameters["resultKey"]?.flowString {
                outputs[resultKey] = values[resultKey] ?? .json(.null)
            } else {
                for (name, value) in values { outputs[name] = value }
            }
        }
        if final.frames.last?.ownerNodeID == node.id {
            final.frames.removeLast()
        }
        runs[runID] = final
        let nodeKey = final.key(callPath: callPath, nodeID: node.id)
        try await finalizeUnit(runID: runID, nodeKey: nodeKey, nodeID: node.id,
                               generation: final.generation, outputs: outputs,
                               inputs: [:])
    }

    // MARK: Native / external step execution

    private func executeNative(
        runID: UUID,
        node: FlowNode,
        inputs: [String: FlowValue],
        callPath: String,
        iterationIndex: Int?
    ) async throws -> [String: FlowValue] {
        guard let handler = nativeRegistry.handler(for: nativeRegistry.key(for: node)) else {
            throw FlowRuntimeError.hostCapabilityUnavailable(
                "no native handler registered for '\(nativeRegistry.key(for: node))'")
        }
        guard var run = runs[runID] else { throw FlowRuntimeError.runNotFound(runID) }
        emit(runID, .stepStarted(runID: runID, nodeID: node.id, attempt: 1, external: false))
        var iterationVariables: [String: FlowValue] = [:]
        if let frame = run.frames.last {
            for (name, value) in frame.values { iterationVariables[name] = value }
        }
        let context = FlowNativeStepContext(node: node, inputs: inputs, iterationVariables: iterationVariables)
        let outputs = try await handler(context)
        try applyVariableWrites(run: &run, node: node, outputs: outputs)
        runs[runID] = run
        return outputs
    }

    private func applyVariableWrites(
        run: inout FlowRunState,
        node: FlowNode,
        outputs: [String: FlowValue]
    ) throws {
        guard let mapping = node.parameters["writeVariables"]?.flowObject else { return }
        for portName in mapping.keys.sorted() {
            guard let variableName = mapping[portName]?.flowString,
                  let value = outputs[portName] else { continue }
            // Innermost frame that declares the variable wins.
            var targetIndex: Int? = nil
            for index in stride(from: run.frames.count - 1, through: 0, by: -1) {
                if run.frames[index].declaration(of: variableName) != nil {
                    targetIndex = index
                    break
                }
            }
            guard let index = targetIndex else {
                throw FlowVariableError.undefinedVariable(variableName)
            }
            let declaration = run.frames[index].declaration(of: variableName)!
            guard FlowEvaluation.isCompatible(value, with: declaration.dataType) else {
                throw FlowVariableError.typeMismatch(
                    variable: variableName,
                    expected: declaration.dataType,
                    found: value.valueType)
            }
            run.frames[index].values[variableName] = value
        }
    }

    /// Input gathering implements the variadic aggregation contract:
    /// edges arrive in deterministic (sorted) order; a normal source
    /// contributes one projected item per edge; a variadic source port
    /// contributes all of its list elements (flattened). Variadic input
    /// ports always receive a `.list` (possibly empty); inert condition
    /// branches and failed/skipped variadic upstreams contribute nothing.
    private func gatherInputs(
        runID: UUID,
        compiled: CompiledFlow,
        node: FlowNode,
        callPath: String
    ) throws -> [String: FlowValue] {
        guard let run = runs[runID] else { throw FlowRuntimeError.runNotFound(runID) }
        var inputs: [String: FlowValue] = [:]
        let edges = compiled.incomingEdges[node.id] ?? []
        for port in node.ports where port.direction == .input {
            let portEdges = edges.filter { $0.destinationPortID == port.id }
                .filter { !isCarryEdge($0, compiled: compiled) }
            if port.isVariadic {
                var items: [FlowValue] = []
                for edge in portEdges {
                    let sourceKey = run.key(callPath: callPath, nodeID: edge.sourceNodeID)
                    if let chosen = run.conditionChoices[sourceKey],
                       let sourceNode = compiled.nodes[edge.sourceNodeID],
                       sourceNode.kind == .condition,
                       chosen != edge.sourcePortID {
                        continue // inert branch contributes nothing
                    }
                    guard case .succeeded(let outputs) = run.unitStatus[sourceKey],
                          let sourcePortName = portName(
                            compiled: compiled, nodeID: edge.sourceNodeID,
                            portID: edge.sourcePortID) else {
                        continue // failed/skipped variadic upstreams contribute nothing
                    }
                    let value = outputs[sourcePortName] ?? .json(.null)
                    let sourceVariadic = compiled.nodes[edge.sourceNodeID]?
                        .ports.first(where: { $0.id == edge.sourcePortID })?.isVariadic ?? false
                    if sourceVariadic, case .list(let elements) = value {
                        items.append(contentsOf: elements.map {
                            FlowEvaluation.project($0, to: port.dataType)
                        })
                    } else {
                        items.append(FlowEvaluation.project(value, to: port.dataType))
                    }
                }
                inputs[port.name] = .list(items)
            } else {
                guard let edge = portEdges.first else { continue }
                let sourceKey = run.key(callPath: callPath, nodeID: edge.sourceNodeID)
                if let chosen = run.conditionChoices[sourceKey],
                   let sourceNode = compiled.nodes[edge.sourceNodeID],
                   sourceNode.kind == .condition,
                   chosen != edge.sourcePortID {
                    continue
                }
                guard case .succeeded(let outputs) = run.unitStatus[sourceKey],
                      let sourcePortName = portName(
                        compiled: compiled, nodeID: edge.sourceNodeID,
                        portID: edge.sourcePortID) else {
                    continue
                }
                let value = outputs[sourcePortName] ?? .json(.null)
                inputs[port.name] = FlowEvaluation.project(value, to: port.dataType)
            }
        }
        for input in run.configuration.runInputs where input.nodeID == node.id {
            inputs[input.portName] = input.value
        }
        return inputs
    }

    private func executeExternal(
        runID: UUID,
        node: FlowNode,
        inputs: [String: FlowValue],
        callPath: String,
        iterationIndex: Int?,
        generation: Int
    ) async throws {
        guard var run = runs[runID] else { throw FlowRuntimeError.runNotFound(runID) }
        // Lazily enforce host execution policy: submitting real external
        // script/API work requires the run identity to carry a real
        // environment AND host task ownership (never derived from node
        // parameters or invented labels). Local/deterministic nodes above
        // already ran fine without one. A missing configuration fails the
        // step honestly — the executor is never called and there is no
        // host-interpreter fallback.
        guard run.configuration.identity.environmentID.isEmpty == false else {
            throw FlowRuntimeError.environmentRequired(runID)
        }
        guard run.configuration.identity.owningTaskID != nil else {
            throw FlowRuntimeError.invalidRunConfiguration(
                "external step \(node.id.uuidString) requires a host owningTaskID in the run identity")
        }
        // Deterministic attempt numbering per execution coordinate
        // (node, call path, iteration): only TERMINAL prior attempts
        // advance the counter. An interrupted composite (pause, cancel,
        // unconfirmed submission) that re-executes a coordinate whose
        // attempt is still unresolved therefore regenerates the SAME
        // attempt ID, and the host's `(runID, attemptID)` dedupe prevents
        // duplicate paid work — the documented recovery contract. A
        // controlled retry after a terminal outcome mints the next number
        // and thus a genuinely new attempt.
        let coordinateAttempts = run.attempts.values.filter {
            $0.nodeID == node.id && $0.callPath == callPath
                && $0.iterationIndex == iterationIndex
        }
        let attemptNumber = (coordinateAttempts.filter { $0.terminalStatus }
            .map(\.attempt).max() ?? 0) + 1
        let attemptID = FlowDeterministicID.make(name:
            "\(runID.uuidString)|\(node.id.uuidString)|\(attemptNumber)|\(callPath)|\(iterationIndex ?? -1)")
        if let existing = run.attempts[attemptID], existing.terminalStatus {
            // Crash/restart reuse: adopt the recorded terminal result; the
            // host must never be asked to do the same work twice.
            try await adoptTerminalAttempt(runID: runID, node: node, record: existing,
                                           callPath: callPath, generation: generation)
            return
        }

        // Persist the immutable request BEFORE any submission.
        var record = FlowAttemptRecord(
            attemptID: attemptID,
            runID: runID,
            nodeID: node.id,
            attempt: attemptNumber,
            callPath: callPath,
            iterationIndex: iterationIndex,
            inputs: inputs)
        run.attempts[attemptID] = record
        runs[runID] = run
        try await journal?.persistAttempt(record)
        try? await journal?.appendJournal(runID: runID, entry: .attemptUpdated(record))

        guard let executor else {
            // Honest unavailable result: no executor injected, no fake work.
            record.status = .failed
            record.error = "stepExecutorUnavailable"
            record.updatedAt = Date()
            run.attempts[attemptID] = record
            runs[runID] = run
            try await journal?.persistAttempt(record)
        try? await journal?.appendJournal(runID: runID, entry: .attemptUpdated(record))
            runs[runID]?.unitStatus[run.key(callPath: callPath, nodeID: node.id)] = .failed(
                error: "stepExecutorUnavailable")
            runs[runID]?.failureCount += 1
            emit(runID, .stepFailed(runID: runID, nodeID: node.id, attempt: attemptNumber,
                                    error: "stepExecutorUnavailable"))
            return
        }

        let context = runtimeContext(run: run)
        let request = CanvasStepExecutionRequest(
            runIdentity: run.configuration.identity,
            attemptID: attemptID,
            node: node,
            inputs: inputs,
            resumeCheckpoint: FlowRunCheckpoint(
                runID: runID,
                completedStepIDs: completedNodeIDs(run: run, callPath: callPath),
                loopCounters: [:]),
            context: context)
        emit(runID, .stepStarted(runID: runID, nodeID: node.id,
                                 attempt: attemptNumber, external: true))

        let submission: CanvasStepQueryResult?
        do {
            submission = try await executor.submitStep(request)
        } catch {
            submission = nil
        }
        guard let currentRun = runs[runID] else { return }
        run = currentRun
        guard let result = submission else {
            record.status = .unknown
            record.updatedAt = Date()
            run.attempts[attemptID] = record
            run.pendingAttempts.insert(attemptID)
            runs[runID] = run
            try await journal?.persistAttempt(record)
        try? await journal?.appendJournal(runID: runID, entry: .attemptUpdated(record))
            emit(runID, .reconcileRequired(runID: runID, attemptID: attemptID, nodeID: node.id))
            return
        }

        switch result.status {
        case .succeeded, .failed, .cancelled:
            record.status = .init(result.status)
            record.outputs = result.outputs
            record.error = result.error
            record.hostTaskBinding = result.hostTaskBinding
            record.updatedAt = Date()
            run.attempts[attemptID] = record
            runs[runID] = run
            try await journal?.persistAttempt(record)
        try? await journal?.appendJournal(runID: runID, entry: .attemptUpdated(record))
            try await adoptTerminalAttempt(runID: runID, node: node, record: record,
                                           callPath: callPath, generation: generation)
        case .unknown:
            record.status = .unknown
            record.hostTaskBinding = result.hostTaskBinding
            record.updatedAt = Date()
            run.attempts[attemptID] = record
            run.pendingAttempts.insert(attemptID)
            runs[runID] = run
            try await journal?.persistAttempt(record)
        try? await journal?.appendJournal(runID: runID, entry: .attemptUpdated(record))
            emit(runID, .reconcileRequired(runID: runID, attemptID: attemptID, nodeID: node.id))
        case .queued, .running:
            record.status = .running
            record.hostTaskBinding = result.hostTaskBinding
            record.updatedAt = Date()
            run.attempts[attemptID] = record
            // Held by the host: track the in-flight coordinate WITHOUT a
            // continuation and return. The pump never suspends on external
            // work, so `startRun`/`resumeRun` return once scheduling is
            // accepted (held attempts stay `.running`, unconfirmed ones go
            // to `.waitingReconcile`) instead of blocking the caller for
            // the whole held task/flow. The runtime retains pump ownership
            // with generation fencing (see `cancel`, `adoptTerminalAttempt`
            // and the late-delivery fence in `externalStepDidFinish`).
            // Completion arrives via `externalStepDidFinish`/`reconcile`,
            // which adopt the result and pump again.
            run.inFlight[attemptID] = FlowRunState.InFlightStep(
                attemptID: attemptID,
                nodeKey: run.key(callPath: callPath, nodeID: node.id),
                generation: generation,
                continuation: nil)
            runs[runID] = run
            try await journal?.persistAttempt(record)
        try? await journal?.appendJournal(runID: runID, entry: .attemptUpdated(record))
        }
    }

    private func adoptTerminalAttempt(
        runID: UUID,
        node: FlowNode,
        record: FlowAttemptRecord,
        callPath: String,
        generation: Int
    ) async throws {
        guard var run = runs[runID] else { return }
        guard run.generation == generation else { return }
        let key = run.key(callPath: callPath, nodeID: node.id)
        // Idempotent adoption: a reconcile-driven adopt may already have
        // settled this unit (query-then-continue path); never double-record.
        if let current = run.unitStatus[key], current.isTerminal {
            run.attempts[record.attemptID] = record
            runs[runID] = run
            return
        }
        switch record.status {
        case .succeeded:
            run.unitStatus[key] = .succeeded(outputs: record.outputs)
            run.completedStepCount += 1
            run.attempts[record.attemptID] = record
            runs[runID] = run
            emit(runID, .stepCompleted(runID: runID, nodeID: node.id,
                                       attempt: record.attempt, outputs: record.outputs))
            appendRecordForNode(runID: runID, nodeID: node.id, status: .succeeded,
                                outputs: record.outputs, attempt: record.attempt)
        case .failed:
            run.unitStatus[key] = .failed(error: record.error ?? "failed")
            run.failureCount += 1
            run.attempts[record.attemptID] = record
            runs[runID] = run
            emit(runID, .stepFailed(runID: runID, nodeID: node.id,
                                    attempt: record.attempt, error: record.error ?? "failed"))
            appendRecordForNode(runID: runID, nodeID: node.id, status: .failed,
                                error: record.error ?? "failed", attempt: record.attempt)
        case .cancelled:
            run.unitStatus[key] = .skipped(reason: "cancelled")
            run.attempts[record.attemptID] = record
            runs[runID] = run
        default:
            runs[runID] = run
            return
        }
        if record.status == .succeeded {
            var mutable = runs[runID] ?? run
            try applyVariableWrites(run: &mutable, node: node, outputs: record.outputs)
            runs[runID] = mutable
        }
        await checkpointIfDue(runID)
    }

    private func completedNodeIDs(run: FlowRunState, callPath: String) -> [UUID] {
        run.unitStatus.compactMap { key, status in
            guard key.hasPrefix("\(callPath)#"), case .succeeded = status else { return nil }
            return UUID(uuidString: key.components(separatedBy: "#").last ?? "")
        }
    }

    private func appendRecordForNode(
        runID: UUID,
        nodeID: UUID,
        status: FlowStepStatus,
        outputs: [String: FlowValue] = [:],
        error: String? = nil,
        inputs: [String: FlowValue] = [:],
        attempt: Int = 1
    ) {
        guard var run = runs[runID] else { return }
        let record = FlowStepRecord(
            runID: runID,
            nodeID: nodeID,
            attempt: attempt,
            status: status,
            inputs: inputs,
            outputs: outputs,
            error: error,
            startedAt: Date(),
            finishedAt: Date())
        run.stepRecords.append(record)
        runs[runID] = run
    }

    private func finalize(_ runID: UUID) async {
        guard var run = runs[runID] else { return }
        let anyFailed = run.failureCount > 0
        run.phase = anyFailed ? .failed : .completed
        if anyFailed, run.runFailure == nil {
            run.runFailure = "one or more steps failed"
        }
        runs[runID] = run
        try? await journal?.writeManifest(.init(
            identity: run.configuration.identity,
            graphDigest: run.compiled.graphDigest,
            configurationDigest: run.configuration.configurationDigest,
            revisionKeyDigest: flowRevisionKeyDigest(run.revisionKey),
            definitionsDigest: run.definitionsDigest,
            phase: run.phase,
            createdAt: run.configuration.identity.startedAt,
            updatedAt: Date()))
        emit(runID, .runFinished(runID: runID, phase: run.phase), terminal: true)
        await checkpoint(runID)
    }

    // MARK: Checkpoints

    private func flowRevisionKeyDigest(_ key: FlowRevisionKey) -> String {
        (try? FlowDigest.of(key)) ?? key.graphDigest
    }

    private func checkpointIfDue(_ runID: UUID) async {
        guard let run = runs[runID], run.configuration.checkpointEverySteps > 0 else { return }
        if run.completedStepCount % max(1, run.configuration.checkpointEverySteps) == 0 {
            await checkpoint(runID)
        }
    }

    /// Persist the run snapshot. A journal write failure is surfaced
    /// truthfully: `checkpointSaved` is NEVER emitted for a failed write, a
    /// non-terminal run transitions to `.failed` so no further work is
    /// scheduled as though the state were recoverable, and the already
    /// submitted attempts stay durable (per-attempt files were fsynced before
    /// submission) for later reconcile/adoption. The failure never claims
    /// provider cancellation — host work is left untouched.
    private func checkpoint(_ runID: UUID) async {
        guard let run = runs[runID], let journal else { return }
        var nodeStates: [String: FlowRunStateSnapshot.NodeState] = [:]
        for (key, status) in run.unitStatus {
            switch status {
            case .pending:
                nodeStates[key] = .init(kind: .pending, outputs: [:], attempt: 1)
            case .running:
                nodeStates[key] = .init(kind: .running, outputs: [:], attempt: 1)
            case .succeeded(let outputs):
                nodeStates[key] = .init(kind: .succeeded, outputs: outputs, attempt: 1)
            case .failed(let error):
                nodeStates[key] = .init(kind: .failed, outputs: [:], error: error, attempt: 1)
            case .skipped(let reason):
                nodeStates[key] = .init(kind: .skipped, outputs: [:], attempt: 1, skipReason: reason)
            }
        }
        let snapshot = FlowRunStateSnapshot(
            identity: run.configuration.identity,
            graphDigest: run.compiled.graphDigest,
            configurationDigest: run.configuration.configurationDigest,
            revisionKeyDigest: flowRevisionKeyDigest(run.revisionKey),
            phase: run.phase,
            generation: run.generation,
            frames: run.frames.map {
                .init(ownerNodeID: $0.ownerNodeID, declarations: $0.declarations, values: $0.values)
            },
            nodeStates: nodeStates,
            stepRecords: run.stepRecords,
            loopCounters: run.loopCounters,
            batchProgress: run.batchProgress,
            pendingAttempts: run.pendingAttempts.compactMap { run.attempts[$0] },
            breakpoints: Array(run.breakpoints).sorted { $0.uuidString < $1.uuidString },
            bypassed: Array(run.bypassed).sorted { $0.uuidString < $1.uuidString },
            completedStepCount: run.completedStepCount,
            runOutputs: run.runOutputs,
            updatedAt: Date())
        do {
            try await journal.saveCheckpoint(snapshot)
            emit(runID, .checkpointSaved(runID: runID))
        } catch {
            await handleCheckpointFailure(runID: runID, error: error)
        }
    }

    /// Honest recovery boundary for a durable-checkpoint write failure.
    private func handleCheckpointFailure(runID: UUID, error: Error) async {
        guard var run = runs[runID] else { return }
        let message = describe(error)
        guard run.checkpointFailure == nil else { return }
        run.checkpointFailure = message
        let alreadyTerminal = run.phase == .completed || run.phase == .failed
            || run.phase == .cancelled
        if alreadyTerminal {
            // The run outcome stands (it was already persisted before this
            // best-effort checkpoint); only the durability failed. Report it
            // without altering the terminal phase.
            runs[runID] = run
            emit(runID, .checkpointFailed(runID: runID, error: message))
            return
        }
        // The run can no longer prove recoverable state: stop scheduling new
        // work immediately. Submitted attempts remain on disk for a later
        // resumeRun to query/adopt; the host is NOT asked to cancel anything.
        run.phase = .failed
        if run.runFailure == nil { run.runFailure = message }
        runs[runID] = run
        emit(runID, .checkpointFailed(runID: runID, error: message))
        try? await journal?.writeManifest(.init(
            identity: run.configuration.identity,
            graphDigest: run.compiled.graphDigest,
            configurationDigest: run.configuration.configurationDigest,
            revisionKeyDigest: flowRevisionKeyDigest(run.revisionKey),
            definitionsDigest: run.definitionsDigest,
            phase: run.phase,
            createdAt: run.configuration.identity.startedAt,
            updatedAt: Date()))
        emit(runID, .runFinished(runID: runID, phase: .failed), terminal: true)
    }

    private func defaultValue(for type: FlowValueType) -> FlowValue {
        switch type {
        case .string: return .string("")
        case .number: return .number(0)
        case .bool: return .bool(false)
        case .list: return .list([])
        case .table: return .table(header: [], rows: [])
        case .asset: return .json(.null)
        case .json: return .json(.null)
        }
    }
}

private extension FlowAttemptRecord {
    var terminalStatus: Bool {
        switch status {
        case .succeeded, .failed, .cancelled: return true
        case .persisted, .submitted, .running, .unknown: return false
        }
    }
}

private extension FlowAttemptRecord.Status {
    init(_ status: CanvasStepQueryStatus) {
        switch status {
        case .queued: self = .submitted
        case .running: self = .running
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        case .unknown: self = .unknown
        }
    }
}

private extension FlowStepStatus {
    init(_ status: FlowAttemptRecord.Status) {
        switch status {
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        case .persisted, .submitted, .unknown: self = .queued
        case .running: self = .running
        }
    }
}

private extension CanvasStepQueryStatus {
    init(_ status: FlowAttemptRecord.Status) {
        switch status {
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        case .running: self = .running
        case .submitted: self = .queued
        case .unknown, .persisted: self = .unknown
        }
    }
}
