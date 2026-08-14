// FloePersistenceTests — Schema v1 build, cascades, FTS5, user_version,
// writer serialization, audit append-only.

import Foundation
import Testing
@testable import FloePersistence
import GRDB

@Suite("FloePersistence.DatabaseManager")
struct DatabaseManagerTests {

    private func makeManager() async throws -> DatabaseManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-test-\(UUID().uuidString).sqlite")
        let manager = try DatabaseManager(path: url)
        try await manager.migrate()
        return manager
    }

    @Test("Migrations create app and sync tables plus FTS virtual table")
    func v1CreatesSchema() async throws {
        let manager = try await makeManager()
        let tables = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'message_fts%'
                ORDER BY name
                """)
        }
        #expect(tables == [
            "approvals", "attachments", "audit_entries", "checkpoints", "config_sync_metadata",
            "conversations", "documents", "hosts", "images", "known_hosts", "message_parts",
            "messages", "models", "providers", "remote_sessions", "run_errors", "run_events",
            "run_usage", "runs", "sync_engine_state", "tool_calls", "vnc_sessions"
        ])
        let fts = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'message_fts'
                """)
        }
        #expect(fts == ["message_fts"])
    }

    @Test("user_version aligns with applied migrations")
    func userVersionAligned() async throws {
        let manager = try await makeManager()
        let version = try await manager.userVersion()
        #expect(version == DatabaseManager.currentSchemaVersion)
        let applied = try await manager.appliedMigrations()
        #expect(applied.contains("v1"))
        #expect(applied.contains("v2"))
        #expect(applied.contains("v3"))
    }

    @Test("Migration is idempotent (second migrate is a no-op)")
    func idempotentMigration() async throws {
        let manager = try await makeManager()
        try await manager.migrate()
        let version = try await manager.userVersion()
        #expect(version == DatabaseManager.currentSchemaVersion)
    }

    @Test("Foreign key cascade: deleting a conversation removes messages")
    func foreignKeyCascade() async throws {
        let manager = try await makeManager()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES ('c1', 'test', '2024-01-01T00:00:00Z', '2024-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES ('m1', 'c1', 'user', 'hello', '2024-01-01T00:00:00Z')
                """)
        }
        var count = try await manager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
        #expect(count == 1)
        try await manager.writer { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = 'c1'")
        }
        count = try await manager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
        #expect(count == 0)
    }

    @Test("FTS5 trigger sync and tokenization contract")
    func ftsQuery() async throws {
        let manager = try await makeManager()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES ('c1', 't', '2024-01-01T00:00:00Z', '2024-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES ('m1', 'c1', 'user', '请帮我分析这份报告的第三季度数据', '2024-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES ('m2', 'c1', 'assistant', 'unrelated english text', '2024-01-01T00:00:01Z')
                """)
        }
        // FTS5 unicode61 tokenizes a CJK run as ONE token, so a bare CJK
        // substring query matches nothing. Pin this contract: CJK search
        // needs a segmenting tokenizer or wildcard queries (M2+ decision).
        let cjkHits = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT m.id FROM messages m
                JOIN message_fts f ON m.rowid = f.rowid
                WHERE message_fts MATCH '报'
                """)
        }
        #expect(cjkHits.isEmpty)

        // The trigger pipeline itself works: English tokens match the
        // exact row synced from messages.
        let englishHits = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT m.id FROM messages m
                JOIN message_fts f ON m.rowid = f.rowid
                WHERE message_fts MATCH 'english'
                """)
        }
        #expect(englishHits == ["m2"])
    }

    @Test("Concurrent writers serialize without error")
    func concurrentWritersSerialize() async throws {
        let manager = try await makeManager()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES ('c1', 't', '2024-01-01T00:00:00Z', '2024-01-01T00:00:00Z')
                """)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await manager.writer { db in
                        try db.execute(
                            sql: """
                                INSERT INTO messages (id, conversation_id, role, content, created_at)
                                VALUES (?, 'c1', 'user', ?, '2024-01-01T00:00:00Z')
                                """,
                            arguments: ["m\(index)", "msg \(index)"]
                        )
                    }
                }
            }
            try await group.waitForAll()
        }
        let count = try await manager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
        #expect(count == 20)
    }

    @Test("audit_entries rejects UPDATE and DELETE (append-only)")
    func auditAppendOnly() async throws {
        let manager = try await makeManager()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO audit_entries
                    (id, sequence, timestamp, run_id, model_remote_id, tool_name,
                     target, policy_used, decision, exit_status,
                     output_digest_sha256, prev_hash_sha256, entry_hash_sha256)
                VALUES ('a1', 1, '2024-01-01T00:00:00Z', 'r1', 'm', 't', '', '', '', NULL, '',
                        '0000000000000000000000000000000000000000000000000000000000000000',
                        '1111111111111111111111111111111111111111111111111111111111111111')
                """)
        }
        await #expect(throws: (any Error).self) {
            try await manager.writer { db in
                try db.execute(sql: "UPDATE audit_entries SET decision = 'x' WHERE id = 'a1'")
            }
        }
        await #expect(throws: (any Error).self) {
            try await manager.writer { db in
                try db.execute(sql: "DELETE FROM audit_entries WHERE id = 'a1'")
            }
        }
        // INSERT still allowed.
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO audit_entries
                    (id, sequence, timestamp, run_id, model_remote_id, tool_name,
                     target, policy_used, decision, exit_status,
                     output_digest_sha256, prev_hash_sha256, entry_hash_sha256)
                VALUES ('a2', 2, '2024-01-01T00:00:01Z', 'r1', 'm', 't', '', '', '', NULL, '',
                        '1111111111111111111111111111111111111111111111111111111111111111',
                        '2222222222222222222222222222222222222222222222222222222222222222')
                """)
        }
    }
}
