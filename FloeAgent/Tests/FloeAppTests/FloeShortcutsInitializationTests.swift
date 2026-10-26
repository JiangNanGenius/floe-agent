// FloeAppTests — S3-A App Intent initialization lifecycle.
//
// Cold/headless App Intent launches have no RootView. Production therefore owns
// ONE environment from FloeAgentApp.init and one shared bootstrap plus
// external-automation readiness attempt that intents join. These tests drive the
// real production types:
//
// - `FloeSingleFlightGate` (the shared join/retirement/cancellation helper)
//   with controlled bodies: concurrent join, failed-attempt retry, later-attempt
//   identity, a cancelled waiter that must return BEFORE the shared body is
//   released, an already-cancelled caller that starts no attempt, and the
//   completion-before-registration latch of its waiter rendezvous;
// - `AppEnvironment` entry guards on a preview graph that is never bootstrapped;
// - ONE ordered actual-entry test against the real app-owned environment and
//   the real legacy App Intents. It requires a host launched with
//   `FLOE_S3A_ENTRY_QUALIFICATION=1`: the scene `.task` parks before bootstrap,
//   the test drives a real cold readiness failure, a full normal retry and the
//   legacy rejections, then releases the scene task to join the cached launch.
//
// No provider, network, tool, OS Shortcuts or Siri dispatch is invoked — the
// readiness seam only joins the launch, process-latched run recovery, reload and
// durable configuration reads.

#if canImport(UIKit) && DEBUG
import Foundation
import Testing
import FloeCore
import FloePersistence
@testable import FloeApp

/// Deterministic body for the shared gate: counts executions and holds the
/// first body open until the test releases it.
@MainActor
private final class GateProbe {
    private(set) var executions = 0
    private(set) var overlaps = 0
    private var held: CheckedContinuation<Void, Never>?

    func body() async {
        executions += 1
        if held != nil {
            // A second body must never run while one is held; release it so a
            // regression fails the assertions instead of hanging the suite.
            overlaps += 1
            return
        }
        await withCheckedContinuation { self.held = $0 }
    }

    func quickBody() {
        executions += 1
    }

    func release() {
        held?.resume()
        held = nil
    }
}

@MainActor
private final class Flag {
    var value = false
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    // Bounded yield loop: deterministic enough for the gate's main-actor
    // scheduling and never a wall-clock sleep or uninterruptible wait.
    for _ in 0..<10_000 where !condition() {
        await Task.yield()
    }
}

@Suite("Shortcut initialization lifecycle", .serialized)
@MainActor
struct FloeShortcutsInitializationTests {
    // MARK: - Shared gate mechanics (actual production helper)

    @Test("Concurrent callers join one attempt")
    func concurrentCallersJoinOneAttempt() async {
        let gate = FloeSingleFlightGate()
        let probe = GateProbe()
        let first = Task { @MainActor in await gate.run { await probe.body() } }
        await waitUntil { probe.executions == 1 }
        let joiners = (0..<7).map { _ in
            Task { @MainActor in await gate.run { await probe.body() } }
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(probe.executions == 1)
        #expect(probe.overlaps == 0)
        #expect(gate.isRunning)
        probe.release()
        await first.value
        for joiner in joiners { await joiner.value }
        #expect(probe.executions == 1)
        #expect(!gate.isRunning)
    }

    @Test("A completed attempt retires before an explicit retry")
    func failedAttemptRetiresBeforeExplicitRetry() async {
        let gate = FloeSingleFlightGate()
        let probe = GateProbe()
        // First attempt "fails" (its shared state records the failure) and
        // completes. The gate must be retired before this call returns, so an
        // immediate explicit retry runs the body again instead of rejoining
        // the finished failed attempt.
        await gate.run { probe.quickBody() }
        #expect(probe.executions == 1)
        #expect(!gate.isRunning)
        await gate.run { probe.quickBody() }
        #expect(probe.executions == 2)
        #expect(!gate.isRunning)
    }

    @Test("A later attempt is not cleared by the earlier attempt's completion")
    func laterAttemptSurvivesEarlierCompletion() async {
        let gate = FloeSingleFlightGate()
        let probe = GateProbe()
        await gate.run { probe.quickBody() }          // attempt 1 completes
        #expect(!gate.isRunning)
        let second = Task { @MainActor in await gate.run { await probe.body() } }
        await waitUntil { probe.executions == 2 }     // attempt 2 held
        let third = Task { @MainActor in
            await gate.run { probe.quickBody() }      // must join attempt 2
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(probe.executions == 2)
        #expect(probe.overlaps == 0)
        #expect(gate.isRunning)
        probe.release()
        await second.value
        await third.value
        #expect(probe.executions == 2)
        #expect(!gate.isRunning)
    }

    @Test("A synchronous attempt body still returns to its caller")
    func synchronousAttemptBodyReturnsToCaller() async {
        // Regression for the completion-before-registration race: a body that
        // finishes immediately must not leave its caller suspended.
        let gate = FloeSingleFlightGate()
        let probe = GateProbe()
        let returned = Flag()
        Task { @MainActor in
            await gate.run { probe.quickBody() }
            returned.value = true
        }
        await waitUntil { returned.value }
        #expect(returned.value)
        #expect(probe.executions == 1)
        #expect(!gate.isRunning)
    }

    @Test("Completion is latched when it lands before wait registration")
    func completionBeforeWaitRegistrationIsLatched() async {
        let waiter = FloeSingleFlightGate.AttemptWaiter()
        waiter.complete()                    // completion FIRST
        let returned = Flag()
        Task { @MainActor in
            await waiter.wait()              // registration AFTER completion
            returned.value = true
        }
        await waitUntil { returned.value }
        #expect(returned.value)
    }

    @Test("A cancelled waiter returns before the shared body is released")
    func cancelledWaiterReturnsBeforeSharedBodyCompletes() async {
        let gate = FloeSingleFlightGate()
        let probe = GateProbe()
        let owner = Task { @MainActor in await gate.run { await probe.body() } }
        await waitUntil { probe.executions == 1 }

        let waiterReturned = Flag()
        let waiter = Task { @MainActor () -> Bool in
            await gate.run { probe.quickBody() }
            waiterReturned.value = true
            return Task.isCancelled
        }
        for _ in 0..<100 { await Task.yield() }
        waiter.cancel()

        // The cancelled waiter must finish WITHOUT the shared body completing.
        await waitUntil { waiterReturned.value }
        #expect(waiterReturned.value)
        #expect(gate.isRunning)
        #expect(probe.executions == 1)

        // Another caller keeps waiting on the same attempt, which still runs
        // exactly once, and the cancelled caller observed cancellation.
        let survivor = Task { @MainActor in await gate.run { probe.quickBody() } }
        for _ in 0..<100 { await Task.yield() }
        #expect(probe.executions == 1)
        probe.release()
        await owner.value
        await survivor.value
        let cancelled = await waiter.value
        #expect(cancelled)
        #expect(probe.executions == 1)
        #expect(!gate.isRunning)
    }

    @Test("An already-cancelled caller starts no attempt")
    func alreadyCancelledCallerStartsNoAttempt() async {
        let gate = FloeSingleFlightGate()
        let probe = GateProbe()
        let result = await Task { @MainActor () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            await gate.run { probe.quickBody() }
            return Task.isCancelled
        }.value
        #expect(result)
        #expect(probe.executions == 0)
        #expect(!gate.isRunning)
    }

    // MARK: - AppEnvironment entry guard (no launch work)
    //
    // The preview graph is deliberately NOT bootstrapped: `preview()` shares
    // production service roots (provider Keychain namespace, Notes/CAD
    // reconciliation, credential/cleanup queues, fonts, DesignFreeze, CloudKit),
    // so an in-memory SQLite database alone does not make bootstrap side-effect
    // free. This case proves only the entry guard: cancellation is observed
    // before bootstrap/readiness starts, so no launch work executes.

    @Test("A cancelled caller starts no launch or readiness work")
    func cancelledCallerStartsNoWork() async {
        let environment = AppEnvironment.preview()
        let cancelled = await Task { @MainActor () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await environment.ensureReadyForExternalAutomation()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        #expect(cancelled)
        #expect(environment.bootstrapExecutionCount == 0)
        #expect(environment.externalAutomationExecutionCount == 0)
    }

    @Test("Cold download entry initializes configuration once without starting a run",
          .enabled(if: FloeEntryQualificationSupport.isRequested))
    func actualColdDownloadEntryJoinsReadinessAndRetriesFailure() async throws {
        let environment = try #require(AppEnvironment.qualificationLaunchEnvironment)
        defer { FloeEntryQualification.releaseSceneBootstrapBarrier() }
        try #require(await FloeEntryQualification.waitForSceneBootstrapBarrier())
        #expect(environment.bootstrapExecutionCount == 0)
        let before = try await environment.conversationStore.conversations(includeArchived: true).count
        #expect(!environment.backgroundDownloadAutomationReady)
        // The fixture injects one real launch failure. An early wake cannot
        // treat default preferences or an uninitialized model list as ready.
        FloeEntryQualification.armBootstrapFailureOnce()
        environment.startBackgroundDownloadInitialization()
        for _ in 0..<8 { environment.startBackgroundDownloadInitialization() }
        let firstDeadline = Date().addingTimeInterval(30)
        while environment.isBackgroundDownloadInitializationRunning && Date() < firstDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!environment.isBackgroundDownloadInitializationRunning)
        #expect(environment.bootstrapExecutionCount == 1)
        #expect(!environment.backgroundDownloadAutomationReady)
        #expect(environment.bootstrapError != nil)
        environment.startBackgroundDownloadInitialization()
        for _ in 0..<8 { environment.startBackgroundDownloadInitialization() }
        let retryDeadline = Date().addingTimeInterval(90)
        while environment.isBackgroundDownloadInitializationRunning && Date() < retryDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!environment.isBackgroundDownloadInitializationRunning)
        #expect(environment.backgroundDownloadAutomationReady)
        #expect(environment.bootstrapExecutionCount == 2)
        #expect(environment.externalAutomationExecutionCount == 1)
        environment.startBackgroundDownloadInitialization()
        await Task.yield()
        #expect(!environment.isBackgroundDownloadInitializationRunning)
        #expect(environment.bootstrapExecutionCount == 2)
        #expect(try await environment.conversationStore.conversations(includeArchived: true).count == before)
    }

    // MARK: - Actual App / Intent entry (hosted, ordered)
    //
    // The hosted App must launch with FLOE_S3A_ENTRY_QUALIFICATION=1. The scene
    // `.task` parks before bootstrap; this test directly reads the actual
    // app-owned environment and drives the actual legacy intents while the
    // scene is still cold. `defer` always releases the scene task, which then
    // joins the cached successful bootstrap. This is hosted `perform()` before
    // scene bootstrap, not OS Shortcuts/Siri/headless-system dispatch.

    @Test(
        "Actual cold App Intent entry retries once and rejects before work",
        .enabled(if: FloeEntryQualificationSupport.isRequested)
    )
    func actualColdIntentEntryRetriesAndRejectsBeforeWork() async throws {
        let environment = try #require(AppEnvironment.qualificationLaunchEnvironment)
        defer { FloeEntryQualification.releaseSceneBootstrapBarrier() }

        let barrierReached = await FloeEntryQualification.waitForSceneBootstrapBarrier()
        try #require(barrierReached, "scene .task did not park before bootstrap")
        #expect(environment.bootstrapExecutionCount == 0)
        #expect(environment.externalAutomationExecutionCount == 0)
        #expect(!environment.persistenceReady)
        #expect(environment.bootstrapError == nil)

        let conversationsBefore = try await environment.conversationStore
            .conversations(includeArchived: true).count
        let scheduleStore = SQLiteTaskScheduleStore(database: environment.database)
        let schedulesBefore = try await scheduleStore.schedules().count
        let shortcutsEnabled = AppleCapabilityPreferences.isEnabled(.shortcuts)
        let automationEnabled = AppleCapabilityPreferences.isEnabled(.automation)

        FloeEntryQualification.armBootstrapFailureOnce()

        if shortcutsEnabled {
            // Actual legacy Run intent: the first entry traverses production
            // readiness and hits the one injected cold-start failure.
            let coldFailure = await runIntentFailure()
            #expect((coldFailure as? FloeShortcutRunError) == .durableStorageUnavailable)
            #expect(environment.bootstrapExecutionCount == 1)
            #expect(environment.externalAutomationExecutionCount == 0)
            #expect(environment.bootstrapError != nil)
            #expect(!environment.persistenceReady)

            // The second actual entry retries the full normal bootstrap once,
            // then rejects the empty prompt (or missing default model) BEFORE
            // any task, network or tool work.
            let retryFailure = await runIntentFailure()
            #expect(environment.bootstrapExecutionCount == 2)
            #expect(environment.externalAutomationExecutionCount == 1)
            #expect(environment.persistenceReady)
            #expect(environment.bootstrapError == nil)
            let center = environment.conversationCenter
            if center.providerAndModel(modelID: center.modelPreferences.defaultAgentModelID) == nil {
                #expect((retryFailure as? FloeError)
                    == .invalidConfiguration("No default Floe model is configured"))
            } else {
                #expect((retryFailure as? FloeError) == .validationFailed("Task must not be empty"))
            }
        } else {
            // Shortcuts is disabled in the persisted settings. Do not change
            // it: prove the production readiness seam directly (cold failure,
            // then the full retry), then run the actual disabled legacy intent.
            let coldFailure = await ensureReadyFailure(environment)
            #expect((coldFailure as? FloeShortcutRunError) == .durableStorageUnavailable)
            #expect(environment.bootstrapExecutionCount == 1)
            #expect(environment.externalAutomationExecutionCount == 0)

            let readyFailure = await ensureReadyFailure(environment)
            #expect(readyFailure == nil)
            #expect(environment.bootstrapExecutionCount == 2)
            #expect(environment.externalAutomationExecutionCount == 1)
            #expect(environment.persistenceReady)
            #expect(environment.bootstrapError == nil)

            let disabledFailure = await runIntentFailure()
            #expect((disabledFailure as? FloeError)
                == .invalidConfiguration("Shortcuts is disabled in Floe Settings"))
        }

        // Actual legacy Schedule intent with an empty prompt: it must not save
        // a schedule, whether the persisted capabilities allow it or not.
        let scheduleFailure = await scheduleIntentFailure()
        if shortcutsEnabled && automationEnabled {
            #expect((scheduleFailure as? FloeError) == .validationFailed("Task must not be empty"))
        } else {
            #expect((scheduleFailure as? FloeError)
                == .invalidConfiguration("Shortcuts or Automation is disabled in Floe Settings"))
        }

        // Actual pre-cancelled Run: no task and no extra readiness body.
        let cancellationFailure = await cancelledRunIntentFailure()
        if shortcutsEnabled {
            #expect(cancellationFailure is CancellationError)
        } else {
            #expect((cancellationFailure as? FloeError)
                == .invalidConfiguration("Shortcuts is disabled in Floe Settings"))
        }

        // No task/schedule was created; the readiness bodies stayed shared.
        #expect(try await environment.conversationStore
            .conversations(includeArchived: true).count == conversationsBefore)
        #expect(try await scheduleStore.schedules().count == schedulesBefore)
        #expect(environment.bootstrapExecutionCount == 2)
        #expect(environment.externalAutomationExecutionCount == 1)
        #expect(environment.persistenceReady)
        #expect(environment.bootstrapError == nil)

        // The ordinary scene `.task` now joins the cached successful bootstrap
        // instead of re-running launch recovery.
        FloeEntryQualification.releaseSceneBootstrapBarrier()
        let sceneJoined = await FloeEntryQualification.waitForSceneBootstrapReturn()
        try #require(sceneJoined, "released scene .task did not return from bootstrap")
        #expect(environment.bootstrapExecutionCount == 2)
        #expect(environment.externalAutomationExecutionCount == 1)
    }

    // MARK: - Actual Intent helpers

    private func runIntentFailure() async -> Error? {
        var intent = RunFloeTaskIntent()
        intent.task = ""
        do {
            _ = try await intent.perform()
            return nil
        } catch {
            return error
        }
    }

    private func scheduleIntentFailure() async -> Error? {
        var intent = ScheduleFloeTaskIntent()
        intent.task = ""
        intent.scheduledAt = Date()
        intent.cadence = .once
        do {
            _ = try await intent.perform()
            return nil
        } catch {
            return error
        }
    }

    private func cancelledRunIntentFailure() async -> Error? {
        await Task { @MainActor () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            var intent = RunFloeTaskIntent()
            intent.task = ""
            do {
                _ = try await intent.perform()
                return nil
            } catch {
                return error
            }
        }.value
    }

    private func ensureReadyFailure(_ environment: AppEnvironment) async -> Error? {
        do {
            try await environment.ensureReadyForExternalAutomation()
            return nil
        } catch {
            return error
        }
    }
}
#endif
