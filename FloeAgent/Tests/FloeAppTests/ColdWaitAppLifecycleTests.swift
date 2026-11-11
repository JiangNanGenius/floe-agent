// SPDX-License-Identifier: MPL-2.0
// Hosted App tests: real preview environment, canonical SQLite and file actions.
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloeAgentRuntime
import FloeProviders
import FloeSecurity
@testable import FloeApp

@Suite("FloeApp.ColdWaitLifecycle", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ColdWaitAppLifecycleTests {
    private struct ColdWait {
        let conversationID: UUID
        let runID: UUID
        let record: AgentWaitRecord
        let binding: TaskExecutionBinding
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let environment: AppEnvironment
        let checkpoints: SQLiteRunCheckpointStore
        let library: PersonalContentLibrary
        let access: StudioDocumentAccess
        var conversations: Set<UUID> = []
        var beforeCommitReadbacks = 0
        var center: ConversationCenter { environment.conversationCenter }

        init() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("FloeColdWaitApp-" + UUID().uuidString, isDirectory: true)
            let library = PersonalContentLibrary(root: root.appendingPathComponent("Library"))
            let access = try StudioDocumentAccess(root: root.appendingPathComponent("Authority"))
            let environment = AppEnvironment.preview()
            try await environment.database.migrate()
            // Fail visibly if preview composition changes. Do not substitute
            // a file/mock store or bypass the canonical execution-pin check.
            let checkpoints = try #require(environment.checkpointStore as? SQLiteRunCheckpointStore)
            self.root = root
            self.library = library
            self.access = access
            self.environment = environment
            self.checkpoints = checkpoints
            environment.studioCoordinator = StudioCoordinator(
                environment: environment, authority: access, library: library)
        }

        func installColdWait(conversationID: UUID = UUID(), expired: Bool = false) async throws -> ColdWait {
            let now = Date(), runID = UUID(), callID = "cold-wait-" + UUID().uuidString
            let waitStartedAt = expired ? now.addingTimeInterval(-60) : now
            let runStartedAt = waitStartedAt.addingTimeInterval(-1)
            if try await environment.conversationStore.conversation(id: conversationID) == nil {
                try await environment.conversationStore.saveConversation(.init(
                    id: conversationID, title: "Synthetic cold wait", createdAt: runStartedAt, updatedAt: now))
            }
            conversations.insert(conversationID)
            let bindings = TaskExecutionBindingStore(database: environment.database)
            // A saved target is not started or claimed healthy. Native waits
            // retain its real persisted pin even while commands are unavailable.
            let binding = try await bindings.bindInitial(.init(conversationID: conversationID,
                target: .init(environmentID: "saved-cold-wait-" + conversationID.uuidString,
                    backend: .linuxVM, operatingSystem: "linux", architecture: "arm64"),
                generation: 7, updatedAt: runStartedAt))
            try await environment.runStore.saveRun(.init(id: runID, conversationID: conversationID,
                state: "executingTool", goal: "Synthetic persisted wait", startedAt: runStartedAt))
            try await bindings.pinRun(runID: runID, binding: binding)
            let request = RuntimeWaitRequest(seconds: expired ? 1 : 3_600)
            let call = try ToolCall(id: callID, toolName: AgentWaitTool.name,
                argumentsJSON: JSONEncoder().encode(request), scope: .local).withIDContext(runID: runID)
            let record = try AgentWaitRecord(owner: .init(conversationID: conversationID,
                runID: runID, callID: callID, clientSessionID: "run:" + runID.uuidString),
                request: request, now: waitStartedAt)
            let descriptor = AnyAgentTool(AgentWaitTool()).descriptor
            let checkpoint = AgentCheckpoint(runID: runID, conversationID: conversationID,
                state: .checkpointed(.init(reason: AgentWaitRecovery.markerPrefix + ":" + record.waitID.uuidString)),
                messages: [.init(role: "user", content: "Synthetic persisted wait", createdAt: runStartedAt)],
                pendingToolCalls: [call], createdAt: waitStartedAt.addingTimeInterval(0.1),
                conversationMode: .chat, executionBinding: binding,
                toolLifecycleEntries: [.init(callID: callID, toolName: AgentWaitTool.name,
                    authorizationIdentity: descriptor.authorizationIdentity, isSideEffecting: false,
                    phase: .dispatched, updatedAt: waitStartedAt)], runtimeWaits: [record])
            try await environment.checkpointStore.save(checkpoint)
            let independentlyLoaded = try #require(try await readCheckpoint(runID: runID))
            #expect(independentlyLoaded.executionBinding == binding)
            #expect(try await environment.runStore.run(id: runID)?.executionBinding == binding)
            #expect(AgentWaitRecovery.hasWaitingMarker(independentlyLoaded))
            #expect(try await checkpoints.pendingRuntimeWaitCheckpoints().contains { $0.runID == runID })
            return ColdWait(conversationID: conversationID, runID: runID, record: record, binding: binding)
        }

        func readCheckpoint(runID: UUID) async throws -> AgentCheckpoint? {
            // A fresh instance reads the same real canonical DB row; no
            // test-owned in-memory projection can satisfy the assertions.
            try await SQLiteRunCheckpointStore(database: environment.database, legacyDirectory: nil).load(runID: runID)
        }

        func expectStopped(_ cold: ColdWait) async throws {
            let checkpoint = try #require(try await readCheckpoint(runID: cold.runID))
            let receipt = try #require(checkpoint.runtimeWaits?.first?.receipt)
            let row = try #require(try await environment.runStore.run(id: cold.runID))
            #expect(!AgentWaitRecovery.hasWaitingMarker(checkpoint))
            #expect(receipt.status == .cancelled)
            #expect(receipt.waitID == cold.record.waitID)
            #expect(receipt.continuationInputID == cold.record.continuationInputID)
            #expect(checkpoint.executionBinding == cold.binding)
            #expect(row.executionBinding == cold.binding)
            #expect(row.state == "cancelled" && row.endedAt != nil)
            #expect(center.runtimeWaitRecoveryWork(conversationID: cold.conversationID).isEmpty)
            #expect(!center.hasLiveOwner(runID: cold.runID))
            #expect(try await environment.runStore.runs(conversationID: cold.conversationID).map(\.id) == [cold.runID])
            #expect(try await checkpoints.pendingRuntimeWaitCheckpoints().allSatisfy { $0.runID != cold.runID })
            #expect(try await environment.runningInputStore.pending(conversationID: cold.conversationID).isEmpty)
        }

        func finish() async {
            // Also drain on a thrown #require/read error so this test never
            // leaves an hour-long recovery worker in the reused App host.
            for id in conversations {
                let work = center.runtimeWaitRecoveryWork(conversationID: id)
                await center.stopRuntimeWaitRecovery(work)
                for run in (try? await environment.runStore.runs(conversationID: id)) ?? [] {
                    await center.cancel(runID: run.id)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Stop drains freshly registered cold-wait recovery and commits cancellation to canonical SQLite")
    func refreshedColdWaitStopsWithoutCreatingAnotherRun() async throws {
        let f = try await Fixture()
        do {
            let cold = try await f.installColdWait()
            await f.center.refreshRuntimeWaitRecovery()
            // Stay on MainActor: no sleep, yield or DB await between refresh,
            // capturing its actual setup reservation and entering UI Stop.
            let captured = f.center.runtimeWaitRecoveryWork(conversationID: cold.conversationID)
            #expect(captured[cold.runID] != nil)
            await f.center.cancel(runID: cold.runID)
            // The real Stop joins the registered worker and settles its
            // checkpoint under an invocation reservation before returning.
            try await f.expectStopped(cold)
            await f.center.stopRuntimeWaitRecovery(captured) // repeat join is harmless
            await f.center.refreshRuntimeWaitRecovery()
            try await f.expectStopped(cold)
            await f.finish()
        } catch {
            await f.finish()
            throw error
        }
    }

    @Test("Actual file Trash/Restore persists the cold wait stop before commit and never restarts it")
    func fileTrashRestoreKeepsBytesAndDoesNotResumeExpiredColdWait() async throws {
        let f = try await Fixture()
        do {
            let payload = Data("original-file+history\0中文".utf8)
            let original = try await f.library.create(kind: .diagram, title: "Synthetic bound original") { directory, _ in
                try payload.write(to: directory.appendingPathComponent("original.bin"))
            }
            let assistant = UUID()
            let cold = try await f.installColdWait(conversationID: assistant, expired: true)
            try await f.access.bindAssistant(conversationID: assistant, projectID: original.id)
            #expect(try await f.access.assistant(projectID: original.id) == assistant)
            let originalURL = try await f.library.resolve(original.id).url.appendingPathComponent("original.bin")
            #expect(try Data(contentsOf: originalURL) == payload)
            // The expired checkpoint is a genuine cold recovery candidate;
            // do not arm it before the actual file deletion owns its fence.
            let elapsedDeadline = try #require(cold.record.deadline)
            #expect(elapsedDeadline < Date())
            let entry = try await PersonalLibraryFileActions.delete(original,
                environment: f.environment, library: f.library, validateSource: {
                    // This callback runs inside the production stop lease,
                    // before the original's file/trash commit. Later retire
                    // logic cannot mask a missing durable stop proof here.
                    try await f.expectStopped(cold)
                    #expect(try Data(contentsOf: originalURL) == payload)
                    f.beforeCommitReadbacks += 1
                })
            #expect(f.beforeCommitReadbacks > 0)
            #expect(try await f.library.records().isEmpty)
            #expect(try await f.library.recentlyDeleted().contains { $0.id == entry.id })
            #expect(!f.center.fileAssistantConversations.contains { $0.id == assistant })
            #expect(f.center.unavailableFileAssistantConversationIDs.contains(assistant))
            #expect(try await f.environment.conversationStore.conversation(id: assistant) != nil)
            #expect(try await f.access.assistant(projectID: original.id) == assistant)
            try await f.expectStopped(cold)
            try await PersonalLibraryFileActions.restore(entry, environment: f.environment, library: f.library)
            let restored = try await f.library.resolve(original.id)
            #expect(restored.record.id == original.id)
            #expect(try Data(contentsOf: restored.url.appendingPathComponent("original.bin")) == payload)
            #expect(try await f.access.assistant(projectID: original.id) == assistant)
            #expect(f.center.fileAssistantConversations.contains { $0.id == assistant })
            #expect(!f.center.unavailableFileAssistantConversationIDs.contains(assistant))
            #expect(try await f.access.pendingFileLifecycles().isEmpty)
            // The old deadline is already due. The actual foreground recovery
            // entry still must not recreate a worker, input or another run.
            await f.center.refreshRuntimeWaitRecovery()
            try await f.expectStopped(cold)
            await f.finish()
        } catch {
            await f.finish()
            throw error
        }
    }
}

@Suite("FloeApp.GoalLifecycle", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct GoalLifecycleTests {
    private let input = TaskGoalCreateArguments(objective: "Record a concrete target for this authorized task",
        acceptanceCriteria: ["The native goal is saved and attached to this run"], steps: ["Keep durable task progress"])
    private func arguments(_ objective: String = "Record a concrete target for this authorized task") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["objective": objective,
            "acceptanceCriteria": ["The native goal is saved and attached to this run"], "steps": ["Keep durable task progress"]])
    }
    private func stores() async throws -> (DatabaseManager, SQLiteConversationStore, SQLiteRunStore, SQLiteIntelligenceStore, UUID) {
        let db = try DatabaseManager.inMemory(); try await db.migrate()
        let conversations = SQLiteConversationStore(database: db), runs = SQLiteRunStore(database: db)
        let id = UUID(), now = Date()
        try await conversations.saveConversation(.init(id: id, title: "Owned goal fixture", createdAt: now, updatedAt: now))
        return (db, conversations, runs, SQLiteIntelligenceStore(database: db), id)
    }
    private func context(runID: UUID, conversationID: UUID, call: String, temporary: Bool = false) -> ToolContext {
        ToolContext(runID: runID, toolCallID: call, allowedToolNames: [TaskCreateGoalTool.name, TaskReadGoalTool.name],
            cancellation: CancellationToken(), conversationID: conversationID,
            callOrigin: .init(kind: .mainRunDelegate, runID: runID, callID: call, toolName: TaskCreateGoalTool.name),
            temporaryReadOnly: temporary)
    }
    private func until(_ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func modelDiscoversCreatesAndFinishesCurrentRunWithDurableGoalReservation() async throws {
        let (db, conversations, runs, goals, conversationID) = try await stores()
        let registry = ToolRunnerRegistry()
        registerTaskChecklistTools(store: TaskChecklistStore(database: db), goalStore: goals, registry: registry)
        let provider = ProviderProfile(kind: .openAI, wireProtocol: .openAIChatCompletions, baseURL: URL(string: "https://goal-fixture.invalid/v1")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "goal-fixture", displayName: "Goal fixture",
            limits: .init(contextTokens: 16_384, maxOutputTokens: 2_048), capabilities: [.text, .tools])
        let state = GoalLifecycleProviderState()
        let adapter = GoalLifecycleProvider(state: state, createArguments: try arguments())
        let service = ConversationRunService(configuration: .init(conversationID: conversationID,
                provider: provider, model: model, maxToolSteps: 4, verifyFinalAnswer: false),
            adapter: adapter, policy: TaskFullAccessPolicy(), executor: CatalogToolExecutor(runners: registry),
            intelligenceStore: goals, conversationStore: conversations, runStore: runs)
        let userTask = "Only establish a durable goal for my current task; do not perform external actions."
        try await service.start(goal: userTask)
        let goal = try #require(try await goals.goals(conversationID: conversationID).first)
        let run = try #require(try await runs.run(id: service.runID))
        #expect(state.offeredGoalSchemas)
        #expect(run.goalID == goal.id && run.conversationMode == "chat")
        #expect(run.state == "completed")
        #expect(goal.objective == userTask && goal.steps.first?.detail == input.objective)
        #expect(goal.status == .verifying && goal.progress.cycleCount == 1 && goal.revision == 2)
        #expect(goal.evidence.isEmpty, "Creating a goal is preparation, not completion evidence")
        #expect(goal.budgets.maxParentIterationsPerCycle == 4, "A model goal cannot raise this run's cap")
        #expect(try await runs.runs(conversationID: conversationID).count == 1, "No tool-created replacement run")
    }

    @Test func registeredGoalToolRejectsOverwriteSpoofAndTemporaryWritesAtomically() async throws {
        let (db, _, runs, goals, conversationID) = try await stores()
        let registry = ToolRunnerRegistry()
        registerTaskChecklistTools(store: TaskChecklistStore(database: db), goalStore: goals, registry: registry)
        let executor = CatalogToolExecutor(runners: registry), runID = UUID(), now = Date()
        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            try await TaskGoalRuntimeBudgetScope.$budgets.withValue(GoalBudgets(maxParentIterationsPerCycle: 4)) {
                try await executor.execute(call, context: context)
            }
        }
        // The approved call may outrun RunService's phase projection.
        try await runs.saveRun(.init(id: runID, conversationID: conversationID, state: "streamingModel",
            goal: "User-authorized original task", startedAt: now, conversationMode: "chat"))
        let call = try ToolCall(id: "create-native-goal", toolName: TaskCreateGoalTool.name,
            argumentsJSON: arguments(), scope: .local)
        let temporary = try await execute(call, context: context(runID: runID, conversationID: conversationID,
            call: call.id, temporary: true))
        #expect(temporary.status == .failed && temporary.outputSummary.contains("unauthorized"))
        #expect(try await goals.goals(conversationID: conversationID).isEmpty)
        let first = try await execute(call, context: context(runID: runID, conversationID: conversationID, call: call.id))
        let replay = try await execute(call, context: context(runID: runID, conversationID: conversationID, call: call.id))
        #expect(first.status == .ok && replay.status == .ok)
        let initial = try #require(try await goals.goals(conversationID: conversationID).first)
        var changed = call; changed.argumentsJSON = try arguments("Different target under the same call ID")
        let reused = try await execute(changed, context: context(runID: runID, conversationID: conversationID, call: call.id))
        #expect(reused.status == .failed && reused.outputSummary.contains("identityReused"))
        let nextRunID = UUID()
        try await runs.saveRun(.init(id: nextRunID, conversationID: conversationID, state: "executingTool",
            goal: "Same task next activation", startedAt: now.addingTimeInterval(1), conversationMode: "chat"))
        let nextCall = try ToolCall(id: "do-not-replace", toolName: TaskCreateGoalTool.name,
            argumentsJSON: arguments(), scope: .local)
        let denied = try await execute(nextCall,
            context: context(runID: nextRunID, conversationID: conversationID, call: nextCall.id))
        #expect(denied.status == .failed && denied.outputSummary.contains("activeGoalExists"))
        #expect(try await goals.goals(conversationID: conversationID) == [initial])
        #expect(try await runs.run(id: nextRunID)?.goalID == nil)
        let forbidden = try ToolCall(id: "no-budget-escalation", toolName: TaskCreateGoalTool.name,
            argumentsJSON: Data(#"{"objective":"x","acceptanceCriteria":["x"],"steps":["x"],"budgets":{"maxCycles":9999}}"#.utf8),
            scope: .local)
        let budget = try await execute(forbidden,
            context: context(runID: nextRunID, conversationID: conversationID, call: forbidden.id))
        #expect(budget.status == .failed && budget.outputSummary.contains("invalidArguments"))
        #expect(try await goals.goals(conversationID: conversationID) == [initial])
    }

    @Test func pauseFencesLateCompletionAndExplicitBlockedResumeKeepsSameGoalAndEvidence() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        environment.markIsolatedLaunchReadyForTesting()
        let center = environment.conversationCenter
        let provider = ProviderProfile(kind: .openAI, wireProtocol: .openAIChatCompletions, baseURL: URL(string: "https://goal-fixture.invalid/v1")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "goal-control-fixture", displayName: "Goal control fixture",
            limits: .init(contextTokens: 16_384, maxOutputTokens: 2_048), capabilities: [.text, .tools])
        try await environment.configurationStore.saveProvider(provider)
        try await environment.configurationStore.saveModel(model)
        let conversationID = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: conversationID,
            title: "Owned goal controls", createdAt: now, updatedAt: now))
        let evidence = GoalEvidence(kind: .testResult, reference: "owned-fixture", summary: "Retained prior progress")
        let original = ConversationGoal(conversationID: conversationID, objective: "Continue this same authorized task",
            acceptanceCriteria: [.init(text: "Preserve prior evidence")], steps: [.init(title: "Continue", order: 0)],
            evidence: [evidence], status: .active, budgets: .init(maxCycles: 10, maxModelCalls: 20),
            progress: .init(cycleCount: 2, modelCallCount: 2, totalIterationCount: 4, startedAt: now))
        try await environment.intelligenceStore.saveGoal(original)
        let state = GoalLifecycleProviderState(), idle = GoalLifecycleProvider(state: state, createArguments: nil)
        center.providerAdapterTestOverride = { _, _ in idle }
        defer { center.providerAdapterTestOverride = nil }
        let preflight = GoalLaunchPreflightGate()
        center.launchTestHooks.beforeGoalPreflight = { await preflight.hold() }
        let lateStart = Task {
            try await center.startRun(goal: original.objective, in: conversationID,
                provider: provider, model: model, executionMode: .goal, isGoalContinuation: true,
                expectedGoal: (original.id, 1), startOrigin: .goalContinuation)
        }
        await preflight.waitForEntry()
        let preflightPaused = try await center.pauseGoal(conversationID: conversationID,
            expectedGoalID: original.id, expectedRevision: 1)
        center.launchTestHooks.beforeGoalPreflight = nil
        await preflight.release()
        do {
            _ = try await lateStart.value
            Issue.record("A continuation suspended before availability survived Pause")
        } catch is CancellationError { }
        #expect(try await environment.runStore.runs(conversationID: conversationID).isEmpty,
            "A stale preflight must create neither a new run nor a failed-run notification")
        #expect(state.requestCount == 0)
        let started = try await center.resumeGoal(conversationID: conversationID, expectedGoalID: original.id,
            expectedRevision: preflightPaused.revision ?? 1, provider: provider, model: model)
        let attached = await until {
            (try? await environment.runStore.run(id: started.runID)?.goalID) == original.id && state.requestCount >= 1
        }
        #expect(attached)
        let beforePause = try #require(try await environment.intelligenceStore.goal(id: original.id))
        let paused = try await center.pauseGoal(conversationID: conversationID, expectedGoalID: original.id,
            expectedRevision: beforePause.revision ?? 1)
        _ = await started.result.value
        #expect(paused.status == .paused && paused.evidence == original.evidence && paused.progress == original.progress)
        let lateAttempted = await until { state.lateCompletionAttempts >= 1 }
        #expect(lateAttempted)
        var stale = original; stale.status = .verifying
        let overwritten = try await environment.intelligenceStore.saveGoalIfRevisionMatches(stale, expectedRevision: 1)
        #expect(!overwritten, "A late completion must not overwrite the paused revision")
        var blocked = paused
        blocked.status = .blocked; blocked.progress.repeatedBlockerKey = "no-inspectable-evidence"; blocked.progress.repeatedBlockerCount = 3
        let blockedSaved = try await environment.intelligenceStore.saveGoalIfRevisionMatches(blocked, expectedRevision: paused.revision ?? 1)
        #expect(blockedSaved)
        let savedBlocked = try #require(try await environment.intelligenceStore.goal(id: original.id))
        #expect(center.goalBlockedReason(savedBlocked)?.isEmpty == false)
        let resumed = try await center.resumeGoal(conversationID: conversationID, expectedGoalID: original.id,
            expectedRevision: savedBlocked.revision ?? 1, provider: provider, model: model)
        let reattached = await until {
            (try? await environment.runStore.run(id: resumed.runID)?.goalID) == original.id && state.requestCount >= 2
        }
        #expect(reattached && resumed.runID != started.runID)
        let active = try #require(try await environment.intelligenceStore.goal(id: original.id))
        do {
            _ = try await center.resumeGoal(conversationID: conversationID, expectedGoalID: original.id,
                expectedRevision: active.revision ?? 1, provider: provider, model: model)
            Issue.record("Resume re-entered an already-owned goal run")
        } catch { }
        let final = try await center.pauseGoal(conversationID: conversationID, expectedGoalID: original.id,
            expectedRevision: active.revision ?? 1)
        _ = await resumed.result.value
        #expect(final.evidence == original.evidence && final.budgets == original.budgets)
        #expect(final.progress.cycleCount == 2 && final.progress.totalIterationCount == 4)
        #expect(try await environment.intelligenceStore.goals(conversationID: conversationID).count == 1)
        #expect(try await environment.runStore.runs(conversationID: conversationID).count == 2)
        try await center.deleteConversation(id: conversationID)
    }
}

private final class GoalLifecycleProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, late = 0
    private var offered = false
    var requestCount: Int { lock.withLock { count } }
    var lateCompletionAttempts: Int { lock.withLock { late } }
    var offeredGoalSchemas: Bool { lock.withLock { offered } }
    func next(_ names: Set<String>) -> Int {
        lock.withLock {
            let value = count; count += 1
            offered = offered || names.isSuperset(of: [TaskCreateGoalTool.name, TaskReadGoalTool.name])
            return value
        }
    }
    func lateCompletion() { lock.withLock { late += 1 } }
}

private actor GoalLaunchPreflightGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

/// Only provider transport is synthetic; dispatch, registry, SQL, RunService
/// and center control methods above are their production implementations.
private struct GoalLifecycleProvider: ProviderAdapter {
    let state: GoalLifecycleProviderState
    let createArguments: Data?
    var protocolKind: ModelProtocol { .openAIChatCompletions }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        let index = state.next(Set(request.toolSchemas.map(\.name)))
        return AsyncThrowingStream { continuation in
            if let createArguments {
                if index == 0 {
                    do {
                        continuation.yield(.toolRequest(try ToolCall(id: "model-native-goal", toolName: TaskCreateGoalTool.name,
                            argumentsJSON: createArguments, scope: .local)))
                    } catch { continuation.finish(throwing: error); return }
                } else {
                    continuation.yield(.textDelta(.init(text: "The task goal is recorded in Floe. No external action was performed.")))
                    continuation.yield(.completed(.init(stopReason: .endTurn)))
                }
                continuation.finish()
            } else {
                let work = Task {
                    continuation.yield(.textDelta(.init(text: "Working on the saved task goal.")))
                    do { try await Task.sleep(for: .seconds(60)) } catch { }
                    // Deliberately late even after cancellation: the runtime
                    // and durable revision must refuse resurrection.
                    state.lateCompletion()
                    continuation.yield(.completed(.init(stopReason: .endTurn)))
                    continuation.finish()
                }
                continuation.onTermination = { _ in work.cancel() }
            }
        }
    }
}
#endif
