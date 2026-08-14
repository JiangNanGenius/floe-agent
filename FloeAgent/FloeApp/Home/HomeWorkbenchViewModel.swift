// FloeApp — Chat-first home view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Presentation state for ChatHomeView: recent threads (conversations),
// the composer draft/model/project/target/mode selection, and pending
// approvals surfaced as a compact badge. Sending creates a conversation
// and returns its ID so the view can navigate straight into the thread
// (Chat-first: no intermediate workbench step). Holds only presentation
// state; all work goes through ConversationCenter and the stores.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence

/// View model for the Chat-first home screen.
@MainActor
final class ChatHomeViewModel: ObservableObject {

    // MARK: - Published presentation state

    /// Recent conversations, newest first (the "最近线程" list).
    @Published private(set) var recentConversations: [ConversationRecord] = []
    /// Latest run state per conversation ID (drives row status pills).
    @Published private(set) var latestRunStates: [UUID: String] = [:]
    /// Whether a load is in flight.
    @Published private(set) var isLoading = false
    /// Honest error surface for the last failed action.
    @Published private(set) var actionError: String?

    /// Composer draft text.
    @Published var draft: String = ""
    /// Per-composer model override; nil resolves to the global default.
    @Published var selectedModelID: UUID?
    /// Workspace project selection (placeholder until T05 wires the real
    /// WorkspaceCenter list).
    @Published var selectedProjectID: UUID?
    /// Where the next run executes (local only until host tools land).
    @Published var executionTarget: AgentExecutionTarget = .local
    /// How the next run behaves (agent vs chat-only).
    @Published var agentMode: AgentExecutionMode = .agent
    /// Attachments staged in the composer.
    @Published var attachments: [AttachmentRef] = []
    /// Whether the composer is mid-send (guards double-tap).
    @Published private(set) var isSending = false

    let center: ConversationCenter
    let environment: AppEnvironment

    init(center: ConversationCenter) {
        self.center = center
        self.environment = center.environment
    }

    /// Pending approvals, straight from the center (badge source).
    var pendingApprovals: [PendingApproval] {
        center.pendingApprovals
    }

    /// True when at least one provider+model is configured. The app is
    /// fully usable without one; only AI send is gated.
    var hasConfiguredProvider: Bool {
        center.hasConfiguredProvider
    }

    /// The provider/model the composer will use for a new task.
    var activeModelName: String? {
        center.providerAndModel(modelID: selectedModelID)?.1.displayName
    }

    var availableModels: [ModelProfile] { center.availableAgentModels }

    /// Placeholder project list — empty until T05's WorkspaceCenter
    /// provides real workspaces; the picker renders "无项目" honestly.
    var availableProjects: [ComposerProject] { [] }

    /// Whether the composer may send.
    var canSend: Bool {
        center.providerAndModel(modelID: selectedModelID) != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending
    }

    // MARK: - Loading

    /// Reloads conversations and per-conversation latest run states.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        await center.reload()
        if selectedModelID == nil { selectedModelID = center.modelPreferences.defaultAgentModelID }
        recentConversations = center.conversations
        var states: [UUID: String] = [:]
        for conversation in center.conversations {
            let runs = (try? await environment.runStore.runs(conversationID: conversation.id)) ?? []
            if let latest = runs.sorted(by: { $0.startedAt > $1.startedAt }).first {
                states[conversation.id] = latest.state
            }
        }
        latestRunStates = states
    }

    // MARK: - Actions

    /// Creates a conversation for the draft goal, starts a run, and
    /// returns the new conversation ID so the view can navigate straight
    /// into the thread. Staged attachments persist as message parts so
    /// the thread renders them as chips on the user bubble.
    @discardableResult
    func sendNewTask() async -> UUID? {
        guard canSend,
              let (provider, model) = center.providerAndModel(modelID: selectedModelID)
        else { return nil }
        isSending = true
        defer { isSending = false }
        let goal = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedAttachments = attachments
        do {
            let conversation = try await center.createConversation(title: Self.title(from: goal))
            if !stagedAttachments.isEmpty {
                await persistAttachments(stagedAttachments, in: conversation.id)
            }
            try await center.send(goal: goal, in: conversation.id, provider: provider, model: model)
            draft = ""
            attachments = []
            actionError = nil
            await load()
            return conversation.id
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    /// Persists staged attachments as file/image parts on the user goal
    /// message so ThreadDetailView's UserMessageBubble shows chips. The
    /// store has no standalone part-append API, so the message is
    /// re-appended with its parts merged (appendMessage re-inserts parts).
    private func persistAttachments(
        _ attachments: [AttachmentRef],
        in conversationID: UUID
    ) async {
        let store = environment.conversationStore
        guard let messages = try? await store.messages(conversationID: conversationID),
              var userMessage = messages.first(where: { $0.role == "user" }) else { return }
        for attachment in attachments {
            try? await store.saveAttachment(attachment)
        }
        let newParts = attachments.enumerated().map { offset, attachment in
            MessagePart(
                messageID: userMessage.id,
                partIndex: offset + 1,
                kind: attachment.kind == .image ? .image : .file,
                attachmentID: attachment.id,
                metadata: ["name": attachment.displayName]
            )
        }
        userMessage.parts.append(contentsOf: newParts)
        try? await store.appendMessage(userMessage)
    }

    /// Derives a conversation title from the goal (first ~40 chars).
    private static func title(from goal: String) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 40 { return trimmed }
        return String(trimmed.prefix(40)) + "…"
    }
}
#endif
