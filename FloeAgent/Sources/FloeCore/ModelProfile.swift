// FloeCore — Model configuration profile.
// See docs/DEVELOPMENT_PLAN.md §2.2.

import Foundation

/// Capability flags advertised by a remote model. Approval is a task policy,
/// not an optional model feature; the legacy bit remains decodable only for
/// configuration compatibility.
public struct ModelCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let text            = ModelCapabilities(rawValue: 1 << 0)
    public static let vision          = ModelCapabilities(rawValue: 1 << 1)
    public static let tools           = ModelCapabilities(rawValue: 1 << 2)
    public static let imageGeneration = ModelCapabilities(rawValue: 1 << 3)
    public static let imageEditing    = ModelCapabilities(rawValue: 1 << 4)
    public static let approval        = ModelCapabilities(rawValue: 1 << 5)
    public static let videoGeneration = ModelCapabilities(rawValue: 1 << 6)

    /// Every wire protocol currently implemented by Floe has a native
    /// structured function/tool-call contract. Manual entries therefore start
    /// tool-capable; users may still disable the flag in the model editor for
    /// endpoints or models that do not implement that part of the protocol.
    public static func defaultTextModel(for wireProtocol: ModelProtocol) -> ModelCapabilities {
        switch wireProtocol {
        case .openAIResponses, .openAIChatCompletions, .anthropicMessages:
            return [.text, .tools, .approval]
        }
    }
}

/// Hard limits enforced client-side before sending a request.
public struct ModelLimits: Sendable, Codable, Hashable {
    public var contextTokens: Int
    /// Zero means the user did not configure a provider-side output limit.
    /// Optional protocols omit the field; required protocols choose a
    /// conservative adapter default.
    public var maxOutputTokens: Int

    public init(contextTokens: Int, maxOutputTokens: Int) {
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
    }

    public var configuredMaxOutputTokens: Int? {
        maxOutputTokens > 0 ? maxOutputTokens : nil
    }

    /// Local byte-budget input when the provider limit is unspecified. This
    /// is a safety ceiling only and is never sent on the wire.
    public var clientOutputSafetyTokens: Int {
        configuredMaxOutputTokens ?? min(contextTokens, 131_072)
    }

    public var clientOutputSafetyBytes: Int {
        let cappedTokens = min(clientOutputSafetyTokens, (8 * 1_024 * 1_024) / 16)
        return max(65_536, cappedTokens * 16)
    }
}

/// Informational pricing, shown to the user before potentially costly calls.
public struct PricingMetadata: Sendable, Codable, Hashable {
    public var inputPerMillion: Decimal?
    public var outputPerMillion: Decimal?
    /// ISO 4217 currency code.
    public var currency: String

    public init(inputPerMillion: Decimal? = nil, outputPerMillion: Decimal? = nil, currency: String = "USD") {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.currency = currency
    }
}

/// Provider-neutral user intent for how much reasoning work a model should
/// perform. Adapters translate this value to their native protocol and omit it
/// when the selected endpoint/model family is not known to support the field.
public enum ModelReasoningEffort: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case automatic
    case low
    case medium
    case high
    case maximum

    public var id: String { rawValue }
}

/// One selectable model exposed by a provider.
public struct ModelProfile: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var providerID: UUID
    /// Identifier sent on the wire (e.g. "gpt-5", "claude-opus-4").
    public var remoteModelID: String
    public var displayName: String
    public var limits: ModelLimits
    public var pricing: PricingMetadata?
    public var capabilities: ModelCapabilities
    /// Optional keeps older CloudKit/config payloads source-compatible;
    /// `nil` has the same meaning as `.automatic`.
    public var reasoningEffort: ModelReasoningEffort?
    public var isEnabled: Bool
    /// Independent presentation preference for the primary chat-model picker.
    ///
    /// `nil` decodes legacy synced payloads as visible. A hidden model remains
    /// enabled and can still serve auxiliary routes such as vision, approval,
    /// package review or an already-running conversation.
    public var isHiddenFromPrimaryPicker: Bool?

    public init(
        id: UUID = UUID(),
        providerID: UUID,
        remoteModelID: String,
        displayName: String,
        limits: ModelLimits,
        pricing: PricingMetadata? = nil,
        capabilities: ModelCapabilities = [.text],
        reasoningEffort: ModelReasoningEffort? = nil,
        isEnabled: Bool = true,
        isHiddenFromPrimaryPicker: Bool? = false
    ) {
        self.id = id
        self.providerID = providerID
        self.remoteModelID = remoteModelID
        self.displayName = displayName
        self.limits = limits
        self.pricing = pricing
        self.capabilities = capabilities
        self.reasoningEffort = reasoningEffort
        self.isEnabled = isEnabled
        self.isHiddenFromPrimaryPicker = isHiddenFromPrimaryPicker
    }

    public var effectiveReasoningEffort: ModelReasoningEffort {
        reasoningEffort ?? .automatic
    }

    public var isVisibleInPrimaryPicker: Bool {
        isHiddenFromPrimaryPicker != true
    }
}
