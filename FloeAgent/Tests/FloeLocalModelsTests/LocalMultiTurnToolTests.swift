// FloeLocalModelsTests — Build 222 multi-turn tool behavior.
//
// The Build 221 device reports and the supplied prompt tests showed:
//   * the runtime envelope and memory context were silently clipped away,
//   * a tool offered on turn 1 could disappear on turn 2/3 while its call and
//     result were still being replayed,
//   * the Qwen-family chat template received native tool schemas it cannot
//     render, which is what the tool-invocation crashes terminate in,
//   * one response could only ever yield a single tool call,
//   * models were unloaded the moment a turn ended instead of after the
//     accepted two-minute idle window.
//
// Every test below runs through the production adapter/runtime with a
// deterministic engine double; no weights are mapped and no real model is
// invoked.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

// MARK: - Deterministic engine doubles

/// Scripted engine that records exactly what the runtime handed to the chat
/// template (instructions, prompt, tools) so the bounded-protocol split is
/// directly observable.
private final class RecordingEngine: LocalModelTextEngine, @unchecked Sendable {
    typealias Behavior = @Sendable (RecordingEngine) throws -> LocalGenerationResult

    let includesVisionProjector: Bool
    private let behavior: Behavior
    private let lock = NSLock()
    private var _shutdownCount = 0
    private var _receivedTools: [ToolSchemaDescriptor] = []
    private var _receivedInstructions = ""
    private var _receivedPrompt = ""
    private var _generationCount = 0

    var shutdownCount: Int { lock.withLock { _shutdownCount } }
    var receivedTools: [ToolSchemaDescriptor] { lock.withLock { _receivedTools } }
    var receivedInstructions: String { lock.withLock { _receivedInstructions } }
    var receivedPrompt: String { lock.withLock { _receivedPrompt } }
    var generationCount: Int { lock.withLock { _generationCount } }

    static func text(_ value: String) -> Behavior {
        { _ in
            LocalGenerationResult(
                text: value,
                inputTokens: 12,
                outputTokens: 6,
                timeToFirstTokenMs: 4,
                generationDurationMs: 8
            )
        }
    }

    init(includesVisionProjector: Bool = false, behavior: @escaping Behavior) {
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
            _receivedInstructions = instructions
            _receivedPrompt = prompt
            _receivedTools = tools
            _generationCount += 1
        }
        return try behavior(self)
    }

    func shutdown() async {
        lock.withLock { _shutdownCount += 1 }
    }
}

/// Thread-safe flag for the arbiter closures, which are `@Sendable`.
private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class EngineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

// MARK: - Harness

@available(macOS 15.4, iOS 26.0, *)
private struct LocalRuntimeHarness {
    let root: URL
    let engine: RecordingEngine
    let created: EngineCounter
    let runtime: LocalModelRuntime
    let store: LocalModelStore

    init(
        engine: RecordingEngine,
        idleUnloadInterval: Duration = .seconds(120),
        arbiter: HeavyRuntimeArbiter = HeavyRuntimeArbiter()
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-b222-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.engine = engine
        let created = EngineCounter()
        self.created = created
        let modelRoot = root
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
            idleUnloadInterval: idleUnloadInterval,
            arbiter: arbiter
        )
        self.store = LocalModelStore(root: modelRoot)
    }

    func adapter() -> LocalProviderAdapter {
        LocalProviderAdapter(runtime: runtime, store: store)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@available(macOS 15.4, iOS 26.0, *)
private func localModel(
    remoteModelID: String,
    contextTokens: Int = 8_192
) -> ModelProfile {
    ModelProfile(
        providerID: LocalProviderAdapter.providerProfile.id,
        remoteModelID: remoteModelID,
        displayName: "Synthetic local",
        limits: .init(contextTokens: contextTokens, maxOutputTokens: 1_024),
        capabilities: [.text, .tools]
    )
}

private let readFileSchema = ToolSchemaDescriptor(
    name: "workspace.readFile",
    description: "Read a workspace file",
    parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#
)

private let localPythonSchema = ToolSchemaDescriptor(
    name: "exec.localPython",
    description: "Run a bounded local Python script",
    parametersJSON: #"{"type":"object","properties":{"script":{"type":"string"}}}"#
)

// MARK: - Multi-turn tool definition stability

@Suite("Local multi-turn tool stability")
struct LocalMultiTurnToolStabilityTests {
    @Test("A tool that already settled stays offered on later turns")
    @available(macOS 15.4, iOS 26.0, *)
    func settledToolSurvivesFollowingTurns() throws {
        let call = try ToolCall(
            id: "py-1",
            toolName: "exec.localPython",
            argumentsJSON: Data(#"{"script":"print(1)"}"#.utf8),
            scope: .local
        )
        let result = ToolResult(
            callID: "py-1",
            status: .ok,
            outputSummary: "1",
            outputDigest: "digest"
        )
        let base = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(remoteModelID: "qwen3.8-4b-heretic-mlx4"),
            messages: [
                (role: "system", content: "Run context: synthetic workspace."),
                (role: "user", content: "继续基于刚才的结果回答。")
            ],
            toolSchemas: [readFileSchema, localPythonSchema],
            allToolNames: [readFileSchema.name, localPythonSchema.name]
        )

        // Turn 1 established nothing: the follow-up text alone does not select
        // the Python tool.
        let withoutReplay = LocalProviderAdapter.buildPrompt(for: base)
        #expect(!withoutReplay.selectedTools.contains { $0.name == "exec.localPython" })

        // Turn 2/3 replay the settled pair: the exact definition stays offered
        // and the call/result association stays visible.
        let withReplay = LocalProviderAdapter.buildPrompt(
            for: ProviderStreamRequest(
                provider: base.provider,
                model: base.model,
                messages: base.messages,
                replayedToolPairs: [ReplayedToolPair(call: call, result: result)],
                toolSchemas: base.toolSchemas,
                allToolNames: base.allToolNames
            )
        )
        #expect(withReplay.selectedTools.contains { $0.name == "exec.localPython" })
        #expect(withReplay.text.contains("EARLIER TOOL CALL exec.localPython id=py-1"))
        #expect(withReplay.text.contains("EARLIER TOOL RESULT id=py-1"))
    }

    @Test("A failed receipt reaches the next turn as a failed status, not as success")
    @available(macOS 15.4, iOS 26.0, *)
    func failedReceiptStaysTruthful() throws {
        let call = try ToolCall(
            id: "py-2",
            toolName: "exec.localPython",
            argumentsJSON: Data(#"{"script":"raise SystemExit(3)"}"#.utf8),
            scope: .local
        )
        let result = ToolResult(
            callID: "py-2",
            status: .failed,
            outputSummary: "status=failed exitCode=3",
            outputDigest: "digest",
            exitStatus: 3
        )
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(remoteModelID: "qwen3.5-4b-mlx4"),
            messages: [
                (role: "system", content: "Run context: synthetic workspace."),
                (role: "user", content: "刚才的脚本为什么失败？")
            ],
            toolResults: [(callID: "py-2", output: result.outputSummary)],
            pendingToolCalls: [call],
            replayedToolPairs: [ReplayedToolPair(call: call, result: result)],
            toolSchemas: [localPythonSchema],
            allToolNames: [localPythonSchema.name]
        )
        let build = LocalProviderAdapter.buildPrompt(for: request)
        #expect(build.text.contains("TOOL RESULT py-2"))
        #expect(build.text.contains("status=failed"))
        #expect(build.systemInstructions.contains("TOOL RESULT with the same call id"))
    }
}

// MARK: - Qwen bounded protocol

@Suite("Local bounded tool protocol")
struct LocalBoundedToolProtocolTests {
    @Test("Qwen snapshots are identified as non-native; other MLX families are not")
    @available(macOS 15.4, iOS 26.0, *)
    func familyClassification() {
        #expect(!LocalProviderAdapter.usesNativeToolSchemas(modelRemoteID: "qwen3.5-4b-mlx4"))
        #expect(!LocalProviderAdapter.usesNativeToolSchemas(modelRemoteID: "qwen3.8-4b-heretic-mlx4"))
        #expect(!LocalProviderAdapter.usesNativeToolSchemas(modelRemoteID: "qwen3-next"))
        #expect(LocalProviderAdapter.usesNativeToolSchemas(modelRemoteID: "gemma4-e4b-mlx4"))
    }

    @Test("A Qwen prompt documents JSON calls and hands the template no schemas")
    @available(macOS 15.4, iOS 26.0, *)
    func qwenPromptUsesBoundedProtocol() throws {
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(remoteModelID: "qwen3.5-4b-mlx4"),
            messages: [
                (role: "system", content: "Run context: synthetic workspace."),
                (role: "user", content: "读取 a.md 并把结果告诉我。")
            ],
            toolSchemas: [readFileSchema],
            allToolNames: [readFileSchema.name]
        )
        let build = LocalProviderAdapter.buildPrompt(for: request)
        #expect(!build.usesNativeToolSchemas)
        #expect(build.nativeToolSchemas.isEmpty)
        #expect(!build.selectedTools.isEmpty)
        #expect(build.systemInstructions.contains(#"{"tool_call":{"name":"exact.offered.name","arguments":{}}}"#))
        #expect(build.systemInstructions.contains("one object per line"))
        #expect(!build.systemInstructions.lowercased().contains("use the native tool interface"))

        let gemma = LocalProviderAdapter.buildPrompt(
            for: ProviderStreamRequest(
                provider: request.provider,
                model: localModel(remoteModelID: "gemma4-e4b-mlx4"),
                messages: request.messages,
                toolSchemas: request.toolSchemas,
                allToolNames: request.allToolNames
            )
        )
        #expect(gemma.usesNativeToolSchemas)
        #expect(gemma.nativeToolSchemas.map(\.name) == gemma.selectedTools.map(\.name))
        #expect(!gemma.nativeToolSchemas.isEmpty)
    }

    @Test("The engine receives no native schemas for Qwen and native schemas for other MLX models")
    @available(macOS 15.4, iOS 26.0, *)
    func engineReceivesProtocolCompatibleSchemas() async throws {
        // The adapter decides the schema split; drive it through the real
        // stream so the assertion covers production wiring end to end. The
        // scripted response uses the documented JSON envelope, which is the
        // only tool channel the bounded Qwen path offers.
        let envelope = #"{"tool_call":{"name":"workspace.readFile","arguments":{"path":"a.md"}}}"#
        let qwenEngine = RecordingEngine(behavior: RecordingEngine.text(envelope))
        let qwenAdapterHarness = try LocalRuntimeHarness(engine: qwenEngine)
        defer { qwenAdapterHarness.cleanUp() }
        let qwenRequest = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(remoteModelID: "qwen3.5-4b-mlx4"),
            messages: [(role: "user", content: "读取 a.md 并告诉我内容。")],
            toolSchemas: [readFileSchema],
            allToolNames: [readFileSchema.name]
        )
        var qwenEvents: [AgentEvent] = []
        for try await event in qwenAdapterHarness.adapter().stream(
            request: qwenRequest,
            credentials: ProviderCredentials()
        ) {
            qwenEvents.append(event)
        }
        #expect(qwenEvents.contains { if case .completed = $0 { return true } else { return false } })
        #expect(qwenEvents.contains {
            if case .toolRequest(let call) = $0 { return call.toolName == "workspace.readFile" }
            return false
        })
        #expect(qwenEngine.receivedTools.isEmpty)
        #expect(qwenEngine.receivedInstructions.contains("TOOL RESULT with the same call id"))

        // Gemma 4 is retired from the selectable catalog (it cannot be
        // admitted on an M4-class allowance), so install it as the resident
        // engine to exercise the native-schema passthrough without real
        // weights. The runtime reuses a resident engine with a matching key.
        let gemmaEngine = RecordingEngine(behavior: RecordingEngine.text(envelope))
        let gemmaHarness = try LocalRuntimeHarness(engine: gemmaEngine)
        defer { gemmaHarness.cleanUp() }
        await gemmaHarness.runtime.installResidentEngineForTesting(
            gemmaEngine,
            modelID: "gemma4-e4b-mlx4",
            includesVisionProjector: false
        )
        let gemmaRequest = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(remoteModelID: "gemma4-e4b-mlx4"),
            messages: [(role: "user", content: "读取 a.md 并告诉我内容。")],
            toolSchemas: [readFileSchema],
            allToolNames: [readFileSchema.name]
        )
        var gemmaEvents: [AgentEvent] = []
        for try await event in gemmaHarness.adapter().stream(
            request: gemmaRequest,
            credentials: ProviderCredentials()
        ) {
            gemmaEvents.append(event)
        }
        #expect(gemmaEvents.contains { if case .completed = $0 { return true } else { return false } })
        #expect(gemmaEvents.contains {
            if case .toolRequest(let call) = $0 { return call.toolName == "workspace.readFile" }
            return false
        })
        #expect(gemmaEngine.receivedTools.map(\.name) == ["workspace.readFile"])
    }
}

// MARK: - Multiple sequential tool calls in one turn

@Suite("Local sequential tool calls")
struct LocalSequentialToolCallsTests {
    @Test("The parser accepts one object, a JSON array and one object per line")
    @available(macOS 15.4, iOS 26.0, *)
    func parserAcceptsEveryBoundedForm() throws {
        let offered: Set<String> = ["workspace.readFile", "web.fetch"]
        let single = try LocalProviderAdapter.toolCalls(
            from: #"{"tool_call":{"name":"workspace.readFile","arguments":{"path":"a.md"}}}"#,
            offeredToolNames: offered
        )
        #expect(single.count == 1)

        let array = try LocalProviderAdapter.toolCalls(
            from: #"[{"tool_call":{"name":"workspace.readFile","arguments":{"path":"a.md"}}},{"tool_call":{"name":"web.fetch","arguments":{"url":"https://example.com"}}}]"#,
            offeredToolNames: offered
        )
        #expect(array.map(\.toolName) == ["workspace.readFile", "web.fetch"])

        let lines = try LocalProviderAdapter.toolCalls(
            from: """
            {"tool_call":{"name":"workspace.readFile","arguments":{"path":"a.md"}}}
            {"tool_call":{"name":"web.fetch","arguments":{"url":"https://example.com"}}}
            """,
            offeredToolNames: offered
        )
        #expect(lines.map(\.toolName) == ["workspace.readFile", "web.fetch"])
    }

    @Test("Sequential calls are capped and unknown names are dropped")
    @available(macOS 15.4, iOS 26.0, *)
    func parserIsBounded() throws {
        let offered: Set<String> = ["workspace.readFile"]
        var lines: [String] = []
        for index in 0..<8 {
            lines.append(#"{"tool_call":{"name":"workspace.readFile","arguments":{"path":"\#(index).md"}}}"#)
        }
        let capped = try LocalProviderAdapter.toolCalls(
            from: lines.joined(separator: "\n"),
            offeredToolNames: offered
        )
        #expect(capped.count == LocalProviderAdapter.maximumSequentialToolCalls)

        let unknown = try LocalProviderAdapter.toolCalls(
            from: """
            {"tool_call":{"name":"not.offered","arguments":{}}}
            {"tool_call":{"name":"workspace.readFile","arguments":{"path":"a.md"}}}
            """,
            offeredToolNames: offered
        )
        #expect(unknown.map(\.toolName) == ["workspace.readFile"])
    }

    @Test("One response emits every sequential call before the tool-use completion")
    @available(macOS 15.4, iOS 26.0, *)
    func streamEmitsSequentialRequests() async throws {
        let engine = RecordingEngine(behavior: RecordingEngine.text("""
        {"tool_call":{"name":"workspace.readFile","arguments":{"path":"a.md"}}}
        {"tool_call":{"name":"workspace.readFile","arguments":{"path":"b.md"}}}
        """))
        let harness = try LocalRuntimeHarness(engine: engine)
        defer { harness.cleanUp() }
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(remoteModelID: "qwen3.5-4b-mlx4"),
            messages: [(role: "user", content: "读取 a.md 和 b.md 并对比。")],
            toolSchemas: [readFileSchema],
            allToolNames: [readFileSchema.name]
        )
        var events: [AgentEvent] = []
        for try await event in harness.adapter().stream(
            request: request,
            credentials: ProviderCredentials()
        ) {
            events.append(event)
        }
        let toolRequests = events.compactMap { event -> ToolCall? in
            if case .toolRequest(let call) = event { return call }
            return nil
        }
        #expect(toolRequests.count == 2)
        #expect(toolRequests.map(\.toolName) == ["workspace.readFile", "workspace.readFile"])
        #expect(Set(toolRequests.map(\.id)).count == 2)
        let completions = events.compactMap { event -> AgentEvent.StopReason? in
            if case .completed(let completion) = event { return completion.stopReason }
            return nil
        }
        #expect(completions == [.toolUse])
        #expect(engine.receivedPrompt.contains("读取 a.md 和 b.md"))
    }
}

// MARK: - Idle unload

@Suite("Local model idle unload")
struct LocalModelIdleUnloadTests {
    @Test("A finished turn keeps the engine and the idle timer unloads it later")
    @available(macOS 15.4, iOS 26.0, *)
    func idleWindowUnloadsEngine() async throws {
        let engine = RecordingEngine(behavior: RecordingEngine.text("synthetic answer"))
        let harness = try LocalRuntimeHarness(
            engine: engine,
            idleUnloadInterval: .milliseconds(150)
        )
        defer { harness.cleanUp() }
        _ = try await harness.runtime.completeMeasured(
            modelID: "qwen3.5-4b-mlx4",
            instructions: "bounded",
            prompt: "hello",
            images: [],
            tools: [],
            maxTokens: 32
        )
        // The turn no longer tears the mapping down immediately.
        #expect(engine.shutdownCount == 0)
        guard case .ready = await harness.runtime.currentLoadState() else {
            Issue.record("Expected the engine to stay resident right after a turn")
            return
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.shutdownCount == 1)
        #expect(await harness.runtime.currentLoadState() == .unloaded)
        #expect(await harness.runtime.lifecycleDiagnostics().idleUnloadCount == 1)
    }

    @Test("A message inside the idle window cancels the pending unload and reuses the engine")
    @available(macOS 15.4, iOS 26.0, *)
    func activityCancelsIdleUnload() async throws {
        let engine = RecordingEngine(behavior: RecordingEngine.text("synthetic answer"))
        let harness = try LocalRuntimeHarness(
            engine: engine,
            idleUnloadInterval: .milliseconds(250)
        )
        defer { harness.cleanUp() }
        for _ in 0..<2 {
            _ = try await harness.runtime.completeMeasured(
                modelID: "qwen3.5-4b-mlx4",
                instructions: "bounded",
                prompt: "hello",
                images: [],
                tools: [],
                maxTokens: 32
            )
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(harness.created.value == 1)
        #expect(engine.shutdownCount == 0)
        #expect(engine.generationCount == 2)
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.shutdownCount == 1)
    }

    @Test("An explicit unload releases the engine before the idle window")
    @available(macOS 15.4, iOS 26.0, *)
    func explicitUnloadIsImmediate() async throws {
        let engine = RecordingEngine(behavior: RecordingEngine.text("synthetic answer"))
        let harness = try LocalRuntimeHarness(
            engine: engine,
            idleUnloadInterval: .seconds(120)
        )
        defer { harness.cleanUp() }
        _ = try await harness.runtime.completeMeasured(
            modelID: "qwen3.5-4b-mlx4",
            instructions: "bounded",
            prompt: "hello",
            images: [],
            tools: [],
            maxTokens: 32
        )
        await harness.runtime.unload()
        #expect(engine.shutdownCount == 1)
        #expect(await harness.runtime.currentLoadState() == .unloaded)
        // The cancelled timer must not shut the same engine down twice.
        #expect(await harness.runtime.lifecycleDiagnostics().idleUnloadCount == 0)
    }
}

// MARK: - Heavy-runtime arbitration through the runtime

@Suite("Local heavy-runtime admission")
struct LocalHeavyRuntimeAdmissionTests {
    @Test("A declined Linux conflict fails before any engine is created")
    @available(macOS 15.4, iOS 26.0, *)
    func declinedConflictDoesNotLoad() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let stopped = TestFlag()
        arbiter.configure(
            activityProbe: {
                HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ["env-1"])
            },
            guestStopper: { _ in stopped.set() },
            decisionHandler: { _ in .deferLocalModel }
        )
        let engine = RecordingEngine(behavior: RecordingEngine.text("should not run"))
        let harness = try LocalRuntimeHarness(engine: engine, arbiter: arbiter)
        defer { harness.cleanUp() }

        do {
            _ = try await harness.runtime.completeMeasured(
                modelID: "qwen3.5-4b-mlx4",
                instructions: "bounded",
                prompt: "hello",
                images: [],
                tools: [],
                maxTokens: 32
            )
            Issue.record("A declined conflict must not start local inference")
        } catch let error as FloeError {
            #expect(error.localizedDescription.contains("Linux"))
        }
        #expect(harness.created.value == 0)
        #expect(engine.generationCount == 0)
        #expect(!stopped.isSet)
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("A confirmed conflict stops the guest and then runs locally")
    @available(macOS 15.4, iOS 26.0, *)
    func confirmedConflictStopsThenRuns() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let stopped = TestFlag()
        arbiter.configure(
            activityProbe: {
                stopped.isSet
                    ? HeavyRuntimeArbiter.LinuxActivity()
                    : HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ["env-9"])
            },
            guestStopper: { activity in
                #expect(activity.guestEnvironmentIDs == ["env-9"])
                stopped.set()
            },
            decisionHandler: { _ in .stopGuestsAndProceed },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(200)
        )
        let engine = RecordingEngine(behavior: RecordingEngine.text("synthetic answer"))
        let harness = try LocalRuntimeHarness(engine: engine, arbiter: arbiter)
        defer { harness.cleanUp() }

        let completion = try await harness.runtime.completeMeasured(
            modelID: "qwen3.5-4b-mlx4",
            instructions: "bounded",
            prompt: "hello",
            images: [],
            tools: [],
            maxTokens: 32
        )
        #expect(completion.text == "synthetic answer")
        #expect(stopped.isSet)
        #expect(arbiter.stoppedGuestCount == 1)
        #expect(!arbiter.isLocalInferenceActive)
    }
}
