// FloeApp — DEBUG-only temporary-chat UI qualification fixture.
//
// SPDX-License-Identifier: MPL-2.0
//
// Seeds ONE clearly synthetic SAVED conversation (fixed identity, two fixed
// synthetic messages) so the GUI acceptance can exercise the REAL temporary
// chat paths without any paid model request: populated-chat toggle → separate
// session, explicit End / Keep with seeded in-RAM messages, original history
// intact, route-leave discard. The optional preset-session mode starts the
// separate session through the REAL ConversationCenter toggle API and appends
// two in-RAM messages through the session stores, then navigates to it.
// Nothing here deletes user history, fakes a route, or completes a model
// request; every identity is a fixed synthetic UUID.
//
// Gated on `-ui-testing` + explicit launch arguments, simulator only.
#if DEBUG
import Foundation
import FloeCore
import FloeModels
import FloePersistence

@MainActor
enum TemporaryChatUITestFixture {
    static let launchArgument = "--ui-test-temporary-chat-fixture"
    /// Also start + navigate to a separate temporary session with two
    /// synthetic in-RAM messages (End/Keep acceptance).
    static let presetSessionArgument = "--ui-test-temporary-chat-preset-session"

    /// Fixed synthetic identities — namespaced, idempotent, never user data.
    static let savedConversationID = UUID(uuidString: "7A1E22C4-3B0F-4A5D-9E62-1C8F3D5B7A21")!
    static let savedTitle = "临时会话合成任务"
    static let savedMessage = "合成历史消息"
    static let tempUserMessage = "合成临时提问"
    static let tempAssistantMessage = "合成临时回答"

    /// Seeds the durable saved conversation once (real store, synthetic rows).
    static func seedIfRequested(environment: AppEnvironment) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(launchArgument) else { return }
        #if targetEnvironment(simulator)
        let historical = arguments.contains("--ui-test-history-date-copy")
        let id = historical ? UUID(uuidString: "9289330B-91EB-4617-81B2-ABA312B98801")! : savedConversationID
        let title = historical ? "历史日期与复制测试" : savedTitle
        let firstSentAt = historical ? Date(timeIntervalSince1970: 1_658_232_000) : Date()
        if (try? await environment.conversationStore.conversation(id: id)) == nil {
            try? await environment.conversationStore.saveConversation(ConversationRecord(
                id: id,
                title: title,
                createdAt: firstSentAt,
                updatedAt: Date()
            ))
        }
        let existing = (try? await environment.conversationStore
            .messages(conversationID: id)) ?? []
        if existing.isEmpty {
            for (index, role) in ["user", "assistant"].enumerated() {
                let text = historical && role == "user" ? "第一行  \n第二行" : "\(savedMessage)-\(index)"
                try? await environment.conversationStore.appendMessage(PersistedMessage(
                    id: UUID(),
                    conversationID: id,
                    role: role,
                    content: text,
                    createdAt: firstSentAt.addingTimeInterval(TimeInterval(index))
                ))
            }
        }
        // This is an ordinary saved chat, so use the same canonical ownership
        // as real history. Never create a workspace for the RAM-only preset.
        _ = try? await SQLiteWorkspaceStore(database: environment.database)
            .ensureWorkspace(conversationID: id, title: title)
        await environment.workspaceCenter.reload()
        await environment.conversationCenter.reload()
        #endif
    }

    /// Starts a separate temporary session from the synthetic saved chat via
    /// the REAL center toggle, seeds two in-RAM messages and navigates. Pure
    /// RAM content: nothing durable, no provider request.
    static func presetSessionIfRequested(router: AppRouter, center: ConversationCenter) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(presetSessionArgument) else { return }
        #if targetEnvironment(simulator)
        guard center.temporarySession == nil else { return }
        let outcome = try? await center.toggleTemporaryChat(for: savedConversationID)
        guard case .temporaryActive(let tempID) = outcome,
              let session = center.temporarySession else { return }
        try? await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: tempID, role: "user",
            content: tempUserMessage, createdAt: Date()
        ))
        try? await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: tempID, role: "assistant",
            content: tempAssistantMessage, createdAt: Date().addingTimeInterval(1)
        ))
        router.openConversation(tempID)
        #endif
    }
}
#endif
