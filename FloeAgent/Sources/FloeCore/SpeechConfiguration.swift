// FloeCore — Text-to-speech configuration value types.
//
// SPDX-License-Identifier: MPL-2.0
//
// Shared, Foundation-only value types for the speech/TTS feature lane:
// provider identity, explicit billing-route binding, synthesis requests and
// ordered PCM chunks. Services and network adapters live in FloeProviders
// (`Sources/FloeProviders/Speech`) and the app (`FloeApp/TTS`); this file is
// the single source of truth for the wire-independent vocabulary so the
// settings store, adapters, playback and tests can all speak one contract
// without circular dependencies. No secrets are represented here: credentials
// are referenced by Keychain service/account metadata only.

import Foundation

/// Speech-synthesis capability provider. `apple` is the built-in
/// AVSpeechSynthesizer path and the app default until the user explicitly
/// selects a cloud provider; the others are metered cloud services whose
/// keys are supplied per billing route (never inferred from an LLM provider).
public enum TTSSpeakerProvider: String, Codable, CaseIterable, Sendable, Hashable {
    case apple
    /// Explicit on-device model path (a local speech model injected into
    /// `TTSSpeechService` by the host app). NEVER uses a cloud credential or a
    /// billing route; `modelID`, `voiceID` and `language` are reused verbatim
    /// to select the local model/voice/language when present. Selecting this
    /// provider without an injected local provider is a hard configuration
    /// error — the router never silently falls back to `apple` or any cloud.
    case onDevice
    case volcengine
    case elevenLabs
    case openAI
    case alibaba

    /// Billing routes valid for this provider. Selection outside this set is a
    /// configuration error: the router never silently substitutes a route and
    /// a failure never switches route or provider on its own.
    public var supportedBillingRoutes: [TTSBillingRoute] {
        switch self {
        case .apple, .onDevice: return []
        case .volcengine: return [.agentPlan, .payAsYouGo]
        case .alibaba: return [.tokenPlan, .payAsYouGo]
        case .elevenLabs, .openAI: return [.payAsYouGo]
        }
    }

    /// Whether synthesis for this provider may leave the device at all.
    /// `.apple` and `.onDevice` are always local.
    public var requiresCloudCredential: Bool {
        switch self {
        case .apple, .onDevice: return false
        case .volcengine, .elevenLabs, .openAI, .alibaba: return true
        }
    }
}

/// Explicit billing channel. Volcengine Agent Plan and Alibaba Token Plan use
/// dedicated keys and dedicated endpoints that are fully isolated from the
/// providers' ordinary pay-as-you-go services (per each vendor's official
/// documentation); mixing a plan key with a pay-as-you-go URL (or vice versa)
/// is rejected before any request is sent.
public enum TTSBillingRoute: String, Codable, CaseIterable, Sendable, Hashable {
    /// Volcengine Ark Agent Plan voice models (`/api/v3/plan/...` + plan key).
    case agentPlan
    /// Alibaba Model Studio Token Plan (`sk-sp-` key + token-plan host).
    case tokenPlan
    /// Ordinary metered TTS service of the selected provider.
    case payAsYouGo

    public static func isValid(_ route: TTSBillingRoute, for provider: TTSSpeakerProvider) -> Bool {
        provider.supportedBillingRoutes.contains(route)
    }
}

/// Streaming audio container. The playback/AEC path consumes raw signed 16-bit
/// little-endian mono PCM only; compressed formats are deliberately not
/// accepted mid-stream (there is no partial MP3/Opus decoder), which keeps
/// decoding bounded to zero. Requests therefore always ask the provider for
/// PCM output.
public struct TTSAudioFormat: Codable, Sendable, Hashable {
    public enum Container: String, Codable, Sendable, Hashable {
        case pcm16le
    }

    public var container: Container
    /// Sample rate in Hz. Limited to values every cloud route documents for
    /// PCM streaming; 24_000 is the common denominator and the default.
    public var sampleRate: Int

    public static let pcm24k = TTSAudioFormat(container: .pcm16le, sampleRate: 24_000)

    public static let supportedSampleRates: [Int] = [8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

    public init(container: Container = .pcm16le, sampleRate: Int = 24_000) {
        self.container = container
        self.sampleRate = TTSAudioFormat.supportedSampleRates.contains(sampleRate)
            ? sampleRate
            : Self.pcm24k.sampleRate
    }
}

/// Optional OpenAI-compatible TTS API base address.
///
/// The official route stays the default: an absent (`nil`) value always
/// resolves to `https://api.openai.com/v1/audio/speech`, and persisted
/// settings written before this option existed keep decoding unchanged. A
/// configured value is the API base documented by the compatible service
/// (for example `https://api.openai-proxy.org/v1`); the speech path
/// (`/audio/speech`) is composed onto it exactly once.
///
/// The same rules are applied at save time and again before any dispatch, so
/// a corrupted persisted value can never reach the network:
/// * HTTPS only, an explicit host is required, and embedded user info, query
///   parameters and fragments are rejected. No plain-HTTP path or ATS bypass
///   is introduced, and no key can be smuggled into the URL.
/// * Reverse-proxy path prefixes are preserved. A base that already ends in
///   the speech path (a full endpoint URL) is used verbatim, and a repeated
///   trailing `/v1` is collapsed, so `/v1/v1` or
///   `/audio/speech/audio/speech` can never be produced.
public enum TTSOpenAISpeechEndpoint {
    public static let officialBaseURL = "https://api.openai.com/v1"
    public static let speechPath = "/audio/speech"
    /// User input bound: longer values are rejected, never truncated.
    public static let maxBaseURLCharacters = 2_048

    /// The official endpoint used when no override is configured.
    public static let officialSpeechURL = URL(string: officialBaseURL + speechPath)!

    /// Short, lane-internal English reason an address is unusable, or nil
    /// when the value is blank (official default) or valid. Never contains
    /// the offending value.
    public static func validationProblem(for raw: String) -> String? {
        guard let trimmed = trimmed(raw) else { return nil }
        if case .problem(let problem) = problemOrParse(trimmed) { return problem }
        return nil
    }

    /// Canonical stored form: `https` + lowercased host + explicit non-default
    /// port + the entered path without trailing slashes. Blank input returns
    /// nil (official default). Throws `invalidConfiguration` for unusable
    /// input so callers fail before writing a credential or a profile.
    public static func normalized(_ raw: String?) throws -> String? {
        guard let trimmed = trimmed(raw) else { return nil }
        switch problemOrParse(trimmed) {
        case .problem(let problem):
            throw TTSSynthesisError.invalidConfiguration(problem)
        case .parsed(let parsed):
            return parsed.canonicalBase
        }
    }

    /// Final speech endpoint for one request. nil/blank → the official URL;
    /// otherwise the validated compatible base + `/audio/speech`.
    public static func speechURL(base raw: String?) throws -> URL {
        guard try normalized(raw) != nil, let trimmed = trimmed(raw) else {
            return officialSpeechURL
        }
        switch problemOrParse(trimmed) {
        case .problem(let problem):
            throw TTSSynthesisError.invalidConfiguration(problem)
        case .parsed(let parsed):
            return try parsed.speechURL()
        }
    }

    /// True when the API origin (host + port, official default included)
    /// differs between two configured values. Path-only changes on the same
    /// origin are the same connection and may reuse the stored key; a host or
    /// port change must not silently reuse a key issued by another service.
    public static func originChanged(from old: String?, to new: String?) -> Bool {
        originKey(old) != originKey(new)
    }

    // MARK: - Parsing

    private struct Parsed {
        let host: String
        let port: Int?
        let percentEncodedPath: String

        var origin: String { "\(host):\(port ?? 443)" }

        var canonicalBase: String {
            var path = percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            var value = "https://" + host
            if let port { value += ":" + String(port) }
            return value + path
        }

        /// Speech path with the version/endpoint guards applied once.
        var composedSpeechPath: String {
            var path = percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            while path.hasSuffix("/v1/v1") { path.removeLast("/v1".count) }
            if path.hasSuffix(TTSOpenAISpeechEndpoint.speechPath) {
                return path
            }
            if path.isEmpty {
                path = "/v1"
            } else if !path.hasSuffix("/v1") {
                path += "/v1"
            }
            return path + TTSOpenAISpeechEndpoint.speechPath
        }

        func speechURL() throws -> URL {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.port = port
            components.percentEncodedPath = composedSpeechPath
            guard let url = components.url else {
                throw TTSSynthesisError.invalidConfiguration(
                    "endpoint is not a valid URL")
            }
            return url
        }
    }

    private static let officialOriginKey = "api.openai.com:443"

    private static func originKey(_ raw: String?) -> String {
        guard let trimmed = trimmed(raw) else { return officialOriginKey }
        switch problemOrParse(trimmed) {
        case .problem: return "invalid"
        case .parsed(let parsed): return parsed.origin
        }
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Parse outcome for one candidate address. Kept as a local enum instead
    /// of `Result` so the failure side can carry plain lane text.
    private enum ParseOutcome {
        case parsed(Parsed)
        case problem(String)
    }

    private static func problemOrParse(_ value: String) -> ParseOutcome {
        guard value.count <= maxBaseURLCharacters else {
            return .problem("endpoint is too long")
        }
        // A URL carries no whitespace; reject any interior whitespace or
        // control scalar instead of letting Foundation reinterpret it.
        if value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) {
            return .problem("endpoint must be a single URL without spaces")
        }
        guard let components = URLComponents(string: value) else {
            return .problem("endpoint is not a valid URL")
        }
        guard components.scheme?.lowercased() == "https" else {
            return .problem("endpoint must use https")
        }
        guard let host = components.host, !host.isEmpty,
              !host.hasPrefix(".") else {
            return .problem("endpoint must include a host name")
        }
        if components.user != nil || components.password != nil {
            return .problem(
                "endpoint credentials belong in the API key field, not in the URL")
        }
        if components.query != nil {
            return .problem("endpoint must not include query parameters")
        }
        if components.fragment != nil {
            return .problem("endpoint must not include a fragment")
        }
        if let port = components.port, !(1...65_535).contains(port) {
            return .problem("endpoint port is invalid")
        }
        return .parsed(Parsed(
            host: host.lowercased(),
            // Drop the explicit default HTTPS port so it cannot create a
            // false "different connection" result.
            port: components.port == 443 ? nil : components.port,
            percentEncodedPath: components.percentEncodedPath))
    }
}

/// One ordered synthesis request for one bounded text segment of an utterance.
/// `sessionID` is the cancellation/late-event fence: every chunk, completion
/// and error callback must carry the active sessionID or be dropped.
public struct TTSSynthesisRequest: Sendable, Hashable, Identifiable {
    public var id: UUID { sessionID }
    public var sessionID: UUID
    /// Position of this segment within the utterance queue (strictly ordered).
    public var segmentIndex: Int
    public var provider: TTSSpeakerProvider
    public var billingRoute: TTSBillingRoute
    /// Provider service region (Alibaba pay-as-you-go only). `nil` = the
    /// provider's documented default region.
    public var region: String?
    /// Optional OpenAI-compatible API base address (see
    /// `TTSOpenAISpeechEndpoint`). `nil` = official OpenAI endpoint. Frozen
    /// into a request when the answer's speech configuration is captured, so
    /// editing the setting never moves an in-flight utterance.
    public var openAIBaseURL: String?
    /// Provider model ID (e.g. `qwen-audio-3.0-tts-plus`, `gpt-4o-mini-tts`).
    public var modelID: String
    /// Provider voice/speaker ID. Custom (cloned/designed) IDs are supported
    /// verbatim; there is no cloning/training UI.
    public var voiceID: String
    /// One bounded segment already split on sentence boundaries.
    public var text: String
    /// Relative speech rate 0.5…2.0 mapped onto the provider's supported knob.
    /// Providers without a matching knob ignore it; nothing is approximated.
    /// This is the DIRECT-provider semantics. The app's configured settings
    /// source (`ConfiguredTTSSpeechSource`) deliberately sends 1.0 and carries
    /// the user rate/pitch on `TTSPlaybackControls` instead, so the shared
    /// output effect applies the user rate exactly once and never twice.
    public var speechRateRatio: Double
    public var format: TTSAudioFormat
    /// Optional BCP-47 language hint (nil = auto-detect / provider default).
    /// Consumed by the LOCAL paths (`.apple` voice selection, the injected
    /// `.onDevice` provider). Cloud adapters transmit it ONLY where their
    /// documented request body actually carries a language field; none of the
    /// four current cloud routes document a reliable one, so those requests
    /// deliberately omit it — invented fields would change provider behavior
    /// or cause rejects, so the hint stays informational for them.
    public var language: String?

    public init(
        sessionID: UUID = UUID(),
        segmentIndex: Int = 0,
        provider: TTSSpeakerProvider,
        billingRoute: TTSBillingRoute,
        region: String? = nil,
        openAIBaseURL: String? = nil,
        modelID: String,
        voiceID: String,
        text: String,
        speechRateRatio: Double = 1.0,
        format: TTSAudioFormat = .pcm24k,
        language: String? = nil
    ) {
        self.sessionID = sessionID
        self.segmentIndex = segmentIndex
        self.provider = provider
        self.billingRoute = billingRoute
        self.region = region
        let trimmedBaseURL = openAIBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openAIBaseURL = (trimmedBaseURL?.isEmpty == false) ? trimmedBaseURL : nil
        self.modelID = modelID
        self.voiceID = voiceID
        self.text = text
        self.speechRateRatio = min(2.0, max(0.5, speechRateRatio))
        self.format = format
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (trimmedLanguage?.isEmpty == false) ? trimmedLanguage : nil
    }

    /// Configuration validation performed before any network access. Returns
    /// nil when the request may be dispatched. The Apple system path is NOT a
    /// cloud route: it bypasses billing-route, model and voice requirements
    /// (empty voice = automatic language selection) while still requiring
    /// non-empty text and PCM output. The `.onDevice` local path behaves the
    /// same way: no billing route, no cloud model/voice requirement — only
    /// text and PCM output are enforced here; whether the local model/voice/
    /// language IDs resolve is the injected provider's own decision.
    public func validationProblem() -> String? {
        if format.container != .pcm16le {
            return "streaming synthesis requires PCM output"
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "request text is empty"
        }
        guard provider.requiresCloudCredential else { return nil }
        if !TTSBillingRoute.isValid(billingRoute, for: provider) {
            return "billing route \(billingRoute.rawValue) is not valid for provider \(provider.rawValue)"
        }
        if voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "voice ID is required"
        }
        if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "model ID is required"
        }
        // OpenAI-compatible base address: validated here so an unusable URL
        // fails before the request is dispatched (the adapter repeats the
        // same rule defensively before any network access).
        if provider == .openAI, let openAIBaseURL,
           let problem = TTSOpenAISpeechEndpoint.validationProblem(for: openAIBaseURL) {
            return problem
        }
        return nil
    }
}

/// One ordered decoded PCM audio chunk. Emitted incrementally as the provider
/// streams bytes; never re-emitted after cancellation and never produced by
/// buffering a complete response.
public struct TTSAudioChunk: Sendable, Hashable {
    public var sessionID: UUID
    public var segmentIndex: Int
    /// Monotonic within (sessionID, segmentIndex).
    public var sequence: Int
    /// s16le mono PCM at `sampleRate`.
    public var pcm: Data
    public var sampleRate: Int
    /// True on the last chunk of the segment (provider stream completed).
    /// Synthesis-end ONLY: it does NOT mean the audio finished playing. A
    /// consumer that plays audio (SpeechService's internal player, the
    /// continuous-voice AEC engine) must report its own drained/played receipt
    /// before treating the utterance as spoken.
    public var isFinal: Bool

    public init(
        sessionID: UUID,
        segmentIndex: Int,
        sequence: Int,
        pcm: Data,
        sampleRate: Int,
        isFinal: Bool = false
    ) {
        self.sessionID = sessionID
        self.segmentIndex = segmentIndex
        self.sequence = sequence
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.isFinal = isFinal
    }

    /// Total bytes of audio (s16le mono).
    public var byteCount: Int { pcm.count }
}

/// Fixed-category network failure. Provider or system error TEXT never leaves
/// the adapter: responses and `URLError.localizedDescription` may echo request
/// content or credentials, so only these categories are carried outward.
public enum TTSTransportFailure: String, Codable, Sendable, Hashable {
    case cannotResolveHost
    case cannotConnect
    case timedOut
    case tlsFailure
    case notReachable
    case cancelled
    case unknown
}

/// Redacted, actionable synthesis failures. No header values, keys, URL user
/// info, provider response bodies or provider/system error strings are ever
/// carried. `logID` is a provider-issued request trace ID, sanitized to a
/// short alphanumeric token (safe to show, useful for support).
public enum TTSSynthesisError: Error, Sendable, Hashable {
    /// No credential resolves for the explicit provider/route binding. Nothing
    /// was sent. The UI must offer the manual system-voice fallback.
    case credentialMissing(provider: TTSSpeakerProvider, route: TTSBillingRoute)
    /// Settings/selection combination that cannot be dispatched (e.g. invalid
    /// billing-route pairing, missing voice ID for a model with no built-ins).
    /// Carries only lane-authored reason text, never provider content.
    case invalidConfiguration(String)
    /// Provider rejected the key for the selected route. Route/provider stay
    /// unchanged; only a manual user action may switch.
    case authentication(provider: TTSSpeakerProvider, route: TTSBillingRoute, logID: String?)
    /// Provider quota / rate limit. Not retried automatically; a retry could
    /// duplicate audio and unexpected billing.
    case quotaOrRateLimited(provider: TTSSpeakerProvider, route: TTSBillingRoute, logID: String?)
    /// Network failure, category only (see `TTSTransportFailure`).
    case transport(provider: TTSSpeakerProvider, failure: TTSTransportFailure)
    /// HTTP failure with a documented status code (never a reason phrase or body).
    case httpStatus(provider: TTSSpeakerProvider, statusCode: Int, logID: String?)
    /// Provider signalled an error event: provider numeric code + sanitized
    /// trace ID only; the message text is deliberately not carried.
    case providerRejected(provider: TTSSpeakerProvider, code: Int?, logID: String?)
    /// Stream ended without the final event; already-played chunks are kept,
    /// missing audio is reported instead of replayed.
    case streamTruncated(provider: TTSSpeakerProvider)
    /// The active session was cancelled; chunks are fenced by sessionID.
    case cancelled

    /// Sanitizes a provider trace identifier to a short safe token, or nil.
    public static func sanitizedLogID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = String.UnicodeScalarView(
            raw.unicodeScalars.filter { allowed.contains($0) }
        )
        let value = String(filtered)
        guard !value.isEmpty, value.count <= 64 else { return nil }
        return value
    }
}

/// Normalized user playback controls applied once by the shared output DSP.
///
/// This is the single cross-stage voice for "how fast" and "how high" a
/// spoken answer sounds. Both the ordinary answer player and the continuous
/// voice output read the same immutable value from `TTSConfiguredStream` and
/// insert it into their final audio graph; provider requests carry no pitch
/// parameter and the configured source sends a neutral rate, so the effect is
/// never applied twice. Values are sanitized on construction: non-finite input
/// falls back to neutral and finite input is clamped to the supported range.
public struct TTSPlaybackControls: Sendable, Equatable, Hashable {
    /// Relative speech rate: 0.5 = half speed, 1.0 = normal, 2.0 = double.
    public static let rateRange: ClosedRange<Double> = 0.5...2.0
    /// Intonation offset in semitones: -6 = lowest, 0 = unchanged, 6 = highest.
    public static let pitchSemitoneRange: ClosedRange<Double> = -6.0...6.0
    /// Speed used when no user preference applies.
    public static let neutralRate = 1.0
    /// Pitch used when no user preference applies.
    public static let neutralPitch = 0.0

    public var speechRateRatio: Double
    public var speechPitchSemitones: Double

    public init(
        speechRateRatio: Double = TTSPlaybackControls.neutralRate,
        speechPitchSemitones: Double = TTSPlaybackControls.neutralPitch
    ) {
        self.speechRateRatio = TTSPlaybackControls.normalizedRate(speechRateRatio)
        self.speechPitchSemitones = TTSPlaybackControls.normalizedPitch(speechPitchSemitones)
    }

    /// Unchanged output: normal speed and no pitch offset.
    public static let neutral = TTSPlaybackControls()

    /// True when this value carries no user adjustment (both axes neutral).
    /// A neutral value still lets a consumer pass audio through untouched.
    public var isNeutral: Bool { self == TTSPlaybackControls.neutral }

    static func normalizedRate(_ value: Double) -> Double {
        guard value.isFinite else { return neutralRate }
        return min(rateRange.upperBound, max(rateRange.lowerBound, value))
    }

    static func normalizedPitch(_ value: Double) -> Double {
        guard value.isFinite else { return neutralPitch }
        return min(pitchSemitoneRange.upperBound, max(pitchSemitoneRange.lowerBound, value))
    }
}

/// Persisted non-secret speech settings (UserDefaults JSON via
/// `TTSSettingsService`). Defaults mirror the pre-existing behavior: system
/// voice, no automatic reading, barge-in allowed.
public struct TTSSettingsSnapshot: Codable, Sendable, Hashable, Equatable {
    public var provider: TTSSpeakerProvider
    public var billingRoute: TTSBillingRoute
    /// Alibaba pay-as-you-go region; ignored elsewhere.
    public var alibabaRegion: String?
    /// Optional OpenAI-compatible API base address (OpenAI route only,
    /// canonical form from `TTSOpenAISpeechEndpoint`). nil = official OpenAI
    /// endpoint; the key is absent from older persisted settings, which keeps
    /// decoding backward compatible. Other providers store nil so their
    /// behavior and stored shape stay unchanged.
    public var openAIBaseURL: String?
    public var modelID: String
    public var voiceID: String
    /// Relative speech rate for every route (0.5…2.0). The system path maps it
    /// onto AVSpeechUtteranceDefaultSpeechRate so the existing `rate` slider
    /// stays compatible.
    public var speechRateRatio: Double
    /// Intonation offset in semitones for every route (-6…6, 0 = unchanged).
    /// No provider documents a pitch parameter, so this value never reaches a
    /// provider request; the shared output DSP applies it. Settings written
    /// before the control existed decode to the neutral 0.
    public var speechPitchSemitones: Double
    /// Automatic reading of assistant answers (default OFF per settled spec).
    public var autoReadEnabled: Bool
    /// Continuous-voice barge-in: user speech may interrupt answer audio
    /// (default ON per settled spec).
    public var allowBargeIn: Bool
    /// Explicit reuse of an already-configured provider connection (its Keychain
    /// secret) instead of a dedicated TTS key. nil = dedicated TTS key only.
    /// Reuse is opt-in per provider kind and never a silent fallback.
    public var connectionProviderID: UUID?
    /// Optional language preference (BCP-47 string; nil = auto / provider
    /// default). Consumed by the local paths (`.apple` voice selection and the
    /// injected `.onDevice` provider); cloud routes keep current behavior
    /// because their documented bodies carry no reliable language field.
    /// Adding the optional key is Codable backward compatible: old persisted
    /// JSON without it decodes to nil.
    public var language: String?

    public init(
        provider: TTSSpeakerProvider = .apple,
        billingRoute: TTSBillingRoute = .payAsYouGo,
        alibabaRegion: String? = nil,
        openAIBaseURL: String? = nil,
        modelID: String = "",
        voiceID: String = "",
        speechRateRatio: Double = 1.0,
        speechPitchSemitones: Double = 0.0,
        autoReadEnabled: Bool = false,
        allowBargeIn: Bool = true,
        connectionProviderID: UUID? = nil,
        language: String? = nil
    ) {
        self.provider = provider
        self.billingRoute = billingRoute
        self.alibabaRegion = alibabaRegion
        let trimmedBaseURL = openAIBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openAIBaseURL = (trimmedBaseURL?.isEmpty == false) ? trimmedBaseURL : nil
        self.modelID = modelID
        self.voiceID = voiceID
        // One normalization for the persisted fields and the computed
        // `playbackControls`: a corrupted value can never reach a player.
        let controls = TTSPlaybackControls(
            speechRateRatio: speechRateRatio,
            speechPitchSemitones: speechPitchSemitones)
        self.speechRateRatio = controls.speechRateRatio
        self.speechPitchSemitones = controls.speechPitchSemitones
        self.autoReadEnabled = autoReadEnabled
        self.allowBargeIn = allowBargeIn
        self.connectionProviderID = connectionProviderID
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (trimmedLanguage?.isEmpty == false) ? trimmedLanguage : nil
    }

    /// Normalized value both output paths consume. Never stores a second copy:
    /// the persisted fields above remain the single source of truth.
    public var playbackControls: TTSPlaybackControls {
        TTSPlaybackControls(
            speechRateRatio: speechRateRatio,
            speechPitchSemitones: speechPitchSemitones)
    }

    /// Backward-compatible decoding for ONE new field: `speechPitchSemitones`
    /// did not exist before this control, so a stored snapshot without it is
    /// still a valid record and decodes to the neutral 0. Everything the
    /// previous synthesized decoder required stays required — a corrupt or
    /// incomplete stored identity (missing provider/route/model/voice/rate/
    /// flags) is rejected exactly as before instead of silently turning into
    /// the system route, and the settings service then keeps its documented
    /// fallback. Historically optional fields keep their `decodeIfPresent`
    /// treatment, and both control axes are re-sanitized on decode.
    /// Encoding stays synthesized (schema version 1 plus the new key).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: try container.decode(
                TTSSpeakerProvider.self, forKey: .provider),
            billingRoute: try container.decode(
                TTSBillingRoute.self, forKey: .billingRoute),
            alibabaRegion: try container.decodeIfPresent(
                String.self, forKey: .alibabaRegion),
            openAIBaseURL: try container.decodeIfPresent(
                String.self, forKey: .openAIBaseURL),
            modelID: try container.decode(
                String.self, forKey: .modelID),
            voiceID: try container.decode(
                String.self, forKey: .voiceID),
            speechRateRatio: try container.decode(
                Double.self, forKey: .speechRateRatio),
            speechPitchSemitones: try container.decodeIfPresent(
                Double.self, forKey: .speechPitchSemitones) ?? TTSPlaybackControls.neutralPitch,
            autoReadEnabled: try container.decode(
                Bool.self, forKey: .autoReadEnabled),
            allowBargeIn: try container.decode(
                Bool.self, forKey: .allowBargeIn),
            connectionProviderID: try container.decodeIfPresent(
                UUID.self, forKey: .connectionProviderID),
            language: try container.decodeIfPresent(String.self, forKey: .language))
    }

    private enum CodingKeys: String, CodingKey {
        case provider, billingRoute, alibabaRegion, openAIBaseURL, modelID, voiceID
        case speechRateRatio, speechPitchSemitones, autoReadEnabled, allowBargeIn
        case connectionProviderID, language
    }

    public static let systemDefault = TTSSettingsSnapshot()

    /// Persisted-storage schema version (kept in the JSON envelope).
    public static let schemaVersion = 1
}
