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
    @Published var draftPolicy = DraftTaskPolicy()
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

    init(
        center: ConversationCenter,
        taskStarter: (any HomeTaskStarting)? = nil,
        selectedProjectID: UUID? = nil
    ) {
        self.center = center
        self.environment = center.environment
        self.taskStarter = taskStarter
        self.selectedProjectID = selectedProjectID
        // Default the draft policy to the user's global default agent mode so
        // "自动审批" actually takes effect on new tasks started from Home.
        if environment.settingsCenter.defaultAgentMode == .approvalModel {
            draftPolicy = DraftTaskPolicy(approvalMode: .automatic)
        }
    }

    var pendingApprovals: [PendingApproval] { center.pendingApprovals }
    var hasConfiguredProvider: Bool { center.hasConfiguredProvider }
    var availableModels: [ModelProfile] { center.availableAgentModels }

    var activeModelName: String? {
        center.providerAndModel(modelID: selectedModelID)?.1.displayName
    }

    var usesLocalModel: Bool {
        center.providerAndModel(modelID: selectedModelID)?.0.kind == .local
    }

    var availableProjects: [ComposerProject] {
        environment.workspaceCenter.projectWorkspaces.map(ComposerProject.init(record:))
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
        // Nil is a deliberate private-chat scope. Never inherit whatever
        // project happens to be open in another task or inspector.

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

    /// Live path: one persistence transaction creates the conversation, run,
    /// first message, attachments and workspace link before provider I/O.
    private func startTaskLive(goal: String, stagedAttachments: [AttachmentRef]) async throws -> UUID {
        guard let (provider, model) = center.providerAndModel(modelID: selectedModelID) else {
            throw FloeError.invalidConfiguration("No provider and model configured")
        }
        let started = try await center.startTask(
            goal: goal,
            title: Self.title(from: goal),
            provider: provider,
            model: model,
            workspaceID: selectedProjectID,
            attachments: stagedAttachments,
            executionMode: agentMode,
            initialPolicy: draftPolicy
        )
        return started.conversationID
    }

    /// Derives a conversation title from the goal (first ~40 chars).
    private static func title(from goal: String) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 40 { return trimmed }
        return String(trimmed.prefix(40)) + "…"
    }
}
#endif
