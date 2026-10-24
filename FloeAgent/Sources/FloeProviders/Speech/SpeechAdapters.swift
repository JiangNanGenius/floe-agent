// FloeProviders — Speech provider adapter protocol, router and voice catalog.
//
// SPDX-License-Identifier: MPL-2.0
//
// Adapters synthesize ONE bounded text segment per request and stream ordered
// PCM chunks INCREMENTALLY with demand-driven, lossless handoff: the response
// body is consumed chunk by chunk (byte-wise URLSession.AsyncBytes grouped on
// demand, or WebSocket frames) and pushed through a bounded awaiting channel
// — nothing is buffered whole and nothing is dropped (see SpeechChannel).
// A failed auth/quota never switches provider or billing route: the redacted
// error surfaces and falling back to the system voice is a MANUAL user
// action. Local routes never leave the device: `.apple` uses AVFoundation,
// `.onDevice` uses the host-injected local provider, and onDevice WITHOUT an
// injected provider fails closed with an actionable configuration error —
// never a silent substitution of any other provider or route.

import Foundation
import FloeCore
#if canImport(AVFoundation) && (os(iOS) || os(macOS))
import AVFoundation
#endif

/// One provider synthesis capability. `credential` is resolved by the caller
/// (settings service) from Keychain; adapters never read the Keychain.
public protocol TTSSpeechProviding: Sendable {
    /// Starts one incremental synthesis. Cancelling the consumer's iteration
    /// closes the channel, cancels the producer task and cancels the network
    /// task; already-sent chunks are what the consumer received (no replay).
    func synthesize(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream
}

// MARK: - Shared runner plumbing

/// Wraps a producer closure into a lossless stream; the producer AWAITS each
/// chunk handoff, so a slow consumer backpressures the socket instead of
/// silently dropping audio.
func ttssRunStream(
    provider: TTSSpeakerProvider,
    producer: @escaping @Sendable (TTSAudioChunkSender) async throws -> Void
) -> TTSAudioChunkStream {
    let (stream, sender) = TTSAudioChunkStream.make()
    let task = Task {
        do {
            try await producer(sender)
        } catch {
            sender.finish(throwing: TTSSpeechNormalize.normalize(error, provider: provider))
        }
    }
    sender.attach(task)
    return stream
}

/// Forwards a raw-PCM byte sequence as ordered aligned chunks (OpenAI and
/// ElevenLabs stream bare PCM over chunked HTTP).
func ttssForwardRawPCM(
    _ chunks: TTSSpeechByteChunks,
    request: TTSSynthesisRequest,
    sender: TTSAudioChunkSender
) async throws {
    var sequence = 0
    var received = 0
    for try await chunk in chunks {
        received += chunk.count
        if received > TTSSpeechLimits.maxSegmentAudioBytes {
            throw TTSSynthesisError.streamTruncated(provider: request.provider)
        }
        for piece in TTSSpeechPCMChunking.split(chunk) {
            try await sender.send(TTSAudioChunk(
                sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                sequence: sequence, pcm: piece,
                sampleRate: request.format.sampleRate))
            sequence += 1
        }
    }
    try await sender.send(TTSAudioChunk(
        sessionID: request.sessionID, segmentIndex: request.segmentIndex,
        sequence: sequence, pcm: Data(),
        sampleRate: request.format.sampleRate, isFinal: true))
    sender.finish()
}

// MARK: - Voice catalog

/// One selectable voice for a provider route. Cloud custom (cloned/designed)
/// IDs are supported verbatim; there is no cloning/training UI here.
public struct TTSSpeechVoice: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// Returned by a provider voice-list API (ElevenLabs).
        case listed
        /// Fixed built-in documented by the provider (OpenAI, Apple).
        case builtin
        /// Manual ID entry only (Volcengine speakers; Alibaba models with no
        /// built-in voices).
        case manual
    }

    public var id: String { voiceID }
    public var voiceID: String
    public var displayName: String
    public var kind: Kind

    public init(voiceID: String, displayName: String, kind: Kind) {
        self.voiceID = voiceID
        self.displayName = displayName
        self.kind = kind
    }
}

// MARK: - OpenAI Speech adapter
// Official guide: https://developers.openai.com/api/docs/guides/text-to-speech
// POST /v1/audio/speech; streaming = chunk transfer encoding; pcm = 24 kHz
// 16-bit signed little-endian mono raw samples. Built-in voices (guide list,
// 2026-10): alloy ash ballad coral echo fable nova onyx sage shimmer verse
// marin cedar. Custom voice IDs from the custom-voices flow are accepted
// verbatim. `speed` is the documented rate knob (0.25–4.0); pitch is not
// supported and is never approximated. Note tts-1 / tts-1-hd / gpt-4o-mini-tts
// are the current Speech-API models; the guide flags tts-1/tts-1-hd
// deprecated for 2027 — the default is therefore gpt-4o-mini-tts.
// The official endpoint stays the default. A profile may configure an
// OpenAI-compatible service base URL (resolved by TTSOpenAISpeechEndpoint);
// the endpoint is frozen per request, so settings edits never move an
// in-flight utterance.

public struct OpenAISpeechAdapter: TTSSpeechProviding {
    public static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    public static let builtInVoices: [TTSSpeechVoice] = [
        "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx",
        "sage", "shimmer", "verse", "marin", "cedar",
    ].map { TTSSpeechVoice(voiceID: $0, displayName: $0.capitalized, kind: .builtin) }

    public static let supportedModels: [String] = ["gpt-4o-mini-tts", "tts-1", "tts-1-hd"]
    public static let defaultModel = "gpt-4o-mini-tts"

    let session: URLSession

    public init(session: URLSession? = nil) {
        // Default TTS transport is the module-internal ephemeral session: no
        // shared URLCache/cookie/credential storage, so speech traffic never
        // writes provider responses to disk (temporary-chat privacy rule too).
        self.session = session ?? ProviderTransport.session(ephemeral: true)
    }

    /// Dedicated session for user-configured compatible endpoints. CFNetwork
    /// copies request headers (including `Authorization`) onto redirects, so
    /// the same rule as the video adapters applies: follow only an HTTPS
    /// redirect that stays on the configured origin, and stop on anything
    /// else (the 3xx then surfaces as a redacted HTTP failure) instead of
    /// handing the key to another host. Retention matches the ephemeral
    /// speech transport: no cache, cookies or URL credentials.
    private static let compatibleEndpointSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(
            configuration: configuration,
            delegate: SameHostHTTPSRedirectPolicy.shared,
            delegateQueue: nil)
    }()

    /// Speech endpoint for one request: the frozen per-answer override when a
    /// compatible base URL was configured, otherwise the official endpoint.
    /// Re-validates before any network access so a corrupted persisted value
    /// can never dispatch.
    public static func speechURL(for request: TTSSynthesisRequest) throws -> URL {
        try TTSOpenAISpeechEndpoint.speechURL(base: request.openAIBaseURL)
    }

    public static func makeBody(
        for request: TTSSynthesisRequest,
        instructions: String? = nil
    ) throws -> Data {
        var payload: [String: Any] = [
            "model": request.modelID,
            "input": request.text,
            "voice": request.voiceID,
            "response_format": "pcm",
        ]
        if request.speechRateRatio != 1.0 {
            payload["speed"] = min(4.0, max(0.25, request.speechRateRatio))
        }
        if let instructions, !instructions.isEmpty {
            payload["instructions"] = instructions
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    public static func makeHeaders(credential: String) -> [String: String] {
        var headers = TTSSpeechRequestHeaders(accept: "audio/L16")
        headers["Authorization"] = "Bearer \(credential)"
        return headers
    }

    public func synthesize(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream {
        ttssRunStream(provider: .openAI) { sender in
            guard request.validationProblem() == nil else {
                throw TTSSynthesisError.invalidConfiguration(
                    request.validationProblem() ?? "invalid request")
            }
            // Resolve and re-validate the frozen endpoint before the body or
            // the credential-bearing headers are built: nothing is sent for
            // an unusable address.
            let url = try Self.speechURL(for: request)
            let body = try OpenAISpeechAdapter.makeBody(for: request)
            let opened = try await TTSSpeechHTTP.post(
                url: url,
                headers: Self.makeHeaders(credential: credential),
                body: body,
                // A custom origin uses the redirect-guarded ephemeral
                // session; the official route keeps its existing transport.
                session: request.openAIBaseURL == nil ? session : Self.compatibleEndpointSession,
                provider: .openAI,
                route: .payAsYouGo   // OpenAI speech has no plan channel
            )
            try await ttssForwardRawPCM(opened.chunks, request: request, sender: sender)
        }
    }
}

/// Same-origin HTTPS redirect policy for user-configured TTS endpoints.
/// Follows only redirects that keep the scheme, host and port of the original
/// request and never carry URL user info; every other redirect is refused so
/// the `Authorization` header cannot be forwarded to a third party.
private final class SameHostHTTPSRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SameHostHTTPSRedirectPolicy()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let target = request.url,
              target.scheme?.lowercased() == "https",
              target.user == nil, target.password == nil,
              let originalHost = original.host?.lowercased(),
              let targetHost = target.host?.lowercased(),
              targetHost == originalHost,
              (target.port ?? 443) == (original.port ?? 443) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - ElevenLabs adapter
// Official reference: https://elevenlabs.io/docs/api-reference/text-to-speech/stream
// POST /v1/text-to-speech/{voice_id}/stream?output_format=pcm_24000 streams
// raw PCM over chunked transfer; auth header `xi-api-key`. Voice settings
// `speed` (0.7–1.5) is the documented rate knob; no pitch knob exists, so
// pitch is never approximated. Voices come from the documented GET /v2/voices
// (account + shared) API.

public struct ElevenLabsSpeechAdapter: TTSSpeechProviding {
    public static let apiBase = URL(string: "https://api.elevenlabs.io/v1")!
    public static let voicesBase = URL(string: "https://api.elevenlabs.io/v2")!
    public static let supportedModels: [String] = [
        "eleven_multilingual_v2", "eleven_flash_v2_5", "eleven_turbo_v2_5", "eleven_v3",
    ]
    public static let defaultModel = "eleven_multilingual_v2"

    let session: URLSession

    public init(session: URLSession? = nil) {
        // Default TTS transport is the module-internal ephemeral session: no
        // shared URLCache/cookie/credential storage, so speech traffic never
        // writes provider responses to disk (temporary-chat privacy rule too).
        self.session = session ?? ProviderTransport.session(ephemeral: true)
    }

    public static func streamURL(voiceID: String, sampleRate: Int = 24_000) throws -> URL {
        // Reject blank/whitespace-only voice IDs BEFORE percent-encoding
        // (encoding never empties them, so the encoded-empty guard alone
        // would build a garbage path for "   ").
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TTSSynthesisError.invalidConfiguration("voice ID is required")
        }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        guard let encoded, !encoded.isEmpty else {
            throw TTSSynthesisError.invalidConfiguration("voice ID is required")
        }
        var components = URLComponents(
            url: apiBase.appendingPathComponent("text-to-speech/\(encoded)/stream"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_\(sampleRate)")]
        return components.url!
    }

    public static func makeBody(for request: TTSSynthesisRequest) throws -> Data {
        var voiceSettings: [String: Any] = [:]
        if request.speechRateRatio != 1.0 {
            voiceSettings["speed"] = min(1.5, max(0.7, request.speechRateRatio))
        }
        var payload: [String: Any] = [
            "text": request.text,
            "model_id": request.modelID,
        ]
        if !voiceSettings.isEmpty { payload["voice_settings"] = voiceSettings }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    public static func makeHeaders(credential: String) -> [String: String] {
        var headers = TTSSpeechRequestHeaders(accept: "audio/L16")
        headers["xi-api-key"] = credential
        return headers
    }

    public func synthesize(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream {
        ttssRunStream(provider: .elevenLabs) { sender in
            guard request.validationProblem() == nil else {
                throw TTSSynthesisError.invalidConfiguration(
                    request.validationProblem() ?? "invalid request")
            }
            let url = try Self.streamURL(
                voiceID: request.voiceID, sampleRate: request.format.sampleRate)
            let opened = try await TTSSpeechHTTP.post(
                url: url,
                headers: Self.makeHeaders(credential: credential),
                body: try Self.makeBody(for: request),
                session: session,
                provider: .elevenLabs,
                route: .payAsYouGo   // ElevenLabs has no plan channel
            )
            try await ttssForwardRawPCM(opened.chunks, request: request, sender: sender)
        }
    }

    /// GET /v2/voices (official voices API) → catalog entries. The response is
    /// untrusted content: only voice_id/name strings are extracted, capped.
    public static func voicesRequest(credential: String) -> URLRequest {
        var request = URLRequest(url: voicesBase.appendingPathComponent("voices"), timeoutInterval: 30)
        request.httpMethod = "GET"
        for (name, value) in TTSSpeechRequestHeaders(accept: "application/json") {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(credential, forHTTPHeaderField: "xi-api-key")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    public static func parseVoices(_ data: Data) -> [TTSSpeechVoice] {
        guard let root = TTSSpeechJSON.dictionary(data),
              let voices = root["voices"] as? [[String: Any]] else { return [] }
        var result: [TTSSpeechVoice] = []
        for entry in voices.prefix(500) {
            guard let voiceID = TTSSpeechJSON.string(entry, "voice_id"), !voiceID.isEmpty else {
                continue
            }
            let name = TTSSpeechJSON.string(entry, "name") ?? voiceID
            result.append(TTSSpeechVoice(
                voiceID: String(voiceID.prefix(128)),
                displayName: String(name.prefix(128)),
                kind: .listed))
        }
        return result
    }
}

// MARK: - Fail-closed local provider sentinel

/// Returned by the router when the `.onDevice` provider is selected but no
/// local provider was injected. It never falls back to Apple or any cloud
/// route: synthesis throws an actionable `invalidConfiguration`. This keeps
/// `provider(for:)` non-optional (so existing callers stay valid) while
/// guaranteeing a configured-error rather than silent substitution.
struct TTSMissingLocalSpeechProvider: TTSSpeechProviding {
    func synthesize(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream {
        let (stream, sender) = TTSAudioChunkStream.make()
        sender.finish(throwing: TTSSynthesisError.invalidConfiguration(
            "on-device speech selected but no local provider is configured"))
        return stream
    }
}

// MARK: - Router

/// Routes validated synthesis requests to the adapter for the provider/route
/// binding. One instance is shared app-wide (Sendable, no per-session state).
public final class TTSSpeechService: Sendable {
    private let session: URLSession
    private let volcengine: VolcengineSpeechAdapter
    private let elevenLabs: ElevenLabsSpeechAdapter
    private let openAI: OpenAISpeechAdapter
    private let alibaba: AlibabaSpeechAdapter
    private let apple: AppleSystemSpeechAdapter
    /// Optional injected local provider for the `.onDevice` route (a local
    /// speech model, owned by the primary model store). `nil` = on-device
    /// requests fail closed with an actionable configuration error; the router
    /// never substitutes Apple or a cloud route.
    private let localProvider: (any TTSSpeechProviding)?

    /// Default transport is the module-internal EPHEMERAL session: no shared
    /// URLCache/cookie/credential storage, so speech traffic never writes
    /// provider responses to disk. A public default argument cannot reference
    /// the internal session symbol, so the parameter is an optional resolved
    /// inside the body (same pattern as the four adapters).
    public init(
        session: URLSession? = nil,
        localProvider: (any TTSSpeechProviding)? = nil
    ) {
        let resolved = session ?? ProviderTransport.session(ephemeral: true)
        self.session = resolved
        self.volcengine = VolcengineSpeechAdapter(session: resolved)
        self.elevenLabs = ElevenLabsSpeechAdapter(session: resolved)
        self.openAI = OpenAISpeechAdapter(session: resolved)
        self.alibaba = AlibabaSpeechAdapter(session: resolved)
        self.apple = AppleSystemSpeechAdapter()
        self.localProvider = localProvider
    }

    public func provider(for request: TTSSynthesisRequest) -> any TTSSpeechProviding {
        switch request.provider {
        case .apple: return apple
        case .onDevice: return localProvider ?? TTSMissingLocalSpeechProvider()
        case .volcengine: return volcengine
        case .elevenLabs: return elevenLabs
        case .openAI: return openAI
        case .alibaba: return alibaba
        }
    }

    /// Dispatch with pre-flight validation. Nothing is sent when validation
    /// fails; the caller's credential is only handed to the matching adapter.
    /// Local routes (`.apple`, `.onDevice`) never leave the device and the
    /// credential is passed through but unused; `.onDevice` without an
    /// injected local provider fails closed (see `provider(for:)`).
    public func synthesize(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream {
        if let problem = request.validationProblem() {
            let (stream, sender) = TTSAudioChunkStream.make()
            sender.finish(throwing: TTSSynthesisError.invalidConfiguration(problem))
            return stream
        }
        return provider(for: request).synthesize(request, credential: credential)
    }

    /// Voice catalog for the settings UI (manual IDs always allowed; listed
    /// voices require an explicit fetch with the user's key).
    public func builtinVoices(for provider: TTSSpeakerProvider) -> [TTSSpeechVoice] {
        builtinVoices(for: provider, modelID: nil)
    }

    /// Model-aware catalog. The Volcengine 2.0 speakers are bound to the
    /// seed-tts-2.0 resource, so they are offered only when the profile's
    /// model resolves to that family; the 1.0 model keeps manual IDs and is
    /// never shown a 2.0 speaker that would be rejected by the service.
    public func builtinVoices(
        for provider: TTSSpeakerProvider,
        modelID: String?
    ) -> [TTSSpeechVoice] {
        switch provider {
        case .apple: return Self.appleVoices()
        case .onDevice: return []
        case .openAI: return OpenAISpeechAdapter.builtInVoices
        case .volcengine:
            return VolcengineSpeechAdapter.catalogueVoices(forModel: modelID ?? "")
        case .elevenLabs, .alibaba: return []
        }
    }

    /// Apple voices are enumerated on device (AVFoundation present).
    public static func appleVoices() -> [TTSSpeechVoice] {
        #if canImport(AVFoundation) && (os(iOS) || os(macOS))
        return AVSpeechSynthesisVoice.speechVoices().map { voice in
            TTSSpeechVoice(voiceID: voice.identifier, displayName: voice.name, kind: .builtin)
        }
        #else
        return []
        #endif
    }

    /// Suggested models per provider (from official docs; the field remains
    /// editable so users can target newer IDs without an app update).
    public func suggestedModels(for provider: TTSSpeakerProvider) -> [String] {
        switch provider {
        case .apple: return []
        case .onDevice: return []   // local model IDs come from the host's model store
        case .openAI: return OpenAISpeechAdapter.supportedModels
        case .elevenLabs: return ElevenLabsSpeechAdapter.supportedModels
        case .volcengine: return ["doubao-seed-tts-2.0", "doubao-seed-tts-1.0"]
        case .alibaba: return ["qwen-audio-3.0-tts-plus", "cosyvoice-v3-flash"]
        }
    }

    /// Fetch the ElevenLabs voice list with a dedicated credential. Other
    /// providers have no voice-list API; the UI falls back to manual ID entry.
    public func fetchVoiceCatalog(
        provider: TTSSpeakerProvider,
        credential: String
    ) async throws -> [TTSSpeechVoice] {
        switch provider {
        case .elevenLabs:
            let request = ElevenLabsSpeechAdapter.voicesRequest(credential: credential)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw TTSSpeechHTTP.classifyHTTPStatus(
                    provider: .elevenLabs,
                    statusCode: http.statusCode,
                    logID: TTSSpeechHTTP.traceLogID(from: response),
                    route: .payAsYouGo)
            }
            return ElevenLabsSpeechAdapter.parseVoices(data)
        case .apple:
            return Self.appleVoices()
        case .onDevice:
            return []   // local voices/model IDs are the host model store's truth
        case .openAI:
            return OpenAISpeechAdapter.builtInVoices
        case .volcengine, .alibaba:
            return []
        }
    }
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
