// FloeProviders — Provider adapter protocol, request model, and the three
// adapter skeletons (OpenAI Responses, OpenAI Chat Completions, Anthropic
// Messages). Network transport is URLSession bytes(for:) + SSEParser.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore
import FloeModels

/// Compat-mode tool name mapping shared by all three wire adapters.
/// Some providers (DeepSeek, gateways) enforce ^[A-Za-z0-9_-]+$ function
/// names, so dotted canonical names travel the wire as underscored spellings.
/// The official Moonshot/Kimi chat endpoints (api.kimi.com, api.moonshot.cn,
/// api.moonshot.ai) are stricter still: any request carrying a name outside
/// ^[A-Za-z][A-Za-z0-9_-]*$ is rejected whole, before the answer starts
/// (Build300 logged exactly
/// {"error":{"type":"invalid_request_error","message":"function name is
/// invalid, must start with a letter and can contain letters, numbers,
/// underscores, and dashes"}} on protocol=chat host=api.kimi.com model=k3.1-pro
/// with tools=23, on 4 attempts with 8 identical error mentions: an immediate
/// request-grammar rejection, not an image decode/size failure — the chat
/// screenshot's IMG_9719.JPG attachment only coincided with the turn). The
/// dotted-name cause is this lane's source-path diagnosis, not a logged fact:
/// neither the catalog default nor any preset sets `toolNameCompatibility`
/// for these hosts and no saved override was logged, so under the previous
/// boundary canonical dotted names (`tools.search`, `exec.shell`,
/// `skill.read`, `checklist.updatePlan`, …) would have reached Kimi raw.
/// Detection is by exact normalized official host only: a display alias or
/// proxy domain that merely contains "kimi"/"moonshot" never rewrites an
/// unrelated endpoint, and the saved `toolNameCompatibility` opt-in keeps
/// forcing the compat spelling for every other provider exactly as before.
/// Normalization stays at the provider wire boundary: runtime history, tool
/// IDs, dispatch and canonical dotted names are untouched, and the reverse
/// map recovers each canonical exactly. The map is total over one complete
/// deterministic per-request universe (run ceiling, this turn's schemas and
/// every assistant-history/pending call name the encoder can emit), because
/// the runtime may legitimately invite calls to tools whose schema was
/// budget-evicted from this request. Unknown or ambiguous spellings pass
/// through unchanged so the runtime's not-in-catalog denial stays honest.
public enum CompatToolNames {
    /// Exact official chat hosts whose function-name grammar requires a
    /// leading ASCII letter. The api.kimi.com identity reuses the typed
    /// `KimiCodeEndpointIdentity` evidence set (for name grammar only —
    /// image routing still requires its stricter path variants); the two
    /// Moonshot platform hosts are the vendor's public API roots.
    static let grammarStrictHosts: Set<String> =
        KimiCodeEndpointIdentity.apiHosts.union(["api.moonshot.cn", "api.moonshot.ai"])

    public static func usesWireSafeNames(_ provider: ProviderProfile) -> Bool {
        provider.traits().usesWireSafeToolNames || requiresLetterInitialNames(provider)
    }

    /// True only for the exact normalized official Moonshot/Kimi chat hosts.
    public static func requiresLetterInitialNames(_ provider: ProviderProfile) -> Bool {
        guard let host = provider.baseURL.host?.lowercased() else { return false }
        return grammarStrictHosts.contains(host)
    }

    /// One deterministic Moonshot/Kimi-grammar hardening: after the compat
    /// dot→underscore step, every remaining non-ASCII-alphanumeric/underscore/
    /// dash scalar becomes an underscore, and a spelling that does not start
    /// with an ASCII letter gains the "f_" prefix. Reversal is exact through
    /// the per-request `wireTable`, not through string arithmetic.
    static func letterInitialSpelling(_ canonicalName: String) -> String {
        let compat = ToolNameSpelling.wire(canonicalName, safe: true)
        var mapped = String(String.UnicodeScalarView(compat.unicodeScalars.map { scalar in
            if ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-" {
                return scalar
            }
            return "_"
        }))
        let startsWithLetter = mapped.unicodeScalars.first.map {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0)
        } ?? false
        if !startsWithLetter { mapped = "f_" + mapped }
        return mapped
    }

    public static func wireName(_ canonicalName: String, for provider: ProviderProfile) -> String {
        if requiresLetterInitialNames(provider) { return letterInitialSpelling(canonicalName) }
        return ToolNameSpelling.wire(canonicalName, safe: usesWireSafeNames(provider))
    }

    /// Wire name using the request's deterministic collision table when one
    /// covers the name; falls back to the per-name spelling otherwise (a
    /// name outside this request's whole outbound universe, e.g. a forged
    /// model emission, keeps the suffix-free hardening and then denies
    /// honestly on the inbound lookup).
    public static func wireName(
        _ canonicalName: String,
        for provider: ProviderProfile,
        table: [String: String]
    ) -> String {
        table[canonicalName] ?? wireName(canonicalName, for: provider)
    }

    /// The complete outbound universe for one request: the run ceiling, this
    /// turn's schemas, and every assistant-history/pending tool-call name the
    /// adapters serialize. History-only names participate in collision
    /// resolution so they can never fall back to the same hardened spelling
    /// as an advertised tool and break exact recovery.
    static func requestUniverse(_ request: ProviderStreamRequest) -> [String] {
        var names = request.allToolNames
        names.append(contentsOf: request.toolSchemas.map(\.name))
        names.append(contentsOf: request.replayedToolPairs.map(\.call.toolName))
        names.append(contentsOf: request.pendingToolCalls.map(\.toolName))
        return names
    }

    /// Deterministic canonical→wire table over the request's complete tool
    /// universe (see `requestUniverse`). On grammar-strict providers two
    /// canonical names that harden to the same spelling (e.g.
    /// `workspace.readFile` and `workspace_readFile`) get "_2"/"_3"… suffixes
    /// in sorted-canonical order, making the forward map injective so the
    /// reverse lookup recovers each canonical name exactly. The same table
    /// serves every outbound occurrence and the inbound lookup. Non-strict
    /// providers get an empty table and keep the legacy per-name spelling,
    /// byte-for-byte unchanged.
    public static func wireTable(for request: ProviderStreamRequest) -> [String: String] {
        guard requiresLetterInitialNames(request.provider) else { return [:] }
        let universe = Set(requestUniverse(request)).sorted()
        var table: [String: String] = [:]
        var used = Set<String>()
        for canonical in universe {
            let base = letterInitialSpelling(canonical)
            var candidate = base
            var suffix = 2
            while used.contains(candidate) {
                candidate = base + "_\(suffix)"
                suffix += 1
            }
            used.insert(candidate)
            table[canonical] = candidate
        }
        return table
    }

    /// Canonical (dotted) name for a model-emitted wire name. The universe is
    /// the run ceiling AND the schemas offered this turn — discovery tools
    /// (tools.list/tools.search) and the synthetic plan tool exist only in
    /// toolSchemas. On grammar-strict providers the exact collision table is
    /// consulted first (suffix-spelled names are unique by construction);
    /// then the shared spelling rule folds dots/case. Unknown or ambiguous
    /// spellings pass through unchanged so the runtime's not-in-catalog
    /// denial stays honest.
    public static func canonicalName(_ wireName: String, request: ProviderStreamRequest) -> String {
        guard usesWireSafeNames(request.provider) else { return wireName }
        if requiresLetterInitialNames(request.provider) {
            let table = wireTable(for: request)
            if let canonical = table.first(where: { $0.value == wireName })?.key {
                return canonical
            }
        }
        var universe = request.allToolNames
        universe.append(contentsOf: request.toolSchemas.map(\.name))
        return ToolNameSpelling.canonical(wireName, among: universe) ?? wireName
    }
}

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
    public var reasoningContent: String?

    public init(role: String, content: [ProviderContentPart], reasoningContent: String? = nil) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
    }

    public init(role: String, text: String) {
        self.init(role: role, content: [.text(text)])
    }
}

/// Per-request reasoning policy. Internal classifiers and visual evidence
/// extraction must be able to explicitly disable reasoning even when the
/// selected provider/model defaults it on.
public enum ProviderReasoningPolicy: Sendable, Hashable {
    case modelDefault
    case disabled
}

/// One settled (call, result) pair from earlier in the run, replayed as wire
/// history so cross-turn tool evidence stays visible to the model instead of
/// collapsing into a ledger excerpt. A nominal type (rather than a tuple)
/// keeps the pair Codable for checkpoints and dispatch snapshots.
public struct ReplayedToolPair: Sendable, Hashable, Codable {
    public var call: ToolCall
    public var result: ToolResult
    /// Reasoning emitted immediately before this call. Thinking-mode providers
    /// (DeepSeek) reject tool-bearing requests whose historical assistant
    /// turns omit `reasoning_content`; nil for pre-capture checkpoints.
    public var assistantReasoning: String?

    public init(call: ToolCall, result: ToolResult, assistantReasoning: String? = nil) {
        self.call = call
        self.result = result
        self.assistantReasoning = assistantReasoning
    }
}

/// Empty reasoning is absent reasoning: an empty string on the wire is
/// rejected by thinking-mode providers and bypasses legacy fallbacks.
func nonEmptyReasoning(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

/// Everything an adapter needs to build one streaming request.
public struct ProviderStreamRequest: Sendable {
    /// Marker splitting the system envelope into a run-stable, cacheable
    /// prefix and a per-turn volatile suffix. The runtime injects it; wire
    /// adapters may turn the prefix into an explicit cache breakpoint.
    public static let liveStateMarker = "# Live runtime state (volatile; refreshed every turn)"

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
    /// Settled pairs from earlier turns, already budget-trimmed by the
    /// runtime. Adapters render them after `messages` and before the pending
    /// pair so tool evidence survives beyond its original follow-up request.
    public var replayedToolPairs: [ReplayedToolPair]
    /// Provider reasoning emitted immediately before pending tool calls.
    /// DeepSeek requires this exact field on the follow-up request.
    public var pendingAssistantReasoning: String?
    /// Tools offered to the model, as wire-neutral schema descriptors.
    public var toolSchemas: [ToolSchemaDescriptor]
    /// Every canonical tool name inside this run's capability ceiling — the
    /// SAME set tools.list enumerates. Compat-mode reverse name mapping must
    /// be total over this set, not just over the budget-trimmed schemas,
    /// because the runtime legitimately invites calls to evicted tools.
    public var allToolNames: [String]
    public var reasoningPolicy: ProviderReasoningPolicy
    /// Transient liveness only. Partial arguments are never dispatched,
    /// persisted as a tool call, or exposed as model text.
    public var onToolArgumentsProgress: (@Sendable () async -> Void)?
    /// True for temporary (ephemeral) conversations: the transport must not
    /// leave request/response content in any shared on-disk cache. The
    /// request still reaches the provider normally — this is a local cache
    /// directive, not a provider zero-retention promise.
    public var ephemeralTransport: Bool

    public init(
        provider: ProviderProfile,
        model: ModelProfile,
        messages: [(role: String, content: String)] = [],
        contentMessages: [ProviderMessage] = [],
        toolResults: [(callID: String, output: String)] = [],
        pendingToolCalls: [ToolCall] = [],
        replayedToolPairs: [ReplayedToolPair] = [],
        pendingAssistantReasoning: String? = nil,
        toolSchemas: [ToolSchemaDescriptor] = [],
        allToolNames: [String] = [],
        reasoningPolicy: ProviderReasoningPolicy = .modelDefault,
        onToolArgumentsProgress: (@Sendable () async -> Void)? = nil,
        ephemeralTransport: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.messages = messages
        self.contentMessages = contentMessages
        self.toolResults = toolResults
        self.pendingToolCalls = pendingToolCalls
        self.replayedToolPairs = replayedToolPairs
        self.pendingAssistantReasoning = pendingAssistantReasoning
        self.toolSchemas = toolSchemas
        self.allToolNames = allToolNames
        self.reasoningPolicy = reasoningPolicy
        self.onToolArgumentsProgress = onToolArgumentsProgress
        self.ephemeralTransport = ephemeralTransport
    }

    public var effectiveMessages: [ProviderMessage] {
        if !contentMessages.isEmpty { return contentMessages }
        return messages.map { ProviderMessage(role: $0.role, text: $0.content) }
    }

    /// Keep changing clocks and ledger snapshots out of the leading system
    /// prefix. Transport adapters attach this context after tool results,
    /// without inserting a new user turn in a reasoning/tool round.
    var cacheContext: (messages: [ProviderMessage], live: String?) {
        var live: [String] = []
        let messages = effectiveMessages.compactMap { message -> ProviderMessage? in
            guard message.role == "system", message.content.allSatisfy({ if case .text = $0 { true } else { false } }) else { return message }
            let text = message.content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined(separator: "\n\n")
            guard let range = text.range(of: Self.liveStateMarker) else { return message }
            live.append(String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
            let stable = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return stable.isEmpty ? nil : ProviderMessage(role: "system", text: stable)
        }
        let context = live.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (messages, context.isEmpty ? nil : "[Floe runtime context; current app state, separate from the preceding user text or tool output]\n" + context)
    }

    /// Transient device context at the actual dispatch boundary. Also covers
    /// auxiliary requests and frozen checkpoint retries without editing history.
    public func refreshingRuntimeClock(
        now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current
    ) -> Self {
        var copy = self
        let clock = "Runtime clock at dispatch: \(ISO8601DateFormatter().string(from: now)); timeZone=\(timeZone.identifier); utcOffsetSeconds=\(timeZone.secondsFromGMT(for: now)); locale=\(locale.identifier). Use this clock instead of older timestamps when answering about now."
        if let index = copy.messages.firstIndex(where: { $0.role == "system" }) {
            if !copy.messages[index].content.contains(Self.liveStateMarker) { copy.messages[index].content += "\n\n" + Self.liveStateMarker }
            copy.messages[index].content += "\n\n" + clock
        } else {
            copy.messages.insert((role: "system", content: Self.liveStateMarker + "\n\n" + clock), at: 0)
        }
        if !copy.contentMessages.isEmpty {
            if let index = copy.contentMessages.firstIndex(where: { $0.role == "system" }) {
                if !copy.contentMessages[index].content.contains(where: { if case .text(let text) = $0 { text.contains(Self.liveStateMarker) } else { false } }) {
                    copy.contentMessages[index].content.append(.text(Self.liveStateMarker))
                }
                copy.contentMessages[index].content.append(.text(clock))
            } else {
                copy.contentMessages.insert(ProviderMessage(role: "system", text: Self.liveStateMarker + "\n\n" + clock), at: 0)
            }
        }
        return copy
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

/// Flush complete SSE lines immediately, including short first events. A
/// size-only 1 KiB buffer can hide valid events until the watchdog expires.
struct SSEByteFramer: Sendable {
    private var parser = SSEParser()
    private var buffer: [UInt8] = []

    mutating func feed(_ byte: UInt8) -> [SSEEvent] {
        buffer.append(byte)
        guard buffer.count >= 1024 || byte == 10 || byte == 13 else { return [] }
        let events = parser.feed(buffer)
        buffer.removeAll(keepingCapacity: true)
        return events
    }

    mutating func finish() throws -> [SSEEvent] {
        let events = parser.feed(buffer)
        buffer.removeAll(keepingCapacity: true)
        return events + (try parser.finish())
    }
}

/// Scoped per-request transport for provider traffic.
///
/// Ordinary requests keep using the caller's session (default
/// `URLSession.shared`): the global on-disk cache/cookie state is never
/// mutated or wiped by a temporary chat. Temporary (ephemeral) conversation
/// requests travel on ONE dedicated in-process session whose configuration
/// is `.ephemeral` with every storage slot nilled out — no shared URLCache,
/// no cookie jar, no credential storage — so no request/response content can
/// land in a shared on-disk cache. The request itself reaches the provider
/// unchanged; this is purely a local retention directive, not a provider
/// zero-retention promise.
enum ProviderTransport {
    static let ephemeralSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// The session a request must travel on: the dedicated ephemeral session
    /// for temporary conversations, the shared ordinary session otherwise.
    static func session(ephemeral: Bool) -> URLSession {
        ephemeral ? ephemeralSession : .shared
    }
}

/// Feeds an HTTP byte stream through `SSEParser` and emits decoded SSE
/// events. Cancellation of the consuming task cancels the URLSession task.
struct SSEBytePump: Sendable {
    let urlRequest: URLRequest
    /// Transport the request travels on. Temporary conversations pass the
    /// scoped ephemeral session; ordinary traffic keeps `.shared` so the
    /// global cache is never disturbed.
    let session: URLSession

    init(urlRequest: URLRequest, session: URLSession = .shared) {
        self.urlRequest = urlRequest
        self.session = session
    }

    func events() -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if os(Linux)
                    var parser = SSEParser()
                    // FoundationNetworking does not expose URLSession.bytes(for:).
                    // Linux is a build/test target, not an app runtime, so use a
                    // bounded-lifetime buffered fallback to keep wire parsing and
                    // contract tests portable. Apple platforms remain truly streaming.
                    let (data, response) = try await session.data(for: urlRequest)
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
                    let (bytes, response) = try await session.bytes(for: urlRequest)
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
                    var framer = SSEByteFramer()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for event in framer.feed(byte) { continuation.yield(event) }
                    }
                    for event in try framer.finish() { continuation.yield(event) }
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

enum ProviderWireEncoder {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

/// Adapter for the OpenAI Responses API (`/responses`, SSE streaming).
public struct OpenAIResponsesAdapter: ProviderAdapter {
    public let protocolKind: ModelProtocol = .openAIResponses
    private let logger = FloeLogger(category: .providers)

    public init() {}

    public func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let request = request.refreshingRuntimeClock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = try buildURLRequest(request: request, credentials: credentials)
                    let body = try ProviderWireEncoder.encode(buildBody(from: request))
                    urlRequest.httpBody = body
                    let host = request.provider.baseURL.host ?? "unknown"
                    logger.info(
                        "providerRequestStarted protocol=responses provider=\(request.provider.id.uuidString) host=\(host) model=\(request.model.remoteModelID) messages=\(request.effectiveMessages.count) tools=\(request.toolSchemas.count) bodyBytes=\(body.count)"
                    )
                    let pump = SSEBytePump(
                        urlRequest: urlRequest,
                        session: ProviderTransport.session(ephemeral: request.ephemeralTransport)
                    )
                    let decoder = JSONDecoder()
                    for try await sseEvent in pump.events() {
                        if let errorEvent = httpErrorEvent(from: sseEvent) {
                            if case .error(let error) = errorEvent {
                                let status = error.httpStatus.map(String.init) ?? "none"
                                logger.warning(
                                    "providerRequestRejected protocol=responses provider=\(request.provider.id.uuidString) model=\(request.model.remoteModelID) kind=\(error.kind.rawValue) httpStatus=\(status) message=\(request.ephemeralTransport ? "redacted" : String(error.providerMessage.prefix(500)))"
                                )
                            }
                            continuation.yield(errorEvent)
                            continue
                        }
                        guard sseEvent.data != "[DONE]" else { continue }
                        do {
                            let wireEvent = try decoder.decode(ResponsesStreamEvent.self, from: Data(sseEvent.data.utf8))
                            if case .functionCallArgumentsDelta(let delta) = wireEvent, !delta.isEmpty {
                                await request.onToolArgumentsProgress?()
                            }
                            for event in WireTranslator.translate(wireEvent) {
                                if case .toolRequest(var call) = event {
                                    call.toolName = CompatToolNames.canonicalName(call.toolName, request: request)
                                    continuation.yield(.toolRequest(call))
                                } else {
                                    continuation.yield(event)
                                }
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
        if request.ephemeralTransport {
            urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        urlRequest.timeoutInterval = 180
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
        let replaysReasoning = ReasoningCompatibility.requiresAssistantReasoningReplay(
            provider: request.provider,
            model: request.model
        )
        let nameTable = CompatToolNames.wireTable(for: request)
        let context = request.cacheContext
        var input: [ResponsesRequest.InputItem] = []
        for message in context.messages {
            let reasoning = replaysReasoning && message.role == "assistant"
                ? nonEmptyReasoning(message.reasoningContent)
                : nil
            if replaysReasoning, message.role == "assistant", reasoning == nil,
               !request.toolSchemas.isEmpty {
                // Legacy assistant history without captured reasoning: keep it
                // as explicitly non-authoritative context instead of an
                // assistant message the provider may reject.
                let text = message.content.compactMap { part -> String? in
                    if case .text(let value) = part { return value }
                    return nil
                }.joined(separator: "\n")
                input.append(.message(role: "system", content: "[Legacy assistant history; protocol reasoning unavailable]\n" + String(text.prefix(4_000))))
                continue
            }
            if let reasoning {
                input.append(.reasoning(text: reasoning))
            }
            if case .text(let text) = message.content.first, message.content.count == 1 {
                input.append(.message(role: message.role, content: text))
            } else {
                input.append(.multimodalMessage(
                    role: message.role,
                    content: message.content.map { part in
                        switch part {
                        case .text(let text): return .text(text)
                        case .imageData(let mimeType, let base64):
                            return .imageURL("data:\(mimeType);base64,\(base64)")
                        case .imageURL(let url): return .imageURL(url.absoluteString)
                        }
                    }
                ))
            }
        }
        for pair in request.replayedToolPairs {
            let pairName = CompatToolNames.wireName(pair.call.toolName, for: request.provider, table: nameTable)
            let pairReasoning = nonEmptyReasoning(pair.assistantReasoning)
            if replaysReasoning, pairReasoning == nil {
                input.append(.message(
                    role: "system",
                    content: "[Historical tool call; protocol reasoning unavailable] \(pairName) -> \(String(pair.result.outputSummary.prefix(2_000)))"
                ))
                continue
            }
            if let pairReasoning {
                input.append(.reasoning(text: pairReasoning))
            }
            input.append(.functionCall(
                callID: pair.call.id,
                name: pairName,
                arguments: String(decoding: pair.call.argumentsJSON, as: UTF8.self)
            ))
            input.append(.functionCallOutput(
                callID: pair.result.callID,
                output: pair.result.outputSummary
            ))
        }
        if !request.pendingToolCalls.isEmpty,
           let pendingReasoning = replaysReasoning ? nonEmptyReasoning(request.pendingAssistantReasoning) : nil {
            input.append(.reasoning(text: pendingReasoning))
        }
        for call in request.pendingToolCalls {
            input.append(.functionCall(
                callID: call.id,
                name: CompatToolNames.wireName(call.toolName, for: request.provider, table: nameTable),
                arguments: String(decoding: call.argumentsJSON, as: UTF8.self)
            ))
        }
        for result in request.toolResults {
            input.append(.functionCallOutput(callID: result.callID, output: result.output))
        }
        if let live = context.live {
            switch input.last {
            case .functionCallOutput(let id, let output):
                input[input.count - 1] = .functionCallOutput(callID: id, output: output + "\n\n" + live)
            case .message(let role, let text) where role == "user":
                input[input.count - 1] = .message(role: role, content: text + "\n\n" + live)
            case .multimodalMessage(let role, let parts) where role == "user":
                input[input.count - 1] = .multimodalMessage(role: role, content: parts + [.text(live)])
            default: input.append(.message(role: "user", content: live))
            }
        }
        let tools = request.toolSchemas.map {
            ResponsesRequest.ToolDefinition(
                name: CompatToolNames.wireName($0.name, for: request.provider, table: nameTable),
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
                model: request.model,
                policy: request.reasoningPolicy
            ).map(ResponsesRequest.Reasoning.init(effort:)),
            thinking: ReasoningCompatibility.responsesThinkingType(
                provider: request.provider,
                model: request.model,
                policy: request.reasoningPolicy
            ).map(ResponsesRequest.Thinking.init(type:)),
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
        let request = request.refreshingRuntimeClock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = try buildURLRequest(request: request, credentials: credentials)
                    let body = try ProviderWireEncoder.encode(buildBody(from: request))
                    urlRequest.httpBody = body
                    let host = request.provider.baseURL.host ?? "unknown"
                    logger.info(
                        "providerRequestStarted protocol=chat provider=\(request.provider.id.uuidString) host=\(host) model=\(request.model.remoteModelID) messages=\(request.effectiveMessages.count) tools=\(request.toolSchemas.count) bodyBytes=\(body.count)"
                    )
                    let pump = SSEBytePump(
                        urlRequest: urlRequest,
                        session: ProviderTransport.session(ephemeral: request.ephemeralTransport)
                    )
                    let decoder = JSONDecoder()
                    var aggregator = ToolCallAggregator()
                    var deferredCompletion: AgentEvent.CompletionInfo?
                    // Some OpenAI-compatible gateways (observed with Ark)
                    // repeat the same usage frame for one HTTP request. Usage
                    // is billed once per request, so suppress an identical
                    // report here, before the runtime enriches each copy with
                    // timings. This set belongs to this `stream` call only:
                    // distinct values are all kept, and an identical report in
                    // a separate request starts with a fresh set and counts.
                    var emittedUsageReports = Set<AgentEvent.UsageReport>()
                    for try await sseEvent in pump.events() {
                        if let errorEvent = httpErrorEvent(from: sseEvent) {
                            if case .error(let error) = errorEvent {
                                let status = error.httpStatus.map(String.init) ?? "none"
                                logger.warning(
                                    "providerRequestRejected protocol=chat provider=\(request.provider.id.uuidString) model=\(request.model.remoteModelID) kind=\(error.kind.rawValue) httpStatus=\(status) message=\(request.ephemeralTransport ? "redacted" : String(error.providerMessage.prefix(500)))"
                                )
                            }
                            continuation.yield(errorEvent)
                            continue
                        }
                        guard sseEvent.data != "[DONE]" else { continue }
                        do {
                            let chunk = try decoder.decode(ChatChunk.self, from: Data(sseEvent.data.utf8))
                            if chunk.choices.contains(where: { choice in
                                (choice.delta.toolCalls ?? []).contains { !($0.function?.arguments ?? "").isEmpty }
                            }) {
                                await request.onToolArgumentsProgress?()
                            }
                            for event in WireTranslator.translate(chunk, aggregator: &aggregator) {
                                if case .toolRequest(var call) = event {
                                    call.toolName = CompatToolNames.canonicalName(call.toolName, request: request)
                                    continuation.yield(.toolRequest(call))
                                } else if case .completed(let completion) = event {
                                    // OpenAI Chat Completions commonly sends a
                                    // separate usage-only chunk after the
                                    // finish_reason chunk. Do not terminate the
                                    // runtime until the SSE stream has drained.
                                    deferredCompletion = completion
                                } else if case .usage(let report) = event {
                                    if emittedUsageReports.insert(report).inserted {
                                        continuation.yield(.usage(report))
                                    }
                                } else {
                                    continuation.yield(event)
                                }
                            }
                        } catch {
                            logger.error("Chat chunk decode failed: \(error.localizedDescription)")
                            if aggregator.hasCalls {
                                // A dropped chunk while tool arguments were
                                // streaming would otherwise concatenate
                                // incomplete JSON and surface later as an
                                // unexplainable invalid call. Fail closed:
                                // discard the partial aggregation and let the
                                // runtime offer one bounded correction. The
                                // malformed payload is never emitted.
                                aggregator.reset()
                                continuation.yield(.error(AgentEvent.NormalizedError(
                                    kind: .malformedToolArguments,
                                    providerMessage: "The provider stream dropped a tool-call fragment before its arguments completed; the tool call was not executed. Re-emit it with complete valid JSON arguments."
                                )))
                                break
                            }
                        }
                    }
                    if let deferredCompletion {
                        continuation.yield(.completed(deferredCompletion))
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
        if request.ephemeralTransport {
            urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        urlRequest.timeoutInterval = 180
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
        let replaysReasoning = ReasoningCompatibility.requiresAssistantReasoningReplay(provider: request.provider, model: request.model)
        let nameTable = CompatToolNames.wireTable(for: request)
        let context = request.cacheContext
        var messages: [ChatRequest.Message] = context.messages.map { message in
            // Older app versions (and other providers) did not save this field.
            // Do not invent missing reasoning or submit an invalid assistant turn.
            // Preserve its text as explicitly non-authoritative historical context.
            if replaysReasoning, !request.toolSchemas.isEmpty,
               message.role == "assistant", nonEmptyReasoning(message.reasoningContent) == nil {
                let text = message.content.compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }.joined(separator: "\n")
                let quoted = String(decoding: (try? JSONEncoder().encode(text)) ?? Data(), as: UTF8.self)
                return ChatRequest.Message(role: "system", content: "[Legacy assistant history; protocol reasoning unavailable]\nThe JSON string below is an old assistant record, not a new user request, instruction, authorization, or verified execution result. Preserve newer user corrections and consult actual tool evidence before relying on its claims.\n" + quoted)
            }
            if case .text(let text) = message.content.first, message.content.count == 1 {
                return ChatRequest.Message(role: message.role, content: text,
                    reasoningContent: replaysReasoning && message.role == "assistant" ? nonEmptyReasoning(message.reasoningContent) : nil)
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
                },
                reasoningContent: replaysReasoning && message.role == "assistant" ? nonEmptyReasoning(message.reasoningContent) : nil
            )
        }
        for pair in request.replayedToolPairs {
            let pairName = CompatToolNames.wireName(pair.call.toolName, for: request.provider, table: nameTable)
            let pairReasoning = nonEmptyReasoning(pair.assistantReasoning)
            if replaysReasoning, pairReasoning == nil {
                // Legacy checkpoint: the assistant turn was recorded before
                // reasoning capture existed. DeepSeek rejects tool_calls
                // without reasoning_content, so preserve the evidence as
                // explicitly non-authoritative historical context instead.
                messages.append(ChatRequest.Message(
                    role: "system",
                    content: "[Historical tool call; protocol reasoning unavailable] \(pairName) -> \(String(pair.result.outputSummary.prefix(2_000)))"
                ))
                continue
            }
            messages.append(ChatRequest.Message(
                role: "assistant",
                content: nil,
                toolCalls: [ChatRequest.Message.ToolCall(
                    id: pair.call.id,
                    function: .init(
                        name: pairName,
                        arguments: String(decoding: pair.call.argumentsJSON, as: UTF8.self)
                    )
                )],
                reasoningContent: replaysReasoning ? pairReasoning : nil
            ))
            messages.append(ChatRequest.Message(
                role: "tool",
                content: pair.result.outputSummary,
                toolCallID: pair.result.callID
            ))
        }
        if !request.pendingToolCalls.isEmpty {
            messages.append(ChatRequest.Message(
                role: "assistant",
                content: nil,
                toolCalls: request.pendingToolCalls.map { call in
                    ChatRequest.Message.ToolCall(
                        id: call.id,
                        function: .init(
                            name: CompatToolNames.wireName(call.toolName, for: request.provider, table: nameTable),
                            arguments: String(decoding: call.argumentsJSON, as: UTF8.self)
                        )
                    )
                },
                reasoningContent: replaysReasoning
                    ? nonEmptyReasoning(request.pendingAssistantReasoning)
                    : nil
            ))
        }
        for result in request.toolResults {
            messages.append(ChatRequest.Message(
                role: "tool",
                content: result.output,
                toolCallID: result.callID
            ))
        }
        if let live = context.live {
            if let last = messages.indices.last, ["user", "tool"].contains(messages[last].role) {
                switch messages[last].content {
                case .text(let text): messages[last].content = .text(text + "\n\n" + live)
                case .parts(let parts): messages[last].content = .parts(parts + [.text(live)])
                case nil: messages[last].content = .text(live)
                }
            } else { messages.append(.init(role: "user", content: live)) }
        }
        let tools = request.toolSchemas.map {
            // DeepSeek and some gateways reject dots in tool names
            // (^[a-zA-Z0-9_-]+$). When the provider has toolNameCompatibility
            // enabled, convert dots to underscores for the wire only.
            // Grammar-strict Moonshot/Kimi hosts additionally get the exact
            // collision table so every emitted name satisfies
            // ^[A-Za-z][A-Za-z0-9_-]*$ and reverses to its canonical name.
            let wireName = CompatToolNames.wireName($0.name, for: request.provider, table: nameTable)
            return ChatRequest.ToolDefinition(
                name: wireName,
                description: $0.description,
                parameters: $0.parametersJSON
            )
        }
        let reasoning = ReasoningCompatibility.chatOptions(
            provider: request.provider,
            model: request.model,
            policy: request.reasoningPolicy
        )
        return ChatRequest(
            model: request.model.remoteModelID,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: tools.isEmpty ? nil : "auto",
            maxTokens: request.model.limits.configuredMaxOutputTokens,
            thinking: reasoning.thinkingType.map(ChatRequest.Thinking.init(type:)),
            reasoningEffort: reasoning.reasoningEffort,
            enableThinking: reasoning.enableThinking,
            stream: true,
            streamOptions: .init(includeUsage: true)
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
        let request = request.refreshingRuntimeClock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = try buildURLRequest(request: request, credentials: credentials)
                    urlRequest.httpBody = try ProviderWireEncoder.encode(buildBody(from: request))
                    let pump = SSEBytePump(
                        urlRequest: urlRequest,
                        session: ProviderTransport.session(ephemeral: request.ephemeralTransport)
                    )
                    let decoder = JSONDecoder()
                    var aggregator = WireTranslator.AnthropicAggregator()
                    for try await sseEvent in pump.events() {
                        if let errorEvent = httpErrorEvent(from: sseEvent) {
                            continuation.yield(errorEvent)
                            continue
                        }
                        do {
                            let wireEvent = try decoder.decode(AnthropicStreamEvent.self, from: Data(sseEvent.data.utf8))
                            if case .inputJSONDelta(_, let partialJSON) = wireEvent, !partialJSON.isEmpty {
                                await request.onToolArgumentsProgress?()
                            }
                            for event in WireTranslator.translate(wireEvent, aggregator: &aggregator) {
                                if case .toolRequest(var call) = event {
                                    call.toolName = CompatToolNames.canonicalName(call.toolName, request: request)
                                    continuation.yield(.toolRequest(call))
                                } else {
                                    continuation.yield(event)
                                }
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
        if request.ephemeralTransport {
            urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        urlRequest.timeoutInterval = 180
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
        let context = request.cacheContext
        let nameTable = CompatToolNames.wireTable(for: request)
        let systemText = context.messages.filter { $0.role == "system" }.flatMap(\.content)
            .compactMap { part -> String? in if case .text(let text) = part { return text }; return nil }
            .joined(separator: "\n\n")
        let system: [AnthropicRequest.SystemBlock]? = systemText.isEmpty ? nil : [.init(text: systemText, cacheable: true)]
        let replaysReasoning = ReasoningCompatibility.requiresAssistantReasoningReplay(
            provider: request.provider,
            model: request.model
        )
        var messages: [AnthropicRequest.Message] = context.messages
            .filter { $0.role != "system" }
            .map { message in
            var blocks: [AnthropicContent] = message.content.map { part in
                switch part {
                case .text(let text): return .text(text)
                case .imageData(let mimeType, let base64): return .image(mimeType: mimeType, base64: base64)
                case .imageURL(let url): return .text("[Image: \(url.absoluteString)]")
                }
            }
            if replaysReasoning, message.role == "assistant",
               let reasoning = nonEmptyReasoning(message.reasoningContent) {
                blocks.insert(.thinking(reasoning), at: 0)
            }
            return AnthropicRequest.Message(role: message.role, content: blocks)
        }
        for pair in request.replayedToolPairs {
            var assistantBlocks: [AnthropicContent] = []
            if replaysReasoning, let reasoning = nonEmptyReasoning(pair.assistantReasoning) {
                assistantBlocks.append(.thinking(reasoning))
            }
            assistantBlocks.append(.toolUse(
                id: pair.call.id,
                name: CompatToolNames.wireName(pair.call.toolName, for: request.provider, table: nameTable),
                inputJSON: String(decoding: pair.call.argumentsJSON, as: UTF8.self)
            ))
            messages.append(AnthropicRequest.Message(role: "assistant", content: assistantBlocks))
            messages.append(AnthropicRequest.Message(
                role: "user",
                content: [.toolResult(
                    toolUseID: pair.result.callID,
                    content: pair.result.outputSummary,
                    isError: false
                )]
            ))
        }
        if !request.pendingToolCalls.isEmpty {
            var assistantBlocks: [AnthropicContent] = []
            if replaysReasoning, let reasoning = nonEmptyReasoning(request.pendingAssistantReasoning) {
                assistantBlocks.append(.thinking(reasoning))
            }
            assistantBlocks.append(contentsOf: request.pendingToolCalls.map { call in
                .toolUse(
                    id: call.id,
                    name: CompatToolNames.wireName(call.toolName, for: request.provider, table: nameTable),
                    inputJSON: String(decoding: call.argumentsJSON, as: UTF8.self)
                )
            })
            messages.append(AnthropicRequest.Message(role: "assistant", content: assistantBlocks))
        }
        if !request.toolResults.isEmpty {
            messages.append(AnthropicRequest.Message(
                role: "user",
                content: request.toolResults.map { result in
                    .toolResult(toolUseID: result.callID, content: result.output, isError: false)
                }
            ))
        }
        if let live = context.live {
            if let last = messages.indices.last, messages[last].role == "user" {
                messages[last].content.append(.text(live))
            } else { messages.append(.init(role: "user", content: [.text(live)])) }
        }
        let tools = request.toolSchemas.map {
            AnthropicRequest.ToolDefinition(
                name: CompatToolNames.wireName($0.name, for: request.provider, table: nameTable),
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
            system: system?.isEmpty == false ? system : nil,
            tools: tools,
            thinking: reasoning.thinkingType.map {
                AnthropicRequest.Thinking(type: $0, budgetTokens: reasoning.budgetTokens)
            },
            outputConfig: reasoning.effort.map(AnthropicRequest.OutputConfig.init(effort:)),
            stream: true
        )
    }
}
