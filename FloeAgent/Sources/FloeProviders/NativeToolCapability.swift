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
/// Existing local identity, limits and user-facing names remain stable.
///
/// Two enforcement rules, not comments:
///
///   1. **No silent vision migration.** An existing row (with or without
///      provenance) may only be repaired with the legacy endpoint-reported
///      bits in `legacyRepairableCapabilities` ([.text, .tools]). `.vision`
///      decides which model sees the user's images, so it reaches an existing
///      row only through the user-reviewed catalog migration — even when a
///      catalog-backed discovery payload starts carrying it for new models.
///   2. **Explicit decisions win.** A bit recorded in
///      `ModelProfile.explicitCapabilities` (an editor toggle, or a bit applied
///      through the reviewed migration) is never added or re-enabled by a
///      refresh, and never removed by it either.
///
/// New rows (no local counterpart) are returned as discovered, so metadata-
/// driven defaults for freshly created models are unaffected.
public enum ModelCatalogMerger {

    /// Capability bits a discovery refresh may union into an existing row that
    /// has no recorded provenance. Deliberately excludes `.vision`.
    public static let legacyRepairableCapabilities: ModelCapabilities = [.text, .tools]

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
                let repairable = remote.capabilities
                    .intersection(Self.legacyRepairableCapabilities)
                    .subtracting(local.explicitCapabilities ?? [])
                local.capabilities.formUnion(repairable)
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
