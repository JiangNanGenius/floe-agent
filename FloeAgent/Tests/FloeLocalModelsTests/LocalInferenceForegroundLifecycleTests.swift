// FloeLocalModelsTests — Build 232 foreground lifecycle and no-output repair.
//
// Device evidence (Build 231 diagnostic export, current session near upload):
// a foreground-recovery resume reached the local adapter while the scene was
// still transitioning. The old admission refused immediately with a bare
// `CancellationError`; the harness treats that as "cancel() owns the terminal
// transition" and ignores it, so the run ended in `streamingModel` with
// `runResumeFinished terminal=false` and the user saw no reply.
//
// These tests pin the repair with deterministic engine doubles:
//
//   * a resume that arrives before the scene is active waits for the bounded
//     foreground grace and then generates normally;
//   * a run that stays backgrounded refuses with one retryable
//     `.rateLimited` deferral event (never a silent non-terminal end) and
//     succeeds on the next attempt once active;
//   * a lifecycle cancellation mid-generation defers explicitly instead of
//     vanishing, while a caller cancellation still stays a cancellation;
//   * two tool turns keep their receipt across a foreground deferral and the
//     refused turn performs no duplicate inference;
//   * through the real `ConversationRunService`, a backgrounded local run
//     ends as a terminal recoverable failure instead of an endless stream,
//     and a run whose app returns during the retry window completes.

import Foundation
import Synchronization
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

// MARK: - Scripted foreground probe

@available(macOS 15.4, iOS 26.0, *)
private final class ForegroundGate: @unchecked Sendable {
    private let active = Mutex(false)

    init(active: Bool) {
        self.active.withLock { $0 = active }
    }

    var isActive: Bool { active.withLock { $0 } }

    func set(_ value: Bool) {
        active.withLock { $0 = value }
    }
}

/// Reports active for the prepare-stage probe and inactive from the next read
/// on, so a test can deterministically land the caller inside the generation
/// registration wait without racing the scripted engine.
@available(macOS 15.4, iOS 26.0, *)
private final class ForegroundGateFlipAfterFirstRead: @unchecked Sendable {
    private let reads = Mutex(0)

    var readCount: Int { reads.withLock { $0 } }

    var isActive: Bool {
        reads.withLock { count in
            count += 1
            return count == 1
        }
    }
}

// MARK: - Harness

@available(macOS 15.4, iOS 26.0, *)
private struct ForegroundLifecycleHarness {
    let root: URL
    let engine: ScriptedStreamingEngine
    let canceller: LocalInferenceBackgroundCanceller
    let runtime: LocalModelRuntime
    let store: LocalModelStore

    init(
        engine: ScriptedStreamingEngine,
        canceller: LocalInferenceBackgroundCanceller = LocalInferenceBackgroundCanceller(),
        admission: LocalForegroundAdmissionPolicy = .immediate
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-b232-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.engine = engine
        self.canceller = canceller
        let modelRoot = root
        self.runtime = LocalModelRuntime(
            store: LocalModelStore(root: modelRoot),
            makeEngine: { _, _, _, _ in engine },
            measureAvailableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            modelSnapshot: { modelID in
                (directory: modelRoot.appendingPathComponent(modelID, isDirectory: true),
                 weightBytes: 1_000_000)
            },
            preflightSettleSamples: 0,
            preflightSettleInterval: .milliseconds(1),
            idleUnloadInterval: .seconds(120),
            arbiter: HeavyRuntimeArbiter(),
            backgroundCanceller: canceller,
            foregroundAdmission: admission
        )
        self.store = LocalModelStore(root: modelRoot)
    }

    func adapter(ownerRunID: UUID? = nil) -> LocalProviderAdapter {
        LocalProviderAdapter(
            runtime: runtime,
            store: store,
            ownerRunID: ownerRunID,
            watchdogPolicy: .disabled
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@available(macOS 15.4, iOS 26.0, *)
private func lifecycleModel(
    remoteModelID: String = "qwen3.8-4b-heretic-mlx4"
) -> ModelProfile {
    ModelProfile(
        providerID: LocalProviderAdapter.providerProfile.id,
        remoteModelID: remoteModelID,
        displayName: "Synthetic local",
        limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
        capabilities: [.text, .tools]
    )
}

private let lifecycleReadFileSchema = ToolSchemaDescriptor(
    name: "workspace.readFile",
    description: "Read a workspace file",
    parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#
)

@available(macOS 15.4, iOS 26.0, *)
private func lifecycleRequest(
    _ content: String,
    toolSchemas: [ToolSchemaDescriptor] = []
) -> ProviderStreamRequest {
    ProviderStreamRequest(
        provider: LocalProviderAdapter.providerProfile,
        model: lifecycleModel(),
        messages: [(role: "user", content: content)],
        toolSchemas: toolSchemas,
        allToolNames: toolSchemas.map(\.name)
    )
}

@available(macOS 15.4, iOS 26.0, *)
private func awaitTrue(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private extension Array where Element == AgentEvent {
    var textDeltas: [String] {
        compactMap { event -> String? in
            if case .textDelta(let delta) = event { return delta.text }
            return nil
        }
    }

    var stopReasons: [AgentEvent.StopReason] {
        compactMap { event -> AgentEvent.StopReason? in
            if case .completed(let completion) = event { return completion.stopReason }
            return nil
        }
    }

    var errorKinds: [AgentEvent.NormalizedError.Kind] {
        compactMap { event -> AgentEvent.NormalizedError.Kind? in
            if case .error(let error) = event { return error.kind }
            return nil
        }
    }

    var errorMessages: [String] {
        compactMap { event -> String? in
            if case .error(let error) = event { return error.providerMessage }
            return nil
        }
    }

    var toolRequests: [ToolCall] {
        compactMap { event -> ToolCall? in
            if case .toolRequest(let call) = event { return call }
            return nil
        }
    }
}

@available(macOS 15.4, iOS 26.0, *)
private func collect(
    _ adapter: LocalProviderAdapter,
    _ request: ProviderStreamRequest
) async -> (events: [AgentEvent], error: Error?) {
    var events: [AgentEvent] = []
    do {
        for try await event in adapter.stream(request: request, credentials: ProviderCredentials()) {
            events.append(event)
        }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

// MARK: - Adapter-level lifecycle regression tests

@Suite("Local inference foreground lifecycle")
struct LocalInferenceForegroundLifecycleTests {
    @Test("A resume before the scene is active waits for the bounded grace, then generates")
    @available(macOS 15.4, iOS 26.0, *)
    func resumeBeforeSceneActiveWaitsThenGenerates() async throws {
        let gate = ForegroundGate(active: false)
        let canceller = LocalInferenceBackgroundCanceller()
        canceller.installForegroundProbeForTesting { gate.isActive }
        let engine = ScriptedStreamingEngine(scripts: [[.output("前台恢复完成")]])
        let harness = try ForegroundLifecycleHarness(
            engine: engine,
            canceller: canceller,
            admission: LocalForegroundAdmissionPolicy(
                graceSeconds: 2,
                pollIntervalSeconds: 0.02
            )
        )
        defer { harness.cleanUp() }
        // The scene reports active shortly after the resume lands, exactly the
        // ordering the device log showed (refusal 93 ms after inactive, active
        // again 5.4 s later).
        let flipper = Task.detached {
            try? await Task.sleep(for: .milliseconds(120))
            gate.set(true)
        }
        defer { flipper.cancel() }
        let (events, error) = await collect(harness.adapter(), lifecycleRequest("继续刚才的任务"))
        #expect(error == nil)
        #expect(events.textDeltas == ["前台恢复完成"])
        #expect(events.stopReasons == [.endTurn])
        #expect(engine.generationCount == 1)
    }

    @Test("A backgrounded admission refuses retryably with no GPU work, then succeeds when active")
    @available(macOS 15.4, iOS 26.0, *)
    func backgroundedAdmissionRefusesRetryably() async throws {
        let gate = ForegroundGate(active: false)
        let canceller = LocalInferenceBackgroundCanceller()
        canceller.installForegroundProbeForTesting { gate.isActive }
        let engine = ScriptedStreamingEngine(scripts: [[.output("恢复后的回答")]])
        let harness = try ForegroundLifecycleHarness(
            engine: engine,
            canceller: canceller,
            admission: .immediate
        )
        defer { harness.cleanUp() }
        let adapter = harness.adapter()

        let (refusedEvents, refusedError) = await collect(adapter, lifecycleRequest("后台开始的任务"))
        #expect(refusedError == nil)
        #expect(refusedEvents.errorKinds == [.rateLimited])
        #expect(refusedEvents.textDeltas.isEmpty)
        // The refusal happens before any engine work: no prefill, no GPU
        // submission, no duplicate inference while iOS would reject it.
        #expect(engine.generationCount == 0)

        // Returning to the foreground is the retry; the same adapter must
        // generate normally. The harness (AgentRuntime) owns the retry loop
        // in production; at this layer the contract is: one deferral event,
        // then a normal turn when eligible.
        gate.set(true)
        let (recoveredEvents, recoveredError) = await collect(adapter, lifecycleRequest("后台开始的任务"))
        #expect(recoveredError == nil)
        #expect(recoveredEvents.textDeltas == ["恢复后的回答"])
        #expect(recoveredEvents.stopReasons == [.endTurn])
        #expect(engine.generationCount == 1)
    }

    @Test("A lifecycle cancellation mid-generation defers instead of vanishing")
    @available(macOS 15.4, iOS 26.0, *)
    func lifecycleCancellationDefersExplicitly() async throws {
        let gate = ForegroundGate(active: true)
        let canceller = LocalInferenceBackgroundCanceller()
        canceller.installForegroundProbeForTesting { gate.isActive }
        let engine = ScriptedStreamingEngine(scripts: [[
            .progress(LocalInferenceProgress(stage: .preparing)),
            .waitForCancellation
        ]])
        let harness = try ForegroundLifecycleHarness(engine: engine, canceller: canceller)
        defer { harness.cleanUp() }
        let adapter = harness.adapter()
        let collector = Task { await collect(adapter, lifecycleRequest("运行中切到后台")) }
        #expect(await awaitTrue { engine.generationCount == 1 })
        // The app leaves the foreground while prefill/decode is in flight.
        canceller.applyLifecycleTransition(isBackground: true)
        let (events, error) = await collector.value
        #expect(error == nil)
        #expect(events.errorKinds == [.rateLimited])
        #expect(events.errorMessages.first?.contains("前台") == true)
        #expect(events.errorMessages.first?.contains("generation") == true)
        #expect(events.textDeltas.isEmpty)
        // The engine observed the cancellation before any teardown released
        // the GPU stream.
        #expect(engine.cancellationObserved)
    }

    @Test("A caller cancellation stays a cancellation and never becomes a deferral")
    @available(macOS 15.4, iOS 26.0, *)
    func callerCancellationStaysACancellation() async throws {
        let gate = ForegroundGate(active: true)
        let canceller = LocalInferenceBackgroundCanceller()
        canceller.installForegroundProbeForTesting { gate.isActive }
        let engine = ScriptedStreamingEngine(scripts: [[
            .progress(LocalInferenceProgress(stage: .preparing)),
            .waitForCancellation
        ]])
        let harness = try ForegroundLifecycleHarness(engine: engine, canceller: canceller)
        defer { harness.cleanUp() }
        let adapter = harness.adapter()
        let collector = Task { await collect(adapter, lifecycleRequest("用户停止")) }
        #expect(await awaitTrue { engine.generationCount == 1 })
        collector.cancel()
        let (events, error) = await collector.value
        #expect(error == nil || error is CancellationError)
        #expect(!(error is LocalInferenceDeferredError))
        #expect(events.errorKinds.isEmpty)
        #expect(engine.cancellationObserved)
    }

    @Test("A lifecycle deferral keeps the run's resident mapping; no early engine release")
    @available(macOS 15.4, iOS 26.0, *)
    func lifecycleDeferralKeepsResidentEngine() async throws {
        let runID = UUID()
        let gate = ForegroundGate(active: true)
        let canceller = LocalInferenceBackgroundCanceller()
        canceller.installForegroundProbeForTesting { gate.isActive }
        let engine = ScriptedStreamingEngine(scripts: [[
            .progress(LocalInferenceProgress(stage: .preparing)),
            .waitForCancellation
        ]])
        let harness = try ForegroundLifecycleHarness(engine: engine, canceller: canceller)
        defer { harness.cleanUp() }
        // The durable run claims the mapping before the turn, exactly as the
        // conversation service does at launch/recovery.
        await harness.runtime.retainForTask(taskID: runID, modelID: "qwen3.8-4b-heretic-mlx4")
        let adapter = harness.adapter(ownerRunID: runID)
        let collector = Task { await collect(adapter, lifecycleRequest("运行中切到后台")) }
        #expect(await awaitTrue { engine.generationCount == 1 })
        canceller.applyLifecycleTransition(isBackground: true)
        let (events, error) = await collector.value
        #expect(error == nil)
        #expect(events.errorKinds == [.rateLimited])
        // The deferral is not a model failure and the durable run still claims
        // the model, so the resident mapping must stay ready for the retry.
        let loadState = await harness.runtime.currentLoadState()
        if case .ready(let modelID, _) = loadState {
            #expect(modelID == "qwen3.8-4b-heretic-mlx4")
        } else {
            Issue.record("expected the resident engine to stay ready, got \(loadState)")
        }
        #expect(engine.shutdownCount == 0)
        await harness.runtime.releaseForTask(taskID: runID, reason: "testFinished")
    }

    @Test("A caller stop while waiting for admission stays a cancellation, with no GPU work and no retry event")
    @available(macOS 15.4, iOS 26.0, *)
    func callerCancellationWhileWaitingForAdmission() async throws {
        let gate = ForegroundGate(active: false)
        let canceller = LocalInferenceBackgroundCanceller()
        canceller.installForegroundProbeForTesting { gate.isActive }
        let engine = ScriptedStreamingEngine(scripts: [[.output("不应生成")]])
        let harness = try ForegroundLifecycleHarness(
            engine: engine,
            canceller: canceller,
            // A long grace makes the wait observable; the cancellation must
            // abort it immediately rather than running it to completion.
            admission: LocalForegroundAdmissionPolicy(
                graceSeconds: 10,
                pollIntervalSeconds: 0.02
            )
        )
        defer { harness.cleanUp() }
        let adapter = harness.adapter()
        let collector = Task { await collect(adapter, lifecycleRequest("等待准入时取消")) }
        try? await Task.sleep(for: .milliseconds(150))
        let clock = ContinuousClock()
        let cancelStarted = clock.now
        collector.cancel()
        let (events, error) = await collector.value
        let elapsed = clock.now - cancelStarted
        #expect(error == nil || error is CancellationError)
        #expect(!(error is LocalInferenceDeferredError))
        #expect(events.errorKinds.isEmpty)
        #expect(engine.generationCount == 0)
        #expect(elapsed < .seconds(3))
    }

    @Test("A caller stop while waiting for generation registration never launches the GPU task")
    @available(macOS 15.4, iOS 26.0, *)
    func callerCancellationWhileWaitingForGenerationRegistration() async throws {
        let gate = ForegroundGateFlipAfterFirstRead()
        let canceller = LocalInferenceBackgroundCanceller()
        canceller.installForegroundProbeForTesting { gate.isActive }
        let engine = ScriptedStreamingEngine(scripts: [[.output("不应生成")]])
        let harness = try ForegroundLifecycleHarness(
            engine: engine,
            canceller: canceller,
            admission: LocalForegroundAdmissionPolicy(
                graceSeconds: 10,
                pollIntervalSeconds: 0.02
            )
        )
        defer { harness.cleanUp() }
        let adapter = harness.adapter()
        let collector = Task { await collect(adapter, lifecycleRequest("等待注册时取消")) }
        // Read 1 passes the pre-map admission; read 2 onward the app reports
        // inactive, so the caller is inside the generation registration wait.
        #expect(await awaitTrue { gate.readCount >= 2 })
        let clock = ContinuousClock()
        let cancelStarted = clock.now
        collector.cancel()
        let (events, error) = await collector.value
        let elapsed = clock.now - cancelStarted
        #expect(error == nil || error is CancellationError)
        #expect(!(error is LocalInferenceDeferredError))
        #expect(events.errorKinds.isEmpty)
        // The GPU task is created only after a successful registration, so a
        // cancelled registration performs no inference at all.
        #expect(engine.generationCount == 0)
        #expect(elapsed < .seconds(3))
    }

    @Test("Two tool turns keep their receipt across a foreground deferral without duplicate inference")
    @available(macOS 15.4, iOS 26.0, *)
    func twoToolTurnsSurviveForegroundDeferral() async throws {
        let callEnvelope = #"{"tool_call":{"name":"workspace.readFile","arguments":{"path":"a.md"}}}"#
        let gate = ForegroundGate(active: true)
        let canceller = LocalInferenceBackgroundCanceller()
        canceller.installForegroundProbeForTesting { gate.isActive }
        let engine = ScriptedStreamingEngine(scripts: [
            [.output(callEnvelope)],
            [.output("a.md 的内容是 hello。")]
        ])
        let harness = try ForegroundLifecycleHarness(
            engine: engine,
            canceller: canceller,
            admission: .immediate
        )
        defer { harness.cleanUp() }
        let adapter = harness.adapter()

        // Turn 1: the tool request itself.
        let (firstEvents, firstError) = await collect(
            adapter,
            lifecycleRequest("读取 a.md 并告诉我内容。", toolSchemas: [lifecycleReadFileSchema])
        )
        #expect(firstError == nil)
        #expect(firstEvents.toolRequests.map(\.toolName) == ["workspace.readFile"])
        #expect(firstEvents.stopReasons == [.toolUse])
        #expect(engine.generationCount == 1)
        guard let call = firstEvents.toolRequests.first else { return }

        let receipt = ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "hello",
            outputDigest: "digest"
        )
        let continuation = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: lifecycleModel(),
            messages: [
                (role: "user", content: "读取 a.md 并告诉我内容。"),
                (role: "assistant", content: callEnvelope),
                (role: "user", content: "a.md 里是什么？")
            ],
            toolResults: [(callID: call.id, output: "hello")],
            pendingToolCalls: [call],
            replayedToolPairs: [ReplayedToolPair(call: call, result: receipt)],
            toolSchemas: [lifecycleReadFileSchema],
            allToolNames: [lifecycleReadFileSchema.name]
        )

        // Turn 2: the app is momentarily backgrounded. The turn defers and
        // performs no second inference; the receipt stays in the durable
        // checkpoint (not replayed by the adapter).
        gate.set(false)
        let (deferredEvents, deferredError) = await collect(adapter, continuation)
        #expect(deferredError == nil)
        #expect(deferredEvents.errorKinds == [.rateLimited])
        #expect(deferredEvents.textDeltas.isEmpty)
        #expect(engine.generationCount == 1)

        // Turn 3 (the retry while active): the receipt is part of what the
        // engine receives and the visible answer is returned.
        gate.set(true)
        let (answerEvents, answerError) = await collect(adapter, continuation)
        #expect(answerError == nil)
        #expect(answerEvents.textDeltas == ["a.md 的内容是 hello。"])
        #expect(answerEvents.stopReasons == [.endTurn])
        #expect(engine.generationCount == 2)
        #expect(engine.receivedPrompts.count == 2)
        #expect(engine.receivedPrompts[1].contains("hello"))
    }
}

// MARK: - Runtime-level terminal-state regression tests

@available(macOS 15.4, iOS 26.0, *)
private struct ForegroundLifecycleNoExecution: ToolExecutor {
    var allDescriptors: [ToolCatalog.Descriptor] { [] }
    func descriptor(named name: String) -> ToolCatalog.Descriptor? { nil }
    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        throw FloeError.validationFailed("Synthetic foreground lifecycle test must not execute tools")
    }
}

@Suite("Local backgrounded run terminal state")
struct LocalBackgroundedRunTerminalStateTests {
    @available(macOS 15.4, iOS 26.0, *)
    private func service(
        harness: ForegroundLifecycleHarness,
        database: DatabaseManager,
        conversationID: UUID,
        retries: Int
    ) async throws -> ConversationRunService {
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        let provider = LocalProviderAdapter.providerProfile
        let model = lifecycleModel()
        return ConversationRunService(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: model,
                allowedToolNames: [],
                maxProviderRetries: retries,
                providerRetryBaseDelay: 0.05,
                providerRetryMaxDelay: 0.1,
                providerRetryJitterRatio: 0
            ),
            adapter: harness.adapter(),
            policy: HumanApprovalPolicy(),
            executor: ForegroundLifecycleNoExecution(),
            conversationStore: conversations,
            runStore: runs
        )
    }

    @Test("A backgrounded local run ends terminal and recoverable, never as an endless stream")
    @available(macOS 15.4, iOS 26.0, *)
    func backgroundedLocalRunEndsRecoverable() async throws {
        let gate = ForegroundGate(active: false)
        let canceller = LocalInferenceBackgroundCanceller()
        canceller.installForegroundProbeForTesting { gate.isActive }
        let engine = ScriptedStreamingEngine(scripts: [])
        let harness = try ForegroundLifecycleHarness(
            engine: engine,
            canceller: canceller,
            admission: .immediate
        )
        defer { harness.cleanUp() }
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let conversationID = UUID()
        try await conversations.saveConversation(.init(
            id: conversationID,
            title: "Synthetic backgrounded local run",
            createdAt: Date(),
            updatedAt: Date()
        ))
        let runService = try await service(
            harness: harness,
            database: database,
            conversationID: conversationID,
            retries: 1
        )
        try await runService.start(goal: "在后台开始的任务")
        let snapshot = await runService.snapshot()
        // Before the repair this ended in `streamingModel` (isTerminal false)
        // because the refusal was thrown as a bare CancellationError.
        #expect(snapshot.isTerminal)
        #expect(snapshot.stateName == "recoveryFailed")
        #expect(engine.generationCount == 0)
    }

    @Test("A local run whose app returns during the retry window completes")
    @available(macOS 15.4, iOS 26.0, *)
    func localRunRetriesWhenForegroundReturns() async throws {
        let gate = ForegroundGate(active: false)
        let canceller = LocalInferenceBackgroundCanceller()
        canceller.installForegroundProbeForTesting { gate.isActive }
        let engine = ScriptedStreamingEngine(scripts: [[.output("返回前台后的回答")]])
        let harness = try ForegroundLifecycleHarness(
            engine: engine,
            canceller: canceller,
            admission: .immediate
        )
        defer { harness.cleanUp() }
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let conversationID = UUID()
        try await conversations.saveConversation(.init(
            id: conversationID,
            title: "Synthetic foreground retry",
            createdAt: Date(),
            updatedAt: Date()
        ))
        let runService = try await service(
            harness: harness,
            database: database,
            conversationID: conversationID,
            retries: 3
        )
        let flipper = Task.detached {
            try? await Task.sleep(for: .milliseconds(40))
            gate.set(true)
        }
        defer { flipper.cancel() }
        try await runService.start(goal: "稍后返回前台的任务")
        let snapshot = await runService.snapshot()
        #expect(snapshot.isTerminal)
        #expect(snapshot.stateName == "completed")
        #expect(engine.generationCount == 1)
    }
}
