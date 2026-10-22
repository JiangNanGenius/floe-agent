// FloeApp — conversation-local chat preference drafts and labels facade.
//
// SPDX-License-Identifier: MPL-2.0
//
// The composer's chat reasoning chip binds through
// `ConversationCenter.chatReasoningPreference(for:)` /
// `setChatReasoningPreference(_:for:)`. Ordinary durable conversations are
// backed by the schema-51 `conversation_chat_preferences` row (the foreign
// key makes a durable write for a missing conversation impossible). This
// file supplies the two remaining pieces:
//
//   * `ChatReasoningDraftStore` — the process-local RAM drafts for owner
//     identities that are NOT durable yet (a Home/Notes launch slot whose
//     pre-generated conversation id only becomes a real row at the atomic
//     launch, and temporary sessions, which are RAM-only by contract). A
//     draft value transfers to the durable store exactly once, at the first
//     chat-round freeze of that conversation, and is dropped when its
//     temporary session is destroyed — it is never written to SQLite on the
//     temporary path.
//   * `ChatModePreferences` — pure display helpers for chat-surface chips.
//     These return concrete token strings (never localization keys); the
//     catalogs and the composer copy stay owned by the app lane.

import Foundation
import FloeCore

/// RAM-only chat reasoning drafts keyed by composer owner identity.
/// Mirrors `ComposerDraftStore` lifetime semantics but never touches disk:
/// the values here become durable only through the center's atomic
/// first-chat-round transfer, and only for a conversation whose row exists.
@MainActor
final class ChatReasoningDraftStore {
    static let shared = ChatReasoningDraftStore()

    private var drafts: [UUID: ChatReasoningPreference] = [:]

    private init() {}

    /// The draft value for an owner identity, if the user picked one before
    /// the conversation became durable.
    func draft(for ownerID: UUID) -> ChatReasoningPreference? {
        drafts[ownerID]
    }

    func setDraft(_ preference: ChatReasoningPreference, for ownerID: UUID) {
        drafts[ownerID] = preference
    }

    /// Removes and returns the draft. Used by the atomic launch transfer so
    /// a draft value can never be re-transferred into a second conversation
    /// or survive its own promoted round as a stale shadow.
    func takeDraft(for ownerID: UUID) -> ChatReasoningPreference? {
        drafts.removeValue(forKey: ownerID)
    }

    /// Drops drafts for destroyed temporary sessions and deleted
    /// conversations. The durable rows follow their conversations through
    /// the schema-51 foreign key cascade; RAM entries have no cascade and
    /// must be dropped explicitly at the same boundaries.
    func removeDrafts(for ownerIDs: some Collection<UUID>) {
        for ownerID in ownerIDs { drafts[ownerID] = nil }
    }

    func removeAllDrafts() {
        drafts.removeAll()
    }
}

/// Pure presentation facade for the chat reasoning chip. Not a policy: the
/// runtime ceiling and reasoning resolution never consult these helpers.
enum ChatModePreferences {

    /// All five conversation-local settings are selectable on the chat
    /// surface today. This is the single gate a future surface consults when
    /// it must hide a choice (for example a compact picker); it never
    /// changes what a run resolves.
    static func canShowPreference(_ preference: ChatReasoningPreference) -> Bool {
        ChatReasoningPreference.allCases.contains(preference)
    }

    /// Concrete display tokens (never localization keys): the app catalogs
    /// own the localized copy; this table is the neutral reference for
    /// diagnostics and any future key-free surface.
    static let displayTokens: [(preference: ChatReasoningPreference, english: String, chinese: String)] = [
        (.fast, "Fast", "快速"),
        (.low, "Low", "低"),
        (.medium, "Medium", "中"),
        (.high, "High", "高"),
        (.maximum, "Maximum", "最高"),
    ]

    /// The token pair for one preference; diagnostics and plain-text
    /// surfaces use this instead of duplicating the table.
    static func displayToken(for preference: ChatReasoningPreference)
        -> (english: String, chinese: String)? {
        guard let entry = displayTokens.first(where: { $0.preference == preference }) else {
            return nil
        }
        return (entry.english, entry.chinese)
    }
}
