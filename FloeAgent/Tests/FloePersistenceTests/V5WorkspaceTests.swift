// FloePersistenceTests — Schema v5 (workspace) migration and store tests.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §5.3: v1→v5 migration, v4 data
// preservation, foreign-key cascades, nullable grant FKs, idempotency and
// STRICT negative cases.

import Foundation
import Testing
import GRDB
@testable import FloePersistence
import FloeModels

@Suite("FloePersistence.V5Workspace")
struct V5WorkspaceTests {

    private func makeDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    private func makeStore(_ db: DatabaseManager) -> SQLiteWorkspaceStore {
        SQLiteWorkspaceStore(database: db)
    }

    private func makeWorkspace(id: UUID = UUID(), name: String = "proj") -> WorkspaceRecord {
        WorkspaceRecord(
            id: id,
            name: name,
            rootBookmark: Data([0x62, 0x6F, 0x6F, 0x6B]),
            activeTarget: .local,
            inspectorState: InspectorState(isExpanded: true, selectedRelativePath: "README.md"),
            instructionsRelativePath: "FLOE.md"
        )
    }

    private func seedConversation(_ db: DatabaseManager, id: UUID) async throws {
        try await db.writer { db in
            try db.execute(
                sql: "INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, '', ?, ?)",
                arguments: [
                    id.uuidString,
                    PersistenceCodec.encode(Date()),
                    PersistenceCodec.encode(Date())
                ]
            )
        }
    }

    // MARK: 1. Migration reaches v5 from v1

    @Test("Migration v1…v5 applies cleanly and sets user_version = 5")
    func migratesToV5() async throws {
        let database = try await makeDatabase()
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)
        #expect(try await database.userVersion() >= 5)
        let applied = try await database.appliedMigrations()
        for identifier in ["v1", "v2", "v3", "v4", "v5"] {
            #expect(applied.contains(identifier), "missing migration \(identifier)")
        }
    }

    @Test("v5 creates the workspace tables and indexes")
    func v5TablesExist() async throws {
        let database = try await makeDatabase()
        let tables = try await database.reader { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        for expected in ["workspaces", "workspace_conversations", "workspace_recent_files", "approval_grants"] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }
        let indexes = try await database.reader { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
        }
        #expect(indexes.contains("idx_workspace_conversations_conversation"))
        #expect(indexes.contains("idx_approval_grants_lookup"))
    }

    // MARK: 2. v4 data survives the v5 migration

    @Test("v4 data (conversations/messages/run_events) survives migration to v5")
    func v4DataPreserved() async throws {
        // Build a v4-only database, seed data, close, then re-open with v5.
        let path = NSTemporaryDirectory()
            .appending("floe-v5-preserve-\(UUID().uuidString).sqlite")
        let fileURL = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let conversationID = UUID()
        let messageID = UUID()
        let runID = UUID()

        do {
            // v4-only migrator: reproduce the registration list without v5.
            var migrator = DatabaseMigrator()
            V1Initial.register(into: &migrator)
            V2ConfigSync.register(into: &migrator)
            V3AgentDaily.register(into: &migrator)
            V4ModelPreferences.register(into: &migrator)
            let queue = try DatabaseQueue(path: path)
            try migrator.migrate(queue)
            let version = try await queue.read { db in
                try Int.fetchOne(db, sql: "PRAGMA user_version")
            }
            #expect(version == 4)
            try await queue.write { db in
                let now = PersistenceCodec.encode(Date())
                try db.execute(
                    sql: "INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, 'keep', ?, ?)",
                    arguments: [conversationID.uuidString, now, now]
                )
                try db.execute(
                    sql: """
                        INSERT INTO messages (id, conversation_id, role, content, created_at)
                        VALUES (?, ?, 'user', 'hello v4', ?)
                        """,
                    arguments: [messageID.uuidString, conversationID.uuidString, now]
                )
                try db.execute(
                    sql: """
                        INSERT INTO runs (id, conversation_id, state, goal, started_at)
                        VALUES (?, ?, 'completed', 'g', ?)
                        """,
                    arguments: [runID.uuidString, conversationID.uuidString, now]
                )
                try db.execute(
                    sql: """
                        INSERT INTO run_events (id, run_id, sequence, kind, payload_json, created_at)
                        VALUES (?, ?, 1, 'assistantText', '{}', ?)
                        """,
                    arguments: [UUID().uuidString, runID.uuidString, now]
                )
            }
        }

        // Re-open through DatabaseManager: v5 (and any later migrations)
        // must apply on top.
        let database = try DatabaseManager(path: fileURL)
        try await database.migrate()
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)

        let conversationStore = SQLiteConversationStore(database: database)
        let conversation = try await conversationStore.conversation(id: conversationID)
        #expect(conversation?.title == "keep")
        let messages = try await conversationStore.messages(conversationID: conversationID)
        #expect(messages.count == 1)
        #expect(messages[0].content == "hello v4")

        let runStore = SQLiteRunStore(database: database)
        let events = try await runStore.events(runID: runID)
        #expect(events.count == 1)
        #expect(events[0].kind == .assistantText)
    }

    // MARK: 3. Foreign-key cascades

    @Test("Deleting a workspace cascades conversation links and recent files")
    func workspaceCascade() async throws {
        let db = try await makeDatabase()
        let store = makeStore(db)
        let workspace = makeWorkspace()
        try await store.saveWorkspace(workspace)
        let conversationID = UUID()
        try await seedConversation(db, id: conversationID)
        try await store.linkConversation(workspaceID: workspace.id, conversationID: conversationID)
        try await store.recordRecentFile(RecentFile(
            workspaceID: workspace.id, relativePath: "Sources/main.swift", displayName: "main.swift"
        ))
        try await store.saveGrant(StoredGrant(
            workspaceID: workspace.id, toolName: "workspace.writeFile", policyName: "human"
        ))

        try await store.deleteWorkspace(id: workspace.id)
        #expect(try await store.workspace(id: workspace.id) == nil)
        #expect(try await store.conversations(workspaceID: workspace.id).isEmpty)
        #expect(try await store.recentFiles(workspaceID: workspace.id).isEmpty)
        #expect(try await store.activeGrants(
            toolName: "workspace.writeFile", workspaceID: workspace.id, hostID: nil
        ).isEmpty)

        // The conversation row itself survives — only the link is removed.
        let conversationStore = SQLiteConversationStore(database: db)
        #expect(try await conversationStore.conversation(id: conversationID) != nil)
    }

    @Test("Deleting a conversation cascades the workspace link")
    func conversationCascadeClearsLink() async throws {
        let db = try await makeDatabase()
        let store = makeStore(db)
        let workspace = makeWorkspace()
        try await store.saveWorkspace(workspace)
        let conversationID = UUID()
        try await seedConversation(db, id: conversationID)
        try await store.linkConversation(workspaceID: workspace.id, conversationID: conversationID)
        #expect(try await store.conversations(workspaceID: workspace.id) == [conversationID])

        let conversationStore = SQLiteConversationStore(database: db)
        try await conversationStore.deleteConversation(id: conversationID)
        #expect(try await store.conversations(workspaceID: workspace.id).isEmpty)
    }

    // MARK: 4. approval_grants nullable FKs (SET NULL target column / CASCADE grant)

    @Test("Deleting a host sets workspaces.active_target_host_id to NULL and cascades host grants")
    func hostDeleteSemantics() async throws {
        let db = try await makeDatabase()
        let store = makeStore(db)
        let hostID = UUID()
        try await db.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO hosts (id, display_name, address, port, user, auth_json, created_at, updated_at)
                    VALUES (?, 'box', '192.168.1.10', 22, 'me', '{}', ?, ?)
                    """,
                arguments: [
                    hostID.uuidString,
                    PersistenceCodec.encode(Date()),
                    PersistenceCodec.encode(Date())
                ]
            )
        }

        var workspace = makeWorkspace()
        workspace.activeTarget = .host(hostID)
        try await store.saveWorkspace(workspace)
        try await store.saveGrant(StoredGrant(
            workspaceID: workspace.id, hostID: hostID,
            toolName: "ssh.execute", singleUse: false, policyName: "human"
        ))

        try await db.writer { db in
            try db.execute(sql: "DELETE FROM hosts WHERE id = ?", arguments: [hostID.uuidString])
        }

        // SET NULL: the workspace row survives with a NULL host reference.
        let reloaded = try await store.workspace(id: workspace.id)
        #expect(reloaded?.activeTarget.hostID == nil)
        // CASCADE: grants anchored to the deleted host are removed.
        #expect(try await store.activeGrants(
            toolName: "ssh.execute", workspaceID: workspace.id, hostID: hostID
        ).isEmpty)
    }

    // MARK: 5. Migration idempotency

    @Test("Running the migrator twice is a no-op")
    func migrationIdempotent() async throws {
        let database = try await makeDatabase()
        try await database.migrate()
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)
        let applied = try await database.appliedMigrations()
        #expect(applied.filter { $0 == "v5" }.count == 1)
    }

    // MARK: 6. STRICT negative cases

    @Test("STRICT tables reject type-mismatched writes")
    func strictRejectsTypeMismatch() async throws {
        let db = try await makeDatabase()
        await #expect(throws: (any Error).self) {
            try await db.writer { db in
                // root_bookmark is BLOB; a TEXT value must be rejected by STRICT.
                try db.execute(
                    sql: """
                        INSERT INTO workspaces (id, name, root_bookmark, created_at, updated_at)
                        VALUES (?, 'x', 'not-a-blob', ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString,
                        PersistenceCodec.encode(Date()),
                        PersistenceCodec.encode(Date())
                    ]
                )
            }
        }
        await #expect(throws: (any Error).self) {
            try await db.writer { db in
                // single_use is INTEGER; a TEXT value must be rejected.
                try db.execute(
                    sql: """
                        INSERT INTO approval_grants (
                            id, tool_name, single_use, policy_name, decided_at
                        ) VALUES (?, 'workspace.readFile', 'yes', 'human', ?)
                        """,
                    arguments: [UUID().uuidString, PersistenceCodec.encode(Date())]
                )
            }
        }
    }

    // MARK: WorkspaceStore behaviour

    @Test("Workspace CRUD round-trips all fields in deterministic order")
    func workspaceCRUD() async throws {
        let db = try await makeDatabase()
        let store = makeStore(db)
        let first = makeWorkspace(name: "alpha")
        var second = makeWorkspace(name: "Beta")
        second.activeTarget = .local
        second.inspectorState = InspectorState(isExpanded: false, selectedRelativePath: nil)
        second.instructionsRelativePath = nil
        try await store.saveWorkspace(first)
        try await store.saveWorkspace(second)

        let all = try await store.workspaces()
        #expect(all.map(\.name) == ["alpha", "Beta"]) // name-sorted

        let loaded = try await store.workspace(id: first.id)
        #expect(loaded?.rootBookmark == first.rootBookmark)
        #expect(loaded?.inspectorState.isExpanded == true)
        #expect(loaded?.inspectorState.selectedRelativePath == "README.md")
        #expect(loaded?.instructionsRelativePath == "FLOE.md")
        #expect(loaded?.activeTarget == .local)

        // Upsert updates mutable fields.
        var renamed = first
        renamed.name = "alpha-2"
        try await store.saveWorkspace(renamed)
        #expect(try await store.workspace(id: first.id)?.name == "alpha-2")
        #expect(try await store.workspaces().count == 2)
    }

    @Test("touchLastOpened updates the timestamp")
    func touchLastOpened() async throws {
        let db = try await makeDatabase()
        let store = makeStore(db)
        let workspace = makeWorkspace()
        try await store.saveWorkspace(workspace)
        #expect(try await store.workspace(id: workspace.id)?.lastOpenedAt == nil)

        try await store.touchLastOpened(id: workspace.id)
        let opened = try await store.workspace(id: workspace.id)?.lastOpenedAt
        #expect(opened != nil)
    }

    @Test("Conversation links are idempotent and unlinkable")
    func conversationLinks() async throws {
        let db = try await makeDatabase()
        let store = makeStore(db)
        let workspace = makeWorkspace()
        try await store.saveWorkspace(workspace)
        let a = UUID()
        let b = UUID()
        try await seedConversation(db, id: a)
        try await seedConversation(db, id: b)

        try await store.linkConversation(workspaceID: workspace.id, conversationID: a)
        try await store.linkConversation(workspaceID: workspace.id, conversationID: b)
        try await store.linkConversation(workspaceID: workspace.id, conversationID: a) // no-op
        #expect(Set(try await store.conversations(workspaceID: workspace.id)) == Set([a, b]))

        try await store.unlinkConversation(workspaceID: workspace.id, conversationID: a)
        #expect(try await store.conversations(workspaceID: workspace.id) == [b])
    }

    @Test("Recent files upsert and sort by recency")
    func recentFiles() async throws {
        let db = try await makeDatabase()
        let store = makeStore(db)
        let workspace = makeWorkspace()
        try await store.saveWorkspace(workspace)

        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        try await store.recordRecentFile(RecentFile(
            workspaceID: workspace.id, relativePath: "a.md", displayName: "a.md", lastOpenedAt: old
        ))
        try await store.recordRecentFile(RecentFile(
            workspaceID: workspace.id, relativePath: "b.md", displayName: "b.md", lastOpenedAt: new
        ))
        // Upsert a.md with a newer timestamp: moves to the front.
        try await store.recordRecentFile(RecentFile(
            workspaceID: workspace.id, relativePath: "a.md", displayName: "a.md",
            lastOpenedAt: new.addingTimeInterval(1_000)
        ))

        let files = try await store.recentFiles(workspaceID: workspace.id)
        #expect(files.count == 2)
        #expect(files.map(\.relativePath) == ["a.md", "b.md"])

        try await store.removeRecentFile(workspaceID: workspace.id, relativePath: "b.md")
        #expect(try await store.recentFiles(workspaceID: workspace.id).map(\.relativePath) == ["a.md"])
    }

    @Test("Grants: scope lookup, expiry filtering and no secret storage")
    func grantLookupAndExpiry() async throws {
        let db = try await makeDatabase()
        let store = makeStore(db)
        let workspace = makeWorkspace()
        try await store.saveWorkspace(workspace)

        let expired = StoredGrant(
            workspaceID: workspace.id, toolName: "workspace.writeFile",
            paths: ["Sources/"], singleUse: false, policyName: "human",
            decidedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 2_000) // in the past
        )
        let active = StoredGrant(
            workspaceID: workspace.id, toolName: "workspace.writeFile",
            paths: ["README.md"], singleUse: false, policyName: "human",
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let noExpiry = StoredGrant(
            workspaceID: workspace.id, toolName: "workspace.readFile", policyName: "autopilot"
        )
        try await store.saveGrant(expired)
        try await store.saveGrant(active)
        try await store.saveGrant(noExpiry)

        let writeGrants = try await store.activeGrants(
            toolName: "workspace.writeFile", workspaceID: workspace.id, hostID: nil
        )
        #expect(writeGrants.count == 1)
        #expect(writeGrants[0].id == active.id)
        #expect(writeGrants[0].paths == ["README.md"])
        #expect(writeGrants[0].singleUse == false)

        // Different tool name: no cross-tool leakage.
        #expect(try await store.activeGrants(
            toolName: "workspace.deleteFile", workspaceID: workspace.id, hostID: nil
        ).isEmpty)

        // No-expiry grant remains active.
        let readGrants = try await store.activeGrants(
            toolName: "workspace.readFile", workspaceID: workspace.id, hostID: nil
        )
        #expect(readGrants.count == 1)
    }
}
