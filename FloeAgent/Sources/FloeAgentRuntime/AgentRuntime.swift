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
    func agentRuntime(_ runtime: FloeAgentRuntime, didChangeLiveness snapshot: AgentLivenessSnapshot) async
    func agentRuntime(_ runtime: FloeAgentRuntime, didChangeProviderAttempt snapshot: ProviderAttemptSnapshot) async
    /// Called only after a complete assistant/model step and before a steer
    /// is inserted. Persistence uses it to seal the assistant message without
    /// falsely emitting a terminal event.
    func agentRuntime(_ runtime: FloeAgentRuntime, didCompleteAssistantStep text: String) async
    /// Called after the steer is durably part of the runtime's message list,
    /// immediately before the next provider request is constructed.
    func agentRuntime(_ runtime: FloeAgentRuntime, didConsumeSteer input: RuntimeSteerInput) async
    /// Called after the context engine compacts the conversation, so the UI
    /// can reflect the token reduction.
    func agentRuntime(_ runtime: FloeAgentRuntime, didCompact record: ContextCompactionRecord) async
    func agentRuntime(
        _ runtime: FloeAgentRuntime,
        didChangeApprovalReview snapshot: ApprovalReviewSnapshot
    ) async
}

public extension AgentEventSink {
    func agentRuntime(_ runtime: FloeAgentRuntime, didChangeLiveness snapshot: AgentLivenessSnapshot) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime, didChangeProviderAttempt snapshot: ProviderAttemptSnapshot) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime, didCompleteAssistantStep text: String) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime, didConsumeSteer input: RuntimeSteerInput) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime, didCompact record: ContextCompactionRecord) async {}
    func agentRuntime(
        _ runtime: FloeAgentRuntime,
        didChangeApprovalReview snapshot: ApprovalReviewSnapshot
    ) async {}
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
    /// Executes only if the live runner still has the authority identity that
    /// policy approved. Dynamic registries override this atomically.
    func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult
    /// Risk labels for a tool, from the catalog. Unknown tools return nil
    /// and are rejected before policy evaluation.
    func descriptor(named name: String) -> ToolCatalog.Descriptor?
    /// Descriptors visible to this executor. Native executors merge compiled
    /// tools with bounded runtime sources such as namespaced MCP tools.
    var allDescriptors: [ToolCatalog.Descriptor] { get }
}

public extension ToolExecutor {
    var allDescriptors: [ToolCatalog.Descriptor] { ToolCatalog.allDescriptors }

    func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        if let expectedAuthorizationIdentity,
           descriptor(named: call.toolName)?.authorizationIdentity != expectedAuthorizationIdentity {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Tool authority changed after approval; review the updated tool before retrying",
                outputDigest: ""
            )
        }
        return try await execute(call, context: context)
    }
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
        ToolCatalog.descriptor(named: name) ?? runners.descriptor(named: name)
    }

    public var allDescriptors: [ToolCatalog.Descriptor] {
        var merged = Dictionary(
            uniqueKeysWithValues: ToolCatalog.allDescriptors.map { ($0.name, $0) }
        )
        for descriptor in runners.allDescriptors {
            merged[descriptor.name] = descriptor
        }
        return merged.values.sorted { $0.name < $1.name }
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try await execute(call, expectedAuthorizationIdentity: nil, context: context)
    }

    public func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        guard let runner = runners.runner(named: call.toolName) else {
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "No runner registered for tool '\(call.toolName)'",
                outputDigest: ""
            )
        }
        if let expectedAuthorizationIdentity,
           runner.descriptor.authorizationIdentity != expectedAuthorizationIdentity {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Tool authority changed after approval; review the updated tool before retrying",
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
                status: output.requiresUserAction ? .needsUser : .ok,
                outputSummary: ToolWorkflowGuidance.outputSummary(
                    output.summary,
                    exposing: output.artifacts
                ),
                outputDigest: output.fullOutputSHA256,
                exitStatus: output.exitStatus,
                artifacts: output.artifacts
            )
        } catch let error as FloeError where error == .cancelled {
            return ToolResult(callID: call.id, status: .cancelled, outputSummary: "Cancelled", outputDigest: "")
        } catch is CancellationError {
            return ToolResult(callID: call.id, status: .cancelled, outputSummary: "Cancelled", outputDigest: "")
        } catch {
            let recovery = ToolWorkflowGuidance.recoveryHint(for: call.toolName)
                .map { " Recovery: \($0)" } ?? ""
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "Execution error: \(error.localizedDescription)\(recovery)",
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
        return try AgentCheckpoint.decoded(from: Data(floeContentsOf: url))
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
        /// Exact installed-skill Python artifacts audited at installation.
        /// Approval policies may reuse only these fingerprints/specs.
        public var preapprovedPythonScriptSHA256: Set<String>
        public var preapprovedPythonPackages: Set<String>
        /// Canonical task workspace, independent of the currently visible UI.
        public var workspaceRootURL: URL?
        /// Persisted task-relative file scope; empty means the full root.
        public var allowedWorkspacePaths: [String]
        /// Chat-only runs can disable the compiled catalog entirely.
        public var toolsEnabled: Bool
        /// Pause timeout before automatic checkpoint.
        public var pauseTimeout: TimeInterval
        /// Emergency parent-iteration ceiling. Normal runs use a practically
        /// unbounded value and are governed by progress fingerprints instead;
        /// tests and constrained deployments can still provide a finite cap.
        public var maxToolSteps: Int
        /// When enabled, a completed answer gets one tool-free self-critique
        /// pass (verifying) before the run terminates, letting the model
        /// correct omissions or tighten its final reply.
        public var verifyFinalAnswer: Bool
        /// One-shot user request to compact seeded history before the next
        /// provider request. This is separate from automatic pressure-based
        /// compaction and is consumed by exactly one runtime.
        public var forceInitialCompaction: Bool
        /// Number of retries allowed for a cloud request after a network,
        /// server, rate-limit, or stream-liveness failure.
        public var maxProviderRetries: Int
        /// Maximum identical observable tool outcomes in one progress epoch.
        /// A value of two stops on the first unchanged retry.
        public var unchangedToolOutcomeLimit: Int
        /// Maximum wait for the first decoded provider event.
        public var providerFirstEventTimeout: TimeInterval
        /// Maximum gap between decoded provider events after the first event.
        public var providerStreamIdleTimeout: TimeInterval
        /// A longer bounded silence window after an explicit reasoning event.
        /// Some reasoning providers compute a large internal step before the
        /// next delta; treating that as ordinary answer silence causes false
        /// stall recovery and duplicate turns.
        public var providerReasoningIdleTimeout: TimeInterval
        /// Base delay for bounded exponential provider retry backoff.
        public var providerRetryBaseDelay: TimeInterval
        /// Upper bound for provider retry delay.
        public var providerRetryMaxDelay: TimeInterval
        /// Proportion of the backoff added as positive jitter.
        public var providerRetryJitterRatio: Double

        public init(
            conversationID: UUID = UUID(),
            provider: ProviderProfile,
            model: ModelProfile,
            conversationMode: ConversationMode = .chat,
            activeSkillIDs: Set<String> = [],
            allowedToolNames: Set<String>? = nil,
            preapprovedPythonScriptSHA256: Set<String> = [],
            preapprovedPythonPackages: Set<String> = [],
            workspaceRootURL: URL? = nil,
            allowedWorkspacePaths: [String] = [],
            toolsEnabled: Bool = true,
            pauseTimeout: TimeInterval = 300,
            maxToolSteps: Int = Int.max / 4,
            verifyFinalAnswer: Bool = false,
            forceInitialCompaction: Bool = false,
            maxProviderRetries: Int = 5,
            unchangedToolOutcomeLimit: Int = 3,
            providerFirstEventTimeout: TimeInterval = 30,
            providerStreamIdleTimeout: TimeInterval = 45,
            providerReasoningIdleTimeout: TimeInterval = 180,
            providerRetryBaseDelay: TimeInterval = 1,
            providerRetryMaxDelay: TimeInterval = 30,
            providerRetryJitterRatio: Double = 0.2
        ) {
            self.conversationID = conversationID
            self.provider = provider
            self.model = model
            self.conversationMode = conversationMode
            self.activeSkillIDs = activeSkillIDs
            self.allowedToolNames = allowedToolNames
            self.preapprovedPythonScriptSHA256 = preapprovedPythonScriptSHA256
            self.preapprovedPythonPackages = preapprovedPythonPackages
            self.workspaceRootURL = workspaceRootURL
            self.allowedWorkspacePaths = allowedWorkspacePaths
            self.toolsEnabled = toolsEnabled
            self.pauseTimeout = pauseTimeout
            self.maxToolSteps = maxToolSteps
            self.verifyFinalAnswer = verifyFinalAnswer
            self.forceInitialCompaction = forceInitialCompaction
            self.maxProviderRetries = max(0, maxProviderRetries)
            self.unchangedToolOutcomeLimit = max(2, unchangedToolOutcomeLimit)
            self.providerFirstEventTimeout = max(0, providerFirstEventTimeout)
            self.providerStreamIdleTimeout = max(0, providerStreamIdleTimeout)
            self.providerReasoningIdleTimeout = max(
                self.providerStreamIdleTimeout,
                providerReasoningIdleTimeout
            )
            self.providerRetryBaseDelay = max(0, providerRetryBaseDelay)
            self.providerRetryMaxDelay = max(self.providerRetryBaseDelay, providerRetryMaxDelay)
            self.providerRetryJitterRatio = min(1, max(0, providerRetryJitterRatio))
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
    /// Last boundary before model-produced tool arguments can enter approval,
    /// checkpoints, audit events or logs. App hosts use this to replace raw
    /// credential fields with Keychain-backed references.
    private let toolCallNormalizer: (@Sendable (ToolCall) async throws -> ToolCall)?

    private var messages: [ConversationMessage] = []
    private var pendingToolCalls: [ToolCall] = []
    private var pendingToolResults: [ToolResult] = []
    /// Tool calls collected from the current model response, executed as a
    /// batch on the provider's completion event.
    private var pendingToolBatch: [ToolCall] = []
    private var grants: [ApprovalGrant] = []
    private var executedIdempotencyKeys: Set<String> = []
    private var totalInputTokens = 0
    private var totalOutputTokens = 0
    private var streamText = ""
    private var responseReasoning = ""
    private var streamTextByteCount = 0
    private var providerEventCount = 0
    private var providerPayloadBytes = 0
    private var modelRequestStartedAt: Date?
    private var firstModelActivityAt: Date?
    /// Tool executions so far in this run (bounded by
    /// `Configuration.maxToolSteps`).
    private var toolStepCount = 0
    private var contextOverflowRecoveryCount = 0
    private var loopGuard = ToolLoopGuard()
    private var executionLedger = HarnessExecutionLedger()
    /// Durable per-call boundaries distinguish a request that never started
    /// from one whose real-world outcome became unknown during interruption.
    private var toolLifecycleByCallID: [String: AgentToolLifecycleEntry] = [:]
    /// True only after this runtime has loaded a persisted checkpoint. The
    /// recovery ledger is intentionally used to deduplicate calls at this
    /// boundary; a normal fresh run may legitimately observe the same path
    /// again after a mutation.
    private var resumedFromCheckpoint = false
    private var forcedStopReason: AgentEvent.StopReason?
    private var isFinalizingWithoutTools = false
    /// Structured logging for run diagnostics (state transitions, approval
    /// decisions, tool execution). Category `.runtime` shares the channel
    /// with ConversationRunService.
    private let logger = FloeLogger(category: .runtime)
    /// Guards the single self-critique pass so verification runs once.
    private var didVerifyFinalAnswer = false
    /// A provider can occasionally end a turn with prose such as “I will now
    /// call the tool” without emitting a structured call. Repair that broken
    /// action boundary once; a hard cap keeps weak models from turning the
    /// harness correction itself into a loop.
    private var deferredActionRepairCount = 0
    private var malformedToolRepairCount = 0
    private var malformedToolRepairRequested = false
    /// Set by tool/compaction handling to request another provider turn.
    /// The outer model loop consumes this flag; handlers never recursively
    /// enter `runModelTurn`, which keeps one owner for state transitions.
    private var modelTurnContinuationRequested = false
    /// A visible tool (for example browser takeover) parked the run at a
    /// durable checkpoint until the user explicitly continues it.
    private var waitingForUserAction = false
    /// User guidance waits here until the current model output and any tool
    /// request/result pair have reached a complete step boundary.
    private var pendingSteers: [RuntimeSteerInput] = []
    private var acceptedSteerIDs: Set<UUID> = []
    private var forceCompactionOnNextTurn: Bool
    /// Last committed compaction transaction. Persisting this in checkpoints
    /// makes resume auditable and prevents a recovered run from treating an
    /// already summarized transcript as pristine history.
    private var latestContextCompaction: ContextCompactionRecord?
    /// Exact, secret-free summary of the last request checkpointed before
    /// provider dispatch. It survives streaming recovery points after the
    /// pending call/result arrays have been consumed in memory.
    private var latestProviderDispatchEnvelope: ProviderDispatchEnvelope?
    /// Cross-process replay copy paired with the envelope. Unlike
    /// `providerRetryRequest`, this value is Codable and survives relaunch.
    private var latestProviderDispatchRequest: ProviderDispatchRequestSnapshot?
    /// When recovery parked the run during an unfinished provider request,
    /// the first replay must reconstruct the same secret-free boundary before
    /// another request is allowed onto the wire. Completed provider turns
    /// clear this value before tool settlement or terminal publication.
    private var restoredProviderDispatchEnvelope: ProviderDispatchEnvelope?
    /// Exact request retained for an in-process retry. Rebuilding a request
    /// through a fresh context compaction pass could silently move the replay
    /// boundary, so retries reuse the committed dispatch envelope verbatim.
    private var providerRetryRequest: ProviderStreamRequest?
    /// Full pending tool/result pair retained while a provider request is on
    /// the wire. The public checkpoint stores this pair even after the live
    /// request arrays are drained, so relaunch can reconstruct the same safe
    /// dispatch boundary instead of having only opaque envelope IDs.
    private var activeProviderPendingCalls: [ToolCall] = []
    private var activeProviderPendingResults: [ToolResult] = []
    private var providerRetryCount = 0
    private var providerAttemptNumber = 0
    private var providerReceivedFirstEvent = false
    private var providerLastEventWasReasoning = false
    private var providerLastProgressAt = Date()
    private var providerAttemptStartedAt = Date()
    private var providerRetryRequested = false
    private var providerRetryDelay: TimeInterval = 0
    private var providerWatchdogTask: Task<Void, Never>?
    private var livenessSnapshot = AgentLivenessSnapshot(
        phase: .preparing,
        message: "Preparing the run",
        isRecoverable: true
    )
    private var providerAttemptSnapshot: ProviderAttemptSnapshot?

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
        toolCallNormalizer: (@Sendable (ToolCall) async throws -> ToolCall)? = nil,
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
        self.toolCallNormalizer = toolCallNormalizer
        self.sink = sink
        self.runID = runID
        self.forceCompactionOnNextTurn = configuration.forceInitialCompaction
        self.latestContextCompaction = nil
        self.latestProviderDispatchRequest = nil
        self.providerRetryRequest = nil
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
        await publishLivenessForState(newState)
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
             ("streamingModel", "verifying"),
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
             ("verifying", "streamingModel"),
             ("verifying", "cancelling"),
             ("verifying", "checkpointed"),
             ("verifying", "failed"),
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
                || message.content.hasPrefix(Self.visualEvidenceSystemPrefix)
                || message.content.hasPrefix("The user attached image evidence,")
                || message.content.hasPrefix("The configured auxiliary vision model")
        })
    }

    /// Latest secret-free progress snapshot for diagnostics and UI recovery
    /// cards. The timestamp is the runtime's last observed progress boundary.
    public func liveness() -> AgentLivenessSnapshot { livenessSnapshot }

    /// Latest provider-attempt diagnostics, when a cloud request has started.
    public func providerAttempt() -> ProviderAttemptSnapshot? { providerAttemptSnapshot }

    /// Stable marker for app-produced visual handoffs. Keeping one typed
    /// prefix prevents harmless OCR/VLM evidence from being discarded by the
    /// historical-system-message authority filter when wording changes.
    public static let visualEvidenceSystemPrefix =
        "Visual evidence handoff (app-generated, untrusted data):"

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
        let activeRunTask = streamTask
        activeRunTask?.cancel()
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
        providerWatchdogTask?.cancel()
        providerWatchdogTask = nil
        // 4. Let an in-flight executor publish its cancelled/tool result
        // before the final checkpoint is written. Previously cancellation
        // checkpointed immediately and the executor could finish one actor
        // turn later, leaving a provider tool_call without its required tool
        // result. Recovery then failed at the provider boundary with a 400.
        await activeRunTask?.value
        // 5. Persist and park.
        do {
            try await writeCheckpoint()
            await transition(to: .checkpointed(AgentState.CheckpointRef(
                reason: "任务已由用户停止，当前进度已保存"
            )))
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
        // Time was intentionally allowed to pass. Treat the resumed step as
        // a fresh progress epoch so a prior unchanged observation cannot
        // terminate a legitimate post-wait verification route.
        loopGuard.advanceProgressEpoch()
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
            await transition(to: .checkpointed(AgentState.CheckpointRef(
                reason: "暂停等待已超时，当前进度已保存"
            )))
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
        await transition(to: .checkpointed(AgentState.CheckpointRef(
            reason: "任务已保存检查点，等待继续"
        )))
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
        activeProviderPendingCalls = []
        activeProviderPendingResults = []
        grants = checkpoint.approvals
        executedIdempotencyKeys = checkpoint.idempotencyKeys
        executionLedger = HarnessExecutionLedger(records: checkpoint.executionLedgerEntries ?? [])
        toolLifecycleByCallID = Dictionary(
            uniqueKeysWithValues: (checkpoint.toolLifecycleEntries ?? []).map { ($0.callID, $0) }
        )
        if let envelope = checkpoint.providerDispatchEnvelope {
            guard envelope.providerID == configuration.provider.id,
                  envelope.modelID == configuration.model.id,
                  envelope.remoteModelID == configuration.model.remoteModelID,
                  envelope.conversationMode == configuration.conversationMode.rawValue else {
                throw FloeError.validationFailed(
                    "Checkpoint provider dispatch identity does not match the resumed run configuration"
                )
            }
        }
        latestProviderDispatchRequest = checkpoint.providerDispatchRequest
        if let snapshot = checkpoint.providerDispatchRequest {
            let restoredRequest = snapshot.request()
            guard restoredRequest.provider.id == configuration.provider.id,
                  restoredRequest.model.id == configuration.model.id else {
                throw FloeError.validationFailed(
                    "Checkpoint provider request does not match the resumed run configuration"
                )
            }
            latestProviderDispatchEnvelope = checkpoint.providerDispatchEnvelope
            restoredProviderDispatchEnvelope = checkpoint.providerDispatchEnvelope
            providerRetryRequest = restoredRequest
        } else {
            // v4 and older checkpoints persisted only a digest. Rebuilding
            // after an app update can legitimately change catalog ordering or
            // prompt compaction, so that digest cannot act as a replay lock.
            // The execution ledger/lifecycle still prevent settled tools from
            // being replayed; start a fresh provider boundary from that
            // committed state and upgrade the next checkpoint to v5.
            latestProviderDispatchEnvelope = nil
            restoredProviderDispatchEnvelope = nil
            providerRetryRequest = nil
        }
        // Older checkpoints may already contain a complete provider pair but
        // predate lifecycle metadata. Normalize those pairs before enforcing
        // the v3 provider/checkpoint invariants.
        let restoredResultIDs = Set(pendingToolResults.map(\.callID))
        for call in pendingToolCalls where restoredResultIDs.contains(call.id) {
            setToolLifecycle(call: call, phase: .resultCommitted)
        }
        repairInterruptedToolPairs()
        resumedFromCheckpoint = true
        // A checkpoint is a committed tool-result boundary. Never carry a
        // cancelled provider stream's partial prose into the replay turn.
        streamText = ""
        responseReasoning = ""
        streamTextByteCount = 0
        providerEventCount = 0
        providerPayloadBytes = 0
        latestContextCompaction = checkpoint.contextCompaction
        toolStepCount = checkpoint.parentIterationCount ?? 0
        await budgetLedger.restore(
            parent: checkpoint.parentIterationCount ?? 0,
            total: checkpoint.totalIterationCount ?? checkpoint.parentIterationCount ?? 0
        )
        let goal = messages.last(where: { $0.role == "user" })?.content ?? ""
        await transition(to: .preparing(AgentState.PreparingInfo(goal: goal, resumedFromCheckpoint: true)))
        await runModelTurn()
    }

    /// Provider protocols require every assistant tool call to be followed by
    /// one result. A force-quit or suspension can occur after a remote command
    /// was dispatched but before its result was committed. Pair that orphaned
    /// call with an explicit unknown-outcome result so recovery is valid and
    /// the model verifies remote state instead of blindly repeating a write.
    private func repairInterruptedToolPairs() {
        var pairedIDs = Set(pendingToolResults.map(\.callID))
        for call in pendingToolCalls where !pairedIDs.contains(call.id) {
            let lifecycle = toolLifecycleByCallID[call.id]
            let result: ToolResult
            if let recovered = executionLedger.recoveredResult(for: call) {
                result = recovered
            } else if lifecycle?.phase == .recorded || lifecycle?.phase == .approved {
                result = ToolResult(
                    callID: call.id,
                    status: .failed,
                    outputSummary: "The tool call was recorded but never dispatched. No external action started; re-plan from current state without treating this as a failed side effect.",
                    outputDigest: ""
                )
            } else {
                let retryGuidance = executor.descriptor(named: call.toolName)?.isSideEffecting == false
                    ? "This tool is read-only, so it may be retried only if fresh evidence is still needed."
                    : "Inspect current external state before deciding whether any action should be retried."
                result = ToolResult(
                    callID: call.id,
                    status: .failed,
                    outputSummary: "Execution was interrupted after dispatch but before its result was committed. The real-world outcome is unknown. \(retryGuidance)",
                    outputDigest: ""
                )
            }
            pendingToolResults.append(result)
            pairedIDs.insert(call.id)
            executionLedger.record(
                call: call,
                result: result,
                isSideEffecting: executor.descriptor(named: call.toolName)?.isSideEffecting == true
            )
            setToolLifecycle(call: call, phase: .resultCommitted)
        }
        // Provider protocols require results in the same order as their
        // assistant tool calls. Older checkpoints may have persisted a
        // complete but out-of-order set; normalize it before the boundary
        // invariant is enforced.
        let resultByCallID = Dictionary(
            pendingToolResults.map { ($0.callID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        pendingToolResults = pendingToolCalls.compactMap { resultByCallID[$0.id] }
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

    /// Re-evaluates an already visible approval after the user changes the
    /// task mode from the composer. An unchanged human/escalation result
    /// leaves the card in place; allow/deny/stopped resumes the suspended
    /// continuation exactly once.
    public func approvalPolicyDidChange() async {
        guard case .waitingApproval(let waiting) = state,
              approvalContinuation != nil,
              let descriptor = executor.descriptor(named: waiting.toolCall.toolName)
        else { return }
        let action = ProposedAction(
            toolCall: waiting.toolCall,
            riskLabels: Set(descriptor.riskLabels.map(\.rawValue)),
            userGoal: messages.last(where: { $0.role == "user" })?.content ?? "",
            recentContext: Self.approvalContext(from: messages),
            hostAndPathScope: waiting.toolCall.scope,
            preapprovedPythonScriptSHA256: configuration.preapprovedPythonScriptSHA256,
            preapprovedPythonPackages: configuration.preapprovedPythonPackages
        )
        let decision: ApprovalDecision
        do {
            decision = try await policy.decide(action)
        } catch {
            return
        }
        guard case .waitingApproval(let current) = state,
              current.toolCall.id == waiting.toolCall.id else { return }
        switch decision {
        case .allow, .deny, .stopped:
            await resolveApproval(decision)
        case .escalateToHuman:
            break
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
            // Fresh user guidance is explicit progress. Previous unchanged
            // retry evidence must not block the newly steered route.
            loopGuard.advanceProgressEpoch()
            return .accepted
        case .idle, .cancelling, .checkpointed, .verifying, .completed, .failed:
            return .rejected(reason: "The target run is no longer accepting guidance")
        }
    }

    // MARK: Core loop

    /// preparing → streamingModel; consumes the provider stream.
    private func runModelTurn() async {
        repeat {
            modelTurnContinuationRequested = false
            await runSingleModelTurn()
            if providerRetryRequested {
                let delay = providerRetryDelay
                providerRetryRequested = false
                if delay > 0, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        } while modelTurnContinuationRequested && !Self.isTerminalState(state)
    }

    /// Executes exactly one provider request. Tool handling can request a
    /// subsequent turn by setting `modelTurnContinuationRequested`; it must
    /// never call this method recursively.
    private func runSingleModelTurn() async {
        let hasFreshSteer = !pendingSteers.isEmpty
        if hasFreshSteer, !streamText.isEmpty {
            messages.append(ConversationMessage(role: "assistant", content: streamText))
            await sink?.agentRuntime(self, didCompleteAssistantStep: streamText)
        }
        await consumeSteersAtStepBoundary()
        if hasFreshSteer {
            // New user authority deliberately changes the next provider
            // boundary, so it supersedes an unfinished replay reservation.
            restoredProviderDispatchEnvelope = nil
            latestProviderDispatchEnvelope = nil
            latestProviderDispatchRequest = nil
            providerRetryRequest = nil
        }
        // Sink callbacks perform durable persistence and therefore suspend.
        // A user cancel/pause can win during that suspension; never revive a
        // parked or terminal run by starting a provider request afterwards.
        switch state {
        case .cancelling, .paused, .checkpointed, .completed, .failed:
            return
        default:
            break
        }
        if providerRetryRequest == nil, let contextEngine {
            let latestUserID = messages.last(where: { $0.role == "user" })?.id
            let protection = ContextProtection(
                messageIDs: latestUserID.map { [$0] } ?? []
            )
            let compressionPolicy = Self.contextCompressionPolicy(
                configuration: configuration,
                messages: messages
            )
            logger.debug(
                "contextBudgetConfigured run=\(runID.uuidString) mode=\(compressionPolicy.mode.rawValue) tier=\(compressionPolicy.tier.rawValue) window=\(compressionPolicy.budget.contextWindowTokens) availableInput=\(compressionPolicy.budget.availableInputTokens) reservedOutput=\(compressionPolicy.budget.reservedOutputTokens) toolSchemas=\(compressionPolicy.budget.toolSchemaTokens) images=\(compressionPolicy.budget.imageTokens) trigger=\(compressionPolicy.budget.triggerRatio) target=\(compressionPolicy.budget.targetRatio)"
            )
            let request = ContextRequest(
                messages: messages,
                budget: compressionPolicy.budget,
                protection: protection
            )
            let wasForcedCompaction = forceCompactionOnNextTurn
            do {
                let prepared: PreparedContext
                if forceCompactionOnNextTurn {
                    let compacted = try await contextEngine.compact(CompactionRequest(
                        context: request,
                        force: true
                    ))
                    prepared = PreparedContext(
                        messages: compacted.messages,
                        estimatedInputTokens: compacted.estimatedTokens,
                        compaction: compacted.record
                    )
                    forceCompactionOnNextTurn = false
                } else {
                    prepared = try await contextEngine.prepareContext(for: request)
                }
                if let compaction = prepared.compaction,
                   !compaction.sourceMessageIDs.isEmpty {
                    let summary = prepared.messages.first(where: {
                        $0.role == "system" && $0.content.contains("Historical summary:")
                    })?.content ?? ""
                    // Treat compaction as a transaction. The provider must
                    // never receive a rewritten history that failed durable
                    // persistence, otherwise resume can silently diverge.
                    if let intelligenceStore {
                        try await intelligenceStore.saveCompaction(
                            runID: runID,
                            record: compaction,
                            summary: summary
                        )
                    }
                    messages = prepared.messages
                    latestContextCompaction = compaction
                    logger.info(
                        "contextCompacted run=\(runID.uuidString) mode=\(compressionPolicy.mode.rawValue) tier=\(compressionPolicy.tier.rawValue) before=\(compaction.beforeEstimatedTokens) after=\(compaction.afterEstimatedTokens) sources=\(compaction.sourceMessageIDs.count) emergency=\(prepared.isEmergencyCompaction)"
                    )
                    await sink?.agentRuntime(self, didCompact: compaction)
                }
            } catch {
                logger.warning(
                    "contextCompactionFailed run=\(runID.uuidString) forced=\(wasForcedCompaction) error=\(error.localizedDescription)"
                )
                forceCompactionOnNextTurn = false
                if wasForcedCompaction {
                    await failRun(
                        message: "Context compaction failed: \(error.localizedDescription)",
                        recoverable: true
                    )
                    return
                }
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
            catalogDescriptors = PlanToolPolicy().allowedDescriptors(from: executor.allDescriptors)
        } else {
            catalogDescriptors = executor.allDescriptors
        }
        if configuration.model.capabilities.contains(.vision) {
            // A multimodal model receives the current image bytes directly.
            // Do not offer auxiliary inspection/OCR escape hatches that make
            // capable models avoid looking at the supplied image. Preflight
            // fallback evidence is prepared by the app before this boundary
            // when an on-device vision projector cannot load.
            // OCR remains useful for dense text/screenshots and can reduce
            // token usage even for a multimodal model. Only semantic image
            // inspection is redundant with direct vision.
            let auxiliaryVisionTools: Set<String> = ["image.inspect"]
            catalogDescriptors.removeAll { auxiliaryVisionTools.contains($0.name) }
        }
        let effectiveAllowedNames: Set<String>? = {
            if let configured = configuration.allowedToolNames { return configured }
            return configuration.activeSkillIDs.isEmpty ? nil : []
        }()
        if let effectiveAllowedNames {
            catalogDescriptors.removeAll { !effectiveAllowedNames.contains($0.name) }
        }
        // Prerequisite wording belongs to the current user turn. Do not let a
        // historical SSH-before-VNC request constrain a later, unrelated turn.
        let statefulRouteGoal = messages.last(where: { $0.role == "user" })?.content ?? ""
        catalogDescriptors.removeAll {
            !executionLedger.allowsStatefulTool(named: $0.name, userGoal: statefulRouteGoal)
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
        let usesFiniteIterationBudget = configuration.maxToolSteps < 100_000
        let pressure: String? = if usesFiniteIterationBudget && !isFinalizingWithoutTools && remainingIterations <= 3 {
            "Harness control: only \(remainingIterations) tool iterations remain. Return the final answer now and do not call another tool unless it is strictly required to avoid an incorrect answer."
        } else if usesFiniteIterationBudget && !isFinalizingWithoutTools && remainingIterations <= 10 {
            "Harness control: \(remainingIterations) tool iterations remain. Start wrapping up, consolidate evidence, and prepare a final answer."
        } else {
            nil
        }
        if let pressure {
            legacyMessages.append((role: "system", content: pressure))
            contentMessages.append(ProviderMessage(role: "system", content: [.text(pressure)]))
        }
        if let ledger = executionLedger.promptBlock() {
            // Keep one leading system envelope. Some OpenAI-compatible
            // providers become less reliable when a second system message is
            // inserted after the user turn.
            if let index = legacyMessages.firstIndex(where: { $0.role == "system" }) {
                legacyMessages[index].content += "\n\n\(ledger)"
                contentMessages[index].content.append(.text("\n\n\(ledger)"))
            } else {
                legacyMessages.insert((role: "system", content: ledger), at: 0)
                contentMessages.insert(
                    ProviderMessage(role: "system", content: [.text(ledger)]),
                    at: 0
                )
            }
        }
        let providerInvariantViolations = HarnessInvariantRegistry.validateProviderBoundary(
            calls: pendingToolCalls,
            results: pendingToolResults,
            lifecycleByCallID: toolLifecycleByCallID
        )
        guard providerInvariantViolations.isEmpty else {
            await failRun(
                message: "Harness invariant failed before model dispatch: \(HarnessInvariantRegistry.summary(providerInvariantViolations))",
                recoverable: true
            )
            return
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
        let freshRequest = ProviderStreamRequest(
            provider: configuration.provider,
            model: configuration.model,
            messages: legacyMessages,
            contentMessages: contentMessages,
            toolResults: pendingToolResults.map {
                (callID: $0.callID, output: Self.modelVisibleToolResult($0))
            },
            // Tool-call/result pairs are provider history, not permission to
            // issue another tool. A forced tool-free finalization must hide
            // schemas while still replaying the complete ordered pair.
            pendingToolCalls: pendingToolCalls,
            pendingAssistantReasoning: pendingToolCalls.isEmpty || responseReasoning.isEmpty
                ? nil : responseReasoning,
            toolSchemas: supportsTools ? catalogDescriptors.map {
                ToolSchemaDescriptor(
                    name: $0.name,
                    description: Self.providerToolDescription($0),
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
        // A retry must replay the exact safe dispatch boundary. In particular,
        // do not rebuild a compacted prompt or regenerate a tool request after
        // the provider has already crossed the network boundary.
        let request = providerRetryRequest ?? freshRequest
        let dispatchEnvelope = Self.dispatchEnvelope(
            request: request,
            conversationMode: configuration.conversationMode
        )
        if let restored = restoredProviderDispatchEnvelope,
           !Self.dispatchEnvelopesMatch(restored, dispatchEnvelope) {
            await failRun(
                message: "Recovered provider request does not match its durable dispatch checkpoint",
                recoverable: true
            )
            return
        }
        restoredProviderDispatchEnvelope = nil
        latestProviderDispatchEnvelope = dispatchEnvelope
        latestProviderDispatchRequest = ProviderDispatchRequestSnapshot(request: request)
        logger.info(
            "promptAssembly run=\(runID.uuidString) digest=\(Self.promptAssemblyDigest(messages: legacyMessages, descriptors: catalogDescriptors)) tools=\(request.toolSchemas.count) pendingCalls=\(request.pendingToolCalls.count) pendingResults=\(request.toolResults.count) mode=\(configuration.conversationMode.rawValue)"
        )
        // The exact prompt/tool-result boundary must be recoverable before a
        // provider request is allowed onto the wire. This prevents a restart
        // from silently falling behind the context that the model received.
        if providerRetryRequest == nil { providerRetryRequest = request }
        if activeProviderPendingCalls.isEmpty, !pendingToolCalls.isEmpty {
            activeProviderPendingCalls = pendingToolCalls
            activeProviderPendingResults = pendingToolResults
        }
        do {
            try await writeCheckpoint()
        } catch {
            await failRun(
                message: "Unable to save the model-dispatch recovery checkpoint: \(error.localizedDescription)",
                recoverable: true
            )
            return
        }
        pendingToolResults.removeAll(keepingCapacity: true)
        pendingToolCalls.removeAll(keepingCapacity: true)
        responseReasoning = ""

        modelRequestStartedAt = Date()
        firstModelActivityAt = nil
        providerAttemptNumber += 1
        providerReceivedFirstEvent = false
        providerLastEventWasReasoning = false
        providerAttemptStartedAt = modelRequestStartedAt ?? Date()
        providerLastProgressAt = providerAttemptStartedAt
        await publishProviderAttempt(
            status: .started,
            reason: "Provider request dispatched",
            error: nil
        )
        await publishLiveness(
            phase: .waitingForFirstEvent,
            message: "Waiting for the cloud model's first event",
            isRecoverable: true
        )
        startProviderWatchdog(attempt: providerAttemptNumber)
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
                    let batch = await self.drainPendingToolBatch()
                    if !batch.isEmpty {
                        await self.executeToolBatch(batch)
                        // The batch's resumeStream requested the next turn.
                    } else {
                        let interrupted = AgentEvent.NormalizedError(
                            kind: .network,
                            providerMessage: "Cloud model stream ended before a completion event; no final reply was committed."
                        )
                        await self.emit(.error(interrupted))
                        await self.handleProviderFailure(interrupted)
                    }
                }
            } catch is CancellationError {
                // cancel() owns the terminal transition.
            } catch {
                let normalized = Self.normalizedBoundaryError(error)
                await self.emit(.error(normalized))
                await self.handleProviderFailure(normalized)
            }
        }
        await streamTask?.value
        providerWatchdogTask?.cancel()
        providerWatchdogTask = nil
    }

    /// Errors thrown before the first wire event are often request-building
    /// or local-inference failures, not network outages. Preserve that
    /// distinction so the UI and uploaded diagnostics identify the real
    /// failing layer instead of showing every launch as a retryable network
    /// pause.
    private static func normalizedBoundaryError(_ error: Error) -> AgentEvent.NormalizedError {
        if error is CancellationError {
            return .init(kind: .cancelled, providerMessage: "Cancelled")
        }
        if let urlError = error as? URLError {
            return .init(kind: .network, providerMessage: urlError.localizedDescription)
        }
        if let floeError = error as? FloeError {
            let kind: AgentEvent.NormalizedError.Kind = switch floeError {
            case .unauthorized: .auth
            case .syncUnavailable: .network
            case .cancelled: .cancelled
            case .invalidConfiguration, .validationFailed, .notFound,
                 .storageCorrupted, .internalError: .malformed
            }
            return .init(kind: kind, providerMessage: floeError.localizedDescription)
        }
        let nsError = error as NSError
        let message = "\(error.localizedDescription) [\(nsError.domain):\(nsError.code)]"
        return .init(kind: .malformed, providerMessage: String(message.prefix(500)))
    }

    private static func providerImageEvidence(
        _ artifact: ToolArtifactReference
    ) -> ProviderContentPart? {
        guard artifact.mimeType == "image/jpeg" || artifact.mimeType == "image/png",
              artifact.byteCount > 0, artifact.byteCount <= 8 * 1024 * 1024,
              (artifact.relativePath.hasPrefix("BrowserArtifacts/")
                || artifact.relativePath.hasPrefix("GeneratedImages/")
                || artifact.relativePath.hasPrefix("VNCArtifacts/")),
              !artifact.relativePath.split(separator: "/").contains("..")
        else { return nil }
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
        let url = root.appendingPathComponent(artifact.relativePath)
        guard let data = try? Data(floeContentsOf: url, options: [.mappedIfSafe]),
              data.count == artifact.byteCount else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256.lowercased() else { return nil }
        return .imageData(mimeType: artifact.mimeType, base64: data.base64EncodedString())
    }

    private func handleStreamEvent(_ rawEvent: AgentEvent) async {
        // Never mutate after leaving streamingModel (cancel race safety).
        guard case .streamingModel(var info) = state else { return }

        let observedAt = Date()
        providerLastProgressAt = observedAt
        providerLastEventWasReasoning = {
            if case .reasoningSummary = rawEvent { return true }
            return false
        }()
        if !providerReceivedFirstEvent {
            providerReceivedFirstEvent = true
            await publishProviderAttempt(
                status: .firstEvent,
                reason: "Provider delivered its first event",
                error: nil
            )
            await publishLiveness(
                phase: .streaming,
                message: "Cloud model stream is active",
                isRecoverable: true
            )
        }
        switch rawEvent {
        case .textDelta, .reasoningSummary, .toolRequest:
            if firstModelActivityAt == nil { firstModelActivityAt = observedAt }
        default:
            break
        }
        let event: AgentEvent
        if case .usage(var report) = rawEvent {
            if let startedAt = modelRequestStartedAt {
                if report.totalDurationMs == nil {
                    report.totalDurationMs = max(0, Int(observedAt.timeIntervalSince(startedAt) * 1_000))
                }
                if let firstAt = firstModelActivityAt {
                    if report.timeToFirstTokenMs == nil {
                        report.timeToFirstTokenMs = max(0, Int(firstAt.timeIntervalSince(startedAt) * 1_000))
                    }
                    let generationSeconds = observedAt.timeIntervalSince(firstAt)
                    if report.tokensPerSecond == nil,
                       report.outputTokens > 0,
                       generationSeconds > 0.001 {
                        report.tokensPerSecond = Double(report.outputTokens) / generationSeconds
                    }
                }
            }
            event = .usage(report)
        } else {
            event = rawEvent
        }

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
            if !pendingToolBatch.isEmpty {
                let batch = pendingToolBatch
                pendingToolBatch = []
                await publishProviderAttempt(
                    status: .completed,
                    reason: "Provider completed with a tool batch",
                    error: nil
                )
                await executeToolBatch(batch)
                // The batch's resumeStream already requested the next turn.
                return
            }
            if malformedToolRepairRequested {
                malformedToolRepairRequested = false
                clearCompletedProviderDispatch()
                messages.append(ConversationMessage(
                    role: "system",
                    content: "Harness control: the previous structured tool request was rejected before recording or execution because its arguments were malformed. Emit one corrected native tool call with valid JSON, or explain the actionable failure without calling a tool. Do not repeat the invalid payload."
                ))
                modelTurnContinuationRequested = true
                return
            }
            await publishProviderAttempt(
                status: .completed,
                reason: "Provider completed the model turn",
                error: nil
            )
            clearCompletedProviderDispatch()
            await finishOrSteer(stopReason: forcedStopReason ?? completion.stopReason)
            return
        }

        // Verification output is private harness work. Buffer it in
        // `streamText`, but do not stream a bare "CONFIRM" (or an unfinished
        // correction) into the user-visible answer. A corrected answer is
        // emitted atomically at the verification boundary below.
        let shouldPublishEvent: Bool
        if case .textDelta = event, didVerifyFinalAnswer, isFinalizingWithoutTools {
            shouldPublishEvent = false
        } else {
            shouldPublishEvent = true
        }
        if shouldPublishEvent { await emit(event) }
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

        case .reasoningSummary(let summary):
            responseReasoning += summary.text

        case .usage(let report):
            totalInputTokens = report.inputTokens
            totalOutputTokens = report.outputTokens
            await contextEngine?.observeUsage(UsageSnapshot(
                inputTokens: report.inputTokens,
                outputTokens: report.outputTokens,
                modelCalls: 1,
                cacheReadTokens: report.cacheReadTokens,
                cacheWriteTokens: report.cacheWriteTokens,
                reasoningTokens: report.reasoningTokens,
                totalDurationMs: report.totalDurationMs,
                timeToFirstTokenMs: report.timeToFirstTokenMs,
                tokensPerSecond: report.tokensPerSecond,
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
            // Collect into the response batch; execution happens on the
            // provider's completion event so read-only calls can run in
            // parallel and writes act as barriers.
            do {
                let normalized = try await toolCallNormalizer?(call) ?? call
                pendingToolBatch.append(normalized.withIDContext(runID: runID))
            } catch {
                pendingToolBatch.removeAll { $0.id == call.id }
                if malformedToolRepairRequested {
                    // One provider response may contain several invalid calls;
                    // reject the whole batch as one correction opportunity.
                } else if malformedToolRepairCount == 0 {
                    malformedToolRepairCount = 1
                    malformedToolRepairRequested = true
                    await publishLiveness(
                        phase: .resolvingTool,
                        message: "Rejected malformed tool arguments before dispatch; requesting one correction",
                        isRecoverable: true
                    )
                } else {
                    await failRun(
                        message: "Tool arguments remained invalid after one correction: \(error.localizedDescription)",
                        recoverable: false
                    )
                }
            }

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
                // Context compaction intentionally changes the request. It is
                // not a transport retry and therefore must not replay the
                // pre-compaction dispatch envelope.
                providerRetryRequest = nil
                latestProviderDispatchEnvelope = nil
                latestProviderDispatchRequest = nil
                restoredProviderDispatchEnvelope = nil
                modelTurnContinuationRequested = true
            case .cancelled:
                break // cancel() owns the transition.
            case .rateLimited, .server, .network:
                await handleProviderFailure(error)
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
            if shouldRepairDeferredActionPromise(stopReason: stopReason) {
                await beginDeferredActionRepair()
                return
            }
            if stopReason == .endTurn,
               configuration.verifyFinalAnswer,
               !didVerifyFinalAnswer,
               !streamText.isEmpty {
                await beginFinalAnswerVerification(stopReason: stopReason)
                return
            }
            if didVerifyFinalAnswer, isFinalizingWithoutTools {
                let verification = streamText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !verification.isEmpty, verification.uppercased() != "CONFIRM" {
                    await emit(.textDelta(.init(text: streamText)))
                }
            }
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

    /// Detects an unfinished action promise at the exact provider boundary.
    /// This is intentionally conservative: tools must be available, the turn
    /// must otherwise be terminal, and the prose must combine a near-future
    /// phrase with either an action verb or an exposed tool name.
    private func shouldRepairDeferredActionPromise(
        stopReason: AgentEvent.StopReason
    ) -> Bool {
        guard stopReason == .endTurn,
              deferredActionRepairCount == 0,
              !isFinalizingWithoutTools,
              configuration.toolsEnabled,
              configuration.model.capabilities.contains(.tools),
              !executor.allDescriptors.isEmpty else { return false }

        let text = streamText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !text.isEmpty else { return false }

        let futureMarkers = [
            "我现在", "现在用", "现在调用", "接下来我", "下一步我", "我会立即",
            "立即调用", "让我", "我先", "准备调用", "准备执行",
            "i'll now", "i will now", "next i'll", "next i will", "let me",
            "i'm going to", "i am going to", "now i'll", "now i will"
        ]
        guard futureMarkers.contains(where: text.contains) else { return false }

        let actionMarkers = [
            "调用", "执行", "观察", "检查", "读取", "连接", "安装", "测试",
            "打开", "获取", "截图", "重试", "call", "run", "execute",
            "inspect", "observe", "read", "connect", "install", "test",
            "open", "fetch", "capture", "retry"
        ]
        if actionMarkers.contains(where: text.contains) { return true }

        return executor.allDescriptors.contains { descriptor in
            let dotted = descriptor.name.lowercased()
            return text.contains(dotted) || text.contains(dotted.replacingOccurrences(of: ".", with: "_"))
        }
    }

    /// Seals the misleading prose as a complete assistant step and asks the
    /// provider to either emit the real structured call or report a concrete
    /// blocker. Tool schemas stay enabled for this one repair turn.
    private func beginDeferredActionRepair() async {
        deferredActionRepairCount += 1
        messages.append(ConversationMessage(role: "assistant", content: streamText))
        await sink?.agentRuntime(self, didCompleteAssistantStep: streamText)
        await transition(to: .verifying)
        messages.append(ConversationMessage(
            role: "system",
            content: "Harness control: your previous response promised an immediate action but emitted no structured tool call. If that action is still required, issue the actual tool call now. If no suitable tool is available or the action is blocked, give a final answer with the exact reason. Do not merely promise another future action."
        ))
        modelTurnContinuationRequested = true
    }

    /// One tool-free self-critique pass before completion: the model reviews
    /// its own answer and may correct it. The draft is sealed first so the
    /// verification turn's output is appended as the final confirmation or
    /// correction without losing the original answer.
    private func beginFinalAnswerVerification(stopReason: AgentEvent.StopReason) async {
        didVerifyFinalAnswer = true
        forcedStopReason = stopReason
        isFinalizingWithoutTools = true
        messages.append(ConversationMessage(role: "assistant", content: streamText))
        await sink?.agentRuntime(self, didCompleteAssistantStep: streamText)
        await transition(to: .verifying)
        messages.append(ConversationMessage(
            role: "system",
            content: "Harness control: review your just-given answer for correctness, omissions, and clarity. If it is already accurate and complete, reply with exactly CONFIRM. Otherwise give only the corrected final answer. Do not call any tool."
        ))
        modelTurnContinuationRequested = true
    }

    /// Terminal resolution of one tool call after the budget, catalog, gate
    /// and approval-policy passes.
    private enum ToolResolution {
        case approved(grant: ApprovalGrant)
        case denied(reason: String, decision: String)
        case stopped(reason: String)
        case budgetExhausted
    }

    /// Resolves a single tool call through the budget, catalog, catastrophic
    /// gate and approval policy. Approval escalation blocks here (the runtime
    /// waits for the human decision), so this phase must always run serially —
    /// never inside a concurrent task group.
    private func resolveToolCall(_ call: ToolCall) async -> ToolResolution {
        await publishLiveness(
            phase: .resolvingTool,
            message: "Resolving tool authorization and safety policy for \(call.toolName)",
            isRecoverable: true
        )
        do {
            try await budgetLedger.reserveParentIteration()
            toolStepCount += 1
        } catch {
            return .budgetExhausted
        }
        guard let descriptor = executor.descriptor(named: call.toolName) else {
            return .denied(
                reason: "Unknown tool '\(call.toolName)' — not in catalog",
                decision: "deny:not-in-catalog"
            )
        }
        let effectiveAllowedNames: Set<String>?
        if let configured = configuration.allowedToolNames {
            effectiveAllowedNames = configured
        } else {
            effectiveAllowedNames = configuration.activeSkillIDs.isEmpty ? nil : []
        }
        if let effectiveAllowedNames, !effectiveAllowedNames.contains(call.toolName) {
            return .denied(
                reason: "Tool '\(call.toolName)' is outside the active skill capability set",
                decision: "deny:skill-capability"
            )
        }
        let statefulRouteGoal = messages.last(where: { $0.role == "user" })?.content ?? ""
        if let reason = executionLedger.statefulToolDenialReason(
            for: call.toolName,
            userGoal: statefulRouteGoal
        ) {
            return .denied(reason: reason, decision: "deny:stateful-prerequisite")
        }
        if configuration.conversationMode == .plan,
           let denial = PlanToolPolicy().denialResult(call: call, descriptor: descriptor) {
            return .denied(reason: denial.outputSummary, decision: "deny:plan-read-only")
        }
        if descriptor.requiresHostScope, case .local = call.scope {
            return .denied(
                reason: "Remote tool call is missing a valid hostID scope",
                decision: "deny:missing-remote-scope"
            )
        }
        let action = ProposedAction(
            toolCall: call,
            riskLabels: Set(descriptor.riskLabels.map(\.rawValue)),
            userGoal: messages.last(where: { $0.role == "user" })?.content ?? "",
            recentContext: Self.approvalContext(from: messages),
            hostAndPathScope: call.scope,
            preapprovedPythonScriptSHA256: configuration.preapprovedPythonScriptSHA256,
            preapprovedPythonPackages: configuration.preapprovedPythonPackages
        )
        // Catastrophic gate runs before every policy.
        if let gate, let command = extractCommandString(from: call) {
            let verdict = gate.evaluate(command: command)
            if verdict.stopped {
                let patternID = verdict.matchedPatternID ?? "gate"
                return .stopped(reason: verdict.reason ?? patternID)
            }
        }
        // A human can deliberately choose a task/project/host scope on the
        // inline approval card. Reuse that non-single-use grant for later
        // matching calls in this activation instead of asking for the same
        // authority on every SSH/bootstrap step. The catastrophic gate above
        // still evaluates every concrete command, including reused grants.
        let authorizationIdentity = descriptor.authorizationIdentity
        if let reusableGrant = grants.last(where: {
            !$0.scope.singleUse && !$0.isExpired()
                && Self.scopePermits(
                    $0.scope,
                    call: call,
                    currentAuthorizationIdentity: authorizationIdentity
                )
        }) {
            logger.info(
                "toolDecision run=\(runID.uuidString) tool=\(call.toolName) policy=\(reusableGrant.policyName) decision=reuseGrant"
            )
            return .approved(grant: reusableGrant)
        }
        let decision: ApprovalDecision
        let requiresModelReview = (policy as? any ApprovalReviewRouting)?
            .requiresModelReview(action) ?? (policy.policyName == "approval-model")
        if !descriptor.isSideEffecting, !requiresModelReview {
            decision = .allow(scope: Self.approvalScope(for: call), expiresAt: nil)
        } else {
            if requiresModelReview {
                await sink?.agentRuntime(
                    self,
                    didChangeApprovalReview: .init(
                        callID: call.id,
                        toolName: call.toolName,
                        isEvaluating: true
                    )
                )
            }
            do {
                decision = try await policy.decide(action)
            } catch {
                decision = .escalateToHuman(reason: "Policy error: \(error.localizedDescription)")
            }
            if requiresModelReview {
                let outcomeSummary: String = switch decision {
                case .allow:
                    "已通过：该操作在当前任务授权和安全边界内。"
                case .deny(let reason):
                    "未通过：\(reason)"
                case .escalateToHuman(let reason):
                    "需要确认：\(reason)"
                case .stopped(let gateReason):
                    "已阻止：\(gateReason)"
                }
                await sink?.agentRuntime(
                    self,
                    didChangeApprovalReview: .init(
                        callID: call.id,
                        toolName: call.toolName,
                        isEvaluating: false,
                        outcomeSummary: outcomeSummary
                    )
                )
            }
        }
        logger.info("toolDecision run=\(runID.uuidString) tool=\(call.toolName) policy=\(policy.policyName) decision=\(decision.logLabel)")
        switch decision {
        case .allow(let scope, let expiresAt):
            return .approved(grant: ApprovalGrant(
                scope: Self.bind(scope, to: authorizationIdentity),
                expiresAt: expiresAt,
                policyName: policy.policyName
            ))
        case .deny(let reason):
            return .denied(reason: reason, decision: "deny:\(reason)")
        case .escalateToHuman(let reason):
            await transition(to: .waitingApproval(AgentState.WaitingApproval(toolCall: call, reason: reason)))
            let humanDecision = await withCheckedContinuation {
                (continuation: CheckedContinuation<ApprovalDecision, Never>) in
                approvalContinuation = continuation
            }
            guard case .waitingApproval = state else {
                return .denied(reason: "Cancelled while waiting for approval", decision: "deny:cancelled")
            }
            switch humanDecision {
            case .allow(let scope, let expiresAt):
                return .approved(grant: ApprovalGrant(
                    scope: Self.bind(scope, to: authorizationIdentity),
                    expiresAt: expiresAt,
                    policyName: "human"
                ))
            case .deny(let denyReason):
                return .denied(reason: denyReason, decision: "deny:human:\(denyReason)")
            case .escalateToHuman, .stopped:
                return .denied(reason: "Approval not granted", decision: "deny:unresolved")
            }
        case .stopped(let gateReason):
            return .stopped(reason: gateReason)
        }
    }

    /// Recent conversational evidence supplied to the approval classifier.
    /// Tool output and user text are deliberately bounded so one decision
    /// cannot expand the provider request without limit.
    private static func approvalContext(from messages: [ConversationMessage]) -> String {
        let projected = messages.suffix(12).map { message in
            "\(message.role): \(String(message.content.prefix(1200)))"
        }.joined(separator: "\n")
        return String(projected.suffix(8192))
    }

    /// Resolves the run-scoped plan hand-off without registering it in the
    /// process-global tool registry. The caller still pairs the assistant
    /// tool call with this result in provider history.
    private func planSubmissionResult(for call: ToolCall) -> ToolResult {
        do {
            let submission = try JSONDecoder().decode(
                PlanSubmission.self,
                from: call.argumentsJSON
            )
            if submission.validationErrors.isEmpty {
                return ToolResult(
                    callID: call.id,
                    status: .ok,
                    outputSummary: "Plan submitted for user review. Briefly summarize it, then stop.",
                    outputDigest: ""
                )
            }
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "Plan is incomplete: \(submission.validationErrors.joined(separator: ", ")). Repair and submit again.",
                outputDigest: ""
            )
        } catch {
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "Invalid plan.submit payload: \(error.localizedDescription)",
                outputDigest: ""
            )
        }
    }

    /// Executes one approved call (with its child budget) and returns the
    /// result. Audits and emits the result before returning so the caller can
    /// never drop it. The caller owns the stream resume, which lets a batch
    /// execute several calls before advancing the model loop once.
    private func executeResolved(
        call: ToolCall,
        grant: ApprovalGrant,
        emitTransition: Bool = true
    ) async -> ToolResult {
        guard let descriptor = executor.descriptor(named: call.toolName),
              !grant.isExpired(),
              Self.scopePermits(
                grant.scope,
                call: call,
                currentAuthorizationIdentity: descriptor.authorizationIdentity
              ) else {
            let result = ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Approval scope does not permit this tool call",
                outputDigest: ""
            )
            await audit(toolCall: call, result: result, decision: "deny:scope-mismatch-or-expired")
            return result
        }

        // Idempotency: never re-execute a key already executed in this run.
        if !call.idempotencyKey.isEmpty, executedIdempotencyKeys.contains(call.idempotencyKey) {
            return ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: "Skipped: duplicate idempotency key",
                outputDigest: ""
            )
        }

        if emitTransition {
            await transition(to: .executingTool(AgentState.ExecutingInfo(toolCall: call)))
        }

        setToolLifecycle(
            call: call,
            phase: .dispatched,
            authorizationIdentity: descriptor.authorizationIdentity
        )

        // Commit the exact provider history, approval grant and pending call
        // before crossing a side-effect boundary. If persistence is
        // unavailable we must not dispatch the action: recovery could
        // otherwise replay a write whose real-world outcome is unknown.
        if descriptor.isSideEffecting {
            do {
                try await writeCheckpoint()
            } catch {
                let result = ToolResult(
                    callID: call.id,
                    status: .failed,
                    outputSummary: "Action not executed because its recovery checkpoint could not be saved: \(error.localizedDescription)",
                    outputDigest: ""
                )
                await audit(toolCall: call, result: result, decision: "deny:checkpoint-failed")
                return result
            }
        }

        // Subagent delegation opens a child slot in the shared budget ledger
        // so the subagent's iterations are charged against this run's total.
        let childBudget = await makeChildBudget(for: call)

        let context = ToolContext(
            runID: runID,
            toolCallID: call.id,
            approvalGrantID: grant.id,
            scope: call.scope,
            activeSkillIDs: configuration.activeSkillIDs,
            allowedToolNames: configuration.allowedToolNames,
            workspaceRootURL: configuration.workspaceRootURL,
            allowedWorkspacePaths: configuration.allowedWorkspacePaths,
            cancellation: cancellationToken,
            childBudget: childBudget
        )
        let result: ToolResult
        do {
            result = try await executor.execute(
                call,
                expectedAuthorizationIdentity: grant.scope.toolAuthorizationIdentity,
                context: context
            )
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
        return result
    }

    /// Atomically drains the pending tool batch (used by the stream loop when
    /// the provider closes without an explicit completion event).
    private func drainPendingToolBatch() -> [ToolCall] {
        let batch = pendingToolBatch
        pendingToolBatch = []
        return batch
    }

    /// Executes a batch of tool calls resolved from one model response.
    /// Read-only calls run in parallel; side-effecting calls act as barriers
    /// and run serially (their approval already resolved during `resolve`).
    /// Every result is audited and resumed exactly once.
    private func executeToolBatch(_ calls: [ToolCall]) async {
        guard !calls.isEmpty else { return }
        // The provider response is complete once it yields this settled tool
        // batch. Later recovery checkpoints describe the ordered call/result
        // boundary, not the already-finished request that produced it.
        await publishProviderAttempt(
            status: .completed,
            reason: "Provider completed with a settled tool batch",
            error: nil
        )
        clearCompletedProviderDispatch()
        guard Self.hasValidCallIDs(calls) else {
            await failRun(
                message: "Provider emitted empty or duplicate tool-call identifiers",
                recoverable: false
            )
            return
        }
        var approvedByID: [String: ApprovalGrant] = [:]
        var resultsByID: [String: ToolResult] = [:]
        var budgetWasExhausted = false
        var blockedNoProgressCallIDs: Set<String> = []
        var suppressedCallIDs: Set<String> = []
        var firstCallIDByRoute: [String: String] = [:]

        // Record the complete provider batch first. Even if the iteration
        // budget expires during resolution, every structured call must still
        // receive exactly one result.
        for call in calls {
            pendingToolCalls.append(call)
            setToolLifecycle(call: call, phase: .recorded)
            let route = ToolLoopGuard.canonicalRoute(for: call)
            if let firstCallID = firstCallIDByRoute[route] {
                let duplicate = ToolResult(
                    callID: call.id,
                    status: .failed,
                    outputSummary: "Harness suppression: duplicate tool request in the same model batch. The matching call \(firstCallID) is the single authoritative execution; use its result and choose a different route if it fails.",
                    outputDigest: ""
                )
                await audit(
                    toolCall: call,
                    result: duplicate,
                    decision: "deny:duplicate-batch-route"
                )
                resultsByID[call.id] = duplicate
                suppressedCallIDs.insert(call.id)
            } else {
                firstCallIDByRoute[route] = call.id
            }
        }

        // Phase 1 — resolve serially (approval escalation blocks).
        for call in calls {
            if resultsByID[call.id] != nil { continue }
            if budgetWasExhausted {
                let skipped = ToolResult(
                    callID: call.id,
                    status: .failed,
                    outputSummary: "Not dispatched because the activation iteration budget was already exhausted.",
                    outputDigest: ""
                )
                await audit(toolCall: call, result: skipped, decision: "deny:harness-budget")
                resultsByID[call.id] = skipped
                continue
            }
            if let guardrail = loopGuard.blockDecision(for: call) {
                let blocked = ToolResult(
                    callID: call.id,
                    status: .failed,
                    outputSummary: "Harness suppression: " + guardrail.message,
                    outputDigest: ""
                )
                await audit(
                    toolCall: call,
                    result: blocked,
                    decision: "deny:nonretryable-route"
                )
                resultsByID[call.id] = blocked
                suppressedCallIDs.insert(call.id)
                if guardrail.shouldStop {
                    blockedNoProgressCallIDs.insert(call.id)
                }
                continue
            }
            if resumedFromCheckpoint,
               let recovered = executionLedger.recoveredResult(for: call) {
                // A provider can regenerate a completed call after a stream
                // interruption. Preserve the provider pairing, but do not
                // cross the executor/approval boundary a second time.
                resultsByID[call.id] = recovered
                continue
            }
            // plan.submit is an internal, run-scoped persistence hand-off and
            // is not part of the batch/parallel path.
            if configuration.conversationMode == .plan,
               call.toolName == PlanSubmission.toolName {
                resultsByID[call.id] = planSubmissionResult(for: call)
                continue
            }
            switch await resolveToolCall(call) {
            case .approved(let grant):
                grants.append(grant)
                approvedByID[call.id] = grant
                setToolLifecycle(
                    call: call,
                    phase: .approved,
                    authorizationIdentity: grant.scope.toolAuthorizationIdentity
                )
            case .denied(let reason, let decision):
                let result = ToolResult(callID: call.id, status: .denied, outputSummary: reason, outputDigest: "")
                await audit(toolCall: call, result: result, decision: decision)
                resultsByID[call.id] = result
            case .stopped(let reason):
                let result = ToolResult(callID: call.id, status: .denied, outputSummary: "Stopped: \(reason)", outputDigest: "")
                await audit(toolCall: call, result: result, decision: "stopped:\(reason)")
                resultsByID[call.id] = result
            case .budgetExhausted:
                let exhausted = ToolResult(
                    callID: call.id,
                    status: .failed,
                    outputSummary: "The activation iteration budget is exhausted. Summarize the work completed, evidence collected, and any remaining limitations without calling more tools.",
                    outputDigest: ""
                )
                await audit(toolCall: call, result: exhausted, decision: "deny:harness-budget")
                resultsByID[call.id] = exhausted
                budgetWasExhausted = true
            }
        }

        // Phase 2 — execute approved calls.
        if let first = calls.first(where: { approvedByID[$0.id] != nil }) {
            await transition(to: .executingTool(AgentState.ExecutingInfo(
                toolCall: first
            )))
        }
        // Preserve provider order: consecutive reads may run in parallel, but
        // every write is a barrier before and after its position in the batch.
        var pendingReads: [(call: ToolCall, grant: ApprovalGrant)] = []
        for call in calls {
            guard let grant = approvedByID[call.id] else { continue }
            let isReadOnly = executor.descriptor(named: call.toolName)?.isSideEffecting == false
            if isReadOnly {
                pendingReads.append((call, grant))
                continue
            }
            if !pendingReads.isEmpty {
                for item in await executeApprovedInParallel(pendingReads) {
                    resultsByID[item.call.id] = item.result
                }
                pendingReads.removeAll(keepingCapacity: true)
            }
            resultsByID[call.id] = await executeResolved(
                call: call, grant: grant, emitTransition: false
            )
        }
        if !pendingReads.isEmpty {
            for item in await executeApprovedInParallel(pendingReads) {
                resultsByID[item.call.id] = item.result
            }
        }

        // Phase 3 — settle the whole provider batch as one durable step.
        // Individual checkpoints here are unsafe: if [read, read, write,
        // read] finishes and the process dies after committing only the first
        // result, recovery would correctly mark the other already-executed
        // calls outcome-unknown and force redundant verification. Commit the
        // complete ordered call/result set before publishing any result card
        // or asking the provider for the next step.
        await publishLiveness(
            phase: .persisting,
            message: "Committing the complete ordered tool batch before continuing",
            isRecoverable: true
        )
        var orderedResults: [(call: ToolCall, result: ToolResult)] = []
        var needsUserResult: ToolResult?
        var noProgressDetected = false
        for call in calls {
            var result = resultsByID[call.id] ?? ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "Harness failed to settle this tool call; no result was produced.",
                outputDigest: ""
            )
            result = finalizeToolResult(result, for: call)
            if result.status == .needsUser {
                needsUserResult = needsUserResult ?? result
            } else if !suppressedCallIDs.contains(call.id),
                      let guardrail = loopGuard.record(
                call: call,
                result: result,
                isSideEffecting: executor.descriptor(named: call.toolName)?.isSideEffecting == true,
                stopLimit: configuration.unchangedToolOutcomeLimit
            ) {
                noProgressDetected = noProgressDetected || guardrail.shouldStop
                result.outputSummary += "\n\nHarness warning: \(guardrail.message)"
            }
            if blockedNoProgressCallIDs.contains(call.id) {
                noProgressDetected = true
            }
            pendingToolResults.append(result)
            executionLedger.record(
                call: call,
                result: result,
                isSideEffecting: executor.descriptor(named: call.toolName)?.isSideEffecting == true
            )
            setToolLifecycle(call: call, phase: .resultCommitted)
            orderedResults.append((call, result))
        }
        do {
            try await writeCheckpoint()
        } catch {
            await failRun(
                message: "Unable to save the tool-batch settlement checkpoint: \(error.localizedDescription)",
                recoverable: true
            )
            return
        }

        // Publication follows persistence and preserves provider order.
        for item in orderedResults {
            await emit(.toolResult(item.result))
        }

        if let needsUserResult {
            waitingForUserAction = true
            modelTurnContinuationRequested = false
            do {
                await transition(to: .checkpointed(AgentState.CheckpointRef(
                    reason: needsUserResult.outputSummary.isEmpty
                        ? "工具需要你完成操作后继续"
                        : needsUserResult.outputSummary
                )))
                try await writeCheckpoint()
            } catch {
                await failRun(
                    message: "Unable to save the user-action checkpoint: \(error.localizedDescription)",
                    recoverable: true
                )
            }
            return
        }
        if budgetWasExhausted {
            await beginForcedFinalization(with: nil, stopReason: .budgetLimited)
        } else if noProgressDetected {
            await beginForcedFinalization(with: nil, stopReason: .noProgress)
        } else {
            modelTurnContinuationRequested = true
        }
    }

    private static func providerToolDescription(
        _ descriptor: ToolCatalog.Descriptor
    ) -> String {
        guard !descriptor.prerequisites.isEmpty else {
            return descriptor.toolDescription
        }
        let requirements = descriptor.prerequisites.map { prerequisite in
            let resolver: String
            if let resolverToolName = prerequisite.resolverToolName {
                resolver = "; resolve explicitly with " + resolverToolName
                    + " before this tool"
            } else {
                resolver = "; no automatic resolver is available"
            }
            return "Requires state " + prerequisite.state + resolver + "."
        }.joined(separator: " ")
        return descriptor.toolDescription + " " + requirements
    }

    /// The runtime, not a tool implementation or provider, owns provenance.
    /// This is the finalization boundary shared by serial and parallel tools.
    private func finalizeToolResult(
        _ result: ToolResult,
        for call: ToolCall
    ) -> ToolResult {
        var finalized = result
        var identity = Data(runID.uuidString.utf8)
        identity.append(Data(call.id.utf8))
        identity.append(Data(call.toolName.utf8))
        let sourceID = SHA256.hash(data: identity)
            .map { String(format: "%02x", $0) }.joined()
        finalized.provenance = ToolResultProvenance(
            sourceID: sourceID,
            toolName: call.toolName,
            runID: runID,
            taskID: configuration.conversationID,
            resourceBindings: ToolWorkflowGuidance.structuredResourceBindings(
                in: finalized.outputSummary,
                toolName: call.toolName,
                artifacts: finalized.artifacts
            )
        )
        return finalized
    }

    /// Providers still accept a string tool-result channel, so prepend one
    /// compact JSON envelope that preserves the runtime-authored bindings.
    /// The ordinary human summary follows unchanged for weak models.
    private static func modelVisibleToolResult(_ result: ToolResult) -> String {
        guard let provenance = result.provenance else { return result.outputSummary }
        let envelope: [String: Any] = [
            "trustedSourceID": provenance.sourceID,
            "toolName": provenance.toolName,
            "runID": provenance.runID.uuidString,
            "taskID": provenance.taskID?.uuidString ?? "",
            "parentCallID": provenance.parentCallID ?? "",
            "resourceBindings": provenance.resourceBindings.map {
                ["name": $0.name, "value": $0.value]
            }
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(
                  withJSONObject: envelope, options: [.sortedKeys]
              ) else { return result.outputSummary }
        return String(decoding: data, as: UTF8.self) + "\n" + result.outputSummary
    }

    /// Executes read-only calls in parallel. Context construction, audit,
    /// emission and idempotency bookkeeping stay serial (actor-isolated);
    /// only the tool execution itself runs concurrently.
    private func executeApprovedInParallel(
        _ calls: [(call: ToolCall, grant: ApprovalGrant)]
    ) async -> [(call: ToolCall, result: ToolResult)] {
        var toRun: [(call: ToolCall, grant: ApprovalGrant, context: ToolContext)] = []
        var precomputed: [String: ToolResult] = [:]
        var reservedIdempotencyKeys = executedIdempotencyKeys
        for (call, grant) in calls {
            if !call.idempotencyKey.isEmpty {
                if reservedIdempotencyKeys.contains(call.idempotencyKey) {
                    precomputed[call.id] = ToolResult(
                        callID: call.id,
                        status: .ok,
                        outputSummary: "Skipped: duplicate idempotency key",
                        outputDigest: ""
                    )
                    continue
                }
                reservedIdempotencyKeys.insert(call.idempotencyKey)
            }
            let childBudget = await makeChildBudget(for: call)
            let context = ToolContext(
                runID: runID,
                toolCallID: call.id,
                approvalGrantID: grant.id,
                scope: call.scope,
                activeSkillIDs: configuration.activeSkillIDs,
                allowedToolNames: configuration.allowedToolNames,
                workspaceRootURL: configuration.workspaceRootURL,
                allowedWorkspacePaths: configuration.allowedWorkspacePaths,
                cancellation: cancellationToken,
                childBudget: childBudget
            )
            toRun.append((call, grant, context))
        }

        if !toRun.isEmpty {
            for (call, grant, _) in toRun {
                setToolLifecycle(
                    call: call,
                    phase: .dispatched,
                    authorizationIdentity: grant.scope.toolAuthorizationIdentity
                )
            }
            do {
                try await writeCheckpoint()
            } catch {
                var failedResults: [(call: ToolCall, result: ToolResult)] = []
                for item in calls {
                    let failed = ToolResult(
                        callID: item.call.id,
                        status: .failed,
                        outputSummary: "Read-only tool not dispatched because its recovery checkpoint could not be saved: \(error.localizedDescription)",
                        outputDigest: ""
                    )
                    await audit(
                        toolCall: item.call,
                        result: failed,
                        decision: "deny:checkpoint-failed"
                    )
                    failedResults.append((item.call, failed))
                }
                return failedResults
            }
        }

        let executor = self.executor
        let results = await withTaskGroup(
            of: (String, ToolResult).self,
            returning: [String: ToolResult].self
        ) { group in
            for (call, grant, context) in toRun {
                group.addTask {
                    let result: ToolResult
                    do {
                        result = try await executor.execute(
                            call,
                            expectedAuthorizationIdentity: grant.scope.toolAuthorizationIdentity,
                            context: context
                        )
                    } catch {
                        result = ToolResult(
                            callID: call.id,
                            status: .failed,
                            outputSummary: "Execution error: \(error.localizedDescription)",
                            outputDigest: ""
                        )
                    }
                    return (call.id, result)
                }
            }
            var map: [String: ToolResult] = [:]
            for await (id, result) in group {
                map[id] = result
            }
            return map
        }

        var contextsByID = Dictionary(uniqueKeysWithValues: toRun.map { ($0.call.id, $0) })
        var out: [(call: ToolCall, result: ToolResult)] = []
        for (call, _) in calls {
            if let result = precomputed[call.id] {
                out.append((call, result))
                continue
            }
            guard let (_, grant, _) = contextsByID.removeValue(forKey: call.id) else {
                continue
            }
            let result = results[call.id] ?? ToolResult(
                callID: call.id, status: .failed,
                outputSummary: "Missing execution result", outputDigest: ""
            )
            await audit(toolCall: call, result: result, decision: "allow:\(grant.policyName)")
            if !call.idempotencyKey.isEmpty {
                executedIdempotencyKeys.insert(call.idempotencyKey)
            }
            out.append((call, result))
        }
        return out
    }

    /// Opens a child slot in the shared budget ledger for a subagent
    /// delegation. Non-delegating tools get nil (no child is charged).
    private func makeChildBudget(for call: ToolCall) async -> ChildBudgetContext? {
        guard call.toolName == DelegateTool.name else { return nil }
        let childID = UUID()
        do {
            try await budgetLedger.startChild(id: childID, requestedByRunID: runID)
        } catch {
            // Fail closed. DelegateTool requires a child budget and returns a
            // structured failure without starting another provider loop.
            return nil
        }
        let ledger = budgetLedger
        return ChildBudgetContext(
            maximumIterations: ledger.budgets.maxChildIterations,
            reserve: {
                do {
                    try await ledger.reserveChildIteration(id: childID)
                    return true
                } catch {
                    return false
                }
            },
            finish: {
                await ledger.finishChild(id: childID)
            }
        )
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

    private func publishLiveness(
        phase: AgentLivenessPhase,
        message: String,
        isRecoverable: Bool,
        lastProgressAt: Date? = nil
    ) async {
        livenessSnapshot = AgentLivenessSnapshot(
            phase: phase,
            message: safeDiagnostic(message),
            attempt: providerAttemptNumber,
            retryCount: providerRetryCount,
            lastProgressAt: lastProgressAt ?? providerLastProgressAt,
            isRecoverable: isRecoverable
        )
        await sink?.agentRuntime(self, didChangeLiveness: livenessSnapshot)
    }

    private func publishLivenessForState(_ state: AgentState) async {
        switch state {
        case .preparing:
            await publishLiveness(
                phase: .preparing,
                message: "Preparing the next safe execution boundary",
                isRecoverable: true
            )
        case .streamingModel:
            await publishLiveness(
                phase: providerReceivedFirstEvent ? .streaming : .waitingForFirstEvent,
                message: providerReceivedFirstEvent
                    ? "Cloud model stream is active"
                    : "Waiting for the cloud model's first event",
                isRecoverable: true
            )
        case .waitingApproval:
            await publishLiveness(
                phase: .waitingApproval,
                message: "Waiting for approval before dispatching the requested tool",
                isRecoverable: true
            )
        case .executingTool:
            await publishLiveness(
                phase: .executingTool,
                message: "Executing an approved tool",
                isRecoverable: true
            )
        case .compacting:
            await publishLiveness(
                phase: .compacting,
                message: "Compacting conversation context before retrying the model",
                isRecoverable: true
            )
        case .verifying:
            await publishLiveness(
                phase: .verifying,
                message: "Verifying the final answer",
                isRecoverable: true
            )
        case .checkpointed, .paused, .cancelling:
            await publishLiveness(
                phase: .waitingForRecovery,
                message: "Run is parked at a durable checkpoint and can be resumed",
                isRecoverable: true
            )
        case .completed:
            await publishLiveness(
                phase: .completed,
                message: "Run completed",
                isRecoverable: false
            )
        case .failed(let failure):
            await publishLiveness(
                phase: .failed,
                message: failure.message,
                isRecoverable: failure.isRecoverable
            )
        case .idle:
            break
        }
    }

    private func publishProviderAttempt(
        status: ProviderAttemptStatus,
        reason: String?,
        error: AgentEvent.NormalizedError?,
        nextRetryAt: Date? = nil
    ) async {
        let snapshot = ProviderAttemptSnapshot(
            attempt: max(1, providerAttemptNumber),
            maxAttempts: 1 + configuration.maxProviderRetries,
            status: status,
            reason: reason.map { safeDiagnostic($0) },
            errorKind: error?.kind.rawValue,
            httpStatus: error?.httpStatus,
            startedAt: providerAttemptStartedAt,
            lastProgressAt: providerLastProgressAt,
            nextRetryAt: nextRetryAt
        )
        providerAttemptSnapshot = snapshot
        await sink?.agentRuntime(self, didChangeProviderAttempt: snapshot)
    }

    private func startProviderWatchdog(attempt: Int) {
        providerWatchdogTask?.cancel()
        let firstTimeout = configuration.providerFirstEventTimeout
        let idleTimeout = configuration.providerStreamIdleTimeout
        let reasoningIdleTimeout = configuration.providerReasoningIdleTimeout
        providerWatchdogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let timeout = await self.providerWatchdogTimeout(
                    firstTimeout: firstTimeout,
                    idleTimeout: idleTimeout,
                    reasoningIdleTimeout: reasoningIdleTimeout
                )
                let poll = min(0.25, max(0.01, timeout / 4))
                do {
                    try await Task.sleep(for: .seconds(poll))
                } catch {
                    return
                }
                let keepWatching = await self.providerWatchdogFired(
                    attempt: attempt,
                    firstTimeout: firstTimeout,
                    idleTimeout: idleTimeout,
                    reasoningIdleTimeout: reasoningIdleTimeout
                )
                if !keepWatching { return }
            }
        }
    }

    private func providerWatchdogTimeout(
        firstTimeout: TimeInterval,
        idleTimeout: TimeInterval,
        reasoningIdleTimeout: TimeInterval
    ) -> TimeInterval {
        guard providerReceivedFirstEvent else { return firstTimeout }
        return providerLastEventWasReasoning ? reasoningIdleTimeout : idleTimeout
    }

    private func providerWatchdogFired(
        attempt: Int,
        firstTimeout: TimeInterval,
        idleTimeout: TimeInterval,
        reasoningIdleTimeout: TimeInterval
    ) async -> Bool {
        guard attempt == providerAttemptNumber,
              case .streamingModel = state,
              !providerRetryRequested else { return false }
        let timeout = providerReceivedFirstEvent
            ? (providerLastEventWasReasoning ? reasoningIdleTimeout : idleTimeout)
            : firstTimeout
        let elapsed = Date().timeIntervalSince(providerLastProgressAt)
        guard timeout > 0, elapsed >= timeout else { return true }
        let message = providerReceivedFirstEvent
            ? "Cloud model stream stalled: no \(providerLastEventWasReasoning ? "reasoning progress" : "event") for \(Self.durationDescription(timeout))"
            : "Cloud model stream stalled: no first event within \(Self.durationDescription(timeout))"
        let error = AgentEvent.NormalizedError(kind: .network, providerMessage: message)
        await emit(.error(error))
        await handleProviderFailure(error)
        // A stalled AsyncStream may never finish on its own. Cancel the
        // exact in-flight consumer after reserving the retry boundary so
        // runModelTurn can advance to the scheduled reconnect.
        streamTask?.cancel()
        providerWatchdogTask?.cancel()
        return false
    }

    private func handleProviderFailure(_ error: AgentEvent.NormalizedError) async {
        let safeProviderMessage = safeDiagnostic(error.providerMessage)
        let retryable: Bool = [.network, .server, .rateLimited].contains(error.kind)
        guard retryable else {
            await publishProviderAttempt(status: .failed, reason: error.providerMessage, error: error)
            await failRun(message: safeProviderMessage, recoverable: false)
            return
        }
        guard latestProviderDispatchEnvelope != nil, providerRetryRequest != nil else {
            let message = "Cloud model request failed and no safe dispatch checkpoint is available. \(safeProviderMessage) Re-run the task to try again; no tool was replayed."
            await publishProviderAttempt(status: .failed, reason: message, error: error)
            await failRun(message: message, recoverable: true)
            return
        }
        guard providerRetryCount < configuration.maxProviderRetries else {
            let message = "Cloud model retry budget exhausted after \(providerAttemptNumber) attempt(s). Last cause: \(safeProviderMessage) Safe recovery: resume or re-run from the saved dispatch checkpoint; no tool side effect was replayed."
            await publishProviderAttempt(status: .exhausted, reason: message, error: error)
            await failRun(message: message, recoverable: true)
            return
        }
        providerRetryCount += 1
        let exponential = configuration.providerRetryBaseDelay
            * pow(2, Double(providerRetryCount - 1))
        let bounded = min(configuration.providerRetryMaxDelay, exponential)
        let jitter = bounded * configuration.providerRetryJitterRatio
            * Double.random(in: 0...1)
        providerRetryDelay = min(configuration.providerRetryMaxDelay, bounded + jitter)
        let retryAt = Date().addingTimeInterval(providerRetryDelay)
        let reason = "\(safeProviderMessage) Retrying from the last safe dispatch checkpoint; completed tools will not be replayed."
        await publishProviderAttempt(
            status: .retryScheduled,
            reason: reason,
            error: error,
            nextRetryAt: retryAt
        )
        await publishLiveness(
            phase: .retrying,
            message: reason,
            isRecoverable: true
        )
        streamText = ""
        responseReasoning = ""
        pendingToolBatch.removeAll(keepingCapacity: true)
        modelTurnContinuationRequested = true
        providerRetryRequested = true
    }

    private func safeDiagnostic(_ value: String) -> String {
        String(SecretRedactor.redact(value, secret: credentials.apiKey).prefix(500))
    }

    private static func durationDescription(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int(seconds * 1_000))ms" }
        return "\(String(format: "%.1f", seconds))s"
    }

    private func completeRun(stopReason: AgentEvent.StopReason) async {
        // A verification pass that answers with a bare confirmation should
        // not append "CONFIRM" onto the already-sealed draft answer.
        let isConfirmation = didVerifyFinalAnswer
            && streamText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "CONFIRM"
        if !streamText.isEmpty, !isConfirmation {
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
                    budget: Self.contextCompressionPolicy(
                        configuration: configuration,
                        messages: messages
                    ).budget,
                    protection: ContextProtection(
                        messageIDs: latestUserID.map { [$0] } ?? []
                    )
                ),
                force: force
            )
            do {
                let result = try await contextEngine.compact(request)
                messages = result.messages
                return
            } catch {
                logger.warning(
                    "contextHistoryFallback run=\(runID.uuidString) forced=\(force) error=\(error.localizedDescription)"
                )
            }
        }
        let system = messages.filter { $0.role == "system" }
        let rest = messages.filter { $0.role != "system" }
        messages = system + rest.suffix(8)
    }

    // MARK: Checkpoint persistence

    private func writeCheckpoint() async throws {
        await publishLiveness(
            phase: .persisting,
            message: "Persisting a recovery checkpoint",
            isRecoverable: true
        )
        guard let checkpointStore else {
            await publishLivenessForState(state)
            return
        }
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
        // Do not persist `streamText`: it is an uncommitted fragment from a
        // provider stream that may have been cancelled mid-token. Replaying it
        // as an assistant message loses the real continuation point and makes
        // the model repeat completed work. Committed assistant steps already
        // live in `messages`.
        let checkpointMessages = messages
        let iterationSnapshot = await budgetLedger.snapshot()
        let checkpoint = AgentCheckpoint(
            runID: runID,
            conversationID: configuration.conversationID,
            state: persistedState,
            messages: checkpointMessages,
            pendingToolCalls: activeProviderPendingCalls.isEmpty
                ? pendingToolCalls : activeProviderPendingCalls,
            pendingToolResults: activeProviderPendingCalls.isEmpty
                ? pendingToolResults : activeProviderPendingResults,
            approvals: grants,
            idempotencyKeys: executedIdempotencyKeys,
            conversationMode: configuration.conversationMode,
            contextCompaction: latestContextCompaction,
            parentIterationCount: iterationSnapshot.parent,
            totalIterationCount: iterationSnapshot.total,
            executionLedgerEntries: executionLedger.checkpointRecords(),
            toolLifecycleEntries: toolLifecycleByCallID.values.sorted {
                if $0.updatedAt == $1.updatedAt { return $0.callID < $1.callID }
                return $0.updatedAt < $1.updatedAt
            },
            providerDispatchEnvelope: latestProviderDispatchEnvelope,
            providerDispatchRequest: latestProviderDispatchRequest
        )
        let invariantViolations = HarnessInvariantRegistry.validateCheckpoint(checkpoint)
        guard invariantViolations.isEmpty else {
            throw FloeError.validationFailed(
                "Harness checkpoint invariant failed: \(HarnessInvariantRegistry.summary(invariantViolations))"
            )
        }
        try await checkpointStore.save(checkpoint)
        await publishLivenessForState(state)
    }

    private func setToolLifecycle(
        call: ToolCall,
        phase: AgentToolLifecyclePhase,
        authorizationIdentity: String? = nil
    ) {
        let prior = toolLifecycleByCallID[call.id]
        if let prior {
            guard prior.toolName == call.toolName else {
                logger.error(
                    "toolLifecycleIdentityMismatch run=\(runID.uuidString) call=\(call.id) expected=\(prior.toolName) actual=\(call.toolName)"
                )
                return
            }
            guard Self.lifecycleOrder(phase) >= Self.lifecycleOrder(prior.phase) else {
                logger.error(
                    "toolLifecyclePhaseRegression run=\(runID.uuidString) call=\(call.id) from=\(prior.phase.rawValue) to=\(phase.rawValue)"
                )
                return
            }
            if let priorIdentity = prior.authorizationIdentity,
               let authorizationIdentity,
               priorIdentity != authorizationIdentity {
                logger.error(
                    "toolLifecycleAuthorizationChanged run=\(runID.uuidString) call=\(call.id)"
                )
                return
            }
            if let priorContext = prior.executorContextFingerprint,
               priorContext != executorContextFingerprint(for: call) {
                logger.error(
                    "toolLifecycleExecutorContextChanged run=\(runID.uuidString) call=\(call.id)"
                )
                return
            }
        }
        toolLifecycleByCallID[call.id] = AgentToolLifecycleEntry(
            callID: call.id,
            toolName: call.toolName,
            authorizationIdentity: authorizationIdentity ?? prior?.authorizationIdentity,
            executorContextFingerprint: prior?.executorContextFingerprint
                ?? executorContextFingerprint(for: call),
            phase: phase,
            updatedAt: Date()
        )
        // Keep the checkpoint bounded while retaining every currently pending
        // call and the most recent completed boundaries.
        if toolLifecycleByCallID.count > 64 {
            let pendingIDs = Set(pendingToolCalls.map(\.id))
            let removable = toolLifecycleByCallID.values
                .filter { !pendingIDs.contains($0.callID) && $0.phase == .resultCommitted }
                .sorted { $0.updatedAt < $1.updatedAt }
            for entry in removable.prefix(toolLifecycleByCallID.count - 64) {
                toolLifecycleByCallID.removeValue(forKey: entry.callID)
            }
        }
    }

    private func executorContextFingerprint(for call: ToolCall) -> String {
        let scope: String = switch call.scope {
        case .local: "local"
        case .host(let id): "host:\(id.uuidString)"
        case .hostPath(let id, let path): "hostPath:\(id.uuidString):\(path)"
        }
        let root = configuration.workspaceRootURL?.standardizedFileURL.path ?? "none"
        let ceilings = configuration.allowedWorkspacePaths.sorted().joined(separator: "|")
        let value = "\(scope)\n\(root)\n\(ceilings)"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func lifecycleOrder(_ phase: AgentToolLifecyclePhase) -> Int {
        switch phase {
        case .recorded: 0
        case .approved: 1
        case .dispatched: 2
        case .resultCommitted: 3
        }
    }

    private static func promptAssemblyDigest(
        messages: [(role: String, content: String)],
        descriptors: [ToolCatalog.Descriptor]
    ) -> String {
        var material = messages.map { "\($0.role):\($0.content)" }.joined(separator: "\n")
        material += descriptors.sorted { $0.name < $1.name }.map {
            "\n\($0.name):\($0.authorizationIdentity)"
        }.joined()
        return String(
            SHA256.hash(data: Data(material.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(16)
        )
    }

    private static func dispatchEnvelope(
        request: ProviderStreamRequest,
        conversationMode: ConversationMode
    ) -> ProviderDispatchEnvelope {
        let messageMaterial: String = request.effectiveMessages.map { message -> String in
            let parts = message.content.map { part -> String in
                switch part {
                case .text(let text):
                    return "text:\(text)"
                case .imageData(let mimeType, let base64):
                    return "image:\(mimeType):\(digest(Data(base64.utf8)))"
                case .imageURL(let url):
                    return "imageURL:\(url.absoluteString)"
                }
            }.joined(separator: "|")
            return "\(message.role):\(parts)"
        }.joined(separator: "\n")
        let schemaMaterial: String = request.toolSchemas.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            if $0.description != $1.description { return $0.description < $1.description }
            return $0.parametersJSON < $1.parametersJSON
        }.map { schema -> String in
            "\(schema.name)|\(schema.description)|\(schema.parametersJSON)"
        }.joined(separator: "\n")
        return ProviderDispatchEnvelope(
            providerID: request.provider.id,
            providerKind: request.provider.kind.rawValue,
            wireProtocol: request.provider.wireProtocol.rawValue,
            modelID: request.model.id,
            remoteModelID: request.model.remoteModelID,
            conversationMode: conversationMode.rawValue,
            messagesDigest: digest(Data(messageMaterial.utf8)),
            toolSchemasDigest: digest(Data(schemaMaterial.utf8)),
            pendingCallIDs: request.pendingToolCalls.map(\.id),
            pendingResultCallIDs: request.toolResults.map(\.callID),
            reasoningDigest: request.pendingAssistantReasoning.map { digest(Data($0.utf8)) }
        )
    }

    private static func dispatchEnvelopesMatch(
        _ expected: ProviderDispatchEnvelope,
        _ actual: ProviderDispatchEnvelope
    ) -> Bool {
        expected.providerID == actual.providerID
            && expected.providerKind == actual.providerKind
            && expected.wireProtocol == actual.wireProtocol
            && expected.modelID == actual.modelID
            && expected.remoteModelID == actual.remoteModelID
            && expected.conversationMode == actual.conversationMode
            && expected.messagesDigest == actual.messagesDigest
            && expected.toolSchemasDigest == actual.toolSchemasDigest
            && expected.pendingCallIDs == actual.pendingCallIDs
            && expected.pendingResultCallIDs == actual.pendingResultCallIDs
            && expected.reasoningDigest == actual.reasoningDigest
    }

    private func clearCompletedProviderDispatch() {
        latestProviderDispatchEnvelope = nil
        latestProviderDispatchRequest = nil
        restoredProviderDispatchEnvelope = nil
        providerRetryRequest = nil
        activeProviderPendingCalls.removeAll(keepingCapacity: true)
        activeProviderPendingResults.removeAll(keepingCapacity: true)
        providerRetryCount = 0
        providerAttemptNumber = 0
        providerRetryDelay = 0
        providerRetryRequested = false
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    private static func bind(_ scope: ApprovalScope, to authorizationIdentity: String) -> ApprovalScope {
        var bound = scope
        bound.toolAuthorizationIdentity = authorizationIdentity
        return bound
    }

    private static func scopePermits(
        _ scope: ApprovalScope,
        call: ToolCall,
        currentAuthorizationIdentity: String
    ) -> Bool {
        guard scope.toolName == call.toolName else { return false }
        if let approvedIdentity = scope.toolAuthorizationIdentity {
            guard approvedIdentity == currentAuthorizationIdentity else { return false }
        } else {
            // Backward-compatible checkpoints may omit the digest. Only
            // compiled tools have stable process authority; dynamic runners
            // must receive a fresh, identity-bound approval after upgrade.
            guard ToolCatalog.descriptor(named: call.toolName) != nil else { return false }
        }
        switch call.scope {
        case .local:
            // Local tools have no host/path scope — path confinement is enforced
            // by WorkspacePathGuard, not ApprovalScope. The approval card's
            // "project" choice carries workspace paths as bookkeeping only, so it
            // must not reject a local grant (otherwise approving a local tool
            // "for this project" fails with a scope mismatch).
            return scope.hostID == nil
        case .host(let hostID):
            return scope.hostID == hostID && scope.paths.isEmpty
        case .hostPath(let hostID, let path):
            // An empty `paths` list means "no path constraint" (see
            // ApprovalScope). FullControlPolicy relies on that to authorize
            // every path on the granted host, so an empty list must pass here
            // rather than be rejected as a scope mismatch.
            return scope.hostID == hostID && (scope.paths.isEmpty || scope.paths.contains(path))
        }
    }

    /// Provider IDs are correlation and authorization identities. Accepting an
    /// empty or repeated ID would merge independent approval/result records.
    private static func hasValidCallIDs(_ calls: [ToolCall]) -> Bool {
        var seen = Set<String>()
        for call in calls {
            guard !call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(call.id).inserted else {
                return false
            }
        }
        return true
    }

    private static func contextOutputReservation(limits: ModelLimits) -> Int {
        if let configured = limits.configuredMaxOutputTokens {
            return min(configured, max(1, limits.contextTokens / 2))
        }
        return min(4_096, max(512, limits.contextTokens / 4))
    }

    private static func contextCompressionPolicy(
        configuration: Configuration,
        messages: [ConversationMessage]
    ) -> ContextCompressionPolicy {
        let reservedOutput = contextOutputReservation(limits: configuration.model.limits)
        guard configuration.provider.kind == .local else {
            return .cloud(
                contextWindowTokens: configuration.model.limits.contextTokens,
                reservedOutputTokens: reservedOutput
            )
        }
        let toolSchemaTokens: Int
        if configuration.toolsEnabled && configuration.model.capabilities.contains(.tools) {
            // LocalProviderAdapter performs intent routing and offers at most
            // a small bounded tool subset on each turn.
            toolSchemaTokens = 1_000
        } else {
            toolSchemaTokens = 0
        }
        // Inline images are not represented in ConversationMessage.content,
        // so account for them explicitly. This is deliberately conservative;
        // provider-specific token usage will refine later turns.
        let imageTokens = messages.reduce(0) { $0 + $1.images.count * 1_024 }
        return .local(
            contextWindowTokens: configuration.model.limits.contextTokens,
            reservedOutputTokens: reservedOutput,
            toolSchemaTokens: toolSchemaTokens,
            imageTokens: imageTokens
        )
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

struct ToolLoopGuardrailDecision {
    var shouldStop: Bool
    var message: String
}

/// Hermes-style per-user-turn guardrails. This deliberately compares
/// canonical arguments and observable results rather than call IDs, which
/// providers commonly regenerate on every retry.
struct ToolLoopGuard {
    private var outcomeCountsInEpoch: [String: Int] = [:]
    private var lastObservationInEpoch: String?
    private var nonretryableRoutesInEpoch: Set<String> = []
    private var blockedNonretryableRouteCounts: [String: Int] = [:]

    mutating func advanceProgressEpoch() {
        outcomeCountsInEpoch.removeAll(keepingCapacity: true)
        lastObservationInEpoch = nil
        nonretryableRoutesInEpoch.removeAll(keepingCapacity: true)
        blockedNonretryableRouteCounts.removeAll(keepingCapacity: true)
    }

    mutating func blockDecision(for call: ToolCall) -> ToolLoopGuardrailDecision? {
        let route = Self.canonicalRoute(for: call)
        guard nonretryableRoutesInEpoch.contains(route) else { return nil }
        blockedNonretryableRouteCounts[route, default: 0] += 1
        let count = blockedNonretryableRouteCounts[route, default: 0]
        return ToolLoopGuardrailDecision(
            shouldStop: count >= 2,
            message: count >= 2
                ? "This unchanged call already returned a non-retryable failure and was suppressed again. Stop this dead-end route and preserve its evidence."
                : "This unchanged call already returned a non-retryable failure in the current progress epoch. It was not executed again. Change route now by satisfying prerequisites, updating configuration, or using materially different arguments."
        )
    }

    mutating func record(
        call: ToolCall,
        result: ToolResult,
        isSideEffecting: Bool,
        stopLimit: Int = 3
    ) -> ToolLoopGuardrailDecision? {
        let arguments = Self.canonicalDigest(call.argumentsJSON)
        let observableOutput = result.outputDigest.isEmpty
            ? Self.digest(Data(result.outputSummary.utf8))
            : result.outputDigest.lowercased()
        let route = "\(call.toolName)|\(arguments)"
        let outcome = "\(result.status.rawValue)|\(observableOutput)"

        // A successful mutation, an explicit wait, or a materially changed
        // observation establishes progress and opens a fresh epoch. This
        // keeps the guard focused on unchanged retries instead of imposing a
        // hidden total-round limit on productive agent work.
        let isExplicitWait = call.toolName == "wait" || call.toolName.hasSuffix(".wait")
        if result.status == .ok,
           (isSideEffecting || isExplicitWait) {
            advanceProgressEpoch()
            return nil
        }
        let exact = "\(route)|\(outcome)"
        if let previous = lastObservationInEpoch, previous != exact {
            advanceProgressEpoch()
        }
        lastObservationInEpoch = exact

        if result.status == .failed || result.status == .denied,
           Self.isExplicitlyNonretryable(result.outputSummary) {
            nonretryableRoutesInEpoch.insert(route)
        }

        outcomeCountsInEpoch[exact, default: 0] += 1
        if outcomeCountsInEpoch[exact, default: 0] >= stopLimit {
            return ToolLoopGuardrailDecision(
                shouldStop: true,
                message: "The same tool, canonical arguments, status, and observable result repeated without intervening progress. Stop only this unchanged retry route; preserve the evidence and synthesize or choose materially different arguments."
            )
        }
        if outcomeCountsInEpoch[exact, default: 0] == 2 {
            return ToolLoopGuardrailDecision(
                shouldStop: false,
                message: "This exact tool, canonical argument set, status, and observable result has already repeated. Do not issue the unchanged call again; different arguments or a different error remain valid progress."
            )
        }
        return nil
    }

    static func canonicalRoute(for call: ToolCall) -> String {
        "\(call.toolName)|\(canonicalDigest(call.argumentsJSON))"
    }

    private static func isExplicitlyNonretryable(_ summary: String) -> Bool {
        let compact = summary.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return compact.contains(#""retryable":false"#)
            || compact.contains("retryable=false")
            || compact.contains("non-retryable")
            || compact.contains("nonretryable")
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
