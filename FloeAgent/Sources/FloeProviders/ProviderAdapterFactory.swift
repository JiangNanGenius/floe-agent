// FloeProviders — Provider presets and adapter factory.
// See docs/ALPHA_DAILY_PLAN.md §"Providers and real chat": presets for
// OpenAI Responses/Chat, Anthropic Messages, Volcengine Ark-compatible,
// Alibaba Model Studio-compatible and custom compatible endpoints. The
// factory maps a `ProviderProfile` to the wire adapter that speaks its
// `wireProtocol`. No credentials are embedded — they stay in Keychain.

import Foundation
import FloeCore

/// Builds the correct `ProviderAdapter` for a provider's wire protocol and
/// supplies canonical presets. Value type; no shared mutable state.
public struct ProviderAdapterFactory: Sendable {

    public init() {}

    /// Returns the adapter that speaks `profile.wireProtocol`.
    public func adapter(for profile: ProviderProfile) -> any ProviderAdapter {
        Self.adapter(for: profile.wireProtocol)
    }

    /// Returns the adapter for a wire protocol. Compatible third-party
    /// endpoints (Ark, Alibaba, custom OpenAI-compatible) reuse the OpenAI
    /// Chat Completions adapter because they speak that wire format.
    public static func adapter(for wireProtocol: ModelProtocol) -> any ProviderAdapter {
        switch wireProtocol {
        case .openAIResponses:
            return OpenAIResponsesAdapter()
        case .openAIChatCompletions:
            return OpenAIChatCompletionsAdapter()
        case .anthropicMessages:
            return AnthropicMessagesAdapter()
        }
    }
}

/// A named provider preset: default endpoint, wire protocol and auth shape.
/// Used by the provider editor to pre-fill a new provider; the user may edit
/// every field before saving. Presets carry no credentials.
public enum ProviderTemplateID: String, Sendable, Codable, CaseIterable, Hashable {
    case openAI
    case anthropic
    case volcengineArk
    case alibabaStudio
    case googleGemini
    case local
    case custom
}

public struct ProviderPreset: Sendable, Hashable, Identifiable {
    public var id: ProviderTemplateID
    public var kind: ProviderKind
    public var displayName: String
    public var defaultProtocol: ModelProtocol
    public var supportedProtocols: [ModelProtocol]
    public var defaultBaseURL: URL
    /// Whether the endpoint is expected to expose a `/models` listing.
    public var supportsModelDiscovery: Bool
    /// Auth header style required by the endpoint.
    public var authStyle: AuthStyle

    public enum AuthStyle: String, Sendable, Hashable {
        /// `Authorization: Bearer <key>` (OpenAI and most compatible gateways).
        case bearer
        /// `x-api-key: <key>` (Anthropic).
        case apiKeyHeader
        /// No authentication (local inference).
        case none
    }

    public init(
        id: ProviderTemplateID,
        kind: ProviderKind,
        displayName: String,
        defaultProtocol: ModelProtocol,
        supportedProtocols: [ModelProtocol],
        defaultBaseURL: URL,
        supportsModelDiscovery: Bool,
        authStyle: AuthStyle
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.defaultProtocol = defaultProtocol
        self.supportedProtocols = supportedProtocols
        self.defaultBaseURL = defaultBaseURL
        self.supportsModelDiscovery = supportsModelDiscovery
        self.authStyle = authStyle
    }

    /// Backward-compatible shorthand for call sites that want the preset's
    /// default protocol rather than the user's provider-level selection.
    public var wireProtocol: ModelProtocol { defaultProtocol }
}

public extension ProviderPreset {
    /// Canonical launch presets. Base URLs are the providers' public API
    /// roots; compatible gateways use the OpenAI Chat Completions wire format.
    static let openAIResponses = ProviderPreset(
        id: .openAI,
        kind: .openAI,
        displayName: "OpenAI",
        defaultProtocol: .openAIResponses,
        supportedProtocols: [.openAIResponses, .openAIChatCompletions],
        defaultBaseURL: URL(string: "https://api.openai.com/v1")!,
        supportsModelDiscovery: true,
        authStyle: .bearer
    )

    static let anthropic = ProviderPreset(
        id: .anthropic,
        kind: .anthropic,
        displayName: "Anthropic",
        defaultProtocol: .anthropicMessages,
        supportedProtocols: [.anthropicMessages],
        defaultBaseURL: URL(string: "https://api.anthropic.com")!,
        supportsModelDiscovery: true,
        authStyle: .apiKeyHeader
    )

    static let volcengineArk = ProviderPreset(
        id: .volcengineArk,
        kind: .volcengineArk,
        displayName: "Volcengine Ark",
        defaultProtocol: .openAIChatCompletions,
        supportedProtocols: [.openAIChatCompletions],
        defaultBaseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
        supportsModelDiscovery: true,
        authStyle: .bearer
    )

    static let alibabaStudio = ProviderPreset(
        id: .alibabaStudio,
        kind: .alibabaStudio,
        // DashScope is the public API/SDK name users encounter when creating
        // keys and reading the image API documentation. Keep the persisted
        // enum case for database compatibility, but use the recognizable API
        // product name in the UI.
        displayName: "DashScope（阿里云百炼）",
        defaultProtocol: .openAIChatCompletions,
        supportedProtocols: [.openAIChatCompletions],
        defaultBaseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!,
        supportsModelDiscovery: true,
        authStyle: .bearer
    )

    /// Image-only Gemini API preset. It is intentionally excluded from the
    /// chat-provider picker because Floe uses the native generateContent image
    /// contract rather than pretending it is OpenAI-compatible.
    static let googleGemini = ProviderPreset(
        id: .googleGemini,
        kind: .googleGemini,
        displayName: "Google Gemini Images",
        defaultProtocol: .openAIChatCompletions,
        supportedProtocols: [.openAIChatCompletions],
        defaultBaseURL: URL(string: "https://generativelanguage.googleapis.com/v1")!,
        supportsModelDiscovery: false,
        authStyle: .apiKeyHeader
    )

    static let custom = ProviderPreset(
        id: .custom,
        kind: .custom,
        displayName: "Custom compatible endpoint",
        defaultProtocol: .openAIChatCompletions,
        supportedProtocols: [.openAIResponses, .openAIChatCompletions, .anthropicMessages],
        defaultBaseURL: URL(string: "https://example.com/v1")!,
        // OpenAI-compatible endpoints (DeepSeek, Grok, vLLM, …) expose
        // GET /models, so discovery and a real connection probe both work.
        supportsModelDiscovery: true,
        authStyle: .bearer
    )

    static let local = ProviderPreset(
        id: .local,
        kind: .local,
        displayName: "On-device models",
        defaultProtocol: .openAIChatCompletions,
        supportedProtocols: [.openAIChatCompletions],
        defaultBaseURL: URL(string: "http://127.0.0.1")!,
        supportsModelDiscovery: true,
        authStyle: .none
    )

    /// All launch presets in display order.
    static let all: [ProviderPreset] = [
        .openAIResponses,
        .anthropic,
        .volcengineArk,
        .alibabaStudio,
        .googleGemini,
        .local,
        .custom
    ]

    /// Providers that can be configured as remote conversation-model
    /// endpoints. Google Gemini Images belongs in Auxiliary Models, while
    /// on-device models are managed by the dedicated Local Models screen.
    static let chatPresets: [ProviderPreset] = all.filter {
        $0.kind != .googleGemini && $0.kind != .local
    }

    /// Looks up the preset matching a provider kind, defaulting to custom.
    static func preset(for kind: ProviderKind) -> ProviderPreset {
        all.first { $0.kind == kind } ?? .custom
    }
}
