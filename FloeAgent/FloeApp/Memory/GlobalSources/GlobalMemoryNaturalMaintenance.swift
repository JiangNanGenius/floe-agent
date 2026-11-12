// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import FloePersistence
import FloeAgentRuntime

nonisolated struct GlobalMemoryCompaction: Decodable, Sendable { var content: String?; var forget: Bool }
nonisolated protocol GlobalMemoryCompactionGenerator: Sendable { func compact(_ memory: MemoryEntry) async throws -> GlobalMemoryCompaction }

/// Later compaction follows the same forgetting clock as recall. Every writer
/// rechecks pin/preference, recall, source, content and real run ownership after
/// an asynchronous generator returns. Originals are never read or removed.
actor GlobalMemoryNaturalMaintenance {
    private let database: DatabaseManager
    private let memories: SQLiteIntelligenceStore
    private let generator: any GlobalMemoryCompactionGenerator
    init(database: DatabaseManager, memories: SQLiteIntelligenceStore, generator: any GlobalMemoryCompactionGenerator) {
        self.database = database; self.memories = memories; self.generator = generator
    }

    func run(now: Date = Date()) async throws {
        try await database.writer { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS global_memory_lifecycle(memory_id TEXT PRIMARY KEY NOT NULL,stage INTEGER NOT NULL,last_transition REAL NOT NULL)")
        }
        let rows: [(UUID, Int)] = try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id,COALESCE(l.stage,0) AS stage FROM memory_entries m LEFT JOIN global_memory_lifecycle l ON l.memory_id=m.id
                WHERE m.owner_deleted_at IS NOT NULL AND m.is_pinned=0
                  AND (m.scope<>'user' OR m.expires_at IS NOT NULL)
                  AND NOT(m.scope='agent' AND m.source_kind='explicitUserRequest' AND m.expires_at IS NULL)
                  AND (\(MemoryForgettingPolicy.deletedOwnerSQL))
                  AND julianday(?)-MAX(julianday(m.owner_deleted_at),COALESCE(julianday(m.last_recalled_at),0))
                      >= CASE WHEN COALESCE(l.stage,0)=0 THEN ? ELSE ? END
                  AND (COALESCE(l.stage,0)=0 OR m.retained_until IS NULL OR m.retained_until<=?)
                  AND (COALESCE(l.stage,0)<2 OR l.last_transition<?)
                ORDER BY m.owner_deleted_at LIMIT 8
                """, arguments: [now.ISO8601Format(), MemoryForgettingPolicy.importanceHalfLife / 86_400,
                    MemoryForgettingPolicy.archiveAfter / 86_400, now.ISO8601Format(),
                    now.addingTimeInterval(-MemoryForgettingPolicy.recallRetention).timeIntervalSince1970]).compactMap { row in
                    let text: String = row["id"], stage: Int = row["stage"]
                    return UUID(uuidString: text).map { ($0, stage) }
                }
        }
        for (id, stage) in rows {
            try Task.checkCancellation()
            guard let memory = try await memories.memory(id: id), !MemoryForgettingPolicy.isLongTerm(memory) else { continue }
            let result: GlobalMemoryCompaction?
            if stage >= 2 { result = try await generator.compact(memory) }
            else { result = nil }
            try Task.checkCancellation()
            let expectedUpdatedAt = ISO8601DateFormatter().string(from: memory.updatedAt)
            let didTransition = try await database.writer { db in
                try memories.withMemoryUseProtection { protected in
                    guard !protected.contains(id) else { return false }
                    // Recheck all mutable protection/clock inputs after model
                    // I/O, in the same writer and ownership critical section.
                    guard try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM memory_entries m
                            LEFT JOIN global_memory_lifecycle l ON l.memory_id=m.id
                            WHERE m.id=? AND m.content=? AND m.updated_at=? AND m.is_pinned=0
                              AND m.owner_deleted_at IS NOT NULL AND (\(MemoryForgettingPolicy.deletedOwnerSQL))
                              AND (m.scope<>'user' OR m.expires_at IS NOT NULL)
                              AND NOT(m.scope='agent' AND m.source_kind='explicitUserRequest' AND m.expires_at IS NULL)
                              AND COALESCE(l.stage,0)=? AND m.status IN ('active','superseded')
                              AND (?<2 OR m.status='superseded')
                              AND julianday(?)-MAX(julianday(m.owner_deleted_at),COALESCE(julianday(m.last_recalled_at),0))>=?
                              AND (?=0 OR m.retained_until IS NULL OR m.retained_until<=?)
                              AND (?<2 OR l.last_transition<?))
                        """, arguments: [id.uuidString, memory.content, expectedUpdatedAt, stage, stage,
                            now.ISO8601Format(), (stage == 0 ? MemoryForgettingPolicy.importanceHalfLife : MemoryForgettingPolicy.archiveAfter) / 86_400,
                            stage, now.ISO8601Format(), stage,
                            now.addingTimeInterval(-MemoryForgettingPolicy.recallRetention).timeIntervalSince1970]) == true else { return false }
                    if stage == 0 {
                        // Ranking computes the 30-day half-life from its true
                        // anchor; maintenance must not repeatedly multiply it.
                    } else if stage == 1 {
                        try db.execute(sql: "UPDATE memory_entries SET status='superseded' WHERE id=?", arguments: [id.uuidString])
                    } else if let result, result.forget, stage >= 3 {
                        try db.execute(sql: "DELETE FROM memory_entries WHERE id=?", arguments: [id.uuidString])
                        try db.execute(sql: """
                            INSERT INTO memory_tombstones(memory_id,deleted_at,sync_revision) VALUES (?,?,?)
                            ON CONFLICT(memory_id) DO UPDATE SET deleted_at=excluded.deleted_at,
                                sync_revision=MAX(memory_tombstones.sync_revision,excluded.sync_revision)
                            """, arguments: [id.uuidString, now.ISO8601Format(), Int64(now.timeIntervalSince1970 * 1_000)])
                        try db.execute(sql: "DELETE FROM global_memory_lifecycle WHERE memory_id=?", arguments: [id.uuidString])
                        return true
                    } else if let content = result?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !content.isEmpty, content.count < memory.content.count,
                              GlobalSourceTextPolicy.safeText(content) == content {
                        try db.execute(sql: "UPDATE memory_entries SET content=?,normalized_content=?,updated_at=? WHERE id=?",
                            arguments: [content, content.lowercased(), now.ISO8601Format(), id.uuidString])
                        try db.execute(sql: "DELETE FROM memory_embeddings WHERE memory_id=?", arguments: [id.uuidString])
                    } else { return false }
                    try Self.transition(id, stage: stage + 1, now: now, db: db)
                    return true
                }
            }
            _ = didTransition
        }
    }

    private static func transition(_ id: UUID, stage: Int, now: Date, db: Database) throws {
        try db.execute(sql: "INSERT INTO global_memory_lifecycle(memory_id,stage,last_transition) VALUES (?,?,?) ON CONFLICT(memory_id) DO UPDATE SET stage=excluded.stage,last_transition=excluded.last_transition",
            arguments: [id.uuidString, stage, now.timeIntervalSince1970])
    }
}
#endif
