// FloeLocalModelsTests — Build 230/231 adapter streaming and terminal states.
//
// Drives the production adapter + runtime through a deterministic engine
// double. No weights are mapped and no GPU work runs.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

// MARK: - Scripted engine double

@available(macOS 15.4, iOS 26.0, *)
private final class ScriptedStreamingEngine: LocalModelTextEngine, @unchecked Sendable {
    enum Step: Sendable {
        case progress(LocalInferenceProgress)
        case output(String)
        case sleepMilliseconds(Int)
        /// Blocks until the surrounding task is cancelled, records the
        /// cancellation, then throws `CancellationError`. Used to prove the
        /// no-progress supervisor cancels instead of releasing a container.
        case waitForCancellation
        /// Fails the generation with the retriable decode failure.
        case failDecode
    }

    let includesVisionProjector = false
    private let lock = NSLock()
    private var scripts: [[Step]]
    private var callIndex = 0
    private var _receivedPrompts: [String] = []
    private var _receivedInstructions: [String] = []
    private var _generationCount = 0
    private var _cancellationObserved = false
    private var _shutdownCount = 0
    private var _shutdownAfterCancellationObserved = false

    var receivedPrompts: [String] { lock.withLock { _receivedPrompts } }
    var receivedInstructions: [String] { lock.withLock { _receivedInstructions } }
    var generationCount: Int { lock.withLock { _generationCount } }
    var cancellationObserved: Bool { lock.withLock { _cancellationObserved } }
    var shutdownCount: Int { lock.withLock { _shutdownCount } }
    var shutdownAfterCancellationObserved: Bool {
        lock.withLock { _shutdownAfterCancellationObserved }
    }

    init(scripts: [[Step]]) {
        self.scripts = scripts
    }

    private func nextSteps() -> [Step] {
        lock.withLock {
            guard callIndex < scripts.count else { return [] }
            let steps = scripts[callIndex]
            callIndex += 1
            return steps
        }
    }

    private func recordCancellationObserved() {
        lock.withLock { _cancellationObserved = true }
    }

    private static func result(text: String) -> LocalGenerationResult {
        LocalGenerationResult(
            text: text,
            inputTokens: 16,
            outputTokens: max(1, text.count / 4),
            timeToFirstTokenMs: 3,
            generationDurationMs: 6
        )
    }

    func streamMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?,
        onProgress: @escaping @Sendable (LocalInferenceProgress) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> LocalGenerationResult {
        lock.withLock {
            _receivedPrompts.append(prompt)
            _receivedInstructions.append(instructions)
            _generationCount += 1
        }
        var text = ""
        for step in nextSteps() {
            switch step {
            case .progress(let progress):
                onProgress(progress)
            case .output(let chunk):
                if Task.isCancelled {
                    recordCancellationObserved()
                    throw CancellationError()
                }
                text += chunk
                onOutput(chunk)
            case .sleepMilliseconds(let milliseconds):
                do {
                    try await Task.sleep(for: .milliseconds(milliseconds))
                } catch {
                    recordCancellationObserved()
                    throw CancellationError()
                }
            case .waitForCancellation:
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    recordCancellationObserved()
                    throw CancellationError()
                }
            case .failDecode:
                throw LocalInferenceError.decodeFailed
            }
        }
        try Task.checkCancellation()
        return Self.result(text: text)
    }

    func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult {
        Self.result(text: "")
    }

    func shutdown() async {
        lock.withLock {
            _shutdownCount += 1
            _shutdownAfterCancellationObserved = _cancellationObserved
        }
    }
}

// MARK: - Harness

@available(macOS 15.4, iOS 26.0, *)
private struct StreamDeliveryHarness {
    let root: URL
    let engine: ScriptedStreamingEngine
    let runtime: LocalModelRuntime
    let store: LocalModelStore

    init(engine: ScriptedStreamingEngine, idleUnloadInterval: Duration = .seconds(120)) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-b231-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.engine = engine
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
            idleUnloadInterval: idleUnloadInterval,
            arbiter: HeavyRuntimeArbiter()
        )
        self.store = LocalModelStore(root: modelRoot)
    }

    func adapter(
        watchdogPolicy: LocalGenerationWatchdogPolicy = .disabled
    ) -> LocalProviderAdapter {
        LocalProviderAdapter(
            runtime: runtime,
            store: store,
            ownerRunID: nil,
            watchdogPolicy: watchdogPolicy
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@available(macOS 15.4, iOS 26.0, *)
private func deliveryModel(remoteModelID: String = "qwen3.5-4b-mlx4") -> ModelProfile {
    ModelProfile(
        providerID: LocalProviderAdapter.providerProfile.id,
        remoteModelID: remoteModelID,
        displayName: "Synthetic local",
        limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
        capabilities: [.text, .tools]
    )
}

private let deliveryReadFileSchema = ToolSchemaDescriptor(
    name: "workspace.readFile",
    description: "Read a workspace file",
    parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#
)

@available(macOS 15.4, iOS 26.0, *)
private func waitUntil(
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

    var toolRequests: [ToolCall] {
        compactMap { event -> ToolCall? in
            if case .toolRequest(let call) = event { return call }
            return nil
        }
    }

    var errorMessages: [String] {
        compactMap { event -> String? in
            if case .error(let error) = event { return error.providerMessage }
            return nil
        }
    }
}

// MARK: - Tests

@Suite("Local streamed delivery")
struct LocalStreamDeliveryTests {
    @Test("Prose reaches the caller before completion, exactly once")
    @available(macOS 15.4, iOS 26.0, *)
    func proseStreamsBeforeCompletion() async throws {
        let engine = ScriptedStreamingEngine(scripts: [[
            .progress(LocalInferenceProgress(stage: .preparing)),
            .progress(LocalInferenceProgress(stage: .prefill, prefilledTokens: 0, totalInputTokens: 128)),
            .output("你好"),
            .output("，世界"),
            .progress(LocalInferenceProgress(stage: .decoding, prefilledTokens: 128, totalInputTokens: 128, emittedChunks: 2))
        ]])
        let harness = try StreamDeliveryHarness(engine: engine)
        defer { harness.cleanUp() }
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: deliveryModel(),
            messages: [(role: "user", content: "打个招呼")],
            toolSchemas: [],
            allToolNames: []
        )
        var events: [AgentEvent] = []
        for try await event in harness.adapter().stream(
            request: request,
            credentials: ProviderCredentials()
        ) {
            events.append(event)
        }
        #expect(events.textDeltas == ["你好", "，世界"])
        #expect(events.stopReasons == [.endTurn])
        #expect(events.textDeltas.joined() == "你好，世界")
    }

    @Test("Cross-chunk think markup never reaches the visible stream")
    @available(macOS 15.4, iOS 26.0, *)
    func thinkMarkupNeverLeaks() async throws {
        let engine = ScriptedStreamingEngine(scripts: [[
            .output("<thi"),
            .output("nk>这是私有推理</think"),
            .output(">回复：好的")
        ]])
        let harness = try StreamDeliveryHarness(engine: engine)
        defer { harness.cleanUp() }
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: deliveryModel(),
            messages: [(role: "user", content: "回复我")],
            toolSchemas: [],
            allToolNames: []
        )
        var events: [AgentEvent] = []
        for try await event in harness.adapter().stream(
            request: request,
            credentials: ProviderCredentials()
        ) {
            events.append(event)
        }
        #expect(!events.textDeltas.joined().contains("私有推理"))
        #expect(events.textDeltas.joined() == "回复：好的")
        #expect(events.stopReasons == [.endTurn])
    }

    @Test("A tool envelope split across chunks yields a tool request and no prose")
    @available(macOS 15.4, iOS 26.0, *)
    func splitToolEnvelopeYieldsRequest() async throws {
        let engine = ScriptedStreamingEngine(scripts: [[
            .output(#"{"tool_call":{"name":"workspace.readFile","#),
            .output(#""arguments":{"path":"a.md"}}}"#)
        ]])
        let harness = try StreamDeliveryHarness(engine: engine)
        defer { harness.cleanUp() }
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: deliveryModel(),
            messages: [(role: "user", content: "读取 a.md")],
            toolSchemas: [deliveryReadFileSchema],
            allToolNames: [deliveryReadFileSchema.name]
        )
        var events: [AgentEvent] = []
        for try await event in harness.adapter().stream(
            request: request,
            credentials: ProviderCredentials()
        ) {
            events.append(event)
        }
        #expect(events.textDeltas.isEmpty)
        #expect(events.toolRequests.map(\.toolName) == ["workspace.readFile"])
        #expect(events.stopReasons == [.toolUse])
    }

    @Test("An empty generation ends as an explicit empty endTurn")
    @available(macOS 15.4, iOS 26.0, *)
    func emptyGenerationIsExplicit() async throws {
        let engine = ScriptedStreamingEngine(scripts: [[]])
        let harness = try StreamDeliveryHarness(engine: engine)
        defer { harness.cleanUp() }
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: deliveryModel(),
            messages: [(role: "user", content: "你好")],
            toolSchemas: [],
            allToolNames: []
        )
        var events: [AgentEvent] = []
        for try await event in harness.adapter().stream(
            request: request,
            credentials: ProviderCredentials()
        ) {
            events.append(event)
        }
        #expect(events.textDeltas.isEmpty)
        #expect(events.stopReasons == [.endTurn])
        let usage = events.compactMap { event -> AgentEvent.UsageReport? in
            if case .usage(let report) = event { return report }
            return nil
        }.first
        #expect(usage?.outputTokens == 1) // engine double's floor for empty text
    }

    @Test("A stalled generation ends with one explicit no-progress error and observes cancellation first")
    @available(macOS 15.4, iOS 26.0, *)
    func stalledGenerationEndsExplicitly() async throws {
        let engine = ScriptedStreamingEngine(scripts: [[
            .progress(LocalInferenceProgress(stage: .preparing)),
            .waitForCancellation
        ]])
        let harness = try StreamDeliveryHarness(engine: engine)
        defer { harness.cleanUp() }
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: deliveryModel(),
            messages: [(role: "user", content: "你好")],
            toolSchemas: [],
            allToolNames: []
        )
        let adapter = harness.adapter(watchdogPolicy: LocalGenerationWatchdogPolicy(
            firstActivitySeconds: 5,
            idleSeconds: 0.2,
            pollIntervalSeconds: 0.05
        ))
        var events: [AgentEvent] = []
        for try await event in adapter.stream(
            request: request,
            credentials: ProviderCredentials()
        ) {
            events.append(event)
        }
        #expect(events.errorMessages.count == 1)
        #expect(events.errorMessages.first?.contains("长时间没有输出") == true)
        #expect(events.textDeltas.isEmpty)
        let observed = await waitUntil { engine.cancellationObserved }
        #expect(observed)
        _ = await waitUntil(timeout: .seconds(2)) { engine.shutdownCount > 0 }
        if engine.shutdownCount > 0 {
            #expect(engine.shutdownAfterCancellationObserved)
        }
    }

    @Test("Consumer cancellation stays a cancellation and reaches the engine")
    @available(macOS 15.4, iOS 26.0, *)
    func consumerCancellationPropagates() async throws {
        let engine = ScriptedStreamingEngine(scripts: [[
            .progress(LocalInferenceProgress(stage: .preparing)),
            .waitForCancellation
        ]])
        let harness = try StreamDeliveryHarness(engine: engine)
        defer { harness.cleanUp() }
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: deliveryModel(),
            messages: [(role: "user", content: "你好")],
            toolSchemas: [],
            allToolNames: []
        )
        let adapter = harness.adapter()
        let consumer = Task { () -> Error? in
            do {
                for try await _ in adapter.stream(
                    request: request,
                    credentials: ProviderCredentials()
                ) {}
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(120))
        consumer.cancel()
        let error = await consumer.value
        // Cancellation may surface as a thrown CancellationError or as a
        // prompt stream end; either way it is never a composed failure and
        // the engine sees the cancellation before any teardown.
        #expect(error == nil || error is CancellationError)
        let observed = await waitUntil { engine.cancellationObserved }
        #expect(observed)
    }

    @Test("A two-turn tool flow keeps real receipts and returns non-empty answers")
    @available(macOS 15.4, iOS 26.0, *)
    func twoTurnToolFlow() async throws {
        let callEnvelope = #"{"tool_call":{"name":"workspace.readFile","arguments":{"path":"a.md"}}}"#
        let engine = ScriptedStreamingEngine(scripts: [
            [.output(callEnvelope)],
            [.output("a.md 的内容是 hello。")]
        ])
        let harness = try StreamDeliveryHarness(engine: engine)
        defer { harness.cleanUp() }

        let firstRequest = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: deliveryModel(),
            messages: [(role: "user", content: "读取 a.md 并告诉我内容。")],
            toolSchemas: [deliveryReadFileSchema],
            allToolNames: [deliveryReadFileSchema.name]
        )
        var firstEvents: [AgentEvent] = []
        for try await event in harness.adapter().stream(
            request: firstRequest,
            credentials: ProviderCredentials()
        ) {
            firstEvents.append(event)
        }
        let calls = firstEvents.toolRequests
        #expect(calls.count == 1)
        #expect(firstEvents.stopReasons == [.toolUse])
        guard let call = calls.first else { return }

        // The receipt is the settled tool result the harness would have
        // executed; the continuation turn must see it and answer visibly.
        let receipt = ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "hello",
            outputDigest: "digest"
        )
        let secondRequest = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: deliveryModel(),
            messages: [
                (role: "user", content: "读取 a.md 并告诉我内容。"),
                (role: "assistant", content: callEnvelope),
                (role: "user", content: "a.md 里是什么？")
            ],
            toolResults: [(callID: call.id, output: "hello")],
            pendingToolCalls: [call],
            replayedToolPairs: [ReplayedToolPair(call: call, result: receipt)],
            toolSchemas: [deliveryReadFileSchema],
            allToolNames: [deliveryReadFileSchema.name]
        )
        var secondEvents: [AgentEvent] = []
        for try await event in harness.adapter().stream(
            request: secondRequest,
            credentials: ProviderCredentials()
        ) {
            secondEvents.append(event)
        }
        #expect(!secondEvents.textDeltas.isEmpty)
        #expect(secondEvents.textDeltas.joined() == "a.md 的内容是 hello。")
        #expect(secondEvents.stopReasons == [.endTurn])
        #expect(engine.receivedPrompts.count == 2)
        #expect(engine.receivedPrompts[1].contains("hello"))
        // The continuation runs against the real bounded Qwen envelope (not a
        // minimal prompt): the tool protocol text and the settled receipt are
        // both present in what the engine actually received.
        #expect(engine.receivedInstructions[1].contains("TOOL RESULT with the same call id"))
        #expect(engine.receivedInstructions[1].contains("workspace.readFile"))
        #expect(engine.generationCount == 2)
    }

    @Test("A retriable decode failure retries once and then surfaces an explicit failure")
    @available(macOS 15.4, iOS 26.0, *)
    func decodeFailureSurfacesExplicitly() async throws {
        let engine = ScriptedStreamingEngine(scripts: [[.failDecode], [.failDecode]])
        let harness = try StreamDeliveryHarness(engine: engine)
        defer { harness.cleanUp() }
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: deliveryModel(),
            messages: [(role: "user", content: "你好")],
            toolSchemas: [],
            allToolNames: []
        )
        var events: [AgentEvent] = []
        var thrown: Error?
        do {
            for try await event in harness.adapter().stream(
                request: request,
                credentials: ProviderCredentials()
            ) {
                events.append(event)
            }
        } catch {
            thrown = error
        }
        #expect(thrown is LocalInferenceError)
        #expect(engine.generationCount == 2)
        #expect(events.textDeltas.isEmpty)
        #expect(events.stopReasons.isEmpty)
    }
}
