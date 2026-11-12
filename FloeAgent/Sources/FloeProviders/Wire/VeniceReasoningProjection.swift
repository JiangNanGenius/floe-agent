// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Venice's documented Chat dialect, never a model-name/provider-name guess.
/// No supplier/model catalog entries or account state are registered here.
enum VeniceReasoningProjection {
    static func matches(_ provider: ProviderProfile) -> Bool {
        provider.wireProtocol == .openAIChatCompletions && matchesEndpoint(provider)
    }

    static func matchesEndpoint(_ provider: ProviderProfile) -> Bool {
        let url = provider.baseURL
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.venice.ai",
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil else { return false }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return path == "/api/v1"
    }

    static func effortOptions(_ model: ModelProfile) -> [String]? {
        guard !model.effectiveOmitReasoningParameters,
              let metadata = model.reasoningMetadata,
              metadata.supportsReasoning != false,
              metadata.supportsReasoningEffort == true else { return nil }
        return metadata.supportedEfforts
    }

    static func canDisable(_ model: ModelProfile) -> Bool {
        !model.effectiveOmitReasoningParameters
            && model.reasoningMetadata?.supportsReasoning != false
            && model.reasoningMetadata?.canDisableThinking == true
    }

    static func controls(model: ModelProfile, policy: ProviderReasoningPolicy) -> ChatRequest.Reasoning? {
        guard !model.effectiveOmitReasoningParameters else { return nil }
        if policy == .disabled {
            // A token called 'none' is not proof this model can stop thinking.
            return canDisable(model) ? .init(enabled: false) : nil
        }
        guard let effort = ReasoningEffortProjection.token(for: model.effectiveReasoningEffort,
            options: effortOptions(model)) else { return nil }
        return .init(enabled: true, effort: effort)
    }
}
