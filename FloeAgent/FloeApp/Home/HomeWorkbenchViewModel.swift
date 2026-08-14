// FloeApp — Home workbench view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Composes the Home task workbench: active (non-terminal) runs, pending
// approvals, recent remote sessions and provider/connection status. Holds
// only presentation state; all work goes through the centers and the
// committed stores.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence

/// View model for the Home task workbench.
@MainActor
final class HomeWorkbenchViewModel: ObservableObject {

    // MARK: - Published presentation state

    /// Non-terminal runs across all conversations (Active Tasks).
    @Published private(set) var activeTasks: [RunRecord] = []
    /// Recent remote sessions (connecting/connected/suspended).
    @Published private(set) var recentSessions: [RemoteSessionRecord] = []
    /// Whether a load is in flight.
    @Published private(set) var isLoading = false
    /// Composer draft text.
    @Published var draft: String = ""

    let center: ConversationCenter
    let environment: AppEnvironment

    init(center: ConversationCenter) {
        self.center = center
        self.environment = center.environment
    }

    /// Pending approvals, straight from the center.
    var pendingApprovals: [PendingApproval] {
        center.pendingApprovals
    }

    /// True when at least one provider+model is configured.
    var hasConfiguredProvider: Bool {
        center.hasConfiguredProvider
    }

    /// The provider/model the composer will use for a new task.
    var activeModelName: String? {
        center.defaultProviderAndModel()?.1.displayName
    }

    /// Whether the composer may send.
    var canSend: Bool {
        hasConfiguredProvider
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Run states that count as "still active" for the workbench.
    private static let terminalStates: Set<String> = ["completed", "failed", "checkpointed"]

    // MARK: - Loading

    /// Reloads conversations, providers, active runs and recent sessions.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        await center.reload()
        await loadActiveTasks()
        await loadRecentSessions()
    }

    private func loadActiveTasks() async {
        var runs: [RunRecord] = []
        for conversation in center.conversations {
            let conversationRuns =
                (try? await environment.runStore.runs(conversationID: conversation.id)) ?? []
            runs.append(contentsOf: conversationRuns)
        }
        activeTasks = runs
            .filter { !Self.terminalStates.contains($0.state) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func loadRecentSessions() async {
        recentSessions =
            (try? await environment.remoteSessionRegistry.activeSessions()) ?? []
    }

    // MARK: - Actions

    /// Creates a conversation for the draft goal and starts a run.
    /// Returns the new conversation ID so the view can navigate to Chat.
    @discardableResult
    func sendNewTask() async -> UUID? {
        guard canSend, let (provider, model) = center.defaultProviderAndModel() else { return nil }
        let goal = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        do {
            let conversation = try await center.createConversation(title: Self.title(from: goal))
            try await center.send(goal: goal, in: conversation.id, provider: provider, model: model)
            await load()
            return conversation.id
        } catch {
            return nil
        }
    }

    /// Derives a conversation title from the goal (first ~40 chars).
    private static func title(from goal: String) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 40 { return trimmed }
        return String(trimmed.prefix(40)) + "…"
    }
}
#endif
