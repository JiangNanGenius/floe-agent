// SPDX-License-Identifier: MPL-2.0

import FloeModels
import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("Android paired history storage")
struct DeviceHistoryPagingStoreTests {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Android v52 rows are backfilled by the shared migration")
    func backfillsThePreviousAndroidStore() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        // Recreate the immediately preceding Android schema in the fixture.
        // Existing Android migrations and their identifiers stay applied.
        try await database.writer { db in
            try db.execute(sql: """
                DROP TRIGGER device_history_message_insert;
                DROP TRIGGER device_history_message_update;
                DROP TRIGGER device_history_text_insert;
                DROP TRIGGER device_history_text_update;
                DROP TRIGGER device_history_text_delete;
                DROP TABLE device_history_receive_cursors;
                DROP TABLE device_history_order;
                DROP TABLE device_history_sequences;
                DELETE FROM grdb_migrations WHERE identifier = 'v68-device-history-paging';
                PRAGMA user_version = 52;
                """)
        }
        let store = SQLiteConversationStore(database: database)
        let id = UUID()
        let original = PersistedMessage(id: UUID(), conversationID: id, role: "user", content: "Existing", createdAt: time)
        try await store.saveConversation(.init(id: id, title: "Existing task", createdAt: time, updatedAt: time))
        try await store.appendMessage(original)
        #expect(try await database.userVersion() == 52)

        try await database.migrate()
        #expect(try await database.userVersion() == 68)
        let registered = await database.registeredMigrations()
        #expect(try await database.appliedMigrations().sorted() == registered.sorted())
        let page = try await store.deviceHistoryPage(conversationID: id, after: nil, through: nil)
        #expect(try DeviceConversationHistory(data: page.archive).messages.map(\.id) == [original.id])
        #expect(page.nextCursor != nil)
    }

    @Test("Long history resumes across a reopen, including an older timestamp")
    func resumesFromTheCommittedCursor() async throws {
        let senderDB = try DatabaseManager.inMemory()
        try await senderDB.migrate()
        let sender = SQLiteConversationStore(database: senderDB)
        let id = UUID()
        let time = self.time
        try await sender.saveConversation(.init(id: id, title: "Long task", createdAt: time, updatedAt: time))
        let ids = (0...DeviceConversationHistory.maximumMessages).map { _ in UUID() }
        try await senderDB.writer { db in
            let insert = try db.makeStatement(sql: """
                INSERT INTO messages(id, conversation_id, role, content, created_at)
                VALUES (?, ?, 'user', 'text', ?)
                """)
            for message in ids {
                try insert.execute(arguments: [message.uuidString, id.uuidString, PersistenceCodec.encode(time)])
            }
        }
        await #expect(throws: DeviceConversationHistoryError.sizeLimit) {
            try await sender.deviceHistory(conversationID: id)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("receive.sqlite")
        let peer = "synthetic-source"
        let first = try await sender.deviceHistoryPage(conversationID: id, after: nil, through: nil)
        #expect(first.hasMore)
        do {
            let database = try DatabaseManager(path: path)
            try await database.migrate()
            let receipt = try await importPage(first, from: peer, into: SQLiteConversationStore(database: database))
            #expect(receipt.addedMessages > 0)
            try await database.close()
        }
        let reopened = try DatabaseManager(path: path)
        try await reopened.migrate()
        let receiver = SQLiteConversationStore(database: reopened)
        var cursor = try await receiver.deviceHistoryCursor(from: peer, conversationID: id)
        #expect(cursor == first.nextCursor)
        #expect(try await receiver.deviceHistoryCursor(from: "other-source", conversationID: id) == nil)
        while true {
            let page = try await sender.deviceHistoryPage(conversationID: id, after: cursor, through: first.through)
            _ = try await importPage(page, from: peer, into: receiver)
            cursor = page.nextCursor
            if !page.hasMore { break }
        }
        #expect(try await receiver.messages(conversationID: id).map(\.id) == ids)

        let late = PersistedMessage(id: UUID(), conversationID: id, role: "assistant",
                                    content: "Late arrival", createdAt: time.addingTimeInterval(-30))
        try await sender.appendMessage(late)
        let next = try await sender.deviceHistoryPage(conversationID: id, after: cursor, through: nil)
        #expect(try DeviceConversationHistory(data: next.archive).messages.map(\.id) == [late.id])
        #expect(try await importPage(next, from: peer, into: receiver).addedMessages == 1)
        #expect(try await importPage(next, from: peer, into: receiver).addedMessages == 0)
        let caughtUp = try await sender.deviceHistoryPage(conversationID: id, after: next.nextCursor, through: nil)
        #expect(caughtUp.nextCursor == next.nextCursor && !caughtUp.hasMore)
        #expect(try DeviceConversationHistory(data: caughtUp.archive).messages.isEmpty)
        try await receiver.deleteConversation(id: id)
        #expect(try await receiver.deviceHistoryCursor(from: peer, conversationID: id) == nil)
        try await reopened.close()
    }

    @Test("The Android writer preserves the previous cursor on busy or conflict")
    func rollsBackCursorWithTheMessages() async throws {
        let senderDB = try DatabaseManager.inMemory()
        let receiverDB = try DatabaseManager.inMemory()
        try await senderDB.migrate()
        try await receiverDB.migrate()
        let sender = SQLiteConversationStore(database: senderDB)
        let receiver = SQLiteConversationStore(database: receiverDB)
        let id = UUID()
        let message = UUID()
        let peer = "synthetic-source"
        try await sender.saveConversation(.init(id: id, title: "Shared", createdAt: time, updatedAt: time))
        try await sender.appendMessage(.init(id: message, conversationID: id, role: "user", content: "Original", createdAt: time))
        let first = try await sender.deviceHistoryPage(conversationID: id, after: nil, through: nil)
        _ = try await importPage(first, from: peer, into: receiver)
        try await sender.appendMessage(.init(id: UUID(), conversationID: id, role: "assistant", content: "Later", createdAt: time))
        let next = try await sender.deviceHistoryPage(conversationID: id, after: first.nextCursor, through: nil)
        await #expect(throws: DeviceConversationHistoryError.busy) {
            try await receiver.importDeviceHistory(DeviceConversationHistory(data: next.archive),
                                                   sourcePeerID: peer, nextCursor: next.nextCursor,
                                                   hasLiveRun: { _ in true })
        }
        try await sender.appendMessage(.init(id: message, conversationID: id, role: "user", content: "Edited", createdAt: time))
        await #expect(throws: DeviceConversationHistoryError.cursorExpired) {
            try await sender.deviceHistoryPage(conversationID: id, after: first.nextCursor, through: nil)
        }
        let replay = try await sender.deviceHistoryPage(conversationID: id, after: nil, through: nil)
        await #expect(throws: DeviceConversationHistoryError.messageConflict(message)) {
            try await importPage(replay, from: peer, into: receiver)
        }
        #expect(try await receiver.deviceHistoryCursor(from: peer, conversationID: id) == first.nextCursor)
        #expect(try await receiver.messages(conversationID: id).map(\.content) == ["Original"])
    }

    private func importPage(
        _ page: DeviceConversationHistoryPage, from peer: String, into receiver: SQLiteConversationStore
    ) async throws -> DeviceConversationImport {
        try await receiver.importDeviceHistory(DeviceConversationHistory(data: page.archive),
                                               sourcePeerID: peer, nextCursor: page.nextCursor,
                                               hasLiveRun: { _ in false })
    }
}
