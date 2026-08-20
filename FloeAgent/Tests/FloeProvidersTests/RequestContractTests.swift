import Foundation
import Testing
@testable import FloeCore
@testable import FloeModels
@testable import FloeProviders

@Suite("FloeProviders.RequestContracts")
struct RequestContractTests {
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

    @Test("Chat tools are omitted when tool calling is disabled")
    func chatOmitsUnusedTools() throws {
        let body = ChatRequest(
            model: "model",
            messages: [.init(role: "user", content: "hello")]
        )
        let object = try jsonObject(body)
        #expect(object["tools"] == nil)
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
        #expect(body.system == "Follow the user intent.")
        #expect(body.messages.count == 1)
        #expect(body.messages.first?.role == "user")
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

    @Test("Compatible tool names round-trip between wire and canonical catalogs")
    func compatibleToolNamesRoundTrip() throws {
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
        #expect(adapter.canonicalToolName("workspace_listDirectory", for: request)
            == "workspace.listDirectory")
        #expect(adapter.canonicalToolName("workspace.listDirectory", for: request)
            == "workspace.listDirectory")
    }

    @Test("Volcengine Ark uses native Chat Completions tool contracts")
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
        #expect((tools.first?["function"] as? [String: Any])?["name"] as? String == "workspace.listDirectory")
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

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
