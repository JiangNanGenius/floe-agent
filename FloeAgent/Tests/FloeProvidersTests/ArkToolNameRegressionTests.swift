// FloeProvidersTests — Volcengine Ark function-name regression.
//
// The supplied screenshot shows an `ark-code-latest` Agent Plan turn failing
// before any answer with:
//   {"error":{"code":"InvalidParameter","message":"function name is invalid
//   Request id: …","param":"","type":"BadRequest"}}
// Ark's documented custom-tool/function grammar accepts only ASCII letters,
// digits, underscores and hyphens; canonical Floe names are dotted. Agent
// Plan is stored as `.custom`, so the old host-only Kimi rule never applied.
// These tests pin exact Ark API-root detection (PAYG `/api/v3` and Agent Plan
// `/api/plan/v3`, including custom profiles), one deterministic collision
// table shared by definitions/history/pending names across all adapters, and
// the explicit proxy override boundary. All fixtures are synthetic; no real
// keys, endpoints, user text or transcript content are used here.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeModels
@testable import FloeProviders

@Suite("FloeProviders.ArkToolNameRegression")
struct ArkToolNameRegressionTests {

    /// Ark documents custom tool names as ASCII letters, digits, underscores
    /// and hyphens. There is no documented letter-initial requirement.
    private static let arkGrammar = "^[A-Za-z0-9_-]+$"

    private func satisfiesArkGrammar(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: Self.arkGrammar, options: .regularExpression) != nil
    }

    private func provider(
        kind: ProviderKind = .custom,
        endpoint: String,
        displayName: String? = nil,
        presetID: String? = nil,
        wire: ModelProtocol = .openAIChatCompletions,
        toolNameCompatibility: Bool = false
    ) -> ProviderProfile {
        ProviderProfile(
            kind: kind,
            wireProtocol: wire,
            baseURL: try! #require(URL(string: endpoint)),
            displayName: displayName,
            presetID: presetID,
            toolNameCompatibility: toolNameCompatibility
        )
    }

    private func model(
        _ id: String,
        capabilities: ModelCapabilities = [.text, .tools]
    ) -> ModelProfile {
        ModelProfile(
            providerID: UUID(),
            remoteModelID: id,
            displayName: id,
            limits: .init(contextTokens: 8192, maxOutputTokens: 2048),
            capabilities: capabilities
        )
    }

    private func call(_ id: String, _ canonical: String) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: canonical,
            argumentsJSON: Data(#"{"q":"x"}"#.utf8),
            scope: .local
        )
    }

    private func result(_ callID: String, _ summary: String = "prior output") -> ToolResult {
        ToolResult(callID: callID, status: .ok, outputSummary: summary, outputDigest: "digest")
    }

    private func request(
        for profile: ProviderProfile,
        schemas: [String],
        ceiling: [String] = [],
        pairs: [(String, String)] = [],
        pending: [(String, String)] = [],
        results: [(String, String)] = [],
        withImage: Bool = false,
        modelID: String = "ark-code-latest"
    ) throws -> ProviderStreamRequest {
        var userParts: [ProviderContentPart] = [.text("看看这张图")]
        if withImage {
            userParts.append(.imageData(
                mimeType: "image/jpeg",
                base64: "U1lOVEhFVElDLUJZVEVT"
            ))
        }
        return ProviderStreamRequest(
            provider: profile,
            model: model(modelID, capabilities: [.text, .tools, .vision]),
            contentMessages: [
                .init(role: "system", content: [.text("You are Floe.")]),
                .init(role: "user", content: userParts)
            ],
            toolResults: results.map { (callID: $0.0, output: $0.1) },
            pendingToolCalls: try pending.map { try call($0.0, $0.1) },
            replayedToolPairs: try pairs.map {
                ReplayedToolPair(call: try call($0.0, $0.1), result: result($0.0))
            },
            toolSchemas: schemas.map {
                ToolSchemaDescriptor(
                    name: $0,
                    description: "synthetic descriptor",
                    parametersJSON: "{}"
                )
            },
            allToolNames: ceiling.isEmpty ? schemas : ceiling
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func allNameValues(_ node: Any) -> [String] {
        if let dict = node as? [String: Any] {
            var found: [String] = []
            if let name = dict["name"] as? String { found.append(name) }
            for (key, value) in dict where key != "name" {
                found.append(contentsOf: allNameValues(value))
            }
            return found
        }
        if let array = node as? [Any] { return array.flatMap { allNameValues($0) } }
        return []
    }

    private let arkPAYGRoot = "https://ark.cn-beijing.volces.com/api/v3"
    private let arkPlanRoot = "https://ark.cn-beijing.volces.com/api/plan/v3"

    // MARK: - Exact route detection

    @Test("PAYG and Agent Plan API roots get Ark wire names; lookalikes do not")
    func exactArkRoutesOnly() throws {
        #expect(ProviderBillingEndpoint.resolve(
            ProviderPreset.volcengineAgentPlan.defaultBaseURL
        ) == .volcengineAgentPlan)
        #expect(ProviderBillingEndpoint.resolve(
            ProviderPreset.volcengineArk.defaultBaseURL
        ) == nil)

        let roots: [(String, ProviderKind)] = [
            (arkPAYGRoot, .volcengineArk),
            (arkPAYGRoot + "/", .volcengineArk),
            (arkPAYGRoot, .custom),
            (arkPlanRoot, .custom),
            (arkPlanRoot + "/", .custom)
        ]
        for (endpoint, kind) in roots {
            let profile = provider(kind: kind, endpoint: endpoint)
            #expect(CompatToolNames.requiresArkNames(profile))
            #expect(CompatToolNames.usesWireSafeNames(profile))
            #expect(CompatToolNames.wireName("workspace.readFile", for: profile) == "workspace_readFile")
            #expect(CompatToolNames.wireName("tools.search", for: profile) == "tools_search")
        }

        // Real preset identities, including the Agent Plan preset that stores
        // `.custom`, are identified by their exact endpoint.
        #expect(CompatToolNames.requiresArkNames(
            provider(endpoint: ProviderPreset.volcengineArk.defaultBaseURL.absoluteString)
        ))
        #expect(CompatToolNames.requiresArkNames(
            provider(
                endpoint: ProviderPreset.volcengineAgentPlan.defaultBaseURL.absoluteString,
                presetID: "volcengine-agent-plan"
            )
        ))
        // A legacy profile that saved the plan URL under the PAYG kind is
        // still on the same Ark route.
        #expect(CompatToolNames.requiresArkNames(
            provider(kind: .volcengineArk, endpoint: arkPlanRoot)
        ))

        for endpoint in [
            "https://ark.cn-beijing.volces.com.attacker.example/api/plan/v3",
            "https://notark.cn-beijing.volces.com/api/plan/v3",
            "https://ark.cn-beijing.volces.com:8443/api/plan/v3",
            "http://ark.cn-beijing.volces.com/api/plan/v3",
            "https://ark.cn-beijing.volces.com/api/coding/v3",
            "https://ark.cn-beijing.volces.com/api/v3/responses",
            "https://ark.cn-beijing.volces.com/api/plan/v3?x=1",
            "https://ark-proxy.example.test/api/v3",
            "https://ark.cn-beijing.volces.com.evil.test/api/v3"
        ] {
            let profile = provider(
                endpoint: endpoint,
                displayName: "Ark Agent Plan 代理",
                presetID: "volcengine-agent-plan"
            )
            #expect(!CompatToolNames.requiresArkNames(profile), "\(endpoint)")
            #expect(!CompatToolNames.usesWireSafeNames(profile), "\(endpoint)")
            #expect(CompatToolNames.wireName("workspace.readFile", for: profile) == "workspace.readFile")
            #expect(CompatToolNames.wireTable(for: try request(for: profile, schemas: ["tools.search"])).isEmpty)
        }

        // A proxy keeps the existing explicit saved opt-in: dot folding only,
        // no Ark-specific table or letter prefix.
        let proxy = provider(
            endpoint: "https://gateway.example.test/v1",
            displayName: "My Ark-compatible proxy",
            toolNameCompatibility: true
        )
        #expect(CompatToolNames.usesWireSafeNames(proxy))
        #expect(!CompatToolNames.requiresArkNames(proxy))
        #expect(CompatToolNames.wireName("workspace.readFile", for: proxy) == "workspace_readFile")
        #expect(CompatToolNames.wireName("2fa.backupCode", for: proxy) == "2fa_backupCode")
        #expect(CompatToolNames.wireTable(for: try request(for: proxy, schemas: ["tools.search"])).isEmpty)
    }

    // MARK: - Deterministic table

    @Test("every table spelling satisfies Ark grammar and reverses exactly")
    func tableIsGrammarExactAndReversible() throws {
        let profile = provider(endpoint: arkPlanRoot)
        let canonicalNames = [
            "tools.search", "tools.list", "skill.read", "exec.shell",
            "checklist.updatePlan", "workspace.readFile", "media.transcribe",
            "2fa.backupCode", "_leading.underscore", "-dash.first",
            "检索.query", "a tool/name", "UPPER.case"
        ]
        let req = try request(for: profile, schemas: canonicalNames)
        let table = CompatToolNames.wireTable(for: req)
        #expect(table.count == canonicalNames.count)
        for canonical in canonicalNames {
            let wire = try #require(table[canonical])
            #expect(satisfiesArkGrammar(wire), "\(canonical) -> \(wire)")
            #expect(!wire.contains("."))
            #expect(CompatToolNames.canonicalName(wire, request: req) == canonical)
        }
        // Value uniqueness is what makes exact reverse recovery total.
        #expect(Set(table.values).count == table.count)
        #expect(table["2fa.backupCode"] == "2fa_backupCode")
        #expect(table["检索.query"] == "___query")
        #expect(table["a tool/name"] == "a_tool_name")
        // Canonical runtime names are never mutated by table construction.
        #expect(req.toolSchemas.map(\.name) == canonicalNames)
    }

    @Test("history-only name colliding with an advertised tool gets a distinct spelling")
    func historyOnlyCollision() throws {
        let profile = provider(endpoint: arkPlanRoot)
        let req = try request(
            for: profile,
            schemas: ["workspace.readFile"],
            ceiling: ["workspace.readFile"],
            pairs: [("c9", "workspace_readFile")]
        )
        let table = CompatToolNames.wireTable(for: req)
        // '.' sorts before '_': the advertised dotted name keeps the base
        // spelling; the history-only underscored canonical gets "_2".
        #expect(table["workspace.readFile"] == "workspace_readFile")
        #expect(table["workspace_readFile"] == "workspace_readFile_2")
        #expect(CompatToolNames.canonicalName("workspace_readFile", request: req) == "workspace.readFile")
        #expect(CompatToolNames.canonicalName("workspace_readFile_2", request: req) == "workspace_readFile")
        // Unknown names stay honest pass-throughs.
        #expect(CompatToolNames.canonicalName("ghost.tool", request: req) == "ghost.tool")
        #expect(CompatToolNames.canonicalName("totally_unknown", request: req) == "totally_unknown")
    }

    // MARK: - Actual chat wire body

    @Test("Agent Plan ark-code-latest chat body carries grammar-exact names, image and history")
    func chatBodyCoversAllOccurrences() throws {
        let profile = provider(
            endpoint: arkPlanRoot,
            displayName: "火山方舟 Agent Plan",
            presetID: "volcengine-agent-plan"
        )
        let schemas = [
            "tools.search", "tools.list", "skill.search", "skill.read",
            "exec.shell", "checklist.readPlan", "checklist.updatePlan",
            "workspace.readFile", "browser.screenshot", "2fa.backupCode"
        ]
        let req = try request(
            for: profile,
            schemas: schemas,
            ceiling: schemas + ["media.transcribe"],
            pairs: [("c1", "workspace.readFile")],
            pending: [("c2", "2fa.backupCode")],
            results: [("c2", "done")],
            withImage: true
        )
        let body = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: req))
        let names = allNameValues(body)
        #expect(!names.isEmpty)
        #expect(names.allSatisfy { satisfiesArkGrammar($0) })
        #expect(!names.contains { $0.contains(".") })

        let table = CompatToolNames.wireTable(for: req)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == schemas.count)
        for (index, entry) in tools.enumerated() {
            let function = try #require(entry["function"] as? [String: Any])
            #expect(function["name"] as? String == table[schemas[index]])
        }
        #expect(body["tool_choice"] as? String == "auto")

        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first {
            ($0["role"] as? String) == "assistant" && ($0["tool_calls"] as? [Any])?.count == 1
        })
        let replayed = try #require(((assistant["tool_calls"] as? [[String: Any]])?.first)?["function"] as? [String: Any])
        #expect(replayed["name"] as? String == "workspace_readFile")
        let toolMessage = try #require(messages.first { ($0["role"] as? String) == "tool" })
        #expect(toolMessage["tool_call_id"] as? String == "c1")
        let lastTool = try #require(messages.last { ($0["role"] as? String) == "tool" })
        #expect(lastTool["tool_call_id"] as? String == "c2")
        let pendingEntry = try #require(messages.last { ($0["role"] as? String) == "assistant" })
        let pendingCall = try #require(((pendingEntry["tool_calls"] as? [[String: Any]])?.first)?["function"] as? [String: Any])
        #expect(pendingCall["name"] as? String == "2fa_backupCode")

        // The synthetic image remains an image part; name hardening must not
        // alter the attachment.
        let user = try #require(messages.first { ($0["role"] as? String) == "user" })
        let parts = try #require(user["content"] as? [[String: Any]])
        #expect(parts.contains {
            ($0["image_url"] as? [String: Any])?["url"] as? String
                == "data:image/jpeg;base64,U1lOVEhFVElDLUJZVEVT"
        })

        // Restored history and canonical descriptors round-trip exactly.
        #expect(req.toolSchemas.map(\.name) == schemas)
        #expect(CompatToolNames.canonicalName("workspace_readFile", request: req) == "workspace.readFile")
        #expect(CompatToolNames.canonicalName("2fa_backupCode", request: req) == "2fa.backupCode")
    }

    @Test("Responses and Anthropic adapters use the same Ark table for history")
    func crossAdapterParity() throws {
        let schemas = ["workspace.readFile", "media.transcribe"]
        let chatProfile = provider(endpoint: arkPlanRoot)
        let base = try request(for: chatProfile, schemas: schemas, pairs: [("c1", "media.transcribe")])
        let expected = CompatToolNames.wireTable(for: base)

        let responses = try jsonObject(OpenAIResponsesAdapter().buildBody(from: try request(
            for: provider(endpoint: arkPlanRoot, wire: .openAIResponses),
            schemas: schemas,
            pairs: [("c1", "media.transcribe")]
        )))
        let responsesTools = try #require(responses["tools"] as? [[String: Any]])
        #expect(responsesTools.compactMap { $0["name"] as? String } == schemas.map { expected[$0]! })
        #expect(allNameValues(responses).allSatisfy { satisfiesArkGrammar($0) })

        let anthropic = try jsonObject(AnthropicMessagesAdapter().buildBody(from: try request(
            for: provider(endpoint: arkPlanRoot, wire: .anthropicMessages),
            schemas: schemas,
            pairs: [("c1", "media.transcribe")]
        )))
        let anthropicTools = try #require(anthropic["tools"] as? [[String: Any]])
        #expect(anthropicTools.compactMap { $0["name"] as? String } == schemas.map { expected[$0]! })
        #expect(allNameValues(anthropic).allSatisfy { satisfiesArkGrammar($0) })
        #expect(CompatToolNames.canonicalName(expected["media.transcribe"]!, request: base) == "media.transcribe")
    }
}
