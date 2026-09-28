// FloeLocalModelsTests — Build 233 explicit named-tool intent regression.
//
// Cloud real-weight run 36395580557 (source 5aa40e52) failed the second file
// turn: the first `workspace.readFile` call executed and its receipt was
// answered, then the new user message
//
//   "Now call workspace.readFile with path qualification-probe-2.txt.
//    Report its exact contents only after the tool responds."
//
// produced prose quoting the OLD receipt and NO second call. Root cause was
// intent classification: `requestsInventory` matched the bare substring
// "tool", while `requestsExplicitToolExecution` only recognized the fuzzy
// "call one / try one" phrasing — so a direct command that NAMED an offered
// tool was downgraded to a capability question, `requiresToolCall` stayed
// false, no bounded repair ran, and the stale prose answer was accepted.
//
// The tests pin:
//   * the exact cloud second-turn replay now requires and (through the one
//     bounded repair) obtains a real second invocation with the NEW path and
//     a new call id — the old receipt is never substituted for the new call,
//   * a direct Chinese named invocation ("现在调用 workspace.readFile …") is
//     an execution request even though the sentence mentions 工具,
//   * genuine capability questions stay informational,
//   * quoted examples, how-to questions and negations naming a tool never
//     force a call,
//   * a tool-result continuation still answers instead of repeating the
//     action,
//   * ordinary chat that merely mentions a tool name stays conversational.
//
// Deterministic engine doubles: no weights are mapped and no real model runs.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModels

@available(macOS 15.4, iOS 26.0, *)
private enum NamedIntentFixtures {
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

    static let readFile = ToolSchemaDescriptor(
        name: "workspace.readFile",
        description: "Read the UTF-8 text of one file in the current workspace",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
    )
    static let webSearch = ToolSchemaDescriptor(
        name: "web.search",
        description: "Search the public web",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
    )
    static let offeredTools = [readFile, webSearch]

    static let systemEnvelope =
        "A workspace is available. Use workspace.readFile when asked to read a file. Never guess file contents."
    static let firstUserText =
        "Call workspace.readFile with path qualification-probe.txt. After the tool result, report its exact contents."
    static let secondUserText =
        "Now call workspace.readFile with path qualification-probe-2.txt. Report its exact contents only after the tool responds."
    static let firstMarker = "FLOE_TOOL_PROBE_7B42"
    static let secondMarker = "FLOE_SECOND_TOOL_PROBE_92F1"

    static func firstTurnRequest() -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: model(),
            messages: [
                (role: "system", content: systemEnvelope),
                (role: "user", content: firstUserText)
            ],
            toolSchemas: [readFile],
            allToolNames: [readFile.name]
        )
    }

    static func secondTurnRequest(
        firstCall: ToolCall,
        firstResult: ToolResult,
        firstAnswer: String
    ) -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: model(),
            messages: [
                (role: "system", content: systemEnvelope),
                (role: "user", content: firstUserText),
                (role: "assistant", content: firstAnswer),
                (role: "user", content: secondUserText)
            ],
            replayedToolPairs: [ReplayedToolPair(call: firstCall, result: firstResult)],
            toolSchemas: [readFile],
            allToolNames: [readFile.name]
        )
    }

    static func request(
        userText: String,
        toolSchemas: [ToolSchemaDescriptor] = offeredTools,
        toolResults: [(callID: String, output: String)] = []
    ) -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: model(),
            messages: [
                (role: "system", content: systemEnvelope),
                (role: "user", content: userText)
            ],
            toolResults: toolResults,
            toolSchemas: toolSchemas,
            allToolNames: toolSchemas.map(\.name)
        )
    }

    static func envelope(path: String) -> String {
        #"{"tool_call":{"name":"workspace.readFile","arguments":{"path":"\#(path)"}}}"#
    }

    /// What the actual-weight model emitted on the failed cloud second turn:
    /// completed prose that quotes the OLD receipt and requests no tool.
    static func staleReceiptProse(path: String, marker: String) -> String {
        """
        ## Qualification Probe Result

        The file `\(path)` contains:

        ```
        \(marker)
        ```

        This confirms that the workspace is properly initialized and accessible. The probe file exists and is readable.
        """
    }
}

@Suite("Local named-tool intent classification")
struct LocalNamedToolIntentClassificationTests {
    @Test("The exact cloud second-turn command requires an invocation despite mentioning the tool responding")
    @available(macOS 15.4, iOS 26.0, *)
    func exactSecondTurnReplayRequiresInvocation() throws {
        let call = try ToolCall(
            id: "call-1",
            toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"qualification-probe.txt"}"#.utf8),
            scope: .local
        )
        let result = ToolResult(
            callID: "call-1",
            status: .ok,
            outputSummary: NamedIntentFixtures.firstMarker,
            outputDigest: "digest"
        )
        let build = LocalProviderAdapter.buildPrompt(
            for: NamedIntentFixtures.secondTurnRequest(
                firstCall: call,
                firstResult: result,
                firstAnswer: "The probe file says \(NamedIntentFixtures.firstMarker)."
            )
        )
        #expect(build.requiresToolCall)
        #expect(build.selectedTools.contains { $0.name == "workspace.readFile" })
        let primary = try #require(build.primaryRepairTool)
        #expect(primary.name == "workspace.readFile")
        // The Qwen bounded path gets the JSON-envelope priority directive.
        #expect(build.systemInstructions.contains("Emit the documented JSON tool_call object(s) now"))
        // The current request (new fixture) is what the repair must satisfy.
        let repairPrompt = LocalProviderAdapter.repairPrompt(
            for: NamedIntentFixtures.secondTurnRequest(
                firstCall: call,
                firstResult: result,
                firstAnswer: "The probe file says \(NamedIntentFixtures.firstMarker)."
            ),
            directive: "Emit the call now using the offered tool in the documented form; no prose."
        )
        #expect(repairPrompt.contains("qualification-probe-2.txt"))
        #expect(repairPrompt.contains("USER: \(NamedIntentFixtures.secondUserText)"))
    }

    @Test("A direct Chinese named invocation is an execution request even with 工具 in the sentence")
    @available(macOS 15.4, iOS 26.0, *)
    func chineseDirectNamedInvocationRequiresCall() {
        let text = "现在调用 workspace.readFile 读取 qualification-probe-2.txt，等工具响应后再告诉我内容。"
        let build = LocalProviderAdapter.buildPrompt(for: NamedIntentFixtures.request(userText: text))
        #expect(build.requiresToolCall)
        #expect(build.primaryRepairTool?.name == "workspace.readFile")
        #expect(build.systemInstructions.contains("Emit the documented JSON tool_call object(s) now"))
    }

    @Test("English imperatives naming each offered tool classify as named executions")
    @available(macOS 15.4, iOS 26.0, *)
    func englishNamedImperatives() {
        let names = NamedIntentFixtures.offeredTools.map(\.name)
        #expect(
            LocalProviderAdapter.namedExecutionToolNames(
                in: "now call workspace.readfile with path a.txt",
                offeredToolNames: names
            ) == ["workspace.readFile"]
        )
        #expect(
            LocalProviderAdapter.namedExecutionToolNames(
                in: "please invoke web.search with query weather",
                offeredToolNames: names
            ) == ["web.search"]
        )
        #expect(
            LocalProviderAdapter.namedExecutionToolNames(
                in: "execute workspace.readfile for b.md and then summarize",
                offeredToolNames: names
            ) == ["workspace.readFile"]
        )
    }

    @Test("Genuine capability questions stay informational")
    @available(macOS 15.4, iOS 26.0, *)
    func capabilityQuestionsDoNotRequireCalls() {
        let cases = [
            "你有哪些工具？能做什么？",
            "列出当前可用的工具和能力",
            "What tools are available? List the capabilities.",
            "Can you tell me which tool capabilities this assistant has?"
        ]
        for text in cases {
            let build = LocalProviderAdapter.buildPrompt(for: NamedIntentFixtures.request(userText: text))
            #expect(!build.requiresToolCall, "capability question must stay informational: \(text)")
            #expect(
                LocalProviderAdapter.namedExecutionToolNames(
                    in: text.lowercased(),
                    offeredToolNames: NamedIntentFixtures.offeredTools.map(\.name)
                ).isEmpty,
                "capability question must not name a commanded tool: \(text)"
            )
        }
    }

    @Test("The fuzzy list-then-try-one inventory request still requires one invocation")
    @available(macOS 15.4, iOS 26.0, *)
    func fuzzyInventoryPlusTryOneStillRequiresCall() {
        let build = LocalProviderAdapter.buildPrompt(
            for: NamedIntentFixtures.request(userText: "列出你有哪些工具，然后随便试一个。")
        )
        #expect(build.requiresToolCall)
    }

    @Test("Quoted examples and how-to questions naming a tool never force a call")
    @available(macOS 15.4, iOS 26.0, *)
    func quotedExamplesAndHowToStayProse() {
        let names = NamedIntentFixtures.offeredTools.map(\.name)
        let namedNegatives = [
            "for example, you could call workspace.readFile with path demo.txt — which tools support that?",
            "such as: invoke web.search with query x in a fenced sample below",
            "how do i call workspace.readFile from a script?",
            "how to invoke web.search safely in python?",
            "比如，调用 workspace.readFile 可以做到吗？它属于哪些工具能力？",
            "示例：调用 web.search 的用法是什么？",
            // Bare quoted sentences: the entire command is the quote.
            "\u{201C}call workspace.readFile with path demo.txt\u{201D}",
            "\u{300C}调用 workspace.readFile\u{300D}",
            "`call workspace.readFile with path x.txt`",
            "the envelope looks like {\"tool_call\":{\"name\":\"workspace.readFile\",\"arguments\":{}}} in docs",
            "```\ncall workspace.readFile with path x.txt\n```"
        ]
        for text in namedNegatives {
            #expect(
                LocalProviderAdapter.namedExecutionToolNames(
                    in: text.lowercased(),
                    offeredToolNames: names
                ).isEmpty,
                "explanatory/quoted text must not be a command: \(text)"
            )
        }
        // End-to-end through PromptBuild: capability-framed and bare quoted
        // examples must not enter the forced call/repair path even though the
        // tool name and an imperative verb both appear.
        let promptNegatives = [
            "For example, you could call workspace.readFile with path demo.txt — what tool capabilities exist?",
            "比如，调用 workspace.readFile 能做什么？有哪些工具能力？",
            "how do i call workspace.readFile from a script?",
            "示例：调用 web.search 的用法是什么？",
            "\u{201C}call workspace.readFile with path demo.txt\u{201D}",
            "\u{300C}调用 workspace.readFile\u{300D}",
            "`call workspace.readFile with path x.txt`"
        ]
        for text in promptNegatives {
            let build = LocalProviderAdapter.buildPrompt(
                for: NamedIntentFixtures.request(userText: text)
            )
            #expect(!build.requiresToolCall, "quoted example must not force a call: \(text)")
        }
    }

    @Test("A real command keeps its name when only the arguments are quoted")
    @available(macOS 15.4, iOS 26.0, *)
    func commandWithQuotedArgumentsStillRequiresCall() {
        // Quoted ARGUMENTS must not strip the command, which lives outside the
        // quote span.
        let english = NamedIntentFixtures.request(
            userText: "call workspace.readFile with path \"qualification-probe-2.txt\" now"
        )
        #expect(LocalProviderAdapter.buildPrompt(for: english).requiresToolCall)
        let chinese = NamedIntentFixtures.request(
            userText: #"调用 workspace.readFile，路径用 "qualification-probe-2.txt""#
        )
        #expect(LocalProviderAdapter.buildPrompt(for: chinese).requiresToolCall)
        for text in [
            "Now call `workspace.readFile` with path qualification-probe-2.txt after the tool responds.",
            "现在调用「workspace.readFile」工具，读取 qualification-probe-2.txt"
        ] {
            #expect(LocalProviderAdapter.buildPrompt(
                for: NamedIntentFixtures.request(userText: text)).requiresToolCall)
        }
    }

    @Test("Negated tool commands never require the invocation")
    @available(macOS 15.4, iOS 26.0, *)
    func negatedCommandsDoNotRequireCalls() {
        let names = NamedIntentFixtures.offeredTools.map(\.name)
        let negatives = [
            "don't call workspace.readFile yet",
            "do not invoke web.search for this",
            "answer without calling workspace.readFile",
            "不要调用 workspace.readFile，直接回答",
            "先别执行 web.search"
        ]
        for text in negatives {
            #expect(
                LocalProviderAdapter.namedExecutionToolNames(
                    in: text.lowercased(),
                    offeredToolNames: names
                ).isEmpty,
                "negation must not be a command: \(text)"
            )
            // Final PromptBuild gate too: the legacy fuzzy substring inside the
            // offered name must not promote a negation into a required call.
            #expect(
                !LocalProviderAdapter.buildPrompt(
                    for: NamedIntentFixtures.request(userText: text)
                ).requiresToolCall,
                "negation must not force a call: \(text)"
            )
        }
    }

    @Test("Ordinary chat mentioning a tool name stays conversational")
    @available(macOS 15.4, iOS 26.0, *)
    func ordinaryChatMentioningToolNameStaysConversational() {
        let names = NamedIntentFixtures.offeredTools.map(\.name)
        let chat = [
            "I read about workspace.readFile in the documentation yesterday.",
            "a web.search result is only useful when the question is current.",
            "workspace.readfile is a neat name for a capability"
        ]
        for text in chat {
            #expect(
                LocalProviderAdapter.namedExecutionToolNames(
                    in: text.lowercased(),
                    offeredToolNames: names
                ).isEmpty,
                "ordinary chat must not be a command: \(text)"
            )
        }
    }

    @Test("The tool name must match an offered name with boundaries")
    @available(macOS 15.4, iOS 26.0, *)
    func nameMatchingIsBoundarySafe() {
        let names = NamedIntentFixtures.offeredTools.map(\.name)
        // A different, non-offered name cannot satisfy the offered tool even
        // when it shares a prefix, and word-boundary collisions ("recall",
        // "because") do not count as the imperative verb.
        #expect(
            LocalProviderAdapter.namedExecutionToolNames(
                in: "call workspace.readfilebackup now",
                offeredToolNames: names
            ).isEmpty
        )
        #expect(
            LocalProviderAdapter.namedExecutionToolNames(
                in: "i recall that workspace.readfile exists because it is documented",
                offeredToolNames: names
            ).isEmpty
        )
        #expect(
            LocalProviderAdapter.namedExecutionToolNames(
                in: "call web.searchv2 please",
                offeredToolNames: names
            ).isEmpty
        )
    }

    @Test("A tool-result continuation answers instead of repeating the named action")
    @available(macOS 15.4, iOS 26.0, *)
    func receiptContinuationDoesNotRepeatNamedCall() {
        // Exactly the qualification follow-up shape: the retained user text is
        // itself the original "Call workspace.readFile …" command, but a tool
        // result for its call is present on this turn.
        var continuation = NamedIntentFixtures.request(userText: NamedIntentFixtures.firstUserText)
        continuation.toolResults = [(callID: "call-1", output: NamedIntentFixtures.firstMarker)]
        let build = LocalProviderAdapter.buildPrompt(for: continuation)
        #expect(!build.requiresToolCall)
    }
}

// MARK: - End-to-end replay through the production adapter

@available(macOS 15.4, iOS 26.0, *)
private final class ScriptedIndexEngine: LocalModelTextEngine, @unchecked Sendable {
    let includesVisionProjector = false
    private let lock = NSLock()
    private let scripts: [String]
    private var index = 0
    private(set) var toolsLog: [[ToolSchemaDescriptor]] = []

    var generationCount: Int { lock.withLock { index } }

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
            let chosen = scripts[min(index, scripts.count - 1)]
            toolsLog.append(tools)
            index += 1
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
private struct ReplayStreamHarness {
    let root: URL
    let engine: ScriptedIndexEngine
    let runtime: LocalModelRuntime
    let store: LocalModelStore

    init(engine: ScriptedIndexEngine) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-b233-intent-\(UUID().uuidString)", isDirectory: true)
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

@Suite("Local named-tool second-turn replay")
struct LocalNamedToolReplayTests {
    @Test("Prose quoting the old receipt on a new named request earns one repair and the new call")
    @available(macOS 15.4, iOS 26.0, *)
    func staleReceiptProseIsRepairedIntoSecondCall() async throws {
        let engine = ScriptedIndexEngine([
            // Turn 1: the first fixture call, emitted directly.
            NamedIntentFixtures.envelope(path: "qualification-probe.txt"),
            // Turn 2: the exact cloud failure shape — completed prose that
            // quotes the OLD receipt and requests no tool.
            NamedIntentFixtures.staleReceiptProse(
                path: "qualification-probe.txt",
                marker: NamedIntentFixtures.firstMarker
            ),
            // The one bounded repair: the new call with the NEW path.
            NamedIntentFixtures.envelope(path: "qualification-probe-2.txt")
        ])
        let harness = try ReplayStreamHarness(engine: engine)
        defer { harness.cleanUp() }
        let adapter = harness.adapter()

        // Turn 1: first fixture call executes.
        var firstCalls: [ToolCall] = []
        for try await event in adapter.stream(
            request: NamedIntentFixtures.firstTurnRequest(),
            credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { firstCalls.append(call) }
        }
        #expect(firstCalls.map(\.toolName) == ["workspace.readFile"])
        let firstCall = try #require(firstCalls.first)
        #expect(String(decoding: firstCall.argumentsJSON, as: UTF8.self)
            .contains("qualification-probe.txt"))
        let firstResult = ToolResult(
            callID: firstCall.id, status: .ok,
            outputSummary: NamedIntentFixtures.firstMarker,
            outputDigest: "digest-1"
        )

        // The assistant's first-turn answer (receipt reported) precedes the
        // new user command, exactly like the qualification replay.
        let secondRequest = NamedIntentFixtures.secondTurnRequest(
            firstCall: firstCall,
            firstResult: firstResult,
            firstAnswer: "The probe file says \(NamedIntentFixtures.firstMarker)."
        )
        var secondCalls: [ToolCall] = []
        var secondCompletionReasons: [AgentEvent.StopReason] = []
        for try await event in adapter.stream(
            request: secondRequest,
            credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { secondCalls.append(call) }
            if case .completed(let info) = event { secondCompletionReasons.append(info.stopReason) }
        }
        // The repair must produce exactly one NEW call for the NEW fixture.
        #expect(secondCalls.count == 1)
        let secondCall = try #require(secondCalls.first)
        #expect(secondCall.toolName == "workspace.readFile")
        #expect(secondCall.id != firstCall.id)
        #expect(String(decoding: secondCall.argumentsJSON, as: UTF8.self)
            .contains("qualification-probe-2.txt"))
        #expect(!String(decoding: secondCall.argumentsJSON, as: UTF8.self)
            .contains("qualification-probe.txt\""))
        #expect(secondCompletionReasons == [.toolUse])
        // Three generations: first call, stale prose, one bounded repair.
        #expect(engine.generationCount == 3)
        // The repair channel (generation index 2) for the Qwen bounded path
        // carries no native schemas.
        #expect(engine.toolsLog.count == 3)
        #expect(engine.toolsLog[2].isEmpty)
    }

    @Test("A direct Chinese named command whose first attempt is prose repairs into the call")
    @available(macOS 15.4, iOS 26.0, *)
    func chineseNamedCommandRepairsProseIntoCall() async throws {
        let engine = ScriptedIndexEngine([
            "好的，我这就读取文件给你看。",
            NamedIntentFixtures.envelope(path: "qualification-probe-2.txt")
        ])
        let harness = try ReplayStreamHarness(engine: engine)
        defer { harness.cleanUp() }
        let request = NamedIntentFixtures.request(
            userText: "现在调用 workspace.readFile 读取 qualification-probe-2.txt，等工具响应后再告诉我内容。",
            toolSchemas: [NamedIntentFixtures.readFile]
        )
        var calls: [ToolCall] = []
        var reasons: [AgentEvent.StopReason] = []
        for try await event in harness.adapter().stream(
            request: request, credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { calls.append(call) }
            if case .completed(let info) = event { reasons.append(info.stopReason) }
        }
        #expect(calls.count == 1)
        #expect(calls.first?.toolName == "workspace.readFile")
        #expect(String(decoding: try #require(calls.first).argumentsJSON, as: UTF8.self)
            .contains("qualification-probe-2.txt"))
        #expect(reasons == [.toolUse])
        #expect(engine.generationCount == 2)
    }

    @Test("A genuine capability question stays answered as prose with no repair")
    @available(macOS 15.4, iOS 26.0, *)
    func capabilityQuestionStaysProse() async throws {
        let engine = ScriptedIndexEngine(["我可以读取文件和搜索网页，属于工具能力介绍。"])
        let harness = try ReplayStreamHarness(engine: engine)
        defer { harness.cleanUp() }
        var calls: [ToolCall] = []
        var reasons: [AgentEvent.StopReason] = []
        for try await event in harness.adapter().stream(
            request: NamedIntentFixtures.request(userText: "你有哪些工具？能做什么？"),
            credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { calls.append(call) }
            if case .completed(let info) = event { reasons.append(info.stopReason) }
        }
        #expect(calls.isEmpty)
        #expect(reasons == [.endTurn])
        // No repair generation: an informational answer is not a gap.
        #expect(engine.generationCount == 1)
    }
}
