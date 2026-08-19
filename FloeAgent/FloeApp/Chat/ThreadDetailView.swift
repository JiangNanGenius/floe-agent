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
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime

/// The canonical thread: messages + run events for one conversation.
struct ThreadDetailView: View {
    @StateObject private var viewModel: ThreadDetailViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingPendingInput: PendingUserInput?
    @State private var showingGoalBuilder = false
    @State private var showingScreenShare = false
    @State private var showingScreenShareGuide = false
    @State private var confirmingScreenTransmission = false
    @State private var showingPermissionsSheet = false

    init(conversationID: UUID, center: ConversationCenter) {
        _viewModel = StateObject(
            wrappedValue: ThreadDetailViewModel(conversationID: conversationID, center: center)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.latestPlan != nil || viewModel.activeGoal != nil {
                intelligenceStatus
            }
            Divider()
            threadScroll
            if let error = viewModel.actionError {
                errorBanner(error)
            }
            composer
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle(viewModel.taskTitle.isEmpty ? String(localized: "thread.title") : viewModel.taskTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { stateToolbar }
        .task {
            viewModel.selectedRunID = router.selectedRunID
            await viewModel.load()
        }
        .onDisappear { viewModel.stopLiveUpdates() }
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
                TaskPermissionsInspectorView(conversationID: viewModel.conversationID)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("action.done") { showingPermissionsSheet = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingScreenShare) {
            BroadcastPickerView(center: environment.screenShareCenter)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showingScreenShareGuide) {
            ScreenShareGuideView(
                center: environment.screenShareCenter,
                userGoal: viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? viewModel.taskTitle
                    : viewModel.draft
            )
        }
        .alert("发送当前屏幕画面？", isPresented: $confirmingScreenTransmission) {
            Button("取消", role: .cancel) {}
            Button("发送并继续") {
                guard environment.screenShareCenter.confirmScreenAnalysisTransmission() else { return }
                showingScreenShareGuide = true
            }
        } message: {
            Text("当前完整屏幕截图将发送到 \(environment.screenShareCenter.analysisDestinationName) 进行分析，画面可能包含其他 App 的敏感信息。")
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
                        recommendation == .goal ? "建议转为 Goal" : "建议普通执行",
                        systemImage: recommendation == .goal ? "target" : "play.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let reason = plan.recommendationReason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if plan.status == .awaitingInput || plan.status == .ready {
                    HStack {
                        Button("按普通计划执行") {
                            Task { await viewModel.acceptLatestPlan(as: .normal) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("转为 Goal") {
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // The unified timeline: user goal → run events in stored
                    // sequence → live tail → approvals → terminal last.
                    // "Completed" can never float above the final reply.
                    ForEach(viewModel.timeline) { item in
                        timelineRow(item)
                            .id(item.id)
                    }

                    if viewModel.events.isEmpty && viewModel.messages.isEmpty {
                        ContentUnavailableView {
                            Label("thread.empty", systemImage: "text.bubble")
                        } description: {
                            Text("thread.empty.hint")
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.liveStreamedText.count) { _, _ in
                // Follow the streaming tail smoothly without yanking the
                // scroll position on every cluster — only while the tail
                // is the live bottom of the thread. Persisted-event growth
                // deliberately does NOT auto-scroll, so the user can review
                // reasoning, tool calls, and earlier output mid-thread
                // without being dragged back to the bottom.
                guard viewModel.showsLiveTail,
                      !viewModel.liveStreamedText.isEmpty else { return }
                proxy.scrollTo(ThreadTimelineItem.liveAssistantTail.id, anchor: .bottom)
            }
        }
    }

    /// Renders one unified timeline row.
    @ViewBuilder
    private func timelineRow(_ item: ThreadTimelineItem) -> some View {
        switch item {
        case .userMessage(let message):
            MessageBubble(message: message)

        case .assistantMessage(let text, _):
            AssistantMessageView(text: text, isStreaming: false)

        case .event(let event):
            ThreadEventView(
                event: event,
                isLive: viewModel.isRunning,
                hasError: viewModel.events.contains { $0.kind == .error },
                onRetry: viewModel.selectedRun.map {
                    $0.state == "failed" || $0.state == "interrupted"
                } == true
                    ? { Task { await viewModel.retry() } }
                    : nil
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
            HStack(spacing: 10) {
                ProgressView()
                Text(LocalizedStringKey(viewModel.hasProviderActivity
                    ? "thread.model_thinking"
                    : "thread.contacting_provider"))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .approval(let approval):
            ApprovalCardView(approval: approval) { decision in
                Task { await viewModel.resolve(approval, decision: decision) }
            }
        }
    }

    // MARK: - State toolbar (status + Stop/Retry + inspector)

    /// Plain-text export of the conversation (title + user/assistant turns).
    private var exportText: String? {
        let messages = viewModel.messages
        guard !messages.isEmpty else { return nil }
        let title = viewModel.taskTitle.isEmpty ? "对话" : viewModel.taskTitle
        let body = messages
            .map { "\($0.role == "user" ? "用户" : "助手"): \($0.content)" }
            .joined(separator: "\n\n")
        return "\(title)\n\n\(body)"
    }

    @ToolbarContentBuilder
    private var stateToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("直接设置 Goal", systemImage: "target") {
                    showingGoalBuilder = true
                }
                if let exportText {
                    ShareLink(item: exportText) {
                        Label("导出对话", systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
                Button("共享屏幕", systemImage: "rectangle.on.rectangle") {
                    showingScreenShare = true
                }
                if environment.screenShareCenter.isSharing {
                    Button("操作引导", systemImage: "hand.tap") {
                        if environment.screenShareCenter.hasScreenAnalysisConsent {
                            showingScreenShareGuide = true
                        } else {
                            confirmingScreenTransmission = true
                        }
                    }
                }
                Divider()
                inspectorButton("变更", icon: "arrow.triangle.2.circlepath", content: .changes)
                inspectorButton("文件", icon: "folder", content: .workspaceFiles)
                inspectorButton("浏览器", icon: "safari", content: .browser)
                inspectorButton("终端/主机", icon: "terminal", content: .terminal)
                inspectorButton("进度", icon: "chart.bar", content: .progress)
                inspectorButton("子 Agent", icon: "person.2", content: .childAgents)
                inspectorButton("权限", icon: "lock.shield", content: .permissions)
                if router.inspectorVisible {
                    Divider()
                    Button("收起检查器", systemImage: "sidebar.right") { router.hideInspector() }
                }
            } label: {
                Label("inspector.files", systemImage: "sidebar.right")
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("inspector.files")
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
            } else if let run = viewModel.selectedRun,
                      run.state == "failed" || run.state == "interrupted" {
                Button {
                    Task { await viewModel.retry() }
                } label: {
                    Label("action.retry", systemImage: "arrow.clockwise")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("action.retry")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let state = viewModel.liveStateName {
                Text(RunStateLocalizer.title(for: state))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(RunStateLocalizer.color(for: state))
                    .accessibilityLabel(Text(RunStateLocalizer.title(for: state)))
                    .accessibilityIdentifier("thread.run_state.\(state)")
            }
        }
    }

    private func inspectorButton(
        _ title: String,
        icon: String,
        content: AppRouter.InspectorContent
    ) -> some View {
        Button(title, systemImage: icon) { router.showInspector(content) }
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
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(FloeTheme.destructive.opacity(0.08))
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
                    agentMode: $viewModel.agentMode,
                    attachments: $viewModel.attachments,
                    onSend: { Task { await viewModel.send() } },
                    onStop: { Task { await viewModel.cancel() } },
                    onPermissions: { showingPermissionsSheet = true },
                    approvalMode: viewModel.taskPolicy.resolvedApprovalMode
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
                Label("消息队列", systemImage: "text.badge.plus")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(inputs.count)")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            ForEach(inputs) { input in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(input.content)
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(statusTitle(input.status))
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(input.status == .queued ? .secondary : FloeTheme.pending)
                    }
                    Spacer(minLength: 4)
                    if input.status == .queued {
                        let queuedIndex = queuedInputs.firstIndex(where: { $0.id == input.id })
                        Menu {
                            Button("编辑", systemImage: "pencil") { onEdit(input) }
                            Button("上移", systemImage: "arrow.up") { onMove(input, -1) }
                                .disabled(queuedIndex == queuedInputs.startIndex)
                            Button("下移", systemImage: "arrow.down") { onMove(input, 1) }
                                .disabled(queuedIndex == queuedInputs.indices.last)
                            Button("转为引导", systemImage: "arrow.triangle.turn.up.right.diamond") {
                                onSteer(input)
                            }
                            .disabled(!canSteer)
                            Divider()
                            Button("删除", systemImage: "trash", role: .destructive) { onDelete(input) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        }
                        .accessibilityLabel("队列消息操作")
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

    private func statusTitle(_ status: PendingUserInputStatus) -> String {
        switch status {
        case .queued: "等待当前运行结束"
        case .promoting: "正在转为引导"
        case .steerPending: "等待安全插入点"
        case .consumed: "已发送"
        case .cancelled: "已取消"
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
                Section("最终目标") {
                    TextEditor(text: $objective).frame(minHeight: 90)
                }
                Section("验收标准（每行一条）") {
                    TextEditor(text: $criteria).frame(minHeight: 80)
                }
                Section("阻断条件（每行一条）") {
                    TextEditor(text: $blockers).frame(minHeight: 80)
                }
                Section("停止条件（每行一条）") {
                    TextEditor(text: $stops).frame(minHeight: 80)
                }
            }
            .navigationTitle("设置 Goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建并开始") {
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
                TextField("队列消息", text: $text, axis: .vertical)
                    .lineLimit(3...10)
            }
            .navigationTitle("编辑队列消息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
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
private struct TerminalEventRow: View {
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

    private var attachmentNames: [String] {
        message.parts
            .filter { $0.kind == .file || $0.kind == .image }
            .map { $0.metadata["name"] ?? $0.text ?? "" }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        if message.role == "user" {
            UserMessageBubble(text: message.content, attachments: attachmentNames)
        } else {
            AssistantMessageView(text: message.content, isStreaming: false)
        }
    }
}
#endif
