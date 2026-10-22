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
    /// Provider model ID (e.g. `qwen-audio-3.0-tts-plus`, `gpt-4o-mini-tts`).
    public var modelID: String
    /// Provider voice/speaker ID. Custom (cloned/designed) IDs are supported
    /// verbatim; there is no cloning/training UI.
    public var voiceID: String
    /// One bounded segment already split on sentence boundaries.
    public var text: String
    /// Relative speech rate 0.5…2.0 mapped onto the provider's supported knob.
    /// Providers without a matching knob ignore it; nothing is approximated.
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

/// Persisted non-secret speech settings (UserDefaults JSON via
/// `TTSSettingsService`). Defaults mirror the pre-existing behavior: system
/// voice, no automatic reading, barge-in allowed.
public struct TTSSettingsSnapshot: Codable, Sendable, Hashable, Equatable {
    public var provider: TTSSpeakerProvider
    public var billingRoute: TTSBillingRoute
    /// Alibaba pay-as-you-go region; ignored elsewhere.
    public var alibabaRegion: String?
    public var modelID: String
    public var voiceID: String
    /// Relative speech rate for every route (0.5…2.0). The system path maps it
    /// onto AVSpeechUtteranceDefaultSpeechRate so the existing `rate` slider
    /// stays compatible.
    public var speechRateRatio: Double
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
        modelID: String = "",
        voiceID: String = "",
        speechRateRatio: Double = 1.0,
        autoReadEnabled: Bool = false,
        allowBargeIn: Bool = true,
        connectionProviderID: UUID? = nil,
        language: String? = nil
    ) {
        self.provider = provider
        self.billingRoute = billingRoute
        self.alibabaRegion = alibabaRegion
        self.modelID = modelID
        self.voiceID = voiceID
        self.speechRateRatio = speechRateRatio
        self.autoReadEnabled = autoReadEnabled
        self.allowBargeIn = allowBargeIn
        self.connectionProviderID = connectionProviderID
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (trimmedLanguage?.isEmpty == false) ? trimmedLanguage : nil
    }

    public static let systemDefault = TTSSettingsSnapshot()

    /// Persisted-storage schema version (kept in the JSON envelope).
    public static let schemaVersion = 1
}
