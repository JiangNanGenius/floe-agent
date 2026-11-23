// SPDX-License-Identifier: MPL-2.0

import FloeModels
import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("Device history paging")
struct DeviceHistoryPagingTests {
    @Test("A historical v1 archive imports without the attachment list and part kind")
    func legacyArchiveWithoutNewKeysImports() async throws {
        let payload = Data(#"""
        {
          "version": 1, "id": "10000000-0000-0000-0000-000000000001",
          "title": "Legacy fixture", "createdAt": 0, "updatedAt": 1,
          "messages": [{
            "id": "20000000-0000-0000-0000-000000000001",
            "role": "user", "content": "Original message", "createdAt": 1,
            "parts": [{
              "id": "30000000-0000-0000-0000-000000000001",
              "index": 0, "text": "Original message", "createdAt": 1
            }]
          }]
        }
        """#.utf8)
        let history = try DeviceConversationHistory(data: payload)
        let message = try #require(history.messages.first)
        #expect(history.attachments.isEmpty)
        #expect(message.parts.first?.kind == .text)

        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        #expect(try await store.importDeviceHistory(history).addedMessages == 1)
        #expect(try await store.parts(messageID: message.id).count == 1)
        #expect(try await store.importDeviceHistory(history).addedMessages == 0)
    }

    @Test("Typed history fills links only after restore and keeps v1 replay idempotent")
    func attachmentAndToolHistoryRestoresWithoutDanglingParts() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let store = SQLiteConversationStore(database: db)
        let owner = UUID(), message = UUID(), toolMessage = UUID(), attachment = UUID()
        let time = Date(timeIntervalSince1970: 200.1234567)
        let digest = String(repeating: "a", count: 64)
        let record = DeviceConversationHistory.Attachment(id: attachment, kind: "document",
            displayName: "report.txt", uti: "public.plain-text", byteCount: 14, sha256: digest, createdAt: time)
        let content = DeviceConversationHistory.Message(id: message, role: "user", content: "See report", createdAt: time,
            parts: [
                .init(id: UUID(), index: 0, kind: .text, text: "See report", createdAt: time),
                .init(id: UUID(), index: 1, kind: .attachment, attachmentID: attachment, createdAt: time),
            ])
        let answer = DeviceConversationHistory.Message(id: toolMessage, role: "assistant", content: "Read", createdAt: time,
            parts: [.init(id: UUID(), index: 0, kind: .tool, text: "Read the report", toolName: "workspace.readFile",
                          toolStatus: "ok", createdAt: time)])
        let archive = DeviceConversationHistory(id: owner, title: "Shared", createdAt: time, updatedAt: time,
            messages: [content, answer], attachments: [record], version: 2)
        _ = try await store.importDeviceHistory(try DeviceConversationHistory(data: archive.encoded()))
        #expect(try await store.parts(messageID: message).map(\.kind) == [.text])
        #expect(try await store.parts(messageID: toolMessage).first?.metadata["deviceHistory.tool"] == "workspace.readFile")
        #expect(try await store.attachment(id: attachment)?.storage == AttachmentRef.Storage.none)

        let foreignOwner = UUID()
        let forgedMessage = DeviceConversationHistory.Message(id: UUID(), role: "user", content: "Different owner",
            createdAt: time, parts: [.init(id: UUID(), index: 0, kind: .attachment, attachmentID: attachment, createdAt: time)])
        let foreign = DeviceConversationHistory(id: foreignOwner, title: "Another task", createdAt: time, updatedAt: time,
            messages: [forgedMessage], attachments: [record], version: 2)
        await #expect(throws: DeviceConversationHistoryError.messageConflict(forgedMessage.id)) {
            try await store.importDeviceHistory(foreign, sourcePeerID: "foreign", nextCursor: "candidate")
        }
        #expect(try await store.deviceHistoryCursor(from: "foreign", conversationID: foreignOwner) == nil)
        #expect(try await store.attachment(id: attachment)?.conversationID == owner)

        #expect(try await store.restoreDeviceHistoryAttachment(conversationID: owner, attachmentID: attachment,
            messageID: message, digest: digest, relativePath: "verified.txt"))
        #expect(try await store.parts(messageID: message).compactMap(\.attachmentID) == [attachment])
        let legacy = try await store.deviceHistory(conversationID: owner)
        #expect(legacy.version == 1 && legacy.messages.flatMap(\.parts).map(\.kind) == [.text])
        #expect(try await store.importDeviceHistory(legacy).addedMessages == 0)
        #expect(try await store.importDeviceHistory(archive).addedMessages == 0)
        #expect(try await store.parts(messageID: message).count == 2)
    }

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
