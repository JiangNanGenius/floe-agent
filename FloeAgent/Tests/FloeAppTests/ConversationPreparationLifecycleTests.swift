#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeAgentRuntime
import FloeEnvironments
@testable import FloeApp

@Suite("FloeApp.ConversationPreparationLifecycle", .serialized)
@MainActor
struct ConversationPreparationLifecycleTests {
    private actor Gate {
        private var entered = false
        private var open = false
        private var parked: CheckedContinuation<Void, Never>?
        private var observers: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0
        func hold() async {
            calls += 1; entered = true
            let ready = observers; observers.removeAll(); ready.forEach { $0.resume() }
            if open { return }
            await withCheckedContinuation { parked = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { observers.append($0) }
        }
        func release() { open = true; parked?.resume(); parked = nil }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private struct HeldGenerator: PersonalizationGenerator {
        let gate: Gate
        func generate(_ request: PersonalizationGenerationRequest) async throws -> PersonalizationGenerationResult {
            // Deliberately ignores caller cancellation until actually released.
            await gate.hold()
            return PersonalizationGenerationResult(content: "# Reviewed profile\nStable synthetic preference", evidenceDigest: "qa-only")
        }
    }
    private struct NoNetworkAdapter: ProviderAdapter {
        let calls: Counter
        var protocolKind: ModelProtocol { .openAIChatCompletions }
        func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            calls.add()
            return AsyncThrowingStream { $0.finish(throwing: TestFailure.unexpectedProvider) }
        }
        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    }
    private enum TestFailure: Error, Equatable { case unexpectedProvider, injectedAfterLease, didNotSettle, observedCleanupBinding }

    private struct Fixture {
        let environment: AppEnvironment
        let center: ConversationCenter
        let provider: ProviderProfile
        let model: ModelProfile
        let providerCalls: Counter
    }
    private func fixture() async throws -> Fixture {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = ConversationCenter(environment: environment)
        let provider = ProviderProfile(kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.invalid/v1")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "preparation-fixture", displayName: "Fixture",
            limits: .init(contextTokens: 4096, maxOutputTokens: 1024), capabilities: [.text, .tools])
        let configuration = ModelConfigurationStore(database: environment.database)
        try await configuration.saveProvider(provider); try await configuration.saveModel(model)
        var preferences = try await configuration.preferences()
        preferences.defaultAgentModelID = model.id
        try await configuration.savePreferences(preferences)
        await center.reload()
        let calls = Counter()
        center.providerAdapterTestOverride = { _, _ in NoNetworkAdapter(calls: calls) }
        return Fixture(environment: environment, center: center, provider: provider, model: model, providerCalls: calls)
    }
    private func dueProfile(_ fixture: Fixture) async throws {
        try await fixture.environment.personalizationStore.saveCursor(PersonalizationUpdateCursor(
            kind: .userProfile, userMessagesSinceUpdate: 30))
        try await fixture.environment.personalizationService.setAutomaticUpdates(false, kind: .soul)
    }
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        // Qualification wait only, not a product timeout or failure policy.
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestFailure.didNotSettle
    }

    @Test("A suspended automatic generation cannot hold accepted input before its run owner")
    func suspendedMaintenanceDoesNotBlockSend() async throws {
        let f = try await fixture(); try await dueProfile(f)
        let generation = Gate(), launch = Gate()
        f.center.personalizationGeneratorTestOverride = HeldGenerator(gate: generation)
        f.center.requestPersonalizationMaintenance(workspaceID: nil)
        f.center.requestPersonalizationMaintenance(workspaceID: nil)
        await generation.waitUntilEntered()
        defer { Task { await generation.release(); await launch.release() } }
        let conversation = try await f.center.createConversation(title: "Owned preparation fixture")
        f.center.launchTestHooks.deferredTaskBody = { await launch.hold() }
        let started = try await f.center.startRun(goal: "One synthetic input", in: conversation.id,
            provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        #expect(f.center.hasLiveOwner(runID: started.runID))
        let cursor = try await f.environment.personalizationStore.cursor(kind: .userProfile, workspaceID: nil)
        #expect(cursor.userMessagesSinceUpdate == 31)
        #expect(await generation.calls == 1)
        await f.center.cancel(runID: started.runID)
        await launch.release()
        if case .success = await started.result.value { Issue.record("Stopped preparation must not start") }
        #expect(f.providerCalls.value() == 0)
        let messages = try await f.environment.conversationStore.messages(conversationID: conversation.id)
        #expect(messages.filter { $0.role == "user" }.map(\.content) == ["One synthetic input"])
        try await f.environment.personalizationService.setAutomaticUpdates(false, kind: .userProfile)
        await generation.release()
        try await settle { f.center.isPersonalizationMaintenanceIdle }
        let document = try await f.environment.personalizationStore.activeDocument(kind: .userProfile, workspaceID: nil)
        #expect(document == nil)
    }

    @Test("Stop during pre-deferred preparation fences late launch; the same run cannot duplicate input or cadence")
    func stopAndDuplicateDuringPreparation() async throws {
        let f = try await fixture(), gate = Gate()
        let conversation = try await f.center.createConversation(title: "Owned stopped input")
        let runID = UUID()
        f.center.launchTestHooks.afterRunPrepared = { _ in await gate.hold() }
        let send = Task { try await f.center.startRun(goal: "Keep this exact input", in: conversation.id,
            provider: f.provider, model: f.model, newRunID: runID, startOrigin: .explicitUserAction) }
        await gate.waitUntilEntered()
        defer { Task { await gate.release() } }
        #expect(f.center.hasLiveOwner(runID: runID))
        await #expect(throws: (any Error).self) {
            _ = try await f.center.startRun(goal: "Keep this exact input", in: conversation.id,
                provider: f.provider, model: f.model, newRunID: runID, startOrigin: .explicitUserAction)
        }
        await f.center.cancel(runID: runID)
        await f.center.cancel(runID: runID)
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await send.value }
        #expect(!f.center.hasLiveOwner(runID: runID))
        let run = try await f.environment.runStore.run(id: runID)
        #expect(run?.state == "cancelled")
        let messages = try await f.environment.conversationStore.messages(conversationID: conversation.id)
        #expect(messages.filter { $0.role == "user" }.map(\.content) == ["Keep this exact input"])
        let cursor = try await f.environment.personalizationStore.cursor(kind: .userProfile, workspaceID: nil)
        #expect(cursor.userMessagesSinceUpdate == 1)
        #expect(f.providerCalls.value() == 0)
    }

    @Test("Disabled automatic updates reject a delayed actual generation result")
    func disabledMaintenanceDropsLateResult() async throws {
        let f = try await fixture(); try await dueProfile(f)
        let gate = Gate(), owner = ConversationPersonalizationMaintenance()
        let fenced = ConversationMaintenanceGenerator(base: HeldGenerator(gate: gate), documents: f.environment.personalizationStore)
        let service = f.environment.personalizationService
        owner.enqueue(workspaceID: nil) { _ = try? await service.generateIfDue(kind: .userProfile, generator: fenced) }
        await gate.waitUntilEntered()
        defer { Task { await gate.release() } }
        #expect(!owner.enqueue(workspaceID: nil) { Issue.record("Duplicate generation") })
        try await service.setAutomaticUpdates(false, kind: .userProfile)
        await gate.release(); try await settle { owner.isIdle }
        let document = try await f.environment.personalizationStore.activeDocument(kind: .userProfile, workspaceID: nil)
        #expect(document == nil)
        #expect(await gate.calls == 1)
        let cursor = try await f.environment.personalizationStore.cursor(kind: .userProfile, workspaceID: nil)
        #expect(!cursor.automaticUpdatesEnabled)
        #expect(cursor.userMessagesSinceUpdate == 30)
    }

    @Test("Cancelled maintenance owns its slot until the real producer returns and discards its result")
    func cancelledMaintenanceDoesNotOverlapProducer() async throws {
        let f = try await fixture(); try await dueProfile(f)
        let gate = Gate(), next = Counter(), owner = ConversationPersonalizationMaintenance()
        let fenced = ConversationMaintenanceGenerator(base: HeldGenerator(gate: gate), documents: f.environment.personalizationStore)
        let service = f.environment.personalizationService
        owner.enqueue(workspaceID: nil) { _ = try? await service.generateIfDue(kind: .userProfile, generator: fenced) }
        await gate.waitUntilEntered()
        defer { Task { await gate.release() } }
        owner.cancel()
        #expect(!owner.isIdle)
        #expect(!owner.enqueue(workspaceID: nil) { Issue.record("Cancelled producer overlapped") })
        #expect(owner.enqueue(workspaceID: UUID()) { next.add() })
        #expect(next.value() == 0)
        await gate.release(); try await settle { owner.isIdle }
        #expect(next.value() == 1)
        let document = try await f.environment.personalizationStore.activeDocument(kind: .userProfile, workspaceID: nil)
        #expect(document == nil)
    }

    @Test("A construction error releases its acquired root once and the next preparation can acquire it")
    func unhandedRootReleasedAfterConstructionError() async throws {
        try await verifyUnhandedRootReleasedAndReacquirable(cancelled: false)
    }

    @Test("Cancellation releases its acquired root once and the next preparation can acquire it")
    func unhandedRootReleasedAfterCancellation() async throws {
        try await verifyUnhandedRootReleasedAndReacquirable(cancelled: true)
    }

    @Test("Stop of a registered preparing run commits its terminal row despite cancelling the launch task", .timeLimit(.minutes(1)))
    func cancelledRegisteredPreparationPersistsTerminalInItsOwnStore() async throws {
        let f = try await fixture(), gate = Gate()
        let conversation = try await f.center.createConversation(title: "Owned cancelled preparation")
        f.center.launchTestHooks.deferredTaskBody = { await gate.hold() }
        defer {
            f.center.launchTestHooks.deferredTaskBody = nil
            Task { await gate.release() }
        }
        let started = try await f.center.startRun(goal: "Preserve this accepted input", in: conversation.id,
            provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        await gate.waitUntilEntered()
        try #require(f.center.hasLiveOwner(runID: started.runID))
        let preparing = try #require(try await f.environment.runStore.run(id: started.runID))
        try #require(preparing.state == "preparing" && preparing.endedAt == nil)
        try await f.center.stopRunFromComposer(preparing)
        await gate.release()
        if case .success = await started.result.value { Issue.record("A stopped preparation reached execution") }
        let coldStore = SQLiteRunStore(database: f.environment.database)
        let stopped = try #require(try await coldStore.run(id: started.runID))
        #expect(stopped.state == "cancelled" && stopped.endedAt != nil)
        #expect(stopped.conversationID == conversation.id && stopped.goal == preparing.goal)
        // Cold reconciliation consumes this query. Both historical spellings
        // of a deliberate Stop are terminal, along with the other outcomes.
        let terminalStates = ["completed", "failed", "checkpointed", "interrupted", "cancelled", "canceled"]
        var terminalIDs = Set([stopped.id])
        for state in terminalStates {
            let record = RunRecord(id: UUID(), conversationID: conversation.id, state: state,
                goal: "Owned terminal fixture", startedAt: preparing.startedAt, endedAt: Date())
            terminalIDs.insert(record.id)
            try await coldStore.saveRun(record)
        }
        let active = RunRecord(id: UUID(), conversationID: conversation.id, state: "preparing",
            goal: "Separate active fixture", startedAt: Date())
        try await coldStore.saveRun(active)
        let unfinished = Set(try await coldStore.nonTerminalRuns().map(\.id))
        #expect(unfinished.isDisjoint(with: terminalIDs) && unfinished.contains(active.id))
        #expect(!f.center.hasLiveOwner(runID: started.runID) && f.providerCalls.value() == 0)
        #expect(try await f.environment.conversationStore.messages(conversationID: conversation.id)
            .filter { $0.role == "user" }.map(\.content) == ["Preserve this accepted input"])
    }

    @Test("A cancelled destroyed temporary preparation cannot write through to durable storage or its replacement", .timeLimit(.minutes(1)))
    func cancelledTemporaryPreparationKeepsItsFrozenTerminalAuthority() async throws {
        let f = try await fixture(), gate = Gate()
        let conversationID = try await f.center.startTemporarySession(initialDraft: "")
        f.center.launchTestHooks.deferredTaskBody = { await gate.hold() }
        defer {
            f.center.launchTestHooks.deferredTaskBody = nil
            Task { await gate.release() }
        }
        let started = try await f.center.startRun(goal: "Temporary owned input", in: conversationID,
            provider: f.provider, model: f.model, startOrigin: .explicitUserAction)
        await gate.waitUntilEntered()
        try #require(f.center.hasFrozenTemporaryRunAuthority(runID: started.runID, conversationID: conversationID))
        let ramStore = f.center.runStore(for: conversationID)
        var terminalIDs = Set<UUID>()
        for state in ["completed", "failed", "checkpointed", "interrupted", "cancelled", "canceled"] {
            let record = RunRecord(id: UUID(), conversationID: conversationID, state: state,
                goal: "Owned RAM terminal fixture", startedAt: Date(), endedAt: Date())
            terminalIDs.insert(record.id)
            try await ramStore.saveRun(record)
        }
        let unfinished = Set(try await ramStore.nonTerminalRuns().map(\.id))
        #expect(unfinished.isDisjoint(with: terminalIDs) && unfinished.contains(started.runID))
        #expect(await f.center.endTemporaryChat() == .newTask)
        let frozen = f.center.runStoreForTerminalRun(runID: started.runID, conversationID: conversationID)
        await #expect(throws: (any Error).self) {
            try await frozen.updateRunState(id: started.runID, state: "failed", endedAt: Date())
        }
        let replacementID = try await f.center.startTemporarySession(initialDraft: "Replacement remains empty")
        await gate.release()
        _ = await started.result.value
        #expect(!f.center.hasFrozenTemporaryRunAuthority(runID: started.runID, conversationID: conversationID))
        #expect(!f.center.hasLiveOwner(runID: started.runID) && f.providerCalls.value() == 0)
        #expect(try await f.environment.runStore.run(id: started.runID) == nil)
        #expect(try await f.environment.conversationStore.conversation(id: conversationID) == nil)
        #expect(try await f.environment.conversationStore.messages(conversationID: conversationID).isEmpty)
        #expect(f.center.temporarySession?.conversation.id == replacementID)
        #expect(try await f.center.runStore(for: replacementID).runs(conversationID: replacementID).isEmpty)
        #expect(await f.center.endTemporaryChat() == .newTask)
    }

    private func verifyUnhandedRootReleasedAndReacquirable(cancelled: Bool) async throws {
        let f = try await fixture(), gate = Gate(), releases = Counter(), acquisitions = Counter()
        let conversation = try await f.center.createConversation(title: "Owned lease fixture")
        f.center.launchTestHooks.didReleaseTaskRoot = { releases.add() }
        f.center.launchTestHooks.afterTaskRootAcquired = { root in
            #expect(root != nil); acquisitions.add(); await gate.hold()
            if !cancelled { throw TestFailure.injectedAfterLease }
        }
        let attempt = Task { try await f.center.runService(for: conversation.id, provider: f.provider,
            model: f.model, executionMode: .chat) }
        await gate.waitUntilEntered()
        defer { Task { await gate.release() } }
        #expect(releases.value() == 0)
        if cancelled { attempt.cancel() }
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await attempt.value }
        #expect(releases.value() == 1)
        f.center.launchTestHooks.afterTaskRootAcquired = { root in
            #expect(root != nil); acquisitions.add(); throw TestFailure.injectedAfterLease
        }
        await #expect(throws: TestFailure.self) {
            _ = try await f.center.runService(for: conversation.id, provider: f.provider,
                model: f.model, executionMode: .chat)
        }
        #expect(acquisitions.value() == 2)
        #expect(releases.value() == 2)
    }

    private struct CleanupFixture {
        let app: Fixture
        let conversation: ConversationRecord
        let prepared: PreparedRun
        let target: TaskExecutionTarget
    }

    private func cleanupFixture(bindShared: Bool) async throws -> CleanupFixture {
        let app = try await fixture()
        let conversation = try await app.center.createConversation(
            title: "Synthetic cleanup scope", linuxCacheCleanup: true)
        try await app.environment.environmentRegistry.prepare()
        let shared = try #require(await app.environment.environmentRegistry.record(
            id: EnvironmentRegistry.sharedContainerID))
        let target = TaskExecutionTarget(environmentID: shared.id, backend: .linuxVM,
            operatingSystem: shared.operatingSystem ?? "linux", architecture: shared.architecture ?? "arm64",
            runtimeGeneration: shared.runtimeGeneration)
        if bindShared {
            _ = try await TaskExecutionBindingStore(database: app.environment.database)
                .bindInitial(.init(conversationID: conversation.id, target: target))
        }
        let prepared = try await app.environment.runLaunchStore.prepare(RunLaunchRequest(
            conversationID: conversation.id, runID: UUID(), goal: "Inspect only synthetic cache state",
            initialState: "preparing", conversationMode: "chat", messageRole: "user"))
        return CleanupFixture(app: app, conversation: conversation, prepared: prepared, target: target)
    }

    private func observeCleanupBinding(_ fixture: CleanupFixture) {
        let owner = fixture.conversation.id
        fixture.app.center.launchTestHooks.afterExecutionBindingResolved = { binding in
            let binding = try #require(binding)
            #expect(binding.conversationID == owner)
            #expect(binding.target.environmentID == EnvironmentRegistry.sharedContainerID)
            #expect(binding.target.backend == .linuxVM)
            throw TestFailure.observedCleanupBinding
        }
    }

    private func constructCleanup(_ fixture: CleanupFixture, workspaceID: UUID? = nil) async throws {
        _ = try await fixture.app.center.runService(for: fixture.conversation.id,
            provider: fixture.app.provider, model: fixture.app.model, runID: fixture.prepared.run.id,
            executionMode: .chat, workspaceID: workspaceID)
    }

    @Test("Cleanup purpose committed before its pin recovers without selecting a project on first send or continuation")
    func cleanupPurposePrecedesDefaultBinding() async throws {
        // Real entry-point interruption state: atomic purpose/workspace save
        // finished, but the later asynchronous bindInitial never committed.
        let f = try await cleanupFixture(bindShared: false)
        let store = TaskExecutionBindingStore(database: f.app.environment.database)
        #expect(try await store.binding(conversationID: f.conversation.id) == nil)
        let environmentsBefore = await f.app.environment.environmentRegistry.all().map(\.id).sorted()
        observeCleanupBinding(f)
        await #expect(throws: TestFailure.observedCleanupBinding) { try await constructCleanup(f) }
        let first = try #require(try await store.binding(conversationID: f.conversation.id))
        #expect(first.target.environmentID == EnvironmentRegistry.sharedContainerID)
        #expect(await f.app.environment.environmentRegistry.all().map(\.id).sorted() == environmentsBefore)
        #expect(try await f.app.environment.runStore.run(id: f.prepared.run.id)?.executionBinding == first)
        // Same durable run, no UI WorkspaceCenter publication or environment
        // override: continuation must retain the exact pin and user message.
        await #expect(throws: TestFailure.observedCleanupBinding) { try await constructCleanup(f) }
        #expect(try await store.binding(conversationID: f.conversation.id) == first)
        #expect(try await f.app.environment.runStore.runs(conversationID: f.conversation.id).count == 1)
        let messages = try await f.app.environment.conversationStore.messages(conversationID: f.conversation.id)
        #expect(messages.filter { $0.role == "user" }.count == 1)
        #expect(f.app.providerCalls.value() == 0)
    }

    @Test("A cleanup root filesystem failure keeps its underlying error and original scope, then the same run can recover")
    func cleanupRootFailureDoesNotBecomeScopeMismatch() async throws {
        let f = try await cleanupFixture(bindShared: true)
        let store = TaskExecutionBindingStore(database: f.app.environment.database)
        let pin = try #require(try await store.binding(conversationID: f.conversation.id))
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let relative = try #require(f.prepared.workspace.internalRelativePath)
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
        let obstruction = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent, isDirectory: false)
        try #require(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = Data("task-owned root obstruction fixture".utf8)
        try marker.write(to: obstruction)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await constructCleanup(f)
            Issue.record("A regular file cannot be leased as a working folder")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == "Floe.LinuxCacheCleanup.Workspace")
            #expect(failure.userInfo[NSUnderlyingErrorKey] != nil)
            #expect(!failure.localizedDescription.contains("stored Linux scope"))
        }
        #expect(try Data(contentsOf: obstruction) == marker) // no cleanup or repair deletion
        #expect(try await store.binding(conversationID: f.conversation.id) == pin)
        #expect(try await f.app.environment.runStore.run(id: f.prepared.run.id)?.executionBinding == nil)
        try FileManager.default.removeItem(at: obstruction) // only this test's marker
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        observeCleanupBinding(f)
        await #expect(throws: TestFailure.observedCleanupBinding) { try await constructCleanup(f) }
        #expect(try await f.app.environment.runStore.run(id: f.prepared.run.id)?.executionBinding == pin)
        #expect(f.app.providerCalls.value() == 0)
    }

    @Test("Cleanup workspace-read errors remain actionable and do not discard its shared binding")
    func cleanupWorkspaceReadFailureDoesNotBecomeScopeMismatch() async throws {
        let f = try await cleanupFixture(bindShared: true)
        let workspace = f.prepared.workspace
        try await f.app.environment.database.writer { db in
            try db.execute(sql: "UPDATE workspaces SET inspector_state_json = 'not-json' WHERE id = ?",
                           arguments: [workspace.id.uuidString])
        }
        do {
            try await constructCleanup(f)
            Issue.record("A workspace read error must not be swallowed")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == "Floe.LinuxCacheCleanup.Workspace")
            #expect(failure.userInfo[NSUnderlyingErrorKey] != nil)
            #expect(!failure.localizedDescription.contains("stored Linux scope"))
        }
        try await SQLiteWorkspaceStore(database: f.app.environment.database).saveWorkspace(workspace)
        observeCleanupBinding(f)
        await #expect(throws: TestFailure.observedCleanupBinding) { try await constructCleanup(f) }
        #expect(f.app.providerCalls.value() == 0)
    }

    @Test("A cleanup task's conflicting saved environment is rejected without silently repairing or widening it")
    func cleanupConflictingPinStaysRejected() async throws {
        let f = try await cleanupFixture(bindShared: false)
        let store = TaskExecutionBindingStore(database: f.app.environment.database)
        let conflicting = try await store.bindInitial(.init(conversationID: f.conversation.id,
            target: .init(environmentID: "unrelated-project-" + UUID().uuidString, backend: .linuxVM,
                          operatingSystem: "linux", architecture: "arm64")))
        observeCleanupBinding(f)
        do {
            try await constructCleanup(f)
            Issue.record("The cleanup purpose cannot silently replace an existing task pin")
        } catch TestFailure.observedCleanupBinding {
            Issue.record("A conflicting pin reached the accepted binding boundary")
        } catch { }
        #expect(try await store.binding(conversationID: f.conversation.id) == conflicting)
        #expect(try await f.app.environment.runStore.run(id: f.prepared.run.id)?.executionBinding == nil)
        #expect(f.app.providerCalls.value() == 0)
    }

    @Test("A stale UI workspace hint cannot redirect a cleanup task into another task's working folder")
    func cleanupStaleWorkspaceHintStaysRejected() async throws {
        let f = try await cleanupFixture(bindShared: true)
        let other = try await f.app.center.createConversation(title: "Unrelated synthetic task")
        let otherWorkspace = try #require(try await SQLiteWorkspaceStore(database: f.app.environment.database)
            .workspaceID(conversationID: other.id))
        observeCleanupBinding(f)
        do {
            try await constructCleanup(f, workspaceID: otherWorkspace)
            Issue.record("A cleanup task must retain its durable workspace owner")
        } catch TestFailure.observedCleanupBinding {
            Issue.record("A stale UI owner reached execution binding")
        } catch {
            #expect((error as NSError).domain == "Floe.LinuxCacheCleanup.Workspace")
        }
        let pin = try await TaskExecutionBindingStore(database: f.app.environment.database)
            .binding(conversationID: f.conversation.id)
        #expect(pin?.target.environmentID == EnvironmentRegistry.sharedContainerID)
        #expect(try await f.app.environment.runStore.run(id: f.prepared.run.id)?.executionBinding == nil)
        #expect(f.app.providerCalls.value() == 0)
    }
}
#endif
