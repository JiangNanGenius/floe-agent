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
import GRDB
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
            try Row.fetchAll(db, sql: "PRAGMA table_info(conversation_chat_preferences)")
                .compactMap { (row: Row) -> String? in row["name"] as String? }
        }
        #expect(Set(columns).isSuperset(of: ["conversation_id", "preferences_json", "updated_at"]))
    }

    @Test("an already-applied prerelease migration repairs its version without losing preferences")
    func repairsPrereleaseVersionWithoutReplayingMigration() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        let saved = ChatConversationPreferences(chatReasoning: .maximum, preferredExecutionMode: "chat")
        try await store.savePreferences(saved, conversationID: conversationID)
        let appliedBefore = try await manager.appliedMigrations()
        try await manager.writer { db in try db.execute(sql: "PRAGMA user_version = 49") }
        try await manager.migrate()
        #expect(try await manager.userVersion() == DatabaseManager.currentSchemaVersion)
        #expect(try await manager.appliedMigrations() == appliedBefore)
        #expect(try await store.preferences(conversationID: conversationID) == saved)
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

    @Test("the honest read state separates absent, unreadable and a snapshot")
    func readStateDistinguishesAbsentAndUnreadable() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        #expect(try await store.preferencesState(conversationID: conversationID) == .absent)
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_chat_preferences (conversation_id, preferences_json, updated_at)
                    VALUES (?, 'not-json', datetime('now'))
                    """,
                arguments: [conversationID.uuidString])
        }
        // An unreadable row may hold an explicit Chat choice: authority
        // decisions must not confuse it with a legacy absent row.
        #expect(try await store.preferencesState(conversationID: conversationID) == .unreadable)
        try await store.savePreferences(
            ChatConversationPreferences(chatReasoning: .low, preferredExecutionMode: "chat"),
            conversationID: conversationID)
        #expect(try await store.preferencesState(conversationID: conversationID) == .snapshot(
            ChatConversationPreferences(chatReasoning: .low, preferredExecutionMode: "chat")))
    }

    // MARK: - Preferred execution mode (schema v51 field, no migration)

    @Test("a preferred mode round-trips beside reasoning, including through reopen")
    func preferredExecutionModeRoundTrips() async throws {
        let (manager, url) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        try await store.savePreferences(
            ChatConversationPreferences(chatReasoning: .high, preferredExecutionMode: "chat"),
            conversationID: conversationID)
        let saved = try #require(await store.preferences(conversationID: conversationID))
        #expect(saved.preferredExecutionMode == "chat")
        #expect(saved.effectiveChatReasoning == .high)
        let reopened = try DatabaseManager(path: url)
        try await reopened.migrate()
        let loaded = try #require(await SQLiteChatPreferenceStore(database: reopened)
            .preferences(conversationID: conversationID))
        #expect(loaded.preferredExecutionMode == "chat")
        #expect(loaded.effectiveChatReasoning == .high)
    }

    @Test("a legacy row without the mode field decodes with no remembered choice")
    func legacySnapshotHasNoPreferredMode() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        // A snapshot written by the previous app version: the new optional
        // field is absent from the JSON, not an explicit null decision.
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_chat_preferences (conversation_id, preferences_json, updated_at)
                    VALUES (?, '{"chatReasoning":"medium"}', datetime('now'))
                    """,
                arguments: [conversationID.uuidString])
        }
        let loaded = try #require(await SQLiteChatPreferenceStore(database: manager)
            .preferences(conversationID: conversationID))
        #expect(loaded.preferredExecutionMode == nil)
        #expect(loaded.effectiveChatReasoning == .medium)
    }

    @Test("field updates preserve the sibling field in both directions")
    func fieldUpdatesMergeSiblings() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        try await store.savePreferences(
            ChatConversationPreferences(chatReasoning: .medium, preferredExecutionMode: "plan"),
            conversationID: conversationID)
        // Reasoning update must not erase the mode.
        try await store.updateChatReasoning(.maximum, conversationID: conversationID)
        var snapshot = try #require(await store.preferences(conversationID: conversationID))
        #expect(snapshot.chatReasoning == .maximum)
        #expect(snapshot.preferredExecutionMode == "plan")
        // Mode update must not erase reasoning.
        try await store.updatePreferredExecutionMode("agent", conversationID: conversationID)
        snapshot = try #require(await store.preferences(conversationID: conversationID))
        #expect(snapshot.chatReasoning == .maximum)
        #expect(snapshot.preferredExecutionMode == "agent")
        // Clearing one field keeps the other.
        try await store.updatePreferredExecutionMode(nil, conversationID: conversationID)
        snapshot = try #require(await store.preferences(conversationID: conversationID))
        #expect(snapshot.preferredExecutionMode == nil)
        #expect(snapshot.chatReasoning == .maximum)
    }

    @Test("a field update creates the snapshot row and still fails closed on a missing conversation")
    func fieldUpdateCreatesRowAndFailsClosed() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        try await store.updatePreferredExecutionMode("chat", conversationID: conversationID)
        let saved = try #require(await store.preferences(conversationID: conversationID))
        #expect(saved.preferredExecutionMode == "chat")
        #expect(saved.chatReasoning == nil)
        var didThrow = false
        do {
            try await store.updatePreferredExecutionMode("chat", conversationID: UUID())
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        // The FK failure created no orphan row.
        let rows = try await manager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_chat_preferences") ?? 0
        }
        #expect(rows == 1)
    }

    @Test("an unrecognized stored mode is persisted verbatim; the App validates")
    func unrecognizedModeIsStoredVerbatim() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        // The store is a dumb durable boundary: Core/App readers decide how
        // to fail closed, so a future mode value is never silently rewritten
        // into Agent authority by persistence.
        try await store.updatePreferredExecutionMode("summarize", conversationID: conversationID)
        let saved = try #require(await store.preferences(conversationID: conversationID))
        #expect(saved.preferredExecutionMode == "summarize")
    }

    @Test("a field update into a corrupt snapshot repairs it without failing")
    func fieldUpdateRepairsCorruptSnapshot() async throws {
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
        try await store.updateChatReasoning(.high, conversationID: conversationID)
        let afterReasoning = try #require(await store.preferences(conversationID: conversationID))
        #expect(afterReasoning.preferredExecutionMode == "chat")
        #expect(afterReasoning.chatReasoning == .high)
        try await store.updatePreferredExecutionMode("chat", conversationID: conversationID)
        let repaired = try #require(await store.preferences(conversationID: conversationID))
        #expect(repaired.preferredExecutionMode == "chat")
        #expect(repaired.effectiveChatReasoning == .high)
    }

    @Test("concurrent field updates keep both fields")
    func concurrentFieldUpdatesKeepBothFields() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        try await store.savePreferences(
            ChatConversationPreferences(chatReasoning: .low, preferredExecutionMode: "chat"),
            conversationID: conversationID)
        // The production regression: a reasoning save and a mode save racing
        // must merge, not replace each other with a stale whole snapshot.
        async let reasoning: Void = store.updateChatReasoning(.high, conversationID: conversationID)
        async let mode: Void = store.updatePreferredExecutionMode("goal", conversationID: conversationID)
        _ = try await (reasoning, mode)
        let snapshot = try #require(await store.preferences(conversationID: conversationID))
        #expect(snapshot.chatReasoning == .high)
        #expect(snapshot.preferredExecutionMode == "goal")
    }

    @Test("a whole-snapshot save still replaces every field")
    func wholeSnapshotSaveReplacesFields() async throws {
        let (manager, _) = try await makeDatabase()
        let conversationID = try await makeConversation(manager)
        let store = SQLiteChatPreferenceStore(database: manager)
        try await store.savePreferences(
            ChatConversationPreferences(chatReasoning: .high, preferredExecutionMode: "chat"),
            conversationID: conversationID)
        // Deliberate full reset (tests, explicit clear): generic whole-value
        // semantics stay available to callers that really mean it.
        try await store.savePreferences(
            ChatConversationPreferences(chatReasoning: .low), conversationID: conversationID)
        let reset = try #require(await store.preferences(conversationID: conversationID))
        #expect(reset.preferredExecutionMode == nil)
        #expect(reset.chatReasoning == .low)
    }
}
