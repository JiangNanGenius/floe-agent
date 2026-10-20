// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — cross-domain port adapters (ordinary base).
//
// These adapters compose the ACTUAL delivered domain types; they reimplement
// no domain algorithm. Each one is a thin, honest seam:
//   * fail-closed run environment/job ownership proof (no G03 environment
//     is invented in G02);
//   * models-lane route port for personalization generate (real configured
//     text model; honest noUsableTextModel/credentialUnavailable/
//     transportUnqualified outcomes);
//   * personalization event fences bound to the live generation (the
//     temporary-conversation question is answered by the optional-domain
//     extension seam — false while no temporary extension is attached, which
//     is the truth for the ordinary product);
//   * RB4 staged image loading over the REAL staging service;
//   * conversation deletion credential drain over the joined vault.
//
// The vault normalizer port is the Run-QUALIFIED
// `RunCredentialArgumentNormalizerAdapter` (RuntimeFacadeRunAssembly.swift)
// bound directly at the run-components construction site — this file does
// not wrap it. The P8 post-commit feed is the Run-qualified
// `RunPersonalizationFeedBinder` — the rejected detached
// G02IntelligenceFeedBridge is gone. Privacy ports (global fence, secret
// ordering, host confirmation, event drop) move with the privacy extension
// successor through the G02DomainExtension seam.
import Foundation
import GRDB
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
import FloeModels
import FloeProviders

// MARK: - RB4 environment/job ownership proof (fail-closed until G03)

/// `run.queue`/`run.steer` may carry optional environment/job roles. G02
/// ships no execution environments and no G03 guests: every proof answers
/// false and the run domain refuses the role with its typed
/// `unsupportedRole` — never a manufactured admission.
public struct G02NoEnvironmentOwnership: RunEnvironmentOwnershipProving {
    public init() {}

    public func proveEnvironment(_ environmentID: String,
                                 conversationID: UUID,
                                 epoch: UInt64) async -> Bool {
        false
    }

    public func proveJob(_ jobID: String,
                         runID: UUID,
                         epoch: UInt64) async -> Bool {
        false
    }
}

// MARK: - Models route port for personalization generate

/// Resolves the ACTUAL general-auxiliary text route from the shared model
/// configuration store, mirroring the original `generalAuxiliary` semantics:
/// `preferences.generalAuxiliaryLLMModelID ?? defaultAgentModelID`, the
/// model must be enabled and `supportsGeneralAuxiliaryLLM`, the provider
/// must be enabled and non-local, and the typed credential must resolve
/// BEFORE any network dispatch. No unpublished memory type is required and
/// no stubbed route is invented: every outcome is a frozen
/// `PersonalizationRouteOutcome` case.
public struct G02PersonalizationRouteProvider: PersonalizationRouteProviding {
    private let configurationStore: ModelConfigurationStore
    private let credentials: RunCredentialResolver

    public init(configurationStore: ModelConfigurationStore,
                credentials: RunCredentialResolver) {
        self.configurationStore = configurationStore
        self.credentials = credentials
    }

    public func textOnlyRoute() async -> PersonalizationRouteOutcome {
        // Transport admission is the qualified gate (closed until Main's
        // transport+TLS qualification passes): fail closed honestly.
        guard G02RuntimeComposition.shared.transportGate.admitsCloudNetwork else {
            return .transportUnqualified
        }
        do {
            let preferences = try await configurationStore.preferences()
            guard let modelID = preferences.generalAuxiliaryLLMModelID
                    ?? preferences.defaultAgentModelID,
                  let model = try await configurationStore.model(id: modelID),
                  model.supportsGeneralAuxiliaryLLM else {
                return .noUsableTextModel
            }
            guard let provider = try await configurationStore.provider(id: model.providerID),
                  provider.isEnabled else {
                return .noUsableTextModel
            }
            // G02: no local inference (AGENTS execution invariant).
            if provider.kind == .local {
                return .noUsableTextModel
            }
            switch await credentials.resolve(provider: provider) {
            case .resolved, .explicitNoAuth:
                break
            case .gatewayUnregistered:
                return .credentialUnavailable("gatewayUnregistered")
            case .secretMissing:
                return .credentialUnavailable("secretMissing")
            case .secretInvalidated:
                return .credentialUnavailable("secretInvalidated")
            }
            let credentialValue: ProviderCredentials
            do {
                credentialValue = try await credentials.credentials(for: provider)
            } catch {
                return .credentialUnavailable("secretMissing")
            }
            let adapter = OriginalProviderAdapterFactory().adapter(for: provider)
            return .resolved(PersonalizationGenerateModelInput(
                provider: provider,
                model: model,
                credentials: credentialValue,
                adapter: adapter))
        } catch {
            return .noUsableTextModel
        }
    }
}

// MARK: - Personalization event fences bound to the live generation

/// The P8 handlers ask three fence questions before touching memory; all
/// answers come from the CURRENT accepted generation state, never from
/// mutable UI state. The temporary-conversation question is answered by
/// the optional-domain extension seam: while no temporary extension is
/// attached (the ordinary product) every conversation is an ordinary one
/// — `false` is the truth, never a fabricated temporary flag.
public struct G02PersonalizationFenceProvider: PersonalizationEventFenceProviding {
    public init() {}

    public func currentRootEpoch() async -> UInt64 {
        AndroidRuntimeBootstrap.currentPumps()?.epoch ?? 0
    }

    public func isTemporaryConversation(_ conversationID: UUID) async -> Bool {
        // Only a bound temporary extension can claim a conversation is
        // temporary; the extension owns that authority when it attaches.
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              let temporary = installed.attachedExtensions[G02DomainExtensionKey.temporary]
        else {
            return false
        }
        return await temporary.isTemporaryConversation(conversationID,
                                                       epoch: installed.epoch)
    }

    public func isDeletionOrHistoryClearPending(_ conversationID: UUID) async -> Bool {
        await G02RuntimeComposition.shared.isDeletionOrHistoryClearPending(conversationID)
    }
}

// MARK: - RB4 staged image loading over the REAL staging service

/// Loads staged inline images through the canonical staging owner (job 0f);
/// the composition never invents an alternate image path.
public struct G02StagedImageLoader: RunStagedImageLoading {
    private let staging: AttachmentStagingService

    public init(staging: AttachmentStagingService) {
        self.staging = staging
    }

    public func imagePart(for lease: RunAttachmentLease,
                          maxBytes: Int) async throws -> ConversationImagePart {
        guard let part = staging.loadStagedInlineImage(handle: lease.handle,
                                                       remainingBudget: maxBytes) else {
            throw RunStagingError.handleUnknown
        }
        return part
    }
}

/// Conversation deletion drain over the joined vault (durable V11 queue).
public struct G02VaultCredentialDrain: ConversationCredentialDeletionDraining {
    private let vault: AndroidCredentialVault

    public init(vault: AndroidCredentialVault) {
        self.vault = vault
    }

    public func drainDeletionQueue() async -> CredentialDeletionDrainSummary {
        let report = await vault.drainDeletionQueue()
        return CredentialDeletionDrainSummary(
            drained: report.completed,
            deferredCount: report.remaining,
            failedCount: report.failed)
    }
}
