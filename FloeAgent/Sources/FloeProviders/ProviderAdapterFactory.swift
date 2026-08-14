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
public struct ProviderPreset: Sendable, Hashable, Identifiable {
    public var id: String { kind.rawValue }
    public var kind: ProviderKind
    public var displayName: String
    public var wireProtocol: ModelProtocol
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
        kind: ProviderKind,
        displayName: String,
        wireProtocol: ModelProtocol,
        defaultBaseURL: URL,
        supportsModelDiscovery: Bool,
        authStyle: AuthStyle
    ) {
        self.kind = kind
        self.displayName = displayName
        self.wireProtocol = wireProtocol
        self.defaultBaseURL = defaultBaseURL
        self.supportsModelDiscovery = supportsModelDiscovery
        self.authStyle = authStyle
    }
}

public extension ProviderPreset {
    /// Canonical launch presets. Base URLs are the providers' public API
    /// roots; compatible gateways use the OpenAI Chat Completions wire format.
    static let openAIResponses = ProviderPreset(
        kind: .openAI,
        displayName: "OpenAI (Responses)",
        wireProtocol: .openAIResponses,
        defaultBaseURL: URL(string: "https://api.openai.com/v1")!,
        supportsModelDiscovery: true,
        authStyle: .bearer
    )

    static let openAIChatCompletions = ProviderPreset(
        kind: .openAI,
        displayName: "OpenAI (Chat Completions)",
        wireProtocol: .openAIChatCompletions,
        defaultBaseURL: URL(string: "https://api.openai.com/v1")!,
        supportsModelDiscovery: true,
        authStyle: .bearer
    )

    static let anthropic = ProviderPreset(
        kind: .anthropic,
        displayName: "Anthropic",
        wireProtocol: .anthropicMessages,
        defaultBaseURL: URL(string: "https://api.anthropic.com")!,
        supportsModelDiscovery: true,
        authStyle: .apiKeyHeader
    )

    static let volcengineArk = ProviderPreset(
        kind: .volcengineArk,
        displayName: "Volcengine Ark (compatible)",
        wireProtocol: .openAIChatCompletions,
        defaultBaseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
        supportsModelDiscovery: true,
        authStyle: .bearer
    )

    static let alibabaStudio = ProviderPreset(
        kind: .alibabaStudio,
        displayName: "Alibaba Model Studio (compatible)",
        wireProtocol: .openAIChatCompletions,
        defaultBaseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!,
        supportsModelDiscovery: true,
        authStyle: .bearer
    )

    static let custom = ProviderPreset(
        kind: .custom,
        displayName: "Custom compatible endpoint",
        wireProtocol: .openAIChatCompletions,
        defaultBaseURL: URL(string: "https://example.com/v1")!,
        supportsModelDiscovery: false,
        authStyle: .bearer
    )

    /// All launch presets in display order.
    static let all: [ProviderPreset] = [
        .openAIResponses,
        .openAIChatCompletions,
        .anthropic,
        .volcengineArk,
        .alibabaStudio,
        .custom
    ]

    /// Looks up the preset matching a provider kind, defaulting to custom.
    static func preset(for kind: ProviderKind) -> ProviderPreset {
        all.first { $0.kind == kind } ?? .custom
    }
}
