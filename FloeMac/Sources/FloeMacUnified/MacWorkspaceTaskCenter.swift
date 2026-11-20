// SPDX-License-Identifier: MPL-2.0

import FloePersistence
import SwiftUI

/// Mac task center: the durable conversation list with the newest persisted
/// run state per task. Every status comes from real `ConversationRecord` /
/// `RunRecord` rows published by `HostAgentWorkspace`; the view fabricates
/// nothing and falls back to an honest "unknown" for unrecognized states.
///
/// History management mirrors the iPad Chat list on the same durable
/// commands: pin/unpin and rename (metadata changes), move/archive/delete,
/// an archived scope with the archived date, restore and a confirmed
/// clear-archive, plus cross-conversation search that combines title/goal
/// matches with durable message-text matches. A message hit shows its
/// projected snippet and opens the conversation at that exact message; the
/// archived scope keeps the restore workflow instead of opening.
struct MacWorkspaceTaskCenter: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let onOpen: (UUID) -> Void
    let onNew: () -> Void
    let onArchive: (UUID, Bool) -> Void
    let onMove: (ConversationRecord) -> Void
    let onDelete: (ConversationRecord) -> Void
    /// Optional owner hook for a verified content hit
    /// `(conversationID, messageID)`; nil falls back to plain `onOpen`.
    let onOpenMatch: ((UUID, UUID) -> Void)?

    @Environment(\.locale) private var locale
    let findRequest: UUID?
    let didDeleteArchived: (UUID) -> Void
    @FocusState private var searchFocused: Bool
    @State private var renameTarget: ConversationRecord?
    @State private var renameDraft = ""
    @State private var renameError: String?
    /// Inline, dismissible banner for failed management actions (pin,
    /// rename, clear archive). Honest text only; cleared by the next action.
    @State private var actionError: String?
    @State private var confirmsClearArchive = false
    @State private var archiveDeletionIDs: [UUID] = []
    @State private var clearingArchive = false
    private let relativeFormatter: RelativeDateTimeFormatter

    #if FLOE_MAC_HOST_SMOKE
    /// Live geometry of each result's open button, recorded by the smoke
    /// frame reader; memory-only and never persisted.
    static var smokeResultFrames: [UUID: CGRect] = [:]
    #endif

    init(workspace: HostAgentWorkspace, findRequest: UUID? = nil, onOpen: @escaping (UUID) -> Void, onNew: @escaping () -> Void,
         onArchive: @escaping (UUID, Bool) -> Void, onMove: @escaping (ConversationRecord) -> Void,
         onDelete: @escaping (ConversationRecord) -> Void, didDeleteArchived: @escaping (UUID) -> Void,
         onOpenMatch: ((UUID, UUID) -> Void)? = nil) {
        self.didDeleteArchived = didDeleteArchived
        self.findRequest = findRequest
        self.workspace = workspace
        self.onOpen = onOpen
        self.onNew = onNew
        self.onArchive = onArchive
        self.onMove = onMove
        self.onDelete = onDelete
        self.onOpenMatch = onOpenMatch
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        self.relativeFormatter = formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if workspace.isPreparing {
                ProgressView(t("正在打开任务…", "Opening tasks…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !workspace.isReady {
                ContentUnavailableView {
                    Label(t("任务不可用", "Tasks Unavailable"),
                          systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(t("Floe 无法读取任务历史。", "Floe could not read the task history."))
                } actions: {
                    Button(t("重试", "Try Again")) { Task { await workspace.prepare() } }
                        .accessibilityIdentifier("workspace.task.retry.ready")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Re-read run states when storage becomes ready, when the conversation
        // set changes, and when a send finishes (the id array alone does not
        // change when an existing conversation is updated by a run). The same
        // moments re-arm the debounced content search so results track the
        // durable store; the latest query owns every publish.
        .task(id: workspace.isReady) {
            await workspace.loadTaskRuns()
            workspace.scheduleTaskContentSearch(
                query: workspace.taskCenterQuery, archived: workspace.taskCenterShowsArchived)
        }
        .onChange(of: workspace.conversations) { _, _ in
            Task { await workspace.loadTaskRuns() }
            workspace.scheduleTaskContentSearch(
                query: workspace.taskCenterQuery, archived: workspace.taskCenterShowsArchived)
        }
        .onChange(of: workspace.taskCenterQuery) { _, value in
            workspace.scheduleTaskContentSearch(
                query: value, archived: workspace.taskCenterShowsArchived)
        }
        .onChange(of: workspace.taskCenterShowsArchived) { _, value in
            workspace.scheduleTaskContentSearch(
                query: workspace.taskCenterQuery, archived: value)
        }
        .onChange(of: workspace.activeRunCount) { previous, count in
            if count < previous {
                Task { await workspace.loadTaskRuns() }
                workspace.scheduleTaskContentSearch(query: workspace.taskCenterQuery, archived: workspace.taskCenterShowsArchived)
            }
        }
        .popover(item: $renameTarget, arrowEdge: .trailing) { record in
            renamePopover(for: record)
        }
        .alert(t("清空归档？", "Clear Archive?"), isPresented: $confirmsClearArchive) {
            Button(t("取消", "Cancel"), role: .cancel) {}
            Button(t("永久删除", "Delete Permanently"), role: .destructive) {
                Task { await clearArchived() }
            }
        } message: {
            Text(t("归档中的 \(archiveDeletionIDs.count) 个任务及其会话记录将被永久删除。",
                   "The \(archiveDeletionIDs.count) archived tasks and their conversation history will be deleted permanently."))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                taskFilters
                if workspace.taskCenterShowsArchived && !tasks.isEmpty {
                    Spacer(minLength: 8)
                    Button(t("清空归档…", "Clear Archive…")) {
                        archiveDeletionIDs = tasks.map(\.id)
                        confirmsClearArchive = true
                    }
                        .disabled(clearingArchive || workspace.isTerminating || workspace.isAcceptingPlan)
                        .accessibilityIdentifier("workspace.task.clearArchive")
                }
            }
            if workspace.taskRunLookupFailed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(t("运行状态读取失败。", "Couldn’t read run states."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(t("重试", "Retry")) { Task { await workspace.loadTaskRuns() } }
                        .accessibilityIdentifier("workspace.task.retry.runs")
                }
            }
            if workspace.taskContentSearchFailed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(t("消息内容搜索失败。", "Couldn’t search message content."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(t("重试", "Retry")) {
                        workspace.scheduleTaskContentSearch(
                            query: workspace.taskCenterQuery, archived: workspace.taskCenterShowsArchived)
                    }
                    .accessibilityIdentifier("workspace.task.retry.contentSearch")
                }
                .accessibilityIdentifier("workspace.task.contentSearchError")
            }
            if let actionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button(t("关闭", "Dismiss")) { self.actionError = nil }
                        .accessibilityIdentifier("workspace.task.actionError.dismiss")
                }
                .accessibilityIdentifier("workspace.task.actionError")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: findRequest) { _, request in
            if request != nil { searchFocused = true }
        }
    }

    @ViewBuilder private var taskFilters: some View {
        Picker(t("任务列表", "Task List"), selection: $workspace.taskCenterShowsArchived) {
            Text(t("当前任务", "Current")).tag(false)
            Text(t("已归档", "Archived")).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(t("搜索任务或消息", "Search tasks or messages"), text: $workspace.taskCenterQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("workspace.task.search")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.fill.quaternary, in: .rect(cornerRadius: 6))
    }

    @ViewBuilder private var content: some View {
        if tasks.isEmpty && workspace.taskCenterShowsArchived {
            ContentUnavailableView(t("暂无已归档任务", "No Archived Tasks"), systemImage: "archivebox")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tasks.isEmpty {
            ContentUnavailableView {
                Label(t("暂无任务", "No Tasks Yet"), systemImage: "checklist")
            } description: {
                Text(t("新建一个任务，开始与 Floe 协作。", "Create a task to start working with Floe."))
            } actions: {
                Button(t("新建任务", "New Task"), action: onNew)
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.isTerminating)
                    .accessibilityIdentifier("workspace.task.empty.new")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView(t("没有匹配的任务", "No Matching Tasks"),
                                   systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(visible) { record in
                    row(for: record)
                }
            }
            .listStyle(.inset)
        }
    }

    private var tasks: [ConversationRecord] {
        if !workspace.taskCenterShowsArchived { return workspace.conversations.filter(\.isVisibleInOrdinaryList) }
        return workspace.conversations.filter {
            $0.purpose == .ordinary && $0.visibility == .normal && $0.editorOwnership == nil && $0.archivedAt != nil
        }
    }

    /// A conversation stays listed when its title, its latest run goal, or a
    /// persisted message body matches the query. Content matches come from
    /// the scoped durable search; title/goal matching stays client-side.
    private var visible: [ConversationRecord] {
        let ordered = ConversationListOrdering.sorted(tasks)
        let trimmed = searchQuery
        guard !trimmed.isEmpty else { return ordered }
        return ordered.filter { record in
            if record.title.localizedStandardContains(trimmed) { return true }
            if workspace.taskContentMatchesByID[record.id] != nil { return true }
            guard let run = workspace.recentTaskRuns[record.id] else { return false }
            return run.goal.localizedStandardContains(trimmed)
        }
    }

    private var searchQuery: String { workspace.taskCenterQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// iPad list parity: a durable message hit shows its projected snippet;
    /// otherwise, when the query matched persisted run content rather than
    /// the title, surface a small window around the first hit so the match
    /// is explainable (the iPad row shows the same kind of snippet).
    private func matchSnippet(for record: ConversationRecord) -> String? {
        let trimmed = searchQuery
        guard !trimmed.isEmpty else { return nil }
        if let match = workspace.taskContentMatchesByID[record.id] { return match.snippet }
        guard !record.title.localizedStandardContains(trimmed),
              let run = workspace.recentTaskRuns[record.id],
              run.goal.localizedStandardContains(trimmed) else { return nil }
        return Self.matchSnippet(goal: run.goal, query: trimmed)
    }

    /// Pure snippet helper: a bounded window around the first
    /// case/diacritic-insensitive occurrence, honest ellipses when clipped.
    static func matchSnippet(goal: String, query: String, limit: Int = 120) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let range = goal.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        guard goal.utf8.count > limit else { return goal }
        let lower = goal.index(range.lowerBound, offsetBy: -(limit / 3),
                               limitedBy: goal.startIndex) ?? goal.startIndex
        let upper = goal.index(range.upperBound, offsetBy: limit / 2,
                               limitedBy: goal.endIndex) ?? goal.endIndex
        return (lower > goal.startIndex ? "…" : "")
            + goal[lower..<upper]
            + (upper < goal.endIndex ? "…" : "")
    }

    private func row(for record: ConversationRecord) -> some View {
        let run = workspace.recentTaskRuns[record.id]
        let snippet = matchSnippet(for: record)
        // A persisted nonterminal row is the LAST RECORDED state, not proof of
        // live ownership: only the workspace's actual current send spins.
        let sendingHere = workspace.isTaskRunning(record.id)
        return HStack {
            Button {
                guard !workspace.taskCenterShowsArchived else { return }
                // A verified durable content hit opens at its exact message;
                // anything else opens the conversation as before.
                if let match = workspace.taskContentMatchesByID[record.id],
                   let messageID = match.messageID,
                   let onOpenMatch {
                    onOpenMatch(match.conversationID, messageID)
                } else {
                    onOpen(record.id)
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    if workspace.hasPendingApproval(in: record.id) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    } else if workspace.isWaitingForAnswer(in: record.id) {
                        Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    } else if sendingHere {
                        ProgressView().controlSize(.mini)
                            .accessibilityHidden(true)
                    } else {
                        Circle()
                        .fill(run.map { statusColor(for: displayedState($0)) } ?? Color.clear)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if record.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            Text(title(for: record))
                                .font(.body)
                                .lineLimit(1)
                        }
                        if let snippet {
                            Text(snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .accessibilityIdentifier("workspace.task.snippet")
                        }
                        caption(run: run, taskID: record.id, sendingHere: sendingHere)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(timeText(rowDate(record: record, run: run)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .disabled(workspace.taskCenterShowsArchived)
            .accessibilityIdentifier("workspace.task.open.\(record.id.uuidString)")
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader {
                Self.smokeResultFrames[record.id] = $0
            })
            #endif
            if workspace.taskCenterShowsArchived {
                Button(t("恢复", "Restore")) { onArchive(record.id, false) }
                    .disabled(sendingHere || workspace.isTerminating || workspace.isAcceptingPlan)
            }
        }
        .contextMenu {
            if sendingHere {
                Button("host.chat.stop", systemImage: "stop.circle") { workspace.stopTask(record.id) }
            }
            if !workspace.taskCenterShowsArchived {
                Button(LocalizedStringKey(record.isPinned ? "mac.workspace.unpin" : "mac.workspace.pin"),
                       systemImage: record.isPinned ? "pin.slash" : "pin") {
                    Task { await setPinned(!record.isPinned, for: record.id) }
                }
                .disabled(sendingHere || workspace.isTerminating || workspace.isAcceptingPlan)
                Button("mac.workspace.rename", systemImage: "pencil") {
                    renameTarget = record
                    renameDraft = record.title
                    renameError = nil
                }
                .disabled(sendingHere || workspace.isTerminating || workspace.isAcceptingPlan)
                Button("mac.workspace.moveTask", systemImage: "folder") { onMove(record) }
                    .disabled(sendingHere || workspace.isTerminating || workspace.isAcceptingPlan)
                Button(t("归档", "Archive"), systemImage: "archivebox") { onArchive(record.id, true) }
                    .disabled(sendingHere || workspace.isTerminating || workspace.isAcceptingPlan)
            } else {
                Button(t("恢复", "Restore"), systemImage: "arrow.uturn.backward") { onArchive(record.id, false) }
                    .disabled(sendingHere || workspace.isTerminating || workspace.isAcceptingPlan)
            }
            Button(t("删除任务…", "Delete Task…"), systemImage: "trash", role: .destructive) { onDelete(record) }
                .disabled(sendingHere || workspace.isTerminating || workspace.isAcceptingPlan)
        }
        .listRowBackground(workspace.selectedID == record.id
                           ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityIdentifier("workspace.task.row.\(record.id.uuidString)")
    }

    /// Archived rows answer "when was it archived" (iPad archive parity);
    /// current rows keep the run/activity recency date.
    private func rowDate(record: ConversationRecord, run: RunRecord?) -> Date {
        if workspace.taskCenterShowsArchived { return record.archivedAt ?? record.updatedAt }
        return run?.startedAt ?? record.updatedAt
    }

    private func caption(run: RunRecord?, taskID: UUID, sendingHere: Bool) -> Text {
        if sendingHere {
            if workspace.hasPendingApproval(in: taskID) {
                return Text(t("等待审批", "Awaiting approval")).foregroundStyle(Color.orange)
            }
            if workspace.isWaitingForAnswer(in: taskID) {
                return Text(t("等待你回答", "Waiting for your answer")).foregroundStyle(Color.orange)
            }
            var text = Text(t("运行中", "Running")).foregroundStyle(Color.blue)
            if let run, let duration = durationText(startedAt: run.startedAt, endedAt: run.endedAt) {
                text = text + Text(" · ").foregroundStyle(.secondary)
                    + Text(t("用时 ", "Took ") + duration).foregroundStyle(.secondary)
            }
            return text
        }
        guard let run else { return Text(" ").foregroundStyle(.secondary) }
        let state = displayedState(run)
        var text = Text(statusText(for: state)).foregroundStyle(statusColor(for: state))
        if let duration = durationText(startedAt: run.startedAt, endedAt: run.endedAt) {
            text = text + Text(" · ").foregroundStyle(.secondary)
                + Text(t("用时 ", "Took ") + duration).foregroundStyle(.secondary)
        }
        return text
    }

    private func displayedState(_ run: RunRecord) -> String {
        guard run.endedAt == nil,
              !workspace.isTaskRunning(run.conversationID) else { return run.state }
        switch run.state {
        case "idle", "preparing", "running", "streamingModel", "preparingToolCall", "executingTool",
             "verifying", "committingResults", "reconnecting", "compacting", "reviewingApproval",
             "waitingApproval", "waitingTool", "waitingUser", "waitingUserQuestion", "waitingNativeInput",
             "cancelling":
            return "interrupted"
        default:
            return run.state
        }
    }

    private func title(for record: ConversationRecord) -> String {
        record.workbenchDisplayTitle
    }

    // MARK: - Task management actions (durable runtime commands)

    /// Pin/unpin through the same metadata command the sidebar uses; a
    /// failure is surfaced inline instead of failing silently.
    private func setPinned(_ pinned: Bool, for id: UUID) async {
        actionError = nil
        let changed = await workspace.changeConversationMetadata(id: id, change: .pin(pinned))
        if !changed { actionError = String(localized: "mac.workspace.saveFailed") }
    }

    /// The runtime caps titles at 200 UTF-8 bytes; the Save button stays
    /// disabled past that, and the inline message explains why.
    private var renameTooLong: Bool { renameDraft.utf8.count > 200 }

    private func renamePopover(for record: ConversationRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("mac.workspace.taskName", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .accessibilityIdentifier("workspace.task.rename.field")
            if renameTooLong {
                Text(t("名称过长（最多 200 字节）。", "The name is too long (200 bytes maximum)."))
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let renameError {
                Text(renameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("host.chat.cancel", role: .cancel) { renameTarget = nil }
                    .accessibilityIdentifier("workspace.task.rename.cancel")
                Button("host.chat.save") { Task { await saveRename(for: record) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameTooLong)
                    .accessibilityIdentifier("workspace.task.rename.save")
            }
        }
        .padding(14)
        .accessibilityIdentifier("workspace.task.rename.popover")
    }

    private func saveRename(for record: ConversationRecord) async {
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 200 else {
            renameError = t("请输入有效名称。", "Enter a valid name.")
            return
        }
        actionError = nil
        let saved = await workspace.changeConversationMetadata(id: record.id, change: .rename(title))
        renameTarget = nil
        renameError = nil
        if !saved { actionError = String(localized: "mac.workspace.saveFailed") }
    }

    private func clearArchived() async {
        guard !clearingArchive else { return }
        clearingArchive = true
        defer { clearingArchive = false }
        actionError = nil
        var failures = 0
        let confirmed = archiveDeletionIDs
        for id in confirmed {
            guard let record = workspace.conversations.first(where: { $0.id == id }),
                  record.archivedAt != nil, record.purpose == .ordinary, record.visibility == .normal,
                  record.editorOwnership == nil else { continue }
            guard !workspace.isTaskRunning(id),
                  await workspace.changeConversationMetadata(id: id, change: .delete) else {
                failures += 1
                continue
            }
            didDeleteArchived(id)
        }
        if failures > 0 {
            actionError = t("\(failures) 个任务删除失败，请重试。",
                            "\(failures) tasks could not be deleted. Try again.")
        }
    }

    // MARK: - Run state presentation (machine name → concise bilingual label)

    private func statusText(for state: String) -> String {
        switch state {
        case "preparing", "idle": t("准备中", "Preparing")
        case "streamingModel": t("模型回复中", "Streaming")
        case "preparingToolCall": t("准备工具", "Preparing tool")
        case "executingTool": t("执行工具", "Running tool")
        case "verifying": t("校验中", "Verifying")
        case "committingResults": t("保存结果", "Saving results")
        case "reconnecting": t("重连中", "Reconnecting")
        case "compacting": t("压缩上下文", "Compacting")
        case "reviewingApproval": t("审批复核", "Reviewing approval")
        case "waitingApproval": t("等待批准", "Waiting for approval")
        case "waitingTool": t("等待工具", "Waiting for tool")
        case "waitingUser", "waitingUserQuestion": t("等待输入", "Waiting for you")
        case "waitingNativeInput": t("等待输入", "Waiting for input")
        case "cancelling": t("正在停止", "Stopping")
        case "completed": t("已完成", "Completed")
        case "failed": t("失败", "Failed")
        case "recoveryFailed": t("恢复失败", "Recovery failed")
        case "interrupted": t("已中断", "Interrupted")
        case "checkpointed", "paused": t("已暂停", "Paused")
        case "blocked", "noProgress": t("被阻塞", "Blocked")
        case "budgetLimited": t("预算已用完", "Budget reached")
        case "truncated": t("输出截断", "Truncated")
        case "cancelled", "canceled": t("已停止", "Stopped")
        default: t("未知", "Unknown")
        }
    }

    private func statusColor(for state: String) -> Color {
        switch state {
        case "completed": .green
        case "failed", "recoveryFailed", "cancelling": .red
        case "interrupted", "checkpointed", "paused", "blocked", "noProgress",
             "budgetLimited", "truncated", "waitingApproval", "waitingTool",
             "waitingUser", "waitingUserQuestion", "waitingNativeInput", "compacting",
             "reviewingApproval": .orange
        default: .blue
        }
    }

    private func durationText(startedAt: Date, endedAt: Date?) -> String? {
        guard let endedAt else { return nil }
        let total = max(0, Int(endedAt.timeIntervalSince(startedAt).rounded()))
        if total < 60 { return t("\(total) 秒", "\(total)s") }
        let minutes = total / 60
        if minutes < 60 { return t("\(minutes) 分钟", "\(minutes)m") }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest > 0 ? t("\(hours) 小时 \(rest) 分钟", "\(hours)h \(rest)m")
                        : t("\(hours) 小时", "\(hours)h")
    }

    private func timeText(_ date: Date) -> String {
        relativeFormatter.locale = locale
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func t(_ chinese: String, _ english: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? chinese : english
    }
}
