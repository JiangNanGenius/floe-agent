// FloeMac — native in-conversation message search for the unified Mac host.
//
// SPDX-License-Identifier: MPL-2.0
//
// Brings the iPad in-chat find flow to the Mac workbench: the same shared
// `ConversationSearchQuery` normalizer (whitespace-AND, quoted phrase,
// case/diacritic/width insensitive) and the same shared
// `ConversationSearchText` visible-text projection, so a hit always names the
// exact string the timeline renders — never raw Markdown syntax or a hidden
// link target. Snippets come from the shared `snippet(in:query:)` helper.
//
// `MacConversationSearchModel` owns only presentation/selection state. The
// Host supplies three capabilities and stays the single source of truth:
//  - `loadedWindow`: a FRESH snapshot of the currently loaded messages plus
//    the durable paging boundary (`earlierCursor` / `hasEarlier`). It is
//    invoked at the start of every search, so a result can never come from a
//    stale window or another conversation's projection.
//  - `historyPage`: the bounded, paginated async closure
//    `(ConversationMessageCursor?) async throws -> ConversationMessagePage`
//    backed by `FloeMacSelfRuntime.conversationMessagePage`. Older pages are
//    pulled only until the query is answered, the aggregate page/text/hit
//    bounds are reached, or history is exhausted.
//  - `reveal`: hit -> visible, owned by the Host/view (scroll + highlight +
//    any Mac-specific row mapping). It returns false when the hit cannot be
//    made visible; the model then surfaces an honest error instead of faking
//    focus.
//
// Searching walks user/assistant VISIBLE text only. Messages the Mac renders
// as chrome rather than body text (plan confirmations) and legacy hidden
// workspace context notices are excluded, mirroring the iPad document
// projection; the Host-side reveal/highlight path stays authoritative for any
// row it cannot render. Durable paging is debounced (180 ms), cancellable and
// generation-guarded: only the latest query can publish, and switching
// conversations (`bind(conversationID:)`) discards everything, so no stale
// query or other-task projection can leak across.

import Combine
import FloeAgentRuntime
import FloePersistence
import Foundation
import SwiftUI

/// One resolved in-conversation match, ordered chronologically by the model.
struct MacConversationSearchHit: Identifiable, Equatable, Sendable {
    let messageID: UUID
    let createdAt: Date
    /// Readable hit line from the shared snippet helper.
    let snippet: String

    var id: UUID { messageID }
}

/// UI-owned find state for one Mac conversation window.
@MainActor
final class MacConversationSearchModel: ObservableObject {
    /// Fresh loaded-window snapshot from the Host. Never cached by the model.
    typealias LoadedWindowProvider = @MainActor () -> (
        messages: [PersistedMessage],
        earlierCursor: ConversationMessageCursor?,
        hasEarlier: Bool
    )
    /// Bounded paginated durable-history loader (nil cursor = latest page).
    typealias HistoryPageProvider = @MainActor (ConversationMessageCursor?) async throws -> ConversationMessagePage
    /// Host-owned reveal: scroll/highlight the hit; false = not visible.
    typealias Reveal = @MainActor (MacConversationSearchHit) async -> Bool

    /// Aggregate bounds for one search. They cap total work only; every hit
    /// that is returned still went through the exact visible-text matcher.
    static let maximumPagesPerSearch = 20
    static let maximumScannedMessages = 2_000
    static let maximumHits = 200
    static let debounceMilliseconds = 180

    @Published private(set) var isActive = false
    @Published var query = "" {
        didSet { scheduleLookup() }
    }
    @Published private(set) var hits: [MacConversationSearchHit] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isSearching = false
    /// True when durable history was NOT fully scanned (bound reached or a
    /// page fetch failed) while more history may exist. Never resets the
    /// hits; it only says the count is a partial one.
    @Published private(set) var isPartial = false
    @Published private(set) var errorText: String?
    /// The message the reader is currently on. Kept after `end()` so the
    /// view stays exactly at the hit instead of jumping back to the end.
    @Published private(set) var focusedMessageID: UUID?
    @Published private(set) var conversationID: UUID?

    private let loadedWindow: LoadedWindowProvider
    private let historyPage: HistoryPageProvider
    private let reveal: Reveal
    private var lookupTask: Task<Void, Never>?
    private var searchGeneration = 0

    init(
        loadedWindow: @escaping LoadedWindowProvider,
        historyPage: @escaping HistoryPageProvider,
        reveal: @escaping Reveal
    ) {
        self.loadedWindow = loadedWindow
        self.historyPage = historyPage
        self.reveal = reveal
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var countLabel: String {
        if hits.isEmpty { return isSearching ? "…" : "0/0" }
        return "\(min(currentIndex + 1, hits.count))/\(hits.count)"
    }

    var currentHit: MacConversationSearchHit? {
        guard hits.indices.contains(currentIndex) else { return nil }
        return hits[currentIndex]
    }

    /// Enters find mode. The Host shows the bar and focuses the field.
    func begin() {
        isActive = true
        errorText = nil
    }

    /// Leaves find mode at the current hit. Query/selection state is cleared;
    /// scroll position is deliberately untouched (focusedMessageID persists).
    func end() {
        lookupTask?.cancel()
        searchGeneration += 1
        isActive = false
        isSearching = false
        query = ""
        hits = []
        currentIndex = 0
        isPartial = false
        errorText = nil
    }

    /// Rebinds the model to the conversation actually on screen. Any identity
    /// change discards the query, results and focus: no other task's
    /// projection and no stale query can survive a conversation switch.
    func bind(conversationID newConversationID: UUID?) {
        guard newConversationID != conversationID else { return }
        lookupTask?.cancel()
        searchGeneration += 1
        conversationID = newConversationID
        isActive = false
        isSearching = false
        query = ""
        hits = []
        currentIndex = 0
        isPartial = false
        errorText = nil
        focusedMessageID = nil
    }

    /// Programmatic refresh (e.g. the Host's menu action). Bypasses debounce.
    func retry() async {
        lookupTask?.cancel()
        await runSearch()
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

    // MARK: - Lookup

    /// Cancellable, debounced re-query owned by the model. Each edit cancels
    /// the pending lookup and invalidates any in-flight publish.
    private func scheduleLookup() {
        lookupTask?.cancel()
        searchGeneration += 1
        guard isActive else { return }
        lookupTask = Task { [weak self] in
            guard let self else { return }
            if self.hasQuery {
                try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            }
            guard !Task.isCancelled else { return }
            await self.runSearch()
        }
    }

    private func runSearch() async {
        guard isActive else { return }
        searchGeneration += 1
        let generation = searchGeneration
        let parsed = ConversationSearchQuery(raw: query)
        guard !parsed.isEmpty else {
            isSearching = false
            hits = []
            currentIndex = 0
            isPartial = false
            errorText = nil
            return
        }
        isSearching = true
        errorText = nil

        // Fresh snapshot per search: the Host decides what is loaded and
        // where the durable boundary is, so results track the real window.
        let window = loadedWindow()
        var byID: [UUID: MacConversationSearchHit] = [:]
        var scanned = 0
        var scanLimited = false
        func scan(_ messages: [PersistedMessage]) {
            for message in messages.reversed() {
                guard scanned < Self.maximumScannedMessages, byID.count < Self.maximumHits else {
                    scanLimited = true
                    return
                }
                scanned += 1
                guard byID[message.id] == nil,
                      let visibleText = Self.visibleText(for: message),
                      parsed.matches(visibleText) else { continue }
                byID[message.id] = MacConversationSearchHit(
                    messageID: message.id,
                    createdAt: message.createdAt,
                    snippet: ConversationSearchText.snippet(in: visibleText, query: parsed)
                )
            }
        }
        scan(window.messages)

        var cursor = window.earlierCursor
        var hasEarlier = window.hasEarlier
        var pagesFetched = 0
        var fetchFailed = false
        while hasEarlier, let nextCursor = cursor,
              pagesFetched < Self.maximumPagesPerSearch,
              scanned < Self.maximumScannedMessages,
              byID.count < Self.maximumHits,
              !Task.isCancelled {
            pagesFetched += 1
            do {
                let page = try await historyPage(nextCursor)
                // Only the newest query may consume pages or publish.
                guard generation == searchGeneration, !Task.isCancelled else { return }
                scan(page.messages)
                cursor = page.earlierCursor
                hasEarlier = page.hasEarlier
            } catch {
                fetchFailed = true
                break
            }
        }
        guard generation == searchGeneration,
              parsed.raw == query,
              !Task.isCancelled else { return }

        isSearching = false
        // Honest partial indicator: more durable history may exist than the
        // bounds allowed us to scan (or a page fetch failed mid-scan).
        isPartial = scanLimited || fetchFailed || hasEarlier
        hits = byID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.messageID.uuidString < rhs.messageID.uuidString
        }
        guard !hits.isEmpty else {
            currentIndex = 0
            focusedMessageID = nil
            return
        }
        // Start at the newest match: the reader is usually at the live end of
        // the task, and typing must not yank the view to the oldest hit.
        // Previous/next then walk chronologically.
        currentIndex = hits.count - 1
        await focusCurrent()
    }

    /// The exact visible string the Mac timeline renders for this message, or
    /// nil when the row is not searchable body text: only user/assistant
    /// bodies count, plan confirmations render as a status label and legacy
    /// workspace context notices are hidden chrome.
    static func visibleText(for message: PersistedMessage) -> String? {
        guard message.role == "user" || message.role == "assistant" else { return nil }
        guard PlanConfirmationSnapshot.from(message: message) == nil,
              !ConversationHistoryAssembler.isLegacyWorkspaceContextNotice(message) else {
            return nil
        }
        let visible = ConversationSearchText.visibleText(
            role: message.role, content: message.content)
        return visible.isEmpty ? nil : visible
    }

    private func focusCurrent() async {
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
            errorText = MacConversationSearchCopy.olderMatchUnavailable
        }
    }
}

/// A single pinned row: query field, match position, previous/next and Done.
/// Return jumps to the next match; Esc (`.onExitCommand` / cancel shortcut)
/// leaves find mode at the current hit. The composer draft and the
/// conversation are never touched here.
struct MacConversationSearchBar: View {
    @ObservedObject var model: MacConversationSearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(MacConversationSearchCopy.placeholder, text: $model.query)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                .onSubmit { Task { await model.next() } }
                .accessibilityIdentifier("mac.conversation.search.field")
            if model.isSearching {
                ProgressView().controlSize(.small)
            } else if let errorText = model.errorText {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(errorText)
                    .accessibilityIdentifier("mac.conversation.search.error")
            } else {
                HStack(spacing: 4) {
                    Text(model.countLabel)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(model.currentHit?.snippet ?? "")
                        .accessibilityIdentifier("mac.conversation.search.count")
                    if model.isPartial {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                            .help(MacConversationSearchCopy.partialNotice)
                            .accessibilityLabel(Text(MacConversationSearchCopy.partialNotice))
                            .accessibilityIdentifier("mac.conversation.search.partial")
                    }
                }
            }
            Button {
                Task { await model.previous() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(model.isSearching || model.hits.count < 2)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .accessibilityLabel(MacConversationSearchCopy.previous)
            .accessibilityIdentifier("mac.conversation.search.previous")
            Button {
                Task { await model.next() }
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(model.isSearching || model.hits.count < 2)
            .keyboardShortcut("g", modifiers: .command)
            .accessibilityLabel(MacConversationSearchCopy.next)
            .accessibilityIdentifier("mac.conversation.search.next")
            Button(MacConversationSearchCopy.done) {
                model.end()
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("mac.conversation.search.done")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onExitCommand { model.end() }
        // Focus without stealing focus permanently: Done/Esc dismisses find.
        .task { fieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.conversation.search.bar")
    }
}

// MARK: - Bilingual text

/// EN / zh-CN inline strings for this surface. The Mac host follows the
/// system language for its catalog, so this mirrors the same resolution used
/// by `MacProviderText` without adding new catalog keys in this package.
enum MacConversationSearchCopy {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    static var placeholder: String {
        t("在对话中查找", "Find in chat")
    }
    static var done: String {
        t("完成", "Done")
    }
    static var previous: String {
        t("上一个", "Previous match")
    }
    static var next: String {
        t("下一个", "Next match")
    }
    static var partialNotice: String {
        t("仅搜索了部分较早历史", "Only part of the older history was searched")
    }
    static var olderMatchUnavailable: String {
        t("这条较早的消息暂时无法载入", "This older message could not be loaded")
    }
}
