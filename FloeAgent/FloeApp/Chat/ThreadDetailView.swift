// FloeApp — Canonical foldable thread detail.
//
// SPDX-License-Identifier: MPL-2.0
//
// One conversation's execution thread: persisted run events in sequence
// order, a live snapshot while the selected run is non-terminal, pending
// approval cards, and a composer (glass) for the next run. Every state —
// loading, streaming, waiting-approval, failed, terminal — is explicit;
// nothing invents live data.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime
import FloeCore

private struct ThreadScrollMetrics: Equatable {
    let offset: Double
    let height: Double
    let bottomDistance: Double
}

/// A user-selected context staged for review in the regular composer; never auto-sends.
struct ThreadComposerInput: Identifiable {
    let id = UUID()
    let text: String
    let attachments: [AttachmentRef]
}

/// The canonical thread: messages + run events for one conversation.
struct ThreadDetailView: View {
    /// Identity of a delegated child opened from a delegate card.
    private struct PresentedChildRun: Identifiable {
        let id: UUID
    }

    @StateObject private var viewModel: ThreadDetailViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var designEntryState: DesignEntryStateCenter
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingPendingInput: PendingUserInput?
    @State private var showingGoalBuilder = false
    @State private var showingPermissionsSheet = false
    /// Full temporary-chat explanation (lifecycle, tools/cloud, voice) opened
    /// from the compact badge menu's About action.
    @State private var showsTemporaryAbout = false
    @State private var showingUsageDetails = false
    /// Last usage snapshot handed to the popover. Retained until the next
    /// open so a dismissal never collapses the presented content to an empty
    /// view while the transition is in flight.
    @State private var presentedUsageSummary: ThreadUsageSummary?
    @State private var selectedImportantFile: ImportantFileShortcut?
    @State private var selectedAttachment: ChatAttachmentOpenRequest?
    @State private var showsReturnToLatest = false
    @State private var latestFollow = LatestMessageFollowState()
    @State private var isUserScrolling = false
    @State private var structuredExport: TaskExportFile?
    @State private var exporting = false
    @State private var showsChecklist = false
    @State private var consumedInputID: UUID?
    @State private var refreshingMediaJobs = false
    /// The delegated child opened from a delegate card's "View" action. The
    /// sheet renders the same durable transcript view the child-agents
    /// inspector pushes (one source of truth, no second registry).
    @State private var presentedChild: PresentedChildRun?
    /// Natural-language design page for this conversation's frozen launch
    /// binding (same conversation/run/workspace; embedded + fullscreen).
    /// Presented from the APP ROOT (AppRouter): a sheet anchored here would
    /// dismiss spontaneously while the live thread re-renders behind it.
    /// (`router` is declared at the top of this view.)
    private let composerInput: ThreadComposerInput?
    private let onSaveToNotes: ((String) -> Void)?
    private let embedded: Bool
    private let documentAssistant: Bool
    private let onInputConsumed: (UUID) -> Void

    init(conversationID: UUID, center: ConversationCenter, composerInput: ThreadComposerInput? = nil, embedded: Bool = false, documentAssistant: Bool = false, onSaveToNotes: ((String) -> Void)? = nil, onInputConsumed: @escaping (UUID) -> Void = { _ in }) {
        self.composerInput = composerInput
        self.embedded = embedded
        self.documentAssistant = documentAssistant
        self.onSaveToNotes = onSaveToNotes
        self.onInputConsumed = onInputConsumed
        _viewModel = StateObject(
            wrappedValue: ThreadDetailViewModel(conversationID: conversationID, center: center)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                // The temporary state lives in the compact top-header entry
                // (badge + action menu). There is deliberately no persistent
                // banner: the ordinary chat layout is reused unchanged.
                if let checklist = viewModel.taskChecklist {
                    checklistStatus(checklist)
                }
                if viewModel.latestPlan != nil || viewModel.activeGoal != nil {
                    intelligenceStatus
                }
                Divider()
                if !viewModel.importantFiles.isEmpty {
                    importantFilesStrip
                    Divider()
                }
                threadScroll
                if let status = viewModel.compactionStatus {
                    HStack {
                        if viewModel.isCompacting { ProgressView().controlSize(.small) }
                        Text(status).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .accessibilityIdentifier("thread.compaction.status")
                    .transition(.opacity)
                }
                if let error = viewModel.actionError {
                    errorBanner(error)
                }
                if viewModel.canContinue {
                    continuationBar
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                composer
            }
            .background(FloeTheme.readingSurface)
            // The composer input caps at one third of the actually
            // available height — rotation, split and dynamic-type relayouts
            // all funnel through this proxy.
            .environment(\.composerHeightBudget, proxy.size.height)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.compactionStatus)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.canContinue)
            .navigationTitle(viewModel.taskTitle.isEmpty ? String(localized: "thread.title") : viewModel.taskTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if !embedded { stateToolbar } }
            .task {
                if !embedded { viewModel.selectedRunID = router.selectedRunID }
                await viewModel.load()
                // Re-derive the shared design-entry state when a thread
                // opens: bootstrap-time refresh can race design-service
                // initialization, and run-end updates land here too.
                await environment.designEntryState.refresh(
                    conversationID: viewModel.conversationID, environment: environment)
            }
            .task(id: composerInput?.id) {
                guard let input = composerInput, consumedInputID != input.id else { return }
                viewModel.draft += (viewModel.draft.isEmpty ? "" : "\n\n") + input.text
                let existing = Set(viewModel.attachments.map(\.id))
                viewModel.attachments.append(contentsOf: input.attachments.filter { !existing.contains($0.id) })
                consumedInputID = input.id
                onInputConsumed(input.id)
            }
            .onDisappear { viewModel.stopLiveUpdates() }

            .sheet(item: $structuredExport) { file in
                TaskExportShareSheet(url: file.url, lease: file.lease)
            }
            .sheet(item: $presentedChild) { child in
                NavigationStack {
                    ChildAgentDetailView(childRunID: child.id)
                }
            }
            .sheet(isPresented: $showsTemporaryAbout) {
                TemporaryChatAboutSheet()
            }
            .sheet(item: $editingPendingInput) { input in
                PendingInputEditor(input: input) { text in
                    Task { await viewModel.editPendingInput(input, content: text) }
                }
            }
            .sheet(isPresented: $showingGoalBuilder) {
                GoalBuilderSheet { objective, criteria, blockers, stops in
                    Task {
                        await viewModel.createGoal(
                            objective: objective,
                            criteria: criteria,
                            blockingConditions: blockers,
                            stoppingConditions: stops
                        )
                    }
                }
            }
            .sheet(isPresented: $showingPermissionsSheet) {
                NavigationStack {
                    TaskPermissionsInspectorView(
                        conversationID: viewModel.conversationID,
                        isLocalModel: viewModel.usesLocalModel
                    )
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("action.done") { showingPermissionsSheet = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $selectedAttachment) { request in
                ChatAttachmentOpenSheet(request: request, environment: environment).id(request.id)
            }
            .sheet(item: $selectedImportantFile) { file in
                NavigationStack {
                    FilePreviewView(
                        relativePath: file.path,
                        center: environment.workspaceCenter,
                        conversationID: viewModel.conversationID
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("workspace.workspace_canvas_view.done") { selectedImportantFile = nil }
                        }
                    }
                }
            }
        }
    }

    private func checklistStatus(_ checklist: TaskChecklist) -> some View {
        DisclosureGroup(isExpanded: $showsChecklist) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(checklist.steps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: checklistIcon(step.status))
                                .foregroundStyle(step.status == .completed ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title).font(.subheadline)
                                if !step.evidence.isEmpty {
                                    Text(step.evidence.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(checklist.title).lineLimit(1)
                    if let step = checklist.currentStep {
                        Text(FloeL10n.l("chat.thread_detail_view.current", step.title)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(checklist.progressSummary)
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.subheadline)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .accessibilityIdentifier("thread.checklist")
    }

    private func checklistIcon(_ status: TaskChecklist.Step.Status) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "arrow.trianglehead.2.clockwise.rotate.90"
        case .completed: "checkmark.circle.fill"
        case .blocked: "pause.circle"
        case .cancelled: "minus.circle"
        }
    }

    private var importantFilesStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("chat.thread_detail_view.key_files", systemImage: "doc.text.magnifyingglass")
                    .font(FloeTheme.Typography.metadata.weight(.semibold))
                Spacer()
                Button("chat.thread_detail_view.all_files") { router.showInspector(.workspaceFiles) }
                    .font(FloeTheme.Typography.metadata)
            }
            .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.importantFiles) { file in
                        Button {
                            selectedImportantFile = file
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: icon(for: file.path))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((file.path as NSString).lastPathComponent)
                                        .lineLimit(1)
                                    Text(file.action)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(FloeTheme.Typography.metadata)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("chat.thread_detail_view.open", systemImage: "doc.text") { selectedImportantFile = file }
                            Button("chat.thread_detail_view.copy_path", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = file.path
                            }
                        }
                        .accessibilityLabel("\(file.action) \(file.path)")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(FloeTheme.readingSurface)
    }

    private func icon(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "py": "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "mjs", "cjs": "curlybraces"
        case "html", "htm": "safari"
        case "csv": "tablecells"
        case "md", "markdown": "doc.richtext"
        case "pdf": "doc.fill"
        default: "doc.text"
        }
    }

    private var intelligenceStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = viewModel.latestPlan {
                HStack(alignment: .top) {
                    Label("plan.title", systemImage: "list.bullet.clipboard")
                        .font(.headline)
                    Spacer()
                    Text(plan.status.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Text(plan.title).font(.subheadline).lineLimit(2)
                if let recommendation = plan.executionRecommendation {
                    Label(
                        recommendation == .goal ? "chat.thread_detail_view.suggest_converting_to_goal" : "chat.thread_detail_view.recommend_normal_execution",
                        systemImage: recommendation == .goal ? "target" : "play.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let reason = plan.recommendationReason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if plan.status == .ready && plan.isDecisionComplete {
                    HStack {
                        Button("chat.thread_detail_view.execute_on_the_normal_plan") {
                            Task { await viewModel.acceptLatestPlan(as: .normal) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("chat.thread_detail_view.convert_to_goal") {
                            Task { await viewModel.acceptLatestPlan(as: .goal) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            if let goal = viewModel.activeGoal {
                HStack {
                    Label("goal.title", systemImage: "target").font(.headline)
                    Spacer()
                    Text(goal.status.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Text(goal.objective).font(.subheadline).lineLimit(2)
                ProgressView(
                    value: Double(goal.steps.filter { $0.status == .completed }.count),
                    total: Double(max(1, goal.steps.count))
                )
                if goal.status == .verifying {
                    Button("goal.confirm_complete") {
                        Task { await viewModel.confirmGoalCompletion() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .background(FloeTheme.groupedSurface)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Thread content

    private var threadScroll: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.hasEarlierMessages {
                        Button("chat.thread_detail_view.load_earlier_messages", systemImage: "arrow.up.circle") {
                            Task { await viewModel.loadEarlierMessages() }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(viewModel.loadingEarlierMessages)
                        .accessibilityHint("chat.thread_detail_view.load_thirty_more_older_messages_each")
                    }
                    // The unified timeline: user goal → run events in stored
                    // sequence → live tail → approvals → terminal last.
                    // "Completed" can never float above the final reply.
                    ForEach(viewModel.timeline) { item in
                        timelineRow(item)
                            .id(item.id)
                            .transition(viewModel.isRunning ? FloeTheme.stepTransition(reduceMotion: reduceMotion) : .identity)
                    }

                    if let usage = viewModel.usageSummary {
                        ThreadUsageFooter(summary: usage)
                    }

                        if !embedded && viewModel.events.isEmpty && viewModel.messages.isEmpty {
                            ContentUnavailableView {
                                Label("thread.empty", systemImage: "text.bubble")
                            } description: {
                                Text("thread.empty.hint")
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("thread-latest-anchor")
                    }
                    .padding()
                    .animation(viewModel.isRunning && !reduceMotion ? .easeOut(duration: 0.22) : nil, value: viewModel.timelineIDs)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollPhaseChange { _, phase in
                    isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                    if phase == .idle, latestFollow.followsLatest {
                        proxy.scrollTo("thread-latest-anchor", anchor: .bottom)
                    }
                }
                .onScrollGeometryChange(for: ThreadScrollMetrics.self) { geometry in
                    ThreadScrollMetrics(offset: geometry.contentOffset.y,
                        height: geometry.contentSize.height,
                        bottomDistance: geometry.contentSize.height + geometry.contentInsets.bottom
                            - geometry.contentOffset.y - geometry.containerSize.height)
                } action: { old, new in
                    latestFollow.observe(offset: new.offset, bottomDistance: new.bottomDistance,
                                         userScrolling: isUserScrolling)
                    showsReturnToLatest = latestFollow.isAwayFromLatest && !latestFollow.followsLatest
                    // Observe layout too: an image or tool card can grow without
                    // adding an event or increasing the streamed text length.
                    if old.height != new.height, latestFollow.followsLatest, !isUserScrolling {
                        proxy.scrollTo("thread-latest-anchor", anchor: .bottom)
                    }
                }

                if showsReturnToLatest {
                    Button {
                        latestFollow.returnToLatest()
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                            proxy.scrollTo("thread-latest-anchor", anchor: .bottom)
                        }
                        showsReturnToLatest = false
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .accessibilityLabel("chat.thread_detail_view.jump_to_latest")
                    .accessibilityHint("chat.thread_detail_view.scroll_to_the_latest_message_in")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: viewModel.hasLoaded) { _, loaded in
                guard loaded else { return }
                latestFollow.returnToLatest()
                proxy.scrollTo("thread-latest-anchor", anchor: .bottom)
                showsReturnToLatest = false
            }
            .onChange(of: [viewModel.liveStreamedText.utf8.count, viewModel.liveReasoningText.utf8.count,
                           viewModel.events.count, viewModel.messages.count,
                           viewModel.isRunning ? 1 : 0]) { _, _ in
                // Follow only when the user has not intentionally scrolled
                // away to inspect earlier reasoning or tool output.
                guard viewModel.hasLoaded, latestFollow.followsLatest, !isUserScrolling else { return }
                proxy.scrollTo("thread-latest-anchor", anchor: .bottom)
            }
        }
    }

    /// Renders one unified timeline row.
    @ViewBuilder
    private func timelineRow(_ item: ThreadTimelineItem) -> some View {
        switch item {
        case .earlierEvents(let runID):
            Button("chat.thread_detail_view.show_earlier_tool_activity", systemImage: "clock.arrow.circlepath") {
                Task { await viewModel.loadEarlierEvents(runID: runID) }
            }
            .disabled(viewModel.loadingEventRunIDs.contains(runID))
            .accessibilityIdentifier("thread.events.earlier.\(runID.uuidString)")
        case .userMessage(let message):
            MessageBubble(message: message, onOpenAttachment: { item in
                selectedAttachment = ChatAttachmentOpenRequest(conversationID: message.conversationID,
                    messageID: message.id, attachmentID: item.attachmentID)
            })

        case .assistantMessage(let text, let idSuffix):
            // A task-level assistant message may carry REAL returned
            // attachments (e.g. the adopted design result returned by the
            // publication port). Render them through the same shared chip
            // surface; assistantText events resolve to no message and render
            // exactly as before.
            let persisted = UUID(uuidString: idSuffix).flatMap { messageID in
                viewModel.messages.first { $0.id == messageID && $0.role == "assistant" }
            }
            if let persisted {
                MessageBubble(message: persisted, displayedText: text, onSaveToNotes: onSaveToNotes,
                    onOpenAttachment: { item in
                        selectedAttachment = ChatAttachmentOpenRequest(conversationID: persisted.conversationID,
                            messageID: persisted.id, attachmentID: item.attachmentID)
                    })
            } else {
                AssistantMessageView(text: text, isStreaming: false, onSaveToNotes: onSaveToNotes)
            }

        case .event(let event):
            ThreadEventView(
                event: event,
                isLive: viewModel.isRunning,
                hasError: viewModel.events.contains { $0.kind == .error },
                onRetry: viewModel.selectedRun.map {
                    $0.state == "failed" || $0.state == "interrupted"
                } == true
                    ? { Task { await viewModel.retry() } }
                    : nil,
                decisionSummary: decisionSummary(for: event),
                childRun: childRun(for: event),
                onOpenChild: { openChild($0) },
                conversationID: viewModel.conversationID
            )

        case .stepGroup(let events, let isLatest):
            StepGroupView(
                events: events,
                isLatest: isLatest,
                isLive: viewModel.isRunning && events.contains { $0.runID == viewModel.selectedRunID },
                hasError: events.contains { $0.kind == .error },
                pendingApprovals: viewModel.pendingApprovals,
                decisions: viewModel.decisionAnnotations,
                childRunRecords: viewModel.childRunRecords,
                onOpenChild: { openChild($0) },
                conversationID: viewModel.conversationID,
                onResolveApproval: { approval, decision in
                    Task { await viewModel.resolve(approval, decision: decision) }
                }
            )

        case .terminal(let event):
            TerminalEventRow(event: event)

        case .missingFinalMessage:
            MissingFinalMessageRow()

        case .liveReasoning:
            ReasoningBlockView(
                text: viewModel.liveReasoningText,
                isStreaming: true
            )

        case .liveAssistantTail:
            AssistantMessageView(
                text: viewModel.liveStreamedText,
                isStreaming: true
            )

        case .liveThinking:
            ModelResponseWaitingView()

        case .approval(let approval):
            ApprovalCardView(approval: approval) { decision in
                Task { await viewModel.resolve(approval, decision: decision) }
            }
        }
    }

    // MARK: - State toolbar (status + Stop/Retry + inspector)

    /// Markdown export of the conversation (title + user/assistant turns).
    private var exportMarkdown: String? {
        let messages = viewModel.messages
        guard !messages.isEmpty else { return nil }
        let title = viewModel.taskTitle.isEmpty ? FloeL10n.l("tab.chat") : viewModel.taskTitle
        var lines: [String] = ["# \(title)", ""]
        for message in messages {
            let role = message.role == "user" ? FloeL10n.l("hosts.user") : FloeL10n.l("chat.thread_detail_view.assistant")
            lines.append("## \(role)")
            lines.append("")
            // The trusted design confirmation exports as the same concise
            // localized summary the conversation shows, never the internal
            // target/grant payload. Every other message stays verbatim.
            lines.append(exportSummary(for: message) ?? message.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Plain-text export of the conversation (title + user/assistant turns).
    private var exportText: String? {
        let messages = viewModel.messages
        guard !messages.isEmpty else { return nil }
        let title = viewModel.taskTitle.isEmpty ? FloeL10n.l("tab.chat") : viewModel.taskTitle
        let body = messages
            .map { message -> String in
                let role = message.role == "user" ? FloeL10n.l("hosts.user") : FloeL10n.l("chat.thread_detail_view.assistant")
                let content = exportSummary(for: message) ?? message.content
                return "\(role): \(content)"
            }
            .joined(separator: "\n\n")
        return "\(title)\n\n\(body)"
    }

    /// One export line for a message: the decision-specific concise sentence
    /// for a validated proposal decision, the existing concise notice summary
    /// for other trusted internal notices, nil (verbatim) otherwise.
    private func exportSummary(for message: PersistedMessage) -> String? {
        if let notice = ProposalDecisionPresentation.trustedNotice(for: message) {
            return notice.summary
        }
        return InternalNoticeProjection.userFacingSummary(for: message)
    }

    /// The compact decision line shown inside the matching tool step, when
    /// this event's call carries a projected automatic decision. Scoped to the
    /// event's OWN run: raw provider call ids repeat across runs, so a notice
    /// correlated to another run's call must never decorate this row.
    private func decisionSummary(for event: RunEventRecord) -> String? {
        let payload = ConversationCenter.decodePayload(event.payloadJSON)
        let callID = payload["callID"] ?? payload["id"] ?? ""
        let summaries = ThreadRunScopedResolution.decisionSummaries(
            callID: callID, runID: event.runID, in: viewModel.decisionAnnotations)
        return summaries.isEmpty ? nil : summaries.joined(separator: "\n")
    }

    /// The durable delegated-child record for this event's call, when the
    /// persisted relation maps the delegate call id to a child run OF THIS
    /// RUN. Run scoping is required: call ids are provider-supplied and repeat
    /// across runs, and the deep link must open the child this call created.
    private func childRun(for event: RunEventRecord) -> ChildRunRecord? {
        let payload = ConversationCenter.decodePayload(event.payloadJSON)
        let callID = payload["callID"] ?? payload["id"] ?? ""
        return ThreadRunScopedResolution.child(
            callID: callID, parentRunID: event.runID, in: viewModel.childRunRecords)
    }

    /// Opens the delegated child's durable transcript when the specific child
    /// is known; otherwise falls back to the child-agents inspector list for
    /// this conversation. Both render the same `ChildAgentDetailView` over the
    /// lifecycle owner's store — one UI source of truth.
    private func openChild(_ childRun: ChildRunRecord?) {
        if let childRun {
            presentedChild = PresentedChildRun(id: childRun.id)
        } else {
            router.inspectorRoute = AppRouter.InspectorRoute(
                content: .childAgents, conversationID: viewModel.conversationID)
        }
    }

    @ToolbarContentBuilder
    private var stateToolbar: some ToolbarContent {
        if !embedded {
            temporaryToolbarItems
        }
        ToolbarItem(placement: .topBarTrailing) {
            usageToolbarHost
        }
        // Natural-language design page entry — the SHARED, published entry
        // state (derived from durable binding/envelope/capability truth,
        // refreshed at launch/restore/run-end). Ordinary Q&A gets nothing;
        // creative tasks stay conversation-first until a REAL artifact.
        let entry = designEntryState.presentation(for: viewModel.conversationID)
        if entry == .openWorkbench || entry == .viewArtifactEntry {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard let target = DesignLaunchBindingStore.load(
                        conversationID: viewModel.conversationID)?.target else { return }
                    router.presentedDesignPage = DesignPageRequest(
                        target: target, conversationID: viewModel.conversationID)
                } label: {
                    Label("design.page.open", systemImage: "square.on.square.dashed")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("thread.designPage")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !viewModel.isTemporary {
                Button(refreshingMediaJobs ? "chat.thread_detail_view.refreshing_media_tasks" : "chat.thread_detail_view.refresh_media_task_status", systemImage: "arrow.clockwise") {
                    refreshingMediaJobs = true
                    Task {
                        defer { refreshingMediaJobs = false }
                        await viewModel.refreshMediaJobs()
                    }
                }
                .disabled(refreshingMediaJobs)
                Button("chat.thread_detail_view.set_goal_directly", systemImage: "target") {
                    showingGoalBuilder = true
                }
                Button(exporting ? "chat.thread_detail_view.exporting" : "chat.thread_detail_view.export_full_task_including_tool_results", systemImage: "doc.badge.gearshape") {
                    exporting = true
                    Task {
                        defer { exporting = false }
                        if let result = await viewModel.exportStructuredConversation() {
                            structuredExport = TaskExportFile(url: result.url, lease: result.lease)
                        }
                    }
                }.disabled(exporting)
                if let exportText {
                    ShareLink(item: exportText) {
                        Label("chat.thread_detail_view.export_conversation_text", systemImage: "square.and.arrow.up")
                    }
                }
                if let exportMarkdown {
                    ShareLink(item: exportMarkdown) {
                        Label("chat.thread_detail_view.export_conversation_markdown", systemImage: "doc.richtext")
                    }
                }
                Divider()
                }
                if !viewModel.isTemporary {
                    // Task inspectors bind workspace/browser/terminal/change
                    // resources; a casual temporary chat owns none of those
                    // and must not surface bindings it never made. The run
                    // progress readout and inspector chrome stay available.
                    inspectorButton("chat.thread_detail_view.changes", icon: "arrow.triangle.2.circlepath", content: .changes)
                    inspectorButton("tab.files", icon: "folder", content: .workspaceFiles)
                    inspectorButton("browser.title", icon: "safari", content: .browser)
                    inspectorButton("chat.thread_detail_view.terminal_host", icon: "terminal", content: .terminal)
                    inspectorButton("chat.thread_detail_view.subagents", icon: "person.2", content: .childAgents)
                }
                inspectorButton("chat.thread_detail_view.progress", icon: "chart.bar", content: .progress)
                if router.inspectorVisible {
                    Divider()
                    Button("chat.thread_detail_view.hide_inspector", systemImage: "sidebar.right") { router.hideInspector() }
                }
            } label: {
                if viewModel.isTemporary {
                    Label("chat.thread_detail_view.progress", systemImage: "chart.bar")
                } else {
                    Label("inspector.files", systemImage: "sidebar.right")
                }
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel(viewModel.isTemporary
                ? Text("chat.thread_detail_view.progress") : Text("inspector.files"))
            .accessibilityIdentifier("thread.inspector.menu")
        }
        ToolbarItem(placement: .topBarTrailing) {
            BackgroundPiPToolbarButton(
                videoService: environment.backgroundVideoService,
                isRunActive: viewModel.isRunning
                    || environment.backgroundRunCoordinator
                        .shouldOfferVisualSurfaceControl(conversationID: viewModel.conversationID)
            )
            .pipAudioQuickSettings(center: environment.settingsCenter, audioService: environment.pipAudioService)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if viewModel.isRunning {
                Button(role: .destructive) {
                    Task { await viewModel.cancel() }
                } label: {
                    Label("action.stop", systemImage: "stop.circle")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("action.stop")
            } else if viewModel.canContinue {
                Button {
                    Task { await viewModel.retry() }
                } label: {
                    Label("chat.thread_detail_view.continue", systemImage: "play.fill")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("action.retry")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if viewModel.selectedRunWaitingForJobs {
                // A run parked for outstanding background jobs is WAITING, not
                // finished: the durable `checkpointed` reason says so.
                Text(ChatBilingualCatalog.localized(
                    key: "state.waiting_for_background_work",
                    en: "Waiting for background work", zh: "等待后台作业"))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.pending)
                    .accessibilityIdentifier("thread.run_state.awaitingDependency")
            } else if let state = viewModel.liveStateName {
                Text(RunStateLocalizer.title(for: state))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(RunStateLocalizer.color(for: state))
                    .accessibilityLabel(Text(RunStateLocalizer.title(for: state)))
                    .accessibilityIdentifier("thread.run_state.\(state)")
            }
        }
    }

    // MARK: - Temporary chat (active state + Keep/End)

    /// Active temporary session: a compact top-header badge menu carrying the
    /// concise explanation plus the Keep and End actions — no persistent
    /// banner takes chat space. Starting a temporary chat belongs to the New
    /// Task launchpad entry ONLY (`home.temporary.toggle`); an ordinary saved
    /// chat never shows a temporary switch here, so a saved conversation can
    /// never be converted implicitly from its own thread.
    @ToolbarContentBuilder
    private var temporaryToolbarItems: some ToolbarContent {
        if viewModel.isTemporary {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // A SHORT lifecycle header that fits the native menu's
                    // disabled-item clamp; the full lifecycle, tool/cloud and
                    // voice details stay readable behind the enabled About
                    // action below (a 3-line menu row clipped the long text).
                    Text("chat.temporary.header")
                        .accessibilityIdentifier("chat.temporary.hint")
                    Button {
                        showsTemporaryAbout = true
                    } label: {
                        Label("chat.temporary.about", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("chat.temporary.about")
                    Button {
                        Task { await viewModel.keepTemporaryChat() }
                    } label: {
                        switch viewModel.temporaryKeepState {
                        case .saving:
                            Label("chat.temporary.keep", systemImage: "tray.and.arrow.down")
                        case .partialRetry:
                            Label("chat.temporary.keepPartialRetry", systemImage: "tray.and.arrow.down")
                        case .failed:
                            Label("chat.temporary.keepFailedRetry", systemImage: "tray.and.arrow.down")
                        case .idle:
                            Label("chat.temporary.keep", systemImage: "tray.and.arrow.down")
                        }
                    }
                    .disabled(viewModel.temporaryKeepState == .saving)
                    .accessibilityLabel("chat.temporary.keep")
                    .accessibilityIdentifier("chat.temporary.keep")
                    Button(role: .destructive) {
                        endTemporaryChatFromHeader()
                    } label: {
                        Label("chat.temporary.end", systemImage: "xmark.circle")
                    }
                    .accessibilityLabel("chat.temporary.end")
                    .accessibilityIdentifier("chat.temporary.end")
                } label: {
                    // Explicit compact word + icon: a toolbar Label collapses
                    // to icon-only in compact layouts, which made the active
                    // temporary state indistinguishable from an ordinary
                    // chat's generic bubble. Same small native header menu,
                    // just a visible state word ("Temporary"/"临时").
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.fill")
                        Text("chat.temporary.badge")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(FloeTheme.primary)
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("chat.temporary.badge")
                .accessibilityIdentifier("chat.temporary.badge")
                .help(String(localized: "chat.temporary.banner"))
            }
        }
    }

    /// Explicit End from the compact header menu: the session is destroyed
    /// synchronously by the view model, then the caller routes to the
    /// restored ordinary conversation or the fresh-task surface.
    private func endTemporaryChatFromHeader() {
        Task {
            guard let target = await viewModel.endTemporaryChat() else { return }
            switch target {
            case .openConversation(let id):
                router.openConversation(id)
            case .openNewTask:
                router.startNewTask()
            }
        }
    }

    /// The context-usage ring and its popover host.
    ///
    /// Build 231 TestFlight feedback trapped in UIKit's
    /// `_UIZoomTransitionController.startInteractiveTransition` while
    /// SwiftUI's `UIKitPopoverBridge.dismissAndReset` dismissed a
    /// popover inside `ViewGraph.updateOutputs`. The
    /// stack matches that popover-dismissal class; this ring was the chat
    /// screen's only toolbar popover mounted on a conditionally-created
    /// source, so an approval resume or a usage tick could remove the
    /// presenter while the presentation was live.
    ///
    /// This host is mounted for the toolbar's lifetime; only the ring inside
    /// it is conditional. Availability loss and run switches clear the
    /// presented state explicitly so a later run's usage cannot resurrect
    /// it, and compact widths use the platform's default adaptation (a sheet
    /// on iPhone), avoiding the forced compact popover presentation.
    private var usageToolbarHost: some View {
        ZStack {
            if usageAvailability, let usage = viewModel.contextUsageSummary {
                Button {
                    // Capture the snapshot before presenting: the presented
                    // content must not collapse to an empty view if the run's
                    // usage disappears while SwiftUI tears the presentation
                    // down. It is replaced on the next open.
                    presentedUsageSummary = usage
                    showingUsageDetails = true
                } label: {
                    ContextUsageRing(fraction: usage.contextFraction)
                }
                .buttonStyle(.plain)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("chat.thread_detail_view.view_context_usage")
                .accessibilityValue(
                    usage.contextTokens > 0
                        ? "\(TokenUnitFormatter.string(usage.contextTokens)) / \(TokenUnitFormatter.string(usage.contextWindowTokens))"
                        : String(localized: "chat.context_usage.pending")
                )
            }
        }
        .onChange(of: usageAvailability) { _, available in
            if !available { showingUsageDetails = false }
        }
        .onChange(of: viewModel.selectedRun?.id) { _, _ in
            showingUsageDetails = false
        }
        .popover(isPresented: usageDetailsPresented) {
            if let summary = presentedUsageSummary {
                ContextUsageDetails(summary: summary)
                    .presentationCompactAdaptation(.automatic)
                    .presentationDetents([.medium])
            }
        }
    }

    /// Whether the ring currently has a source. The presented flag is derived
    /// from this so it can never outlive its data, while the explicit
    /// `onChange` above also clears the stored flag (otherwise the next run's
    /// usage would immediately re-present the popover).
    private var usageAvailability: Bool {
        (viewModel.contextUsageSummary?.contextWindowTokens ?? 0) > 0
    }

    private var usageDetailsPresented: Binding<Bool> {
        Binding(
            get: { showingUsageDetails && usageAvailability },
            set: { showingUsageDetails = $0 }
        )
    }

    private func inspectorButton(
        _ title: LocalizedStringKey,
        icon: String,
        content: AppRouter.InspectorContent
    ) -> some View {
        Button(title, systemImage: icon) { router.showInspector(content) }
            .accessibilityIdentifier("thread.inspector.open.\(content.rawValue)")
    }

    // MARK: - Error banner (honest failure surface)

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon")
                .foregroundStyle(FloeTheme.destructive)
                .accessibilityHidden(true)
            Text(message)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.destructive)
            Spacer()
            Button {
                viewModel.dismissActionError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(FloeTheme.destructive)
            .accessibilityLabel("chat.thread_detail_view.dismiss_error")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(FloeTheme.destructive.opacity(0.08))
    }

    private var continuationBar: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.selectedRun?.state == "failed"
                  ? "exclamationmark.circle" : "pause.circle")
                .foregroundStyle(FloeTheme.pending)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.continuationTitle)
                    .font(FloeTheme.Typography.metadata.weight(.semibold))
                Text(viewModel.continuationDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await viewModel.retry() }
            } label: {
                Label("chat.thread_detail_view.continue", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(FloeTheme.pending.opacity(0.08))
    }

    // MARK: - Composer (glass; reading surfaces stay opaque)

    @ViewBuilder
    private var composer: some View {
        if viewModel.isConversationMissing {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                    .foregroundStyle(FloeTheme.pending)
                Text("chat.select_or_new")
                    .font(FloeTheme.Typography.metadata)
                Spacer()
            }
            .padding()
            .background(FloeTheme.pending.opacity(0.08))
            .accessibilityIdentifier("thread.conversation_missing")
        } else {
            VStack(spacing: 0) {
                if !viewModel.pendingInputs.isEmpty {
                    PendingInputQueueView(
                        inputs: viewModel.pendingInputs,
                        canSteer: viewModel.isRunning,
                        onEdit: { editingPendingInput = $0 },
                        onDelete: { input in Task { await viewModel.removePendingInput(input) } },
                        onMove: { input, offset in Task { await viewModel.movePendingInput(input, offset: offset) } },
                        onSteer: { input in Task { await viewModel.promotePendingInput(input) } }
                    )
                }
                if viewModel.needsProvider {
                    addProviderBar
                }
                ThreadComposerView(
                    draft: $viewModel.draft,
                    selectedModelID: $viewModel.selectedModelID,
                    models: viewModel.availableModels,
                    modelName: viewModel.selectedModelName,
                    providerConfigured: !viewModel.needsProvider,
                    isRunning: viewModel.isRunning,
                    runningInputMode: $viewModel.runningInputMode,
                    canSend: viewModel.canSend,
                    projects: viewModel.availableProjects,
                    projectSelectionLocked: true,
                    selectedProjectID: $viewModel.selectedProjectID,
                    executionTarget: $viewModel.executionTarget,
                    agentMode: Binding(
                        get: { viewModel.effectiveAgentMode },
                        set: { viewModel.selectAgentMode($0) }
                    ),
                    attachments: $viewModel.attachments,
                    onSend: {
                        // Sending owns the composer from this point. End any
                        // in-flight dictation first so late partial results
                        // cannot mutate the already-submitted prompt.
                        environment.voiceInput.stop()
                        Task { await viewModel.send() }
                    },
                    onStop: { Task { await viewModel.cancel() } },
                    onManualCompact: { viewModel.requestManualCompaction() },
                    onPermissions: { showingPermissionsSheet = true },
                    approvalMode: viewModel.taskPolicy.resolvedApprovalMode,
                    contextID: viewModel.conversationID,
                    isDraftConsumedBySend: viewModel.isConsumingDraft,
                    embedded: embedded,
                    documentAssistant: documentAssistant,
                    temporary: viewModel.isTemporary,
                    draftPersistenceEnabled: viewModel.shouldPersistDraftEdits,
                    onDraftEdited: { viewModel.noteDraftEditedByUser() }
                )
            }
        }
    }

    private var addProviderBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            Text("chat.add_provider.hint")
                .font(FloeTheme.Typography.metadata)
            Spacer()
            Button("setup.launcher.open") { router.presentedSetup = .manual }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(FloeTheme.pending.opacity(0.08))
    }
}

private struct ThreadUsageFooter: View {
    let summary: ThreadUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Label("\(formatted(summary.inputTokens))", systemImage: "arrow.up")
                Label("\(formatted(summary.outputTokens))", systemImage: "arrow.down")
                Text(FloeL10n.l("chat.thread_detail_view.total", formatted(summary.totalTokens)))
                if summary.isEstimatedLive {
                    Text("chat.thread_detail_view.live_estimate")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(FloeL10n.l("chat.thread_detail_view.context_reuse", reported(summary.cacheReadTokens)))
                Text(FloeL10n.l("chat.thread_detail_view.reasoning_usage", reported(summary.reasoningTokens)))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Text(FloeL10n.l("chat.thread_detail_view.context_reuse_rate", percent(summary.cacheHitRate)))
                Text(FloeL10n.l("chat.thread_detail_view.generation_speed", speed(summary.tokensPerSecond)))
                Text(FloeL10n.l("chat.thread_detail_view.first_response", duration(summary.timeToFirstTokenMs)))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func formatted(_ value: Int) -> String {
        TokenUnitFormatter.string(value)
    }

    private func reported(_ value: Int?) -> String {
        value.map(formatted) ?? FloeL10n.l("settings.usage_statistics_view.not_reported")
    }

    private func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? FloeL10n.l("settings.usage_statistics_view.not_reported")
    }

    private func speed(_ value: Double?) -> String {
        value.map { FloeL10n.plural("settings.usage_statistics_view.fragments_sec", count: Int($0.rounded()), $0.formatted(.number.precision(.fractionLength(1)))) } ?? FloeL10n.l("settings.usage_statistics_view.not_reported")
    }

    private func duration(_ value: Int?) -> String {
        value.map {
            "\((Double($0) / 1_000).formatted(.number.precision(.fractionLength(2))))s"
        } ?? FloeL10n.l("settings.usage_statistics_view.not_reported")
    }
}

private struct ContextUsageRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(
                    fraction > 0.85 ? FloeTheme.pending : FloeTheme.primary,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .contentShape(Circle())
    }
}

private struct ContextUsageDetails: View {
    let summary: ThreadUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("chat.thread_detail_view.context_window", systemImage: "circle.dotted")
                .font(.headline)
            Text("\(summary.contextTokens > 0 ? TokenUnitFormatter.string(summary.contextTokens) : "—") / \(TokenUnitFormatter.string(summary.contextWindowTokens))")
                .font(.title3.monospacedDigit().weight(.semibold))
            if summary.contextTokens > 0 {
                ProgressView(value: summary.contextFraction)
                    .tint(summary.contextFraction > 0.85 ? FloeTheme.pending : FloeTheme.primary)
                Text(FloeL10n.l("chat.thread_detail_view.this_turn_input_output", TokenUnitFormatter.string(summary.inputTokens), TokenUnitFormatter.string(summary.outputTokens)))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                Text("chat.context_usage.pending")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 240)
        .accessibilityElement(children: .combine)
    }
}

enum TokenUnitFormatter {
    static func string(_ value: Int) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 {
            return scaled(value, divisor: 1_000_000_000, suffix: "B")
        }
        if magnitude >= 1_000_000 {
            return scaled(value, divisor: 1_000_000, suffix: "M")
        }
        if magnitude >= 1_000 {
            return scaled(value, divisor: 1_000, suffix: "K")
        }
        return value.formatted()
    }

    private static func scaled(_ value: Int, divisor: Int, suffix: String) -> String {
        let quotient = Double(value) / Double(divisor)
        let number = quotient.rounded() == quotient
            ? String(Int(quotient))
            : String(format: "%.1f", quotient).replacingOccurrences(of: ".0", with: "")
        return number + suffix
    }
}

private struct PendingInputQueueView: View {
    let inputs: [PendingUserInput]
    let canSteer: Bool
    let onEdit: (PendingUserInput) -> Void
    let onDelete: (PendingUserInput) -> Void
    let onMove: (PendingUserInput, Int) -> Void
    let onSteer: (PendingUserInput) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("chat.thread_detail_view.message_queue", systemImage: "text.badge.plus")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(inputs.count)")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            ForEach(inputs) { input in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayText(for: input))
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(input.executionMode == "browserHandoff" && input.status == .queued
                            ? IDELanguageRunText.t("通知已保存至原任务，可在浏览器中继续任务", "Saved to the original task; continue from the browser")
                            : statusTitle(input.status))
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(input.status == .queued ? .secondary : FloeTheme.pending)
                    }
                    Spacer(minLength: 4)
                    if input.executionMode == "browserHandoff" {
                        Image(systemName: "safari").foregroundStyle(.secondary)
                    } else if input.status == .queued || input.status == .steerPending {
                        let queuedIndex = queuedInputs.firstIndex(where: { $0.id == input.id })
                        Menu {
                            Button("workspace.workspace_canvas_view.edit", systemImage: "pencil") { onEdit(input) }
                            Button("chat.thread_detail_view.move_up", systemImage: "arrow.up") { onMove(input, -1) }
                                .disabled(queuedIndex == nil || queuedIndex == queuedInputs.startIndex)
                            Button("chat.thread_detail_view.move_down", systemImage: "arrow.down") { onMove(input, 1) }
                                .disabled(queuedIndex == nil || queuedIndex == queuedInputs.indices.last)
                            Button("chat.thread_detail_view.convert_to_steer", systemImage: "arrow.triangle.turn.up.right.diamond") {
                                onSteer(input)
                            }
                            .disabled(!canSteer || input.status != .queued)
                            Divider()
                            Button("workspace.workspace_canvas_view.delete", systemImage: "trash", role: .destructive) { onDelete(input) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        }
                        .accessibilityLabel("chat.thread_detail_view.queue_message_action")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }

    private var queuedInputs: [PendingUserInput] {
        inputs.filter { $0.status == .queued }
    }

    /// A trusted internal notice steer (design-assistant confirmation or
    /// structured proposal decision) shows the concise localized summary
    /// instead of the raw grant/target/identity payload. A validated proposal
    /// decision uses its decision-specific sentence. Every other input is
    /// untouched.
    private func displayText(for input: PendingUserInput) -> String {
        if let decisionSummary = ProposalDecisionPresentation.summary(for: input) {
            return decisionSummary
        }
        if let summary = InternalNoticeProjection.userFacingSummary(for: input) {
            return summary
        }
        return input.executionMode == "browserHandoff"
            ? IDELanguageRunText.t("浏览器控制权已交还", "Browser control returned")
            : input.content
    }

    private func statusTitle(_ status: PendingUserInputStatus) -> String {
        switch status {
        case .queued: FloeL10n.l("chat.thread_detail_view.wait_for_the_current_run_to")
        case .promoting: FloeL10n.l("chat.thread_detail_view.converting_to_steer")
        case .steerPending: FloeL10n.l("chat.thread_detail_view.waiting_for_a_safe_insertion_point")
        case .consumed: FloeL10n.l("chat.thread_detail_view.sent")
        case .cancelled: FloeL10n.l("chat.thread_detail_view.cancelled")
        }
    }
}

private struct GoalBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var objective = ""
    @State private var criteria = ""
    @State private var blockers = ""
    @State private var stops = ""
    let onCreate: (String, [String], [String], [String]) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("chat.thread_detail_view.final_goal") {
                    TextEditor(text: $objective).frame(minHeight: 90)
                }
                Section("chat.thread_detail_view.acceptance_criteria_one_per_line") {
                    TextEditor(text: $criteria).frame(minHeight: 80)
                }
                Section("chat.thread_detail_view.blocking_conditions_one_per_line") {
                    TextEditor(text: $blockers).frame(minHeight: 80)
                }
                Section("chat.thread_detail_view.stop_conditions_one_per_line") {
                    TextEditor(text: $stops).frame(minHeight: 80)
                }
            }
            .navigationTitle("chat.thread_detail_view.set_goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("workspace.workspace_canvas_view.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("chat.thread_detail_view.create_and_start") {
                        onCreate(objective, lines(criteria), lines(blockers), lines(stops))
                        dismiss()
                    }
                    .disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func lines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct PendingInputEditor: View {
    let input: PendingUserInput
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(input: PendingUserInput, onSave: @escaping (String) -> Void) {
        self.input = input
        self.onSave = onSave
        _text = State(initialValue: input.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("chat.thread_detail_view.queue_message", text: $text, axis: .vertical)
                    .lineLimit(3...10)
            }
            .navigationTitle("chat.thread_detail_view.edit_queue_message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("workspace.workspace_canvas_view.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("workspace.workspace_canvas_view.save") {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// The terminal marker row: a single quiet status line, always rendered
/// after the final assistant reply. No big card, no raw machine names —
/// the stop reason resolves through RunStateLocalizer.
struct TerminalEventRow: View {
    let event: RunEventRecord

    private var state: String {
        ConversationCenter.decodePayload(event.payloadJSON)["stopReason"] ?? "completed"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state == "completed" || state == "endTurn"
                ? "checkmark.circle" : "stop.circle")
                .foregroundStyle(RunStateLocalizer.color(for: "completed"))
                .accessibilityHidden(true)
            Text(RunStateLocalizer.terminalTitle(stopReason: state))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            Spacer()
            Text(event.createdAt, style: .time)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread.terminal")
    }
}

/// A completed run that produced no final assistant text is an explicit,
/// honest failure surface — never silent.
private struct MissingFinalMessageRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            Text("thread.no_final_reply")
                .font(FloeTheme.Typography.body)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread.no_final_reply")
    }
}

/// A persisted message: user goals render as right-aligned bubbles with
/// attachment chips; other roles (final assistant answers) render as
/// Markdown in the left-aligned reading column.
private struct MessageBubble: View {
    let message: PersistedMessage
    var displayedText: String? = nil
    var onSaveToNotes: ((String) -> Void)? = nil
    var onOpenAttachment: ((AttachmentChipItem) -> Void)? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    /// Explicit design entrance: one chosen attachment of this message as a typed
    /// chat-attachment target (original task + exact attachment identity).
    @State private var designTarget: DesignTarget?

    private var attachmentItems: [AttachmentChipItem] {
        AttachmentChipItem.items(in: message.parts)
    }

    /// Explicit typed design entry for ONE attachment. Multi-attachment
    /// messages list every file/image attachment as its own entry — never a
    /// first-attachment or current-selection heuristic.
    private func attachmentDesignTarget(attachmentID: UUID) -> DesignTarget {
        DesignOwnerTargets.chatAttachment(
            conversationID: message.conversationID,
            messageID: message.id,
            attachmentID: attachmentID)
    }

    private var attachmentDesignEntries: [(id: UUID, name: String)] {
        message.parts.compactMap { part in
            guard part.kind == .file || part.kind == .image,
                  let attachmentID = part.attachmentID else { return nil }
            // Same name resolution as the visible attachment chips.
            let name = part.metadata["name"] ?? part.text ?? attachmentID.uuidString
            return (attachmentID, name)
        }
    }

    var body: some View {
        Group {
            if message.role == "user" {
                UserMessageBubble(text: displayedText ?? message.content, attachments: attachmentItems, onOpenAttachment: onOpenAttachment)
            } else {
                AssistantMessageView(
                    text: displayedText ?? message.content, isStreaming: false,
                    onSaveToNotes: onSaveToNotes, attachments: attachmentItems, onOpenAttachment: onOpenAttachment)
            }
        }
        .contextMenu {
            // Per-attachment explicit entry/selection: with several
            // attachments each one gets its own design item bound to its
            // exact attachment identity.
            ForEach(attachmentDesignEntries, id: \.id) { entry in
                Button {
                    designTarget = attachmentDesignTarget(attachmentID: entry.id)
                } label: {
                    Label {
                        Text("design.owner.from_attachment_named \(entry.name)")
                    } icon: {
                        Image(systemName: "square.on.square.dashed")
                    }
                }
                .accessibilityIdentifier("design.owner.fromAttachment.\(entry.id.uuidString)")
            }
        }
.onChange(of: designTarget, initial: false) { _, target in
            // The per-attachment design entry opens the SAME conversation's
            // design page (preview + conversation), never a second chat and
            // never the old form — presented from the stable app root.
            guard let target else { return }
            router.presentedDesignPage = DesignPageRequest(
                target: target, conversationID: message.conversationID)
            designTarget = nil
        }
    }
}
private struct TaskExportFile: Identifiable {
    let id = UUID()
    let url: URL
    let lease: ScratchLeaseToken
}

private struct TaskExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    let lease: ScratchLeaseToken
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            lease.release()
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Full readable temporary-chat explanation opened from the badge menu.
///
/// The native menu row itself only fits a short lifecycle header; every
/// disclosure (immediate discard semantics, the read-only tool ceiling and
/// the provider's own processing policy, the voice-processing note) stays
/// fully readable here instead of being clipped or removed.
struct TemporaryChatAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("chat.temporary.banner")
                        .accessibilityIdentifier("chat.temporary.about.lifecycle")
                    Text("chat.temporary.about.tools")
                        .accessibilityIdentifier("chat.temporary.about.tools")
                    Text("chat.temporary.voiceNote")
                        .accessibilityIdentifier("chat.temporary.voice.note")
                }
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("chat.temporary.about.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "providers.save.done")) { dismiss() }
                        .frame(minHeight: FloeTheme.minimumTarget)
                        .accessibilityIdentifier("chat.temporary.about.done")
                }
            }
        }
    }
}
#endif
