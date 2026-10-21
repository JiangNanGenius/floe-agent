// Focused tests for the selected-schedule action's cleanup evidence hook.
//
// The action keeps the ONE stable identity route — the picked
// `TaskScheduleEntity` (the signed shared template personalizes the SAME
// entity through the system's import question; measured in the iPadOS 27
// automation editor). These tests pin:
//   • the typed deleted-plan refusal copy is byte-identical to the existing
//     route (FloeShortcutRunIntentTests is the sibling regression gate);
//   • a fire for a missing schedule best-effort records durable evidence
//     under the ORIGINAL stable UUID (creating a row even when the old app
//     never recorded a setup; dedupe into an existing open row; a user
//     "removed" mark only reopens on fresh fire evidence);
//   • routing is by UUID, never by title: a same-title plan created AFTER
//     the original was deleted is never touched by the stale fire;
//   • the DEBUG host without an injected environment performs NO recording
//     and NO environment access at all (zero side effects — existing
//     hosted failure-copy tests are unaffected).
//
// Same DEBUG task-local seams as the existing intent tests: no launched
// App, no real Shortcuts execution, compiled out of Release.

#if canImport(AppIntents) && DEBUG
import AppIntents
import XCTest
@testable import FloeApp
import FloeCore
import FloeModels
import FloePersistence

final class FloeScheduledTaskStaleTriggerIntentTests: XCTestCase {

    @MainActor
    private func makeEnvironment() async throws -> AppEnvironment {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        return environment
    }

    @MainActor
    private func save(_ environment: AppEnvironment,
                      title: String,
                      cadence: TaskScheduleCadence = .daily,
                      enabled: Bool = true) async throws -> TaskScheduleRecord {
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let record = TaskScheduleRecord(
            title: title, prompt: "p", cadence: cadence,
            scheduledAt: Date().addingTimeInterval(-60), isEnabled: enabled)
        try await store.save(record)
        return record
    }

    @MainActor
    private func performDeleted(_ intent: RunScheduledTaskIntent,
                                environment: AppEnvironment?) async -> Error? {
        var thrown: Error?
        let route: @MainActor (UUID) async throws ->
            BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt = { _ in
            throw BackgroundRunCoordinator.FloeSelectedScheduleFailure.scheduleDeleted
        }
        var intent = intent
        do {
            _ = try await RunScheduledTaskIntent.$debugRoute.withValue(route) {
                try await RunScheduledTaskIntent.$debugEnvironment.withValue(environment) {
                    try await intent.perform()
                }
            }
        } catch {
            thrown = error
        }
        return thrown
    }

    // MARK: Refusal + evidence

    @MainActor
    func testDeletedEntityKeepsTypedRefusalAndRecordsEvidence() async throws {
        let environment = try await makeEnvironment()
        let store = TaskScheduleCleanupReminderStore(database: environment.database)
        let record = try await save(environment, title: "Morning report")
        // The app DID record the handoff: the delete already opened 'deleted'.
        try await store.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .importFlowOpened, at: Date())
        try await SQLiteTaskScheduleStore(database: environment.database)
            .delete(id: record.id)

        var intent = RunScheduledTaskIntent()
        intent.schedule = TaskScheduleEntity(id: record.id, title: "Morning report")
        let error = await performDeleted(intent, environment: environment)
        let actionError = try XCTUnwrap(error as? FloeShortcutActionError)
        XCTAssertEqual(actionError.message,
                       FloeL10n.l("shortcuts.schedule.run.error.not_found"))

        // Dedupe: the lingering fire does NOT add a second row or rewrite
        // the first reason — it only advances last-seen evidence.
        let open = try await store.openReminders()
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.scheduleID, record.id)
        XCTAssertEqual(open.first?.reason, .deleted)
    }

    @MainActor
    func testStaleFireForNeverMonitoredPlanCreatesReminder() async throws {
        let environment = try await makeEnvironment()
        let store = TaskScheduleCleanupReminderStore(database: environment.database)
        let record = try await save(environment, title: "Legacy plan")
        try await SQLiteTaskScheduleStore(database: environment.database)
            .delete(id: record.id)
        let beforeFire = try await store.openReminders()
        XCTAssertTrue(beforeFire.isEmpty)

        var intent = RunScheduledTaskIntent()
        intent.schedule = TaskScheduleEntity(id: record.id, title: "Legacy plan")
        _ = await performDeleted(intent, environment: environment)

        let open = try await store.openReminders()
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.reason, .staleTrigger)
        XCTAssertEqual(open.first?.title, "Legacy plan")
    }

    @MainActor
    func testStaleFireIsUUIDRoutedAndNeverTouchesSameTitlePlan() async throws {
        let environment = try await makeEnvironment()
        let store = TaskScheduleCleanupReminderStore(database: environment.database)
        let schedules = SQLiteTaskScheduleStore(database: environment.database)
        let old = try await save(environment, title: "Standup note")
        try await schedules.delete(id: old.id)
        // A NEW plan later gets the exact same title (the failure mode a
        // name route would silently re-point the old trigger at).
        let fresh = try await save(environment, title: "Standup note")

        var captured: UUID?
        var intent = RunScheduledTaskIntent()
        intent.schedule = TaskScheduleEntity(id: old.id, title: "Standup note")
        let route: @MainActor (UUID) async throws ->
            BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt = { id in
            captured = id
            throw BackgroundRunCoordinator.FloeSelectedScheduleFailure.scheduleDeleted
        }
        do {
            _ = try await RunScheduledTaskIntent.$debugRoute.withValue(route) {
                try await RunScheduledTaskIntent.$debugEnvironment.withValue(environment) {
                    try await intent.perform()
                }
            }
            XCTFail("the deleted schedule must be refused")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message,
                           FloeL10n.l("shortcuts.schedule.run.error.not_found"))
        }
        // Routing used the ORIGINAL stable UUID, and only that identity
        // produced evidence; the same-title plan stays enabled, unlaunched
        // and reminder-free.
        XCTAssertEqual(captured, old.id)
        let open = try await store.openReminders()
        XCTAssertEqual(open.map(\.scheduleID), [old.id])
        let afterOpt = try await schedules.schedule(id: fresh.id)
        let after = try XCTUnwrap(afterOpt)
        XCTAssertTrue(after.isEnabled)
        let freshRow = try await store.reminder(scheduleID: fresh.id)
        XCTAssertNil(freshRow)
    }

    @MainActor
    func testDebugHostWithoutEnvironmentRecordsNothingAndAccessesNothing() async throws {
        let environment = try await makeEnvironment()
        let store = TaskScheduleCleanupReminderStore(database: environment.database)
        let record = try await save(environment, title: "Protected")
        try await store.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .userConfirmed, at: Date())
        try await SQLiteTaskScheduleStore(database: environment.database)
            .delete(id: record.id)
        let openBefore = try await store.openReminders()
        let before = try XCTUnwrap(openBefore.first)

        var intent = RunScheduledTaskIntent()
        intent.schedule = TaskScheduleEntity(id: record.id, title: "Protected")
        // NO debugEnvironment injected (same shape as the existing hosted
        // failure-copy tests): the stale hook must skip entirely.
        let error = await performDeleted(intent, environment: nil)
        let actionError = try XCTUnwrap(error as? FloeShortcutActionError)
        XCTAssertEqual(actionError.message,
                       FloeL10n.l("shortcuts.schedule.run.error.not_found"))

        let afterRowOpt = try await store.reminder(id: before.id)
        let afterRow = try XCTUnwrap(afterRowOpt)
        XCTAssertEqual(afterRow.lastSeenAt, before.lastSeenAt,
                       "un-injected DEBUG hosts must perform zero recording")
    }

    @MainActor
    func testFreshFireReopensUserRemovedReminder() async throws {
        let environment = try await makeEnvironment()
        let store = TaskScheduleCleanupReminderStore(database: environment.database)
        let record = try await save(environment, title: "Reopened")
        try await store.recordSetup(
            scheduleID: record.id, title: record.title,
            source: .importFlowOpened, at: Date())
        try await SQLiteTaskScheduleStore(database: environment.database)
            .delete(id: record.id)
        let openList = try await store.openReminders()
        let id = try XCTUnwrap(openList.first?.id)
        try await store.markRemoved(id: id)
        let emptyList = try await store.openReminders()
        XCTAssertTrue(emptyList.isEmpty)

        var intent = RunScheduledTaskIntent()
        intent.schedule = TaskScheduleEntity(id: record.id, title: "Reopened")
        _ = await performDeleted(intent, environment: environment)

        // The fire itself disproves the "removed" claim: honest reopen.
        let open = try await store.openReminders()
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.reason, .staleTrigger)
    }
}
#endif
