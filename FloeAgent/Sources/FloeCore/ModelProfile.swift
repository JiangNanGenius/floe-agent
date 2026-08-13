// FloeCore — Model configuration profile.
// See docs/DEVELOPMENT_PLAN.md §2.2.

import Foundation

/// Capability flags advertised by a remote model. Used to gate features
/// (e.g. only `.approval` models may serve as the approval model).
public struct ModelCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let text            = ModelCapabilities(rawValue: 1 << 0)
    public static let vision          = ModelCapabilities(rawValue: 1 << 1)
    public static let tools           = ModelCapabilities(rawValue: 1 << 2)
    public static let imageGeneration = ModelCapabilities(rawValue: 1 << 3)
    public static let imageEditing    = ModelCapabilities(rawValue: 1 << 4)
    public static let approval        = ModelCapabilities(rawValue: 1 << 5)
}

/// Hard limits enforced client-side before sending a request.
public struct ModelLimits: Sendable, Codable, Hashable {
    public var contextTokens: Int
    public var maxOutputTokens: Int

    public init(contextTokens: Int, maxOutputTokens: Int) {
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
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
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        providerID: UUID,
        remoteModelID: String,
        displayName: String,
        limits: ModelLimits,
        pricing: PricingMetadata? = nil,
        capabilities: ModelCapabilities = [.text],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.providerID = providerID
        self.remoteModelID = remoteModelID
        self.displayName = displayName
        self.limits = limits
        self.pricing = pricing
        self.capabilities = capabilities
        self.isEnabled = isEnabled
    }
}
