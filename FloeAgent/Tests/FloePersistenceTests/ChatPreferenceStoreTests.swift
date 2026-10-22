// FloePersistenceTests — conversation chat preference store (schema v51).
//
// Pins the durable boundary of the fast chat lane: one whole-snapshot row per
// CONVERSATION, absent row/missing key/corrupt snapshot all resolving to the
// product default without failing the reader, the foreign key making a write
// for a missing (draft/temporary) conversation fail closed, cascade deletion
// with the conversation, and exact durability across re-open.

import Foundation
import Testing
import FloeCore
@testable import FloePersistence

@Suite("FloePersistence.ChatPreferenceStore")
struct ChatPreferenceStoreTests {

    private func makeDatabase() async throws -> (DatabaseManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-chat-prefs-\(UUID().uuidString).sqlite")
        let manager = try DatabaseManager(path: url)
        try await manager.migrate()
        return (manager, url)
    }

    private func makeConversation(_ manager: DatabaseManager) async throws -> UUID {
        let id = UUID()
        let store = SQLiteConversationStore(database: manager)
        try await store.saveConversation(ConversationRecord(
            id: id, title: "chat", createdAt: Date(), updatedAt: Date()))
        return id
    }

    @Test("migration v51 is applied and the table exists")
    func migrationCreatesTable() async throws {
        let (manager, _) = try await makeDatabase()
        #expect(try await manager.userVersion() == DatabaseManager.currentSchemaVersion)
        let applied = try await manager.appliedMigrations()
        #expect(applied.contains("v51_chat_preferences"))
        let columns = try await manager.reader { db in
            try String.fetchAll(db, sql: "PRAGMA table_info(conversation_chat_preferences)").map { $0 }
                .compactMap { row in row.split(separator: "|").dropFirst(1).first.map(String.init) }
        }
        #expect(Set(columns).isSuperset(of: ["conversation_id", "preferences_json", "updated_at"]))
    }

    @Test("an absent row answers no snapshot and the effective view defaults to fast")
    func absentRowDefaultsToFast() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        #expect(try await store.preferences(conversationID: conversationID) == nil)
        #expect(try await store.effectivePreferences(conversationID: conversationID)
                    .effectiveChatReasoning == .fast)
    }

    @Test("whole-snapshot save/read round-trips and last full write wins")
    func saveReadRoundTrip() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        try await store.savePreferences(
            ChatConversationPreferences(chatReasoning: .high), conversationID: conversationID)
        let saved = try #require(await store.preferences(conversationID: conversationID))
        #expect(saved.effectiveChatReasoning == .high)
        // Overwrite replaces the whole snapshot (fields are not merged).
        try await store.savePreferences(
            ChatConversationPreferences(chatReasoning: .maximum), conversationID: conversationID)
        let updated = try #require(await store.preferences(conversationID: conversationID))
        #expect(updated.chatReasoning == .maximum)
        // Clearing back to the product default stores an explicit null field,
        // not a deleted row.
        try await store.savePreferences(
            ChatConversationPreferences(), conversationID: conversationID)
        let cleared = try #require(await store.preferences(conversationID: conversationID))
        #expect(cleared.chatReasoning == nil)
        #expect(cleared.effectiveChatReasoning == .fast)
    }

    @Test("a write for a missing conversation fails closed on the foreign key")
    func unknownConversationFailsClosed() async throws {
        let (manager, _) = try await makeDatabase()
        let store = SQLiteChatPreferenceStore(database: manager)
        // Draft/voice-only identities have no conversations row: no fake
        // durable row may ever be created.
        var didThrow = false
        do {
            try await store.savePreferences(
                ChatConversationPreferences(chatReasoning: .high),
                conversationID: UUID())
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test("an unreadable snapshot behaves like an absent one")
    func corruptSnapshotDegradesToDefault() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_chat_preferences (conversation_id, preferences_json, updated_at)
                    VALUES (?, 'not-json', datetime('now'))
                    """,
                arguments: [conversationID.uuidString])
        }
        let store = SQLiteChatPreferenceStore(database: manager)
        #expect(try await store.preferences(conversationID: conversationID) == nil)
        // The effective view still answers (a corrupt row must never fail a
        // run) and a corrective save replaces it.
        #expect(try await store.effectivePreferences(conversationID: conversationID)
                    .effectiveChatReasoning == .fast)
        try await store.savePreferences(
            ChatConversationPreferences(chatReasoning: .low), conversationID: conversationID)
        let repaired = try #require(await store.preferences(conversationID: conversationID))
        #expect(repaired.chatReasoning == .low)
    }

    @Test("the preference row cascades with its conversation")
    func cascadeDeletionWithConversation() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        try await store.savePreferences(
            ChatConversationPreferences(chatReasoning: .maximum), conversationID: conversationID)
        try await SQLiteConversationStore(database: manager).deleteConversation(id: conversationID)
        #expect(try await store.preferences(conversationID: conversationID) == nil)
    }

    @Test("preferences survive a re-opened database exactly")
    func durableAcrossReopen() async throws {
        let (manager, url) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        try await SQLiteChatPreferenceStore(database: manager).savePreferences(
            ChatConversationPreferences(chatReasoning: .medium), conversationID: conversationID)
        let reopened = try DatabaseManager(path: url)
        try await reopened.migrate()
        let loaded = try #require(await SQLiteChatPreferenceStore(database: reopened)
            .preferences(conversationID: conversationID))
        #expect(loaded.effectiveChatReasoning == .medium)
    }
}
