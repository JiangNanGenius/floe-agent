// SPDX-License-Identifier: MPL-2.0
// Task-owned synthetic databases only; the runtime does not install this feed.
import Foundation
import FloeDesktopSync
import FloeModels
import FloePersistence
import GRDB
import Testing
@testable import FloeMacSelfCore

private enum FeedFixtureError: Error { case rollback }

@Suite("Mac canonical feed storage")
struct CanonicalFeedStorageTests {
    @Test("Installation follows the caller's outer transaction and rejects partial state")
    func installationRollback() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        do {
            try await database.writer { db in
                _ = try FloeMacCanonicalFeedStorage.install(in: db)
                throw FeedFixtureError.rollback
            }
            Issue.record("outer transaction unexpectedly committed")
        } catch is FeedFixtureError {}
        try await database.writer { db in
            #expect(throws: CanonicalMessageFeed.FeedError.unavailable) {
                _ = try FloeMacCanonicalFeedStorage.position(in: db)
            }
            let installed = try FloeMacCanonicalFeedStorage.install(in: db)
            #expect(installed.sequence == 0)
            #expect(try FloeMacCanonicalFeedStorage.position(in: db) == installed)
            #expect(throws: CanonicalMessageFeed.FeedError.alreadyInstalled) {
                _ = try FloeMacCanonicalFeedStorage.install(in: db)
            }
        }
        try await database.writer { db in
            try db.execute(sql: "DROP TRIGGER floe_msgfeed_messages_insert_v1")
            #expect(throws: CanonicalMessageFeed.FeedError.unavailable) {
                _ = try FloeMacCanonicalFeedStorage.position(in: db)
            }
            #expect(throws: CanonicalMessageFeed.FeedError.alreadyInstalled) {
                _ = try FloeMacCanonicalFeedStorage.install(in: db)
            }
        }
        try await database.close()
    }

    @Test("Actual conversation store and a second database connection share a durable feed")
    func actualStoreReopenAndRotation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floe-mac-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fixture.sqlite")
        let first = try DatabaseManager(path: path)
        try await first.migrate()
        let conversationID = UUID(), messageID = UUID(), partID = UUID(), now = Date()
        let firstStore = SQLiteConversationStore(database: first)
        try await firstStore.saveConversationWithCanonicalWorkspace(
            ConversationRecord(id: conversationID, title: "synthetic", createdAt: now, updatedAt: now))
        let initial = try await first.writer { try FloeMacCanonicalFeedStorage.install(in: $0) }
        let bootstrap = try await first.writer { db in
            let connection = try #require(db.sqliteConnection)
            return try CanonicalMessageFeed.beginBootstrap(on: connection, conversationID: conversationID)
        }
        #expect(bootstrap.start == initial)

        // Open a separate pool after installation; its actual conversation
        // writer must fire the persistent source-database triggers too.
        let second = try DatabaseManager(path: path)
        let secondStore = SQLiteConversationStore(database: second)
        let part = MessagePart(id: partID, messageID: messageID, partIndex: 0, kind: .text, text: "hello")
        try await secondStore.appendMessage(PersistedMessage(id: messageID, conversationID: conversationID,
            role: "user", content: "hello", createdAt: now, parts: [part]))
        let written = try await first.writer { db in try FloeMacCanonicalFeedStorage.position(in: db) }
        #expect(written.generation == initial.generation && written.sequence > initial.sequence)
        let changes = try await first.writer { db in
            let connection = try #require(db.sqliteConnection)
            return try CanonicalMessageFeed.changes(on: connection, conversationID: conversationID, after: initial, limit: 100)
        }
        #expect(changes.changes.contains { $0.messageID == messageID && $0.message?.parts.first?.id == partID })

        // Failed work must not advance either the real source rows or feed.
        do {
            try await second.writer { db in
                try db.execute(sql: "UPDATE messages SET content='not committed' WHERE id=?", arguments: [messageID.uuidString])
                throw FeedFixtureError.rollback
            }
            Issue.record("failed writer unexpectedly committed")
        } catch is FeedFixtureError {}
        #expect(try await first.writer { try FloeMacCanonicalFeedStorage.position(in: $0) } == written)
        #expect(try await firstStore.message(id: messageID, conversationID: conversationID)?.content == "hello")

        try await secondStore.deleteConversation(id: conversationID)
        let deleted = try await first.writer { db in
            let connection = try #require(db.sqliteConnection)
            return try CanonicalMessageFeed.changes(on: connection, conversationID: conversationID, after: written, limit: 100)
        }
        #expect(deleted.changes.contains { $0.messageID == messageID && $0.message == nil })
        let beforeRotation = try await first.writer { try FloeMacCanonicalFeedStorage.position(in: $0) }
        let rotated = try await first.writer { db in
            let connection = try #require(db.sqliteConnection)
            return try CanonicalMessageFeed.rotateHistory(on: connection)
        }
        #expect(rotated.generation != beforeRotation.generation && rotated.sequence == beforeRotation.sequence)
        try await second.writer { db in
            let connection = try #require(db.sqliteConnection)
            #expect(throws: CanonicalMessageFeed.FeedError.wrongGeneration) {
                _ = try CanonicalMessageFeed.changes(on: connection, conversationID: conversationID, after: beforeRotation, limit: 10)
            }
        }
        try await second.close()
        try await first.close()
        let reopened = try DatabaseManager(path: path)
        #expect(try await reopened.writer { try FloeMacCanonicalFeedStorage.position(in: $0) } == rotated)
        try await reopened.close()
    }
}
