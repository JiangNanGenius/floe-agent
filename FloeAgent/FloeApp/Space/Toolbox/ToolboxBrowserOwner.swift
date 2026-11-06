// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloePersistence

@MainActor final class ToolboxBrowserOwner {
    private weak var environment: AppEnvironment?
    private var conversationID: UUID?
    private var previousVisibleID: UUID?
    private var pending: Task<UUID, Error>?
    init(environment: AppEnvironment) { self.environment = environment }
    func owner() async throws -> UUID {
        if let pending { return try await pending.value }
        let pending = Task { try await prepare() }; self.pending = pending
        defer { self.pending = nil }
        return try await pending.value
    }
    private func prepare() async throws -> UUID {
        guard let environment else { throw PersonalContentError.storageUnavailable }
        try await environment.ensureDurableAutomationReady()
        let id = conversationID ?? UUID(), now = Date()
        if try await environment.conversationStore.conversation(id: id) == nil {
            try await environment.conversationStore.saveConversation(.init(id: id,
                title: IDELanguageRunText.t("工具箱浏览器", "Toolbox browser"), createdAt: now, updatedAt: now, titleOrigin: .manual))
        }
        _ = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id,
            title: IDELanguageRunText.t("工具箱浏览器", "Toolbox browser"))
        try await environment.conversationStore.setArchived(id: id, archived: true)
        await environment.conversationCenter.authoringConversationBecameVisible(id)
        conversationID = id
        if environment.browserCenter.conversationID != id { previousVisibleID = environment.browserCenter.conversationID }
        return id
    }
    func leave() {
        if let environment, environment.browserCenter.conversationID == conversationID {
            environment.browserCenter.bind(to: previousVisibleID)
        }
    }
}
#endif
