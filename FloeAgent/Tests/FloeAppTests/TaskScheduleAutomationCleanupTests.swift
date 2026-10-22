// Focused behavior regressions for the terminal cleanup popup.
//
// The durable lifecycle semantics (who opens a row, dedupe, resolved marks,
// re-armed once plans) are pinned in FloePersistence's
// `TaskScheduleCleanupReminderStoreTests`; the live OPEN-set trigger is
// pinned there too (observation emits). This suite pins only the app-side
// PRESENTATION behavior through the real production model and store, with
// zero system contact:
//   • at most ONE popup, newest open row first; resolved or still-
//     monitoring rows are never candidates;
//   • an on-screen popup is not swapped or hidden by a second event, and
//     is released when its row stops being open elsewhere;
//   • "Later"/"Open Shortcuts" are presentation marks ONLY: the durable
//     row stays open (inline 已移除/忽略 remain the only resolutions) and
//     repeated passes in one process never re-nag the SAME event;
//   • suppression is keyed to the event's lifecycle — durable row PLUS
//     that row's persisted monitoring epoch (`setup_at`) — so duplicate
//     receipts on one epoch stay quiet, while a REAL re-arm (which
//     updates the same row and advances the epoch) makes the next
//     terminal a fresh event that is offered again, exactly once;
//   • an inline resolution's scoped release callback keeps a later fresh
//     durable event on the same row presentable (the store-sanctioned
//     stale-fire reopening of a `removed` row), without claiming any
//     deletion;
//   • a relaunch (fresh ledger) may re-offer an unresolved event honestly;
//   • a pass whose gate was cancelled while durable reads were in flight
//     publishes NOTHING late and consumes no marks; the next gated pass
//     still presents the still-open event (the alert's own visibility is
//     gated the same way, and only explicit button taps mark — system
//     dismissals never record "shown"; this is view-level wiring pinned by
//     Main's UI gate);
//   • the shared copy stays honest per reason. No UI is instantiated.

#if canImport(UIKit) && canImport(SwiftUI) && DEBUG
import Foundation
import Testing
import FloeModels
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.TaskScheduleAutomationCleanup")
@MainActor
struct TaskScheduleAutomationCleanupTests {

    private func reminder(
        _ status: TaskScheduleCleanupStatus,
        reason: TaskScheduleCleanupReason?,
        minutesAgo: TimeInterval = 0,
        id: UUID = UUID(),
        setupMinutesAgo: TimeInterval? = nil
    ) -> TaskScheduleCleanupReminder {
        let now = Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60)
        let setup = Date(timeIntervalSince1970:
            1_800_000_000 - (setupMinutesAgo ?? minutesAgo) * 60)
        return TaskScheduleCleanupReminder(
            id: id, scheduleID: UUID(), title: "Plan",
            reason: reason, status: status,
            setupSource: .importFlowOpened, setupAt: setup,
            createdAt: now, updatedAt: now, lastSeenAt: now)
    }

    private func makeModel() async throws -> (
        model: TaskScheduleCleanupPopupModel,
        schedules: SQLiteTaskScheduleStore,
        reminders: TaskScheduleCleanupReminderStore,
        ledger: TaskScheduleCleanupPopupLedger
    ) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let reminders = TaskScheduleCleanupReminderStore(database: database)
        let ledger = TaskScheduleCleanupPopupLedger()
        return (
            TaskScheduleCleanupPopupModel(store: reminders, ledger: ledger),
            SQLiteTaskScheduleStore(database: database),
            reminders,
            ledger
        )
    }

    private func dailyPlan(_ schedules: SQLiteTaskScheduleStore) async throws
        -> TaskScheduleRecord {
        let record = TaskScheduleRecord(
            title: "Report", prompt: "p", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-60))
        try await schedules.save(record)
        return record
    }

    private func oncePlan(
        _ schedules: SQLiteTaskScheduleStore,
        title: String,
        base: Date
    ) async throws -> TaskScheduleRecord {
        let record = TaskScheduleRecord(
            title: title, prompt: "p", cadence: .once,
            scheduledAt: base.addingTimeInterval(-60))
        try await schedules.save(record)
        return record
    }

    /// Drives ONE real round through the production schedule store:
    /// claim → running → launch (a once plan is consumed and disabled by
    /// its own start) → the bound occurrence TERMINAL, which is the honest
    /// retirement moment that opens the cleanup row epoch-fenced against
    /// the row's current `setup_at`.
    private func runOnceRound(
        _ schedules: SQLiteTaskScheduleStore,
        record: TaskScheduleRecord,
        key: String,
        start: Date
    ) async throws {
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: record.id, dedupeKey: key),
            scheduleID: record.id,
            scheduledFor: start,
            dedupeKey: key)
        _ = try await schedules.enqueueOccurrence(occurrence)
        _ = try await schedules.claimOccurrence(id: occurrence.id, at: start)
        _ = try await schedules.markOccurrenceRunning(
            id: occurrence.id, runID: UUID(), conversationID: UUID(),
            at: start.addingTimeInterval(1))
        try await schedules.markStarted(
            id: record.id, at: start.addingTimeInterval(2))
        try await schedules.finishOccurrence(
            id: occurrence.id, state: .completed, summary: nil, errorText: nil,
            at: start.addingTimeInterval(3))
    }

    // MARK: Pure policy

    @Test("Only OPEN, not-yet-shown rows are candidates; newest first")
    func candidateSelection() {
        let openNewest = reminder(.open, reason: .deleted, minutesAgo: 0)
        let openOldest = reminder(.open, reason: .onceConsumed, minutesAgo: 5)
        let monitoring = reminder(.monitoring, reason: nil, minutesAgo: 1)
        let dismissed = reminder(.dismissed, reason: .deleted, minutesAgo: 2)
        // openReminders delivers newest-seen-first; a stray monitoring or
        // dismissed row passed in by mistake can NEVER hijack the popup.
        let picked = TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [openNewest, monitoring, dismissed, openOldest],
            alreadyShown: [])
        #expect(picked?.id == openNewest.id)
    }

    @Test("Shown events are skipped; the next unseen still surfaces once")
    func shownSkipAndFreshEvent() {
        let first = reminder(.open, reason: .staleTrigger)
        let second = reminder(.open, reason: .deleted, minutesAgo: 3)
        let list = [first, second]
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: list, alreadyShown: [])?.id == first.id)
        // First handled: the queued second event comes up on the NEXT pass.
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: list,
            alreadyShown: [TaskScheduleCleanupEventKey(first)])?.id == second.id)
        // Both handled: this process nags nothing further — one popup per
        // event, never per activation loop.
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: list,
            alreadyShown: [TaskScheduleCleanupEventKey(first),
                          TaskScheduleCleanupEventKey(second)]) == nil)
        // A genuinely newer event (newest-seen-first ordering) is still
        // presented once even with older rows already shown.
        let third = reminder(.open, reason: .onceConsumed, minutesAgo: 0)
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [third, first, second],
            alreadyShown: [TaskScheduleCleanupEventKey(first),
                          TaskScheduleCleanupEventKey(second)])?.id == third.id)
    }

    @Test("An empty or fully-shown list presents nothing")
    func nothingToPresent() {
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [], alreadyShown: []) == nil)
        let only = reminder(.open, reason: .deleted)
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [only], alreadyShown: [TaskScheduleCleanupEventKey(only)]) == nil)
    }

    @Test(
        "The event key is row + monitoring epoch: receipts never re-nag, a re-armed terminal is fresh"
    )
    func lifecycleEpochIsTheEventKey() {
        let rowID = UUID()
        let event = reminder(.open, reason: .onceConsumed, id: rowID)
        let shown: Set<TaskScheduleCleanupEventKey> = [
            TaskScheduleCleanupEventKey(event)
        ]
        // A duplicate open receipt (retire dedupe / stale echo) advances
        // only `last_seen_at`/`updated_at` — SAME row, SAME persisted
        // monitoring epoch. Keying on those receipt bookkeeping fields
        // would re-nag per receipt; keying on the durable lifecycle epoch
        // keeps this one event quiet.
        let echo = reminder(.open, reason: .onceConsumed,
                            minutesAgo: 1, id: rowID, setupMinutesAgo: 0)
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [echo], alreadyShown: shown) == nil)
        // Re-arm updates the SAME row and advances its persisted monitoring
        // epoch: the next terminal is a NEW lifecycle event and must be
        // offered again in this very process.
        let rearmedTerminal = reminder(.open, reason: .onceConsumed,
                                       id: rowID, setupMinutesAgo: 10)
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [rearmedTerminal], alreadyShown: shown)?.id == rowID)
    }

    @Test("A fresh process may re-offer an unresolved cleanup honestly")
    func ledgerIsProcessScoped() {
        let ledger = TaskScheduleCleanupPopupLedger()
        let row = reminder(.open, reason: .onceConsumed)
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [row], alreadyShown: ledger.shownKeys)?.id == row.id)
        ledger.markShown(row)
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [row], alreadyShown: ledger.shownKeys) == nil)
        #expect(ledger.contains(row))
        // "Restart": a NEW ledger sees the still-open event as presentable —
        // because the durable row was never consumed by "Later".
        let relaunched = TaskScheduleCleanupPopupLedger()
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [row], alreadyShown: relaunched.shownKeys)?.id == row.id)
        // The scoped inline-resolution release clears exactly ONE row's
        // marks (presentation only; the durable status write is the
        // store's own transition, tested against the real store below).
        let other = reminder(.open, reason: .deleted)
        ledger.markShown(other)
        ledger.releaseRowSuppressions(rowID: row.id)
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [row, other], alreadyShown: ledger.shownKeys)?.id == row.id)
        // The other row's event stays suppressed — the release is scoped.
        #expect(TaskScheduleCleanupPopupPolicy.nextReminder(
            open: [other], alreadyShown: ledger.shownKeys) == nil)
        #expect(!ledger.contains(row))
        #expect(ledger.contains(other))
    }

    // MARK: Production model over the real durable chain

    @Test("The model presents exactly the terminal row and stays silent otherwise")
    func modelFollowsTheDurableTruth() async throws {
        let (model, schedules, reminders, _) = try await makeModel()
        let record = try await dailyPlan(schedules)
        // Live but only SILENTLY monitored: nothing to present.
        try await reminders.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .importFlowOpened, at: Date())
        await model.refresh()
        #expect(model.candidate == nil)
        // Terminal (permanent delete) → exactly one popup candidate.
        try await schedules.delete(id: record.id)
        await model.refresh()
        let popup = try #require(model.candidate)
        #expect(popup.reason == .deleted)
        #expect(popup.title == "Report")
        // A second event cannot swap or hide the shown popup.
        let other = try await dailyPlan(schedules)
        try await reminders.recordSetup(
            scheduleID: other.id, title: other.title,
            source: .importFlowOpened, at: Date())
        try await schedules.delete(id: other.id)
        await model.refresh()
        #expect(model.candidate?.id == popup.id)
        // Answering ("Later" semantics) clears the screen but consumes
        // NOTHING durable: the row is still open for the inline actions.
        model.markPresented()
        #expect(model.candidate == nil)
        #expect(try await reminders.openReminders().count == 2)
        // Repeat passes in this process no longer nag the answered row;
        // they surface the still-unanswered second event exactly once.
        await model.refresh()
        let next = try #require(model.candidate)
        #expect(next.id != popup.id)
        model.markPresented()
        await model.refresh()
        #expect(model.candidate == nil)
    }

    @Test(
        "The REAL re-arm chain: Later, re-enable, new terminal → one fresh popup"
    )
    func rearmTerminalAfterLaterPresentsFreshOnce() async throws {
        let (model, schedules, reminders, _) = try await makeModel()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try await oncePlan(schedules, title: "Round trip", base: base)
        try await reminders.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .importFlowOpened, at: base)
        // Round one runs and TERMINATES: the cleanup opens.
        try await runOnceRound(
            schedules, record: record, key: "calendar:1",
            start: base.addingTimeInterval(5))
        await model.refresh()
        let first = try #require(model.candidate)
        #expect(first.reason == .onceConsumed)
        #expect(first.id == TaskScheduleCleanupReminder.stableID(scheduleID: record.id))
        #expect(first.setupAt == base)
        // "稍后" in the SAME process: mark lands, durable row stays open.
        model.markPresented()
        #expect(model.candidate == nil)
        let answered = try #require(try await reminders.reminder(scheduleID: record.id))
        #expect(answered.status == .open)
        // The user RE-ARMS the same plan through the real store: the row
        // returns to silent monitoring with its persisted epoch advanced,
        // same stable row id — no new row, no new id.
        try await schedules.setEnabled(
            id: record.id, enabled: true, at: base.addingTimeInterval(20))
        let rearmed = try #require(try await reminders.reminder(scheduleID: record.id))
        #expect(rearmed.id == first.id)
        #expect(rearmed.status == .monitoring)
        #expect(rearmed.setupAt == base.addingTimeInterval(20))
        await model.refresh()
        #expect(model.candidate == nil)   // silent monitoring is never a candidate
        // The new round reaches its OWN terminal: same row, NEW epoch.
        // This is exactly the event the row-id-only ledger used to swallow.
        try await runOnceRound(
            schedules, record: record, key: "calendar:2",
            start: base.addingTimeInterval(30))
        await model.refresh()
        let second = try #require(model.candidate)
        #expect(second.id == first.id)               // the same durable row…
        #expect(second.setupAt != first.setupAt)     // …a new lifecycle event
        #expect(second.reason == .onceConsumed)
        // Exactly once: answering it again keeps this process quiet.
        model.markPresented()
        await model.refresh()
        #expect(model.candidate == nil)
        #expect(try await reminders.openReminders().count == 1)
    }

    @Test("Duplicate receipts on one answered epoch never re-nag")
    func duplicateReceiptsOnOneEpochStayQuiet() async throws {
        let (model, _, reminders, _) = try await makeModel()
        let gone = UUID()
        try await reminders.recordStaleTrigger(
            scheduleID: gone, title: "Ghost", at: Date())
        await model.refresh()
        let popup = try #require(model.candidate)
        model.markPresented()
        // Repeated external fires for the SAME vanished plan: the store
        // dedupes into the one row (its epoch-less stale identity and its
        // first reason survive; only receipt bookkeeping advances). The
        // popup must not come back per receipt.
        try await reminders.recordStaleTrigger(
            scheduleID: gone, title: "Ghost", at: Date())
        try await reminders.recordStaleTrigger(
            scheduleID: gone, title: "Ghost", at: Date())
        await model.refresh()
        #expect(model.candidate == nil)
        let open = try await reminders.openReminders()
        #expect(open.count == 1)
        #expect(open.first?.id == popup.id)
        #expect(open.first?.reason == .staleTrigger)
    }

    @Test("A stale fire reopening a removed row presents fresh; repeats stay quiet")
    func removedRowReopenedByStaleFirePresentsFresh() async throws {
        let (model, _, reminders, ledger) = try await makeModel()
        let gone = UUID()
        try await reminders.recordStaleTrigger(
            scheduleID: gone, title: "Ghost", at: Date())
        await model.refresh()
        let popup = try #require(model.candidate)
        model.markPresented()   // "稍后" marks this event for the process
        // The user then resolves inline ("已移除") and Home runs its
        // scoped release callback after the successful durable write
        // (presentation marks only — nothing here deletes or claims a
        // system-automation removal).
        try await reminders.markRemoved(id: popup.id)
        ledger.releaseRowSuppressions(rowID: popup.id)
        await model.refresh()
        #expect(model.candidate == nil)   // a resolved row is never a candidate
        // A NEW stale fire reopens the row — the store treats direct fire
        // evidence on a `removed` row as fresh, reusing the SAME row and
        // epoch. Without the resolution release this would stay suppressed
        // forever for a genuinely new event.
        try await reminders.recordStaleTrigger(
            scheduleID: gone, title: "Ghost", at: Date())
        await model.refresh()
        let reopened = try #require(model.candidate)
        #expect(reopened.id == popup.id)
        #expect(reopened.status == .open)
        model.markPresented()
        // Further fires of the same still-open stale event stay quiet:
        // one popup per event in-process, no per-receipt spam.
        try await reminders.recordStaleTrigger(
            scheduleID: gone, title: "Ghost", at: Date())
        await model.refresh()
        #expect(model.candidate == nil)
    }

    @Test("A pass cancelled by the gate publishes nothing; the next pass still does")
    func cancelledPassDoesNotPublishFreshCandidate() async throws {
        let (model, schedules, reminders, ledger) = try await makeModel()
        let record = try await dailyPlan(schedules)
        try await reminders.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .importFlowOpened, at: Date())
        try await schedules.delete(id: record.id)
        let row = try #require(try await reminders.reminder(scheduleID: record.id))
        #expect(row.status == .open)
        // The root `.task(id: popupGate)` tore down (scene left foreground)
        // while its durable reads were in flight — the real race, because
        // a GRDB read can RETURN after the cancellation. Cancellation is
        // set before the pass body can start (same actor, no suspension
        // between start and cancel here), so the late-returning reads must
        // publish NO popup and consume NO process marks: an answered-
        // looking popup the user never saw would silently steal the event.
        let offGate = Task { @MainActor in
            await model.refresh()
            return model.candidate?.id
        }
        offGate.cancel()
        _ = await offGate.value
        #expect(model.candidate == nil)
        #expect(ledger.shownKeys.isEmpty)
        // Honest durability: the row stayed exactly where it was and the
        // NEXT gated (uncancelled) pass presents the event once.
        await model.refresh()
        let popup = try #require(model.candidate)
        #expect(popup.id == row.id)
        #expect(ledger.shownKeys.isEmpty)   // presenting consumed nothing
    }

    @Test("A row resolved elsewhere releases its on-screen popup")
    func inlineResolutionReleasesPopup() async throws {
        let (model, schedules, reminders, _) = try await makeModel()
        let record = try await dailyPlan(schedules)
        try await reminders.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .importFlowOpened, at: Date())
        try await schedules.delete(id: record.id)
        await model.refresh()
        let popup = try #require(model.candidate)
        // The user handles the SAME event from the inline section
        // ("忽略") while the popup is up: the popup must let go.
        try await reminders.dismiss(id: popup.id)
        await model.refresh()
        #expect(model.candidate == nil)
        // And a dismissed event never comes back as a candidate in this
        // process either (store keeps it silenced; policy only reads open).
        await model.refresh()
        #expect(model.candidate == nil)
    }

    @Test("A stale receipt for a vanished plan surfaces through the model")
    func staleReceiptSurfacesThroughModel() async throws {
        let (model, _, reminders, _) = try await makeModel()
        // The external-trigger receipt path records directly for a plan
        // that no longer exists (no setup was ever monitored).
        let gone = UUID()
        try await reminders.recordStaleTrigger(
            scheduleID: gone, title: "Ghost plan", at: Date())
        // The foreground safety-net pass in refresh cannot duplicate it.
        await model.refresh()
        let popup = try #require(model.candidate)
        #expect(popup.reason == .staleTrigger)
        #expect(popup.title == "Ghost plan")
        await model.refresh()
        #expect(model.candidate?.id == popup.id)
    }

    // MARK: Shared honest copy

    @Test("Popup copy names the plan, asks the USER to act, claims nothing")
    func copyHonesty() {
        for reason in [TaskScheduleCleanupReason.deleted, .onceConsumed, .staleTrigger] {
            let line = TaskScheduleCleanupCopy.reason(
                reminder(.open, reason: reason))
            #expect(line.contains("Plan"))
            // Both languages route the action to Shortcuts, never to Floe.
            #expect(line.contains("快捷指令") || line.contains("Shortcuts"))
        }
        // The two popup choices are exactly Open-Shortcuts and Later —
        // locale-stable as a closed set; there is NO delete/confirm action.
        #expect(Set(["打开快捷指令", "Open Shortcuts"])
            .contains(TaskScheduleCleanupCopy.openShortcuts()))
        #expect(Set(["稍后", "Later"]).contains(TaskScheduleCleanupCopy.later()))
        #expect(Set(["已移除", "Removed"]).contains(TaskScheduleCleanupCopy.removed()))
        #expect(Set(["忽略", "Dismiss"]).contains(TaskScheduleCleanupCopy.dismiss()))
    }
}
#endif
