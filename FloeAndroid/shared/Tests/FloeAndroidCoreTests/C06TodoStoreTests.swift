// SPDX-License-Identifier: MPL-2.0
//
// C06 App-local todo store/domain tests. Authored source; NOT RUN by this
// lane. The store tests use the REAL file-backed GRDB DatabaseManager and the
// exact declarative table SQL; only the reminder transport is a spy.

import Foundation
import XCTest
import GRDB
import FloeCore
import FloePersistence
@testable import FloeAndroidCore

private actor FakeTodoReminderPort: C06TodoReminderPort {
    var armed: [String: C06TodoPlan] = [:]
    var disarmed: [String] = []
    var shown: [(String, String)] = []
    var armResult = C06TodoReminderArmResult(scheduled: true, state: "scheduled")

    func setArmResult(_ value: C06TodoReminderArmResult) { armResult = value }

    func arm(plan: C06TodoPlan, owner: C06TodoOwner) async throws -> C06TodoReminderArmResult {
        armed[plan.todoID.uuidString.lowercased()] = plan
        return armResult
    }

    func disarm(todoID: UUID, owner: C06TodoOwner) async throws {
        disarmed.append(todoID.uuidString.lowercased())
        armed.removeValue(forKey: todoID.uuidString.lowercased())
    }

    func noteReminderShown(todoID: UUID, occurrenceKey: String, epoch: UInt64) async {
        shown.append((todoID.uuidString.lowercased(), occurrenceKey))
    }
}

private struct TodoTestHarness {
    let directory: URL
    let databaseURL: URL
    let database: DatabaseManager
    let store: C06TodoStore
}

final class C06TodoStoreTests: XCTestCase {
    private var harnesses: [TodoTestHarness] = []

    override func tearDown() {
        for harness in harnesses {
            try? FileManager.default.removeItem(at: harness.directory)
        }
        harnesses = []
        super.tearDown()
    }

    private func makeHarness() async throws -> TodoTestHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-c06-todo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("db.sqlite")
        let database = try DatabaseManager(path: url)
        try await database.writer { db in
            try db.execute(sql: C06TodoSchema.createTableSQL)
            for index in C06TodoSchema.indexesSQL {
                try db.execute(sql: index)
            }
        }
        let harness = TodoTestHarness(
            directory: directory,
            databaseURL: url,
            database: database,
            store: C06TodoStore(database: database)
        )
        harnesses.append(harness)
        return harness
    }

    private func owner(
        conversation: UUID? = nil,
        token: String = "test.todo.owner"
    ) throws -> C06TodoOwner {
        try C06TodoOwner(
            token: token,
            nativeEpoch: 1,
            conversationID: conversation,
            taskID: conversation
        )
    }

    private func date(_ raw: String) throws -> Date {
        try C06CalendarDate.parseISO8601(raw)
    }

    func testInsertListGetAndPersistenceAcrossManagerReopen() async throws {
        let harness = try await makeHarness()
        let due = try date("2026-11-02T09:00:00+11:00")
        let record = C06TodoRecord(
            title: "Buy milk",
            notes: "Two litres",
            dueAt: due,
            dueTimeZone: "Australia/Sydney",
            recurrence: C06TodoRecurrence(kind: .daily, interval: 1),
            reminderMinutesBefore: 15,
            ownerConversationID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")
        )
        try await harness.store.insert(record)
        let fetched = try await harness.store.get(id: record.id)
        XCTAssertEqual(fetched?.title, "Buy milk")
        XCTAssertEqual(fetched?.revision, 1)
        XCTAssertEqual(fetched?.reminderMinutesBefore, 15)
        let (rows, total) = try await harness.store.list(includeCompleted: false, limit: 10, offset: 0)
        XCTAssertEqual(total, 1)
        XCTAssertEqual(rows.first?.id, record.id)

        let reopened = try DatabaseManager(path: harness.databaseURL)
        let store = C06TodoStore(database: reopened)
        let again = try await store.get(id: record.id)
        XCTAssertEqual(again?.title, "Buy milk")
        XCTAssertEqual(again?.ownerConversationID, record.ownerConversationID)
    }

    func testRevisionCasRejectsStaleDraftAndStrictlyAdvances() async throws {
        let harness = try await makeHarness()
        var record = C06TodoRecord(title: "Draft")
        try await harness.store.insert(record)
        record.title = "First edit"
        let updated = try await harness.store.updateCAS(record, expectedRevision: 1)
        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.title, "First edit")

        record.title = "Stale overwrite"
        do {
            _ = try await harness.store.updateCAS(record, expectedRevision: 1)
            XCTFail("stale CAS must be refused")
        } catch let error as C06TodoError {
            XCTAssertEqual(error.code, .revisionConflict)
        }
        let current = try await harness.store.get(id: record.id)
        XCTAssertEqual(current?.title, "First edit")
        XCTAssertEqual(current?.revision, 2)
    }

    func testCompleteReopenAndDeleteAreCasOwned() async throws {
        let harness = try await makeHarness()
        let record = C06TodoRecord(title: "Finish", dueAt: try date("2026-11-05T09:00:00Z"))
        try await harness.store.insert(record)
        let completed = try await harness.store.completeCAS(
            id: record.id, expectedRevision: 1, completed: true, at: Date()
        )
        XCTAssertTrue(completed.completed)
        XCTAssertEqual(completed.revision, 2)
        do {
            _ = try await harness.store.completeCAS(
                id: record.id, expectedRevision: 1, completed: false, at: Date()
            )
            XCTFail("stale complete must be refused")
        } catch let error as C06TodoError {
            XCTAssertEqual(error.code, .revisionConflict)
        }
        let reopened = try await harness.store.completeCAS(
            id: record.id, expectedRevision: 2, completed: false, at: Date()
        )
        XCTAssertFalse(reopened.completed)
        XCTAssertNil(reopened.completedAt)
        do {
            try await harness.store.deleteCAS(id: record.id, expectedRevision: 2)
            XCTFail("stale delete must be refused")
        } catch let error as C06TodoError {
            XCTAssertEqual(error.code, .revisionConflict)
        }
        try await harness.store.deleteCAS(id: record.id, expectedRevision: 3)
        let afterDelete = try await harness.store.get(id: record.id)
        XCTAssertNil(afterDelete)
    }

    func testMarkReminderShownIsIdempotentPerOccurrence() async throws {
        let harness = try await makeHarness()
        let record = C06TodoRecord(
            title: "Reminder",
            dueAt: try date("2026-11-02T09:00:00Z"),
            reminderMinutesBefore: 0
        )
        try await harness.store.insert(record)
        let first = try await harness.store.markReminderShown(
            id: record.id, occurrenceKey: "2026-11-02T09:00:00Z", at: Date()
        )
        let second = try await harness.store.markReminderShown(
            id: record.id, occurrenceKey: "2026-11-02T09:00:00Z", at: Date()
        )
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let stored = try await harness.store.get(id: record.id)
        XCTAssertEqual(stored?.lastReminderOccurrence, "2026-11-02T09:00:00Z")
    }

    func testDailyRecurrencePreservesWallClockAcrossDst() throws {
        let due = try date("2026-10-31T09:00:00-04:00")
        let record = C06TodoRecord(
            title: "DST",
            dueAt: due,
            dueTimeZone: "America/New_York",
            recurrence: C06TodoRecurrence(kind: .daily, interval: 1),
            reminderMinutesBefore: 0
        )
        let plan = C06TodoPlanner.plan(record: record, now: due.addingTimeInterval(3_600))
        XCTAssertEqual(C06CalendarDate.iso8601(plan?.dueAt ?? Date(timeIntervalSince1970: 0)),
                       "2026-11-01T14:00:00Z")
    }

    func testAllDayDailyRecurrenceStaysUtcMidnight() throws {
        let due = try date("2026-03-07T00:00:00Z")
        let record = C06TodoRecord(
            title: "All day",
            dueAt: due,
            dueTimeZone: "UTC",
            allDay: true,
            recurrence: C06TodoRecurrence(kind: .daily, interval: 1),
            reminderMinutesBefore: 0
        )
        let plan = C06TodoPlanner.plan(record: record, now: due.addingTimeInterval(90_000))
        XCTAssertEqual(C06CalendarDate.iso8601(plan?.dueAt ?? Date(timeIntervalSince1970: 0)),
                       "2026-03-08T00:00:00Z")
        XCTAssertTrue(C06CalendarDomain.isUTCMidnight(plan?.dueAt ?? Date()))
    }

    func testReminderPlansRollForwardAndStopAtUntil() throws {
        let due = try date("2026-11-02T09:00:00Z")
        var record = C06TodoRecord(
            title: "Roll",
            dueAt: due,
            dueTimeZone: "UTC",
            recurrence: C06TodoRecurrence(kind: .daily, interval: 1),
            reminderMinutesBefore: 10
        )
        let plan = C06TodoPlanner.plan(record: record, now: due.addingTimeInterval(86_400))
        XCTAssertEqual(plan?.occurrenceKey, "2026-11-03T09:00:00Z")
        let expectedReminder = try date("2026-11-03T08:50:00Z")
        XCTAssertEqual(plan?.reminderAt, expectedReminder)

        record.recurrence.until = try date("2026-11-02T23:00:00Z")
        XCTAssertNil(C06TodoPlanner.plan(record: record, now: due.addingTimeInterval(86_400)))

        var oneShot = C06TodoRecord(
            title: "Once", dueAt: due, dueTimeZone: "UTC", reminderMinutesBefore: 0
        )
        XCTAssertNil(C06TodoPlanner.plan(record: oneShot, now: due.addingTimeInterval(1)))
        oneShot.completed = true
        XCTAssertNil(C06TodoPlanner.plan(record: oneShot, now: due.addingTimeInterval(-60)))
    }

    func testTodoSchemaHasNoConversationCascade() async throws {
        let harness = try await makeHarness()
        XCTAssertFalse(C06TodoSchema.createTableSQL.uppercased().contains("REFERENCES"))
        XCTAssertFalse(C06TodoSchema.createTableSQL.uppercased().contains("FOREIGN KEY"))
        try await harness.database.writer { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS tasks_fixture (id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO tasks_fixture (id) VALUES ('task-1')")
        }
        let record = C06TodoRecord(
            title: "Independent",
            ownerConversationID: UUID(uuidString: "11111111-2222-4333-8444-555555555555"),
            ownerTaskID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")
        )
        try await harness.store.insert(record)
        try await harness.database.writer { db in
            try db.execute(sql: "DELETE FROM tasks_fixture")
        }
        let stored = try await harness.store.get(id: record.id)
        XCTAssertEqual(stored?.ownerConversationID, record.ownerConversationID)
        XCTAssertEqual(stored?.ownerTaskID, record.ownerTaskID)
    }

    func testDomainSaveArmDisarmAndConflict() async throws {
        let harness = try await makeHarness()
        let reminders = FakeTodoReminderPort()
        let fixedNow = try date("2026-11-02T08:00:00Z")
        let store = harness.store
        let domain = C06TodoDomain(
            store: { _ in store },
            reminders: reminders,
            readiness: { (true, 1) },
            now: { fixedNow }
        )
        let due = try date("2026-11-02T09:00:00Z")
        let saved = try await domain.save(
            owner: try owner(),
            id: nil,
            expectedRevision: nil,
            title: "Domain",
            notes: "",
            dueAt: due,
            allDay: false,
            timeZone: "UTC",
            recurrence: C06TodoRecurrence(kind: .none),
            reminderMinutesBefore: 15
        )
        XCTAssertEqual(saved.record.revision, 1)
        XCTAssertTrue(saved.reminder.scheduled)
        let armed = await reminders.armed
        XCTAssertTrue(armed.keys.contains(saved.record.id.uuidString.lowercased()))

        do {
            _ = try await domain.save(
                owner: try owner(),
                id: saved.record.id,
                expectedRevision: 99,
                title: "Stale",
                notes: "",
                dueAt: due,
                allDay: false,
                timeZone: "UTC",
                recurrence: C06TodoRecurrence(kind: .none),
                reminderMinutesBefore: nil
            )
            XCTFail("domain must surface the store revision conflict")
        } catch let error as C06TodoError {
            XCTAssertEqual(error.code, .revisionConflict)
        }

        let completed = try await domain.complete(
            owner: try owner(),
            id: saved.record.id,
            expectedRevision: 1,
            completed: true
        )
        XCTAssertTrue(completed.record.completed)
        let disarmed = await reminders.disarmed
        XCTAssertTrue(disarmed.contains(saved.record.id.uuidString.lowercased()))

        _ = try await domain.save(
            owner: try owner(),
            id: saved.record.id,
            expectedRevision: 2,
            title: "Reopened",
            notes: "",
            dueAt: due,
            allDay: false,
            timeZone: "UTC",
            recurrence: C06TodoRecurrence(kind: .none),
            reminderMinutesBefore: nil
        )
        try await domain.delete(owner: try owner(), id: saved.record.id, expectedRevision: 3)
        let deleted = try await harness.store.get(id: saved.record.id)
        XCTAssertNil(deleted)
    }

    func testDomainValidatesReminderDueAndBounds() async throws {
        let harness = try await makeHarness()
        let reminders = FakeTodoReminderPort()
        let store = harness.store
        let domain = C06TodoDomain(
            store: { _ in store },
            reminders: reminders,
            readiness: { (true, 1) }
        )
        do {
            _ = try await domain.save(
                owner: try owner(), id: nil, expectedRevision: nil,
                title: "No due", notes: "", dueAt: nil, allDay: false,
                timeZone: "UTC", recurrence: C06TodoRecurrence(),
                reminderMinutesBefore: 5
            )
            XCTFail("reminder without due must fail")
        } catch let error as C06TodoError {
            XCTAssertEqual(error.code, .invalidDue)
        }
        do {
            _ = try await domain.save(
                owner: try owner(), id: nil, expectedRevision: nil,
                title: "   ", notes: "", dueAt: nil, allDay: false,
                timeZone: "UTC", recurrence: C06TodoRecurrence(),
                reminderMinutesBefore: nil
            )
            XCTFail("empty title must fail")
        } catch let error as C06TodoError {
            XCTAssertEqual(error.code, .invalidTitle)
        }
        do {
            _ = try await domain.save(
                owner: try owner(), id: nil, expectedRevision: nil,
                title: "Bad interval", notes: "", dueAt: try date("2026-11-02T09:00:00Z"),
                allDay: false, timeZone: "UTC",
                recurrence: C06TodoRecurrence(kind: .daily, interval: 0),
                reminderMinutesBefore: nil
            )
            XCTFail("zero interval must fail")
        } catch let error as C06TodoError {
            XCTAssertEqual(error.code, .invalidRecurrence)
        }
    }
}
