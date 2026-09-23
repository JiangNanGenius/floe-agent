// FloeLocalModelsTests — F2 explicit Linux-demand physical yield.
//
// `ConversationCenter` retains the local-model runtime for the WHOLE durable
// run (before the preparing phase, released only when the run reaches a
// terminal state), and a run that emits a Linux tool therefore owns the
// resident MLX mapping while it is *physically idle* (between generations,
// waiting on that tool). The ordinary release policies deliberately refuse to
// touch an engine a retained run owns:
//
//   * the two-minute idle window defers while any task is retained,
//   * `releaseIdleResidentEngineIfUnclaimed` requires zero retained tasks.
//
// Without an explicit demand path the Linux start waits on `drainRetainTimeout`
// and fails truthfully (`linuxModelRetained`) while the local run waits on its
// own tool: a self-deadlock converted into a failed tool, not a working
// continuation.
//
// `LocalModelRuntime.yieldIdleResidentEngineForLinux(reason:)` is the single
// narrow demand that physically unmaps the retained-but-idle engine while the
// logical claim, the conversation/tool context and the pinned snapshot stay
// exactly where they were. These tests script the real engine lifecycle
// around it — load -> generate -> Linux demand -> physical unload -> reload
// and continue — and additionally drive the REAL `HeavyRuntimeArbiter`
// drain/admission path the app wiring uses, so the integration contract is
// verified and not just described. No weights are mapped and no real model is
// invoked.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModels

// MARK: - Deterministic doubles

@available(macOS 15.4, iOS 26.0, *)
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Scripted engine that records exactly what the runtime handed to the chat
/// template (instructions, prompt) and how often it was shut down, so the
/// yield/reload boundary is directly observable.
@available(macOS 15.4, iOS 26.0, *)
private final class ScriptedEngine: LocalModelTextEngine, @unchecked Sendable {
    typealias Behavior = @Sendable (ScriptedEngine) throws -> LocalGenerationResult

    let includesVisionProjector = false
    private let behavior: Behavior
    private let lock = NSLock()
    private var _shutdownCount = 0
    private var _generationCount = 0
    private var _receivedPrompt = ""
    private var _receivedInstructions = ""

    var shutdownCount: Int { lock.withLock { _shutdownCount } }
    var generationCount: Int { lock.withLock { _generationCount } }
    var receivedPrompt: String { lock.withLock { _receivedPrompt } }
    var receivedInstructions: String { lock.withLock { _receivedInstructions } }

    static func reply(_ text: String) -> Behavior {
        { _ in
            LocalGenerationResult(
                text: text,
                inputTokens: 12,
                outputTokens: 6,
                timeToFirstTokenMs: 4,
                generationDurationMs: 8
            )
        }
    }

    init(behavior: @escaping Behavior = ScriptedEngine.reply("synthetic answer")) {
        self.behavior = behavior
    }

    func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult {
        lock.withLock {
            _generationCount += 1
            _receivedPrompt = prompt
            _receivedInstructions = instructions
        }
        return try behavior(self)
    }

    func shutdown() async {
        lock.withLock { _shutdownCount += 1 }
    }
}

/// Async gate that holds every container construction until the test releases
/// it. The blocked load is inside `prepareEngine`, i.e. the runtime already
/// holds both the FIFO inference slot and a transient engine lease — exactly
/// the state the yield must respect.
@available(macOS 15.4, iOS 26.0, *)
private actor EngineGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@available(macOS 15.4, iOS 26.0, *)
private final class ScriptedEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let gate: EngineGate?
    private var engines: [ScriptedEngine] = []
    private var makeCount = 0
    private var maxConcurrentLive = 0
    private var makeError: (@Sendable (Int) -> Error?)?
    private var behaviors: [Int: ScriptedEngine.Behavior] = [:]

    init(gate: EngineGate? = nil) { self.gate = gate }

    var liveCount: Int { lock.withLock { engines.filter { $0.shutdownCount == 0 }.count } }
    var maxLive: Int { lock.withLock { maxConcurrentLive } }
    var created: [ScriptedEngine] { lock.withLock { engines } }

    /// `error` receives the 1-based make index; returning non-nil throws that
    /// error out of the factory (simulating a container construction failure).
    func scheduleMakeError(_ error: @escaping @Sendable (Int) -> Error?) {
        lock.withLock { makeError = error }
    }

    func scheduleBehavior(_ behavior: @escaping ScriptedEngine.Behavior, forMakeIndex index: Int) {
        lock.withLock { behaviors[index] = behavior }
    }

    func make() async throws -> ScriptedEngine {
        // Register the engine first so a gated test can observe a real live
        // engine while the load is still in flight (the runtime already holds
        // the FIFO slot and a transient lease at this point).
        let engine = try registerEngine()
        if let gate { await gate.markStartedAndWait() }
        return engine
    }

    private func registerEngine() throws -> ScriptedEngine {
        let (error, behavior): (Error?, ScriptedEngine.Behavior) = lock.withLock {
            makeCount += 1
            let index = makeCount
            return (makeError?(index), behaviors[index] ?? ScriptedEngine.reply("synthetic answer"))
        }
        if let error { throw error }
        let engine = ScriptedEngine(behavior: behavior)
        lock.withLock {
            engines.append(engine)
            let live = engines.filter { $0.shutdownCount == 0 }.count
            maxConcurrentLive = max(maxConcurrentLive, live)
        }
        return engine
    }
}

// MARK: - Harness

@available(macOS 15.4, iOS 26.0, *)
private struct YieldHarness {
    let root: URL
    let runtime: LocalModelRuntime
    let factory: ScriptedEngineFactory
    let arbiter: HeavyRuntimeArbiter

    init(idleUnloadInterval: Duration = .seconds(120), gate: EngineGate? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-linux-yield-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = ScriptedEngineFactory(gate: gate)
        let arbiter = HeavyRuntimeArbiter()
        let modelRoot = root
        self.root = root
        self.factory = factory
        self.arbiter = arbiter
        self.runtime = LocalModelRuntime(
            store: LocalModelStore(root: modelRoot),
            makeEngine: { _, _, _, _ in try await factory.make() },
            measureAvailableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            modelSnapshot: { modelID in
                (directory: modelRoot.appendingPathComponent(modelID, isDirectory: true),
                 weightBytes: 1_000_000)
            },
            preflightSettleSamples: 0,
            preflightSettleInterval: .milliseconds(1),
            idleUnloadInterval: idleUnloadInterval,
            arbiter: arbiter
        )
    }

    /// The exact integration contract B2 will install in
    /// `AppEnvironment`'s `idleDrainHandler`: the explicit yield first, then
    /// the busy check (during a load `residentModelID()` is still nil while
    /// weights may already be mapping), then `residentModelID()` to separate
    /// "retained" from "nothing resident".
    func installLinuxDrain() {
        let runtime = self.runtime
        arbiter.configure(
            activityProbe: { HeavyRuntimeArbiter.LinuxActivity() },
            guestStopper: { _ in },
            idleDrainHandler: {
                if let released = await runtime.yieldIdleResidentEngineForLinux(reason: "linuxStartWaiting") {
                    return .released(modelID: released)
                }
                if await runtime.hasActiveInferenceOperation() {
                    return .retained
                }
                if await runtime.residentModelID() == nil {
                    return .nothingResident
                }
                return .retained
            },
            drainRetryInterval: .milliseconds(20),
            drainRetainTimeout: .seconds(5)
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private let linuxYieldModelID = "qwen3.8-4b-heretic-mlx4"

/// Bounded poll so a regression that stops admission surfaces as a failed
/// expectation instead of hanging the suite.
private func waitUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(10),
    _ condition: @Sendable () async -> Bool
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try await Task.sleep(for: interval)
    }
    return await condition()
}

@available(macOS 15.4, iOS 26.0, *)
private func generate(
    _ harness: YieldHarness,
    prompt: String
) async throws -> LocalRuntimeCompletion {
    try await harness.runtime.completeMeasured(
        modelID: linuxYieldModelID,
        instructions: "bounded",
        prompt: prompt,
        images: [],
        tools: [],
        maxTokens: 32
    )
}

// MARK: - Tests

@Suite("Local model Linux physical yield")
struct LocalModelLinuxYieldTests {
    @Test("A durable run yields its idle resident engine for its own Linux tool and reloads the same context")
    @available(macOS 15.4, iOS 26.0, *)
    func durableRunYieldsThenReloads() async throws {
        let harness = try YieldHarness()
        defer { harness.cleanUp() }
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: linuxYieldModelID)

        let first = try await generate(harness, prompt: "user: list the workspace")
        #expect(first.text == "synthetic answer")
        #expect(harness.factory.created.count == 1)
        #expect(harness.factory.liveCount == 1)
        #expect(await harness.runtime.retainedTaskCount == 1)

        // The generation ended and the run is suspended on its Linux tool.
        // This explicit demand is the only release that may unmap an engine a
        // durable run still owns.
        let released = await harness.runtime.yieldIdleResidentEngineForLinux(
            reason: "linuxTool:exec.shell"
        )
        #expect(released == linuxYieldModelID)
        #expect(harness.factory.created[0].shutdownCount == 1)
        #expect(harness.factory.liveCount == 0)
        #expect(await harness.runtime.residentModelID() == nil)
        #expect(await harness.runtime.currentLoadState() == .unloaded)
        // The logical claim and the run identity are untouched.
        #expect(await harness.runtime.retainedTaskCount == 1)
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.linuxYieldCount == 1)
        #expect(lifecycle.idleUnloadCount == 0)

        // The tool result arrives and the SAME run continues: the next
        // generation reloads the pinned snapshot (exactly one live engine,
        // never two) and receives the settled transcript including the tool
        // result, so the conversation/tool context survives the unmap.
        let settledTranscript = """
        user: list the workspace
        assistant: <tool_call name="exec.shell">ls -la</tool_call>
        <tool_result>a.md, b.md</tool_result>
        """
        let second = try await generate(harness, prompt: settledTranscript)
        #expect(second.text == "synthetic answer")
        #expect(harness.factory.created.count == 2)
        #expect(harness.factory.created[0].shutdownCount == 1)
        #expect(harness.factory.created[1].shutdownCount == 0)
        #expect(harness.factory.maxLive == 1)
        #expect(harness.factory.created[1].receivedPrompt.contains("<tool_result>a.md, b.md</tool_result>"))
        #expect(await harness.runtime.retainedTaskCount == 1)
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the reloaded engine to be ready for the continued run")
            return
        }

        await harness.runtime.releaseForTask(taskID: taskID, reason: "runFinished")
        await harness.runtime.unload()
        #expect(harness.factory.created[1].shutdownCount == 1)
        #expect(harness.factory.liveCount == 0)
    }

    @Test("An in-flight generation is never stolen: the Linux demand answers retained, then releases the idle mapping")
    @available(macOS 15.4, iOS 26.0, *)
    func activeGenerationIsNotStolen() async throws {
        let gate = EngineGate()
        let harness = try YieldHarness(gate: gate)
        defer { harness.cleanUp() }
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: linuxYieldModelID)

        let turn = Task { try await generate(harness, prompt: "turn one") }
        await gate.waitUntilStarted()
        #expect(harness.factory.created.count == 1)
        #expect(harness.factory.liveCount == 1)

        // The generation owns the FIFO slot and the mapping. The demand must
        // answer promptly with nil (arbiter `.retained`) instead of waiting on
        // or seizing the active work.
        let returned = Locked(false)
        let yieldTask = Task { () -> String? in
            let released = await harness.runtime.yieldIdleResidentEngineForLinux(reason: "linuxTool")
            returned.current = true
            return released
        }
        let prompt = try await waitUntil(timeout: .seconds(1)) { returned.current }
        guard prompt else {
            Issue.record("The Linux demand must answer retained promptly while a generation is in flight")
            await gate.release()
            _ = try? await turn.value
            _ = await yieldTask.value
            return
        }
        #expect(await yieldTask.value == nil)
        // The mapping was not touched, and the truthful mid-load state is
        // visible: slot busy, no resident model yet.
        #expect(harness.factory.created[0].shutdownCount == 0)
        #expect(harness.factory.created[0].generationCount == 0)
        #expect(await harness.runtime.hasActiveInferenceOperation())
        #expect(await harness.runtime.residentModelID() == nil)
        #expect(await harness.runtime.retainedTaskCount == 1)

        await gate.release()
        let completion = try await turn.value
        #expect(completion.text == "synthetic answer")
        #expect(harness.factory.created[0].generationCount == 1)

        // Once the generation finished and the mapping is physically idle,
        // the retried demand releases it exactly once.
        let released = await harness.runtime.yieldIdleResidentEngineForLinux(reason: "linuxTool:retry")
        #expect(released == linuxYieldModelID)
        #expect(harness.factory.created[0].shutdownCount == 1)
        #expect(harness.factory.liveCount == 0)
        #expect(!(await harness.runtime.hasActiveInferenceOperation()))
        #expect(await harness.runtime.retainedTaskCount == 1)
        await harness.runtime.releaseForTask(taskID: taskID, reason: "runFinished")
    }

    @Test("Ordinary idle paths keep durable-task protection; only the Linux yield releases the mapping")
    @available(macOS 15.4, iOS 26.0, *)
    func ordinaryProtectionAndNarrowYield() async throws {
        let harness = try YieldHarness(idleUnloadInterval: .milliseconds(120))
        defer { harness.cleanUp() }
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: linuxYieldModelID)
        try await harness.runtime.preload(modelID: linuxYieldModelID)
        #expect(harness.factory.liveCount == 1)

        // The two-minute idle window elapses with the task still retained: the
        // Build 224 protection is unchanged and the timer defers.
        try await Task.sleep(for: .milliseconds(320))
        #expect(harness.factory.created[0].shutdownCount == 0)
        #expect(await harness.runtime.lifecycleDiagnostics().idleUnloadCount == 0)

        // Benchmark/cleanup style release: deliberately refuses a retained
        // task (a benchmark must never unload the model a chat task is using).
        let kept = await harness.runtime.releaseIdleResidentEngineIfUnclaimed(
            reason: "benchmarkCleanup"
        )
        #expect(kept == nil)
        #expect(harness.factory.liveCount == 1)

        // The explicit Linux demand is narrower and does release it.
        let released = await harness.runtime.yieldIdleResidentEngineForLinux(
            reason: "linuxStartWaiting"
        )
        #expect(released == linuxYieldModelID)
        #expect(harness.factory.liveCount == 0)
        #expect(harness.factory.created[0].shutdownCount == 1)
        #expect(await harness.runtime.retainedTaskCount == 1)

        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.idleUnloadCount == 0)
        #expect(lifecycle.linuxYieldCount == 1)
        await harness.runtime.releaseForTask(taskID: taskID, reason: "runFinished")
        await harness.runtime.unload()
    }

    @Test("Two durable logical users recover across a Linux yield and still share one live engine")
    @available(macOS 15.4, iOS 26.0, *)
    func twoDurableUsersRecover() async throws {
        let harness = try YieldHarness(idleUnloadInterval: .milliseconds(150))
        defer { harness.cleanUp() }
        let first = UUID()
        let second = UUID()
        await harness.runtime.retainForTask(taskID: first, modelID: linuxYieldModelID)
        await harness.runtime.retainForTask(taskID: second, modelID: linuxYieldModelID)
        #expect(await harness.runtime.retainedTaskCount == 2)

        _ = try await generate(harness, prompt: "run one: turn one")
        #expect(harness.factory.created.count == 1)

        let released = await harness.runtime.yieldIdleResidentEngineForLinux(
            reason: "linuxStartWaiting"
        )
        #expect(released == linuxYieldModelID)
        #expect(await harness.runtime.retainedTaskCount == 2)

        // Nothing resident: an idempotent yield is a truthful no-op and never
        // touches the ledger.
        let idle = await harness.runtime.yieldIdleResidentEngineForLinux(
            reason: "linuxStartWaiting"
        )
        #expect(idle == nil)
        #expect(await harness.runtime.retainedTaskCount == 2)

        // The other logical user resumes on the same snapshot.
        _ = try await generate(harness, prompt: "run two: turn one")
        #expect(harness.factory.created.count == 2)
        #expect(harness.factory.maxLive == 1)
        #expect(harness.factory.created[1].generationCount == 1)

        // Releasing one user keeps the mapping for the other: ordinary
        // protection applies again after the yield.
        await harness.runtime.releaseForTask(taskID: first, reason: "finished")
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.factory.created[1].shutdownCount == 0)

        // The last release hands the mapping back to the accepted idle window.
        await harness.runtime.releaseForTask(taskID: second, reason: "finished")
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.factory.created[1].shutdownCount == 1)
        #expect(await harness.runtime.currentLoadState() == .unloaded)
    }

    @Test("A cancelled Linux request and a failed reload leave the durable run valid and recoverable")
    @available(macOS 15.4, iOS 26.0, *)
    func cancelledRequestAndFailedReloadStayRecoverable() async throws {
        let harness = try YieldHarness()
        defer { harness.cleanUp() }
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: linuxYieldModelID)
        _ = try await generate(harness, prompt: "turn one")

        let released = await harness.runtime.yieldIdleResidentEngineForLinux(
            reason: "linuxTool:exec.shell"
        )
        #expect(released == linuxYieldModelID)

        // The Linux start is cancelled before that tool returns. The runtime
        // owes no rollback: the claim, snapshot and transcript are unchanged.
        harness.arbiter.cancelLinuxStart(environmentID: "env-never-started")
        #expect(await harness.runtime.residentModelID() == nil)
        #expect(await harness.runtime.retainedTaskCount == 1)
        #expect(harness.factory.created.count == 1)

        // The next turn tries to reload and the container construction fails
        // (the device failure family): no half-initialized engine may leak and
        // the run must stay retryable.
        let failing = Locked(true)
        harness.factory.scheduleMakeError { _ in
            failing.current ? LocalInferenceError.modelLoadFailed : nil
        }
        await #expect(throws: LocalInferenceError.self) {
            _ = try await generate(harness, prompt: "turn two after linux")
        }
        guard case .failed = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the failed reload to surface a failed load state")
            return
        }
        #expect(harness.factory.liveCount == 0)
        #expect(await harness.runtime.retainedTaskCount == 1)

        // The retry succeeds on the same snapshot and the run continues.
        failing.current = false
        let resumed = try await generate(harness, prompt: "turn two after linux, retry")
        #expect(resumed.text == "synthetic answer")
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the recovered reload to be ready")
            return
        }
        #expect(harness.factory.created.count == 2)
        #expect(await harness.runtime.retainedTaskCount == 1)

        await harness.runtime.releaseForTask(taskID: taskID, reason: "runFinished")
        await harness.runtime.unload()
        #expect(harness.factory.liveCount == 0)
    }

    @Test("The real arbiter drain physically releases a logically retained but physically idle engine")
    @available(macOS 15.4, iOS 26.0, *)
    func arbiterDrainReleasesRetainedEngine() async throws {
        let harness = try YieldHarness()
        defer { harness.cleanUp() }
        harness.installLinuxDrain()
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: linuxYieldModelID)
        _ = try await generate(harness, prompt: "turn one")
        #expect(harness.factory.liveCount == 1)
        #expect(await harness.runtime.retainedTaskCount == 1)

        let linuxTask = Task {
            try await harness.arbiter.waitForLocalInferenceIdle(registeringStart: "env-linux-1")
        }
        let admitted = try await waitUntil(timeout: .seconds(5)) {
            harness.arbiter.pendingLinuxStartEnvironmentIDs == ["env-linux-1"]
        }
        linuxTask.cancel()
        _ = try? await linuxTask.value
        #expect(admitted, "Linux admission must not wait on a retained-but-idle engine")

        #expect(harness.factory.created[0].shutdownCount == 1)
        #expect(harness.factory.liveCount == 0)
        #expect(await harness.runtime.residentModelID() == nil)
        #expect(await harness.runtime.lifecycleDiagnostics().linuxYieldCount == 1)
        #expect(harness.arbiter.linuxDrainCompletionCount >= 1)

        harness.arbiter.releaseLinuxStart(environmentID: "env-linux-1")
        await harness.runtime.releaseForTask(taskID: taskID, reason: "runFinished")
        await harness.runtime.unload()
    }

    @Test("Linux admission waits through the active generation, then reclaims the yielded mapping")
    @available(macOS 15.4, iOS 26.0, *)
    func arbiterWaitsThroughActiveGeneration() async throws {
        let gate = EngineGate()
        let harness = try YieldHarness(gate: gate)
        defer { harness.cleanUp() }
        harness.installLinuxDrain()
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: linuxYieldModelID)

        let turn = Task { try await generate(harness, prompt: "turn one") }
        await gate.waitUntilStarted()

        let linuxTask = Task {
            try await harness.arbiter.waitForLocalInferenceIdle(registeringStart: "env-linux-2")
        }
        // The active inference session queues the start; the drain cannot run
        // and the engine is not touched while the generation is in flight.
        let queued = try await waitUntil(timeout: .seconds(2)) {
            harness.arbiter.linuxWaiterCount == 1
        }
        #expect(queued, "The Linux start must queue behind the active local generation")
        #expect(harness.factory.liveCount == 1)
        #expect(harness.factory.created[0].shutdownCount == 0)
        #expect(harness.arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)

        await gate.release()
        let completion = try await turn.value
        #expect(completion.text == "synthetic answer")

        let admitted = try await waitUntil(timeout: .seconds(5)) {
            harness.arbiter.pendingLinuxStartEnvironmentIDs == ["env-linux-2"]
        }
        linuxTask.cancel()
        _ = try? await linuxTask.value
        #expect(admitted, "Linux admission must proceed once the generation ended and the mapping was yielded")

        #expect(harness.factory.created[0].shutdownCount == 1)
        #expect(harness.factory.liveCount == 0)
        #expect(await harness.runtime.retainedTaskCount == 1)
        #expect(await harness.runtime.lifecycleDiagnostics().linuxYieldCount == 1)

        harness.arbiter.releaseLinuxStart(environmentID: "env-linux-2")
        await harness.runtime.releaseForTask(taskID: taskID, reason: "runFinished")
        await harness.runtime.unload()
    }

    @Test("Racing Linux demand and generation stay serialized with a single live mapping")
    @available(macOS 15.4, iOS 26.0, *)
    func racingYieldAndGenerationStaySerialized() async throws {
        let harness = try YieldHarness()
        defer { harness.cleanUp() }
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: linuxYieldModelID)

        for index in 0..<8 {
            async let turn = generate(harness, prompt: "racing turn \(index)")
            async let yielded = harness.runtime.yieldIdleResidentEngineForLinux(reason: "linuxTool")
            let completion = try await turn
            _ = await yielded
            #expect(completion.text == "synthetic answer")
        }

        #expect(harness.factory.maxLive == 1)
        #expect(harness.factory.liveCount <= 1)
        #expect(harness.factory.created.allSatisfy { $0.shutdownCount <= 1 })
        let generations = harness.factory.created.reduce(0) { $0 + $1.generationCount }
        #expect(generations == 8, "No turn may be cancelled or lost to a racing yield")
        #expect(await harness.runtime.retainedTaskCount == 1)

        await harness.runtime.releaseForTask(taskID: taskID, reason: "runFinished")
        await harness.runtime.unload()
        #expect(harness.factory.liveCount == 0)
    }
}
