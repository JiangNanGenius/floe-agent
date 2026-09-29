// FloeLocalModelsQualification — Build 235 deterministic contract gate.
//
// Focus: the device failure where a local Qwen model printed prose plus a JSON
// envelope naming the *search provider* `bochaWeb` instead of the registered
// `web.search` tool, and reported success without any tool running.
//
// This host is weight-free, network-free and deterministic: a scripted text
// engine stands in for model weights. It drives the production
// LocalProviderAdapter with the REAL WebSearchTool schema and a
// production-shaped (synthetic) web.search result payload. It is NOT iPad or
// real-weight acceptance — real model honesty is established separately by the
// MLX qualification host. What this proves at the source/contract layer:
//
//   1. every WebSearchProviderKind backend enum (bochaWeb, bochaAI, …) is
//      rejected as a tool name — none is aliased or executed,
//   2. the canonical `web.search` envelope parses/executes,
//   3. prose + a rejected-name envelope is withheld, correctively repaired
//      once into `web.search`, and never shown as a successful answer,
//   4. a production-shaped search result (which embeds provider raw values and
//      real result items) grounds a receipt continuation: the items reach the
//      continuation prompt verbatim, no repeat call is required, and the
//      synthetic/no-live marker is preserved (no-fabrication gate).
//
// Exits non-zero and prints JSON evidence on any failure.

import Foundation
import Synchronization
import FloeCore
import FloeModels
import FloeProviders
import FloeExecution
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

// MARK: - Evidence

final class Evidence: @unchecked Sendable {
    private let state = Mutex<[[String: Any]]>([])

    func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        state.withLock { $0.append(["check": name, "passed": passed, "detail": detail]) }
    }

    var allPassed: Bool {
        state.withLock { $0.allSatisfy { $0["passed"] as? Bool == true } }
    }

    func json() -> String {
        let snapshot = state.withLock { $0 }
        let object: [String: Any] = [
            "event": "build235-local-models-qualification",
            "platform": "macOS-host-deterministic-not-iPad",
            "realWeights": false,
            "network": false,
            "passed": snapshot.allSatisfy { $0["passed"] as? Bool == true },
            "checks": snapshot
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{\"passed\":false}"
    }
}

// MARK: - Production-shaped fixtures

enum Fixtures {
    static let modelID = "qwen3.8-4b-heretic-mlx4"

    static func model() -> ModelProfile {
        ModelProfile(
            providerID: LocalProviderAdapter.providerProfile.id,
            remoteModelID: modelID,
            displayName: "Synthetic local",
            limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
    }

    /// Exact production descriptor (name/description/JSON Schema).
    static let webSearch = ToolSchemaDescriptor(
        name: WebSearchTool.name,
        description: WebSearchTool.toolDescription,
        parametersJSON: WebSearchTool.parametersJSON
    )

    static let offeredTools = [webSearch]

    static let newsUserText = "那你能尝试调用一下工具，随便搜索一下今天的新闻吗"

    static func request(
        userText: String,
        toolResults: [(callID: String, output: String)] = [],
        pendingToolCalls: [ToolCall] = [],
        replayedToolPairs: [ReplayedToolPair] = []
    ) -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: model(),
            messages: [
                (role: "system", content: "Runtime envelope: synthetic qualification workspace."),
                (role: "user", content: userText)
            ],
            toolResults: toolResults,
            pendingToolCalls: pendingToolCalls,
            replayedToolPairs: replayedToolPairs,
            toolSchemas: offeredTools,
            allToolNames: offeredTools.map(\.name)
        )
    }

    static func canonicalEnvelope(query: String) -> String {
        #"{"tool_call":{"name":"web.search","arguments":{"query":"\#(query)"}}}"#
    }

    /// Byte-for-byte key shape produced by WebSearchTool.execute (sorted keys),
    /// with the provider enum raw value embedded exactly as in production.
    static func productionShapedResultJSON(marker: String, withItems: Bool) -> String {
        let results: [[String: Any]]
        if withItems {
            results = [
                ["citation": "src-1", "title": "SYNTHETIC ITEM \(marker)-A 示例城市发布示例交通公告",
                 "url": "https://example.invalid/a", "snippet": "synthetic snippet A",
                 "source": "示例来源", "publishedAt": "", "provider": "bochaWeb"],
                ["citation": "src-2", "title": "SYNTHETIC ITEM \(marker)-B 示例科技公司发布示例芯片",
                 "url": "https://example.invalid/b", "snippet": "synthetic snippet B",
                 "source": "示例来源", "publishedAt": "", "provider": "bochaWeb"]
            ]
        } else {
            results = []
        }
        let payload: [String: Any] = [
            "query": "今天新闻",
            "providers": ["bochaWeb"],
            "failures": [],
            "results": results
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Scripted engine

final class ScriptedEngine: LocalModelTextEngine, @unchecked Sendable {
    struct Capture: Sendable {
        let instructions: String
        let prompt: String
        let tools: [ToolSchemaDescriptor]
    }

    let includesVisionProjector = false
    private let scripts: [String]
    private let state = Mutex<(index: Int, captures: [Capture])>((0, []))

    var generationCount: Int { state.withLock { $0.index } }

    var lastCapture: Capture? { state.withLock { $0.captures.last } }

    init(_ scripts: [String]) { self.scripts = scripts }

    func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult {
        let chosen: String = state.withLock { state in
            let value = scripts[min(state.index, scripts.count - 1)]
            state.captures.append(Capture(instructions: instructions, prompt: prompt, tools: tools))
            state.index += 1
            return value
        }
        return LocalGenerationResult(
            text: chosen, inputTokens: 12, outputTokens: 8,
            timeToFirstTokenMs: 2, generationDurationMs: 4
        )
    }

    func shutdown() async {}
}

struct Harness {
    let root: URL
    let engine: ScriptedEngine
    let runtime: LocalModelRuntime
    let store: LocalModelStore

    init(engine: ScriptedEngine) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-b235-qual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.engine = engine
        self.store = LocalModelStore(root: root)
        self.runtime = LocalModelRuntime(
            store: store,
            makeEngine: { _, _, _, _ in engine },
            measureAvailableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            modelSnapshot: { modelID in
                (directory: root.appendingPathComponent(modelID, isDirectory: true), weightBytes: 1_000_000)
            },
            preflightSettleSamples: 0,
            preflightSettleInterval: .milliseconds(1),
            idleUnloadInterval: .seconds(120),
            arbiter: HeavyRuntimeArbiter()
        )
    }

    func adapter() -> LocalProviderAdapter { LocalProviderAdapter(runtime: runtime, store: store) }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@main
struct Qualification {
    static func main() async {
        let evidence = Evidence()
        let offered = Set(Fixtures.offeredTools.map(\.name))

        // 1. Every provider/backend enum is rejected as a tool name.
        for kind in WebSearchProviderKind.allCases {
            let envelope = #"{"tool_call":{"name":"\#(kind.rawValue)","arguments":{"query":"x"}}}"#
            let calls = (try? LocalProviderAdapter.toolCalls(from: envelope, offeredToolNames: offered)) ?? []
            evidence.record(
                "provider-enum-not-a-tool[\(kind.rawValue)]",
                calls.isEmpty,
                "parsed=\(calls.map(\.toolName))"
            )
        }

        // 2. Canonical web.search envelope parses to the registered tool.
        do {
            let calls = try LocalProviderAdapter.toolCalls(
                from: Fixtures.canonicalEnvelope(query: "今天新闻"),
                offeredToolNames: offered
            )
            evidence.record("canonical-call-parses",
                            calls.map(\.toolName) == ["web.search"],
                            "parsed=\(calls.map(\.toolName))")
        } catch {
            evidence.record("canonical-call-parses", false, "\(error)")
        }

        // 3. Prose + rejected-name envelope -> withheld, one corrective repair
        //    -> executes web.search; the invented name never executes or shows.
        do {
            let rejected = "好的，我来帮你搜索一下今天的新闻。\n"
                + #"{"tool_call":{"name":"bochaWeb","arguments":{"query":"今天新闻"}}}"#
            let engine = ScriptedEngine([rejected, Fixtures.canonicalEnvelope(query: "今天新闻")])
            let harness = try Harness(engine: engine)
            defer { harness.cleanUp() }
            var calls: [ToolCall] = []
            var visible = ""
            var reasons: [AgentEvent.StopReason] = []
            for try await event in harness.adapter().stream(
                request: Fixtures.request(userText: Fixtures.newsUserText),
                credentials: ProviderCredentials()
            ) {
                switch event {
                case .toolRequest(let call): calls.append(call)
                case .textDelta(let delta): visible += delta.text
                case .completed(let info): reasons.append(info.stopReason)
                default: break
                }
            }
            evidence.record("rejected-name-executes-canonical",
                            calls.map(\.toolName) == ["web.search"] && reasons == [.toolUse],
                            "calls=\(calls.map(\.toolName)) reasons=\(reasons) generations=\(engine.generationCount)")
            evidence.record("rejected-name-never-visible",
                            !visible.contains("bochaWeb") && !visible.contains("tool_call"),
                            "visibleCharacters=\(visible.count)")
            evidence.record("corrective-repair-single-bounded",
                            engine.generationCount == 2
                                && (engine.lastCapture?.prompt.contains("not an offered tool") == true)
                                && (engine.lastCapture?.prompt.contains("web.search") == true),
                            "generations=\(engine.generationCount)")
        } catch {
            evidence.record("rejected-name-repair-flow", false, "\(error)")
        }

        // 4a. Production-shaped result WITH real items grounds the receipt
        //     continuation: items reach the prompt, no repeat call required.
        do {
            let marker = "8C44"
            let resultJSON = Fixtures.productionShapedResultJSON(marker: marker, withItems: true)
            let itemTitle = "SYNTHETIC ITEM \(marker)-A"
            let receipt = "receipt marker: FLOE_SEARCH_RECEIPT_\(marker). synthetic fixture "
                + "(no live search performed). Tool result JSON:\n\(resultJSON)"
            let call = try ToolCall(
                id: "local-qual-1", toolName: "web.search",
                argumentsJSON: Data(#"{"query":"今天新闻"}"#.utf8), scope: .local
            )
            let groundedAnswer = "根据工具返回（FLOE_SEARCH_RECEIPT_\(marker)，synthetic fixture）：\(itemTitle) …"
            let engine = ScriptedEngine([groundedAnswer])
            let harness = try Harness(engine: engine)
            defer { harness.cleanUp() }
            var answer = ""
            var furtherCalls: [ToolCall] = []
            let request = Fixtures.request(
                userText: Fixtures.newsUserText,
                toolResults: [(callID: call.id, output: receipt)],
                pendingToolCalls: [call]
            )
            for try await event in harness.adapter().stream(
                request: request, credentials: ProviderCredentials()
            ) {
                if case .textDelta(let delta) = event { answer += delta.text }
                if case .toolRequest(let newCall) = event { furtherCalls.append(newCall) }
            }
            let prompt = engine.lastCapture?.prompt ?? ""
            evidence.record("receipt-items-reach-prompt",
                            prompt.contains(itemTitle) && prompt.contains("bochaWeb"),
                            "item present=\(prompt.contains(itemTitle))")
            evidence.record("receipt-continuation-no-repeat-call",
                            furtherCalls.isEmpty && engine.generationCount == 1 && answer.contains(itemTitle),
                            "furtherCalls=\(furtherCalls.count) generations=\(engine.generationCount)")
        } catch {
            evidence.record("receipt-items-grounding", false, "\(error)")
        }

        // 4b. Count-only / zero-item result: the continuation prompt carries the
        //     no-live/synthetic marker and still does not require a new call;
        //     the model must answer from the (empty) evidence, never invent.
        do {
            let resultJSON = Fixtures.productionShapedResultJSON(marker: "7A31", withItems: false)
            let receipt = "receipt marker: FLOE_SEARCH_RECEIPT_7A31. synthetic fixture "
                + "(no live search performed): 0 usable normalized results.\n\(resultJSON)"
            let call = try ToolCall(
                id: "local-qual-2", toolName: "web.search",
                argumentsJSON: Data(#"{"query":"今天新闻"}"#.utf8), scope: .local
            )
            let continuation = Fixtures.request(
                userText: Fixtures.newsUserText,
                toolResults: [(callID: call.id, output: receipt)],
                pendingToolCalls: [call]
            )
            let continuationBuild = LocalProviderAdapter.buildPrompt(for: continuation)
            evidence.record(
                "empty-receipt-no-required-repeat",
                !continuationBuild.requiresToolCall
                    && continuationBuild.text.contains("synthetic fixture")
                    && continuationBuild.text.contains("never invent facts"),
                "requiresToolCall=\(continuationBuild.requiresToolCall)"
            )
            // The empty result JSON itself must never be a tool invocation.
            let callsFromResult = try LocalProviderAdapter.toolCalls(
                from: resultJSON, offeredToolNames: offered
            )
            evidence.record("result-json-is-not-a-call", callsFromResult.isEmpty,
                            "parsed=\(callsFromResult.map(\.toolName))")
        } catch {
            evidence.record("empty-receipt-gate", false, "\(error)")
        }

        print(evidence.json())
        exit(evidence.allPassed ? 0 : 1)
    }
}
