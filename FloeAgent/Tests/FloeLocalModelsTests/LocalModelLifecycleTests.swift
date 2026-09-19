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

    /// Scripted on-device engine. Records shutdown and the exact inputs so
    /// vision retention and ownership are directly observable.
    private final class FakeEngine: LocalModelTextEngine, @unchecked Sendable {
        typealias Behavior = @Sendable (FakeEngine) throws -> LocalGenerationResult
        let includesVisionProjector: Bool
        let behavior: Behavior
        private let lock = NSLock()
        private var _shutdownCount = 0
        private var _receivedImages: [Data] = []
        var shutdownCount: Int { lock.withLock { _shutdownCount } }
        var receivedImages: [Data] { lock.withLock { _receivedImages } }

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
            lock.withLock { _receivedImages = images }
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
        // Turn 1: load -> generate -> unload.
        let first = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn one",
            images: [], tools: [], maxTokens: 32
        )
        #expect(first.text == "synthetic answer")
        #expect(harness.factory.created.count == 1)
        #expect(harness.factory.created[0].shutdownCount == 1)
        #expect(harness.factory.liveCount == 0)
        #expect(await harness.runtime.currentLoadState() == .unloaded)
        // Turn 2 (text-only continuation): reloads the same pinned snapshot,
        // never two containers at once, and receives zero image bytes.
        let second = try await harness.runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn two",
            images: [], tools: [], maxTokens: 32
        )
        #expect(second.text == "synthetic answer")
        #expect(harness.factory.created.count == 2)
        #expect(harness.factory.maxLive == 1)
        #expect(harness.factory.created[1].receivedImages.isEmpty)
        #expect(harness.factory.created[1].includesVisionProjector == false)
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.engineCreateCount == 2)
        #expect(lifecycle.engineShutdownCount == 2)
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
        #expect(await harness.runtime.currentLoadState() == .unloaded)
        let lifecycle = await harness.runtime.lifecycleDiagnostics()
        #expect(lifecycle.decodeRetryCount == 1)
        #expect(lifecycle.consecutiveFailureCount == 0)
    }

    @Test("A persistent decode failure surfaces one error and the next turn recovers")
    @available(macOS 15.4, iOS 26.0, *)
    func persistentDecodeFailureThenRecovery() async throws {
        let harness = Harness(memorySamples: [4_000_000_000, 4_000_000_000])
        let failing = Locked(true)
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
        // Schedule the persistent decode failure on both the first engine and
        // the retry engine; the flag flips the behavior for later makes.
        let decodeFailure: FakeEngine.Behavior = { engine in
            if failing.value { throw LocalInferenceError.decodeFailed }
            return try FakeEngine.success(text: "clean retry")(engine)
        }
        factory.scheduleBehavior(decodeFailure, forMakeIndex: 1)
        factory.scheduleBehavior(decodeFailure, forMakeIndex: 2)
        factory.scheduleBehavior(decodeFailure, forMakeIndex: 3)
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
        // The runtime is not permanently broken: with the engine healthy and
        // memory recovered, the next turn loads and finishes cleanly.
        failing.value = false
        let result = try await runtime.completeMeasured(
            modelID: modelID, instructions: "i", prompt: "turn two",
            images: [], tools: [], maxTokens: 32
        )
        #expect(result.text == "clean retry")
        #expect(await runtime.currentLoadState() == .unloaded)
        lifecycle = await runtime.lifecycleDiagnostics()
        #expect(lifecycle.consecutiveFailureCount == 0)
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
            guard case .insufficientMemory(let required, let physical) = error else {
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
        let otherID = "gemma4-e4b-mlx4"
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
        #expect(factory.liveCount == 0)
        for engine in factory.created {
            #expect(engine.shutdownCount == 1)
        }
    }
}
