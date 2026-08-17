import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
import FloeCore
import FloeTestSupport

private final class SteerBoundaryAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private struct State {
        var callCount = 0
        var requests: [ProviderStreamRequest] = []
        var first: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    }
    private let storage = AsyncLock(State())

    var requests: [ProviderStreamRequest] { storage.withLock { $0.requests } }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let call = storage.withLock { state -> Int in
                let call = state.callCount
                state.callCount += 1
                state.requests.append(request)
                if call == 0 { state.first = continuation }
                return call
            }
            if call == 0 {
                continuation.yield(.textDelta(.init(text: "First answer")))
            } else {
                continuation.yield(.textDelta(.init(text: "Guided answer")))
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
        }
    }

    func finishFirst() {
        let continuation = storage.withLock { state -> AsyncThrowingStream<AgentEvent, Error>.Continuation? in
            defer { state.first = nil }
            return state.first
        }
        continuation?.yield(.completed(.init(stopReason: .endTurn)))
        continuation?.finish()
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

@Suite("FloeAgentRuntime.RuntimeSteer")
struct RuntimeSteerTests {
    @Test("guidance waits for completion boundary and continues the same run")
    func completionBoundary() async throws {
        let adapter = SteerBoundaryAdapter()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor()
        )
        let task = Task { try await runtime.start(goal: "initial") }
        for _ in 0..<200 {
            if await runtime.state.name == "streamingModel", !adapter.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let inputID = UUID()
        let acceptance = await runtime.steer(
            .init(id: inputID, content: "change direction"),
            expectedRunID: runtime.runID
        )
        #expect(acceptance == .accepted)
        adapter.finishFirst()
        try await task.value

        #expect(await runtime.state.name == "completed")
        #expect(adapter.requests.count == 2)
        let continuedMessages = adapter.requests[1].messages
        let assistantIndex = continuedMessages.firstIndex {
            $0.role == "assistant" && $0.content == "First answer"
        }
        let steerIndex = continuedMessages.firstIndex {
            $0.role == "user" && $0.content == "change direction"
        }
        #expect(assistantIndex != nil)
        #expect(steerIndex != nil)
        if let assistantIndex, let steerIndex {
            #expect(assistantIndex < steerIndex)
        }
        #expect(adapter.requests[1].messages.contains {
            $0.role == "user" && $0.content == "change direction"
        })
    }

    @Test("expected run identity rejects stale UI delivery")
    func rejectsWrongRun() async {
        let adapter = SteerBoundaryAdapter()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor()
        )
        let result = await runtime.steer(
            .init(id: UUID(), content: "wrong"),
            expectedRunID: UUID()
        )
        guard case .rejected = result else {
            Issue.record("Expected stale run rejection")
            return
        }
    }
}
