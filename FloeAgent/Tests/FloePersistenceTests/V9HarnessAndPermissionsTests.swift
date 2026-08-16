import GRDB
import Testing
@testable import FloePersistence

@Suite("FloePersistence.V9HarnessAndPermissions")
struct V9HarnessAndPermissionsTests {
    @Test("v9 normalizes legacy approval values without granting authority")
    func normalizesLegacyApprovalValues() throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: configuration)
        var throughV8 = DatabaseMigrator()
        V1Initial.register(into: &throughV8)
        V2ConfigSync.register(into: &throughV8)
        V3AgentDaily.register(into: &throughV8)
        V4ModelPreferences.register(into: &throughV8)
        V5Workspace.register(into: &throughV8)
        V6AppSettings.register(into: &throughV8)
        V7WorkbenchIntelligence.register(into: &throughV8)
        V8TaskOwnership.register(into: &throughV8)
        try throughV8.migrate(queue)

        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO app_settings (key, value_json, updated_at) VALUES ('agent.defaultMode', ?, '2026-01-01T00:00:00Z')",
                arguments: [#""fullControl""#]
            )
            for (index, mode) in [nil, "human", "approvalModel", "fullControl", "automatic", "fullAccess"].enumerated() {
                let conversationID = "conversation-\(index)"
                try db.execute(
                    sql: "INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, '', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
                    arguments: [conversationID]
                )
                try db.execute(
                    sql: "INSERT INTO task_policies (conversation_id, approval_mode, updated_at) VALUES (?, ?, '2026-01-01T00:00:00Z')",
                    arguments: [conversationID, mode]
                )
            }
        }

        var v9 = DatabaseMigrator()
        V9HarnessAndPermissions.register(into: &v9)
        try v9.migrate(queue)

        try queue.read { db in
            let modes = try String.fetchAll(db, sql: "SELECT approval_mode FROM task_policies ORDER BY conversation_id")
            #expect(modes == ["ask", "ask", "ask", "ask", "automatic", "fullAccess"])
            #expect(try String.fetchOne(
                db,
                sql: "SELECT value_json FROM app_settings WHERE key = 'agent.defaultMode'"
            ) == #""human""#)
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 9)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}
