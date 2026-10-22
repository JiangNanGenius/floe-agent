// FloePersistence — conversation-local chat preference snapshots (schema v51).
//
// SPDX-License-Identifier: MPL-2.0
//
// One durable JSON snapshot per CONVERSATION. The snapshot's fields are
// optional, so an absent row decodes to the product default (`.fast` for
// chat reasoning) without backfill. This is presentation state for the chat
// surface only; the model catalog (`ModelProfile`) and task policy rows are
// untouched, and temporary sessions never reach SQLite at all — their
// conversation rows do not exist, and the foreign key makes a durable draft
// write impossible by construction.

import Foundation
import GRDB
import FloeCore

/// Durable chat-preference read/write surface for one conversation.
public protocol ChatPreferenceStore: Sendable {
    /// The stored snapshot, or nil when the conversation never saved one.
    func preferences(conversationID: UUID) async throws -> ChatConversationPreferences?
    /// Atomic whole-snapshot upsert (last full value wins; fields are not
    /// merged across writers).
    func savePreferences(
        _ preferences: ChatConversationPreferences,
        conversationID: UUID
    ) async throws
}

public extension ChatPreferenceStore {
    /// Absent record + missing key both resolve to the product default.
    func effectivePreferences(conversationID: UUID) async throws -> ChatConversationPreferences {
        (try? await preferences(conversationID: conversationID)) ?? ChatConversationPreferences()
    }
}

public actor SQLiteChatPreferenceStore: ChatPreferenceStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func preferences(conversationID: UUID) async throws -> ChatConversationPreferences? {
        try await database.reader { db in
            guard let text: String = try String.fetchOne(
                db,
                sql: "SELECT preferences_json FROM conversation_chat_preferences WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]
            ) else { return nil }
            // An unreadable snapshot behaves like an absent one: the caller
            // falls back to the product default instead of failing the run.
            guard let data = text.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(ChatConversationPreferences.self, from: data)
            else { return nil }
            return snapshot
        }
    }

    public func savePreferences(
        _ preferences: ChatConversationPreferences,
        conversationID: UUID
    ) async throws {
        let data = try JSONEncoder().encode(preferences)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FloeError.invalidConfiguration("Chat preferences are not encodable")
        }
        try await database.writer { db in
            // The foreign key is the authority boundary: writing for a
            // missing (or temporary-only) conversation fails closed instead
            // of creating a fake durable row.
            try db.execute(
                sql: """
                    INSERT INTO conversation_chat_preferences (conversation_id, preferences_json, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(conversation_id) DO UPDATE SET
                        preferences_json = excluded.preferences_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    conversationID.uuidString,
                    text,
                    PersistenceCodec.encode(Date())
                ]
            )
        }
    }
}
