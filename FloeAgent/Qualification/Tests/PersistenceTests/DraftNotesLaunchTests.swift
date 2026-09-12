// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import GRDB
import FloePersistence

@Suite("Draft Notes launch identity")
struct DraftNotesLaunchTests {
    @Test func reservedIdentityCreatesOnceAndCannotReplaceExistingTask() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteRunLaunchStore(database: database)
        let id = UUID()
        let prepared = try await store.prepare(RunLaunchRequest(newConversationID: id, conversationTitle: "Selected Notes", goal: "Explain selected material"))
        #expect(prepared.conversation.id == id)
        await #expect(throws: (any Error).self) {
            try await store.prepare(RunLaunchRequest(newConversationID: id, conversationTitle: "Replacement", goal: "Must not replace"))
        }
        let counts = try await database.reader { db in
            [try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs") ?? -1]
        }
        #expect(counts == [1, 1])
        let title = try await database.reader { db in try String.fetchOne(db, sql: "SELECT title FROM conversations WHERE id=?", arguments: [id.uuidString]) }
        #expect(title == "Selected Notes")
    }
    @Test func failedPreflightKeepsDraftIdentityReusableWithoutBlankTask() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteRunLaunchStore(database: database)
        let id = UUID()
        await #expect(throws: (any Error).self) {
            try await store.prepare(RunLaunchRequest(newConversationID: id, goal: " "))
        }
        await #expect(throws: (any Error).self) {
            try await store.prepare(RunLaunchRequest(conversationID: UUID(), newConversationID: id, goal: "Invalid identity pair"))
        }
        let count = try await database.reader { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") }
        #expect(count == 0)
        let prepared = try await store.prepare(RunLaunchRequest(newConversationID: id, goal: "Retry"))
        #expect(prepared.conversation.id == id)
    }
}
