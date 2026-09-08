import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("Local workspace cleanup")
struct LocalWorkspaceCleanupTests {
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
