#if os(macOS)
import Foundation
import MLXLMCommon
import FloeCore
import FloeModels
import FloeProviders

/// Bounded, qualification-only plan for discriminating why the real pinned
/// local model fabricates tool results despite intact prompt wording.
///
/// Build 233 already tried two prompt-wording repairs on the production
/// template and both failed at real weights (search receipt continuation
/// invented news; `answerContainsReceipt:false`, code 34). This plan does
/// **not** add more adjective-strengthened wording. It encodes the explicit
/// competing hypotheses as controlled, individually-varied cases so the next
/// real-weight run can distinguish:
///
/// - `H-COPY` — the model cannot reliably copy a verbatim token/sentence;
/// - `H-REPR` — the flattened single-user-turn representation dilutes receipt
///   authority (the existing production shape);
/// - `H-SAMPLING` — temperature sampling picks the high-prior fabrication
///   branch where argmax would ground;
/// - `H-REPPENALTY` — the repetition penalty down-weights the exact receipt
///   tokens (marker, "synthetic fixture") at generation time;
/// - `H-REPR-NATIVE` — Qwen's native multi-step protocol (assistant
///   `tool_calls` then a `tool` role rendered inside `<tool_response>`)
///   grounds where the flattened shape does not;
/// - `H-MODEL` — the abliterated 4B distill pattern-completes regardless of
///   representation/sampling; a hypothesis the bounded matrix can support but cannot prove universally.
///
/// The production app never constructs or sends this plan; it is consumed only
/// by the LocalInference qualification host. Every string is a synthetic
/// fixture: no user or private content, no live search results.
@available(macOS 15.4, iOS 26.0, *)
public struct LocalGroundingProbePlan: Sendable {

    /// Synthetic fixed-needle strings. They intentionally reuse the markers
    /// already visible in the (synthetic-only) qualification evidence so the
    /// real-weight run measures the exact v7/v8 failure shape.
    public enum Fixtures {
        public static let query = "今天的新闻"
        public static let callID = "probe-call-7a31"
        public static let emptyMarker = "FLOE_SEARCH_RECEIPT_7A31"
        /// Receipt that truthfully identifies a synthetic fixture and reports
        /// zero usable result items. A grounded answer must state the
        /// synthetic/no-live-search fact (and repeat the marker when the run
        /// context asks), never invent news items.
        public static let emptyReceipt =
            "receipt marker: \(emptyMarker). synthetic fixture (no live search performed): "
            + "3 normalized results for query \"\(query)\""

        public static let itemsMarker = "FLOE_SEARCH_RECEIPT_8C44"
        /// Complementary receipt that DOES carry three clearly-labeled
        /// synthetic items. Used to tell "cannot ground provided content at
        /// all" apart from "will not abstain when content is absent": an
        /// answer grounded here must echo the provided synthetic items rather
        /// than inventing other news.
        public static let itemsReceipt =
            "receipt marker: \(itemsMarker). synthetic fixture (no live search performed). "
            + "Results returned (all synthetic, not real events): "
            + "1. SYNTHETIC ITEM 8C44-A: 合成新闻条目甲，示例城市发布示例交通公告； "
            + "2. SYNTHETIC ITEM 8C44-B: 合成新闻条目乙，示例科技公司发布示例芯片； "
            + "3. SYNTHETIC ITEM 8C44-C: 合成新闻条目丙，示例市场出现示例波动。"
    }

    /// Sendable, wire-minimal message spec for direct probe cases. The pinned
    /// `Chat.Message` is not `Sendable`, so the plan stores this spec and the
    /// module resolves it to `Chat.Message` at the engine boundary.
    public struct ProbeMessage: Sendable {
        public enum Role: String, Sendable {
            case system, user, assistant, tool
        }
        public let role: Role
        public let content: String
        /// When true on an assistant message, the resolver attaches the
        /// native `web.search` tool call.
        public let carriesToolCall: Bool

        public init(role: Role, content: String, carriesToolCall: Bool = false) {
            self.role = role
            self.content = content
            self.carriesToolCall = carriesToolCall
        }
    }

    /// One controlled case.
    public struct Case: Sendable {
        public enum Content: Sendable {
            /// Messages sent to the template directly.
            case direct(messages: [ProbeMessage])
            /// Production flattened representation: the host maps this request
            /// through `LocalProviderAdapter.buildPrompt` so the case measures
            /// the exact production composer (system + single user turn).
            case flatContinuation(request: ProviderStreamRequest)
        }

        /// Stable id used in structured evidence.
        public let id: String
        /// Competing hypothesis this case discriminates.
        public let hypothesis: String
        public let content: Content
        public let temperature: Float
        public let repetitionPenalty: Float
        public let maxTokens: Int
        /// Literal substrings that must be proven present in the actual
        /// prepared token ids before generation.
        public let evidenceNeedles: [String]

        public init(id: String, hypothesis: String, content: Content,
                    temperature: Float, repetitionPenalty: Float, maxTokens: Int,
                    evidenceNeedles: [String]) {
            self.id = id
            self.hypothesis = hypothesis
            self.content = content
            self.temperature = temperature
            self.repetitionPenalty = repetitionPenalty
            self.maxTokens = maxTokens
            self.evidenceNeedles = evidenceNeedles
        }
    }

    public let cases: [Case]

    public init(cases: [Case]) { self.cases = cases }

    /// Production sampling values, matching `MLXTextEngine` generation.
    static let productionTemperature: Float = 0.55
    static let productionRepetitionPenalty: Float = 1.05

    /// Model profile used by the flat-continuation requests: same limits the
    /// search roundtrip uses. This is diagnostic-only.
    static func probeModel(modelID: String) -> ModelProfile {
        ModelProfile(
            providerID: LocalProviderAdapter.providerProfile.id,
            remoteModelID: modelID,
            displayName: "Qwen grounding probe",
            limits: .init(contextTokens: 8_192, maxOutputTokens: 256),
            capabilities: [.text, .tools]
        )
    }

    /// Builds the production-flat continuation request for a given receipt.
    /// The request mirrors `runActualSearchRoundtrip`: system envelope,
    /// greeting history, current news request, the pending pair and its
    /// replay, plus the offered schemas.
    public static func flatRequest(
        envelope: String,
        receipt: String,
        schemas: [ToolSchemaDescriptor],
        modelID: String
    ) throws -> ProviderStreamRequest {
        let argumentsJSON = Data(#"{"mode":"balanced","query":"今天的新闻"}"#.utf8)
        // FloeLocalModels must not depend on FloeExecution; the production
        // search tool name is the stable literal "web.search".
        let call = try ToolCall(
            id: Fixtures.callID,
            toolName: "web.search",
            argumentsJSON: argumentsJSON,
            scope: .local
        )
        let result = ToolResult(
            callID: Fixtures.callID,
            status: .ok,
            outputSummary: receipt,
            outputDigest: FloeDigest.sha256Hex(Data(receipt.utf8))
        )
        return ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: probeModel(modelID: modelID),
            messages: [
                (role: "system", content: envelope),
                (role: "user", content: "你好，今天过得怎么样？"),
                (role: "assistant",
                 content: "你好！今天我过得挺充实的，谢谢关心～今天有什么特别的计划或想聊的话题吗？"),
                (role: "user", content: "那你能尝试调用一下工具，随便搜索一下今天的新闻吗")
            ],
            toolResults: [(callID: Fixtures.callID, output: receipt)],
            pendingToolCalls: [call],
            replayedToolPairs: [ReplayedToolPair(call: call, result: result)],
            toolSchemas: schemas,
            allToolNames: schemas.map(\.name)
        )
    }

    /// Native multi-step protocol message spec: assistant with a `web.search`
    /// tool call, then a real `tool` role answering the call. The production
    /// Qwen3 template renders the tool role inside `<tool_response>`.
    static func nativeMessages(envelope: String, receipt: String) -> [ProbeMessage] {
        [
            ProbeMessage(role: .system, content: envelope),
            ProbeMessage(role: .user,
                content: "那你能尝试调用一下工具，随便搜索一下今天的新闻吗"),
            ProbeMessage(role: .assistant, content: "", carriesToolCall: true),
            ProbeMessage(role: .tool, content: receipt)
        ]
    }

    /// Resolves sendable probe messages into the engine's `Chat.Message`
    /// list, attaching the native search call where requested. Lives inside
    /// FloeLocalModels to keep `Chat.Message` construction module-local.
    public static func resolveProbeMessages(
        _ messages: [ProbeMessage]
    ) -> [Chat.Message] {
        messages.map { message in
            switch message.role {
            case .system:
                return .system(message.content)
            case .user:
                return .user(message.content)
            case .tool:
                return .tool(message.content, id: Fixtures.callID)
            case .assistant:
                if message.carriesToolCall {
                    let nativeCall = MLXLMCommon.ToolCall(
                        function: .init(name: "web.search",
                                        arguments: ["mode": "balanced",
                                                    "query": Fixtures.query]),
                        id: Fixtures.callID)
                    return .assistant(message.content, toolCalls: [nativeCall])
                }
                return .assistant(message.content)
            }
        }
    }

    /// Assembles the standard seven-case matrix. `envelope` is produced by
    /// the host via `AgentPromptComposer` (FloeAgentRuntime); this package
    /// must not import that module.
    public static func standard(
        envelope: String,
        schemas: [ToolSchemaDescriptor],
        modelID: String
    ) throws -> LocalGroundingProbePlan {
        let emptyNeedles = [Fixtures.emptyMarker, "synthetic fixture"]
        let itemsNeedles = [Fixtures.itemsMarker, "SYNTHETIC ITEM"]

        let flatEmpty = Case.Content.flatContinuation(request: try flatRequest(
            envelope: envelope, receipt: Fixtures.emptyReceipt,
            schemas: schemas, modelID: modelID))
        let flatItems = Case.Content.flatContinuation(request: try flatRequest(
            envelope: envelope, receipt: Fixtures.itemsReceipt,
            schemas: schemas, modelID: modelID))

        let copyCase = Case(
            id: "copy-minimal", hypothesis: "H-COPY",
            content: .direct(messages: [
                ProbeMessage(role: .system,
                    content: "Repeat the text below exactly; no extra words."),
                ProbeMessage(role: .user, content: Fixtures.emptyReceipt)
            ]),
            temperature: productionTemperature,
            repetitionPenalty: productionRepetitionPenalty,
            maxTokens: 160, evidenceNeedles: emptyNeedles)

        let flatCase = Case(
            id: "flat-production", hypothesis: "H-REPR",
            content: flatEmpty,
            temperature: productionTemperature,
            repetitionPenalty: productionRepetitionPenalty,
            maxTokens: 256, evidenceNeedles: emptyNeedles)

        let greedyCase = Case(
            id: "flat-greedy", hypothesis: "H-SAMPLING",
            content: flatEmpty,
            temperature: 0, repetitionPenalty: productionRepetitionPenalty,
            maxTokens: 256, evidenceNeedles: emptyNeedles)

        let noRepPenaltyCase = Case(
            id: "flat-no-rep-penalty", hypothesis: "H-REPPENALTY",
            content: flatEmpty,
            temperature: productionTemperature, repetitionPenalty: 1.0,
            maxTokens: 256, evidenceNeedles: emptyNeedles)

        let nativeCase = Case(
            id: "native-tool", hypothesis: "H-REPR-NATIVE",
            content: .direct(messages: nativeMessages(
                envelope: envelope, receipt: Fixtures.emptyReceipt)),
            temperature: productionTemperature,
            repetitionPenalty: productionRepetitionPenalty,
            maxTokens: 256, evidenceNeedles: emptyNeedles)

        let nativeGreedyCase = Case(
            id: "native-greedy-noRP", hypothesis: "H-COMBINED",
            content: .direct(messages: nativeMessages(
                envelope: envelope, receipt: Fixtures.emptyReceipt)),
            temperature: 0, repetitionPenalty: 1.0,
            maxTokens: 256, evidenceNeedles: emptyNeedles)

        let itemsCase = Case(
            id: "flat-items-present", hypothesis: "H-ITEMS",
            content: flatItems,
            temperature: productionTemperature,
            repetitionPenalty: productionRepetitionPenalty,
            maxTokens: 320, evidenceNeedles: itemsNeedles)

        return LocalGroundingProbePlan(cases: [
            copyCase, flatCase, greedyCase, noRepPenaltyCase,
            nativeCase, nativeGreedyCase, itemsCase
        ])
    }

    /// Maps a flat-continuation request through the production
    /// `LocalProviderAdapter.buildPrompt`, returning the exact system/user
    /// messages the template will receive. This lives inside FloeLocalModels
    /// because `buildPrompt` is module-internal.
    public static func flattenedMessages(
        for request: ProviderStreamRequest
    ) -> [Chat.Message] {
        let built = LocalProviderAdapter.buildPrompt(for: request)
        return [.system(built.systemInstructions), .user(built.text)]
    }

    /// First index range where `needle` appears contiguously in `ids`, or nil.
    /// Naive search; both arrays are bounded by the prepared turn length.
    static func firstSpan(of needle: [Int], in ids: [Int]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= ids.count else { return nil }
        let limit = ids.count - needle.count
        var start = 0
        while start <= limit {
            var offset = 0
            while offset < needle.count, ids[start + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count { return start..<(start + needle.count) }
            start += 1
        }
        return nil
    }
}

#endif
