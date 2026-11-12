import Foundation
import Testing
import GRDB
@testable import FloeAgentRuntime
@testable import FloePersistence

@Suite("Memory forgetting lifecycle", .serialized, .timeLimit(.minutes(1)))
struct MemoryForgettingTests {
    private let clock = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: TimeInterval = 86_400

    private struct Use: Equatable, Sendable {
        var count: Int
        var recalled: String?
        var retained: String?
        var updated: String
        var importance: Double
    }
    private func usage(_ db: DatabaseManager, _ id: UUID) async throws -> Use {
        try await db.reader { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM memory_entries WHERE id=?", arguments: [id.uuidString]))
            return Use(count: row["recall_count"], recalled: row["last_recalled_at"], retained: row["retained_until"],
                updated: row["updated_at"], importance: row["importance"])
        }
    }
    private func vectors(_ db: DatabaseManager, _ id: UUID) async throws -> Int {
        try await db.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_embeddings WHERE memory_id=?", arguments: [id.uuidString]) ?? -1
        }
    }
    private func database() async throws -> DatabaseManager {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        return db
    }
    private func source(_ db: DatabaseManager) async throws -> UUID {
        let id = UUID()
        try await SQLiteConversationStore(database: db).saveConversation(.init(id: id, title: "Owned memory source", createdAt: clock, updatedAt: clock))
        return id
    }

    @Test("Deleted global origins age; library browsing never reinforces, genuine recall postpones the boundary")
    func deletedOriginAndObservationClock() async throws {
        let db = try await database(), owner = try await source(db)
        let store = SQLiteIntelligenceStore(database: db)
        let memory = MemoryEntry(scope: .agentGlobal, status: .active, content: "violet handoff checklist",
            confidence: 1, importance: 0.8, sourceKind: .automaticTurnReview, originConversationID: owner,
            createdAt: clock, updatedAt: clock)
        try await store.saveMemory(memory, evidence: [])
        try await store.saveEmbedding(.init(memoryID: memory.id, modality: .text, modelIdentifier: "owned", modelRevision: "1", values: [1,0], contentDigest: "owned"))
        try await store.preserveMemoriesBeforeConversationDeletion(conversationID: owner, ownerLabel: "Owned memory source", now: clock)
        try await SQLiteConversationStore(database: db).deleteConversation(id: owner)
        let request = HybridMemoryRecallRequest(query: "violet checklist")
        let before = try await usage(db, memory.id)
        for days in [30.0, 45.0] {
            let hits = try await store.browseMemories(request, now: clock.addingTimeInterval(days * day))
            #expect(hits.map(\.id).contains(memory.id))
            #expect(try await usage(db, memory.id) == before)
        }
        let actualRecall = try await store.hybridRecall(request, now: clock.addingTimeInterval(60 * day))
        #expect(actualRecall.map(\.id).contains(memory.id))
        let reinforced = try await usage(db, memory.id)
        #expect(reinforced.count == 1 && reinforced.recalled != nil)
        #expect(reinforced.importance > before.importance && reinforced.updated == before.updated)
        try await store.maintainMemoryLifecycle(now: clock.addingTimeInterval(149 * day))
        #expect(try await store.memory(id: memory.id)?.status == .active)
        try await store.maintainMemoryLifecycle(now: clock.addingTimeInterval(150 * day))
        #expect(try await store.memory(id: memory.id)?.status == .superseded)
        try await store.maintainMemoryLifecycle(now: clock.addingTimeInterval(239 * day))
        #expect(try await vectors(db, memory.id) == 1)
        try await store.maintainMemoryLifecycle(now: clock.addingTimeInterval(240 * day))
        #expect(try await vectors(db, memory.id) == 0)
        #expect(try await store.memory(id: memory.id)?.content == memory.content)
    }

    @Test("Older origin-only orphans are repaired without a fresh-use timestamp; unknown sources stay intact")
    func historicalOrphanRepairDoesNotRenewUse() async throws {
        let db = try await database(), store = SQLiteIntelligenceStore(database: db)
        let old = clock.addingTimeInterval(-200 * day)
        let orphan = MemoryEntry(scope: .agentGlobal, status: .active, content: "obsolete owned deployment detail",
            confidence: 1, importance: 0.5, sourceKind: .automaticTurnReview, originConversationID: UUID(), createdAt: old, updatedAt: old)
        let unknown = MemoryEntry(scope: .agentGlobal, status: .active, content: "Unknown provenance must be kept",
            confidence: 1, importance: 0.5, sourceKind: .automaticTurnReview, createdAt: old, updatedAt: old)
        try await store.saveMemory(orphan, evidence: [])
        try await store.saveMemory(unknown, evidence: [])
        let earlierRecall = clock.addingTimeInterval(-300 * day).ISO8601Format()
        try await db.writer { db in
            try db.execute(sql: "UPDATE memory_entries SET last_recalled_at=? WHERE id=?",
                arguments: [earlierRecall, orphan.id.uuidString])
        }
        let before = try await usage(db, orphan.id)
        try await store.maintainMemoryLifecycle(now: clock)
        let repaired: String? = try await db.reader { db in
            try String.fetchOne(db, sql: "SELECT owner_deleted_at FROM memory_entries WHERE id=?", arguments: [orphan.id.uuidString])
        }
        #expect(repaired == before.updated)
        #expect(try await usage(db, orphan.id) == before)
        #expect(try await store.memory(id: orphan.id)?.status == .superseded)
        #expect(try await store.memory(id: orphan.id)?.content == orphan.content)
        #expect(try await store.memory(id: unknown.id)?.status == .active)
    }

    @Test("Actual SQLite hybrid ranking weakens a deleted task's old fact before the archive boundary")
    func deletedFactImportanceDecaysInActualRecall() async throws {
        let db = try await database(), oldOwner = try await source(db), recentOwner = try await source(db)
        let store = SQLiteIntelligenceStore(database: db)
        let old = MemoryEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            scope: .agentGlobal, status: .active, content: "matching violet operational fact", confidence: 1, importance: 0.8,
            sourceKind: .automaticTurnReview, originConversationID: oldOwner, createdAt: clock, updatedAt: clock)
        let recent = MemoryEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            scope: .agentGlobal, status: .active, content: old.content, confidence: 1, importance: 0.8,
            sourceKind: .automaticTurnReview, originConversationID: recentOwner, createdAt: clock, updatedAt: clock)
        for entry in [old, recent] { try await store.saveMemory(entry, evidence: []) }
        try await store.preserveMemoriesBeforeConversationDeletion(conversationID: oldOwner, ownerLabel: "Old", now: clock)
        try await store.preserveMemoriesBeforeConversationDeletion(conversationID: recentOwner, ownerLabel: "Recent", now: clock.addingTimeInterval(60 * day))
        let conversations = SQLiteConversationStore(database: db)
        try await conversations.deleteConversation(id: oldOwner)
        try await conversations.deleteConversation(id: recentOwner)
        let hits = try await store.browseMemories(.init(query: "violet operational"), now: clock.addingTimeInterval(60 * day))
        #expect(hits.map(\.id) == [recent.id, old.id])
        // Equal text, base importance and updatedAt; deterministic lexical
        // order favors old.id, so only the real age weighting reverses it.
        #expect(hits.first?.lexicalRank == 2)
        #expect(try await usage(db, old.id).count == 0)

        // A new, unrelated task cannot silently renew either automatic fact
        // through the default prompt fallback. Explicit recall above remains
        // available, and pinning or a current owner is still respected.
        let currentConversation = UUID()
        #expect(!MemoryForgettingPolicy.isDefaultContext(old,
            conversationID: currentConversation, workspaceID: nil))
        #expect(!MemoryForgettingPolicy.isDefaultContext(recent,
            conversationID: currentConversation, workspaceID: nil))
        var pinned = old
        pinned.isPinned = true
        #expect(MemoryForgettingPolicy.isDefaultContext(pinned,
            conversationID: currentConversation, workspaceID: nil))
        var current = recent
        current.originConversationID = currentConversation
        #expect(MemoryForgettingPolicy.isDefaultContext(current,
            conversationID: currentConversation, workspaceID: nil))
    }

    @Test("Pins and lasting preferences survive deletion; expired task facts and expired preferences are archived")
    func lastingAndTimeBoundMemoriesRemainDistinct() async throws {
        let db = try await database(), owner = try await source(db)
        let store = SQLiteIntelligenceStore(database: db)
        let entries = [
            MemoryEntry(scope: .task(owner), status: .active, content: "Manually pinned task reference", confidence: 1, importance: 1,
                isPinned: true, sourceKind: .automaticTurnReview, createdAt: clock, updatedAt: clock),
            MemoryEntry(scope: .userProfile, status: .active, content: "Prefer concise answers", confidence: 1, importance: 1,
                sourceKind: .automaticTurnReview, originConversationID: owner, createdAt: clock, updatedAt: clock),
            MemoryEntry(scope: .agentGlobal, status: .active, content: "Explicit lasting convention", confidence: 1, importance: 1,
                sourceKind: .explicitUserRequest, originConversationID: owner, createdAt: clock, updatedAt: clock),
            MemoryEntry(scope: .task(owner), status: .active, content: "Task-only temporary instruction", confidence: 1, importance: 1,
                sourceKind: .explicitUserRequest, createdAt: clock, updatedAt: clock),
            MemoryEntry(scope: .userProfile, status: .active, content: "This preference ends next week", confidence: 1, importance: 1,
                sourceKind: .explicitUserRequest, originConversationID: owner, expiresAt: clock.addingTimeInterval(7 * day), createdAt: clock, updatedAt: clock)
        ]
        for entry in entries { try await store.saveMemory(entry, evidence: []) }
        // A preservation attempt while the task still exists is not deletion.
        try await store.preserveMemoriesBeforeConversationDeletion(conversationID: owner, ownerLabel: "Owned", now: clock)
        try await store.maintainMemoryLifecycle(now: clock.addingTimeInterval(100 * day))
        #expect(try await store.memory(id: entries[3].id)?.status == .active)
        try await SQLiteConversationStore(database: db).deleteConversation(id: owner)
        try await store.maintainMemoryLifecycle(now: clock.addingTimeInterval(400 * day))
        for entry in entries.prefix(3) {
            #expect(try await store.memory(id: entry.id)?.status == .active)
            #expect(try await store.memory(id: entry.id)?.content == entry.content)
        }
        #expect(try await store.memory(id: entries[3].id)?.status == .superseded)
        #expect(try await store.memory(id: entries[4].id)?.status == .superseded)
    }

    @Test("Real preparing run owners protect used memories until the last exact lease releases, never by Goal status")
    func memoryUseLeaseIsExactAndReleasesOnce() async throws {
        let db = try await database(), store = SQLiteIntelligenceStore(database: db)
        let prepared = try await SQLiteRunLaunchStore(database: db).prepare(.init(goal: "Owned current run"))
        let old = clock.addingTimeInterval(-200 * day)
        let memory = MemoryEntry(scope: .agentGlobal, status: .active, content: "Old result currently referenced by a new run",
            confidence: 1, importance: 0.5, sourceKind: .automaticTurnReview, originConversationID: UUID(), createdAt: old, updatedAt: old)
        try await store.saveMemory(memory, evidence: [])
        let first = store.beginMemoryUse(runID: prepared.run.id)
        let second = store.beginMemoryUse(runID: prepared.run.id)
        // Exercise the same existential async dispatch as MemoryTools before
        // any direct include can hide an accidental default no-op witness.
        let durable: any DurableMemoryStore = store
        #expect(!store.withMemoryUseProtection { $0.contains(memory.id) })
        await durable.recordMemoryUse([memory.id], runID: prepared.run.id)
        #expect(store.withMemoryUseProtection { $0.contains(memory.id) })
        first.include([memory.id])
        let current = MemoryEntry(scope: .agentGlobal, status: .active, content: "Current selected fallback",
            confidence: 1, importance: 0.5, sourceKind: .automaticTurnReview, createdAt: clock, updatedAt: clock)
        let expired = MemoryEntry(scope: .agentGlobal, status: .active, content: "Expired snapshot must not enter the prompt",
            confidence: 1, importance: 0.5, sourceKind: .automaticTurnReview,
            expiresAt: clock.addingTimeInterval(-day), createdAt: clock, updatedAt: clock)
        try await store.saveMemory(current, evidence: [])
        try await store.saveMemory(expired, evidence: [])
        let projected = try await store.retainRuntimeMemories([current.id, expired.id], useLease: first, now: clock)
        #expect(projected.map(\.id) == [current.id])
        #expect(try await usage(db, current.id).count == 1)
        _ = try await store.retainRuntimeMemories([current.id], useLease: second, alreadyRecalled: [current.id], now: clock)
        #expect(try await usage(db, current.id).count == 1, "A real hybrid recall must not be counted twice by projection")
        first.finish(); first.finish()
        let lateProjection = try await store.retainRuntimeMemories([current.id], useLease: first, now: clock)
        #expect(lateProjection.isEmpty)
        #expect(try await usage(db, current.id).count == 1)
        try await store.maintainMemoryLifecycle(now: clock)
        #expect(try await store.memory(id: memory.id)?.status == .active)
        second.finish()
        // A late tool callback cannot recreate an owner after final cleanup.
        await durable.recordMemoryUse([memory.id], runID: prepared.run.id)
        #expect(!store.withMemoryUseProtection { $0.contains(memory.id) })
        try await store.maintainMemoryLifecycle(now: clock)
        #expect(try await store.memory(id: memory.id)?.status == .superseded)
        #expect(try await store.memory(id: memory.id)?.content == memory.content)
        let replacement = store.beginMemoryUse(runID: prepared.run.id)
        replacement.include([memory.id])
        first.finish()
        #expect(store.withMemoryUseProtection { $0.contains(memory.id) })
        replacement.finish()
        #expect(!store.withMemoryUseProtection { $0.contains(memory.id) })
    }
}
