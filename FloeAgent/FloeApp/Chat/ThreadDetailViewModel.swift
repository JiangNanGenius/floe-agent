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

struct ThreadUsageSummary: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var contextTokens: Int
    var contextWindowTokens: Int
    var isEstimatedLive: Bool
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var reasoningTokens: Int?

    var totalTokens: Int { inputTokens + outputTokens }
    var contextFraction: Double {
        guard contextWindowTokens > 0 else { return 0 }
        return min(1, Double(contextTokens) / Double(contextWindowTokens))
    }
}

/// View model for the canonical foldable thread of one conversation.
@MainActor
final class ThreadDetailViewModel: ObservableObject {

    private let logger = FloeLogger(category: .app)

    // MARK: - Published presentation state

    /// The conversation's runs, newest first.
    @Published private(set) var runs: [RunRecord] = []
    /// The run currently displayed (the one the user expanded / latest).
    @Published var selectedRunID: UUID?
    /// Persisted events of the selected run, in sequence order.
    @Published private(set) var events: [RunEventRecord] = []
    @Published private(set) var eventsByRun: [UUID: [RunEventRecord]] = [:]
    @Published private(set) var usageByRun: [UUID: [RunUsageRecord]] = [:]
    @Published private(set) var liveUsage = UsageSnapshot()
    @Published private(set) var latestUsage = UsageSnapshot()
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
        center.environment.workspaceCenter.projectWorkspaces.map(ComposerProject.init(record:))
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
    @Published private(set) var taskTitle: String = ""
    @Published private(set) var taskPolicy: TaskPolicy
    @Published private(set) var pendingInputs: [PendingUserInput] = []
    @Published var runningInputMode: RunningInputMode = .queue

    let conversationID: UUID
    let center: ConversationCenter

    /// Grapheme-ordered display coordinator for the live assistant tail.
    /// The network snapshot is the target; the view renders only
    /// `animator.displayedText`, so a terminal snapshot can never make a
    /// whole paragraph pop in at once.
    let animator: StreamingTextAnimator
    /// Reasoning uses the same grapheme-cluster presentation buffer as the
    /// final answer. Provider chunks therefore never replace a whole line.
    let reasoningAnimator: StreamingTextAnimator

    /// True while the animator is draining the remainder of a finished
    /// network stream. The run is logically terminal but the live tail
    /// must stay visible until the display catches up — no flicker, no
    /// gap before the persisted message takes over.
    @Published private(set) var isDraining = false

    private var liveEventTask: Task<Void, Never>?
    private var sessionEventTask: Task<Void, Never>?
    private var sessionRevision = -1
    private let diagnostics: ThreadStreamingDiagnostics

    init(conversationID: UUID, center: ConversationCenter) {
        self.conversationID = conversationID
        self.center = center
        self.taskPolicy = TaskPolicy(conversationID: conversationID)
        let diagnostics = ThreadStreamingDiagnostics()
        self.animator = StreamingTextAnimator(diagnostics: diagnostics)
        self.reasoningAnimator = StreamingTextAnimator(diagnostics: diagnostics)
        self.diagnostics = diagnostics
        self.animator.onDisplayedTextChange = { [weak self] text in
            self?.liveStreamedText = text
        }
        self.reasoningAnimator.onDisplayedTextChange = { [weak self] text in
            self?.liveReasoningText = text
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

    /// Whether the composer may send, queue or steer the current draft.
    var canSend: Bool {
        !isConversationMissing
            && center.providerAndModel(modelID: selectedModelID) != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var needsProvider: Bool {
        center.providerAndModel(modelID: selectedModelID) == nil
    }

    var availableModels: [ModelProfile] { center.availableAgentModels }

    var selectedModelName: String? {
        center.providerAndModel(modelID: selectedModelID)?.1.displayName
    }

    var canContinue: Bool {
        guard !isRunning, let state = selectedRun?.state else { return false }
        return ["failed", "interrupted", "checkpointed"].contains(state)
    }

    var usageSummary: ThreadUsageSummary? {
        guard let run = selectedRun else { return nil }
        let records = usageByRun[run.id, default: []]
        let persistedInput = records.reduce(0) { $0 + $1.inputTokens }
        let persistedOutput = records.reduce(0) { $0 + $1.outputTokens }
        let persistedCacheRead = Self.sumReported(records.map(\.cacheReadTokens))
        let persistedCacheWrite = Self.sumReported(records.map(\.cacheWriteTokens))
        let persistedReasoning = Self.sumReported(records.map(\.reasoningTokens))
        let streamedEstimate = Self.estimatedTokens(in: liveStreamedText)
        let currentOutput = max(liveUsage.outputTokens, streamedEstimate)
        let input = isRunning ? persistedInput + liveUsage.inputTokens : persistedInput
        let output = isRunning
            ? persistedOutput + currentOutput
            : persistedOutput
        guard input + output > 0 else { return nil }
        let modelID = run.modelID ?? selectedModelID
        let window = modelID.flatMap {
            center.providerAndModel(modelID: $0)?.1.limits.contextTokens
        } ?? 0
        let currentContext = max(
            records.last.map { $0.inputTokens + $0.outputTokens } ?? 0,
            latestUsage.inputTokens + max(latestUsage.outputTokens, streamedEstimate)
        )
        return ThreadUsageSummary(
            inputTokens: input,
            outputTokens: output,
            contextTokens: currentContext,
            contextWindowTokens: window,
            isEstimatedLive: isRunning && streamedEstimate > liveUsage.outputTokens,
            cacheReadTokens: Self.addReported(persistedCacheRead, isRunning ? liveUsage.cacheReadTokens : nil),
            cacheWriteTokens: Self.addReported(persistedCacheWrite, isRunning ? liveUsage.cacheWriteTokens : nil),
            reasoningTokens: Self.addReported(persistedReasoning, isRunning ? liveUsage.reasoningTokens : nil)
        )
    }

    private static func sumReported(_ values: [Int?]) -> Int? {
        let reported = values.compactMap { $0 }
        return reported.isEmpty ? nil : reported.reduce(0, +)
    }

    private static func addReported(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }

    // MARK: - Loading

    /// Loads persisted state, then subscribes to the selected run's bounded
    /// push stream while it is non-terminal.
    func load() async {
        actionError = nil
        var stage = "centerReload"
        do {
            await center.reload()
            stage = "runningInputPreferences"
            await center.environment.settingsCenter.loadRunningInputMode()
            runningInputMode = center.environment.settingsCenter.runningInputMode
            stage = "workspaceReload"
            await center.environment.workspaceCenter.reload()
            stage = "conversationRead"
            guard let conversation = try await center.environment.conversationStore
                .conversation(id: conversationID) else {
                isConversationMissing = true
                runs = []
                messages = []
                events = []
                stopLiveUpdates()
                return
            }
            isConversationMissing = false
            taskTitle = conversation.title
            center.environment.browserCenter.bind(to: conversationID)
            selectedProjectID = center.environment.workspaceCenter.workspaceID(for: conversationID)
            if selectedModelID == nil { selectedModelID = center.modelPreferences.defaultAgentModelID }
            stage = "runList"
            runs = try await center.environment.runStore.runs(conversationID: conversationID)
            stage = "messageList"
            messages = try await center.environment.conversationStore
                .messages(conversationID: conversationID)
            stage = "planLoad"
            latestPlan = try await center.environment.intelligenceStore
                .latestPlan(conversationID: conversationID)
            // Restore Plan mode while an unfinished plan is still awaiting
            // review, so leaving and reopening a task never silently drops
            // the mode it was running in.
            if let plan = latestPlan,
               plan.status == .awaitingInput || plan.status == .ready {
                agentMode = .plan
            }
            stage = "goalLoad"
            activeGoal = try await center.environment.intelligenceStore
                .goals(conversationID: conversationID).first
            stage = "pendingInputLoad"
            pendingInputs = try await center.environment.runningInputStore
                .pending(conversationID: conversationID)
            selectedRunID = runs.first?.id
            stage = "eventLoad"
            try await loadAllEvents()
            try await loadAllUsage()
            startSessionUpdates()
            startLiveUpdates()
        } catch {
            actionError = presentableError(error, stage: stage)
        }
    }

    /// Selects a run and loads its persisted event thread.
    func selectRun(_ runID: UUID) async {
        selectedRunID = runID
        do {
            try await loadEvents()
        } catch {
            actionError = presentableError(error, stage: "selectRunEvents")
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
        eventsByRun[runID] = events
        // Historical run failures already live in the selected run's ordered
        // timeline. Never resurrect one as a new composer error when the user
        // opens the task or starts a later run.
        actionError = nil
    }

    private func loadAllEvents() async throws {
        var loaded: [UUID: [RunEventRecord]] = [:]
        for run in runs {
            loaded[run.id] = try await center.environment.runStore.events(runID: run.id)
        }
        eventsByRun = loaded
        events = selectedRun.flatMap { loaded[$0.id] } ?? []
    }

    private func loadAllUsage() async throws {
        var loaded: [UUID: [RunUsageRecord]] = [:]
        for run in runs {
            loaded[run.id] = try await center.environment.runStore.usage(runID: run.id)
        }
        usageByRun = loaded
    }

    func dismissActionError() {
        actionError = nil
    }

    /// The unified, sequence-ordered timeline for the selected run.
    var timeline: [ThreadTimelineItem] {
        ThreadTimelineBuilder.buildConversation(
            messages: messages,
            runs: runs,
            eventsByRun: eventsByRun,
            liveRunID: selectedRun?.id,
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
        actionError = nil
        if isRunning, let expectedRunID = selectedRun?.id {
            do {
                try await center.submitRunningInput(
                    content: goal,
                    in: conversationID,
                    expectedRunID: expectedRunID,
                    mode: runningInputMode,
                    selectedModelID: selectedModelID,
                    workspaceID: selectedProjectID,
                    executionMode: agentMode,
                    attachments: stagedAttachments
                )
                draft = ""
                attachments = []
                pendingInputs = try await center.environment.runningInputStore
                    .pending(conversationID: conversationID)
            } catch {
                actionError = presentableError(error, stage: "submitRunningInput")
            }
            return
        }
        draft = ""
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
            try await loadAllEvents()
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
            actionError = presentableError(error, stage: "startOrCompleteRun")
        }
    }

    /// Cancels the selected run.
    func cancel() async {
        guard let runID = selectedRun?.id else { return }
        await center.cancel(runID: runID)
    }

    func editPendingInput(_ input: PendingUserInput, content: String) async {
        do {
            try await center.editPendingInput(id: input.id, content: content)
            pendingInputs = try await center.environment.runningInputStore.pending(conversationID: conversationID)
        } catch { actionError = error.localizedDescription }
    }

    func removePendingInput(_ input: PendingUserInput) async {
        do {
            try await center.removePendingInput(id: input.id)
            pendingInputs = try await center.environment.runningInputStore.pending(conversationID: conversationID)
        } catch { actionError = error.localizedDescription }
    }

    func movePendingInput(_ input: PendingUserInput, offset: Int) async {
        var queued = pendingInputs.filter { $0.status == .queued }
        guard let source = queued.firstIndex(where: { $0.id == input.id }) else { return }
        let destination = source + offset
        guard queued.indices.contains(destination) else { return }
        queued.swapAt(source, destination)
        do {
            try await center.reorderPendingInputs(
                conversationID: conversationID,
                orderedIDs: queued.map(\.id)
            )
            pendingInputs = try await center.environment.runningInputStore.pending(conversationID: conversationID)
        } catch { actionError = error.localizedDescription }
    }

    func promotePendingInput(_ input: PendingUserInput) async {
        guard let runID = selectedRun?.id, isRunning else { return }
        do {
            try await center.promoteToSteer(inputID: input.id, expectedRunID: runID)
            pendingInputs = try await center.environment.runningInputStore.pending(conversationID: conversationID)
        } catch { actionError = error.localizedDescription }
    }

    /// Retries the selected run (fresh run, same goal/provider/model).
    func retry() async {
        guard let runID = selectedRun?.id else { return }
        actionError = nil
        do {
            let started = try await center.retry(runID: runID)
            runs = try await center.environment.runStore.runs(conversationID: conversationID)
            selectedRunID = started.runID
            try await loadAllEvents()
            try await loadAllUsage()
            startLiveUpdates()
        } catch {
            actionError = presentableError(error, stage: "retryRun")
        }
    }

    /// Records the exact failing phase without leaking task text or file
    /// contents. Cocoa's generic code 259 is replaced with an actionable app
    /// message instead of the misleading system-wide "format incorrect" text.
    private func presentableError(_ error: Error, stage: String) -> String {
        let nsError = error as NSError
        let detail = String(
            error.localizedDescription
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(500)
        )
        logger.error(
            "threadActionFailed conversation=\(conversationID.uuidString) stage=\(stage) domain=\(nsError.domain) code=\(nsError.code) detail=\(detail)"
        )
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadCorruptFile.rawValue {
            return "读取任务数据失败。请重新选择附件或重新打开任务；诊断日志已记录失败阶段（\(stage)）。"
        }
        if let floeError = error as? FloeError,
           case .syncUnavailable(let reason) = floeError {
            if reason.localizedCaseInsensitiveContains("approval") {
                return "自动审批模型暂时不可用或响应超时。安全读操作会按本地规则继续；敏感操作请重试或手动确认。"
            }
            return "同步服务暂时不可用，本机数据仍可继续使用。稍后会自动重试。"
        }
        return error.localizedDescription
    }

    /// Resolves a pending approval on this thread.
    func resolve(_ approval: PendingApproval, decision: ApprovalDecision) async {
        await center.resolve(approval, decision: decision)
    }

    func acceptLatestPlan(as execution: PlanExecutionRecommendation? = nil) async {
        guard let latestPlan else { return }
        guard !isRunning,
              let (provider, model) = center.providerAndModel(modelID: selectedModelID) else {
            actionError = "请先选择可用模型，并等待当前运行结束"
            return
        }
        let selectedExecution = execution ?? latestPlan.executionRecommendation ?? .normal
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
            if selectedExecution == .goal {
                var goal = try GoalFromPlanFactory.makeGoal(from: accepted)
                goal.status = .active
                goal.progress.startedAt = Date()
                try await center.environment.intelligenceStore.saveGoal(goal)
                activeGoal = goal
            }
            let ordered = accepted.sections.sorted { $0.order < $1.order }.map {
                "## \($0.title)\n\($0.body)"
            }.joined(separator: "\n\n")
            let criteria = accepted.acceptanceCriteria.map {
                "- \($0.text)（验证：\($0.verification)）"
            }.joined(separator: "\n")
            let prompt = """
            Execute the accepted plan below. Preserve its ordering, verify each criterion with inspectable evidence, and continue until the safe in-scope work is complete.

            # \(accepted.title)
            \(accepted.summary)

            \(ordered)

            Acceptance criteria:
            \(criteria)
            """
            let started = try await center.startRun(
                goal: prompt,
                in: conversationID,
                provider: provider,
                model: model,
                workspaceID: selectedProjectID,
                executionMode: selectedExecution == .goal ? .goal : .agent
            )
            selectedRunID = started.runID
            await load()
        } catch { actionError = error.localizedDescription }
    }

    func createGoal(
        objective: String,
        criteria: [String],
        blockingConditions: [String],
        stoppingConditions: [String]
    ) async {
        let cleanObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanObjective.isEmpty else { return }
        guard !isRunning,
              let (provider, model) = center.providerAndModel(modelID: selectedModelID) else {
            actionError = "请先选择可用模型，并等待当前运行结束"
            return
        }
        let cleanCriteria = criteria.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let goalCriteria = cleanCriteria.isEmpty
            ? ["目标已通过可检查证据验证"]
            : cleanCriteria
        let goal = ConversationGoal(
            conversationID: conversationID,
            objective: cleanObjective,
            blockingConditions: blockingConditions.filter { !$0.isEmpty },
            stoppingConditions: stoppingConditions.filter { !$0.isEmpty },
            acceptanceCriteria: goalCriteria.map { GoalCriterion(text: $0) },
            steps: [GoalStep(title: "推进目标", status: .inProgress, order: 0)],
            status: .active,
            progress: GoalProgress(startedAt: Date())
        )
        do {
            try await center.environment.intelligenceStore.saveGoal(goal)
            activeGoal = goal
            let blockers = blockingConditions.filter { !$0.isEmpty }.map { "- \($0)" }.joined(separator: "\n")
            let stops = stoppingConditions.filter { !$0.isEmpty }.map { "- \($0)" }.joined(separator: "\n")
            let started = try await center.startRun(
                goal: "Goal: \(cleanObjective)\nBlocking conditions:\n\(blockers)\nStopping conditions:\n\(stops)",
                in: conversationID,
                provider: provider,
                model: model,
                workspaceID: selectedProjectID,
                executionMode: .goal
            )
            selectedRunID = started.runID
            await load()
        } catch {
            actionError = error.localizedDescription
        }
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
        let confirmedIDs = Set(
            goal.acceptanceCriteria
                .filter(\.requiresUserConfirmation)
                .map(\.id)
        )
        let proposal = GoalCompletionProposal(
            goalID: goal.id,
            criterionEvidence: Dictionary(uniqueKeysWithValues: goal.acceptanceCriteria.map {
                ($0.id, $0.evidenceIDs)
            }),
            reviewModelApproved: true
        )
        let verdict = GoalCompletionGate.evaluate(
            goal: goal,
            proposal: proposal,
            userConfirmedCriterionIDs: confirmedIDs
        )
        guard verdict.mayComplete else {
            actionError = "仍有步骤、验收证据或检查项未完成，Goal 不会提前结束"
            return
        }
        goal.status = .completed
        goal.updatedAt = Date()
        do {
            try await center.environment.intelligenceStore.saveGoal(goal)
            activeGoal = goal
        } catch { actionError = error.localizedDescription }
    }

    // MARK: - Live push stream

    private func startSessionUpdates() {
        sessionEventTask?.cancel()
        let stream = center.sessionEvents(conversationID: conversationID)
        sessionEventTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in stream {
                guard !Task.isCancelled, snapshot.revision >= self.sessionRevision else { continue }
                self.sessionRevision = snapshot.revision
                let previousRunID = self.selectedRunID
                self.taskTitle = snapshot.conversation.title
                self.messages = snapshot.messages
                self.runs = snapshot.runs
                self.eventsByRun = snapshot.eventsByRun
                self.selectedRunID = snapshot.runs.first?.id
                self.events = self.selectedRunID.flatMap { snapshot.eventsByRun[$0] } ?? []
                self.latestPlan = snapshot.latestPlan
                // Keep Plan mode in sync when a plan becomes ready or still
                // awaits input, so reopening never drops the active mode.
                if let plan = snapshot.latestPlan,
                   plan.status == .awaitingInput || plan.status == .ready {
                    self.agentMode = .plan
                }
                self.activeGoal = snapshot.activeGoal
                self.taskPolicy = snapshot.taskPolicy
                self.pendingInputs = snapshot.pendingInputs
                if previousRunID != self.selectedRunID {
                    self.startLiveUpdates()
                }
            }
        }
    }

    private func startLiveUpdates() {
        liveEventTask?.cancel()
        guard let run = selectedRun else { return }
        liveStateName = run.state
        liveReasoningText = ""
        hasProviderActivity = false
        isDraining = false
        animator.reset()
        reasoningAnimator.reset()
        liveUsage = UsageSnapshot()
        latestUsage = UsageSnapshot()
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
            var reasoningTarget = snapshot.reasoningText
            self.reasoningAnimator.update(target: reasoningTarget)
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
                    // The reasoning segment ended the instant the answer
                    // began; the service already persisted it. Drop the live
                    // reasoning buffer now so it never duplicates the
                    // persisted `.reasoning` row or piles the next turn's
                    // reasoning on top of this turn's text.
                    if !reasoningTarget.isEmpty {
                        reasoningTarget = ""
                        self.reasoningAnimator.reset()
                    }
                    answerTarget += delta.text
                    self.animator.update(target: answerTarget)
                    self.hasProviderActivity = true
                case .reasoningDelta(let delta):
                    // A fresh reasoning segment starts. The previous answer
                    // was already sealed at the last tool boundary; clear the
                    // live tail defensively so reasoning always renders after
                    // the answer that preceded it, never above it.
                    if !answerTarget.isEmpty {
                        answerTarget = ""
                        self.animator.reset()
                    }
                    reasoningTarget += delta.text
                    self.reasoningAnimator.update(target: reasoningTarget)
                    self.hasProviderActivity = true
                case .toolLifecycle(.requested):
                    // Tool boundary: the answer segment is durable now. Clear
                    // both live buffers so their persisted rows — not a
                    // duplicate live reasoning block — take over.
                    if !answerTarget.isEmpty {
                        answerTarget = ""
                        self.animator.reset()
                    }
                    if !reasoningTarget.isEmpty {
                        reasoningTarget = ""
                        self.reasoningAnimator.reset()
                    }
                    self.hasProviderActivity = true
                case .userInputConsumed:
                    answerTarget = ""
                    reasoningTarget = ""
                    self.animator.reset()
                    self.reasoningAnimator.reset()
                    self.hasProviderActivity = false
                case .stateChanged(let state):
                    self.liveStateName = state.rawValue
                    self.isRunning = ![.completed, .cancelled, .failed, .interrupted].contains(state)
                case .approvalReviewChanged(let snapshot):
                    self.liveStateName = snapshot.isEvaluating
                        ? "reviewingApproval"
                        : "streamingModel"
                    self.hasProviderActivity = true
                case .usageChanged(let usage):
                    self.latestUsage = usage
                    self.liveUsage.inputTokens += usage.inputTokens
                    self.liveUsage.outputTokens += usage.outputTokens
                    self.liveUsage.modelCalls += usage.modelCalls
                    self.liveUsage.cacheReadTokens = Self.addReported(
                        self.liveUsage.cacheReadTokens, usage.cacheReadTokens
                    )
                    self.liveUsage.cacheWriteTokens = Self.addReported(
                        self.liveUsage.cacheWriteTokens, usage.cacheWriteTokens
                    )
                    self.liveUsage.reasoningTokens = Self.addReported(
                        self.liveUsage.reasoningTokens, usage.reasoningTokens
                    )
                    if let cost = usage.costEstimate {
                        self.liveUsage.costEstimate = (self.liveUsage.costEstimate ?? 0) + cost
                    }
                    self.hasProviderActivity = true
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
        await animator.drain(maximumDuration: .milliseconds(750))
        await reasoningAnimator.drain(maximumDuration: .milliseconds(500))
        isDraining = false
        // Refresh persisted state even if the selection moved on during the
        // drain. A finished run must never strand the UI in a non-terminal
        // "thinking" state merely because loadAllEvents was skipped.
        guard !Task.isCancelled else { return }
        messages = (try? await center.environment.conversationStore
            .messages(conversationID: conversationID)) ?? messages
        runs = (try? await center.environment.runStore
            .runs(conversationID: conversationID)) ?? runs
        // `loadAllEvents` iterates `runs`; refresh the run list first so a
        // queued follow-up that started while the animator drained is not
        // omitted from the timeline snapshot.
        try? await loadAllEvents()
        try? await loadAllUsage()
        if selectedRunID == runID {
            liveStateName = runs.first(where: { $0.id == runID })?.state ?? liveStateName
        }
    }

    func stopLiveUpdates() {
        liveEventTask?.cancel()
        liveEventTask = nil
        sessionEventTask?.cancel()
        sessionEventTask = nil
        // Leaving the thread stops the animation immediately; the partial
        // display is discarded with the live tail, persisted rows reload
        // from the store on the next open.
        animator.cancel()
        reasoningAnimator.cancel()
        isDraining = false
        isRunning = false
    }

    private static func estimatedTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let scalarCount = text.unicodeScalars.count
        let cjkCount = text.unicodeScalars.filter {
            (0x3400...0x9FFF).contains(Int($0.value))
        }.count
        return max(1, cjkCount + (scalarCount - cjkCount + 3) / 4)
    }
}

/// Forwards animator diagnostics into FloeLogger with the structured event
/// names. Only counts and flags — never transcript content.
private struct ThreadStreamingDiagnostics: StreamingTextAnimatorDiagnostics {
    private let logger = FloeLogger(category: .app)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var targetUpdates = 0

    func streamTargetAdvanced(pendingCharacters: Int) {
        let count = Self.lock.withLock {
            Self.targetUpdates += 1
            return Self.targetUpdates
        }
        if count == 1 || count.isMultiple(of: 60) {
            logger.debug("streamTargetAdvanced samples=\(count) pending=\(pendingCharacters)")
        }
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
