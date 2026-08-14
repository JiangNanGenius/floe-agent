// FloeAgentRuntimeTests — ConversationRunService persistence: the run thread
// (messages, events, usage, errors) lands in the durable stores across a
// streamed conversation, without leaking secrets.

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

@Suite("FloeAgentRuntime.ConversationRunService")
struct ConversationRunServiceTests {

    private func makeStores() async throws -> (SQLiteConversationStore, SQLiteRunStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return (SQLiteConversationStore(database: database), SQLiteRunStore(database: database))
    }

    @Test("A completed streaming run persists assistant message, events and usage")
    func persistedStreamingRun() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Run", createdAt: Date(), updatedAt: Date()
        ))

        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(AgentEvent.TextDelta(text: "Hello ")),
            .textDelta(AgentEvent.TextDelta(text: "world")),
            .usage(AgentEvent.UsageReport(inputTokens: 10, outputTokens: 4)),
            .completed(AgentEvent.CompletionInfo(stopReason: .endTurn))
        ]]

        let service = ConversationRunService(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            conversationStore: conversationStore,
            runStore: runStore
        )

        try await service.start(goal: "Say hello")

        // The assistant message persisted.
        let messages = try await conversationStore.messages(conversationID: conversationID)
        #expect(messages.contains { $0.role == "user" && $0.content == "Say hello" })
        #expect(messages.contains { $0.role == "assistant" && $0.content == "Hello world" })

        // The event thread persisted in order.
        let events = try await runStore.events(runID: service.runID)
        // Stream chunks stay live-only; the canonical completed assistant
        // message is persisted once to avoid per-token write amplification.
        #expect(!events.contains { $0.kind == .assistantText })
        #expect(events.contains { $0.kind == .status })
        #expect(events.map(\.sequence) == events.map(\.sequence).sorted())

        // Usage persisted.
        let usage = try await runStore.usage(runID: service.runID)
        #expect(usage.contains { $0.inputTokens == 10 && $0.outputTokens == 4 })

        // Run reached a terminal state.
        let run = try await runStore.run(id: service.runID)
        #expect(run?.state == "completed")
        #expect(run?.endedAt != nil)
    }

    @Test("A provider error persists a structured, redacted error record")
    func persistedError() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()
        ))

        let adapter = MockAdapter()
        adapter.script = [[
            .error(AgentEvent.NormalizedError(
                kind: .rateLimited,
                providerMessage: "slow down; key sk-secretvalue123 was throttled",
                httpStatus: 429
            ))
        ]]

        let service = ConversationRunService(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            conversationStore: conversationStore,
            runStore: runStore
        )

        try await service.start(goal: "trigger error")

        let errors = try await runStore.errors(runID: service.runID)
        #expect(errors.count == 1)
        #expect(errors[0].kind == "rateLimited")
        #expect(errors[0].httpStatus == 429)
        #expect(errors[0].recoverable)
        // The secret-shaped substring is redacted before persistence.
        #expect(!errors[0].message.contains("sk-secretvalue123"))
    }

    @Test("The configured API key is redacted even when it has no known prefix")
    func configuredKeyIsRedacted() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        // Assemble a deliberately unusual credential at runtime so the fixture
        // exercises exact-value redaction without resembling a committed secret.
        let customKey = ["opaque", "key", "unusual", "shape", "4815", "1623", "42"]
            .joined(separator: "-")
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()
        ))

        let adapter = MockAdapter()
        adapter.script = [[.error(AgentEvent.NormalizedError(
            kind: .auth,
            providerMessage: "Provider echoed credential: \(customKey)",
            httpStatus: 401
        ))]]
        let service = ConversationRunService(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            credentials: ProviderCredentials(apiKey: customKey),
            conversationStore: conversationStore,
            runStore: runStore
        )

        try await service.start(goal: "trigger auth error")

        let errors = try await runStore.errors(runID: service.runID)
        #expect(errors.count == 1)
        #expect(!errors[0].message.contains(customKey))
        #expect(errors[0].message.localizedCaseInsensitiveContains("redacted"))
    }
}
