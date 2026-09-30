// FloeAgentRuntimeTests — caller-stop terminal-state repair.
//
// Invariants under test:
//   1. A user stop mid-generation quiesces to the terminal `checkpointed`
//      state; callers never observe a transient `.cancelling` projection
//      ("committingResults"/"interrupted") as the final state.
//   2. `presentationStateName` is state-authoritative for the parked
//      terminal state: transient liveness (`.persisting` during the final
//      checkpoint write, `.waitingForRecovery` published for the park) must
//      not mask `checkpointed`.
//   3. Cloud runs share the same honest stop semantics; ordinary completion
//      gains no quiesce delay.
//
// The fixtures run through the real `ConversationRunService` and
// `AgentRuntime` with deterministic provider doubles — no local weights, no
// network.

import Foundation
import Synchronization
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime

// MARK: - Deterministic provider doubles

/// Stream that emits nothing and only terminates when its consuming task is
/// cancelled — the exact shape of an on-device generation that is still in
/// prefill when the user presses stop. Mirrors the contract the real local
/// adapter keeps: consumer cancellation terminates the stream promptly even
/// though the underlying engine stops later.
private final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var current: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class CancelGatedAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    private let started: StreamCounter
    private let onStream: (@Sendable () -> Void)?
    /// Artificial engine wind-down after the stream observes cancellation:
    /// widens the `.cancelling` window exactly like an on-device prefill that
    /// keeps running after the consumer stopped.
    private let teardownMilliseconds: UInt64

    init(
        started: StreamCounter,
        onStream: (@Sendable () -> Void)? = nil,
        teardownMilliseconds: UInt64 = 0
    ) {
        self.started = started
        self.onStream = onStream
        self.teardownMilliseconds = teardownMilliseconds
    }

    var streamCount: Int { started.current }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        // `unfolding` runs on the consuming task, so consumer cancellation
        // (the runtime's streamTask stop) terminates the stream promptly —
        // the exact contract the on-device adapter keeps when a stop lands
        // mid-prefill, while the underlying engine winds down later.
        AsyncThrowingStream {
            self.started.increment()
            self.onStream?()
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if self.teardownMilliseconds > 0 {
                // Uninterruptible wind-down: a cancelled `Task.sleep` returns
                // immediately, which would otherwise close the cancelling
                // window before any observer can land in it.
                usleep(useconds_t(self.teardownMilliseconds * 1_000))
            }
            throw CancellationError()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }

    func testConnection(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws {}
}

/// Cloud-style adapter: emits one scripted text answer per request and ends.
/// Used to prove the caller-stop quiescence does not disturb ordinary cloud
/// completion semantics.
private final class ScriptedCloudAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    let answer: String
    private let streams: StreamCounter

    init(answer: String, streams: StreamCounter) {
        self.answer = answer
        self.streams = streams
    }

    var streamCount: Int { streams.current }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            self.streams.increment()
            continuation.yield(.textDelta(.init(text: answer)))
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }

    func testConnection(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws {}
}

@available(macOS 15.4, iOS 26.0, *)
private func cancelTerminalModel(
    providerID: UUID = UUID(),
    remoteModelID: String = "cancel-terminal-model"
) -> ModelProfile {
    ModelProfile(
        providerID: providerID,
        remoteModelID: remoteModelID,
        displayName: "Synthetic terminal-state model",
        limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
        capabilities: [.text, .tools]
    )
}

@available(macOS 15.4, iOS 26.0, *)
private func terminalStateService(
    adapter: any ProviderAdapter,
    conversationID: UUID,
    retries: Int = 1
) async throws -> ConversationRunService {
    let database = try DatabaseManager.inMemory()
    try await database.migrate()
    let conversations = SQLiteConversationStore(database: database)
    try await conversations.saveConversation(.init(
        id: conversationID,
        title: "Synthetic caller-stop run",
        createdAt: Date(),
        updatedAt: Date()
    ))
    let model = cancelTerminalModel()
    return ConversationRunService(
        configuration: FloeAgentRuntime.Configuration(
            conversationID: conversationID,
            provider: ProviderProfile(
                kind: .custom,
                wireProtocol: .openAIChatCompletions,
                baseURL: URL(string: "https://example.invalid")!,
                displayName: "Synthetic"
            ),
            model: model,
            allowedToolNames: [],
            maxProviderRetries: retries,
            providerRetryBaseDelay: 0.05,
            providerRetryMaxDelay: 0.1,
            providerRetryJitterRatio: 0
        ),
        adapter: adapter,
        policy: HumanApprovalPolicy(),
        executor: TerminalStateNoExecution(),
        conversationStore: conversations,
        runStore: SQLiteRunStore(database: database)
    )
}

@available(macOS 15.4, iOS 26.0, *)
private struct TerminalStateNoExecution: ToolExecutor {
    var allDescriptors: [ToolCatalog.Descriptor] { [] }
    func descriptor(named name: String) -> ToolCatalog.Descriptor? { nil }
    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        throw FloeError.validationFailed("Synthetic caller-stop test must not execute tools")
    }
}

@available(macOS 15.4, iOS 26.0, *)
private func awaitTrue(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - Suite

@Suite("Caller-stop terminal state")
struct CancelTerminalStateTests {

    @Test("A user stop mid-generation quiesces to the terminal checkpointed state")
    @available(macOS 15.4, iOS 26.0, *)
    func userStopQuiescesToTerminalCheckpoint() async throws {
        let conversationID = UUID()
        let started = StreamCounter()
        let service = try await terminalStateService(
            adapter: CancelGatedAdapter(started: started),
            conversationID: conversationID
        )
        let runner = Task { try await service.start(goal: "运行中的长任务") }
        // The turn is genuinely in flight (prefill-shaped) before the stop.
        #expect(await awaitTrue { started.current == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await service.snapshot().isTerminal == false)

        await service.cancel()
        try await runner.value

        let snapshot = await service.snapshot()
        // Deterministic post-fix contract; pre-fix this observed
        // "interrupted" (or raced "committingResults") while durable state
        // was already checkpointed.
        #expect(snapshot.isTerminal)
        #expect(snapshot.stateName == "checkpointed")
        #expect(snapshot.checkpointReason?.isEmpty == false)
    }

    @Test("Task cancellation paired with a user stop still reports the parked state")
    @available(macOS 15.4, iOS 26.0, *)
    func pairedTaskCancellationReportsParkedState() async throws {
        // ConversationCenter.cancel cancels the owner task AND the service.
        // The model loop itself is non-throwing (provider waits are
        // `Task<Void, Never>`), so the caller cancellation never surfaces as
        // an error from `start`; the quiesce handshake is what guarantees the
        // final observation is the parked terminal state. The mid-cancel
        // observation window equals the final checkpoint-write latency
        // (device: ~3 ms between cancelling and checkpointed), which a poll
        // cannot capture deterministically; the projection defect behind the
        // "committingResults" report is pinned deterministically in
        // `checkpointedNameIgnoresLivenessMasking`.
        let conversationID = UUID()
        let started = StreamCounter()
        let service = try await terminalStateService(
            adapter: CancelGatedAdapter(
                started: started,
                teardownMilliseconds: 300
            ),
            conversationID: conversationID
        )
        let runner = Task { try await service.start(goal: "运行中的长任务") }
        #expect(await awaitTrue { started.current == 1 })
        try? await Task.sleep(for: .milliseconds(50))

        let cancelTask = Task { await service.cancel() }
        try? await Task.sleep(for: .milliseconds(30))
        runner.cancel()
        _ = try await runner.value
        await cancelTask.value

        let snapshot = await service.snapshot()
        #expect(snapshot.isTerminal)
        #expect(snapshot.stateName == "checkpointed")
    }

    @Test("A raw task cancellation without a stop ends terminal and recoverable")
    @available(macOS 15.4, iOS 26.0, *)
    func rawTaskCancellationEndsRecoverable() async throws {
        // Never paired with a stop, a mid-stream caller cancellation flows
        // through the adapter's normalized provider-failure path; with a one-
        // retry budget the run ends as a terminal recoverable failure. This is
        // pre-existing semantics (the runtime never entered `.cancelling`, so
        // the quiesce handshake is inert here): the pins are that it neither
        // hangs nor reports a false success.
        let conversationID = UUID()
        let started = StreamCounter()
        let service = try await terminalStateService(
            adapter: CancelGatedAdapter(started: started),
            conversationID: conversationID
        )
        let runner = Task { try await service.start(goal: "运行中的长任务") }
        #expect(await awaitTrue { started.current == 1 })
        try? await Task.sleep(for: .milliseconds(50))

        runner.cancel()
        _ = try await runner.value
        let snapshot = await service.snapshot()
        #expect(snapshot.isTerminal)
        #expect(snapshot.stateName == "recoveryFailed")
    }

    @Test("A checkpointed snapshot is state-authoritative over transient liveness")
    @available(macOS 15.4, iOS 26.0, *)
    func checkpointedNameIgnoresLivenessMasking() {
        // The exact failure projection this repair fixes: a terminal
        // checkpoint observed while the cancel checkpoint write still
        // published `.persisting` liveness used to read "committingResults".
        let persisting = AgentLivenessSnapshot(
            phase: .persisting,
            message: "Persisting a recovery checkpoint",
            attempt: 1,
            retryCount: 0,
            isRecoverable: true
        )
        let parked = ConversationRunService.presentationStateName(
            state: .checkpointed(AgentState.CheckpointRef(reason: "任务已由用户停止，当前进度已保存")),
            isReviewingApproval: false,
            liveness: persisting
        )
        #expect(parked == "checkpointed")

        let waiting = AgentLivenessSnapshot(
            phase: .waitingForRecovery,
            message: "Run is parked at a durable checkpoint and can be resumed",
            attempt: 1,
            retryCount: 0,
            isRecoverable: true
        )
        let parkedWaiting = ConversationRunService.presentationStateName(
            state: .checkpointed(AgentState.CheckpointRef(reason: "任务已由用户停止，当前进度已保存")),
            isReviewingApproval: false,
            liveness: waiting
        )
        #expect(parkedWaiting == "checkpointed")

        // A genuinely mid-cancel observation stays honest about committing.
        let cancelling = ConversationRunService.presentationStateName(
            state: .cancelling,
            isReviewingApproval: false,
            liveness: persisting
        )
        #expect(cancelling == "committingResults")

        // Terminal completed/failed projections keep their stop-reason names.
        let cancelled = ConversationRunService.presentationStateName(
            state: .completed(AgentState.CompletionInfo(
                stopReason: .cancelled,
                totalInputTokens: 0,
                totalOutputTokens: 0
            )),
            isReviewingApproval: false,
            liveness: waiting
        )
        #expect(cancelled == "cancelled")
    }

    @Test("Cloud completion is untouched: no quiesce delay, ordinary completed state")
    @available(macOS 15.4, iOS 26.0, *)
    func cloudCompletionStaysOrdinary() async throws {
        let conversationID = UUID()
        let streams = StreamCounter()
        let first = try await terminalStateService(
            adapter: ScriptedCloudAdapter(answer: "云端回答", streams: streams),
            conversationID: conversationID
        )
        let clock = ContinuousClock()
        let start = clock.now
        try await first.start(goal: "普通云端问题")
        let elapsed = clock.now - start
        #expect(await first.snapshot().stateName == "completed")
        // `start(goal:)` requires the idle state; a fresh service owns each
        // run (this is what ConversationCenter guarantees per launch).
        let second = try await terminalStateService(
            adapter: ScriptedCloudAdapter(answer: "云端回答", streams: streams),
            conversationID: conversationID
        )
        try await second.start(goal: "第二个普通云端问题")
        #expect(await second.snapshot().stateName == "completed")
        // No cancel was involved: the loop must not sit in any quiesce wait.
        #expect(streams.current == 2)
        #expect(elapsed < .seconds(2))
    }

    @Test("Cloud caller stop uses the same honest parked terminal state")
    @available(macOS 15.4, iOS 26.0, *)
    func cloudStopAlsoParksCheckpointed() async throws {
        let conversationID = UUID()
        let started = StreamCounter()
        let service = try await terminalStateService(
            adapter: CancelGatedAdapter(started: started),
            conversationID: conversationID
        )
        let runner = Task { try await service.start(goal: "运行中的云端任务") }
        #expect(await awaitTrue { started.current == 1 })
        try? await Task.sleep(for: .milliseconds(50))

        await service.cancel()
        try await runner.value

        let snapshot = await service.snapshot()
        #expect(snapshot.isTerminal)
        #expect(snapshot.stateName == "checkpointed")
    }
}
