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
            baseURL: URL(string: "https://example.invalid/v1")!
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
            pendingToolCalls: [call]
        )

        let chatObject = try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))
        let chatMessages = try #require(chatObject["messages"] as? [[String: Any]])
        #expect(chatMessages.contains { $0["role"] as? String == "assistant" && $0["tool_calls"] != nil })
        #expect(chatMessages.contains { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == call.id })
        let responsesObject = try jsonObject(OpenAIResponsesAdapter().buildBody(from: request))
        let input = try #require(responsesObject["input"] as? [[String: Any]])
        #expect(input.contains { $0["type"] as? String == "function_call" && $0["call_id"] as? String == call.id })
        #expect(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == call.id })
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
        #expect(try jsonObject(OpenAIChatCompletionsAdapter().buildBody(from: request))["max_tokens"] == nil)
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
