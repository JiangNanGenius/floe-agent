import Foundation
import Testing
import GRDB
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


    // MARK: - Presentation / manual / skip (v57)

    @Test("The origin conversation round-trips and unbound rows stay unbound")
    func originBindingRoundTrip() async throws {
        let (_, store) = try await makeStore()
        let conversationID = UUID()
        let bound = TaskScheduleRecord(
            title: "Bound", prompt: "Report", cadence: .daily,
            scheduledAt: Date(), originConversationID: conversationID)
        try await store.save(bound)
        let read = try #require(try await store.schedule(id: bound.id))
        #expect(read.originConversationID == conversationID)
        // An explicit nil (pre-v57/Home-created) is preserved, never inferred
        // from a title or a later occurrence.
        let unbound = TaskScheduleRecord(
            title: "Unbound", prompt: "Report", cadence: .daily, scheduledAt: Date())
        try await store.save(unbound)
        #expect(try await store.schedule(id: unbound.id)?.originConversationID == nil)
    }

    @Test("Linked schedules use the trusted origin or the actual occurrence conversation")
    func schedulesLinkedByOriginOrLedger() async throws {
        let (_, store) = try await makeStore()
        let conversationID = UUID()
        let originBound = TaskScheduleRecord(
            title: "季度总结", prompt: "Report", cadence: .daily,
            scheduledAt: Date(), originConversationID: conversationID)
        let titleOnlyLookalike = TaskScheduleRecord(
            title: "季度总结", prompt: "Report", cadence: .daily, scheduledAt: Date())
        try await store.save(originBound)
        try await store.save(titleOnlyLookalike)

        var linked = try await store.schedulesLinked(to: conversationID)
        #expect(linked.map(\.id) == [originBound.id])
        // A matching title alone never links.
        #expect(linked.contains(where: { $0.id == titleOnlyLookalike.id }) == false)

        // A conversation CREATED by an occurrence resolves through the real
        // ledger even when the plan itself has no origin binding.
        let occurrenceConversation = UUID()
        let occurrenceID = TaskScheduleOccurrence.stableID(
            scheduleID: titleOnlyLookalike.id, dedupeKey: "day:2026-10-30")
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: occurrenceID, scheduleID: titleOnlyLookalike.id,
            scheduledFor: Date(), dedupeKey: "day:2026-10-30"))
        try await store.claimOccurrence(id: occurrenceID, at: Date())
        try await store.markOccurrenceRunning(
            id: occurrenceID, runID: UUID(), conversationID: occurrenceConversation, at: Date())
        linked = try await store.schedulesLinked(to: occurrenceConversation)
        #expect(linked.map(\.id) == [titleOnlyLookalike.id])
        #expect(try await store.schedulesLinked(to: UUID()).isEmpty)
    }

    @Test("Skip next records one stable skipped occurrence and advances a recurring plan")
    func skipNextRecurring() async throws {
        let (_, store) = try await makeStore()
        let anchor = Date().addingTimeInterval(-3_600)
        let schedule = TaskScheduleRecord(
            title: "Daily", prompt: "Report", cadence: .daily,
            scheduledAt: anchor, anchorTimezone: "UTC")
        try await store.save(schedule)

        let first = try #require(try await store.skipNext(id: schedule.id, at: Date()))
        #expect(first.planDisabled == false)
        #expect(first.nextExpectedAt != nil)
        let firstOccurrence = try #require(try await store.occurrence(id: first.skippedOccurrenceID))
        #expect(firstOccurrence.state == .skipped)
        #expect(firstOccurrence.runID == nil)
        var saved = try #require(try await store.schedule(id: schedule.id))
        #expect(saved.isEnabled)
        #expect(saved.nextExpectedAt == first.nextExpectedAt)
        #expect(try await store.occurrences(scheduleID: schedule.id, limit: 10).count == 1)

        // A second skip targets the NEXT fire time, not the already-skipped
        // instance; it never reuses an old id.
        let second = try #require(try await store.skipNext(id: schedule.id, at: Date()))
        #expect(second.skippedOccurrenceID != first.skippedOccurrenceID)
        #expect(second.nextExpectedAt! > first.nextExpectedAt!)
        #expect(try await store.occurrences(scheduleID: schedule.id, limit: 10).count == 2)
        saved = try #require(try await store.schedule(id: schedule.id))
        #expect(saved.isEnabled)
    }

    @Test("Skip next retires a one-shot but keeps its record and history")
    func skipNextOneShotRetires() async throws {
        let (_, store) = try await makeStore()
        let schedule = TaskScheduleRecord(
            title: "Once", prompt: "Do it", cadence: .once,
            scheduledAt: Date().addingTimeInterval(3_600))
        try await store.save(schedule)
        let result = try #require(try await store.skipNext(id: schedule.id, at: Date()))
        #expect(result.planDisabled)
        #expect(result.nextExpectedAt == nil)
        let saved = try #require(try await store.schedule(id: schedule.id))
        #expect(saved.isEnabled == false)
        #expect(saved.nextExpectedAt == nil)
        #expect(try await store.occurrence(id: result.skippedOccurrenceID)?.state == .skipped)
        // History survives deleting the plan itself.
        try await store.delete(id: schedule.id)
        #expect(try await store.occurrences(scheduleID: schedule.id, limit: 10).count == 1)
    }

    @Test("Skip next refuses a paused or event-driven plan and leaves a running instance alone")
    func skipNextGuards() async throws {
        let (_, store) = try await makeStore()
        let paused = TaskScheduleRecord(
            title: "Paused", prompt: "x", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-60), isEnabled: false)
        try await store.save(paused)
        await #expect(throws: (any Error).self) {
            _ = try await store.skipNext(id: paused.id, at: Date())
        }
        let eventDriven = TaskScheduleRecord(
            title: "After", prompt: "x", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: UUID())
        try await store.save(eventDriven)
        await #expect(throws: (any Error).self) {
            _ = try await store.skipNext(id: eventDriven.id, at: Date())
        }

        // A RUNNING current instance is history in progress: skip targets the
        // next fire time, not the running row.
        let anchor = Date().addingTimeInterval(-7_200)
        let running = TaskScheduleRecord(
            title: "Running", prompt: "x", cadence: .daily,
            scheduledAt: anchor, anchorTimezone: "UTC")
        try await store.save(running)
        let key = TaskSchedulePlanner.dedupeKey(for: anchor, record: running)
        let occurrenceID = TaskScheduleOccurrence.stableID(
            scheduleID: running.id, dedupeKey: key)
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: occurrenceID, scheduleID: running.id,
            scheduledFor: anchor, dedupeKey: key))
        try await store.claimOccurrence(id: occurrenceID, at: Date())
        try await store.markOccurrenceRunning(
            id: occurrenceID, runID: UUID(), conversationID: UUID(), at: Date())
        let result = try #require(try await store.skipNext(id: running.id, at: Date()))
        #expect(result.skippedOccurrenceID != occurrenceID)
        #expect(try await store.occurrence(id: occurrenceID)?.state == .running)
        #expect(try await store.occurrence(id: result.skippedOccurrenceID)?.state == .skipped)
    }

    @Test("A manual start never advances or retires the calendar plan")
    func manualStartDoesNotAdvance() async throws {
        let (_, store) = try await makeStore()
        let future = Date().addingTimeInterval(7_200)
        let once = TaskScheduleRecord(
            title: "Once", prompt: "x", cadence: .once, scheduledAt: future)
        try await store.save(once)
        let planned = try #require(try await store.schedule(id: once.id)?.nextExpectedAt)
        try await store.markManualStarted(id: once.id, at: Date())
        let saved = try #require(try await store.schedule(id: once.id))
        #expect(saved.lastStartedAt != nil)
        #expect(saved.nextExpectedAt == planned)
        #expect(saved.isEnabled)
        // The calendar launch transition is unchanged for real due instances.
        try await store.markStarted(id: once.id, at: Date())
        #expect(try await store.schedule(id: once.id)?.isEnabled == false)
    }

    @Test("Automatic run count includes every started automatic row but no manual row")
    func automaticStartedCount() async throws {
        let (database, store) = try await makeStore()
        let schedule = TaskScheduleRecord(
            title: "Daily", prompt: "x", cadence: .daily, scheduledAt: Date())
        try await store.save(schedule)
        let base = Date(timeIntervalSince1970: 1_702_000_000)
        // 55 automatic started rows (more than any UI history preview) plus
        // manual and not-yet-started rows that must not count.
        try await database.writer { db in
            for index in 0..<55 {
                let key = "epoch:\(index)"
                let id = TaskScheduleOccurrence.stableID(
                    scheduleID: schedule.id, dedupeKey: key)
                try db.execute(sql: """
                    INSERT INTO task_schedule_occurrences (
                        id, schedule_id, scheduled_for, state, dedupe_key,
                        started_at, created_at, updated_at
                    ) VALUES (?, ?, ?, 'completed', ?, ?, ?, ?)
                    """, arguments: [
                        id.uuidString, schedule.id.uuidString,
                        ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(index))),
                        key,
                        ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(index))),
                        ISO8601DateFormatter().string(from: base),
                        ISO8601DateFormatter().string(from: base)
                    ])
            }
            let manualKey = "manual:\(UUID().uuidString)"
            try db.execute(sql: """
                INSERT INTO task_schedule_occurrences (
                    id, schedule_id, scheduled_for, state, dedupe_key,
                    started_at, created_at, updated_at
                ) VALUES (?, ?, ?, 'completed', ?, ?, ?, ?)
                """, arguments: [
                    UUID().uuidString, schedule.id.uuidString,
                    ISO8601DateFormatter().string(from: base),
                    manualKey,
                    ISO8601DateFormatter().string(from: base),
                    ISO8601DateFormatter().string(from: base),
                    ISO8601DateFormatter().string(from: base)
                ])
            try db.execute(sql: """
                INSERT INTO task_schedule_occurrences (
                    id, schedule_id, scheduled_for, state, dedupe_key,
                    created_at, updated_at
                ) VALUES (?, ?, ?, 'pending', ?, ?, ?)
                """, arguments: [
                    UUID().uuidString, schedule.id.uuidString,
                    ISO8601DateFormatter().string(from: base),
                    "epoch:pending",
                    ISO8601DateFormatter().string(from: base),
                    ISO8601DateFormatter().string(from: base)
                ])
        }
        #expect(try await store.startedAutomaticOccurrenceCount(scheduleID: schedule.id) == 55)
        // A successful recurring run settles its instance but never disables
        // the plan by itself.
        let occurrenceID = TaskScheduleOccurrence.stableID(
            scheduleID: schedule.id, dedupeKey: "epoch:run")
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: occurrenceID, scheduleID: schedule.id,
            scheduledFor: Date(), dedupeKey: "epoch:run"))
        let runID = UUID()
        try await store.claimOccurrence(id: occurrenceID, at: Date())
        try await store.markOccurrenceRunning(
            id: occurrenceID, runID: runID, conversationID: UUID(), at: Date())
        _ = try await store.recordRunCompletion(
            runID: runID, succeeded: true, cancelled: false, summary: "done", at: Date())
        #expect(try await store.schedule(id: schedule.id)?.isEnabled == true)
        #expect(try await store.occurrence(id: occurrenceID)?.state == .completed)
        #expect(try await store.startedAutomaticOccurrenceCount(scheduleID: schedule.id) == 56)
    }

    @Test("V57 adds the origin column and conversation index without a cascade")
    func presentationMigrationShape() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("fixture_base") { db in
            try db.execute(sql: "CREATE TABLE task_schedules (id TEXT PRIMARY KEY) STRICT")
            try db.execute(sql: """
                CREATE TABLE task_schedule_occurrences (
                    id TEXT PRIMARY KEY,
                    schedule_id TEXT NOT NULL,
                    conversation_id TEXT,
                    scheduled_for TEXT NOT NULL
                ) STRICT
                """)
        }
        V57SchedulePresentation.register(into: &migrator)
        try migrator.migrate(queue)
        let columns = try queue.read { db in
            try db.columns(in: "task_schedules").map(\.name)
        }
        #expect(columns.contains("origin_conversation_id"))
        let indexNames = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexNames.contains("idx_schedule_occurrences_conversation"))
        #expect(try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        } == 57)
        // No deletion cascade: the origin column has no foreign-key clause.
        let schema = try queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'task_schedules'
                """) ?? ""
        }
        #expect(!schema.contains("origin_conversation_id TEXT REFERENCES"))
        #expect(!schema.uppercased().contains("CASCADE"))
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
