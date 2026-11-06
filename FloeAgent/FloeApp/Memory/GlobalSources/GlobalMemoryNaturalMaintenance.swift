// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import FloePersistence
import FloeAgentRuntime

nonisolated struct GlobalMemoryCompaction: Decodable, Sendable { var content: String?; var forget: Bool }
nonisolated protocol GlobalMemoryCompactionGenerator: Sendable { func compact(_ memory: MemoryEntry) async throws -> GlobalMemoryCompaction }

/// Extends the existing orphan-memory lifecycle with model-backed gradual
/// compaction. It never touches originals or treats background reads as recall.
actor GlobalMemoryNaturalMaintenance {
    private let database: DatabaseManager
    private let memories: SQLiteIntelligenceStore
    private let generator: any GlobalMemoryCompactionGenerator
    init(database: DatabaseManager, memories: SQLiteIntelligenceStore, generator: any GlobalMemoryCompactionGenerator) {
        self.database = database; self.memories = memories; self.generator = generator
    }
    func run() async throws {
        try await database.writer { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS global_memory_lifecycle(memory_id TEXT PRIMARY KEY NOT NULL,stage INTEGER NOT NULL,last_transition REAL NOT NULL)")
        }
        let rows: [(UUID, Int)] = try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id,COALESCE(l.stage,0) AS stage FROM memory_entries m LEFT JOIN global_memory_lifecycle l ON l.memory_id=m.id
                WHERE m.owner_deleted_at IS NOT NULL AND m.is_pinned=0 AND m.source_kind<>'explicitUserRequest'
                  AND ( (COALESCE(l.stage,0)=0 AND julianday('now')-MAX(julianday(m.owner_deleted_at),COALESCE(julianday(m.last_recalled_at),0))>=180)
                     OR (l.stage=1 AND julianday('now')-MAX(julianday(m.owner_deleted_at),COALESCE(julianday(m.last_recalled_at),0))>=365)
                     OR (l.stage>=2 AND l.last_transition<?))
                ORDER BY m.owner_deleted_at LIMIT 8
                """, arguments: [Date().addingTimeInterval(-90 * 86_400).timeIntervalSince1970]).compactMap { row in
                    let text: String = row["id"], stage: Int = row["stage"]; return UUID(uuidString: text).map { ($0, stage) }
                }
        }
        for (id, stage) in rows {
            try Task.checkCancellation()
            guard var memory = try await memories.memory(id: id) else { continue }
            if stage < 2 {
                try await database.writer { db in
                    if stage == 0 { try db.execute(sql: "UPDATE memory_entries SET importance=MAX(0.05,importance*0.7) WHERE id=? AND is_pinned=0 AND owner_deleted_at IS NOT NULL", arguments: [id.uuidString]) }
                    else { try db.execute(sql: "UPDATE memory_entries SET status='superseded' WHERE id=? AND is_pinned=0 AND owner_deleted_at IS NOT NULL", arguments: [id.uuidString]) }
                    try Self.transition(id, stage: stage + 1, db: db)
                }
                continue
            }
            // Missing models leave the same durable stage pending. No substring truncation is called compaction.
            let result = try await generator.compact(memory)
            if result.forget, stage >= 3 {
                try await memories.deleteMemory(id: id, syncRevision: Int64(Date().timeIntervalSince1970 * 1_000))
                try await database.writer { db in try db.execute(sql: "DELETE FROM global_memory_lifecycle WHERE memory_id=?", arguments: [id.uuidString]) }
            } else if let content = result.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty, content.count < memory.content.count, GlobalSourceTextPolicy.safeText(content) == content {
                let previous = memory.content; memory.content = content
                try await database.writer { db in
                    try db.execute(sql: "UPDATE memory_entries SET content=?,normalized_content=?,updated_at=? WHERE id=? AND content=? AND is_pinned=0 AND owner_deleted_at IS NOT NULL", arguments: [content, content.lowercased(), Date().ISO8601Format(), id.uuidString, previous])
                    guard db.changesCount == 1 else { throw GlobalSourceJobError.sourceChanged }
                    try db.execute(sql: "DELETE FROM memory_embeddings WHERE memory_id=?", arguments: [id.uuidString])
                    try Self.transition(id, stage: stage + 1, db: db)
                }
            }
        }
    }
    private static func transition(_ id: UUID, stage: Int, db: Database) throws {
        try db.execute(sql: "INSERT INTO global_memory_lifecycle(memory_id,stage,last_transition) VALUES (?,?,?) ON CONFLICT(memory_id) DO UPDATE SET stage=excluded.stage,last_transition=excluded.last_transition", arguments: [id.uuidString, stage, Date().timeIntervalSince1970])
    }
}
#endif
