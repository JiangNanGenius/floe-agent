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

    @Test("memory.remember checks prior memory and does not duplicate identical content")
    func rememberAvoidsExactDuplicate() async throws {
        let store = FakeMemoryStore()
        let existing = MemoryEntry(
            scope: .agentGlobal,
            status: .active,
            content: "Floe uses dark mode",
            confidence: 1,
            importance: 0.8,
            sourceKind: .explicitUserRequest
        )
        await store.preload([existing])
        let tool = MemoryRememberTool(store: store) { _ in UUID() }

        let output = try await tool.execute(
            .init(content: "  floe uses dark mode  "),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )

        #expect(output.summary.contains("status=unchanged"))
        #expect(output.summary.contains("priorMemoryChecked=true"))
        #expect(await store.activeFor(.agentGlobal).count == 1)
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

    @Test("memory.list enumerates concrete entries instead of only aggregate counts")
    func listEntries() async throws {
        let store = FakeMemoryStore()
        let entry = MemoryEntry(
            scope: .agentGlobal,
            status: .active,
            content: "HK4H4G agent version is 1.4.1",
            confidence: 1,
            importance: 0.8,
            sourceKind: .explicitUserRequest,
            factIdentity: MemoryFactIdentity(subjectKey: "host:hk4h4g", attributeKey: "agent-version")
        )
        await store.preload([entry])
        let output = try await MemoryListTool(store: store).execute(
            .init(scope: "global", limit: 100),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.summary.contains("trust=untrustedStoredFacts"))
        #expect(output.summary.contains(entry.id.uuidString))
        #expect(output.summary.contains("HK4H4G agent version is 1.4.1"))
    }

    @Test("memory.update changes an existing fact instead of adding a duplicate")
    func updateFact() async throws {
        let store = FakeMemoryStore()
        let entry = MemoryEntry(
            scope: .agentGlobal, status: .active, content: "Agent version is 1.2.0",
            confidence: 1, importance: 0.8, sourceKind: .explicitUserRequest,
            factIdentity: MemoryFactIdentity(subjectKey: "host:hk4h4g", attributeKey: "agent-version")
        )
        await store.preload([entry])
        let tool = MemoryUpdateTool(store: store)
        let output = try await tool.execute(
            .init(id: entry.id, content: "Agent version is 1.4.1"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(await store.activeFor(.agentGlobal).map(\.content) == ["Agent version is 1.4.1"])
    }

    @Test("memory.forget removes a stable fact slot")
    func forgetFact() async throws {
        let store = FakeMemoryStore()
        let identity = MemoryFactIdentity(subjectKey: "host:hk4h4g", attributeKey: "address")
        await store.preload([
            MemoryEntry(scope: .agentGlobal, status: .active, content: "Address is example.invalid",
                        confidence: 1, importance: 0.8, sourceKind: .explicitUserRequest,
                        factIdentity: identity)
        ])
        let output = try await MemoryForgetTool(store: store).execute(
            .init(subjectKey: identity.subjectKey, attributeKey: identity.attributeKey),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.summary.contains("count=1"))
        #expect(await store.activeFor(.agentGlobal).isEmpty)
    }
}

private actor FakeMemoryStore: DurableMemoryStore {
    private var entries: [MemoryEntry] = []
    private var appliedBatches: Set<UUID> = []

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
    func memory(id: UUID) async throws -> MemoryEntry? { entries.first { $0.id == id } }
    func memories(factIdentity: MemoryFactIdentity, scope: MemoryScope?) async throws -> [MemoryEntry] {
        entries.filter { $0.factIdentity == factIdentity && (scope == nil || $0.scope == scope) }
    }
    func organizationPreview(limit: Int) async throws -> MemoryOrganizationProposal {
        MemoryOrganizationProposal(scannedCount: min(limit, entries.count), suggestions: [])
    }
    func applyMaintenanceBatch(_ batch: MemoryMaintenanceBatch) async throws -> MemoryMaintenanceBatchResult {
        guard appliedBatches.insert(batch.id).inserted else {
            return MemoryMaintenanceBatchResult(
                batchID: batch.id, appliedCount: 0, deletedCount: 0,
                replacedCount: 0, wasAlreadyApplied: true
            )
        }
        var deleted = 0
        var replaced = 0
        for operation in batch.operations {
            switch operation {
            case .delete(let id):
                let previous = entries.count
                entries.removeAll { $0.id == id }
                if entries.count != previous { deleted += 1 }
            case .replace(let id, let entry):
                guard let index = entries.firstIndex(where: { $0.id == id }) else {
                    throw FloeError.validationFailed("missing memory")
                }
                entries[index] = entry
                replaced += 1
            }
        }
        return MemoryMaintenanceBatchResult(
            batchID: batch.id, appliedCount: batch.operations.count,
            deletedCount: deleted, replacedCount: replaced
        )
    }
}
