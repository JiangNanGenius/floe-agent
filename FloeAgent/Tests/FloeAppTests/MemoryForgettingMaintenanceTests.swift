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
}
#endif
