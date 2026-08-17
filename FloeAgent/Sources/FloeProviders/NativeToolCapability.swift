// FloeProviders — native structured-tool capability assessment.

import Foundation
import FloeCore
import FloeModels

/// Honest, user-presentable state for native structured tool calling.
///
/// `configured` means the model profile advertises tool support. Only an
/// explicit round-trip that returns a structured `AgentEvent.toolRequest`
/// upgrades the state to `verified`.
public enum NativeToolCapabilityStatus: Sendable, Equatable {
    case disabled
    case configured
    case probing
    case verified
    case inconclusive(String)
    case failed(String)
}

/// Merges a provider's latest model catalog without discarding capabilities.
/// Existing local identity, limits and user-facing names remain stable, while
/// provider-advertised capability bits repair records created by older clients.
public enum ModelCatalogMerger {
    public static func merge(
        existing: [ModelProfile],
        discovered: [ModelProfile]
    ) -> [ModelProfile] {
        var byRemoteID: [String: ModelProfile] = [:]
        for model in existing {
            byRemoteID[model.remoteModelID] = model
        }
        for var remote in discovered {
            remote.capabilities.insert(.text)
            if var local = byRemoteID[remote.remoteModelID] {
                local.capabilities.formUnion(remote.capabilities)
                local.isEnabled = local.isEnabled && remote.isEnabled
                byRemoteID[remote.remoteModelID] = local
            } else {
                byRemoteID[remote.remoteModelID] = remote
            }
        }
        return byRemoteID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

/// Explicit capability probe. It offers one inert function whose only input is
/// a nonce, then accepts *only* the provider adapter's structured tool event as
/// proof. Text that looks like a function call is deliberately ignored.
public enum NativeToolCapabilityProbe {
    public static let toolName = "floe_capability_probe"

    public static func initialStatus(for model: ModelProfile) -> NativeToolCapabilityStatus {
        model.capabilities.contains(.tools) ? .configured : .disabled
    }

    public static func run(
        adapter: any ProviderAdapter,
        provider: ProviderProfile,
        model: ModelProfile,
        credentials: ProviderCredentials
    ) async -> NativeToolCapabilityStatus {
        guard model.capabilities.contains(.tools) else { return .disabled }

        let nonce = UUID().uuidString
        let schema = #"{"type":"object","properties":{"nonce":{"type":"string"}},"required":["nonce"],"additionalProperties":false}"#
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [(
                role: "user",
                content: "Call floe_capability_probe exactly once with nonce \(nonce). Do not answer with text."
            )],
            toolSchemas: [ToolSchemaDescriptor(
                name: toolName,
                description: "Verifies native structured function calling. It performs no action.",
                parametersJSON: schema
            )]
        )

        do {
            for try await event in adapter.stream(request: request, credentials: credentials) {
                switch event {
                case .toolRequest(let call):
                    guard call.toolName == toolName,
                          let object = try? JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
                          object["nonce"] as? String == nonce else {
                        return .inconclusive("The provider returned a different structured tool call")
                    }
                    return .verified
                case .error(let error):
                    return .failed(SecretRedactor.redact(error.providerMessage))
                case .textDelta, .reasoningSummary, .toolResult, .usage, .completed:
                    // Pseudo calls in text are not evidence of native support.
                    continue
                }
            }
            return .inconclusive("The model completed without a native structured tool call")
        } catch {
            return .failed(SecretRedactor.redact(error.localizedDescription))
        }
    }
}
