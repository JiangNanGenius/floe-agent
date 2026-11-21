import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("Local workspace cleanup")
struct LocalWorkspaceCleanupTests {
    @Test("Upgrade removes a stale cleanup intent for an existing game workspace")
    func upgradeRetainsExistingGameWorkspace() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let workspaces = SQLiteWorkspaceStore(database: database)
        let game = WorkspaceRecord(name: "Game", rootBookmark: Data(), kind: .privateTask,
                                   internalRelativePath: "Personal/Game/Files")
        try await workspaces.saveWorkspace(game)
        try await database.writer { db in
            try db.execute(sql: "INSERT INTO local_workspace_cleanup (workspace_id, relative_path) VALUES (?, ?)",
                           arguments: [game.id.uuidString, game.internalRelativePath])
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v65'")
            try db.execute(sql: "PRAGMA user_version = 64")
        }
        try await database.migrate()
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)
        #expect(try await workspaces.pendingLocalCleanup().isEmpty)
        #expect(try await workspaces.workspace(id: game.id) != nil)
    }

    @Test("Game workspace migration respects the observed owner and running tasks")
    func gameWorkspaceMigrationIsIdleAndCompareAndSwap() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let tasks = SQLiteConversationStore(database: database)
        let workspaces = SQLiteWorkspaceStore(database: database)
        let task = ConversationRecord(id: UUID(), title: "Game", createdAt: Date(), updatedAt: Date())
        try await tasks.saveConversation(task)
        let previous = try await workspaces.ensureWorkspace(conversationID: task.id, title: task.title)
        let game = WorkspaceRecord(name: "Game", rootBookmark: Data(), kind: .privateTask,
                                   internalRelativePath: "Personal/Game/Files")
        try await workspaces.saveWorkspace(game)
        let runs = SQLiteRunStore(database: database)
        let run = RunRecord(id: UUID(), conversationID: task.id, state: "running", goal: "test", startedAt: Date())
        try await runs.saveRun(run)
        #expect(try await !workspaces.assignConversationIfIdle(workspaceID: game.id,
            conversationID: task.id, expectedWorkspaceID: previous.id))
        #expect(try await workspaces.workspaceID(conversationID: task.id) == previous.id)
        try await runs.saveRun(RunRecord(id: run.id, conversationID: task.id, state: "completed",
                                         goal: run.goal, startedAt: run.startedAt, endedAt: Date()))
        #expect(try await !workspaces.assignConversationIfIdle(workspaceID: game.id,
            conversationID: task.id, expectedWorkspaceID: UUID()))
        #expect(try await workspaces.assignConversationIfIdle(workspaceID: game.id,
            conversationID: task.id, expectedWorkspaceID: previous.id))
        #expect(try await workspaces.workspaceID(conversationID: task.id) == game.id)
        #expect(try await workspaces.workspace(id: previous.id) != nil)
    }

    @Test("Deleting an assistant never schedules its app-owned game workspace for cleanup")
    func appOwnedGameWorkspaceSurvivesAssistantDeletion() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let tasks = SQLiteConversationStore(database: database)
        let workspaces = SQLiteWorkspaceStore(database: database)
        let task = ConversationRecord(id: UUID(), title: "Game", createdAt: Date(), updatedAt: Date())
        try await tasks.saveConversation(task)
        let game = WorkspaceRecord(name: "Game", rootBookmark: Data(), kind: .privateTask,
                                   internalRelativePath: "Personal/Game/Files")
        try await workspaces.saveWorkspace(game)
        try await workspaces.assignConversation(workspaceID: game.id, conversationID: task.id)
        #expect(!game.isDisposableTaskWorkspace)
        try await tasks.deleteConversation(id: task.id)
        #expect(try await workspaces.pendingLocalCleanup().isEmpty)
        #expect(try await workspaces.workspace(id: game.id) != nil)
    }

    @Test("Private cleanup survives task and workspace deletion; projects stay untouched")
    func durableIntent() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let tasks = SQLiteConversationStore(database: database)
        let workspaces = SQLiteWorkspaceStore(database: database)
        let task = ConversationRecord(id: UUID(), title: "Private", createdAt: Date(), updatedAt: Date())
        try await tasks.saveConversation(task)
        let owned = try await workspaces.ensureWorkspace(conversationID: task.id, title: task.title)
        let project = WorkspaceRecord(name: "Shared", rootBookmark: Data([1]))
        try await workspaces.saveWorkspace(project)
        let sharedTask = ConversationRecord(id: UUID(), title: "Shared", createdAt: Date(), updatedAt: Date())
        try await tasks.saveConversation(sharedTask)
        try await workspaces.assignConversation(workspaceID: project.id, conversationID: sharedTask.id)
        try await tasks.deleteConversation(id: sharedTask.id)
        #expect(try await workspaces.pendingLocalCleanup().isEmpty)
        #expect(try await workspaces.workspace(id: project.id) != nil)
        try await tasks.deleteConversation(id: task.id)
        #expect(try await workspaces.pendingLocalCleanup().map(\.workspaceID) == [owned.id])
        try await workspaces.deleteWorkspace(id: owned.id)
        #expect(try await workspaces.pendingLocalCleanup().map(\.relativePath) == [owned.internalRelativePath])
        try await workspaces.finishLocalCleanup(workspaceID: owned.id)
        #expect(try await workspaces.pendingLocalCleanup().isEmpty)
    }

    @Test("Rolled back task deletion cannot enqueue filesystem cleanup")
    func rollback() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let tasks = SQLiteConversationStore(database: database)
        let workspaces = SQLiteWorkspaceStore(database: database)
        let task = ConversationRecord(id: UUID(), title: "Keep", createdAt: Date(), updatedAt: Date())
        try await tasks.saveConversation(task)
        _ = try await workspaces.ensureWorkspace(conversationID: task.id, title: task.title)
        await #expect(throws: (any Error).self) {
            try await database.writer { db in
                try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [task.id.uuidString])
                throw FloeError.validationFailed("fixture transaction rollback")
            }
        }
        #expect(try await tasks.conversation(id: task.id) != nil)
        #expect(try await workspaces.pendingLocalCleanup().isEmpty)
    }
}
