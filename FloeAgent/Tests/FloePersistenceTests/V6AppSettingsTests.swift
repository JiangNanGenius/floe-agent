// FloePersistenceTests — Schema v6 (app_settings) migration tests.
// See docs/ARCHITECTURE_SETTINGS.md §2.3: v1→v6 full-chain migration,
// v5 data preservation, app_settings CRUD, idempotency, STRICT negatives.

import Foundation
import Testing
import GRDB
@testable import FloePersistence
import FloeModels

@Suite("FloePersistence.V6AppSettings")
struct V6AppSettingsTests {

    private func makeDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    // MARK: 1. Migration reaches v6 from v1

    @Test("Migration v1…v6 applies cleanly and sets user_version = 6")
    func migratesToV6() async throws {
        let database = try await makeDatabase()
        #expect(try await database.userVersion() == 6)
        #expect(DatabaseManager.currentSchemaVersion == 6)
        let applied = try await database.appliedMigrations()
        for identifier in ["v1", "v2", "v3", "v4", "v5", "v6"] {
            #expect(applied.contains(identifier), "missing migration \(identifier)")
        }
    }

    @Test("v6 creates the app_settings table as STRICT")
    func v6TableExists() async throws {
        let database = try await makeDatabase()
        let tables = try await database.reader { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        #expect(tables.contains("app_settings"))
        let sql = try await database.reader { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name='app_settings'"
            )
        }
        #expect(sql?.contains("STRICT") == true)
    }

    // MARK: 2. v5 data survives the v6 migration

    @Test("v5 data (workspaces/grants/conversations) survives migration to v6")
    func v5DataPreserved() async throws {
        // Build a v5-only database, seed data, then re-open and migrate to v6.
        let path = NSTemporaryDirectory()
            .appending("floe-v6-preserve-\(UUID().uuidString).sqlite")
        let fileURL = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let workspaceID = UUID()
        let conversationID = UUID()
        let grantID = UUID()

        do {
            // v5-only migrator: registration list without v6.
            var migrator = DatabaseMigrator()
            V1Initial.register(into: &migrator)
            V2ConfigSync.register(into: &migrator)
            V3AgentDaily.register(into: &migrator)
            V4ModelPreferences.register(into: &migrator)
            V5Workspace.register(into: &migrator)
            let queue = try DatabaseQueue(path: path)
            try migrator.migrate(queue)
            let version = try await queue.read { db in
                try Int.fetchOne(db, sql: "PRAGMA user_version")
            }
            #expect(version == 5)
            try await queue.write { db in
                let now = PersistenceCodec.encode(Date())
                try db.execute(
                    sql: """
                        INSERT INTO workspaces (
                            id, name, root_bookmark, inspector_state_json, created_at, updated_at
                        ) VALUES (?, 'legacy', ?, '{}', ?, ?)
                        """,
                    arguments: [workspaceID.uuidString, Data([0x01]), now, now]
                )
                try db.execute(
                    sql: "INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, 'keep', ?, ?)",
                    arguments: [conversationID.uuidString, now, now]
                )
                try db.execute(
                    sql: """
                        INSERT INTO workspace_conversations (workspace_id, conversation_id, created_at)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [workspaceID.uuidString, conversationID.uuidString, now]
                )
                try db.execute(
                    sql: """
                        INSERT INTO approval_grants (
                            id, workspace_id, tool_name, paths_json, single_use, policy_name, decided_at
                        ) VALUES (?, ?, 'workspace.writeFile', '["Sources/"]', 0, 'human', ?)
                        """,
                    arguments: [grantID.uuidString, workspaceID.uuidString, now]
                )
            }
        }

        // Re-open through DatabaseManager: v6 must apply on top.
        let database = try DatabaseManager(path: fileURL)
        try await database.migrate()
        #expect(try await database.userVersion() == 6)

        let workspaceStore = SQLiteWorkspaceStore(database: database)
        let workspace = try await workspaceStore.workspace(id: workspaceID)
        #expect(workspace?.name == "legacy")
        #expect(try await workspaceStore.conversations(workspaceID: workspaceID) == [conversationID])

        let grants = try await workspaceStore.allGrants()
        #expect(grants.count == 1)
        #expect(grants[0].id == grantID)
        #expect(grants[0].paths == ["Sources/"])
        #expect(grants[0].singleUse == false)

        let conversationStore = SQLiteConversationStore(database: database)
        #expect(try await conversationStore.conversation(id: conversationID)?.title == "keep")
    }

    // MARK: 3. app_settings CRUD via raw SQL (store behaviour lives in SettingsStoreTests)

    @Test("app_settings upserts and deletes rows")
    func appSettingsCRUD() async throws {
        let database = try await makeDatabase()
        try await database.writer { db in
            let now = PersistenceCodec.encode(Date())
            try db.execute(
                sql: "INSERT INTO app_settings (key, value_json, updated_at) VALUES ('agent.defaultMode', '\"human\"', ?)",
                arguments: [now]
            )
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at)
                    VALUES ('agent.defaultMode', '\"approvalModel\"', ?)
                    ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json
                    """,
                arguments: [now]
            )
        }
        let value = try await database.reader { db in
            try String.fetchOne(
                db,
                sql: "SELECT value_json FROM app_settings WHERE key = 'agent.defaultMode'"
            )
        }
        #expect(value == "\"approvalModel\"")

        try await database.writer { db in
            try db.execute(sql: "DELETE FROM app_settings WHERE key = 'agent.defaultMode'")
        }
        #expect(try await database.reader { db in
            try String.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = 'agent.defaultMode'")
        } == nil)
    }

    // MARK: 4. Migration idempotency

    @Test("Running the migrator twice is a no-op")
    func migrationIdempotent() async throws {
        let database = try await makeDatabase()
        try await database.migrate()
        #expect(try await database.userVersion() == 6)
        let applied = try await database.appliedMigrations()
        #expect(applied.filter { $0 == "v6" }.count == 1)
    }

    // MARK: 5. STRICT negative cases

    @Test("STRICT table rejects type-mismatched writes")
    func strictRejectsTypeMismatch() async throws {
        let db = try await makeDatabase()
        await #expect(throws: (any Error).self) {
            try await db.writer { db in
                // value_json is TEXT; a BLOB must be rejected by STRICT.
                try db.execute(
                    sql: "INSERT INTO app_settings (key, value_json, updated_at) VALUES ('x', ?, ?)",
                    arguments: [Data([0x00]), PersistenceCodec.encode(Date())]
                )
            }
        }
        await #expect(throws: (any Error).self) {
            try await db.writer { db in
                // updated_at is TEXT; a BLOB must be rejected by STRICT.
                // (STRICT accepts numeric values in TEXT columns via
                // flexible numeric affinity, so a BLOB is the reliable
                // negative case.)
                try db.execute(
                    sql: "INSERT INTO app_settings (key, value_json, updated_at) VALUES ('y', '{}', ?)",
                    arguments: [Data([0x00])]
                )
            }
        }
        // NOT NULL: missing value_json must be rejected.
        await #expect(throws: (any Error).self) {
            try await db.writer { db in
                try db.execute(
                    sql: "INSERT INTO app_settings (key, updated_at) VALUES ('z', ?)",
                    arguments: [PersistenceCodec.encode(Date())]
                )
            }
        }
    }
}
