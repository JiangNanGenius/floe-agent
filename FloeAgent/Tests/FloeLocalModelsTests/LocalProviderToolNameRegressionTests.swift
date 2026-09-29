// FloeLocalModelsTests — Build 235 fabricated provider-name regression.
//
// Device evidence (Build 234, local Qwen): an explicit Chinese web-search
// turn first failed with "no valid tool call", and on retry the model printed
// ordinary prose followed by a JSON envelope that named the *search provider*
// instead of the registered tool:
//
//   好的，我来帮你搜索一下今天的新闻。
//   {"tool_call":{"name":"bochaWeb","arguments":{"query":"今天新闻"}}}
//
// and then said it was searching without any tool actually running. `bochaWeb`
// is a `WebSearchProviderKind` backend enum, never a registered tool — the
// canonical, registered capability is `web.search`. These tests pin:
//
//   * a valid canonical `web.search` envelope parses and executes exactly once,
//   * a provider/enum name such as `bochaWeb` is NEVER aliased or executed,
//   * a mixed prose + rejected-name envelope is withheld from the visible
//     answer, earns exactly one bounded corrective repair naming `web.search`,
//     and then executes the canonical call,
//   * a rejected-name repair that stays prose fails honestly (no false success),
//   * the same corrective behaviour holds on a fresh task and on a
//     retry/two-turn receipt chain (old receipt is never a substitute),
//   * cloud wire adapters never route through this local repair path.
//
// Deterministic engine doubles only: no weights are mapped and no real model,
// network or provider is invoked.

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
private enum ProviderNameFixtures {
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

    /// Real production descriptor.
    static let webSearch = ToolSchemaDescriptor(
        name: WebSearchTool.name,
        description: WebSearchTool.toolDescription,
        parametersJSON: WebSearchTool.parametersJSON
    )

    static let readFile = ToolSchemaDescriptor(
        name: "workspace.readFile",
        description: "Read a workspace file",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
    )

    static let offeredTools: [ToolSchemaDescriptor] = [readFile, webSearch]

    static let newsUserText = "那你能尝试调用一下工具，随便搜索一下今天的新闻吗"

    static func request(
        userText: String,
        toolSchemas: [ToolSchemaDescriptor] = offeredTools,
        toolResults: [(callID: String, output: String)] = [],
        pendingToolCalls: [ToolCall] = [],
        replayedToolPairs: [ReplayedToolPair] = []
    ) -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: model(),
            messages: [
                (role: "system", content: "Runtime envelope: synthetic workspace."),
                (role: "user", content: userText)
            ],
            toolResults: toolResults,
            pendingToolCalls: pendingToolCalls,
            replayedToolPairs: replayedToolPairs,
            toolSchemas: toolSchemas,
            allToolNames: toolSchemas.map(\.name)
        )
    }

    static func canonicalEnvelope(query: String) -> String {
        #"{"tool_call":{"name":"web.search","arguments":{"query":"\#(query)"}}}"#
    }

    /// The exact device failure shape: prose lead-in then a structurally valid
    /// envelope naming the provider enum instead of the tool.
    static let rejectedNameEnvelope =
        #"{"tool_call":{"name":"bochaWeb","arguments":{"query":"今天新闻"}}}"#
    static let proseThenRejectedName =
        "好的，我来帮你搜索一下今天的新闻。\n" + rejectedNameEnvelope
}

@Suite("Local provider-name is not a tool name")
struct LocalProviderToolNameParserTests {
    @Test("A canonical web.search envelope parses to the registered tool")
    @available(macOS 15.4, iOS 26.0, *)
    func canonicalEnvelopeParses() throws {
        let offered: Set<String> = ["web.search", "workspace.readFile"]
        let calls = try LocalProviderAdapter.toolCalls(
            from: ProviderNameFixtures.canonicalEnvelope(query: "今天新闻"),
            offeredToolNames: offered
        )
        #expect(calls.map(\.toolName) == ["web.search"])
        let args = String(decoding: try #require(calls.first).argumentsJSON, as: UTF8.self)
        #expect(args.contains("今天新闻"))
    }

    @Test("The bochaWeb provider enum is never parsed, aliased or executed")
    @available(macOS 15.4, iOS 26.0, *)
    func providerEnumNameIsRejected() throws {
        let offered: Set<String> = ["web.search", "web.searchAI", "web.fetch"]
        let calls = try LocalProviderAdapter.toolCalls(
            from: ProviderNameFixtures.rejectedNameEnvelope,
            offeredToolNames: offered
        )
        #expect(calls.isEmpty, "a provider enum must never become a tool call")
        // It is still recognized structurally, so it can be withheld/repair-classified.
        let envelopes = LocalProviderAdapter.structuralToolEnvelopes(
            in: ProviderNameFixtures.rejectedNameEnvelope
        )
        #expect(envelopes.map(\.name) == ["bochaWeb"])
        #expect(LocalProviderAdapter.looksLikeToolCallPayload(
            ProviderNameFixtures.rejectedNameEnvelope))
    }

    @Test("A mixed prose + rejected-name envelope is a rejected-name gap, not missing invocation")
    @available(macOS 15.4, iOS 26.0, *)
    func mixedProseClassifiesAsUnrecognizedName() throws {
        let reason = LocalProviderAdapter.invocationGapReason(
            rawOutput: ProviderNameFixtures.proseThenRejectedName,
            parsedCalls: [],
            offeredNames: Set(ProviderNameFixtures.offeredTools.map(\.name))
        )
        guard case .unrecognizedToolName(let emitted, _) = reason else {
            Issue.record("expected unrecognizedToolName, got \(reason)")
            return
        }
        #expect(emitted == "bochaWeb")
    }

    @Test("Pure prose with no envelope is a missing-invocation gap")
    @available(macOS 15.4, iOS 26.0, *)
    func pureProseIsMissingInvocation() {
        let reason = LocalProviderAdapter.invocationGapReason(
            rawOutput: "好的，我这就开始搜索。",
            parsedCalls: [],
            offeredNames: ["web.search"]
        )
        #expect(reason == .missingInvocation)
    }

    @Test("Quoted inline examples are not structural envelopes and stay prose")
    @available(macOS 15.4, iOS 26.0, *)
    func inlineExampleIsNotStructural() {
        let text = #"你可以写 {"tool_call":{"name":"bochaWeb","arguments":{}}} 这样，但我不会执行。"#
        #expect(LocalProviderAdapter.structuralToolEnvelopes(in: text).isEmpty)
        #expect(!LocalProviderAdapter.looksLikeToolCallPayload(text))
    }

    @Test("A fenced json envelope after prose is structural (withhold) but never directly executable")
    @available(macOS 15.4, iOS 26.0, *)
    func fencedEnvelopeIsStructuralButNotExecutable() throws {
        let text = """
        好的，我来帮你搜索一下今天的新闻。
        ```json
        {"tool_call":{"name":"bochaWeb","arguments":{"query":"今天新闻"}}}
        ```
        """
        // Structural probe (withhold/gap classification) sees it.
        #expect(LocalProviderAdapter.structuralToolEnvelopes(in: text).map(\.name) == ["bochaWeb"])
        #expect(LocalProviderAdapter.looksLikeToolCallPayload(text))
        // The authoritative execution parser keeps fenced lines non-executable.
        let calls = try LocalProviderAdapter.toolCalls(
            from: text, offeredToolNames: ["web.search", "bochaWeb"]
        )
        #expect(calls.isEmpty, "a fenced envelope is a sample, never a direct call even if its name were offered")
    }

    @Test("An unlabelled fence is treated as a sample, not a structural envelope")
    @available(macOS 15.4, iOS 26.0, *)
    func unlabelledFenceIsNotStructural() {
        let text = """
        用法如下：
        ```
        {"tool_call":{"name":"bochaWeb","arguments":{"query":"x"}}}
        ```
        """
        #expect(LocalProviderAdapter.structuralToolEnvelopes(in: text).isEmpty)
        #expect(!LocalProviderAdapter.looksLikeToolCallPayload(text))
    }

    @Test("Withhold gating preserves legitimate JSON examples on ordinary turns")
    @available(macOS 15.4, iOS 26.0, *)
    func ordinaryTurnExampleStaysVisible() {
        let offered: Set<String> = ["web.search"]
        // An inline example sharing a prose line is never a structural
        // envelope: it stays visible on BOTH ordinary and action turns (the
        // execution parser also refuses it, so it can never run).
        let inlineExample = #"The envelope looks like {"tool_call":{"name":"bochaWeb","arguments":{}}} in the docs."#
        #expect(!LocalProviderAdapter.toolLikePayloadWithhold(
            payload: inlineExample, offeredToolNames: offered, turnRequiresCall: true))
        #expect(!LocalProviderAdapter.toolLikePayloadWithhold(
            payload: inlineExample, offeredToolNames: offered, turnRequiresCall: false))
        // A whole rejected-name payload AFTER prose on its own line is a
        // structural envelope. Withheld while the action turn is repaired,
        // but on an ordinary (non-action) turn it is shown so a user-requested
        // JSON sample/question can be answered.
        let proseThenWhole = "Here is the shape you asked about:\n"
            + #"{"tool_call":{"name":"bochaWeb","arguments":{}}}"#
        #expect(LocalProviderAdapter.structuralToolEnvelopes(in: proseThenWhole)
            .map(\.name) == ["bochaWeb"])
        #expect(LocalProviderAdapter.toolLikePayloadWithhold(
            payload: proseThenWhole, offeredToolNames: offered, turnRequiresCall: true))
        #expect(!LocalProviderAdapter.toolLikePayloadWithhold(
            payload: proseThenWhole, offeredToolNames: offered, turnRequiresCall: false))
        // A canonical whole envelope always withholds: even on an ordinary
        // turn it parses to a real call and must never print as answer text.
        let canonicalWhole = #"{"tool_call":{"name":"web.search","arguments":{"query":"x"}}}"#
        #expect(LocalProviderAdapter.toolLikePayloadWithhold(
            payload: canonicalWhole, offeredToolNames: offered, turnRequiresCall: false))
    }

    @Test("The corrective repair target for a news request is web.search")
    @available(macOS 15.4, iOS 26.0, *)
    func correctiveTargetIsWebSearch() {
        let build = LocalProviderAdapter.buildPrompt(
            for: ProviderNameFixtures.request(userText: ProviderNameFixtures.newsUserText)
        )
        #expect(build.requiresToolCall)
        #expect(build.primaryRepairTool?.name == "web.search")
    }

    @Test("The display framer withholds a rejected-name envelope (bare and fenced) while releasing prose")
    @available(macOS 15.4, iOS 26.0, *)
    func framerWithholdsRejectedNameEnvelope() {
        let offered = Set(ProviderNameFixtures.offeredTools.map(\.name))
        let cases: [String] = [
            ProviderNameFixtures.proseThenRejectedName,
            "好的，我来帮你搜索一下今天的新闻。\n```json\n"
                + ProviderNameFixtures.rejectedNameEnvelope + "\n```"
        ]
        for text in cases {
            var framer = LocalStreamFramer { payload in
                LocalProviderAdapter.toolLikePayloadWithhold(
                    payload: payload, offeredToolNames: offered, turnRequiresCall: true)
            }
            var delivered = ""
            // Feed one character at a time to prove no split leaks the JSON.
            for character in text {
                delivered += framer.ingest(String(character))
            }
            #expect(delivered.contains("搜索"), "prose lead-in must stream: \(text.prefix(20))")
            #expect(!delivered.contains("bochaWeb"))
            #expect(!delivered.contains("tool_call"))
            #expect(!framer.emitted.contains("bochaWeb"))
        }
    }
}

@Suite("Local provider-name streaming repair")
struct LocalProviderToolNameStreamingTests {
    @Test("Prose plus a rejected-name envelope is withheld, repaired once, and executes web.search")
    @available(macOS 15.4, iOS 26.0, *)
    func rejectedNameIsCorrectedIntoCanonicalCall() async throws {
        let engine = SequencedNameRepairEngine([
            ProviderNameFixtures.proseThenRejectedName,
            ProviderNameFixtures.canonicalEnvelope(query: "今天新闻")
        ])
        let harness = try NameStreamHarness(engine: engine)
        defer { harness.cleanUp() }

        var calls: [ToolCall] = []
        var visible = ""
        var reasons: [AgentEvent.StopReason] = []
        for try await event in harness.adapter().stream(
            request: ProviderNameFixtures.request(userText: ProviderNameFixtures.newsUserText),
            credentials: ProviderCredentials()
        ) {
            switch event {
            case .toolRequest(let call): calls.append(call)
            case .textDelta(let delta): visible += delta.text
            case .completed(let info): reasons.append(info.stopReason)
            default: break
            }
        }
        // Exactly one executed call, and it is the canonical registered tool.
        #expect(calls.map(\.toolName) == ["web.search"])
        #expect(reasons == [.toolUse])
        // The rejected-name JSON must never appear in the visible answer.
        #expect(!visible.contains("bochaWeb"))
        #expect(!visible.contains("tool_call"))
        // Two generations: the failed attempt and the single bounded repair.
        #expect(engine.generationCount == 2)
        // The corrective repair names the canonical tool and preserves intent.
        #expect(engine.repairInstructionsLog.last?.contains("web.search") == true)
        #expect(engine.repairPrompts.last?.contains("not an offered tool") == true)
        // Qwen bounded path: no native schemas on the repair channel.
        #expect(engine.repairToolsLog.last?.isEmpty == true)
    }

    @Test("A fenced rejected-name first attempt is withheld and corrected into web.search")
    @available(macOS 15.4, iOS 26.0, *)
    func fencedRejectedNameIsCorrectedIntoCanonicalCall() async throws {
        let fenced = "好的，我来帮你搜索一下今天的新闻。\n```json\n"
            + ProviderNameFixtures.rejectedNameEnvelope + "\n```"
        let engine = SequencedNameRepairEngine([
            fenced,
            ProviderNameFixtures.canonicalEnvelope(query: "今天新闻")
        ])
        let harness = try NameStreamHarness(engine: engine)
        defer { harness.cleanUp() }

        var calls: [ToolCall] = []
        var visible = ""
        var reasons: [AgentEvent.StopReason] = []
        for try await event in harness.adapter().stream(
            request: ProviderNameFixtures.request(userText: ProviderNameFixtures.newsUserText),
            credentials: ProviderCredentials()
        ) {
            switch event {
            case .toolRequest(let call): calls.append(call)
            case .textDelta(let delta): visible += delta.text
            case .completed(let info): reasons.append(info.stopReason)
            default: break
            }
        }
        #expect(calls.map(\.toolName) == ["web.search"])
        #expect(reasons == [.toolUse])
        #expect(!visible.contains("bochaWeb"))
        #expect(!visible.contains("tool_call"))
        #expect(engine.generationCount == 2)
    }

    @Test("A fresh task emitting the canonical call directly executes with no repair")
    @available(macOS 15.4, iOS 26.0, *)
    func freshCanonicalCallNeedsNoRepair() async throws {
        let engine = SequencedNameRepairEngine([
            ProviderNameFixtures.canonicalEnvelope(query: "今天新闻")
        ])
        let harness = try NameStreamHarness(engine: engine)
        defer { harness.cleanUp() }

        var calls: [ToolCall] = []
        var visible = ""
        for try await event in harness.adapter().stream(
            request: ProviderNameFixtures.request(userText: ProviderNameFixtures.newsUserText),
            credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { calls.append(call) }
            if case .textDelta(let delta) = event { visible += delta.text }
        }
        #expect(calls.map(\.toolName) == ["web.search"])
        #expect(!visible.contains("tool_call"))
        #expect(engine.generationCount == 1, "a valid canonical call needs no repair")
    }

    @Test("A rejected-name repair that stays prose fails honestly with no execution")
    @available(macOS 15.4, iOS 26.0, *)
    func rejectedNameWithoutRepairFailsClosed() async throws {
        let engine = SequencedNameRepairEngine([
            ProviderNameFixtures.proseThenRejectedName,
            "抱歉，我暂时无法完成搜索。"
        ])
        let harness = try NameStreamHarness(engine: engine)
        defer { harness.cleanUp() }

        var calls: [ToolCall] = []
        var failed = false
        do {
            for try await event in harness.adapter().stream(
                request: ProviderNameFixtures.request(userText: ProviderNameFixtures.newsUserText),
                credentials: ProviderCredentials()
            ) {
                if case .toolRequest(let call) = event { calls.append(call) }
            }
        } catch let error as FloeError {
            failed = error.localizedDescription.contains("工具调用")
        }
        #expect(calls.isEmpty, "no phantom/aliased call after a failed corrective repair")
        #expect(failed, "a corrective repair that stays prose must fail honestly")
        #expect(engine.generationCount == 2)
    }

    @Test("Retry/two-turn chain: rejected name repaired, then receipt answers, then a new call runs")
    @available(macOS 15.4, iOS 26.0, *)
    func retryReceiptAndSecondUserTurn() async throws {
        let canonicalFirst = ProviderNameFixtures.canonicalEnvelope(query: "今天新闻")
        let canonicalSecond = ProviderNameFixtures.canonicalEnvelope(query: "明天天气")
        let engine = SequencedNameRepairEngine([
            // Turn 1 attempt: prose + rejected provider name.
            ProviderNameFixtures.proseThenRejectedName,
            // Turn 1 bounded repair: canonical call.
            canonicalFirst,
            // Turn 2 receipt continuation: grounded answer, no new call.
            "根据搜索结果（FLOE_SEARCH_RECEIPT_7A31，synthetic fixture）：共 3 条合成新闻。",
            // Turn 3 new user request: canonical call directly (no repair).
            canonicalSecond
        ])
        let harness = try NameStreamHarness(engine: engine)
        defer { harness.cleanUp() }
        let adapter = harness.adapter()

        // Turn 1: rejected name corrected into the canonical call.
        var firstCalls: [ToolCall] = []
        for try await event in adapter.stream(
            request: ProviderNameFixtures.request(userText: ProviderNameFixtures.newsUserText),
            credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { firstCalls.append(call) }
        }
        #expect(firstCalls.map(\.toolName) == ["web.search"])
        let firstCall = try #require(firstCalls.first)
        let marker = "FLOE_SEARCH_RECEIPT_7A31"
        let receipt = "receipt marker: \(marker). synthetic fixture (no live search performed): 3 results for \"今天新闻\""
        let firstResult = ToolResult(
            callID: firstCall.id, status: .ok,
            outputSummary: receipt, outputDigest: "digest-1"
        )

        // Turn 2: the runtime feeds the tool result back. The continuation
        // answers from the receipt and never repeats the call.
        let continuation = ProviderNameFixtures.request(
            userText: ProviderNameFixtures.newsUserText,
            toolResults: [(callID: firstCall.id, output: receipt)],
            pendingToolCalls: [firstCall],
            replayedToolPairs: []
        )
        var answer = ""
        var secondCalls: [ToolCall] = []
        for try await event in adapter.stream(
            request: continuation, credentials: ProviderCredentials()
        ) {
            if case .textDelta(let delta) = event { answer += delta.text }
            if case .toolRequest(let call) = event { secondCalls.append(call) }
        }
        #expect(secondCalls.isEmpty, "a receipt continuation must not repeat the call")
        #expect(answer.contains(marker))

        // Turn 3: a NEW user request runs its own canonical call, with the old
        // pair replayed as settled history (never substituted for the new call).
        let followup = ProviderNameFixtures.request(
            userText: "很好，再帮我搜索一下明天的天气",
            replayedToolPairs: [ReplayedToolPair(call: firstCall, result: firstResult)]
        )
        var thirdCalls: [ToolCall] = []
        for try await event in adapter.stream(
            request: followup, credentials: ProviderCredentials()
        ) {
            if case .toolRequest(let call) = event { thirdCalls.append(call) }
        }
        #expect(thirdCalls.map(\.toolName) == ["web.search"])
        let thirdCall = try #require(thirdCalls.first)
        #expect(thirdCall.id != firstCall.id)
        #expect(String(decoding: thirdCall.argumentsJSON, as: UTF8.self).contains("明天天气"))
        #expect(engine.generationCount == 4, "one corrective repair only; the new turn calls directly")
    }

    @Test("Cloud wire protocols never use the local corrective repair adapter")
    @available(macOS 15.4, iOS 26.0, *)
    func cloudProvidersAreUnaffected() {
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
}

// MARK: - Deterministic engine + harness

@available(macOS 15.4, iOS 26.0, *)
private final class SequencedNameRepairEngine: LocalModelTextEngine, @unchecked Sendable {
    let includesVisionProjector = false
    private let lock = NSLock()
    private let scripts: [String]
    private var index = 0
    private(set) var toolsLog: [[ToolSchemaDescriptor]] = []
    private(set) var instructionsLog: [String] = []
    private(set) var promptLog: [String] = []

    var generationCount: Int { lock.withLock { index } }
    var repairToolsLog: [[ToolSchemaDescriptor]] { lock.withLock { toolsLog } }
    var repairInstructionsLog: [String] { lock.withLock { instructionsLog } }
    var repairPrompts: [String] { lock.withLock { promptLog } }

    init(_ scripts: [String]) { self.scripts = scripts }

    func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult {
        lock.withLock {
            let chosen = scripts[min(index, scripts.count - 1)]
            toolsLog.append(tools)
            instructionsLog.append(instructions)
            promptLog.append(prompt)
            index += 1
            return LocalGenerationResult(
                text: chosen, inputTokens: 10, outputTokens: 6,
                timeToFirstTokenMs: 2, generationDurationMs: 4
            )
        }
    }

    func shutdown() async {}
}

@available(macOS 15.4, iOS 26.0, *)
private struct NameStreamHarness {
    let root: URL
    let engine: SequencedNameRepairEngine
    let runtime: LocalModelRuntime
    let store: LocalModelStore

    init(engine: SequencedNameRepairEngine) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-b235-name-\(UUID().uuidString)", isDirectory: true)
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
