// FloeApp — Provider list view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Presentation state for the provider list under More. Reads providers and
// models through ConversationCenter; never touches the Keychain directly
// (secret state is derived per-provider via KeychainSecretStore.status).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeProviders
import FloeSync
import FloeSyncCore

/// View model for the provider list.
@MainActor
final class ProviderListViewModel: ObservableObject {

    @Published private(set) var isLoading = false
    /// Per-provider secret sync status (e.g. `.waitingForSecret`).
    @Published private(set) var secretStatus: [UUID: SyncStatus] = [:]
    @Published var errorMessage: String?
    /// Count of remote configuration records rejected by the sync engine's
    /// canonical gate. Non-zero means the last batch was an honest partial
    /// failure: the local configuration was kept and the rejected remote
    /// updates were skipped (never persisted, never acknowledged here).
    @Published private(set) var remoteSyncRejectionCount = 0
    @Published private(set) var isRetryingRemoteSync = false

    let center: ConversationCenter
    private let secretStore = KeychainSecretStore()

    init(center: ConversationCenter) {
        self.center = center
    }

    var providers: [ProviderProfile] {
        center.configuredProviders.filter { provider in
            guard provider.kind != .local else { return false }
            let models = center.configuredModelsByProvider[provider.id] ?? []
            // Keep empty providers visible while they are being configured,
            // but route dedicated media-only endpoints to their own section.
            return models.isEmpty || models.contains(where: \.supportsChatAgentSurface)
        }
    }

    var imageProviders: [ProviderProfile] {
        center.configuredProviders.filter { provider in
            guard provider.kind != .local else { return false }
            let models = center.configuredModelsByProvider[provider.id] ?? []
            return models.contains {
                $0.supportsImageGenerationSurface
            }
        }
    }

    var videoProviders: [ProviderProfile] {
        center.configuredProviders.filter { provider in
            guard provider.kind != .local else { return false }
            return center.configuredModelsByProvider[provider.id]?.contains {
                $0.supportsVideoGenerationSurface
            } == true
        }
    }

    func imageModelCount(for providerID: UUID) -> Int {
        center.configuredModelsByProvider[providerID]?
            .filter {
                $0.supportsImageGenerationSurface
            }.count ?? 0
    }

    func videoModelCount(for providerID: UUID) -> Int {
        center.configuredModelsByProvider[providerID]?
            .filter(\.supportsVideoGenerationSurface).count ?? 0
    }

    func modelCount(for providerID: UUID) -> Int {
        center.configuredModelsByProvider[providerID]?
            .filter(\.supportsChatAgentSurface).count ?? 0
    }

    /// Saved models whose verified catalog metadata adds capabilities. The
    /// list is a REVIEW diff only: nothing changes until the user applies it
    /// (explicit overrides are excluded from the proposals).
    func capabilityProposals(catalog: ProviderCatalogIndex?) -> [ProviderCatalogCapabilityProposal] {
        ProviderCatalogCapabilityMigration.proposals(
            providers: center.configuredProviders,
            modelsByProvider: center.configuredModelsByProvider,
            catalog: catalog
        )
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await center.reload()
        await refreshSecretStatus()
        await refreshRemoteSyncOutcome()
    }

    /// Reads the sync engine's rejected-record set (never persisted, never a
    /// remote write) so the list can state the honest partial-failure state.
    func refreshRemoteSyncOutcome() async {
        remoteSyncRejectionCount = await center.environment.configurationSync
            .rejectedRemoteRecordIDs.count
    }

    /// Retries the rejected remote batch through the existing serialized
    /// sync path (no new store, no forced remote write). A corrected remote
    /// payload clears the rejection; a still-invalid one keeps it visible.
    func retryRejectedRemoteSync() async {
        guard !isRetryingRemoteSync else { return }
        isRetryingRemoteSync = true
        defer { isRetryingRemoteSync = false }
        await center.environment.settingsCenter.synchronizeConfiguration()
        await refreshRemoteSyncOutcome()
    }

    /// Derives each provider's secret sync status honestly.
    private func refreshSecretStatus() async {
        var map: [UUID: SyncStatus] = [:]
        for provider in center.configuredProviders {
            let hasSecret = provider.secretRef != nil
            map[provider.id] = await secretStore.status(
                for: provider.id,
                hasConfiguration: hasSecret
            )
        }
        secretStatus = map
    }

    func status(for providerID: UUID) -> SyncStatus {
        secretStatus[providerID] ?? .synced
    }

    /// Provider-level routing switch exposed directly in the settings list.
    /// The endpoint, Keychain reference and per-model switches remain intact
    /// while every runtime picker hides the provider immediately after save.
    func setEnabled(_ enabled: Bool, provider: ProviderProfile) async {
        var updated = provider
        updated.isEnabled = enabled
        updated.updatedAt = Date()
        do {
            try await center.saveProvider(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
        await load()
    }

    func delete(_ provider: ProviderProfile) async {
        do {
            // Remove the secret first. If metadata deletion then fails, the
            // provider remains visible in an honest waiting-for-secret state
            // instead of leaving an unreachable Keychain/iCloud credential.
            try await secretStore.deleteSecret(scope: .provider(provider.id))
            try await center.deleteProvider(id: provider.id)
            // The declined-offer memory belongs to the provider identity.
            // Clearing it on delete keeps a later add under the same UUID
            // (or a restored backup) from silently starting pre-declined.
            ProviderServiceOfferPromptStore.shared.clear(for: provider.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        await load()
    }
}
#endif
