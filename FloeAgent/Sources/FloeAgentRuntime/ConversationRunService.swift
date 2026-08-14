// FloeAgentRuntime — Persisted conversation run coordinator.
// See docs/ALPHA_DAILY_PLAN.md §"Agent run and approvals": a run thread
// persists assistant messages, tool events, approvals, evidence, usage and
// terminal outcomes across relaunch. This service owns one run's runtime,
// mirrors its event stream into the durable stores, and re-exposes a live
// view for the UI. It never persists provider secrets.

import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeSecurity

/// Coordinates a single agent run: starts the runtime, persists the event
/// thread, usage, errors and checkpoints, and exposes live state to the UI.
/// One instance per run. All store writes are best-effort and never block
/// the agent loop — persistence failure surfaces as a recorded error event,
/// not a crashed run.
public actor ConversationRunService {

    /// Live view of the run for the UI.
    public struct Snapshot: Sendable, Hashable {
        public var runID: UUID
        public var conversationID: UUID
        public var stateName: String
        public var streamedText: String
        /// Provider-supplied reasoning text/summary accumulated for this run.
        /// It is separate from the canonical assistant answer so clients can
        /// present it behind an explicit disclosure control.
        public var reasoningText: String
        /// True after the provider has delivered any valid stream event,
        /// including reasoning-only chunks before visible answer text.
        public var hasProviderActivity: Bool
        public var isTerminal: Bool
        /// The exact runtime payload awaiting approval. UI code must display
        /// this value rather than reconstructing authority from an event.
        public var pendingApproval: AgentState.WaitingApproval?

        public init(
            runID: UUID,
            conversationID: UUID,
            stateName: String,
            streamedText: String,
            reasoningText: String = "",
            hasProviderActivity: Bool = false,
            isTerminal: Bool,
            pendingApproval: AgentState.WaitingApproval? = nil
        ) {
            self.runID = runID
            self.conversationID = conversationID
            self.stateName = stateName
            self.streamedText = streamedText
            self.reasoningText = reasoningText
            self.hasProviderActivity = hasProviderActivity
            self.isTerminal = isTerminal
            self.pendingApproval = pendingApproval
        }
    }

    /// Run identity. Immutable, so exposed non-isolated for synchronous reads
    /// from `@MainActor` coordinators (no actor hop required for identity).
    public nonisolated let runID: UUID
    /// Conversation identity. Immutable; non-isolated for the same reason.
    public nonisolated let conversationID: UUID

    private let runtime: FloeAgentRuntime
    private let conversationStore: any ConversationStore
    private let runStore: any RunStore
    private let secretForRedaction: String?
    private let streamedTextLimitBytes: Int
    private var streamedText = ""
    private var reasoningText = ""
    private var unflushedReasoningText = ""
    private var hasProviderActivity = false
    private var latestState: AgentState = .idle

    public init(
        configuration: FloeAgentRuntime.Configuration,
        adapter: any ProviderAdapter,
        policy: any ApprovalPolicy,
        executor: any ToolExecutor,
        credentials: ProviderCredentials = ProviderCredentials(),
        gate: CatastrophicActionGate? = nil,
        auditSink: (any AuditSink)? = nil,
        checkpointStore: (any CheckpointStore)? = nil,
        conversationStore: any ConversationStore,
        runStore: any RunStore,
        runID: UUID = UUID()
    ) {
        self.runID = runID
        self.conversationID = configuration.conversationID
        self.conversationStore = conversationStore
        self.runStore = runStore
        self.secretForRedaction = credentials.apiKey
        self.streamedTextLimitBytes = max(
            65_536,
            min(8 * 1_024 * 1_024, configuration.model.limits.maxOutputTokens * 16)
        )
        // The sink forwards into the service via closures so callbacks reach
        // the actor without an access-level or retain-cycle problem.
        let forwarder = SinkForwarder()
        self.runtime = FloeAgentRuntime(
            configuration: configuration,
            adapter: adapter,
            policy: policy,
            executor: executor,
            credentials: credentials,
            gate: gate,
            auditSink: auditSink,
            checkpointStore: checkpointStore,
            sink: forwarder,
            runID: runID
        )
        forwarder.onTransition = { [weak self] state in
            await self?.handleTransition(state)
        }
        forwarder.onEvent = { [weak self] event in
            await self?.handleEvent(event)
        }
    }

    /// Current live snapshot for the UI.
    public func snapshot() -> Snapshot {
        let pendingApproval: AgentState.WaitingApproval?
        if case .waitingApproval(let waiting) = latestState {
            pendingApproval = waiting
        } else {
            pendingApproval = nil
        }
        return Snapshot(
            runID: runID,
            conversationID: conversationID,
            stateName: latestState.name,
            streamedText: streamedText,
            reasoningText: reasoningText,
            hasProviderActivity: hasProviderActivity,
            isTerminal: isTerminal(latestState),
            pendingApproval: pendingApproval
        )
    }

    /// Records the run header and starts the agent loop. The user goal is
    /// persisted as the first message and as the run's goal.
    public func start(goal: String) async throws {
        try await runStore.saveRun(RunRecord(
            id: runID,
            conversationID: conversationID,
            state: AgentState.preparing(AgentState.PreparingInfo(goal: goal)).name,
            goal: goal,
            startedAt: Date()
        ))
        let userMessageID = UUID()
        try await conversationStore.appendMessage(PersistedMessage(
            id: userMessageID,
            conversationID: conversationID,
            role: "user",
            content: goal,
            createdAt: Date(),
            parts: [MessagePart(messageID: userMessageID, partIndex: 0, kind: .text, text: goal)]
        ))
        _ = try? await runStore.appendEvent(runID: runID, kind: .status, payloadJSON: #"{"state":"preparing"}"#)
        try await runtime.start(goal: goal)
    }

    /// Cancels the run. The runtime owns the terminal transition; persistence
    /// of the checkpoint happens via the runtime's checkpoint store.
    public func cancel() async {
        await runtime.cancel()
    }

    /// Resolves a pending human approval.
    public func resolveApproval(_ decision: ApprovalDecision) async {
        await runtime.resolveApproval(decision)
    }

    // MARK: - Sink handling

    private func handleTransition(_ state: AgentState) async {
        latestState = state
        if isTerminal(state) {
            await flushReasoning()
        }
        let endedAt: Date? = isTerminal(state) ? Date() : nil
        try? await runStore.updateRunState(id: runID, state: state.name, endedAt: endedAt)
        if case .waitingApproval(let waiting) = state {
            let payload = Self.approvalPayload(waiting)
            _ = try? await runStore.appendEvent(runID: runID, kind: .approval, payloadJSON: payload)
        }
        if isTerminal(state) {
            _ = try? await runStore.appendEvent(
                runID: runID, kind: .status,
                payloadJSON: #"{"state":"\#(state.name)"}"#
            )
        }
    }

    private func handleEvent(_ event: AgentEvent) async {
        hasProviderActivity = true
        if case .reasoningSummary = event {
            // Keep adjacent streaming deltas in one durable record. Writing a
            // database row per token makes long reasoning runs impractical.
        } else {
            await flushReasoning()
        }
        switch event {
        case .textDelta(let delta):
            let remaining = max(0, streamedTextLimitBytes - streamedText.utf8.count)
            if remaining > 0 {
                streamedText += Self.utf8Prefix(delta.text, maxBytes: remaining)
            }
        case .reasoningSummary(let summary):
            let remaining = max(0, streamedTextLimitBytes - reasoningText.utf8.count)
            if remaining > 0 {
                let delta = Self.utf8Prefix(summary.text, maxBytes: remaining)
                reasoningText += delta
                unflushedReasoningText += delta
            }
        case .toolRequest(let call):
            _ = try? await runStore.appendEvent(
                runID: runID, kind: .toolRequest,
                payloadJSON: Self.jsonPayload(["tool": call.toolName, "id": call.id])
            )
        case .toolResult(let result):
            _ = try? await runStore.appendEvent(
                runID: runID, kind: .toolResult,
                payloadJSON: Self.jsonPayload(["status": result.status.rawValue, "summary": result.outputSummary])
            )
        case .usage(let report):
            try? await runStore.recordUsage(RunUsageRecord(
                runID: runID,
                inputTokens: report.inputTokens,
                outputTokens: report.outputTokens,
                costEstimate: report.costEstimate.map { "\($0)" }
            ))
        case .error(let error):
            try? await runStore.recordError(RunErrorRecord(
                runID: runID,
                kind: error.kind.rawValue,
                message: SecretRedactor.redact(error.providerMessage, secret: secretForRedaction),
                httpStatus: error.httpStatus,
                recoverable: Self.isRecoverable(error.kind)
            ))
        case .completed(let completion):
            // Persist the final assistant message on completion.
            if !streamedText.isEmpty {
                let messageID = UUID()
                try? await conversationStore.appendMessage(PersistedMessage(
                    id: messageID,
                    conversationID: conversationID,
                    role: "assistant",
                    content: streamedText,
                    createdAt: Date(),
                    parts: [MessagePart(messageID: messageID, partIndex: 0, kind: .text, text: streamedText)]
                ))
            }
            _ = try? await runStore.appendEvent(
                runID: runID, kind: .status,
                payloadJSON: Self.jsonPayload(["stopReason": completion.stopReason.rawValue])
            )
        }
    }

    // MARK: - Helpers

    private func flushReasoning() async {
        guard !unflushedReasoningText.isEmpty else { return }
        let text = unflushedReasoningText
        unflushedReasoningText = ""
        _ = try? await runStore.appendEvent(
            runID: runID,
            kind: .reasoning,
            payloadJSON: Self.jsonPayload(["text": text])
        )
    }

    private func isTerminal(_ state: AgentState) -> Bool {
        switch state {
        case .completed, .failed, .checkpointed:
            return true
        default:
            return false
        }
    }

    private static func isRecoverable(_ kind: AgentEvent.NormalizedError.Kind) -> Bool {
        switch kind {
        case .rateLimited, .server, .network, .contextOverflow:
            return true
        case .auth, .malformed, .cancelled:
            return false
        }
    }

    private static func jsonPayload(_ dictionary: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(dictionary),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func utf8Prefix(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        if value.utf8.count <= maxBytes { return value }
        var result = ""
        result.reserveCapacity(min(value.count, maxBytes))
        var used = 0
        for character in value {
            let width = String(character).utf8.count
            guard used + width <= maxBytes else { break }
            result.append(character)
            used += width
        }
        return result
    }

    private static func approvalPayload(_ waiting: AgentState.WaitingApproval) -> String {
        jsonPayload([
            "tool": waiting.toolCall.toolName,
            "callID": waiting.toolCall.id,
            "scope": scopeDescription(waiting.toolCall.scope),
            "reason": waiting.reason
        ])
    }

    private static func scopeDescription(_ scope: ToolScope) -> String {
        switch scope {
        case .local:
            return "local"
        case .host(let hostID):
            return "host:\(hostID.uuidString)"
        case .hostPath(let hostID, let path):
            return "host:\(hostID.uuidString):path:\(path)"
        }
    }
}

/// Forwards runtime sink callbacks into the service actor via closures,
/// avoiding a retain cycle (the runtime holds the sink strongly).
private final class SinkForwarder: AgentEventSink, @unchecked Sendable {
    var onTransition: (@Sendable (AgentState) async -> Void)?
    var onEvent: (@Sendable (AgentEvent) async -> Void)?

    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {
        await onTransition?(state)
    }

    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {
        await onEvent?(event)
    }
}
