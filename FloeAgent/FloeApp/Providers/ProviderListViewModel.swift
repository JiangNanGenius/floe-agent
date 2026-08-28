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
import FloeSync
import FloeSyncCore

/// View model for the provider list.
@MainActor
final class ProviderListViewModel: ObservableObject {

    @Published private(set) var isLoading = false
    /// Per-provider secret sync status (e.g. `.waitingForSecret`).
    @Published private(set) var secretStatus: [UUID: SyncStatus] = [:]
    @Published var errorMessage: String?

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
            return models.isEmpty || models.contains { $0.capabilities.contains(.text) }
        }
    }

    var imageProviders: [ProviderProfile] {
        center.configuredProviders.filter { provider in
            guard provider.kind != .local else { return false }
            let models = center.configuredModelsByProvider[provider.id] ?? []
            return models.contains {
                $0.capabilities.contains(.imageGeneration)
                    || $0.capabilities.contains(.imageEditing)
            }
        }
    }

    var videoProviders: [ProviderProfile] {
        center.configuredProviders.filter { provider in
            guard provider.kind != .local else { return false }
            return center.configuredModelsByProvider[provider.id]?.contains {
                $0.capabilities.contains(.videoGeneration)
            } == true
        }
    }

    func imageModelCount(for providerID: UUID) -> Int {
        center.configuredModelsByProvider[providerID]?
            .filter {
                $0.capabilities.contains(.imageGeneration)
                    || $0.capabilities.contains(.imageEditing)
            }.count ?? 0
    }

    func videoModelCount(for providerID: UUID) -> Int {
        center.configuredModelsByProvider[providerID]?
            .filter { $0.capabilities.contains(.videoGeneration) }.count ?? 0
    }

    func modelCount(for providerID: UUID) -> Int {
        center.configuredModelsByProvider[providerID]?
            .filter { $0.capabilities.contains(.text) }.count ?? 0
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await center.reload()
        await refreshSecretStatus()
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
        } catch {
            errorMessage = error.localizedDescription
        }
        await load()
    }
}
#endif
