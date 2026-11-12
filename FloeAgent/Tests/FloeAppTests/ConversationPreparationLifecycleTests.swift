#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeAgentRuntime
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
    private enum TestFailure: Error { case unexpectedProvider, injectedAfterLease, didNotSettle }

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
}
#endif
