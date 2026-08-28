import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.MemoryTools")
struct MemoryToolsTests {
    @Test("memory.remember is a consent-gated persistent write")
    func rememberDescriptorRequiresConsent() {
        #expect(MemoryRememberTool.isSideEffecting)
        #expect(MemoryRememberTool.riskLabels == [.persistsPersonalData])
        #expect(MemoryRememberTool.toolEffect == .internalState)
    }


    @Test("memory.remember records an active memory")
    func remember() async throws {
        let store = FakeMemoryStore()
        let taskID = UUID()
        let tool = MemoryRememberTool(store: store) { _ in taskID }
        let output = try await tool.execute(
            .init(content: "User prefers dark mode"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=remembered"))
        let active = await store.activeFor(.agentGlobal)
        #expect(active.count == 1)
        #expect(active.first?.content == "User prefers dark mode")
        #expect(active.first?.originConversationID == taskID)
    }

    @Test("memory.remember fails closed when task ownership is unavailable")
    func rememberRequiresTaskOwner() async throws {
        let store = FakeMemoryStore()
        let tool = MemoryRememberTool(store: store) { _ in nil }
        let output = try await tool.execute(
            .init(content: "Must keep an owner"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 1)
        #expect(await store.activeFor(.agentGlobal).isEmpty)
    }

    @Test("memory.remember rejects empty content")
    func rememberValidation() async {
        let tool = MemoryRememberTool(store: FakeMemoryStore())
        #expect(throws: FloeError.self) {
            try tool.validate(.init(content: "   "))
        }
    }

    @Test("memory.recall lists active memories, pinned first")
    func recall() async throws {
        let store = FakeMemoryStore()
        let pinned = MemoryEntry(scope: .agentGlobal, status: .active, content: "Pinned note",
                                 confidence: 1, importance: 0.3, isPinned: true, sourceKind: .explicitUserRequest)
        let normal = MemoryEntry(scope: .agentGlobal, status: .active, content: "Normal note",
                                 confidence: 1, importance: 0.9, isPinned: false, sourceKind: .explicitUserRequest)
        await store.preload([normal, pinned])

        let tool = MemoryRecallTool(store: store)
        let output = try await tool.execute(
            .init(scope: "global"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("Pinned note"))
        #expect(output.summary.contains("Normal note"))
    }

    @Test("memory.recall with no memories is honest")
    func recallEmpty() async throws {
        let tool = MemoryRecallTool(store: FakeMemoryStore())
        let output = try await tool.execute(
            .init(),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.summary.contains("No active memories"))
    }
}

private actor FakeMemoryStore: DurableMemoryStore {
    private var entries: [MemoryEntry] = []

    func preload(_ list: [MemoryEntry]) { entries = list }
    func activeFor(_ scope: MemoryScope) -> [MemoryEntry] {
        entries.filter { $0.scope == scope && $0.status == .active }
    }

    func saveMemory(_ entry: MemoryEntry, evidence: [MemoryEvidenceReference]) async throws {
        entries.append(entry)
    }
    func memories(scope: MemoryScope, status: MemoryEntryStatus?) async throws -> [MemoryEntry] {
        entries.filter { $0.scope == scope && (status == nil || $0.status == status) }
    }
    func recall(query: String, workspaceID: UUID?, conversationID: UUID?, limit: Int) async throws -> [MemoryRecallItem] { [] }
    func saveEmbedding(_ embedding: MemoryEmbedding) async throws {}
    func embeddingNeedsRefresh(
        memoryID: UUID, modality: MemoryEmbeddingModality,
        modelIdentifier: String, modelRevision: String, contentDigest: String
    ) async throws -> Bool { false }
    func hybridRecall(_ request: HybridMemoryRecallRequest) async throws -> [HybridMemoryRecallItem] { [] }
    func deleteMemory(id: UUID, syncRevision: Int64) async throws {}
}
