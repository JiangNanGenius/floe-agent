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

/// Everything an adapter needs to build one streaming request.
public struct ProviderStreamRequest: Sendable {
    public var provider: ProviderProfile
    public var model: ModelProfile
    /// Conversation messages in wire-neutral form: (role, text content).
    public var messages: [(role: String, content: String)]
    /// Tool results to feed back, in wire-neutral form.
    public var toolResults: [(callID: String, output: String)]
    /// Pending assistant tool calls awaiting results (for context).
    public var pendingToolCalls: [ToolCall]
    /// Tools offered to the model, as wire-neutral schema descriptors.
    public var toolSchemas: [ToolSchemaDescriptor]

    public init(
        provider: ProviderProfile,
        model: ModelProfile,
        messages: [(role: String, content: String)] = [],
        toolResults: [(callID: String, output: String)] = [],
        pendingToolCalls: [ToolCall] = [],
        toolSchemas: [ToolSchemaDescriptor] = []
    ) {
        self.provider = provider
        self.model = model
        self.messages = messages
        self.toolResults = toolResults
        self.pendingToolCalls = pendingToolCalls
        self.toolSchemas = toolSchemas
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
        var input: [ResponsesRequest.InputItem] = request.messages.map {
            .message(role: $0.role, content: $0.content)
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
            maxOutputTokens: request.model.limits.maxOutputTokens,
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
                                continuation.yield(event)
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
        var messages: [ChatRequest.Message] = request.messages.map {
            ChatRequest.Message(role: $0.role, content: $0.content)
        }
        if !request.pendingToolCalls.isEmpty {
            messages.append(ChatRequest.Message(
                role: "assistant",
                content: nil,
                toolCalls: request.pendingToolCalls.map { call in
                    ChatRequest.Message.ToolCall(
                        id: call.id,
                        function: .init(
                            name: call.toolName,
                            arguments: String(decoding: call.argumentsJSON, as: UTF8.self)
                        )
                    )
                }
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
            ChatRequest.ToolDefinition(
                name: $0.name,
                description: $0.description,
                parameters: $0.parametersJSON
            )
        }
        return ChatRequest(
            model: request.model.remoteModelID,
            messages: messages,
            tools: tools,
            maxTokens: request.model.limits.maxOutputTokens,
            stream: true
        )
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
        let system = request.messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n\n")
        var messages: [AnthropicRequest.Message] = request.messages
            .filter { $0.role != "system" }
            .map {
            AnthropicRequest.Message(role: $0.role, content: [.text($0.content)])
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
        return AnthropicRequest(
            model: request.model.remoteModelID,
            maxTokens: request.model.limits.maxOutputTokens,
            messages: messages,
            system: system.isEmpty ? nil : system,
            tools: tools,
            stream: true
        )
    }
}
