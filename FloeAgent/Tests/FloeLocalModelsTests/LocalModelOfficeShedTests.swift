// FloeLocalModelsTests — Build 233 R2 Office idle-memory shed.
//
// Office memory-heavy preparation (editable mount, Impress import) and system
// memory warnings may ask the local-model runtime to release an *idle*
// resident mapping before the engine and document import allocate. The
// release must be strictly narrower than the Linux demand:
//
//   * an active load/benchmark/generation owns the mapping — the shed must
//     answer immediately (never wait on the FIFO slot) and must not unload it;
//   * a durable run that still holds its logical claim must keep its mapping
//     (no silent cancellation of a tool continuation);
//   * only a genuinely idle mapping is unmapped, and the next generation
//     reloads the same pinned snapshot.
//
// These tests script the real runtime lifecycle with a deterministic engine
// double: no weights are mapped and no real model is invoked.

import Foundation
import Testing
import FloeCore
import FloeProviders
@testable import FloeLocalModels

@available(macOS 15.4, iOS 26.0, *)
private final class OfficeShedLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@available(macOS 15.4, iOS 26.0, *)
private final class OfficeShedEngine: LocalModelTextEngine, @unchecked Sendable {
    let includesVisionProjector = false
    private let lock = NSLock()
    private var _shutdownCount = 0
    private var _generationCount = 0

    var shutdownCount: Int { lock.withLock { _shutdownCount } }
    var generationCount: Int { lock.withLock { _generationCount } }

    func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult {
        lock.withLock { _generationCount += 1 }
        return LocalGenerationResult(
            text: "synthetic answer",
            inputTokens: 8,
            outputTokens: 4,
            timeToFirstTokenMs: 3,
            generationDurationMs: 6
        )
    }

    func shutdown() async {
        lock.withLock { _shutdownCount += 1 }
    }
}

/// Holds every container construction until the test releases the gate, so a
/// load can be observed while it owns the FIFO slot and a transient lease.
@available(macOS 15.4, iOS 26.0, *)
private actor OfficeShedGate {
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
private final class OfficeShedFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let gate: OfficeShedGate?
    private var engines: [OfficeShedEngine] = []

    init(gate: OfficeShedGate? = nil) { self.gate = gate }

    var liveCount: Int { lock.withLock { engines.filter { $0.shutdownCount == 0 }.count } }
    var created: [OfficeShedEngine] { lock.withLock { engines } }

    func make() async throws -> OfficeShedEngine {
        let engine = OfficeShedEngine()
        lock.withLock { engines.append(engine) }
        if let gate { await gate.markStartedAndWait() }
        return engine
    }
}

@available(macOS 15.4, iOS 26.0, *)
private struct OfficeShedHarness {
    let root: URL
    let runtime: LocalModelRuntime
    let factory: OfficeShedFactory

    init(gate: OfficeShedGate? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-shed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = OfficeShedFactory(gate: gate)
        let modelRoot = root
        self.root = root
        self.factory = factory
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
            idleUnloadInterval: .seconds(120),
            arbiter: HeavyRuntimeArbiter()
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private let officeShedModelID = "qwen3.8-4b-heretic-mlx4"

@available(macOS 15.4, iOS 26.0, *)
private func officeShedGenerate(_ harness: OfficeShedHarness) async throws {
    _ = try await harness.runtime.completeMeasured(
        modelID: officeShedModelID,
        instructions: "bounded",
        prompt: "user: hello",
        images: [],
        tools: [],
        maxTokens: 16
    )
}

/// Bounded poll so a regression surfaces as a failed expectation, never a
/// hung suite. The shed itself must not wait on the FIFO slot.
private func officeShedWait(timeout: Duration,
                            interval: Duration = .milliseconds(10),
                            _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

@Suite("Local model Office idle shed")
struct LocalModelOfficeShedTests {
    @Test("An idle resident mapping is released for Office and reloads on the next turn")
    @available(macOS 15.4, iOS 26.0, *)
    func idleMappingIsReleasedAndReloads() async throws {
        let harness = try OfficeShedHarness()
        defer { harness.cleanUp() }

        try await officeShedGenerate(harness)
        #expect(harness.factory.liveCount == 1)
        #expect(await harness.runtime.residentModelID() == officeShedModelID)

        let released = await harness.runtime.shedIdleResidentEngineForOffice(
            reason: "office.prepare.editable"
        )
        #expect(released == officeShedModelID)
        #expect(harness.factory.created[0].shutdownCount == 1)
        #expect(harness.factory.liveCount == 0)
        #expect(await harness.runtime.residentModelID() == nil)
        #expect(await harness.runtime.currentLoadState() == .unloaded)

        // The next local generation reloads the same pinned snapshot: exactly
        // one live container, never two, and the mapping is usable again.
        try await officeShedGenerate(harness)
        #expect(harness.factory.created.count == 2)
        #expect(harness.factory.liveCount == 1)
        #expect(await harness.runtime.residentModelID() == officeShedModelID)
    }

    @Test("A durable run's logical claim keeps its mapping until it releases")
    @available(macOS 15.4, iOS 26.0, *)
    func retainedRunKeepsMapping() async throws {
        let harness = try OfficeShedHarness()
        defer { harness.cleanUp() }
        let taskID = UUID()
        await harness.runtime.retainForTask(taskID: taskID, modelID: officeShedModelID)
        try await officeShedGenerate(harness)
        #expect(harness.factory.liveCount == 1)

        // Between generations the run still owns its logical claim: Office
        // must not steal the mapping a tool continuation depends on.
        let kept = await harness.runtime.shedIdleResidentEngineForOffice(reason: "office.prepare")
        #expect(kept == nil)
        #expect(harness.factory.liveCount == 1)
        #expect(await harness.runtime.residentModelID() == officeShedModelID)

        await harness.runtime.releaseForTask(taskID: taskID, reason: "testRelease")
        // Still the accepted idle window, not an immediate teardown.
        #expect(harness.factory.liveCount == 1)

        // Once the last claim is gone the same Office demand releases it.
        let released = await harness.runtime.shedIdleResidentEngineForOffice(reason: "office.memoryWarning")
        #expect(released == officeShedModelID)
        #expect(harness.factory.liveCount == 0)
    }

    @Test("An in-flight load answers immediately and is never unloaded")
    @available(macOS 15.4, iOS 26.0, *)
    func inflightOperationIsNotWaitedOn() async throws {
        let gate = OfficeShedGate()
        let harness = try OfficeShedHarness(gate: gate)
        defer { harness.cleanUp() }

        let load = Task { try await officeShedGenerate(harness) }
        await gate.waitUntilStarted()

        let outcome = OfficeShedLocked<String?>(nil)
        let finished = OfficeShedLocked(false)
        let shed = Task {
            let released = await harness.runtime.shedIdleResidentEngineForOffice(reason: "office.prepare")
            outcome.current = released
            finished.current = true
        }
        // The answer arrives while the load is still gated: a shed that waited
        // on the inference FIFO could only return after `gate.release()`.
        let answered = await officeShedWait(timeout: .seconds(3)) { finished.current }
        #expect(answered, "the Office shed must not block behind active inference")
        #expect(outcome.current == nil, "an in-flight operation keeps its mapping")
        #expect(harness.factory.liveCount == 1)

        await gate.release()
        try await load.value
        await shed.value
        // After the operation settles the mapping is still resident (the
        // refused shed changed nothing) and can be released on demand.
        #expect(harness.factory.liveCount == 1)
        let released = await harness.runtime.shedIdleResidentEngineForOffice(reason: "office.prepare")
        #expect(released == officeShedModelID)
    }
}
