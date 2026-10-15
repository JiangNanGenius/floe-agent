// FloeAppTests — Automatic reasoning-effort launch lifecycle through the real
// ConversationCenter with an in-memory database.
//
// Deterministic, offline: a scripted provider adapter (installed through the
// center's test-only override seam) serves both the auxiliary classifier
// request and the main run, so nothing leaves this process. These tests prove
// the launch-boundary contract G2 must keep:
//   * Stop / Delete while the auxiliary decision is pending cancels the
//     helper promptly, fails the launch closed, and never starts the main
//     provider (no decision record is persisted from the cancelled attempt).
//   * A same-round Continue (retry) reuses the frozen choice and sends no
//     second auxiliary request, while the real main request still carries the
//     frozen effort on the wire model.
#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
@testable import FloeApp

@Suite("FloeApp.AutomaticReasoningEffortLifecycle")
@MainActor
struct AutomaticReasoningEffortLifecycleTests {
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
        // The preview environment is un-migrated (bootstrap runs the real
        // migration); the schema must exist before any store write.
        try await fixture.environment.database.migrate()
        return fixture
    }

    /// One main model that supports a variable effort wire field plus a
    /// DISTINCT auxiliary route, both on the same hermetically overridden
    /// provider. Nothing here reaches the network.
    private func configureProviderModels(
        _ fixture: Fixture
    ) async throws -> (provider: ProviderProfile, model: ModelProfile) {
        let configuration = ModelConfigurationStore(database: fixture.environment.database)
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.com/v1")!
        )
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "gpt-5.2",
            displayName: "Main",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
        let auxiliary = ModelProfile(
            providerID: provider.id,
            remoteModelID: "gpt-5.1-aux",
            displayName: "Auxiliary",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 1_024),
            capabilities: [.text]
        )
        try await configuration.saveProvider(provider)
        try await configuration.saveModel(model)
        try await configuration.saveModel(auxiliary)
        var preferences = try await configuration.preferences()
        preferences.defaultAgentModelID = model.id
        preferences.generalAuxiliaryLLMModelID = auxiliary.id
        try await configuration.savePreferences(preferences)
        await fixture.center.reload()
        return (provider, model)
    }

    private func pollUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// Decision records live in the store that owns the run: the durable run
    /// store for an ordinary conversation, the RAM session store for a
    /// temporary one. The caller passes the owning store explicitly.
    private func decisionEvents(
        _ store: any RunStore,
        runID: UUID
    ) async -> [RunEventRecord] {
        let events = (try? await store.events(
            runID: runID, afterSequence: 0, limit: 256)) ?? []
        return events.filter { $0.payloadJSON.contains("automaticReasoningEffort") }
    }

    @Test("Stop while the auxiliary decision is pending fails the launch closed with no main request")
    func stopCancelsPendingDecisionAndNeverStartsMain() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await configureProviderModels(fixture)
        let state = ScriptedEffortState()
        let scripted = ScriptedEffortProvider(helperAnswer: nil, state: state)
        fixture.center.providerAdapterTestOverride = { _, _ in scripted }
        defer { fixture.center.providerAdapterTestOverride = nil }

        let conversation = try await fixture.center.createConversation(title: nil)
        // A new ordinary chat owns an app-owned private-task workspace, exactly
        // like the real creation flow; RunLaunchStore is fail-closed without
        // that ownership row (the preview environment has none by default).
        _ = try await WorkspaceCenter.ensureReviewConversationWorkspace(
            conversationID: conversation.id,
            workspaceID: nil,
            title: "运行",
            store: SQLiteWorkspaceStore(database: fixture.environment.database)
        )
        let started = try await fixture.center.startRun(
            goal: "hello",
            in: conversation.id,
            provider: provider,
            model: model,
            startOrigin: .explicitUserAction
        )
        // The launch must actually reach the auxiliary request before the
        // Stop, otherwise this proves nothing about a pending classifier.
        let helperSeen = await pollUntil { state.helperRequestCount >= 1 }
        #expect(helperSeen)
        #expect(state.mainRequestCount == 0)

        await fixture.center.cancel(runID: started.runID)
        let outcome = await started.result.value
        if case .success = outcome {
            Issue.record("A stopped launch must not complete successfully")
        }
        #expect(state.mainRequestCount == 0)
        // The pending classifier was cancelled, not waited out to its
        // deadline: a deadline fallback would have persisted a decision event.
        #expect(await decisionEvents(fixture.environment.runStore, runID: started.runID).isEmpty)
        let ownerReleased = await pollUntil(timeout: 2) {
            !fixture.center.hasLiveOwner(runID: started.runID)
        }
        #expect(ownerReleased)
    }

    @Test("Deleting the conversation while the auxiliary decision is pending starts no main request")
    func deletionCancelsPendingDecisionAndNeverStartsMain() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await configureProviderModels(fixture)
        let state = ScriptedEffortState()
        let scripted = ScriptedEffortProvider(helperAnswer: nil, state: state)
        fixture.center.providerAdapterTestOverride = { _, _ in scripted }
        defer { fixture.center.providerAdapterTestOverride = nil }

        let conversation = try await fixture.center.createConversation(title: nil)
        _ = try await WorkspaceCenter.ensureReviewConversationWorkspace(
            conversationID: conversation.id,
            workspaceID: nil,
            title: "运行",
            store: SQLiteWorkspaceStore(database: fixture.environment.database)
        )
        let started = try await fixture.center.startRun(
            goal: "hello",
            in: conversation.id,
            provider: provider,
            model: model,
            startOrigin: .explicitUserAction
        )
        let helperSeen = await pollUntil { state.helperRequestCount >= 1 }
        #expect(helperSeen)

        try await fixture.center.deleteConversation(id: conversation.id)
        #expect(state.mainRequestCount == 0)
        // The conversation and its run rows are gone: no late classifier
        // result can resurrect a decision surface for the deleted run.
        #expect(try await fixture.environment.conversationStore
            .conversation(id: conversation.id) == nil)
        #expect(try await fixture.environment.runStore.run(id: started.runID) == nil)
        let outcome = await started.result.value
        if case .success = outcome {
            Issue.record("A deleted launch must not complete successfully")
        }
    }

    @Test("A same-round Continue reuses the frozen decision and sends no second auxiliary request")
    func sameRoundContinueReusesFrozenDecision() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await configureProviderModels(fixture)
        let state = ScriptedEffortState()
        let scripted = ScriptedEffortProvider(
            helperAnswer: #"{"effort":"high"}"#, state: state)
        fixture.center.providerAdapterTestOverride = { _, _ in scripted }
        defer { fixture.center.providerAdapterTestOverride = nil }

        // A temporary session keeps the completed run's post-finish surfaces
        // (personalization generation, memory/skill dream) out of the
        // provider counts: those services never run for a temporary
        // conversation, so every adapter call here belongs to this contract.
        let conversationID = try await fixture.center.startTemporarySession(initialDraft: "")
        let sessionRunStore = try #require(fixture.center.temporarySession?.runStore)
        let started = try await fixture.center.startRun(
            goal: "hello",
            in: conversationID,
            provider: provider,
            model: model,
            startOrigin: .explicitUserAction
        )
        let completed = await started.result.value
        if case .failure(let error) = completed {
            Issue.record("first round failed: \(error)")
        }
        // Exactly one auxiliary decision and exactly one main request, and
        // the main request carried the frozen level on the real wire model.
        #expect(state.helperRequestCount == 1)
        #expect(state.mainRequestCount == 1)
        #expect(state.mainEfforts == [.high])
        #expect(await decisionEvents(sessionRunStore, runID: started.runID).count == 1)

        // Continue = resume the SAME round: the frozen abstract choice is
        // reused (re-clamped for the target in use) with no new helper call.
        let resumed = try await fixture.center.retry(
            runID: started.runID,
            startOrigin: .explicitUserAction
        )
        let resumedOutcome = await resumed.result.value
        if case .failure(let error) = resumedOutcome {
            Issue.record("same-round resume failed: \(error)")
        }
        #expect(state.helperRequestCount == 1)
        #expect(state.mainRequestCount == 2)
        #expect(state.mainEfforts == [.high, .high])
        #expect(await decisionEvents(sessionRunStore, runID: started.runID).count == 1)
        _ = await fixture.center.endTemporaryChat()
    }

    @Test("An active-round steer reuses the frozen decision once and is delivered")
    func activeRoundSteerReusesFrozenDecision() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await configureProviderModels(fixture)
        let state = ScriptedEffortState()
        let gate = ScriptedGate()
        let scripted = ScriptedEffortProvider(
            helperAnswer: #"{"effort":"high"}"#, state: state, mainGate: gate)
        fixture.center.providerAdapterTestOverride = { _, _ in scripted }
        defer { fixture.center.providerAdapterTestOverride = nil }

        let conversationID = try await fixture.center.startTemporarySession(initialDraft: "")
        let sessionRunStore = try #require(fixture.center.temporarySession?.runStore)
        let started = try await fixture.center.startRun(
            goal: "hello",
            in: conversationID,
            provider: provider,
            model: model,
            startOrigin: .explicitUserAction
        )
        let helperSeen = await pollUntil {
            state.helperRequestCount == 1 && state.mainRequestCount == 1
        }
        #expect(helperSeen)
        #expect(state.mainEfforts == [.high])

        // The real user-visible steer path: compose guidance while the round
        // is live. This goes through ConversationCenter.submitRunningInput
        // (mode .steer) exactly like the composer does, not through the bare
        // runtime resolver.
        try await fixture.center.submitRunningInput(
            content: "FLOE-STEER-ONE",
            in: conversationID,
            expectedRunID: started.runID,
            mode: .steer,
            selectedModelID: model.id,
            workspaceID: nil,
            executionMode: .chat,
            attachments: []
        )
        let pending = try await fixture.center.runningInputStore(for: conversationID)
            .pending(conversationID: conversationID)
        let steer = try #require(pending.first { $0.content == "FLOE-STEER-ONE" })
        #expect(steer.mode == .steer)
        #expect(steer.status == .steerPending)
        // Composing and delivering guidance inside the live round must not ask
        // the auxiliary model again: the decision is frozen for the round.
        #expect(state.helperRequestCount == 1)

        gate.open()
        let outcome = await started.result.value
        if case .failure(let error) = outcome {
            Issue.record("the steered round failed: \(error)")
        }
        let consumed = try await fixture.center.runningInputStore(for: conversationID)
            .input(id: steer.id)
        #expect(consumed?.status == .consumed)
        #expect(state.helperRequestCount == 1)
        #expect(state.mainRequestCount >= 2)
        #expect(state.mainEfforts.allSatisfy { $0 == .high })
        #expect(await decisionEvents(sessionRunStore, runID: started.runID).count == 1)
        let messages = try await fixture.center.conversationStore(for: conversationID)
            .messages(conversationID: conversationID)
        #expect(messages.contains { $0.content == "FLOE-STEER-ONE" })
        _ = await fixture.center.endTemporaryChat()
    }
}

// MARK: - Scripted provider

/// One offline adapter serving both hops. The auxiliary classifier request is
/// identified by its dedicated route model; everything else is the main run.
/// `helperAnswer == nil` parks the classifier request until the coordinator
/// cancels it (Stop/Delete), then finishes without output.
private struct ScriptedEffortProvider: ProviderAdapter {
    let helperAnswer: String?
    let state: ScriptedEffortState
    /// When set, the main stream holds its turn open until the test opens the
    /// gate, so the test can compose a real steer against a live round.
    var mainGate: ScriptedGate?

    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        if request.model.remoteModelID.hasSuffix("-aux") {
            state.noteHelperRequest()
            guard let helperAnswer else {
                return AsyncThrowingStream { continuation in
                    let work = Task {
                        do {
                            try await Task.sleep(for: .seconds(30))
                            continuation.yield(.textDelta(.init(text: #"{"effort":"low"}"#)))
                        } catch {
                            // Cancelled: finish without a result.
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in work.cancel() }
                }
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.textDelta(.init(text: helperAnswer)))
                continuation.finish()
            }
        }
        state.noteMainRequest(effort: request.model.effectiveReasoningEffort)
        if let mainGate {
            return AsyncThrowingStream { continuation in
                let work = Task {
                    continuation.yield(.textDelta(.init(text: "FLOE_EFFORT_STEP")))
                    for await _ in mainGate.stream { break }
                    continuation.yield(.completed(.init(stopReason: .endTurn)))
                    continuation.finish()
                }
                continuation.onTermination = { _ in work.cancel() }
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(.init(text: "FLOE_EFFORT_OK")))
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

/// One-shot async gate: lets one test keep the scripted main stream open
/// until it has submitted a steer through the real center API.
private final class ScriptedGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?
    let stream: AsyncStream<Void>

    init() {
        var captured: AsyncStream<Void>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        continuation = captured
    }

    func open() {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        value?.finish()
    }
}

/// Per-test counters for the scripted adapter.
private final class ScriptedEffortState: @unchecked Sendable {
    private let lock = NSLock()
    private var helpers = 0
    private var mains = 0
    private var efforts: [ModelReasoningEffort?] = []

    func noteHelperRequest() {
        lock.lock()
        helpers += 1
        lock.unlock()
    }

    func noteMainRequest(effort: ModelReasoningEffort?) {
        lock.lock()
        mains += 1
        efforts.append(effort)
        lock.unlock()
    }

    var helperRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return helpers
    }

    var mainRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mains
    }

    var mainEfforts: [ModelReasoningEffort?] {
        lock.lock()
        defer { lock.unlock() }
        return efforts
    }
}
#endif
