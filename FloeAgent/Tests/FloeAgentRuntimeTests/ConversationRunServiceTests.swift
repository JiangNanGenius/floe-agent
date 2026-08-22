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
            .reasoningSummary(AgentEvent.ReasoningSummary(text: "Check ")),
            .reasoningSummary(AgentEvent.ReasoningSummary(text: "the answer.")),
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
        // The final reply persists exactly once as an assistantText event,
        // ordered strictly BEFORE the terminal marker so the unified
        // timeline can never render "Completed" above the answer.
        let assistantTextEvents = events.filter { $0.kind == .assistantText }
        #expect(assistantTextEvents.count == 1)
        #expect(assistantTextEvents[0].payloadJSON.contains("Hello world"))
        if let terminal = events.last(where: { $0.kind == .terminal }) {
            #expect(assistantTextEvents[0].sequence < terminal.sequence)
            #expect(events.last?.id == terminal.id)
        } else {
            Issue.record("Expected a terminal event")
        }
        let reasoningEvents = events.filter { $0.kind == .reasoning }
        #expect(reasoningEvents.count == 1)
        #expect(reasoningEvents[0].payloadJSON.contains("Check the answer."))
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

    @Test("Resuming a prepared run keeps the original run and user turn")
    func preparedResumeDoesNotDuplicateUserTurn() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        let runID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Resume", createdAt: Date(), updatedAt: Date()
        ))
        try await runStore.saveRun(RunRecord(
            id: runID,
            conversationID: conversationID,
            state: "checkpointed",
            goal: "继续原任务",
            startedAt: Date()
        ))
        let userMessageID = UUID()
        try await conversationStore.appendMessage(PersistedMessage(
            id: userMessageID,
            conversationID: conversationID,
            role: "user",
            content: "继续原任务",
            createdAt: Date(),
            parts: [.init(
                messageID: userMessageID,
                partIndex: 0,
                kind: .text,
                text: "继续原任务"
            )],
            runID: runID
        ))

        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(.init(text: "已继续。")),
            .completed(.init(stopReason: .endTurn))
        ]]
        let service = ConversationRunService(
            configuration: .init(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            conversationStore: conversationStore,
            runStore: runStore,
            runID: runID
        )
        let checkpoint = AgentCheckpoint(
            runID: runID,
            conversationID: conversationID,
            state: .preparing(.init(goal: "继续原任务")),
            messages: [.init(role: "user", content: "继续原任务")],
            createdAt: Date()
        )

        try await service.resumePrepared(from: checkpoint)

        let messages = try await conversationStore.messages(conversationID: conversationID)
        #expect(messages.filter { $0.role == "user" }.count == 1)
        #expect(messages.contains { $0.role == "assistant" && $0.content == "已继续。" })
        #expect(try await runStore.run(id: runID)?.state == "completed")
    }

    @Test("A provider that omits streaming usage still records a conservative estimate")
    func estimatesMissingProviderUsage() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Estimated usage", createdAt: Date(), updatedAt: Date()
        ))
        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(.init(text: "这是一个可统计的回答。")),
            .completed(.init(stopReason: .endTurn))
        ]]
        let service = ConversationRunService(
            configuration: .init(
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

        try await service.start(goal: "统计这一轮")

        let usage = try await runStore.usage(runID: service.runID)
        let estimate = try #require(usage.last)
        #expect(estimate.inputTokens > 0)
        #expect(estimate.outputTokens > 0)
        #expect(estimate.costEstimate == nil)
    }

    @Test("A tool turn persists the provider's final assistant reply")
    func toolTurnPersistsFinalReply() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Tool run", createdAt: Date(), updatedAt: Date()
        ))
        let call = try TestFixtures.toolCall(id: "call_file_write")
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call)],
            [
                .textDelta(AgentEvent.TextDelta(text: "文件已写入。")),
                .completed(AgentEvent.CompletionInfo(stopReason: .endTurn))
            ]
        ]
        let executor = MockExecutor()
        executor.descriptors[call.toolName] = ToolCatalog.Descriptor(
            name: call.toolName, riskLabels: [], isSideEffecting: false
        )
        let service = ConversationRunService(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            conversationStore: conversationStore,
            runStore: runStore
        )

        try await service.start(goal: "写入文件")

        let messages = try await conversationStore.messages(conversationID: conversationID)
        #expect(messages.last(where: { $0.role == "assistant" })?.content == "文件已写入。")
        let events = try await runStore.events(runID: service.runID)
        #expect(events.contains { $0.kind == .terminal })
        #expect(!events.contains {
            $0.kind == .status && !$0.payloadJSON.contains("state")
        })
        // After a tool turn the run must still persist the final reply as
        // an assistantText event ahead of terminal.
        let assistantTextEvents = events.filter { $0.kind == .assistantText }
        #expect(assistantTextEvents.count == 1)
        #expect(assistantTextEvents[0].payloadJSON.contains("文件已写入。"))
        let terminal = try #require(events.last(where: { $0.kind == .terminal }))
        #expect(assistantTextEvents[0].sequence < terminal.sequence)
        #expect(events.last?.id == terminal.id)
    }

    @Test("Text emitted before a tool request remains before that tool in the timeline")
    func textIsSealedAtToolBoundary() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Ordered", createdAt: Date(), updatedAt: Date()
        ))
        let call = try TestFixtures.toolCall(id: "call_ordered")
        let adapter = MockAdapter()
        adapter.script = [
            [
                .reasoningSummary(.init(text: "先检查")),
                .textDelta(.init(text: "我先读取文件。")),
                .toolRequest(call)
            ],
            [
                .textDelta(.init(text: "读取完成。")),
                .completed(.init(stopReason: .endTurn))
            ]
        ]
        let executor = MockExecutor()
        executor.descriptors[call.toolName] = .init(
            name: call.toolName, riskLabels: [], isSideEffecting: false
        )
        let service = ConversationRunService(
            configuration: .init(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            conversationStore: conversationStore,
            runStore: runStore
        )

        try await service.start(goal: "检查文件")
        let events = try await runStore.events(runID: service.runID)
        let before = try #require(events.first { $0.kind == .assistantText && $0.payloadJSON.contains("我先读取") })
        let request = try #require(events.first { $0.kind == .toolRequest })
        let result = try #require(events.first { $0.kind == .toolResult })
        let after = try #require(events.first { $0.kind == .assistantText && $0.payloadJSON.contains("读取完成") })
        #expect(before.sequence < request.sequence)
        #expect(request.sequence < result.sequence)
        #expect(result.sequence < after.sequence)
    }

    @Test("A completion without final text persists an explicit error event")
    func completionWithoutFinalText() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()
        ))
        let adapter = MockAdapter()
        adapter.script = [[
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

        try await service.start(goal: "Say nothing")

        // No assistant message, no assistantText event — but an explicit
        // error row so the timeline renders "no final reply" instead of a
        // silent success.
        let messages = try await conversationStore.messages(conversationID: conversationID)
        #expect(!messages.contains { $0.role == "assistant" })
        let events = try await runStore.events(runID: service.runID)
        #expect(!events.contains { $0.kind == .assistantText })
        let errorEvents = events.filter { $0.kind == .error }
        #expect(errorEvents.contains { $0.payloadJSON.contains("noFinalText") })
        let terminal = try #require(events.last(where: { $0.kind == .terminal }))
        #expect(errorEvents.allSatisfy { $0.sequence < terminal.sequence })
        #expect(events.last?.id == terminal.id)
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
