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
#endif
