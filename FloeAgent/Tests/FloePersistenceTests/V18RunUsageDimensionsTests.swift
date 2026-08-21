import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("FloePersistence v18 run usage dimensions")
struct V18RunUsageDimensionsTests {
    private func database() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    private func installConfiguration(
        database: DatabaseManager,
        providerID: UUID,
        modelID: UUID
    ) async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID,
            kind: .alibabaStudio,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")),
            displayName: "DashScope"
        ))
        try await store.saveModel(ModelProfile(
            id: modelID,
            providerID: providerID,
            remoteModelID: "qwen-vl",
            displayName: "qwen-vl",
            limits: ModelLimits(contextTokens: 32_000, maxOutputTokens: 4_096)
        ))
    }

    @Test("Launch snapshots provider and model identity on the run")
    func launchSnapshotsUsageDimensions() async throws {
        let database = try await database()
        let providerID = UUID()
        let modelID = UUID()
        try await installConfiguration(database: database, providerID: providerID, modelID: modelID)
        let prepared = try await SQLiteRunLaunchStore(database: database).prepare(
            RunLaunchRequest(
                conversationTitle: "Snapshot",
                goal: "hello",
                providerID: providerID,
                modelID: modelID,
                providerName: "DeepSeek",
                modelName: "deepseek-v4-flash"
            )
        )

        let run = try #require(await SQLiteRunStore(database: database).run(id: prepared.run.id))
        #expect(run.providerID == providerID)
        #expect(run.modelID == modelID)
        #expect(run.providerName == "DeepSeek")
        #expect(run.modelName == "deepseek-v4-flash")
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)
    }

    @Test("Statistics aggregate by conversation model and provider")
    func aggregatesAllUsageDimensions() async throws {
        let database = try await database()
        let launchStore = SQLiteRunLaunchStore(database: database)
        let runStore = SQLiteRunStore(database: database)
        let providerID = UUID()
        let modelID = UUID()
        try await installConfiguration(database: database, providerID: providerID, modelID: modelID)

        let first = try await launchStore.prepare(RunLaunchRequest(
            conversationTitle: "图片任务",
            goal: "first",
            providerID: providerID,
            modelID: modelID,
            providerName: "DashScope",
            modelName: "qwen-vl"
        ))
        let second = try await launchStore.prepare(RunLaunchRequest(
            conversationID: first.conversation.id,
            goal: "second",
            providerID: providerID,
            modelID: modelID,
            providerName: "DashScope",
            modelName: "qwen-vl"
        ))
        try await runStore.recordUsage(RunUsageRecord(
            runID: first.run.id,
            inputTokens: 100,
            outputTokens: 30,
            cacheReadTokens: 40,
            cacheWriteTokens: 10,
            reasoningTokens: 5
        ))
        try await runStore.recordUsage(RunUsageRecord(
            runID: second.run.id,
            inputTokens: 50,
            outputTokens: 20
        ))

        let stats = try await runStore.usageStatistics()
        #expect(stats.totalTokens == 200)
        #expect(stats.totalRuns == 2)
        #expect(stats.cacheReadTokens == 40)
        #expect(stats.cacheWriteTokens == 10)
        #expect(stats.reasoningTokens == 5)
        #expect(stats.byConversation == [UsageBreakdown(
            id: first.conversation.id.uuidString,
            label: "图片任务",
            inputTokens: 150,
            outputTokens: 50,
            runs: 2,
            cacheReadTokens: 40,
            cacheWriteTokens: 10,
            reasoningTokens: 5
        )])
        #expect(stats.byModel == [UsageBreakdown(
            id: modelID.uuidString,
            label: "qwen-vl",
            inputTokens: 150,
            outputTokens: 50,
            runs: 2,
            cacheReadTokens: 40,
            cacheWriteTokens: 10,
            reasoningTokens: 5
        )])
        #expect(stats.byProvider == [UsageBreakdown(
            id: providerID.uuidString,
            label: "DashScope",
            inputTokens: 150,
            outputTokens: 50,
            runs: 2,
            cacheReadTokens: 40,
            cacheWriteTokens: 10,
            reasoningTokens: 5
        )])
    }
}
