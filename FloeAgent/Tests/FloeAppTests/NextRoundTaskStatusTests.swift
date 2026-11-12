#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeApp

@Suite("RQ41 truthful task conclusion and notification ownership", .serialized)
@MainActor
struct NextRoundTaskStatusTests {
    @Test("Settled completion and checkpoints survive invocation errors; genuine failure stays failed")
    func settledConclusionIsNotInvocationFailure() {
        #expect(TaskRunConclusion.from(state: "completed")?.invocationSettledNormally == true)
        #expect(TaskRunConclusion.from(state: "checkpointed")?.invocationSettledNormally == true)
        #expect(TaskRunConclusion.from(state: "interrupted") == .checkpointed)
        #expect(TaskRunConclusion.from(state: "failed") == .failed)
        #expect(TaskRunConclusion.from(state: "failed")?.invocationSettledNormally == false)
        for state in ["cancelled", "canceled", "aborted"] {
            #expect(TaskRunConclusion.from(state: state) == .cancelled)
            #expect(TaskRunConclusion.from(state: state)?.invocationSettledNormally == false)
        }
        #expect(TaskRunConclusion.from(state: "streamingModel") == nil)
    }

    @Test("Pause releases continued eligibility while keeping the immutable original start authority")
    func pausedRunKeepsOriginWithoutEligibility() {
        var state = ContinuedProcessingEligibilityState<UUID>()
        let run = UUID(), automatic = UUID()
        let registered = state.registerRun(run, origin: .explicitUserAction)
        let registeredAutomatic = state.registerRun(automatic, origin: .automaticTool)
        #expect(registered)
        #expect(registeredAutomatic)
        #expect(state.hasEligibleWork)
        state.suspendRun(run)
        #expect(!state.hasEligibleWork)
        #expect(state.origin(forRun: run) == .explicitUserAction)
        #expect(state.suspendedRunIDs.contains(run))
        let upgraded = state.registerRun(automatic, origin: .explicitUserAction)
        #expect(!upgraded)
        #expect(state.origin(forRun: automatic) == .automaticTool)
        state.resumeRun(automatic)
        #expect(!state.hasEligibleWork)
        state.resumeRun(run)
        #expect(state.hasEligibleWork)
        #expect(state.origin(forRun: run) == .explicitUserAction)
    }

    @Test("Pausing one run preserves another run; late resume after terminal removal cannot recreate authority")
    func independentRunAndLateResumeBoundaries() {
        var state = ContinuedProcessingEligibilityState<UUID>()
        let first = UUID(), second = UUID()
        state.registerRun(first, origin: .explicitUserAction)
        state.registerRun(second, origin: .explicitUserAction)
        state.suspendRun(first)
        #expect(state.hasEligibleWork)
        state.finishRun(second)
        #expect(!state.hasEligibleWork)
        state.finishRun(first)
        state.resumeRun(first)
        state.suspendRun(first)
        #expect(!state.hasEligibleWork)
        #expect(state.origin(forRun: first) == nil)
        #expect(!state.suspendedRunIDs.contains(first))
    }

    @Test("An obsolete system-add failure cannot resurrect an invalidated run notification")
    func obsoleteNotificationFailureCannotResurrectOutbox() {
        let run = UUID(), conversation = UUID()
        let failure = TaskTerminalEvent.modelRunTerminal(runID: run, conversationID: conversation,
            taskName: "Fixture", kind: .failed, body: "Failed")
        let completed = TaskTerminalEvent.modelRunTerminal(runID: run, conversationID: conversation,
            taskName: "Fixture", kind: .completed, body: "Completed")
        var outbox = TaskNotificationOutbox(), fence = TaskNotificationDeliveryFence()
        outbox.enqueue(failure, canPresent: false)
        let presentable = outbox.takePresentable(canPresent: true)
        #expect(presentable == [failure])
        let obsoleteAdd = fence.begin(identifier: failure.identifier)
        // This is the same pause/resume replacement boundary used by the
        // coordinator: discard local residue and invalidate the old callback.
        fence.invalidate(identifier: failure.identifier)
        outbox.discard(identifier: failure.identifier)
        outbox.enqueue(completed, canPresent: false)
        if fence.finish(identifier: failure.identifier, owner: obsoleteAdd) {
            outbox.enqueue(failure, canPresent: false)
        }
        #expect(outbox.pending == [completed])
        #expect(outbox.pending.allSatisfy { $0.kind != .failed })
    }

    @Test("Replacement callback ownership cannot consume a new delivery or another run's delivery")
    func callbackOwnershipIsPerIdentifierAndAttempt() {
        var fence = TaskNotificationDeliveryFence()
        let first = "run.\(UUID().uuidString).terminal", second = "run.\(UUID().uuidString).terminal"
        let obsolete = fence.begin(identifier: first)
        let current = fence.begin(identifier: first)
        let unrelated = fence.begin(identifier: second)
        let obsoleteFinished = fence.finish(identifier: first, owner: obsolete)
        #expect(!obsoleteFinished)
        #expect(fence.isCurrent(identifier: first, owner: current))
        #expect(fence.isCurrent(identifier: second, owner: unrelated))
        let currentFinished = fence.finish(identifier: first, owner: current)
        let duplicateFinished = fence.finish(identifier: first, owner: current)
        let unrelatedFinished = fence.finish(identifier: second, owner: unrelated)
        #expect(currentFinished)
        #expect(!duplicateFinished)
        #expect(unrelatedFinished)
    }

    @Test("Only actual runtime execution can resume paused eligibility, never late terminal or waiting snapshots")
    func snapshotRepaintCannotResumePausedRun() {
        var eligibility = ContinuedProcessingEligibilityState<UUID>()
        let run = UUID()
        eligibility.registerRun(run, origin: .explicitUserAction)
        eligibility.suspendRun(run)
        for state in ["completed", "failed", "checkpointed", "interrupted", "cancelled",
                      "waitingApproval", "waitingUserQuestion", "idle", "recoveryFailed"] {
            let activity = TaskRunConclusion.isRuntimeActivity(state: state)
            #expect(!activity, "A late/waiting \(state) is not actual execution")
            if activity { eligibility.resumeRun(run) }
        }
        #expect(!eligibility.hasEligibleWork)
        #expect(eligibility.origin(forRun: run) == .explicitUserAction)
        for state in ["preparing", "streamingModel", "preparingToolCall", "executingTool",
                      "committingResults", "compacting", "verifying", "reconnecting"] {
            #expect(TaskRunConclusion.isRuntimeActivity(state: state))
        }
        if TaskRunConclusion.isRuntimeActivity(state: "executingTool") { eligibility.resumeRun(run) }
        #expect(eligibility.hasEligibleWork)
    }

    @Test("Same-run admission is reserved before preparation; cancellation keeps its cleanup barrier and spares other runs")
    func invocationAdmissionAndCancellationAreOwned() throws {
        var ownership = ConversationRunInvocationOwnership()
        let run = UUID(), otherRun = UUID()
        let claimed = ownership.claim(run)
        let first = try #require(claimed)
        #expect(ownership.mayExecute(first))
        let duplicate = ownership.claim(run)
        #expect(duplicate == nil)
        let otherClaim = ownership.claim(otherRun)
        let other = try #require(otherClaim)
        ownership.cancel(run)
        #expect(!ownership.mayExecute(first))
        #expect(ownership.hasOwner(run))
        let duringCleanup = ownership.claim(run)
        #expect(duringCleanup == nil)
        #expect(ownership.mayExecute(other))
        let released = ownership.finish(first)
        #expect(released)
        #expect(!ownership.hasOwner(run))
        #expect(ownership.hasOwner(otherRun))
    }

    @Test("An old cleanup token cannot erase the replacement invocation or its resource authority")
    func oldInvocationCleanupCannotEraseReplacement() throws {
        var ownership = ConversationRunInvocationOwnership()
        let run = UUID()
        let originalClaim = ownership.claim(run)
        let original = try #require(originalClaim)
        let oldFinished = ownership.finish(original)
        #expect(oldFinished)
        let newClaim = ownership.claim(run)
        let current = try #require(newClaim)
        #expect(original != current)
        let obsoleteFinished = ownership.finish(original)
        #expect(!obsoleteFinished)
        #expect(ownership.hasOwner(run))
        #expect(ownership.mayExecute(current))
        ownership.cancel(run)
        #expect(!ownership.mayExecute(current))
        #expect(ownership.hasOwner(run))
        let currentFinished = ownership.finish(current)
        #expect(currentFinished)
        #expect(!ownership.hasOwner(run))
    }

    @Test("Expiration completes managed scheduler handles before the first checkpoint await, exactly once")
    func expirationClosesWindowBeforeCheckpointing() async {
        var managed = true
        var events: [String] = []
        let completed = await ContinuedProcessingExpirationSequence.runIfManaged(
            drainAndCompleteIfManaged: {
                guard managed else { return false }
                managed = false
                events.append("window-completed")
                return true
            },
            persistRecoveryPoints: {
                #expect(events == ["window-completed"])
                events.append("checkpoint")
            })
        #expect(completed)
        let repeated = await ContinuedProcessingExpirationSequence.runIfManaged(
            drainAndCompleteIfManaged: { managed },
            persistRecoveryPoints: { events.append("duplicate-checkpoint") })
        #expect(!repeated)
        #expect(events == ["window-completed", "checkpoint"])
    }
}

/// These run the real coordinator and SQLite stores. Only the OS notification
/// center is replaced; no provider, guest or continued-processing task starts.
@Suite("Transient errors do not become terminal task notifications", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RunTerminalNotificationRecoveryTests {
    @MainActor private final class DeliveryProbe {
        var authorization: NotificationAuthorizationState = .authorized
        var sent: [TaskTerminalEvent] = []
        var visible: [String: TaskTerminalEvent] = [:]
        var removed: [String] = []
        var continuedCompletions: [Bool] = []
        var holdIdentifier: String?
        var heldAdd: CheckedContinuation<Void, Never>?
        func releaseAdd() { heldAdd?.resume(); heldAdd = nil }
        var delivery: TaskTerminalNotificationDelivery {
            .init(add: { [self] event in
                sent.append(event)
                if holdIdentifier == event.identifier {
                    await withCheckedContinuation { heldAdd = $0 }
                }
                visible[event.identifier] = event
            }, remove: { [self] identifiers in
                removed += identifiers
                for id in identifiers { visible[id] = nil }
            }, existing: { [self] in
                visible.values.map { .init(identifier: $0.identifier, deepLink: $0.deepLink) }
            }, persistsOutbox: false, authorization: { [self] in authorization })
        }
    }
    private struct Fixture {
        var environment: AppEnvironment
        var coordinator: BackgroundRunCoordinator
        var probe: DeliveryProbe
        var conversationID: UUID
        var runID: UUID
    }
    private func fixture(authorization: NotificationAuthorizationState = .authorized) async throws -> Fixture {
        let environment = AppEnvironment.preview(), probe = DeliveryProbe()
        try await environment.database.migrate()
        probe.authorization = authorization
        let coordinator = BackgroundRunCoordinator(environment: environment, notificationDelivery: probe.delivery)
        let conversationID = UUID(), runID = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: conversationID,
            title: "Notification lifecycle fixture", createdAt: now, updatedAt: now))
        try await environment.runStore.saveRun(.init(id: runID, conversationID: conversationID,
            state: "streamingModel", goal: "Complete only this owned round", startedAt: now.addingTimeInterval(-5)))
        coordinator.continuedTaskCompletionForTesting = { [weak probe] success in probe?.continuedCompletions.append(success) }
        coordinator.didStart(conversationID: conversationID, runID: runID,
            title: "Owned round", origin: .foregroundRecovery)
        await coordinator.refreshNotificationAuthorizationAndFlush()
        return .init(environment: environment, coordinator: coordinator, probe: probe,
            conversationID: conversationID, runID: runID)
    }
    private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition(), "The exact coordinator/SQLite observation did not settle")
    }
    private func cleanup(_ f: Fixture, additionalRuns: [UUID] = []) async {
        f.probe.releaseAdd()
        f.coordinator.runFinishValidationBarrierForTesting = nil
        for id in [f.runID] + additionalRuns where f.coordinator.hasActiveRunForTesting(id) {
            try? await f.environment.runStore.updateRunState(id: id, state: "cancelled", endedAt: Date())
            f.coordinator.didCancel(runID: id, message: nil)
        }
        await f.coordinator.waitForRunNotificationWorkForTesting()
        for id in [f.runID] + additionalRuns { await BackgroundWorkRegistry.shared.remove(id: id) }
    }

    @Test("A network or tool attempt failure keeps its owner and OS window; successful retry reports only completion")
    func networkRetryDoesNotFinishOrNotifyFailure() async throws {
        let f = try await fixture()
        do {
            f.coordinator.didUpdateTool(runID: f.runID, name: "workspace.readFile", outcome: .started)
            f.coordinator.didUpdateTool(runID: f.runID, name: "workspace.readFile", outcome: .finished(failed: true))
            f.coordinator.didFinish(runID: f.runID, succeeded: false, message: "Transient connection lost")
            await f.coordinator.waitForRunNotificationWorkForTesting()
            #expect(f.coordinator.hasActiveRunForTesting(f.runID))
            #expect(f.probe.sent.isEmpty && f.coordinator.queuedTerminalEventsForTesting.isEmpty)
            #expect(!f.probe.continuedCompletions.contains(false))
            try await f.environment.runStore.updateRunState(id: f.runID, state: "reconnecting", endedAt: nil)
            f.coordinator.didUpdateProgress(runID: f.runID, stage: "Reconnecting", progress: 34)
            try await f.environment.runStore.updateRunState(id: f.runID, state: "streamingModel", endedAt: nil)
            f.coordinator.didReceiveActivity(runID: f.runID, characters: 20)
            try await f.environment.runStore.updateRunState(id: f.runID, state: "completed", endedAt: Date())
            f.coordinator.didFinish(runID: f.runID, succeeded: true, message: "Verified result")
            try await waitFor { f.probe.sent.count == 1 }
            #expect(f.probe.sent.map(\.kind) == [.completed])
            #expect(!f.probe.continuedCompletions.contains(false))
            #expect(!f.coordinator.hasActiveRunForTesting(f.runID))
            try await waitFor { await BackgroundWorkRegistry.shared.snapshot(id: f.runID)?.state == .completed }
        } catch { await cleanup(f); throw error }
        await cleanup(f)
    }

    @Test("A proven failed run remains a failed notification, work record and OS completion")
    func durableFinalFailureRemainsVisible() async throws {
        let f = try await fixture()
        do {
            try await f.environment.runStore.updateRunState(id: f.runID, state: "failed", endedAt: Date())
            f.coordinator.didFinish(runID: f.runID, succeeded: false, message: "Retries exhausted")
            try await waitFor { f.probe.sent.count == 1 }
            #expect(f.probe.sent.first?.kind == .failed)
            #expect(f.probe.sent.first?.deepLink.runID == f.runID)
            #expect(f.probe.sent.first?.body.contains("Retries exhausted") == true)
            #expect(f.probe.continuedCompletions.filter { !$0 }.count == 1)
            #expect(!f.coordinator.hasActiveRunForTesting(f.runID))
            try await waitFor { await BackgroundWorkRegistry.shared.snapshot(id: f.runID)?.state == .failed }
        } catch { await cleanup(f); throw error }
        await cleanup(f)
    }

    @Test("A new round removes its old queued/delivered failure; a late add cannot restore it or affect another task")
    func supersededRunAlertsAndLateAddsAreRetired() async throws {
        for blockedAuthorization in [false, true] {
            let f = try await fixture(authorization: blockedAuthorization ? .denied : .authorized)
            let nextRun = UUID(), otherRun = UUID(), otherConversation = UUID()
            let oldID = "run.\(f.runID.uuidString).terminal"
            let foreign = TaskTerminalEvent.modelRunTerminal(runID: otherRun, conversationID: otherConversation,
                taskName: "Other task", kind: .failed, body: "Real unrelated failure")
            f.probe.visible[foreign.identifier] = foreign
            if !blockedAuthorization { f.probe.holdIdentifier = oldID }
            do {
                try await f.environment.runStore.updateRunState(id: f.runID, state: "failed", endedAt: Date())
                f.coordinator.didFinish(runID: f.runID, succeeded: false, message: "Earlier attempt ended")
                if blockedAuthorization {
                    try await waitFor { f.coordinator.queuedTerminalEventsForTesting.contains { $0.identifier == oldID } }
                } else { try await waitFor { f.probe.heldAdd != nil } }
                try await f.environment.runStore.saveRun(.init(id: nextRun, conversationID: f.conversationID,
                    state: "reconnecting", goal: "New current round", startedAt: Date()))
                f.coordinator.didStart(conversationID: f.conversationID, runID: nextRun,
                    title: "Current round", origin: .foregroundRecovery)
                f.probe.releaseAdd()
                await f.coordinator.waitForRunNotificationWorkForTesting()
                f.probe.authorization = .authorized
                await f.coordinator.refreshNotificationAuthorizationAndFlush()
                await f.coordinator.waitForRunNotificationWorkForTesting()
                #expect(f.coordinator.hasActiveRunForTesting(nextRun))
                #expect(f.probe.visible[oldID] == nil)
                #expect(!f.coordinator.queuedTerminalEventsForTesting.contains { $0.identifier == oldID })
                #expect(f.probe.visible[foreign.identifier] == foreign)
                // A duplicate old report must never finish the current owner.
                let failures = f.probe.continuedCompletions.filter { !$0 }.count
                f.coordinator.didFinish(runID: f.runID, succeeded: false, message: "Late old callback")
                await f.coordinator.waitForRunNotificationWorkForTesting()
                #expect(f.coordinator.hasActiveRunForTesting(nextRun))
                #expect(f.probe.continuedCompletions.filter { !$0 }.count == failures)
            } catch { await cleanup(f, additionalRuns: [nextRun]); throw error }
            await cleanup(f, additionalRuns: [nextRun])
        }
    }

    @Test("Resuming the same run fences an earlier failure read before any terminal side effect")
    func sameRunResumeRejectsInFlightFailureValidation() async throws {
        let f = try await fixture()
        let gate = ValidationGate()
        do {
            try await f.environment.runStore.updateRunState(id: f.runID, state: "failed", endedAt: Date())
            f.coordinator.runFinishValidationBarrierForTesting = { await gate.hold() }
            f.coordinator.didFinish(runID: f.runID, succeeded: false, message: "Obsolete attempt")
            try await waitFor { gate.entered }
            try await f.environment.runStore.updateRunState(id: f.runID, state: "reconnecting", endedAt: nil)
            f.coordinator.didStart(conversationID: f.conversationID, runID: f.runID,
                title: "Resuming same round", origin: .foregroundRecovery)
            f.coordinator.didUpdateProgress(runID: f.runID, stage: "Retrying", progress: 34)
            gate.release()
            await f.coordinator.waitForRunNotificationWorkForTesting()
            #expect(f.coordinator.hasActiveRunForTesting(f.runID))
            #expect(f.probe.sent.isEmpty && !f.probe.continuedCompletions.contains(false))
            #expect(try await f.environment.runStore.run(id: f.runID)?.state == "reconnecting")
        } catch { gate.release(); await cleanup(f); throw error }
        gate.release()
        await cleanup(f)
    }
    @MainActor private final class ValidationGate {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test("Stop reports cancellation; checkpointed work stays suspended and never creates a failure")
    func cancellationAndCheckpointNeverReportFailure() async throws {
        for checkpointed in [false, true] {
            let f = try await fixture()
            do {
                try await f.environment.runStore.updateRunState(id: f.runID,
                    state: checkpointed ? "checkpointed" : "cancelled", endedAt: Date())
                if checkpointed {
                    f.coordinator.didFinish(runID: f.runID, succeeded: false, message: "Transport cleanup after checkpoint")
                    await f.coordinator.waitForRunNotificationWorkForTesting()
                    #expect(f.coordinator.hasActiveRunForTesting(f.runID) && f.coordinator.runIsSuspendedForTesting(f.runID))
                    #expect(f.probe.sent.isEmpty && f.coordinator.queuedTerminalEventsForTesting.isEmpty)
                } else {
                    f.coordinator.didCancel(runID: f.runID, message: nil)
                    try await waitFor { f.probe.sent.count == 1 }
                    #expect(f.probe.sent.first?.kind == .cancelled)
                    #expect(!f.coordinator.hasActiveRunForTesting(f.runID))
                }
                #expect(!f.probe.continuedCompletions.contains(false))
                #expect(f.probe.sent.allSatisfy { $0.kind != .failed })
            } catch { await cleanup(f); throw error }
            await cleanup(f)
        }
    }
}
#endif
