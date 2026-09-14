import Foundation
import Testing
@testable import FloeCore
@testable import FloeAgentRuntime
@testable import FloeModels
@testable import FloePersistence

@Suite("Conversation full-text search")
struct ConversationSearchTests {
    @Test("Library search includes CJK message substrings, literal wildcard characters and old conversations")
    func libraryContentsSearch() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let id = UUID()
        try await conversations.saveConversation(.init(id: id, title: "Unrelated title", createdAt: Date(), updatedAt: Date()))
        for index in 0..<60 {
            try await conversations.appendMessage(.init(id: UUID(), conversationID: id, role: "user", content: "第\(index) 条包含边际成本和100%_混合 English", createdAt: Date()))
        }
        #expect(try await store.matchingConversationSnippets("边际成本").keys.sorted { $0.uuidString < $1.uuidString } == [id])
        #expect(try await store.matchingConversationSnippets("100%_")[id]?.contains("100%_") == true)
        #expect(try await store.matchingConversationSnippets("missing").isEmpty)
        #expect(try await store.matchingConversationSnippets(" ").isEmpty)
    }

    @Test("Search ranks FTS hits without bm25 auxiliary-function context error")
    func searchRanksHits() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationStore = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let conversationID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_200_000)
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Searchable", createdAt: base, updatedAt: base
        ))
        let frequent = UUID()
        try await conversationStore.appendMessage(PersistedMessage(
            id: frequent, conversationID: conversationID, role: "user",
            content: "alpha beta beta beta", createdAt: base
        ))
        try await conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "assistant",
            content: "beta appears once", createdAt: base.addingTimeInterval(1)
        ))
        try await conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "assistant",
            content: "unrelated content", createdAt: base.addingTimeInterval(2)
        ))

        // This query previously threw "SQLite error 1: unable to use function
        // bm25 in the requested context" because bm25()/snippet() were
        // evaluated in the ORDER BY of a GROUP BY aggregate.
        let hits = try await store.search(ConversationSearchRequest(query: "beta"))
        #expect(hits.count == 2)
        #expect(hits.first?.messageID == frequent)
        #expect(hits.allSatisfy { $0.conversationID == conversationID })
        #expect(hits.first?.snippet.contains("[beta]") == true)
        #expect(hits.first?.conversationTitle == "Searchable")
    }

    @Test("Search honours workspace ownership filter and date range")
    func searchFilters() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationStore = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let base = Date(timeIntervalSince1970: 1_700_300_000)

        let ownedConversation = UUID()
        let otherConversation = UUID()
        for (id, title) in [(ownedConversation, "Owned"), (otherConversation, "Other")] {
            try await conversationStore.saveConversation(ConversationRecord(
                id: id, title: title, createdAt: base, updatedAt: base
            ))
            try await conversationStore.appendMessage(PersistedMessage(
                id: UUID(), conversationID: id, role: "user",
                content: "shared needle", createdAt: base
            ))
        }
        let workspaceID = UUID()
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO workspaces (id, name, root_bookmark, created_at, updated_at)
                VALUES (?, 'ws', X'00', ?, ?)
                """, arguments: [workspaceID.uuidString, Self.iso(base), Self.iso(base)])
            try db.execute(sql: """
                INSERT INTO conversation_workspace_ownership (conversation_id, workspace_id, assigned_at)
                VALUES (?, ?, ?)
                """, arguments: [ownedConversation.uuidString, workspaceID.uuidString, Self.iso(base)])
        }

        let filtered = try await store.search(ConversationSearchRequest(query: "needle", workspaceID: workspaceID))
        #expect(filtered.count == 1)
        #expect(filtered.first?.conversationID == ownedConversation)
        #expect(filtered.first?.workspaceID == workspaceID)

        let unfiltered = try await store.search(ConversationSearchRequest(query: "needle"))
        #expect(unfiltered.count == 2)

        let futureOnly = try await store.search(ConversationSearchRequest(
            query: "needle", startDate: base.addingTimeInterval(60)
        ))
        #expect(futureOnly.isEmpty)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
