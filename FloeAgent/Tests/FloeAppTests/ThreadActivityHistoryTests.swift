// FloeAppTests — Continuous earlier-tool-history regressions.
//
// The chat thread no longer folds older run events behind a manual
// "Show earlier tool activity" button. These tests pin the replacement
// contract: a boundary row delivers one bounded slice per real visibility
// demand edge (no tap, no hard page cap, no indefinite spinner and no
// silently frozen remainder), keeps chronological order and tool pairing
// across page boundaries, deduplicates overlapping pages, ends cleanly when
// nothing earlier remains, pauses auto-paging after a genuine fetch failure
// while keeping an explicit retry, and treats a normal visibility-task
// cancellation or a superseding reload as NOT a failure and never merges
// stale rows. The hosted case proves the records arrive with zero user
// interaction.
//
// Membership: FloeAppTests explicit source list (App-hosted unit bundle),
// registered by the integration owner in FloeAgent/project.yml.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import Testing
@testable import FloeApp
import FloeModels
import FloePersistence

@Suite("FloeApp.ThreadActivityHistory", .serialized)
@MainActor
struct ThreadActivityHistoryTests {

    // MARK: - Helpers

    private func makeRun(state: String, conversationID: UUID, startedAt: Date) -> RunRecord {
        RunRecord(
            id: UUID(),
            conversationID: conversationID,
            state: state,
            goal: "goal",
            startedAt: startedAt,
            endedAt: state == "completed" ? startedAt.addingTimeInterval(5) : nil
        )
    }

    private func makeEnvironment() async throws
        -> (AppEnvironment, ConversationCenter, ConversationRecord) {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = environment.conversationCenter
        let conversation = try await center.createConversation(title: "Continuous history")
        return (environment, center, conversation)
    }

    /// Appends `count` tool events as complete request/result pairs (odd
    /// sequences request, even sequences result) to one run.
    private func appendToolPairs(to store: any RunStore, runID: UUID, count: Int) async throws {
        for sequence in 1...count {
            if sequence % 2 == 1 {
                try await store.appendEvent(runID: runID, kind: .toolRequest, payloadJSON:
                    "{\"tool\":\"workspace.readFile\",\"status\":\"pending\",\"id\":\"call-\(sequence)\",\"input\":\"{\\\"path\\\":\\\"f\(sequence).txt\\\"}\"}")
            } else {
                try await store.appendEvent(runID: runID, kind: .toolResult, payloadJSON:
                    "{\"tool\":\"workspace.readFile\",\"id\":\"call-\(sequence - 1)\",\"status\":\"ok\",\"summary\":\"done \(sequence)\"}")
            }
        }
    }

    private func appendGoalMessage(_ environment: AppEnvironment, conversationID: UUID,
                                   runID: UUID, content: String, at date: Date) async throws {
        try await environment.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: content, createdAt: date, parts: [], runID: runID))
    }

    /// Seeds one older completed run (with tool history plus its goal
    /// message) and one newest completed run, then loads the model.
    private func seededModel(olderEventCount: Int) async throws
        -> (ThreadDetailViewModel, RunRecord, AppEnvironment, ConversationCenter, ConversationRecord) {
        let (environment, center, conversation) = try await makeEnvironment()
        let older = makeRun(state: "completed", conversationID: conversation.id,
                            startedAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeRun(state: "completed", conversationID: conversation.id,
                            startedAt: Date(timeIntervalSince1970: 2_000))
        try await environment.runStore.saveRun(older)
        try await environment.runStore.saveRun(newer)
        try await appendGoalMessage(environment, conversationID: conversation.id, runID: older.id,
                                    content: "older goal", at: Date(timeIntervalSince1970: 1_001))
        try await appendGoalMessage(environment, conversationID: conversation.id, runID: newer.id,
                                    content: "newest goal", at: Date(timeIntervalSince1970: 2_001))
        try await appendToolPairs(to: environment.runStore, runID: older.id, count: olderEventCount)
        try await appendToolPairs(to: environment.runStore, runID: newer.id, count: 4)
        let model = ThreadDetailViewModel(conversationID: conversation.id, center: center)
        await model.load()
        model.stopLiveUpdates()
        return (model, older, environment, center, conversation)
    }

    /// Delivers exactly ONE visibility demand edge: the view's boundary row
    /// arms one bounded fetch per real edge, then the episode ends through
    /// layout gating. Tests use this directly as the model-side contract.
    private func deliverOneVisibilityEdge(_ model: ThreadDetailViewModel, runID: UUID) async {
        guard ThreadEarlierActivityPolicy.nextAutoLoadStep(
            visible: true,
            hasMore: model.earlierEventRunIDs.contains(runID),
            loading: model.loadingEventRunIDs.contains(runID),
            failed: model.failedEarlierEventRunIDs.contains(runID)
        ) == .load else { return }
        await model.loadEarlierEvents(runID: runID)
    }

    private func projectedSequences(_ items: [ThreadTimelineItem], runID: UUID) -> [Int] {
        items.flatMap { item -> [Int] in
            switch item {
            case .event(let event):
                return event.runID == runID ? [event.sequence] : []
            case .stepGroup(let events, _):
                return events.filter { $0.runID == runID }.map(\.sequence)
            default:
                return []
            }
        }
    }

    // MARK: - Policy contract

    @Test("The boundary policy pages on demand edges and never fakes state")
    func policyTables() {
        // A fresh visible edge with older coverage starts one bounded fetch:
        // no tap, no fold.
        #expect(ThreadEarlierActivityPolicy.nextAutoLoadStep(
            visible: true, hasMore: true, loading: false, failed: false) == .load)
        // A repeated trigger while a page is genuinely in flight waits —
        // it never stacks a second bounded fetch for the same run.
        #expect(ThreadEarlierActivityPolicy.nextAutoLoadStep(
            visible: true, hasMore: true, loading: true, failed: false) == .wait)
        // Exhausted coverage ends the boundary (the builder removes the row).
        #expect(ThreadEarlierActivityPolicy.nextAutoLoadStep(
            visible: true, hasMore: false, loading: false, failed: false) == .stop)
        // Off-screen rows never fetch (the lazy margin stays bounded).
        #expect(ThreadEarlierActivityPolicy.nextAutoLoadStep(
            visible: false, hasMore: true, loading: false, failed: false) == .stop)
        // A genuine failure pauses auto-paging; only the retry acts.
        #expect(ThreadEarlierActivityPolicy.nextAutoLoadStep(
            visible: true, hasMore: true, loading: false, failed: true) == .stop)

        // Display mirrors reality only: a spinner appears exactly while a
        // fetch is in flight, so it can never stick after an episode ends.
        #expect(ThreadEarlierActivityPolicy.mode(loading: false, failed: false) == .quiet)
        #expect(ThreadEarlierActivityPolicy.mode(loading: true, failed: false) == .loading)
        #expect(ThreadEarlierActivityPolicy.mode(loading: false, failed: true) == .failed)
        #expect(ThreadEarlierActivityPolicy.mode(loading: true, failed: true) == .loading)
    }

    @Test("A retry shows progress while its old failure is still recorded")
    func retryProgressTakesPrecedence() {
        #expect(ThreadEarlierActivityPolicy.mode(loading: true, failed: true) == .loading)
    }

    // MARK: - Opening stays bounded

    @Test("Opening a tool-heavy thread never eagerly loads older events")
    func openIsBoundedNotEager() async throws {
        let (model, older, _, _, _) = try await seededModel(olderEventCount: 300)
        // Only the newest selected run is loaded on open; the older run is
        // represented by its auto-paging boundary, not a manual button.
        #expect(model.eventsByRun[older.id] == nil)
        #expect(model.earlierEventRunIDs.contains(older.id))
        #expect(model.timeline.contains { if case .earlierEvents(let id) = $0 { id == older.id } else { false } })
        // The stable goal row of the older run exists as the scroll anchor.
        model.stopLiveUpdates()
    }

    // MARK: - Continuous chronological history without any tap

    @Test("Demand edges expose the full history chronologically, one bounded slice each")
    func edgesPageChronologicallyWithoutTaps() async throws {
        let (model, older, _, _, _) = try await seededModel(olderEventCount: 300)
        let total = 300

        var edges = 0
        var lastCount = 0
        while model.earlierEventRunIDs.contains(older.id), edges < 12 {
            edges += 1
            await deliverOneVisibilityEdge(model, runID: older.id)
            let count = model.eventsByRun[older.id]?.count ?? 0
            // Every edge advances by at most one bounded 50-row page.
            #expect(count - lastCount <= 50)
            lastCount = count
        }
        // 300 events across 50-row pages: six demand edges, no more.
        #expect(edges == 6)
        #expect(lastCount == total)

        let loaded = model.eventsByRun[older.id] ?? []
        #expect(loaded.map(\.sequence) == Array(1...total))
        #expect(Set(loaded.map(\.id)).count == total)
        // The boundary is gone once nothing earlier remains — no residual
        // hidden remainder and no leftover control.
        #expect(!model.earlierEventRunIDs.contains(older.id))
        #expect(!model.loadingEventRunIDs.contains(older.id))
        #expect(model.failedEarlierEventRunIDs.isEmpty)
        // The projected timeline shows the whole run in stored sequence
        // order, continuously, without any manual expansion.
        #expect(projectedSequences(model.timeline, runID: older.id) == Array(1...total))
        model.stopLiveUpdates()
    }

    @Test("A page boundary never splits a tool request from its result after paging")
    func pageBoundaryKeepsToolPairing() async throws {
        // 101 events: the first recent window keeps sequences 52...101 and
        // the pair (51 request / 52 result) straddles that boundary.
        let (model, older, _, _, _) = try await seededModel(olderEventCount: 101)
        var edges = 0
        while model.earlierEventRunIDs.contains(older.id), edges < 8 {
            edges += 1
            await deliverOneVisibilityEdge(model, runID: older.id)
        }
        #expect(edges == 3)
        #expect(!model.earlierEventRunIDs.contains(older.id))
        let loaded = model.eventsByRun[older.id] ?? []
        #expect(loaded.map(\.sequence) == Array(1...101))
        let sequences = projectedSequences(model.timeline, runID: older.id)
        #expect(sequences == Array(1...101))
        // The straddling pair is adjacent again in the merged projection:
        // a result never precedes its own request.
        if let requestIndex = sequences.firstIndex(of: 51) {
            #expect(sequences[requestIndex + 1] == 52)
        } else {
            Issue.record("boundary request 51 missing from projection")
        }
        model.stopLiveUpdates()
    }

    @Test("Re-fetching an overlapping window dedups by id and keeps order")
    func overlappingWindowsDedup() async throws {
        let (model, older, environment, _, _) = try await seededModel(olderEventCount: 120)
        for _ in 0..<3 { await deliverOneVisibilityEdge(model, runID: older.id) }
        #expect(model.eventsByRun[older.id]?.map(\.sequence) == Array(1...120))
        // A newer event arrives (live append / reconnect) and a further
        // fetch re-reads a window overlapping everything already merged.
        try await appendToolPairs(to: environment.runStore, runID: older.id, count: 1)
        await model.loadEarlierEvents(runID: older.id)
        let loaded = model.eventsByRun[older.id] ?? []
        #expect(loaded.map(\.sequence) == Array(1...121))
        #expect(Set(loaded.map(\.id)).count == loaded.count)
        // The redundant overlap did not resurrect the resolved boundary.
        #expect(!model.earlierEventRunIDs.contains(older.id))
        model.stopLiveUpdates()
    }

    // MARK: - Failure, retry, cancellation and reload lifecycle

    @Test("A failed page marks only that run, keeps it actionable and recovers on retry")
    func failureRetryAndReload() async throws {
        struct Boom: Error {}
        let (model, older, _, _, _) = try await seededModel(olderEventCount: 120)

        model.earlierEventPageOverride = { _, _, _ in throw Boom() }
        await model.loadEarlierEvents(runID: older.id)
        #expect(model.failedEarlierEventRunIDs.contains(older.id))
        #expect(model.actionError != nil)
        #expect(model.eventsByRun[older.id] == nil)
        // Auto-paging pauses on the failed run (no retry storm).
        #expect(ThreadEarlierActivityPolicy.nextAutoLoadStep(
            visible: true,
            hasMore: model.earlierEventRunIDs.contains(older.id),
            loading: false,
            failed: model.failedEarlierEventRunIDs.contains(older.id)) == .stop)

        // The explicit retry (the only button the row ever shows) recovers
        // through the real store and clears the failure bookkeeping.
        model.earlierEventPageOverride = nil
        await model.loadEarlierEvents(runID: older.id)
        #expect(!model.failedEarlierEventRunIDs.contains(older.id))
        #expect(model.actionError == nil)
        #expect(model.eventsByRun[older.id]?.count == 50)

        // A fresh failure is also cleared by the conversation reload, so a
        // transient store error can never keep history folded permanently.
        model.earlierEventPageOverride = { _, _, _ in throw Boom() }
        await model.loadEarlierEvents(runID: older.id)
        #expect(model.failedEarlierEventRunIDs.contains(older.id))
        model.earlierEventPageOverride = nil
        await model.load()
        model.stopLiveUpdates()
        #expect(model.failedEarlierEventRunIDs.isEmpty)
    }

    @Test("A visibility-task cancellation is not a failure and merges nothing")
    func scrollAwayCancellationIsSilentAndStaleFree() async throws {
        let (model, older, _, _, _) = try await seededModel(olderEventCount: 120)
        model.earlierEventPageOverride = { _, _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return []
        }
        let fetch = Task { await model.loadEarlierEvents(runID: older.id) }
        try await Task.sleep(for: .milliseconds(40))
        // The row leaves the viewport: SwiftUI cancels the boundary task.
        fetch.cancel()
        await fetch.value
        model.earlierEventPageOverride = nil
        // A normal scroll-away must not arm the retry state or surface an
        // error; the quiet boundary stays ready for the next demand edge.
        #expect(model.failedEarlierEventRunIDs.isEmpty)
        #expect(model.actionError == nil)
        #expect(model.eventsByRun[older.id] == nil)
        // The next real edge still pages normally.
        await deliverOneVisibilityEdge(model, runID: older.id)
        #expect(model.eventsByRun[older.id]?.count == 50)
        model.stopLiveUpdates()
    }

    @Test("A superseding reload drops the stale page instead of merging it")
    func reloadFencesStalePage() async throws {
        let (model, older, environment, _, _) = try await seededModel(olderEventCount: 120)
        let runStore = environment.runStore
        // Delay a real, non-empty page so the reload's generation fence is
        // what discards it (an empty page could not prove the merge drop).
        model.earlierEventPageOverride = { runID, _, limit in
            try await Task.sleep(for: .milliseconds(160))
            return try await runStore.recentEvents(runID: runID, limit: limit)
        }
        let fetch = Task { await model.loadEarlierEvents(runID: older.id) }
        try await Task.sleep(for: .milliseconds(20))
        await model.load()
        model.stopLiveUpdates()
        await fetch.value
        model.earlierEventPageOverride = nil
        // The stale page from the previous pass was neither merged nor
        // treated as a failure.
        #expect(model.failedEarlierEventRunIDs.isEmpty)
        #expect(model.actionError == nil)
        #expect(model.eventsByRun[older.id] == nil)
        // The reload path itself re-hydrated the boundary, ready for a real
        // demand edge that lands through the production store.
        #expect(model.earlierEventRunIDs.contains(older.id))
        await deliverOneVisibilityEdge(model, runID: older.id)
        #expect(model.eventsByRun[older.id]?.count == 50)
    }

    @Test("Concurrent episode triggers share one bounded in-flight fetch")
    func inFlightFetchIsSingleton() async throws {
        actor Counter {
            private(set) var calls = 0
            private(set) var limits: [Int] = []
            func record(limit: Int) { calls += 1; limits.append(limit) }
        }
        let (model, older, _, _, _) = try await seededModel(olderEventCount: 120)
        let counter = Counter()
        model.earlierEventPageOverride = { _, _, limit in
            await counter.record(limit: limit)
            try await Task.sleep(for: .milliseconds(120))
            return []
        }
        let first = Task { await model.loadEarlierEvents(runID: older.id) }
        let second = Task { await model.loadEarlierEvents(runID: older.id) }
        await first.value
        await second.value
        let calls = await counter.calls
        #expect(calls == 1)
        // Every page requests exactly one bounded 51-row window.
        let limits = await counter.limits
        #expect(limits == [51])
        model.earlierEventPageOverride = nil
        model.stopLiveUpdates()
    }

    // MARK: - Hosted boundary row: zero-tap behavior

    @Test("The hosted boundary delivers one bounded page per demand edge without taps")
    func hostedRowPagesOnVisibilityEdgesWithoutInteraction() async throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            Issue.record("no active window scene for hosted boundary row")
            return
        }
        let (model, older, _, _, _) = try await seededModel(olderEventCount: 300)
        defer { model.stopLiveUpdates() }

        let viewport = CGRect(x: 0, y: 0, width: 320, height: 600)
        // A static short viewport loads only one page. Another real scroll
        // demand must load more without a forced jump or visibility dance.
        let row = ThreadEarlierActivityRow(
            viewModel: model, runID: older.id, viewportFrame: viewport)
        let host = UIHostingController(rootView: row)
        host.view.frame = viewport
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = viewport
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        // First demand edge: simply being inside the viewport delivers the
        // first bounded page. No tap ever happens in this test.
        let firstDeadline = Date().addingTimeInterval(3)
        while (model.eventsByRun[older.id]?.count ?? 0) < 50, Date() < firstDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.eventsByRun[older.id]?.count == 50)

        // Layout then stays static (no real scroll, no anchor move): the
        // episode ends by itself — the row must NOT keep walking the store
        // and must NOT keep a loading state alive.
        try await Task.sleep(for: .milliseconds(900))
        #expect(model.eventsByRun[older.id]?.count == 50)
        #expect(!model.loadingEventRunIDs.contains(older.id))
        #expect(model.failedEarlierEventRunIDs.isEmpty)

        // A new scroll gesture while the SAME row remains visible must
        // deliver another bounded slice (short histories cannot scroll the
        // boundary off screen). There is no expansion button or scrollTo.
        host.rootView = ThreadEarlierActivityRow(
            viewModel: model, runID: older.id, viewportFrame: viewport,
            scrollDemand: 1)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let secondDeadline = Date().addingTimeInterval(4)
        while (model.eventsByRun[older.id]?.count ?? 0) < 100, Date() < secondDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.eventsByRun[older.id]?.count == 100)
        // Chronology from the store side is contiguous across the pages.
        #expect((model.eventsByRun[older.id] ?? []).map(\.sequence) == Array(201...300))
        // The remaining older records stay reachable through further edges.
        #expect(model.earlierEventRunIDs.contains(older.id))

        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
    }
}
#endif
