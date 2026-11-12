// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeProviders
import FloeTools
@testable import FloeApp

@MainActor @Suite("Home Plan and explicit Goal controls", .serialized, .timeLimit(.minutes(1)))
struct PlanGoalControlTests {
    private nonisolated final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ProviderStreamRequest] = []
        private var streams: [AsyncThrowingStream<AgentEvent, Error>.Continuation] = []
        private var configuredBudgets: [UUID: GoalBudgets] = [:]
        func recordBudget(runID: UUID, budget: GoalBudgets?) { lock.withLock { configuredBudgets[runID] = budget } }
        func budget(runID: UUID) -> GoalBudgets? { lock.withLock { configuredBudgets[runID] } }
        func append(_ value: ProviderStreamRequest, stream: AsyncThrowingStream<AgentEvent, Error>.Continuation) {
            lock.withLock { values.append(value); streams.append(stream) }
        }
        var all: [ProviderStreamRequest] { lock.withLock { values } }
        func complete(at index: Int) -> Bool {
            let stream = lock.withLock { streams.indices.contains(index) ? streams[index] : nil }
            guard let stream else { return false }
            stream.yield(.textDelta(.init(text: "The owned round finished without an external action.")))
            stream.yield(.completed(.init(stopReason: .endTurn)))
            stream.finish()
            return true
        }
    }
    private nonisolated struct IdleProvider: ProviderAdapter {
        let requests: Requests
        var protocolKind: ModelProtocol { .openAIChatCompletions }
        func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            // The automatic-effort hop is real but is not the admitted
            // round. Answer its exact native contract instead of parking it
            // or recording it as the Plan/Goal provider request.
            if request.reasoningPolicy == .disabled, request.toolSchemas.isEmpty,
               request.effectiveMessages.contains(ProviderMessage(role: "system",
                   text: AutomaticReasoningEffortAuxiliaryClassifier.instructions)) {
                return AsyncThrowingStream { continuation in
                    continuation.yield(.textDelta(.init(text: #"{"effort":"low"}"#)))
                    continuation.yield(.completed(.init(stopReason: .endTurn)))
                    continuation.finish()
                }
            }
            guard request.diagnosticRunID != nil else {
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: FloeError.validationFailed(
                        "Unexpected auxiliary request in the Plan/Goal fixture"))
                }
            }
            return AsyncThrowingStream { requests.append(request, stream: $0) }
        }
        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    }
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        private(set) var identity: UUID?
        func hold(id: UUID? = nil) async {
            identity = id
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    private struct Fixture {
        let environment: AppEnvironment
        let center: ConversationCenter
        let provider: ProviderProfile
        let model: ModelProfile
        let requests: Requests
    }
    private func fixture() async throws -> Fixture {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        environment.markIsolatedLaunchReadyForTesting()
        let center = environment.conversationCenter
        center.localModelDiscoveryOverrideForTesting = {}
        let requests = Requests()
        center.providerAdapterTestOverride = { _, _ in IdleProvider(requests: requests) }
        let provider = ProviderProfile(kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://plan-goal-owned-fixture.invalid/v1")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "plan-goal-owned-fixture",
            displayName: "Plan/Goal fixture", limits: .init(contextTokens: 16_384, maxOutputTokens: 2_048),
            capabilities: [.text, .tools])
        try await environment.configurationStore.saveProvider(provider)
        try await environment.configurationStore.saveModel(model)
        var preferences = try await environment.configurationStore.preferences()
        preferences.defaultAgentModelID = model.id
        try await environment.configurationStore.savePreferences(preferences)
        await center.reload()
        return Fixture(environment: environment, center: center, provider: provider, model: model, requests: requests)
    }
    private func waitForRequest(_ f: Fixture, after count: Int) async throws -> ProviderStreamRequest {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while f.requests.all.count <= count, ContinuousClock.now < deadline { await Task.yield() }
        let request = try #require(f.requests.all.dropFirst(count).first, "The real runtime never reached the scripted provider")
        try #require(request.diagnosticRunID != nil, "An auxiliary request cannot stand in for the admitted round")
        return request
    }
    private func systemText(_ request: ProviderStreamRequest) -> String {
        request.effectiveMessages.filter { $0.role == "system" }
            .flatMap(\.content).compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }.joined(separator: "\n")
    }
    private func waitForGate(_ gate: Gate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await gate.entered), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.entered, "The real launch did not reach its owned preflight gate")
    }

    private func waitForEnd(_ f: Fixture, runID: UUID) async throws -> RunRecord {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let run = try await f.environment.runStore.run(id: runID), run.endedAt != nil,
               !f.center.hasLiveOwner(runID: runID) { return run }
            await Task.yield()
        }
        let final = try await f.environment.runStore.run(id: runID)
        throw FloeError.validationFailed(
            "The real round did not terminate and release its owner (state=\(final?.state ?? "missing"), ended=\(final?.endedAt != nil), owned=\(f.center.hasLiveOwner(runID: runID)))")
    }

    @Test("Home inline and expanded sends persist Plan before navigation and really offer read-only tools")
    func homeInlineAndExpandedPlanKeepReadOnlyExecutionAndPreference() async throws {
        let f = try await fixture()
        for expanded in [false, true] {
            let home = HomeLaunchpadViewModel(center: f.center, draftStorageID: UUID(), initialDraft: "Prepare a read-only plan")
            home.selectedModelID = f.model.id; home.agentMode = .plan
            let previous = f.requests.all.count
            let id: UUID?
            if expanded {
                let editor = FullEditorController()
                editor.sendAllowed = true; editor.markedTextOverride = false
                var launch: Task<UUID?, Never>?
                editor.onSend = {
                    let selection = home.captureTaskMode()
                    launch = Task { await home.sendNewTask(modeSelection: selection) }
                }
                try #require(editor.requestSend())
                id = await launch?.value
                editor.onSend = nil
            } else { id = await home.sendNewTask(modeSelection: home.captureTaskMode()) }
            let conversationID = try #require(id)
            let run = try #require(try await f.environment.runStore.runs(conversationID: conversationID).first)
            #expect(run.conversationMode == ConversationMode.plan.rawValue)
            #expect(home.agentMode == .plan)
            let thread = ThreadDetailViewModel(conversationID: conversationID, center: f.center)
            await thread.load()
            #expect(thread.effectiveAgentMode == .plan)
            let request = try await waitForRequest(f, after: previous)
            #expect(request.toolSchemas.contains { $0.name == PlanSubmission.toolName })
            let descriptors = Dictionary(uniqueKeysWithValues: CatalogToolExecutor().allDescriptors.map { ($0.name, $0) })
            for schema in request.toolSchemas where schema.name != PlanSubmission.toolName {
                let descriptor = try #require(descriptors[schema.name])
                #expect(descriptor.effect == .readOnly)
            }
            await f.center.cancel(runID: run.id)
        }
    }

    @Test("Plan-to-Goal uses the accepted implementation contract and keeps planning history and original constraints")
    func acceptedPlanGoalUsesImplementationContract() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Accepted implementation")
        let plan = PlanDraft(conversationID: conversation.id, status: .ready,
            title: "Deliver the playable fixture", summary: "PLANNING_ONLY_MARKER: only confirm the plan; do not implement yet",
            sections: [.init(title: "Implement the game", body: "Build the agreed playable scene", order: 0),
                .init(title: "Verify and deliver", body: "Run the agreed checks and retain the result", order: 1)],
            assumptions: [.init(text: "Do not send files outside this task", isAccepted: true)],
            risks: [.init(text: "Keep the existing original", mitigation: "Write an owned result", severity: .medium)],
            acceptanceCriteria: [.init(text: "A playable result exists", verification: "Inspect the retained output")],
            executionRecommendation: .goal)
        try await f.environment.intelligenceStore.savePlanRevision(plan)
        let direct = try GoalFromPlanFactory.makeGoal(from: plan)
        #expect(!direct.objective.contains("PLANNING_ONLY_MARKER"))
        #expect(direct.objective == GoalFromPlanFactory.implementationObjective(from: plan))
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        view.selectedModelID = f.model.id
        await view.load()
        await view.acceptLatestPlan(as: .goal)
        let goal = try #require(view.activeGoal)
        let accepted = try #require(try await f.environment.intelligenceStore.latestPlan(conversationID: conversation.id))
        #expect(accepted.status == .accepted && accepted.summary == plan.summary)
        #expect(goal.conversationID == conversation.id && goal.sourcePlanID == plan.id && goal.sourcePlanDigest == accepted.digest)
        #expect(goal.objective == GoalFromPlanFactory.implementationObjective(from: accepted))
        #expect(goal.steps.map(\.detail) == plan.sections.map(\.body))
        #expect(goal.acceptanceCriteria.map(\.text) == plan.acceptanceCriteria.map(\.text))
        #expect(goal.budgets == direct.budgets && view.effectiveAgentMode == .agent)
        let runID = try #require(view.selectedRunID)
        let run = try #require(try await f.environment.runStore.run(id: runID))
        #expect(run.conversationMode == ConversationMode.goal.rawValue)
        #expect(run.goal == GoalFromPlanFactory.implementationPrompt(from: accepted))
        #expect(run.goal.contains("Do not send files outside this task") && !run.goal.contains("PLANNING_ONLY_MARKER"))
        let request = try await waitForRequest(f, after: 0)
        #expect(!systemText(request).contains("PLANNING_ONLY_MARKER"))
        await view.pauseActiveGoal()
        let paused = try #require(try await f.environment.intelligenceStore.goal(id: goal.id))
        let continuing = try #require(try await f.environment.runStore.run(id: runID))
        #expect(paused.status == .paused && continuing.endedAt == nil && f.center.hasLiveOwner(runID: runID))
        #expect(continuing.goal == run.goal && continuing.goalID == goal.id)
        try #require(f.requests.complete(at: 0))
        let completed = try await waitForEnd(f, runID: runID)
        #expect(completed.state == "completed" && completed.goal == run.goal)
        let afterPauseCompletion = try #require(try await f.environment.intelligenceStore.goal(id: goal.id))
        #expect(afterPauseCompletion.status == .paused && afterPauseCompletion.budgets == paused.budgets)
        #expect(paused.evidence.allSatisfy { afterPauseCompletion.evidence.contains($0) })
        #expect(afterPauseCompletion.progress.modelCallCount >= paused.progress.modelCallCount)
        await view.load()
        await view.resumeActiveGoal()
        let nextRunID = try #require(view.selectedRunID)
        try #require(nextRunID != runID)
        _ = try await waitForRequest(f, after: 1)
        let next = try #require(try await f.environment.runStore.run(id: nextRunID))
        let deleting = try #require(view.activeGoal)
        await view.deleteGoal(deleting)
        let stillRunning = try #require(try await f.environment.runStore.run(id: nextRunID))
        #expect(stillRunning.goal == next.goal && stillRunning.goalID == goal.id && stillRunning.endedAt == nil)
        #expect(f.center.hasLiveOwner(runID: nextRunID))
        #expect(try await f.environment.intelligenceStore.goal(id: goal.id)?.status == .cancelled)
        try #require(f.requests.complete(at: 1))
        #expect(try await waitForEnd(f, runID: nextRunID).state == "completed")
        #expect(try await f.environment.intelligenceStore.goal(id: goal.id)?.status == .cancelled)
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 2)
        #expect(f.requests.all.count == 2, "Long-term Pause/Delete must not cancel the round or start another cycle")
    }

    @Test("A prepared round keeps its admitted Goal context and native budget after editing or replacement")
    func preparedRoundKeepsAdmittedGoalContextAndBudgetAfterLongTermChanges() async throws {
        for deleteAndReplace in [false, true] {
            let f = try await fixture()
            let conversation = try await f.center.createConversation(title: "Admission context fixture")
            let original = ConversationGoal(conversationID: conversation.id,
                objective: "ADMITTED_OBJECTIVE_A", acceptanceCriteria: [.init(text: "ADMITTED_CRITERION_A")],
                steps: [.init(title: "ADMITTED_STEP_A", order: 0)], status: .active,
                budgets: .init(maxCycles: 7, maxModelCalls: 9, maxParentIterationsPerCycle: 11))
            try await f.environment.intelligenceStore.saveGoal(original)
            let admitted = try #require(try await f.environment.intelligenceStore.goal(id: original.id))
            let gate = Gate(), recorder = f.requests
            f.center.launchTestHooks.afterRunPrepared = { await gate.hold(id: $0) }
            f.center.launchTestHooks.didConfigureGoalBudget = { recorder.recordBudget(runID: $0, budget: $1) }
            let launch = Task {
                try await f.center.startRun(goal: "Execute the admitted round", in: conversation.id,
                    provider: f.provider, model: f.model, executionMode: .goal,
                    expectedGoal: (admitted.id, admitted.revision ?? 1), startOrigin: .explicitUserAction)
            }
            defer {
                f.center.launchTestHooks.afterRunPrepared = nil
                f.center.launchTestHooks.didConfigureGoalBudget = nil
                launch.cancel()
                Task { await gate.release() }
            }
            try await waitForGate(gate)
            let runID = try #require(await gate.identity)
            let prepared = try #require(try await f.environment.runStore.run(id: runID))
            try #require(prepared.state == "preparing" && prepared.goalID == admitted.id)
            #expect(f.requests.all.isEmpty && recorder.budget(runID: runID) == nil)
            var replacement: ConversationGoal?
            if deleteAndReplace {
                try await f.center.deleteGoal(conversationID: conversation.id, expectedGoalID: admitted.id,
                    expectedRevision: admitted.revision ?? 1, expectedDefinition: admitted)
                let next = ConversationGoal(conversationID: conversation.id, objective: "REPLACEMENT_OBJECTIVE_B",
                    acceptanceCriteria: [.init(text: "REPLACEMENT_CRITERION_B")], steps: [], status: .active,
                    budgets: .init(maxCycles: 99, maxModelCalls: 99, maxParentIterationsPerCycle: 99))
                try await f.environment.intelligenceStore.saveGoal(next)
                replacement = try #require(try await f.environment.intelligenceStore.goal(id: next.id))
            } else {
                let edited = try await f.center.editGoal(conversationID: conversation.id,
                    expectedGoalID: admitted.id, expectedRevision: admitted.revision ?? 1, expectedDefinition: admitted,
                    objective: "EDITED_OBJECTIVE_A", criteria: ["EDITED_CRITERION_A"],
                    blockingConditions: [], stoppingConditions: [])
                #expect(edited.status == .paused && edited.objective != admitted.objective)
            }
            await gate.release()
            let started = try await launch.value
            #expect(started.runID == runID)
            let request = try await waitForRequest(f, after: 0)
            let system = systemText(request)
            #expect(system.contains("ADMITTED_OBJECTIVE_A") && system.contains("ADMITTED_CRITERION_A"))
            #expect(!system.contains("EDITED_OBJECTIVE_A") && !system.contains("EDITED_CRITERION_A"))
            #expect(!system.contains("REPLACEMENT_OBJECTIVE_B") && !system.contains("REPLACEMENT_CRITERION_B"))
            #expect(try #require(recorder.budget(runID: runID)) == admitted.budgets,
                "Observe the actual native Configuration, not a test-created projection")
            let executing = try #require(try await f.environment.runStore.run(id: runID))
            #expect(executing.goalID == admitted.id && executing.goal == prepared.goal && executing.endedAt == nil)
            #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
            await f.center.cancel(runID: runID)
            _ = await started.result.value
            _ = try await waitForEnd(f, runID: runID)
            if let replacement {
                #expect(try await f.environment.intelligenceStore.goal(id: replacement.id) == replacement,
                    "The old admitted round cannot bind, spend or pause its replacement")
            }
        }
    }

    @Test("Explicit editing rebases progress, rejects competing definitions, and deletion fences only the old Goal launch")
    func editDeletePreserveProgressAndFenceOnlyGoalLaunches() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Owned Goal edit/delete")
        let workspaceStore = SQLiteWorkspaceStore(database: f.environment.database)
        let workspaceID = try #require(try await workspaceStore.workspaceID(conversationID: conversation.id))
        let workspace = try #require(try await workspaceStore.workspace(id: workspaceID))
        let fileLease = try await f.environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: conversation.id)
        let file = fileLease.url.appendingPathComponent("owned-goal-result.txt")
        let bytes = Data("Keep this completed result".utf8)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file); fileLease.release() }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let evidence = GoalEvidence(kind: .file, reference: "owned-goal-result.txt", summary: "Completed result", capturedAt: now)
        let seed = ConversationGoal(conversationID: conversation.id, objective: "Deliver the owned result",
            acceptanceCriteria: [.init(text: "Keep the result", isSatisfied: true, evidenceIDs: [evidence.id])],
            steps: [.init(title: "Completed work", status: .completed, order: 0)], evidence: [evidence], status: .active,
            budgets: .init(maxCycles: 10, maxModelCalls: 20), progress: .init(cycleCount: 2, modelCallCount: 3, totalIterationCount: 4, startedAt: now))
        try await f.environment.intelligenceStore.saveGoal(seed)
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        view.selectedModelID = f.model.id
        try await f.center.setPreferredExecutionMode(.plan, for: conversation.id)
        await view.load()
        let initial = try #require(view.activeGoal)
        let currentA = try await f.center.startRun(goal: seed.objective, in: conversation.id,
            provider: f.provider, model: f.model, executionMode: .goal,
            expectedGoal: (seed.id, initial.revision ?? 1), startOrigin: .explicitUserAction)
        _ = try await waitForRequest(f, after: 0)
        await view.load()
        let admittedA = try #require(try await f.environment.runStore.run(id: currentA.runID))
        let opened = try #require(view.activeGoal)
        var progressed = opened; progressed.progress.modelCallCount += 1
        try #require(try await f.environment.intelligenceStore.saveGoalIfRevisionMatches(progressed, expectedRevision: opened.revision ?? 1))
        let latestProgress = try #require(try await f.environment.intelligenceStore.goal(id: seed.id))

        // The native launch transaction must reject an old Goal revision
        // without leaving either a run or its user message behind.
        let beforeRuns = try await f.environment.runStore.runs(conversationID: conversation.id)
        let beforeMessages = try await f.environment.conversationStore.messages(conversationID: conversation.id)
        var staleRejected = false
        do {
            _ = try await SQLiteRunLaunchStore(database: f.environment.database).prepare(.init(
                conversationID: conversation.id, goal: "Stale Goal revision must not start",
                conversationMode: "goal", goalID: seed.id, expectedGoalRevision: opened.revision ?? 1,
                goalDefinitionFingerprint: try GoalRunDefinitionFingerprint.make(opened)))
        } catch let error as FloeError {
            if case .validationFailed = error { staleRejected = true }
            else { Issue.record("Unexpected transaction rejection: \(error)") }
        }
        #expect(staleRejected)
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id) == beforeRuns)
        #expect(try await f.environment.conversationStore.messages(conversationID: conversation.id) == beforeMessages)

        let goalGate = Gate()
        f.center.launchTestHooks.beforeGoalPreflight = { await goalGate.hold() }
        let lateGoal = Task {
            try await f.center.startRun(goal: seed.objective, in: conversation.id, provider: f.provider, model: f.model,
                executionMode: .goal, isGoalContinuation: true, expectedGoal: (seed.id, latestProgress.revision ?? 1), startOrigin: .goalContinuation)
        }
        defer {
            f.center.launchTestHooks.beforeGoalPreflight = nil
            lateGoal.cancel()
            Task { await goalGate.release() }
        }
        try await waitForGate(goalGate)
        #expect(await view.editGoal(opened, objective: "Deliver the edited result", criteria: ["Keep the result", "Verify the delivery"],
            blockingConditions: ["Ask if the original would change"], stoppingConditions: ["Stop after verified delivery"]))
        let edited = try #require(view.activeGoal)
        #expect(edited.id == seed.id && edited.conversationID == conversation.id && edited.status == .paused)
        #expect(edited.progress == latestProgress.progress && edited.budgets == latestProgress.budgets)
        #expect(edited.evidence == latestProgress.evidence && edited.steps == latestProgress.steps)
        #expect(edited.acceptanceCriteria.first == latestProgress.acceptanceCriteria.first)
        #expect(edited.acceptanceCriteria.last?.isSatisfied == false && view.effectiveAgentMode == .plan)
        let afterEditA = try #require(try await f.environment.runStore.run(id: currentA.runID))
        #expect(afterEditA.goal == admittedA.goal && afterEditA.endedAt == nil && f.center.hasLiveOwner(runID: currentA.runID))

        var competing = edited; competing.objective = "A definition saved in another window"
        try #require(try await f.environment.intelligenceStore.saveGoalIfRevisionMatches(competing, expectedRevision: edited.revision ?? 1))
        #expect(!(await view.editGoal(edited, objective: "Must not overwrite", criteria: ["Keep the result"], blockingConditions: [], stoppingConditions: [])))
        #expect(try await f.environment.intelligenceStore.goal(id: seed.id)?.objective == competing.objective)
        await view.load()

        let ordinaryGate = Gate(), deletionGate = Gate(), bPreparedGate = Gate()
        let ordinaryRunID = UUID()
        f.center.launchTestHooks.afterRunPrepared = { runID in
            if runID == ordinaryRunID { await ordinaryGate.hold(id: runID) }
            else { await bPreparedGate.hold(id: runID) }
        }
        let ordinary = Task {
            try await f.center.startRun(goal: "Keep this ordinary user input", in: conversation.id, provider: f.provider, model: f.model,
                executionMode: .agent, newRunID: ordinaryRunID, startOrigin: .explicitUserAction)
        }
        defer {
            f.center.launchTestHooks.afterRunPrepared = nil
            ordinary.cancel()
            Task { await ordinaryGate.release(); await bPreparedGate.release() }
        }
        try await waitForGate(ordinaryGate)
        let deletionSnapshot = try #require(view.activeGoal)
        f.center.launchTestHooks.afterGoalControlFence = { id in
            if id == seed.id { await deletionGate.hold() }
        }
        let deletion = Task { await view.deleteGoal(deletionSnapshot) }
        defer {
            f.center.launchTestHooks.afterGoalControlFence = nil
            Task { await deletionGate.release() }
        }
        try await waitForGate(deletionGate)
        let tombstone = try #require(try await f.environment.intelligenceStore.goal(id: seed.id))
        try #require(tombstone.status == .cancelled)

        // A second surface can create explicit B after A's tombstone commits
        // while A's advancement fence is suspended. Use the actual VM create/start
        // path and hold B after real prepare, before Core can assign any ID.
        let otherSurface = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        otherSurface.selectedModelID = f.model.id
        f.center.launchTestHooks.beforeGoalPreflight = nil
        let bCreation = Task {
            await otherSurface.createGoal(objective: "A new explicitly authorized Goal B", criteria: ["Verify B"],
                blockingConditions: [], stoppingConditions: [])
        }
        defer { bCreation.cancel(); Task { await bPreparedGate.release() } }
        try await waitForGate(bPreparedGate)
        let goalB = try #require(otherSurface.activeGoal)
        let runB = try #require(await bPreparedGate.identity)
        try #require(goalB.id != seed.id)
        let preparedB = try #require(try await f.environment.runStore.run(id: runB))
        try #require(preparedB.state == "preparing" && preparedB.endedAt == nil)
        #expect(preparedB.goalID == goalB.id, "Known B must be bound before its deferred service/Core starts")
        let admissionEvent = try #require(try await f.environment.runStore.events(runID: runB).first)
        let admission = try JSONDecoder().decode([String: String].self, from: Data(admissionEvent.payloadJSON.utf8))
        #expect(admissionEvent.kind == .status && admission["state"] == "preparing")
        #expect(admission["goalID"] == goalB.id.uuidString && admission["goalRevision"] == String(goalB.revision ?? 1))
        #expect(admission["goalDefinitionFingerprint"] == (try GoalRunDefinitionFingerprint.make(goalB)))

        await deletionGate.release()
        await deletion.value
        #expect(view.activeGoal?.id == goalB.id && view.effectiveAgentMode == .plan)
        let afterAStop = try #require(try await f.environment.runStore.run(id: runB))
        #expect(afterAStop.goalID == goalB.id && afterAStop.state == "preparing" && afterAStop.endedAt == nil,
            "Deleting long-term A must not cancel admitted B")
        let afterDeleteA = try #require(try await f.environment.runStore.run(id: currentA.runID))
        #expect(afterDeleteA.goal == admittedA.goal && afterDeleteA.endedAt == nil && f.center.hasLiveOwner(runID: currentA.runID))
        // Composer Stop targets the actual old A row. B must remain active,
        // even though it now owns the conversation's long-term Goal bar.
        try await f.center.stopRunFromComposer(afterDeleteA)
        _ = await currentA.result.value
        #expect(try await waitForEnd(f, runID: currentA.runID).state == "checkpointed")
        #expect(try await f.environment.intelligenceStore.goal(id: goalB.id)?.status == .active)
        f.center.launchTestHooks.afterGoalControlFence = nil
        await ordinaryGate.release()
        let kept = try await ordinary.value
        _ = try await waitForRequest(f, after: 1)
        #expect(try await f.environment.runStore.run(id: kept.runID)?.conversationMode == ConversationMode.chat.rawValue)
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 3)
        let deleted = try #require(try await f.environment.intelligenceStore.goal(id: seed.id))
        #expect(deleted.status == .cancelled && deleted.objective == competing.objective && deleted.budgets == edited.budgets)
        #expect(edited.evidence.allSatisfy { deleted.evidence.contains($0) })
        #expect(deleted.progress.cycleCount >= edited.progress.cycleCount
            && deleted.progress.modelCallCount >= edited.progress.modelCallCount
            && deleted.progress.totalIterationCount >= edited.progress.totalIterationCount,
            "Stopping the original round may settle actual usage, without losing progress or replacing the tombstone")
        #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).count == 2)
        #expect(try await f.environment.conversationStore.conversation(id: conversation.id) != nil)
        #expect(try Data(contentsOf: file) == bytes)
        let ordinarySnapshot = try #require(try await f.environment.runStore.run(id: kept.runID))
        try await f.center.stopRunFromComposer(ordinarySnapshot)
        _ = await kept.result.value
        #expect(try await f.environment.intelligenceStore.goal(id: goalB.id)?.status == .active,
            "Stopping an ordinary round must not pause another Goal")
        let stopDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while f.center.hasLiveOwner(runID: kept.runID), ContinuousClock.now < stopDeadline { await Task.yield() }
        try #require(!f.center.hasLiveOwner(runID: kept.runID), "The ordinary run did not finish releasing its owner")

        f.center.launchTestHooks.afterRunPrepared = nil
        let beforeBPause = try #require(try await f.environment.intelligenceStore.goal(id: goalB.id))
        let admittedBPaused = try await f.center.pauseGoal(conversationID: conversation.id,
            expectedGoalID: goalB.id, expectedRevision: beforeBPause.revision ?? 1)
        #expect(admittedBPaused.status == .paused)
        #expect(try await f.environment.runStore.run(id: runB)?.state == "preparing",
            "Goal Pause cannot revoke the transactionally admitted round before Core starts")
        await bPreparedGate.release()
        try #require(await bCreation.value)
        _ = try await waitForRequest(f, after: 2)
        await goalGate.release()
        do { _ = try await lateGoal.value; Issue.record("The deleted Goal's queued launch survived its fence") }
        catch { #expect(error is CancellationError) }
        let retainedB = try #require(try await f.environment.intelligenceStore.goal(id: goalB.id))
        let retainedRunB = try #require(try await f.environment.runStore.run(id: runB))
        #expect(retainedB.objective == goalB.objective && retainedB.status == .paused)
        #expect(retainedB.progress.modelCallCount >= goalB.progress.modelCallCount)
        #expect(retainedRunB.goalID == goalB.id && retainedRunB.endedAt == nil && !["failed", "cancelled"].contains(retainedRunB.state))
        #expect(f.center.hasLiveOwner(runID: runB))
        #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).count == 2,
            "Core must reuse the preparing run's existing Goal, not create another one")
        let bSnapshot = try #require(try await f.environment.runStore.run(id: runB))
        try await f.center.stopRunFromComposer(bSnapshot)
        #expect(try await waitForEnd(f, runID: runB).state == "checkpointed")
        let stoppedB = try #require(try await f.environment.intelligenceStore.goal(id: goalB.id))
        #expect(stoppedB.status == .paused && stoppedB.objective == retainedB.objective)
        #expect(stoppedB.budgets == retainedB.budgets && retainedB.evidence.allSatisfy { stoppedB.evidence.contains($0) })
        #expect(try Data(contentsOf: file) == bytes)
    }
}
#endif
