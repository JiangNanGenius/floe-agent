// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeModels
@testable import FloeProviders
import Foundation
import Testing

struct ProviderCompatibilityTests {
    @Test("Official tool names survive serialization and recover their canonical spelling",
          arguments: ModelProtocol.allCases)
    func officialWireNames(wire: ModelProtocol) throws {
        let anthropic = wire == .anthropicMessages
        let provider = ProviderProfile(kind: anthropic ? .anthropic : .openAI, wireProtocol: wire,
            baseURL: try #require(URL(string: anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1")))
        let stem = String(repeating: "a", count: 135)
        let names = ["exec.shell", "exec_shell", stem + ".read", stem + ".write"]
        let request = ProviderStreamRequest(
            provider: provider,
            model: .init(providerID: provider.id, remoteModelID: "model", displayName: "Fixture",
                         limits: .init(contextTokens: 32_768, maxOutputTokens: 2048), capabilities: [.text, .tools]),
            contentMessages: [.init(role: "user", content: [.text("Read the fixture.")])],
            toolResults: [],
            toolSchemas: names.map { .init(name: $0, description: "Fixture", parametersJSON: #"{"type":"object"}"#) },
            allToolNames: names
        )
        let table = CompatToolNames.wireTable(for: request)
        let encoded: Data
        switch wire {
        case .openAIChatCompletions:
            encoded = try OpenAIChatCompletionsAdapter().prepareBody(from: request).data
            let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(json["max_completion_tokens"] as? Int == 2048)
            #expect(json["max_tokens"] == nil)
        case .openAIResponses: encoded = try JSONEncoder().encode(OpenAIResponsesAdapter().buildBody(from: request))
        case .anthropicMessages: encoded = try JSONEncoder().encode(AnthropicMessagesAdapter().buildBody(from: request))
        }
        let limit = anthropic ? 128 : 64
        #expect(Set(table.values).count == names.count)
        for name in names {
            let spelling = try #require(table[name])
            #expect(spelling.count <= limit)
            #expect(spelling.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
            #expect(encoded.range(of: Data(("\"" + spelling + "\"").utf8)) != nil)
            #expect(CompatToolNames.canonicalName(spelling, request: request) == name)
        }
    }

    @Test("Only official Ark Agent Plan subscription errors show a subscription remedy")
    func inactiveSubscription() {
        let plan = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
                                   baseURL: ProviderPreset.volcengineAgentPlan.defaultBaseURL)
        let payg = ProviderProfile(kind: .volcengineArk, wireProtocol: .openAIChatCompletions,
                                   baseURL: ProviderPreset.volcengineArk.defaultBaseURL)
        let secret = "FLOE-unit-test-sensitive-exact-value"
        let body = #"{"error":{"code":"InvalidSubscription","message":"\#(secret) 已到期"}}"#
        let event = SSEEvent(event: "__http_error__", data: "400\n" + body)
        guard case .error(let subscription) = httpErrorEvent(from: event, provider: plan, secret: secret),
              case .error(let other) = httpErrorEvent(from: event, provider: payg, secret: secret) else {
            Issue.record("Missing provider error event"); return
        }
        #expect(subscription.kind == .auth)
        #expect(subscription.providerMessage == ProviderConnectionProbe.inactiveVolcenginePlanMessage)
        #expect(other.kind == .malformed)
        #expect(!other.providerMessage.contains(secret))
        #expect(other.providerMessage.contains("已到期"))
    }
}
