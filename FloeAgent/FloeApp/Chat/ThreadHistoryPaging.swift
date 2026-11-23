// FloeApp — Shared transcript history pager (iPad thread paging authority).
//
// SPDX-License-Identifier: MPL-2.0
//
// Platform-neutral orchestration over the shared `ThreadHistoryPaging` state
// extractor. The iPad `ThreadDetailViewModel` is the implementation authority
// for the thread's hydration, merge and cursor/search behavior; this pager
// lifts that exact flow — same keyset windows, same coverage rules, same
// "earlier activity" affordance — so the native Mac host (and any other
// surface) drives an IDENTICAL transcript without a second paging dialect.
//
// The pager owns no store and no persistence: hosts pass the SAME
// `ConversationStore` / `RunStore` protocols the iPad reads through, plus a
// `Fence` that answers whether the caller's conversation selection (or load
// generation) is still current. A stale fence discards the in-flight page —
// never merging rows, never arming retry state, never surfacing an error.
//
// This file intentionally imports only Foundation/Combine/FloeModels/
// FloePersistence so it compiles unchanged on iPad and macOS.

import Foundation
import Combine
import FloeModels
import FloePersistence

/// Fetches and merges transcript pages with iPad-identical windows and rules.
@MainActor
public final class ThreadHistoryPager: ObservableObject {

    /// Thrown when the host's fence reports the conversation selection changed
    /// (or the task was cancelled) while a page was in flight. Hosts must
    /// treat this as silent cancellation, never as a visible failure.
    public struct StaleFenceError: Error, Sendable {
        public init() {}
    }

    /// Host-supplied currency check: reads the caller's selection token /
    /// load generation (and `Task.isCancelled`) so a late page can never
    /// merge into a different conversation's transcript. `@MainActor` because
    /// it reads the host's main-actor selection state; every caller here is
    /// already on the main actor.
    public struct Fence: Sendable {
        public var isCurrent: @MainActor @Sendable () -> Bool

        public init(isCurrent: @escaping @MainActor @Sendable () -> Bool) {
            self.isCurrent = isCurrent
        }

        @MainActor
        public func guardCurrent() throws {
            if !isCurrent() { throw StaleFenceError() }
        }
    }

    // MARK: - Windows of record (identical to the iPad thread)

    /// Latest message window loaded when a conversation opens.
    public static let latestMessageWindow = 20
    /// "Load earlier" message page.
    public static let earlierMessageWindow = 30
    /// Run header directory loaded when a conversation opens.
    public static let runHeaderWindow = 30
    /// Run event page: 50 displayed rows plus one boundary row that only
    /// answers "is there even earlier history?" and never renders.
    public static let eventWindow = 51

    // MARK: - Published transcript state (mirrors the shared extractor)

    /// The merged messages of the bound conversation, chronological.
    @Published public private(set) var messages: [PersistedMessage] = []
    /// The conversation's run headers, newest first.
    @Published public private(set) var runs: [RunRecord] = []
    /// Persisted events per run, each in sequence order.
    @Published public private(set) var eventsByRun: [UUID: [RunEventRecord]] = [:]
    /// Runs with earlier events available but none loaded yet (paged
    /// "earlier activity" rows).
    @Published public private(set) var earlierEventRunIDs: Set<UUID> = []
    /// Runs whose earlier-events fetch is currently in flight.
    @Published public private(set) var loadingEventRunIDs: Set<UUID> = []
    /// Runs whose latest earlier-events page fetch genuinely failed. The row
    /// stays actionable through an explicit retry; auto-paging pauses until
    /// the retry or a conversation reload succeeds (never a silent storm).
    @Published public private(set) var failedEarlierEventRunIDs: Set<UUID> = []
    /// True while an earlier message page may exist beyond the merged window.
    @Published public private(set) var hasEarlierMessages = false

    private var state = ThreadHistoryPaging()
    private var eventLoadTokens: [UUID: UUID] = [:]

    public init() {}

    /// The newest uncovered message boundary; nil once history is contiguous.
    public var earlierMessageCursor: ConversationMessageCursor? {
        state.earlierMessageCursor
    }

    /// Binds the pager to a conversation: drops every merged row and cursor so
    /// no other task's projection can leak across the switch.
    public func reset() {
        state.reset()
        eventLoadTokens.removeAll()
        loadingEventRunIDs.removeAll()
        failedEarlierEventRunIDs.removeAll()
        publishAll()
    }

    // MARK: - Messages

    /// Loads the latest message window (`latestMessageWindow` rows). Also the
    /// refresh entry point after a live turn: merging the newest page keeps
    /// every previously loaded older row and only appends genuinely new rows.
    public func loadLatestMessages(
        conversationID: UUID,
        store: any ConversationStore,
        fence: Fence
    ) async throws {
        let page = try await store.messagePage(
            conversationID: conversationID, before: nil, limit: Self.latestMessageWindow
        )
        try fence.guardCurrent()
        state.mergeMessagePage(page)
        publishMessages()
    }

    /// Refreshes one durable same-ID edit without disturbing page coverage.
    public func refreshPresentedMessage(id: UUID, conversationID: UUID, store: any ConversationStore,
                                        fence: Fence) async throws {
        let message = try await store.message(id: id, conversationID: conversationID)
        try fence.guardCurrent()
        if let message { presentCommittedMessage(message) }
    }

    /// Presents a committed row without moving the earlier-message cursor.
    public func presentCommittedMessage(_ message: PersistedMessage) {
        if state.replaceMessages([message]) { publishMessages() }
    }

    /// Pages one earlier message window, exactly like the iPad "Load earlier".
    /// No-op when coverage already reaches the beginning of history.
    public func loadEarlierMessages(
        conversationID: UUID,
        store: any ConversationStore,
        fence: Fence
    ) async throws {
        guard let cursor = state.earlierMessageCursor else { return }
        let page = try await store.messagePage(
            conversationID: conversationID, before: cursor, limit: Self.earlierMessageWindow
        )
        try fence.guardCurrent()
        state.mergeMessagePage(page, before: cursor)
        publishMessages()
    }

    /// Merges a bounded window around one search hit (loaded through the
    /// host's store lookup). Never claims page coverage: the "Load earlier"
    /// cursor stays authoritative for the gaps this window skips.
    public func mergeSearchWindow(_ rows: [PersistedMessage]) {
        state.mergeSearchWindow(rows)
        publishMessages()
    }

    // MARK: - Run headers + earlier-activity hydration

    /// Loads the run header directory (`runHeaderWindow` newest runs).
    public func loadRunHeaders(
        conversationID: UUID,
        store: any RunStore,
        fence: Fence
    ) async throws {
        let headers = try await store.recentRuns(
            conversationID: conversationID, limit: Self.runHeaderWindow
        )
        try fence.guardCurrent()
        state.mergeRunHeaders(headers)
        publishRuns()
    }

    /// Resolves headers for run ids referenced by loaded messages but missing
    /// from the directory (the store half of the iPad
    /// `hydrateVisibleRunDetails`). Unknown/foreign ids are ignored, never
    /// fabricated.
    public func ensureRunHeaders(
        _ runIDs: Set<UUID>,
        conversationID: UUID,
        store: any RunStore,
        fence: Fence
    ) async throws {
        let known = Set(state.runs.map(\.id))
        var fetched: [RunRecord] = []
        for id in runIDs.subtracting(known) {
            if let header = try await store.run(id: id), header.conversationID == conversationID {
                fetched.append(header)
            }
            try Task.checkCancellation()
        }
        try fence.guardCurrent()
        state.mergeRunHeaders(fetched)
        publishRuns()
    }

    /// Marks every listed run that has no event page yet as having earlier
    /// activity, so its paged row appears exactly like the iPad thread.
    public func markRunsNeedingEventHydration(_ runIDs: Set<UUID>) {
        state.markRunsWithEarlierEvents(runIDs)
        if earlierEventRunIDs != state.earlierEventRunIDs {
            earlierEventRunIDs = state.earlierEventRunIDs
        }
    }

    // MARK: - Run events

    /// Loads the latest event page (`eventWindow` rows) for one run — the
    /// eager load for the active/latest run and the refresh after a live
    /// turn. New tail rows append; loaded rows and cursors are preserved.
    public func loadLatestEvents(
        runID: UUID,
        store: any RunStore,
        fence: Fence
    ) async throws {
        let page = try await store.recentEvents(runID: runID, limit: Self.eventWindow)
        try fence.guardCurrent()
        state.mergeEventPage(page, runID: runID)
        publishEvents()
    }

    /// Pages one earlier event window for exactly one run, fenced against a
    /// reload and against the boundary row's own visibility task: a normal
    /// scroll-away cancellation or a newer conversation load never merges
    /// stale rows, surfaces an error, or arms the retry state. Only a current
    /// genuine fetch failure keeps the row actionable (host maps the error).
    public func loadEarlierEvents(
        runID: UUID,
        store: any RunStore,
        fence: Fence
    ) async throws {
        guard loadingEventRunIDs.insert(runID).inserted else { return }
        let token = UUID()
        eventLoadTokens[runID] = token
        defer {
            if eventLoadTokens[runID] == token {
                eventLoadTokens.removeValue(forKey: runID)
                loadingEventRunIDs.remove(runID)
            }
        }
        do {
            let before = state.earlierEventCursor(runID: runID)
            let page: [RunEventRecord]
            if let before {
                page = try await store.earlierEvents(
                    runID: runID, beforeSequence: before, limit: Self.eventWindow
                )
            } else {
                page = try await store.recentEvents(runID: runID, limit: Self.eventWindow)
            }
            try fence.guardCurrent()
            state.mergeEventPage(page, runID: runID, before: before)
            failedEarlierEventRunIDs.remove(runID)
            publishEvents()
        } catch is StaleFenceError {
            throw StaleFenceError()
        } catch {
            if fence.isCurrent() {
                failedEarlierEventRunIDs.insert(runID)
            }
            throw error
        }
    }

    // MARK: - Publishing

    private func publishMessages() {
        if messages != state.messages { messages = state.messages }
        if hasEarlierMessages != state.hasEarlierMessages { hasEarlierMessages = state.hasEarlierMessages }
        if earlierEventRunIDs != state.earlierEventRunIDs { earlierEventRunIDs = state.earlierEventRunIDs }
    }

    private func publishRuns() {
        if runs != state.runs { runs = state.runs }
    }

    private func publishEvents() {
        if eventsByRun != state.eventsByRun { eventsByRun = state.eventsByRun }
        if earlierEventRunIDs != state.earlierEventRunIDs { earlierEventRunIDs = state.earlierEventRunIDs }
    }

    private func publishAll() {
        publishMessages()
        publishRuns()
        publishEvents()
    }
}
