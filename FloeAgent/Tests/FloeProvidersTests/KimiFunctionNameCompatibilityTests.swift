// Kimi/Moonshot function-name grammar compatibility.
//
// Build300 evidence (redacted facts from the user's uploaded diagnostic):
//   providerRequestStarted protocol=chat host=api.kimi.com model=k3.1-pro
//   messages=2 tools=23 bodyBytes=242451, with the same exact server error
//   {"error":{"type":"invalid_request_error","message":"function name is
//   invalid, must start with a letter and can contain letters, numbers,
//   underscores, and dashes"}} on 4 start attempts (8 identical error
//   mentions), immediately before the answer. The chat screenshot showed
//   Agent mode with an IMG_9719.JPG photo attachment.
// The uploaded report logged the exact function-name grammar rejection, the
// api.kimi.com chat host and tools=23, but no raw tool names or compatibility
// flag; attributing the rejection to canonical dotted names (`tools.search`,
// `exec.shell`, …) reaching the wire raw is this lane's source-path diagnosis
// of the serializer, not a logged fact. The logs do show an immediate request
// rejection, not an image decode/size failure.
// These tests pin the wire-boundary repair: exact official-host detection,
// the Moonshot grammar `^[A-Za-z][A-Za-z0-9_-]*$`, one complete deterministic
// collision table shared by every outbound occurrence (definitions, replayed
// assistant history, pending calls, all three adapters) and the inbound
// streamed-name recovery, with unrelated providers byte-for-byte unchanged.
// All fixtures are synthetic; no real keys, endpoints or user content.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeModels
@testable import FloeProviders

@Suite("FloeProviders.KimiFunctionNameCompatibility")
struct KimiFunctionNameCompatibilityTests {

    // MARK: - Synthetic fixtures

    private static let kimiGrammar = "^[A-Za-z][A-Za-z0-9_-]*$"

    private func satisfiesKimiGrammar(_ name: String) -> Bool {
        name.range(of: Self.kimiGrammar, options: .regularExpression) != nil
    }

    private func provider(_ endpoint: String, displayName: String? = nil,
                          wire: ModelProtocol = .openAIChatCompletions,
                          toolNameCompatibility: Bool = false) -> ProviderProfile {
        ProviderProfile(kind: .custom, wireProtocol: wire,
                        baseURL: try! #require(URL(string: endpoint)),
                        displayName: displayName,
                        toolNameCompatibility: toolNameCompatibility)
    }

    private func model(_ id: String, capabilities: [ModelCapability] = [.text, .tools]) -> ModelProfile {
        ModelProfile(providerID: UUID(), remoteModelID: id, displayName: id,
                     limits: .init(contextTokens: 4096, maxOutputTokens: 1024),
                     capabilities: capabilities)
    }

    private func call(_ id: String, _ canonical: String) throws -> ToolCall {
        try ToolCall(id: id, toolName: canonical, argumentsJSON: Data(#"{"q":"x"}"#.utf8), scope: .local)
    }

    private func result(_ callID: String, _ summary: String) -> ToolResult {
        ToolResult(callID: callID, status: .ok, outputSummary: summary, outputDigest: "digest")
    }

    private func request(
        for profile: ProviderProfile,
        schemas: [String],
        ceiling: [String] = [],
        pairs: [(String, String)] = [],
        pending: [(String, String)] = [],
        results: [(String, String)] = [],
        withImage: Bool = false
    ) throws -> ProviderStreamRequest {
        var userParts: [ProviderContentPart] = [.text("看看这张图")]
        if withImage { userParts.append(.imageData(mimeType: "image/jpeg", base64: "U1lOVEhFVElDLUJZVEVT")) }
        return ProviderStreamRequest(
            provider: profile,
            model: model("k3.1-pro", capabilities: [.text, .tools, .vision]),
            contentMessages: [
                .init(role: "system", content: [.text("You are Floe.")]),
                .init(role: "user", content: userParts)
            ],
            toolResults: results.map { (callID: $0.0, output: $0.1) },
            pendingToolCalls: try pending.map { try call($0.0, $0.1) },
            replayedToolPairs: try pairs.map {
                // The settled result carries the SAME call id as its call —
                // exactly the runtime's pairing contract.
                ReplayedToolPair(call: try call($0.0, $0.1), result: result($0.0, "prior output"))
            },
            toolSchemas: schemas.map { ToolSchemaDescriptor(name: $0, description: "d", parametersJSON: "{}") },
            allToolNames: ceiling.isEmpty ? schemas : ceiling
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Collects every JSON string under any "name" key in a subtree.
    private func allNameValues(_ node: Any) -> [String] {
        if let dict = node as? [String: Any] {
            var found: [String] = []
            if let name = dict["name"] as? String { found.append(name) }
            for (key, value) in dict where key != "name" { found.append(contentsOf: allNameValues(value)) }
            return found
        }
        if let array = node as? [Any] { return array.flatMap { allNameValues($0) } }
        return []
    }

    private let kimiHosts = [
        "https://api.kimi.com/v1",
        "https://api.kimi.com/coding/v1",
        "https://api.moonshot.cn/v1",
        "https://api.moonshot.ai/v1"
    ]

    // MARK: - Detection is by exact official host only

    @Test("Official Kimi/Moonshot hosts get letter-initial wire-safe names without any saved override")
    func officialHostsDetected() throws {
        for endpoint in kimiHosts {
            let profile = provider(endpoint)
            #expect(CompatToolNames.requiresLetterInitialNames(profile))
            #expect(CompatToolNames.usesWireSafeNames(profile))
            #expect(CompatToolNames.wireName("workspace.readFile", for: profile) == "workspace_readFile")
            #expect(CompatToolNames.wireName("tools.search", for: profile) == "tools_search")
            #expect(CompatToolNames.wireName("exec.shell", for: profile) == "exec_shell")
        }
    }

    @Test("Aliases and lookalike hosts are never rewritten; the saved opt-in keeps legacy compat only")
    func lookalikesUntouched() throws {
        for endpoint in ["https://kimi.example.test/v1", "https://api.kimi.com.evil.test/v1",
                         "https://notapi.kimi.com/v1", "https://moonshot-gw.example.com/v1",
                         "https://moonshot.cn/v1"] {
            let profile = provider(endpoint, displayName: "Kimi Moonshot 直连")
            #expect(!CompatToolNames.requiresLetterInitialNames(profile))
            #expect(!CompatToolNames.usesWireSafeNames(profile))
            #expect(CompatToolNames.wireName("workspace.readFile", for: profile) == "workspace.readFile")
        }
        // Explicit saved compatibility override behaves exactly as before on an
        // unrelated host: dots fold to underscores, leading digits stay legal.
        let optIn = provider("https://gateway.example.test/v1", toolNameCompatibility: true)
        #expect(CompatToolNames.usesWireSafeNames(optIn))
        #expect(!CompatToolNames.requiresLetterInitialNames(optIn))
        #expect(CompatToolNames.wireName("workspace.readFile", for: optIn) == "workspace_readFile")
        #expect(CompatToolNames.wireName("2fa.backupCode", for: optIn) == "2fa_backupCode")
        let deepSeek = provider("https://api.deepseek.com")
        #expect(CompatToolNames.wireName("2fa.backupCode", for: deepSeek) == "2fa_backupCode")
        // Non-strict providers get no table and never an "f_" prefix.
        let plain = provider("https://example.test/v1")
        #expect(CompatToolNames.wireTable(for: try request(for: plain, schemas: ["workspace.readFile"])).isEmpty)
    }

    // MARK: - Grammar hardening

    @Test("Names with leading digits, symbols or non-ASCII scalars become grammar-exact and recover exactly")
    func adversarialSpellingHardening() throws {
        let profile = provider("https://api.kimi.com/v1")
        let cases = ["2fa.backupCode", "_leading.underscore", "-dash.first", "检索.query",
                     "a tool/name", "UPPER.case"]
        let schemas = cases + ["workspace.readFile", "tools.search"]
        let req = try request(for: profile, schemas: schemas)
        let table = CompatToolNames.wireTable(for: req)
        for canonical in cases {
            let wire = try #require(table[canonical])
            #expect(satisfiesKimiGrammar(wire), "\(canonical) -> \(wire)")
            #expect(CompatToolNames.canonicalName(wire, request: req) == canonical)
        }
        #expect(table["2fa.backupCode"] == "f_2fa_backupCode")
        #expect(table["检索.query"] == "f____query")
        // Already letter-initial: only the illegal symbols fold, no prefix.
        #expect(table["a tool/name"] == "a_tool_name")
    }

    // MARK: - Encoder: request with image + history + tool_choice

    @Test("Chat encoder emits only grammar-exact names while history pairing and images stay complete")
    func chatBodyGrammarAndPairing() throws {
        let profile = provider("https://api.kimi.com/v1")
        let schemas = ["tools.search", "tools.list", "skill.search", "skill.read", "exec.shell",
                       "checklist.readPlan", "checklist.updatePlan", "workspace.readFile",
                       "browser.screenshot", "2fa.backupCode"]
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

        // Every name anywhere in the payload satisfies the exact server grammar.
        let names = allNameValues(body)
        #expect(!names.isEmpty)
        #expect(names.allSatisfy { satisfiesKimiGrammar($0) })
        #expect(!names.contains { $0.contains(".") })

        // Tool definitions: same count, same order, table spellings.
        let table = CompatToolNames.wireTable(for: req)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == schemas.count)
        for (index, entry) in tools.enumerated() {
            let function = try #require(entry["function"] as? [String: Any])
            #expect(function["name"] as? String == table[schemas[index]])
        }
        #expect(body["tool_choice"] as? String == "auto")

        // Replayed assistant history keeps its call id, wired name and tool
        // result pairing; the pending follow-up call carries the hardened name.
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["tool_calls"] != nil && ($0["role"] as? String) == "assistant" && ((($0["tool_calls"] as? [Any])?.count) == 1) })
        let toolCall = try #require(((assistant["tool_calls"] as? [[String: Any]])?.first)?["function"] as? [String: Any])
        #expect(toolCall["name"] as? String == "workspace_readFile")
        let toolMessage = try #require(messages.first { ($0["role"] as? String) == "tool" })
        #expect(toolMessage["tool_call_id"] as? String == "c1")
        // The fresh result for the pending call stays id-paired as well.
        let lastTool = try #require(messages.last { ($0["role"] as? String) == "tool" })
        #expect(lastTool["tool_call_id"] as? String == "c2")
        let pendingEntry = try #require(messages.last { ($0["role"] as? String) == "assistant" })
        let pendingCall = try #require(((pendingEntry["tool_calls"] as? [[String: Any]])?.first)?["function"] as? [String: Any])
        #expect(pendingCall["name"] as? String == "f_2fa_backupCode")

        // The attached image survives serialization (data URL part), and the
        // request's canonical descriptors are never mutated in place.
        let user = try #require(messages.first { ($0["role"] as? String) == "user" })
        let parts = try #require(user["content"] as? [[String: Any]])
        #expect(parts.contains { ($0["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64,U1lOVEhFVElDLUJZVEVT" })
        #expect(req.toolSchemas.map(\.name) == schemas)

        // Image presence changes only the user part, never a tool name.
        let noImage = try request(for: profile, schemas: schemas, ceiling: schemas + ["media.transcribe"])
        let noImageBody = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: noImage))
        let toolsA = try #require(body["tools"] as? [[String: Any]])
        let toolsB = try #require(noImageBody["tools"] as? [[String: Any]])
        let dataA = try JSONSerialization.data(withJSONObject: toolsA, options: [.sortedKeys])
        let dataB = try JSONSerialization.data(withJSONObject: toolsB, options: [.sortedKeys])
        #expect(dataA == dataB)
    }

    // MARK: - History-only collision determinism + exact recovery

    @Test("A history-only name colliding with an advertised tool gets a distinct wired spelling and recovers exactly")
    func historyOnlyCollision() throws {
        let profile = provider("https://api.kimi.com/v1")
        let req = try request(
            for: profile,
            schemas: ["workspace.readFile"],
            ceiling: ["workspace.readFile"],
            pairs: [("c9", "workspace_readFile")]  // settled under a name outside this turn's schemas
        )
        let table = CompatToolNames.wireTable(for: req)
        // '.' (0x2E) sorts before '_' (0x5F): the advertised tool keeps the
        // base spelling, the history-only canonical gains the "_2" suffix.
        #expect(table["workspace.readFile"] == "workspace_readFile")
        #expect(table["workspace_readFile"] == "workspace_readFile_2")

        let body = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: req))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["tool_calls"] != nil })
        let replayedName = try #require((((assistant["tool_calls"] as? [[String: Any]])?.first)?["function"] as? [String: Any])?["name"] as? String)
        #expect(replayedName == "workspace_readFile_2")
        let tools = try #require(body["tools"] as? [[String: Any]])
        let advertisedName = try #require(((tools.first)?["function"] as? [String: Any])?["name"] as? String)
        #expect(advertisedName == "workspace_readFile")

        // Inbound streamed names reverse through the same complete table.
        #expect(CompatToolNames.canonicalName("workspace_readFile", request: req) == "workspace.readFile")
        #expect(CompatToolNames.canonicalName("workspace_readFile_2", request: req) == "workspace_readFile")
        // Unknown spellings stay honest pass-throughs (not-in-catalog denial).
        #expect(CompatToolNames.canonicalName("totally_unknown", request: req) == "totally_unknown")
        #expect(CompatToolNames.canonicalName("ghost.tool", request: req) == "ghost.tool")
    }

    @Test("Legacy DeepSeek compat folding is preserved unchanged; strict prefixing is Kimi/Moonshot-only")
    func deepSeekRegressionGuard() throws {
        let profile = provider("https://api.deepseek.com")
        let req = try request(for: profile, schemas: ["workspace.readFile", "tools.search"])
        let body = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: req))
        let tools = try #require(body["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names == ["workspace_readFile", "tools_search"])
        #expect(CompatToolNames.canonicalName("workspace_readFile", request: req) == "workspace.readFile")
        #expect(CompatToolNames.wireTable(for: req).isEmpty)
    }

    // MARK: - Same boundary mapping across all three wire adapters

    @Test("Responses and Anthropic adapters share the exact Kimi table for definitions and history")
    func crossAdapterParity() throws {
        let collisionSchemas = ["workspace.readFile", "media.transcribe"]
        let chatProfile = provider("https://api.kimi.com/v1")
        let base = try request(for: chatProfile, schemas: collisionSchemas, pairs: [("c1", "media.transcribe")])
        let expected = CompatToolNames.wireTable(for: base)

        let responsesProfile = provider("https://api.kimi.com/v1", wire: .openAIResponses)
        let responsesReq = try request(for: responsesProfile, schemas: collisionSchemas, pairs: [("c1", "media.transcribe")])
        let responsesBody = try jsonObject(OpenAIResponsesAdapter().buildBody(from: responsesReq))
        let responsesTools = try #require(responsesBody["tools"] as? [[String: Any]])
        #expect(responsesTools.compactMap { $0["name"] as? String } == collisionSchemas.map { expected[$0]! })
        #expect(allNameValues(responsesBody).allSatisfy { satisfiesKimiGrammar($0) })

        let anthropicProfile = provider("https://api.kimi.com/v1", wire: .anthropicMessages)
        let anthropicReq = try request(for: anthropicProfile, schemas: collisionSchemas, pairs: [("c1", "media.transcribe")])
        let anthropicBody = try jsonObject(AnthropicMessagesAdapter().buildBody(from: anthropicReq))
        let anthropicTools = try #require(anthropicBody["tools"] as? [[String: Any]])
        #expect(anthropicTools.compactMap { $0["name"] as? String } == collisionSchemas.map { expected[$0]! })
        #expect(allNameValues(anthropicBody).allSatisfy { satisfiesKimiGrammar($0) })
        // The replayed pair's inbound recovery on the original request round-trips.
        #expect(CompatToolNames.canonicalName(expected["media.transcribe"]!, request: base) == "media.transcribe")
    }
}
