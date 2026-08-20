// FloeProviders — Provider adapter protocol, request model, and the three
// adapter skeletons (OpenAI Responses, OpenAI Chat Completions, Anthropic
// Messages). Network transport is URLSession bytes(for:) + SSEParser.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore
import FloeModels

/// Credentials resolved from the Keychain for one request. Never persisted
/// beyond the call site.
public struct ProviderCredentials: Sendable {
    public var apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }
}

/// Wire-neutral tool schema descriptor offered to the model. Mirrors the
/// catalog's descriptor without creating a FloeProviders → FloeTools
/// dependency cycle (FloeAgentRuntime maps between them).
public struct ToolSchemaDescriptor: Sendable, Hashable {
    public var name: String
    public var description: String
    /// JSON Schema object as raw JSON string.
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String = #"{"type":"object"}"#) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// Ordered, wire-neutral content sent to a model. Keeping images as bounded
/// inline data or an HTTPS URL lets the runtime attach browser screenshots
/// without teaching the harness about each provider's JSON dialect.
public enum ProviderContentPart: Sendable, Hashable {
    case text(String)
    case imageData(mimeType: String, base64: String)
    case imageURL(URL)
}

public struct ProviderMessage: Sendable, Hashable {
    public var role: String
    public var content: [ProviderContentPart]

    public init(role: String, content: [ProviderContentPart]) {
        self.role = role
        self.content = content
    }

    public init(role: String, text: String) {
        self.init(role: role, content: [.text(text)])
    }
}

/// Everything an adapter needs to build one streaming request.
public struct ProviderStreamRequest: Sendable {
    public var provider: ProviderProfile
    public var model: ModelProfile
    /// Conversation messages in wire-neutral form: (role, text content).
    public var messages: [(role: String, content: String)]
    /// Ordered multimodal messages. When non-empty these supersede `messages`.
    /// The legacy text field remains source-compatible with existing callers.
    public var contentMessages: [ProviderMessage]
    /// Tool results to feed back, in wire-neutral form.
    public var toolResults: [(callID: String, output: String)]
    /// Pending assistant tool calls awaiting results (for context).
    public var pendingToolCalls: [ToolCall]
    /// Provider reasoning emitted immediately before pending tool calls.
    /// DeepSeek requires this exact field on the follow-up request.
    public var pendingAssistantReasoning: String?
    /// Tools offered to the model, as wire-neutral schema descriptors.
    public var toolSchemas: [ToolSchemaDescriptor]

    public init(
        provider: ProviderProfile,
        model: ModelProfile,
        messages: [(role: String, content: String)] = [],
        contentMessages: [ProviderMessage] = [],
        toolResults: [(callID: String, output: String)] = [],
        pendingToolCalls: [ToolCall] = [],
        pendingAssistantReasoning: String? = nil,
        toolSchemas: [ToolSchemaDescriptor] = []
    ) {
        self.provider = provider
        self.model = model
        self.messages = messages
        self.contentMessages = contentMessages
        self.toolResults = toolResults
        self.pendingToolCalls = pendingToolCalls
        self.pendingAssistantReasoning = pendingAssistantReasoning
        self.toolSchemas = toolSchemas
    }

    public var effectiveMessages: [ProviderMessage] {
        if !contentMessages.isEmpty { return contentMessages }
        return messages.map { ProviderMessage(role: $0.role, text: $0.content) }
    }
}

/// One provider endpoint speaking one wire protocol. Implementations must
/// be value types or actors; all shared mutable state stays inside the
/// returned stream's task.
public protocol ProviderAdapter: Sendable {
    /// Wire protocol this adapter speaks.
    var protocolKind: ModelProtocol { get }

    /// Opens a streaming completion. The returned stream yields translated
    /// `AgentEvent` values and terminates after `.completed`, `.error`, or
    /// task cancellation (which must yield `.error(.cancelled)` semantics
    /// via stream termination — the runtime injects the cancelled event).
    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error>

    /// Lists models available at the endpoint. `listModels` failures
    /// surface as thrown errors, not stream events, so callers can fall back
    /// to manual model entry. `provider` supplies the base URL and
    /// non-secret headers; `credentials` supplies the API key.
    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile]

    /// Performs a lightweight connectivity/auth check against the endpoint.
    /// Throws on failure.
    func testConnection(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws
}

public extension ProviderAdapter {
    /// Default connection probe: attempt model discovery. Adapters may
    /// override with a cheaper request.
    func testConnection(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws {
        _ = try await listModels(provider: provider, credentials: credentials)
    }
}

// MARK: - Shared SSE plumbing

/// Reads a non-streaming response with an application-level byte ceiling.
/// The Apple path stops reading as soon as the limit is crossed instead of
/// first buffering the complete body in memory.
enum BoundedHTTP {
    static func data(
        for request: URLRequest,
        session: URLSession = .shared,
        maxBytes: Int
    ) async throws -> (Data, URLResponse) {
        #if os(Linux)
        let (data, response) = try await session.data(for: request)
        guard data.count <= maxBytes else {
            throw FloeError.validationFailed("Provider response exceeds \(maxBytes) bytes")
        }
        return (data, response)
        #else
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maxBytes) {
            throw FloeError.validationFailed("Provider response exceeds \(maxBytes) bytes")
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maxBytes else {
                throw FloeError.validationFailed("Provider response exceeds \(maxBytes) bytes")
            }
            data.append(byte)
        }
        return (data, response)
        #endif
    }
}

/// Feeds an HTTP byte stream through `SSEParser` and emits decoded SSE
/// events. Cancellation of the consuming task cancels the URLSession task.
struct SSEBytePump: Sendable {
    let urlRequest: URLRequest

    func events() -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    #if os(Linux)
                    // FoundationNetworking does not expose URLSession.bytes(for:).
                    // Linux is a build/test target, not an app runtime, so use a
                    // bounded-lifetime buffered fallback to keep wire parsing and
                    // contract tests portable. Apple platforms remain truly streaming.
                    let (data, response) = try await URLSession.shared.data(for: urlRequest)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        let body = String(decoding: data.prefix(4096), as: UTF8.self)
                        continuation.yield(SSEEvent(
                            event: "__http_error__",
                            data: "\(http.statusCode)\n\(body)"
                        ))
                        continuation.finish()
                        return
                    }
                    try Task.checkCancellation()
                    for event in parser.feed(data) {
                        continuation.yield(event)
                    }
                    for event in try parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                    #else
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await byte in bytes {
                            body.append(Character(UnicodeScalar(byte)))
                            if body.count > 4096 { break }
                        }
                        continuation.yield(SSEEvent(
                            event: "__http_error__",
                            data: "\(http.statusCode)\n\(body)"
                        ))
                        continuation.finish()
                        return
                    }
                    var buffer: [UInt8] = []
                    buffer.reserveCapacity(4096)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if buffer.count >= 1024 {
                            for event in parser.feed(buffer) {
                                continuation.yield(event)
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        for event in parser.feed(buffer) {
                            continuation.yield(event)
                        }
                    }
                    for event in try parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                    #endif
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Extracts an HTTP error AgentEvent from the pump's sentinel event.
func httpErrorEvent(from sseEvent: SSEEvent) -> AgentEvent? {
    if sseEvent.event == "__floe_sse_error__" {
        return .error(AgentEvent.NormalizedError(
            kind: .malformed,
            providerMessage: sseEvent.data
        ))
    }
    guard sseEvent.event == "__http_error__" else { return nil }
    let lines = sseEvent.data.split(separator: "\n", maxSplits: 1)
    let status = Int(lines.first ?? "") ?? 500
    let body = lines.count > 1 ? String(lines[1]) : ""
    return WireTranslator.httpError(status: status, body: body)
}

// MARK: - OpenAI Responses adapter

/// Adapter for the OpenAI Responses API (`/responses`, SSE streaming).
public struct OpenAIResponsesAdapter: ProviderAdapter {
    public let protocolKind: ModelProtocol = .openAIResponses
    private let logger = FloeLogger(category: .providers)

    public init() {}

    public func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = try buildURLRequest(request: request, credentials: credentials)
                    urlRequest.httpBody = try JSONEncoder().encode(buildBody(from: request))
                    let pump = SSEBytePump(urlRequest: urlRequest)
                    let decoder = JSONDecoder()
                    for try await sseEvent in pump.events() {
                        if let errorEvent = httpErrorEvent(from: sseEvent) {
                            continuation.yield(errorEvent)
                            continue
                        }
                        guard sseEvent.data != "[DONE]" else { continue }
                        do {
                            let wireEvent = try decoder.decode(ResponsesStreamEvent.self, from: Data(sseEvent.data.utf8))
                            for event in WireTranslator.translate(wireEvent) {
                                continuation.yield(event)
                            }
                        } catch {
                            logger.warning("Responses event decode failed: \(error.localizedDescription)")
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        try await ModelDiscovery.fetchOpenAICompatibleModels(provider: provider, credentials: credentials)
    }

    func buildURLRequest(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) throws -> URLRequest {
        let url = request.provider.baseURL.appendingPathComponent("responses")
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 45
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey = credentials.apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in request.provider.nonSecretHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        return urlRequest
    }

    func buildBody(from request: ProviderStreamRequest) -> ResponsesRequest {
        var input: [ResponsesRequest.InputItem] = request.effectiveMessages.map { message in
            if case .text(let text) = message.content.first, message.content.count == 1 {
                return .message(role: message.role, content: text)
            }
            return .multimodalMessage(
                role: message.role,
                content: message.content.map { part in
                    switch part {
                    case .text(let text): return .text(text)
                    case .imageData(let mimeType, let base64):
                        return .imageURL("data:\(mimeType);base64,\(base64)")
                    case .imageURL(let url): return .imageURL(url.absoluteString)
                    }
                }
            )
        }
        for call in request.pendingToolCalls {
            input.append(.functionCall(
                callID: call.id,
                name: call.toolName,
                arguments: String(decoding: call.argumentsJSON, as: UTF8.self)
            ))
        }
        for result in request.toolResults {
            input.append(.functionCallOutput(callID: result.callID, output: result.output))
        }
        let tools = request.toolSchemas.map {
            ResponsesRequest.ToolDefinition(
                name: $0.name,
                description: $0.description,
                parameters: $0.parametersJSON
            )
        }
        return ResponsesRequest(
            model: request.model.remoteModelID,
            input: input,
            tools: tools,
            maxOutputTokens: request.model.limits.configuredMaxOutputTokens,
            reasoning: ReasoningCompatibility.responsesEffort(
                provider: request.provider,
                model: request.model
            ).map(ResponsesRequest.Reasoning.init(effort:)),
            stream: true
        )
    }
}

// MARK: - OpenAI Chat Completions adapter

/// Adapter for the OpenAI Chat Completions API (`/chat/completions`, SSE).
public struct OpenAIChatCompletionsAdapter: ProviderAdapter {
    public let protocolKind: ModelProtocol = .openAIChatCompletions
    private let logger = FloeLogger(category: .providers)

    public init() {}

    public func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = try buildURLRequest(request: request, credentials: credentials)
                    urlRequest.httpBody = try JSONEncoder().encode(buildBody(from: request))
                    let pump = SSEBytePump(urlRequest: urlRequest)
                    let decoder = JSONDecoder()
                    var aggregator = ToolCallAggregator()
                    for try await sseEvent in pump.events() {
                        if let errorEvent = httpErrorEvent(from: sseEvent) {
                            continuation.yield(errorEvent)
                            continue
                        }
                        guard sseEvent.data != "[DONE]" else { continue }
                        do {
                            let chunk = try decoder.decode(ChatChunk.self, from: Data(sseEvent.data.utf8))
                            for event in WireTranslator.translate(chunk, aggregator: &aggregator) {
                                if case .toolRequest(var call) = event {
                                    call.toolName = canonicalToolName(call.toolName, for: request)
                                    continuation.yield(.toolRequest(call))
                                } else {
                                    continuation.yield(event)
                                }
                            }
                        } catch {
                            logger.warning("Chat chunk decode failed: \(error.localizedDescription)")
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        try await ModelDiscovery.fetchOpenAICompatibleModels(provider: provider, credentials: credentials)
    }

    func buildURLRequest(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) throws -> URLRequest {
        let url = request.provider.baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 45
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey = credentials.apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in request.provider.nonSecretHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        return urlRequest
    }

    func buildBody(from request: ProviderStreamRequest) -> ChatRequest {
        var messages: [ChatRequest.Message] = request.effectiveMessages.map { message in
            if case .text(let text) = message.content.first, message.content.count == 1 {
                return ChatRequest.Message(role: message.role, content: text)
            }
            return ChatRequest.Message(
                role: message.role,
                contentParts: message.content.map { part in
                    switch part {
                    case .text(let text): return .text(text)
                    case .imageData(let mimeType, let base64):
                        return .imageURL("data:\(mimeType);base64,\(base64)")
                    case .imageURL(let url): return .imageURL(url.absoluteString)
                    }
                }
            )
        }
        if !request.pendingToolCalls.isEmpty {
            messages.append(ChatRequest.Message(
                role: "assistant",
                content: nil,
                toolCalls: request.pendingToolCalls.map { call in
                    ChatRequest.Message.ToolCall(
                        id: call.id,
                        function: .init(
                            name: wireToolName(call.toolName, for: request.provider),
                            arguments: String(decoding: call.argumentsJSON, as: UTF8.self)
                        )
                    )
                },
                reasoningContent: ReasoningCompatibility.requiresAssistantReasoningReplay(
                    provider: request.provider,
                    model: request.model
                ) ? request.pendingAssistantReasoning : nil
            ))
        }
        for result in request.toolResults {
            messages.append(ChatRequest.Message(
                role: "tool",
                content: result.output,
                toolCallID: result.callID
            ))
        }
        let tools = request.toolSchemas.map {
            // DeepSeek and some gateways reject dots in tool names
            // (^[a-zA-Z0-9_-]+$). When the provider has toolNameCompatibility
            // enabled, convert dots to underscores for the wire only.
            let wireName = wireToolName($0.name, for: request.provider)
            return ChatRequest.ToolDefinition(
                name: wireName,
                description: $0.description,
                parameters: $0.parametersJSON
            )
        }
        let reasoning = ReasoningCompatibility.chatOptions(
            provider: request.provider,
            model: request.model
        )
        return ChatRequest(
            model: request.model.remoteModelID,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            maxTokens: request.model.limits.configuredMaxOutputTokens,
            thinking: reasoning.thinkingType.map(ChatRequest.Thinking.init(type:)),
            reasoningEffort: reasoning.reasoningEffort,
            stream: true,
            streamOptions: .init(includeUsage: true)
        )
    }

    /// Converts only names actually advertised on this request. A model may
    /// still return a canonical dotted name, and underscore collisions remain
    /// untouched unless the mapping is unique.
    func canonicalToolName(_ wireName: String, for request: ProviderStreamRequest) -> String {
        guard request.provider.toolNameCompatibility else { return wireName }
        if request.toolSchemas.contains(where: { $0.name == wireName }) { return wireName }
        let matches = request.toolSchemas.filter {
            wireToolName($0.name, for: request.provider) == wireName
        }
        return matches.count == 1 ? matches[0].name : wireName
    }

    func wireToolName(_ canonicalName: String, for provider: ProviderProfile) -> String {
        provider.toolNameCompatibility
            ? canonicalName.replacingOccurrences(of: ".", with: "_")
            : canonicalName
    }
}

// MARK: - Anthropic Messages adapter

/// Adapter for the Anthropic Messages API (`/v1/messages`, SSE streaming).
public struct AnthropicMessagesAdapter: ProviderAdapter {
    public let protocolKind: ModelProtocol = .anthropicMessages
    private let logger = FloeLogger(category: .providers)

    /// API version header required by Anthropic.
    public static let apiVersion = "2023-06-01"

    public init() {}

    public func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = try buildURLRequest(request: request, credentials: credentials)
                    urlRequest.httpBody = try JSONEncoder().encode(buildBody(from: request))
                    let pump = SSEBytePump(urlRequest: urlRequest)
                    let decoder = JSONDecoder()
                    var aggregator = WireTranslator.AnthropicAggregator()
                    for try await sseEvent in pump.events() {
                        if let errorEvent = httpErrorEvent(from: sseEvent) {
                            continuation.yield(errorEvent)
                            continue
                        }
                        do {
                            let wireEvent = try decoder.decode(AnthropicStreamEvent.self, from: Data(sseEvent.data.utf8))
                            for event in WireTranslator.translate(wireEvent, aggregator: &aggregator) {
                                continuation.yield(event)
                            }
                        } catch {
                            logger.warning("Anthropic event decode failed: \(error.localizedDescription)")
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        try await ModelDiscovery.fetchAnthropicModels(provider: provider, credentials: credentials)
    }

    func buildURLRequest(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) throws -> URLRequest {
        let url = request.provider.baseURL.appendingPathComponent("v1/messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 45
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let apiKey = credentials.apiKey {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        for (field, value) in request.provider.nonSecretHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        return urlRequest
    }

    func buildBody(from request: ProviderStreamRequest) -> AnthropicRequest {
        let system = request.effectiveMessages
            .filter { $0.role == "system" }
            .flatMap(\.content)
            .compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            .joined(separator: "\n\n")
        var messages: [AnthropicRequest.Message] = request.effectiveMessages
            .filter { $0.role != "system" }
            .map { message in
            AnthropicRequest.Message(role: message.role, content: message.content.map { part in
                switch part {
                case .text(let text): return .text(text)
                case .imageData(let mimeType, let base64): return .image(mimeType: mimeType, base64: base64)
                case .imageURL(let url): return .text("[Image: \(url.absoluteString)]")
                }
            })
        }
        if !request.pendingToolCalls.isEmpty {
            messages.append(AnthropicRequest.Message(
                role: "assistant",
                content: request.pendingToolCalls.map { call in
                    .toolUse(
                        id: call.id,
                        name: call.toolName,
                        inputJSON: String(decoding: call.argumentsJSON, as: UTF8.self)
                    )
                }
            ))
        }
        if !request.toolResults.isEmpty {
            messages.append(AnthropicRequest.Message(
                role: "user",
                content: request.toolResults.map { result in
                    .toolResult(toolUseID: result.callID, content: result.output, isError: false)
                }
            ))
        }
        let tools = request.toolSchemas.map {
            AnthropicRequest.ToolDefinition(
                name: $0.name,
                description: $0.description,
                inputSchema: $0.parametersJSON
            )
        }
        let reasoning = ReasoningCompatibility.anthropicOptions(
            provider: request.provider,
            model: request.model
        )
        return AnthropicRequest(
            model: request.model.remoteModelID,
            // Anthropic requires max_tokens. A blank UI value therefore
            // selects a conservative protocol default instead of forcing the
            // user to research a model-specific number before saving it.
            maxTokens: request.model.limits.configuredMaxOutputTokens
                ?? min(8_192, request.model.limits.contextTokens),
            messages: messages,
            system: system.isEmpty ? nil : system,
            tools: tools,
            thinking: reasoning.thinkingType.map {
                AnthropicRequest.Thinking(type: $0, budgetTokens: reasoning.budgetTokens)
            },
            outputConfig: reasoning.effort.map(AnthropicRequest.OutputConfig.init(effort:)),
            stream: true
        )
    }
}
