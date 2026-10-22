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

/// The durable read outcome for one conversation. `absent` (no row) and
/// `unreadable` (a row whose JSON cannot be decoded) MUST stay distinct:
/// absence is legacy data with no remembered choice, while an unreadable row
/// may hold an explicit Chat choice and a reader that confused the two would
/// silently grant Agent authority.
public enum ChatPreferencesReadState: Sendable, Equatable {
    case absent
    case snapshot(ChatConversationPreferences)
    case unreadable
}

/// Durable chat-preference read/write surface for one conversation.
public protocol ChatPreferenceStore: Sendable {
    /// The stored snapshot, or nil when the conversation never saved one.
    /// An undecodable snapshot also answers nil here (the per-run reasoning
    /// path treats it as absent); mode readers use `preferencesState` where
    /// the distinction decides authority.
    func preferences(conversationID: UUID) async throws -> ChatConversationPreferences?
    /// The honest three-way read used by authority decisions.
    func preferencesState(conversationID: UUID) async throws -> ChatPreferencesReadState
    /// Atomic whole-snapshot upsert (last full value wins; fields are not
    /// merged across writers). Kept for tests and deliberate full resets;
    /// production writers that change ONE field must use the field updates
    /// below so they can never erase a concurrently chosen sibling field.
    func savePreferences(
        _ preferences: ChatConversationPreferences,
        conversationID: UUID
    ) async throws
    /// Atomically sets (or clears, with nil) the chat reasoning field inside a
    /// single write transaction: the existing snapshot's other fields are
    /// preserved verbatim. The foreign key still fails closed for a
    /// conversation that has no durable row.
    func updateChatReasoning(
        _ preference: ChatReasoningPreference?,
        conversationID: UUID
    ) async throws
    /// Atomically sets (or clears, with nil) the conversation's preferred
    /// execution mode raw value, preserving every sibling field. Validation
    /// belongs to the App that owns the mode enum; this store persists the
    /// text verbatim and never invents a mode.
    func updatePreferredExecutionMode(
        _ rawMode: String?,
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
        guard case .snapshot(let snapshot) = try await preferencesState(
            conversationID: conversationID) else { return nil }
        return snapshot
    }

    public func preferencesState(conversationID: UUID) async throws -> ChatPreferencesReadState {
        try await database.reader { db in
            guard let text: String = try String.fetchOne(
                db,
                sql: "SELECT preferences_json FROM conversation_chat_preferences WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]
            ) else { return .absent }
            // A row exists but its JSON does not decode: never pretend the
            // choice was never made. The reasoning path degrades to `.fast`
            // through `preferences()`, while mode readers fail closed.
            guard let snapshot = Self.decode(snapshotJSON: text) else { return .unreadable }
            return .snapshot(snapshot)
        }
    }

    public func savePreferences(
        _ preferences: ChatConversationPreferences,
        conversationID: UUID
    ) async throws {
        let text = try Self.encode(preferences)
        try await database.writer { db in
            // The foreign key is the authority boundary: writing for a
            // missing (or temporary-only) conversation fails closed instead
            // of creating a fake durable row.
            try Self.upsert(snapshotJSON: text, conversationID: conversationID, in: db)
        }
    }

    public func updateChatReasoning(
        _ preference: ChatReasoningPreference?,
        conversationID: UUID
    ) async throws {
        try await merge(conversationID: conversationID) { snapshot in
            snapshot.chatReasoning = preference
        }
    }

    public func updatePreferredExecutionMode(
        _ rawMode: String?,
        conversationID: UUID
    ) async throws {
        try await merge(conversationID: conversationID) { snapshot in
            snapshot.preferredExecutionMode = rawMode
        }
    }

    /// Read-merge-write inside ONE serialized writer transaction: a
    /// reasoning change can never erase a concurrently saved execution mode
    /// (or vice versa), and two writers racing on different fields both
    /// survive. A row that does not exist yet is created; a missing
    /// conversation still trips the foreign key.
    private func merge(
        conversationID: UUID,
        _ mutate: @Sendable (inout ChatConversationPreferences) -> Void
    ) async throws {
        try await database.writer { db in
            let existing: String? = try String.fetchOne(
                db,
                sql: "SELECT preferences_json FROM conversation_chat_preferences WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]
            )
            // A corrupt row may have held Chat. Repairing another field must
            // retain that least-privilege mode; only an explicit mode update
            // can replace it. A genuinely absent row remains legacy data.
            var snapshot = existing.flatMap(Self.decode(snapshotJSON:))
                ?? ChatConversationPreferences(preferredExecutionMode: existing == nil ? nil : "chat")
            mutate(&snapshot)
            let text = try Self.encode(snapshot)
            try Self.upsert(snapshotJSON: text, conversationID: conversationID, in: db)
        }
    }

    private static func decode(snapshotJSON text: String) -> ChatConversationPreferences? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChatConversationPreferences.self, from: data)
    }

    private static func encode(_ preferences: ChatConversationPreferences) throws -> String {
        let data = try JSONEncoder().encode(preferences)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FloeError.invalidConfiguration("Chat preferences are not encodable")
        }
        return text
    }

    private static func upsert(
        snapshotJSON text: String,
        conversationID: UUID,
        in db: Database
    ) throws {
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
