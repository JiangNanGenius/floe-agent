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
        var enableThinking: Bool? = nil
    }

    struct AnthropicOptions: Equatable {
        var thinkingType: String? = nil
        var budgetTokens: Int? = nil
        var effort: String? = nil
    }

    static func responsesEffort(
        provider: ProviderProfile,
        model: ModelProfile,
        policy: ProviderReasoningPolicy = .modelDefault
    ) -> String? {
        if policy == .disabled {
            if provider.kind == .alibabaStudio || isDashScope(provider) { return "none" }
            if isOpenAIReasoningFamily(provider: provider, model: model) {
                return supportsOpenAINone(model.remoteModelID) ? "none" : nil
            }
            return nil
        }
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

    static func chatOptions(
        provider: ProviderProfile,
        model: ModelProfile,
        policy: ProviderReasoningPolicy = .modelDefault
    ) -> ChatOptions {
        if policy == .disabled {
            if provider.kind == .alibabaStudio || isDashScope(provider) {
                return ChatOptions(enableThinking: false)
            }
            if provider.kind == .volcengineArk || isDeepSeek(provider: provider, model: model) {
                return ChatOptions(thinkingType: "disabled")
            }
            if isOpenAIReasoningFamily(provider: provider, model: model),
               supportsOpenAINone(model.remoteModelID) {
                return ChatOptions(reasoningEffort: "none")
            }
            return ChatOptions()
        }
        let effort = model.effectiveReasoningEffort
        guard effort != .automatic else { return ChatOptions() }

        if isDeepSeek(provider: provider, model: model) {
            // Official chat contract (api-docs.deepseek.com/api/create-chat-completion):
            // reasoning_effort accepts none/low/high/max. `minimal` is accepted
            // as a compatibility alias for low and `medium`/`xhigh` are
            // accepted and mapped to high. There is no native medium tier, so
            // .medium intentionally becomes "high" rather than claiming a
            // native medium value. .low must never silently become high.
            return ChatOptions(
                thinkingType: "enabled",
                reasoningEffort: deepSeekEffort(effort)
            )
        }
        if provider.kind == .volcengineArk {
            return ChatOptions(
                thinkingType: "enabled",
                reasoningEffort: effort == .maximum ? "high" : effort.rawValue
            )
        }
        if provider.kind == .alibabaStudio || isDashScope(provider) {
            return ChatOptions(reasoningEffort: effort == .maximum ? "max" : effort.rawValue)
        }
        if isOpenAIReasoningFamily(provider: provider, model: model) {
            return ChatOptions(
                reasoningEffort: openAIEffort(effort, modelID: model.remoteModelID)
            )
        }
        return ChatOptions()
    }

    static func responsesThinkingType(
        provider: ProviderProfile,
        model: ModelProfile,
        policy: ProviderReasoningPolicy = .modelDefault
    ) -> String? {
        guard policy == .disabled else { return nil }
        if provider.kind == .volcengineArk || isDeepSeek(provider: provider, model: model) {
            return "disabled"
        }
        return nil
    }

    static func anthropicOptions(provider: ProviderProfile, model: ModelProfile) -> AnthropicOptions {
        let effort = model.effectiveReasoningEffort
        guard effort != .automatic else { return AnthropicOptions() }

        if isDeepSeek(provider: provider, model: model) {
            // DeepSeek's Anthropic-compatible endpoint documents support for
            // `output_config.effort` (api-docs.deepseek.com/guides/anthropic_api).
            // It does not enumerate the value set separately from the chat
            // contract, and it is the same backend, so apply the documented
            // reasoning_effort mapping: low/high/max native, medium is the
            // accepted compatibility alias that lands as high.
            return AnthropicOptions(effort: deepSeekEffort(effort))
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
        provider.traits(model: model).isDeepSeek
    }

    /// DeepSeek's documented effort contract. There is no native `medium`
    /// value: the endpoint accepts it as a compatibility alias and maps it to
    /// `high`, so Floe sends the value the endpoint will actually use rather
    /// than implying a distinct tier.
    private static func deepSeekEffort(_ effort: ModelReasoningEffort) -> String {
        switch effort {
        case .low: return "low"
        case .medium, .high: return "high"
        case .maximum: return "max"
        case .automatic: return "high"
        }
    }

    private static func isDashScope(_ provider: ProviderProfile) -> Bool {
        provider.traits().isDashScope
    }

    private static func supportsOpenAINone(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        return id.hasPrefix("gpt-5.1") || id.hasPrefix("gpt-5.2")
            || id.hasPrefix("gpt-5.3") || id.hasPrefix("gpt-5.4")
            || id.hasPrefix("gpt-5.5") || id.hasPrefix("gpt-5.6")
    }

    private static func isOpenAIReasoningFamily(provider: ProviderProfile, model: ModelProfile) -> Bool {
        provider.traits(model: model).isOpenAIReasoningFamily
    }

    private static func isAnthropicFamily(provider: ProviderProfile, model: ModelProfile) -> Bool {
        provider.traits(model: model).isAnthropicFamily
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

    // MARK: - Automatic effort decision support

    /// True when the selected wire protocol would actually transmit an effort
    /// value for this provider/model family. The probe uses the same mapping
    /// the adapters use, so families whose fields are all omitted (unknown
    /// custom endpoints, media endpoints, on-device engines) report false and
    /// keep today's "automatic" behavior without an extra request.
    static func supportsVariableReasoningEffort(
        provider: ProviderProfile,
        model: ModelProfile
    ) -> Bool {
        guard provider.kind != .local else { return false }
        var probe = model
        probe.reasoningEffort = .high
        switch provider.wireProtocol {
        case .openAIResponses:
            return responsesEffort(provider: provider, model: probe) != nil
        case .openAIChatCompletions:
            let options = chatOptions(provider: provider, model: probe)
            return options.reasoningEffort != nil
                || options.thinkingType != nil
                || options.enableThinking != nil
        case .anthropicMessages:
            let options = anthropicOptions(provider: provider, model: probe)
            return options.effort != nil || options.thinkingType != nil
        }
    }

    /// Freezes the level whose wire value the endpoint will actually use.
    /// Mirrors `chatOptions` precedence (DeepSeek, Ark, DashScope, OpenAI
    /// family, Anthropic family) so a stored decision never claims a tier the
    /// endpoint does not have.
    static func clampAutomaticReasoningEffort(
        _ effort: ModelReasoningEffort,
        provider: ProviderProfile,
        model: ModelProfile
    ) -> ModelReasoningEffort {
        let traits = provider.traits(model: model)
        if traits.isDeepSeek {
            // No native medium tier: `medium` is only a compatibility alias
            // that lands as `high`.
            return effort == .medium ? .high : effort
        }
        if provider.kind == .volcengineArk {
            // `maximum` is sent as `high`.
            return effort == .maximum ? .high : effort
        }
        if provider.kind == .alibabaStudio || traits.isDashScope {
            return effort
        }
        if traits.isOpenAIReasoningFamily {
            // `maximum` is only a distinct xhigh tier where the model
            // actually accepts it; otherwise it is sent as `high`.
            if effort == .maximum,
               openAIEffort(effort, modelID: model.remoteModelID) != "xhigh" {
                return .high
            }
            return effort
        }
        if traits.isAnthropicFamily, supportsAnthropicEffort(model.remoteModelID) {
            if effort == .maximum,
               anthropicEffort(effort, modelID: model.remoteModelID) != "max" {
                return .high
            }
            return effort
        }
        return effort
    }

    /// The exact effort token the selected protocol transmits for this model,
    /// or nil when the mapping omits every reasoning field. Policy-independent:
    /// ordinary runs use `.modelDefault`.
    static func wireEffortValue(provider: ProviderProfile, model: ModelProfile) -> String? {
        guard model.effectiveReasoningEffort != .automatic else { return nil }
        switch provider.wireProtocol {
        case .openAIResponses:
            return responsesEffort(provider: provider, model: model)
        case .openAIChatCompletions:
            let options = chatOptions(provider: provider, model: model)
            return options.reasoningEffort ?? options.thinkingType
        case .anthropicMessages:
            return anthropicOptions(provider: provider, model: model).effort
        }
    }

}
