#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
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
#endif
