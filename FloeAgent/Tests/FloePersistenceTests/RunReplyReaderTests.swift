import Foundation
import Testing
import FloeModels
import FloePersistence

@Suite("FloePersistence.RunReplyReader")
struct RunReplyReaderTests {
    @Test("The reply belongs to this exact run and conversation")
    func exactRunAndOwner() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let owner = UUID(), other = UUID(), runID = UUID(), laterRun = UUID()
        for id in [owner, other] {
            try await store.saveConversation(.init(id: id, title: "Synthetic reply owner",
                createdAt: Date(), updatedAt: Date()))
        }
        let runs = SQLiteRunStore(database: database)
        for id in [runID, laterRun] {
            try await runs.saveRun(.init(id: id, conversationID: owner, state: "completed",
                goal: "Synthetic reply", startedAt: Date(), endedAt: Date()))
        }
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "Exact original reply", createdAt: Date(), runID: runID))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "Later run's reply", createdAt: Date(), runID: laterRun))
        try await store.appendMessage(.init(id: UUID(), conversationID: other, role: "assistant",
            content: "Foreign owner's row", createdAt: Date(), runID: runID))
        let reader = SQLiteRunReplyReader(database: database)
        #expect(try await reader.latestAssistantText(runID: runID, conversationID: owner) == "Exact original reply")
        #expect(try await reader.latestAssistantText(runID: laterRun, conversationID: owner) == "Later run's reply")
        #expect(try await reader.latestAssistantText(runID: laterRun, conversationID: other) == nil)
    }

    @Test("Clock rollback cannot replace the final answer with a pre-tool step")
    func clockRollbackAndRoleFiltering() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let owner = UUID(), runID = UUID()
        try await store.saveConversation(.init(id: owner, title: "Synthetic clock correction",
            createdAt: Date(), updatedAt: Date()))
        try await SQLiteRunStore(database: database).saveRun(.init(id: runID,
            conversationID: owner, state: "completed", goal: "Synthetic clock correction",
            startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 3_000)))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "Earlier tool step", createdAt: Date(timeIntervalSince1970: 2_000), runID: runID))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "Full final reply\n第二行 👩🏽‍🚀", createdAt: Date(timeIntervalSince1970: 1_000), runID: runID))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "tool",
            content: "Not an assistant result", createdAt: Date(), runID: runID))
        #expect(try await SQLiteRunReplyReader(database: database)
            .latestAssistantText(runID: runID, conversationID: owner) == "Full final reply\n第二行 👩🏽‍🚀")
    }
}
