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
