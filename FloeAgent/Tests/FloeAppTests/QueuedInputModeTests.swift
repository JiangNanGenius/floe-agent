// FloeAppTests — Running-message behavior: the global steer/queue mode is
// only consulted while a run is active (idle sends execute immediately),
// and a pending message's three-dot menu migrates its mode both ways only
// before consumption. Consumed guidance can never be disguised as a queue
// row. Fixtures are synthetic; no provider calls are made.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeProviders
@testable import FloeApp

@Suite("FloeApp.QueuedInputMode")
@MainActor
struct QueuedInputModeTests {

    // MARK: - Send dispatch: idle executes directly, active run routes

    @Test("Idle executes immediately; an active run routes with the resolved mode")
    func sendRouteFollowsRunActivity() {
        #expect(RunningInputModePolicy.sendRoute(isRunActive: false, mode: .steer) == .executeImmediately)
        #expect(RunningInputModePolicy.sendRoute(isRunActive: false, mode: .queue) == .executeImmediately)
        #expect(RunningInputModePolicy.sendRoute(isRunActive: true, mode: .queue) == .runningInput(.queue))
        #expect(RunningInputModePolicy.sendRoute(isRunActive: true, mode: .steer) == .runningInput(.steer))
    }

    @Test("An opened thread follows the global steer/queue default live; explicit thread choice wins")
    func openedThreadFollowsGlobalModeUntilExplicitChoice() async throws {
        let fixture = try await makeFixture()
        let conversation = try await fixture.center.createConversation(title: "thread")
        let viewModel = ThreadDetailViewModel(conversationID: conversation.id, center: fixture.center)
        // Fresh thread starts from the current global default.
        #expect(viewModel.runningInputMode == .queue)
        // A global settings change reaches the ALREADY-OPEN thread without
        // reload — the value send() captures is never stale.
        try await fixture.environment.settingsCenter.setRunningInputMode(.steer)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.runningInputMode == .steer)
        // The composer's explicit per-thread choice is preserved for this
        // thread even when the global default changes again.
        viewModel.selectRunningInputMode(.queue)
        try await fixture.environment.settingsCenter.setRunningInputMode(.steer)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.runningInputMode == .queue)
        // The real send dispatch consumes the resolved mode both ways:
        // idle executes directly, an active run routes through it.
        #expect(RunningInputModePolicy.sendRoute(
            isRunActive: false, mode: viewModel.runningInputMode) == .executeImmediately)
        #expect(RunningInputModePolicy.sendRoute(
            isRunActive: true, mode: viewModel.runningInputMode) == .runningInput(.queue))
    }

    // MARK: - Three-dot menu actions

    @Test("Mode actions: queued can steer, pending steer can return, consumed offers nothing")
    func menuActionsFollowConsumptionBoundary() {
        #expect(RunningInputModePolicy.modeActions(status: .queued, canSteer: true) == [.promoteToSteer])
        #expect(RunningInputModePolicy.modeActions(status: .queued, canSteer: false) == [])
        #expect(RunningInputModePolicy.modeActions(status: .steerPending, canSteer: false) == [.demoteToQueue])
        #expect(RunningInputModePolicy.modeActions(status: .steerPending, canSteer: true) == [.demoteToQueue])
        #expect(RunningInputModePolicy.modeActions(status: .promoting, canSteer: true) == [])
        #expect(RunningInputModePolicy.modeActions(status: .consumed, canSteer: true) == [])
        #expect(RunningInputModePolicy.modeActions(status: .cancelled, canSteer: true) == [])
    }

    // MARK: - Center boundary with the real durable store

    private final class Fixture: @unchecked Sendable {
        let environment: AppEnvironment
        let center: ConversationCenter

        @MainActor
        init() throws {
            environment = AppEnvironment.preview()
            center = ConversationCenter(environment: environment)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let fixture = try Fixture()
        try await fixture.environment.database.migrate()
        return fixture
    }

    @Test("Demote withdraws an unconsumed steer back to the queue, content intact")
    func demoteSteerToQueuedWithdrawsBeforeConsumption() async throws {
        let fixture = try await makeFixture()
        let store = fixture.environment.runningInputStore
        let conversation = try await fixture.center.createConversation(title: "thread")
        let runID = UUID()
        try await fixture.environment.runStore.saveRun(RunRecord(
            id: runID, conversationID: conversation.id,
            state: "streamingModel", goal: "goal", startedAt: Date()))
        let input = try await store.enqueue(PendingUserInput(
            conversationID: conversation.id, content: "QUEUE-THEN-STEER-THEN-QUEUE"))
        let promoted = try #require(await store.beginSteerPromotion(
            id: input.id, expectedRunID: runID))
        #expect(promoted.status == .promoting)
        try await store.markSteerAccepted(id: input.id, runID: runID)
        let pending = try #require(await store.input(id: input.id))
        #expect(pending.status == .steerPending)
        #expect(pending.mode == .steer)

        try await fixture.center.demoteSteerToQueued(id: input.id)

        let restored = try #require(await store.input(id: input.id))
        #expect(restored.status == .queued)
        #expect(restored.mode == .queue)
        #expect(restored.targetRunID == nil)
        #expect(restored.content == "QUEUE-THEN-STEER-THEN-QUEUE")
        // The row is pending again for this conversation.
        let visible = try await store.pending(conversationID: conversation.id)
        #expect(visible.contains { $0.id == input.id && $0.status == .queued })
        // A queued row cannot demote again — the boundary is exact.
        await #expect(throws: (any Error).self) {
            try await fixture.center.demoteSteerToQueued(id: input.id)
        }
    }

    @Test("Mode migration is bidirectional and persists through the durable row")
    func modeMigrationRoundTripsThroughStore() async throws {
        let fixture = try await makeFixture()
        let store = fixture.environment.runningInputStore
        let conversation = try await fixture.center.createConversation(title: "thread")
        let runID = UUID()
        try await fixture.environment.runStore.saveRun(RunRecord(
            id: runID, conversationID: conversation.id,
            state: "streamingModel", goal: "goal", startedAt: Date()))
        let input = try await store.enqueue(PendingUserInput(
            conversationID: conversation.id, content: "ROUND-TRIP"))
        for round in 1...2 {
            _ = try #require(await store.beginSteerPromotion(id: input.id, expectedRunID: runID))
            try await store.markSteerAccepted(id: input.id, runID: runID)
            let steered = try #require(await store.input(id: input.id))
            #expect(steered.status == .steerPending, "round \(round)")
            try await fixture.center.demoteSteerToQueued(id: input.id)
            let queued = try #require(await store.input(id: input.id))
            #expect(queued.status == .queued, "round \(round)")
            #expect(queued.mode == .queue, "round \(round)")
        }
    }

    @Test("A consumed steer can never be disguised as a queued row")
    func consumedSteerCannotBeDisguisedAsQueued() async throws {
        let fixture = try await makeFixture()
        let store = fixture.environment.runningInputStore
        let conversation = try await fixture.center.createConversation(title: "thread")
        let input = try await store.enqueue(PendingUserInput(
            conversationID: conversation.id, content: "CONSUMED-BOUNDARY"))
        let runID = UUID()
        try await fixture.environment.runStore.saveRun(RunRecord(
            id: runID, conversationID: conversation.id,
            state: "streamingModel", goal: "goal", startedAt: Date()))
        _ = try #require(await store.beginSteerPromotion(id: input.id, expectedRunID: runID))
        try await store.markSteerAccepted(id: input.id, runID: runID)
        try await store.markConsumed(id: input.id, runID: runID)

        await #expect(throws: (any Error).self) {
            try await fixture.center.demoteSteerToQueued(id: input.id)
        }
        let after = try #require(await store.input(id: input.id))
        #expect(after.status == .consumed)
        #expect(after.consumedRunID == runID)
        // Not pending any more: it left the visible queue.
        let visible = try await store.pending(conversationID: conversation.id)
        #expect(!visible.contains { $0.id == input.id })
    }

    @Test("Demoting a cancelled row throws and never resurrects it")
    func cancelledRowCannotDemote() async throws {
        let fixture = try await makeFixture()
        let store = fixture.environment.runningInputStore
        let conversation = try await fixture.center.createConversation(title: "thread")
        let input = try await store.enqueue(PendingUserInput(
            conversationID: conversation.id, content: "CANCELLED-BOUNDARY"))
        try await store.cancel(id: input.id)
        await #expect(throws: (any Error).self) {
            try await fixture.center.demoteSteerToQueued(id: input.id)
        }
        let cancelled = try await store.input(id: input.id)
        #expect(cancelled?.status == .cancelled)
    }

    @Test("Demote of a missing input is an actionable not-found")
    func demoteMissingInputThrows() async throws {
        let fixture = try await makeFixture()
        await #expect(throws: (any Error).self) {
            try await fixture.center.demoteSteerToQueued(id: UUID())
        }
    }
}

@Suite("Goal composer and controls")
@MainActor
struct GoalComposerTests {
    private struct Fixture {
        let environment: AppEnvironment
        let center: ConversationCenter
        let modelID: UUID?
    }

    private func fixture(configured: Bool = true) async throws -> Fixture {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = ConversationCenter(environment: environment)
        center.localModelDiscoveryOverrideForTesting = {}
        center.providerAdapterTestOverride = { _, _ in GoalComposerIdleProvider() }
        guard configured else { return Fixture(environment: environment, center: center, modelID: nil) }
        let provider = ProviderProfile(kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://goal-composer.invalid/v1")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "goal-composer",
            displayName: "Goal composer fixture", limits: .init(contextTokens: 8192, maxOutputTokens: 1024),
            capabilities: [.text, .tools])
        try await environment.configurationStore.saveProvider(provider)
        try await environment.configurationStore.saveModel(model)
        var preferences = try await environment.configurationStore.preferences()
        preferences.defaultAgentModelID = model.id
        try await environment.configurationStore.savePreferences(preferences)
        await center.reload()
        return Fixture(environment: environment, center: center, modelID: model.id)
    }

    private func waitForStopped(_ f: Fixture, runID: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let run = try await f.environment.runStore.run(id: runID), run.endedAt != nil,
               !f.center.hasLiveOwner(runID: runID) { return }
            await Task.yield()
        }
        throw FloeError.validationFailed("The selected owned round did not stop")
    }

    @Test("Goal setup resets only the composer; pause/resume preserves the same durable goal")
    func successfulSetupThenPauseResumeKeepsGoalAndAgentComposer() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Goal composer")
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        view.selectedModelID = f.modelID
        await view.load()
        view.selectAgentMode(.goal)
        view.draft = "Keep this separate unsent draft"
        let created = await view.createGoal(objective: "Preserve the actual goal", criteria: ["Inspect the result"],
            blockingConditions: ["Ask before sending"], stoppingConditions: ["Result confirmed"])
        #expect(created)
        let goal = try #require(view.activeGoal)
        let firstRunID = try #require(view.selectedRunID)
        let firstRun = try #require(try await f.environment.runStore.run(id: firstRunID))
        #expect(firstRun.conversationMode == AgentExecutionMode.goal.conversationMode.rawValue)
        #expect(view.agentMode == .agent && view.draft == "Keep this separate unsent draft")
        #expect(goal.status == .active && goal.conversationID == conversation.id)

        await view.pauseActiveGoal()
        let paused = try #require(try await f.environment.intelligenceStore.goal(id: goal.id))
        #expect(paused.status == .paused && view.activeGoal?.id == goal.id)
        #expect(paused.steps == goal.steps && paused.acceptanceCriteria == goal.acceptanceCriteria)
        #expect(paused.evidence == goal.evidence && paused.progress.startedAt == goal.progress.startedAt)
        #expect(view.canResumeGoal && !view.canContinue)
        #expect(view.goalStatusTitle(.paused) != GoalStatus.paused.rawValue)
        #expect(!view.goalStatusTitle(.paused).hasPrefix("goal.status."))

        await view.resumeActiveGoal()
        let resumed = try #require(try await f.environment.intelligenceStore.goal(id: goal.id))
        let nextRunID = try #require(view.selectedRunID)
        let nextRun = try #require(try await f.environment.runStore.run(id: nextRunID))
        #expect(resumed.id == goal.id && resumed.conversationID == conversation.id && resumed.status == .active)
        #expect(resumed.steps == goal.steps && resumed.evidence == goal.evidence)
        #expect(nextRunID == firstRunID && nextRun.conversationID == conversation.id && nextRun.endedAt == nil)
        #expect(f.center.hasLiveOwner(runID: firstRunID))
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
        #expect(nextRun.conversationMode == AgentExecutionMode.goal.conversationMode.rawValue)
        #expect(view.agentMode == .agent && view.draft == "Keep this separate unsent draft")
        await view.cancel()
        try await waitForStopped(f, runID: firstRunID)
        #expect(try await f.environment.intelligenceStore.goal(id: goal.id)?.status == .paused)
        #expect(try await f.environment.runStore.run(id: firstRunID)?.state == "cancelled")
        #expect(view.agentMode == .agent && view.draft == "Keep this separate unsent draft")
    }

    @Test("A saved goal whose launch fails keeps its draft and retries the same goal identity")
    func failedSetupPreservesGoalModeAndDraft() async throws {
        for useGoalControl in [false, true] {
            let f = try await fixture()
            let conversation = try await f.center.createConversation(title: "Goal failure")
            let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
            await view.load()
            view.selectedModelID = f.modelID
            view.selectAgentMode(.goal)
            view.draft = "  original draft  "
            // A real missing workspace rejects the launch AFTER GoalStore
            // saved the goal. Both recovery entries must finish that setup.
            view.selectedProjectID = UUID()
            let created = await view.createGoal(objective: "New goal still in the form", criteria: [],
                blockingConditions: [], stoppingConditions: [])
            #expect(!created && view.agentMode == .goal && view.draft == "  original draft  ")
            let original = try #require(view.activeGoal)
            #expect(view.actionError != nil)
            let saved = try await f.environment.intelligenceStore.goals(conversationID: conversation.id)
            #expect(saved.count == 1 && saved.first?.id == original.id)
            let persistedStartedAt = try #require(saved.first?.progress.startedAt)
            #expect(try await f.environment.runStore.recentRuns(conversationID: conversation.id, limit: 10).isEmpty)
            view.selectedProjectID = nil
            if useGoalControl {
                await view.resumeActiveGoal()
            } else {
                let retried = await view.createGoal(objective: "New goal still in the form", criteria: [],
                    blockingConditions: [], stoppingConditions: [])
                #expect(retried)
            }
            #expect(view.agentMode == .agent && view.draft == "  original draft  ")
            let after = try await f.environment.intelligenceStore.goals(conversationID: conversation.id)
            #expect(after.count == 1 && after.first?.id == original.id && view.activeGoal?.id == original.id)
            #expect(after.first?.progress.startedAt == persistedStartedAt)
            #expect(view.selectedRun?.conversationMode == AgentExecutionMode.goal.conversationMode.rawValue)
            await view.pauseActiveGoal()
            let pausedRunID = try #require(view.selectedRunID)
            #expect(f.center.hasLiveOwner(runID: pausedRunID))
            #expect(try await f.environment.runStore.run(id: pausedRunID)?.endedAt == nil)
            #expect(try await f.environment.intelligenceStore.goal(id: original.id)?.status == .paused)
            await view.cancel()
            try await waitForStopped(f, runID: pausedRunID)
            #expect(try await f.environment.intelligenceStore.goal(id: original.id)?.status == .paused)

            // A terminal stored fixture isolates pending-composer cleanup;
            // it does not claim to exercise the evidence completion gate.
            var finished = try #require(try await f.environment.intelligenceStore.goal(id: original.id))
            finished.status = .completed
            finished.updatedAt = Date()
            try await f.environment.intelligenceStore.saveGoal(finished)
            await view.load()
            view.selectAgentMode(.goal)
            let nextCreated = await view.createGoal(objective: "A separate next goal", criteria: [],
                blockingConditions: [], stoppingConditions: [])
            #expect(nextCreated)
            let goals = try await f.environment.intelligenceStore.goals(conversationID: conversation.id)
            #expect(goals.count == 2 && goals.contains { $0.id == original.id && $0.status == .completed })
            let next = try #require(goals.first { $0.id != original.id })
            #expect(view.activeGoal?.id == next.id)
            #expect(view.agentMode == .agent)

            // Make the actual whole-second SQL ordering tie deterministic.
            // Only fixture timestamps change; identities, status and progress
            // stay intact. No sleep or product clock workaround is involved.
            let sameStoredTime = Date(timeIntervalSince1970: 1_800_000_000)
            for var snapshot in goals {
                snapshot.updatedAt = sameStoredTime
                try await f.environment.intelligenceStore.saveGoal(snapshot)
            }
            let tied = try await f.environment.intelligenceStore.goals(conversationID: conversation.id)
            #expect(Set(tied.map(\.updatedAt)).count == 1)
            await view.load()
            #expect(view.activeGoal?.id == next.id && view.activeGoal?.status == .active)
            #expect(view.agentMode == .agent)
            await view.cancel()
            try await waitForStopped(f, runID: try #require(view.selectedRunID))
        }
    }

    @Test("Load never rearms a blocked Goal; explicit Continue resumes only the same round")
    func blockedGoalDoesNotResumeWhenComposerLoads() async throws {
        for status in [GoalStatus.blocked, .paused] {
            let f = try await fixture()
            let conversation = try await f.center.createConversation(title: "Stopped goal")
            var goal = ConversationGoal(conversationID: conversation.id, objective: "Wait for the required file",
                blockingConditions: ["Required file is missing"], acceptanceCriteria: [], steps: [], status: status)
            goal.progress.repeatedBlockerKey = "user-condition:Required file is missing"
            goal.progress.repeatedBlockerCount = 3
            try await f.environment.intelligenceStore.saveGoal(goal)
            let pair = try #require(f.center.providerAndModel(modelID: f.modelID))
            let prior = RunRecord(id: UUID(), conversationID: conversation.id,
                state: status == .paused ? "interrupted" : "failed", goal: goal.objective,
                startedAt: Date(), endedAt: Date(), goalID: goal.id,
                providerID: pair.0.id, modelID: pair.1.id,
                conversationMode: AgentExecutionMode.goal.conversationMode.rawValue)
            try await f.environment.runStore.saveRun(prior)
            let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
            view.selectedRunID = prior.id
            await view.load()
            #expect(view.activeGoal?.status == status && view.canResumeGoal && view.canContinue)
            #expect(!f.center.hasLiveOwner(runID: prior.id))
            #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
            if status == .blocked {
                #expect(view.goalBlockedReason(goal)?.isEmpty == false)
                #expect(view.goalBlockedReason(goal)?.contains("user-condition:") == false)
            }
            // Continue is an explicit same-run action, not Goal Resume.
            // It must not create a cycle or reactivate long-term advancement.
            await view.retry()
            #expect(view.actionError == nil)
            let runs = try await f.environment.runStore.recentRuns(conversationID: conversation.id, limit: 10)
            #expect(runs.count == 1 && runs.first?.id == prior.id && runs.first?.goal == prior.goal)
            #expect(view.selectedRunID == prior.id && f.center.hasLiveOwner(runID: prior.id))
            #expect(try await f.environment.intelligenceStore.goal(id: goal.id)?.status == status)
            await view.cancel()
            try await waitForStopped(f, runID: prior.id)
            #expect(try await f.environment.intelligenceStore.goal(id: goal.id)?.status == .paused)
        }
    }

    @Test("Home resets a goal input only after launch succeeds")
    func homeGoalInputResetsOnlyAfterSuccess() async throws {
        for fails in [false, true] {
            let f = try await fixture()
            let view = HomeLaunchpadViewModel(center: f.center,
                taskStarter: fails ? GoalComposerRejectedLaunch() : nil,
                draftStorageID: UUID(), initialDraft: "Home goal")
            view.selectedModelID = f.modelID
            view.agentMode = .goal
            let conversationID = await view.sendNewTask()
            if fails {
                #expect(conversationID == nil && view.agentMode == .goal && view.draft == "Home goal")
            } else {
                let id = try #require(conversationID)
                let run = try #require(try await f.environment.runStore.recentRuns(conversationID: id, limit: 10).first)
                #expect(view.agentMode == .agent)
                #expect(run.conversationMode == AgentExecutionMode.goal.conversationMode.rawValue)
                await f.center.cancel(runID: run.id)
            }
        }
    }
}

/// The real launch/store path runs, while the scripted transport waits until
/// cancellation. No network, credential, Linux activation or paid model is used.
private struct GoalComposerIdleProvider: ProviderAdapter {
    var protocolKind: ModelProtocol { .openAIChatCompletions }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { _ in }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

private struct GoalComposerRejectedLaunch: HomeTaskStarting {
    struct Rejected: Error {}
    func startTask(goal: String, modelID: UUID?) async throws -> UUID { throw Rejected() }
}
#endif
