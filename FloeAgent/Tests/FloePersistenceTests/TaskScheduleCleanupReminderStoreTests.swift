import Foundation
import GRDB
import Testing
@testable import FloeModels
@testable import FloePersistence

/// Focused regressions for the setup-scoped Shortcut cleanup lifecycle:
/// silent monitoring records only for ACTUAL Shortcut handoffs/confirmations
/// (a never-configured plan stays silent forever); cleanup opens at the
/// PERMANENT delete or at the TERMINAL retirement of a one-shot — never at
/// `markStarted` while the task may still run, never at a recurring
/// occurrence completion, never at a reversible pause; dedupe keeps ONE
/// row per schedule; the load/foreground reconciliation recovers writes lost
/// to a crash; a fresh handoff after an earlier resolved marker restarts
/// monitoring; only direct stale-fire evidence may reopen a user-resolved
/// row — and never a silenced one. Reminder writes can never enable,
/// re-arm or launch a schedule. Re-arming an already-run one-shot returns
/// its monitoring/open evidence to the SILENT current round and advances
/// the monitoring epoch: a historical `last_started_at` can never consume a
/// fresh handoff or a paused re-enable (temporary pauses never remind),
/// while a genuine NEW terminal still opens exactly once.
@Suite("FloePersistence.TaskScheduleCleanupReminderStore")
struct TaskScheduleCleanupReminderStoreTests {

    private func makeStores() throws -> (
        database: DatabaseManager,
        schedules: SQLiteTaskScheduleStore,
        reminders: TaskScheduleCleanupReminderStore
    ) {
        let database = try DatabaseManager.inMemory()
        try database.migrate()
        return (
            database,
            SQLiteTaskScheduleStore(database: database),
            TaskScheduleCleanupReminderStore(database: database)
        )
    }

    private func makeSchedule(
        _ schedules: SQLiteTaskScheduleStore,
        title: String,
        cadence: TaskScheduleCadence = .daily
    ) async throws -> TaskScheduleRecord {
        let record = TaskScheduleRecord(
            title: title, prompt: "p", cadence: cadence,
            scheduledAt: Date().addingTimeInterval(-60))
        try await schedules.save(record)
        return record
    }

    private func monitor(
        _ reminders: TaskScheduleCleanupReminderStore,
        _ record: TaskScheduleRecord
    ) async throws {
        try await reminders.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .importFlowOpened, at: Date())
    }

    // MARK: Setup gate

    @Test("No setup: deleting a never-configured plan records nothing")
    func deleteWithoutSetupIsSilent() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Never shared")
        try await schedules.delete(id: record.id)
        #expect(try await reminders.openReminders().isEmpty)
        #expect(try await reminders.reminder(scheduleID: record.id) == nil)
        _ = database
    }

    @Test("Monitoring is silent: a live monitored plan shows nothing")
    func monitoringInvisible() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Monitored live")
        try await monitor(reminders, record)
        #expect(try await reminders.openReminders().isEmpty)
        let row = try #require(try await reminders.reminder(scheduleID: record.id))
        #expect(row.status == .monitoring)
        #expect(row.reason == nil)
        #expect(row.setupSource == .importFlowOpened)
        _ = database
    }

    @Test("Actual handoff then delete opens one reminder that survives relaunch")
    func setupThenDeleteOpensAndSurvivesRelaunch() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Weekly digest")
        try await monitor(reminders, record)
        try await schedules.delete(id: record.id)

        let list = try await reminders.openReminders()
        #expect(list.count == 1)
        let reminder = try #require(list.first)
        #expect(reminder.scheduleID == record.id)
        #expect(reminder.title == "Weekly digest")
        #expect(reminder.reason == .deleted)
        #expect(reminder.status == .open)

        // A fresh store over the same durable database = relaunch. The
        // captured title survives even though the plan row is gone (no FK).
        let reopened = TaskScheduleCleanupReminderStore(database: database)
        let afterRelaunch = try await reopened.openReminders()
        #expect(afterRelaunch.count == 1)
        #expect(afterRelaunch.first?.title == "Weekly digest")
        #expect(try await schedules.schedule(id: record.id) == nil)
    }

    // MARK: One-shot terminal semantics

    @Test("Started-but-running one-shot shows nothing; terminal shows onceConsumed")
    func onceTerminalNotStart() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Once", cadence: .once)
        try await monitor(reminders, record)

        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: record.id, dedupeKey: "calendar:1"),
            scheduleID: record.id,
            scheduledFor: Date().addingTimeInterval(-60),
            dedupeKey: "calendar:1")
        _ = try await schedules.enqueueOccurrence(occurrence)
        _ = try await schedules.claimOccurrence(id: occurrence.id, at: Date())
        _ = try await schedules.markOccurrenceRunning(
            id: occurrence.id, runID: UUID(), conversationID: UUID(), at: Date())
        // The launch consumes the one-shot (disabled permanently)…
        try await schedules.markStarted(id: record.id, at: Date())
        // …but the task may still be running: NO cleanup yet.
        #expect(try await reminders.openReminders().isEmpty)

        // The bound occurrence TERMINATES: cleanup opens.
        try await schedules.finishOccurrence(
            id: occurrence.id, state: .completed, summary: nil, errorText: nil, at: Date())
        let list = try await reminders.openReminders()
        #expect(list.count == 1)
        #expect(list.first?.reason == .onceConsumed)
        #expect(list.first?.title == "Once")
        _ = database
    }

    @Test("recordRunCompletion is a terminal retirement moment too")
    func onceTerminalViaRunCompletion() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Once run", cadence: .once)
        try await monitor(reminders, record)
        let runID = UUID()
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: record.id, dedupeKey: "calendar:1"),
            scheduleID: record.id,
            scheduledFor: Date().addingTimeInterval(-60),
            dedupeKey: "calendar:1")
        _ = try await schedules.enqueueOccurrence(occurrence)
        _ = try await schedules.claimOccurrence(id: occurrence.id, at: Date())
        _ = try await schedules.markOccurrenceRunning(
            id: occurrence.id, runID: runID, conversationID: UUID(), at: Date())
        try await schedules.markStarted(id: record.id, at: Date())
        #expect(try await reminders.openReminders().isEmpty)

        _ = try await schedules.recordRunCompletion(
            runID: runID, succeeded: true, cancelled: false, summary: nil, at: Date())
        let list = try await reminders.openReminders()
        #expect(list.map(\.reason) == [.onceConsumed])
        _ = database
    }

    @Test("Recurring occurrence completion and any pause record nothing")
    func recurringAndPauseAreNotRetirement() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Daily", cadence: .daily)
        try await monitor(reminders, record)

        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: record.id, dedupeKey: "calendar:1"),
            scheduleID: record.id,
            scheduledFor: Date().addingTimeInterval(-60),
            dedupeKey: "calendar:1")
        _ = try await schedules.enqueueOccurrence(occurrence)
        _ = try await schedules.claimOccurrence(id: occurrence.id, at: Date())
        _ = try await schedules.markOccurrenceRunning(
            id: occurrence.id, runID: UUID(), conversationID: UUID(), at: Date())
        try await schedules.markStarted(id: record.id, at: Date())
        // A recurring occurrence COMPLETES — the plan keeps running later,
        // so nothing retires.
        try await schedules.finishOccurrence(
            id: occurrence.id, state: .completed, summary: nil, errorText: nil, at: Date())
        #expect(try await reminders.openReminders().isEmpty)

        // Ordinary (reversible) pause: still nothing.
        try await schedules.setEnabled(id: record.id, enabled: false, at: Date())
        #expect(try await reminders.openReminders().isEmpty)
        // And the reconciliation must not misread a paused plan either.
        let opened = try await reminders.reconcileMonitoring()
        #expect(opened == 0)
        #expect(try await reminders.openReminders().isEmpty)
        _ = database
    }

    @Test("A cancelled one-shot occurrence is terminal and retires")
    func cancelledOnceOccurrenceRetires() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Once cancelled", cadence: .once)
        try await monitor(reminders, record)
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: record.id, dedupeKey: "calendar:1"),
            scheduleID: record.id,
            scheduledFor: Date().addingTimeInterval(-60),
            dedupeKey: "calendar:1")
        _ = try await schedules.enqueueOccurrence(occurrence)
        _ = try await schedules.claimOccurrence(id: occurrence.id, at: Date())
        _ = try await schedules.markOccurrenceRunning(
            id: occurrence.id, runID: UUID(), conversationID: UUID(), at: Date())
        try await schedules.markStarted(id: record.id, at: Date())
        try await schedules.finishOccurrence(
            id: occurrence.id, state: .cancelled, summary: nil, errorText: nil, at: Date())
        let list = try await reminders.openReminders()
        #expect(list.map(\.reason) == [.onceConsumed])
        _ = database
    }

    // MARK: Reconciliation (crash / lost auxiliary write)

    @Test("Reconcile opens monitoring rows whose delete write was lost")
    func reconcileOpensMissedDelete() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Crash deleted")
        try await monitor(reminders, record)
        // Simulate the crash window: the plan row is gone but the cleanup
        // open write never landed (raw DELETE bypasses the store hook).
        try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM task_schedules WHERE id = ?",
                arguments: [record.id.uuidString])
        }
        let opened = try await reminders.reconcileMonitoring()
        #expect(opened == 1)
        let list = try await reminders.openReminders()
        #expect(list.count == 1)
        #expect(list.first?.reason == .deleted)
        #expect(list.first?.title == "Crash deleted")
    }

    @Test("Reconcile opens a consumed one-shot whose terminal write was lost")
    func reconcileOpensConsumedOnce() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Crash once", cadence: .once)
        try await monitor(reminders, record)
        // markStarted consumed the plan; no live occurrence remains; the
        // terminal open write is assumed lost.
        try await schedules.markStarted(id: record.id, at: Date())
        let opened = try await reminders.reconcileMonitoring()
        #expect(opened == 1)
        let list = try await reminders.openReminders()
        #expect(list.first?.reason == .onceConsumed)
        _ = database
    }

    @Test("Reconcile never opens a one-shot still running or never started")
    func reconcileGuardsRunningAndPausedOnce() async throws {
        let (database, schedules, reminders) = try makeStores()
        // Still running: claimed+running instance exists.
        let running = try await makeSchedule(schedules, title: "Running once", cadence: .once)
        try await monitor(reminders, running)
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: running.id, dedupeKey: "calendar:1"),
            scheduleID: running.id,
            scheduledFor: Date().addingTimeInterval(-60),
            dedupeKey: "calendar:1")
        _ = try await schedules.enqueueOccurrence(occurrence)
        _ = try await schedules.claimOccurrence(id: occurrence.id, at: Date())
        _ = try await schedules.markOccurrenceRunning(
            id: occurrence.id, runID: UUID(), conversationID: UUID(), at: Date())
        try await schedules.markStarted(id: running.id, at: Date())
        // Paused before ever starting: disabled but no launch recorded.
        let paused = try await makeSchedule(schedules, title: "Paused once", cadence: .once)
        try await monitor(reminders, paused)
        try await schedules.setEnabled(id: paused.id, enabled: false, at: Date())

        let opened = try await reminders.reconcileMonitoring()
        #expect(opened == 0)
        #expect(try await reminders.openReminders().isEmpty)
        _ = database
    }

    // MARK: Rounds, dedupe and user marks

    @Test("A fresh handoff after a resolved marker can retire again")
    func freshSetupAfterResolved() async throws {
        let (database, schedules, reminders) = try makeStores()
        var record = try await makeSchedule(schedules, title: "Round one")
        try await monitor(reminders, record)
        try await schedules.delete(id: record.id)
        let first = try await reminders.openReminders()
        #expect(first.count == 1)
        try await reminders.dismiss(id: first[0].id)
        #expect(try await reminders.openReminders().isEmpty)

        // The SAME plan identity gets a NEW actual handoff (e.g. re-created
        // with the stable id after an import round): monitoring restarts.
        try await reminders.recordSetup(
            scheduleID: record.id, title: "Round two",
            source: .handedOffToUser, at: Date())
        #expect(try await reminders.openReminders().isEmpty)
        record = TaskScheduleRecord(
            id: record.id, title: "Round two", prompt: "p", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-60))
        try await schedules.save(record)
        try await schedules.delete(id: record.id)
        // …and the next retirement opens the row again.
        let second = try await reminders.openReminders()
        #expect(second.count == 1)
        #expect(second.first?.title == "Round two")
        #expect(second.first?.status == .open)
        _ = database
    }

    @Test("Repeated retirement events dedupe to one row and keep the first reason")
    func dedupeKeepsFirstReason() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Twice", cadence: .once)
        try await monitor(reminders, record)
        try await schedules.delete(id: record.id)
        // Further evidence of the SAME lifecycle never adds a row nor
        // rewrites the first reason.
        try await reminders.recordStaleTrigger(
            scheduleID: record.id, title: "Twice renamed", at: Date())
        _ = try await reminders.reconcileMonitoring()

        let list = try await reminders.openReminders()
        #expect(list.count == 1)
        #expect(list.first?.reason == .deleted)
        let stored = try #require(try await reminders.reminder(id: list.first?.id ?? UUID()))
        #expect(stored.lastSeenAt >= stored.createdAt)
        _ = database
    }

    @Test("Dismiss and mark-removed are distinct user-side transitions")
    func userTransitions() async throws {
        let (database, schedules, reminders) = try makeStores()
        let first = try await makeSchedule(schedules, title: "A")
        let second = try await makeSchedule(schedules, title: "B")
        try await monitor(reminders, first)
        try await monitor(reminders, second)
        try await schedules.delete(id: first.id)
        try await schedules.delete(id: second.id)
        #expect(try await reminders.openReminders().count == 2)

        let firstID = TaskScheduleCleanupReminder.stableID(scheduleID: first.id)
        let secondID = TaskScheduleCleanupReminder.stableID(scheduleID: second.id)
        try await reminders.markRemoved(id: firstID)
        try await reminders.dismiss(id: secondID)
        #expect(try await reminders.openReminders().isEmpty)
        #expect(try await reminders.reminder(id: firstID)?.status == .removed)
        #expect(try await reminders.reminder(id: secondID)?.status == .dismissed)

        // Resolved rows only move from 'open': a repeat tap cannot flip
        // removed into dismissed or back into open.
        try await reminders.dismiss(id: firstID)
        #expect(try await reminders.reminder(id: firstID)?.status == .removed)
        _ = database
    }

    @Test("A new stale fire REOPENS a removed row (the fire disproves it)")
    func staleReopensRemoved() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Claimed gone")
        try await monitor(reminders, record)
        try await schedules.delete(id: record.id)
        let id = try #require(try await reminders.openReminders().first?.id)
        try await reminders.markRemoved(id: id)
        #expect(try await reminders.openReminders().isEmpty)

        try await reminders.recordStaleTrigger(
            scheduleID: record.id, title: "Claimed gone", at: Date())
        let reopened = try await reminders.openReminders()
        #expect(reopened.count == 1)
        // The reopening reason is the direct evidence itself.
        #expect(reopened.first?.reason == .staleTrigger)
        _ = database
    }

    @Test("A stale fire never re-nags a dismissed event, only advances evidence")
    func dismissedStaysSilent() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Silenced")
        try await monitor(reminders, record)
        try await schedules.delete(id: record.id)
        let id = try #require(try await reminders.openReminders().first?.id)
        try await reminders.dismiss(id: id)
        let before = try #require(try await reminders.reminder(id: id))

        try await reminders.recordStaleTrigger(
            scheduleID: record.id, title: "Silenced", at: Date())
        #expect(try await reminders.openReminders().isEmpty)
        let after = try #require(try await reminders.reminder(id: id))
        #expect(after.status == .dismissed)
        #expect(after.reason == .deleted)
        #expect(after.lastSeenAt >= before.lastSeenAt)
        _ = database
    }

    @Test("Stale fire for a never-monitored deleted plan creates the reminder")
    func staleWithoutSetup() async throws {
        let (database, schedules, reminders) = try makeStores()
        // Old app: a plan was deleted with NO monitoring (pre-import or the
        // user never confirmed anything). The fire itself is the evidence.
        let record = try await makeSchedule(schedules, title: "Old trigger")
        try await schedules.delete(id: record.id)
        #expect(try await reminders.reminder(scheduleID: record.id) == nil)

        try await reminders.recordStaleTrigger(
            scheduleID: record.id, title: "Old trigger", at: Date())
        let list = try await reminders.openReminders()
        #expect(list.count == 1)
        #expect(list.first?.reason == .staleTrigger)
        #expect(list.first?.setupSource == nil)
        _ = database
    }

    // MARK: Isolation and robustness

    @Test("Reminder writes never touch schedule, occurrence or enable state")
    func noLifecycleSideEffects() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Invariant", cadence: .once)
        let before = try #require(try await schedules.schedule(id: record.id))
        try await reminders.recordSetup(
            scheduleID: record.id, title: "Invariant", source: .userConfirmed, at: Date())
        try await reminders.recordStaleTrigger(
            scheduleID: record.id, title: "Invariant", at: Date())
        _ = try await reminders.reconcileMonitoring()
        let after = try #require(try await schedules.schedule(id: record.id))
        #expect(before == after)
        #expect(after.isEnabled == true)
        #expect(try await schedules.pendingOccurrences(limit: 10).isEmpty)

        // A stale automation cannot re-enable a deleted plan either: after
        // delete + reminder, enabling the missing id must fail, not revive.
        try await schedules.delete(id: record.id)
        do {
            try await schedules.setEnabled(id: record.id, enabled: true, at: Date())
            Issue.record("setEnabled on a deleted schedule must throw, not revive")
        } catch {
            // expected
        }
        #expect(try await schedules.schedule(id: record.id) == nil)
        _ = database
    }

    @Test("A cleanup write failure can never roll back core mutations")
    func auxiliaryFailureCannotBreakCore() async throws {
        let (database, schedules, reminders) = try makeStores()
        let record = try await makeSchedule(schedules, title: "Break me", cadence: .once)
        try await monitor(reminders, record)
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: record.id, dedupeKey: "calendar:1"),
            scheduleID: record.id,
            scheduledFor: Date().addingTimeInterval(-60),
            dedupeKey: "calendar:1")
        _ = try await schedules.enqueueOccurrence(occurrence)
        _ = try await schedules.claimOccurrence(id: occurrence.id, at: Date())
        _ = try await schedules.markOccurrenceRunning(
            id: occurrence.id, runID: UUID(), conversationID: UUID(), at: Date())

        // Remove the auxiliary table entirely: every core mutation must
        // still commit, and cleanup is simply lost (recoverable, not fatal).
        try await database.writer { db in
            try db.execute(sql: "DROP TABLE task_schedule_cleanup_reminders")
        }
        try await schedules.markStarted(id: record.id, at: Date())
        try await schedules.finishOccurrence(
            id: occurrence.id, state: .completed, summary: nil, errorText: nil, at: Date())
        try await schedules.delete(id: record.id)
        #expect(try await schedules.schedule(id: record.id) == nil)
        let settled = try #require(try await schedules.occurrence(id: occurrence.id))
        #expect(settled.state == .completed)
        do {
            _ = try await reminders.openReminders()
            Issue.record("reads fail honestly while the table is absent")
        } catch {
            // expected — the UI layer treats this as an empty, retryable state
        }
    }

    @Test("A malformed reminder row is skipped without blanking the list")
    func malformedRowSkipped() async throws {
        let (database, schedules, reminders) = try makeStores()
        try await database.writer { db in
            // CHECK-valid values but an unparseable UUID column: only a
            // decode-level failure can exercise the quiet-skip path.
            try db.execute(sql: """
                INSERT INTO task_schedule_cleanup_reminders (
                    id, schedule_id, title, reason, status, setup_source, setup_at,
                    created_at, updated_at, last_seen_at
                ) VALUES ('not-a-uuid', 'not-a-uuid-either', 'X', 'deleted', 'open',
                          NULL, NULL, '1', '1', '1')
                """)
        }
        let record = try await makeSchedule(schedules, title: "Real")
        try await monitor(reminders, record)
        try await schedules.delete(id: record.id)
        let list = try await reminders.openReminders()
        #expect(list.count == 1)
        #expect(list.first?.title == "Real")
    }

    // MARK: Re-arm epoch (historical-run false positives closed)

    /// Deterministic launch: enqueue → claim → running → `markStarted` at
    /// `startedAt`; optionally settle the bound occurrence at `finishedAt`.
    private func launch(
        _ schedules: SQLiteTaskScheduleStore,
        scheduleID: UUID,
        key: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        state: TaskScheduleOccurrenceState = .completed
    ) async throws {
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: scheduleID, dedupeKey: key),
            scheduleID: scheduleID,
            scheduledFor: startedAt.addingTimeInterval(-1),
            dedupeKey: key)
        _ = try await schedules.enqueueOccurrence(occurrence)
        _ = try await schedules.claimOccurrence(id: occurrence.id, at: startedAt)
        _ = try await schedules.markOccurrenceRunning(
            id: occurrence.id, runID: UUID(), conversationID: UUID(), at: startedAt)
        try await schedules.markStarted(id: scheduleID, at: startedAt)
        if let finishedAt {
            try await schedules.finishOccurrence(
                id: occurrence.id, state: state, summary: nil, errorText: nil, at: finishedAt)
        }
    }

    @Test("Re-enabling a consumed one-shot silences the old event; a reversible pause never reminds")
    func reEnabledOncePauseNeverReminds() async throws {
        let (database, schedules, reminders) = try makeStores()
        let base = Date()
        let record = try await makeSchedule(schedules, title: "Rearm once", cadence: .once)
        try await reminders.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .importFlowOpened, at: base)
        // Round one genuinely finishes: the onceConsumed reminder opens.
        try await launch(
            schedules, scheduleID: record.id, key: "calendar:1",
            startedAt: base.addingTimeInterval(60),
            finishedAt: base.addingTimeInterval(90))
        let first = try await reminders.openReminders()
        #expect(first.count == 1)
        #expect(first.first?.reason == .onceConsumed)

        // The SAME one-shot is re-enabled for another run: its old-event
        // evidence returns to silent monitoring for the new lifecycle…
        try await schedules.setEnabled(
            id: record.id, enabled: true, at: base.addingTimeInterval(120))
        let monitoring = try #require(try await reminders.reminder(scheduleID: record.id))
        #expect(monitoring.status == .monitoring)
        #expect(monitoring.reason == nil)
        // …and then reversibly paused. The OLD run's last_started_at must
        // not consume this round: reconcile opens nothing, list stays empty.
        try await schedules.setEnabled(
            id: record.id, enabled: false, at: base.addingTimeInterval(180))
        let paused = try #require(try await schedules.schedule(id: record.id))
        #expect(!paused.isEnabled)
        // History preserved: the old launch is still stored, not cleared.
        #expect(paused.lastStartedAt.map {
            abs($0.timeIntervalSince(base.addingTimeInterval(60))) < 1
        } == true)
        #expect(try await reminders.reconcileMonitoring() == 0)
        #expect(try await reminders.openReminders().isEmpty)

        // A genuine NEW run of the re-armed round still opens exactly once.
        try await schedules.setEnabled(
            id: record.id, enabled: true, at: base.addingTimeInterval(210))
        try await launch(
            schedules, scheduleID: record.id, key: "calendar:2",
            startedAt: base.addingTimeInterval(240),
            finishedAt: base.addingTimeInterval(270))
        let second = try await reminders.openReminders()
        #expect(second.count == 1)
        #expect(second.first?.reason == .onceConsumed)
        #expect(second.first?.id == first.first?.id)
        // Safety-net passes on the opened row add nothing further.
        #expect(try await reminders.reconcileMonitoring() == 0)
        #expect(try await reminders.openReminders().count == 1)
        _ = database
    }

    @Test("A fresh handoff after an old terminal is not consumed by historical evidence")
    func freshHandoffAfterTerminalIsNotConsumedByHistory() async throws {
        let (database, schedules, reminders) = try makeStores()
        let base = Date()
        let record = try await makeSchedule(schedules, title: "Handoff twice", cadence: .once)
        try await reminders.recordSetup(
            scheduleID: record.id, title: record.title, source: .userConfirmed, at: base)
        try await launch(
            schedules, scheduleID: record.id, key: "calendar:1",
            startedAt: base.addingTimeInterval(60),
            finishedAt: base.addingTimeInterval(90))
        #expect(try await reminders.openReminders().count == 1)

        // A NEW actual handoff restarts the round; the plan still carries
        // the old run's history. Reconciliation must NOT consume the fresh
        // monitoring row from that historical evidence.
        try await reminders.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .handedOffToUser, at: base.addingTimeInterval(120))
        let monitoring = try #require(try await reminders.reminder(scheduleID: record.id))
        #expect(monitoring.status == .monitoring)
        #expect(monitoring.reason == nil)
        #expect(try await reminders.reconcileMonitoring() == 0)
        #expect(try await reminders.openReminders().isEmpty)

        // Re-enable + pause inside the fresh round: still silent.
        try await schedules.setEnabled(
            id: record.id, enabled: true, at: base.addingTimeInterval(150))
        try await schedules.setEnabled(
            id: record.id, enabled: false, at: base.addingTimeInterval(160))
        #expect(try await reminders.reconcileMonitoring() == 0)
        #expect(try await reminders.openReminders().isEmpty)

        // The genuinely new terminal still opens exactly once.
        try await schedules.setEnabled(
            id: record.id, enabled: true, at: base.addingTimeInterval(180))
        try await launch(
            schedules, scheduleID: record.id, key: "calendar:2",
            startedAt: base.addingTimeInterval(240),
            finishedAt: base.addingTimeInterval(270))
        let list = try await reminders.openReminders()
        #expect(list.count == 1)
        #expect(list.first?.reason == .onceConsumed)
        _ = database
    }

    @Test("Re-arm after a lost terminal write stays silent across a pause; a new launch still reconciles open")
    func lostTerminalWriteThenRearmStaysSilent() async throws {
        let (database, schedules, reminders) = try makeStores()
        let base = Date()
        let record = try await makeSchedule(schedules, title: "Crash window", cadence: .once)
        try await reminders.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .importFlowOpened, at: base)
        // The launch happened; the terminal open write is lost (no bound
        // occurrence settles — the same crash window the reconciliation
        // safety net exists for).
        try await schedules.markStarted(id: record.id, at: base.addingTimeInterval(60))
        // BEFORE the next foreground reconcile, the user re-enables for
        // another run and pauses again: the safety net must read the old
        // launch against the NEW epoch and open nothing.
        try await schedules.setEnabled(
            id: record.id, enabled: true, at: base.addingTimeInterval(90))
        try await schedules.setEnabled(
            id: record.id, enabled: false, at: base.addingTimeInterval(120))
        #expect(try await reminders.reconcileMonitoring() == 0)
        #expect(try await reminders.openReminders().isEmpty)
        // The new round actually starts: the safety net opens exactly once.
        try await schedules.setEnabled(
            id: record.id, enabled: true, at: base.addingTimeInterval(150))
        try await schedules.markStarted(id: record.id, at: base.addingTimeInterval(180))
        #expect(try await reminders.reconcileMonitoring() == 1)
        let list = try await reminders.openReminders()
        #expect(list.count == 1)
        #expect(list.first?.reason == .onceConsumed)
        _ = database
    }

    @Test("Re-arm creates nothing for a never-setup plan (enable toggle and edit upsert)")
    func reArmNeverRecordsUnmonitoredPlans() async throws {
        let (database, schedules, reminders) = try makeStores()
        let base = Date()
        let record = try await makeSchedule(schedules, title: "Never monitored", cadence: .once)
        try await schedules.setEnabled(id: record.id, enabled: false, at: base)
        // An edit upsert that re-enables the plan (Home sheet / the Apple
        // automation tools save through here) must also record nothing.
        var reEnabled = try #require(try await schedules.schedule(id: record.id))
        reEnabled.isEnabled = true
        reEnabled.updatedAt = base.addingTimeInterval(30)
        try await schedules.save(reEnabled)
        try await schedules.setEnabled(
            id: record.id, enabled: true, at: base.addingTimeInterval(60))
        try await schedules.setEnabled(
            id: record.id, enabled: false, at: base.addingTimeInterval(90))
        #expect(try await reminders.reconcileMonitoring() == 0)
        #expect(try await reminders.reminder(scheduleID: record.id) == nil)
        // And the later delete stays silent too (setup gate intact).
        try await schedules.delete(id: record.id)
        #expect(try await reminders.reminder(scheduleID: record.id) == nil)
        #expect(try await reminders.openReminders().isEmpty)
        _ = database
    }

    @Test("Re-arm keeps a resolved mark intact and survives a missing reminders table")
    func reArmRespectsResolvedRowsAndMissingTable() async throws {
        let (database, schedules, reminders) = try makeStores()
        let base = Date()
        let record = try await makeSchedule(schedules, title: "Dismissed round", cadence: .once)
        try await reminders.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .importFlowOpened, at: base)
        try await launch(
            schedules, scheduleID: record.id, key: "calendar:1",
            startedAt: base.addingTimeInterval(60),
            finishedAt: base.addingTimeInterval(90))
        let open = try await reminders.openReminders()
        #expect(open.count == 1)
        try await reminders.dismiss(id: try #require(open.first).id)

        // Re-enabling does NOT rewrite the user's dismissed mark…
        try await schedules.setEnabled(
            id: record.id, enabled: true, at: base.addingTimeInterval(120))
        let resolved = try #require(try await reminders.reminder(scheduleID: record.id))
        #expect(resolved.status == .dismissed)
        #expect(resolved.reason == .onceConsumed)
        // …and a new terminal without a fresh handoff stays silent (only an
        // actual setup starts a new round against resolved evidence).
        try await launch(
            schedules, scheduleID: record.id, key: "calendar:2",
            startedAt: base.addingTimeInterval(180),
            finishedAt: base.addingTimeInterval(210))
        #expect(try await reminders.openReminders().isEmpty)

        // Re-arm hooks are best-effort like every other reminder write:
        // with the auxiliary table gone, enable and edit-upsert re-arms
        // still COMMIT core schedule state.
        try await database.writer { db in
            try db.execute(sql: "DROP TABLE task_schedule_cleanup_reminders")
        }
        try await schedules.setEnabled(
            id: record.id, enabled: true, at: base.addingTimeInterval(240))
        var live = try #require(try await schedules.schedule(id: record.id))
        #expect(live.isEnabled)
        live.isEnabled = false
        live.updatedAt = base.addingTimeInterval(270)
        try await schedules.save(live)
        live.isEnabled = true
        live.updatedAt = base.addingTimeInterval(300)
        // disabled→enabled upsert: the re-arm auxiliary write throws and is
        // swallowed; the upsert itself must still land.
        try await schedules.save(live)
        live = try #require(try await schedules.schedule(id: record.id))
        #expect(live.isEnabled)
        // Historical launch evidence survives every re-arm and pause.
        #expect(live.lastStartedAt != nil)
        _ = database
    }
}
