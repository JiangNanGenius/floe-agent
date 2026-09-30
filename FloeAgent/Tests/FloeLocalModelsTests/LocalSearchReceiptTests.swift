// FloeLocalModelsTests — local search receipt repair.
//
// Invariants under test:
//   * the bounded execution parser never executes fenced JSON (a fenced
//     sample stays a sample), so a required search invocation whose only
//     "call" is prose plus a fenced envelope earns exactly one bounded
//     repair that names the canonical tool;
//   * a canonical call flows through the real `ConversationRunService` to a
//     real receipt, and a second tool event on the continuation turn keeps
//     both receipts in the model context;
//   * the new invocation classifier is bounded by the curated live-web
//     policy (no forced call without `web.search` offered, informational
//     questions stay conversational, receipt continuations answer from the
//     receipt);
//   * the fuzzy-action contract and quoted-example rejection are unchanged.
//
// The fixtures drive the production adapter/runtime with a deterministic
// engine double; no weights are mapped and no network is touched.

import Foundation
import Synchronization
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

// MARK: - Scripted engine with a scripted repair channel

@available(macOS 15.4, iOS 26.0, *)
private final class SearchChainEngine: LocalModelTextEngine, @unchecked Sendable {
    enum Step: Sendable {
        case output(String)
        case failDecode
    }

    let includesVisionProjector = false
    private let lock = NSLock()
    private var streamScripts: [[Step]]
    private var repairText: String
    private var _streamCalls = 0
    private var _repairCalls = 0
    private var _receivedPrompts: [String] = []
    private var _receivedInstructions: [String] = []

    var streamCallCount: Int { lock.withLock { _streamCalls } }
    var repairCallCount: Int { lock.withLock { _repairCalls } }
    var receivedPrompts: [String] { lock.withLock { _receivedPrompts } }
    var receivedInstructions: [String] { lock.withLock { _receivedInstructions } }

    init(streamScripts: [[Step]], repairText: String = "") {
        self.streamScripts = streamScripts
        self.repairText = repairText
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

    private func nextScript() -> [Step] {
        lock.withLock {
            guard !streamScripts.isEmpty else { return [] }
            return streamScripts.removeFirst()
        }
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
            _streamCalls += 1
            _receivedPrompts.append(prompt)
            _receivedInstructions.append(instructions)
        }
        var text = ""
        for step in nextScript() {
            switch step {
            case .output(let chunk):
                if Task.isCancelled { throw CancellationError() }
                text += chunk
                onOutput(chunk)
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
        let scripted: String = lock.withLock {
            _repairCalls += 1
            _receivedPrompts.append(prompt)
            _receivedInstructions.append(instructions)
            return repairText
        }
        return Self.result(text: scripted)
    }

    func shutdown() async {}
}

// MARK: - Harness pieces

@available(macOS 15.4, iOS 26.0, *)
private struct SearchHarness {
    let root: URL
    let engine: SearchChainEngine
    let runtime: LocalModelRuntime
    let store: LocalModelStore

    init(engine: SearchChainEngine) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-b238-\(UUID().uuidString)", isDirectory: true)
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
            idleUnloadInterval: .seconds(120),
            arbiter: HeavyRuntimeArbiter(),
            backgroundCanceller: LocalInferenceBackgroundCanceller()
        )
        self.store = LocalModelStore(root: modelRoot)
    }

    func adapter(ownerRunID: UUID? = nil) -> LocalProviderAdapter {
        LocalProviderAdapter(
            runtime: runtime,
            store: store,
            ownerRunID: ownerRunID,
            watchdogPolicy: .disabled
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@available(macOS 15.4, iOS 26.0, *)
private func searchModel() -> ModelProfile {
    ModelProfile(
        providerID: LocalProviderAdapter.providerProfile.id,
        remoteModelID: "qwen3.8-4b-heretic-mlx4",
        displayName: "Synthetic local",
        limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
        capabilities: [.text, .tools]
    )
}

private let webSearchSchema = ToolSchemaDescriptor(
    name: "web.search",
    description: "Search the public web",
    parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"},"provider":{"type":"string"}},"required":["query"]}"#
)

private let readFileSchema = ToolSchemaDescriptor(
    name: "workspace.readFile",
    description: "Read a workspace file",
    parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
)

@available(macOS 15.4, iOS 26.0, *)
private func searchRequest(
    _ content: String,
    toolSchemas: [ToolSchemaDescriptor],
    toolResults: [(callID: String, output: String)] = []
) -> ProviderStreamRequest {
    ProviderStreamRequest(
        provider: LocalProviderAdapter.providerProfile,
        model: searchModel(),
        messages: [(role: "user", content: content)],
        toolResults: toolResults,
        toolSchemas: toolSchemas,
        allToolNames: toolSchemas.map(\.name)
    )
}

@available(macOS 15.4, iOS 26.0, *)
private func collect(
    _ adapter: LocalProviderAdapter,
    _ request: ProviderStreamRequest
) async -> (events: [AgentEvent], error: Error?) {
    var events: [AgentEvent] = []
    do {
        for try await event in adapter.stream(request: request, credentials: ProviderCredentials()) {
            events.append(event)
        }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

private extension Array where Element == AgentEvent {
    var textDeltas: [String] {
        compactMap { event -> String? in
            if case .textDelta(let delta) = event { return delta.text }
            return nil
        }
    }

    var toolRequests: [ToolCall] {
        compactMap { event -> ToolCall? in
            if case .toolRequest(let call) = event { return call }
            return nil
        }
    }

    var errorEvents: [AgentEvent.NormalizedError] {
        compactMap { event -> AgentEvent.NormalizedError? in
            if case .error(let error) = event { return error }
            return nil
        }
    }

    var stopReasons: [AgentEvent.StopReason] {
        compactMap { event -> AgentEvent.StopReason? in
            if case .completed(let completion) = event { return completion.stopReason }
            return nil
        }
    }
}

// MARK: - Recording executor (two curated tools)

@available(macOS 15.4, iOS 26.0, *)
private final class TwoToolRecorder: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [ToolCall] = []
    let summaries: [String: String]

    init(summaries: [String: String]) {
        self.summaries = summaries
    }

    var calls: [ToolCall] { lock.withLock { _calls } }

    var allDescriptors: [ToolCatalog.Descriptor] {
        [
            ToolCatalog.Descriptor(
                name: "web.search",
                toolDescription: "Search the public web",
                parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"},"provider":{"type":"string"}},"required":["query"],"additionalProperties":false}"#,
                riskLabels: [.networkAccess],
                isSideEffecting: false
            ),
            ToolCatalog.Descriptor(
                name: "workspace.readFile",
                toolDescription: "Read a workspace file",
                parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#,
                riskLabels: [],
                isSideEffecting: false
            ),
        ]
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        allDescriptors.first { $0.name == name }
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        lock.withLock { _calls.append(call) }
        let summary = summaries[call.toolName] ?? "未配置的工具"
        return ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: summary,
            outputDigest: "digest-\(call.toolName)"
        )
    }
}

// MARK: - Suite

@Suite("Local search receipts")
struct LocalSearchReceiptTests {

    @Test("Screenshot-shaped prose plus fenced web.search envelope earns one bounded repair and a canonical tool event")
    @available(macOS 15.4, iOS 26.0, *)
    func fencedSearchProseRepairsToCanonicalToolEvent() async throws {
        // Device-observed shape: the model announces the call in prose and
        // places the provider envelope in a ```json fence. Mixed with prose,
        // the fence is a sample by design — never executed — so no receipt
        // can exist without the bounded repair.
        let fenced = """
        我先搜索今天的新闻：
        ```json
        {"tool_call":{"name":"web.search","arguments":{"query":"今天新闻","provider":"bochaWeb"}}}
        ```
        """
        let repairEnvelope = #"{"tool_call":{"name":"web.search","arguments":{"query":"今天新闻"}}}"#
        let engine = SearchChainEngine(streamScripts: [[.output(fenced)]], repairText: repairEnvelope)
        let harness = try SearchHarness(engine: engine)
        defer { harness.cleanUp() }

        let (events, error) = await collect(
            harness.adapter(),
            searchRequest("今天新闻", toolSchemas: [webSearchSchema])
        )
        #expect(error == nil)
        // The bounded correction ran exactly once and named the canonical tool.
        #expect(engine.repairCallCount == 1)
        #expect(engine.receivedInstructions.last?.contains("web.search") == true)
        // Exactly one canonical tool event; no fabricated prose answer.
        #expect(events.toolRequests.count == 1)
        #expect(events.toolRequests.first?.toolName == "web.search")
        guard let call = events.toolRequests.first else { return }
        let arguments = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any]
        #expect(arguments?["query"] as? String == "今天新闻")
        #expect(events.stopReasons == [.toolUse])
        #expect(events.errorEvents.isEmpty)
        // The raw call JSON was withheld from the visible stream, never shown
        // as a finished prose answer.
        #expect(events.textDeltas.allSatisfy { !$0.contains("tool_call") })
    }

    @Test("A whole-payload fenced envelope parses directly with no repair")
    @available(macOS 15.4, iOS 26.0, *)
    func wholePayloadFenceParsesWithoutRepair() async throws {
        // Boundary: when the ENTIRE answer is the fenced envelope, the
        // documented whole-payload protocol accepts it (fenced samples stay
        // non-executable only inside mixed prose).
        let fenced = """
        ```json
        {"tool_call":{"name":"web.search","arguments":{"query":"今天新闻","provider":"bochaWeb"}}}
        ```
        """
        let engine = SearchChainEngine(streamScripts: [[.output(fenced)]])
        let harness = try SearchHarness(engine: engine)
        defer { harness.cleanUp() }

        let (events, error) = await collect(
            harness.adapter(),
            searchRequest("今天新闻", toolSchemas: [webSearchSchema])
        )
        #expect(error == nil)
        #expect(engine.repairCallCount == 0)
        #expect(events.toolRequests.map(\.toolName) == ["web.search"])
        #expect(events.stopReasons == [.toolUse])
    }

    @Test("Fenced prose without a required invocation stays a non-executable sample")
    @available(macOS 15.4, iOS 26.0, *)
    func fencedSampleOnOrdinaryTurnNeverExecutes() async throws {
        // An ordinary (non-search-intent) turn where the model shows a fenced
        // sample: the execution parser must keep refusing fenced lines, and no
        // repair may fire (nothing required the invocation).
        let fenced = """
        示例格式：
        ```json
        {"tool_call":{"name":"web.search","arguments":{"query":"示例"}}}
        ```
        以上就是示例，不是要执行。
        """
        let engine = SearchChainEngine(streamScripts: [[.output(fenced)]])
        let harness = try SearchHarness(engine: engine)
        defer { harness.cleanUp() }

        let (events, error) = await collect(
            harness.adapter(),
            searchRequest("给我讲讲工具调用的概念", toolSchemas: [webSearchSchema])
        )
        #expect(error == nil)
        #expect(engine.repairCallCount == 0)
        #expect(events.toolRequests.isEmpty)
        #expect(events.errorEvents.isEmpty)
        #expect(events.stopReasons == [.endTurn])
    }

    @Test("Two tools across two turns keep their receipts through the real run service")
    @available(macOS 15.4, iOS 26.0, *)
    func twoToolsAcrossTwoTurnsKeepReceipts() async throws {
        let engine = SearchChainEngine(streamScripts: [
            [.output(#"{"tool_call":{"name":"web.search","arguments":{"query":"今天新闻"}}}"#)],
            [.output(#"{"tool_call":{"name":"workspace.readFile","arguments":{"path":"a.md"}}}"#)],
            [.output("已检索今天的新闻，并读取了 a.md。")]
        ])
        let harness = try SearchHarness(engine: engine)
        defer { harness.cleanUp() }

        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let conversationID = UUID()
        try await conversations.saveConversation(.init(
            id: conversationID,
            title: "Synthetic local search receipts",
            createdAt: Date(),
            updatedAt: Date()
        ))
        let model = searchModel()
        let recorder = TwoToolRecorder(summaries: [
            "web.search": "bochaWeb: 5 results for 今天新闻",
            "workspace.readFile": "a.md contents: hello"
        ])
        let service = ConversationRunService(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: LocalProviderAdapter.providerProfile,
                model: model,
                allowedToolNames: ["web.search", "workspace.readFile"],
                maxProviderRetries: 1,
                providerRetryBaseDelay: 0.05,
                providerRetryMaxDelay: 0.1,
                providerRetryJitterRatio: 0
            ),
            adapter: harness.adapter(),
            policy: TaskFullAccessPolicy(),
            executor: recorder,
            conversationStore: conversations,
            runStore: SQLiteRunStore(database: database)
        )
        try await service.start(goal: "今天新闻")

        let snapshot = await service.snapshot()
        #expect(snapshot.stateName == "completed")
        #expect(engine.streamCallCount == 3)
        // Valid envelopes executed directly — no repair was needed.
        #expect(engine.repairCallCount == 0)
        // Both tools executed, in provider order.
        #expect(recorder.calls.map(\.toolName) == ["web.search", "workspace.readFile"])
        // Turn 2 carried the web.search receipt; turn 3 carried both receipts.
        let prompts = engine.receivedPrompts
        #expect(prompts.count == 3)
        #expect(prompts[1].contains("bochaWeb: 5 results for 今天新闻"))
        #expect(prompts[2].contains("bochaWeb: 5 results for 今天新闻"))
        #expect(prompts[2].contains("a.md contents: hello"))
    }

    @Test("Live-web search intent requires the invocation only with the canonical tool offered")
    @available(macOS 15.4, iOS 26.0, *)
    func searchIntentClassifierBoundaries() throws {
        // The curated live-web classification (LocalModelToolPolicy) requires
        // the call when web.search is actually presented…
        let required = LocalProviderAdapter.buildPrompt(
            for: searchRequest("今天新闻", toolSchemas: [webSearchSchema])
        )
        #expect(required.requiresToolCall)

        // …and stays honest when web.search is not offered: no forced call to
        // a missing capability (the truthful-notice path).
        let missing = LocalProviderAdapter.buildPrompt(
            for: searchRequest("今天新闻", toolSchemas: [readFileSchema])
        )
        #expect(missing.requiresToolCall == false)

        // Capability inventory questions keep the informational path.
        let inventory = LocalProviderAdapter.buildPrompt(
            for: searchRequest("有哪些可用的新闻搜索工具", toolSchemas: [webSearchSchema])
        )
        #expect(inventory.requiresToolCall == false)

        // Definitional questions carry no execution cue.
        let definitional = LocalProviderAdapter.buildPrompt(
            for: searchRequest("什么是网页", toolSchemas: [webSearchSchema])
        )
        #expect(definitional.requiresToolCall == false)

        // Direct-URL fetch turns keep their own flow.
        let directFetch = LocalProviderAdapter.buildPrompt(
            for: searchRequest("抓取 https://example.com 的网页", toolSchemas: [webSearchSchema])
        )
        #expect(directFetch.requiresToolCall == false)

        // A receipt continuation answers from the receipt instead of
        // re-invoking the same call.
        let continuation = LocalProviderAdapter.buildPrompt(
            for: searchRequest(
                "今天新闻",
                toolSchemas: [webSearchSchema],
                toolResults: [("local-1", "bochaWeb: 5 results")]
            )
        )
        #expect(continuation.requiresToolCall == false)

        // The fuzzy-action contract is unchanged for plain file lookups.
        let fileLookup = LocalProviderAdapter.buildPrompt(
            for: searchRequest("读取 a.md 文件", toolSchemas: [readFileSchema])
        )
        #expect(fileLookup.requiresToolCall)
    }
}
