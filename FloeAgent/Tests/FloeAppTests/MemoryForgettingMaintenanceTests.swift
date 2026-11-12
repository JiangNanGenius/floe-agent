#if canImport(UIKit)
import Foundation
import Testing
import GRDB
import FloePersistence
import FloeAgentRuntime
@testable import FloeApp

@MainActor @Suite("Memory maintenance ownership fence", .serialized, .timeLimit(.minutes(1)))
struct MemoryForgettingMaintenanceTests {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var entered = false
        private var released = false
        func hold() async {
            entered = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func waitUntilEntered() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(entered, "The actual compaction worker did not reach its generator")
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    private struct Compactor: GlobalMemoryCompactionGenerator {
        let gate: Gate
        func compact(_ memory: MemoryEntry) async throws -> GlobalMemoryCompaction {
            await gate.hold()
            return .init(content: nil, forget: true)
        }
    }
    private actor CountingEmbedding: MemoryEmbeddingProvider {
        nonisolated let modelIdentifier = "owned-empty-corpus"
        nonisolated let modelRevision = "1"
        nonisolated let modality = MemoryEmbeddingModality.text
        private(set) var calls = 0
        private var shouldThrow = true
        enum Failure: Error { case requested }
        func setThrowing(_ value: Bool) { shouldThrow = value }
        func embedding(for content: String) async throws -> [Float] {
            calls += 1
            if shouldThrow { throw Failure.requested }
            return [1, 0]
        }
    }
    private struct SavedSource: GlobalSourceProvider {
        let snapshot: GlobalSourceSnapshot
        var id: String { snapshot.source.providerID }
        func inventory(cursor: String?, limit: Int) async throws -> GlobalSourcePage {
            .init(sources: cursor == nil ? [snapshot.source] : [], nextCursor: nil)
        }
        func read(_ source: GlobalSourceDescriptor) async throws -> GlobalSourceSnapshot {
            guard source.id == snapshot.source.id, source.revision == snapshot.source.revision else {
                throw GlobalSourceJobError.sourceChanged
            }
            return snapshot
        }
        func isAccessible(_ source: GlobalSourceDescriptor) async -> Bool { source.id == snapshot.source.id }
    }

    private struct Fixture: Sendable {
        let database: DatabaseManager
        let store: SQLiteIntelligenceStore
        let memory: MemoryEntry
        let clock: Date
        let gate: Gate
        let maintenance: GlobalMemoryNaturalMaintenance
    }
    private func fixture() async throws -> Fixture {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let store = SQLiteIntelligenceStore(database: db)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-400 * 86_400)
        let memory = MemoryEntry(scope: .agentGlobal, status: .active, content: "Owned old result must survive a late protection",
            confidence: 1, importance: 0.5, sourceKind: .automaticTurnReview, originConversationID: UUID(), createdAt: old, updatedAt: old)
        try await store.saveMemory(memory, evidence: [])
        try await store.maintainMemoryLifecycle(now: now)
        try await db.writer { db in
            try db.execute(sql: "CREATE TABLE global_memory_lifecycle(memory_id TEXT PRIMARY KEY NOT NULL,stage INTEGER NOT NULL,last_transition REAL NOT NULL)")
            try db.execute(sql: "INSERT INTO global_memory_lifecycle VALUES (?,3,?)", arguments: [memory.id.uuidString, now.addingTimeInterval(-100 * 86_400).timeIntervalSince1970])
        }
        let gate = Gate()
        return .init(database: db, store: store, memory: memory, clock: now, gate: gate,
            maintenance: .init(database: db, memories: store, generator: Compactor(gate: gate)))
    }
    private func assertRetained(_ f: Fixture, pinned: Bool) async throws {
        let entry = try #require(try await f.store.memory(id: f.memory.id))
        #expect(entry.content == f.memory.content && entry.isPinned == pinned)
        let counts = try await f.database.reader { db in
            let tombstones = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_tombstones WHERE memory_id=?", arguments: [f.memory.id.uuidString]) ?? -1
            let stage = try Int.fetchOne(db, sql: "SELECT stage FROM global_memory_lifecycle WHERE memory_id=?", arguments: [f.memory.id.uuidString]) ?? -1
            return [tombstones, stage]
        }
        #expect(counts == [0,3])
    }

    @Test("A real run starts using the memory during compaction; the late forget result cannot delete it")
    func lateRunUseFencesCompactionCommit() async throws {
        let f = try await fixture()
        let task = Task { try await f.maintenance.run(now: f.clock) }
        defer { task.cancel(); Task { await f.gate.release() } }
        try await f.gate.waitUntilEntered()
        let prepared = try await SQLiteRunLaunchStore(database: f.database).prepare(.init(goal: "Owned active consumer"))
        let use = f.store.beginMemoryUse(runID: prepared.run.id)
        use.include([f.memory.id])
        defer { use.finish() }
        await f.gate.release()
        try await task.value
        try await assertRetained(f, pinned: false)
    }

    @Test("A manual pin made while the compactor awaits is rechecked in its actual SQLite commit")
    func manualPinFencesCompactionCommit() async throws {
        let f = try await fixture()
        let task = Task { try await f.maintenance.run(now: f.clock) }
        defer { task.cancel(); Task { await f.gate.release() } }
        try await f.gate.waitUntilEntered()
        var pinned = try #require(try await f.store.memory(id: f.memory.id))
        pinned.isPinned = true; pinned.updatedAt = f.clock
        try await f.store.saveMemory(pinned, evidence: [])
        await f.gate.release()
        try await task.value
        try await assertRetained(f, pinned: true)
    }
    @Test("Empty eligible SQLite corpora do not invoke embeddings; nonempty memory and source search retain real recall")
    func emptyCorporaSkipEmbeddingAndNonemptyCandidatesStillRecall() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let memories = SQLiteIntelligenceStore(database: database)
        let index = GlobalSourceIndexStore(database: database)
        let embedding = CountingEmbedding()
        let now = Date()
        let owner = UUID()
        try await SQLiteConversationStore(database: database).saveConversation(.init(
            id: owner, title: "Owned semantic fixture", createdAt: now, updatedAt: now))
        let source = GlobalSourceDescriptor(id: "owned-source", providerID: "owned-source-provider", kind: .workspaceFile,
            ownerID: owner.uuidString, revision: "r1", title: "Saved source", locator: "owned-fixture",
            conversationID: owner, modifiedAt: now)
        let snapshot = GlobalSourceSnapshot(source: source, text: "rose courtyard detail")
        let service = GlobalSourceMemoryService(index: index, memories: memories,
            candidates: MemoryCandidatePipeline(documents: SQLitePersonalizationStore(database: database), memories: memories),
            providers: [SavedSource(snapshot: snapshot)], embedding: embedding, summary: nil)
        let context = GlobalSourceSearchContext(conversationID: owner)

        #expect(try await service.recallMemories("unrelatedpreamble", context: context).isEmpty)
        #expect(try await service.browseMemories("unrelatedpreamble", context: context).isEmpty)
        #expect(try await service.search("unrelatedpreamble", context: context).isEmpty)
        #expect(await embedding.calls == 0, "An empty store must not call even a throwing model")

        // These real pinned rows remain active under retention, but explicit
        // expiry excludes them from recall. Fill one actual page so the later
        // live candidate also proves that an unread cursor is never empty.
        for number in 0..<100 {
            try await memories.saveMemory(.init(scope: .userProfile, status: .active,
                content: "Expired pinned row \(number)", confidence: 1, importance: 1, isPinned: true,
                sourceKind: .explicitUserRequest, expiresAt: now.addingTimeInterval(-60)), evidence: [])
        }
        #expect(try await service.recallMemories("unrelatedpreamble", context: context).isEmpty)
        #expect(try await service.browseMemories("unrelatedpreamble", context: context).isEmpty)
        #expect(await embedding.calls == 0)
        #expect(try await memories.listMemories(.init(status: .active, limit: 100)).entries.count == 100)

        let active = MemoryEntry(scope: .task(owner), status: .active, content: "orchid semantic preference",
            confidence: 1, importance: 0.8, sourceKind: .automaticTurnReview, createdAt: now, updatedAt: now)
        try await memories.saveMemory(active, evidence: [])
        try await memories.saveEmbedding(.init(memoryID: active.id, modality: .text,
            modelIdentifier: embedding.modelIdentifier, modelRevision: embedding.modelRevision,
            values: [1, 0], contentDigest: MemoryContentDigest.make(active.content)))
        await embedding.setThrowing(false)
        let observed = try await service.browseMemories("unrelatedpreamble", context: context)
        #expect(observed.contains { $0.id == active.id && $0.semanticRank != nil })
        #expect(await embedding.calls == 1)
        let browseCount = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT recall_count FROM memory_entries WHERE id=?", arguments: [active.id.uuidString])
        }
        #expect(browseCount == 0, "Presence detection and browsing must not reinforce memory")
        let recalled = try await service.recallMemories("unrelatedpreamble", context: context)
        #expect(recalled.contains { $0.id == active.id && $0.semanticRank != nil })
        #expect(await embedding.calls == 2)
        let recallCount = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT recall_count FROM memory_entries WHERE id=?", arguments: [active.id.uuidString])
        }
        #expect(recallCount == 1)

        _ = try await index.touch(source, token: "fixture")
        var chunk = GlobalSourceChunk(id: "owned-source-chunk", sourceID: source.id, revision: source.revision,
            ordinal: 0, offset: 0, text: snapshot.text, digest: MemoryContentDigest.make(snapshot.text))
        try await index.replace(snapshot, chunks: [chunk], seenToken: "fixture", queueSummary: false)
        let lexical = try await service.search("rose", context: context)
        #expect(lexical.contains { $0.id == chunk.id && !$0.semantic && $0.sourceAvailable })
        #expect(await embedding.calls == 2, "A lexical-only index has no vector work")
        chunk.vector = [1, 0]; chunk.vectorModel = embedding.modelIdentifier; chunk.vectorRevision = "older"
        try await index.replace(snapshot, chunks: [chunk], seenToken: "fixture", queueSummary: false)
        #expect(try await service.search("rose", context: context).contains { $0.id == chunk.id })
        #expect(await embedding.calls == 2, "Another model revision is not a current semantic corpus")
        chunk.vectorRevision = embedding.modelRevision
        try await index.replace(snapshot, chunks: [chunk], seenToken: "fixture", queueSummary: false)
        let semantic = try await service.search("unrelatedpreamble", context: context)
        #expect(semantic.contains { $0.id == chunk.id && $0.semantic && $0.sourceAvailable })
        #expect(await embedding.calls == 3)
        await embedding.setThrowing(true)
        #expect(try await service.search("rose", context: context).contains { $0.id == chunk.id && !$0.semantic })
        #expect(await embedding.calls == 4, "A model failure retains the existing lexical fallback")

        // Corrupt derived data is a real read failure, never an empty corpus.
        try await database.writer { db in
            try db.execute(sql: "UPDATE global_memory_chunks SET vector=X'7B' WHERE id='owned-source-chunk'")
        }
        await #expect(throws: (any Error).self) {
            _ = try await service.search("unrelatedpreamble", context: context)
        }
        #expect(await embedding.calls == 4)
        try await database.writer { db in try db.execute(sql: "DROP TABLE memory_entries") }
        await #expect(throws: (any Error).self) {
            _ = try await service.recallMemories("unrelatedpreamble", context: context)
        }
        await #expect(throws: (any Error).self) {
            _ = try await service.browseMemories("unrelatedpreamble", context: context)
        }
        #expect(await embedding.calls == 4, "A failed SQLite read cannot trigger a model or become an empty success")
    }

}
#endif
