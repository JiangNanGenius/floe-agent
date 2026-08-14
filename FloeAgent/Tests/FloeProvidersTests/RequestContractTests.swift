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
