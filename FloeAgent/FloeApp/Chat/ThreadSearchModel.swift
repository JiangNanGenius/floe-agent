// FloeApp — in-chat find state and the global-search jump handoff.
//
// SPDX-License-Identifier: MPL-2.0
//
// The find bar searches the CURRENT task's user/assistant VISIBLE text. It
// reuses the shared `ConversationSearchQuery` normalizer (whitespace-AND,
// quoted phrase, case/diacritic insensitive) and the shared visible-text
// projection, so the offsets it highlights always belong to the same string
// the thread renders — never to raw Markdown syntax, hidden link targets or a
// different display projection.
//
// `ThreadSearchModel` owns only presentation/selection state. It asks the
// thread view model for hits and for loading a bounded history window around
// the selected hit; it never owns a store or a second conversation reader.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Combine
import SwiftUI
import FloeCore
import FloePersistence
import FloeAgentRuntime

/// One searchable message (visible text only).
struct ThreadSearchDocument: Identifiable, Equatable, Sendable {
    let messageID: UUID
    let role: String
    let createdAt: Date
    /// The exact visible string the thread shows for this message. Assistant
    /// messages use the flattened Markdown projection; user text is verbatim.
    let visibleText: String

    var id: UUID { messageID }
}

/// One resolved in-chat match. `snippet` is the readable hit line; highlight
/// ranges are computed by the thread against its currently loaded text so a
/// hit loaded later still highlights correctly.
struct ThreadSearchHit: Identifiable, Equatable, Sendable {
    let messageID: UUID
    let role: String
    let createdAt: Date
    let snippet: String

    var id: UUID { messageID }
}

/// Search result for one query, ordered chronologically (oldest first).
struct ThreadSearchResult: Equatable, Sendable {
    var hits: [ThreadSearchHit]
    /// True when durable history beyond the loaded window was also queried.
    var includesDurableHistory: Bool
}

enum ThreadSearchText {
    static func document(for message: PersistedMessage) -> ThreadSearchDocument? {
        guard message.role == "user" || message.role == "assistant" else { return nil }
        // Only body text the timeline actually renders as body text. Internal
        // notices/decision markers render as a concise sentence instead of
        // their stored template, and legacy workspace context is hidden: none
        // of that may surface as a searchable message body.
        guard ProposalDecisionPresentation.trustedNotice(for: message) == nil,
              InternalNoticeProjection.userFacingSummary(for: message) == nil,
              !ConversationHistoryAssembler.isLegacyWorkspaceContextNotice(message) else {
            return nil
        }
        return ThreadSearchDocument(
            messageID: message.id,
            role: message.role,
            createdAt: message.createdAt,
            visibleText: ConversationSearchText.visibleText(
                role: message.role, content: message.content)
        )
    }

    /// Pure in-memory matching for already loaded documents.
    static func hits(
        in documents: [ThreadSearchDocument],
        query: ConversationSearchQuery
    ) -> [ThreadSearchHit] {
        guard !query.isEmpty else { return [] }
        return documents
            .filter { query.matches($0.visibleText) }
            .map { document in
                ThreadSearchHit(
                    messageID: document.messageID,
                    role: document.role,
                    createdAt: document.createdAt,
                    snippet: ConversationSearchText.snippet(
                        in: document.visibleText, query: query)
                )
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.messageID.uuidString < rhs.messageID.uuidString
            }
    }

    /// Attributed text with every term occurrence highlighted. Ranges are
    /// character offsets into `text` itself; out-of-bounds ranges are dropped
    /// instead of shifting the highlight onto other characters.
    static func highlighted(_ text: String, ranges: [Range<Int>]) -> AttributedString {
        var attributed = AttributedString(text)
        let characterCount = attributed.characters.count
        for range in ranges {
            guard range.lowerBound >= 0,
                  range.upperBound <= characterCount,
                  range.upperBound > range.lowerBound else { continue }
            let lower = attributed.index(
                attributed.startIndex, offsetByCharacters: range.lowerBound)
            let upper = attributed.index(
                attributed.startIndex, offsetByCharacters: range.upperBound)
            attributed[lower..<upper].backgroundColor = Color.yellow.opacity(0.35)
        }
        return attributed
    }
}

/// UI-owned find state. The thread supplies the two async capabilities:
/// query → hits, and hit → load/reveal (returns false when the hit could not
/// be made visible, e.g. a deleted row).
@MainActor
final class ThreadSearchModel: ObservableObject {
    typealias Provider = @MainActor (ConversationSearchQuery) async -> ThreadSearchResult
    typealias Reveal = @MainActor (ThreadSearchHit) async -> Bool

    @Published private(set) var isActive = false
    @Published var query = ""
    @Published private(set) var hits: [ThreadSearchHit] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isSearching = false
    @Published private(set) var searchedDurableHistory = false
    @Published private(set) var errorText: String?
    /// The message the user is currently on. Kept after Done so the thread
    /// stays exactly at the hit instead of jumping back to the latest reply.
    @Published private(set) var focusedMessageID: UUID?

    private let provider: Provider
    private let reveal: Reveal
    private var searchGeneration = 0

    init(provider: @escaping Provider, reveal: @escaping Reveal) {
        self.provider = provider
        self.reveal = reveal
    }

    var isShowingResults: Bool { !hits.isEmpty }
    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var countLabel: String {
        if hits.isEmpty { return isSearching ? "…" : "0/0" }
        return "\(min(currentIndex + 1, hits.count))/\(hits.count)"
    }

    var currentHit: ThreadSearchHit? {
        guard hits.indices.contains(currentIndex) else { return nil }
        return hits[currentIndex]
    }

    func begin() {
        isActive = true
        errorText = nil
    }

    /// Leaves find mode at the current hit. The query/selection are cleared,
    /// but scroll position is deliberately untouched.
    func end() {
        searchGeneration += 1
        isActive = false
        isSearching = false
        query = ""
        hits = []
        currentIndex = 0
        searchedDurableHistory = false
        errorText = nil
    }

    func search() async {
        searchGeneration += 1
        let generation = searchGeneration
        let parsed = ConversationSearchQuery(raw: query)
        guard !parsed.isEmpty else {
            isSearching = false
            hits = []
            currentIndex = 0
            searchedDurableHistory = false
            errorText = nil
            return
        }
        isSearching = true
        errorText = nil
        let result = await provider(parsed)
        guard generation == searchGeneration,
              parsed.raw == query,
              !Task.isCancelled else { return }
        isSearching = false
        searchedDurableHistory = result.includesDurableHistory
        hits = result.hits
        guard !hits.isEmpty else {
            currentIndex = 0
            focusedMessageID = nil
            return
        }
        // Start at the newest match: the reader is usually at the live end of
        // the task, and typing must not yank the view to the first message of
        // a long history. Prev/next then walk chronologically.
        currentIndex = hits.count - 1
        await focusCurrent()
    }

    func next() async {
        guard !hits.isEmpty else { return }
        currentIndex = (currentIndex + 1) % hits.count
        await focusCurrent()
    }

    func previous() async {
        guard !hits.isEmpty else { return }
        currentIndex = (currentIndex - 1 + hits.count) % hits.count
        await focusCurrent()
    }

    func focusCurrent() async {
        guard let hit = currentHit else { return }
        let generation = searchGeneration
        let visible = await reveal(hit)
        // A newer query may have started while the hit was being revealed;
        // its selection is authoritative.
        guard generation == searchGeneration, !Task.isCancelled else { return }
        if visible {
            focusedMessageID = hit.messageID
            errorText = nil
        } else {
            errorText = ThreadSearchCopy.olderMatchUnavailable
        }
    }

    func retry() async {
        await search()
    }
}

/// Process-local handoff for "open this conversation at this exact message".
/// The global search screen cannot extend AppRouter (owned centrally), so the
/// target is stashed and announced; the thread consumes it after its own load
/// or immediately when it is already on screen. Only a real message id is
/// ever handed over — a title-only result never posts here.
@MainActor
enum ThreadSearchJumpCenter {
    static let notification = Notification.Name("floe.thread.search.jumpToMessage")
    private static var pending: [UUID: UUID] = [:]

    static func request(conversationID: UUID, messageID: UUID) {
        pending[conversationID] = messageID
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: ["conversationID": conversationID]
        )
    }

    static func consume(conversationID: UUID) -> UUID? {
        pending.removeValue(forKey: conversationID)
    }
}

enum ThreadSearchCopy {
    static func localized(_ key: String, zh: String, en: String) -> String {
        ChatBilingualCatalog.localized(key: key, en: en, zh: zh)
    }

    static var placeholder: String {
        localized("chat.search.find_in_chat", zh: "在对话中查找", en: "Find in chat")
    }
    static var done: String {
        localized("chat.search.done", zh: "完成", en: "Done")
    }
    static var previous: String {
        localized("chat.search.previous", zh: "上一个", en: "Previous match")
    }
    static var next: String {
        localized("chat.search.next", zh: "下一个", en: "Next match")
    }
    static var noMatches: String {
        localized("chat.search.no_matches", zh: "没有匹配", en: "No matches")
    }
    static var olderMatchUnavailable: String {
        localized(
            "chat.search.older_match_unavailable",
            zh: "这条较早的消息暂时无法载入",
            en: "This older message could not be loaded"
        )
    }
    static var durableNotice: String {
        localized(
            "chat.search.includes_history",
            zh: "含较早历史",
            en: "Includes older history"
        )
    }
    static var titleOnly: String {
        localized("chat.search.title_only", zh: "标题匹配", en: "Title match")
    }
}

#endif
