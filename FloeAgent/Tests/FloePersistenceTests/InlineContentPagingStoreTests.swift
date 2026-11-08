// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeModels
import FloePersistence

@Suite("Read-only inline-content paging stores")
struct InlineContentPagingStoreTests {
    @Test func sqliteKeysetsKeepTimestampTiesAndMessageOwnership() async throws {
        let db = try DatabaseManager.inMemory(); try await db.migrate()
        let conversations = SQLiteConversationStore(database: db), runs = SQLiteRunStore(database: db)
        let task = UUID(), foreign = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        for id in [task, foreign] { try await conversations.saveConversation(.init(id: id, title: "Paging contract", createdAt: date, updatedAt: date)) }
        let ids = (0..<9).map { _ in UUID() }.sorted { $0.uuidString > $1.uuidString }
        for id in ids { try await runs.saveRun(.init(id: id, conversationID: task, state: "completed", goal: "native content", startedAt: date)) }
        try await runs.saveRun(.init(id: UUID(), conversationID: foreign, state: "completed", goal: "foreign", startedAt: date))
        var cursor: ConversationRunCursor?, delivered: [UUID] = []
        repeat {
            let page = try await runs.runPage(conversationID: task, before: cursor, limit: 2)
            #expect(page.runs.count <= 2 && page.runs.allSatisfy { $0.conversationID == task })
            delivered += page.runs.map(\.id)
            guard page.hasEarlier else { break }
            let next = try #require(page.earlierCursor); #expect(next != cursor); cursor = next
        } while true
        #expect(delivered == ids && Set(delivered).count == ids.count)
        let message = PersistedMessage(id: UUID(), conversationID: task, role: "user", content: "owned", createdAt: date,
            parts: [])
        try await conversations.appendMessage(message)
        #expect(try await conversations.message(id: message.id, conversationID: task)?.id == message.id)
        #expect(try await conversations.message(id: message.id, conversationID: foreign) == nil)
    }
}
