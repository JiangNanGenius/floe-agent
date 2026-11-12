// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import FloeCore
import FloeModels
@testable import FloeProviders

private final class VeniceContractURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State { var body: String; var requests: [URLRequest] = [] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    static func install(_ id: String, body: String) { lock.withLock { states[id] = .init(body: body) } }
    static func requests(_ id: String) -> [URLRequest] { lock.withLock { states[id]?.requests ?? [] } }
    static func remove(_ id: String) { lock.withLock { _ = states.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true } // Never use the network.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let input = captured.httpBodyStream {
            input.open(); defer { input.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }; data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        let id = request.value(forHTTPHeaderField: "X-Synthetic-Contract-ID") ?? ""
        let result = Self.lock.withLock { () -> (Int,String) in
            guard var state = Self.states[id] else { return (500,"Missing owned fixture") }
            state.requests.append(captured); Self.states[id] = state; return (200,state.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type":"text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.1.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Venice metadata and final reasoning omission", .serialized)
struct VeniceReasoningContractTests {
    private func request() -> ProviderStreamRequest {
        let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.venice.ai/api/v1")!)
        var model = ModelProfile(providerID: provider.id, remoteModelID: "e2ee-deepseek-derived-synthetic",
            displayName: "Owned contract model", limits: .init(contextTokens: 1_000_000, maxOutputTokens: 131_072),
            capabilities: [.text,.tools], reasoningEffort: .maximum)
        model.reasoningMetadata = .init(supportsReasoning: true, supportsReasoningEffort: true,
            supportedEfforts: ["low","high","max"], defaultEffort: "low", canDisableThinking: false)
        return .init(provider: provider, model: model, messages: [(role:"user",content:"Use the owned native tool")],
            toolSchemas: [.init(name:"studio.read",description:"Read the owned fixture",parametersJSON:#"{"type":"object"}"#)],
            allToolNames:["studio.read"])
    }
    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func veniceMapsOnlyDeclaredEffortsAndKeepsNonAdjustableReasoning() throws {
        for (options,intent,expected) in [
            (["low","high","max"],ModelReasoningEffort.medium,"low"),
            (["high","max"],.low,"high"),
            (["low","medium","high"],.maximum,"high"),
            (["high","xhigh"],.maximum,"xhigh"),
            (["xhigh","max"],.high,"xhigh"),
            (["low","high","max"],.maximum,"max")
        ] {
            var input = request(); input.model.reasoningEffort = intent
            input.model.reasoningMetadata?.supportedEfforts = options
            let body = try json(OpenAIChatCompletionsAdapter().buildBody(from: input))
            let controls = try #require(body["reasoning"] as? [String: Any])
            #expect(controls["effort"] as? String == expected && controls["enabled"] as? Bool == true)
            #expect(body["thinking"] == nil && body["reasoning_effort"] == nil && body["enable_thinking"] == nil)
            let clamped = ReasoningCompatibility.clampAutomaticReasoningEffort(intent, provider: input.provider, model: input.model)
            var frozen = input.model; frozen.reasoningEffort = clamped
            #expect(ReasoningCompatibility.wireEffortValue(provider: input.provider, model: frozen) == expected)
        }
        var input = request(); input.model.reasoningEffort = .automatic
        #expect(try json(OpenAIChatCompletionsAdapter().buildBody(from: input))["reasoning"] == nil)
        #expect(input.model.reasoningMetadata?.defaultEffort == "low")
        // The actual user's model advertises reasoning but no effort control.
        input.model.reasoningEffort = .maximum
        input.model.reasoningMetadata = .init(supportsReasoning: true, supportsReasoningEffort: false)
        #expect(try json(OpenAIChatCompletionsAdapter().buildBody(from: input))["reasoning"] == nil)
        #expect(!ReasoningCompatibility.supportsVariableReasoningEffort(provider: input.provider, model: input.model))
        #expect(input.model.capabilities.contains([.text,.tools]))
        // Even a 'none' token does not establish a disable capability.
        input.model.reasoningMetadata = .init(supportsReasoning: true, supportsReasoningEffort: true, supportedEfforts:["none","high"])
        input.reasoningPolicy = .disabled
        #expect(try json(OpenAIChatCompletionsAdapter().buildBody(from: input))["reasoning"] == nil)
        input.model.reasoningMetadata?.canDisableThinking = true
        #expect((try json(OpenAIChatCompletionsAdapter().buildBody(from: input))["reasoning"] as? [String:Any])?["enabled"] as? Bool == false)
        for endpoint in ["https://gateway.invalid/v1", "https://api.venice.ai/other/v1", "https://api.venice.ai.lookalike.invalid/api/v1"] {
            input.provider.baseURL = URL(string:endpoint)!
            #expect(try json(OpenAIChatCompletionsAdapter().buildBody(from: input))["reasoning"] == nil)
        }
    }

    @Test func omitReasoningWinsAfterChatPreferencesWithoutRemovingHistoryOrTools() throws {
        let call = try ToolCall(id:"owned-history",toolName:"studio.read",argumentsJSON:Data("{}".utf8),scope:.local)
        for wire in [ModelProtocol.openAIChatCompletions,.openAIResponses,.anthropicMessages] {
            for policy in [ProviderReasoningPolicy.modelDefault,.disabled] {
                var input = request(); input.provider.wireProtocol = wire
                input.provider.baseURL = URL(string:"https://api.deepseek.com")!
                input.model.omitReasoningParameters = true; input.reasoningPolicy = policy
                input.pendingToolCalls = [call]; input.pendingAssistantReasoning = "Preserved captured reasoning"
                input.toolResults = [(callID:call.id,output:"Preserved actual result")]
                let body: [String:Any]
                switch wire {
                case .openAIChatCompletions: body = try json(OpenAIChatCompletionsAdapter().buildBody(from: input))
                case .openAIResponses: body = try json(OpenAIResponsesAdapter().buildBody(from: input))
                case .anthropicMessages: body = try json(AnthropicMessagesAdapter().buildBody(from: input))
                }
                for key in ["thinking","reasoning_effort","reasoning","enable_thinking","disable_thinking","thinkingConfig","output_config"] { #expect(body[key] == nil) }
                #expect((body["tools"] as? [Any])?.count == 1)
                let encoded = String(decoding:try JSONSerialization.data(withJSONObject:body),as:UTF8.self)
                #expect(encoded.contains("Preserved captured reasoning") && encoded.contains("Preserved actual result"))
                #expect(!ReasoningCompatibility.supportsVariableReasoningEffort(provider:input.provider,model:input.model))
                for preference in [ChatReasoningPreference.fast,.low,.medium,.high,.maximum] {
                    let resolved = ReasoningCompatibility.resolveChatReasoning(preference,provider:input.provider,model:input.model)
                    #expect(resolved.policy == .modelDefault && resolved.level == nil)
                }
            }
        }
    }

    @Test func normalNativeReasoningContractsRemainDistinctFromVenice() throws {
        for (kind,wire,url,id,key,expected) in [
            (ProviderKind.custom,ModelProtocol.openAIChatCompletions,"https://api.deepseek.com","deepseek-v4-flash","reasoning_effort","max"),
            (.volcengineArk,.openAIChatCompletions,"https://ark.cn-beijing.volces.com/api/v3","doubao-thinking","reasoning_effort","high"),
            (.openAI,.openAIResponses,"https://api.openai.com/v1","gpt-5.6-codex","reasoning","xhigh"),
            (.custom,.openAIChatCompletions,"https://generativelanguage.googleapis.com/v1beta/openai","gemini-3-pro-preview","reasoning_effort","high"),
            (.anthropic,.anthropicMessages,"https://api.anthropic.com","claude-opus-4-6","output_config","max")
        ] {
            var input = request(); input.provider.kind = kind; input.provider.wireProtocol = wire
            input.provider.baseURL = URL(string:url)!; input.model.remoteModelID = id
            input.model.reasoningMetadata = nil; input.model.omitReasoningParameters = false
            let body: [String:Any]
            switch wire {
            case .openAIChatCompletions: body = try json(OpenAIChatCompletionsAdapter().buildBody(from:input))
            case .openAIResponses: body = try json(OpenAIResponsesAdapter().buildBody(from:input))
            case .anthropicMessages: body = try json(AnthropicMessagesAdapter().buildBody(from:input))
            }
            let value = (body[key] as? String) ?? (body[key] as? [String:String])?["effort"]
            #expect(value == expected)
            #expect((body["tools"] as? [Any])?.count == 1)
            input.model.omitReasoningParameters = true
            let suppressed: [String:Any]
            switch wire {
            case .openAIChatCompletions: suppressed = try json(OpenAIChatCompletionsAdapter().buildBody(from:input))
            case .openAIResponses: suppressed = try json(OpenAIResponsesAdapter().buildBody(from:input))
            case .anthropicMessages: suppressed = try json(AnthropicMessagesAdapter().buildBody(from:input))
            }
            for field in ["thinking","reasoning_effort","reasoning","enable_thinking","output_config"] { #expect(suppressed[field] == nil) }
        }
    }

    @Test func actualChatStreamKeepsReasoningAndOneNativeCallWithAndWithoutParameters() async throws {
        for effortSupported in [false,true] {
            for omit in [false,true] {
                let key = UUID().uuidString
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [VeniceContractURLProtocol.self]
                config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 3
                let session = URLSession(configuration:config)
                defer { session.invalidateAndCancel(); VeniceContractURLProtocol.remove(key) }
                let body = "data: " + #"{"choices":[{"index":0,"delta":{"reasoning_content":"Preserved thinking output"}}]}"#
                    + "\n\ndata: " + #"{"choices":[{"index":0,"delta":{"content":"Visible answer"}}]}"#
                    + "\n\ndata: " + #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"new-owned-call","type":"function","function":{"name":"studio_read","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
                    + "\n\ndata: [DONE]\n\n"
                VeniceContractURLProtocol.install(key,body:body)
                var input = request(); input.provider.nonSecretHeaders["X-Synthetic-Contract-ID"] = key
                input.model.reasoningMetadata?.supportsReasoningEffort = effortSupported
                input.model.omitReasoningParameters = omit
                var reasoning = "", answer = "", calls:[ToolCall] = [], errors = 0
                for try await event in OpenAIChatCompletionsAdapter().stream(request:input,credentials:.init(),session:session) {
                    if case .reasoningSummary(let value) = event { reasoning += value.text }
                    if case .textDelta(let value) = event { answer += value.text }
                    if case .toolRequest(let call) = event { calls.append(call) }
                    if case .error = event { errors += 1 }
                }
                let requests = VeniceContractURLProtocol.requests(key)
                #expect(requests.count == 1 && errors == 0)
                let data = try #require(requests.first?.httpBody)
                let sent = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
                #expect(sent["thinking"] == nil && sent["venice_parameters"] == nil)
                #expect((sent["reasoning"] != nil) == (effortSupported && !omit))
                #expect(requests.first?.value(forHTTPHeaderField:"X-Venice-TEE-Client-Pub-Key") == nil)
                #expect(reasoning == "Preserved thinking output" && answer == "Visible answer")
                #expect(calls.map(\.id) == ["new-owned-call"] && calls.first?.toolName == "studio.read")
            }
        }
    }
}


extension VeniceReasoningContractTests {
    @Test func veniceMissingReasoningKeepsTheActualAssistantAndNativeToolRound() throws {
        let call = try ToolCall(id:"original-owned-call",toolName:"studio.read",argumentsJSON:Data("{}".utf8),scope:.local)
        let result = ToolResult(callID:call.id,status:.ok,outputSummary:"Original actual tool result",outputDigest:"owned-digest")
        for captured in [String?.none, "Original optional reasoning"] {
            for wire in [ModelProtocol.openAIChatCompletions,.openAIResponses,.anthropicMessages] {
                var input = request(); input.provider.wireProtocol = wire
                input.model.reasoningMetadata = .init(supportsReasoning:true,supportsReasoningEffort:false)
                input.contentMessages = [.init(role:"user",text:"Original question"),
                    .init(role:"assistant",content:[.text("Original assistant reply")],reasoningContent:captured)]
                input.replayedToolPairs = [.init(call:call,result:result,assistantReasoning:captured)]
                #expect(ReasoningCompatibility.requiresAssistantReasoningReplay(provider:input.provider,model:input.model))
                #expect(!ReasoningCompatibility.requiresMissingReasoningFallback(provider:input.provider,model:input.model))
                let body:[String:Any]
                switch wire {
                case .openAIChatCompletions:
                    body = try json(OpenAIChatCompletionsAdapter().buildBody(from:input))
                    let messages = try #require(body["messages"] as? [[String:Any]])
                    #expect(messages.contains { $0["role"] as? String == "assistant" && $0["content"] as? String == "Original assistant reply" })
                    #expect(messages.contains { message in
                        (message["role"] as? String) == "assistant"
                            && (message["tool_calls"] as? [[String:Any]])?.first?["id"] as? String == call.id
                    })
                    #expect(messages.contains { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == call.id })
                case .openAIResponses:
                    body = try json(OpenAIResponsesAdapter().buildBody(from:input))
                    let items = try #require(body["input"] as? [[String:Any]])
                    #expect(items.contains { $0["role"] as? String == "assistant" && $0["content"] as? String == "Original assistant reply" })
                    #expect(items.contains { $0["type"] as? String == "function_call" && $0["call_id"] as? String == call.id })
                    #expect(items.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == call.id })
                case .anthropicMessages:
                    body = try json(AnthropicMessagesAdapter().buildBody(from:input))
                    let messages = try #require(body["messages"] as? [[String:Any]])
                    #expect(messages.contains { message in
                        (message["role"] as? String) == "assistant"
                            && (message["content"] as? [[String:Any]])?.contains { $0["type"] as? String == "tool_use" && $0["id"] as? String == call.id } == true
                    })
                }
                let encoded = String(decoding:try JSONSerialization.data(withJSONObject:body),as:UTF8.self)
                #expect(!encoded.contains("[Legacy assistant history;") && !encoded.contains("[Historical tool call;"))
                #expect(encoded.contains("Original actual tool result"))
                if let captured { #expect(encoded.contains(captured)) }
                input.provider.baseURL = URL(string:"https://api.deepseek.com")!
                #expect(ReasoningCompatibility.requiresMissingReasoningFallback(provider:input.provider,model:input.model))
            }
        }
    }
}
