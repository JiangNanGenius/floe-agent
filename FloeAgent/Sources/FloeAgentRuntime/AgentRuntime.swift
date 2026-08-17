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
import Crypto

/// Sink observing state transitions and normalized events. Implemented by
/// the UI layer (iOS) and by tests.
public protocol AgentEventSink: Sendable {
    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async
    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async
    /// Called only after a complete assistant/model step and before a steer
    /// is inserted. Persistence uses it to seal the assistant message without
    /// falsely emitting a terminal event.
    func agentRuntime(_ runtime: FloeAgentRuntime, didCompleteAssistantStep text: String) async
    /// Called after the steer is durably part of the runtime's message list,
    /// immediately before the next provider request is constructed.
    func agentRuntime(_ runtime: FloeAgentRuntime, didConsumeSteer input: RuntimeSteerInput) async
}

public extension AgentEventSink {
    func agentRuntime(_ runtime: FloeAgentRuntime, didCompleteAssistantStep text: String) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime, didConsumeSteer input: RuntimeSteerInput) async {}
}

/// Input accepted for delivery at a safe model/tool step boundary.
public struct RuntimeSteerInput: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var content: String
    public var images: [ConversationImagePart]
    public var attachments: [AttachmentRef]
    public var createdAt: Date

    public init(
        id: UUID,
        content: String,
        images: [ConversationImagePart] = [],
        attachments: [AttachmentRef] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.images = images
        self.attachments = attachments
        self.createdAt = createdAt
    }
}

public enum RuntimeSteerAcceptance: Sendable, Hashable {
    case accepted
    case alreadyAccepted
    case rejected(reason: String)
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
                exitStatus: output.exitStatus,
                artifacts: output.artifacts
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
        /// Determines the hard capability contract for this run. Plan mode
        /// exposes and executes read-only tools only.
        public var conversationMode: ConversationMode
        /// Installed instruction skills selected for this activation.
        public var activeSkillIDs: Set<String>
        /// Tool ceiling after skill declarations, device compatibility and
        /// user grants are intersected. `nil` preserves legacy no-skill runs.
        public var allowedToolNames: Set<String>?
        /// Canonical task workspace, independent of the currently visible UI.
        public var workspaceRootURL: URL?
        /// Persisted task-relative file scope; empty means the full root.
        public var allowedWorkspacePaths: [String]
        /// Chat-only runs can disable the compiled catalog entirely.
        public var toolsEnabled: Bool
        /// Pause timeout before automatic checkpoint.
        public var pauseTimeout: TimeInterval
        /// Maximum parent iterations in the mobile activation budget. The
        /// runtime uses the shared Harness ledger and finishes with a
        /// tool-free summary when this value is exhausted.
        public var maxToolSteps: Int

        public init(
            conversationID: UUID = UUID(),
            provider: ProviderProfile,
            model: ModelProfile,
            conversationMode: ConversationMode = .chat,
            activeSkillIDs: Set<String> = [],
            allowedToolNames: Set<String>? = nil,
            workspaceRootURL: URL? = nil,
            allowedWorkspacePaths: [String] = [],
            toolsEnabled: Bool = true,
            pauseTimeout: TimeInterval = 300,
            maxToolSteps: Int = 90
        ) {
            self.conversationID = conversationID
            self.provider = provider
            self.model = model
            self.conversationMode = conversationMode
            self.activeSkillIDs = activeSkillIDs
            self.allowedToolNames = allowedToolNames
            self.workspaceRootURL = workspaceRootURL
            self.allowedWorkspacePaths = allowedWorkspacePaths
            self.toolsEnabled = toolsEnabled
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
    private let intelligenceStore: SQLiteIntelligenceStore?
    private let sink: (any AgentEventSink)?
    private let contextEngine: (any ContextEngine)?
    private let budgetLedger: HarnessBudgetLedger

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
    private var contextOverflowRecoveryCount = 0
    private var loopGuard = ToolLoopGuard()
    private var forcedStopReason: AgentEvent.StopReason?
    private var isFinalizingWithoutTools = false
    /// Set by tool/compaction handling to request another provider turn.
    /// The outer model loop consumes this flag; handlers never recursively
    /// enter `runModelTurn`, which keeps one owner for state transitions.
    private var modelTurnContinuationRequested = false
    /// User guidance waits here until the current model output and any tool
    /// request/result pair have reached a complete step boundary.
    private var pendingSteers: [RuntimeSteerInput] = []
    private var acceptedSteerIDs: Set<UUID> = []

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
        intelligenceStore: SQLiteIntelligenceStore? = nil,
        contextEngine: (any ContextEngine)? = nil,
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
        self.intelligenceStore = intelligenceStore
        self.contextEngine = contextEngine
        self.sink = sink
        self.runID = runID
        self.budgetLedger = HarnessBudgetLedger(
            rootRunID: runID,
            budgets: HarnessBudgets(
                maxParentIterations: max(1, configuration.maxToolSteps),
                maxChildIterations: 50,
                maxTotalIterations: max(1, configuration.maxToolSteps + 200),
                maxConcurrentChildren: 4
            )
        )
    }

    // MARK: Transitions

    private func transition(to newState: AgentState) async {
        guard state.name != newState.name else { return }
        guard Self.isLegalTransition(from: state, to: newState) else {
            await sink?.agentRuntime(self, didEmit: .error(.init(
                kind: .malformed,
                providerMessage: "Illegal runtime transition \(state.name) -> \(newState.name)"
            )))
            return
        }
        state = newState
        await sink?.agentRuntime(self, didTransitionTo: newState)
    }

    private static func isLegalTransition(from old: AgentState, to new: AgentState) -> Bool {
        switch (old.name, new.name) {
        case ("idle", "preparing"),
             ("preparing", "cancelling"),
             ("preparing", "checkpointed"),
             ("preparing", "streamingModel"),
             ("streamingModel", "executingTool"),
             ("streamingModel", "waitingApproval"),
             ("streamingModel", "compacting"),
             ("streamingModel", "paused"),
             ("streamingModel", "cancelling"),
             ("streamingModel", "completed"),
             ("streamingModel", "failed"),
             ("executingTool", "streamingModel"),
             ("executingTool", "cancelling"),
             ("executingTool", "completed"),
             ("executingTool", "failed"),
             ("waitingApproval", "executingTool"),
             ("waitingApproval", "streamingModel"),
             ("waitingApproval", "cancelling"),
             ("waitingApproval", "completed"),
             ("waitingApproval", "failed"),
             ("compacting", "streamingModel"),
             ("compacting", "failed"),
             ("paused", "preparing"),
             ("paused", "cancelling"),
             ("paused", "checkpointed"),
             ("paused", "failed"),
             ("checkpointed", "preparing"),
             ("streamingModel", "checkpointed"),
             ("executingTool", "checkpointed"),
             ("waitingApproval", "checkpointed"),
             ("cancelling", "checkpointed"),
             ("cancelling", "failed"),
             ("preparing", "failed"):
            true
        default:
            false
        }
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

    /// Seeds prior messages from the same durable task. This is deliberately
    /// separate from cross-conversation reference injection: these messages
    /// are the actual preceding turns of the current conversation.
    public func seedConversationHistory(_ history: [ConversationMessage]) async {
        guard case .idle = state else { return }
        messages.append(contentsOf: history.filter { message in
            guard message.role == "system" else { return true }
            // Only locally generated, explicitly data-only context survives.
            // Arbitrary historical system messages remain excluded so old
            // conversation text can never manufacture current authority.
            return message.content.hasPrefix("Historical summary for this task only.")
                || message.content.hasPrefix("Historical reference only;")
                || message.content.hasPrefix("Auxiliary visual analysis (untrusted evidence;")
                || message.content.hasPrefix("The user attached image evidence,")
                || message.content.hasPrefix("The configured auxiliary vision model")
        })
    }

    /// idle → preparing → streamingModel …
    public func start(goal: String, images: [ConversationImagePart] = []) async throws {
        guard case .idle = state else {
            throw FloeError.invalidConfiguration("start(goal:) requires idle state, currently \(state.name)")
        }
        messages.append(ConversationMessage(role: "user", content: goal, images: images))
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

    /// Writes a recovery point without changing the live state. Used by the
    /// app-level run coordinator while a stream remains active.
    public func persistRecoveryPoint() async throws {
        try await writeCheckpoint()
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
        toolStepCount = checkpoint.parentIterationCount ?? 0
        await budgetLedger.restore(
            parent: checkpoint.parentIterationCount ?? 0,
            total: checkpoint.totalIterationCount ?? checkpoint.parentIterationCount ?? 0
        )
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

    /// Registers guidance for the active run without interrupting a model
    /// stream or in-flight tool. `expectedRunID` prevents a UI race from
    /// steering a newer run after the displayed run changed.
    public func steer(
        _ input: RuntimeSteerInput,
        expectedRunID: UUID
    ) -> RuntimeSteerAcceptance {
        guard expectedRunID == runID else {
            return .rejected(reason: "The active run changed before guidance was delivered")
        }
        let trimmed = input.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(reason: "Guidance must not be empty") }
        if acceptedSteerIDs.contains(input.id) { return .alreadyAccepted }
        switch state {
        case .preparing, .streamingModel, .executingTool, .waitingApproval, .compacting, .paused:
            var normalized = input
            normalized.content = trimmed
            pendingSteers.append(normalized)
            acceptedSteerIDs.insert(input.id)
            return .accepted
        case .idle, .cancelling, .checkpointed, .completed, .failed:
            return .rejected(reason: "The target run is no longer accepting guidance")
        }
    }

    // MARK: Core loop

    /// preparing → streamingModel; consumes the provider stream.
    private func runModelTurn() async {
        repeat {
            modelTurnContinuationRequested = false
            await runSingleModelTurn()
        } while modelTurnContinuationRequested && !Self.isTerminalState(state)
    }

    /// Executes exactly one provider request. Tool handling can request a
    /// subsequent turn by setting `modelTurnContinuationRequested`; it must
    /// never call this method recursively.
    private func runSingleModelTurn() async {
        if !pendingSteers.isEmpty, !streamText.isEmpty {
            messages.append(ConversationMessage(role: "assistant", content: streamText))
            await sink?.agentRuntime(self, didCompleteAssistantStep: streamText)
        }
        await consumeSteersAtStepBoundary()
        // Sink callbacks perform durable persistence and therefore suspend.
        // A user cancel/pause can win during that suspension; never revive a
        // parked or terminal run by starting a provider request afterwards.
        switch state {
        case .cancelling, .paused, .checkpointed, .completed, .failed:
            return
        default:
            break
        }
        if let contextEngine {
            let latestUserID = messages.last(where: { $0.role == "user" })?.id
            let protection = ContextProtection(
                messageIDs: latestUserID.map { [$0] } ?? []
            )
            let request = ContextRequest(
                messages: messages,
                budget: ContextBudget(
                    contextWindowTokens: configuration.model.limits.contextTokens,
                    reservedOutputTokens: Self.contextOutputReservation(
                        limits: configuration.model.limits
                    )
                ),
                protection: protection
            )
            if let prepared = try? await contextEngine.prepareContext(for: request),
               let compaction = prepared.compaction {
                messages = prepared.messages
                let summary = prepared.messages.first(where: {
                    $0.role == "system" && $0.content.contains("Historical summary:")
                })?.content ?? ""
                try? await intelligenceStore?.saveCompaction(
                    runID: runID,
                    record: compaction,
                    summary: summary
                )
            }
        }
        let streamInfo = AgentState.StreamingInfo(modelRemoteID: configuration.model.remoteModelID)
        await transition(to: .streamingModel(streamInfo))
        streamText = ""
        streamTextByteCount = 0

        let supportsTools = configuration.toolsEnabled
            && configuration.model.capabilities.contains(.tools)
            && !isFinalizingWithoutTools
        var catalogDescriptors: [ToolCatalog.Descriptor]
        if configuration.conversationMode == .plan {
            catalogDescriptors = PlanToolPolicy().allowedDescriptors(from: ToolCatalog.allDescriptors)
        } else {
            catalogDescriptors = ToolCatalog.allDescriptors
        }
        let effectiveAllowedNames: Set<String>? = {
            if let configured = configuration.allowedToolNames { return configured }
            return configuration.activeSkillIDs.isEmpty ? nil : []
        }()
        if let effectiveAllowedNames {
            catalogDescriptors.removeAll { !effectiveAllowedNames.contains($0.name) }
        }
        var legacyMessages = messages.map { (role: $0.role, content: $0.content) }
        var contentMessages = messages.map { message in
            var parts: [ProviderContentPart] = [.text(message.content)]
            if configuration.model.capabilities.contains(.vision) {
                parts += message.images.map {
                    .imageData(mimeType: $0.mimeType, base64: $0.base64)
                }
            }
            return ProviderMessage(role: message.role, content: parts)
        }
        // Hermes-style budget pressure is ephemeral: it guides this provider
        // request but never pollutes durable conversation history.
        let iterationSnapshot = await budgetLedger.snapshot()
        let remainingIterations = max(0, configuration.maxToolSteps - iterationSnapshot.parent)
        let pressure: String? = if !isFinalizingWithoutTools && remainingIterations <= 3 {
            "Harness control: only \(remainingIterations) tool iterations remain. Return the final answer now and do not call another tool unless it is strictly required to avoid an incorrect answer."
        } else if !isFinalizingWithoutTools && remainingIterations <= 10 {
            "Harness control: \(remainingIterations) tool iterations remain. Start wrapping up, consolidate evidence, and prepare a final answer."
        } else {
            nil
        }
        if let pressure {
            legacyMessages.append((role: "system", content: pressure))
            contentMessages.append(ProviderMessage(role: "system", content: [.text(pressure)]))
        }
        if configuration.model.capabilities.contains(.vision) {
            let evidence = pendingToolResults.flatMap(\.artifacts)
                .compactMap(Self.providerImageEvidence)
            if !evidence.isEmpty {
                contentMessages.append(ProviderMessage(
                    role: "user",
                    content: [.text("Visible browser evidence for the immediately preceding tool result.")] + evidence
                ))
            }
        }
        let request = ProviderStreamRequest(
            provider: configuration.provider,
            model: configuration.model,
            messages: legacyMessages,
            contentMessages: contentMessages,
            toolResults: pendingToolResults.map {
                (callID: $0.callID, output: $0.outputSummary)
            },
            pendingToolCalls: supportsTools ? pendingToolCalls : [],
            toolSchemas: supportsTools ? catalogDescriptors.map {
                ToolSchemaDescriptor(
                    name: $0.name,
                    description: $0.toolDescription,
                    parametersJSON: $0.parametersJSON
                )
            } + (configuration.conversationMode == .plan ? [
                ToolSchemaDescriptor(
                    name: PlanSubmission.toolName,
                    description: PlanSubmission.toolDescription,
                    parametersJSON: PlanSubmission.parametersJSON
                )
            ] : []) : []
        )
        pendingToolResults.removeAll(keepingCapacity: true)
        pendingToolCalls.removeAll(keepingCapacity: true)

        let stream = adapter.stream(request: request, credentials: credentials)
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    await self.handleStreamEvent(event)
                    if await self.modelTurnContinuationRequested { return }
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
                if case .streamingModel = finalState,
                   !(await self.modelTurnContinuationRequested) {
                    await self.finishOrSteer(stopReason: .endTurn)
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

    private static func providerImageEvidence(
        _ artifact: ToolArtifactReference
    ) -> ProviderContentPart? {
        guard artifact.mimeType == "image/jpeg" || artifact.mimeType == "image/png",
              artifact.byteCount > 0, artifact.byteCount <= 8 * 1024 * 1024,
              artifact.relativePath.hasPrefix("BrowserArtifacts/"),
              !artifact.relativePath.split(separator: "/").contains("..")
        else { return nil }
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
        let url = root.appendingPathComponent(artifact.relativePath)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count == artifact.byteCount else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256.lowercased() else { return nil }
        return .imageData(mimeType: artifact.mimeType, base64: data.base64EncodedString())
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

        // A provider completion is only terminal when no guidance is waiting.
        // Suppressing the terminal event here is essential: persistence must
        // not close the run before the steer is inserted.
        if case .completed(let completion) = event {
            await finishOrSteer(stopReason: forcedStopReason ?? completion.stopReason)
            return
        }

        await emit(event)
        switch event {
        case .textDelta(let delta):
            let nextBytes = delta.text.utf8.count
            let limit = configuration.model.limits.clientOutputSafetyBytes
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
            await contextEngine?.observeUsage(UsageSnapshot(
                inputTokens: report.inputTokens,
                outputTokens: report.outputTokens,
                modelCalls: 1,
                costEstimate: report.costEstimate
            ))

        case .toolRequest(let call):
            // A tool is executable only when the selected model is explicitly
            // configured for native structured calls. Text resembling a call
            // is handled by `.textDelta` and can never reach this branch.
            guard configuration.toolsEnabled,
                  configuration.model.capabilities.contains(.tools) else {
                await failRun(
                    message: "Provider emitted a structured tool call while native tools are disabled for this model",
                    recoverable: false
                )
                return
            }
            if isFinalizingWithoutTools {
                await finishOrSteer(stopReason: forcedStopReason ?? .budgetLimited)
                return
            }
            let scoped = call.withIDContext(runID: runID)
            await handleToolRequest(scoped)

        case .toolResult:
            break // Providers never emit tool results; runtime owns them.

        case .error(let error):
            switch error.kind {
            case .contextOverflow:
                guard contextOverflowRecoveryCount == 0 else {
                    await failRun(
                        message: "Context still exceeds the model limit after compaction",
                        recoverable: true
                    )
                    return
                }
                contextOverflowRecoveryCount += 1
                // streamingModel → compacting → one retry.
                await transition(to: .compacting)
                await compactHistory(force: true)
                modelTurnContinuationRequested = true
            case .cancelled:
                break // cancel() owns the transition.
            case .rateLimited, .server, .network:
                await failRun(message: error.providerMessage, recoverable: true)
            case .auth, .malformed:
                await failRun(message: error.providerMessage, recoverable: false)
            }

        case .completed:
            break // handled before generic event publication above
        }
    }

    /// Consumes every accepted steer in FIFO order immediately before a
    /// provider request. Each remains a distinct user message.
    private func consumeSteersAtStepBoundary() async {
        guard !pendingSteers.isEmpty else { return }
        let inputs = pendingSteers
        pendingSteers.removeAll(keepingCapacity: true)
        for input in inputs {
            messages.append(ConversationMessage(
                id: input.id,
                role: "user",
                content: input.content,
                createdAt: input.createdAt,
                images: input.images
            ))
            await sink?.agentRuntime(self, didConsumeSteer: input)
        }
    }

    /// Seals a complete assistant step, injects pending guidance, and keeps
    /// the same run alive. With no guidance it publishes the ordinary
    /// completion and transitions terminally.
    private func finishOrSteer(stopReason: AgentEvent.StopReason) async {
        guard !pendingSteers.isEmpty else {
            await emit(.completed(.init(stopReason: stopReason)))
            await completeRun(stopReason: stopReason)
            return
        }
        if !streamText.isEmpty {
            messages.append(ConversationMessage(role: "assistant", content: streamText))
            await sink?.agentRuntime(self, didCompleteAssistantStep: streamText)
        }
        await consumeSteersAtStepBoundary()
        modelTurnContinuationRequested = true
    }

    /// streamingModel → executingTool | waitingApproval → streamingModel.
    private func handleToolRequest(_ call: ToolCall) async {
        do {
            try await budgetLedger.reserveParentIteration()
            toolStepCount += 1
        } catch {
            pendingToolCalls.append(call)
            let exhausted = ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "The activation iteration budget is exhausted. Summarize the work completed, evidence collected, and any remaining limitations without calling more tools.",
                outputDigest: ""
            )
            await audit(toolCall: call, result: exhausted, decision: "deny:harness-budget")
            await emit(.toolResult(exhausted))
            await beginForcedFinalization(with: exhausted, stopReason: .budgetLimited)
            return
        }

        // The next provider turn must receive the assistant tool call and
        // its result as a pair. Chat Completions and Anthropic reject or
        // misinterpret an orphan tool-result message, which previously made
        // runs stop after a file write without a final assistant reply.
        pendingToolCalls.append(call)

        // `plan.submit` is an internal, run-scoped persistence hand-off. It is
        // deliberately not registered in the process-global tool registry:
        // concurrent conversations must never share a captured store or ID.
        if configuration.conversationMode == .plan,
           call.toolName == PlanSubmission.toolName {
            let result: ToolResult
            do {
                let submission = try JSONDecoder().decode(
                    PlanSubmission.self,
                    from: call.argumentsJSON
                )
                if submission.validationErrors.isEmpty {
                    result = ToolResult(
                        callID: call.id,
                        status: .ok,
                        outputSummary: "Plan submitted for user review. Briefly summarize it, then stop.",
                        outputDigest: ""
                    )
                } else {
                    result = ToolResult(
                        callID: call.id,
                        status: .failed,
                        outputSummary: "Plan is incomplete: \(submission.validationErrors.joined(separator: ", ")). Repair and submit again.",
                        outputDigest: ""
                    )
                }
            } catch {
                result = ToolResult(
                    callID: call.id,
                    status: .failed,
                    outputSummary: "Invalid plan.submit payload: \(error.localizedDescription)",
                    outputDigest: ""
                )
            }
            await resumeStream(with: result, after: call)
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
            await resumeStream(with: result, after: call)
            return
        }

        let effectiveAllowedNames: Set<String>?
        if let configured = configuration.allowedToolNames {
            effectiveAllowedNames = configured
        } else {
            effectiveAllowedNames = configuration.activeSkillIDs.isEmpty ? nil : []
        }
        if let effectiveAllowedNames, !effectiveAllowedNames.contains(call.toolName) {
            let result = ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Tool '\(call.toolName)' is outside the active skill capability set",
                outputDigest: ""
            )
            await audit(toolCall: call, result: result, decision: "deny:skill-capability")
            await resumeStream(with: result, after: call)
            return
        }

        if configuration.conversationMode == .plan,
           let denial = PlanToolPolicy().denialResult(call: call, descriptor: descriptor) {
            await audit(toolCall: call, result: denial, decision: "deny:plan-read-only")
            await resumeStream(with: denial, after: call)
            return
        }


        if descriptor.requiresHostScope, case .local = call.scope {
            let result = ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Remote tool call is missing a valid hostID scope",
                outputDigest: ""
            )
            await audit(toolCall: call, result: result, decision: "deny:missing-remote-scope")
            await resumeStream(with: result, after: call)
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
                await resumeStream(with: result, after: call)
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
            await resumeStream(with: result, after: call)

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
                await resumeStream(with: result, after: call)
            case .escalateToHuman, .stopped:
                let result = ToolResult(
                    callID: call.id,
                    status: .denied,
                    outputSummary: "Approval not granted",
                    outputDigest: ""
                )
                await audit(toolCall: call, result: result, decision: "deny:unresolved")
                await resumeStream(with: result, after: call)
            }

        case .stopped(let gateReason):
            let result = ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Stopped: \(gateReason)",
                outputDigest: ""
            )
            await audit(toolCall: call, result: result, decision: "stopped:\(gateReason)")
            await resumeStream(with: result, after: call)
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
            await resumeStream(with: result, after: call)
            return
        }

        // Idempotency: never re-execute a key already executed in this run.
        if !call.idempotencyKey.isEmpty, executedIdempotencyKeys.contains(call.idempotencyKey) {
            await resumeStream(with: ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: "Skipped: duplicate idempotency key",
                outputDigest: ""
            ), after: call)
            return
        }

        await transition(to: .executingTool(AgentState.ExecutingInfo(toolCall: call)))

        let context = ToolContext(
            runID: runID,
            approvalGrantID: grant.id,
            scope: call.scope,
            activeSkillIDs: configuration.activeSkillIDs,
            allowedToolNames: configuration.allowedToolNames,
            workspaceRootURL: configuration.workspaceRootURL,
            allowedWorkspacePaths: configuration.allowedWorkspacePaths,
            cancellation: cancellationToken
        )
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
        await resumeStream(with: result, after: call)
    }

    /// streamingModel ← toolResult: queues the result and starts the next
    /// model turn.
    private func resumeStream(with result: ToolResult, after call: ToolCall) async {
        pendingToolResults.append(result)
        if let guardrail = loopGuard.record(call: call, result: result) {
            if guardrail.shouldStop {
                await beginForcedFinalization(with: nil, stopReason: .noProgress)
                return
            }
            pendingToolResults[pendingToolResults.count - 1].outputSummary +=
                "\n\nHarness warning: \(guardrail.message)"
        }
        modelTurnContinuationRequested = true
    }

    private func beginForcedFinalization(
        with result: ToolResult?,
        stopReason: AgentEvent.StopReason
    ) async {
        if let result { pendingToolResults.append(result) }
        guard !isFinalizingWithoutTools else {
            await finishOrSteer(stopReason: stopReason)
            return
        }
        forcedStopReason = stopReason
        isFinalizingWithoutTools = true
        messages.append(ConversationMessage(
            role: "system",
            content: "Harness control: ordinary tools are now disabled because execution stopped making progress or reached its budget. Give one concise final answer describing completed work, evidence, failures, and the exact next user action if one is needed. Do not request another tool."
        ))
        modelTurnContinuationRequested = true
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

    private static func isTerminalState(_ state: AgentState) -> Bool {
        switch state {
        case .completed, .failed, .checkpointed:
            true
        default:
            false
        }
    }

    // MARK: Compaction

    /// Uses the injected hybrid context engine when available and falls back
    /// to a bounded recent tail if summarization is unavailable.
    private func compactHistory(force: Bool = false) async {
        if let contextEngine {
            let latestUserID = messages.last(where: { $0.role == "user" })?.id
            let request = CompactionRequest(
                context: ContextRequest(
                    messages: messages,
                    budget: ContextBudget(
                        contextWindowTokens: configuration.model.limits.contextTokens,
                        reservedOutputTokens: Self.contextOutputReservation(
                            limits: configuration.model.limits
                        )
                    ),
                    protection: ContextProtection(
                        messageIDs: latestUserID.map { [$0] } ?? []
                    )
                ),
                force: force
            )
            if let result = try? await contextEngine.compact(request) {
                messages = result.messages
                return
            }
        }
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
        var checkpointMessages = messages
        if !streamText.isEmpty {
            checkpointMessages.append(ConversationMessage(
                role: "assistant",
                content: streamText
            ))
        }
        let iterationSnapshot = await budgetLedger.snapshot()
        let checkpoint = AgentCheckpoint(
            runID: runID,
            conversationID: configuration.conversationID,
            state: persistedState,
            messages: checkpointMessages,
            pendingToolCalls: pendingToolCalls,
            pendingToolResults: pendingToolResults,
            approvals: grants,
            idempotencyKeys: executedIdempotencyKeys,
            conversationMode: configuration.conversationMode,
            parentIterationCount: iterationSnapshot.parent,
            totalIterationCount: iterationSnapshot.total
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

    private static func contextOutputReservation(limits: ModelLimits) -> Int {
        if let configured = limits.configuredMaxOutputTokens {
            return min(configured, max(1, limits.contextTokens / 2))
        }
        return min(4_096, max(512, limits.contextTokens / 4))
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

private struct ToolLoopGuardrailDecision {
    var shouldStop: Bool
    var message: String
}

/// Hermes-style per-user-turn guardrails. This deliberately compares
/// canonical arguments and observable results rather than call IDs, which
/// providers commonly regenerate on every retry.
private struct ToolLoopGuard {
    private var previousExactFingerprint: String?
    private var exactFailureCount = 0
    private var previousFailedTool: String?
    private var sameToolFailureCount = 0
    private var previousProgressFingerprint: String?
    private var idempotentNoProgressCount = 0

    mutating func record(
        call: ToolCall,
        result: ToolResult
    ) -> ToolLoopGuardrailDecision? {
        let arguments = Self.canonicalDigest(call.argumentsJSON)
        let observableOutput = result.outputDigest.isEmpty
            ? Self.digest(Data(result.outputSummary.utf8))
            : result.outputDigest.lowercased()
        let exact = "\(call.toolName)|\(arguments)|\(result.status.rawValue)|\(observableOutput)"
        let progress = "\(call.toolName)|\(arguments)|\(observableOutput)"
        let failed = result.status != .ok

        if failed, exact == previousExactFingerprint {
            exactFailureCount += 1
        } else {
            previousExactFingerprint = failed ? exact : nil
            exactFailureCount = failed ? 1 : 0
        }

        if failed, call.toolName == previousFailedTool {
            sameToolFailureCount += 1
        } else {
            previousFailedTool = failed ? call.toolName : nil
            sameToolFailureCount = failed ? 1 : 0
        }

        if progress == previousProgressFingerprint {
            idempotentNoProgressCount += 1
        } else {
            previousProgressFingerprint = progress
            idempotentNoProgressCount = 1
        }

        if exactFailureCount >= 5 {
            return ToolLoopGuardrailDecision(
                shouldStop: true,
                message: "The same tool call failed five times with the same result."
            )
        }
        if sameToolFailureCount >= 8 {
            return ToolLoopGuardrailDecision(
                shouldStop: true,
                message: "The same tool continued failing without a successful alternative."
            )
        }
        if idempotentNoProgressCount >= 5 {
            return ToolLoopGuardrailDecision(
                shouldStop: true,
                message: "Repeated idempotent calls produced no observable progress."
            )
        }
        if exactFailureCount == 2 {
            return ToolLoopGuardrailDecision(
                shouldStop: false,
                message: "This exact call already failed twice; change the approach instead of retrying it."
            )
        }
        if sameToolFailureCount == 3 {
            return ToolLoopGuardrailDecision(
                shouldStop: false,
                message: "This tool has failed three times; inspect the failure and choose a different path."
            )
        }
        if idempotentNoProgressCount == 2 {
            return ToolLoopGuardrailDecision(
                shouldStop: false,
                message: "The previous identical call produced the same result and should not be repeated."
            )
        }
        return nil
    }

    private static func canonicalDigest(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return digest(data)
        }
        return digest(canonical)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
