// FloeApp — Destructive and audit-relevant settings actions.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §1.1/§9: every destructive action is a
// real deletion with a ClearReport count echo; nothing silently succeeds.
// The UI performs the second confirmation before calling these methods —
// the action layer is the single write path so counts are always truthful.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloePersistence
import FloeSecurity
import FloeSync

/// Executes settings actions that delete data or revoke access. Each method
/// returns a `ClearReport` so the caller can display exactly what changed.
@MainActor
final class SettingsActions {

    private let environment: AppEnvironment
    private let workspaceStore: any WorkspaceStore
    private let approvalGrants: ApprovalGrantStore

    init(
        environment: AppEnvironment,
        workspaceStore: any WorkspaceStore,
        approvalGrants: ApprovalGrantStore
    ) {
        self.environment = environment
        self.workspaceStore = workspaceStore
        self.approvalGrants = approvalGrants
    }

    // MARK: - 清除本地记录

    /// Deletes all conversations (cascades messages/parts/attachments),
    /// runs, run events, checkpoints and every persisted + in-memory grant.
    /// Returns per-category counts. The UI must collect explicit user
    /// confirmation before calling this.
    func clearLocalHistory() async throws -> ClearReport {
        var report = ClearReport()

        let deletion = try await environment.conversationCenter.deleteAllConversations()
        report.deletedConversations = deletion.conversations
        report.deletedRuns = deletion.runs

        let persistedGrants = try await workspaceStore.allGrants()
        for grant in persistedGrants {
            try await workspaceStore.deleteGrant(id: grant.id)
        }
        report.deletedGrants = persistedGrants.count

        let memoryGrants = await approvalGrants.allGrants
        for grant in memoryGrants {
            await approvalGrants.revoke(id: grant.id)
        }
        report.deletedGrants += memoryGrants.count

        return report
    }

    // MARK: - 清除模型配置

    /// Deletes every provider and model and resets routing preferences,
    /// then removes the matching Keychain API keys. Counts both the DB rows
    /// and the Keychain items removed.
    func clearModelConfiguration() async throws -> ClearReport {
        var report = ClearReport()

        let providers = try await environment.configurationStore.providers()
        let secretStore = KeychainSecretStore()

        for provider in providers {
            // Enqueue provider/model tombstones so a later CloudKit fetch
            // cannot resurrect configuration the user explicitly cleared.
            try await environment.configurationSync.deleteProvider(id: provider.id)
            // Delete both synchronized and local Keychain namespaces. The
            // global sync switch may have migrated the secret without
            // changing the provider's historical SecretReference metadata.
            if provider.secretRef != nil {
                do {
                    try await secretStore.deleteSecret(scope: .provider(provider.id))
                    report.deletedKeychainItems += 1
                } catch {
                    // Item already absent — still counts as removed state.
                }
            }
        }

        try await environment.configurationStore.savePreferences(ModelSelectionPreferences())

        return report
    }

    // MARK: - 撤销授权

    /// Revokes one grant in both layers (DB + memory). No-op when absent.
    func revokeGrant(id: UUID) async {
        try? await workspaceStore.deleteGrant(id: id)
        await approvalGrants.revoke(id: id)
    }
}
#endif
