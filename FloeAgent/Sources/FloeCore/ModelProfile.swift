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

/// Product surfaces where a model may be selected. This is intentionally
/// independent from wire-protocol capabilities: an OpenAI-compatible image
/// endpoint may advertise text-shaped request fields without being a chat
/// agent, while a hidden vision model may remain available to Canvas.
public struct ModelUseSurfaces: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let chatAgent       = ModelUseSurfaces(rawValue: 1 << 0)
    public static let auxiliaryVision = ModelUseSurfaces(rawValue: 1 << 1)
    public static let approval        = ModelUseSurfaces(rawValue: 1 << 2)
    public static let imageGeneration = ModelUseSurfaces(rawValue: 1 << 3)
    public static let videoGeneration = ModelUseSurfaces(rawValue: 1 << 4)
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
    /// Explicit product routing. Nil is retained for synced legacy records and
    /// is deterministically derived from capabilities by `effectiveUseSurfaces`.
    public var useSurfaces: ModelUseSurfaces?
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
        useSurfaces: ModelUseSurfaces? = nil,
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
        self.useSurfaces = useSurfaces
        self.reasoningEffort = reasoningEffort
        self.isEnabled = isEnabled
        self.isHiddenFromPrimaryPicker = isHiddenFromPrimaryPicker
    }

    public var effectiveReasoningEffort: ModelReasoningEffort {
        reasoningEffort ?? .automatic
    }

    public var effectiveUseSurfaces: ModelUseSurfaces {
        var result: ModelUseSurfaces = useSurfaces ?? []
        let hasImageCapability = capabilities.contains(.imageGeneration)
            || capabilities.contains(.imageEditing)
        let hasVideoCapability = capabilities.contains(.videoGeneration)
        let isMedia = hasImageCapability || hasVideoCapability
        if useSurfaces == nil {
            if capabilities.contains(.text), !isMedia { result.insert(.chatAgent) }
            if capabilities.contains(.vision), !isMedia { result.insert(.auxiliaryVision) }
            if capabilities.contains(.approval), !isMedia { result.insert(.approval) }
            if capabilities.contains(.imageGeneration) || capabilities.contains(.imageEditing) {
                result.insert(.imageGeneration)
            }
            if capabilities.contains(.videoGeneration) { result.insert(.videoGeneration) }
        }
        // Treat media endpoints as a separate product role even when a stale
        // synced row explicitly contains chat/vision/approval surfaces. A
        // reference-image input is not visual understanding, and an
        // OpenAI-compatible wire protocol does not make a generator an LLM.
        if isMedia || result.contains(.imageGeneration) || result.contains(.videoGeneration) {
            result.remove([.chatAgent, .auxiliaryVision, .approval])
        }
        // A stale synced role bit must not make a model appear in an
        // unrelated media picker. Capabilities are the authoritative signal
        // once a media capability exists; explicit use surfaces remain the
        // compatibility fallback only for older records that had no media
        // capability flags at all.
        if isMedia {
            if !hasImageCapability { result.remove(.imageGeneration) }
            if !hasVideoCapability { result.remove(.videoGeneration) }
        }
        return result
    }

    public var supportsChatAgentSurface: Bool {
        effectiveUseSurfaces.contains(.chatAgent)
            && capabilities.contains(.text)
    }

    /// Text-producing inference, never a media-generation endpoint whose
    /// advertised text flag merely describes prompt input.
    public var supportsGeneralAuxiliaryLLM: Bool {
        capabilities.contains(.text)
            && capabilities.isDisjoint(with: [.imageGeneration, .imageEditing, .videoGeneration])
            && !effectiveUseSurfaces.contains(.imageGeneration)
            && !effectiveUseSurfaces.contains(.videoGeneration)
    }

    /// A visual-understanding helper must be a dedicated inference model.
    /// Media generators sometimes advertise `vision` because they accept
    /// reference images, but that does not make them suitable for OCR or
    /// describing an attachment. Keep those models out of every auxiliary
    /// vision picker and route even when a stale synced row contains both
    /// surfaces.
    public var supportsAuxiliaryVisionSurface: Bool {
        effectiveUseSurfaces.contains(.auxiliaryVision)
            && capabilities.contains(.vision)
            && !effectiveUseSurfaces.contains(.imageGeneration)
            && !effectiveUseSurfaces.contains(.videoGeneration)
            && !capabilities.contains(.imageGeneration)
            && !capabilities.contains(.imageEditing)
            && !capabilities.contains(.videoGeneration)
    }

    /// Approval must be performed by a text/reasoning model, not by a media
    /// generation endpoint that happens to carry a stale approval flag.
    public var supportsApprovalSurface: Bool {
        effectiveUseSurfaces.contains(.approval)
            && capabilities.contains(.text)
            && !effectiveUseSurfaces.contains(.imageGeneration)
            && !effectiveUseSurfaces.contains(.videoGeneration)
            && !capabilities.contains(.imageGeneration)
            && !capabilities.contains(.imageEditing)
            && !capabilities.contains(.videoGeneration)
    }

    public var supportsImageGenerationSurface: Bool {
        effectiveUseSurfaces.contains(.imageGeneration)
            && (capabilities.contains(.imageGeneration) || capabilities.contains(.imageEditing))
            && !capabilities.contains(.videoGeneration)
    }

    public var supportsVideoGenerationSurface: Bool {
        effectiveUseSurfaces.contains(.videoGeneration)
            && capabilities.contains(.videoGeneration)
            && !capabilities.contains(.imageGeneration)
            && !capabilities.contains(.imageEditing)
    }

    public var isVisibleInPrimaryPicker: Bool {
        isHiddenFromPrimaryPicker != true
    }
}
