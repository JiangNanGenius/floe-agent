import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("FloePersistence.V13PersonalizationMemory")
struct V13PersonalizationMemoryTests {
    @Test("v13 creates vector, review and personalization tables")
    func schema() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)
        let tables = try await database.reader { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        #expect(Set([
            "memory_embeddings", "memory_candidates", "personalization_documents",
            "personalization_update_cursors"
        ]).isSubset(of: tables))
    }

    @Test("memory deletion cascades its embeddings")
    func embeddingCascade() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO memory_entries (
                    id, scope, status, content, normalized_content, confidence,
                    importance, is_pinned, source_kind, created_at, updated_at
                ) VALUES ('m1', 'user', 'active', 'hello', 'hello', 1, 1, 0,
                          'explicitUserRequest', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO memory_embeddings (
                    memory_id, modality, model_identifier, model_revision,
                    dimensions, vector_blob, content_digest, created_at
                ) VALUES ('m1', 'text', 'test', '1', 2, ?, 'digest', '2026-01-01T00:00:00Z')
                """, arguments: [Data(count: 8)])
            try db.execute(sql: "DELETE FROM memory_entries WHERE id = 'm1'")
        }
        let count = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_embeddings") ?? -1
        }
        #expect(count == 0)
    }
}
