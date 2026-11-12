// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
@testable import FloePersistence
import FloeTestSupport

@Suite("Admitted Goal round and long-term control", .serialized)
struct GoalCurrentRoundContractTests {
    private struct Fixture: Sendable {
        let database: DatabaseManager
        let conversations: SQLiteConversationStore
        let runs: SQLiteRunStore
        let goals: SQLiteIntelligenceStore
        let conversationID: UUID
        let runID: UUID
        let userMessageID: UUID
        let original: ConversationGoal
        let frozenObjective: String
    }
    private func fixture(legacy: Bool = false) async throws -> Fixture {
        let db = try DatabaseManager.inMemory(); try await db.migrate()
        let conversations = SQLiteConversationStore(database: db), runs = SQLiteRunStore(database: db)
        let goals = SQLiteIntelligenceStore(database: db)
        let conversationID = UUID(), runID = UUID(), now = Date()
        try await conversations.saveConversation(.init(id: conversationID, title: "Owned Goal round", createdAt: now, updatedAt: now))
        let goal = ConversationGoal(conversationID: conversationID, objective: "Original long-term definition",
            acceptanceCriteria: [.init(text: "Original criterion")], steps: [.init(title: "Original step", order: 0)], status: .active,
            budgets: .init(maxCycles: 5, maxModelCalls: 10, maxParentIterationsPerCycle: 8))
        try await goals.saveGoal(goal)
        let objective = "Execute this admitted original round without changing its task or permissions"
        let userMessageID: UUID
        if legacy {
            var run = RunRecord(id: runID, conversationID: conversationID, state: "preparing", goal: objective, startedAt: now, conversationMode: "goal")
            run.goalID = goal.id; try await runs.saveRun(run)
            _ = try await runs.appendEvent(runID: runID, kind: .status, payloadJSON: #"{"state":"preparing"}"#)
            userMessageID = UUID()
            try await conversations.appendMessage(.init(id: userMessageID, conversationID: conversationID, role: "user", content: objective, createdAt: now, runID: runID))
        } else {
            let prepared = try await SQLiteRunLaunchStore(database: db).prepare(.init(conversationID: conversationID,
                runID: runID, goal: objective, conversationMode: "goal", goalID: goal.id,
                expectedGoalRevision: goal.revision ?? 1, goalDefinitionFingerprint: try GoalRunDefinitionFingerprint.make(goal)))
            userMessageID = prepared.userMessage.id
        }
        return .init(database: db, conversations: conversations, runs: runs, goals: goals,
            conversationID: conversationID, runID: runID, userMessageID: userMessageID,
            original: goal, frozenObjective: objective)
    }
    private func service(_ f: Fixture, adapter: any ProviderAdapter, executor: MockExecutor = MockExecutor(),
                         checkpoints: MockCheckpointStore = MockCheckpointStore()) -> ConversationRunService {
        let provider = TestFixtures.localhostProvider()
        return ConversationRunService(configuration: .init(conversationID: f.conversationID, provider: provider,
                model: TestFixtures.testModel(providerID: provider.id), conversationMode: .goal,
                goalBudgets: f.original.budgets, verifyFinalAnswer: false),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: executor, checkpointStore: checkpoints,
            contextEngine: nil, intelligenceStore: f.goals, conversationStore: f.conversations, runStore: f.runs, runID: f.runID)
    }

    @Test func admittedPauseDeleteAndDefinitionEditDoNotTerminateTheCurrentRound() async throws {
        for control in ["active", "paused", "cancelled", "edited"] {
            let f = try await fixture()
            var changed = f.original
            changed.status = control == "paused" ? .paused : control == "cancelled" ? .cancelled : .active
            changed.budgets.maxModelCalls = 1
            if control == "edited" {
                changed.objective = "New definition for future rounds"
                changed.acceptanceCriteria = [.init(text: "New criterion needs separate evidence", requiresUserConfirmation: true)]
                changed.steps = [.init(title: "New future step", order: 0)]
            }
            #expect(try await f.goals.saveGoalIfRevisionMatches(changed, expectedRevision: 1))
            let expected = try #require(try await f.goals.goal(id: changed.id))
            var newGoal: ConversationGoal?
            if control == "cancelled" {
                let other = ConversationGoal(conversationID: f.conversationID, objective: "Independent newer Goal B",
                    acceptanceCriteria: [.init(text: "B evidence")], steps: [], status: .active)
                try await f.goals.saveGoal(other); newGoal = try #require(try await f.goals.goal(id: other.id))
            }
            let call = try TestFixtures.toolCall(id: "real-native-proof", toolName: "test.nativeProof")
            let adapter = MockAdapter(); adapter.script = [[.toolRequest(call)], [.textDelta(.init(text: "This round is complete.")), .completed(.init(stopReason: .endTurn))]]
            let executor = MockExecutor(); executor.descriptors[call.toolName] = .init(name: call.toolName, riskLabels: [], isSideEffecting: false)
            let run = service(f, adapter: adapter, executor: executor)
            try await run.startPrepared(goal: f.frozenObjective, userMessageID: f.userMessageID)
            let savedRun = try #require(try await f.runs.run(id: f.runID))
            let saved = try #require(try await f.goals.goal(id: f.original.id))
            #expect(savedRun.state == "completed" && savedRun.goalID == f.original.id && savedRun.goal == f.frozenObjective)
            #expect(executor.executedCalls.count == 1 && adapter.requests.count == 2)
            #expect(saved.status == (control == "active" ? .verifying : expected.status) && saved.objective == expected.objective && saved.budgets == expected.budgets)
            #expect(saved.acceptanceCriteria == expected.acceptanceCriteria && saved.steps == expected.steps)
            #expect(saved.progress.modelCallCount == 2 && saved.progress.totalIterationCount == 1 && saved.progress.cycleCount == 1)
            #expect(saved.evidence.contains { $0.reference.hasPrefix("run:\(f.runID.uuidString):event:") })
            let events = try await f.runs.events(runID: f.runID)
            #expect(events.last?.kind == .terminal)
            let receipt = try #require(events.first { $0.kind == .toolResult })
            var mixedReceipt = try #require(JSONSerialization.jsonObject(with: Data(receipt.payloadJSON.utf8)) as? [String: Any])
            mixedReceipt["dispatched"] = true; mixedReceipt["durationMs"] = 7
            let projected = try JSONDecoder().decode(GoalRunEventPayload.self, from: JSONSerialization.data(withJSONObject: mixedReceipt))
            #expect(projected.dispatched && projected.status == "ok" && projected.id == call.id)
            if let newGoal { #expect(try await f.goals.goal(id: newGoal.id) == newGoal) }
        }
    }

    @Test func sameRunContinueKeepsPausedDeletedAndLegacyGoalHistoryWithoutReactivation() async throws {
        for control in ["paused", "cancelled", "legacy"] {
            let f = try await fixture(legacy: control == "legacy")
            var changed = f.original
            changed.status = control == "paused" ? .paused : control == "cancelled" ? .cancelled : .active
            #expect(try await f.goals.saveGoalIfRevisionMatches(changed, expectedRevision: 1))
            var savedRun = try #require(try await f.runs.run(id: f.runID))
            savedRun.state = "checkpointed"; savedRun.endedAt = Date(); try await f.runs.saveRun(savedRun)
            let checkpoint = AgentCheckpoint(runID: f.runID, conversationID: f.conversationID,
                state: .preparing(.init(goal: f.frozenObjective)),
                messages: [.init(id: f.userMessageID, role: "user", content: f.frozenObjective)],
                createdAt: Date(), goalID: f.original.id)
            let adapter = MockAdapter(); adapter.script = [[.textDelta(.init(text: "The same round continued.")), .completed(.init(stopReason: .endTurn))]]
            try await service(f, adapter: adapter).resumePrepared(from: checkpoint)
            let goal = try #require(try await f.goals.goal(id: f.original.id))
            #expect(goal.status == changed.status && goal.progress.cycleCount == 1 && goal.progress.modelCallCount == 1)
            #expect(try await f.runs.run(id: f.runID)?.state == "completed")
            #expect(try await f.runs.run(id: f.runID)?.goalID == f.original.id)
            #expect(try await f.goals.goals(conversationID: f.conversationID).count == 1)
            #expect(try await f.conversations.messages(conversationID: f.conversationID).filter { $0.role == "user" }.count == 1)
        }
    }

    @Test func invalidExactBindingFailsClosedWithoutCreatingOrAssigningAnotherGoal() async throws {
        for invalidBinding in ["foreign", "missing"] {
            let f = try await fixture()
            var foreignSaved: ConversationGoal?
            if invalidBinding == "foreign" {
                let otherConversationID = UUID(), now = Date()
                try await f.conversations.saveConversation(.init(id: otherConversationID, title: "Other owner", createdAt: now, updatedAt: now))
                let foreign = ConversationGoal(conversationID: otherConversationID, objective: "Foreign Goal", acceptanceCriteria: [], steps: [], status: .active)
                try await f.goals.saveGoal(foreign)
                foreignSaved = try #require(try await f.goals.goal(id: foreign.id))
                try await f.runs.assignGoal(runID: f.runID, goalID: foreign.id)
            } else {
                var deleted = f.original; deleted.status = .cancelled
                #expect(try await f.goals.saveGoalIfRevisionMatches(deleted, expectedRevision: 1))
                let exactRunID = f.runID
                // Corrupt only the binding in this owned in-memory fixture;
                // the durable original admission must prevent replacement.
                try await f.database.writer { db in
                    try db.execute(sql: "UPDATE runs SET goal_id=NULL WHERE id=?", arguments: [exactRunID.uuidString])
                }
            }
            let originalBefore = try #require(try await f.goals.goal(id: f.original.id))
            let adapter = MockAdapter(); adapter.script = [[.textDelta(.init(text: "Must not run")), .completed(.init(stopReason: .endTurn))]]
            do {
                try await service(f, adapter: adapter).startPrepared(goal: f.frozenObjective, userMessageID: f.userMessageID)
                Issue.record("An invalid exact Goal binding was admitted")
            } catch { }
            #expect(adapter.requests.isEmpty)
            #expect(try await f.runs.run(id: f.runID)?.goalID == foreignSaved?.id)
            #expect(try await f.goals.goals(conversationID: f.conversationID).map(\.id) == [f.original.id])
            #expect(try await f.goals.goal(id: f.original.id) == originalBefore)
            if let foreignSaved { #expect(try await f.goals.goal(id: foreignSaved.id) == foreignSaved) }
        }
    }

    @Test func stopSettlesPartialUsageAndExplicitSameRunContinueNeverRearmsTheGoal() async throws {
        let f = try await fixture()
        let gate = AsyncGate(), checkpoints = MockCheckpointStore()
        let adapter = HookedAdapter()
        adapter.script = [[.textDelta(.init(text: "Current round is running.")), .textDelta(.init(text: "Held provider response")), .completed(.init(stopReason: .endTurn))]]
        adapter.streamHook = { request, event in if request == 0 && event == 1 { await gate.wait() } }
        let run = service(f, adapter: adapter, checkpoints: checkpoints)
        let work = Task { try await run.startPrepared(goal: f.frozenObjective, userMessageID: f.userMessageID) }
        defer { gate.open(); work.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while gate.parkedCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.parkedCount == 1)
        var paused = try #require(try await f.goals.goal(id: f.original.id))
        let revision = paused.revision ?? 1; paused.status = .paused
        #expect(try await f.goals.saveGoalIfRevisionMatches(paused, expectedRevision: revision))
        await run.cancel()
        gate.open()
        do { try await work.value } catch is CancellationError { }
        let stopped = try #require(try await f.goals.goal(id: f.original.id))
        #expect(stopped.status == .paused && stopped.progress.modelCallCount == 1 && stopped.progress.cycleCount == 0)
        #expect(try await f.runs.run(id: f.runID)?.state == "checkpointed")
        let stoppedSnapshot = await run.snapshot()
        #expect(adapter.requests.count == 1 && stoppedSnapshot.isTerminal)
        let checkpoint = try #require(try await checkpoints.load(runID: f.runID))
        let resumed = MockAdapter(); resumed.script = [[.textDelta(.init(text: "Explicit same-round continuation completed.")), .completed(.init(stopReason: .endTurn))]]
        try await service(f, adapter: resumed, checkpoints: checkpoints).resumePrepared(from: checkpoint)
        let completed = try #require(try await f.goals.goal(id: f.original.id))
        #expect(completed.status == .paused && completed.progress.modelCallCount == 2 && completed.progress.cycleCount == 1)
        #expect(try await f.runs.events(runID: f.runID).last?.kind == .terminal)
        let replay = GoalRunSettlementInput(runID: f.runID, conversationID: f.conversationID, goalID: f.original.id,
            admissionRevision: 1, admissionDefinitionFingerprint: try GoalRunDefinitionFingerprint.make(f.original),
            modelCallCount: 2, toolIterationCount: 0, evidence: [], completed: true)
        let result = try #require(try await SQLiteIntelligenceStore(database: f.database).settleGoalRun(replay))
        #expect(!result.didRecordChange && result.goal == completed)
        #expect(try await f.goals.goal(id: f.original.id) == completed)
    }
}
