import Foundation

/// One place that answers "which provider/model family is this?".
/// Previously `ReasoningCompatibility.isDeepSeek` considered the model id
/// while `CompatToolNames.usesWireSafeNames` did not, so a DeepSeek model on
/// a gateway could receive reasoning-replay requirements without wire-safe
/// tool names (or vice versa). Every heuristic now reads this value.
public struct ProviderTraits: Sendable, Hashable {
    public let kind: ProviderKind
    public let host: String?
    public let displayName: String?
    public let modelRemoteID: String?
    public let toolNameCompatibility: Bool

    public init(provider: ProviderProfile, model: ModelProfile? = nil) {
        self.kind = provider.kind
        self.host = provider.baseURL.host?.lowercased()
        self.displayName = provider.displayName?.lowercased()
        self.modelRemoteID = model?.remoteModelID.lowercased()
        self.toolNameCompatibility = provider.toolNameCompatibility
    }

    private func contains(_ needle: String, in value: String?) -> Bool {
        value?.contains(needle) == true
    }

    public var isDeepSeek: Bool {
        contains("deepseek", in: host)
            || contains("deepseek", in: displayName)
            || contains("deepseek", in: modelRemoteID)
    }

    public var isDashScope: Bool {
        contains("dashscope", in: host) || contains("dashscope", in: displayName)
    }

    public var isAnthropicFamily: Bool {
        kind == .anthropic
            || contains("anthropic", in: host)
            || contains("claude", in: modelRemoteID)
    }

    public var isOpenAIReasoningFamily: Bool {
        if kind == .openAI || contains("openai.com", in: host) { return true }
        guard let id = modelRemoteID else { return false }
        return id.hasPrefix("gpt-5") || id.hasPrefix("o1") || id.hasPrefix("o3")
            || id.hasPrefix("o4") || id.contains("codex")
    }

    /// DeepSeek-shaped endpoints reject dots in function names.
    public var usesWireSafeToolNames: Bool {
        toolNameCompatibility || isDeepSeek
    }

    /// Thinking-mode requests carrying tools must replay prior reasoning.
    public var requiresReasoningReplay: Bool {
        isDeepSeek
    }
}

public extension ProviderProfile {
    func traits(model: ModelProfile? = nil) -> ProviderTraits {
        ProviderTraits(provider: self, model: model)
    }
}
