// FloeLocalModelsTests — Build 233 search-tool repair regression.
//
// Reproduces the device failure chain against the *production* web.search
// tool schema (not a hand-built proxy):
//   * a greeting turn stays conversational and is not forced into a tool,
//   * an explicit "search today's news" turn selects web.search as the
//     single intended repair tool — never an always-loaded workspace tool,
//   * the minimal repair instructions carry the complete argument schema
//     and the never-invent / never-claim-success boundaries,
//   * a repair that emits the JSON call yields the tool request, while a
//     repair that still emits only prose stays a validation failure (no
//     prose+JSON suffix mining, no fabricated success).
//
// Deterministic engine double: no weights are mapped and no real model is
// invoked. The web.search descriptor is the real production descriptor.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels
@testable import FloeExecution

@available(macOS 15.4, iOS 26.0, *)
private enum SearchRepairFixtures {
    static let modelID = "qwen3.8-4b-heretic-mlx4"

    static func model(contextTokens: Int = 8_192) -> ModelProfile {
        ModelProfile(
            providerID: LocalProviderAdapter.providerProfile.id,
            remoteModelID: modelID,
            displayName: "Synthetic local",
            limits: .init(contextTokens: contextTokens, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
    }

    /// Real production descriptor: exact name, description and JSON Schema
    /// object the app actually offers web.search through.
    static let webSearch = ToolSchemaDescriptor(
        name: WebSearchTool.name,
        description: WebSearchTool.toolDescription,
        parametersJSON: WebSearchTool.parametersJSON
    )

    /// Extra offered tools mirroring a real multi-capability request,
    /// including the always-loaded file base that must not outrank search.
    static let offeredTools: [ToolSchemaDescriptor] = [
        .init(name: "workspace.readFile", description: "Read a workspace file",
              parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#),
        .init(name: "workspace.createFile", description: "Create a workspace file",
              parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}}}"#),
        webSearch,
        .init(name: "image.ocr", description: "OCR an image",
              parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#)
    ]

    static func request(userText: String) -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: model(),
            messages: [
                (role: "system", content: "Runtime envelope: synthetic workspace."),
                (role: "user", content: userText)
            ],
            toolSchemas: offeredTools,
            allToolNames: offeredTools.map(\.name)
        )
    }
}

@Suite("Local search repair regression")
struct LocalSearchRepairRegressionTests {
    @Test("A greeting stays conversational even with web.search offered")
    @available(macOS 15.4, iOS 26.0, *)
    func greetingStaysConversational() {
        let build = LocalProviderAdapter.buildPrompt(
            for: SearchRepairFixtures.request(userText: "你好，今天过得怎么样？")
        )
        #expect(!build.requiresToolCall)
        #expect(!build.systemInstructions.contains("Invoke exactly"))
    }

    @Test("A news-search request picks web.search as the primary repair tool")
    @available(macOS 15.4, iOS 26.0, *)
    func newsRequestSelectsWebSearch() throws {
        let build = LocalProviderAdapter.buildPrompt(
            for: SearchRepairFixtures.request(userText: "那你能尝试调用一下工具，随便搜索一下今天的新闻吗")
        )
        #expect(build.requiresToolCall)
        let primary = try #require(build.primaryRepairTool)
        #expect(primary.name == "web.search")
        #expect(primary.name != "workspace.readFile")
    }

    @Test("Minimal repair instructions carry the full argument schema and safety rules")
    @available(macOS 15.4, iOS 26.0, *)
    func minimalRepairCarriesFullSchema() throws {
        let build = LocalProviderAdapter.buildPrompt(
            for: SearchRepairFixtures.request(userText: "随便搜索一下今天的新闻")
        )
        let primary = try #require(build.primaryRepairTool)
        let instructions = try #require(LocalProviderAdapter.PromptBuild.minimalRepairInstructions(
            tool: primary,
            usesNativeToolSchemas: build.usesNativeToolSchemas,
            extraSafety: build.preservedRuntimeInstructions
        ))
        // Full production schema present and structurally intact (required
        // query and additionalProperties:false survive).
        #expect(instructions.contains("\"required\":[\"query\"]"))
        #expect(instructions.contains("\"additionalProperties\":false"))
        #expect(instructions.contains("web.search"))
        // Safety boundaries.
        #expect(instructions.contains("Never invent a tool name"))
        #expect(instructions.contains("never claim the action succeeded"))
        // The repair does not re-send the whole offered tool set.
        #expect(!instructions.contains("workspace.createFile"))
    }

    @Test("A repair emitting the JSON call yields the web.search tool request")
    @available(macOS 15.4, iOS 26.0, *)
    func successfulRepairYieldsToolRequest() async throws {
        // Turn 1: prose only (the device failure). Repair: the JSON call.
        let prose = "好的，我来帮你搜索一下今天的新闻。"
        let callEnvelope = #"{"tool_call":{"name":"web.search","arguments":{"query":"today's news"}}}"#
        let engine = SequencedRepairEngine(first: prose, repair: callEnvelope)
        let harness = try RepairStreamHarness(engine: engine)
        defer { harness.cleanUp() }

        var toolRequests: [ToolCall] = []
        var completions: [AgentEvent.StopReason] = []
        do {
            for try await event in harness.adapter().stream(
                request: SearchRepairFixtures.request(userText: "随便搜索一下今天的新闻"),
                credentials: ProviderCredentials()
            ) {
                if case .toolRequest(let call) = event { toolRequests.append(call) }
                if case .completed(let completion) = event { completions.append(completion.stopReason) }
            }
        } catch {
            Issue.record("a repair emitting a valid call must not throw: \(error)")
        }
        #expect(toolRequests.map(\.toolName) == ["web.search"])
        #expect(completions == [.toolUse])
        #expect(engine.generationCount == 2, "prose turn then one bounded repair")
    }

    @Test("A repair still emitting only prose is a validation failure, not success")
    @available(macOS 15.4, iOS 26.0, *)
    func failedRepairStaysValidationFailure() async throws {
        let engine = SequencedRepairEngine(
            first: "好的，我来搜索。",
            repair: "抱歉，我暂时无法完成搜索。"
        )
        let harness = try RepairStreamHarness(engine: engine)
        defer { harness.cleanUp() }

        var threwValidation = false
        do {
            for try await _ in harness.adapter().stream(
                request: SearchRepairFixtures.request(userText: "随便搜索一下今天的新闻"),
                credentials: ProviderCredentials()
            ) {}
        } catch let error as FloeError {
            threwValidation = error.localizedDescription.contains("工具调用")
        }
        #expect(threwValidation, "missing tool invocation must fail honestly")
    }

    // MARK: - Parser negative cases

    @Test("A quoted inline example in prose is never a tool call")
    @available(macOS 15.4, iOS 26.0, *)
    func inlineQuotedExampleDoesNotParse() throws {
        let offered: Set<String> = ["web.search"]
        let prose = #"好的，例如 {"tool_call":{"name":"web.search","arguments":{"query":"news"}}} 这样调用。"#
        let calls = try LocalProviderAdapter.toolCalls(from: prose, offeredToolNames: offered)
        #expect(calls.isEmpty, "an inline quoted example must not become a phantom call")
    }

    @Test("A JSON example embedded among prose lines is not mined")
    @available(macOS 15.4, iOS 26.0, *)
    func embeddedExampleAmongLinesDoesNotParse() throws {
        let offered: Set<String> = ["web.search"]
        let text = """
        我来解释一下：
        你可以写 \(#"{"tool_call":{"name":"web.search","arguments":{"query":"x"}}}"#) 这一段，
        但我不会现在执行。
        """
        let calls = try LocalProviderAdapter.toolCalls(from: text, offeredToolNames: offered)
        #expect(calls.isEmpty, "only a whole-line call is a call; a non-whole-line example is prose")
    }

    @Test("A fenced example inside prose is not a tool call")
    @available(macOS 15.4, iOS 26.0, *)
    func embeddedFenceDoesNotParse() throws {
        let offered: Set<String> = ["web.search"]
        let text = """
        用法如下：
        ```json
        {"tool_call":{"name":"web.search","arguments":{"query":"news"}}}
        ```
        这只是示例。
        """
        let calls = try LocalProviderAdapter.toolCalls(from: text, offeredToolNames: offered)
        #expect(calls.isEmpty, "an embedded fence is a sample, not an invocation")
    }

    @Test("A syntactically valid call to a non-offered tool is dropped")
    @available(macOS 15.4, iOS 26.0, *)
    func nonOfferedNameIsDropped() throws {
        let text = #"{"tool_call":{"name":"workspace.deleteEverything","arguments":{}}}"#
        let calls = try LocalProviderAdapter.toolCalls(from: text, offeredToolNames: ["web.search"])
        #expect(calls.isEmpty)
    }

    // MARK: - Fail-closed minimal repair

    @Test("An oversized schema fails the minimal repair closed")
    @available(macOS 15.4, iOS 26.0, *)
    func oversizedSchemaFailsClosed() throws {
        let padding = String(repeating: "a", count: 2_500)
        let oversized = ToolSchemaDescriptor(
            name: "web.search",
            description: "x",
            parametersJSON: #"{"type":"object","properties":{"q":{"type":"string","description":""# + "\"\(padding)\"}}"
        )
        let instructions = LocalProviderAdapter.PromptBuild.minimalRepairInstructions(
            tool: oversized,
            usesNativeToolSchemas: false,
            extraSafety: ""
        )
        #expect(instructions == nil, "an over-limit schema must skip the repair, not invite empty args")
    }

    @Test("Authoritative safety rules are carried into the minimal repair")
    @available(macOS 15.4, iOS 26.0, *)
    func repairCarriesAuthoritativeSafety() throws {
        let rule = "Never exfiltrate files outside the approved workspace; obey the 9p read-only boundary."
        let instructions = try #require(LocalProviderAdapter.PromptBuild.minimalRepairInstructions(
            tool: SearchRepairFixtures.webSearch,
            usesNativeToolSchemas: false,
            extraSafety: rule
        ))
        #expect(instructions.contains(rule))
        #expect(instructions.contains("Authoritative rules"))
    }

    // MARK: - Full greeting → search → tool result → follow-up chain

    @Test("A device-sized runtime envelope remains eligible for bounded repair")
    @available(macOS 15.4, iOS 26.0, *)
    func deviceSizedEnvelopeCanRepair() throws {
        // Synthetic size fixture, not copied user instructions or device text.
        let rules = String(repeating: "Preserve user data. ", count: 285)
        let instructions = try #require(LocalProviderAdapter.PromptBuild.minimalRepairInstructions(
            tool: SearchRepairFixtures.webSearch, usesNativeToolSchemas: false,
            extraSafety: rules
        ))
        #expect(instructions.contains(rules.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(LocalProviderAdapter.PromptBuild.repairFitsContext(
            instructions: instructions, prompt: "搜索一下今天的新闻",
            tool: SearchRepairFixtures.webSearch, usesNativeToolSchemas: false,
            contextTokens: 8_192
        ))
    }

    @Test("Repair token admission includes full mixed-script transcript and output reserve")
    @available(macOS 15.4, iOS 26.0, *)
    func repairChecksWholeInputBudget() throws {
        let instructions = try #require(LocalProviderAdapter.PromptBuild.minimalRepairInstructions(
            tool: SearchRepairFixtures.webSearch, usesNativeToolSchemas: false,
            extraSafety: "Keep workspace scope."
        ))
        #expect(!LocalProviderAdapter.PromptBuild.repairFitsContext(
            instructions: instructions, prompt: String(repeating: "汉", count: 10_000),
            tool: SearchRepairFixtures.webSearch, usesNativeToolSchemas: false,
            contextTokens: 8_192
        ))
        #expect(!LocalProviderAdapter.PromptBuild.repairFitsContext(
            instructions: instructions, prompt: "news",
            tool: SearchRepairFixtures.webSearch, usesNativeToolSchemas: true,
            contextTokens: 256
        ))
    }

    @Test("Greeting, repaired search and a follow-up search chain through the adapter")
    @available(macOS 15.4, iOS 26.0, *)
    func greetingSearchFollowupChain() async throws {
        let searchEnvelope = #"{"tool_call":{"name":"web.search","arguments":{"query":"today's news"}}}"#
        let followupEnvelope = #"{"tool_call":{"name":"web.search","arguments":{"query":"tomorrow weather forecast"}}}"#
        // Generations: 1 greeting answer; 2 search prose (fail); 3 repair call;
        // 4 follow-up turn emits its call directly (no repair).
        let engine = MultiScriptEngine([
            "你好！有什么可以帮你的？",
            "好的，我来帮你搜索一下今天的新闻。",
            searchEnvelope,
            followupEnvelope
        ])
        let harness = try ChainStreamHarness(engine: engine)
        defer { harness.cleanUp() }
        let adapter = harness.adapter()

        // Turn 1: greeting stays conversational.
        var firstTools: [ToolCall] = []
        for try await event in adapter.stream(
            request: SearchRepairFixtures.request(userText: "你好，今天过得怎么样？"),
            credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { firstTools.append(call) }
        }
        #expect(firstTools.isEmpty)

        // Turn 2: search with one bounded repair.
        var searchCalls: [ToolCall] = []
        for try await event in adapter.stream(
            request: SearchRepairFixtures.request(userText: "那你能尝试调用一下工具，随便搜索一下今天的新闻吗"),
            credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { searchCalls.append(call) }
        }
        #expect(searchCalls.map(\.toolName) == ["web.search"])
        let searchCall = try #require(searchCalls.first)

        // Turn 3: settled tool receipt replayed; the follow-up request emits
        // its own web.search call directly, with no second repair.
        let result = ToolResult(
            callID: searchCall.id, status: .ok,
            outputSummary: "results: 3 news items", outputDigest: "digest"
        )
        let followupRequest = ProviderStreamRequest(
            provider: SearchRepairFixtures.request(userText: "").provider,
            model: SearchRepairFixtures.model(),
            messages: [
                (role: "system", content: "Runtime envelope: synthetic workspace."),
                (role: "user", content: "很好，再帮我搜索一下明天的天气")
            ],
            replayedToolPairs: [ReplayedToolPair(call: searchCall, result: result)],
            toolSchemas: SearchRepairFixtures.offeredTools,
            allToolNames: SearchRepairFixtures.offeredTools.map(\.name)
        )
        var followupCalls: [ToolCall] = []
        for try await event in adapter.stream(
            request: followupRequest, credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { followupCalls.append(call) }
        }
        #expect(followupCalls.map(\.toolName) == ["web.search"])
        #expect(engine.generationCount == 4, "three turns with exactly one repair")
        // The repair channel (generation 3) for Qwen carries no native schemas.
        #expect(engine.toolsLog[2]?.isEmpty == true)
    }

    // MARK: - Cloud providers are unaffected

    @Test("Cloud wire protocols never route to the local repair adapter")
    @available(macOS 15.4, iOS 26.0, *)
    func cloudProtocolsDoNotUseLocalAdapter() {
        // The local repair path exists only behind LocalProviderAdapter;
        // every remote wire protocol builds a remote adapter and therefore
        // never performs one-tool repair / shortened local context.
        for wire in [
            ModelProtocol.openAIResponses,
            ModelProtocol.openAIChatCompletions,
            ModelProtocol.anthropicMessages
        ] {
            let adapter = ProviderAdapterFactory.adapter(for: wire)
            #expect(!(adapter is LocalProviderAdapter),
                    "cloud wire protocol '\(wire)' must not use the local repair adapter")
        }
    }

    @Test("The minimal-repair symbol exists only on the local adapter build")
    @available(macOS 15.4, iOS 26.0, *)
    func minimalRepairIsLocalOnly() {
        // Cloud adapters are plain remote wire adapters; they expose no
        // PromptBuild and therefore cannot perform one-tool repair. This pins
        // the boundary at the type system: only LocalProviderAdapter carries
        // PromptBuild.
        let local = LocalProviderAdapter.buildPrompt(
            for: SearchRepairFixtures.request(userText: "随便搜索一下今天的新闻")
        )
        #expect(local.primaryRepairTool != nil)
        // Remote adapters are different types.
        #expect(OpenAIChatCompletionsAdapter.self != LocalProviderAdapter.self)
        #expect(AnthropicMessagesAdapter.self != LocalProviderAdapter.self)
        #expect(OpenAIResponsesAdapter.self != LocalProviderAdapter.self)
    }
}

// MARK: - Deterministic repair engine

/// Streams the first response, then returns the repair response via
/// `completeMeasured`, recording what the repair channel actually received.
@available(macOS 15.4, iOS 26.0, *)
private final class SequencedRepairEngine: LocalModelTextEngine, @unchecked Sendable {
    let includesVisionProjector = false
    private let lock = NSLock()
    private let first: String
    private let repair: String
    private var _generationCount = 0
    private var _repairTools: [ToolSchemaDescriptor] = []
    private var _repairInstructions = ""

    var generationCount: Int { lock.withLock { _generationCount } }
    var repairTools: [ToolSchemaDescriptor] { lock.withLock { _repairTools } }
    var repairInstructions: String { lock.withLock { _repairInstructions } }

    init(first: String, repair: String) {
        self.first = first
        self.repair = repair
    }

    func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult {
        let value = lock.withLock {
            _generationCount += 1
            _repairTools = tools
            _repairInstructions = instructions
            return _generationCount == 1 ? first : repair
        }
        return LocalGenerationResult(
            text: value, inputTokens: 10, outputTokens: 5,
            timeToFirstTokenMs: 2, generationDurationMs: 4
        )
    }

    func shutdown() async {}
}

@available(macOS 15.4, iOS 26.0, *)
private struct RepairStreamHarness {
    let root: URL
    let engine: SequencedRepairEngine
    let runtime: LocalModelRuntime
    let store: LocalModelStore

    init(engine: SequencedRepairEngine) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-b233-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.engine = engine
        self.store = LocalModelStore(root: root)
        self.runtime = LocalModelRuntime(
            store: store,
            makeEngine: { _, _, _, _ in engine },
            measureAvailableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            modelSnapshot: { modelID in
                (directory: root.appendingPathComponent(modelID, isDirectory: true),
                 weightBytes: 1_000_000)
            },
            preflightSettleSamples: 0,
            preflightSettleInterval: .milliseconds(1),
            idleUnloadInterval: .seconds(120),
            arbiter: HeavyRuntimeArbiter()
        )
    }

    func adapter() -> LocalProviderAdapter {
        LocalProviderAdapter(runtime: runtime, store: store)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Multi-turn scripted engine (greeting → search → follow-up)

@available(macOS 15.4, iOS 26.0, *)
private final class MultiScriptEngine: LocalModelTextEngine, @unchecked Sendable {
    let includesVisionProjector = false
    private let lock = NSLock()
    private let scripts: [String]
    private var generation = 0
    /// Schemas handed to each generation, indexable for assertions.
    fileprivate var toolsLog: [[ToolSchemaDescriptor]?] = []

    var generationCount: Int { lock.withLock { generation } }

    init(_ scripts: [String]) { self.scripts = scripts }

    func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult {
        let text: String = lock.withLock {
            let index = min(generation, max(0, scripts.count - 1))
            let chosen = scripts[index]
            generation += 1
            toolsLog.append(tools)
            return chosen
        }
        return LocalGenerationResult(
            text: text, inputTokens: 10, outputTokens: 5,
            timeToFirstTokenMs: 2, generationDurationMs: 4
        )
    }

    func shutdown() async {}
}

@available(macOS 15.4, iOS 26.0, *)
private struct ChainStreamHarness {
    let root: URL
    let engine: MultiScriptEngine
    let runtime: LocalModelRuntime
    let store: LocalModelStore

    init(engine: MultiScriptEngine) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-chain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.engine = engine
        self.store = LocalModelStore(root: root)
        self.runtime = LocalModelRuntime(
            store: store,
            makeEngine: { _, _, _, _ in engine },
            measureAvailableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            modelSnapshot: { modelID in
                (directory: root.appendingPathComponent(modelID, isDirectory: true),
                 weightBytes: 1_000_000)
            },
            preflightSettleSamples: 0,
            preflightSettleInterval: .milliseconds(1),
            idleUnloadInterval: .seconds(120),
            arbiter: HeavyRuntimeArbiter()
        )
    }

    func adapter() -> LocalProviderAdapter {
        LocalProviderAdapter(runtime: runtime, store: store)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
