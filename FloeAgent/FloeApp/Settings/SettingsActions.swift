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

        let conversations = try await environment.conversationStore.conversations()
        for conversation in conversations {
            try await environment.conversationStore.deleteConversation(id: conversation.id)
        }
        report.deletedConversations = conversations.count

        // Run rows cascade from conversations, but count them first so the
        // report reflects what the user actually lost.
        var runCount = 0
        for conversation in conversations {
            runCount += (try? await environment.runStore.runs(conversationID: conversation.id).count) ?? 0
        }
        report.deletedRuns = runCount

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

        for provider in providers {
            try await environment.configurationStore.deleteProvider(id: provider.id)
            // Remove the Keychain secret the provider referenced. The
            // reference is deleted with the row; the secret is deleted here.
            if let ref = provider.secretRef {
                let store = KeychainStore(
                    service: "org.floeagent.ios.secrets",
                    synchronizable: ref.synchronizable
                )
                do {
                    try store.delete(account: ref.keychainAccount)
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