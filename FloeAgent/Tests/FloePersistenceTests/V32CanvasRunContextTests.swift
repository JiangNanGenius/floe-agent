import Foundation
import Testing
import GRDB
import FloeModels
@testable import FloePersistence

@Suite("V32 canvas run contexts")
struct V32CanvasRunContextTests {
    @Test("Context round trips and is deleted with its run")
    func roundTripAndCascade() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationID = UUID(), runID = UUID(), canvasID = UUID()
        let documentID = UUID(), selected = [UUID(), UUID()]
        try await SQLiteConversationStore(database: database).saveConversation(
            ConversationRecord(
                id: conversationID,
                title: "Canvas",
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        let runStore = SQLiteRunStore(database: database)
        try await runStore.saveRun(RunRecord(
            id: runID,
            conversationID: conversationID,
            state: "preparing",
            goal: "draw",
            startedAt: Date()
        ))
        let store = CanvasRunContextStore(database: database)
        try await store.save(CanvasRunContext(
            runID: runID,
            conversationID: conversationID,
            canvasID: canvasID,
            documentID: documentID,
            selectedNodeIDs: selected,
            projectRevision: 42
        ))

        let loaded = try #require(try await store.context(runID: runID))
        #expect(loaded.canvasID == canvasID)
        #expect(loaded.documentID == documentID)
        #expect(loaded.selectedNodeIDs == selected)
        #expect(loaded.projectRevision == 42)

        try await database.writer { db in
            try db.execute(sql: "DELETE FROM runs WHERE id = ?", arguments: [runID.uuidString])
        }
        #expect(try await store.context(runID: runID) == nil)
        #expect(try await database.userVersion() == 32)
    }
}
