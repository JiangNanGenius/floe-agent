// FloeApp — Production gateways for the frozen provider save runner.
//
// ProviderSaveRunner (FloeCore) owns the save ordering contract behind
// UIKit/Keychain/CloudKit-free protocols. This file wires the production
// implementations: KeychainSecretStore for credentials and ConversationCenter
// for the local bundle transaction and persisted readback.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeSync

/// Adapts `KeychainSecretStore` to the runner's credential gateway without a
/// retroactive cross-module conformance (explicit App-layer wiring).
struct KeychainSecretGateway: ProviderSecretSaving {
    let store: KeychainSecretStore

    init(store: KeychainSecretStore = KeychainSecretStore()) {
        self.store = store
    }

    func setSyncEnabled(_ enabled: Bool, for providerID: UUID) async throws {
        try await store.setSyncEnabled(enabled, for: providerID)
    }

    func storeSecret(_ secret: Data, scopeProviderID: UUID) async throws {
        try await store.storeSecret(secret, scope: .provider(scopeProviderID))
    }
}

/// Commits a frozen `ProviderSaveRequest` through ConversationCenter.
/// MainActor-bound because ConversationCenter is; the save runner (an actor)
/// hops here for the local transaction.
@MainActor
final class ConversationCenterProviderSaveGateway: ProviderBundleCommitting {
    private weak var center: ConversationCenter?

    init(center: ConversationCenter) {
        self.center = center
    }

    nonisolated func commitProviderBundle(
        _ request: ProviderSaveRequest
    ) async throws -> ProviderBundleCommitResult {
        guard let center = await MainActor.run(body: { self.center }) else {
            throw FloeError.internalError("Conversation center unavailable")
        }
        // Local commit and CloudKit enqueue are separated inside
        // ConversationCenter; a local success with a failed enqueue returns
        // syncPending/syncError instead of throwing, so the editor reports
        // "saved on this device" plus a retry rather than a false failure.
        return try await center.commitProviderBundle(
            provider: request.profile,
            models: request.selectedModels,
            managedCapabilities: request.managedCapabilities
        )
    }

    nonisolated func verifyProviderPersisted(
        _ request: ProviderSaveRequest
    ) async -> String? {
        guard let center = await MainActor.run(body: { self.center }) else {
            // Never report "verified" when verification could not run: a nil
            // return means the readback matched. An unavailable service is an
            // explicit, secret-free failure reason.
            return FloeL10n.isChinese
                ? "无法验证保存结果：会话服务不可用"
                : "The save could not be verified because the conversation service is unavailable"
        }
        return await center.verifyProviderPersisted(
            provider: request.profile,
            selectedModels: request.selectedModels
        )
    }
}
#endif
