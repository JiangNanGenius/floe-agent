import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloeCore
@testable import FloeModels
@testable import FloeProviders

@Suite("FloeProviders.RequestContracts")
struct RequestContractTests {
    @Test("Native Chat transport rejects nonobject schemas with a safe field path", arguments: ["[]", "[{}]", "{invalid"])
    func chatRejectsNonObjectToolParameters(schema: String) throws {
        let request = syntheticChatRequest(schemas: [.init(name: "tools.search", description: "Synthetic", parametersJSON: schema)])
        do {
            _ = try OpenAIChatCompletionsAdapter().prepareBody(from: request)
            Issue.record("A nonobject function schema reached the native transport boundary")
        } catch let violation as ChatRequestContract.Violation {
            #expect(violation.code == .parametersNotObject)
            #expect(violation.path == "tools[0].function.parameters")
            #expect(request.toolSchemas[0].parametersJSON == schema)
        }
    }

    @Test("Final Chat wire rejects broken pairs instead of deleting or inventing results", arguments: ["orphan", "duplicate", "missing", "emptyID", "duplicateResult", "replayOverlap"])
    func chatFinalWirePairValidation(fault: String) throws {
        var request = syntheticChatRequest()
        let call = try ToolCall(id: fault == "emptyID" ? "" : "synthetic-call", toolName: "tools.search", argumentsJSON: Data("{}".utf8), scope: .local)
        request.pendingToolCalls = [call]
        request.toolResults = [(callID: call.id, output: "Synthetic result")]
        let expected: ChatRequestContract.Violation.Code
        switch fault {
        case "orphan": request.pendingToolCalls = []; expected = .orphanToolResult
        case "duplicate": request.pendingToolCalls.append(call); expected = .duplicateCallID
        case "missing": request.toolResults = []; expected = .missingToolResult
        case "emptyID": expected = .emptyCallID
        case "duplicateResult": request.toolResults.append(request.toolResults[0]); expected = .orphanToolResult
        default:
            request.replayedToolPairs = [.init(call: call, result: .init(callID: call.id, status: .ok, outputSummary: "Synthetic history", outputDigest: "synthetic"))]
            expected = .duplicateCallID
        }
        let beforeCalls = request.pendingToolCalls
        let beforeResults = request.toolResults.map(\.output)
        do {
            _ = try OpenAIChatCompletionsAdapter().prepareBody(from: request)
            Issue.record("A malformed final wire pair was accepted")
        } catch let violation as ChatRequestContract.Violation {
            #expect(violation.code == expected)
            #expect(violation.path.hasPrefix("messages["))
            #expect(!violation.path.contains("synthetic-call"))
            #expect(request.pendingToolCalls == beforeCalls)
            #expect(request.toolResults.map(\.output) == beforeResults)
        }
    }

    @Test("Native Chat reports one terminal local-format error without a network error")
    func chatLocalFormatFailureIsTerminal() async throws {
        // The request is invalid before transport. Even a regression can only
        // reach loopback, never a configured provider or external model.
        var request = syntheticChatRequest(schemas: [.init(name: "tools.search", description: "Synthetic", parametersJSON: "[]")])
        request.provider.baseURL = try #require(URL(string: "http://127.0.0.1:9"))
        var events: [AgentEvent] = []
        for try await event in OpenAIChatCompletionsAdapter().stream(request: request, credentials: .init()) {
            events.append(event)
        }
        #expect(events.count == 1)
        let event = try #require(events.first)
        guard case .error(let error) = event else {
            Issue.record("Expected a normalized local-format failure"); return
        }
        #expect(error.kind == .malformed)
        #expect(error.httpStatus == nil)
    }

    @Test("Actual body diagnostics are bounded and omit text, arguments, images and identifiers")
    func chatShapeDiagnosticsAreContentFree() {
        let secret = "SYNTHETIC-CONTENT-MUST-NOT-BE-LOGGED"
        let call = ChatRequest.Message.ToolCall(id: secret, function: .init(name: secret, arguments: #"{"value":"SYNTHETIC-CONTENT-MUST-NOT-BE-LOGGED"}"#))
        var messages = [
            ChatRequest.Message(role: "user", contentParts: [.text(secret), .imageURL("data:image/png;base64," + secret)]),
            .init(role: "assistant", content: ""),
            .init(role: "assistant", reasoningContent: secret),
            .init(role: "assistant", toolCalls: [call]),
            .init(role: "tool", content: secret, toolCallID: secret)
        ]
        messages += Array(repeating: .init(role: secret, content: secret), count: 100)
        let body = ChatRequest(model: secret, messages: messages,
            tools: [.init(name: secret, description: secret, parameters: #"{"type":"object"}"#)])
        let summary = ChatRequestContract.diagnosticSummary(body)
        #expect(summary.contains("wireMessages=105"))
        #expect(summary.contains("wireCalls=1 wireResults=1 imageParts=1"))
        #expect(summary.contains("emptyAssistantTurns=1 reasoningOnlyTurns=1"))
        #expect(summary.contains("shapesOmitted=41"))
        #expect(summary.utf8.count < 8_192)
        #expect(!summary.contains(secret))
        #expect(!summary.contains("data:image"))
        #expect(!summary.contains("base64"))
    }

    @Test("Generic InvalidParameter remains an original terminal error, with an unspecified field")
    func arkGenericParameterErrorRetainsUnknownField() throws {
        let original = #"{"error":{"code":"InvalidParameter","message":"Synthetic invalid request","param":"","type":"BadRequest"}}"#
        let event = WireTranslator.httpError(status: 400, body: original)
        guard case .error(let error) = event else { Issue.record("Expected a provider error"); return }
        #expect(error.kind == .malformed)
        #expect(error.httpStatus == 400)
        #expect(error.providerMessage == original)
        #expect(ChatRequestContract.rejectionFields(error.providerMessage) == "providerCode=InvalidParameter providerParam=unspecified")
        let unsafe = #"{"error":{"code":"PRIVATE-SENTINEL","message":"PRIVATE-SENTINEL","param":"PRIVATE-SENTINEL"}}"#
        #expect(!ChatRequestContract.rejectionFields(unsafe).contains("PRIVATE-SENTINEL"))
    }

    private func syntheticChatRequest(schemas: [ToolSchemaDescriptor] = []) -> ProviderStreamRequest {
        let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.invalid/v1")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "synthetic", displayName: "Synthetic",
            limits: .init(contextTokens: 8192, maxOutputTokens: 1024), capabilities: [.text, .tools])
        return .init(provider: provider, model: model, messages: [(role: "user", content: "Synthetic")], toolSchemas: schemas)
    }

    @Test("DeepSeek replays reasoning for every assistant history turn; other providers omit it")
    func historyReasoningReplay() throws {
        for endpoint in ["https://api.deepseek.com", "https://example.test/v1"] {
            let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
                baseURL: try #require(URL(string: endpoint)))
            let model = ModelProfile(providerID: provider.id, remoteModelID: endpoint.contains("deepseek") ? "deepseek-v4-flash" : "text",
                displayName: "Text", limits: .init(contextTokens: 4096, maxOutputTokens: 1024), capabilities: [.text, .tools])
            let request = ProviderStreamRequest(provider: provider, model: model, messages: [],
                contentMessages: [
                    .init(role: "assistant", content: [.text("first")], reasoningContent: "first reasoning"),
                    .init(role: "user", content: [.text("continue")]),
                    .init(role: "assistant", content: [.text("second")], reasoningContent: "second reasoning")])
            let body = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))
            let messages = try #require(body["messages"] as? [[String: Any]])
            if endpoint.contains("deepseek") {
                #expect(messages[0]["reasoning_content"] as? String == "first reasoning")
                #expect(messages[2]["reasoning_content"] as? String == "second reasoning")
            } else {
                #expect(messages.allSatisfy { $0["reasoning_content"] == nil })
            }
            #expect(messages[1]["reasoning_content"] == nil)
            var legacy = request
            legacy.contentMessages.append(.init(role: "assistant", content: [.text("old answer")]))
            legacy.toolSchemas = [.init(name: "test_read", description: "Read", parametersJSON: "{}")]
            let legacyBody = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: legacy))
            let old = try #require((legacyBody["messages"] as? [[String: Any]])?.last)
            #expect(old["reasoning_content"] == nil)
            if endpoint.contains("deepseek") {
                #expect(old["role"] as? String == "system")
                #expect((old["content"] as? String)?.contains("protocol reasoning unavailable") == true)
                #expect((old["content"] as? String)?.contains("old answer") == true)
            } else { #expect(old["role"] as? String == "assistant") }
        }
    }
    @Test("Dispatch clock refresh is transient and preserves tool pairing and images")
    func dispatchClock() throws {
        let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.test/v1")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "text", displayName: "Text",
            limits: .init(contextTokens: 4096, maxOutputTokens: 1024), capabilities: [.text])
        let request = ProviderStreamRequest(provider: provider, model: model,
            messages: [(role: "user", content: "now?")],
            contentMessages: [.init(role: "user", content: [.text("now?"), .imageData(mimeType: "image/png", base64: "data")])])
        let updated = request.refreshingRuntimeClock(now: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(secondsFromGMT: 36_000)!, locale: Locale(identifier: "en_AU"))
        #expect(request.messages.count == 1)
        #expect(updated.messages.first?.content.contains("1970-01-01T00:00:00Z") == true)
        #expect(updated.messages.first?.content.contains("utcOffsetSeconds=36000") == true)
        #expect(updated.messages.first?.content.contains("locale=en_AU") == true)
        #expect(updated.contentMessages.last == request.contentMessages.last)
        #expect(updated.pendingToolCalls == request.pendingToolCalls)
    }

    private let schema = #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#

    @Test("Provider tool schemas encode as JSON objects, never quoted strings")
    func toolSchemasAreObjects() throws {
        let responses = ResponsesRequest(
            model: "model",
            input: [],
            tools: [.init(name: "shell", description: "Run", parameters: schema)]
        )
        let chat = ChatRequest(
            model: "model",
            messages: [],
            tools: [.init(name: "shell", description: "Run", parameters: schema)]
        )
        let anthropic = AnthropicRequest(
            model: "model",
            maxTokens: 128,
            messages: [],
            tools: [.init(name: "shell", description: "Run", inputSchema: schema)]
        )

        let responsesJSON = try #require(try jsonObject(responses)["tools"] as? [[String: Any]])
        #expect(responsesJSON[0]["parameters"] is [String: Any])

        let chatJSON = try #require(try jsonObject(chat)["tools"] as? [[String: Any]])
        let function = try #require(chatJSON[0]["function"] as? [String: Any])
        #expect(function["parameters"] is [String: Any])

        let anthropicJSON = try #require(try jsonObject(anthropic)["tools"] as? [[String: Any]])
        #expect(anthropicJSON[0]["input_schema"] is [String: Any])
    }

    @Test("Provider tool schemas preserve numeric zero separately from false")
    func toolSchemaNumericZeroIsNotBoolean() throws {
        let boundedNumberSchema = #"{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":10000}},"additionalProperties":false}"#
        let body = ChatRequest(
            model: "deepseek-chat",
            messages: [],
            tools: [.init(
                name: "browser_clickPoint",
                description: "Click viewport coordinates",
                parameters: boundedNumberSchema
            )]
        )

        let encoded = try JSONEncoder().encode(body)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        #expect(encodedText.contains(#""minimum":0"#))
        #expect(!encodedText.contains(#""minimum":false"#))

        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let tools = try #require(object["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: Any])
        let x = try #require(properties["x"] as? [String: Any])
        let minimum = try #require(x["minimum"] as? NSNumber)
        #expect(String(cString: minimum.objCType) != "c")
        #expect((parameters["additionalProperties"] as? NSNumber)?.boolValue == false)
    }

    @Test("Tool schema encoding is byte-stable so provider prefix caches can hit")
    func toolSchemaEncodingIsByteStable() throws {
        // DeepSeek's prompt cache matches on the exact token prefix. Swift
        // dictionary iteration order is nondeterministic, so arbitrary-JSON
        // segments (tool `parameters`) previously re-encoded with a different
        // key order on every request and destroyed the prefix match.
        let unorderedSchema = #"{"type":"object","required":["query"],"properties":{"zeta":{"type":"integer"},"query":{"type":"string"},"alpha":{"type":"boolean"}},"additionalProperties":false}"#
        let body = ChatRequest(
            model: "deepseek-chat",
            messages: [],
            tools: [.init(name: "conversation_search", description: "Search tasks", parameters: unorderedSchema)]
        )

        var encodings = Set<String>()
        for _ in 0..<64 {
            encodings.insert(String(decoding: try ProviderWireEncoder.encode(body), as: UTF8.self))
        }
        #expect(encodings.count == 1)
        let encoded = try #require(encodings.first)
        #expect(encoded.contains(#""properties":{"alpha"#))
        #expect(encoded.contains(#""query":{"type":"string"},"zeta"#))

        // Anthropic's input_schema shares the same RawJSONValue/JSONTree path.
        let anthropic = AnthropicRequest(
            model: "model", maxTokens: 128, messages: [],
            tools: [.init(name: "conversation_search", description: "Search tasks", inputSchema: unorderedSchema)]
        )
        var anthropicEncodings = Set<String>()
        for _ in 0..<64 {
            anthropicEncodings.insert(String(decoding: try ProviderWireEncoder.encode(anthropic), as: UTF8.self))
        }
        #expect(anthropicEncodings.count == 1)
    }

    @Test("Chat tools are omitted when tool calling is disabled")
    func chatOmitsUnusedTools() throws {
        let body = ChatRequest(
            model: "model",
            messages: [.init(role: "user", content: "hello")]
        )
        let object = try jsonObject(body)
        #expect(object["tools"] == nil)
        #expect(object["tool_choice"] == nil)
    }

    @Test("OpenAI-compatible chat explicitly enables native tool selection")
    func chatAdapterEnablesNativeToolSelection() throws {
        let providerID = UUID()
        let request = ProviderStreamRequest(
            provider: ProviderProfile(
                id: providerID,
                kind: .custom,
                wireProtocol: .openAIChatCompletions,
                baseURL: URL(string: "https://example.com/v1")!
            ),
            model: ModelProfile(
                providerID: providerID,
                remoteModelID: "tool-model",
                displayName: "Tool Model",
                limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 512)
            ),
            toolSchemas: [
                .init(name: "browser.observe", description: "Observe", parametersJSON: schema)
            ]
        )

        let body = OpenAIChatCompletionsAdapter().buildBody(from: request)
        let object = try jsonObject(body)
        #expect(object["tool_choice"] as? String == "auto")
    }

    @Test("Anthropic system messages use the top-level system field")
    func anthropicSystemPlacement() {
        let providerID = UUID()
        let request = ProviderStreamRequest(
            provider: ProviderProfile(
                id: providerID,
                kind: .anthropic,
                wireProtocol: .anthropicMessages,
                baseURL: URL(string: "https://api.anthropic.com")!
            ),
            model: ModelProfile(
                providerID: providerID,
                remoteModelID: "claude-test",
                displayName: "Claude Test",
                limits: ModelLimits(contextTokens: 1_000, maxOutputTokens: 128)
            ),
            messages: [
                (role: "system", content: "Follow the user intent."),
                (role: "user", content: "Hello")
            ]
        )

        let body = AnthropicMessagesAdapter().buildBody(from: request)
        #expect(body.system?.map(\.text) == ["Follow the user intent."])
        #expect(body.messages.count == 1)
        #expect(body.messages.first?.role == "user")
    }

    @Test("Thinking-mode replay carries reasoning on every wire and drops empty values")
    func reasoningReplayAcrossWires() throws {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://api.deepseek.com")),
            toolNameCompatibility: true
        )
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "deepseek-v4-pro",
            displayName: "DeepSeek",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.text, .tools]
        )
        let call = try ToolCall(
            id: "call-1",
            toolName: "workspace.readFile",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        let result = ToolResult(callID: call.id, status: .ok, outputSummary: "file contents", outputDigest: "d")
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            contentMessages: [
                ProviderMessage(role: "assistant", content: [.text("working")], reasoningContent: "history-thought")
            ],
            pendingToolCalls: [call],
            replayedToolPairs: [ReplayedToolPair(call: call, result: result, assistantReasoning: "prior-thought")],
            pendingAssistantReasoning: "pending-thought",
            toolSchemas: [.init(name: "workspace.readFile", description: "read")]
        )

        // Chat: assistant history, replayed pair and pending batch all carry reasoning.
        let chat = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))
        let chatMessages = try #require(chat["messages"] as? [[String: Any]])
        let chatReasoning = chatMessages.compactMap { $0["reasoning_content"] as? String }
        #expect(chatReasoning.contains("history-thought"))
        #expect(chatReasoning.contains("prior-thought"))
        #expect(chatReasoning.contains("pending-thought"))

        // Responses: plain-text reasoning items precede each assistant turn.
        let responses = try jsonObject(OpenAIResponsesAdapter().buildBody(from: request))
        let input = try #require(responses["input"] as? [[String: Any]])
        let reasoningItems = input.filter { $0["type"] as? String == "reasoning" }
        #expect(reasoningItems.count == 3)
        #expect(reasoningItems.allSatisfy { item in
            (item["content"] as? [[String: Any]])?.first?["type"] as? String == "reasoning_text"
        })

        // Anthropic: thinking blocks precede tool_use on every assistant turn.
        let anthropic = try jsonObject(AnthropicMessagesAdapter().buildBody(from: request))
        let anthropicMessages = try #require(anthropic["messages"] as? [[String: Any]])
        let thinkingCount = anthropicMessages
            .compactMap { $0["content"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["type"] as? String == "thinking" }
            .count
        #expect(thinkingCount == 3)

        // Empty reasoning is absent, never an empty string.
        var emptyRequest = request
        emptyRequest.pendingAssistantReasoning = ""
        emptyRequest.replayedToolPairs = [ReplayedToolPair(call: call, result: result)]
        let emptyChat = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: emptyRequest))
        let emptyMessages = try #require(emptyChat["messages"] as? [[String: Any]])
        #expect(!emptyMessages.contains { $0["reasoning_content"] as? String == "" })
        // Legacy pairs without reasoning become explicit non-authoritative history.
        #expect(emptyMessages.contains {
            ($0["role"] as? String) == "system"
                && ($0["content"] as? String)?.contains("reasoning unavailable") == true
        })
    }

    @Test("Provider follow-up pairs each tool call with its result")
    func toolCallResultPairing() throws {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.deepseek.com")!
        )
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "model",
            displayName: "Model",
            limits: ModelLimits(contextTokens: 1_000, maxOutputTokens: 128)
        )
        let call = try ToolCall(
            id: "call-1",
            toolName: "shell",
            argumentsJSON: Data(#"{"command":"pwd"}"#.utf8),
            scope: .local
        )
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [(role: "user", content: "where")],
            toolResults: [(callID: call.id, output: "/tmp")],
            pendingToolCalls: [call],
            pendingAssistantReasoning: "I should inspect the working directory."
        )

        let chatObject = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))
        let chatMessages = try #require(chatObject["messages"] as? [[String: Any]])
        #expect(chatMessages.contains { $0["role"] as? String == "assistant" && $0["tool_calls"] != nil })
        #expect(chatMessages.contains {
            $0["role"] as? String == "assistant"
                && $0["reasoning_content"] as? String == "I should inspect the working directory."
        })
        #expect(chatMessages.contains { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == call.id })
        let responsesObject = try jsonObject(OpenAIResponsesAdapter().buildBody(from: request))
        let input = try #require(responsesObject["input"] as? [[String: Any]])
        #expect(input.contains { $0["type"] as? String == "function_call" && $0["call_id"] as? String == call.id })
        #expect(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == call.id })

        let anthropicObject = try jsonObject(AnthropicMessagesAdapter().buildBody(from: request))
        let anthropicMessages = try #require(anthropicObject["messages"] as? [[String: Any]])
        let assistantContent = anthropicMessages.first { $0["role"] as? String == "assistant" }?["content"] as? [[String: Any]]
        let userContent = anthropicMessages
            .compactMap { $0["content"] as? [[String: Any]] }
            .first { blocks in blocks.contains { $0["type"] as? String == "tool_result" } }
        #expect(assistantContent?.contains { $0["type"] as? String == "tool_use" && $0["id"] as? String == call.id } == true)
        #expect(userContent?.contains { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == call.id } == true)
    }

    @Test("Replayed tool pairs render in settlement order on every wire before the pending pair")
    func replayedToolPairsRenderInOrder() throws {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://api.deepseek.com"))
        )
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "deepseek-v4-flash",
            displayName: "DeepSeek",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192)
        )
        let first = try ToolCall(
            id: "history-1",
            toolName: "workspace.listDirectory",
            argumentsJSON: Data(#"{"path":"/tmp"}"#.utf8),
            scope: .local
        )
        let second = try ToolCall(
            id: "history-2",
            toolName: "workspace.listDirectory",
            argumentsJSON: Data(#"{"path":"/var"}"#.utf8),
            scope: .local
        )
        let pending = try ToolCall(
            id: "pending-1",
            toolName: "workspace.listDirectory",
            argumentsJSON: Data(#"{"path":"/etc"}"#.utf8),
            scope: .local
        )
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [
                (role: "system", content: "Follow the user intent."),
                (role: "user", content: "list directories")
            ],
            toolResults: [(callID: pending.id, output: "pending-output")],
            pendingToolCalls: [pending],
            replayedToolPairs: [
                ReplayedToolPair(
                    call: first,
                    result: ToolResult(callID: first.id, status: .ok, outputSummary: "first-output", outputDigest: "f"),
                    assistantReasoning: "first-thought"
                ),
                ReplayedToolPair(
                    call: second,
                    result: ToolResult(callID: second.id, status: .ok, outputSummary: "second-output", outputDigest: "s"),
                    assistantReasoning: "second-thought"
                )
            ]
        )

        // Chat Completions: one assistant tool_calls message plus one role=tool
        // message per pair, in settlement order, before the pending pair.
        let chatObject = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))
        let chatMessages = try #require(chatObject["messages"] as? [[String: Any]])
        let chatSequence = chatMessages.map { message -> String in
            if let calls = message["tool_calls"] as? [[String: Any]],
               let id = calls.first?["id"] as? String {
                return "assistant:\(id)"
            }
            if message["role"] as? String == "tool", let id = message["tool_call_id"] as? String {
                return "tool:\(id)"
            }
            return message["role"] as? String ?? "?"
        }
        #expect(chatSequence == [
            "system", "user",
            "assistant:history-1", "tool:history-1",
            "assistant:history-2", "tool:history-2",
            "assistant:pending-1", "tool:pending-1"
        ])
        // DeepSeek underscore aliasing also covers replayed call names.
        let historyCalls = try #require(chatMessages[2]["tool_calls"] as? [[String: Any]])
        #expect((historyCalls[0]["function"] as? [String: Any])?["name"] as? String
            == "workspace_listDirectory")
        #expect(chatMessages[3]["content"] as? String == "first-output")
        #expect(chatMessages[5]["content"] as? String == "second-output")

        // Responses: function_call/function_call_output input items per pair.
        let responsesObject = try jsonObject(OpenAIResponsesAdapter().buildBody(from: request))
        let input = try #require(responsesObject["input"] as? [[String: Any]])
        let inputSequence = input.map { item -> String in
            let type = item["type"] as? String ?? "message"
            if let callID = item["call_id"] as? String { return "\(type):\(callID)" }
            return "\(type):\(item["role"] as? String ?? "")"
        }
        #expect(inputSequence == [
            "message:system", "message:user",
            "reasoning:", "function_call:history-1", "function_call_output:history-1",
            "reasoning:", "function_call:history-2", "function_call_output:history-2",
            "function_call:pending-1", "function_call_output:pending-1"
        ])
        let historyCall = try #require(input[3]["name"] as? String)
        // Compat providers sanitize on EVERY wire, not just chat.
        #expect(historyCall == "workspace_listDirectory")

        // Anthropic: assistant tool_use / user tool_result blocks per pair;
        // system extraction stays at the top level.
        let anthropicBody = AnthropicMessagesAdapter().buildBody(from: request)
        #expect(anthropicBody.system?.map(\.text) == ["Follow the user intent."])
        let anthropicObject = try jsonObject(anthropicBody)
        let anthropicMessages = try #require(anthropicObject["messages"] as? [[String: Any]])
        let anthropicSequence = anthropicMessages.map { message -> String in
            let blocks = message["content"] as? [[String: Any]] ?? []
            if let use = blocks.first(where: { $0["type"] as? String == "tool_use" }),
               let id = use["id"] as? String {
                return "assistant:\(id)"
            }
            if let result = blocks.first(where: { $0["type"] as? String == "tool_result" }),
               let id = result["tool_use_id"] as? String {
                return "user:\(id)"
            }
            return message["role"] as? String ?? "?"
        }
        #expect(anthropicSequence == [
            "user",
            "assistant:history-1", "user:history-1",
            "assistant:history-2", "user:history-2",
            "assistant:pending-1", "user:pending-1"
        ])
        #expect(anthropicMessages.allSatisfy { $0["role"] as? String != "system" })
    }

    @Test("DeepSeek tool names are wire-safe without relying on a settings toggle")
    func compatibleToolNamesRoundTrip() throws {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://api.deepseek.com")),
            toolNameCompatibility: false
        )
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "deepseek-v4-flash",
            displayName: "DeepSeek",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192)
        )
        let call = try ToolCall(
            id: "call-list",
            toolName: "workspace.listDirectory",
            argumentsJSON: Data(#"{"path":"."}"#.utf8),
            scope: .local
        )
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            pendingToolCalls: [call],
            toolSchemas: [.init(name: "workspace.listDirectory", description: "List")]
        )
        let adapter = OpenAIChatCompletionsAdapter()
        let body = try jsonObject(adapter.buildBody(from: request))
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect((tools[0]["function"] as? [String: Any])?["name"] as? String
            == "workspace_listDirectory")
        let messages = try #require(body["messages"] as? [[String: Any]])
        let replay = try #require(messages.first?["tool_calls"] as? [[String: Any]])
        #expect((replay[0]["function"] as? [String: Any])?["name"] as? String
            == "workspace_listDirectory")
        #expect(CompatToolNames.canonicalName("workspace_listDirectory", request: request)
            == "workspace.listDirectory")
        #expect(CompatToolNames.canonicalName("workspace.listDirectory", request: request)
            == "workspace.listDirectory")
    }

    @Test("Compat reverse mapping is total over the run ceiling, not just offered schemas")
    func compatReverseMappingUsesRunCeiling() throws {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://gateway.example.com")),
            toolNameCompatibility: true
        )
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "gateway-model",
            displayName: "Gateway",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192)
        )
        // The schema was budget-evicted from this request, but the ceiling
        // (tools.list's universe) still names it. The call must resolve.
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            toolSchemas: [.init(name: "web.search", description: "Search")],
            allToolNames: ["web.search", "workspace.readFile", "document.pdf.render"]
        )
        #expect(CompatToolNames.canonicalName("workspace_readFile", request: request) == "workspace.readFile")
        #expect(CompatToolNames.canonicalName("document_pdf_render", request: request) == "document.pdf.render")
        // Tools that exist only as offered schemas (discovery, plan submit)
        // must resolve even when the ceiling snapshot predates them.
        let schemaOnlyRequest = ProviderStreamRequest(
            provider: provider,
            model: model,
            toolSchemas: [
                .init(name: "tools.list", description: "List"),
                .init(name: "tools.search", description: "Search")
            ],
            allToolNames: ["workspace.readFile"]
        )
        #expect(CompatToolNames.canonicalName("tools_list", request: schemaOnlyRequest) == "tools.list")
        #expect(CompatToolNames.canonicalName("tools_search", request: schemaOnlyRequest) == "tools.search")
        // Weak compat models lowercase camelCase segments; the sanitized
        // lookup folds case instead of denying an otherwise unique tool.
        #expect(CompatToolNames.canonicalName("workspace_readfile", request: request) == "workspace.readFile")
        // Ambiguous or unknown spellings pass through unchanged (honest denial downstream).
        #expect(CompatToolNames.canonicalName("workspace_unknown", request: request) == "workspace_unknown")
        // Canonical spellings always pass through, compat on or off.
        #expect(CompatToolNames.canonicalName("web.search", request: request) == "web.search")
        var nativeProvider = provider
        nativeProvider.toolNameCompatibility = false
        nativeProvider.baseURL = try #require(URL(string: "https://api.example.com"))
        let nativeRequest = ProviderStreamRequest(provider: nativeProvider, model: model, allToolNames: ["workspace.readFile"])
        #expect(CompatToolNames.canonicalName("workspace_readFile", request: nativeRequest) == "workspace_readFile")
    }

    @Test("DeepSeek text-only turns validate the advertised catalog before generation")
    func deepSeekTextOnlyTurnUsesWireSafeCatalog() throws {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://api.deepseek.com")),
            toolNameCompatibility: false
        )
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "deepseek-v4-flash",
            displayName: "DeepSeek",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.text, .tools]
        )
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [(role: "user", content: "hello")],
            toolSchemas: [
                .init(name: "browser.clickPoint", description: "Click", parametersJSON: schema),
                .init(name: "image.inspect", description: "Inspect", parametersJSON: schema),
            ]
        )

        let body = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["content"] as? String == "hello")
        let tools = try #require(body["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names == ["browser_clickPoint", "image_inspect"])
    }

    @Test("Volcengine Ark uses ASCII-only wire names while canonical names round-trip")
    func arkNativeToolContract() throws {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .volcengineArk,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://ark.cn-beijing.volces.com/api/v3"))
        )
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "ep-test",
            displayName: "Ark Endpoint",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 4_096),
            capabilities: [.text, .tools]
        )
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [(role: "user", content: "list files")],
            toolSchemas: [.init(name: "workspace.listDirectory", description: "List", parametersJSON: schema)]
        )

        let object = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))
        let tools = try #require(object["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        // Ark's function-name contract is ASCII-only; the canonical dotted
        // runtime name must never cross this wire and must round-trip exactly.
        #expect(names == ["workspace_listDirectory"])
        #expect(!names.contains { $0.contains(".") })
        #expect(CompatToolNames.canonicalName("workspace_listDirectory", request: request)
            == "workspace.listDirectory")
        #expect(request.toolSchemas.map(\.name) == ["workspace.listDirectory"])
        #expect(object["model"] as? String == "ep-test")
    }

    @Test("Reasoning depth maps to each provider's native contract")
    func providerSpecificReasoningContracts() throws {
        let deepSeekID = UUID()
        let deepSeek = ProviderProfile(
            id: deepSeekID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://api.deepseek.com"))
        )
        let deepSeekModel = ModelProfile(
            providerID: deepSeekID,
            remoteModelID: "deepseek-v4-flash",
            displayName: "DeepSeek V4 Flash",
            limits: ModelLimits(contextTokens: 1_048_576, maxOutputTokens: 65_536),
            reasoningEffort: .maximum
        )
        let deepSeekBody = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: .init(
            provider: deepSeek,
            model: deepSeekModel,
            messages: [(role: "user", content: "hello")]
        )))
        #expect((deepSeekBody["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect(deepSeekBody["reasoning_effort"] as? String == "max")

        // Each UI depth maps to the value DeepSeek's documented contract
        // actually uses: low stays low, high stays high, and medium is the
        // accepted compatibility alias that the endpoint resolves to high
        // (there is no native medium tier). Thinking stays enabled throughout.
        for (effort, expected) in [
            (ModelReasoningEffort.low, "low"),
            (.medium, "high"),
            (.high, "high")
        ] {
            var variant = deepSeekModel
            variant.reasoningEffort = effort
            let body = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: .init(
                provider: deepSeek,
                model: variant,
                messages: [(role: "user", content: "hello")]
            )))
            #expect((body["thinking"] as? [String: Any])?["type"] as? String == "enabled")
            #expect(body["reasoning_effort"] as? String == expected)
        }

        // The Anthropic wire path keeps the same direct DeepSeek contract.
        var anthropicDeepSeek = deepSeekModel
        anthropicDeepSeek.reasoningEffort = .low
        let anthropicDeepSeekBody = try jsonObject(AnthropicMessagesAdapter().buildBody(from: .init(
            provider: ProviderProfile(
                id: deepSeekID,
                kind: .custom,
                wireProtocol: .anthropicMessages,
                baseURL: try #require(URL(string: "https://api.deepseek.com"))
            ),
            model: anthropicDeepSeek,
            messages: [(role: "user", content: "hello")]
        )))
        #expect((anthropicDeepSeekBody["output_config"] as? [String: Any])?["effort"] as? String == "low")

        let arkID = UUID()
        let ark = ProviderProfile(
            id: arkID,
            kind: .volcengineArk,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://ark.cn-beijing.volces.com/api/v3"))
        )
        let arkModel = ModelProfile(
            providerID: arkID,
            remoteModelID: "doubao-thinking",
            displayName: "Doubao Thinking",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            reasoningEffort: .medium
        )
        let arkBody = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: .init(
            provider: ark,
            model: arkModel,
            messages: [(role: "user", content: "hello")]
        )))
        #expect((arkBody["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect(arkBody["reasoning_effort"] as? String == "medium")

        let openAIID = UUID()
        let openAI = ProviderProfile(
            id: openAIID,
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://api.openai.com/v1"))
        )
        let openAIModel = ModelProfile(
            providerID: openAIID,
            remoteModelID: "gpt-5.6-codex",
            displayName: "GPT-5.6 Codex",
            limits: ModelLimits(contextTokens: 400_000, maxOutputTokens: 32_768),
            reasoningEffort: .maximum
        )
        let openAIBody = try jsonObject(OpenAIResponsesAdapter().buildBody(from: .init(
            provider: openAI,
            model: openAIModel,
            messages: [(role: "user", content: "hello")]
        )))
        #expect((openAIBody["reasoning"] as? [String: Any])?["effort"] as? String == "xhigh")

        let anthropicID = UUID()
        let anthropic = ProviderProfile(
            id: anthropicID,
            kind: .anthropic,
            wireProtocol: .anthropicMessages,
            baseURL: try #require(URL(string: "https://api.anthropic.com"))
        )
        let anthropicModel = ModelProfile(
            providerID: anthropicID,
            remoteModelID: "claude-sonnet-4-6",
            displayName: "Claude Sonnet 4.6",
            limits: ModelLimits(contextTokens: 200_000, maxOutputTokens: 32_768),
            reasoningEffort: .high
        )
        let anthropicBody = try jsonObject(AnthropicMessagesAdapter().buildBody(from: .init(
            provider: anthropic,
            model: anthropicModel,
            messages: [(role: "user", content: "hello")]
        )))
        #expect(anthropicBody["thinking"] == nil)
        #expect((anthropicBody["output_config"] as? [String: Any])?["effort"] as? String == "high")
    }

    @Test("Internal preprocessing explicitly disables provider-default reasoning")
    func internalReasoningDisableContracts() throws {
        let dashScopeID = UUID()
        let dashScope = ProviderProfile(
            id: dashScopeID,
            kind: .alibabaStudio,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1"))
        )
        let qwen = ModelProfile(
            providerID: dashScopeID,
            remoteModelID: "qwen3.5-flash",
            displayName: "Qwen 3.5 Flash",
            limits: ModelLimits(contextTokens: 256_000, maxOutputTokens: 1_024),
            reasoningEffort: .high
        )
        let dashScopeBody = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: .init(
            provider: dashScope,
            model: qwen,
            messages: [(role: "user", content: "inspect")],
            reasoningPolicy: .disabled
        )))
        #expect(dashScopeBody["enable_thinking"] as? Bool == false)
        #expect(dashScopeBody["reasoning_effort"] == nil)

        let arkID = UUID()
        let ark = ProviderProfile(
            id: arkID,
            kind: .volcengineArk,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://ark.cn-beijing.volces.com/api/v3"))
        )
        let doubao = ModelProfile(
            providerID: arkID,
            remoteModelID: "doubao-seed-2-0-lite-260215",
            displayName: "Doubao Seed",
            limits: ModelLimits(contextTokens: 256_000, maxOutputTokens: 1_024)
        )
        let arkBody = try jsonObject(OpenAIResponsesAdapter().buildBody(from: .init(
            provider: ark,
            model: doubao,
            messages: [(role: "user", content: "inspect")],
            reasoningPolicy: .disabled
        )))
        #expect((arkBody["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    }

    @Test("Unknown custom gateways omit reasoning fields")
    func unknownGatewayOmitsReasoningFields() throws {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://gateway.example/v1"))
        )
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "private-model",
            displayName: "Private Model",
            limits: ModelLimits(contextTokens: 32_000, maxOutputTokens: 4_096),
            reasoningEffort: .maximum
        )
        let body = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: .init(
            provider: provider,
            model: model,
            messages: [(role: "user", content: "hello")]
        )))
        #expect(body["thinking"] == nil)
        #expect(body["reasoning_effort"] == nil)
    }

    @Test("Vision content maps to every provider wire format")
    func visionContentMapping() throws {
        let providerID = UUID()
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "vision-model",
            displayName: "Vision",
            limits: ModelLimits(contextTokens: 8_000, maxOutputTokens: 256),
            capabilities: [.vision]
        )
        let provider = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://example.invalid/v1"))
        )
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            contentMessages: [
                ProviderMessage(role: "user", content: [
                    .text("Inspect this page"),
                    .imageData(mimeType: "image/png", base64: "aGVsbG8=")
                ])
            ]
        )

        let responses = try #require(
            (try jsonObject(OpenAIResponsesAdapter().buildBody(from: request))["input"] as? [[String: Any]])?.first
        )
        #expect((responses["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "input_image" } == true)

        let chat = try #require(
            (try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))["messages"] as? [[String: Any]])?.first
        )
        #expect((chat["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image_url" } == true)

        let anthropic = try #require(
            (try jsonObject(AnthropicMessagesAdapter().buildBody(from: request))["messages"] as? [[String: Any]])?.first
        )
        #expect((anthropic["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image" } == true)
    }

    @Test("Unspecified maximum output is omitted when optional and defaulted when required")
    func unspecifiedMaximumOutput() throws {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://example.invalid/v1"))
        )
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "model",
            displayName: "Model",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 0)
        )
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [(role: "user", content: "hello")]
        )

        #expect(try jsonObject(OpenAIResponsesAdapter().buildBody(from: request))["max_output_tokens"] == nil)
        let chat = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))
        #expect(chat["max_tokens"] == nil)
        #expect((chat["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect(AnthropicMessagesAdapter().buildBody(from: request).maxTokens == 8_192)
    }

    @Test("Remote tool scope is derived from validated host arguments")
    func remoteScopeInference() throws {
        let hostID = UUID()
        let item = FunctionCallItem(
            callID: "call-1",
            name: "ssh.execute",
            arguments: #"{"hostID":"\#(hostID.uuidString)","path":"/tmp","command":"pwd"}"#
        )
        let events = WireTranslator.translate(.outputItemDoneFunctionCall(item))
        guard case .toolRequest(let call) = events.first else {
            Issue.record("Expected a tool request")
            return
        }
        #expect(call.scope == .hostPath(hostID: hostID, path: "/tmp"))
    }


    @Test("Anthropic keeps live state after history and caches the stable system")
    func anthropicSystemCacheBreakpoint() throws {
        let provider = ProviderProfile(kind: .custom, wireProtocol: .anthropicMessages,
            baseURL: URL(string: "https://localhost:8443")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "claude", displayName: "Claude",
            limits: .init(contextTokens: 8_192, maxOutputTokens: 1024), capabilities: [.tools])
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [
                (role: "system", content: "Stable contract.\n\n" + ProviderStreamRequest.liveStateMarker + "\n\nCurrent runtime time: now"),
                (role: "user", content: "Hi")
            ]
        )
        let body = AnthropicMessagesAdapter().buildBody(from: request)
        let blocks = try #require(body.system)
        #expect(blocks.count == 1)
        #expect(blocks[0].text == "Stable contract.")
        #expect(blocks[0].cacheControl != nil)
        #expect(body.messages.last?.content.contains(.text("[Floe runtime context; current app state, separate from the preceding user text or tool output]\nCurrent runtime time: now")) == true)
    }

    @Test("Changing runtime state leaves history prefixes and reasoning tool pairs intact")
    func volatileStateDoesNotInvalidateHistoryPrefix() throws {
        let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.deepseek.com")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "deepseek-flash", displayName: "Flash",
            limits: .init(contextTokens: 8_192, maxOutputTokens: 1024), capabilities: [.text, .tools])
        let call = try ToolCall(id: "read", toolName: "workspace.readFile", argumentsJSON: Data(#"{"path":"a.txt"}"#.utf8), scope: .local)
        func request(_ state: String) -> ProviderStreamRequest {
            .init(provider: provider, model: model,
                contentMessages: [
                    .init(role: "system", content: [.text("Stable instructions"), .text(ProviderStreamRequest.liveStateMarker), .text(state)]),
                    .init(role: "user", content: [.text("Read this"), .imageData(mimeType: "image/png", base64: "image")])
                ], toolResults: [(callID: "read", output: "Actual receipt")], pendingToolCalls: [call], pendingAssistantReasoning: "Exact reasoning")
        }
        let first = request("clock 1"), second = request("clock 2")
        let chatA = OpenAIChatCompletionsAdapter().buildBody(from: first)
        let chatB = OpenAIChatCompletionsAdapter().buildBody(from: second)
        #expect(chatA.messages.dropLast() == chatB.messages.dropLast())
        #expect(chatA.messages.map(\.role) == ["system", "user", "assistant", "tool"])
        #expect(chatA.messages[2].reasoningContent == "Exact reasoning")
        #expect(chatA.messages.last?.toolCallID == "read")
        #expect(chatA.messages.last?.content != chatB.messages.last?.content)
        let responsesA = OpenAIResponsesAdapter().buildBody(from: first)
        let responsesB = OpenAIResponsesAdapter().buildBody(from: second)
        #expect(responsesA.input.dropLast() == responsesB.input.dropLast())
        let anthropicA = AnthropicMessagesAdapter().buildBody(from: first)
        let anthropicB = AnthropicMessagesAdapter().buildBody(from: second)
        #expect(anthropicA.system == anthropicB.system)
        #expect(anthropicA.messages.dropLast() == anthropicB.messages.dropLast())
        #expect(anthropicA.messages.last?.content.first == .toolResult(toolUseID: "read", content: "Actual receipt", isError: false))
    }

    @Test("Every provider-supported image MIME serializes on Chat, Responses and Anthropic wires")
    func allSupportedImageMIMEsSerialize() throws {
        // Real tiny images for each provider-supported type: PNG / JPEG /
        // WebP / GIF all traverse the same ProviderContentPart path the
        // runtime uses for retained tool artifacts.
        let cases: [(mime: String, base64: String)] = [
            ("image/png", "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP4z8DAwPAfAAcAAf9+CLHQAAAAAElFTkSuQmCC"),
            ("image/jpeg", "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/wAARCAABAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD5q1b/AJCt3/13f/0I0UUV/XWT/wDIvof4I/8ApKPMzX/fq3+KX5s//9k="),
            ("image/webp", "UklGRh4AAABXRUJQVlA4TBEAAAAvAQAAAA8Q87//8x8OMqL/AQA="),
            ("image/gif", "R0lGODdhAgABAIEAAP8AAAAA/wAAAAAAACwAAAAAAgABAAAIBQABBAgIADs=")
        ]
        for (mime, base64) in cases {
            let providerID = UUID()
            let model = ModelProfile(
                providerID: providerID, remoteModelID: "vision-model", displayName: "Vision",
                limits: ModelLimits(contextTokens: 8_000, maxOutputTokens: 256),
                capabilities: [.vision]
            )
            let provider = ProviderProfile(
                id: providerID, kind: .custom, wireProtocol: .openAIResponses,
                baseURL: try #require(URL(string: "https://example.invalid/v1"))
            )
            let request = ProviderStreamRequest(
                provider: provider, model: model,
                contentMessages: [
                    ProviderMessage(role: "user", content: [.text("Inspect"), .imageData(mimeType: mime, base64: base64)])
                ]
            )
            // Responses: the exact data URL preserves the MIME.
            let responses = try #require(
                (try jsonObject(OpenAIResponsesAdapter().buildBody(from: request))["input"] as? [[String: Any]])?.first
            )
            let responseContent = try #require(responses["content"] as? [[String: Any]])
            let imagePart = try #require(responseContent.first { $0["type"] as? String == "input_image" })
            #expect((imagePart["image_url"] as? String)?.hasPrefix("data:\(mime);base64,") == true)
            // Chat: same data URL family.
            let chat = try #require(
                (try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))["messages"] as? [[String: Any]])?.first
            )
            let chatContent = try #require(chat["content"] as? [[String: Any]])
            let chatImage = try #require(chatContent.first { $0["type"] as? String == "image_url" })
            let chatURL = try #require((chatImage["image_url"] as? [String: Any])?["url"] as? String)
            #expect(chatURL.hasPrefix("data:\(mime);base64,"))
            // Anthropic: media_type is the declared MIME and the bytes are the
            // exact payload.
            let anthropic = try #require(
                (try jsonObject(AnthropicMessagesAdapter().buildBody(from: request))["messages"] as? [[String: Any]])?.first
            )
            let anthropicContent = try #require(anthropic["content"] as? [[String: Any]])
            let anthropicImage = try #require(anthropicContent.first { $0["type"] as? String == "image" })
            let source = try #require(anthropicImage["source"] as? [String: Any])
            #expect(source["media_type"] as? String == mime)
            #expect(source["data"] as? String == base64)
        }
    }

    @Test("Plan steering followed by a goal tool pair keeps a valid ordered Chat replay")
    func planSteeringGoalToolPairReplayShape() throws {
        // Real 332 lead: a plan-execution run accepts steering that explicitly
        // calls goal.create/goal.read, both settle, and the NEXT main request
        // is rejected by Ark InvalidParameter/BadRequest with an empty param.
        // The exact provider body/param is not available; this locks the local
        // replay contract so a shape defect cannot hide behind "network":
        // a steering user turn must stay ordinary history, the goal pair must
        // be exactly one assistant tool_calls turn followed by the matching
        // tool results, and no partial/duplicate/reordered pair is emitted.
        // The provider consumes opaque JSON tool receipts. Keep this fixture
        // independent of Runtime's goal model so the Providers target can
        // verify the transport without adding a reverse module dependency.
        let createResult = #"{"ok":true,"goal":{"id":"11111111-1111-1111-1111-111111111111","conversationID":"22222222-2222-2222-2222-222222222222","revision":0,"objective":"Deliver the accepted plan","status":"active","acceptanceCriteria":[{"id":"33333333-3333-3333-3333-333333333333","text":"The plan is implemented","isComplete":false}],"steps":[{"id":"44444444-4444-4444-4444-444444444444","title":"Implement","status":"inProgress","order":0}],"progress":{"startedAt":0}},"evidenceTotal":0,"projectionTruncated":false}"#
        let readResult = createResult

        let create = try ToolCall(
            id: "goal_create_1",
            toolName: "goal.create",
            argumentsJSON: Data(#"{"objective":"Deliver the accepted plan","acceptanceCriteria":["The plan is implemented"],"steps":["Implement"]}"#.utf8),
            scope: .local
        )
        let read = try ToolCall(
            id: "goal_read_2",
            toolName: "goal.read",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        var request = syntheticChatRequest(schemas: [
            .init(name: "goal.create", description: "Create", parametersJSON: #"{"type":"object"}"#),
            .init(name: "goal.read", description: "Read", parametersJSON: #"{"type":"object"}"#),
            .init(name: "checklist.readPlan", description: "Plan", parametersJSON: #"{"type":"object"}"#)
        ])
        request.messages = [
            (role: "system", content: "Runtime contract"),
            (role: "user", content: "Execute the accepted plan"),
            (role: "assistant", content: "Starting implementation."),
            (role: "user", content: "Create the durable goal and read it before continuing.")
        ]
        request.pendingToolCalls = [create, read]
        request.toolResults = [
            (callID: create.id, output: createResult),
            (callID: read.id, output: readResult)
        ]
        request.pendingAssistantReasoning = "I should create the goal, then read it."

        // Exercise the exact Ark wire-name grammar, because the failed 332
        // request used ark-code-latest. The canonical dotted names must map
        // consistently in tool definitions, assistant tool_calls and the
        // reverse table, without splitting the result pair.
        request.provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://ark.cn-beijing.volces.com/api/v3")),
            displayName: "Synthetic Ark"
        )
        let prepared = try OpenAIChatCompletionsAdapter().prepareBody(from: request)
        let body = try #require(JSONSerialization.jsonObject(
            with: prepared.data
        ) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let roles = messages.compactMap { $0["role"] as? String }
        let toolCallsIndex = try #require(messages.firstIndex {
            ($0["tool_calls"] as? [[String: Any]])?.isEmpty == false
        })
        let assistantCalls = try #require(messages[toolCallsIndex]["tool_calls"] as? [[String: Any]])
        #expect(assistantCalls.compactMap { $0["id"] as? String } == [create.id, read.id])
        let assistantNames = assistantCalls.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        #expect(assistantNames == ["goal_create", "goal_read"])
        // The assistant tool-call turn must be followed immediately by both
        // matching tool results; a steering user turn may not split the pair.
        #expect(Array(roles[(toolCallsIndex + 1)...(toolCallsIndex + 2)]) == ["tool", "tool"])
        let resultIDs = messages[(toolCallsIndex + 1)...(toolCallsIndex + 2)]
            .compactMap { $0["tool_call_id"] as? String }
        #expect(resultIDs == [create.id, read.id])
        #expect(messages.compactMap { $0["tool_call_id"] as? String }.count == 2)
        // Custom Ark endpoint: no DeepSeek reasoning replay field is invented.
        #expect(messages.allSatisfy { $0["reasoning_content"] == nil })
        // The steering turn stays one ordinary user message before the pair.
        let steeringIndices = messages.indices.filter {
            (messages[$0]["role"] as? String) == "user"
                && (messages[$0]["content"] as? String)?.contains("Create the durable goal") == true
        }
        #expect(steeringIndices.count == 1)
        let steeringIndex = try #require(steeringIndices.first)
        #expect(steeringIndex < toolCallsIndex)
        // Body validation passed in prepareBody; the goal tool definitions
        // remained objects and unique.
        let tools = try #require(body["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(Set(names).count == names.count)
        #expect(names.contains("goal_create") && names.contains("goal_read"))
        #expect(assistantNames.allSatisfy(names.contains))
        #expect(tools.allSatisfy {
            ($0["function"] as? [String: Any])?["parameters"] is [String: Any]
        })
    }

    @Test("Diagnostic run identity survives clock refresh but never reaches the wire")
    func diagnosticRunIdentityIsLogOnly() throws {
        var request = syntheticChatRequest()
        request.diagnosticRunID = "run-fixture-only"
        let refreshed = request.refreshingRuntimeClock()
        #expect(refreshed.diagnosticRunID == "run-fixture-only")
        let body = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: refreshed))
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        #expect(!wire.contains("run-fixture-only"))
        // Durable snapshot coverage belongs to ProviderRecoveryTests in the
        // Runtime module; this Providers test remains independent of Runtime.
    }

    @Test("Official Ark preserves disjoint tagged unions, refs, constraints and opaque values")
    func arkDisjointUnionProjectionIsLossless() throws {
        let original = ##"{"type":"object","properties":{"chart":{"$ref":"#/$defs/Choice"},"oneOf":{"type":"string"},"opaque":{"type":"object","default":{"oneOf":[1,2]}}},"required":["chart"],"additionalProperties":false,"$defs":{"Choice":{"oneOf":[{"type":"object","properties":{"kind":{"type":"string","enum":["number"]},"value":{"type":"number","minimum":0}},"required":["kind","value"],"additionalProperties":false},{"type":"object","properties":{"kind":{"type":"string","enum":["category"]},"value":{"type":"string","minLength":2}},"required":["kind","value"],"additionalProperties":false}]}}}"##
        let raw = try #require(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        let definitions = try #require(raw["$defs"] as? [String: Any])
        let choice = try #require(definitions["Choice"] as? [String: Any])
        let originalBranches = try #require(choice["oneOf"] as? [[String: Any]])
        let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://ark.cn-beijing.volces.com/api/plan/v3")))
        let model = ModelProfile(providerID: provider.id, remoteModelID: "ark-code-latest", displayName: "Fixture",
            limits: .init(contextTokens: 1_048_576, maxOutputTokens: 0), capabilities: [.text, .tools])
        let request = ProviderStreamRequest(provider: provider, model: model,
            messages: [(role: "user", content: "Synthetic contract only")],
            toolSchemas: [.init(name: "document.presentation.createInline", description: "Fixture", parametersJSON: original)])
        func wire(_ request: ProviderStreamRequest) throws -> ([String: Any], [String: Any]) {
            let prepared = try OpenAIChatCompletionsAdapter().prepareBody(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
            let tools = try #require(body["tools"] as? [[String: Any]])
            let function = try #require(tools.first?["function"] as? [String: Any])
            return (body, try #require(function["parameters"] as? [String: Any]))
        }
        let (body, projected) = try wire(request)
        let projectedDefinitions = try #require(projected["$defs"] as? [String: Any])
        let projectedChoice = try #require(projectedDefinitions["Choice"] as? [String: Any])
        #expect(projectedChoice["oneOf"] == nil)
        let alternatives = try #require(projectedChoice["anyOf"] as? [[String: Any]])
        #expect(alternatives.count == originalBranches.count)
        for index in alternatives.indices {
            #expect(NSDictionary(dictionary: alternatives[index]).isEqual(to: originalBranches[index]))
        }
        #expect(NSDictionary(dictionary: try #require(projected["properties"] as? [String: Any]))
            .isEqual(to: try #require(raw["properties"] as? [String: Any])))
        #expect(projected["additionalProperties"] as? Bool == false)
        #expect(projected["required"] as? [String] == ["chart"])
        #expect(request.toolSchemas.first?.parametersJSON == original)
        #expect(body["model"] as? String == "ark-code-latest" && body["max_tokens"] == nil)
        #expect(body["thinking"] == nil && body["reasoning_effort"] == nil)

        // Overlapping tags do not prove oneOf == anyOf. Leave them intact.
        var overlapping = request
        let ambiguous = original.replacingOccurrences(of: #""enum":["category"]"#, with: #""enum":["number"]"#)
            .replacingOccurrences(of: #""type":"string","minLength":2"#, with: #""type":"number","minimum":0"#)
        overlapping.toolSchemas[0].parametersJSON = ambiguous
        let (_, unchanged) = try wire(overlapping)
        let expected = try #require(JSONSerialization.jsonObject(with: Data(ambiguous.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: unchanged).isEqual(to: expected))

        var otherProvider = request
        otherProvider.provider.baseURL = try #require(URL(string: "https://ark.cn-beijing.volces.com.example.invalid/api/plan/v3"))
        #expect(NSDictionary(dictionary: try wire(otherProvider).1).isEqual(to: raw))
        var otherTool = request
        otherTool.toolSchemas[0].name = "synthetic.otherTool"
        #expect(NSDictionary(dictionary: try wire(otherTool).1).isEqual(to: raw))
    }

    @Test("Ark font-source projection keeps exact closed alternatives without weakening XOR")
    func arkFontSourceProjectionPreservesExclusiveInputs() throws {
        let original = #"{"type":"object","properties":{"url":{"type":"string","description":"Direct public HTTPS font URL"},"path":{"type":"string","description":"Workspace-relative font file"}},"additionalProperties":false,"oneOf":[{"required":["url"]},{"required":["path"]}]}"#
        let expected = #"{"type":"object","anyOf":[{"type":"object","properties":{"url":{"type":"string","description":"Direct public HTTPS font URL"}},"required":["url"],"additionalProperties":false},{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative font file"}},"required":["path"],"additionalProperties":false}]}"#
        var request = syntheticChatRequest(schemas: [.init(name: "font.install", description: "Fixture", parametersJSON: original)])
        request.provider.baseURL = try #require(URL(string: "https://ark.cn-beijing.volces.com/api/plan/v3"))
        let prepared = try OpenAIChatCompletionsAdapter().prepareBody(from: request)
        let body = try #require(JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        let tools = try #require(body["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        let expectedObject = try #require(JSONSerialization.jsonObject(with: Data(expected.utf8)) as? [String: Any])
        // Exact closed branches require a source and reject both sources,
        // undeclared fields and wrong source types by JSON Schema semantics.
        #expect(NSDictionary(dictionary: parameters).isEqual(to: expectedObject))
        #expect(request.toolSchemas[0].parametersJSON == original)

        // A future schema with another allowed field cannot be narrowed to
        // those two closed branches by this bounded proof.
        var extended = try #require(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        var properties = try #require(extended["properties"] as? [String: Any])
        properties["note"] = ["type": "string"]
        extended["properties"] = properties
        let extendedJSON = String(decoding: try JSONSerialization.data(withJSONObject: extended, options: [.sortedKeys]), as: UTF8.self)
        let untouched = ArkToolSchemaProjection.parameters(extendedJSON, toolName: "font.install")
        #expect(untouched == extendedJSON)
    }


    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}


// Each fixture owns a unique URL path; parallel tests cannot consume one
// another's responses. No request is allowed to leave this URLProtocol.
private final class ThinkingValidationURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let body: String; var holdBody = false }
    private struct State { var replies: [Reply]; var requests: [URLRequest] = []; var stopped = false }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    private static func key(_ request: URLRequest) -> String { request.url?.path.split(separator: "/").first.map(String.init) ?? "" }
    static func install(_ key: String, replies: [Reply]) { lock.withLock { states[key] = .init(replies: replies) } }
    static func remove(_ key: String) { lock.withLock { _ = states.removeValue(forKey: key) } }
    static func requests(_ key: String) -> [URLRequest] { lock.withLock { states[key]?.requests ?? [] } }
    static func stopped(_ key: String) -> Bool { lock.withLock { states[key]?.stopped == true } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }; data.append(buffer, count: count)
            }
            recorded.httpBody = data
        }
        let key = Self.key(request)
        let reply = Self.lock.withLock { () -> Reply in
            guard var state = Self.states[key] else { return .init(status: 500, body: "Missing owned fixture") }
            state.requests.append(recorded)
            let next = state.replies.isEmpty ? Reply(status: 500, body: "Fixture exhausted") : state.replies.removeFirst()
            Self.states[key] = state; return next
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": reply.status == 200 ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.holdBody {
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        let key = Self.key(request)
        Self.lock.withLock { Self.states[key]?.stopped = true }
    }
}

extension RequestContractTests {
    private var rootThinkingRejection: String {
        #"{"details":{"_errors":["Unrecognized key(s) in object: 'thinking'"]},"issues":[{"code":"unrecognized_keys","keys":["thinking"],"path":[] }]}"#
    }
    private func thinkingRequest(_ key: String, nativePreset: Bool = true) -> ProviderStreamRequest {
        let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://thinking-contract.invalid/\(key)/v1")!, displayName: "Synthetic DeepSeek gateway",
            presetID: nativePreset ? "deepseek" : nil, nonSecretHeaders: ["X-Contract": "preserve"])
        let model = ModelProfile(providerID: provider.id, remoteModelID: "deepseek-synthetic-abliterated", displayName: "Synthetic model",
            limits: .init(contextTokens: 16_384, maxOutputTokens: 1_024), capabilities: [.text, .tools, .vision], reasoningEffort: .high)
        return .init(provider: provider, model: model, messages: [(role: "user", content: "Keep the literal thinking text and the tool history.")],
            toolSchemas: [.init(name: "studio.read", description: "Read owned fixture", parametersJSON: #"{"type":"object","properties":{"thinking":{"type":"string"}}}"#)],
            allToolNames: ["studio.read"], reasoningPolicy: .disabled)
    }
    private func thinkingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThinkingValidationURLProtocol.self]
        configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 3
        return URLSession(configuration: configuration)
    }

    @Test("Model or display names cannot authorize native thinking fields on an unknown gateway")
    func thinkingControlsRequireAnEndpointDialect() throws {
        for wire in [ModelProtocol.openAIChatCompletions, .openAIResponses] {
            for policy in [ProviderReasoningPolicy.modelDefault, .disabled] {
                var request = thinkingRequest(UUID().uuidString, nativePreset: false)
                request.provider.wireProtocol = wire; request.reasoningPolicy = policy
                let provider = request.provider, model = request.model
                let body = wire == .openAIChatCompletions
                    ? try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))
                    : try jsonObject(OpenAIResponsesAdapter().buildBody(from: request))
                #expect(body["thinking"] == nil)
                #expect(body["reasoning_effort"] == nil)
                #expect((body["tools"] as? [Any])?.count == 1)
                #expect(request.provider == provider && request.model == model && request.model.capabilities.contains([.text,.tools,.vision]))
                #expect(!ReasoningCompatibility.documentsDisabledReasoning(provider: provider, model: model))
                #expect(ReasoningCompatibility.requiresAssistantReasoningReplay(provider: provider, model: model))
            }
        }
        for endpoint in ["https://api.deepseek.com/v1", "https://thinking-contract.invalid/native/v1"] {
            var native = thinkingRequest(UUID().uuidString)
            native.provider.baseURL = URL(string: endpoint)!
            if endpoint.contains("api.deepseek.com") { native.provider.presetID = nil }
            native.reasoningPolicy = .modelDefault
            let body = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: native))
            #expect((body["thinking"] as? [String: Any])?["type"] as? String == "enabled")
            #expect(body["reasoning_effort"] as? String == "high")
            native.reasoningPolicy = .disabled
            #expect((try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: native))["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        }
    }

    @Test("Only an exact root thinking validation rejection has a one-use field projection")
    func thinkingValidationRequiresAnExactRootAndOneAttempt() throws {
        for status in [400,422] { #expect(ThinkingFieldCompatibility.rejectsRootThinking(status: status, body: rootThinkingRejection)) }
        for status in [200,401,403,404,429,500] { #expect(!ThinkingFieldCompatibility.rejectsRootThinking(status: status, body: rootThinkingRejection)) }
        let rejected = [
            #"{"error":{"code":"InvalidParameter","type":"BadRequest","param":""}}"#,
            #"{"issues":[{"code":"unrecognized_keys","keys":["thinking"],"path":["tools",0,"function","parameters"]}]}"#,
            #"{"issues":[{"code":"unrecognized_keys","keys":["thinking","tools"],"path":[]}]}"#,
            #"{"issues":[{"code":"invalid_type","keys":["thinking"],"path":[]}]}"#,
            #"{"error":{"param":"thinking","code":"unsupported_parameter","path":["tools"]}}"#,
            #"{"error":{"message":"An example mentioned thinking; actual problem is another field"}}"#
        ]
        for body in rejected { #expect(!ThinkingFieldCompatibility.rejectsRootThinking(status: 400, body: body)) }
        let request = thinkingRequest(UUID().uuidString)
        var url = try OpenAIChatCompletionsAdapter().buildURLRequest(request: request, credentials: .init())
        url.httpBody = try OpenAIChatCompletionsAdapter().prepareBody(from: request).data
        var recovery = ThinkingFieldCompatibility()
        let projectedRequest = recovery.replacementRequest(url, status: 400, body: rootThinkingRejection)
        let replacement = try #require(projectedRequest)
        var before = try #require(JSONSerialization.jsonObject(with: url.httpBody!) as? [String: Any])
        before["thinking"] = nil
        let after = try #require(JSONSerialization.jsonObject(with: replacement.httpBody!) as? [String: Any])
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
        #expect(replacement.url == url.url && replacement.httpMethod == url.httpMethod && replacement.value(forHTTPHeaderField: "X-Contract") == "preserve")
        let exhaustedRequest = recovery.replacementRequest(url, status: 400, body: rootThinkingRejection)
        #expect(exhaustedRequest == nil)
        var afterOutput = ThinkingFieldCompatibility(); afterOutput.observeStreamEvent()
        let afterOutputRequest = afterOutput.replacementRequest(url, status: 400, body: rootThinkingRejection)
        #expect(afterOutputRequest == nil)
    }

    @Test("Actual Chat transport retries a rejected field once and preserves tool history and a single new call")
    func thinkingHTTPRecoveryPreservesTheCompleteRequest() async throws {
        for status in [400,422] {
            let key = UUID().uuidString, session = thinkingSession()
            defer { session.invalidateAndCancel(); ThinkingValidationURLProtocol.remove(key) }
            let success = "data: " + #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"new-call","type":"function","function":{"name":"studio_read","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"# + "\n\ndata: [DONE]\n\n"
            ThinkingValidationURLProtocol.install(key, replies: [.init(status: status, body: rootThinkingRejection), .init(status: 200, body: success)])
            var request = thinkingRequest(key)
            let history = try ToolCall(id: "old-call", toolName: "studio.read", argumentsJSON: Data("{}".utf8), scope: .local)
            request.pendingToolCalls = [history]; request.pendingAssistantReasoning = "Preserved original reasoning"
            request.toolResults = [(callID: history.id, output: "Preserved original result")]
            var events: [AgentEvent] = []
            for try await event in OpenAIChatCompletionsAdapter().stream(request: request, credentials: .init(), session: session) { events.append(event) }
            let requests = ThinkingValidationURLProtocol.requests(key)
            #expect(requests.count == 2)
            let first = try #require(requests.first?.httpBody), second = try #require(requests.last?.httpBody)
            var original = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
            #expect(original.removeValue(forKey: "thinking") != nil)
            let corrected = try #require(JSONSerialization.jsonObject(with: second) as? [String: Any])
            #expect(NSDictionary(dictionary: original).isEqual(to: corrected))
            let calls = events.compactMap { if case .toolRequest(let call) = $0 { call } else { nil } }
            #expect(calls.map(\.id) == ["new-call"] && calls.first?.toolName == "studio.read")
            #expect(!events.contains { if case .error = $0 { true } else { false } })
        }
    }

    @Test("A repeated rejection is terminal and cancellation cannot start the compatibility request")
    func thinkingHTTPRecoveryStopsAtTheErrorOrCancellationBoundary() async throws {
        for exact in [true,false] {
            let key = UUID().uuidString, session = thinkingSession()
            defer { session.invalidateAndCancel(); ThinkingValidationURLProtocol.remove(key) }
            let body = exact ? rootThinkingRejection : #"{"error":{"code":"InvalidParameter","param":""}}"#
            ThinkingValidationURLProtocol.install(key, replies: [.init(status: 400, body: body), .init(status: 400, body: body)])
            var errors: [AgentEvent.NormalizedError] = []
            for try await event in OpenAIChatCompletionsAdapter().stream(request: thinkingRequest(key), credentials: .init(), session: session) {
                if case .error(let error) = event { errors.append(error) }
            }
            #expect(ThinkingValidationURLProtocol.requests(key).count == (exact ? 2 : 1))
            #expect(errors.count == 1 && errors.first?.httpStatus == 400)
        }
        // HTTP 200 SSE content is not request-level validation evidence,
        // even if a later event repeats the same rejection wording.
        do {
            let streamKey = UUID().uuidString, streamSession = thinkingSession()
            defer { streamSession.invalidateAndCancel(); ThinkingValidationURLProtocol.remove(streamKey) }
            let body = "data: " + #"{"choices":[{"index":0,"delta":{"content":"Preserved partial text"}}]}"#
                + "\n\nevent: __http_error__\ndata: 400\ndata: " + rootThinkingRejection + "\n\n"
            ThinkingValidationURLProtocol.install(streamKey, replies: [.init(status: 200, body: body)])
            var text = "", errors = 0
            for try await event in OpenAIChatCompletionsAdapter().stream(request: thinkingRequest(streamKey), credentials: .init(), session: streamSession) {
                if case .textDelta(let value) = event { text += value.text }
                if case .error = event { errors += 1 }
            }
            #expect(ThinkingValidationURLProtocol.requests(streamKey).count == 1)
            #expect(text == "Preserved partial text" && errors == 1)
        }
        let key = UUID().uuidString, session = thinkingSession()
        defer { session.invalidateAndCancel(); ThinkingValidationURLProtocol.remove(key) }
        ThinkingValidationURLProtocol.install(key, replies: [.init(status: 422, body: rootThinkingRejection, holdBody: true)])
        let request = thinkingRequest(key)
        let work = Task {
            for try await _ in OpenAIChatCompletionsAdapter().stream(request: request, credentials: .init(), session: session) { }
        }
        defer { work.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while ThinkingValidationURLProtocol.requests(key).isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(ThinkingValidationURLProtocol.requests(key).count == 1)
        work.cancel()
        do { try await work.value } catch is CancellationError { }
        #expect(ThinkingValidationURLProtocol.requests(key).count == 1)
    }
}
