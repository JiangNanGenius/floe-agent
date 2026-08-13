// FloeAgentRuntimeTests — QA state-machine edge corpus (Round 1, QA/Yan).
// Illegal transitions and terminal-state re-entry the engineer's own tests
// did not cover: start() from non-idle, cancel() from terminal states,
// pause() from non-streaming states, resume() from non-paused states,
// and re-start after completed / failed.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloeTestSupport

/// QA-local adapter whose stream never terminates until cancelled
/// (AgentRuntimeTests' HangingAdapter is file-private).
private struct QAHangingAdapter: ProviderAdapter {
    let protocolKind: ModelProtocol = .openAIResponses

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { _ in /* never yields, never finishes */ }
    }

    func listModels(credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

@Suite("QA.AgentRuntimeEdges")
struct AgentRuntimeEdgeTests {

    private func makeRuntime(
        adapter: MockAdapter,
        sink: MockSink = MockSink(),
        store: MockCheckpointStore = MockCheckpointStore()
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                pauseTimeout: 0.1
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: store,
            sink: sink
        )
    }

    @Test("start() from non-idle state throws invalidConfiguration")
    func startFromNonIdleThrows() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]
        let runtime = makeRuntime(adapter: adapter)
        try await runtime.start(goal: "first")
        #expect(await runtime.state.name == "completed")
        await #expect(throws: FloeError.self) {
            try await runtime.start(goal: "second")
        }
        // State unchanged after the rejected start.
        #expect(await runtime.state.name == "completed")
    }

    @Test("Double start() while still streaming throws")
    func doubleStartWhileStreaming() async throws {
        let adapter = MockAdapter()
        adapter.script = [[]] // HangingAdapter-like: stream with no events but finishes
        let hanging = QAHangingAdapter()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: hanging,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor()
        )
        let startTask = Task { try await runtime.start(goal: "go") }
        // Give the runtime a beat to leave idle.
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: FloeError.self) {
            try await runtime.start(goal: "again")
        }
        await runtime.cancel()
        try await startTask.value
        _ = adapter
    }

    @Test("cancel() from idle is a no-op (stays idle)")
    func cancelFromIdle() async {
        let adapter = MockAdapter()
        let sink = MockSink()
        let runtime = makeRuntime(adapter: adapter, sink: sink)
        await runtime.cancel()
        #expect(await runtime.state.name == "idle")
        #expect(sink.transitions.isEmpty)
    }

    @Test("cancel() from completed is a no-op (terminal state preserved)")
    func cancelFromCompleted() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]
        let sink = MockSink()
        let runtime = makeRuntime(adapter: adapter, sink: sink)
        try await runtime.start(goal: "go")
        #expect(await runtime.state.name == "completed")
        await runtime.cancel()
        #expect(await runtime.state.name == "completed")
        #expect(!sink.transitions.contains("cancelling"))
    }

    @Test("cancel() from failed is a no-op")
    func cancelFromFailed() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.error(AgentEvent.NormalizedError(kind: .auth, providerMessage: "bad key"))]]
        let runtime = makeRuntime(adapter: adapter)
        try await runtime.start(goal: "go")
        #expect(await runtime.state.name == "failed")
        await runtime.cancel()
        #expect(await runtime.state.name == "failed")
    }

    @Test("pause() from idle is a no-op")
    func pauseFromIdle() async {
        let adapter = MockAdapter()
        let runtime = makeRuntime(adapter: adapter)
        await runtime.pause()
        #expect(await runtime.state.name == "idle")
    }

    @Test("pause() from completed is a no-op")
    func pauseFromCompleted() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]
        let runtime = makeRuntime(adapter: adapter)
        try await runtime.start(goal: "go")
        await runtime.pause()
        #expect(await runtime.state.name == "completed")
    }

    @Test("resumeFromPause() from non-paused state is a no-op")
    func resumeFromPauseNotPaused() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]
        let runtime = makeRuntime(adapter: adapter)
        try await runtime.start(goal: "go")
        await runtime.resumeFromPause()
        #expect(await runtime.state.name == "completed")
    }

    @Test("resolveApproval() from non-waiting state is a no-op")
    func resolveApprovalOutsideWaiting() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]
        let runtime = makeRuntime(adapter: adapter)
        try await runtime.start(goal: "go")
        await runtime.resolveApproval(.allow(
            scope: ApprovalScope(toolName: "test.echo"),
            expiresAt: nil
        ))
        #expect(await runtime.state.name == "completed")
    }

    @Test("Double cancel() is idempotent")
    func doubleCancel() async throws {
        let hanging = QAHangingAdapter()
        let store = MockCheckpointStore()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: hanging,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: store
        )
        let startTask = Task { try await runtime.start(goal: "stream") }
        try await Task.sleep(for: .milliseconds(50))
        await runtime.cancel()
        await runtime.cancel() // second cancel must not crash or duplicate
        try await startTask.value
        #expect(await runtime.state.name == "checkpointed")
        #expect(store.saved.count == 1)
    }

    @Test("resume() from a checkpoint while idle runs to completion")
    func resumeWhileIdle() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]
        let runtime = makeRuntime(adapter: adapter)
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(AgentState.PreparingInfo(goal: "resumed")),
            messages: [ConversationMessage(role: "user", content: "resumed")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await runtime.resume(from: checkpoint)
        #expect(await runtime.state.name == "completed")
    }

    @Test("resume() rejects a checkpoint with a newer formatVersion")
    func resumeRejectsNewerFormat() async {
        let adapter = MockAdapter()
        let runtime = makeRuntime(adapter: adapter)
        let checkpoint = AgentCheckpoint(
            formatVersion: 99,
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(AgentState.PreparingInfo(goal: "future")),
            messages: [],
            createdAt: Date()
        )
        await #expect(throws: FloeError.self) {
            try await runtime.resume(from: checkpoint)
        }
        #expect(await runtime.state.name == "idle")
    }

    @Test("completed → cancel → checkpoint is impossible; completed is terminal")
    func completedIsTerminal() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .maxTokens))]]
        let sink = MockSink()
        let runtime = makeRuntime(adapter: adapter, sink: sink)
        try await runtime.start(goal: "go")
        guard case .completed(let info) = await runtime.state else {
            Issue.record("Expected completed")
            return
        }
        #expect(info.stopReason == .maxTokens)
        await runtime.cancel()
        await runtime.pause()
        await runtime.resumeFromPause()
        #expect(await runtime.state.name == "completed")
    }
}
