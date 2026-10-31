// FloeCore — Cloud ASR provider, profile, capability and live-session contract.
//
// SPDX-License-Identifier: MPL-2.0
//
// This file is the wire-independent vocabulary shared by the settings store,
// the OpenAI-compatible adapters and the vendor adapters (Volcengine /
// Alibaba). It deliberately contains:
//
//   * provider + explicit billing-route identity, with no availability gate:
//     a profile with supplied configuration is callable by default. There is
//     no membership, paid-account, entitlement or developer-test switch here,
//     and none may be added as a delivery gate;
//   * `ASRProfile`, which stores only Keychain *metadata* for a credential —
//     never a key, token or secret value;
//   * per-model capabilities, so optional wire parameters (languages array,
//     verbose timestamps, streaming) are only sent when the model supports
//     them;
//   * file/live request and event seams plus injectable HTTP/WebSocket
//     transports, so vendor adapters reuse the same contract and focused tests
//     can drive exact payloads without a live provider.
//
// Existing ASR types (`ASRTranscriptionRequest`, `ASRTranscriptionResult`,
// `ASRTranscriptionError`, `OpenAITranscriptionEndpoint`) stay in
// SpeechConfiguration.swift; only source-compatible defaults are added there.

import Foundation

// MARK: - Provider and billing identity

/// Cloud speech-recognition provider family. Every case is callable when the
/// user supplies the profile configuration; the app must not hide an entry
/// because the developer has no membership, credit or real-account test.
public enum ASRProviderKind: String, Codable, CaseIterable, Sendable, Hashable {
    /// OpenAI and OpenAI-compatible relays (native or reverse proxy).
    case openaiCompatible
    /// Volcengine Doubao large-model streaming ASR.
    case volcengine
    /// Alibaba Model Studio Qwen ASR (pay-as-you-go or Token Plan).
    case alibaba

    /// Billing routes that are valid for this provider. Selecting outside this
    /// set is a configuration error; a failure never switches route silently.
    public var supportedBillingRoutes: [ASRBillingRoute] {
        switch self {
        case .openaiCompatible: return [.payAsYouGo]
        case .volcengine: return [.payAsYouGo, .agentPlan]
        case .alibaba: return [.payAsYouGo, .tokenPlan]
        }
    }

    public func supports(_ route: ASRBillingRoute) -> Bool {
        supportedBillingRoutes.contains(route)
    }

    /// Display default used only when a caller creates a profile without a
    /// name. No user-facing copy is owned by this module.
    public var defaultProfileName: String {
        switch self {
        case .openaiCompatible: return "OpenAI"
        case .volcengine: return "Volcengine"
        case .alibaba: return "Alibaba"
        }
    }
}

/// Explicit ASR billing channel. The three values mirror `TTSBillingRoute` so
/// the settings layer can convert without guessing; they are kept as a
/// separate type because ASR routes, keys and endpoints are independent of
/// synthesis.
public enum ASRBillingRoute: String, Codable, CaseIterable, Sendable, Hashable {
    /// Ordinary metered service (OpenAI, DashScope pay-as-you-go, Volcengine
    /// regular `/auc` endpoints).
    case payAsYouGo
    /// Volcengine Ark Agent Plan (`/api/v3/plan/sauc/...` + plan key).
    case agentPlan
    /// Alibaba Model Studio Token Plan (`sk-sp-` key + token-plan host).
    case tokenPlan

    public init?(_ ttsRoute: TTSBillingRoute) {
        switch ttsRoute {
        case .payAsYouGo: self = .payAsYouGo
        case .agentPlan: self = .agentPlan
        case .tokenPlan: self = .tokenPlan
        }
    }

    public var ttsRoute: TTSBillingRoute {
        switch self {
        case .payAsYouGo: return .payAsYouGo
        case .agentPlan: return .agentPlan
        case .tokenPlan: return .tokenPlan
        }
    }
}

// MARK: - Provider routing defaults

/// Pure default endpoints/models for each provider and billing route. Vendor
/// adapters own auth/framing; these constants exist so they never have to
/// guess a host, cross a plan key into a pay-as-you-go endpoint, or hard-code
/// the model names in two places.
public enum ASRProviderRouting {
    public static let openAIFileBase = "https://api.openai.com/v1"
    public static let openAIRealtimeURL =
        "wss://api.openai.com/v1/realtime?intent=transcription"
    public static let openAIFileModel = "gpt-transcribe"
    public static let openAILiveModel = "gpt-live-transcribe"

    public static let volcengineModel = "bigmodel"
    public static let volcengineResourceID = "volc.seedasr.sauc.duration"
    public static let volcenginePayAsYouGoLiveURL =
        "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    public static let volcengineAgentPlanLiveURL =
        "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async"

    public static let alibabaPayAsYouGoFileURL =
        "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
    public static let alibabaTokenPlanFileURL =
        "https://token-plan.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
    public static let alibabaPayAsYouGoLiveURL =
        "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    public static let alibabaPayAsYouGoFileModel = "qwen-audio-3.1-asr-flash"
    public static let alibabaPayAsYouGoLiveModel =
        "qwen-audio-3.1-asr-flash-streaming"
    public static let alibabaTokenPlanFileModel = "qwen-audio-3.0-asr-flash"

    public static func defaultFileModel(
        provider: ASRProviderKind,
        route: ASRBillingRoute
    ) -> String {
        switch provider {
        case .openaiCompatible: return openAIFileModel
        case .volcengine: return volcengineModel
        case .alibaba:
            return route == .tokenPlan
                ? alibabaTokenPlanFileModel
                : alibabaPayAsYouGoFileModel
        }
    }

    public static func defaultLiveModel(
        provider: ASRProviderKind,
        route: ASRBillingRoute
    ) -> String? {
        switch provider {
        case .openaiCompatible: return openAILiveModel
        case .volcengine: return volcengineModel
        case .alibaba:
            return route == .tokenPlan ? nil : alibabaPayAsYouGoLiveModel
        }
    }

    public static func defaultFileEndpoint(
        provider: ASRProviderKind,
        route: ASRBillingRoute
    ) -> String? {
        guard provider.supports(route) else { return nil }
        switch provider {
        case .openaiCompatible:
            // nil means the official endpoint; the OpenAI endpoint helper
            // composes `/audio/transcriptions` exactly once.
            return nil
        case .volcengine:
            // Volcengine file input is a WebSocket replay of the streaming
            // endpoint, so the file and live hosts are identical.
            return defaultLiveEndpoint(provider: .volcengine, route: route)
        case .alibaba:
            return route == .tokenPlan
                ? alibabaTokenPlanFileURL
                : alibabaPayAsYouGoFileURL
        }
    }

    public static func defaultLiveEndpoint(
        provider: ASRProviderKind,
        route: ASRBillingRoute
    ) -> String? {
        guard provider.supports(route) else { return nil }
        switch provider {
        case .openaiCompatible:
            // nil means the official realtime URL with intent=transcription.
            return nil
        case .volcengine:
            return route == .agentPlan
                ? volcengineAgentPlanLiveURL
                : volcenginePayAsYouGoLiveURL
        case .alibaba:
            return route == .tokenPlan ? nil : alibabaPayAsYouGoLiveURL
        }
    }

    public static func defaultResourceID(
        provider: ASRProviderKind,
        route: ASRBillingRoute
    ) -> String? {
        guard provider.supports(route) else { return nil }
        return provider == .volcengine ? volcengineResourceID : nil
    }
}

// MARK: - Credential metadata

/// Keychain lookup metadata for one profile. This is not a secret: the value
/// is the service/account pair under which the user's key is stored. Adapters
/// receive the secret separately and must never persist, log or encode it.
public struct ASRCredentialReference: Codable, Sendable, Hashable {
    public var service: String
    public var account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

// MARK: - Profile

/// One persisted ASR configuration. Contains no secret value and no
/// availability/paid-account flag. `id` is stable across encoding, app
/// restarts and profile edits; the settings layer can use it as the Keychain
/// account discriminator and the per-profile preference key.
public struct ASRProfile: Codable, Sendable, Hashable, Identifiable {
    public static let maximumLanguages = 8
    public static let maximumKeywords = 32
    public static let maximumKeywordCharacters = 128
    public static let maximumPromptCharacters = 4_000

    public let id: UUID
    public var name: String
    public var provider: ASRProviderKind
    public var billingRoute: ASRBillingRoute
    public var fileModelID: String
    /// nil means this profile has no live route. Constructors for the shipped
    /// default profiles set both the current file and live models.
    public var liveModelID: String?
    /// nil means the provider/route default from `ASRProviderRouting`.
    public var fileEndpoint: String?
    /// nil means the provider/route default from `ASRProviderRouting`.
    public var liveEndpoint: String?
    /// Provider resource binding (for example the Volcengine
    /// `X-Api-Resource-Id` value). Never a credential.
    public var resourceID: String?
    public var credentialReference: ASRCredentialReference?
    public var languages: [String]
    public var prompt: String?
    public var keywords: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        provider: ASRProviderKind,
        billingRoute: ASRBillingRoute,
        fileModelID: String,
        liveModelID: String? = nil,
        fileEndpoint: String? = nil,
        liveEndpoint: String? = nil,
        resourceID: String? = nil,
        credentialReference: ASRCredentialReference? = nil,
        languages: [String] = [],
        prompt: String? = nil,
        keywords: [String] = []
    ) {
        self.id = id
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? provider.defaultProfileName : trimmedName
        self.provider = provider
        self.billingRoute = billingRoute
        self.fileModelID = fileModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.liveModelID = Self.normalizedOptional(liveModelID)
        self.fileEndpoint = Self.normalizedOptional(fileEndpoint)
        self.liveEndpoint = Self.normalizedOptional(liveEndpoint)
        self.resourceID = Self.normalizedOptional(resourceID)
        self.credentialReference = credentialReference
        self.languages = Self.normalizedLanguages(languages)
        self.prompt = Self.normalizedOptional(prompt)
            .map { String($0.prefix(Self.maximumPromptCharacters)) }
        self.keywords = Self.normalizedKeywords(keywords)
    }

    // MARK: Default profiles

    /// Latest OpenAI-compatible file + live models. `fileEndpoint` /
    /// `liveEndpoint` are optional relay overrides; nil keeps the official
    /// HTTPS/WSS routes.
    public static func openAICompatible(
        id: UUID = UUID(),
        name: String = "OpenAI",
        billingRoute: ASRBillingRoute = .payAsYouGo,
        fileModelID: String = ASRProviderRouting.openAIFileModel,
        liveModelID: String? = ASRProviderRouting.openAILiveModel,
        fileEndpoint: String? = nil,
        liveEndpoint: String? = nil,
        credentialReference: ASRCredentialReference? = nil,
        languages: [String] = [],
        prompt: String? = nil,
        keywords: [String] = []
    ) -> ASRProfile {
        ASRProfile(
            id: id,
            name: name,
            provider: .openaiCompatible,
            billingRoute: billingRoute,
            fileModelID: fileModelID,
            liveModelID: liveModelID,
            fileEndpoint: fileEndpoint,
            liveEndpoint: liveEndpoint,
            credentialReference: credentialReference,
            languages: languages,
            prompt: prompt,
            keywords: keywords)
    }

    public static func volcengine(
        id: UUID = UUID(),
        name: String = "Volcengine",
        billingRoute: ASRBillingRoute = .payAsYouGo,
        fileModelID: String = ASRProviderRouting.volcengineModel,
        liveModelID: String? = ASRProviderRouting.volcengineModel,
        fileEndpoint: String? = nil,
        liveEndpoint: String? = nil,
        resourceID: String? = ASRProviderRouting.volcengineResourceID,
        credentialReference: ASRCredentialReference? = nil,
        languages: [String] = [],
        prompt: String? = nil,
        keywords: [String] = []
    ) -> ASRProfile {
        ASRProfile(
            id: id,
            name: name,
            provider: .volcengine,
            billingRoute: billingRoute,
            fileModelID: fileModelID,
            liveModelID: liveModelID,
            fileEndpoint: fileEndpoint,
            liveEndpoint: liveEndpoint,
            resourceID: resourceID,
            credentialReference: credentialReference,
            languages: languages,
            prompt: prompt,
            keywords: keywords)
    }

    public static func alibaba(
        id: UUID = UUID(),
        name: String = "Alibaba",
        billingRoute: ASRBillingRoute = .payAsYouGo,
        fileModelID: String? = nil,
        liveModelID: String? = nil,
        fileEndpoint: String? = nil,
        liveEndpoint: String? = nil,
        credentialReference: ASRCredentialReference? = nil,
        languages: [String] = [],
        prompt: String? = nil,
        keywords: [String] = []
    ) -> ASRProfile {
        ASRProfile(
            id: id,
            name: name,
            provider: .alibaba,
            billingRoute: billingRoute,
            fileModelID: fileModelID ?? ASRProviderRouting.defaultFileModel(
                provider: .alibaba, route: billingRoute),
            liveModelID: liveModelID ?? ASRProviderRouting.defaultLiveModel(
                provider: .alibaba, route: billingRoute),
            fileEndpoint: fileEndpoint,
            liveEndpoint: liveEndpoint,
            credentialReference: credentialReference,
            languages: languages,
            prompt: prompt,
            keywords: keywords)
    }

    // MARK: Resolution

    public var resolvedFileEndpoint: String? {
        Self.normalizedOptional(fileEndpoint)
            ?? ASRProviderRouting.defaultFileEndpoint(provider: provider, route: billingRoute)
    }

    public var resolvedLiveEndpoint: String? {
        if let explicit = Self.normalizedOptional(liveEndpoint) { return explicit }
        // A relay key must stay on the configured relay when live is enabled.
        // Derive its realtime sibling rather than silently using OpenAI's host.
        if provider == .openaiCompatible,
           let file = Self.normalizedOptional(fileEndpoint) {
            guard var components = URLComponents(string: file) else { return file }
            while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
            let suffix = "/audio/transcriptions"
            if components.percentEncodedPath.hasSuffix(suffix) {
                components.percentEncodedPath.removeLast(suffix.count)
            }
            let base = components.string ?? file
            return (try? ASROpenAIRealtimeEndpoint.endpointURL(base: base))?.absoluteString ?? base
        }
        return ASRProviderRouting.defaultLiveEndpoint(provider: provider, route: billingRoute)
    }

    public var fileCapabilities: ASRModelCapabilities {
        ASRModelCapabilityCatalog.capabilities(for: provider, modelID: fileModelID)
    }

    public var liveCapabilities: ASRModelCapabilities? {
        guard let liveModelID = Self.normalizedOptional(liveModelID) else { return nil }
        return ASRModelCapabilityCatalog.capabilities(for: provider, modelID: liveModelID)
    }

    /// Short lane-authored reason this profile cannot be dispatched, or nil.
    /// Never contains a credential, endpoint user info or provider body.
    public func validationProblem() -> String? {
        guard provider.supports(billingRoute) else {
            return "billing route is not available for this provider"
        }
        guard Self.normalizedOptional(fileModelID) != nil else {
            return "file transcription model is required"
        }
        if let liveModelID = Self.normalizedOptional(liveModelID) {
            if liveModelID.isEmpty { return "live transcription model is empty" }
            let capabilities = ASRModelCapabilityCatalog.capabilities(
                for: provider, modelID: liveModelID)
            if !capabilities.supportsLiveTranscription {
                return "live transcription model is not supported"
            }
        }
        if provider == .openaiCompatible {
            // Use the exact adapter endpoint rules so a profile cannot pass
            // validation and then fail at dispatch (for example a query or a
            // plain-HTTP relay).
            if let fileEndpoint = Self.normalizedOptional(fileEndpoint),
               let problem = OpenAITranscriptionEndpoint.validationProblem(
                   for: fileEndpoint) {
                return problem
            }
            if let liveEndpoint = Self.normalizedOptional(liveEndpoint),
               let problem = ASROpenAIRealtimeEndpoint.validationProblem(
                   for: liveEndpoint) {
                return problem
            }
        } else {
            if let fileEndpoint = Self.normalizedOptional(fileEndpoint) {
                let problem = provider == .volcengine
                    ? ASREndpointRules.webSocketProblem(for: fileEndpoint)
                    : ASREndpointRules.httpsProblem(for: fileEndpoint)
                if let problem { return problem }
            }
            if let liveEndpoint = Self.normalizedOptional(liveEndpoint),
               let problem = ASREndpointRules.webSocketProblem(for: liveEndpoint) {
                return problem
            }
        }
        return nil
    }

    public func validated() throws -> ASRProfile {
        if let problem = validationProblem() {
            throw ASRTranscriptionError.invalidConfiguration(problem)
        }
        return self
    }

    // MARK: Normalization

    static func normalizedOptional(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func normalizedLanguages(_ raw: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for language in raw {
            let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
            if result.count == maximumLanguages { break }
        }
        return result
    }

    static func normalizedKeywords(_ raw: [String]) -> [String] {
        var result: [String] = []
        for keyword in raw {
            var value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            // The Realtime/file APIs reject the whole request when a keyword
            // contains these characters. Hints are optional, so an invalid
            // hint is dropped instead of failing the user's transcription.
            if value.contains("<") || value.contains(">")
                || value.contains("\r") || value.contains("\n") { continue }
            if value.count > maximumKeywordCharacters {
                value = String(value.prefix(maximumKeywordCharacters))
            }
            result.append(value)
            if result.count == maximumKeywords { break }
        }
        return result
    }
}

// MARK: - Timing provenance

/// What the adapter actually knows about timing. `.sourceSpanOnly` means the
/// caller supplied the whole-source duration; it is NOT speech alignment and
/// must never be used to fabricate caption segments.
public enum ASRTimingProvenance: String, Codable, Sendable, Hashable {
    case providerSegments
    case providerWords
    case sourceSpanOnly
    case none
}

// MARK: - Model capabilities

public enum ASRFileResponseFormat: String, Codable, Sendable, Hashable {
    /// Let the provider use its documented default (JSON for modern models).
    case automatic
    case json
    case verboseJSON = "verbose_json"
}

/// Which optional language parameter a model accepts. The adapter never sends
/// both forms: `gpt-transcribe` rejects the singular field, older models
/// reject the array.
public enum ASRLanguageParameter: String, Codable, Sendable, Hashable {
    case none
    case singular
    case array
}

/// Per-model capability contract. This is the only place that decides whether
/// an optional provider argument may be sent.
public struct ASRModelCapabilities: Codable, Sendable, Hashable {
    public static let openAIUploadLimit = 25 * 1024 * 1024

    public var supportsFileTranscription: Bool
    public var supportsLiveTranscription: Bool
    public var fileResponseFormat: ASRFileResponseFormat
    public var supportsFileStreaming: Bool
    public var languageParameter: ASRLanguageParameter
    public var supportsTimestampGranularities: Bool
    public var supportsPrompt: Bool
    public var supportsKeywords: Bool
    public var timing: ASRTimingProvenance
    public var maximumFileBytes: Int

    public init(
        supportsFileTranscription: Bool,
        supportsLiveTranscription: Bool,
        fileResponseFormat: ASRFileResponseFormat,
        supportsFileStreaming: Bool,
        languageParameter: ASRLanguageParameter,
        supportsTimestampGranularities: Bool,
        supportsPrompt: Bool,
        supportsKeywords: Bool,
        timing: ASRTimingProvenance,
        maximumFileBytes: Int
    ) {
        self.supportsFileTranscription = supportsFileTranscription
        self.supportsLiveTranscription = supportsLiveTranscription
        self.fileResponseFormat = fileResponseFormat
        self.supportsFileStreaming = supportsFileStreaming
        self.languageParameter = languageParameter
        self.supportsTimestampGranularities = supportsTimestampGranularities
        self.supportsPrompt = supportsPrompt
        self.supportsKeywords = supportsKeywords
        self.timing = timing
        self.maximumFileBytes = maximumFileBytes
    }
}

public enum ASRModelCapabilityCatalog {
    /// Conservative default for an unknown OpenAI-compatible model. It stays
    /// callable (configuration alone is enough; there is no availability
    /// gate), but the adapter sends the minimum wire body: no response_format,
    /// timestamp, streaming, prompt or keyword parameter, and only the singular
    /// `language` form. If the relay/model rejects the request, that is an
    /// ordinary provider error; it is never pre-emptively disabled.
    private static let conservativeOpenAI = ASRModelCapabilities(
        supportsFileTranscription: true,
        supportsLiveTranscription: true,
        fileResponseFormat: .automatic,
        supportsFileStreaming: false,
        languageParameter: .singular,
        supportsTimestampGranularities: false,
        supportsPrompt: false,
        supportsKeywords: false,
        timing: .none,
        maximumFileBytes: ASRModelCapabilities.openAIUploadLimit)

    public static func capabilities(
        for provider: ASRProviderKind,
        modelID: String
    ) -> ASRModelCapabilities {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case .openaiCompatible:
            return openAI(model: model)
        case .volcengine:
            return ASRModelCapabilities(
                supportsFileTranscription: true,
                supportsLiveTranscription: true,
                fileResponseFormat: .automatic,
                supportsFileStreaming: true,
                languageParameter: .none,
                supportsTimestampGranularities: false,
                supportsPrompt: false,
                supportsKeywords: false,
                timing: .providerSegments,
                maximumFileBytes: ASRModelCapabilities.openAIUploadLimit)
        case .alibaba:
            let streaming = model.contains("streaming")
            return ASRModelCapabilities(
                supportsFileTranscription: !streaming,
                supportsLiveTranscription: streaming,
                fileResponseFormat: .automatic,
                supportsFileStreaming: false,
                languageParameter: .none,
                supportsTimestampGranularities: true,
                supportsPrompt: false,
                supportsKeywords: false,
                timing: .providerSegments,
                maximumFileBytes: ASRModelCapabilities.openAIUploadLimit)
        }
    }

    private static func openAI(model: String) -> ASRModelCapabilities {
        if model == "whisper-1" {
            return ASRModelCapabilities(
                supportsFileTranscription: true,
                supportsLiveTranscription: false,
                fileResponseFormat: .verboseJSON,
                supportsFileStreaming: false,
                languageParameter: .singular,
                supportsTimestampGranularities: true,
                supportsPrompt: true,
                supportsKeywords: false,
                timing: .providerSegments,
                maximumFileBytes: ASRModelCapabilities.openAIUploadLimit)
        }
        if model == "gpt-live-transcribe" || model.hasPrefix("gpt-live-transcribe-") {
            return ASRModelCapabilities(
                supportsFileTranscription: false,
                supportsLiveTranscription: true,
                fileResponseFormat: .automatic,
                supportsFileStreaming: false,
                languageParameter: .array,
                supportsTimestampGranularities: false,
                supportsPrompt: true,
                supportsKeywords: true,
                timing: .none,
                maximumFileBytes: ASRModelCapabilities.openAIUploadLimit)
        }
        if model == "gpt-transcribe" || model.hasPrefix("gpt-transcribe-") {
            return ASRModelCapabilities(
                supportsFileTranscription: true,
                supportsLiveTranscription: true,
                fileResponseFormat: .automatic,
                supportsFileStreaming: true,
                languageParameter: .array,
                supportsTimestampGranularities: false,
                supportsPrompt: true,
                supportsKeywords: true,
                timing: .none,
                maximumFileBytes: ASRModelCapabilities.openAIUploadLimit)
        }
        if model.hasPrefix("gpt-4o-transcribe") || model.hasPrefix("gpt-4o-mini-transcribe") {
            return ASRModelCapabilities(
                supportsFileTranscription: true,
                supportsLiveTranscription: false,
                fileResponseFormat: .automatic,
                supportsFileStreaming: true,
                languageParameter: .singular,
                supportsTimestampGranularities: false,
                supportsPrompt: true,
                supportsKeywords: false,
                timing: .none,
                maximumFileBytes: ASRModelCapabilities.openAIUploadLimit)
        }
        return conservativeOpenAI
    }
}

// MARK: - Endpoint validation

/// Shared syntax validation for configured provider endpoints. It never
/// mutates or echoes the input and never carries it into an error.
public enum ASREndpointRules {
    public static let maximumCharacters = 2_048

    public static func httpsProblem(for raw: String) -> String? {
        problem(for: raw, schemes: ["https"], schemeMessage: "endpoint must use https")
    }

    /// Live endpoints accept `wss` (preferred) or `https`, which is upgraded
    /// to `wss` by the WebSocket endpoint helper. Plain `ws`/`http` is never
    /// accepted.
    public static func webSocketProblem(for raw: String) -> String? {
        problem(
            for: raw,
            schemes: ["wss", "https"],
            schemeMessage: "endpoint must use wss")
    }

    private static func problem(
        for raw: String,
        schemes: Set<String>,
        schemeMessage: String
    ) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count <= maximumCharacters else { return "endpoint is too long" }
        if value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) {
            return "endpoint must be a single URL without spaces"
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              schemes.contains(scheme) else {
            return schemeMessage
        }
        guard let host = components.host, !host.isEmpty, !host.hasPrefix(".") else {
            return "endpoint must include a host name"
        }
        if components.user != nil || components.password != nil {
            return "endpoint credentials belong in the API key field, not in the URL"
        }
        if components.fragment != nil { return "endpoint must not include a fragment" }
        if let port = components.port, !(1...65_535).contains(port) {
            return "endpoint port is invalid"
        }
        return nil
    }
}

// MARK: - OpenAI-compatible file request

/// Provider-neutral file transcription input. The profile supplies endpoint,
/// model and optional prompt/keywords; the adapter derives the exact wire
/// arguments from `ASRModelCapabilityCatalog`.
public struct ASRFileTranscriptionRequest: Sendable {
    public var profile: ASRProfile
    public var audio: Data
    public var filename: String
    public var mimeType: String
    /// Empty means `profile.languages`. The adapter picks the array or singular
    /// wire form from the model capabilities.
    public var languages: [String]
    /// Locally measured duration. Used only to report `.sourceSpanOnly`; never
    /// converted into a segment.
    public var sourceDurationSeconds: Double?
    /// Ask a modern model for its SSE transcript stream. Ignored (and never
    /// sent) for models without `supportsFileStreaming`; callers that require
    /// streaming should check the capability first.
    public var streamsResponse: Bool

    public init(
        profile: ASRProfile,
        audio: Data,
        filename: String,
        mimeType: String,
        languages: [String] = [],
        sourceDurationSeconds: Double? = nil,
        streamsResponse: Bool = false
    ) {
        self.profile = profile
        self.audio = audio
        self.filename = filename
        self.mimeType = mimeType
        self.languages = languages
        self.sourceDurationSeconds = sourceDurationSeconds
        self.streamsResponse = streamsResponse
    }
}

// MARK: - File/live protocols

public protocol ASRTranscribing: Sendable {
    /// Legacy request shape retained for source compatibility. New callers use
    /// the profile-driven request below.
    func transcribe(
        _ request: ASRTranscriptionRequest,
        credential: String
    ) async throws -> ASRTranscriptionResult

    func transcribe(
        _ request: ASRFileTranscriptionRequest,
        credential: String
    ) async throws -> ASRTranscriptionResult
}

public extension ASRTranscribing {
    /// Bridges a profile-driven request through the legacy request shape for
    /// conformers that have not adopted the new method yet. The endpoint is
    /// resolved from the profile; language uses the first array element or the
    /// profile's first hint.
    func transcribe(
        _ request: ASRFileTranscriptionRequest,
        credential: String
    ) async throws -> ASRTranscriptionResult {
        let passedLanguages = request.languages.isEmpty
            ? request.profile.languages
            : request.languages
        let legacy = ASRTranscriptionRequest(
            endpointBaseURL: request.profile.resolvedFileEndpoint,
            modelID: request.profile.fileModelID,
            language: passedLanguages.first,
            filename: request.filename,
            mimeType: request.mimeType,
            audio: request.audio,
            durationSeconds: request.sourceDurationSeconds,
            languages: passedLanguages,
            streamsResponse: request.streamsResponse)
        return try await transcribe(legacy, credential: credential)
    }
}

/// Typed live-transcription update keyed by the caller turn and the provider
/// item. Deltas carry the newly available text; finals carry the full text.
public struct ASRLiveEvent: Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case partial
        case final
        case failed
    }

    public let kind: Kind
    public let turnID: UUID
    public let itemID: String?
    public let text: String
    public let failure: ASRTranscriptionError?
    public let sequence: Int

    public init(
        kind: Kind,
        turnID: UUID,
        itemID: String?,
        text: String,
        failure: ASRTranscriptionError? = nil,
        sequence: Int
    ) {
        self.kind = kind
        self.turnID = turnID
        self.itemID = itemID
        self.text = text
        self.failure = failure
        self.sequence = sequence
    }

    public static func partial(
        turnID: UUID,
        itemID: String?,
        delta: String,
        sequence: Int
    ) -> ASRLiveEvent {
        ASRLiveEvent(
            kind: .partial, turnID: turnID, itemID: itemID,
            text: delta, sequence: sequence)
    }

    public static func final(
        turnID: UUID,
        itemID: String?,
        transcript: String,
        sequence: Int
    ) -> ASRLiveEvent {
        ASRLiveEvent(
            kind: .final, turnID: turnID, itemID: itemID,
            text: transcript, sequence: sequence)
    }

    public static func failed(
        turnID: UUID,
        itemID: String?,
        error: ASRTranscriptionError,
        sequence: Int
    ) -> ASRLiveEvent {
        ASRLiveEvent(
            kind: .failed, turnID: turnID, itemID: itemID,
            text: "", failure: error, sequence: sequence)
    }
}

/// One live utterance. The profile selects provider/model/endpoint; the
/// credential is supplied separately and never stored.
public struct ASRLiveSessionRequest: Sendable {
    public var profile: ASRProfile
    public var turnID: UUID
    /// OpenAI requires 24 kHz PCM16 mono. Bounded to 8–48 kHz for vendor use.
    public var inputSampleRate: Int
    public var languages: [String]
    public var prompt: String?
    public var keywords: [String]
    public var maximumAudioBytes: Int
    public var maximumEventBytes: Int
    public var eventQueueCapacity: Int
    public var finishTimeoutSeconds: Double

    public init(
        profile: ASRProfile,
        turnID: UUID = UUID(),
        inputSampleRate: Int = 24_000,
        languages: [String] = [],
        prompt: String? = nil,
        keywords: [String] = [],
        maximumAudioBytes: Int = 64 * 1024 * 1024,
        maximumEventBytes: Int = 1 * 1024 * 1024,
        eventQueueCapacity: Int = 256,
        finishTimeoutSeconds: Double = 30
    ) {
        self.profile = profile
        self.turnID = turnID
        self.inputSampleRate = (8_000...48_000).contains(inputSampleRate)
            ? inputSampleRate
            : 24_000
        self.languages = ASRProfile.normalizedLanguages(languages)
        let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = (trimmedPrompt?.isEmpty ?? true) ? nil : trimmedPrompt
        self.keywords = ASRProfile.normalizedKeywords(keywords)
        self.maximumAudioBytes = Swift.max(2, maximumAudioBytes)
        self.maximumEventBytes = Swift.max(1_024, maximumEventBytes)
        self.eventQueueCapacity = Swift.max(8, eventQueueCapacity)
        self.finishTimeoutSeconds = (finishTimeoutSeconds.isFinite
            && finishTimeoutSeconds > 0) ? finishTimeoutSeconds : 30
    }
}

public protocol ASRLiveTranscribing: Sendable {
    func startLiveSession(
        _ request: ASRLiveSessionRequest,
        credential: String
    ) async throws -> any ASRLiveSession
}

public protocol ASRLiveSession: Sendable {
    nonisolated var events: ASRBoundedEventStream<ASRLiveEvent> { get }
    nonisolated var turnID: UUID { get }
    /// Append PCM16 mono audio. Only valid before `endUtterance`.
    func feed(_ audio: Data) async throws
    /// Commit the current utterance exactly once. Cancellation is separate.
    func endUtterance() async throws
    /// Ensure the utterance is committed, drain until final/failed, then close.
    func finish() async throws
    /// Discard queued events and cancel the transport. Never a provider
    /// failure and never a trigger for silent fallback or route switching.
    func cancel() async
}

// MARK: - Injectable transports

/// One bounded HTTP response. The body is already capped by the transport
/// caller; provider text never enters an error.
public struct ASRHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    public var url: URL?

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data,
        url: URL? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.url = url
    }
}

public protocol ASRHTTPTransport: Sendable {
    func perform(_ request: URLRequest, body: Data) async throws -> ASRHTTPResponse
}

public enum ASRWebSocketMessage: Sendable, Hashable {
    case text(String)
    case data(Data)
}

public protocol ASRWebSocketConnection: Sendable {
    func send(_ message: ASRWebSocketMessage) async throws
    func receive() async throws -> ASRWebSocketMessage
    /// Graceful close after a drained final.
    func close()
    /// Immediate cancellation; queued provider messages must not be delivered.
    func cancel()
}

public protocol ASRWebSocketTransport: Sendable {
    func connect(_ request: URLRequest) async throws -> any ASRWebSocketConnection
}

// MARK: - OpenAI realtime endpoint

/// Explicit OpenAI-compatible realtime endpoint resolution. nil/blank means
/// the official `wss://api.openai.com/v1/realtime?intent=transcription`.
/// A configured value may be a base (`wss://relay.example/openai/v1`), the
/// full `/realtime` URL, or an `https` URL (upgraded to `wss`). Reverse-proxy
/// path and query prefixes are preserved; `intent=transcription` is composed
/// exactly once; embedded credentials and fragments are rejected.
public enum ASROpenAIRealtimeEndpoint {
    public static let officialURL = URL(
        string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    public static let maximumCharacters = 2_048
    public static let realtimePath = "/realtime"
    public static let intent = "transcription"

    public static func validationProblem(for raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if case .problem(let problem) = parse(value) { return problem }
        return nil
    }

    public static func endpointURL(base raw: String?) throws -> URL {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return officialURL }
        switch parse(value) {
        case .problem(let problem):
            throw ASRTranscriptionError.invalidConfiguration(problem)
        case .parsed(let parsed):
            guard let url = parsed.url() else {
                throw ASRTranscriptionError.invalidConfiguration(
                    "endpoint is not a valid URL")
            }
            return url
        }
    }

    public static func originChanged(from old: String?, to new: String?) -> Bool {
        originKey(old) != originKey(new)
    }

    // MARK: Parsing

    private struct Parsed {
        let host: String
        let port: Int?
        let percentEncodedPath: String
        var queryItems: [URLQueryItem]

        var origin: String { "\(host):\(port ?? 443)" }

        var composedPath: String {
            var path = percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            while path.hasSuffix("/v1/v1") { path.removeLast("/v1".count) }
            if path.hasSuffix(realtimePath) { return path }
            if path.isEmpty {
                path = "/v1"
            } else if !path.hasSuffix("/v1") {
                path += "/v1"
            }
            return path + realtimePath
        }

        func url() -> URL? {
            var components = URLComponents()
            components.scheme = "wss"
            components.host = host
            components.port = port
            components.percentEncodedPath = composedPath
            var items = queryItems.filter {
                $0.name.lowercased() != "intent"
            }
            items.append(URLQueryItem(name: "intent", value: ASROpenAIRealtimeEndpoint.intent))
            components.queryItems = items
            return components.url
        }
    }

    private enum ParseOutcome {
        case parsed(Parsed)
        case problem(String)
    }

    private static func parse(_ value: String) -> ParseOutcome {
        guard value.count <= maximumCharacters else {
            return .problem("endpoint is too long")
        }
        if value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) {
            return .problem("endpoint must be a single URL without spaces")
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "wss" || scheme == "https" else {
            return .problem("endpoint must use wss")
        }
        guard let host = components.host, !host.isEmpty, !host.hasPrefix(".") else {
            return .problem("endpoint must include a host name")
        }
        if components.user != nil || components.password != nil {
            return .problem("endpoint credentials belong in the API key field, not in the URL")
        }
        if components.fragment != nil { return .problem("endpoint must not include a fragment") }
        if let port = components.port, !(1...65_535).contains(port) {
            return .problem("endpoint port is invalid")
        }
        let queryItems = components.queryItems ?? []
        if let intentItem = queryItems.first(where: {
            $0.name.lowercased() == "intent"
        }), intentItem.value?.lowercased() != intent {
            return .problem("endpoint intent must be transcription")
        }
        return .parsed(Parsed(
            host: host.lowercased(),
            port: components.port == 443 ? nil : components.port,
            percentEncodedPath: components.percentEncodedPath,
            queryItems: queryItems))
    }

    private static func originKey(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return "api.openai.com:443" }
        switch parse(value) {
        case .problem: return "invalid"
        case .parsed(let parsed): return parsed.origin
        }
    }
}

// MARK: - Bounded event stream

/// Lossless, bounded, ordered async event stream. `send` awaits while the
/// buffer is full, so a slow consumer applies backpressure to the socket
/// reader instead of losing partial transcripts. `finish` drains buffered
/// events then ends; `abandon` clears them (cancellation).
public final class ASRBoundedEventStream<Event: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Event

    private let storage: Storage

    public init(capacity: Int = 256) {
        storage = Storage(capacity: capacity)
    }

    public func send(_ event: Event) async throws {
        try await storage.send(event)
    }

    /// End after buffered events have been consumed.
    public func finish() {
        storage.finish(throwing: nil)
    }

    /// End after buffered events with a terminal error.
    public func finish(throwing error: Error) {
        storage.finish(throwing: error)
    }

    /// Discard buffered events and end with a terminal error (cancellation).
    public func abandon(throwing error: Error) {
        storage.abandon(throwing: error)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(storage: storage)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let storage: Storage

        fileprivate init(storage: Storage) {
            self.storage = storage
        }

        public mutating func next() async throws -> Event? {
            try await storage.next()
        }
    }

    fileprivate final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private let capacity: Int
        private var queue: [Event] = []
        private var finished = false
        private var failure: Error?
        private var consumer: CheckedContinuation<Event?, Error>?
        private var parkedSenders: [CheckedContinuation<Void, Never>] = []

        init(capacity: Int) {
            self.capacity = Swift.max(1, capacity)
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        private func terminalError() -> Error {
            failure ?? CancellationError()
        }

        private enum SendStep {
            case done
            case deliver(CheckedContinuation<Event?, Error>)
            case failed(Error)
            case park
        }

        func send(_ event: Event) async throws {
            while true {
                let step: SendStep = withLock {
                    if finished { return .failed(terminalError()) }
                    if let consumer {
                        self.consumer = nil
                        // Resume only after the lock is released (see below).
                        return .deliver(consumer)
                    }
                    if queue.count < capacity {
                        queue.append(event)
                        return .done
                    }
                    return .park
                }
                switch step {
                case .done:
                    return
                case .deliver(let consumer):
                    consumer.resume(returning: event)
                    return
                case .failed(let error):
                    throw error
                case .park:
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let shouldWake: Bool = withLock {
                            if finished { return true }
                            if queue.count < capacity { return true }
                            parkedSenders.append(continuation)
                            return false
                        }
                        if shouldWake { continuation.resume() }
                    }
                }
            }
        }

        func next() async throws -> Event? {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Event?, Error>) in
                    var immediate: Result<Event?, Error>?
                    var wokenSender: CheckedContinuation<Void, Never>?
                    withLock {
                        if !queue.isEmpty {
                            let event = queue.removeFirst()
                            if !parkedSenders.isEmpty {
                                wokenSender = parkedSenders.removeFirst()
                            }
                            immediate = .success(event)
                        } else if finished {
                            immediate = failure.map { .failure($0) } ?? .success(nil)
                        } else {
                            consumer = continuation
                        }
                    }
                    wokenSender?.resume()
                    if let immediate { continuation.resume(with: immediate) }
                }
            } onCancel: {
                abandon(throwing: CancellationError())
            }
        }

        func finish(throwing error: Error?) {
            var parkedConsumer: CheckedContinuation<Event?, Error>?
            var senders: [CheckedContinuation<Void, Never>] = []
            withLock {
                guard !finished else { return }
                finished = true
                failure = error
                parkedConsumer = consumer
                consumer = nil
                senders = parkedSenders
                parkedSenders = []
            }
            if let parkedConsumer {
                parkedConsumer.resume(
                    with: error.map { Result.failure($0) } ?? .success(nil))
            }
            for sender in senders { sender.resume() }
        }

        func abandon(throwing error: Error) {
            var parkedConsumer: CheckedContinuation<Event?, Error>?
            var senders: [CheckedContinuation<Void, Never>] = []
            withLock {
                guard !finished else { return }
                finished = true
                failure = error
                queue.removeAll()
                parkedConsumer = consumer
                consumer = nil
                senders = parkedSenders
                parkedSenders = []
            }
            if let parkedConsumer {
                parkedConsumer.resume(with: .failure(error))
            }
            for sender in senders { sender.resume() }
        }
    }
}
