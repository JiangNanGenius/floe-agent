// FloePersistenceTests — run-lifecycle stores (schema v46):
// scheduled-task occurrences, run dependencies, delegated-child persistence
// and the promoted title-origin contract.

import Foundation
import Testing
import GRDB
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("FloePersistence.TaskLifecycleStores")
struct TaskLifecycleStoreTests {

    private func database() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    // MARK: - Schedule occurrences

    @Test("Stable occurrence identity is deterministic and dedupe-safe")
    func stableOccurrenceIdentity() async throws {
        let scheduleID = UUID()
        let key = "day:2026-10-15"
        let first = TaskScheduleOccurrence.stableID(scheduleID: scheduleID, dedupeKey: key)
        let second = TaskScheduleOccurrence.stableID(scheduleID: scheduleID, dedupeKey: key)
        #expect(first == second)
        #expect(first != TaskScheduleOccurrence.stableID(scheduleID: scheduleID, dedupeKey: "day:2026-10-16"))
    }

    @Test("An occurrence is claimed exactly once and finishes once")
    func claimExactlyOnce() async throws {
        let database = try await database()
        let store = SQLiteTaskScheduleStore(database: database)
        let schedule = TaskScheduleRecord(
            title: "Daily", prompt: "Report", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-3_600))
        try await store.save(schedule)
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: "day:test"),
            scheduleID: schedule.id,
            scheduledFor: Date(),
            dedupeKey: "day:test")
        #expect(try await store.enqueueOccurrence(occurrence))
        // A second enqueue for the same logical instance is a no-op.
        #expect(try await store.enqueueOccurrence(occurrence) == false)
        #expect(try await store.claimOccurrence(id: occurrence.id, at: Date()))
        #expect(try await store.claimOccurrence(id: occurrence.id, at: Date()) == false)
        let runID = UUID()
        #expect(try await store.markOccurrenceRunning(
            id: occurrence.id, runID: runID, conversationID: UUID(), at: Date()))
        #expect(try await store.markOccurrenceRunning(
            id: occurrence.id, runID: runID, conversationID: UUID(), at: Date()) == false)
        try await store.finishOccurrence(
            id: occurrence.id, state: .completed, summary: "ok", errorText: nil, at: Date())
        let stored = try #require(try await store.occurrence(id: occurrence.id))
        #expect(stored.state == .completed)
        #expect(stored.runID == runID)
    }

    @Test("Only the bound upstream run's success enqueues the after-success occurrence once")
    func afterSuccessFiresOncePerSuccessfulRun() async throws {
        let database = try await database()
        let store = SQLiteTaskScheduleStore(database: database)
        let upstreamRunID = UUID()
        let dependent = TaskScheduleRecord(
            title: "Dependent", prompt: "Publish", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: upstreamRunID)
        try await store.save(dependent)

        // A failed run (even one with an occurrence) triggers nothing.
        let failedRun = UUID()
        let failedOccurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: dependent.id, dedupeKey: "failed"),
            scheduleID: dependent.id, scheduledFor: Date(), dedupeKey: "failed")
        _ = failedOccurrence
        #expect(try await store.recordRunCompletion(
            runID: failedRun, succeeded: false, cancelled: false, summary: "boom", at: Date()).isEmpty)

        // The BOUND run's success enqueues exactly one pending occurrence.
        let enqueued = try await store.recordRunCompletion(
            runID: upstreamRunID, succeeded: true, cancelled: false, summary: "done", at: Date())
        #expect(enqueued.count == 1)
        // A replayed completion callback cannot duplicate it.
        #expect(try await store.recordRunCompletion(
            runID: upstreamRunID, succeeded: true, cancelled: false, summary: "done", at: Date()).isEmpty)
        let dependents = try await store.occurrences(scheduleID: dependent.id, limit: 10)
        #expect(dependents.count == 1)
        #expect(dependents.first?.state == .pending)
        #expect(dependents.first?.dedupeKey == "upstream:\(upstreamRunID.uuidString)")

        // A different run's success does not fire this schedule.
        #expect(try await store.recordRunCompletion(
            runID: UUID(), succeeded: true, cancelled: false, summary: "other", at: Date()).isEmpty)
    }

    @Test("A stale upstream binding on a non-after-success cadence never fires")
    func staleUpstreamBindingIsInert() async throws {
        let database = try await database()
        let store = SQLiteTaskScheduleStore(database: database)
        let upstreamRunID = UUID()
        // A schedule EDITED away from after-success can keep the historical
        // upstream_run_id column until the edit clears it; the completion
        // path must still never fire it from an unrelated run.
        var stale = TaskScheduleRecord(
            title: "Formerly after-success", prompt: "Go", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: upstreamRunID)
        try await store.save(stale)
        stale.cadence = .daily
        try await store.save(stale)

        #expect(try await store.recordRunCompletion(
            runID: upstreamRunID, succeeded: true, cancelled: false,
            summary: "done", at: Date()).isEmpty)
        #expect(try await store.occurrences(scheduleID: stale.id, limit: 10).isEmpty)
        // A genuine after-success schedule bound to the same run still fires.
        let dependent = TaskScheduleRecord(
            title: "Dependent", prompt: "Publish", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: upstreamRunID)
        try await store.save(dependent)
        let enqueued = try await store.recordRunCompletion(
            runID: upstreamRunID, succeeded: true, cancelled: false,
            summary: "done", at: Date())
        #expect(enqueued.count == 1)
        let pending = try await store.pendingOccurrences(limit: 10)
        #expect(pending.contains { $0.scheduleID == dependent.id && $0.dedupeKey == "upstream:\(upstreamRunID.uuidString)" })
    }

    @Test("Disabled schedules cancel pending occurrences; runNow always creates one")
    func disableCancelsPendingRunNowCreates() async throws {
        let database = try await database()
        let store = SQLiteTaskScheduleStore(database: database)
        let schedule = TaskScheduleRecord(
            title: "Once", prompt: "Go", cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60))
        try await store.save(schedule)
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: "once"),
            scheduleID: schedule.id, scheduledFor: Date(), dedupeKey: "once")
        #expect(try await store.enqueueOccurrence(occurrence))
        try await store.setEnabled(id: schedule.id, enabled: false, at: Date())
        #expect(try await store.occurrence(id: occurrence.id)?.state == .cancelled)

        let manual = try #require(try await store.runNow(id: schedule.id, at: Date()))
        #expect(manual.state == .pending)
        let second = try #require(try await store.runNow(id: schedule.id, at: Date()))
        #expect(second.id != manual.id)
    }

    @Test("A claimed occurrence left by a dead process is interrupted; a one-shot is re-armed")
    func reconcileInterruptedOnLaunch() async throws {
        let database = try await database()
        let store = SQLiteTaskScheduleStore(database: database)
        let schedule = TaskScheduleRecord(
            title: "Once", prompt: "Go", cadence: .once,
            scheduledAt: Date().addingTimeInterval(-120))
        try await store.save(schedule)
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: "once"),
            scheduleID: schedule.id, scheduledFor: schedule.scheduledAt, dedupeKey: "once")
        #expect(try await store.enqueueOccurrence(occurrence))
        #expect(try await store.claimOccurrence(id: occurrence.id, at: Date()))
        let count = try await store.reconcileInterruptedOccurrences(at: Date())
        #expect(count == 1)
        #expect(try await store.occurrence(id: occurrence.id)?.state == .interrupted)
        // The never-launched one-shot is enabled again for the next wakeup.
        #expect(try await store.schedule(id: schedule.id)?.isEnabled == true)
    }

    // MARK: - Planner

    @Test("Missed daily fire times coalesce to the most recent window")
    func plannerCoalescesMissedDays() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let anchor = calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 1, hour: 9, minute: 0))!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 5, hour: 12, minute: 0))!
        let schedule = TaskScheduleRecord(
            title: "Daily", prompt: "Report", cadence: .daily,
            scheduledAt: anchor, anchorTimezone: "America/New_York")
        let due = TaskSchedulePlanner.dueFireTimes(record: schedule, now: now, limit: 3)
        #expect(due.count == 3)
        // The most recent fire time is 2026-10-05 09:00 local (DST-independent
        // wall-clock anchor).
        let parts = calendar.dateComponents([.day, .hour], from: due.last!)
        #expect(parts.day == 5)
        #expect(parts.hour == 9)
        #expect(TaskSchedulePlanner.dedupeKey(for: due.last!, record: schedule) == "day:2026-10-05")
    }

    @Test("Fixed interval stays an absolute duration and does not fire before the anchor")
    func plannerIntervalAbsolute() async throws {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = TaskScheduleRecord(
            title: "Every 6h", prompt: "Sync", cadence: .interval,
            scheduledAt: anchor, intervalSeconds: 6 * 3_600)
        #expect(TaskSchedulePlanner.dueFireTimes(
            record: schedule, now: anchor.addingTimeInterval(-60)).isEmpty)
        let due = TaskSchedulePlanner.dueFireTimes(
            record: schedule, now: anchor.addingTimeInterval(13 * 3_600))
        #expect(due.count == 3)
        #expect(abs(due.last!.timeIntervalSince(anchor) - 12 * 3_600) < 0.5)
        let next = try #require(TaskSchedulePlanner.nextFireTime(
            after: anchor.addingTimeInterval(13 * 3_600), record: schedule))
        #expect(abs(next.timeIntervalSince(anchor) - 18 * 3_600) < 0.5)
    }

    @Test("After-success schedules have no clock fire time")
    func plannerAfterSuccessHasNoClock() async throws {
        let schedule = TaskScheduleRecord(
            title: "After", prompt: "Go", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: UUID())
        #expect(TaskSchedulePlanner.dueFireTimes(record: schedule, now: Date()).isEmpty)
        #expect(TaskSchedulePlanner.nextFireTime(after: Date(), record: schedule) == nil)
    }

    // MARK: - Run dependencies

    @Test("Dependency resolves once with the first outcome and lists pending by run")
    func dependencyFirstOutcomeWins() async throws {
        let database = try await database()
        let store = SQLiteRunDependencyStore(database: database)
        let jobID = UUID()
        let runID = UUID()
        try await store.register(RunDependencyRecord(
            jobID: jobID, runID: runID, conversationID: UUID(), kind: "job"))
        try await store.register(RunDependencyRecord(
            jobID: jobID, runID: runID, conversationID: UUID(), kind: "job"))
        #expect(try await store.pending(runID: runID).count == 1)
        let first = try await store.resolve(jobID: jobID, state: .resolved, note: "done")
        #expect(first?.state == .resolved)
        let late = try await store.resolve(jobID: jobID, state: .failed, note: "late failure")
        #expect(late?.state == .resolved)
        #expect(try await store.pending(runID: runID).isEmpty)
        #expect(try await store.allPending().isEmpty)
    }

    // MARK: - Child runs

    @Test("Child identity, relation and bounded paged transcript are durable")
    func childRunTranscript() async throws {
        let database = try await database()
        let store = SQLiteChildRunStore(database: database)
        let childID = UUID()
        let parentRunID = UUID()
        let conversationID = UUID()
        _ = try await store.register(ChildRunRecord(
            id: childID,
            parentRunID: parentRunID,
            rootRunID: conversationID,
            conversationID: conversationID,
            childIndex: 0,
            kind: "explore",
            taskSummary: "inspect the repository",
            delegateCallID: "call-1"))
        try await store.transition(id: childID, state: .running, iterationCount: 1, endedAt: nil)
        for index in 1...5 {
            try await store.appendEntry(
                id: childID, kind: .toolResult,
                payloadJSON: "{\"seq\":\(index)}")
        }
        let firstPage = try await store.entries(childRunID: childID, afterSequence: 0, limit: 2)
        #expect(firstPage.entries.count == 2)
        #expect(firstPage.nextSequence == 2)
        let secondPage = try await store.entries(
            childRunID: childID, afterSequence: firstPage.nextSequence ?? 0, limit: 10)
        #expect(secondPage.entries.count == 3)
        try await store.finish(
            id: childID, state: .completed, iterationCount: 3,
            resultSummary: "done", errorText: nil, digest: "abc")
        let record = try #require(try await store.child(id: childID))
        #expect(record.state == .completed)
        #expect(record.resultSummary == "done")
        // The relation carries the parent/root/conversation binding AND the
        // delegate call id.
        let children = try await store.children(parentRunID: parentRunID)
        #expect(children.count == 1)
        #expect(children.first?.childIndex == 1)
        #expect(children.first?.delegateCallID == "call-1")
        // A relaunch interrupts the still-running child honestly.
        let runningChild = UUID()
        _ = try await store.register(ChildRunRecord(
            id: runningChild,
            parentRunID: parentRunID,
            rootRunID: conversationID,
            conversationID: conversationID,
            childIndex: 0,
            kind: "execute",
            taskSummary: "long work"))
        #expect(try await store.reconcileInterruptedOnLaunch() == 1)
        #expect(try await store.child(id: runningChild)?.state == .interrupted)
    }

    // MARK: - Promoted title origin

    @Test("Promotion persists the title origin: manual survives, autoPending stays eligible once")
    func promotionPersistsTitleOrigin() async throws {
        let database = try await database()
        let promoter = ConversationPromoter(database: database)
        let conversationID = UUID()

        func snapshot(titleOrigin: ConversationTitleOrigin) -> ConversationPromoter.Snapshot {
            ConversationPromoter.Snapshot(
                conversation: ConversationRecord(
                    id: conversationID,
                    title: "Fallback title",
                    createdAt: Date(),
                    updatedAt: Date(),
                    titleOrigin: titleOrigin),
                messages: [],
                attachments: [],
                runs: [],
                events: [],
                usage: [],
                errors: [])
        }
        try await promoter.promote(snapshot(titleOrigin: .manual))
        let manual = try #require(try await SQLiteConversationStore(database: database)
            .conversation(id: conversationID))
        #expect(manual.titleOrigin == .manual)

        let auto = UUID()
        try await promoter.promote(ConversationPromoter.Snapshot(
            conversation: ConversationRecord(
                id: auto, title: "Pending title", createdAt: Date(), updatedAt: Date()),
            messages: [], attachments: [], runs: [], events: [], usage: [], errors: []))
        let pending = try #require(try await SQLiteConversationStore(database: database)
            .conversation(id: auto))
        #expect(pending.titleOrigin == .autoPending)
        // The ordinary auto-title applies exactly once for autoPending.
        #expect(try await SQLiteConversationStore(database: database)
            .setAutomaticTitle(id: auto, title: "Model title") == true)
        #expect(try await SQLiteConversationStore(database: database)
            .setAutomaticTitle(id: auto, title: "Second title") == false)
    }

    // MARK: - Model capability provenance (lane C contract)

    @Test("Model explicit_capabilities round-trips NULL vs reviewed empty vs populated")
    func modelCapabilityProvenance() async throws {
        let database = try await database()
        let store = ModelConfigurationStore(database: database)
        let provider = ProviderProfile(
            kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.com/v1")!)
        try await store.saveProvider(provider)
        let baseModel = ModelProfile(
            providerID: provider.id, remoteModelID: "m1", displayName: "M1",
            limits: ModelLimits(contextTokens: 1_000, maxOutputTokens: 100),
            pricing: nil, capabilities: [.text, .tools])
        try await store.saveModel(baseModel)
        let saved = try #require(try await store.model(id: baseModel.id))
        // Legacy/default row: NULL provenance decodes to nil.
        #expect(try await store.model(id: saved.id)?.explicitCapabilities == nil)
        // Reviewed-but-empty writes an explicit empty mask.
        var reviewed = saved
        reviewed.explicitCapabilities = []
        try await store.saveModel(reviewed)
        #expect(try await store.model(id: saved.id)?.explicitCapabilities == [])
        // Populated mask survives.
        var owned = saved
        owned.explicitCapabilities = [.vision]
        try await store.saveModel(owned)
        #expect(try await store.model(id: saved.id)?.explicitCapabilities == [.vision])
        // A nil write (catalog refresh) must NOT clear the owned mask.
        var nilWrite = saved
        nilWrite.explicitCapabilities = nil
        nilWrite.displayName = "M1 refreshed"
        try await store.saveModel(nilWrite)
        let after = try #require(try await store.model(id: saved.id))
        #expect(after.explicitCapabilities == [.vision])
        #expect(after.displayName == "M1 refreshed")
    }

    @Test("Reviewed saves compare-and-swap against the exact snapshot they validated")
    func modelSaveCompareAndSwap() async throws {
        let database = try await database()
        let store = ModelConfigurationStore(database: database)
        let provider = ProviderProfile(
            kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.com/v1")!)
        try await store.saveProvider(provider)
        let base = ModelProfile(
            providerID: provider.id, remoteModelID: "m2", displayName: "M2",
            limits: ModelLimits(contextTokens: 1_000, maxOutputTokens: 100),
            capabilities: [.text])
        try await store.saveModel(base)
        let snapshot = try #require(try await store.model(id: base.id))

        // A concurrent writer (sync apply / another editor) changes the row
        // after the reviewed snapshot was read.
        var concurrent = snapshot
        concurrent.capabilities.insert(.tools)
        try await store.saveModel(concurrent)

        // The reviewed save against the stale snapshot is refused and writes
        // nothing: the newer state is never silently overwritten.
        var reviewed = snapshot
        reviewed.capabilities.insert(.vision)
        await #expect(throws: (any Error).self) {
            try await store.saveModel(reviewed, expected: snapshot)
        }
        let afterConflict = try #require(try await store.model(id: base.id))
        #expect(afterConflict.capabilities == [.text, .tools])
        #expect(!afterConflict.capabilities.contains(.vision))

        // Re-reading the current row makes the same reviewed change succeed.
        var retried = afterConflict
        retried.capabilities.insert(.vision)
        try await store.saveModel(retried, expected: afterConflict)
        #expect(try await store.model(id: base.id)?.capabilities == [.text, .tools, .vision])

        // A row that vanished in between is a conflict, never a silent upsert.
        let missing = ModelProfile(
            providerID: provider.id, remoteModelID: "gone", displayName: "Gone",
            limits: ModelLimits(contextTokens: 1_000, maxOutputTokens: 100))
        await #expect(throws: (any Error).self) {
            try await store.saveModel(missing, expected: missing)
        }
        #expect(try await store.model(id: missing.id) == nil)
    }
}
