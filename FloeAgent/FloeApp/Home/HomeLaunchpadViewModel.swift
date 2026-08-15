// FloeApp — Home launchpad view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Presentation state for the Home launchpad: the centered start-task
// composer, the second-column overview (active runs / pending approvals /
// recent threads), and the single-flight task creation. Home never shows
// the conversation-history list — that is Chat's job.
//
// Task-creation guarantees:
// - A send creates exactly one conversation, even on a double tap
//   (single-flight flag + cleared draft).
// - A failed send keeps the draft, creates no conversation, and surfaces
//   the error — no empty, forever-"running" thread is ever left behind.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence

/// The task-creation seam behind Home's send button. The live
/// implementation delegates to ConversationCenter; tests substitute a
/// fake to pin the single-creation and failure-cleanup guarantees without
/// standing up the whole app environment.
protocol HomeTaskStarting: Sendable {
    /// Creates a conversation for `goal` and starts its run.
    /// Implementations MUST throw (and leave no empty thread behind) when
    /// the run fails to start.
    func startTask(goal: String, modelID: UUID?) async throws -> UUID
}

@MainActor
final class HomeLaunchpadViewModel: ObservableObject {

    // MARK: - Composer state

    /// Draft text. Preserved verbatim across a failed send.
    @Published var draft: String = ""
    @Published var selectedModelID: UUID?
    @Published var selectedProjectID: UUID?
    @Published var executionTarget: AgentExecutionTarget = .local
    @Published var agentMode: AgentExecutionMode = .agent
    @Published var attachments: [AttachmentRef] = []
    /// Single-flight send guard (double-tap safe).
    @Published private(set) var isSending = false
    /// Honest error surface for the last failed send.
    @Published private(set) var actionError: String?

    // MARK: - Overview state (iPad second column)

    /// Conversations with at least one non-terminal run.
    @Published private(set) var activeTasks: [ConversationRecord] = []
    /// Recent conversations for the overview (capped by the view).
    @Published private(set) var recentConversations: [ConversationRecord] = []
    /// Latest run state per conversation (overview status pills).
    @Published private(set) var latestRunStates: [UUID: String] = [:]
    @Published private(set) var isLoading = false

    let center: ConversationCenter
    let environment: AppEnvironment
    /// Injectable task starter (defaults to the live center-backed one).
    private let taskStarter: (any HomeTaskStarting)?

    init(center: ConversationCenter, taskStarter: (any HomeTaskStarting)? = nil) {
        self.center = center
        self.environment = center.environment
        self.taskStarter = taskStarter
    }

    var pendingApprovals: [PendingApproval] { center.pendingApprovals }
    var hasConfiguredProvider: Bool { center.hasConfiguredProvider }
    var availableModels: [ModelProfile] { center.availableAgentModels }

    var activeModelName: String? {
        center.providerAndModel(modelID: selectedModelID)?.1.displayName
    }

    var availableProjects: [ComposerProject] {
        environment.workspaceCenter.workspaces.map(ComposerProject.init(record:))
    }

    var canSend: Bool {
        center.providerAndModel(modelID: selectedModelID) != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending
    }

    // MARK: - Loading

    /// Loads the overview data. Cheap and quiet: no empty-card stacks —
    /// empty sections simply render nothing.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        await center.reload()
        await environment.workspaceCenter.reload()
        if selectedModelID == nil { selectedModelID = center.modelPreferences.defaultAgentModelID }

        var states: [UUID: String] = [:]
        var active: [ConversationRecord] = []
        for conversation in center.conversations {
            let runs = (try? await environment.runStore.runs(conversationID: conversation.id)) ?? []
            guard let latest = runs.sorted(by: { $0.startedAt > $1.startedAt }).first else { continue }
            states[conversation.id] = latest.state
            if !RunStateLocalizer.isTerminal(latest.state) {
                active.append(conversation)
            }
        }
        latestRunStates = states
        activeTasks = active
        recentConversations = center.conversations
    }

    // MARK: - Task creation

    /// Creates exactly one conversation for the draft and starts its run.
    /// Returns the new conversation ID so Home can open the thread.
    /// On failure nothing is created: the draft stays, the error shows,
    /// and no blank/eternally-timed thread exists.
    @discardableResult
    func sendNewTask() async -> UUID? {
        guard canSend,
              center.providerAndModel(modelID: selectedModelID) != nil
        else { return nil }
        isSending = true
        defer { isSending = false }
        let goal = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedAttachments = attachments
        do {
            let conversationID: UUID
            if let taskStarter {
                conversationID = try await taskStarter.startTask(
                    goal: goal, modelID: selectedModelID
                )
            } else {
                conversationID = try await startTaskLive(
                    goal: goal, stagedAttachments: stagedAttachments
                )
            }
            draft = ""
            attachments = []
            actionError = nil
            await load()
            return conversationID
        } catch {
            // Failure keeps the draft and creates no lingering thread.
            actionError = error.localizedDescription
            return nil
        }
    }

    /// Live path: create the conversation, start the run, and remove the
    /// would-be empty thread if the send itself fails — Home never
    /// abandons a blank, eternally-timed conversation behind.
    private func startTaskLive(goal: String, stagedAttachments: [AttachmentRef]) async throws -> UUID {
        guard let (provider, model) = center.providerAndModel(modelID: selectedModelID) else {
            throw FloeError.invalidConfiguration("No provider and model configured")
        }
        let conversation = try await center.createConversation(title: Self.title(from: goal))
        do {
            let started = try center.startRun(
                goal: goal,
                in: conversation.id,
                provider: provider,
                model: model
            )

            // The run service writes its run row and user message before
            // opening provider I/O. Navigate as soon as that durable start
            // is visible instead of waiting for the entire model response.
            for _ in 0..<50 where !Task.isCancelled {
                if try await environment.runStore.run(id: started.runID) != nil {
                    if !stagedAttachments.isEmpty {
                        await persistAttachments(stagedAttachments, in: conversation.id)
                    }
                    return conversation.id
                }
                try await Task.sleep(for: .milliseconds(40))
            }

            // No durable run appeared: stop the launch and surface its
            // concrete failure (or a bounded start timeout) so the empty
            // conversation can be removed below.
            started.result.cancel()
            switch await started.result.value {
            case .success:
                throw FloeError.internalError("Run did not become available")
            case .failure(let error):
                throw error
            }
        } catch {
            try? await environment.conversationStore.deleteConversation(id: conversation.id)
            await center.reload()
            throw error
        }
    }

    /// Persists staged attachments as file/image parts on the user goal
    /// message so ThreadDetailView's UserMessageBubble shows chips.
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
