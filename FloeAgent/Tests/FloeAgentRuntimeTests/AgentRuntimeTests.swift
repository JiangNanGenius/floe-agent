// FloeAgentRuntimeTests — State machine transitions, cancellation,
// checkpoint golden file, idempotency, waitingApproval recovery.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloeTestSupport

// MARK: - Async-safe lock

/// NSLock wrapper usable from async contexts (Xcode's SDK marks raw
/// NSLock unavailable in async; os_unfair_lock via a tiny nonisolated
/// wrapper keeps tests dependency-free).
final class AsyncLock<State>: @unchecked Sendable {
    private var state: State
    private let lock = NSLock()

    init(_ state: State) {
        self.state = state
    }

    nonisolated func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

// MARK: - Mocks

/// Scripted adapter: emits a fixed event sequence per stream call.
final class MockAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private struct Storage {
        var script: [[AgentEvent]] = []
        var callCount = 0
        var requests: [ProviderStreamRequest] = []
    }
    private let storage = AsyncLock(Storage())

    var script: [[AgentEvent]] {
        get { storage.withLock { $0.script } }
        set { storage.withLock { $0.script = newValue } }
    }

    var requests: [ProviderStreamRequest] { storage.withLock { $0.requests } }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let events = storage.withLock { state -> [AgentEvent] in
            state.requests.append(request)
            let events = state.callCount < state.script.count ? state.script[state.callCount] : []
            state.callCount += 1
            return events
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

/// Scripted executor: returns queued results, or a default ok.
final class MockExecutor: ToolExecutor, @unchecked Sendable {
    private struct Storage {
        var descriptors: [String: ToolCatalog.Descriptor] = [:]
        var results: [ToolResult] = []
        var executedCalls: [ToolCall] = []
    }

    private let storage = AsyncLock(Storage())
    /// Gate for tests that need the tool to block until released.
    var executionGate: (@Sendable () async -> Void)?

    var descriptors: [String: ToolCatalog.Descriptor] {
        get { storage.withLock { $0.descriptors } }
        set { storage.withLock { $0.descriptors = newValue } }
    }

    var results: [ToolResult] {
        get { storage.withLock { $0.results } }
        set { storage.withLock { $0.results = newValue } }
    }

    var executedCalls: [ToolCall] {
        storage.withLock { $0.executedCalls }
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        storage.withLock { $0.descriptors[name] }
    }

    var allDescriptors: [ToolCatalog.Descriptor] {
        storage.withLock { state in
            state.descriptors.values.sorted { $0.name < $1.name }
        }
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        if let executionGate { await executionGate() }
        try context.cancellation.throwIfCancelled()
        let result = storage.withLock { state -> ToolResult? in
            state.executedCalls.append(call)
            return state.results.isEmpty ? nil : state.results.removeFirst()
        }
        return result ?? ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
    }
}

final class MockAuditSink: AuditSink, @unchecked Sendable {
    private let storage = AsyncLock<[AuditEntry]>([])
    var entries: [AuditEntry] { storage.withLock { $0 } }

    func record(_ entry: AuditEntry) async throws {
        storage.withLock { $0.append(entry) }
    }
}

final class MockCheckpointStore: CheckpointStore, @unchecked Sendable {
    private let storage = AsyncLock<[AgentCheckpoint]>([])
    var saved: [AgentCheckpoint] { storage.withLock { $0 } }

    func save(_ checkpoint: AgentCheckpoint) async throws {
        storage.withLock { $0.append(checkpoint) }
    }

    func load(runID: UUID) async throws -> AgentCheckpoint? {
        storage.withLock { $0.last { $0.runID == runID } }
    }
}

final class FailingCheckpointStore: CheckpointStore, @unchecked Sendable {
    func save(_ checkpoint: AgentCheckpoint) async throws {
        throw NSError(
            domain: "FloeAgentRuntimeTests.Checkpoint",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "checkpoint unavailable"]
        )
    }

    func load(runID: UUID) async throws -> AgentCheckpoint? { nil }
}

final class SecondSaveFailingCheckpointStore: CheckpointStore, @unchecked Sendable {
    private let storage = AsyncLock<(saveCount: Int, checkpoints: [AgentCheckpoint])>((0, []))

    func save(_ checkpoint: AgentCheckpoint) async throws {
        let count = storage.withLock { state -> Int in
            state.saveCount += 1
            if state.saveCount < 2 { state.checkpoints.append(checkpoint) }
            return state.saveCount
        }
        if count >= 2 {
            throw NSError(
                domain: "FloeAgentRuntimeTests.Checkpoint",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "tool dispatch checkpoint unavailable"]
            )
        }
    }

    func load(runID: UUID) async throws -> AgentCheckpoint? {
        storage.withLock { $0.checkpoints.last { $0.runID == runID } }
    }
}

final class RecordingApprovalBackend: ModelApprovalPolicy.DecisionBackend, @unchecked Sendable {
    private let storage = AsyncLock<[ProposedAction]>([])
    var actions: [ProposedAction] { storage.withLock { $0 } }

    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        storage.withLock { $0.append(action) }
        return .allow(
            scope: ApprovalScope(toolName: action.toolCall.toolName, singleUse: true),
            expiresAt: nil
        )
    }
}

final class MockSink: AgentEventSink, @unchecked Sendable {
    private let storage = AsyncLock<(transitions: [String], events: [AgentEvent])>(([], []))
    var transitions: [String] { storage.withLock { $0.transitions } }
    var events: [AgentEvent] { storage.withLock { $0.events } }

    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {
        storage.withLock { $0.transitions.append(state.name) }
    }

    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {
        storage.withLock { $0.events.append(event) }
    }
}

// MARK: - Suite

@Suite("FloeAgentRuntime.StateMachine")
struct AgentRuntimeTests {

    @Test("Automatic approval model reviews a read-only tool exactly once with context")
    func approvalModelReviewsEveryToolExactlyOnce() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "review-read"))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo",
            riskLabels: [.readsFiles],
            isSideEffecting: false
        )
        let backend = RecordingApprovalBackend()
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            policy: AutomaticApprovalPolicy(backend: backend)
        )

        try await runtime.start(goal: "inspect the current files")

        #expect(backend.actions.count == 1)
        #expect(backend.actions.first?.toolCall.toolName == "test.echo")
        #expect(backend.actions.first?.recentContext.contains("inspect the current files") == true)
        #expect(executor.executedCalls.count == 1)
    }

    private func makeRuntime(
        adapter: MockAdapter,
        model: ModelProfile? = nil,
        executor: MockExecutor = MockExecutor(),
        policy: any ApprovalPolicy = HumanApprovalPolicy(),
        audit: MockAuditSink = MockAuditSink(),
        store: any CheckpointStore = MockCheckpointStore(),
        sink: MockSink = MockSink(),
        verifyFinalAnswer: Bool = false
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: model ?? TestFixtures.testModel(providerID: provider.id),
                pauseTimeout: 0.1,
                verifyFinalAnswer: verifyFinalAnswer,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                providerRetryJitterRatio: 0
            ),
            adapter: adapter,
            policy: policy,
            executor: executor,
            auditSink: audit,
            checkpointStore: store,
            sink: sink
        )
    }

    private func registerEcho(in executor: MockExecutor, sideEffecting: Bool = false) {
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo",
            riskLabels: [],
            isSideEffecting: sideEffecting
        )
    }

    // MARK: Happy path

    @Test("idle → preparing → streamingModel → completed on endTurn")
    func happyPath() async throws {
        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(AgentEvent.TextDelta(text: "Hello")),
            .completed(AgentEvent.CompletionInfo(stopReason: .endTurn))
        ]]
        let sink = MockSink()
        let runtime = makeRuntime(adapter: adapter, sink: sink)
        try await runtime.start(goal: "say hi")
        let state = await runtime.state
        guard case .completed(let info) = state else {
            Issue.record("Expected completed, got \(state.name)")
            return
        }
        #expect(info.stopReason == .endTurn)
        #expect(sink.transitions == ["preparing", "streamingModel", "completed"])
    }

    @Test("Final-answer verification hides a bare confirmation")
    func verificationConfirmationIsNotUserVisible() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [
                .textDelta(.init(text: "Complete answer")),
                .completed(.init(stopReason: .endTurn))
            ],
            [
                .textDelta(.init(text: "CONFIRM")),
                .completed(.init(stopReason: .endTurn))
            ]
        ]
        let sink = MockSink()
        let runtime = makeRuntime(
            adapter: adapter,
            sink: sink,
            verifyFinalAnswer: true
        )

        try await runtime.start(goal: "answer carefully")

        let visibleText = sink.events.compactMap { event -> String? in
            guard case .textDelta(let delta) = event else { return nil }
            return delta.text
        }
        #expect(visibleText == ["Complete answer"])
        #expect(sink.transitions.contains("verifying"))
        #expect(adapter.requests.count == 2)
        #expect(adapter.requests[1].toolSchemas.isEmpty)
    }

    @Test("Final-answer verification publishes a correction atomically")
    func verificationCorrectionReplacesConfirmation() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [
                .textDelta(.init(text: "Draft answer")),
                .completed(.init(stopReason: .endTurn))
            ],
            [
                .textDelta(.init(text: "Corrected ")),
                .textDelta(.init(text: "answer")),
                .completed(.init(stopReason: .endTurn))
            ]
        ]
        let sink = MockSink()
        let runtime = makeRuntime(
            adapter: adapter,
            sink: sink,
            verifyFinalAnswer: true
        )

        try await runtime.start(goal: "answer carefully")

        let visibleText = sink.events.compactMap { event -> String? in
            guard case .textDelta(let delta) = event else { return nil }
            return delta.text
        }
        #expect(visibleText == ["Draft answer", "Corrected answer"])
    }

    @Test("A promised action without a structured call is repaired once")
    func deferredActionPromiseRequestsTheRealToolCall() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "promised-call")
        adapter.script = [
            [
                .textDelta(.init(text: "我现在调用 test_echo 检查：")),
                .completed(.init(stopReason: .endTurn))
            ],
            [
                .toolRequest(call),
                .completed(.init(stopReason: .toolUse))
            ],
            [
                .textDelta(.init(text: "检查完成")),
                .completed(.init(stopReason: .endTurn))
            ]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let sink = MockSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, sink: sink)

        try await runtime.start(goal: "检查当前状态")

        #expect(executor.executedCalls.map(\.id) == ["promised-call"])
        #expect(adapter.requests.count == 3)
        let repairRequest = try #require(adapter.requests.dropFirst().first)
        #expect(repairRequest.toolSchemas.contains { $0.name == "test.echo" })
        #expect(repairRequest.messages.contains {
            $0.role == "system" && $0.content.contains("promised an immediate action")
        })
        guard case .completed = await runtime.state else {
            Issue.record("Expected repaired run to complete")
            return
        }
    }

    @Test("A text-only model is never offered tool schemas")
    func textOnlyModelOmitsTools() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        var model = TestFixtures.testModel(providerID: provider.id)
        model.capabilities = [.text]
        let runtime = makeRuntime(adapter: adapter, model: model)

        try await runtime.start(goal: "hello")

        #expect(adapter.requests.count == 1)
        #expect(adapter.requests[0].toolSchemas.isEmpty)
        #expect(adapter.requests[0].pendingToolCalls.isEmpty)
    }

    @Test("Non-side-effecting tool: streaming → executing → streaming → completed")
    func nonSideEffectingToolFlow() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_1")
        adapter.script = [
            [.toolRequest(call)],
            [
                .textDelta(AgentEvent.TextDelta(text: "Done")),
                .completed(AgentEvent.CompletionInfo(stopReason: .endTurn))
            ]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let sink = MockSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, sink: sink)
        try await runtime.start(goal: "echo")
        let state = await runtime.state
        #expect(state.name == "completed")
        #expect(sink.transitions == [
            "preparing", "streamingModel", "executingTool",
            "streamingModel", "completed"
        ])
        #expect(executor.executedCalls.count == 1)
        #expect(adapter.requests.count == 2)
        #expect(adapter.requests[1].pendingToolCalls.map(\.id) == [call.id])
        #expect(adapter.requests[1].toolResults.map(\.callID) == [call.id])
        // Idempotency key assigned with run context.
        #expect(executor.executedCalls[0].idempotencyKey.count == 64)
    }

    @Test("Multiple tool calls from one response are paired exactly once")
    func toolBatchPairsEveryCallOnce() async throws {
        let adapter = MockAdapter()
        let first = try TestFixtures.toolCall(id: "batch_1")
        let second = try TestFixtures.toolCall(id: "batch_2")
        adapter.script = [
            [
                .toolRequest(first),
                .toolRequest(second),
                .completed(AgentEvent.CompletionInfo(stopReason: .endTurn))
            ],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let store = MockCheckpointStore()
        let runtime = makeRuntime(adapter: adapter, executor: executor, store: store)

        try await runtime.start(goal: "echo twice in one turn")

        #expect(executor.executedCalls.map(\.id).sorted() == [first.id, second.id])
        #expect(adapter.requests.count == 2)
        #expect(adapter.requests[1].pendingToolCalls.map(\.id) == [first.id, second.id])
        #expect(adapter.requests[1].toolResults.map(\.callID) == [first.id, second.id])
        #expect(!store.saved.contains {
            $0.pendingToolCalls.count == 2 && $0.pendingToolResults.count == 1
        })
        #expect(store.saved.contains {
            $0.pendingToolCalls.map(\.id) == [first.id, second.id]
                && $0.pendingToolResults.map(\.callID) == [first.id, second.id]
                && ($0.toolLifecycleEntries ?? []).filter {
                    [first.id, second.id].contains($0.callID)
                }.allSatisfy { $0.phase == .resultCommitted }
        })
    }

    @Test("Duplicate tool-call IDs fail closed before approval or execution")
    func duplicateToolCallIDsFailClosed() async throws {
        let adapter = MockAdapter()
        let first = try ToolCall(
            id: "duplicate",
            toolName: "test.echo",
            argumentsJSON: Data(#"{"text":"denied"}"#.utf8),
            scope: .local
        )
        let second = try ToolCall(
            id: "duplicate",
            toolName: "test.echo",
            argumentsJSON: Data(#"{"text":"allowed"}"#.utf8),
            scope: .local
        )
        adapter.script = [[
            .toolRequest(first),
            .toolRequest(second),
            .completed(AgentEvent.CompletionInfo(stopReason: .endTurn))
        ]]
        let executor = MockExecutor()
        registerEcho(in: executor, sideEffecting: true)
        let runtime = makeRuntime(adapter: adapter, executor: executor)

        try await runtime.start(goal: "attempt duplicate calls")

        #expect(await runtime.state.name == "failed")
        #expect(executor.executedCalls.isEmpty)
    }

    @Test("Empty tool-call IDs fail closed before execution")
    func emptyToolCallIDsFailClosed() async throws {
        let adapter = MockAdapter()
        let call = try ToolCall(
            id: "   ",
            toolName: "test.echo",
            argumentsJSON: Data(#"{"text":"unsafe"}"#.utf8),
            scope: .local
        )
        adapter.script = [[
            .toolRequest(call),
            .completed(AgentEvent.CompletionInfo(stopReason: .endTurn))
        ]]
        let executor = MockExecutor()
        registerEcho(in: executor, sideEffecting: true)
        let runtime = makeRuntime(adapter: adapter, executor: executor)

        try await runtime.start(goal: "attempt empty call id")

        #expect(await runtime.state.name == "failed")
        #expect(executor.executedCalls.isEmpty)
    }

    @Test("Side-effecting tool under human policy waits for approval; allow executes")
    func waitingApprovalAllow() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_2")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor, sideEffecting: true)
        let sink = MockSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, sink: sink)

        let startTask = Task { try await runtime.start(goal: "do it") }
        // Wait until waitingApproval, then allow.
        try await waitForState("waitingApproval", in: runtime)
        await runtime.resolveApproval(.allow(
            scope: ApprovalScope(toolName: "test.echo"),
            expiresAt: nil
        ))
        try await startTask.value
        let state = await runtime.state
        #expect(state.name == "completed")
        #expect(sink.transitions.contains("waitingApproval"))
        #expect(sink.transitions.contains("executingTool"))
    }

    @Test("Changing task permission mid-run re-evaluates the pending tool")
    func livePermissionChangeResumesPendingTool() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_live_permission")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor, sideEffecting: true)
        let policy = DynamicApprovalPolicy(HumanApprovalPolicy())
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            policy: policy
        )

        let startTask = Task { try await runtime.start(goal: "do it") }
        try await waitForState("waitingApproval", in: runtime)
        policy.update(to: TaskFullAccessPolicy())
        await runtime.approvalPolicyDidChange()
        try await startTask.value

        #expect(executor.executedCalls.count == 1)
        #expect(await runtime.state.name == "completed")
    }

    @Test("Side-effecting tool is not dispatched when its preflight checkpoint fails")
    func sideEffectRequiresDurableCheckpoint() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "checkpoint-write"))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor, sideEffecting: true)
        let audit = MockAuditSink()
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            audit: audit,
            // The model-dispatch barrier succeeds; the second save is the
            // side-effect pre-dispatch barrier under test.
            store: SecondSaveFailingCheckpointStore()
        )

        try await runtime.start(goal: "perform one write")

        #expect(executor.executedCalls.isEmpty)
        #expect(audit.entries.contains { $0.decision == "deny:checkpoint-failed" })
    }

    @Test("Human approval with a mismatched host scope does not execute")
    func waitingApprovalRejectsMismatchedScope() async throws {
        let adapter = MockAdapter()
        let hostID = UUID()
        let call = try ToolCall(
            id: "call_scoped",
            toolName: "test.echo",
            argumentsJSON: Data("{}".utf8),
            scope: .host(hostID)
        )
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor, sideEffecting: true)
        let audit = MockAuditSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, audit: audit)

        let startTask = Task { try await runtime.start(goal: "run remotely") }
        try await waitForState("waitingApproval", in: runtime)
        await runtime.resolveApproval(.allow(
            scope: ApprovalScope(toolName: "test.echo"),
            expiresAt: nil
        ))
        try await startTask.value

        #expect(executor.executedCalls.isEmpty)
        #expect(audit.entries.contains { $0.decision == "deny:scope-mismatch-or-expired" })
        #expect(await runtime.state.name == "completed")
    }

    @Test("HostPath call with an empty-paths scope executes (no path constraint)")
    func hostPathWithUnconstrainedScopeExecutes() async throws {
        let adapter = MockAdapter()
        let hostID = UUID()
        let call = try ToolCall(
            id: "call_hostpath",
            toolName: "test.echo",
            argumentsJSON: Data("{}".utf8),
            scope: .hostPath(hostID: hostID, path: "/var/log/app.log")
        )
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor, sideEffecting: true)
        let audit = MockAuditSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, audit: audit)

        let startTask = Task { try await runtime.start(goal: "run on a host path") }
        try await waitForState("waitingApproval", in: runtime)
        // Empty paths means "no path constraint", which is exactly what
        // FullControlPolicy emits for a fully-controlled host.
        await runtime.resolveApproval(.allow(
            scope: ApprovalScope(toolName: "test.echo", hostID: hostID),
            expiresAt: nil
        ))
        try await startTask.value

        #expect(executor.executedCalls.count == 1)
        #expect(audit.entries.allSatisfy { $0.decision != "deny:scope-mismatch-or-expired" })
        #expect(await runtime.state.name == "completed")
    }

    @Test("Deny routes tool result back into the model (waitingApproval → streamingModel)")
    func waitingApprovalDeny() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_3")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor, sideEffecting: true)
        let audit = MockAuditSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, audit: audit)
        let startTask = Task { try await runtime.start(goal: "do it") }
        try await waitForState("waitingApproval", in: runtime)
        await runtime.resolveApproval(.deny(reason: "not now"))
        try await startTask.value
        #expect(executor.executedCalls.isEmpty)
        // Denial audited.
        #expect(audit.entries.contains { $0.decision.hasPrefix("deny:") })
    }

    // MARK: Cancellation

    @Test("cancel from streamingModel → cancelling → checkpointed")
    func cancelFromStreaming() async throws {
        let adapter = MockAdapter()
        // Adapter that never finishes.
        adapter.script = [[]]
        let hanging = HangingAdapter()
        let store = MockCheckpointStore()
        let sink = MockSink()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: hanging,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: store,
            sink: sink
        )
        let startTask = Task { try await runtime.start(goal: "stream forever") }
        try await waitForState("streamingModel", in: runtime)
        await runtime.cancel()
        try await startTask.value
        let state = await runtime.state
        #expect(state.name == "checkpointed")
        #expect(sink.transitions.contains("cancelling"))
        #expect(store.saved.count == 2)
        // Persisted state downgrades to preparing.
        #expect(store.saved.last?.state.name == "preparing")
        _ = adapter
    }

    @Test("cancel from waitingApproval expires the pending approval and audits it")
    func cancelFromWaitingApproval() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_4")
        adapter.script = [[.toolRequest(call)]]
        let executor = MockExecutor()
        registerEcho(in: executor, sideEffecting: true)
        let audit = MockAuditSink()
        let store = MockCheckpointStore()
        let runtime = makeRuntime(adapter: adapter, executor: executor, audit: audit, store: store)
        let startTask = Task { try await runtime.start(goal: "do it") }
        try await waitForState("waitingApproval", in: runtime)
        await runtime.cancel()
        try await startTask.value
        let state = await runtime.state
        #expect(state.name == "checkpointed")
        #expect(audit.entries.contains { $0.decision == "deny:cancelled" })
    }

    // MARK: Checkpoint / resume

    @Test("Checkpoint v4 golden: format is stable and decode-validates")
    func checkpointGolden() async throws {
        let runID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let conversationID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let checkpoint = AgentCheckpoint(
            runID: runID,
            conversationID: conversationID,
            state: .preparing(AgentState.PreparingInfo(goal: "golden", resumedFromCheckpoint: false)),
            messages: [ConversationMessage(
                id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                role: "user",
                content: "golden",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )],
            pendingToolCalls: [],
            pendingToolResults: [],
            approvals: [],
            idempotencyKeys: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            schemaVersion: 1
        )
        let data = try checkpoint.encoded()
        // Golden field assertions (stable contract for v1 readers).
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["formatVersion"] as? Int == 4)
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["runID"] as? String == runID.uuidString)
        // Round-trip decode.
        let decoded = try AgentCheckpoint.decoded(from: data)
        #expect(decoded == checkpoint)
    }

    @Test("Checkpoint v4 preserves the provider dispatch envelope")
    func checkpointDispatchEnvelopeRoundTrip() throws {
        let envelope = ProviderDispatchEnvelope(
            providerID: UUID(),
            providerKind: "openAICompatible",
            wireProtocol: "responsesAPI",
            modelID: UUID(),
            remoteModelID: "deepseek-chat",
            conversationMode: "agent",
            messagesDigest: "messages-digest",
            toolSchemasDigest: "schemas-digest",
            pendingCallIDs: ["call-1"],
            pendingResultCallIDs: ["call-1"],
            reasoningDigest: "reasoning-digest",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "test")),
            messages: [ConversationMessage(role: "user", content: "test")],
            providerDispatchEnvelope: envelope
        )

        let decoded = try AgentCheckpoint.decoded(from: checkpoint.encoded())
        #expect(decoded.providerDispatchEnvelope == envelope)
    }

    @Test("Newer formatVersion is rejected on decode")
    func checkpointVersionRejected() {
        let json = #"{"formatVersion":99,"runID":"44444444-4444-4444-4444-444444444444","conversationID":"55555555-5555-5555-5555-555555555555","state":"idle","messages":[],"pendingToolCalls":[],"pendingToolResults":[],"approvals":[],"idempotencyKeys":[],"createdAt":0,"schemaVersion":1}"#
        #expect(throws: (any Error).self) {
            _ = try AgentCheckpoint.decoded(from: Data(json.utf8))
        }
    }

    @Test("Idempotency: re-requested tool call with same key is not re-executed")
    func idempotencyDedup() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_5")
        adapter.script = [
            [.toolRequest(call)],
            [.toolRequest(call)], // provider re-requests the same call id
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let runtime = makeRuntime(adapter: adapter, executor: executor)
        try await runtime.start(goal: "echo twice")
        // Same call ID + same run → same idempotency key → executed once.
        #expect(executor.executedCalls.count == 1)
    }

    @Test("Resume from checkpoint restores messages and continues")
    func resumeFromCheckpoint() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]
        let runtime = makeRuntime(adapter: adapter)
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(AgentState.PreparingInfo(goal: "resumed goal")),
            messages: [ConversationMessage(role: "user", content: "resumed goal")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await runtime.resume(from: checkpoint)
        let state = await runtime.state
        #expect(state.name == "completed")
    }

    @Test("Resume rejects a provider dispatch envelope that no longer matches")
    func resumeRejectsDispatchEnvelopeDrift() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        let model = TestFixtures.testModel(providerID: provider.id)
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: model),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: MockCheckpointStore()
        )
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "resume safely")),
            messages: [ConversationMessage(role: "user", content: "resume safely")],
            providerDispatchEnvelope: ProviderDispatchEnvelope(
                providerID: provider.id,
                providerKind: "wrong-provider-kind",
                wireProtocol: "wrong-wire-protocol",
                modelID: model.id,
                remoteModelID: model.remoteModelID,
                conversationMode: ConversationMode.chat.rawValue,
                messagesDigest: "wrong-messages",
                toolSchemasDigest: "wrong-tools",
                pendingCallIDs: [],
                pendingResultCallIDs: [],
                reasoningDigest: "wrong-reasoning"
            )
        )

        try await runtime.resume(from: checkpoint)

        guard case .failed(let failure) = await runtime.state else {
            Issue.record("Expected provider dispatch drift to fail closed")
            return
        }
        #expect(failure.isRecoverable)
        #expect(failure.message.contains("dispatch checkpoint"))
        #expect(adapter.requests.isEmpty)
    }

    @Test("Recovery ledger prevents a completed tool from executing twice")
    func recoveryLedgerDeduplicatesCompletedTool() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "recovered-call")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let runtime = makeRuntime(adapter: adapter, executor: executor)
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(AgentState.PreparingInfo(goal: "resume safely")),
            messages: [ConversationMessage(role: "user", content: "resume safely")],
            executionLedgerEntries: [AgentExecutionLedgerEntry(
                toolName: call.toolName,
                callFingerprint: "cbbbdcd27692",
                status: .ok,
                resultFingerprint: "result",
                excerpt: "already inspected",
                occurrenceCount: 1
            )]
        )

        try await runtime.resume(from: checkpoint)

        #expect(executor.executedCalls.isEmpty)
        #expect(await runtime.state.name == "completed")
    }

    @Test("Resume pairs an interrupted tool call before requesting the provider")
    func resumePairsInterruptedToolCall() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(.init(stopReason: .endTurn))]]
        let call = try TestFixtures.toolCall(id: "interrupted-call")
        let runtime = makeRuntime(adapter: adapter)
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "resume safely")),
            messages: [ConversationMessage(role: "user", content: "resume safely")],
            pendingToolCalls: [call],
            pendingToolResults: []
        )

        try await runtime.resume(from: checkpoint)

        let request = try #require(adapter.requests.first)
        #expect(request.pendingToolCalls.map(\.id) == [call.id])
        #expect(request.toolResults.map(\.callID) == [call.id])
        #expect(request.toolResults.first?.output.contains("outcome is unknown") == true)
    }

    @Test("Resume distinguishes a recorded call that never crossed dispatch")
    func resumeRepairsNotStartedToolWithoutUnknownOutcome() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(.init(stopReason: .endTurn))]]
        let call = try TestFixtures.toolCall(id: "recorded-not-dispatched")
        let runtime = makeRuntime(adapter: adapter)
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "resume safely")),
            messages: [ConversationMessage(role: "user", content: "resume safely")],
            pendingToolCalls: [call],
            toolLifecycleEntries: [AgentToolLifecycleEntry(
                callID: call.id,
                toolName: call.toolName,
                phase: .recorded
            )]
        )

        try await runtime.resume(from: checkpoint)

        let request = try #require(adapter.requests.first)
        #expect(request.toolResults.first?.output.contains("never dispatched") == true)
        #expect(request.toolResults.first?.output.contains("outcome is unknown") == false)
    }

    @Test("Tool results are checkpointed with the execution ledger")
    func toolResultCheckpointIncludesLedger() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "ledger-persist"))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let store = MockCheckpointStore()
        let runtime = makeRuntime(adapter: adapter, executor: executor, store: store)

        try await runtime.start(goal: "persist result boundary")

        #expect(store.saved.contains { !$0.executionLedgerEntries!.isEmpty })
        #expect(store.saved.contains {
            $0.toolLifecycleEntries?.contains { $0.phase == .resultCommitted } == true
        })
    }

    @Test("Provider server error fails the run as recoverable")
    func serverErrorFails() async throws {
        let adapter = MockAdapter()
        adapter.script = Array(repeating: [
            .error(AgentEvent.NormalizedError(kind: .server, providerMessage: "boom"))
        ], count: 4)
        let runtime = makeRuntime(adapter: adapter)
        try await runtime.start(goal: "go")
        let state = await runtime.state
        guard case .failed(let failure) = state else {
            Issue.record("Expected failed, got \(state.name)")
            return
        }
        #expect(failure.isRecoverable)
        #expect(failure.message.contains("boom"))
    }

    @Test("contextOverflow routes through compacting back to streamingModel")
    func compactionCycle() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.error(AgentEvent.NormalizedError(kind: .contextOverflow, providerMessage: "too long"))],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let sink = MockSink()
        let runtime = makeRuntime(adapter: adapter, sink: sink)
        try await runtime.start(goal: "go")
        #expect(sink.transitions.contains("compacting"))
        let state = await runtime.state
        #expect(state.name == "completed")
    }

    // MARK: Helpers

    private func waitForState(
        _ name: String,
        in runtime: FloeAgentRuntime,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await runtime.state.name == name { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for state \(name)")
    }
}

/// Adapter whose stream never terminates until cancelled.
private struct HangingAdapter: ProviderAdapter {
    let protocolKind: ModelProtocol = .openAIResponses

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            // Never yields, never finishes; termination happens via cancel.
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}
