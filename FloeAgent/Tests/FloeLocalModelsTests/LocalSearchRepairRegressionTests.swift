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
@testable import FloeAgentRuntime
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
        // web.search declares required ["query"], so the repair example is an
        // unparsable placeholder (candidate anti-copy shape, not confirmed
        // actual-weight evidence) and names the required key explicitly. A
        // zero-argument tool keeps its legitimate empty object instead.
        #expect(!instructions.contains(#""arguments":{}"#))
        #expect(instructions.contains("Required: query"))
        #expect(instructions.contains("values taken from the user request"))
        // The repair does not re-send the whole offered tool set.
        #expect(!instructions.contains("workspace.createFile"))
    }

    @Test("A zero-argument tool keeps its legitimate empty-arguments repair example")
    @available(macOS 15.4, iOS 26.0, *)
    func zeroArgumentToolRepairKeepsEmptyObject() throws {
        let zeroArgument = ToolSchemaDescriptor(
            name: "tools.list", description: "List offered tools",
            parametersJSON: #"{"type":"object","properties":{}}"#
        )
        let instructions = try #require(LocalProviderAdapter.PromptBuild.minimalRepairInstructions(
            tool: zeroArgument,
            usesNativeToolSchemas: false,
            extraSafety: "Synthetic rules."
        ))
        #expect(instructions.contains(#"{"tool_call":{"name":"tools.list","arguments":{}}}"#))
        #expect(instructions.contains("declares no required arguments"))
        #expect(!instructions.contains("Required:"))
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

    @Test("A fresh search receipt permits an answer while a new follow-up still requires a call")
    @available(macOS 15.4, iOS 26.0, *)
    func receiptDoesNotForceRepeatedAction() {
        var continuation = SearchRepairFixtures.request(userText: "搜索一下今天的新闻")
        continuation.toolResults = [(callID: "search-1", output: "Synthetic result: three news items.")]
        let receiptBuild = LocalProviderAdapter.buildPrompt(for: continuation)
        #expect(!receiptBuild.requiresToolCall)
        #expect(!receiptBuild.systemInstructions.contains("Emit the documented JSON tool_call object(s) now"))
        let followup = SearchRepairFixtures.request(userText: "再搜索一下明天的天气")
        #expect(LocalProviderAdapter.buildPrompt(for: followup).requiresToolCall)
    }

    // MARK: - Receipt grounding after a real tool invocation (Build 233 v7)

    /// Builds the exact continuation shape the v7 real-weight qualification
    /// sent after the model emitted its `web.search` call: production compact
    /// system envelope, the greeting/news transcript, the pending call and the
    /// synthetic receipt — without double-replaying the pending pair (the
    /// production runtime excludes pending pairs from `replayedToolPairs`).
    @available(macOS 15.4, iOS 26.0, *)
    private static func v7SearchContinuation() throws -> (
        build: LocalProviderAdapter.PromptBuild, call: ToolCall, marker: String
    ) {
        let marker = "FLOE_SEARCH_RECEIPT_7A31"
        let call = try ToolCall(
            id: "local-12876B6F-08E5-4260-8DA5-6311B67D9B1D",
            toolName: "web.search",
            argumentsJSON: Data(#"{"query":"今日新闻"}"#.utf8),
            scope: .local
        )
        let summary = "receipt marker: \(marker). synthetic fixture (no live search performed): 3 normalized results for query \"今日新闻\""
        let systemEnvelope = AgentPromptComposer.compose(
            mode: .chat,
            runtimeContext: "# Run context\nWorkspace: synthetic qualification workspace. Tool permissions are enforced by the host. After a tool result, answer from that result; repeat its receipt marker verbatim and identify synthetic results as synthetic.",
            toolsAvailable: true, compactForLocal: true
        )
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: SearchRepairFixtures.model(),
            messages: [
                (role: "system", content: systemEnvelope),
                (role: "user", content: "你好，今天过得怎么样？"),
                (role: "assistant", content: "你好！今天我过得挺充实的，谢谢关心。"),
                (role: "user", content: "那你能尝试调用一下工具，随便搜索一下今天的新闻吗")
            ],
            toolResults: [(callID: call.id, output: summary)],
            pendingToolCalls: [call],
            replayedToolPairs: [],
            toolSchemas: [SearchRepairFixtures.webSearch],
            allToolNames: [SearchRepairFixtures.webSearch.name]
        )
        return (LocalProviderAdapter.buildPrompt(for: request), call, marker)
    }

    @Test("The search receipt survives verbatim in the actual continuation prompt")
    @available(macOS 15.4, iOS 26.0, *)
    func searchReceiptSurvivesContinuationPrompt() throws {
        let rendered = try Self.v7SearchContinuation()
        // The TOOL RESULT line keeps the exact call id and marker body.
        #expect(rendered.build.text.contains(
            "TOOL RESULT \(rendered.call.id): receipt marker: \(rendered.marker)"))
        #expect(rendered.build.text.contains("synthetic fixture (no live search performed)"))
        #expect(rendered.build.text.contains(#"ASSISTANT TOOL REQUEST \#(rendered.call.id): web.search {"query":"今日新闻"}"#))
        // The production runtime grounding note is preserved in the system
        // envelope, and nothing flips the continuation back into a forced call.
        #expect(rendered.build.systemInstructions.contains("After a tool result, answer from that result"))
        #expect(!rendered.build.requiresToolCall)
        #expect(!rendered.build.exceedsContextWindow)
    }

    @Test("A pending receipt gets an explicit answer-now grounding directive after the evidence")
    @available(macOS 15.4, iOS 26.0, *)
    func pendingReceiptGetsGroundingDirective() throws {
        let rendered = try Self.v7SearchContinuation()
        let text = rendered.build.text
        // The harness directive closes the user-side prompt AFTER the TOOL
        // RESULT evidence, nearer generation than both the original search
        // imperative and the JSON-call protocol in the system envelope.
        #expect(text.contains("TOOL RESULT GROUNDING"))
        let resultIndex = try #require(text.range(of:
            "TOOL RESULT \(rendered.call.id): receipt marker: \(rendered.marker)"))
        let directiveIndex = try #require(text.range(of: "TOOL RESULT GROUNDING"))
        #expect(directiveIndex.lowerBound > resultIndex.upperBound)
        #expect(text.range(of: "TOOL RESULT GROUNDING")!.upperBound <= text.endIndex)
        // It forbids repeating the completed call and forbids fabricating
        // facts/results.
        #expect(text.contains("Do not repeat a completed call"))
        #expect(text.contains("only evidence returned"))
        #expect(text.contains("never invent facts"))
        #expect(text.contains("relevant conversation context"))
        #expect(text.contains("only when the user or runtime instructions require it"))
        // Receipts stay data: the directive never embeds a fixture marker or
        // a qualification-specific token of its own.
        let directive = String(text[directiveIndex.lowerBound...])
        #expect(!directive.contains("FLOE_"))
        // The system paragraph stops competing with the call protocol.
        #expect(rendered.build.systemInstructions.contains(
            "answer from that result now"))
    }

    @Test("Ordinary, fresh and replay-only turns never receive the grounding directive")
    @available(macOS 15.4, iOS 26.0, *)
    func nonContinuationTurnsHaveNoGroundingDirective() throws {
        // Plain greeting.
        let greeting = LocalProviderAdapter.buildPrompt(
            for: SearchRepairFixtures.request(userText: "你好，今天过得怎么样？"))
        #expect(!greeting.text.contains("TOOL RESULT GROUNDING"))
        #expect(!greeting.systemInstructions.contains("answer from that result now"))
        // Fresh user turn carrying only settled (replayed) history: no pending
        // receipt, so no continuation directive and the call protocol stays.
        let settledCall = try ToolCall(
            id: "settled-1", toolName: "web.search",
            argumentsJSON: Data(#"{"query":"news"}"#.utf8), scope: .local
        )
        let settled = ToolResult(callID: settledCall.id, status: .ok,
                                 outputSummary: "earlier result", outputDigest: "digest")
        let followup = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: SearchRepairFixtures.model(),
            messages: [
                (role: "system", content: "Runtime envelope: synthetic workspace."),
                (role: "user", content: "再搜索一下明天的天气")
            ],
            replayedToolPairs: [ReplayedToolPair(call: settledCall, result: settled)],
            toolSchemas: SearchRepairFixtures.offeredTools,
            allToolNames: SearchRepairFixtures.offeredTools.map(\.name)
        )
        let followupBuild = LocalProviderAdapter.buildPrompt(for: followup)
        #expect(!followupBuild.text.contains("TOOL RESULT GROUNDING"))
        #expect(!followupBuild.systemInstructions.contains("answer from that result now"))
        #expect(followupBuild.requiresToolCall, "a fresh request still requires its own call")
    }

    @Test("The grounding directive reaches the model through the streaming continuation path")
    @available(macOS 15.4, iOS 26.0, *)
    func groundingDirectiveReachesMLXPrompt() async throws {
        // A real continuation after the model's own web.search call. The
        // deterministic engine answers as a grounded model would (marker
        // repeated), and captures the exact system/user text the MLX path
        // receives. Nothing fabricates the answer: the engine script is the
        // stand-in for weights, and the assertions pin the evidence it saw.
        let marker = "FLOE_SEARCH_RECEIPT_7A31"
        let grounded = "根据搜索结果（\(marker)，synthetic fixture）：今日新闻的合成结果共 3 条。"
        let engine = CapturingContinuationEngine(answer: grounded)
        let harness = try RepairStreamHarness(engine: engine)
        defer { harness.cleanUp() }

        let call = try ToolCall(
            id: "local-cont-1", toolName: "web.search",
            argumentsJSON: Data(#"{"query":"今日新闻"}"#.utf8), scope: .local
        )
        let summary = "receipt marker: \(marker). synthetic fixture (no live search performed): 3 normalized results for query \"今日新闻\""
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: SearchRepairFixtures.model(),
            messages: [
                (role: "system", content: "Runtime envelope: synthetic workspace. After a tool result, answer from that result."),
                (role: "user", content: "随便搜索一下今天的新闻")
            ],
            toolResults: [(callID: call.id, output: summary)],
            pendingToolCalls: [call],
            replayedToolPairs: [],
            toolSchemas: SearchRepairFixtures.offeredTools,
            allToolNames: SearchRepairFixtures.offeredTools.map(\.name)
        )
        var answer = ""
        var furtherCalls: [ToolCall] = []
        for try await event in harness.adapter().stream(
            request: request, credentials: ProviderCredentials()
        ) {
            if case .textDelta(let delta) = event { answer += delta.text }
            if case .toolRequest(let newCall) = event { furtherCalls.append(newCall) }
        }
        #expect(answer.contains(marker))
        #expect(furtherCalls.isEmpty, "a receipt continuation must not request another tool")
        #expect(engine.generationCount == 1, "no bounded invocation repair on an answered continuation")
        let captured = try #require(engine.captured.last)
        #expect(captured.prompt.contains("TOOL RESULT \(call.id)"))
        #expect(captured.prompt.contains(marker))
        #expect(captured.prompt.contains("TOOL RESULT GROUNDING"))
        #expect(captured.prompt.range(of: marker)!.upperBound
                < captured.prompt.range(of: "TOOL RESULT GROUNDING")!.lowerBound)
        #expect(captured.instructions.contains("answer from that result now"))
        // Qwen bounded path: no native schemas on the continuation.
        #expect(engine.captured.last?.tools.isEmpty == true)
    }

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

    @Test("A copied generic protocol example is never accepted as a call")
    @available(macOS 15.4, iOS 26.0, *)
    func documentedProtocolExampleIsNotACall() throws {
        let build = LocalProviderAdapter.buildPrompt(
            for: SearchRepairFixtures.request(userText: "那你能尝试调用一下工具，随便搜索一下今天的新闻吗")
        )
        // The documented shape keeps the proven valid-JSON envelope for
        // successful calls, but its placeholder name is not an offered tool,
        // so echoing the example verbatim yields zero calls and the bounded
        // repair, never a phantom invocation.
        let documentedLine = try #require(
            build.systemInstructions
                .split(separator: "\n")
                .first { $0.contains("exact.offered.name") }
        )
        let copied = try LocalProviderAdapter.fallbackToolCalls(
            from: String(documentedLine),
            modelRemoteID: SearchRepairFixtures.modelID,
            selectedTools: SearchRepairFixtures.offeredTools
        )
        #expect(copied.isEmpty)
    }

    @Test("A well-formed call with empty arguments earns exactly one bounded repair")
    @available(macOS 15.4, iOS 26.0, *)
    func emptyArgumentsCallIsRepaired() async throws {
        // Suspected actual-weight first-turn shape: the model emits the
        // documented envelope with an unfilled arguments object.
        let emptyArguments = #"{"tool_call":{"name":"workspace.readFile","arguments":{}}}"#
        let repaired = #"{"tool_call":{"name":"workspace.readFile","arguments":{"path":"qualification-probe.txt"}}}"#
        let engine = SequencedRepairEngine(first: emptyArguments, repair: repaired)
        let harness = try RepairStreamHarness(engine: engine)
        defer { harness.cleanUp() }
        let readFile = ToolSchemaDescriptor(
            name: "workspace.readFile",
            description: "Read the UTF-8 text of one file in the current workspace",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
        )
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: SearchRepairFixtures.model(),
            messages: [
                (role: "system", content: "A workspace is available."),
                (role: "user", content: "Call workspace.readFile with path qualification-probe.txt.")
            ],
            toolSchemas: [readFile],
            allToolNames: [readFile.name]
        )
        var calls: [ToolCall] = []
        for try await event in harness.adapter().stream(
            request: request, credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { calls.append(call) }
        }
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.toolName == "workspace.readFile")
        #expect(String(decoding: call.argumentsJSON, as: UTF8.self).contains("qualification-probe.txt"))
        #expect(engine.generationCount == 2, "exactly one bounded repair")
        // The repair named the missing required key instead of a copyable
        // empty-arguments example.
        #expect(engine.repairInstructions.contains("Required: path"))
        #expect(!engine.repairInstructions.contains(#""arguments":{}"#))
    }

    @Test("An empty-arguments call whose repair stays prose is an honest failure")
    @available(macOS 15.4, iOS 26.0, *)
    func emptyArgumentsWithoutRepairFailsClosed() async throws {
        let emptyArguments = #"{"tool_call":{"name":"workspace.readFile","arguments":{}}}"#
        let engine = SequencedRepairEngine(first: emptyArguments, repair: "我无法读取该文件。")
        let harness = try RepairStreamHarness(engine: engine)
        defer { harness.cleanUp() }
        let readFile = ToolSchemaDescriptor(
            name: "workspace.readFile",
            description: "Read a workspace file",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
        )
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: SearchRepairFixtures.model(),
            messages: [(role: "user", content: "Call workspace.readFile with path a.txt.")],
            toolSchemas: [readFile],
            allToolNames: [readFile.name]
        )
        var calls: [ToolCall] = []
        var failed = false
        do {
            for try await event in harness.adapter().stream(
                request: request, credentials: ProviderCredentials()
            ) {
                if case .toolRequest(let call) = event { calls.append(call) }
            }
        } catch {
            failed = true
        }
        #expect(calls.isEmpty, "no phantom call is fabricated after the repair")
        #expect(failed, "a missing invocation must stay a validation failure")
        #expect(engine.generationCount == 2, "both scripted generations were consumed")
    }

    @Test("Required-argument admission covers empty, null and schema-free calls")
    @available(macOS 15.4, iOS 26.0, *)
    func requiredArgumentsAdmission() throws {
        let readFile = ToolSchemaDescriptor(
            name: "workspace.readFile",
            description: "Read a workspace file",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
        )
        let empty = try ToolCall(
            id: "empty", toolName: "workspace.readFile",
            argumentsJSON: Data("{}".utf8), scope: .local
        )
        let nullPath = try ToolCall(
            id: "null", toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":null}"#.utf8), scope: .local
        )
        let filled = try ToolCall(
            id: "filled", toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"a.txt"}"#.utf8), scope: .local
        )
        #expect(!LocalProviderAdapter.toolCallsSatisfyRequiredArguments([empty], offered: [readFile]))
        #expect(!LocalProviderAdapter.toolCallsSatisfyRequiredArguments([nullPath], offered: [readFile]))
        #expect(LocalProviderAdapter.toolCallsSatisfyRequiredArguments([filled], offered: [readFile]))
        // A call whose schema declares no required fields stays admissible.
        let bare = ToolSchemaDescriptor(name: "web.fetch", description: "Fetch")
        let bareCall = try ToolCall(
            id: "bare", toolName: "web.fetch",
            argumentsJSON: Data("{}".utf8), scope: .local
        )
        #expect(LocalProviderAdapter.toolCallsSatisfyRequiredArguments([bareCall], offered: [bare]))
        // Unknown schemas never invent a constraint.
        #expect(LocalProviderAdapter.toolCallsSatisfyRequiredArguments([empty], offered: []))
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

// MARK: - Capturing continuation engine

/// One-shot streaming engine for a tool-result continuation. It records the
/// exact system instructions, user prompt and schemas that reach the MLX
/// streaming boundary, then returns a scripted grounded answer. No weights are
/// involved; this pins the prompt representation, not model behaviour.
@available(macOS 15.4, iOS 26.0, *)
private final class CapturingContinuationEngine: LocalModelTextEngine, @unchecked Sendable {
    struct Capture: Sendable {
        let instructions: String
        let prompt: String
        let tools: [ToolSchemaDescriptor]
    }

    let includesVisionProjector = false
    private let lock = NSLock()
    private let answer: String
    private(set) var captured: [Capture] = []
    private(set) var generationCount = 0

    init(answer: String) {
        self.answer = answer
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
            generationCount += 1
            captured.append(Capture(instructions: instructions, prompt: prompt, tools: tools))
        }
        return LocalGenerationResult(
            text: answer, inputTokens: 12, outputTokens: 8,
            timeToFirstTokenMs: 2, generationDurationMs: 4
        )
    }

    func shutdown() async {}
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
    let engine: any LocalModelTextEngine
    let runtime: LocalModelRuntime
    let store: LocalModelStore

    init(engine: any LocalModelTextEngine) throws {
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
