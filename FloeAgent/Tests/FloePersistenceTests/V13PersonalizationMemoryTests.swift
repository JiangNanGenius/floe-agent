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

@Suite("FloePersistence.V52PersonalizationRetention")
struct V52PersonalizationRetentionTests {
    private static func insertLegacyDocument(_ db: Database, id: String,
        kind: String, workspaceID: String?, revision: Int, source: String, isActive: Bool) throws
    {
        try db.execute(sql: """
            INSERT INTO personalization_documents (
                id, kind, workspace_id, revision, content, source_kind,
                evidence_digest, is_active, created_at, lifecycle
            ) VALUES (?, ?, ?, ?, ?, ?, '', ?, '2026-01-01T00:00:00Z', NULL)
            """, arguments: [id, kind, workspaceID, revision, "body-\(id)", source,
                isActive ? 1 : 0])
    }

    private static func laneState(_ db: Database, kind: String, workspaceID: String?) throws
        -> [(id: String, lifecycle: String?, isActive: Bool, revision: Int)]
    {
        try Row.fetchAll(db, sql: """
            SELECT id, lifecycle, is_active, revision FROM personalization_documents
            WHERE kind = ? AND workspace_id IS ? ORDER BY revision
            """, arguments: [kind, workspaceID]).map { row in
            let id: String = row["id"]
            let lifecycle: String? = row["lifecycle"]
            let isActive: Int = row["is_active"]
            let revision: Int = row["revision"]
            return (id, lifecycle, isActive != 0, revision)
        }
    }

    @Test("v52 adds the lifecycle column, revision sequences and unique slot indexes")
    func schema() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)
        let migrations = try await database.appliedMigrations()
        #expect(migrations.contains("v52_personalization_retention"))
        let columns = try await database.reader { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('personalization_documents')"))
        }
        #expect(columns.contains("lifecycle"))
        let tables = try await database.reader { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        #expect(tables.contains("personalization_revision_sequences"))
        let indexes = try await database.reader { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        }
        #expect(indexes.contains("idx_personalization_lifecycle_global"))
        #expect(indexes.contains("idx_personalization_lifecycle_workspace"))
    }

    @Test("backfill keeps current plus the confident activated backup and prunes obsolete drafts")
    func legacyBackfill() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        try await database.writer { db in
            // Legacy lane: activated history interleaved with two never-
            // reviewed automatic drafts. The latest automatic draft (r4) is
            // ambiguous and must never be promoted into a retained slot.
            try Self.insertLegacyDocument(db, id: "r1", kind: "soul", workspaceID: nil,
                revision: 1, source: "manual", isActive: false)
            try Self.insertLegacyDocument(db, id: "r2", kind: "soul", workspaceID: nil,
                revision: 2, source: "automatic", isActive: false)
            try Self.insertLegacyDocument(db, id: "r3", kind: "soul", workspaceID: nil,
                revision: 3, source: "rollback", isActive: false)
            try Self.insertLegacyDocument(db, id: "r4", kind: "soul", workspaceID: nil,
                revision: 4, source: "automatic", isActive: false)
            try Self.insertLegacyDocument(db, id: "r5", kind: "soul", workspaceID: nil,
                revision: 5, source: "oneClick", isActive: false)
            try Self.insertLegacyDocument(db, id: "r6", kind: "soul", workspaceID: nil,
                revision: 6, source: "automatic", isActive: true)
            // A second kind stays independent even while unactivated.
            try Self.insertLegacyDocument(db, id: "p1", kind: "userProfile", workspaceID: nil,
                revision: 1, source: "manual", isActive: true)
            try V52PersonalizationRetention.backfill(db, now: "2026-02-01T00:00:00Z")
        }
        let soul = try await database.reader { db in try Self.laneState(db, kind: "soul", workspaceID: nil) }
        #expect(soul.map(\.id) == ["r5", "r6"])
        #expect(soul.map(\.lifecycle) == ["previous", "current"])
        #expect(soul.first { $0.id == "r6" }?.isActive == true)
        #expect(soul.first { $0.id == "r5" }?.isActive == false)
        let profile = try await database.reader { db in try Self.laneState(db, kind: "userProfile", workspaceID: nil) }
        #expect(profile.map(\.lifecycle) == ["current"])
        let seeded = try await database.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT last_revision FROM personalization_revision_sequences
                WHERE kind = 'soul' AND workspace_key = ''
                """) ?? -1
        }
        // Pruned draft revisions 2–4 were counted: the allocator starts above
        // the highest legacy revision and their numbers are never reused.
        #expect(seeded == 6)
    }

    @Test("backfill is idempotent and classifies workspace lanes independently")
    func backfillIdempotencyAndWorkspaceLanes() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let workspace = UUID().uuidString
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO workspaces (id, root_bookmark, created_at, updated_at)
                VALUES (?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """, arguments: [workspace, Data(count: 8)])
            try Self.insertLegacyDocument(db, id: "g1", kind: "soul", workspaceID: nil,
                revision: 1, source: "manual", isActive: true)
            try Self.insertLegacyDocument(db, id: "w1", kind: "soul", workspaceID: workspace,
                revision: 1, source: "oneClick", isActive: false)
            try Self.insertLegacyDocument(db, id: "w2", kind: "soul", workspaceID: workspace,
                revision: 2, source: "manual", isActive: true)
            try V52PersonalizationRetention.backfill(db, now: "2026-02-01T00:00:00Z")
        }
        let firstPass = try await database.reader { db in try Self.laneState(db, kind: "soul", workspaceID: workspace) }
        #expect(firstPass.map(\.lifecycle) == ["previous", "current"])
        try await database.writer { db in
            try V52PersonalizationRetention.backfill(db, now: "2026-02-02T00:00:00Z")
        }
        let global = try await database.reader { db in try Self.laneState(db, kind: "soul", workspaceID: nil) }
        let local = try await database.reader { db in try Self.laneState(db, kind: "soul", workspaceID: workspace) }
        #expect(global.map(\.lifecycle) == ["current"])
        #expect(local.map(\.lifecycle) == ["previous", "current"])
        let sequences = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_revision_sequences") ?? -1
        }
        // One allocator row per lane, none duplicated by the second pass.
        #expect(sequences == 2)
    }
}
