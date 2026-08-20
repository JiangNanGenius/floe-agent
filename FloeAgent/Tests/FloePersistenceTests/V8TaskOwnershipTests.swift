import Foundation
import GRDB
import Testing
import FloeModels
@testable import FloePersistence

@Suite("FloePersistence.V8TaskOwnership")
struct V8TaskOwnershipTests {
    private func v7Queue() throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        V1Initial.register(into: &migrator)
        V2ConfigSync.register(into: &migrator)
        V3AgentDaily.register(into: &migrator)
        V4ModelPreferences.register(into: &migrator)
        V5Workspace.register(into: &migrator)
        V6AppSettings.register(into: &migrator)
        V7WorkbenchIntelligence.register(into: &migrator)
        try migrator.migrate(queue)
        return queue
    }

    @Test("v8 assigns one owner and reports discarded legacy links")
    func migratesLegacyOwnership() throws {
        let queue = try v7Queue()
        let conversation = UUID().uuidString
        let old = UUID().uuidString
        let recent = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, 'Legacy', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """, arguments: [conversation])
            for id in [old, recent] {
                try db.execute(sql: """
                    INSERT INTO workspaces (
                        id, name, root_bookmark, active_target_kind,
                        inspector_state_json, created_at, updated_at
                    ) VALUES (?, ?, ?, 'local', '{}',
                              '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                    """, arguments: [id, id, Data([1])])
            }
            try db.execute(sql: """
                INSERT INTO workspace_conversations (workspace_id, conversation_id, created_at)
                VALUES (?, ?, '2026-01-01T00:00:00Z'),
                       (?, ?, '2026-02-01T00:00:00Z')
                """, arguments: [old, conversation, recent, conversation])
        }
        var v8 = DatabaseMigrator()
        V8TaskOwnership.register(into: &v8)
        try v8.migrate(queue)

        try queue.read { db in
            let owner = try String.fetchOne(
                db,
                sql: "SELECT workspace_id FROM conversation_workspace_ownership WHERE conversation_id = ?",
                arguments: [conversation]
            )
            #expect(owner == recent)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_reports") == 1)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test("v8 creates an internal private workspace for an unowned task")
    func migratesUnownedConversation() throws {
        let queue = try v7Queue()
        let conversation = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, 'Solo', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """, arguments: [conversation])
        }
        var v8 = DatabaseMigrator()
        V8TaskOwnership.register(into: &v8)
        try v8.migrate(queue)

        try queue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT w.kind, w.internal_relative_path
                FROM workspaces w JOIN conversation_workspace_ownership o ON o.workspace_id = w.id
                WHERE o.conversation_id = ?
                """, arguments: [conversation])
            #expect(row?["kind"] as String? == "privateTask")
            #expect((row?["internal_relative_path"] as String?)?.contains(conversation) == true)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test("Deleting a project rehomes its tasks without deleting conversations")
    func deletingProjectRehomesTasks() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-v8-rehome-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try DatabaseManager(path: url)
        try await database.migrate()
        let workspaceStore = SQLiteWorkspaceStore(database: database)
        let conversationStore = SQLiteConversationStore(database: database)
        let project = WorkspaceRecord(name: "Project", rootBookmark: Data([1]))
        let conversation = ConversationRecord(
            id: UUID(),
            title: "Keep me",
            createdAt: Date(),
            updatedAt: Date()
        )
        try await workspaceStore.saveWorkspace(project)
        try await conversationStore.saveConversation(conversation)
        try await workspaceStore.assignConversation(
            workspaceID: project.id,
            conversationID: conversation.id
        )

        try await workspaceStore.deleteWorkspace(id: project.id)

        #expect(try await conversationStore.conversation(id: conversation.id) != nil)
        let owner = try await workspaceStore.workspaceID(conversationID: conversation.id)
        guard let newOwner = owner else {
            Issue.record("conversation must retain an owner")
            return
        }
        #expect(newOwner != project.id)
        #expect(try await workspaceStore.workspace(id: newOwner)?.kind == .privateTask)
        let foreignKeyIssueCount = try await database.reader { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
        }
        #expect(foreignKeyIssueCount == 0)
    }
}
