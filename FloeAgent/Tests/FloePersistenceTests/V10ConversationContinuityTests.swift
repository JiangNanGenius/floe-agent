import GRDB
import Testing
@testable import FloePersistence

@Suite("FloePersistence.V10ConversationContinuity")
struct V10ConversationContinuityTests {
    @Test("v10 binds deterministic history and leaves ambiguous messages task-scoped")
    func migratesOnlyDeterministicLinks() throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: configuration)
        var throughV9 = DatabaseMigrator()
        V1Initial.register(into: &throughV9)
        V2ConfigSync.register(into: &throughV9)
        V3AgentDaily.register(into: &throughV9)
        V4ModelPreferences.register(into: &throughV9)
        V5Workspace.register(into: &throughV9)
        V6AppSettings.register(into: &throughV9)
        V7WorkbenchIntelligence.register(into: &throughV9)
        V8TaskOwnership.register(into: &throughV9)
        V9HarnessAndPermissions.register(into: &throughV9)
        try throughV9.migrate(queue)

        let conversationID = "10000000-0000-0000-0000-000000000001"
        let firstRunID = "20000000-0000-0000-0000-000000000001"
        let secondRunID = "20000000-0000-0000-0000-000000000002"
        let goalID = "30000000-0000-0000-0000-000000000001"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, 'Legacy', '2026-01-01T00:00:00Z', '2026-01-01T00:02:00Z')
                """, arguments: [conversationID])
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at, ended_at)
                VALUES
                  (?, ?, 'completed', 'repeat', '2026-01-01T00:00:00Z', '2026-01-01T00:00:30Z'),
                  (?, ?, 'completed', 'repeat', '2026-01-01T00:01:00Z', '2026-01-01T00:01:30Z')
                """, arguments: [firstRunID, conversationID, secondRunID, conversationID])
            try db.execute(sql: """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES
                  ('40000000-0000-0000-0000-000000000001', ?, 'user', 'repeat', '2026-01-01T00:00:00Z'),
                  ('40000000-0000-0000-0000-000000000002', ?, 'assistant', 'first answer', '2026-01-01T00:00:25Z')
                """, arguments: [conversationID, conversationID])
            try db.execute(sql: """
                INSERT INTO conversation_goals (
                    id, conversation_id, objective, status, criteria_json,
                    steps_json, evidence_json, budgets_json, progress_json,
                    created_at, updated_at
                ) VALUES (?, ?, 'repeat', 'active', '[]', '[]', '[]', '{}', '{}',
                          '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """, arguments: [goalID, conversationID])
        }

        var v10 = DatabaseMigrator()
        V10ConversationContinuity.register(into: &v10)
        try v10.migrate(queue)

        try queue.read { db in
            let userRun: String? = try String.fetchOne(
                db, sql: "SELECT run_id FROM messages WHERE role = 'user'"
            )
            let assistantRun: String? = try String.fetchOne(
                db, sql: "SELECT run_id FROM messages WHERE role = 'assistant'"
            )
            #expect(userRun == nil)
            #expect(assistantRun == firstRunID)
            #expect(try String.fetchAll(db, sql: "SELECT goal_id FROM runs ORDER BY started_at") == [goalID, goalID])
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 10)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}
