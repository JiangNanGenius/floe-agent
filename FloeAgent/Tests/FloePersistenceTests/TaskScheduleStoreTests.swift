import Foundation
import Testing
@testable import FloeModels
@testable import FloePersistence

@Suite("FloePersistence.TaskScheduleStore")
struct TaskScheduleStoreTests {
    @Test("One-time schedule becomes disabled after its actual start")
    func onceDisables() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteTaskScheduleStore(database: database)
        let dueAt = Date().addingTimeInterval(-60)
        let schedule = TaskScheduleRecord(
            title: "One time", prompt: "Do it", cadence: .once, scheduledAt: dueAt
        )
        try await store.save(schedule)
        #expect(try await store.due(at: Date()).map(\.id) == [schedule.id])

        let actual = Date()
        try await store.markStarted(id: schedule.id, at: actual)
        let saved = try #require(try await store.schedules().first)
        #expect(saved.isEnabled == false)
        #expect(saved.nextExpectedAt == nil)
        #expect(saved.lastStartedAt != nil)
    }

    @Test("Daily schedule advances from actual execution time")
    func dailyAdvances() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteTaskScheduleStore(database: database)
        let schedule = TaskScheduleRecord(
            title: "Daily", prompt: "Report", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-60)
        )
        try await store.save(schedule)
        let actual = Date()
        try await store.markStarted(id: schedule.id, at: actual)
        let saved = try #require(try await store.schedules().first)
        #expect(saved.isEnabled)
        #expect(abs((saved.nextExpectedAt?.timeIntervalSince(actual) ?? 0) - 86_400) < 5)
    }

    // MARK: - Occurrence ledger (selected-schedule execution route)

    private func makeStore() async throws -> (DatabaseManager, SQLiteTaskScheduleStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return (database, SQLiteTaskScheduleStore(database: database))
    }

    @Test("Materializing the same due occurrence twice keeps one row")
    func occurrenceMaterializationIsIdempotent() async throws {
        let (_, store) = try await makeStore()
        let schedule = TaskScheduleRecord(
            title: "Daily", prompt: "Report", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-120))
        try await store.save(schedule)
        let key = "day:2099-01-01"
        let id = TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: key)
        let occurrence = TaskScheduleOccurrence(
            id: id, scheduleID: schedule.id,
            scheduledFor: Date().addingTimeInterval(-60), dedupeKey: key)
        #expect(try await store.enqueueOccurrence(occurrence) == true)
        // A duplicate wakeup (second automation callback, overlapping pass)
        // addresses the SAME logical instance and must not insert a rival row.
        #expect(try await store.enqueueOccurrence(occurrence) == false)
        let rows = try await store.occurrences(scheduleID: schedule.id, limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.id == id)
        #expect(rows.first?.state == .pending)
    }

    @Test("Exactly one of two claim attempts wins the same occurrence")
    func claimIsAtomicExactlyOnce() async throws {
        let (_, store) = try await makeStore()
        let schedule = TaskScheduleRecord(
            title: "Once", prompt: "Do it", cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60))
        try await store.save(schedule)
        let id = TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: "once")
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: id, scheduleID: schedule.id,
            scheduledFor: schedule.scheduledAt, dedupeKey: "once"))
        let at = Date()
        #expect(try await store.claimOccurrence(id: id, at: at) == true)
        // The losing executor (duplicate callback or overlapping pass) sees
        // false and can never launch the same instance.
        #expect(try await store.claimOccurrence(id: id, at: at) == false)
        let row = try #require(try await store.occurrence(id: id))
        #expect(row.state == .claimed)
        #expect(row.claimedAt != nil)
    }

    @Test("A claimed occurrence binds one run and rejects a second binding")
    func runningBindingIsExclusive() async throws {
        let (_, store) = try await makeStore()
        let schedule = TaskScheduleRecord(
            title: "Once", prompt: "Do it", cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60))
        try await store.save(schedule)
        let id = TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: "once")
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: id, scheduleID: schedule.id,
            scheduledFor: schedule.scheduledAt, dedupeKey: "once"))
        try await store.claimOccurrence(id: id, at: Date())
        let runID = UUID(), conversationID = UUID()
        #expect(try await store.markOccurrenceRunning(
            id: id, runID: runID, conversationID: conversationID, at: Date()) == true)
        #expect(try await store.markOccurrenceRunning(
            id: id, runID: UUID(), conversationID: UUID(), at: Date()) == false)
        let row = try #require(try await store.occurrence(id: id))
        #expect(row.state == .running)
        #expect(row.runID == runID)
        #expect(row.conversationID == conversationID)
        // The run-reference readback names exactly this occurrence.
        #expect(try await store.occurrence(runID: runID)?.id == id)
    }

    @Test("Terminal settlement only reaches claimed or running rows")
    func finishRequiresClaim() async throws {
        let (_, store) = try await makeStore()
        let schedule = TaskScheduleRecord(
            title: "Once", prompt: "Do it", cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60))
        try await store.save(schedule)
        let id = TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: "once")
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: id, scheduleID: schedule.id,
            scheduledFor: schedule.scheduledAt, dedupeKey: "once"))
        // A pending row cannot be settled: nobody owns the decision yet.
        try await store.finishOccurrence(
            id: id, state: .failed, summary: nil,
            errorText: "must not land", at: Date())
        #expect(try await store.occurrence(id: id)?.state == .pending)
        try await store.claimOccurrence(id: id, at: Date())
        try await store.finishOccurrence(
            id: id, state: .cancelled, summary: nil,
            errorText: "disabled before launch", at: Date())
        let row = try #require(try await store.occurrence(id: id))
        #expect(row.state == .cancelled)
        #expect(row.errorText == "disabled before launch")
        #expect(row.finishedAt != nil)
    }

    @Test("A recordRunCompletion settles the owned occurrence and enqueues dependents once")
    func completionSettlesOwnerAndArmsDependentOnce() async throws {
        let (_, store) = try await makeStore()
        let upstreamRunID = UUID()
        let dependent = TaskScheduleRecord(
            title: "Chain", prompt: "Publish", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: upstreamRunID)
        try await store.save(dependent)
        // Two completion callbacks (replay) arm ONE logical instance.
        let first = try await store.recordRunCompletion(
            runID: upstreamRunID, succeeded: true, cancelled: false,
            summary: "upstream done", at: Date())
        let second = try await store.recordRunCompletion(
            runID: upstreamRunID, succeeded: true, cancelled: false,
            summary: "upstream done", at: Date())
        #expect(first.count == 1)
        #expect(second.isEmpty)
        let armed = try #require(try await store.occurrence(id: first[0]))
        #expect(armed.state == .pending)
        #expect(armed.dedupeKey == "upstream:\(upstreamRunID.uuidString)")
    }

    @Test("Reconcile interrupts claimed and running rows from a dead process")
    func reconcileInterruptsInFlightRows() async throws {
        let (_, store) = try await makeStore()
        let schedule = TaskScheduleRecord(
            title: "Once", prompt: "Do it", cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60))
        try await store.save(schedule)
        let id = TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: "once")
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: id, scheduleID: schedule.id,
            scheduledFor: schedule.scheduledAt, dedupeKey: "once"))
        try await store.claimOccurrence(id: id, at: Date())
        #expect(try await store.reconcileInterruptedOccurrences(at: Date()) == 1)
        let row = try #require(try await store.occurrence(id: id))
        #expect(row.state == .interrupted)
        #expect(row.errorText != nil)
    }
}
