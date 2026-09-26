import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

/// Build-198 lifecycle regression suite. The device report showed: turn 1
/// succeeds, the next text turn fails with `decodeFailed`, retries then fail
/// the memory preflight (`model files: 3034299183 bytes` vs ~2.6 GB
/// instantaneous allowance), and a later turn fails with "MLX container
/// initialization failed". These tests exercise the repaired lifecycle —
/// reclaim-aware preflight, failure cleanup, clean recreate/retry, vision
/// shed and single-container ownership — through deterministic fakes. No real
/// weights are mapped and no safety threshold is weakened.
@Suite("Local model memory lifecycle")
struct LocalModelLifecycleTests {
    private final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    /// Fire-once latch for scripted behaviors (fail the first call, succeed the
    /// next) without changing the engine identity under test.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.withLock {
                if fired { return false }
                fired = true
                return true
            }
        }
    }

    /// Scripted on-device engine. Records shutdown and the exact inputs so
    /// vision retention and ownership are directly observable.
    private final class FakeEngine: LocalModelTextEngine, @unchecked Sendable {
        typealias Behavior = @Sendable (FakeEngine) throws -> LocalGenerationResult
        let includesVisionProjector: Bool
        let behavior: Behavior
        private let lock = NSLock()
        private var _shutdownCount = 0
        private var _receivedImages: [Data] = []
        private var _receivedPrompts: [String] = []
        private var _requiresCleanReload = false
        var shutdownCount: Int { lock.withLock { _shutdownCount } }
        var receivedImages: [Data] { lock.withLock { _receivedImages } }
        var receivedPrompts: [String] { lock.withLock { _receivedPrompts } }
        var requiresCleanReload: Bool { lock.withLock { _requiresCleanReload } }
        /// Simulates the production engine observing a queued MLX error while
        /// draining a completed turn (the text was still delivered).
        func markUncleanForTesting() { lock.withLock { _requiresCleanReload = true } }

        static func success(text: String = "synthetic answer") -> Behavior {
            { _ in
                LocalGenerationResult(text: text, inputTokens: 8, outputTokens: 4,
                                      timeToFirstTokenMs: 5, generationDurationMs: 10)
            }
        }

        init(includesVisionProjector: Bool = false, behavior: @escaping Behavior = FakeEngine.success()) {
            self.includesVisionProjector = includesVisionProjector
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
                _receivedImages = images
                _receivedPrompts.append(prompt)
            }
            return try behavior(self)
        }

        func shutdown() async {
            lock.withLock { _shutdownCount += 1 }
        }
    }

    /// Tracks every created engine so tests can assert single-container
    /// ownership (at most one live engine at any moment), and supports
    /// per-make-index failure and behavior scheduling.
    private final class EngineFactoryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var engines: [FakeEngine] = []
        private var maxConcurrentLive = 0
        private var makeCount = 0
        private var makeError: (@Sendable (Int) -> Error?)?
        private var behaviors: [Int: FakeEngine.Behavior] = [:]

        var liveCount: Int { lock.withLock { engines.filter { $0.shutdownCount == 0 }.count } }
        var maxLive: Int { lock.withLock { maxConcurrentLive } }
        var created: [FakeEngine] { lock.withLock { engines } }

        /// `error` receives the 1-based make index; returning non-nil throws
        /// that error out of the factory (simulating an MLX init failure).
        func scheduleMakeError(_ error: @escaping @Sendable (Int) -> Error?) {
            lock.withLock { makeError = error }
        }

        func scheduleBehavior(_ behavior: @escaping FakeEngine.Behavior, forMakeIndex index: Int) {
            lock.withLock { behaviors[index] = behavior }
        }

        func makeWithPossibleFailure(includesVisionProjector: Bool = false) throws -> FakeEngine {
            lock.lock()
            makeCount += 1
            let index = makeCount
            let error = makeError?(index)
            let behavior = behaviors[index] ?? FakeEngine.success()
            lock.unlock()
            if let error { throw error }
            return make(includesVisionProjector: includesVisionProjector, behavior: behavior)
        }

        private func make(includesVisionProjector: Bool, behavior: @escaping FakeEngine.Behavior) -> FakeEngine {
            let engine = FakeEngine(includesVisionProjector: includesVisionProjector, behavior: behavior)
            lock.lock()
            engines.append(engine)
            let live = engines.filter { $0.shutdownCount == 0 }.count
            maxConcurrentLive = max(maxConcurrentLive, live)
            lock.unlock()
            return engine
        }
    }

    /// Scriptable `os_proc_available_memory` stand-in.
    private final class MemoryScript: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [UInt64]
        private var reads = 0
        init(_ samples: [UInt64]) { self.samples = samples }
        var readCount: Int { lock.withLock { reads } }
        func next() -> UInt64 {
            lock.withLock {
                reads += 1
                if samples.count > 1 { return samples.removeFirst() }
                return samples.first ?? 4_000_000_000
            }
        }
        func restore(_ values: [UInt64]) {
            lock.withLock { samples = values }
        }
    }

    @available(macOS 15.4, iOS 26.0, *)
    private struct Harness {
        let runtime: LocalModelRuntime
        let factory: EngineFactoryRecorder
        let memory: MemoryScript
        let snapshotRoot: URL

        init(memorySamples: [UInt64],
             settleSamples: Int = 3,
             settleInterval: Duration = .milliseconds(1),
             weightBytes: UInt64 = 3_034_299_183) {
            let factory = EngineFactoryRecorder()
            let memory = MemoryScript(memorySamples)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let runtime = LocalModelRuntime(
                store: LocalModelStore(root: root),
                makeEngine: { _, includesVisionProjector, _, _ in
                    try factory.makeWithPossibleFailure(includesVisionProjector: includesVisionProjector)
                },
                measureAvailableMemory: { memory.next() },
                modelSnapshot: { id in
                    let directory = root.appendingPathComponent(id, isDirectory: true)
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    return (directory: directory, weightBytes: weightBytes)
                },
                preflightSettleSamples: settleSamples,
                preflightSettleInterval: settleInterval
            )
            self.runtime = runtime
            self.factory = factory
            self.memory = memory
            self.snapshotRoot = root
        }
    }

    private let modelID = "qwen3.8-4b-heretic-mlx4"

    // MARK: 1. First text turn -> second text turn

    @Test("First text turn then second text turn keeps a single container and sheds nothing")
    @available(macOS 15.4, iOS 26.0, *)
    func firstTextTurnThenSecondTextTurn() async throws {
        let harness = Harness(memorySamples: [4_000_000_000])
        // Turn 1: load -> generate -> retain for the Build 222 idle window. The
        // per-turn teardown inside the engine still drains the GPU stream and
        // clears the allocator cache; only the weight mapping stays resident.
        let first = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn one",
            images: [], tools: [], maxTokens: 32
        )
        #expect(first.text == "synthetic answer")
        #expect(harness.factory.created.count == 1)
        #expect(harness.factory.created[0].shutdownCount == 0)
        #expect(harness.factory.liveCount == 1)
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the resident engine to stay ready between turns")
            return
        }
        // Turn 2 (text-only continuation): reuses the resident container
        // instead of reloading, never has two containers at once, and
        // receives zero image bytes.
        let second = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn two",
            images: [], tools: [], maxTokens: 32
        )
        #expect(second.text == "synthetic answer")
        #expect(harness.factory.created.count == 1)
        #expect(harness.factory.maxLive == 1)
        #expect(harness.factory.created[0].receivedImages.isEmpty)
        #expect(harness.factory.created[0].includesVisionProjector == false)
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.engineCreateCount == 1)
        #expect(lifecycle.engineShutdownCount == 0)
        #expect(lifecycle.engineReuseCount == 1)
        #expect(lifecycle.idleUnloadCount == 0)
        #expect(lifecycle.visionShedCount == 0)
        #expect(lifecycle.decodeRetryCount == 0)
        #expect(lifecycle.consecutiveFailureCount == 0)
    }

    // MARK: 2. Text continuation sheds a resident vision engine

    @Test("Text-only continuation sheds a resident vision engine")
    @available(macOS 15.4, iOS 26.0, *)
    func textContinuationShedsVisionEngine() async throws {
        let harness = Harness(memorySamples: [4_000_000_000])
        let vlm = try harness.factory.makeWithPossibleFailure(includesVisionProjector: true)
        await harness.runtime.installResidentEngineForTesting(
            vlm, modelID: modelID, includesVisionProjector: true
        )
        let result = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "plain text follow-up",
            images: [], tools: [], maxTokens: 32
        )
        #expect(result.text == "synthetic answer")
        // The VLM is shut down and replaced by a text-only engine; at no
        // moment were two containers live.
        #expect(vlm.shutdownCount == 1)
        #expect(harness.factory.maxLive == 1)
        #expect(harness.factory.created.last?.includesVisionProjector == false)
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.visionShedCount == 1)
    }

    // MARK: 3. Decode failure -> unload/recreate -> clean retry

    @Test("A mid-decode failure unloads, recreates and retries once transparently")
    @available(macOS 15.4, iOS 26.0, *)
    func decodeFailureRetriesOnce() async throws {
        let harness = Harness(memorySamples: [4_000_000_000, 4_000_000_000])
        harness.factory.scheduleBehavior({ _ in throw LocalInferenceError.decodeFailed }, forMakeIndex: 1)
        harness.factory.scheduleBehavior(FakeEngine.success(text: "recovered answer"), forMakeIndex: 2)
        let result = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "second turn",
            images: [], tools: [], maxTokens: 32
        )
        #expect(result.text == "recovered answer")
        #expect(harness.factory.created.count == 2)
        #expect(harness.factory.created[0].shutdownCount == 1)
        #expect(harness.factory.maxLive == 1)
        // The recovered engine now stays resident for the idle window.
        #expect(harness.factory.created[1].shutdownCount == 0)
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the recovered engine to stay ready")
            return
        }
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.decodeRetryCount == 1)
        #expect(lifecycle.consecutiveFailureCount == 0)
    }

    @Test("A persistent decode failure surfaces one error and the next turn recovers")
    @available(macOS 15.4, iOS 26.0, *)
    func persistentDecodeFailureThenRecovery() async throws {
        let harness = Harness(memorySamples: [4_000_000_000, 4_000_000_000])
        let factory = harness.factory
        let runtime = LocalModelRuntime(
            store: LocalModelStore(root: harness.snapshotRoot),
            makeEngine: { _, includesVisionProjector, _, _ in
                try factory.makeWithPossibleFailure(includesVisionProjector: includesVisionProjector)
            },
            measureAvailableMemory: { harness.memory.next() },
            modelSnapshot: { id in
                let directory = harness.snapshotRoot.appendingPathComponent(id, isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return (directory: directory, weightBytes: 3_034_299_183)
            },
            preflightSettleSamples: 3,
            preflightSettleInterval: .milliseconds(1)
        )
        // Turn one fails on both attempts. Turn two also fails on its first
        // engine and must receive its own single transparent retry.
        let decodeFailure: FakeEngine.Behavior = { _ in
            throw LocalInferenceError.decodeFailed
        }
        factory.scheduleBehavior(decodeFailure, forMakeIndex: 1)
        factory.scheduleBehavior(decodeFailure, forMakeIndex: 2)
        factory.scheduleBehavior(decodeFailure, forMakeIndex: 3)
        factory.scheduleBehavior(FakeEngine.success(text: "clean retry"), forMakeIndex: 4)
        // Turn 1: decode keeps failing (first engine + one transparent retry).
        await #expect(throws: LocalInferenceError.self) {
            try await runtime.completeMeasured(
                modelID: modelID, instructions: "i", prompt: "turn one",
                images: [], tools: [], maxTokens: 32
            )
        }
        #expect(factory.created.count == 2)
        #expect(factory.liveCount == 0)
        let failedState = await runtime.currentLoadState()
        if case .failed = failedState {} else {
            Issue.record("Expected failed load state, got \(failedState)")
        }
        var lifecycle = await runtime.lifecycleDiagnostics()
        #expect(lifecycle.decodeRetryCount == 1)
        #expect(lifecycle.consecutiveFailureCount == 1)
        // The runtime is not permanently broken: the next turn gets an
        // independent retry budget and finishes cleanly.
        let result = try await runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn two",
            images: [], tools: [], maxTokens: 32
        )
        #expect(result.text == "clean retry")
        #expect(factory.created.count == 4)
        #expect(factory.created[3].shutdownCount == 0)
        guard case .ready = await runtime.currentLoadState() else {
            Issue.record("Expected the recovered engine to stay ready")
            return
        }
        lifecycle = await runtime.lifecycleDiagnostics()
        #expect(lifecycle.decodeRetryCount == 2)
        #expect(lifecycle.consecutiveFailureCount == 0)
    }

    // MARK: 3b. Failed-turn cleanup (Build 228 second-message regression)

    @Test("A failed retained turn is recreated for the next turn, never reused")
    @available(macOS 15.4, iOS 26.0, *)
    func failedRetainedEngineIsNotReused() async throws {
        // The app retains the durable run BEFORE dispatch, so a turn failure
        // happens with `taskResidency.activeTaskCount > 0`. The repaired
        // cleanup keeps the mapping claimed (a concurrent operation must not
        // be yanked) but marks it failed; the conversation's next message must
        // get a clean container instead of the engine that just errored.
        let harness = Harness(memorySamples: [4_000_000_000])
        let factory = harness.factory
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: modelID)
        let decodeFailure: FakeEngine.Behavior = { _ in
            throw LocalInferenceError.decodeFailed
        }
        // Turn one: first engine plus its one transparent decode retry fail.
        factory.scheduleBehavior(decodeFailure, forMakeIndex: 1)
        factory.scheduleBehavior(decodeFailure, forMakeIndex: 2)
        await #expect(throws: LocalInferenceError.self) {
            try await harness.runtime.completeMeasured(
                modelID: modelID, instructions: "i", prompt: "turn one",
                images: [], tools: [], maxTokens: 32, ownerRunID: taskID
            )
        }
        #expect(factory.created.count == 2)
        // The failed mapping is still claimed, but the state must be honest:
        // failed, never ready, while no other operation is in flight.
        guard case .failed = await harness.runtime.currentLoadState() else {
            Issue.record("A retained failed engine must report failed, not ready")
            return
        }
        #expect(factory.created[1].shutdownCount == 0)

        // Turn two in the same conversation: the failed container must be torn
        // down and replaced by a fresh one. Reusing it would repeat turn one's
        // failure — the Build 228 second-message regression.
        factory.scheduleBehavior(FakeEngine.success(text: "clean second turn"), forMakeIndex: 3)
        let second = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn two",
            images: [], tools: [], maxTokens: 32, ownerRunID: taskID
        )
        #expect(second.text == "clean second turn")
        #expect(factory.created.count == 3)
        #expect(factory.created[1].shutdownCount == 1)
        #expect(factory.liveCount == 1)
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the recreated engine to be ready")
            return
        }
        await harness.runtime.releaseForTask(taskID: taskID, reason: "finished")
    }

    @Test("Releasing the last task after a failure drops the failed mapping immediately")
    @available(macOS 15.4, iOS 26.0, *)
    func failedEngineIsReleasedWithoutIdleWindow() async throws {
        // A failed mapping earns no two-minute idle window: once the last
        // durable claim releases, failure cleanup unloads it immediately so a
        // new conversation turn cannot reuse a broken engine and the settings
        // surface stops reporting it as resident.
        let harness = Harness(memorySamples: [4_000_000_000])
        let factory = harness.factory
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: modelID)
        let decodeFailure: FakeEngine.Behavior = { _ in
            throw LocalInferenceError.decodeFailed
        }
        factory.scheduleBehavior(decodeFailure, forMakeIndex: 1)
        factory.scheduleBehavior(decodeFailure, forMakeIndex: 2)
        await #expect(throws: LocalInferenceError.self) {
            try await harness.runtime.completeMeasured(
                modelID: modelID, instructions: "i", prompt: "turn one",
                images: [], tools: [], maxTokens: 32, ownerRunID: taskID
            )
        }
        #expect(factory.created[1].shutdownCount == 0)
        await harness.runtime.releaseForTask(taskID: taskID, reason: "runFailed")
        #expect(factory.created[1].shutdownCount == 1)
        #expect(factory.liveCount == 0)
        #expect(await harness.runtime.currentLoadState() == .unloaded)
    }

    @Test("A cancelled turn keeps its claim and reuses the mapping")
    @available(macOS 15.4, iOS 26.0, *)
    func cancelledTurnDoesNotPoisonTheEngine() async throws {
        // Cancellation is not a model failure: the retained engine must stay
        // fully reusable, with no failure marking and no recreate.
        let harness = Harness(memorySamples: [4_000_000_000])
        let factory = harness.factory
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: modelID)
        let firstCall = OnceFlag()
        factory.scheduleBehavior({ _ in
            if firstCall.fire() { throw CancellationError() }
            return LocalGenerationResult(
                text: "clean after cancel", inputTokens: 8, outputTokens: 4,
                timeToFirstTokenMs: 5, generationDurationMs: 10
            )
        }, forMakeIndex: 1)
        await #expect(throws: CancellationError.self) {
            try await harness.runtime.completeMeasured(
                modelID: modelID, instructions: "i", prompt: "turn one",
                images: [], tools: [], maxTokens: 32, ownerRunID: taskID
            )
        }
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("A cancelled turn must keep the engine ready")
            return
        }
        let second = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn two",
            images: [], tools: [], maxTokens: 32, ownerRunID: taskID
        )
        #expect(second.text == "clean after cancel")
        #expect(factory.created.count == 1)
        #expect(factory.created[0].shutdownCount == 0)
        await harness.runtime.releaseForTask(taskID: taskID, reason: "finished")
    }

    // MARK: 3c. Successful first turn → second message (the observed sequence)

    @Test("A successful first turn is reused for the longer second message")
    @available(macOS 15.4, iOS 26.0, *)
    func successfulFirstTurnReusedForLongerSecondMessage() async throws {
        // The user-visible sequence under repair: the first answer succeeds and
        // the second message in the same conversation must reach the resident
        // engine with the accumulated history, without a reload and without a
        // cross-turn failure. The second prompt is deliberately longer (the
        // folded USER/ASSISTANT transcript) so a length-sensitive regression
        // cannot pass by accident.
        let harness = Harness(memorySamples: [4_000_000_000])
        let factory = harness.factory
        let firstRun = UUID()
        await harness.runtime.retainForTask(taskID: firstRun, modelID: modelID)
        let first = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "你好",
            images: [], tools: [], maxTokens: 32
        )
        #expect(first.text == "synthetic answer")
        #expect(factory.created.count == 1)
        await harness.runtime.releaseForTask(taskID: firstRun, reason: "completed")
        #expect(factory.created[0].shutdownCount == 0)

        let secondRun = UUID()
        await harness.runtime.retainForTask(taskID: secondRun, modelID: modelID)
        let longerPrompt = "USER: 你好\nASSISTANT: 你好！有什么可以帮你的？\nUSER: 那我们继续刚才的话题"
        let second = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: longerPrompt,
            images: [], tools: [], maxTokens: 32
        )
        #expect(second.text == "synthetic answer")
        // Same container: no second load, no shutdown between turns.
        #expect(factory.created.count == 1)
        #expect(factory.created[0].shutdownCount == 0)
        // Both exact prompts reached the engine in order, so the second turn
        // kept the earlier exchange instead of starting from empty history.
        #expect(factory.created[0].receivedPrompts == ["你好", longerPrompt])
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the shared engine to stay ready after turn two")
            return
        }
        await harness.runtime.releaseForTask(taskID: secondRun, reason: "completed")
    }

    @Test("A success then a second-turn failure still gives the third turn a clean engine")
    @available(macOS 15.4, iOS 26.0, *)
    func successThenSecondTurnFailureThenRecovery() async throws {
        // First turn succeeds; the second message fails inside the resident
        // engine (both the attempt and its transparent decode retry). The
        // failure is reported honestly, and the third turn must never reuse
        // the failed mapping: it is torn down and recreated.
        let harness = Harness(memorySamples: [4_000_000_000])
        let factory = harness.factory
        let firstRun = UUID()
        await harness.runtime.retainForTask(taskID: firstRun, modelID: modelID)
        let firstCall = OnceFlag()
        factory.scheduleBehavior({ _ in
            if firstCall.fire() {
                return LocalGenerationResult(
                    text: "first answer", inputTokens: 8, outputTokens: 4,
                    timeToFirstTokenMs: 5, generationDurationMs: 10
                )
            }
            throw LocalInferenceError.decodeFailed
        }, forMakeIndex: 1)
        factory.scheduleBehavior(
            { _ in throw LocalInferenceError.decodeFailed }, forMakeIndex: 2
        )
        let first = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn one",
            images: [], tools: [], maxTokens: 32
        )
        #expect(first.text == "first answer")
        await harness.runtime.releaseForTask(taskID: firstRun, reason: "completed")

        let secondRun = UUID()
        await harness.runtime.retainForTask(taskID: secondRun, modelID: modelID)
        await #expect(throws: LocalInferenceError.self) {
            try await harness.runtime.completeMeasured(
                modelID: modelID, instructions: "i", prompt: "turn two (longer history)",
                images: [], tools: [], maxTokens: 32, ownerRunID: secondRun
            )
        }
        // Attempt 1 reused the successful engine (which then failed), the
        // transparent retry built a second one and failed too; that second,
        // failed mapping is the one kept claimed and must report failed.
        #expect(factory.created.count == 2)
        #expect(factory.created[0].shutdownCount == 1)
        #expect(factory.created[1].shutdownCount == 0)
        guard case .failed = await harness.runtime.currentLoadState() else {
            Issue.record("A retained failed engine must report failed, not ready")
            return
        }

        factory.scheduleBehavior(FakeEngine.success(text: "third turn"), forMakeIndex: 3)
        let third = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn three",
            images: [], tools: [], maxTokens: 32, ownerRunID: secondRun
        )
        #expect(third.text == "third turn")
        #expect(factory.created.count == 3)
        #expect(factory.created[1].shutdownCount == 1)
        #expect(factory.liveCount == 1)
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the recreated engine to be ready")
            return
        }
        await harness.runtime.releaseForTask(taskID: secondRun, reason: "completed")
    }

    @Test("A successful turn with an unclean MLX teardown is recreated for the next message")
    @available(macOS 15.4, iOS 26.0, *)
    func uncleanTeardownForcesCleanReload() async throws {
        // The Build 228 device sequence: the first answer is delivered (the
        // engine reports success) but its teardown observed a queued MLX error,
        // so the container must not serve the second message. The runtime
        // recreates it instead of reusing the mapping that just errored behind
        // a successful answer.
        let harness = Harness(memorySamples: [4_000_000_000])
        let factory = harness.factory
        let firstRun = UUID()
        await harness.runtime.retainForTask(taskID: firstRun, modelID: modelID)
        let first = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "你好",
            images: [], tools: [], maxTokens: 32, ownerRunID: firstRun
        )
        #expect(first.text == "synthetic answer")
        #expect(factory.created.count == 1)
        factory.created[0].markUncleanForTesting()
        await harness.runtime.releaseForTask(taskID: firstRun, reason: "completed")
        // The unclean mapping earns no idle window: releasing the last claim
        // unloads it immediately and the surface stops reporting it resident.
        #expect(factory.created[0].shutdownCount == 1)
        #expect(factory.liveCount == 0)
        #expect(await harness.runtime.currentLoadState() == .unloaded)

        let secondRun = UUID()
        await harness.runtime.retainForTask(taskID: secondRun, modelID: modelID)
        let second = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i",
            prompt: "USER: 你好\nASSISTANT: 你好！\nUSER: 那我们继续",
            images: [], tools: [], maxTokens: 32, ownerRunID: secondRun
        )
        #expect(second.text == "synthetic answer")
        #expect(factory.created.count == 2)
        #expect(factory.created[1].shutdownCount == 0)
        #expect(factory.liveCount == 1)
        await harness.runtime.releaseForTask(taskID: secondRun, reason: "completed")
    }

    @Test("An unclean engine is recreated even while its run still claims it")
    @available(macOS 15.4, iOS 26.0, *)
    func uncleanEngineRecreatedWhileClaimed() async throws {
        // An in-run continuation (tool result → next model turn) keeps the
        // durable claim while the previous turn reported an unclean teardown.
        // The prepare path must recreate the container rather than reuse it.
        let harness = Harness(memorySamples: [4_000_000_000])
        let factory = harness.factory
        let runID = UUID()
        await harness.runtime.retainForTask(taskID: runID, modelID: modelID)
        let first = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn one",
            images: [], tools: [], maxTokens: 32, ownerRunID: runID
        )
        #expect(first.text == "synthetic answer")
        factory.created[0].markUncleanForTesting()
        // No release: the run continues and still claims the model.
        let second = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn two (tool continuation)",
            images: [], tools: [], maxTokens: 32, ownerRunID: runID
        )
        #expect(second.text == "synthetic answer")
        #expect(factory.created.count == 2)
        #expect(factory.created[0].shutdownCount == 1)
        #expect(factory.created[1].shutdownCount == 0)
        #expect(factory.liveCount == 1)
        await harness.runtime.releaseForTask(taskID: runID, reason: "completed")
    }

    // MARK: 4. Memory-pressure lifecycle
    @Test("Preflight reclaim settle recovers within the bounded window instead of rejecting")
    @available(macOS 15.4, iOS 26.0, *)
    func memoryPressureSettleRecovers() async throws {
        // Qwen3.8 4B weights: 3,034,299,183 bytes. The 110% rule needs
        // >= 2,758,453,803 bytes. The first two reads are too low (as right
        // after a previous turn's teardown); the third recovers.
        let harness = Harness(
            memorySamples: [2_500_000_000, 2_600_000_000, 3_100_000_000],
            settleSamples: 4,
            settleInterval: .milliseconds(1)
        )
        let result = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "second turn",
            images: [], tools: [], maxTokens: 32
        )
        #expect(result.text == "synthetic answer")
        #expect(harness.factory.created.count == 1)
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.lastPreflightSamples.count == 3)
        #expect(lifecycle.preflightRejectCount == 0)
    }

    @Test("Sustained memory pressure rejects with a bounded sample count and recovers later")
    @available(macOS 15.4, iOS 26.0, *)
    func sustainedMemoryPressureRejectsBoundedlyAndRecovers() async throws {
        let harness = Harness(
            memorySamples: [2_000_000_000],
            settleSamples: 3,
            settleInterval: .milliseconds(1)
        )
        do {
            _ = try await harness.runtime.completeMeasured(
                modelID: modelID, instructions: "i", prompt: "turn one",
                images: [], tools: [], maxTokens: 32
            )
            Issue.record("Expected insufficientMemory to be thrown")
        } catch let error as LocalInferenceError {
            guard case .insufficientMemory(let required, let physical, _) = error else {
                Issue.record("Expected insufficientMemory, got \(error)")
                return
            }
            #expect(required == 3_034_299_183)
            #expect(physical == 2_000_000_000)
        }
        // Bounded window: one free sample + three settle samples, no more.
        // (One extra read feeds the post-failure diagnostic log line.)
        #expect(harness.memory.readCount == 5)
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.preflightRejectCount == 1)
        #expect(lifecycle.lastPreflightSamples.count == 4)
        #expect(harness.factory.created.isEmpty)
        // Recovery is never blocked: once the allowance returns, the same
        // runtime loads and answers on the next turn.
        harness.memory.restore([3_500_000_000])
        let result = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn two",
            images: [], tools: [], maxTokens: 32
        )
        #expect(result.text == "synthetic answer")
        #expect(harness.factory.created.count == 1)
    }

    // MARK: 5. Load failure -> clean recreate

    @Test("An MLX container initialization failure recreates once and recovers")
    @available(macOS 15.4, iOS 26.0, *)
    func loadFailureRecreatesOnceAndRecovers() async throws {
        let harness = Harness(memorySamples: [4_000_000_000])
        harness.factory.scheduleMakeError { makeIndex in
            makeIndex == 1
                ? LocalInferenceError.modelLoadFailedWithReason(
                    "MLX container initialization failed (domain MLX.MLXError, code 0). "
                        + "Verify the model snapshot and device memory, then retry."
                )
                : nil
        }
        let result = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "second turn",
            images: [], tools: [], maxTokens: 32
        )
        #expect(result.text == "synthetic answer")
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.loadFailureCount == 1)
        #expect(lifecycle.loadRecoveredCount == 1)
    }

    @Test("A persistent load failure surfaces and the runtime still recovers on the next turn")
    @available(macOS 15.4, iOS 26.0, *)
    func persistentLoadFailureThenRecovery() async throws {
        let harness = Harness(memorySamples: [4_000_000_000, 4_000_000_000])
        let failing = Locked(true)
        harness.factory.scheduleMakeError { _ in
            failing.value
                ? LocalInferenceError.modelLoadFailedWithReason(
                    "MLX container initialization failed (domain MLX.MLXError, code 0)."
                )
                : nil
        }
        await #expect(throws: LocalInferenceError.self) {
            try await harness.runtime.completeMeasured(
                modelID: modelID, instructions: "i", prompt: "turn one",
                images: [], tools: [], maxTokens: 32
            )
        }
        var lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.loadFailureCount == 2)
        #expect(lifecycle.loadRecoveredCount == 0)
        let failedState = await harness.runtime.currentLoadState()
        if case .failed = failedState {} else {
            Issue.record("Expected failed load state, got \(failedState)")
        }
        failing.value = false
        let result = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn two",
            images: [], tools: [], maxTokens: 32
        )
        #expect(result.text == "synthetic answer")
        lifecycle = await harness.runtime.lifecycleDiagnostics()
        // Turn 2's load succeeds on its first attempt, so no "recovered"
        // counter fires; the earlier failures stay recorded.
        #expect(lifecycle.loadFailureCount == 2)
        #expect(lifecycle.loadRecoveredCount == 0)
        #expect(lifecycle.consecutiveFailureCount == 0)
    }

    // MARK: 6. Single-container ownership across model switches

    @Test("Switching resident models never keeps two containers alive")
    @available(macOS 15.4, iOS 26.0, *)
    func modelSwitchKeepsSingleContainer() async throws {
        // A second *selectable* MLX entry distinct from `modelID`: Gemma 4 E4B
        // moved to the retired list (its snapshot cannot be admitted on an
        // M4-class allowance), and retired entries are intentionally not
        // routable, so the switch uses the other live Qwen snapshot.
        let otherID = "qwen3.5-4b-mlx4"
        let harness = Harness(memorySamples: [8_000_000_000])
        let factory = harness.factory
        let runtime = LocalModelRuntime(
            store: LocalModelStore(root: harness.snapshotRoot),
            makeEngine: { _, includesVisionProjector, _, _ in
                try factory.makeWithPossibleFailure(includesVisionProjector: includesVisionProjector)
            },
            measureAvailableMemory: { harness.memory.next() },
            modelSnapshot: { id in
                let directory = harness.snapshotRoot.appendingPathComponent(id, isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return (directory: directory, weightBytes: 3_034_299_183)
            },
            preflightSettleSamples: 3,
            preflightSettleInterval: .milliseconds(1)
        )
        for (index, id) in [modelID, otherID, modelID].enumerated() {
            let result = try await runtime.completeMeasured(
                modelID: id, instructions: "i", prompt: "turn \(index + 1)",
                images: [], tools: [], maxTokens: 32
            )
            #expect(result.text == "synthetic answer")
        }
        #expect(factory.created.count == 3)
        #expect(factory.maxLive == 1)
        // Switching unloads the previous container immediately; the final
        // engine stays resident for the Build 222 idle window and an explicit
        // unload releases it.
        #expect(factory.created[0].shutdownCount == 1)
        #expect(factory.created[1].shutdownCount == 1)
        #expect(factory.created[2].shutdownCount == 0)
        #expect(factory.liveCount == 1)
        await runtime.unload()
        #expect(factory.created[2].shutdownCount == 1)
        #expect(factory.liveCount == 0)
    }

    // MARK: 7. Recoverable on-device boundary events

    @Test("Local context overflow and memory rejection map onto bounded recovery events")
    @available(macOS 15.4, iOS 26.0, *)
    func recoverableBoundaryEvents() {
        let overflow = LocalProviderAdapter.recoverableBoundaryEvent(
            for: LocalInferenceError.promptTooLong
        )
        guard case .error(let overflowError)? = overflow else {
            Issue.record("Expected a context-overflow provider event, got \(String(describing: overflow))")
            return
        }
        #expect(overflowError.kind == .contextOverflow)
        #expect(overflowError.providerMessage.contains("not replayed"))

        let memory = LocalProviderAdapter.recoverableBoundaryEvent(
            for: LocalInferenceError.insufficientMemory(required: 3_000_000_000, physical: 1_200_000_000, reserved: 0)
        )
        guard case .error(let memoryError)? = memory else {
            Issue.record("Expected a retryable memory provider event, got \(String(describing: memory))")
            return
        }
        #expect(memoryError.kind == .rateLimited)

        // Everything else keeps the existing thrown boundary: decode
        // failures already had their own guarded recreate, and cancellation
        // or model-load failures are not silently retried here.
        #expect(LocalProviderAdapter.recoverableBoundaryEvent(
            for: LocalInferenceError.decodeFailed
        ) == nil)
        #expect(LocalProviderAdapter.recoverableBoundaryEvent(
            for: LocalInferenceError.modelLoadFailed
        ) == nil)
        #expect(LocalProviderAdapter.recoverableBoundaryEvent(
            for: CancellationError()
        ) == nil)
        #expect(LocalProviderAdapter.recoverableBoundaryEvent(
            for: FloeError.cancelled
        ) == nil)
    }

    @Test("A prepared-token overflow produces the same recoverable event shape")
    @available(macOS 15.4, iOS 26.0, *)
    func preAllocationOverflowEventShape() {
        let event = LocalProviderAdapter.contextOverflowEvent(
            estimatedTokens: 9_000,
            windowTokens: 7_168
        )
        guard case .error(let error) = event else {
            Issue.record("Expected a context-overflow event")
            return
        }
        #expect(error.kind == .contextOverflow)
        #expect(error.providerMessage.contains("9000"))
    }

    @Test("GDN-family prefill chunk is capped at the validated 32; other families keep their tier batch")
    @available(macOS 15.4, iOS 26.0, *)
    func gdnPrefillChunkCeiling() {
        let roomy = LocalInferenceResourceProfile(
            tier: .roomy, contextSize: 16_384, batchSize: 128,
            gpuLayers: 99, maximumOutputTokens: 1_536
        )
        let constrained = LocalInferenceResourceProfile(
            tier: .constrained, contextSize: 8_192, batchSize: 32,
            gpuLayers: 12, maximumOutputTokens: 1_024
        )
        for gdnID in ["qwen3.5-4b-mlx4", "qwen3.8-4b-heretic-mlx4", "qwen3.5-9b-q4km"] {
            let adjusted = LocalModelRuntime.adjustedProfile(for: gdnID, profile: roomy)
            #expect(adjusted.batchSize == 8, "\(gdnID) must cap the GDN prefill chunk")
            #expect(adjusted.contextSize == roomy.contextSize)
            #expect(adjusted.maximumOutputTokens == roomy.maximumOutputTokens)
            #expect(adjusted.tier == roomy.tier)
        }
        // Already-validated constrained values are untouched.
        #expect(LocalModelRuntime.adjustedProfile(for: "qwen3.5-4b-mlx4", profile: constrained).batchSize == 8)
        // Non-GDN families keep their tier batch.
        for otherID in ["gemma4-4b-mlx4", "llama3.2-3b-mlx4"] {
            #expect(LocalModelRuntime.adjustedProfile(for: otherID, profile: roomy).batchSize == 128)
        }
    }

    // MARK: 8. Unified load/benchmark/chat coordination

    @Test("A failing benchmark never unloads the engine a retained chat task is using")
    @available(macOS 15.4, iOS 26.0, *)
    func benchmarkFailureKeepsTaskRetainedEngine() async throws {
        let harness = Harness(memorySamples: [4_000_000_000, 4_000_000_000])
        // The chat task claims the model first. Its first turn has not run
        // yet — the benchmark reaches the runtime while the task is retained
        // and fails persistently mid-decode (first engine + one transparent
        // retry, both scripted to fail).
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: modelID)
        let failing: FakeEngine.Behavior = { _ in throw LocalInferenceError.decodeFailed }
        harness.factory.scheduleBehavior(failing, forMakeIndex: 1)
        harness.factory.scheduleBehavior(failing, forMakeIndex: 2)
        await #expect(throws: LocalInferenceError.self) {
            try await harness.runtime.benchmark(modelID: modelID)
        }
        // The benchmark's failure must NOT evict the mapping the retained chat
        // task is using: the retry engine stays live and the runtime reports
        // the engine as ready, not failed.
        #expect(harness.factory.created.count == 2)
        #expect(harness.factory.liveCount == 1)
        #expect(harness.factory.created[1].shutdownCount == 0)
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the task-retained engine to stay ready after the benchmark failure")
            return
        }
        // Once the durable task releases its claim, the normal idle window
        // owns the eventual unload; nothing was force-evicted by the benchmark.
        await harness.runtime.releaseForTask(taskID: taskID, reason: "taskFinished")
        #expect(harness.factory.created[1].shutdownCount == 0)
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.idleUnloadCount == 0)
        await harness.runtime.unload()
    }

    @Test("Concurrent load and benchmark on the same model share one container construction")
    @available(macOS 15.4, iOS 26.0, *)
    func concurrentPreloadAndBenchmarkShareSingleLoad() async throws {
        let harness = Harness(memorySamples: [4_000_000_000, 4_000_000_000])
        // 加载 racing 测速: both serialize on the inference slot and the second
        // reuses the resident engine — exactly one construction, never two
        // live containers.
        async let preload: Void = harness.runtime.preload(modelID: modelID)
        async let benchmark = harness.runtime.benchmark(modelID: modelID)
        let result = try await benchmark
        try await preload
        #expect(result.modelID == modelID)
        #expect(harness.factory.created.count == 1)
        #expect(harness.factory.maxLive == 1)
        #expect(harness.factory.created[0].shutdownCount == 0)
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.engineCreateCount == 1)
        #expect(lifecycle.engineReuseCount >= 1)
        await harness.runtime.unload()
        #expect(harness.factory.created[0].shutdownCount == 1)
    }

    @Test("The idle-resident release hook frees the engine only while it is unclaimed")
    @available(macOS 15.4, iOS 26.0, *)
    func releaseIdleResidentEngineOnlyWhenUnclaimed() async throws {
        let harness = Harness(memorySamples: [4_000_000_000])
        try await harness.runtime.preload(modelID: modelID)
        #expect(harness.factory.liveCount == 1)

        // A retained durable task blocks the release: Linux admission must
        // never steal a model a chat task is using.
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: modelID)
        let kept = await harness.runtime.releaseIdleResidentEngineIfUnclaimed(reason: "linuxAdmission")
        #expect(kept == nil)
        #expect(harness.factory.liveCount == 1)

        // With the claim released the hook physically frees the mapping, which
        // is what lets the Core arbiter admit a Linux guest on the reclaimed
        // memory instead of merely decrementing a session counter.
        await harness.runtime.releaseForTask(taskID: taskID, reason: "taskFinished")
        let released = await harness.runtime.releaseIdleResidentEngineIfUnclaimed(reason: "linuxAdmission")
        #expect(released == modelID)
        #expect(harness.factory.liveCount == 0)
        #expect(harness.factory.created[0].shutdownCount == 1)
        guard case .unloaded = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the runtime to be unloaded after the idle release")
            return
        }
    }

    @Test("A failed preload leaves the runtime retryable end to end")
    @available(macOS 15.4, iOS 26.0, *)
    func failedPreloadStaysRetryable() async throws {
        let harness = Harness(memorySamples: [4_000_000_000, 4_000_000_000])
        let failing = Locked(true)
        harness.factory.scheduleMakeError { _ in
            failing.value
                ? LocalInferenceError.modelLoadFailedWithReason(
                    "MLX container initialization failed (stage=container domain MLX.MLXError, code 0, no diagnostic)."
                )
                : nil
        }
        await #expect(throws: LocalInferenceError.self) {
            try await harness.runtime.preload(modelID: modelID)
        }
        guard case .failed = await harness.runtime.currentLoadState() else {
            Issue.record("Expected a failed load state after the preload failure")
            return
        }
        // No half-initialized engine leaked and the failure cleanup left the
        // runtime able to retry: the next preload succeeds.
        #expect(harness.factory.liveCount == 0)
        failing.value = false
        try await harness.runtime.preload(modelID: modelID)
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the retried preload to reach the ready state")
            return
        }
        #expect(harness.factory.created.count == 1)
        await harness.runtime.unload()
    }
}
