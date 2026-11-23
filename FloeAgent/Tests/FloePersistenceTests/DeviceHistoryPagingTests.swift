// SPDX-License-Identifier: MPL-2.0

import FloeModels
import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("Device history paging")
struct DeviceHistoryPagingTests {
    @Test("A history above the old limit resumes after reopening and sends only new commits")
    func resumesAcrossStoreRestart() async throws {
        let sourceDB = try DatabaseManager.inMemory()
        try await sourceDB.migrate()
        let source = SQLiteConversationStore(database: sourceDB)
        let time = Date(timeIntervalSince1970: 200)
        let id = UUID()
        try await source.saveConversation(.init(id: id, title: "Shared history", createdAt: time, updatedAt: time))
        let ids = (0...DeviceConversationHistory.maximumMessages).map { _ in UUID() }
        try await sourceDB.writer { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO messages(id, conversation_id, role, content, created_at)
                VALUES (?, ?, 'user', 'text', ?)
                """)
            for messageID in ids {
                try statement.execute(arguments: [messageID.uuidString, id.uuidString, PersistenceCodec.encode(time)])
            }
        }
        await #expect(throws: DeviceConversationHistoryError.sizeLimit) {
            try await source.deviceHistory(conversationID: id)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("receive.sqlite")
        let peer = "test-peer"
        let first = try await source.deviceHistoryPage(conversationID: id, after: nil, through: nil)
        let firstBatch = try DeviceConversationHistory(data: first.archive)
        do {
            let database = try DatabaseManager(path: dbURL)
            try await database.migrate()
            let destination = SQLiteConversationStore(database: database)
            let receipt = try await destination.importDeviceHistory(firstBatch, sourcePeerID: peer, nextCursor: first.nextCursor)
            #expect(first.hasMore && receipt.addedMessages == firstBatch.messages.count)
            try await database.close()
        }
        let database = try DatabaseManager(path: dbURL)
        try await database.migrate()
        let destination = SQLiteConversationStore(database: database)
        var cursor = try await destination.deviceHistoryCursor(from: peer, conversationID: id)
        #expect(cursor == first.nextCursor)
        let otherPeer = try await destination.deviceHistoryCursor(from: "other-peer", conversationID: id)
        #expect(otherPeer == nil)
        var total = firstBatch.messages.count
        var more = first.hasMore
        while more {
            let page = try await source.deviceHistoryPage(conversationID: id, after: cursor, through: first.through)
            let history = try DeviceConversationHistory(data: page.archive)
            let receipt = try await destination.importDeviceHistory(history, sourcePeerID: peer, nextCursor: page.nextCursor)
            total += receipt.addedMessages
            cursor = page.nextCursor
            more = page.hasMore
        }
        #expect(total == ids.count)
        #expect(try await destination.messages(conversationID: id).map(\.id) == ids)

        let late = PersistedMessage(id: UUID(), conversationID: id, role: "assistant", content: "Late arrival",
                                    createdAt: time.addingTimeInterval(-30))
        try await source.appendMessage(late)
        let incremental = try await source.deviceHistoryPage(conversationID: id, after: cursor, through: nil)
        let appended = try DeviceConversationHistory(data: incremental.archive)
        #expect(!incremental.hasMore && appended.messages.map(\.id) == [late.id])
        let receipt = try await destination.importDeviceHistory(appended, sourcePeerID: peer, nextCursor: incremental.nextCursor)
        #expect(receipt.addedMessages == 1)
        let duplicate = try await destination.importDeviceHistory(appended, sourcePeerID: peer, nextCursor: incremental.nextCursor)
        #expect(duplicate.addedMessages == 0)
        let caughtUp = try await source.deviceHistoryPage(conversationID: id, after: incremental.nextCursor, through: nil)
        #expect(caughtUp.nextCursor == incremental.nextCursor && !caughtUp.hasMore)
        #expect(try DeviceConversationHistory(data: caughtUp.archive).messages.isEmpty)
        try await destination.deleteConversation(id: id)
        #expect(try await destination.deviceHistoryCursor(from: peer, conversationID: id) == nil)
        try await database.close()
    }

    @Test("An edited source anchor is expired and a divergent message rolls back the whole page and cursor")
    func conflictPreservesPriorCommit() async throws {
        let time = Date(timeIntervalSince1970: 200)
        let id = UUID()
        let original = PersistedMessage(id: UUID(), conversationID: id, role: "user", content: "Original", createdAt: time)
        let sourceDB = try DatabaseManager.inMemory()
        try await sourceDB.migrate()
        let source = SQLiteConversationStore(database: sourceDB)
        try await source.saveConversation(.init(id: id, title: "Shared history", createdAt: time, updatedAt: time))
        try await source.appendMessage(original)
        let first = try await source.deviceHistoryPage(conversationID: id, after: nil, through: nil)
        let sinkDB = try DatabaseManager.inMemory()
        try await sinkDB.migrate()
        let sink = SQLiteConversationStore(database: sinkDB)
        _ = try await sink.importDeviceHistory(DeviceConversationHistory(data: first.archive),
                                               sourcePeerID: "peer", nextCursor: first.nextCursor)
        try await source.appendMessage(.init(id: UUID(), conversationID: id, role: "assistant", content: "Later", createdAt: time))
        try await source.appendMessage(.init(id: original.id, conversationID: id, role: "user", content: "Edited", createdAt: time))
        await #expect(throws: DeviceConversationHistoryError.cursorExpired) {
            try await source.deviceHistoryPage(conversationID: id, after: first.nextCursor, through: nil)
        }
        let reset = try await source.deviceHistoryPage(conversationID: id, after: nil, through: nil)
        let replay = try DeviceConversationHistory(data: reset.archive)
        #expect(replay.messages.last?.id == original.id)
        await #expect(throws: DeviceConversationHistoryError.messageConflict(original.id)) {
            try await sink.importDeviceHistory(replay, sourcePeerID: "peer", nextCursor: reset.nextCursor)
        }
        #expect(try await sink.deviceHistoryCursor(from: "peer", conversationID: id) == first.nextCursor)
        #expect(try await sink.messages(conversationID: id).map(\.content) == ["Original"])
    }
}
