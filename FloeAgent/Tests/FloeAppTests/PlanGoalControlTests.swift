// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
@testable import FloeSync
@testable import FloeAgentRuntime
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
        private let preparationStarted = ContinuousClock.now
        private var preparationPhases: [String] = []
        func recordPreparation(runID: UUID, stage: String) {
            let elapsed = preparationStarted.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            lock.withLock {
                if preparationPhases.count == 64 { preparationPhases.removeFirst() }
                preparationPhases.append("\(runID.uuidString.prefix(8)) \(stage) +\(milliseconds)ms")
            }
        }
        var preparationDiagnostic: String { lock.withLock { preparationPhases.joined(separator: "; ") } }
        func recordBudget(runID: UUID, budget: GoalBudgets?) { lock.withLock { configuredBudgets[runID] = budget } }
        func budget(runID: UUID) -> GoalBudgets? { lock.withLock { configuredBudgets[runID] } }
        func append(_ value: ProviderStreamRequest, stream: AsyncThrowingStream<AgentEvent, Error>.Continuation) {
            lock.withLock { values.append(value); streams.append(stream) }
        }
        var all: [ProviderStreamRequest] { lock.withLock { values } }
        func complete(at index: Int, text: String = "The owned round finished without an external action.") -> Bool {
            let stream = lock.withLock { streams.indices.contains(index) ? streams[index] : nil }
            guard let stream else { return false }
            stream.yield(.textDelta(.init(text: text)))
            stream.yield(.completed(.init(stopReason: .endTurn)))
            stream.finish()
            return true
        }
        func emitTool(at index: Int, call: ToolCall) -> Bool {
            let stream = lock.withLock { streams.indices.contains(index) ? streams[index] : nil }
            guard let stream else { return false }
            stream.yield(.toolRequest(call))
            stream.yield(.completed(.init(stopReason: .toolUse)))
            stream.finish()
            return true
        }
    }
    /// Uses CredentialVaultService's existing test seam. Secret bytes stay
    /// in this fixture's RAM; real CredentialStore rows still commit/fail.
    private nonisolated final class IsolatedIngressSecretStore: VaultSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        private var writesDenied = false
        var denyWrites: Bool {
            get { lock.withLock { writesDenied } }
            set { lock.withLock { writesDenied = newValue } }
        }
        func store(account: String, secret: Data) throws {
            try lock.withLock {
                if writesDenied { throw FloeError.validationFailed("injected isolated vault store failure") }
                values[account] = secret
            }
        }
        func read(account: String) throws -> Data {
            try lock.withLock {
                guard let value = values[account] else { throw KeychainStoreError.itemNotFound }
                return value
            }
        }
        func delete(account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
        var count: Int { lock.withLock { values.count } }
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
        // A real suspension lets this MainActor launch and its native
        // callbacks advance; Task.yield can immediately reschedule the poll.
        while f.requests.all.count <= count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let request = try #require(f.requests.all.dropFirst(count).first,
            "The real runtime never reached the scripted provider. Native preparation: \(f.requests.preparationDiagnostic)")
        try #require(request.diagnosticRunID != nil, "An auxiliary request cannot stand in for the admitted round")
        return request
    }
    /// load() installs the same asynchronous live projection as the real
    /// footer. Do not bypass that UI precondition by calling send while its
    /// default isRunning=false still represents an unapplied first snapshot.
    private func waitForRunningComposer(_ view: ThreadDetailViewModel, fixture f: Fixture, runID: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (!view.isRunning || view.selectedRunID != runID), f.center.hasLiveOwner(runID: runID),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(view.isRunning && view.selectedRunID == runID,
            "The real running-input footer never observed its original active run")
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
            try await Task.sleep(for: .milliseconds(2))
        }
        let final = try await f.environment.runStore.run(id: runID)
        throw FloeError.validationFailed(
            "The real round did not terminate and release its owner (state=\(final?.state ?? "missing"), ended=\(final?.endedAt != nil), owned=\(f.center.hasLiveOwner(runID: runID)))")
    }

    private func emitTool(_ f: Fixture, at index: Int, name: String, arguments: [String: Any],
                          callID: String = UUID().uuidString) async throws -> ProviderStreamRequest {
        let call = try ToolCall(id: callID, toolName: name,
            argumentsJSON: JSONSerialization.data(withJSONObject: arguments), scope: .local)
        try #require(f.requests.emitTool(at: index, call: call))
        return try await waitForRequest(f, after: index + 1)
    }

    /// A 16K request can legitimately defer a provider schema while exact
    /// discovery delivers its entire callable contract in the paired result.
    /// Neither catalog membership nor a name-only teaser counts as delivery.
    private func hasCompleteCallableContract(_ request: ProviderStreamRequest, name: String) -> Bool {
        if request.toolSchemas.contains(where: { $0.name == name }) { return true }
        guard let descriptor = ToolCatalog.descriptor(named: name) else { return false }
        return request.toolResults.contains { result in
            result.output.contains("Complete schema for \(name) (complete arguments below;")
                && result.output.contains("parametersJSON: " + descriptor.parametersJSON)
        }
    }

    private func ownedRoot(_ f: Fixture, conversationID: UUID) async throws -> URL {
        let store = SQLiteWorkspaceStore(database: f.environment.database)
        let owner = try #require(try await store.workspaceID(conversationID: conversationID))
        let record = try #require(try await store.workspace(id: owner))
        try #require(record.kind == .privateTask && record.internalRelativePath == "PrivateTasks/\(conversationID.uuidString)")
        let lease = try await f.environment.workspaceCenter.acquireMemorySourceRoot(record)
        let root = lease.root; await lease.release(); return root
    }

    private func stopOwnedFixtureRuns(_ f: Fixture, conversationID: UUID, root: URL?) async {
        let runs = (try? await f.environment.runStore.runs(conversationID: conversationID)) ?? []
        for run in runs where f.center.hasLiveOwner(runID: run.id) { await f.center.cancel(runID: run.id) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while runs.contains(where: { f.center.hasLiveOwner(runID: $0.id) }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if let root, !runs.contains(where: { f.center.hasLiveOwner(runID: $0.id) }) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func verifyPlanExecutionHandoff(planningStillActive: Bool, readOnly: Bool = false) async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Plan handoff native dispatch fixture")
        let taskStore = SQLiteWorkspaceStore(database: f.environment.database)
        try await taskStore.saveTaskPolicy(.init(conversationID: conversation.id,
            approvalMode: readOnly ? "readOnly" : TaskApprovalMode.fullAccess.rawValue))
        try await f.center.setPreferredExecutionMode(.plan, for: conversation.id)
        let planning = try await f.center.startRun(goal: "Plan a native report file, then wait for confirmation", in: conversation.id,
            provider: f.provider, model: f.model, executionMode: .plan, startOrigin: .explicitUserAction)
        var root: URL?
        do {
            let first = try await waitForRequest(f, after: 0)
            root = try await ownedRoot(f, conversationID: conversation.id)
            #expect(first.toolSchemas.contains { $0.name == PlanSubmission.toolName })
            let submission = PlanSubmission(title: "Save the agreed report", summary: "Review the report write before execution",
                sections: [.init(title: "Write", body: "Create plan-execution.txt with native-write-confirmed")],
                acceptanceCriteria: [.init(text: "File is correct", verification: "Read its actual bytes")], executionRecommendation: .normal)
            let args = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(submission)) as? [String: Any])
            _ = try await emitTool(f, at: 0, name: PlanSubmission.toolName, arguments: args, callID: "submit-plan")
            let source = try #require(try await f.environment.intelligenceStore.latestPlan(conversationID: conversation.id))
            #expect(source.status == .ready && f.center.hasLiveOwner(runID: planning.runID))
            let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
            await view.load()
            #expect(view.agentMode == .agent && view.latestPlan?.status == .ready)
            #expect(f.requests.all.count == 2)
            #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
            #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).isEmpty)
            if !planningStillActive {
                try #require(f.requests.complete(at: 1, text: "The plan is ready for confirmation."))
                _ = try await waitForEnd(f, runID: planning.runID); _ = await planning.result.value
                await view.load()
            }
            view.selectAgentMode(.agent) // exact reported workaround must not be required to Stop
            let requestCount = f.requests.all.count
            await view.acceptLatestPlan(as: .normal)
            try #require(view.actionError == nil, "Native handoff failed: \(view.actionError ?? "")")
            let executionID = try #require(view.selectedRunID)
            #expect(executionID != planning.runID && view.agentMode == .agent)
            let execution = try #require(try await f.environment.runStore.run(id: executionID))
            let old = try #require(try await f.environment.runStore.run(id: planning.runID))
            #expect(execution.conversationMode == ConversationMode.chat.rawValue)
            #expect(old.conversationMode == ConversationMode.plan.rawValue && !f.center.hasLiveOwner(runID: old.id))
            let request = try await waitForRequest(f, after: requestCount)
            #expect(request.diagnosticRunID == executionID.uuidString)
            #expect(!request.toolSchemas.contains { $0.name == PlanSubmission.toolName })
            let discovered = try await emitTool(f, at: requestCount, name: ToolDiscovery.name,
                arguments: ["query": "workspace.createFile"], callID: "discover-native-write")
            #expect(discovered.allToolNames.contains("workspace.createFile") == !readOnly)
            #expect(hasCompleteCallableContract(discovered, name: "workspace.createFile") == !readOnly)
            // Execute a real native tool, including its real authorization gate.
            _ = try await emitTool(f, at: requestCount + 1, name: "workspace.createFile",
                arguments: ["path": "plan-execution.txt", "content": "native-write-confirmed"], callID: "native-write")
            let actualRoot = try await ownedRoot(f, conversationID: conversation.id); root = actualRoot
            let file = actualRoot.appendingPathComponent("plan-execution.txt")
            let events = try await f.environment.runStore.events(runID: executionID, afterSequence: 0, limit: 200)
            let result = try #require(events.first { event in
                event.kind == .toolResult && ConversationCenter.decodePayload(event.payloadJSON)["tool"] == "workspace.createFile"
            })
            #expect(ConversationCenter.decodePayload(result.payloadJSON)["status"] == (readOnly ? "denied" : "ok"))
            if readOnly { #expect(!FileManager.default.fileExists(atPath: file.path)) }
            else { #expect(try Data(contentsOf: file) == Data("native-write-confirmed".utf8)) }
            #expect(try await taskStore.taskPolicy(conversationID: conversation.id).approvalMode
                == (readOnly ? "readOnly" : TaskApprovalMode.fullAccess.rawValue))
            try #require(f.requests.complete(at: requestCount + 2,
                text: readOnly ? "The write is blocked by the read-only task policy; no file was created." : "The native file was saved and its bytes verified."))
            _ = try await waitForEnd(f, runID: executionID)
            #expect(try await f.environment.intelligenceStore.latestPlan(conversationID: conversation.id)?.status == .accepted)
            #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).isEmpty)
        } catch { await stopOwnedFixtureRuns(f, conversationID: conversation.id, root: root); throw error }
        await stopOwnedFixtureRuns(f, conversationID: conversation.id, root: root)
    }

    @Test("Active Plan submit -> Agent selection -> Execute really writes without a manual Stop")
    func activePlanExecutesNewAuthorizedRunWithoutManualStop() async throws {
        try await verifyPlanExecutionHandoff(planningStillActive: true)
    }

    @Test("A terminal Plan also executes a distinct authorized run without message resubmission")
    func terminalPlanExecutesNewAuthorizedRunWithoutNewMessage() async throws {
        try await verifyPlanExecutionHandoff(planningStillActive: false)
    }

    @Test("Confirmed execution retains the task's real read-only ceiling")
    func planExecutionPreservesReadOnlyTaskCeilingAtActualDispatch() async throws {
        try await verifyPlanExecutionHandoff(planningStillActive: true, readOnly: true)
    }

    @Test("Execute Plan never cancels an unrelated live Agent owner")
    func planHandoffRefusesNonPlanningOwnerWithoutStoppingIt() async throws {
        let f = try await fixture(), conversation = try await f.center.createConversation(title: "Keep existing Agent owner")
        let current = try await f.center.startRun(goal: "Keep this ordinary round running", in: conversation.id,
            provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        do {
            _ = try await waitForRequest(f, after: 0)
            let plan = PlanDraft(conversationID: conversation.id, status: .ready, title: "Pending", summary: "Only execute on explicit confirmation",
                sections: [.init(title: "Inspect", body: "Inspect the report", order: 0)], acceptanceCriteria: [.init(text: "Verified", verification: "Read the inspection result")])
            try await f.environment.intelligenceStore.savePlanRevision(plan)
            let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
            await view.load(); await view.acceptLatestPlan(as: .normal)
            #expect(view.actionError != nil && f.center.hasLiveOwner(runID: current.runID))
            #expect(try await f.environment.intelligenceStore.latestPlan(conversationID: conversation.id)?.status == .ready)
            #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
            #expect(f.requests.all.count == 1)
        } catch { await f.center.cancel(runID: current.runID); throw error }
        await f.center.cancel(runID: current.runID)
    }

    @Test("The native handoff fences competing send/queue and expires its token on exit")
    func planHandoffSerializesLaunchAndQueueWithoutGrantingAuthority() async throws {
        let f = try await fixture(), conversation = try await f.center.createConversation(title: "Plan handoff serialization")
        let plan = PlanDraft(conversationID: conversation.id, status: .ready, title: "Pending", summary: "No implicit execution")
        try await f.environment.intelligenceStore.savePlanRevision(plan)
        let center = f.center, gate = Gate(), id = conversation.id
        let transition = Task { @MainActor in
            try await center.withPlanExecutionHandoff(plan, in: id) { token in await gate.hold(); return token }
        }
        try await waitForGate(gate)
        do {
            await #expect(throws: (any Error).self) {
                try await center.startRun(goal: "Competing send", in: id, provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
            }
            await #expect(throws: (any Error).self) {
                try await center.submitRunningInput(content: "Competing queue", in: id, expectedRunID: UUID(), mode: .queue,
                    selectedModelID: f.model.id, workspaceID: nil, executionMode: .agent, attachments: [])
            }
            #expect(try await f.environment.runStore.runs(conversationID: id).isEmpty)
            #expect(try await center.runningInputStore(for: id).pending(conversationID: id).isEmpty)
        } catch { await gate.release(); _ = try? await transition.value; throw error }
        await gate.release()
        let expired = try await transition.value
        await #expect(throws: (any Error).self) {
            try await center.startRun(goal: "Expired token", in: id, provider: f.provider, model: f.model,
                planExecutionHandoffID: expired, startOrigin: .explicitUserAction)
        }
        #expect(f.requests.all.isEmpty)
    }

    @Test("Unjoined planning preparation leaves a retryable card instead of starting execution")
    func planHandoffOwnerExitFailureRetainsPendingPlan() async throws {
        let f = try await fixture(), conversation = try await f.center.createConversation(title: "Unjoined Plan owner")
        let gate = Gate()
        f.center.launchTestHooks.deferredTaskBody = { await gate.hold() }
        let planning = try await f.center.startRun(goal: "Planning is still preparing", in: conversation.id,
            provider: f.provider, model: f.model, executionMode: .plan, startOrigin: .explicitUserAction)
        try await waitForGate(gate)
        let plan = PlanDraft(conversationID: conversation.id, status: .ready, title: "Pending", summary: "Keep pending on failure",
            sections: [.init(title: "Inspect", body: "Inspect", order: 0)], acceptanceCriteria: [.init(text: "Inspected", verification: "Read the inspection result")])
        try await f.environment.intelligenceStore.savePlanRevision(plan)
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await view.load(); await view.acceptLatestPlan(as: .normal)
        #expect(view.actionError != nil && !view.isAcceptingPlan)
        #expect(try await f.environment.intelligenceStore.latestPlan(conversationID: conversation.id)?.status == .ready)
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
        #expect(f.requests.all.isEmpty)
        f.center.launchTestHooks.deferredTaskBody = nil
        await gate.release(); _ = await planning.result.value
        #expect(!f.center.hasLiveOwner(runID: planning.runID))
    }

    @Test("Checklist progress observes actual updates and leaves the top on terminal and a new run")
    func checklistTopIsLiveRunScopedAndTerminalDoesNotFakeCompletion() async throws {
        let f = try await fixture(), conversation = try await f.center.createConversation(title: "Owned checklist lifecycle")
        try await SQLiteWorkspaceStore(database: f.environment.database).saveTaskPolicy(.init(
            conversationID: conversation.id, approvalMode: TaskApprovalMode.fullAccess.rawValue))
        let started = try await f.center.startRun(goal: "Create a local fixture file and report the unavailable second step", in: conversation.id,
            provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        var root: URL?
        do {
            _ = try await waitForRequest(f, after: 0)
            root = try await ownedRoot(f, conversationID: conversation.id)
            _ = try await emitTool(f, at: 0, name: ToolDiscovery.name,
                arguments: ["queries": ["workspace.createFile", TaskUpdatePlanTool.name]])
            _ = try await emitTool(f, at: 1, name: "workspace.createFile",
                arguments: ["path": "checklist-evidence.txt", "content": "owned-evidence"])
            _ = try await emitTool(f, at: 2, name: TaskUpdatePlanTool.name, arguments: ["title": "Real progress", "steps": [
                ["id": "write", "title": "Write file", "status": "completed", "evidence": ["checklist-evidence.txt"]],
                ["id": "followup", "title": "Needs user's missing choice", "status": "blocked", "evidence": []]
            ]])
            let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
            await view.load()
            // load starts the same asynchronous live subscription used by
            // the UI; wait for its first snapshot rather than inspect it
            // before that MainActor task has had a chance to run.
            let projectionDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !view.isRunning, f.center.hasLiveOwner(runID: started.runID),
                  ContinuousClock.now < projectionDeadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            let shown = try #require(view.presentedTaskChecklist)
            #expect(shown.runID == started.runID && shown.completedCount == 1 && !shown.isFinished)
            #expect(try Data(contentsOf: try #require(root).appendingPathComponent("checklist-evidence.txt")) == Data("owned-evidence".utf8))
            try #require(f.requests.complete(at: 3, text: "The local file is verified. The remaining step is blocked pending the user's missing choice."))
            _ = try await waitForEnd(f, runID: started.runID)
            await view.load()
            #expect(view.presentedTaskChecklist == nil)
            let retained = try #require(try await TaskChecklistStore(database: f.environment.database).latest(conversationID: conversation.id))
            #expect(retained.completedCount == 1 && retained.steps.last?.status == .blocked && !retained.isFinished)
            let next = try await f.center.startRun(goal: "A new ordinary question without changing the previous checklist", in: conversation.id,
                provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
            _ = try await waitForRequest(f, after: 4)
            view.selectedRunID = next.runID
            await view.load()
            #expect(view.selectedRunID == next.runID && view.presentedTaskChecklist == nil)
            #expect(view.taskChecklist?.runID == started.runID)
            try #require(f.requests.complete(at: 4, text: "No additional work was requested."))
            _ = try await waitForEnd(f, runID: next.runID)
        } catch { await stopOwnedFixtureRuns(f, conversationID: conversation.id, root: root); throw error }
        await stopOwnedFixtureRuns(f, conversationID: conversation.id, root: root)
    }

    @Test("Plan mode discovers and really dispatches native reset; old history/Goal/chat survive")
    func planResetIsDiscoverableDispatchedAndDurablyRebuildable() async throws {
        let f = try await fixture(), conversation = try await f.center.createConversation(title: "Native checklist reset dispatch")
        try await SQLiteWorkspaceStore(database: f.environment.database).saveTaskPolicy(.init(
            conversationID: conversation.id, approvalMode: TaskApprovalMode.fullAccess.rawValue))
        let started = try await f.center.startRun(goal: "Reset only this task's current checklist, retain its history", in: conversation.id,
            provider: f.provider, model: f.model, executionMode: .plan, startOrigin: .explicitUserAction)
        let store = TaskChecklistStore(database: f.environment.database)
        var root: URL?
        do {
            _ = try await waitForRequest(f, after: 0)
            root = try await ownedRoot(f, conversationID: conversation.id)
            let initial = try await store.update(.init(title: "Unfinished original", steps: [
                .init(id: "keep", title: "Still pending", status: .pending)
            ]), runID: started.runID, operationID: "native-seed")
            let messageIDs = try await f.environment.conversationStore.messages(conversationID: conversation.id).map(\.id)
            let goal = ConversationGoal(conversationID: conversation.id, objective: "Separate retained Goal",
                acceptanceCriteria: [.init(text: "No loss")], steps: [.init(title: "Keep", order: 0)])
            try await f.environment.intelligenceStore.saveGoal(goal)
            let loaded = try await emitTool(f, at: 0, name: ToolDiscovery.name,
                arguments: ["query": TaskResetPlanTool.name], callID: "find-reset")
            #expect(loaded.allToolNames.contains(TaskResetPlanTool.name))
            #expect(hasCompleteCallableContract(loaded, name: TaskResetPlanTool.name))
            #expect(!loaded.allToolNames.contains(TaskUpdatePlanTool.name))
            #expect(!hasCompleteCallableContract(loaded, name: TaskUpdatePlanTool.name))
            _ = try await emitTool(f, at: 1, name: TaskResetPlanTool.name,
                arguments: ["expectedRevision": initial.revision], callID: "reset-current")
            let reset = try #require(try await store.latest(conversationID: conversation.id, includeReset: true))
            #expect(reset.wasReset == true && reset.steps.isEmpty && reset.revision == initial.revision + 1)
            #expect(try await store.latest(conversationID: conversation.id) == nil)
            let events = try await f.environment.runStore.events(runID: started.runID, afterSequence: 0, limit: 200)
            let result = try #require(events.first { event in
                event.kind == .toolResult && ConversationCenter.decodePayload(event.payloadJSON)["tool"] == TaskResetPlanTool.name
            })
            #expect(ConversationCenter.decodePayload(result.payloadJSON)["status"] == "ok")
            // Persistent storage, not payload wording, proves actual dispatch.
            let oldBody = try await f.environment.database.reader { db in
                try String.fetchOne(db, sql: "SELECT body_json FROM task_checklist_revisions WHERE conversation_id = ? AND revision = ?",
                    arguments: [conversation.id.uuidString, initial.revision])
            }
            let prior = try JSONDecoder().decode(TaskChecklist.self, from: Data(try #require(oldBody).utf8))
            #expect(prior.steps == initial.steps && prior.completedCount == 0)
            #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).contains { $0.id == goal.id })
            let kept = try await f.environment.conversationStore.messages(conversationID: conversation.id).map(\.id)
            #expect(messageIDs.allSatisfy(kept.contains))
            let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
            await view.load(); #expect(view.presentedTaskChecklist == nil)
            // Rebuild with the existing native store API. No model-only Plan
            // update privilege is added: the executing Plan remains Plan.
            let rebuilt = try await store.update(.init(expectedRevision: reset.revision, title: "Rebuilt", steps: [
                .init(id: "new", title: "New pending work")], startNew: true), runID: started.runID, operationID: "native-rebuild")
            #expect(rebuilt.steps.map(\.id) == ["new"] && rebuilt.revision == reset.revision + 1)
            let operation = try await f.environment.database.reader { db in
                try String.fetchOne(db, sql: "SELECT operation_id FROM task_checklist_revisions WHERE conversation_id = ? AND revision = ?",
                    arguments: [conversation.id.uuidString, reset.revision])
            }
            let replay = try await store.reset(expectedRevision: initial.revision, runID: started.runID,
                conversationID: conversation.id, operationID: try #require(operation))
            #expect(replay.revision == reset.revision && replay.wasReset == true)
            #expect(try await store.latest(conversationID: conversation.id)?.revision == rebuilt.revision)
            #expect(try await f.environment.runStore.run(id: started.runID)?.conversationMode == ConversationMode.plan.rawValue)
            try #require(f.requests.complete(at: 2, text: "The checklist reset is verified; its original steps and separate Goal remain preserved."))
            _ = try await waitForEnd(f, runID: started.runID)
        } catch { await stopOwnedFixtureRuns(f, conversationID: conversation.id, root: root); throw error }
        await stopOwnedFixtureRuns(f, conversationID: conversation.id, root: root)
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
            #expect(request.toolSchemas.filter { $0.name == UserAskTool.name }.count == 1)
            var descriptors = Dictionary(uniqueKeysWithValues: CatalogToolExecutor().allDescriptors.map { ($0.name, $0) })
            // These exact metadata tools are added by the runtime, outside
            // CatalogToolExecutor. Their native effects still must be read-only;
            // any other unknown offered schema remains a failing contract.
            for descriptor in ToolDiscovery.runtimeDescriptors(publicWebOnly: false) {
                descriptors[descriptor.name] = descriptor
            }
            for schema in request.toolSchemas where schema.name != PlanSubmission.toolName {
                let descriptor = try #require(descriptors[schema.name],
                    "No executable or native runtime descriptor for \(schema.name)")
                if [UserAskTool.name, TaskResetPlanTool.name].contains(schema.name) {
                    // These exact main-run interactions are narrow Plan
                    // internal-state exceptions. No other internal
                    // mutation is admitted by the corrected wire assertion.
                    #expect(descriptor.effect == .internalState)
                    #expect(descriptor.executionBoundary == .mainRunOnly)
                    #expect(!descriptor.isSideEffecting && descriptor.riskLabels.isEmpty && !descriptor.requiresHostScope)
                    if case .failure = PlanToolPolicy().decision(for: descriptor) {
                        Issue.record("The native metadata helper must satisfy Plan's exact narrow exception")
                    }
                } else { #expect(descriptor.effect == .readOnly) }
            }
            await f.center.cancel(runID: run.id)
        }
    }

    @Test("Plan-to-Goal uses the accepted implementation contract and keeps planning history and original constraints")
    func acceptedPlanGoalUsesImplementationContract() async throws {
        let f = try await fixture()
        let preparationRequests = f.requests
        f.center.launchTestHooks.didPrepareServiceStage = { runID, stage in
            preparationRequests.recordPreparation(runID: runID, stage: stage)
        }
        defer { f.center.launchTestHooks.didPrepareServiceStage = nil }
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
        let history = try await f.environment.conversationStore.messages(conversationID: conversation.id)
        let confirmed = history.compactMap { message -> (PersistedMessage, PlanConfirmationSnapshot)? in
            PlanConfirmationSnapshot.from(message: message).map { (message, $0) }
        }
        #expect(confirmed.count == 1 && confirmed[0].0.role == "user" && confirmed[0].0.runID == runID)
        #expect(confirmed[0].1.plan == accepted && confirmed[0].1.goalID == goal.id)
        #expect(!accepted.awaitsConfirmation && view.canPauseGoal)
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

    @Test("A failed Plan confirmation retains the pending action and starts neither a Goal nor provider")
    func confirmationFailureKeepsPendingPlan() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Failed confirmation fixture")
        let source = PlanDraft(conversationID: conversation.id, status: .ready,
            title: "Retain the pending plan", summary: "No user decision may disappear on a failed write",
            sections: [.init(title: "Build", body: "Produce the agreed report", order: 0)],
            acceptanceCriteria: [.init(text: "Verified", verification: "Read the result")])
        try await f.environment.intelligenceStore.savePlanRevision(source)
        try await f.environment.database.writer { db in
            try db.execute(sql: "CREATE TRIGGER fail_plan_message BEFORE INSERT ON message_parts BEGIN SELECT RAISE(ABORT, 'injected Plan history failure'); END;")
        }
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await view.load(); await view.acceptLatestPlan(as: .goal)
        #expect(view.latestPlan?.status == .ready && view.latestPlan?.awaitsConfirmation == true)
        #expect(view.actionError != nil && view.activeGoal == nil)
        #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).isEmpty)
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).isEmpty)
        #expect(f.requests.all.isEmpty)
    }

    @Test("Accepted Plan is one user history message and a new pending plan does not rewrite the old card after reload")
    func acceptedPlanHistoryIsSeparateFromCurrentPlan() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Plan history fixture")
        let source = PlanDraft(conversationID: conversation.id, status: .ready,
            title: "First confirmed deliverable", summary: "The first decision stays in history",
            sections: [.init(title: "Write the report", body: "Deliver report.csv and verify its rows", order: 0)],
            acceptanceCriteria: [.init(text: "Correct table", verification: "Read back the rows")])
        try await f.environment.intelligenceStore.savePlanRevision(source)
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await view.load(); await view.acceptLatestPlan(as: .normal)
        let runID = try #require(view.selectedRunID)
        _ = try await waitForRequest(f, after: 0)
        let accepted = try #require(view.latestPlan)
        #expect(accepted.status == .accepted && !accepted.awaitsConfirmation)
        let messages = try await f.environment.conversationStore.messages(conversationID: conversation.id)
        #expect(messages.filter { $0.role == "user" }.count == 1)
        let history = try #require(messages.first.flatMap(PlanConfirmationSnapshot.from(message:)))
        #expect(history.plan.title == source.title && history.execution == .normal)
        try #require(f.requests.complete(at: 0)); _ = try await waitForEnd(f, runID: runID)
        try await f.environment.intelligenceStore.savePlanRevision(accepted.revised(status: .ready, title: "Later pending plan"))
        let reopened = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await reopened.load()
        #expect(reopened.latestPlan?.title == "Later pending plan" && reopened.latestPlan?.awaitsConfirmation == true)
        let reopenedMessages = try await f.environment.conversationStore.messages(conversationID: conversation.id)
        #expect(reopenedMessages.filter { $0.role == "user" }.count == 1)
        #expect(reopenedMessages.compactMap(PlanConfirmationSnapshot.from(message:)).first == history)
        #expect(f.requests.all.count == 1)
    }


    @Test("Plan confirmation captures synthetic ingress secrets before saving and launches the exact safe prompt")
    func planConfirmationUsesCanonicalSecretIngress() async throws {
        let f = try await fixture()
        let isolatedSecrets = IsolatedIngressSecretStore()
        let suite = "org.floeagent.tests.plan-ingress.\(UUID().uuidString)"
        let isolatedVault = CredentialVaultService(records: f.environment.credentialStore,
            local: isolatedSecrets, synchronized: isolatedSecrets, preferencesSuite: suite)
        f.center.launchTestHooks.ingressCredentialVault = isolatedVault
        defer {
            f.center.launchTestHooks.ingressCredentialVault = nil
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let conversation = try await f.center.createConversation(title: "Safe Plan confirmation fixture")
        // Synthetic values from SecretIngressScannerTests, never real keys.
        let source = PlanDraft(conversationID: conversation.id, status: .ready,
            title: "Use the task credentials safely", summary: "Keep credentials in secure storage",
            sections: [.init(title: "Prepare", body: "password: \"correct horse battery staple\"\nAPI_KEY=sk-live-secret", order: 0)],
            acceptanceCriteria: [.init(text: "Safe result", verification: "Inspect the saved artifact")])
        try await f.environment.intelligenceStore.savePlanRevision(source)
        await #expect(throws: (any Error).self) {
            _ = try await f.environment.intelligenceStore.confirmPlan(
                source, conversationID: conversation.id, execution: .goal,
                captureSecrets: { _ in throw FloeError.validationFailed("injected vault capture failure") })
        }
        #expect(try await f.environment.intelligenceStore.latestPlan(conversationID: conversation.id)?.status == .ready)
        #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).isEmpty)
        #expect(try await f.environment.conversationStore.messages(conversationID: conversation.id).isEmpty)
        func clearFixtureCredentials() async {
            for record in (try? await f.environment.credentialStore.records(owner: .conversation(conversation.id))) ?? [] {
                try? await isolatedVault.delete(.init(id: record.id))
            }
        }
        do {
            let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
            await view.load()
            isolatedSecrets.denyWrites = true
            await view.acceptLatestPlan(as: .normal)
            #expect(view.actionError != nil && view.latestPlan?.status == .ready)
            #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).isEmpty)
            #expect(try await f.environment.conversationStore.messages(conversationID: conversation.id).isEmpty)
            #expect(try await f.environment.runStore.runs(conversationID: conversation.id).isEmpty)
            #expect(try await f.environment.credentialStore.records(owner: .conversation(conversation.id)).isEmpty)
            #expect(isolatedSecrets.count == 0 && f.requests.all.isEmpty)
            isolatedSecrets.denyWrites = false
            await view.acceptLatestPlan(as: .normal)
            #expect(view.actionError == nil)
            let runID = try #require(view.selectedRunID)
            _ = try await waitForRequest(f, after: 0)
            let history = try await f.environment.conversationStore.messages(conversationID: conversation.id)
            let message = try #require(history.first { PlanConfirmationSnapshot.from(message: $0) != nil })
            let snapshot = try #require(PlanConfirmationSnapshot.from(message: message))
            let run = try #require(try await f.environment.runStore.run(id: runID))
            let scanned = SecretIngressScanner.scan(snapshot.executionPrompt)
            #expect(scanned.captures.isEmpty && scanned.sanitizedText == snapshot.executionPrompt)
            #expect(snapshot.executionPrompt == message.content && message.content == run.goal)
            #expect(snapshot.executionPrompt == GoalFromPlanFactory.implementationPrompt(from: snapshot.plan)
                .trimmingCharacters(in: .whitespacesAndNewlines))
            let frozen = try snapshot.encoded()
            for synthetic in ["correct horse battery staple", "sk-live-secret"] {
                #expect(!message.content.contains(synthetic) && !frozen.contains(synthetic))
            }
            let credentials = try await f.environment.credentialStore.records(owner: .conversation(conversation.id))
            #expect(credentials.count == 2 && isolatedSecrets.count == 2)
            let capturedValues = try Set(credentials.map { try isolatedSecrets.read(account: $0.keychainAccount) })
            #expect(capturedValues == Set([Data("correct horse battery staple".utf8), Data("sk-live-secret".utf8)]))
            #expect(credentials.allSatisfy { snapshot.executionPrompt.contains(CapturedSecret.placeholder(for: $0.id)) })
            let repeated = try await f.center.confirmPlan(source, in: conversation.id, execution: .normal)
            #expect(repeated.snapshot == snapshot && !repeated.wasCreated)
            #expect(try await f.environment.credentialStore.records(owner: .conversation(conversation.id)).count == 2)
            try #require(f.requests.complete(at: 0)); _ = try await waitForEnd(f, runID: runID)
        } catch {
            await clearFixtureCredentials()
            throw error
        }
        await clearFixtureCredentials()
    }

    @Test("An injected run-insert failure leaves one confirmed card whose explicit retry uses the original planned run")
    func confirmedPlanFirstLaunchCanBeRetriedAfterRunInsertFailure() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Plan first-launch recovery fixture")
        let source = PlanDraft(conversationID: conversation.id, status: .ready,
            title: "Deliver once", summary: "Keep the original accepted decision",
            sections: [.init(title: "Write", body: "Produce report.csv then verify its rows", order: 0)],
            acceptanceCriteria: [.init(text: "Correct output", verification: "Read back the rows")])
        try await f.environment.intelligenceStore.savePlanRevision(source)
        try await f.environment.database.writer { db in
            try db.execute(sql: "CREATE TRIGGER reject_plan_run BEFORE INSERT ON runs BEGIN SELECT RAISE(ABORT, 'injected Plan first-run failure'); END;")
        }
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await view.load(); await view.acceptLatestPlan(as: .normal)
        #expect(view.actionError != nil && view.latestPlan?.status == .accepted)
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).isEmpty)
        #expect(f.requests.all.isEmpty)
        let staged = try await f.environment.conversationStore.messages(conversationID: conversation.id)
        #expect(staged.filter { $0.role == "user" }.count == 1)
        let message = try #require(staged.first)
        let snapshot = try #require(PlanConfirmationSnapshot.from(message: message))
        #expect(message.runID == nil && view.canRetryConfirmedPlan(message))
        let reopened = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await reopened.load()
        #expect(reopened.canRetryConfirmedPlan(message) && f.requests.all.isEmpty,
            "Loading history must offer recovery without launching automatically")
        await #expect(throws: FloeError.unauthorized) {
            _ = try await f.environment.intelligenceStore.planConfirmationForLaunch(snapshot, conversationID: UUID())
        }
        try await f.environment.database.writer { db in try db.execute(sql: "DROP TRIGGER reject_plan_run") }
        await reopened.retryConfirmedPlan(snapshot)
        #expect(reopened.actionError == nil && reopened.selectedRunID == snapshot.executionRunID)
        _ = try await waitForRequest(f, after: 0)
        let runs = try await f.environment.runStore.runs(conversationID: conversation.id)
        #expect(runs.count == 1 && runs[0].id == snapshot.executionRunID)
        let consumed = try await f.environment.conversationStore.messages(conversationID: conversation.id)
        let retained = try #require(consumed.first { $0.id == snapshot.messageID })
        #expect(consumed.filter { $0.role == "user" }.count == 1 && retained.runID == snapshot.executionRunID)
        #expect(PlanConfirmationSnapshot.from(message: retained) == snapshot && retained.parts == message.parts)
        #expect(try await f.environment.intelligenceStore.planRevisions(conversationID: conversation.id).count == 2)
        #expect(!reopened.canRetryConfirmedPlan(retained))
        try #require(f.requests.complete(at: 0)); _ = try await waitForEnd(f, runID: snapshot.executionRunID)
        await reopened.retryConfirmedPlan(snapshot)
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
        #expect(f.requests.all.count == 1, "An existing run must use ordinary Continue, not start another run")
    }

    @Test("Closing a pending Plan card is revision-scoped presentation only and leaves the plan available")
    func closingPlanCardDoesNotRejectOrMutateItsPlan() {
        let conversationID = UUID()
        let plan = PlanDraft(conversationID: conversationID, status: .ready,
            title: "Pending plan", summary: "Keep this context",
            sections: [.init(title: "Write", body: "Produce and verify the result", order: 0)],
            acceptanceCriteria: [.init(text: "Correct", verification: "Read the result")])
        let original = plan
        var hidden: Set<ThreadPlanConfirmationPresentationKey> = []
        hidden.insert(.init(plan))
        #expect(hidden.contains(.init(plan)))
        #expect(plan == original && plan.status == .ready && plan.isDecisionComplete)
        #expect(plan.awaitsConfirmation) // presentation never changes business state
        #expect(!hidden.contains(.init(plan.revised(status: .ready))))
        var otherTask = plan; otherTask.conversationID = UUID()
        #expect(!hidden.contains(.init(otherTask)))
        var otherPlan = plan; otherPlan.id = UUID()
        #expect(!hidden.contains(.init(otherPlan)))
    }


    @Test("Goal-mode steering creates one real same-task Goal before model I/O and binds it at actual consumption")
    func guidedGoalIntentPersistsAndBindsAtConsumedBoundary() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Native guided Goal")
        let started = try await f.center.startRun(goal: "Keep the original admitted round",
            in: conversation.id, provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        _ = try await waitForRequest(f, after: 0)
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await view.load(); view.selectedModelID = f.model.id
        try await waitForRunningComposer(view, fixture: f, runID: started.runID)
        view.selectAgentMode(.goal); view.selectRunningInputMode(.steer)
        let objective = "Create the requested report and verify the actual saved evidence"
        view.draft = objective
        await view.send()
        #expect(view.actionError == nil && view.agentMode == .agent && view.draft.isEmpty)
        let goals = try await f.environment.intelligenceStore.goals(conversationID: conversation.id)
        let goal = try #require(goals.first)
        #expect(goals.count == 1 && goal.objective == objective && goal.conversationID == conversation.id)
        #expect(goal.status == .active && goal.steps.first?.status == .pending)
        let pending = try await f.environment.runningInputStore.pending(conversationID: conversation.id)
        #expect(pending.count == 1 && pending[0].id == goal.id && pending[0].executionMode == "goal")
        #expect(f.requests.all.count == 1, "Goal creation must not depend on an auxiliary/model call")
        #expect(try await f.environment.runStore.run(id: started.runID)?.goalID == nil,
            "Accepted intent is not a fabricated claim that the still-streaming round consumed it")
        await view.load()
        #expect(view.activeGoal?.id == goal.id, "The card projects the actual durable Goal")
        try #require(f.requests.complete(at: 0))
        let next = try await waitForRequest(f, after: 1)
        #expect(next.diagnosticRunID == started.runID.uuidString)
        let bound = try #require(try await f.environment.runStore.run(id: started.runID))
        #expect(bound.goalID == goal.id && bound.goal == "Keep the original admitted round")
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
        #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).count == 1)
        let messages = try await f.environment.conversationStore.messages(conversationID: conversation.id)
        #expect(messages.filter { $0.role == "user" && $0.content == objective }.count == 1)
        try await f.center.stopRunFromComposer(bound)
        _ = await started.result.value
        #expect(try await f.environment.intelligenceStore.goal(id: goal.id)?.status == .paused,
            "Composer Stop still pauses the exact admitted Goal")
    }

    @Test("A failed native Goal+queue transaction preserves all draft text and the selected mode")
    func guidedGoalInputInsertFailureRollsBackGoalAndKeepsDraft() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Rejected guided Goal")
        let started = try await f.center.startRun(goal: "Original round",
            in: conversation.id, provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        _ = try await waitForRequest(f, after: 0)
        try await f.environment.database.writer { db in
            try db.execute(sql: "CREATE TRIGGER reject_goal_input BEFORE INSERT ON pending_user_inputs BEGIN SELECT RAISE(ABORT, 'injected Goal input failure'); END;")
        }
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await view.load(); view.selectedModelID = f.model.id
        try await waitForRunningComposer(view, fixture: f, runID: started.runID)
        view.selectAgentMode(.goal); view.selectRunningInputMode(.steer)
        let draft = " \nPreserve this complete Goal request, including whitespace.\n "
        view.draft = draft
        await view.send()
        #expect(view.actionError != nil && view.agentMode == .goal && view.draft == draft)
        #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).isEmpty)
        #expect(try await f.environment.runningInputStore.pending(conversationID: conversation.id).isEmpty)
        #expect(f.requests.all.count == 1)
        let original = try #require(try await f.environment.runStore.run(id: started.runID))
        #expect(original.goalID == nil && original.endedAt == nil)
        try await f.environment.database.writer { db in try db.execute(sql: "DROP TRIGGER reject_goal_input") }
        try await f.center.stopRunFromComposer(original)
        _ = await started.result.value
    }

    @Test("Late accepted guided Goal cannot overwrite a newer explicit mode or newly typed draft")
    func guidedGoalAcceptancePreservesNewerModeAndDraft() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Late guided Goal acceptance")
        let started = try await f.center.startRun(goal: "Original round",
            in: conversation.id, provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        _ = try await waitForRequest(f, after: 0)
        let gate = Gate()
        f.center.launchTestHooks.afterRunningInputCommitted = { id in await gate.hold(id: id) }
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await view.load(); view.selectedModelID = f.model.id
        try await waitForRunningComposer(view, fixture: f, runID: started.runID)
        view.selectAgentMode(.goal); view.selectRunningInputMode(.steer)
        view.draft = "The accepted long-term objective"
        let send = Task { @MainActor in await view.send() }
        try await waitForGate(gate)
        view.selectAgentMode(.chat)
        view.draft = "This is a new, unsent message"
        await gate.release(); await send.value
        f.center.launchTestHooks.afterRunningInputCommitted = nil
        #expect(view.actionError == nil && view.agentMode == .chat)
        #expect(view.draft == "This is a new, unsent message")
        let goal = try #require(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).first)
        #expect(goal.objective == "The accepted long-term objective")
        try await f.center.deleteGoal(conversationID: conversation.id, expectedGoalID: goal.id,
                                      expectedRevision: goal.revision ?? 1)
        let current = try #require(try await f.environment.runStore.run(id: started.runID))
        try await f.center.stopRunFromComposer(current)
        _ = await started.result.value
        #expect(view.agentMode == .chat && view.draft == "This is a new, unsent message")
    }

    @Test("A cancelled queued Goal never adopts a newer Goal at queue launch")
    func queuedGoalKeepsItsExactIdentityAfterDeleteAndReplacement() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Exact queued Goal identity")
        let started = try await f.center.startRun(goal: "Original round",
            in: conversation.id, provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        _ = try await waitForRequest(f, after: 0)
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await view.load(); view.selectedModelID = f.model.id
        try await waitForRunningComposer(view, fixture: f, runID: started.runID)
        view.selectAgentMode(.goal); view.selectRunningInputMode(.queue)
        view.draft = "Queued Goal A"
        await view.send()
        #expect(view.actionError == nil && view.agentMode == .agent)
        let a = try #require(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).first)
        let input = try #require(try await f.environment.runningInputStore.pending(conversationID: conversation.id).first)
        #expect(input.id == a.id && input.status == .queued)
        try await f.center.deleteGoal(conversationID: conversation.id, expectedGoalID: a.id, expectedRevision: a.revision ?? 1)
        let b = ConversationGoal(conversationID: conversation.id, objective: "Different Goal B",
            acceptanceCriteria: [.init(text: "Keep B independent")],
            steps: [.init(title: "Work only toward B", status: .pending, order: 0)], status: .active)
        try await f.environment.intelligenceStore.saveGoal(b)
        try #require(f.requests.complete(at: 0))
        _ = await started.result.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while f.center.hasLiveOwner(runID: started.runID), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(!f.center.hasLiveOwner(runID: started.runID))
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
        #expect(f.requests.all.count == 1)
        #expect(try await f.environment.runningInputStore.input(id: input.id)?.status == .queued)
        #expect(try await f.environment.intelligenceStore.goal(id: a.id)?.status == .cancelled)
        #expect(try await f.environment.intelligenceStore.goal(id: b.id)?.status == .active)
    }

    @Test("Explicit Goal acceptance preserves original Notes ownership and refuses another conversation's run")
    func nativeGoalInputCannotCrossConversationOrAssistantOwnership() async throws {
        let f = try await fixture()
        let ordinary = try await f.center.createConversation(title: "Ordinary task")
        let assistant = try await f.center.createConversation(title: "Notes-owned task", purpose: .notes)
        let run = RunRecord(id: UUID(), conversationID: assistant.id, state: "preparing", goal: "Notes task",
                            startedAt: Date(), conversationMode: "chat")
        try await f.environment.runStore.saveRun(run)
        let crossed = PendingUserInput(conversationID: ordinary.id, targetRunID: run.id,
            content: "Wrong task", mode: .steer, executionMode: "goal")
        await #expect(throws: TaskGoalError.staleRun) {
            _ = try await f.environment.intelligenceStore.enqueueGoalInput(crossed, expectedRunID: run.id)
        }
        #expect(try await f.environment.intelligenceStore.goals(conversationID: ordinary.id).isEmpty)
        let input = PendingUserInput(conversationID: assistant.id, targetRunID: run.id,
            content: "Continue within the current Notes task", mode: .queue, executionMode: "goal")
        let accepted = try await f.environment.intelligenceStore.enqueueGoalInput(input, expectedRunID: run.id)
        let goal = try #require(try await f.environment.intelligenceStore.goal(id: accepted.id))
        #expect(goal.conversationID == assistant.id && goal.objective == input.content)
        #expect(try await f.environment.runStore.run(id: run.id)?.goalID == nil)
        await f.center.reload()
        #expect(!f.center.conversations.contains { $0.id == assistant.id })
        #expect(f.center.conversations.contains { $0.id == ordinary.id })
        #expect(try await f.environment.intelligenceStore.goals(conversationID: ordinary.id).isEmpty)
    }

    @Test("A preparing run queues the accepted Goal without a parallel launch or fabricated round binding")
    func guidedGoalDuringPreparationWaitsForItsRealDelivery() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Preparing Goal delivery")
        let gate = Gate()
        f.center.launchTestHooks.afterRunPrepared = { id in await gate.hold(id: id) }
        let launch = Task { @MainActor in
            try await f.center.startRun(goal: "Original preparing round", in: conversation.id,
                provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        }
        try await waitForGate(gate)
        let runID = try #require(await gate.identity)
        try await f.center.submitRunningInput(content: "The accepted pending Goal", in: conversation.id,
            expectedRunID: runID, mode: .steer, selectedModelID: f.model.id, workspaceID: nil,
            executionMode: .goal, attachments: [])
        let input = try #require(try await f.environment.runningInputStore.pending(conversationID: conversation.id).first)
        #expect(input.status == .queued && input.executionMode == "goal")
        #expect(try await f.environment.intelligenceStore.goal(id: input.id)?.objective == input.content)
        #expect(try await f.environment.runStore.run(id: runID)?.goalID == nil)
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
        #expect(f.requests.all.isEmpty)
        try await f.center.removePendingInput(id: input.id)
        let goal = try #require(try await f.environment.intelligenceStore.goal(id: input.id))
        try await f.center.deleteGoal(conversationID: conversation.id, expectedGoalID: goal.id,
                                      expectedRevision: goal.revision ?? 1)
        f.center.launchTestHooks.afterRunPrepared = nil
        await gate.release()
        let started = try await launch.value
        _ = try await waitForRequest(f, after: 0)
        let current = try #require(try await f.environment.runStore.run(id: started.runID))
        try await f.center.stopRunFromComposer(current)
        _ = await started.result.value
    }


    @Test("Composer Stop pauses only this run's accepted pending Goal before it reaches the consume boundary")
    func stopPausesTheExactAcceptedPendingGoalBeforeConsumption() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Stop pending Goal")
        let started = try await f.center.startRun(goal: "Original active round", in: conversation.id,
            provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        _ = try await waitForRequest(f, after: 0)
        let unrelated = try await f.center.createConversation(title: "Another task")
        let otherGoal = ConversationGoal(conversationID: unrelated.id, objective: "Keep the other task independent",
            acceptanceCriteria: [.init(text: "Unchanged")], steps: [.init(title: "Other work", order: 0)], status: .active)
        try await f.environment.intelligenceStore.saveGoal(otherGoal)
        let gate = Gate()
        f.center.launchTestHooks.afterRunningInputCommitted = { id in await gate.hold(id: id) }
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await view.load(); view.selectedModelID = f.model.id
        try await waitForRunningComposer(view, fixture: f, runID: started.runID)
        view.selectAgentMode(.goal); view.selectRunningInputMode(.steer)
        view.draft = "Keep this explicit Goal saved and pause it on Stop"
        let send = Task { @MainActor in await view.send() }
        try await waitForGate(gate)
        let inputID = try #require(await gate.identity)
        let original = try #require(try await f.environment.runStore.run(id: started.runID))
        #expect(original.goalID == nil)
        try await f.center.stopRunFromComposer(original)
        _ = await started.result.value
        #expect(try await f.environment.intelligenceStore.goal(id: inputID)?.status == .paused)
        #expect(try await f.environment.intelligenceStore.goal(id: otherGoal.id)?.status == .active)
        f.center.launchTestHooks.afterRunningInputCommitted = nil
        await gate.release(); await send.value
        let retained = try #require(try await f.environment.runningInputStore.input(id: inputID))
        #expect(retained.status == .queued && retained.targetRunID == original.id)
        #expect(retained.content == "Keep this explicit Goal saved and pause it on Stop")
        #expect(view.actionError == nil && view.agentMode == .agent && view.draft.isEmpty)
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
        #expect(try await f.environment.runStore.run(id: original.id)?.goalID == nil,
            "Stopping cannot fabricate an admission that never happened")
        #expect(f.requests.all.count == 1)
    }


    @Test("Resuming a stopped pending Goal consumes its original input in the native launch transaction exactly once")
    func stoppedPendingGoalResumeIsAtomicAndDoesNotRepeatItsInput() async throws {
        let f = try await fixture()
        let conversation = try await f.center.createConversation(title: "Resume accepted pending Goal")
        let original = try await f.center.startRun(goal: "The original current round", in: conversation.id,
            provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        _ = try await waitForRequest(f, after: 0)
        let view = ThreadDetailViewModel(conversationID: conversation.id, center: f.center)
        await view.load(); view.selectedModelID = f.model.id
        try await waitForRunningComposer(view, fixture: f, runID: original.runID)
        view.selectAgentMode(.goal); view.selectRunningInputMode(.queue)
        let objective = "Resume this exact accepted Goal without replaying its original input"
        view.draft = objective; await view.send()
        let input = try #require(try await f.environment.runningInputStore.pending(conversationID: conversation.id).first)
        let activeRound = try #require(try await f.environment.runStore.run(id: original.runID))
        try await f.center.stopRunFromComposer(activeRound)
        _ = await original.result.value
        let pausedGoal = try #require(try await f.environment.intelligenceStore.goal(id: input.id))
        #expect(pausedGoal.status == .paused)
        try await f.environment.database.writer { db in
            try db.execute(sql: "CREATE TRIGGER reject_goal_resume_run BEFORE INSERT ON runs BEGIN SELECT RAISE(ABORT, 'injected first Goal delivery failure'); END;")
        }
        await #expect(throws: (any Error).self) {
            _ = try await f.center.resumeGoal(conversationID: conversation.id,
                expectedGoalID: pausedGoal.id, expectedRevision: pausedGoal.revision ?? 1,
                provider: f.provider, model: f.model)
        }
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 1)
        let unconsumed = try #require(try await f.environment.runningInputStore.input(id: input.id))
        #expect(unconsumed.status == .queued && unconsumed.consumedRunID == nil && unconsumed.content == objective)
        #expect(try await f.environment.intelligenceStore.goal(id: pausedGoal.id)?.status == .paused)
        #expect(f.requests.all.count == 1)
        try await f.environment.database.writer { db in try db.execute(sql: "DROP TRIGGER reject_goal_resume_run") }
        let goal = try #require(try await f.environment.intelligenceStore.goal(id: pausedGoal.id))
        let resumed = try await f.center.resumeGoal(conversationID: conversation.id,
            expectedGoalID: goal.id, expectedRevision: goal.revision ?? 1,
            provider: f.provider, model: f.model)
        let started = try #require(resumed.startedRun)
        _ = try await waitForRequest(f, after: 1)
        let consumed = try #require(try await f.environment.runningInputStore.input(id: input.id))
        #expect(consumed.status == .consumed && consumed.consumedRunID == started.runID && consumed.content == objective)
        #expect(try await f.environment.runningInputStore.pending(conversationID: conversation.id).isEmpty)
        let run = try #require(try await f.environment.runStore.run(id: started.runID))
        #expect(run.goalID == goal.id && run.goal == objective)
        let history = try await f.environment.conversationStore.messages(conversationID: conversation.id)
        #expect(history.filter { $0.role == "user" && $0.content == objective }.count == 1)
        let current = try #require(try await f.environment.intelligenceStore.goal(id: goal.id))
        let again = try await f.center.resumeGoal(conversationID: conversation.id,
            expectedGoalID: current.id, expectedRevision: current.revision ?? 1,
            provider: f.provider, model: f.model)
        #expect(again.runID == started.runID && again.startedRun == nil)
        #expect(try await f.environment.runStore.runs(conversationID: conversation.id).count == 2)
        #expect(f.requests.all.count == 2)
        try await f.center.stopRunFromComposer(run)
        _ = await started.result.value
        #expect(try await f.environment.runningInputStore.input(id: input.id)?.status == .consumed)
        #expect(try await f.environment.intelligenceStore.goals(conversationID: conversation.id).count == 1)
    }

}
#endif
