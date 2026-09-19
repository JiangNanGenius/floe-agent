import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
@testable import FloePersistence
import FloeTestSupport

@Suite("FloeAgentRuntime.ProviderRecovery")
struct ProviderRecoveryTests {
    @Test("Dispatch snapshots round-trip every reasoning field without changing the request")
    func reasoningSnapshotRoundTrip() throws {
        let provider = TestFixtures.localhostProvider()
        let request = ProviderStreamRequest(provider: provider, model: TestFixtures.testModel(providerID: provider.id),
            messages: [], contentMessages: [.init(role: "assistant", content: [.text("answer")], reasoningContent: "historical reasoning")],
            pendingAssistantReasoning: "tool-batch reasoning")
        let snapshot = ProviderDispatchRequestSnapshot(request: request)
        let restored = try JSONDecoder().decode(ProviderDispatchRequestSnapshot.self, from: JSONEncoder().encode(snapshot)).request()
        #expect(restored.effectiveMessages == request.effectiveMessages)
        #expect(restored.pendingAssistantReasoning == "tool-batch reasoning")
        let message = ConversationMessage(role: "assistant", content: "answer", reasoningContent: "exact")
        #expect(try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(message)) == message)
    }

    @Test("cloud provider retry budget defaults to five reconnects")
    func defaultRetryBudgetIsFive() {
        let provider = TestFixtures.localhostProvider()
        let configuration = FloeAgentRuntime.Configuration(
            conversationID: UUID(),
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id)
        )
        #expect(configuration.maxProviderRetries == 5)
    }

    private func configuration(
        conversationID: UUID = UUID(),
        maxProviderRetries: Int = 2,
        firstEventTimeout: TimeInterval = 30
    ) -> FloeAgentRuntime.Configuration {
        let provider = TestFixtures.localhostProvider()
        return .init(
            conversationID: conversationID,
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            maxProviderRetries: maxProviderRetries,
            providerFirstEventTimeout: firstEventTimeout,
            providerStreamIdleTimeout: 30,
            providerRetryBaseDelay: 0,
            providerRetryMaxDelay: 0,
            providerRetryJitterRatio: 0
        )
    }

    @Test("429 and 5xx retry from the same dispatch boundary")
    func transientHTTPFailuresReconnect() async throws {
        for (kind, status) in [(AgentEvent.NormalizedError.Kind.rateLimited, 429), (.server, 503)] {
            let adapter = MockAdapter()
            adapter.script = [
                [.error(.init(
                    kind: kind,
                    providerMessage: "temporary provider failure",
                    httpStatus: status
                ))],
                [.textDelta(.init(text: "reconnected")), .completed(.init(stopReason: .endTurn))]
            ]
            let store = MockCheckpointStore()
            let runtime = FloeAgentRuntime(
                configuration: configuration(),
                adapter: adapter,
                policy: HumanApprovalPolicy(),
                executor: MockExecutor(),
                checkpointStore: store
            )

            try await runtime.start(goal: "recover cloud request")

            #expect(adapter.requests.count == 2)
            #expect(store.saved.count >= 2)
            #expect(await runtime.liveness().phase == .completed)
            #expect(await runtime.providerAttempt()?.status == .completed)
            #expect(await runtime.providerAttempt()?.attempt == 2)
        }
    }

    @Test("retry exhaustion reports a concrete recoverable diagnosis")
    func retryExhaustionIsActionable() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.error(.init(kind: .network, providerMessage: "offline"))],
            [.error(.init(kind: .network, providerMessage: "still offline"))],
            [.error(.init(kind: .network, providerMessage: "still offline"))]
        ]
        let runtime = FloeAgentRuntime(
            configuration: configuration(maxProviderRetries: 2),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: MockCheckpointStore()
        )

        try await runtime.start(goal: "eventually recover")

        guard case .failed(let failure) = await runtime.state else {
            Issue.record("expected retry exhaustion to fail the run")
            return
        }
        #expect(adapter.requests.count == 3)
        #expect(failure.isRecoverable)
        #expect(failure.message.contains("retry budget exhausted"))
        #expect(failure.message.contains("saved dispatch checkpoint"))
        #expect(await runtime.liveness().phase == .failed)
    }

    @Test("a settled tool is never replayed across a later provider reconnect")
    func settledToolIsNotReplayed() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "settled-before-reconnect")
        adapter.script = [
            [.toolRequest(call)],
            [.error(.init(kind: .network, providerMessage: "connection reset"))],
            [.textDelta(.init(text: "final after reconnect")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        let sink = MockSink()
        executor.descriptors[call.toolName] = .init(
            name: call.toolName,
            riskLabels: [],
            isSideEffecting: false
        )
        let runtime = FloeAgentRuntime(
            configuration: configuration(),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            checkpointStore: MockCheckpointStore(),
            sink: sink
        )

        try await runtime.start(goal: "settle once")

        #expect(executor.executedCalls.map(\.id) == [call.id])
        #expect(adapter.requests.count == 3)
        let finalTexts = sink.events.compactMap { event -> String? in
            guard case .textDelta(let delta) = event else { return nil }
            return delta.text
        }
        #expect(finalTexts.last == "final after reconnect")
    }

    @Test("Tool argument fragments keep an attempt alive without dispatching partial calls")
    func argumentProgressPreventsFalseTimeout() async throws {
        let adapter = ArgumentProgressAdapter()
        let executor = MockExecutor()
        var config = configuration(maxProviderRetries: 0, firstEventTimeout: 0.2)
        config.providerStreamIdleTimeout = 0.2
        config.providerReasoningIdleTimeout = 0.2
        let runtime = FloeAgentRuntime(configuration: config, adapter: adapter,
            policy: HumanApprovalPolicy(), executor: executor, checkpointStore: MockCheckpointStore())
        try await runtime.start(goal: "prepare a long text tool argument")
        #expect(await runtime.liveness().phase == .completed)
        #expect(await runtime.providerAttempt()?.attempt == 1)
        #expect(executor.executedCalls.isEmpty)
    }

    @Test("a missing first event triggers the watchdog and reconnects")
    func missingFirstEventReconnects() async throws {
        let adapter = NeverEndingFirstAttemptAdapter()
        let runtime = FloeAgentRuntime(
            configuration: configuration(firstEventTimeout: 0.02),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: MockCheckpointStore()
        )

        try await runtime.start(goal: "watch the first packet")

        #expect(adapter.callCount == 2)
        #expect(await runtime.liveness().phase == .completed)
        #expect(await runtime.providerAttempt()?.attempt == 2)
    }

    @Test("on-device generation is never cancelled or retried by the cloud stall watchdog")
    func localProviderIsExemptFromCloudWatchdog() async throws {
        // The benchmark and ordinary chat differ only in request context, but
        // a local MLX turn yields no provider event until prefill and decode
        // finish. A cloud first-event timeout would cancel that GPU work in
        // flight, which is the documented crash-adjacent path.
        let adapter = SlowLocalAdapter(delay: .milliseconds(300))
        let provider = localProvider()
        let config = FloeAgentRuntime.Configuration(
            conversationID: UUID(),
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            maxProviderRetries: 0,
            providerFirstEventTimeout: 0.02,
            providerStreamIdleTimeout: 0.02,
            providerReasoningIdleTimeout: 0.02
        )
        let runtime = FloeAgentRuntime(
            configuration: config,
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: MockCheckpointStore()
        )

        try await runtime.start(goal: "slow on-device turn")

        #expect(adapter.callCount == 1)
        #expect(await runtime.liveness().phase == .completed)
        #expect(await runtime.providerAttempt()?.attempt == 1)
    }

    @Test("dispatch snapshots preserve the full tool-name ceiling")
    func dispatchSnapshotPreservesToolCeiling() throws {
        let provider = TestFixtures.localhostProvider()
        let request = ProviderStreamRequest(
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            messages: [],
            allToolNames: ["video.generate", "video.models", "tools.search"]
        )
        let encoded = try JSONEncoder().encode(ProviderDispatchRequestSnapshot(request: request))
        let restored = try JSONDecoder().decode(ProviderDispatchRequestSnapshot.self, from: encoded).request()
        #expect(restored.allToolNames == ["video.generate", "video.models", "tools.search"])
    }

    private func localProvider() -> ProviderProfile {
        ProviderProfile(
            id: UUID(),
            kind: .local,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "http://127.0.0.1")!,
            displayName: "On-device models",
            isEnabled: true,
            allowsPlainHTTP: true
        )
    }

}

/// A local-style stream that stays silent longer than the configured cloud
/// watchdog timeouts before producing a complete answer.
private final class SlowLocalAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    private let calls = AsyncLock(0)
    private let delay: Duration

    init(delay: Duration) { self.delay = delay }

    var callCount: Int { calls.withLock { $0 } }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        _ = calls.withLock { value -> Int in
            value += 1
            return value
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: delay)
                continuation.yield(.textDelta(.init(text: "on-device answer")))
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

/// First request remains open until cancellation; the reconnect attempt
/// immediately returns a complete answer.
private final class NeverEndingFirstAttemptAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let calls = AsyncLock(0)

    var callCount: Int { calls.withLock { $0 } }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let call = calls.withLock { value -> Int in
            value += 1
            return value
        }
        if call == 1 {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    try? await Task.sleep(for: .seconds(60))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(.init(text: "watchdog recovered")))
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

private struct ArgumentProgressAdapter: ProviderAdapter {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for _ in 0..<30 {
                    if Task.isCancelled { continuation.finish(); return }
                    await request.onToolArgumentsProgress?()
                    try? await Task.sleep(for: .milliseconds(20))
                }
                continuation.yield(.textDelta(.init(text: "finished preparation")))
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}
