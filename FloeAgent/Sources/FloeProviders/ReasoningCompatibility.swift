// FloeProviders — provider-specific reasoning controls.

import Foundation
import FloeCore

/// Translates one stable UI setting into only the fields documented by the
/// selected provider/model family. Unknown custom endpoints receive no extra
/// fields, which preserves compatibility with strict OpenAI-shaped gateways.
enum ReasoningCompatibility {
    struct ChatOptions: Equatable {
        var thinkingType: String? = nil
        var reasoningEffort: String? = nil
    }

    struct AnthropicOptions: Equatable {
        var thinkingType: String? = nil
        var budgetTokens: Int? = nil
        var effort: String? = nil
    }

    static func responsesEffort(provider: ProviderProfile, model: ModelProfile) -> String? {
        let effort = model.effectiveReasoningEffort
        guard effort != .automatic, isOpenAIReasoningFamily(provider: provider, model: model) else {
            return nil
        }
        return openAIEffort(effort, modelID: model.remoteModelID)
    }

    static func requiresAssistantReasoningReplay(
        provider: ProviderProfile,
        model: ModelProfile
    ) -> Bool {
        isDeepSeek(provider: provider, model: model)
    }

    static func chatOptions(provider: ProviderProfile, model: ModelProfile) -> ChatOptions {
        let effort = model.effectiveReasoningEffort
        guard effort != .automatic else { return ChatOptions() }

        if isDeepSeek(provider: provider, model: model) {
            // DeepSeek V4 accepts only high/max. It intentionally aliases
            // low/medium to high for OpenAI-client compatibility.
            return ChatOptions(
                thinkingType: "enabled",
                reasoningEffort: effort == .maximum ? "max" : "high"
            )
        }
        if provider.kind == .volcengineArk {
            return ChatOptions(
                thinkingType: "enabled",
                reasoningEffort: effort == .maximum ? "high" : effort.rawValue
            )
        }
        if isOpenAIReasoningFamily(provider: provider, model: model) {
            return ChatOptions(
                reasoningEffort: openAIEffort(effort, modelID: model.remoteModelID)
            )
        }
        return ChatOptions()
    }

    static func anthropicOptions(provider: ProviderProfile, model: ModelProfile) -> AnthropicOptions {
        let effort = model.effectiveReasoningEffort
        guard effort != .automatic else { return AnthropicOptions() }

        if isDeepSeek(provider: provider, model: model) {
            return AnthropicOptions(
                effort: effort == .maximum ? "max" : "high"
            )
        }
        guard isAnthropicFamily(provider: provider, model: model) else {
            return AnthropicOptions()
        }

        if supportsAnthropicEffort(model.remoteModelID) {
            return AnthropicOptions(
                effort: anthropicEffort(effort, modelID: model.remoteModelID)
            )
        }
        return AnthropicOptions()
    }

    private static func isDeepSeek(provider: ProviderProfile, model: ModelProfile) -> Bool {
        provider.baseURL.host?.lowercased().contains("deepseek") == true
            || model.remoteModelID.lowercased().contains("deepseek")
    }

    private static func isOpenAIReasoningFamily(provider: ProviderProfile, model: ModelProfile) -> Bool {
        if provider.kind == .openAI || provider.baseURL.host?.lowercased().contains("openai.com") == true {
            return true
        }
        let id = model.remoteModelID.lowercased()
        return id.hasPrefix("gpt-5") || id.hasPrefix("o1") || id.hasPrefix("o3")
            || id.hasPrefix("o4") || id.contains("codex")
    }

    private static func isAnthropicFamily(provider: ProviderProfile, model: ModelProfile) -> Bool {
        provider.kind == .anthropic
            || provider.baseURL.host?.lowercased().contains("anthropic") == true
            || model.remoteModelID.lowercased().contains("claude")
    }

    private static func openAIEffort(_ effort: ModelReasoningEffort, modelID: String) -> String {
        guard effort == .maximum else { return effort.rawValue }
        let id = modelID.lowercased()
        if id.contains("pro") { return "high" }
        if id.contains("codex-max") || id.contains("gpt-5.2") || id.contains("gpt-5.3")
            || id.contains("gpt-5.4") || id.contains("gpt-5.5") || id.contains("gpt-5.6") {
            return "xhigh"
        }
        return "high"
    }

    private static func supportsAnthropicEffort(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        return id.contains("opus-4-5") || id.contains("opus-4.5")
            || id.contains("-4-6") || id.contains("-4.6")
            || id.contains("-4-7") || id.contains("-4.7")
            || id.contains("-4-8") || id.contains("-4.8")
            || id.range(of: #"claude-(?:sonnet|opus|fable|mythos)-5"#, options: .regularExpression) != nil
    }

    private static func anthropicEffort(_ effort: ModelReasoningEffort, modelID: String) -> String {
        guard effort == .maximum else { return effort.rawValue }
        let id = modelID.lowercased()
        if id.contains("haiku") { return "high" }
        return "max"
    }

}
