import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("FloePersistence.V7WorkbenchIntelligence")
struct V7WorkbenchIntelligenceTests {
    @Test("v7 creates durable workbench intelligence schema")
    func schema() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        #expect(try await database.userVersion() == 7)

        let required = Set([
            "plan_drafts", "conversation_goals", "goal_criteria", "goal_steps",
            "goal_events", "run_relations", "context_compactions", "memory_entries",
            "memory_evidence", "memory_tombstones", "skills", "skill_resources",
            "skill_permissions", "workspace_skills", "browser_sessions",
            "browser_tabs", "browser_artifacts"
        ])
        let tables = try await database.reader { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        #expect(required.isSubset(of: tables))
    }

    @Test("v7 keeps foreign-key integrity and cascades intelligence rows")
    func integrityAndCascade() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationID = UUID().uuidString
        let planID = UUID().uuidString
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, 'test', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """, arguments: [conversationID])
            try db.execute(sql: """
                INSERT INTO plan_drafts (
                    id, conversation_id, revision, status, title, summary, digest,
                    created_at, updated_at
                ) VALUES (?, ?, 1, 'drafting', 'Plan', '', 'digest',
                          '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """, arguments: [planID, conversationID])
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [conversationID])
        }
        let count = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM plan_drafts") ?? -1
        }
        #expect(count == 0)
        let violations = try await database.reader { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
        }
        #expect(violations == 0)
    }
}
