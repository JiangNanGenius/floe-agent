// FloeAppTests — selected-schedule terminal completion after bind recovery.
//
// One bounded race: a schedule's durable run can reach a terminal outcome
// while its occurrence is still unbound (the post-commit bind write failed,
// or the completion callback raced the bind). The live completion bridge
// addresses occurrences by `run_id`, so an unbound claim is invisible to it.
// A later selected retry used to bind that already-terminal run as `running`
// and then return a receipt without settling it. These tests prove the retry
// settles the SAME run through the existing completion/store service, keeps
// exactly one durable run, preserves already-settled/interrupted history,
// and surfaces a real settlement write failure instead of claiming it.
//
// No debug route replaces production execution: the recovery tests use the
// real coordinator + SQLite ledger + durable run store, and the launch test
// goes through the production claim -> launch -> bind path with a real
// scoped SQLite bind-write fault. The launch test parks the deferred task at
// the existing launch-test seam only so the durable terminal state can be
// established deterministically while the occurrence is still unbound.

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import FloeCore
import FloeExecution
import FloeModels
import FloePersistence
import GRDB
@testable import FloeApp

@Suite("FloeApp.SelectedScheduleTerminalRecovery")
@MainActor
struct SelectedScheduleTerminalRecoveryTests {

    private func makeEnvironment() async throws -> AppEnvironment {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        // The isolated in-memory graph is genuinely launched for the
        // production readiness layers; no shared service roots are touched.
        environment.markIsolatedLaunchReadyForTesting()
        return environment
    }

    /// Seeds one enabled provider+model and reloads the center so the
    /// production `providerAndModel(modelID:)` resolution sees it.
    private func seedModel(_ environment: AppEnvironment) async throws -> ModelProfile {
        let configuration = ModelConfigurationStore(database: environment.database)
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://selected-schedule-recovery.example/v1")!)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "selected-schedule-recovery-model",
            displayName: "Selected Schedule Recovery Model",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 1_024),
            capabilities: [.text, .tools])
        try await configuration.saveProvider(provider)
        try await configuration.saveModel(model)
        await environment.conversationCenter.reload()
        return model
    }

    private func dueOnceSchedule(
        title: String = "Recovery report",
        modelID: UUID? = nil
    ) -> TaskScheduleRecord {
        TaskScheduleRecord(
            title: title,
            prompt: "Write the recovery report",
            workspaceID: nil,
            cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60),
            isEnabled: true,
            modelID: modelID)
    }

    private func predeterminedIDs(
        scheduleID: UUID,
        occurrenceID: UUID
    ) -> (runID: UUID, conversationID: UUID) {
        (
            TaskScheduleOccurrence.stableID(
                scheduleID: scheduleID, dedupeKey: "run:\(occurrenceID.uuidString)"),
            TaskScheduleOccurrence.stableID(
                scheduleID: scheduleID, dedupeKey: "conversation:\(occurrenceID.uuidString)")
        )
    }

    /// Runs the shared startup reconciliation once (and launches nothing):
    /// a deleted schedule still exercises the production reconcile entry and
    /// fails afterwards with the expected refusal.
    private func markStartupReconcileDone(_ environment: AppEnvironment) async {
        _ = try? await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: UUID())
    }

    private func seedConversationAndRun(
        _ environment: AppEnvironment,
        schedule: TaskScheduleRecord,
        expected: (runID: UUID, conversationID: UUID),
        state: String
    ) async throws {
        let terminal = state == "completed" || state == "failed" || state == "cancelled"
        try await environment.conversationStore.saveConversation(.init(
            id: expected.conversationID,
            title: schedule.title,
            createdAt: Date(),
            updatedAt: Date()))
        try await environment.runStore.saveRun(.init(
            id: expected.runID,
            conversationID: expected.conversationID,
            state: state,
            goal: schedule.prompt,
            startedAt: Date(),
            endedAt: terminal ? Date() : nil))
    }

    private func seedClaimedOccurrence(
        store: SQLiteTaskScheduleStore,
        scheduleID: UUID,
        target: (fireTime: Date, dedupeKey: String, occurrenceID: UUID)
    ) async throws {
        let enqueued = try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: target.occurrenceID,
            scheduleID: scheduleID,
            scheduledFor: target.fireTime,
            dedupeKey: target.dedupeKey))
        #expect(enqueued)
        let claimed = try await store.claimOccurrence(id: target.occurrenceID, at: Date())
        #expect(claimed)
    }

    // MARK: - Real scoped SQLite faults

    /// Installs a REAL scoped SQLite fault on the production occurrence
    /// table: the claimed -> running bind write aborts. Genuine fault
    /// injection at the store layer, not a stubbed coordinator seam.
    private func installBindWriteFault(_ environment: AppEnvironment) async throws {
        try await environment.database.writer { db in
            try db.execute(sql: """
                CREATE TRIGGER test_fault_block_occurrence_bind
                BEFORE UPDATE ON task_schedule_occurrences
                WHEN NEW.state = 'running'
                BEGIN
                    SELECT RAISE(ABORT, 'injected bind-write failure');
                END
                """)
        }
    }

    private func removeBindWriteFault(_ environment: AppEnvironment) async throws {
        try await environment.database.writer { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS test_fault_block_occurrence_bind")
        }
    }

    /// Blocks only the terminal occurrence update performed by the
    /// completion service, leaving the bind write intact. Used to prove a
    /// settlement write failure is reported and retried, never claimed.
    private func installTerminalSettlementFault(_ environment: AppEnvironment) async throws {
        try await environment.database.writer { db in
            try db.execute(sql: """
                CREATE TRIGGER test_fault_block_occurrence_terminal
                BEFORE UPDATE ON task_schedule_occurrences
                WHEN NEW.state IN ('completed', 'failed', 'cancelled')
                BEGIN
                    SELECT RAISE(ABORT, 'injected terminal settlement failure');
                END
                """)
        }
    }

    private func removeTerminalSettlementFault(_ environment: AppEnvironment) async throws {
        try await environment.database.writer { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS test_fault_block_occurrence_terminal")
        }
    }

    // MARK: - Launch parking seam

    /// Parks the launched deferred task before it can touch the run state,
    /// so the test owns the exact unbound/terminal ordering without a real
    /// network request or sleep-based timing assumption.
    private actor LaunchGate {
        private var didEnter = false
        private var isOpen = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var parked: CheckedContinuation<Void, Never>?

        func hook() async {
            didEnter = true
            let waiters = enteredWaiters
            enteredWaiters = []
            waiters.forEach { $0.resume() }
            if isOpen { return }
            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    parked = continuation
                }
            }
        }

        func waitUntilEntered() async {
            if didEnter { return }
            await withCheckedContinuation { continuation in
                if didEnter {
                    continuation.resume()
                } else {
                    enteredWaiters.append(continuation)
                }
            }
        }

        func open() {
            isOpen = true
            let continuation = parked
            parked = nil
            continuation?.resume()
        }
    }

    // MARK: - Tests

    @Test("A run that reaches terminal after a failed bind settles the SAME run on retry, without a second launch")
    func terminalRunAfterBindFaultSettlesSameRunOnRetry() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        await markStartupReconcileDone(environment)

        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(
            scheduleID: schedule.id, occurrenceID: target.occurrenceID)

        // A dependent armed on THIS concrete run: the live completion bridge
        // enqueues it even while the parent occurrence is unbound.
        let dependent = TaskScheduleRecord(
            title: "Follow-up",
            prompt: "Summarize the recovery report",
            cadence: .afterSuccess,
            scheduledAt: Date(),
            upstreamRunID: expected.runID,
            modelID: model.id)
        try await store.save(dependent)

        let gate = LaunchGate()
        environment.conversationCenter.launchTestHooks.deferredTaskBody = { await gate.hook() }
        defer { Task { await gate.open() } }
        try await installBindWriteFault(environment)

        // Real production claim -> launch -> bind, with the bind write
        // failing after the launch committed.
        let first = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        await gate.waitUntilEntered()
        #expect(first.runID == expected.runID)
        #expect(first.conversationID == expected.conversationID)
        #expect(first.freshlyLaunched)
        let stranded = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(stranded.state == .claimed)
        #expect(stranded.runID == nil)
        #expect(try await environment.runStore.runs(
            conversationID: expected.conversationID).count == 1)
        let launchMessages = try await environment.conversationStore
            .messages(conversationID: expected.conversationID).count

        // The real run reaches a terminal state while the occurrence is
        // still unbound, and the production completion service runs exactly
        // as the live bridge would: the after-success dependent is enqueued,
        // but the occurrence cannot be settled because no row names this run.
        try await environment.runStore.updateRunState(
            id: expected.runID, state: "completed", endedAt: Date())
        _ = try await store.recordRunCompletion(
            runID: expected.runID, succeeded: true, cancelled: false,
            summary: "done", at: Date())
        let afterCompletion = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(afterCompletion.state == .claimed)
        #expect(afterCompletion.runID == nil)
        #expect(try await store.occurrences(scheduleID: dependent.id, limit: 10).count == 1)

        try await removeBindWriteFault(environment)
        let retry = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        #expect(retry.runID == first.runID)
        #expect(retry.conversationID == first.conversationID)
        #expect(!retry.freshlyLaunched)
        // The retry rebound the committed launch; it did not append a second
        // user message or start another task.
        #expect(try await environment.conversationStore
            .messages(conversationID: expected.conversationID).count == launchMessages)

        let settled = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(settled.state == .completed)
        #expect(settled.runID == expected.runID)
        #expect(settled.conversationID == expected.conversationID)
        #expect(settled.finishedAt != nil)
        // Exactly one occurrence and one durable run: the retry rebound the
        // committed launch and never started another.
        #expect(try await store.occurrences(scheduleID: schedule.id, limit: 10).count == 1)
        #expect(try await environment.runStore.runs(
            conversationID: expected.conversationID).count == 1)
        #expect(try await environment.runStore.run(id: expected.runID)?.state == "completed")
        #expect(try await environment.runStore.nonTerminalRuns().isEmpty)
        // Reusing the completion service did not duplicate the dependent; the
        // selected receipt never launches unrelated work, so the dependent is
        // armed once and still pending for the ordinary due pass.
        let dependentOccurrences = try await store.occurrences(
            scheduleID: dependent.id, limit: 10)
        #expect(dependentOccurrences.count == 1)
        #expect(dependentOccurrences.first?.state == .pending)
        #expect(dependentOccurrences.first?.runID == nil)
    }

    @Test("A completed run in the unbound window settles as completed after the real bind fault is removed")
    func completedTerminalRunSettlesAfterBindRecovery() async throws {
        try await assertTerminalRunSettles(
            durableState: "completed",
            expectedOccurrence: .completed,
            expectsErrorText: false)
    }

    @Test("A failed run in the unbound window settles as failed after the real bind fault is removed")
    func failedTerminalRunSettlesAfterBindRecovery() async throws {
        try await assertTerminalRunSettles(
            durableState: "failed",
            expectedOccurrence: .failed,
            expectsErrorText: true)
    }

    @Test("A cancelled run in the unbound window settles as cancelled after the real bind fault is removed")
    func cancelledTerminalRunSettlesAfterBindRecovery() async throws {
        try await assertTerminalRunSettles(
            durableState: "cancelled",
            expectedOccurrence: .cancelled,
            expectsErrorText: true)
    }

    /// Seeds the exact post-commit/unbound state (the durable run exists and
    /// is terminal; the occurrence is claimed with no run reference), proves
    /// the retry's REAL bind write failure is honest and retryable, then
    /// proves the retry converges on the same run with the accurate outcome.
    private func assertTerminalRunSettles(
        durableState: String,
        expectedOccurrence: TaskScheduleOccurrenceState,
        expectsErrorText: Bool
    ) async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        await markStartupReconcileDone(environment)

        let schedule = dueOnceSchedule(title: "Terminal \(durableState)", modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(
            scheduleID: schedule.id, occurrenceID: target.occurrenceID)
        try await seedConversationAndRun(
            environment, schedule: schedule, expected: expected, state: durableState)
        try await seedClaimedOccurrence(
            store: store, scheduleID: schedule.id, target: target)

        try await installBindWriteFault(environment)
        await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.storageUnavailable) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        // The failed bind left the claim recoverable: no reset, no terminal
        // claim, no new run.
        let stranded = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(stranded.state == .claimed)
        #expect(stranded.runID == nil)
        #expect(try await environment.runStore.runs(
            conversationID: expected.conversationID).count == 1)

        try await removeBindWriteFault(environment)
        let retry = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        #expect(retry.runID == expected.runID)
        #expect(retry.conversationID == expected.conversationID)
        #expect(!retry.freshlyLaunched)

        let settled = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(settled.state == expectedOccurrence)
        #expect(settled.runID == expected.runID)
        #expect(settled.conversationID == expected.conversationID)
        #expect(settled.finishedAt != nil)
        if expectsErrorText {
            #expect(settled.errorText?.isEmpty == false)
        } else {
            #expect(settled.errorText == nil)
        }
        // The reconciliation reuses the completion service; it never invents
        // result text that the durable run did not provide.
        #expect(settled.summary == nil)
        #expect(try await store.occurrences(scheduleID: schedule.id, limit: 10).count == 1)
        #expect(try await environment.runStore.runs(
            conversationID: expected.conversationID).count == 1)
        #expect(try await environment.conversationStore
            .messages(conversationID: expected.conversationID).isEmpty)
        if expectedOccurrence != .cancelled {
            #expect(try await environment.runStore.nonTerminalRuns().isEmpty)
        }
    }

    @Test("A pending occurrence whose predetermined run is already terminal settles at the shared bind point")
    func pendingOccurrenceWithTerminalRunSettlesAtBind() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        await markStartupReconcileDone(environment)

        let schedule = dueOnceSchedule(title: "Terminal at bind", modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(
            scheduleID: schedule.id, occurrenceID: target.occurrenceID)
        try await seedConversationAndRun(
            environment, schedule: schedule, expected: expected, state: "completed")
        // Pending (not claimed): the shared executeScheduleOccurrence path
        // owns the claim and the bind, exactly like a normal pass.
        let enqueued = try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: target.occurrenceID,
            scheduleID: schedule.id,
            scheduledFor: target.fireTime,
            dedupeKey: target.dedupeKey))
        #expect(enqueued)

        let receipt = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        #expect(receipt.runID == expected.runID)
        #expect(receipt.conversationID == expected.conversationID)
        #expect(!receipt.freshlyLaunched)
        let settled = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(settled.state == .completed)
        #expect(settled.runID == expected.runID)
        #expect(settled.conversationID == expected.conversationID)
        #expect(settled.finishedAt != nil)
        #expect(try await store.occurrences(scheduleID: schedule.id, limit: 10).count == 1)
        #expect(try await environment.runStore.runs(
            conversationID: expected.conversationID).count == 1)
        #expect(try await environment.runStore.nonTerminalRuns().isEmpty)
        #expect(try await environment.conversationStore
            .messages(conversationID: expected.conversationID).isEmpty)
    }

    @Test("A terminal settlement write failure is storage truth; the retry converges without a new launch")
    func settlementWriteFailureIsRetryableAndNeverRelaunches() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        await markStartupReconcileDone(environment)

        let schedule = dueOnceSchedule(title: "Settlement write", modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(
            scheduleID: schedule.id, occurrenceID: target.occurrenceID)
        try await seedConversationAndRun(
            environment, schedule: schedule, expected: expected, state: "completed")
        try await seedClaimedOccurrence(
            store: store, scheduleID: schedule.id, target: target)
        // Bind successfully first: this isolates the settlement write, so
        // the failure cannot be mistaken for the bind fault.
        let bound = try await store.markOccurrenceRunning(
            id: target.occurrenceID, runID: expected.runID,
            conversationID: expected.conversationID, at: Date())
        #expect(bound)

        try await installTerminalSettlementFault(environment)
        await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.storageUnavailable) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        // The write was rolled back: the bound, non-terminal row is intact
        // and the durable run is untouched. No settlement is claimed.
        let stillRunning = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(stillRunning.state == .running)
        #expect(stillRunning.runID == expected.runID)
        #expect(stillRunning.finishedAt == nil)
        #expect(try await environment.runStore.runs(
            conversationID: expected.conversationID).count == 1)

        try await removeTerminalSettlementFault(environment)
        let retry = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        #expect(retry.runID == expected.runID)
        #expect(!retry.freshlyLaunched)
        let settled = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(settled.state == .completed)
        #expect(settled.runID == expected.runID)
        #expect(try await store.occurrences(scheduleID: schedule.id, limit: 10).count == 1)
        #expect(try await environment.runStore.runs(
            conversationID: expected.conversationID).count == 1)
        #expect(try await environment.runStore.nonTerminalRuns().isEmpty)
        #expect(try await environment.conversationStore
            .messages(conversationID: expected.conversationID).isEmpty)
    }

    @Test("Cold-start interrupted history is preserved and never restarted by a terminal run")
    func interruptedHistoryIsNeverOverwritten() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        await markStartupReconcileDone(environment)

        let schedule = dueOnceSchedule(title: "Interrupted history", modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(
            scheduleID: schedule.id, occurrenceID: target.occurrenceID)
        try await seedConversationAndRun(
            environment, schedule: schedule, expected: expected, state: "completed")
        try await seedClaimedOccurrence(
            store: store, scheduleID: schedule.id, target: target)
        // Cold-start reconcile semantics: a claim left by a dead process is
        // explicitly unknown history, not a run outcome.
        try await store.finishOccurrence(
            id: target.occurrenceID, state: .interrupted, summary: nil,
            errorText: "The process exited before this scheduled task launched or finished; its outcome is unknown.",
            at: Date())

        await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.noDueOccurrence(
            eventDriven: false)) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        let history = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(history.state == .interrupted)
        #expect(history.runID == nil)
        #expect(history.errorText?.contains("outcome is unknown") == true)
        #expect(try await store.occurrences(scheduleID: schedule.id, limit: 10).count == 1)
        #expect(try await environment.runStore.runs(
            conversationID: expected.conversationID).count == 1)
    }

    @Test("An occurrence already settled by another writer is not overwritten by receipt reconciliation")
    func settledOccurrenceIsNotOverwritten() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        await markStartupReconcileDone(environment)

        let schedule = dueOnceSchedule(title: "Settled by owner", modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(
            scheduleID: schedule.id, occurrenceID: target.occurrenceID)
        try await seedConversationAndRun(
            environment, schedule: schedule, expected: expected, state: "completed")
        try await seedClaimedOccurrence(
            store: store, scheduleID: schedule.id, target: target)
        let bound = try await store.markOccurrenceRunning(
            id: target.occurrenceID, runID: expected.runID,
            conversationID: expected.conversationID, at: Date())
        #expect(bound)
        // The owning writer settled the occurrence as cancelled while the
        // durable run row still says completed (an inconsistent-looking but
        // explicitly owned row). The receipt must not rewrite it.
        try await store.finishOccurrence(
            id: target.occurrenceID, state: .cancelled, summary: "user stopped",
            errorText: "Scheduled task was cancelled by the owner", at: Date())

        let receipt = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        #expect(receipt.runID == expected.runID)
        #expect(!receipt.freshlyLaunched)
        let ledger = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(ledger.state == .cancelled)
        #expect(ledger.summary == "user stopped")
        #expect(ledger.errorText == "Scheduled task was cancelled by the owner")
        #expect(ledger.runID == expected.runID)
        #expect(try await store.occurrences(scheduleID: schedule.id, limit: 10).count == 1)
        #expect(try await environment.runStore.runs(
            conversationID: expected.conversationID).count == 1)
    }
}

#endif
