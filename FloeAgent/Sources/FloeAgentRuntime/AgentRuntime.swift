// FloeAgentRuntime — Agent state machine actor.
// See blazing-aurora-darwin.md §7. All transitions follow the mermaid
// diagram; cancellation never silently drops audit records:
//
//   cancel() → .cancelling → stream task cancelled (SSE terminates)
//   → in-flight tool receives CancellationToken → waitingApproval items
//     flush as .expired results → produced tool results land in audit
//   → checkpoint written → .checkpointed
//
// Recovery: .streamingModel/.executingTool checkpoint downgrades to
// .preparing; replay resumes from the last tool-result boundary and dedups
// tool calls via `idempotencyKey`.

import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity

/// Sink observing state transitions and normalized events. Implemented by
/// the UI layer (iOS) and by tests.
public protocol AgentEventSink: Sendable {
    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async
    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async
}

/// Abstraction over tool execution so tests can inject fakes without
/// registering concrete catalog tools.
public protocol ToolExecutor: Sendable {
    /// Executes one validated, approved tool call. Must honor cancellation
    /// through `context.cancellation`.
    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult
    /// Risk labels for a tool, from the catalog. Unknown tools return nil
    /// and are rejected before policy evaluation.
    func descriptor(named name: String) -> ToolCatalog.Descriptor?
}

/// Default executor bridging the compile-time catalog and the runtime
/// `ToolRunnerRegistry`. Tools whose descriptor exists but have no runner
/// registered still fail with a structured "No runner registered" result
/// so the runtime keeps flowing.
public struct CatalogToolExecutor: ToolExecutor {
    private let runners: ToolRunnerRegistry

    public init(runners: ToolRunnerRegistry = .shared) {
        self.runners = runners
    }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        ToolCatalog.descriptor(named: name)
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        guard let runner = runners.runner(named: call.toolName) else {
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "No runner registered for tool '\(call.toolName)'",
                outputDigest: ""
            )
        }
        do {
            let output = try await runner.execute(
                argumentsJSON: call.argumentsJSON,
                context: context
            )
            return ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: output.summary,
                outputDigest: output.fullOutputSHA256,
                exitStatus: output.exitStatus
            )
        } catch let error as FloeError where error == .cancelled {
            return ToolResult(callID: call.id, status: .cancelled, outputSummary: "Cancelled", outputDigest: "")
        } catch is CancellationError {
            return ToolResult(callID: call.id, status: .cancelled, outputSummary: "Cancelled", outputDigest: "")
        } catch {
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "Execution error: \(error.localizedDescription)",
                outputDigest: ""
            )
        }
    }
}

/// Abstraction over audit persistence (AuditChain actor in production).
public protocol AuditSink: Sendable {
    func record(_ entry: AuditEntry) async throws
}

/// Checkpoint persistence abstraction.
public protocol CheckpointStore: Sendable {
    func save(_ checkpoint: AgentCheckpoint) async throws
    func load(runID: UUID) async throws -> AgentCheckpoint?
}

/// Filesystem-backed checkpoint store (Application Support on iOS).
public actor FileCheckpointStore: CheckpointStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ checkpoint: AgentCheckpoint) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(checkpoint.runID.uuidString).checkpoint.json")
        try checkpoint.encoded().write(to: url, options: .atomic)
    }

    public func load(runID: UUID) throws -> AgentCheckpoint? {
        let url = directory.appendingPathComponent("\(runID.uuidString).checkpoint.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AgentCheckpoint.decoded(from: Data(contentsOf: url))
    }
}

/// The agent runtime. One instance per run.
public actor FloeAgentRuntime {

    // MARK: Configuration

    public struct Configuration: Sendable {
        public var conversationID: UUID
        public var provider: ProviderProfile
        public var model: ModelProfile
        /// Pause timeout before automatic checkpoint.
        public var pauseTimeout: TimeInterval
        /// Maximum tool executions per run. The only reliable defense
        /// against an infinite tool-request loop; exceeding it fails the
        /// run as recoverable (see ARCHITECTURE_EXECUTION.md §3.3).
        public var maxToolSteps: Int

        public init(
            conversationID: UUID = UUID(),
            provider: ProviderProfile,
            model: ModelProfile,
            pauseTimeout: TimeInterval = 300,
            maxToolSteps: Int = 32
        ) {
            self.conversationID = conversationID
            self.provider = provider
            self.model = model
            self.pauseTimeout = pauseTimeout
            self.maxToolSteps = maxToolSteps
        }
    }

    // MARK: State

    public private(set) var state: AgentState = .idle
    public let runID: UUID

    private let configuration: Configuration
    private let adapter: any ProviderAdapter
    private let policy: any ApprovalPolicy
    private let gate: CatastrophicActionGate?
    private let executor: any ToolExecutor
    private let credentials: ProviderCredentials
    private let auditSink: (any AuditSink)?
    private let checkpointStore: (any CheckpointStore)?
    private let sink: (any AgentEventSink)?

    private var messages: [ConversationMessage] = []
    private var pendingToolCalls: [ToolCall] = []
    private var pendingToolResults: [ToolResult] = []
    private var grants: [ApprovalGrant] = []
    private var executedIdempotencyKeys: Set<String> = []
    private var totalInputTokens = 0
    private var totalOutputTokens = 0
    private var streamText = ""
    private var streamTextByteCount = 0
    private var providerEventCount = 0
    private var providerPayloadBytes = 0
    /// Tool executions so far in this run (bounded by
    /// `Configuration.maxToolSteps`).
    private var toolStepCount = 0

    private var streamTask: Task<Void, Never>?
    private var cancellationToken = CancellationToken()
    private var pauseTask: Task<Void, Never>?
    /// Continuation resumed when a human decision arrives for the pending
    /// approval.
    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?

    public init(
        configuration: Configuration,
        adapter: any ProviderAdapter,
        policy: any ApprovalPolicy,
        executor: any ToolExecutor,
        credentials: ProviderCredentials = ProviderCredentials(),
        gate: CatastrophicActionGate? = nil,
        auditSink: (any AuditSink)? = nil,
        checkpointStore: (any CheckpointStore)? = nil,
        sink: (any AgentEventSink)? = nil,
        runID: UUID = UUID()
    ) {
        self.configuration = configuration
        self.adapter = adapter
        self.policy = policy
        self.executor = executor
        self.credentials = credentials
        self.gate = gate
        self.auditSink = auditSink
        self.checkpointStore = checkpointStore
        self.sink = sink
        self.runID = runID
    }

    // MARK: Transitions

    private func transition(to newState: AgentState) async {
        state = newState
        await sink?.agentRuntime(self, didTransitionTo: newState)
    }

    private func emit(_ event: AgentEvent) async {
        await sink?.agentRuntime(self, didEmit: event)
    }

    // MARK: Public API

    /// Prepends a system message to the conversation context. Called by
    /// ConversationRunService before `start` with the run context
    /// (workspace / selected file / execution target / available tools).
    /// Legal only while idle so the injection stays ahead of the user goal.
    public func injectSystemContext(_ content: String) async {
        guard case .idle = state, !content.isEmpty else { return }
        messages.insert(ConversationMessage(role: "system", content: content), at: 0)
    }

    /// idle → preparing → streamingModel …
    public func start(goal: String) async throws {
        guard case .idle = state else {
            throw FloeError.invalidConfiguration("start(goal:) requires idle state, currently \(state.name)")
        }
        messages.append(ConversationMessage(role: "user", content: goal))
        await transition(to: .preparing(AgentState.PreparingInfo(goal: goal)))
        await runModelTurn()
    }

    /// streamingModel/executingTool/waitingApproval → cancelling → checkpointed.
    public func cancel() async {
        let prior = state
        switch prior {
        case .idle, .completed, .failed, .checkpointed, .cancelling:
            return
        default:
            break
        }
        await transition(to: .cancelling)
        // 1. Stop the model stream (URLSessionTask cancel → SSE terminates).
        streamTask?.cancel()
        streamTask = nil
        // 2. Stop the in-flight tool cooperatively.
        cancellationToken.cancel()
        // 3. Expire any pending approval and audit it.
        if let continuation = approvalContinuation {
            approvalContinuation = nil
            continuation.resume(returning: .deny(reason: "cancelled"))
        }
        if case .waitingApproval(let waiting) = prior {
            let expired = ToolResult(
                callID: waiting.toolCall.id,
                status: .expired,
                outputSummary: "Approval expired due to cancellation",
                outputDigest: ""
            )
            await audit(toolCall: waiting.toolCall, result: expired, decision: "deny:cancelled")
        }
        pauseTask?.cancel()
        pauseTask = nil
        // 4. Persist and park.
        do {
            try await writeCheckpoint()
            await transition(to: .checkpointed(AgentState.CheckpointRef()))
        } catch {
            await transition(to: .failed(AgentState.AgentFailure(
                message: "Checkpoint write failed during cancel: \(error.localizedDescription)"
            )))
        }
    }

    /// streamingModel → paused. paused → streamingModel via `resumeFromPause`.
    public func pause() async {
        guard case .streamingModel = state else { return }
        let timeoutAt = Date().addingTimeInterval(configuration.pauseTimeout)
        await transition(to: .paused(AgentState.PausedInfo(timeoutAt: timeoutAt)))
        streamTask?.cancel()
        streamTask = nil
        // Auto-checkpoint when the pause budget expires.
        let pauseTimeout = configuration.pauseTimeout
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(pauseTimeout))
            guard !Task.isCancelled, let self else { return }
            await self.checkpointFromPause()
        }
    }

    /// paused → streamingModel (via preparing replay).
    public func resumeFromPause() async {
        guard case .paused = state else { return }
        pauseTask?.cancel()
        pauseTask = nil
        await transition(to: .preparing(AgentState.PreparingInfo(
            goal: messages.last(where: { $0.role == "user" })?.content ?? "",
            resumedFromCheckpoint: false
        )))
        await runModelTurn()
    }

    private func checkpointFromPause() async {
        guard case .paused = state else { return }
        do {
            try await writeCheckpoint()
            await transition(to: .checkpointed(AgentState.CheckpointRef()))
        } catch {
            await transition(to: .failed(AgentState.AgentFailure(
                message: "Checkpoint write failed: \(error.localizedDescription)"
            )))
        }
    }

    /// Persists the current run. Legal from streamingModel, executingTool,
    /// waitingApproval, paused. streamingModel/executingTool downgrade to
    /// preparing on disk (replay boundary).
    public func checkpoint() async throws {
        try await writeCheckpoint()
        await transition(to: .checkpointed(AgentState.CheckpointRef()))
    }

    /// checkpointed → preparing. Replays messages; dedups tool calls via
    /// idempotency keys.
    public func resume(from checkpoint: AgentCheckpoint) async throws {
        guard checkpoint.formatVersion <= AgentCheckpoint.currentFormatVersion else {
            throw FloeError.validationFailed("Unsupported checkpoint format v\(checkpoint.formatVersion)")
        }
        messages = checkpoint.messages
        pendingToolCalls = checkpoint.pendingToolCalls
        pendingToolResults = checkpoint.pendingToolResults
        grants = checkpoint.approvals
        executedIdempotencyKeys = checkpoint.idempotencyKeys
        let goal = messages.last(where: { $0.role == "user" })?.content ?? ""
        await transition(to: .preparing(AgentState.PreparingInfo(goal: goal, resumedFromCheckpoint: true)))
        await runModelTurn()
    }

    /// Human decision arriving for a `.waitingApproval` tool call.
    /// waitingApproval → executingTool (allow) or → streamingModel (deny,
    /// result injected back into the model context).
    public func resolveApproval(_ decision: ApprovalDecision) async {
        guard case .waitingApproval = state else { return }
        if let continuation = approvalContinuation {
            approvalContinuation = nil
            continuation.resume(returning: decision)
        }
    }

    // MARK: Core loop

    /// preparing → streamingModel; consumes the provider stream.
    private func runModelTurn() async {
        let streamInfo = AgentState.StreamingInfo(modelRemoteID: configuration.model.remoteModelID)
        await transition(to: .streamingModel(streamInfo))
        streamText = ""
        streamTextByteCount = 0

        let supportsTools = configuration.model.capabilities.contains(.tools)
        let request = ProviderStreamRequest(
            provider: configuration.provider,
            model: configuration.model,
            messages: messages.map { (role: $0.role, content: $0.content) },
            toolResults: pendingToolResults.map {
                (callID: $0.callID, output: $0.outputSummary)
            },
            pendingToolCalls: supportsTools ? pendingToolCalls : [],
            toolSchemas: supportsTools ? ToolCatalog.allDescriptors.map {
                ToolSchemaDescriptor(
                    name: $0.name,
                    description: $0.toolDescription,
                    parametersJSON: $0.parametersJSON
                )
            } : []
        )
        pendingToolResults.removeAll(keepingCapacity: true)
        pendingToolCalls.removeAll(keepingCapacity: true)

        let stream = adapter.stream(request: request, credentials: credentials)
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    await self.handleStreamEvent(event)
                    let currentState = await self.state
                    switch currentState {
                    case .streamingModel, .compacting:
                        continue
                    default:
                        // Tool flow (possibly with approval wait) takes over
                        // the loop inside handleStreamEvent.
                        return
                    }
                }
                // Stream ended without an explicit completion event.
                let finalState = await self.state
                if case .streamingModel = finalState {
                    await self.completeRun(stopReason: .endTurn)
                }
            } catch is CancellationError {
                // cancel() owns the terminal transition.
            } catch {
                let normalized = AgentEvent.NormalizedError(
                    kind: .network,
                    providerMessage: error.localizedDescription
                )
                await self.emit(.error(normalized))
                await self.failRun(message: error.localizedDescription, recoverable: true)
            }
        }
        await streamTask?.value
    }

    private func handleStreamEvent(_ event: AgentEvent) async {
        // Never mutate after leaving streamingModel (cancel race safety).
        guard case .streamingModel(var info) = state else { return }

        providerEventCount += 1
        providerPayloadBytes += Self.payloadSize(of: event)
        guard providerEventCount <= 20_000,
              providerPayloadBytes <= 16 * 1_024 * 1_024 else {
            await failRun(
                message: "Provider stream exceeded the per-run event limit",
                recoverable: false
            )
            return
        }

        await emit(event)
        switch event {
        case .textDelta(let delta):
            let nextBytes = delta.text.utf8.count
            let limit = max(
                65_536,
                min(8 * 1_024 * 1_024, configuration.model.limits.maxOutputTokens * 16)
            )
            guard nextBytes <= limit - streamTextByteCount else {
                await failRun(
                    message: "Provider output exceeded the configured response limit",
                    recoverable: false
                )
                return
            }
            streamText += delta.text
            streamTextByteCount += nextBytes
            info.textSoFar = streamText
            state = .streamingModel(info)

        case .reasoningSummary:
            break

        case .usage(let report):
            totalInputTokens = report.inputTokens
            totalOutputTokens = report.outputTokens

        case .toolRequest(let call):
            let scoped = call.withIDContext(runID: runID)
            await handleToolRequest(scoped)

        case .toolResult:
            break // Providers never emit tool results; runtime owns them.

        case .error(let error):
            switch error.kind {
            case .contextOverflow:
                // streamingModel → compacting → streamingModel.
                await transition(to: .compacting)
                compactHistory()
                await transition(to: .streamingModel(info))
            case .cancelled:
                break // cancel() owns the transition.
            case .rateLimited, .server, .network:
                await failRun(message: error.providerMessage, recoverable: true)
            case .auth, .malformed:
                await failRun(message: error.providerMessage, recoverable: false)
            }

        case .completed(let completion):
            await completeRun(stopReason: completion.stopReason)
        }
    }

    /// streamingModel → executingTool | waitingApproval → streamingModel.
    private func handleToolRequest(_ call: ToolCall) async {
        // Anti-loop guard: count every tool request, including rejected or
        // failed ones — a model that keeps re-requesting after failures
        // must still hit the ceiling. Exceeding it fails the run as
        // recoverable instead of re-entering the model stream.
        toolStepCount += 1
        guard toolStepCount <= configuration.maxToolSteps else {
            await failRun(
                message: "Exceeded max tool steps (\(configuration.maxToolSteps))",
                recoverable: true
            )
            return
        }

        guard let descriptor = executor.descriptor(named: call.toolName) else {
            let result = ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "Unknown tool '\(call.toolName)' — not in catalog",
                outputDigest: ""
            )
            await audit(toolCall: call, result: result, decision: "deny:not-in-catalog")
            await resumeStream(with: result)
            return
        }


        let remoteRiskLabels: Set<RiskLabel> = [
            .executesRemoteCommand,
            .modifiesRemoteSystem,
            .controlsGUI
        ]
        if !descriptor.riskLabels.isDisjoint(with: remoteRiskLabels), case .local = call.scope {
            let result = ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Remote tool call is missing a valid hostID scope",
                outputDigest: ""
            )
            await audit(toolCall: call, result: result, decision: "deny:missing-remote-scope")
            await resumeStream(with: result)
            return
        }

        let action = ProposedAction(
            toolCall: call,
            riskLabels: Set(descriptor.riskLabels.map(\.rawValue)),
            userGoal: messages.last(where: { $0.role == "user" })?.content ?? "",
            hostAndPathScope: call.scope
        )

        // Catastrophic gate runs before every policy.
        if let gate, let command = extractCommandString(from: call) {
            let verdict = gate.evaluate(command: command)
            if verdict.stopped {
                let patternID = verdict.matchedPatternID ?? "gate"
                let result = ToolResult(
                    callID: call.id,
                    status: .denied,
                    outputSummary: "Stopped by catastrophic gate: \(verdict.reason ?? patternID)",
                    outputDigest: ""
                )
                await audit(toolCall: call, result: result, decision: "stopped:\(patternID)")
                await resumeStream(with: result)
                return
            }
        }

        let decision: ApprovalDecision
        if !descriptor.isSideEffecting {
            decision = .allow(
                scope: Self.approvalScope(for: call),
                expiresAt: nil
            )
        } else {
            do {
                decision = try await policy.decide(action)
            } catch {
                decision = .escalateToHuman(reason: "Policy error: \(error.localizedDescription)")
            }
        }

        switch decision {
        case .allow(let scope, let expiresAt):
            let grant = ApprovalGrant(scope: scope, expiresAt: expiresAt, policyName: policy.policyName)
            grants.append(grant)
            await executeApproved(call: call, grant: grant)

        case .deny(let reason):
            let result = ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Denied: \(reason)",
                outputDigest: ""
            )
            await audit(toolCall: call, result: result, decision: "deny:\(reason)")
            await resumeStream(with: result)

        case .escalateToHuman(let reason):
            await transition(to: .waitingApproval(AgentState.WaitingApproval(toolCall: call, reason: reason)))
            let humanDecision = await withCheckedContinuation {
                (continuation: CheckedContinuation<ApprovalDecision, Never>) in
                approvalContinuation = continuation
            }
            guard case .waitingApproval = state else { return } // cancelled meanwhile
            switch humanDecision {
            case .allow(let scope, let expiresAt):
                let grant = ApprovalGrant(scope: scope, expiresAt: expiresAt, policyName: "human")
                grants.append(grant)
                await executeApproved(call: call, grant: grant)
            case .deny(let denyReason):
                let result = ToolResult(
                    callID: call.id,
                    status: .denied,
                    outputSummary: "Denied by user: \(denyReason)",
                    outputDigest: ""
                )
                await audit(toolCall: call, result: result, decision: "deny:human:\(denyReason)")
                await resumeStream(with: result)
            case .escalateToHuman, .stopped:
                let result = ToolResult(
                    callID: call.id,
                    status: .denied,
                    outputSummary: "Approval not granted",
                    outputDigest: ""
                )
                await audit(toolCall: call, result: result, decision: "deny:unresolved")
                await resumeStream(with: result)
            }

        case .stopped(let gateReason):
            let result = ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Stopped: \(gateReason)",
                outputDigest: ""
            )
            await audit(toolCall: call, result: result, decision: "stopped:\(gateReason)")
            await resumeStream(with: result)
        }
    }

    /// executingTool → streamingModel. Executes one approved call, audits
    /// the result before it flows back, then starts the next model turn.
    private func executeApproved(call: ToolCall, grant: ApprovalGrant) async {
        guard !grant.isExpired(), Self.scopePermits(grant.scope, call: call) else {
            let result = ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Approval scope does not permit this tool call",
                outputDigest: ""
            )
            await audit(toolCall: call, result: result, decision: "deny:scope-mismatch-or-expired")
            await resumeStream(with: result)
            return
        }

        // Idempotency: never re-execute a key already executed in this run.
        if !call.idempotencyKey.isEmpty, executedIdempotencyKeys.contains(call.idempotencyKey) {
            await resumeStream(with: ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: "Skipped: duplicate idempotency key",
                outputDigest: ""
            ))
            return
        }

        await transition(to: .executingTool(AgentState.ExecutingInfo(toolCall: call)))

        let context = ToolContext(runID: runID, approvalGrantID: grant.id, cancellation: cancellationToken)
        let result: ToolResult
        do {
            result = try await executor.execute(call, context: context)
        } catch let error as FloeError where error == .cancelled {
            result = ToolResult(callID: call.id, status: .cancelled, outputSummary: "Cancelled", outputDigest: "")
        } catch is CancellationError {
            result = ToolResult(callID: call.id, status: .cancelled, outputSummary: "Cancelled", outputDigest: "")
        } catch {
            result = ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "Execution error: \(error.localizedDescription)",
                outputDigest: ""
            )
        }

        // Audit lands before the result flows back — cancellation must
        // never silently drop it.
        await audit(toolCall: call, result: result, decision: "allow:\(grant.policyName)")
        if !call.idempotencyKey.isEmpty {
            executedIdempotencyKeys.insert(call.idempotencyKey)
        }

        // If cancel() moved us to .cancelling while the tool ran, stop here.
        guard case .executingTool = state else { return }

        await emit(.toolResult(result))
        await resumeStream(with: result)
    }

    /// streamingModel ← toolResult: queues the result and starts the next
    /// model turn.
    private func resumeStream(with result: ToolResult) async {
        pendingToolResults.append(result)
        await transition(to: .streamingModel(AgentState.StreamingInfo(
            modelRemoteID: configuration.model.remoteModelID,
            textSoFar: streamText
        )))
        await runModelTurn()
    }

    // MARK: Terminal transitions

    private func completeRun(stopReason: AgentEvent.StopReason) async {
        if !streamText.isEmpty {
            messages.append(ConversationMessage(role: "assistant", content: streamText))
        }
        await transition(to: .completed(AgentState.CompletionInfo(
            stopReason: stopReason,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens
        )))
    }

    private func failRun(message: String, recoverable: Bool) async {
        await transition(to: .failed(AgentState.AgentFailure(
            message: message,
            isRecoverable: recoverable
        )))
    }

    // MARK: Compaction

    /// Naive M1 compaction: keep system messages and the last eight turns.
    /// Semantic summarization lands in M2.
    private func compactHistory() {
        let system = messages.filter { $0.role == "system" }
        let rest = messages.filter { $0.role != "system" }
        messages = system + rest.suffix(8)
    }

    // MARK: Checkpoint persistence

    private func writeCheckpoint() async throws {
        guard let checkpointStore else { return }
        // streamingModel/executingTool/cancelling downgrade to preparing on
        // disk (replay resumes from the last tool-result boundary).
        let persistedState: AgentState
        switch state {
        case .streamingModel, .executingTool, .cancelling:
            persistedState = .preparing(AgentState.PreparingInfo(
                goal: messages.last(where: { $0.role == "user" })?.content ?? ""
            ))
        default:
            persistedState = state
        }
        let checkpoint = AgentCheckpoint(
            runID: runID,
            conversationID: configuration.conversationID,
            state: persistedState,
            messages: messages,
            pendingToolCalls: pendingToolCalls,
            pendingToolResults: pendingToolResults,
            approvals: grants,
            idempotencyKeys: executedIdempotencyKeys
        )
        try await checkpointStore.save(checkpoint)
    }

    // MARK: Audit

    private func audit(toolCall: ToolCall, result: ToolResult, decision: String) async {
        guard let auditSink else { return }
        let entry = AuditEntry(
            sequence: 0, // recomputed by the chain actor
            runID: runID,
            modelRemoteID: configuration.model.remoteModelID,
            toolName: toolCall.toolName,
            target: describe(scope: toolCall.scope),
            policyUsed: policy.policyName,
            decision: decision,
            exitStatus: result.exitStatus,
            outputDigestSHA256: result.outputDigest,
            prevHashSHA256: "",
            entryHashSHA256: ""
        )
        try? await auditSink.record(entry)
    }

    private func describe(scope: ToolScope) -> String {
        switch scope {
        case .local: return "local"
        case .host(let id): return "host:\(id.uuidString)"
        case .hostPath(let id, let path): return "host:\(id.uuidString):\(path)"
        }
    }

    /// Best-effort extraction of a shell command string from tool arguments
    /// for gate evaluation.
    private func extractCommandString(from call: ToolCall) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any] else {
            return nil
        }
        for key in ["command", "cmd", "script", "shell"] {
            if let value = object[key] as? String { return value }
        }
        return nil
    }

    private static func approvalScope(for call: ToolCall) -> ApprovalScope {
        switch call.scope {
        case .local:
            return ApprovalScope(toolName: call.toolName, singleUse: true)
        case .host(let hostID):
            return ApprovalScope(toolName: call.toolName, hostID: hostID, singleUse: true)
        case .hostPath(let hostID, let path):
            return ApprovalScope(
                toolName: call.toolName,
                hostID: hostID,
                paths: [path],
                singleUse: true
            )
        }
    }

    private static func scopePermits(_ scope: ApprovalScope, call: ToolCall) -> Bool {
        guard scope.toolName == call.toolName else { return false }
        switch call.scope {
        case .local:
            return scope.hostID == nil && scope.paths.isEmpty
        case .host(let hostID):
            return scope.hostID == hostID && scope.paths.isEmpty
        case .hostPath(let hostID, let path):
            return scope.hostID == hostID && scope.paths.contains(path)
        }
    }

    private static func payloadSize(of event: AgentEvent) -> Int {
        switch event {
        case .textDelta(let delta):
            return delta.text.utf8.count
        case .reasoningSummary(let summary):
            return summary.text.utf8.count
        case .toolRequest(let call):
            return call.argumentsJSON.count + call.toolName.utf8.count
        case .toolResult(let result):
            return result.outputSummary.utf8.count
        case .usage:
            return 64
        case .error(let error):
            return error.providerMessage.utf8.count
        case .completed:
            return 64
        }
    }
}
