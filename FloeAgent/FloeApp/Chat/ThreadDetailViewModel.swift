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
import Combine
import Darwin
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime

/// Aggregate load diagnostics only: no conversation identifiers or content.
@MainActor private final class ThreadLoadMetrics {
    private var sampler: Task<Void, Never>?
    private var peakFootprint: UInt64 = 0
    private var longestMainActorDelay: Duration = .zero
    private var finished = false

    init() {
        sampleMemory()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                let expected = ContinuousClock.now.advanced(by: .milliseconds(50))
                do { try await Task.sleep(until: expected, clock: .continuous) } catch { return }
                guard let self else { return }
                self.longestMainActorDelay = max(self.longestMainActorDelay, expected.duration(to: .now))
                self.sampleMemory()
            }
        }
    }

    private func sampleMemory() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS { peakFootprint = max(peakFootprint, info.phys_footprint) }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        sampler?.cancel(); sampler = nil
        sampleMemory()
        FloeLogger(category: .app).info("threadLoadMetrics sampledPeakBytes=\(peakFootprint) mainActorSchedulingDelay=\(longestMainActorDelay)")
    }
}

struct ThreadUsageSummary: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var contextTokens: Int
    var contextWindowTokens: Int
    var isEstimatedLive: Bool
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var reasoningTokens: Int?
    var tokensPerSecond: Double?
    var timeToFirstTokenMs: Int?
    var totalDurationMs: Int?

    var totalTokens: Int {
        inputTokens + outputTokens + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0)
    }
    var contextFraction: Double {
        guard contextWindowTokens > 0 else { return 0 }
        return min(1, Double(contextTokens) / Double(contextWindowTokens))
    }
    var cacheHitRate: Double? {
        guard let cacheReadTokens else { return nil }
        let cacheable = inputTokens + cacheReadTokens + (cacheWriteTokens ?? 0)
        guard cacheable > 0 else { return nil }
        return Double(cacheReadTokens) / Double(cacheable)
    }
}

struct ImportantFileShortcut: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let action: String
}

/// View model for the canonical foldable thread of one conversation.
@MainActor
final class ThreadDetailViewModel: ObservableObject {

    private let logger = FloeLogger(category: .app)

    // MARK: - Published presentation state

    /// The conversation's runs, newest first.
    @Published private(set) var runs: [RunRecord] = [] { didSet { timelineRevision &+= 1 } }
    /// The run currently displayed (the one the user expanded / latest).
    @Published var selectedRunID: UUID? { didSet { timelineRevision &+= 1 } }
    /// Persisted events of the selected run, in sequence order.
    @Published private(set) var events: [RunEventRecord] = [] {
        didSet { cachedImportantFiles = nil }
    }
    @Published private(set) var eventsByRun: [UUID: [RunEventRecord]] = [:] { didSet { timelineRevision &+= 1 } }
    @Published private(set) var usageByRun: [UUID: [RunUsageRecord]] = [:]
    @Published private(set) var liveUsage = UsageSnapshot()
    @Published private(set) var latestUsage = UsageSnapshot()
    /// Live snapshot of the selected run, when the center owns it.
    @Published private(set) var liveStateName: String?
    @Published private(set) var approvalReviewSummary: String?
    @Published private(set) var liveReasoningText: String = ""
    /// Published mirror of StreamingTextAnimator.displayedText. SwiftUI
    /// observes this value, so every grapheme tick is actually rendered.
    @Published private(set) var liveStreamedText: String = ""
    @Published private(set) var hasProviderActivity = false
    /// Persisted messages of the conversation (user goals, final answers).
    @Published private(set) var messages: [PersistedMessage] = [] { didSet { timelineRevision &+= 1 } }
    @Published private(set) var hasLoaded = false
    @Published private(set) var earlierEventRunIDs = Set<UUID>() { didSet { timelineRevision &+= 1 } }
    @Published private(set) var loadingEventRunIDs = Set<UUID>()
    @Published private(set) var loadingEarlierMessages = false
    /// Composer draft text. Every real change (typing, dictation, a send's
    /// own clear, a failure restore) advances `draftGeneration`; a successful
    /// send clears the field only while that generation is unchanged, so a
    /// user who edits A → B → A during the await keeps the new A.
    @Published var draft: String = "" {
        didSet {
            guard draft != oldValue else { return }
            draftGeneration &+= 1
        }
    }
    /// Monotonic identity of the live composer text. See `draft`.
    private(set) var draftGeneration = 0
    private var draftHandoffObserver: AnyCancellable?
    /// Id membership indexes for the paged-in rows. Merging a page no longer
    /// rebuilds a dictionary over every loaded row just to dedup: pages are
    /// sequence-ordered, so only genuinely new rows are appended (earlier
    /// pages) or prepended (newer live rows).
    private var messageIDs = Set<UUID>()
    private var eventIDsByRun: [UUID: Set<UUID>] = [:]
    /// True only while launch acceptance is pending. The draft remains
    /// recoverable if launch fails; an accepted run consumes it immediately,
    /// independently of how long the provider continues running.
    @Published private(set) var isConsumingDraft = false
    @Published var selectedModelID: UUID?
    private var didRestoreConversationModel = false
    /// Workspace selected for the next run.
    @Published var selectedProjectID: UUID?
    /// Where the next run executes (local only until host tools land).
    @Published var executionTarget: AgentExecutionTarget = .local
    /// How the next run behaves (agent vs chat-only).
    @Published var agentMode: AgentExecutionMode = .agent
    /// The plan revision for which the user deliberately selected a different
    /// composer mode. Session refreshes must not invent an exit from Plan or
    /// overwrite this explicit per-turn choice.
    private var explicitModePlanRevision: Int?
    private var isAcceptingPlan = false
    /// Attachments staged in the composer.
    @Published var attachments: [AttachmentRef] = []
    /// Whether a run is currently non-terminal (drives Stop vs Send).
    @Published private(set) var isRunning = false
    /// Honest error surface for the last failed action.
    @Published private(set) var actionError: String?
    /// The parent row may disappear through another scene or history clear.
    /// When true the composer is removed and no follow-up can launch.
    @Published private(set) var isConversationMissing = false
    @Published private(set) var latestPlan: PlanDraft?
    @Published private(set) var taskChecklist: TaskChecklist?
    @Published private(set) var activeGoal: ConversationGoal?
    @Published private(set) var taskTitle: String = ""
    @Published private(set) var taskPolicy: TaskPolicy
    @Published private(set) var pendingInputs: [PendingUserInput] = []
    @Published var runningInputMode: RunningInputMode = .queue

    let conversationID: UUID
    let center: ConversationCenter

    // MARK: - Temporary chat

    /// Whether this conversation is the active ephemeral session. All store
    /// reads above already route through the center's session-aware helpers.
    var isTemporary: Bool {
        center.isTemporaryConversation(conversationID)
    }

    /// Keep-as-saved progress for the toolbar control.
    @Published private(set) var temporaryKeepState: TemporaryKeepState = .idle
    enum TemporaryKeepState: Equatable {
        case idle
        case saving
        /// The durable save committed but the stream tail is still
        /// forwarding: retry completes the remainder (never a false
        /// "nothing saved").
        case partialRetry
        case failed(String)
    }

    /// True while a temporary toggle-off handed an unedited ephemeral draft
    /// back to the ordinary composer: the visible text stays, but it must not
    /// reach the durable draft store until the user edits it again.
    private(set) var temporaryDraftHandoffPending = false

    // MARK: - Delegated children (durable projection)

    /// Durable delegated-child records for this conversation, read from the
    /// lifecycle owner's store. This is a read-only projection for the
    /// in-thread delegate cards; the child-agents inspector reads the SAME
    /// store, so there is exactly one source of truth.
    @Published private(set) var childRunRecords: [ChildRunRecord] = []
    private var childRunPollTask: Task<Void, Never>?
    private var lastChildRunRefresh: ContinuousClock.Instant?

    /// Delegated child record created by `delegateCallID` inside exactly
    /// `parentRunID`.
    ///
    /// Raw provider call ids are NOT unique across runs (the app's approval
    /// cards scope by `runID + callID` for the same reason), so a delegate
    /// card may only resolve a child whose parent run is the run that rendered
    /// the call; within one run the newest child wins when a provider repeats
    /// an id.
    func childRun(delegateCallID: String, parentRunID: UUID) -> ChildRunRecord? {
        ThreadRunScopedResolution.child(
            callID: delegateCallID, parentRunID: parentRunID, in: childRunRecords)
    }

    /// True when the selected run is durably parked because required
    /// background jobs are still outstanding. `checkpointed` alone is not
    /// proof: the run's own terminal status event carries the exact reason
    /// (`awaiting.finite.job:<ids>`), so this never guesses.
    var selectedRunWaitingForJobs: Bool {
        guard selectedRun?.state == "checkpointed",
              let status = events.last(where: { $0.kind == .status }) else { return false }
        let reason = ConversationCenter.decodePayload(status.payloadJSON)["reason"] ?? ""
        return reason.hasPrefix(FloeAgentRuntime.dependencyWaitReasonPrefix)
    }

    /// Available projects disappear in temporary mode (no workspace binding).
    var availableProjects: [ComposerProject] {
        guard !isTemporary else { return [] }
        return center.environment.workspaceCenter.projectWorkspaces.map(ComposerProject.init(record:))
    }

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
    @Published private(set) var hasEarlierMessages = false

    private var liveEventTask: Task<Void, Never>?
    private var messageCoverage = TimelinePageCoverage<ConversationMessageCursor>()
    private var eventCoverage: [UUID: TimelinePageCoverage<Int>] = [:]
    /// Run whose concrete runtime service is currently being observed. A
    /// durable run exists before attachment/vision preprocessing finishes,
    /// so `selectedRunID` alone cannot tell us whether the live subscription
    /// has actually been attached yet.
    private var observedServiceRunID: UUID?
    private var sessionEventTask: Task<Void, Never>?
    private var sessionRevision = -1
    private let diagnostics: ThreadStreamingDiagnostics

    init(conversationID: UUID, center: ConversationCenter) {
        self.conversationID = conversationID
        self.center = center
        self.taskPolicy = TaskPolicy(conversationID: conversationID)
        // Restore an unsent draft (and staged attachments) synchronously so
        // the first layout already shows them; the store was loaded from
        // disk at shared-init time.
        let stored = ComposerDraftStore.shared.entry(for: conversationID)
        _draft = Published(initialValue: stored?.text ?? "")
        _attachments = Published(initialValue: stored?.attachments ?? [])
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
        draftHandoffObserver = ComposerDraftStore.shared.$sendHandoffUpdate.dropFirst().sink { [weak self] update in
            guard let self, let update, update.conversationID == self.conversationID,
                  self.draftGeneration == 0 else { return }
            // A freshly reconstructed editor follows launch reconciliation.
            // Any real edit, including typing then deleting, owns a newer epoch.
            self.draft = update.entry?.text ?? ""
            self.attachments = update.entry?.attachments ?? []
        }
    }

    /// The currently selected run record, if any.
    var selectedRun: RunRecord? {
        if let selectedRunID, let run = runs.first(where: { $0.id == selectedRunID }) {
            return run
        }
        return runs.first
    }

    /// Files actually read or changed in the selected run, newest first.
    /// Directory listings and deleted paths are intentionally excluded: this
    /// strip is a focused working set, not a second file tree. The scan is
    /// computed once per `timelineRevision` (events/messages changes bump
    /// it) instead of per body evaluation — the strip was an O(events)
    /// decode on every render pass during streaming.
    var importantFiles: [ImportantFileShortcut] {
        if let cached = cachedImportantFiles { return cached }
        let value = computeImportantFiles()
        cachedImportantFiles = value
        return value
    }
    private var cachedImportantFiles: [ImportantFileShortcut]?

    private func computeImportantFiles() -> [ImportantFileShortcut] {
        let supportedTools: Set<String> = [
            "workspace.readFile", "workspace.inspectFileMetadata",
            "workspace.createFile", "workspace.writeFile", "workspace.applyPatch"
        ]
        var seen: Set<String> = []
        var result: [ImportantFileShortcut] = []
        for event in events.reversed() where event.kind == .toolResult {
            guard let data = event.payloadJSON.data(using: .utf8),
                  let payload = try? JSONDecoder().decode([String: String].self, from: data),
                  payload["status"] != "failed", payload["status"] != "error",
                  let tool = payload["tool"], supportedTools.contains(tool),
                  let summary = payload["summary"],
                  let path = Self.importantPath(from: summary),
                  !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(".."),
                  seen.insert(path).inserted else { continue }
            let action: String
            if tool == "workspace.readFile" || tool == "workspace.inspectFileMetadata" { action = FloeL10n.l("chat.thread_detail_view_model.view") }
            else if tool == "workspace.createFile" { action = FloeL10n.l("chat.thread_detail_view_model.new") }
            else { action = FloeL10n.l("chat.thread_detail_view_model.edit") }
            result.append(.init(path: path, action: action))
            if result.count == 8 { break }
        }
        return result
    }

    static func importantPath(from summary: String) -> String? {
        let candidates = [
            ("path=", [" offset=", "\n"]),
            ("created=", [" bytes=", "\n"]),
            ("written=", [" bytes=", "\n"]),
            ("patched=", [" hunks=", "\n"])
        ]
        for (marker, terminators) in candidates {
            guard let range = summary.range(of: marker) else { continue }
            let tail = summary[range.upperBound...]
            let end = terminators.compactMap { tail.range(of: $0)?.lowerBound }.min() ?? tail.endIndex
            let value = tail[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Pending approvals belonging to the selected run.
    var pendingApprovals: [PendingApproval] {
        guard let run = selectedRun else { return [] }
        return center.pendingApprovals.filter { $0.runID == run.id }
    }

    /// Whether the composer may send, queue or steer the current draft.
    /// Early-exit whitespace scan (no full trim/copy per keystroke).
    var canSend: Bool {
        !isConversationMissing
            && center.providerAndModel(modelID: selectedModelID) != nil
            && draft.contains(where: { !$0.isWhitespace })
    }

    var needsProvider: Bool {
        center.providerAndModel(modelID: selectedModelID) == nil
    }

    var availableModels: [ModelProfile] { center.availableAgentModels }

    var selectedModelName: String? {
        center.providerAndModel(modelID: selectedModelID)?.1.displayName
    }

    var usesLocalModel: Bool {
        center.providerAndModel(modelID: selectedModelID)?.0.kind == .local
    }

    var canContinue: Bool {
        guard !isRunning, let state = selectedRun?.state else { return false }
        // A run parked on required background work is NOT finished: Continue
        // must not resume it without the dependency (a user message still
        // steers/resumes it intentionally). It becomes continuable again if
        // the dependency settles to a terminal failure.
        if selectedRunWaitingForJobs { return false }
        return !center.hasLiveOwner(runID: selectedRun?.id)
            && ["failed", "interrupted", "checkpointed"].contains(state)
    }

    var continuationTitle: String {
        switch selectedRun?.state {
        case "failed": FloeL10n.l("chat.thread_detail_view_model.task_failed_you_can_continue_from")
        case "interrupted": FloeL10n.l("chat.thread_detail_view_model.task_interrupted")
        default: FloeL10n.l("runtime.conversation_run_service.task_checkpoint_saved")
        }
    }

    var continuationDetail: String {
        let reason = events.reversed().compactMap { event -> String? in
            guard event.kind == .status else { return nil }
            let payload = ConversationCenter.decodePayload(event.payloadJSON)
            return payload["reason"]?.isEmpty == false ? payload["reason"] : nil
        }.first
        let recovery = FloeL10n.l("chat.thread_detail_view_model.continues_the_original_task_and_message")
        return reason.map { "\($0)\n\(recovery)" } ?? recovery
    }

    /// The model's window is known before its first usage receipt arrives.
    /// Keep the toolbar available while waiting, without inventing token usage.
    var contextUsageSummary: ThreadUsageSummary? {
        if let usageSummary { return usageSummary }
        let modelID = selectedRun?.modelID ?? selectedModelID ?? center.modelPreferences.defaultAgentModelID
        let window = center.configuredModelProfile(modelID: modelID)?.limits.contextTokens ?? 0
        guard window > 0 else { return nil }
        return ThreadUsageSummary(
            inputTokens: 0, outputTokens: 0, contextTokens: 0,
            contextWindowTokens: window, isEstimatedLive: false
        )
    }

    var usageSummary: ThreadUsageSummary? {
        guard let run = selectedRun else { return nil }
        let records = usageByRun[run.id, default: []]
        let persistedInput = records.reduce(0) { $0 + $1.inputTokens }
        let persistedOutput = records.reduce(0) { $0 + $1.outputTokens }
        let persistedCacheRead = Self.sumReported(records.map(\.cacheReadTokens))
        let persistedCacheWrite = Self.sumReported(records.map(\.cacheWriteTokens))
        let persistedReasoning = Self.sumReported(records.map(\.reasoningTokens))
        let streamedEstimate = ComposerTokenEstimator.estimatedTokens(in: liveStreamedText)
        let currentOutput = max(liveUsage.outputTokens, streamedEstimate)
        let input = isRunning ? persistedInput + liveUsage.inputTokens : persistedInput
        let output = isRunning
            ? persistedOutput + currentOutput
            : persistedOutput
        guard input + output > 0 else { return nil }
        let modelID = run.modelID ?? selectedModelID
        let window = center.configuredModelProfile(modelID: modelID)?.limits.contextTokens ?? 0
        let currentContext = max(
            records.last.map {
                $0.inputTokens + $0.outputTokens
                    + ($0.cacheReadTokens ?? 0) + ($0.cacheWriteTokens ?? 0)
            } ?? 0,
            latestUsage.inputTokens + max(latestUsage.outputTokens, streamedEstimate)
                + (latestUsage.cacheReadTokens ?? 0) + (latestUsage.cacheWriteTokens ?? 0)
        )
        return ThreadUsageSummary(
            inputTokens: input,
            outputTokens: output,
            contextTokens: currentContext,
            contextWindowTokens: window,
            isEstimatedLive: isRunning && streamedEstimate > liveUsage.outputTokens,
            cacheReadTokens: Self.addReported(persistedCacheRead, isRunning ? liveUsage.cacheReadTokens : nil),
            cacheWriteTokens: Self.addReported(persistedCacheWrite, isRunning ? liveUsage.cacheWriteTokens : nil),
            reasoningTokens: Self.addReported(persistedReasoning, isRunning ? liveUsage.reasoningTokens : nil),
            tokensPerSecond: isRunning
                ? latestUsage.tokensPerSecond
                : records.compactMap(\.tokensPerSecond).last,
            timeToFirstTokenMs: isRunning
                ? latestUsage.timeToFirstTokenMs
                : records.compactMap(\.timeToFirstTokenMs).last,
            totalDurationMs: isRunning
                ? latestUsage.totalDurationMs
                : records.compactMap(\.totalDurationMs).last
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
        loadGeneration &+= 1
        let generation = loadGeneration
        let started = ContinuousClock.now
        let metrics = ThreadLoadMetrics()
        defer {
            metrics.finish()
            if generation == loadGeneration { hasLoaded = true }
        }
        actionError = nil
        var stage = "conversationRead"
        do {
            guard let conversation = try await center.conversationStore(for: conversationID)
                .conversation(id: conversationID) else {
                isConversationMissing = true
                runs = []
                messages = []
                events = []
                messageIDs = []
                eventIDsByRun = [:]
                eventsByRun = [:]
                stopLiveUpdates()
                return
            }
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            isConversationMissing = false
            taskTitle = conversation.title
            if !isTemporary {
                // A temporary chat never binds the shared browser surface or
                // records an owner run: the browser GUI and its session
                // handoffs are outside the ephemeral tool ceiling.
                center.environment.browserCenter.bind(to: conversationID)
            }
            selectedProjectID = center.environment.workspaceCenter.projectWorkspaceID(for: conversationID)
            stage = "runList"
            runs = try await center.runStore(for: conversationID).recentRuns(conversationID: conversationID, limit: 30)
            if let latest = runs.first {
                center.environment.browserCenter.recordOwnerRun(conversationID: conversationID, runID: latest.id)
            }
            stage = "messageList"
            let page = try await center.conversationStore(for: conversationID).messagePage(
                conversationID: conversationID, before: nil, limit: 20
            )
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            mergeMessagePage(page)
            hasLoaded = true
            logger.info("threadFirstPage elapsed=\(started.duration(to: .now)) messages=\(page.messages.count)")
            // Publish recent history before unrelated configuration and plan reads.
            if center.providers.isEmpty { await center.reload() }
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            if !didRestoreConversationModel {
                // A temporary session opened from the launchpad preserves the
                // launchpad's model selection until its first run exists.
                let preserved = isTemporary ? center.temporarySession?.preferredModelID : nil
                let previousModelID = runs.first?.modelID ?? preserved
                selectedModelID = center.providerAndModel(modelID: previousModelID) != nil
                    ? previousModelID
                    : center.modelPreferences.defaultAgentModelID
                didRestoreConversationModel = true
            }
            await center.environment.settingsCenter.loadRunningInputMode()
            runningInputMode = center.environment.settingsCenter.runningInputMode
            await center.environment.workspaceCenter.reload()
            selectedProjectID = center.environment.workspaceCenter.projectWorkspaceID(for: conversationID)
            stage = "visibleRunDetails"
            try await hydrateVisibleRunDetails()
            stage = "planLoad"
            if isTemporary {
                // Temporary conversations own no checklist/plan/goal records.
                taskChecklist = nil
                latestPlan = nil
            } else {
                taskChecklist = try await TaskChecklistStore(database: center.environment.database).latest(conversationID: conversationID)
                latestPlan = try await center.environment.intelligenceStore
                    .latestPlan(conversationID: conversationID)
            }
            // Restore Plan mode while an unfinished plan is still awaiting
            // review, so leaving and reopening a task never silently drops
            // the mode it was running in.
            reconcilePlanComposerMode()
            stage = "goalLoad"
            activeGoal = isTemporary ? nil : try await center.environment.intelligenceStore
                .goals(conversationID: conversationID).first
            stage = "pendingInputLoad"
            pendingInputs = try await center.runningInputStore(for: conversationID)
                .pending(conversationID: conversationID)
            // Preserve an explicit router/run selection. `runs` is newest
            // first, but unconditionally selecting its first item on every
            // refresh used to detach the UI from a just-launched run or from
            // the checkpoint the user explicitly opened.
            if selectedRunID.flatMap({ id in runs.first(where: { $0.id == id }) }) == nil {
                selectedRunID = runs.first?.id
            }
            stage = "latestRunDetails"
            try await loadSelectedRunDetails()
            await refreshChildRuns(force: true)
            startChildRunPollingIfNeeded()
            startSessionUpdates()
            startLiveUpdates()
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            actionError = presentableError(error, stage: stage)
        }
    }

    /// Selects a run and loads its persisted event thread.
    func selectRun(_ runID: UUID) async {
        selectedRunID = runID
        do {
            try await loadSelectedRunDetails()
        } catch {
            actionError = presentableError(error, stage: "selectRunEvents")
        }
        startLiveUpdates()
    }

    private func loadSelectedRunDetails() async throws {
        guard let runID = selectedRun?.id else {
            events = []
            return
        }
        async let selectedEvents = center.runStore(for: conversationID).recentEvents(
            runID: runID, limit: 51
        )
        async let selectedUsage = center.runStore(for: conversationID).usage(runID: runID)
        let (loadedEvents, loadedUsage) = try await (selectedEvents, selectedUsage)
        mergeEventPage(loadedEvents, runID: runID)
        events = eventsByRun[runID, default: []]
        usageByRun[runID] = loadedUsage
        // Historical failures already live in this run's ordered timeline.
        // Never resurrect one as a new composer error when it is selected.
        actionError = nil
    }

    /// Resolve headers only for the visible message window. Tool bodies stay
    /// lazy, including when the user pages beyond the recent run directory.
    private func hydrateVisibleRunDetails() async throws {
        var visibleRunIDs = Set(messages.compactMap(\.runID))
        if let selectedRunID { visibleRunIDs.insert(selectedRunID) }
        let known = Set(runs.map(\.id))
        for id in visibleRunIDs.subtracting(known) {
            if let header = try await center.runStore(for: conversationID).run(id: id), header.conversationID == conversationID {
                mergeRunHeaders([header])
            }
        }
        // Historical messages are immediately readable; fetch their tool
        // chains only when requested, not for every run in the page.
        earlierEventRunIDs.formUnion(visibleRunIDs.filter { eventsByRun[$0] == nil })
    }

    private func mergeRunHeaders(_ incoming: [RunRecord]) {
        var headers = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        var changed = false
        for header in incoming where headers[header.id] != header {
            headers[header.id] = header
            changed = true
        }
        // The session reconciliation pump republishes every two seconds;
        // an unchanged header set must not bump the timeline revision.
        guard changed else { return }
        runs = headers.values.sorted { ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString) }
    }

    func loadEarlierEvents(runID: UUID) async {
        guard loadingEventRunIDs.insert(runID).inserted else { return }
        defer { loadingEventRunIDs.remove(runID) }
        do {
            let before = eventCoverage[runID]?.earlierCursor
            let page: [RunEventRecord]
            let runStore = center.runStore(for: conversationID)
            if let before {
                page = try await runStore.earlierEvents(runID: runID, beforeSequence: before, limit: 51)
            } else {
                page = try await runStore.recentEvents(runID: runID, limit: 51)
            }
            mergeEventPage(page, runID: runID, before: before)
            let selected = eventsByRun[runID, default: []]
            if selectedRunID == runID, events != selected { events = selected }
        } catch { actionError = presentableError(error, stage: "olderEvents") }
    }

    func loadEarlierMessages() async {
        guard !loadingEarlierMessages, hasEarlierMessages, let earlierMessageCursor = messageCoverage.earlierCursor else { return }
        loadingEarlierMessages = true
        defer { loadingEarlierMessages = false }
        do {
            let page = try await center.conversationStore(for: conversationID).messagePage(
                conversationID: conversationID, before: earlierMessageCursor, limit: 30
            )
            mergeMessagePage(page, before: earlierMessageCursor)
            try await hydrateVisibleRunDetails()
        } catch {
            actionError = presentableError(error, stage: "olderMessages")
        }
    }

    /// Record page coverage separately from row identity. Merging only row IDs
    /// loses the cursor for gaps after reconnecting to a bounded live snapshot.
    private func mergeEventPage(_ page: [RunEventRecord], runID: UUID, before: Int? = nil) {
        let tail = Array(page.suffix(50))
        eventCoverage[runID, default: .init()].record(
            first: tail.first?.sequence, last: tail.last?.sequence,
            before: before, hasEarlier: page.count > 50
        )
        let existing = eventsByRun[runID, default: []]
        let known = eventIDsByRun[runID, default: []]
        var added: [RunEventRecord] = []
        var knownUpdated = known
        for event in tail where knownUpdated.insert(event.id).inserted {
            added.append(event)
        }
        guard !added.isEmpty else {
            if eventCoverage[runID]?.earlierCursor != nil { earlierEventRunIDs.insert(runID) }
            else { earlierEventRunIDs.remove(runID) }
            return
        }
        eventIDsByRun[runID] = knownUpdated
        let merged: [RunEventRecord]
        if existing.isEmpty {
            merged = added
        } else if added.last!.sequence <= existing.first!.sequence {
            // An earlier page: its rows precede everything loaded.
            merged = added + existing
        } else if existing.last!.sequence <= added.first!.sequence {
            // A newest page: its rows follow everything loaded.
            merged = existing + added
        } else {
            // Interleave after a reconnect gap: rare; keep the exact
            // sequence order over the merged superset.
            merged = (existing + added).sorted { $0.sequence < $1.sequence }
        }
        eventsByRun[runID] = merged
        if eventCoverage[runID]?.earlierCursor != nil { earlierEventRunIDs.insert(runID) }
        else { earlierEventRunIDs.remove(runID) }
    }

    private func mergeMessagePage(_ page: ConversationMessagePage, before: ConversationMessageCursor? = nil) {
        func cursor(_ message: PersistedMessage) -> ConversationMessageCursor {
            .init(createdAt: message.createdAt, messageID: message.id)
        }
        messageCoverage.record(first: page.messages.first.map(cursor), last: page.messages.last.map(cursor),
                               before: before, hasEarlier: page.hasEarlier)
        let existing = messages
        var added: [PersistedMessage] = []
        for message in page.messages where messageIDs.insert(message.id).inserted {
            added.append(message)
        }
        guard !added.isEmpty else {
            hasEarlierMessages = messageCoverage.earlierCursor != nil
            return
        }
        let merged: [PersistedMessage]
        if existing.isEmpty {
            merged = added
        } else if cursor(added.last!) <= cursor(existing.first!) {
            // An earlier page (or an earlier reconnect snapshot): prepend.
            merged = added + existing
        } else if cursor(existing.last!) <= cursor(added.first!) {
            // The newest page: append after everything loaded.
            merged = existing + added
        } else {
            // Out-of-order overlap after reconnect: rare; restore the exact
            // cursor order over the merged superset.
            merged = (existing + added).sorted { cursor($0) < cursor($1) }
        }
        messages = merged
        hasEarlierMessages = messageCoverage.earlierCursor != nil
    }

    func dismissActionError() {
        actionError = nil
    }

    private var timelineRevision: UInt64 = 0
    private struct TimelineKey: Equatable {
        var revision: UInt64
        var running: Bool
        var hasText: Bool
        var hasReasoning: Bool
        var approvals: [PendingApproval]
    }
    private var cachedTimelineKey: TimelineKey?
    private var cachedTimeline: [ThreadTimelineItem] = []
    private var cachedDecisionAnnotations: [ToolDecisionAnnotation] = []
    private(set) var timelineBuildCount = 0
    private var cachedTimelineIDs: [String] = []
    var timelineIDs: [String] { _ = timeline; return cachedTimelineIDs }
    private var loadGeneration: UInt64 = 0

    /// The unified, sequence-ordered timeline for the selected run.
    var timeline: [ThreadTimelineItem] {
        let approvals = pendingApprovals
        let key = TimelineKey(revision: timelineRevision, running: showsLiveTail,
            hasText: !liveStreamedText.isEmpty, hasReasoning: !liveReasoningText.isEmpty,
            approvals: approvals)
        if cachedTimelineKey == key { return cachedTimeline }
        let visibleRunIDs = Set(messages.compactMap(\.runID))
            .union(selectedRunID.map { [$0] } ?? [])
        // Decision notices are projected from the same revision as the
        // timeline: a validated automatic tool decision becomes an annotation
        // on its tool step (standalone row suppressed), while an
        // uncorrelated/manual decision keeps its concise standalone row.
        // Correlation is restricted to the runs this projection actually
        // renders, so a notice can never be suppressed by an event whose step
        // is not on screen.
        let notices = ProposalDecisionPresentation.notices(
            messages: messages,
            events: eventsByRun
                .filter { visibleRunIDs.contains($0.key) }
                .values
                .flatMap { $0 }
        )
        cachedDecisionAnnotations = notices.compactMap(\.annotation)
        cachedTimeline = ThreadTimelineBuilder.buildConversation(
            messages: messages,
            runs: runs.filter { visibleRunIDs.contains($0.id) },
            eventsByRun: eventsByRun,
            liveRunID: selectedRun?.id,
            isRunning: showsLiveTail,
            liveStreamedText: liveStreamedText,
            liveReasoningText: liveReasoningText,
            pendingApprovals: pendingApprovals,
            earlierEventRunIDs: earlierEventRunIDs,
            suppressedDecisionNoticeIDs: Set(
                notices.filter { $0.automaticCallID != nil }.map(\.id))
        )
        cachedTimelineKey = key
        cachedTimelineIDs = cachedTimeline.map(\.id)
        timelineBuildCount += 1
        return cachedTimeline
    }

    /// Decision records projected onto their tool calls for the current
    /// timeline revision. Filled by `timeline`, so a view that reads it from
    /// a rendered timeline row sees exactly that revision.
    var decisionAnnotations: [ToolDecisionAnnotation] { cachedDecisionAnnotations }

    /// The live tail stays mounted while the run is active OR while the
    /// animator drains a terminal remainder — the final bubble never
    /// flickers or disappears before the persisted reply takes over.
    var showsLiveTail: Bool {
        isRunning || isDraining
    }

    // MARK: - Actions

    /// Sends through the canonical conversation lifecycle. Canvas and future
    /// focused surfaces may supply a contextual goal while retaining the same
    /// run owner, queue/steer path, checkpoint recovery, and live projection.
    func send(
        goalOverride: String? = nil,
        runSurface: AgentRunSurface = .ordinary,
        canvasContext: CanvasRunContextSeed? = nil
    ) async {
        let goal = (goalOverride ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        reconcilePlanComposerMode()
        // Temporary conversations send the ordinary agent turn: tools stay
        // enabled and the immutable public-web ceiling in ConversationCenter
        // (TemporaryChatToolPolicy + descriptor projection) is the authority
        // that decides what the model may call.
        let executionMode = effectiveAgentMode
        guard !isConversationMissing, !goal.isEmpty,
              let (provider, model) = center.providerAndModel(modelID: selectedModelID) else { return }
        let projectIDAtSend = selectedProjectID
        let modelIDAtSend = selectedModelID
        let inputModeAtSend = runningInputMode
        // Build 283: the Office assistant no longer receives a MANDATORY
        // per-send viewport screenshot. A default send carries the user's
        // text, the task context and the selected-document grant exactly as
        // before; the assistant inspects specific document regions (visible
        // OR offscreen) deliberately through notes.read section=officeRegion,
        // whose real PNG artifacts reach the next provider request. Actual
        // user-staged attachments and every other mode are unchanged.
        let stagedAttachments = attachments
        // Temporary chat is text-only: the launch carries no attachments
        // while the staged files stay in the composer (and the ordinary
        // draft) untouched — the center also refuses a nonempty temporary
        // attachment request before any store/provider effect.
        let launchAttachments = isTemporary ? [] : stagedAttachments
        // Send-origin identity, captured BEFORE the first await: a send that
        // belongs to a temporary session is bound to that exact session
        // incarnation. A late success/failure (the session was Ended, or a
        // replacement session reuses the same conversation id) must never
        // restore, save, clear or persist this send's draft into another
        // generation's bucket. Ordinary sends are never gated.
        let sendOrigin = SendOrigin(
            conversationID: conversationID,
            temporaryIncarnation: isTemporary ? center.temporarySession?.incarnation : nil
        )
        // The complete original draft is kept so a failure — including a
        // context-budget rejection — restores every character, never a
        // trimmed or truncated version.
        let originalDraft = draft
        // A Canvas/contextual goal owns its own prompt; only a send that
        // actually consumed the composer draft may clear or restore it.
        let consumesComposerDraft = goalOverride == nil
        isConsumingDraft = consumesComposerDraft
        defer { isConsumingDraft = false }
        actionError = nil
        // Identity of this send's claim on the field and on the stored
        // draft, captured at the entrypoint that consumed it. Text equality
        // is not identity: the user can edit A → B → A while the send is in
        // flight, and a success must never erase that new draft.
        func makeCommit() -> ComposerSendCommit? {
            guard consumesComposerDraft else { return nil }
            return ComposerSendCommit(
                draft: originalDraft,
                // Only user-staged files belong to the composer receipt.
                // A live Office page is context for this request and must
                // never be restored as a stale user-picked attachment.
                attachments: launchAttachments,
                editorGeneration: draftGeneration,
                conversationID: conversationID
            )
        }
        if isRunning, let expectedRunID = selectedRun?.id {
            // The running-input path keeps the field until the submit lands,
            // so the identity is captured before the await.
            let commit = makeCommit()
            do {
                try await center.submitRunningInput(
                    content: goal,
                    in: conversationID,
                    expectedRunID: expectedRunID,
                    mode: inputModeAtSend,
                    selectedModelID: modelIDAtSend,
                    workspaceID: projectIDAtSend,
                    executionMode: executionMode,
                    attachments: launchAttachments
                )
                if let commit, sendOriginAllowsDraftMutation(sendOrigin) {
                    consumeSentDraft(commit)
                }
                pendingInputs = try await center.runningInputStore(for: conversationID)
                    .pending(conversationID: conversationID)
            } catch {
                actionError = presentableError(error, stage: "submitRunningInput")
            }
            return
        }
        if consumesComposerDraft { draft = "" }
        // Captured after the send's own clear: from here only user edits
        // advance the generation.
        let commit = makeCommit()
        commit?.beginLaunch()
        isConsumingDraft = false
        var launchAccepted = false
        do {
            let started = try await center.startRun(
                goal: goal,
                in: conversationID,
                provider: provider,
                model: model,
                workspaceID: projectIDAtSend,
                attachments: launchAttachments,
                executionMode: executionMode,
                runSurface: runSurface,
                canvasContext: canvasContext,
                startOrigin: .explicitUserAction
            )
            // The run now owns the submitted message. Clear its durable
            // draft before awaiting the provider, so leaving and returning
            // while it runs cannot restore an already-sent prompt.
            launchAccepted = true
            if let commit, sendOriginAllowsDraftMutation(sendOrigin) {
                commit.acceptLaunch()
                draft = commit.draftAfterSuccess(currentDraft: draft, currentGeneration: draftGeneration)
                attachments = commit.attachmentsAfterSuccess(current: attachments)
            }
            // From here, emptying a newly typed draft is a real user edit,
            // not the launch's programmatic clear. Persist it normally.
            isConsumingDraft = false
            // The atomic launch returns a durable run identity immediately.
            // Subscribe before awaiting the provider loop so the UI no longer
            // waits for the first token or races a very fast completion.
            mergeRunHeaders(try await center.runStore(for: conversationID).recentRuns(conversationID: conversationID, limit: 30))
            selectedRunID = started.runID
            try await loadSelectedRunDetails()
            startLiveUpdates()
            switch await started.result.value {
            case .success:
                break
            case .failure(let error):
                throw error
            }
            await load()
        } catch {
            // Once accepted, a failed provider turn is already visible in
            // history and must not put the sent text back into the composer.
            if !launchAccepted, let commit, sendOriginAllowsDraftMutation(sendOrigin) {
                let restored = commit.failLaunch(allowTextRecovery: commit.editorStillConsumed(currentGeneration: draftGeneration))
                if restored {
                    draft = ComposerDraftStore.shared.text(for: conversationID)
                    attachments = ComposerDraftStore.shared.attachments(for: conversationID)
                }

            }
            actionError = presentableError(error, stage: "startOrCompleteRun")
        }
    }

    /// Clears exactly the draft content a successful send consumed. Text and
    /// attachments staged while the send was in flight stay bound to the
    /// conversation; the field and the draft store each compare the identity
    /// captured at send start, so a retyped A → B → A is never erased. The
    /// draft store keeps a revision floor so a stale async merge can never
    /// resurrect the cleared revision.
    private func consumeSentDraft(_ commit: ComposerSendCommit) {
        draft = commit.draftAfterSuccess(
            currentDraft: draft,
            currentGeneration: draftGeneration
        )
        attachments = commit.attachmentsAfterSuccess(current: attachments)
        commit.commitStore()
    }

    func selectAgentMode(_ mode: AgentExecutionMode) {
        explicitModePlanRevision = latestPlan.flatMap(Self.activePlanRevision)
        agentMode = mode
    }

    // MARK: - Temporary chat actions

    /// The temporary-session identity a send started from. A send that
    /// belongs to no temporary session (ordinary conversation) is never
    /// gated: ordinary failure recovery is unchanged.
    private struct SendOrigin {
        let conversationID: UUID
        let temporaryIncarnation: UUID?
    }

    /// True while a late send callback may still mutate this conversation's
    /// drafts. A temporary send may do so only while its exact session
    /// incarnation is still active — or after that same identity was
    /// successfully promoted, when the conversation is a normal saved chat
    /// and ordinary recovery applies. A destroyed session (End) or a
    /// same-id replacement generation must never restore, save or clear
    /// another generation's draft.
    private func sendOriginAllowsDraftMutation(_ origin: SendOrigin) -> Bool {
        guard let incarnation = origin.temporaryIncarnation else { return true }
        if let session = center.temporarySession,
           session.conversation.id == origin.conversationID {
            return session.incarnation == incarnation
        }
        return center.lastPromotedConversationID == origin.conversationID
    }

    /// Where the UI should navigate after a toggle, if anywhere.
    enum TemporaryNavigation: Equatable {
        case openConversation(UUID)
        case openNewTask
        var id: UUID {
            switch self {
            case .openConversation(let id): id
            case .openNewTask: UUID()
            }
        }
    }

    /// Toggles temporary mode for this conversation. The New Task launchpad
    /// (`home.temporary.toggle`) is the ONLY UI entry that starts a temporary
    /// chat; this programmatic toggle remains for an explicit in-thread
    /// conversion (empty conversations convert in place, populated ones spawn
    /// a separate session) and for the lifecycle tests. Returns the
    /// navigation target when the visible conversation changes.
    @discardableResult
    func toggleTemporaryChat() async -> TemporaryNavigation? {
        do {
            let outcome = try await center.toggleTemporaryChat(for: conversationID)
            switch outcome {
            case .temporaryActive(let id):
                if id != conversationID {
                    // Separate session: the caller swaps the visible thread.
                    return .openConversation(id)
                }
                // In-place conversion: the same view switches to ephemeral.
                temporaryDraftHandoffPending = false
                return nil
            case .restoredOrdinary(let id):
                if id != conversationID {
                    return .openConversation(id)
                }
                // Hand the RAM draft back without persisting it yet.
                temporaryDraftHandoffPending = !draft.isEmpty
                return nil
            case .requiresExplicitAction:
                // Messages exist: only End / Keep as saved may leave.
                return nil
            }
        } catch {
            actionError = presentableError(error, stage: "toggleTemporaryChat")
            return nil
        }
    }

    /// Ends the temporary chat: cancels owned runs and discards RAM content.
    /// A launchpad-direct session leaves no durable conversation, so the
    /// caller returns to the fresh-task surface. The action binds to THIS
    /// view's conversation identity: a late callback from an old view can
    /// never destroy a replacement session.
    @discardableResult
    func endTemporaryChat() async -> TemporaryNavigation? {
        guard isTemporary,
              let session = center.temporarySession,
              session.conversation.id == conversationID else {
            return nil
        }
        // Bind the destroy to the exact session epoch this view is showing:
        // a replacement session that reuses the same conversation id must
        // never be destroyed by this view's late callback.
        let boundID = conversationID
        let boundIncarnation = session.incarnation
        let target = await center.endTemporaryChat(
            expectedConversationID: boundID,
            expectedIncarnation: boundIncarnation
        )
        switch target {
        case .conversation(let id):
            temporaryKeepState = .idle
            temporaryDraftHandoffPending = false
            return .openConversation(id)
        case .newTask:
            temporaryKeepState = .idle
            temporaryDraftHandoffPending = false
            return .openNewTask
        case .unavailable:
            // The identity this view ended is no longer the active session
            // (a replacement already exists): a stale callback must not
            // mutate this view's Keep surface or navigate anywhere.
            return nil
        }
    }

    /// Keeps the temporary conversation as an ordinary saved chat. Atomic
    /// and idempotent; a failure leaves the RAM session fully recoverable.
    /// Binds to this view's conversation identity so a stale callback from
    /// an old view cannot promote a replacement session; every completion
    /// mutation is additionally gated on the center confirming THIS identity
    /// as the operation's outcome (a leave + replacement in the meantime
    /// must not be reflected here as success/retry).
    func keepTemporaryChat() async {
        guard temporaryKeepState != .saving else { return }
        guard isTemporary,
              let session = center.temporarySession,
              session.conversation.id == conversationID else {
            return
        }
        let boundID = conversationID
        // Epoch binding: a stale Keep from this view can never promote a
        // replacement generation that reuses the same conversation id.
        let boundIncarnation = session.incarnation
        temporaryKeepState = .saving
        actionError = nil
        do {
            _ = try await center.keepTemporaryChat(
                expectedConversationID: boundID,
                expectedIncarnation: boundIncarnation
            )
            // The save settled for this exact identity only if the center
            // recorded it as the promoted conversation. A session destroyed
            // while this save was in flight (leave + replacement) returns
            // committed truth without owning this view; do not flip state,
            // migrate drafts or reload on its behalf.
            guard center.lastPromotedConversationID == boundID else { return }
            temporaryKeepState = .idle
            temporaryDraftHandoffPending = false
            // Reload from the now-durable stores; identity is unchanged.
            await load()
        } catch ConversationCenter.TemporaryKeepError.tailPending {
            // Committed save, tail still syncing: the honest UI state — but
            // only while this identity is still the live temporary session.
            guard center.isTemporaryConversation(boundID) else { return }
            temporaryKeepState = .partialRetry
        } catch {
            guard center.isTemporaryConversation(boundID) else { return }
            let message = error.localizedDescription
            temporaryKeepState = .failed(message)
            actionError = presentableError(error, stage: "keepTemporaryChat")
        }
    }

    /// The mode a temporary conversation actually sends with. It must keep
    /// tools ENABLED: forcing `.chat` disabled tool execution entirely, which
    /// silently contradicted the audited read-only ceiling the temporary
    /// request is supposed to enforce. A temporary chat therefore runs the
    /// ordinary `.agent` turn (never plan/goal, whose durable records a
    /// temporary session never writes) and the immutable ceiling in
    /// ConversationCenter narrows the catalog to verified reads.
    var effectiveAgentMode: AgentExecutionMode {
        isTemporary ? .agent : agentMode
    }

    /// Draft-store write gate for the composer: after a temporary toggle-off,
    /// text typed during the ephemeral phase must not flush until the user
    /// edits it again (a real change re-arms ordinary persistence).
    var shouldPersistDraftEdits: Bool {
        !temporaryDraftHandoffPending
    }

    /// Called by the composer on every real draft change; the first edit
    /// after a handoff re-arms ordinary draft persistence.
    func noteDraftEditedByUser() {
        if temporaryDraftHandoffPending {
            temporaryDraftHandoffPending = false
        }
    }

    /// Explicit user reconciliation for this conversation's durable media jobs
    /// (submitted through `video.generate`). Polls every non-terminal job once
    /// and surfaces any user-presentable error through `actionError`. A job
    /// whose status query is temporarily unavailable keeps its prior durable
    /// state and is picked up by the next automatic or explicit reconcile; it
    /// never changes the overall task state.
    func refreshMediaJobs() async {
        let store = MediaGenerationJobStore(database: center.environment.database)
        guard let jobs = try? await store.jobs(owner: .conversation(conversationID)) else {
            actionError = FloeL10n.l("chat.thread_detail_view_model.media_task_status_is_temporarily_unavailable")
            return
        }
        var firstError: String?
        for job in jobs where !job.state.isTerminal {
            do {
                _ = try await center.environment.mediaGenerationService.refreshVideoJob(jobID: job.id)
            } catch {
                firstError = firstError ?? error.localizedDescription
            }
        }
        if let firstError {
            actionError = FloeL10n.l("chat.thread_detail_view_model.some_media_task_statuses_could_not", firstError)
        }
    }

    private static func activePlanRevision(_ plan: PlanDraft) -> Int? {
        (plan.status == .awaitingInput || plan.status == .ready) ? plan.revision : nil
    }

    private func reconcilePlanComposerMode() {
        guard let plan = latestPlan,
              let revision = Self.activePlanRevision(plan),
              explicitModePlanRevision != revision else { return }
        agentMode = .plan
    }

    /// Cancels the selected run.
    func cancel() async {
        guard let runID = selectedRun?.id else { return }
        // Stop the composer immediately; persistence/live events will still
        // deliver the authoritative cancelled terminal state afterwards.
        isRunning = false
        actionError = nil
        await center.cancel(runID: runID)
    }

    @Published private(set) var compactionStatus: String?
    @Published private(set) var isCompacting = false

    func requestManualCompaction() {
        guard !isCompacting else { return }
        isCompacting = true
        compactionStatus = FloeL10n.l("chat.thread_detail_view_model.compacting_context")
        Task {
            defer { isCompacting = false }
            do {
                compactionStatus = try await center.requestManualCompaction(conversationID: conversationID, modelID: selectedModelID)
            } catch {
                compactionStatus = FloeL10n.l("chat.thread_detail_view_model.compaction_did_not_finish", error.localizedDescription)
            }
        }
    }

    func exportStructuredConversation() async -> (url: URL, lease: ScratchLeaseToken)? {
        do { return try await center.exportStructuredConversation(conversationID: conversationID) }
        catch { actionError = FloeL10n.l("chat.thread_detail_view_model.export_did_not_finish", error.localizedDescription); return nil }
    }

    func editPendingInput(_ input: PendingUserInput, content: String) async {
        do {
            try await center.editPendingInput(id: input.id, content: content)
            pendingInputs = try await center.runningInputStore(for: conversationID).pending(conversationID: conversationID)
        } catch { actionError = error.localizedDescription }
    }

    func removePendingInput(_ input: PendingUserInput) async {
        do {
            try await center.removePendingInput(id: input.id)
            pendingInputs = try await center.runningInputStore(for: conversationID).pending(conversationID: conversationID)
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
            pendingInputs = try await center.runningInputStore(for: conversationID).pending(conversationID: conversationID)
        } catch { actionError = error.localizedDescription }
    }

    func promotePendingInput(_ input: PendingUserInput) async {
        guard let runID = selectedRun?.id, isRunning else { return }
        do {
            try await center.promoteToSteer(inputID: input.id, expectedRunID: runID)
            pendingInputs = try await center.runningInputStore(for: conversationID).pending(conversationID: conversationID)
        } catch { actionError = error.localizedDescription }
    }

    /// Resumes the selected durable run without duplicating its user message.
    func retry() async {
        guard let runID = selectedRun?.id else { return }
        actionError = nil
        do {
            let started = try await center.retry(
                runID: runID,
                startOrigin: .explicitUserAction
            )
            mergeRunHeaders(try await center.runStore(for: conversationID).recentRuns(conversationID: conversationID, limit: 30))
            selectedRunID = started.runID
            try await loadSelectedRunDetails()
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
            return FloeL10n.l("chat.thread_detail_view_model.failed_to_read_task_data_choose", stage)
        }
        if let floeError = error as? FloeError,
           case .syncUnavailable(let reason) = floeError {
            if reason.localizedCaseInsensitiveContains("approval") {
                return FloeL10n.l("chat.thread_detail_view_model.the_auto_approval_model_is_temporarily")
            }
            return FloeL10n.l("chat.thread_detail_view_model.the_sync_service_is_temporarily_unavailable")
        }
        return error.localizedDescription
    }

    /// Resolves a pending approval on this thread.
    func resolve(_ approval: PendingApproval, decision: ApprovalDecision) async {
        await center.resolve(approval, decision: decision)
    }

    func acceptLatestPlan(as execution: PlanExecutionRecommendation? = nil) async {
        guard let latestPlan else { return }
        guard latestPlan.status == .ready, latestPlan.isDecisionComplete else {
            actionError = FloeL10n.l("chat.thread_detail_view_model.the_plan_still_needs_revision_and")
            return
        }
        guard !isAcceptingPlan, !isRunning,
              let (provider, model) = center.providerAndModel(modelID: selectedModelID) else {
            actionError = FloeL10n.l("chat.thread_detail_view_model.choose_an_available_model_first_and")
            return
        }
        isAcceptingPlan = true
        defer { isAcceptingPlan = false }
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
            let criteria = accepted.acceptanceCriteria.map {FloeL10n.l("chat.thread_detail_view_model.verified", $0.text, $0.verification)
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
                executionMode: selectedExecution == .goal ? .goal : .agent,
                startOrigin: .explicitUserAction
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
            actionError = FloeL10n.l("chat.thread_detail_view_model.choose_an_available_model_first_and")
            return
        }
        let cleanCriteria = criteria.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let goalCriteria = cleanCriteria.isEmpty
            ? [FloeL10n.l("chat.thread_detail_view_model.the_goal_was_verified_with_inspectable")]
            : cleanCriteria
        let goal = ConversationGoal(
            conversationID: conversationID,
            objective: cleanObjective,
            blockingConditions: blockingConditions.filter { !$0.isEmpty },
            stoppingConditions: stoppingConditions.filter { !$0.isEmpty },
            acceptanceCriteria: goalCriteria.map { GoalCriterion(text: $0) },
            steps: [GoalStep(title: FloeL10n.l("chat.thread_detail_view_model.advance_goal"), status: .inProgress, order: 0)],
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
                executionMode: .goal,
                startOrigin: .explicitUserAction
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
            actionError = FloeL10n.l("chat.thread_detail_view_model.steps_acceptance_evidence_or_checklist_items")
            return
        }
        goal.status = .completed
        goal.updatedAt = Date()
        do {
            try await center.environment.intelligenceStore.saveGoal(goal)
            activeGoal = goal
        } catch { actionError = error.localizedDescription }
    }

    // MARK: - Delegated child refresh

    /// Refresh the durable child records behind the delegate cards. Throttled
    /// because the session push stream can tick many times per second; the
    /// bounded `childRunPollTask` below covers live states in between.
    private func refreshChildRuns(force: Bool = false) async {
        let now = ContinuousClock.now
        if !force, let last = lastChildRunRefresh, now - last < .seconds(1) { return }
        lastChildRunRefresh = now
        do {
            childRunRecords = try await SQLiteChildRunStore(database: center.environment.database)
                .children(conversationID: conversationID)
        } catch {
            // Presentation projection only: keep the previous records rather
            // than blanking the cards on a transient read failure. The
            // inspector reports its own load errors explicitly.
        }
    }

    /// Bounded visible-thread polling while any loaded child is non-terminal,
    /// so a card never keeps showing "working" after the child finished (or
    /// "done" while it is still running when no change hook fires). Stops as
    /// soon as every child is terminal and when the thread view is left.
    private func startChildRunPollingIfNeeded() {
        guard childRunPollTask == nil else { return }
        guard childRunRecords.contains(where: { !$0.state.isTerminal }) else { return }
        childRunPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                await self.refreshChildRuns(force: true)
                if !self.childRunRecords.contains(where: { !$0.state.isTerminal }) {
                    self.childRunPollTask = nil
                    return
                }
            }
        }
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
                let wasFollowingLatest = self.selectedRunID == self.runs.first?.id
                self.taskTitle = snapshot.conversation.title
                self.mergeMessagePage(ConversationMessagePage(
                    messages: snapshot.messages, earlierCursor: snapshot.earlierMessageCursor,
                    hasEarlier: snapshot.hasEarlierMessages
                ))
                self.mergeRunHeaders(snapshot.runs)
                for (runID, incoming) in snapshot.eventsByRun {
                    self.mergeEventPage(incoming, runID: runID)
                }
                self.earlierEventRunIDs.formUnion(self.messages.compactMap(\.runID).filter { self.eventsByRun[$0] == nil })
                if wasFollowingLatest || self.selectedRunID.flatMap({ id in
                    self.runs.first(where: { $0.id == id })
                }) == nil {
                    self.selectedRunID = snapshot.runs.first?.id
                }
                let selectedEvents = self.selectedRunID.flatMap { self.eventsByRun[$0] } ?? []
                if self.events != selectedEvents {
                    self.events = selectedEvents
                }
                self.latestPlan = snapshot.latestPlan
                self.taskChecklist = snapshot.taskChecklist
                // Keep Plan mode in sync when a plan becomes ready or still
                // awaits input, so reopening never drops the active mode.
                self.reconcilePlanComposerMode()
                self.activeGoal = snapshot.activeGoal
                self.taskPolicy = snapshot.taskPolicy
                self.pendingInputs = snapshot.pendingInputs
                await self.refreshChildRuns()
                self.startChildRunPollingIfNeeded()
                let serviceBecameAvailable = self.selectedRunID.flatMap {
                    center.service(for: $0) != nil && self.observedServiceRunID != $0
                } ?? false
                if previousRunID != self.selectedRunID || serviceBecameAvailable {
                    self.startLiveUpdates()
                } else if self.observedServiceRunID == nil, let run = self.selectedRun {
                    self.liveStateName = run.state
                    self.isRunning = !RunStateLocalizer.isTerminal(run.state)
                }
            }
        }
    }

    private func startLiveUpdates() {
        liveEventTask?.cancel()
        observedServiceRunID = nil
        liveStreamedText = ""
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
                // Atomic launch deliberately persists the run before
                // attachment/vision preparation creates its runtime service.
                // That gap is still a live task, not a pause/failure.
                self.isRunning = center.hasLiveOwner(runID: run.id)
                    || !RunStateLocalizer.isTerminal(run.state)
                self.isDraining = false
                return
            }
            self.observedServiceRunID = run.id

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
                    if state == .compacting { self.compactionStatus = FloeL10n.l("chat.thread_detail_view_model.auto_compacting_context") }
                    else if self.compactionStatus == FloeL10n.l("chat.thread_detail_view_model.auto_compacting_context") {
                        self.compactionStatus = FloeL10n.l("chat.thread_detail_view_model.the_compaction_check_finished_without_replacing")
                    }
                    self.isRunning = ![.completed, .cancelled, .failed, .interrupted].contains(state)
                case .contextCompacted(let record):
                    self.compactionStatus = FloeL10n.l("chat.thread_detail_view_model.context_compacted_about_tokens", record.beforeEstimatedTokens, record.afterEstimatedTokens)
                case .livenessChanged(let snapshot):
                    if snapshot.phase == .compacting {
                        self.compactionStatus = FloeL10n.l("chat.thread_detail_view_model.auto_compacting_context")
                        self.liveStateName = "compacting"
                    }
                case .approvalReviewChanged(let snapshot):
                    self.approvalReviewSummary = snapshot.isEvaluating
                        ? nil
                        : snapshot.outcomeSummary
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
                    self.liveUsage.totalDurationMs = usage.totalDurationMs
                    self.liveUsage.timeToFirstTokenMs = usage.timeToFirstTokenMs
                    self.liveUsage.tokensPerSecond = usage.tokensPerSecond
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
        // "thinking" state merely because historical runs were not prefetched.
        guard !Task.isCancelled else { return }
        if let page = try? await center.conversationStore(for: conversationID).messagePage(
            conversationID: conversationID, before: nil, limit: 20
        ) {
            mergeMessagePage(page)
        }
        if let latestRuns = try? await center.runStore(for: conversationID)
            .recentRuns(conversationID: conversationID, limit: 30) {
            mergeRunHeaders(latestRuns)
        }
        // Refresh only the selected run. Other run details remain lazy and are
        // loaded by `selectRun`, so completion remains bounded on long tasks.
        try? await loadSelectedRunDetails()
        if selectedRunID == runID {
            liveStateName = runs.first(where: { $0.id == runID })?.state ?? liveStateName
        }
    }

    func stopLiveUpdates() {
        liveEventTask?.cancel()
        liveEventTask = nil
        observedServiceRunID = nil
        sessionEventTask?.cancel()
        sessionEventTask = nil
        childRunPollTask?.cancel()
        childRunPollTask = nil
        // Leaving the thread stops the animation immediately; the partial
        // display is discarded with the live tail, persisted rows reload
        // from the store on the next open.
        animator.cancel()
        reasoningAnimator.cancel()
        isDraining = false
        isRunning = false
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
