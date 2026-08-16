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
import FloeAgentRuntime

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
    @Published private(set) var liveReasoningText: String = ""
    /// Published mirror of StreamingTextAnimator.displayedText. SwiftUI
    /// observes this value, so every grapheme tick is actually rendered.
    @Published private(set) var liveStreamedText: String = ""
    @Published private(set) var hasProviderActivity = false
    /// Persisted messages of the conversation (user goals, final answers).
    @Published private(set) var messages: [PersistedMessage] = []
    /// Composer draft text.
    @Published var draft: String = ""
    @Published var selectedModelID: UUID?
    /// Workspace selected for the next run.
    @Published var selectedProjectID: UUID?
    /// Where the next run executes (local only until host tools land).
    @Published var executionTarget: AgentExecutionTarget = .local
    /// How the next run behaves (agent vs chat-only).
    @Published var agentMode: AgentExecutionMode = .agent
    /// Attachments staged in the composer.
    @Published var attachments: [AttachmentRef] = []
    /// Real workspace list from WorkspaceCenter.
    var availableProjects: [ComposerProject] {
        center.environment.workspaceCenter.workspaces.map(ComposerProject.init(record:))
    }
    /// Whether a run is currently non-terminal (drives Stop vs Send).
    @Published private(set) var isRunning = false
    /// Honest error surface for the last failed action.
    @Published private(set) var actionError: String?
    /// The parent row may disappear through another scene or history clear.
    /// When true the composer is removed and no follow-up can launch.
    @Published private(set) var isConversationMissing = false
    @Published private(set) var latestPlan: PlanDraft?
    @Published private(set) var activeGoal: ConversationGoal?

    let conversationID: UUID
    let center: ConversationCenter

    /// Grapheme-ordered display coordinator for the live assistant tail.
    /// The network snapshot is the target; the view renders only
    /// `animator.displayedText`, so a terminal snapshot can never make a
    /// whole paragraph pop in at once.
    let animator: StreamingTextAnimator

    /// True while the animator is draining the remainder of a finished
    /// network stream. The run is logically terminal but the live tail
    /// must stay visible until the display catches up — no flicker, no
    /// gap before the persisted message takes over.
    @Published private(set) var isDraining = false

    private var liveEventTask: Task<Void, Never>?
    private let diagnostics: ThreadStreamingDiagnostics

    init(conversationID: UUID, center: ConversationCenter) {
        self.conversationID = conversationID
        self.center = center
        let diagnostics = ThreadStreamingDiagnostics()
        self.animator = StreamingTextAnimator(diagnostics: diagnostics)
        self.diagnostics = diagnostics
        self.animator.onDisplayedTextChange = { [weak self] text in
            self?.liveStreamedText = text
        }
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
        !isConversationMissing
            && center.providerAndModel(modelID: selectedModelID) != nil
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

    /// Loads persisted state, then subscribes to the selected run's bounded
    /// push stream while it is non-terminal.
    func load() async {
        do {
            await center.reload()
            await center.environment.workspaceCenter.reload()
            guard try await center.environment.conversationStore
                .conversation(id: conversationID) != nil else {
                isConversationMissing = true
                runs = []
                messages = []
                events = []
                stopLiveUpdates()
                return
            }
            isConversationMissing = false
            if selectedModelID == nil { selectedModelID = center.modelPreferences.defaultAgentModelID }
            runs = try await center.environment.runStore.runs(conversationID: conversationID)
            messages = try await center.environment.conversationStore
                .messages(conversationID: conversationID)
            latestPlan = try await center.environment.intelligenceStore
                .latestPlan(conversationID: conversationID)
            activeGoal = try await center.environment.intelligenceStore
                .goals(conversationID: conversationID).first
            if selectedRunID == nil { selectedRunID = runs.first?.id }
            try await loadEvents()
            startLiveUpdates()
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
        startLiveUpdates()
    }

    private func loadEvents() async throws {
        guard let runID = selectedRun?.id else {
            events = []
            return
        }
        // assistantText events stay in the timeline: they carry the final
        // reply in stored sequence order (before terminal).
        events = try await center.environment.runStore.events(runID: runID)
        let errors = try await center.environment.runStore.errors(runID: runID)
        if selectedRun?.state == "failed", let latest = errors.last {
            actionError = latest.message
        }
    }

    /// The unified, sequence-ordered timeline for the selected run.
    var timeline: [ThreadTimelineItem] {
        ThreadTimelineBuilder.build(
            messages: messages,
            events: events,
            run: selectedRun,
            isRunning: showsLiveTail,
            liveStreamedText: liveStreamedText,
            liveReasoningText: liveReasoningText,
            pendingApprovals: pendingApprovals
        )
    }

    /// The live tail stays mounted while the run is active OR while the
    /// animator drains a terminal remainder — the final bubble never
    /// flickers or disappears before the persisted reply takes over.
    var showsLiveTail: Bool {
        isRunning || isDraining
    }

    // MARK: - Actions

    /// Sends the composer draft as a new run in this conversation.
    func send() async {
        guard canSend, let (provider, model) = center.providerAndModel(modelID: selectedModelID) else { return }
        let goal = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedAttachments = attachments
        draft = ""
        actionError = nil
        do {
            let started = try await center.startRun(
                goal: goal,
                in: conversationID,
                provider: provider,
                model: model,
                workspaceID: selectedProjectID,
                attachments: stagedAttachments,
                executionMode: agentMode
            )
            // The atomic launch returns a durable run identity immediately.
            // Subscribe before awaiting the provider loop so the UI no longer
            // waits for the first token or races a very fast completion.
            runs = try await center.environment.runStore.runs(conversationID: conversationID)
            selectedRunID = started.runID
            try await loadEvents()
            startLiveUpdates()
            switch await started.result.value {
            case .success:
                break
            case .failure(let error):
                throw error
            }
            attachments = []
            await load()
        } catch {
            if draft.isEmpty { draft = goal }
            if attachments.isEmpty { attachments = stagedAttachments }
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

    func acceptLatestPlan() async {
        guard let latestPlan else { return }
        let accepted = latestPlan.revised(
            status: .accepted,
            assumptions: latestPlan.assumptions.map {
                PlanAssumption(id: $0.id, text: $0.text, isAccepted: true)
            },
            digest: latestPlan.digest
        )
        do {
            try await center.environment.intelligenceStore.savePlanRevision(accepted)
            self.latestPlan = accepted
        } catch { actionError = error.localizedDescription }
    }

    func confirmGoalCompletion() async {
        guard var goal = activeGoal, goal.status == .verifying else { return }
        let evidence = GoalEvidence(
            kind: .userConfirmation,
            reference: conversationID.uuidString,
            summary: "User confirmed the goal result"
        )
        goal.evidence.append(evidence)
        goal.acceptanceCriteria = goal.acceptanceCriteria.map { criterion in
            var copy = criterion
            if copy.requiresUserConfirmation {
                copy.isSatisfied = true
                copy.evidenceIDs.append(evidence.id)
            }
            return copy
        }
        goal.status = .completed
        goal.updatedAt = Date()
        do {
            try await center.environment.intelligenceStore.saveGoal(goal)
            activeGoal = goal
        } catch { actionError = error.localizedDescription }
    }

    // MARK: - Live push stream

    private func startLiveUpdates() {
        liveEventTask?.cancel()
        guard let run = selectedRun else { return }
        liveStateName = run.state
        liveReasoningText = ""
        hasProviderActivity = false
        isDraining = false
        animator.reset()
        liveEventTask = Task { [weak self, center] in
            guard let self else { return }
            guard let service = center.service(for: run.id) else {
                self.liveStateName = run.state
                self.isRunning = false
                self.isDraining = false
                return
            }

            // Subscribe before reading the snapshot so an event arriving at
            // the boundary is buffered instead of falling between snapshot
            // and stream consumption. The animator still owns display cadence.
            let stream = service.events()
            let snapshot = await service.snapshot()
            guard self.selectedRunID == run.id else { return }
            var answerTarget = snapshot.streamedText
            self.animator.update(target: answerTarget)
            self.liveReasoningText = snapshot.reasoningText
            self.hasProviderActivity = snapshot.hasProviderActivity
            self.liveStateName = snapshot.stateName
            self.isRunning = !snapshot.isTerminal
            if snapshot.isTerminal {
                await self.finishLiveRun(runID: run.id, center: center)
                return
            }

            for await event in stream {
                guard !Task.isCancelled, self.selectedRunID == run.id else { break }
                switch event {
                case .answerDelta(let delta):
                    answerTarget += delta.text
                    self.animator.update(target: answerTarget)
                    self.hasProviderActivity = true
                case .reasoningDelta(let delta):
                    self.liveReasoningText += delta.text
                    self.hasProviderActivity = true
                case .stateChanged(let state):
                    self.liveStateName = state.rawValue
                    self.isRunning = ![.completed, .cancelled, .failed, .interrupted].contains(state)
                case .terminal:
                    await self.finishLiveRun(runID: run.id, center: center)
                    return
                default:
                    self.hasProviderActivity = true
                }
            }
        }
    }

    private func finishLiveRun(runID: UUID, center: ConversationCenter) async {
        isRunning = false
        isDraining = true
        await animator.drain()
        isDraining = false
        guard !Task.isCancelled, selectedRunID == runID else { return }
        try? await loadEvents()
        messages = (try? await center.environment.conversationStore
            .messages(conversationID: conversationID)) ?? messages
        runs = (try? await center.environment.runStore
            .runs(conversationID: conversationID)) ?? runs
        liveStateName = runs.first(where: { $0.id == runID })?.state ?? liveStateName
    }

    func stopLiveUpdates() {
        liveEventTask?.cancel()
        liveEventTask = nil
        // Leaving the thread stops the animation immediately; the partial
        // display is discarded with the live tail, persisted rows reload
        // from the store on the next open.
        animator.cancel()
        isDraining = false
        isRunning = false
    }
}

/// Forwards animator diagnostics into FloeLogger with the structured event
/// names. Only counts and flags — never transcript content.
private struct ThreadStreamingDiagnostics: StreamingTextAnimatorDiagnostics {
    private let logger = FloeLogger(category: .app)

    func streamTargetAdvanced(pendingCharacters: Int) {
        logger.debug("streamTargetAdvanced pending=\(pendingCharacters)")
    }

    func streamNonPrefixDetected() {
        logger.warning("streamNonPrefixDetected")
    }

    func streamDrainStarted(pendingCharacters: Int) {
        logger.info("streamDrainStarted pending=\(pendingCharacters)")
    }

    func streamDrainCompleted() {
        logger.info("streamDrainCompleted")
    }
}
#endif
