// FloeApp — Thread detail view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Binds one conversation: consumes the persisted run_events plus the live
// run snapshot from ConversationCenter, and drives send/cancel/retry/
// model-switch. Presentation state only; sockets, runtimes and stores stay
// behind the center.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity

/// View model for the canonical foldable thread of one conversation.
@MainActor
final class ThreadDetailViewModel: ObservableObject {

    // MARK: - Published presentation state

    /// The conversation's runs, newest first.
    @Published private(set) var runs: [RunRecord] = []
    /// The run currently displayed (the one the user expanded / latest).
    @Published var selectedRunID: UUID?
    /// Persisted events of the selected run, in sequence order.
    @Published private(set) var events: [RunEventRecord] = []
    /// Live snapshot of the selected run, when the center owns it.
    @Published private(set) var liveStateName: String?
    @Published private(set) var liveStreamedText: String = ""
    @Published private(set) var liveReasoningText: String = ""
    @Published private(set) var hasProviderActivity = false
    /// Persisted messages of the conversation (user goals, final answers).
    @Published private(set) var messages: [PersistedMessage] = []
    /// Composer draft text.
    @Published var draft: String = ""
    @Published var selectedModelID: UUID?
    /// Workspace project selection (placeholder until T05).
    @Published var selectedProjectID: UUID?
    /// Where the next run executes (local only until host tools land).
    @Published var executionTarget: AgentExecutionTarget = .local
    /// How the next run behaves (agent vs chat-only).
    @Published var agentMode: AgentExecutionMode = .agent
    /// Attachments staged in the composer.
    @Published var attachments: [AttachmentRef] = []
    /// Real workspace list from WorkspaceCenter (T05).
    var availableProjects: [ComposerProject] {
        center.environment.workspaceCenter.workspaces.map(ComposerProject.init(record:))
    }
    /// Whether a run is currently non-terminal (drives Stop vs Send).
    @Published private(set) var isRunning = false
    /// Honest error surface for the last failed action.
    @Published private(set) var actionError: String?

    let conversationID: UUID
    let center: ConversationCenter

    private var pollTask: Task<Void, Never>?

    init(conversationID: UUID, center: ConversationCenter) {
        self.conversationID = conversationID
        self.center = center
    }

    /// The currently selected run record, if any.
    var selectedRun: RunRecord? {
        if let selectedRunID, let run = runs.first(where: { $0.id == selectedRunID }) {
            return run
        }
        return runs.first
    }

    /// Pending approvals belonging to the selected run.
    var pendingApprovals: [PendingApproval] {
        guard let run = selectedRun else { return [] }
        return center.pendingApprovals.filter { $0.runID == run.id }
    }

    /// Whether the composer may send (provider configured + non-empty draft).
    var canSend: Bool {
        center.providerAndModel(modelID: selectedModelID) != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isRunning
    }

    var needsProvider: Bool {
        center.providerAndModel(modelID: selectedModelID) == nil
    }

    var availableModels: [ModelProfile] { center.availableAgentModels }

    var selectedModelName: String? {
        center.providerAndModel(modelID: selectedModelID)?.1.displayName
    }

    // MARK: - Loading

    /// Loads runs, messages and the selected run's events, then starts
    /// polling the live snapshot while the selected run is non-terminal.
    func load() async {
        do {
            await center.reload()
            await center.environment.workspaceCenter.reload()
            if selectedModelID == nil { selectedModelID = center.modelPreferences.defaultAgentModelID }
            runs = try await center.environment.runStore.runs(conversationID: conversationID)
            messages = try await center.environment.conversationStore
                .messages(conversationID: conversationID)
            if selectedRunID == nil { selectedRunID = runs.first?.id }
            try await loadEvents()
            startPolling()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Selects a run and loads its persisted event thread.
    func selectRun(_ runID: UUID) async {
        selectedRunID = runID
        do {
            try await loadEvents()
        } catch {
            actionError = error.localizedDescription
        }
        startPolling()
    }

    private func loadEvents() async throws {
        guard let runID = selectedRun?.id else {
            events = []
            return
        }
        events = try await center.environment.runStore.events(runID: runID)
            .filter { $0.kind != .assistantText }
        let errors = try await center.environment.runStore.errors(runID: runID)
        if selectedRun?.state == "failed", let latest = errors.last {
            actionError = latest.message
        }
    }

    // MARK: - Actions

    /// Sends the composer draft as a new run in this conversation.
    func send() async {
        guard canSend, let (provider, model) = center.providerAndModel(modelID: selectedModelID) else { return }
        let goal = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        actionError = nil
        do {
            let existingRunIDs = Set(runs.map(\.id))
            let sendTask = Task {
                try await center.send(goal: goal, in: conversationID, provider: provider, model: model)
            }
            // The provider stream is long-lived. Surface the persisted run
            // immediately so Stop, state and live activity are usable while
            // the request is still in flight.
            for _ in 0..<30 where !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(100))
                let refreshed = try await center.environment.runStore.runs(conversationID: conversationID)
                if let newest = refreshed.first, !existingRunIDs.contains(newest.id) {
                    runs = refreshed
                    selectedRunID = newest.id
                    try await loadEvents()
                    startPolling()
                    break
                }
            }
            try await sendTask.value
            await load()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Cancels the selected run.
    func cancel() async {
        guard let runID = selectedRun?.id else { return }
        await center.cancel(runID: runID)
    }

    /// Retries the selected run (fresh run, same goal/provider/model).
    func retry() async {
        guard let runID = selectedRun?.id else { return }
        actionError = nil
        do {
            try await center.retry(runID: runID)
            await load()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Resolves a pending approval on this thread.
    func resolve(_ approval: PendingApproval, decision: ApprovalDecision) async {
        await center.resolve(approval, decision: decision)
    }

    // MARK: - Live polling

    private func startPolling() {
        pollTask?.cancel()
        guard let run = selectedRun else { return }
        pollTask = Task { [weak self, center] in
            guard let self else { return }
            while !Task.isCancelled {
                if let service = center.service(for: run.id) {
                    let snapshot = await service.snapshot()
                    self.liveStateName = snapshot.stateName
                    self.liveStreamedText = snapshot.streamedText
                    self.liveReasoningText = snapshot.reasoningText
                    self.hasProviderActivity = snapshot.hasProviderActivity
                    self.isRunning = !snapshot.isTerminal
                    if snapshot.isTerminal {
                        try? await self.loadEvents()
                        self.messages = (try? await center.environment.conversationStore
                            .messages(conversationID: self.conversationID)) ?? self.messages
                        break
                    }
                } else {
                    // No live service: render the persisted record honestly.
                    self.liveStateName = run.state
                    self.isRunning = false
                    break
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
#endif
