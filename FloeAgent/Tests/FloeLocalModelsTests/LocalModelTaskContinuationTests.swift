// FloeLocalModelsTests — F3 local-model → Linux tool → local-model
// continuation through the REAL arbiter.
//
// F2 (`LocalModelLinuxYieldTests`) covers the Linux-demand direction with an
// EMPTY activity probe: a guest start yields an idle resident engine. F3
// covers the reverse, real end-to-end direction that the app actually hits:
//
//   the local run executes a Linux tool (exec.shell), the tool's guest stays
//   running, and the run's next generation must re-acquire the heavy runtime.
//   The production probe is NONEMPTY there, and the guest is the run's own
//   verified transient tool guest — so the arbiter releases it for the run
//   without a user decision, and only then may the model map weights.
//
// These tests drive the real `LocalModelRuntime` with a deterministic engine
// double (no weights) and a real `HeavyRuntimeArbiter` wired through the
// `ownerRunID` production parameter. The registry-side facts and the real
// flush/stop lifecycle are covered by FloeExecutionTests
// (LinuxGuestTransientOwnershipTests) with the real registry; here the probe
// and the release effect are scripted so the runtime/adapter half is pinned.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModels

// MARK: - deterministic doubles

@available(macOS 15.4, iOS 26.0, *)
private final class ContinuationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool = false) { self.value = value }
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
    func clear() { lock.withLock { value = false } }
}

private final class ContinuationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class ContinuationOrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) { lock.withLock { items.append(item) } }
    var events: [String] { lock.withLock { items } }
}

/// Async gate so a release can be parked deterministically while the test
/// cancels the waiting generation.
private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

/// Records every prompt the runtime handed to the engine (the tool context
/// must survive the release) and when the generation ran.
@available(macOS 15.4, iOS 26.0, *)
private final class ContinuationEngine: LocalModelTextEngine, @unchecked Sendable {
    let includesVisionProjector = false
    private let order: ContinuationOrderLog
    private let lock = NSLock()
    private var _generationCount = 0
    private var _prompts: [String] = []
    private var _shutdownCount = 0

    init(order: ContinuationOrderLog) { self.order = order }

    var generationCount: Int { lock.withLock { _generationCount } }
    var prompts: [String] { lock.withLock { _prompts } }
    var shutdownCount: Int { lock.withLock { _shutdownCount } }

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
            _prompts.append(prompt)
        }
        order.append("generate:\(generationCount)")
        return LocalGenerationResult(
            text: "synthetic answer",
            inputTokens: 12,
            outputTokens: 6,
            timeToFirstTokenMs: 4,
            generationDurationMs: 8
        )
    }

    func shutdown() async {
        lock.withLock { _shutdownCount += 1 }
    }
}

// MARK: - harness

@available(macOS 15.4, iOS 26.0, *)
private struct ContinuationHarness {
    let root: URL
    let runtime: LocalModelRuntime
    let store: LocalModelStore
    let engine: ContinuationEngine
    let arbiter: HeavyRuntimeArbiter
    let order: ContinuationOrderLog
    let decisions: ContinuationCounter
    let created: ContinuationCounter

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-f3-continuation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let order = ContinuationOrderLog()
        let engine = ContinuationEngine(order: order)
        let created = ContinuationCounter()
        let arbiter = HeavyRuntimeArbiter()
        let modelRoot = root
        self.root = root
        self.engine = engine
        self.order = order
        self.decisions = ContinuationCounter()
        self.created = created
        self.arbiter = arbiter
        self.store = LocalModelStore(root: modelRoot)
        self.runtime = LocalModelRuntime(
            store: LocalModelStore(root: modelRoot),
            makeEngine: { _, _, _, _ in
                created.increment()
                return engine
            },
            measureAvailableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            modelSnapshot: { modelID in
                (directory: modelRoot.appendingPathComponent(modelID, isDirectory: true),
                 weightBytes: 1_000_000)
            },
            preflightSettleSamples: 0,
            preflightSettleInterval: .milliseconds(1),
            idleUnloadInterval: .seconds(120),
            arbiter: arbiter
        )
    }

    /// The production wiring shape: a nonempty probe over one environment,
    /// the unconditional guest stopper (only after a user decision), and the
    /// scoped own-transient releaser.
    func installArbiterWiring(
        runID: UUID,
        environmentID: String = "env-1",
        guestUp: ContinuationFlag,
        releaseGate: ContinuationGate? = nil
    ) {
        let arbiter = self.arbiter
        let order = self.order
        let decisions = self.decisions
        arbiter.configure(
            activityProbe: {
                guard guestUp.isSet else { return HeavyRuntimeArbiter.LinuxActivity() }
                return HeavyRuntimeArbiter.LinuxActivity(
                    guestEnvironmentIDs: [environmentID],
                    guests: [HeavyRuntimeArbiter.LinuxGuestActivity(
                        environmentID: environmentID,
                        ownerRunID: runID.uuidString,
                        isTransientToolGuest: true
                    )]
                )
            },
            guestStopper: { _ in
                order.append("confirmedStop")
                guestUp.clear()
            },
            decisionHandler: { _ in
                decisions.increment()
                return .deferLocalModel
            },
            transientGuestReleaser: { activity in
                order.append("release:\(activity.guestEnvironmentIDs.joined(separator: ","))")
                if let releaseGate { await releaseGate.wait() }
                guestUp.clear()
            },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(400)
        )
    }

    func generate(runID: UUID?, prompt: String) async throws -> LocalRuntimeCompletion {
        try await runtime.completeMeasured(
            modelID: continuationModelID,
            instructions: "bounded",
            prompt: prompt,
            images: [],
            tools: [],
            maxTokens: 32,
            ownerRunID: runID
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private let continuationModelID = "qwen3.8-4b-heretic-mlx4"

@available(macOS 15.4, iOS 26.0, *)
private func continuationModel(remoteModelID: String = continuationModelID) -> ModelProfile {
    ModelProfile(
        providerID: LocalProviderAdapter.providerProfile.id,
        remoteModelID: remoteModelID,
        displayName: "Synthetic local",
        limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
        capabilities: [.text, .tools]
    )
}

private func waitUntilFlag(
    timeout: Duration = .seconds(3),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: - tests

@Suite("Local run Linux tool continuation")
struct LocalModelTaskContinuationTests {
    /// The acceptance path: generation 1, then the run's own Linux tool guest
    /// is up, then generation 2 releases that guest without a user decision
    /// and only then generates — with the durable claim and the settled tool
    /// context intact.
    @Test("A local run's own transient Linux tool guest is released for its continuation")
    @available(macOS 15.4, iOS 26.0, *)
    func ownGuestIsReleasedForContinuation() async throws {
        let harness = try ContinuationHarness()
        defer { harness.cleanUp() }
        let runID = UUID()
        let guestUp = ContinuationFlag(false)
        harness.installArbiterWiring(runID: runID, guestUp: guestUp)
        await harness.runtime.retainForTask(taskID: runID, modelID: continuationModelID)

        let first = try await harness.generate(runID: runID, prompt: "gen-1 workspace listing")
        #expect(first.text == "synthetic answer")

        // The run's exec.shell started the environment's guest; the tool
        // result is settled and the guest stays up (registry behavior).
        guestUp.set()
        let second = try await harness.generate(
            runID: runID,
            prompt: "gen-2 <tool_result>total 4</tool_result> continue"
        )
        #expect(second.text == "synthetic answer")

        // No user decision; the guest was released BEFORE the continuation
        // generation ran; the logical claim and the tool context survive.
        #expect(harness.decisions.count == 0)
        #expect(harness.order.events == ["generate:1", "release:env-1", "generate:2"])
        #expect(harness.arbiter.autoReleaseAttemptCount == 1)
        #expect(harness.arbiter.autoReleasedGuestCount == 1)
        #expect(!guestUp.isSet)
        #expect(await harness.runtime.retainedTaskCount == 1)
        #expect(harness.engine.prompts.count == 2)
        #expect(harness.engine.prompts[1].contains("<tool_result>total 4</tool_result>"))
        // One engine served both generations: the release never lost the run.
        #expect(harness.created.count == 1)
        #expect(harness.engine.shutdownCount == 0)
    }

    /// Another run's (or the user's) guest is a REAL conflict: the explicit
    /// decision path runs, a declined answer fails truthfully, nothing is
    /// stopped or released, and no engine is mapped over the guest.
    @Test("A foreign guest keeps the explicit decision and the model is refused")
    @available(macOS 15.4, iOS 26.0, *)
    func foreignGuestStillDefersWithoutStopping() async throws {
        let harness = try ContinuationHarness()
        defer { harness.cleanUp() }
        let requestingRun = UUID()
        let otherRun = UUID()
        let guestUp = ContinuationFlag(true)
        // The probe reports another run's transient guest: same transient
        // facts, different owner.
        harness.arbiter.configure(
            activityProbe: {
                HeavyRuntimeArbiter.LinuxActivity(
                    guestEnvironmentIDs: ["env-other"],
                    guests: [HeavyRuntimeArbiter.LinuxGuestActivity(
                        environmentID: "env-other",
                        ownerRunID: otherRun.uuidString,
                        isTransientToolGuest: true
                    )]
                )
            },
            guestStopper: { _ in harness.order.append("confirmedStop") },
            decisionHandler: { _ in
                harness.decisions.increment()
                return .deferLocalModel
            },
            transientGuestReleaser: { _ in harness.order.append("release") },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(200)
        )
        await harness.runtime.retainForTask(taskID: requestingRun, modelID: continuationModelID)

        do {
            _ = try await harness.generate(runID: requestingRun, prompt: "gen-foreign")
            Issue.record("a foreign guest must defer the local request")
        } catch {
            // Truthful user-visible failure, not a silent overlap.
        }
        #expect(harness.decisions.count == 1)
        #expect(harness.order.events.isEmpty)
        #expect(harness.arbiter.autoReleaseAttemptCount == 0)
        #expect(harness.arbiter.autoReleasedGuestCount == 0)
        #expect(harness.created.count == 0)
        #expect(guestUp.isSet)
        // The durable claim is untouched by the refused generation.
        #expect(await harness.runtime.retainedTaskCount == 1)
        #expect(!harness.arbiter.isLocalInferenceActive)
    }

    /// Cancelling the continuation while its own release is in flight must not
    /// leak the heavy-runtime session or map an engine, and must leave the
    /// durable run recoverable.
    @Test("A cancelled continuation releases its arbiter session and stays recoverable")
    @available(macOS 15.4, iOS 26.0, *)
    func cancelledContinuationStaysRecoverable() async throws {
        let harness = try ContinuationHarness()
        defer { harness.cleanUp() }
        let runID = UUID()
        let guestUp = ContinuationFlag(true)
        let gate = ContinuationGate()
        harness.installArbiterWiring(runID: runID, guestUp: guestUp, releaseGate: gate)
        await harness.runtime.retainForTask(taskID: runID, modelID: continuationModelID)

        let task = Task {
            try await harness.generate(runID: runID, prompt: "gen-cancelled")
        }
        let order = harness.order
        let releaseStarted = await waitUntilFlag {
            order.events.contains("release:env-1")
        }
        #expect(releaseStarted)
        task.cancel()
        gate.open()
        do {
            _ = try await task.value
            Issue.record("a cancelled continuation must not complete normally")
        } catch {
            // expected: cancellation surfaces
        }
        // The session was released on the failure path and no engine mapped.
        #expect(!harness.arbiter.isLocalInferenceActive)
        #expect(harness.created.count == 0)
        #expect(await harness.runtime.retainedTaskCount == 1)
        // The guest was released before the cancellation took effect, so the
        // run's next generation is clean and proceeds with no conflict.
        #expect(!guestUp.isSet)
        let recovered = try await harness.generate(runID: runID, prompt: "gen-recovered")
        #expect(recovered.text == "synthetic answer")
        #expect(harness.decisions.count == 0)
        #expect(harness.created.count == 1)
    }

    /// The provider adapter's `ownerRunID` is what makes the app's real
    /// generation path (adapter -> runtime -> arbiter) own its guest: the
    /// same request without a run id keeps the explicit decision.
    @Test("The provider adapter binds the logical run to the continuation")
    @available(macOS 15.4, iOS 26.0, *)
    func adapterBindsOwnerRunID() async throws {
        let harness = try ContinuationHarness()
        defer { harness.cleanUp() }
        let runID = UUID()
        let guestUp = ContinuationFlag(true)
        harness.installArbiterWiring(runID: runID, guestUp: guestUp)

        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: continuationModel(),
            messages: [(role: "user", content: "继续刚才的 Linux 工具结果")]
        )
        let boundAdapter = LocalProviderAdapter(
            runtime: harness.runtime, store: harness.store, ownerRunID: runID
        )
        var completed = false
        for try await event in boundAdapter.stream(request: request, credentials: ProviderCredentials()) {
            if case .completed = event { completed = true }
        }
        #expect(completed)
        #expect(harness.decisions.count == 0)
        #expect(harness.order.events == ["release:env-1", "generate:1"])
        #expect(!guestUp.isSet)
        #expect(harness.arbiter.autoReleasedGuestCount == 1)

        // Negative control: the same nonempty probe without a bound run id
        // must keep the explicit decision and refuse the generation.
        let unboundHarness = try ContinuationHarness()
        defer { unboundHarness.cleanUp() }
        let unboundGuest = ContinuationFlag(true)
        unboundHarness.installArbiterWiring(runID: runID, guestUp: unboundGuest)
        let unboundAdapter = LocalProviderAdapter(
            runtime: unboundHarness.runtime, store: unboundHarness.store
        )
        do {
            for try await _ in unboundAdapter.stream(request: request, credentials: ProviderCredentials()) {}
            Issue.record("an unbound generation must not be admitted over a guest")
        } catch {
            // expected: the arbiter defers because it cannot prove ownership
        }
        #expect(unboundHarness.decisions.count == 1)
        #expect(unboundHarness.order.events.isEmpty)
        #expect(unboundHarness.created.count == 0)
        #expect(unboundGuest.isSet)
    }
}
