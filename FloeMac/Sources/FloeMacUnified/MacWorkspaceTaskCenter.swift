// SPDX-License-Identifier: MPL-2.0

import FloePersistence
import SwiftUI

/// Mac task center: the durable conversation list with the newest persisted
/// run state per task. Every status comes from real `ConversationRecord` /
/// `RunRecord` rows published by `HostAgentWorkspace`; the view fabricates
/// nothing and falls back to an honest "unknown" for unrecognized states.
struct MacWorkspaceTaskCenter: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let onOpen: (UUID) -> Void
    let onNew: () -> Void

    @Environment(\.locale) private var locale
    @State private var query = ""
    private let relativeFormatter: RelativeDateTimeFormatter

    init(workspace: HostAgentWorkspace, onOpen: @escaping (UUID) -> Void, onNew: @escaping () -> Void) {
        self.workspace = workspace
        self.onOpen = onOpen
        self.onNew = onNew
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
        // change when an existing conversation is updated by a run).
        .task(id: workspace.isReady) { await workspace.loadTaskRuns() }
        .onChange(of: workspace.conversations.map(\.id)) { _, _ in
            Task { await workspace.loadTaskRuns() }
        }
        .onChange(of: workspace.isSending) { _, sending in
            if !sending { Task { await workspace.loadTaskRuns() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(t("搜索任务", "Search Tasks"), text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("workspace.task.search")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.fill.quaternary, in: .rect(cornerRadius: 6))
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
        }
        .padding()
    }

    @ViewBuilder private var content: some View {
        if tasks.isEmpty {
            ContentUnavailableView {
                Label(t("暂无任务", "No Tasks Yet"), systemImage: "checklist")
            } description: {
                Text(t("新建一个任务，开始与 Floe 协作。", "Create a task to start working with Floe."))
            } actions: {
                Button(t("新建任务", "New Task"), action: onNew)
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.isSending || workspace.isTerminating)
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

    /// Ordinary tasks only: notes, archived and editor-owned rows stay out of
    /// the task center exactly as they stay out of the ordinary chat list.
    private var tasks: [ConversationRecord] {
        workspace.conversations.filter(\.isVisibleInOrdinaryList)
    }

    private var visible: [ConversationRecord] {
        let ordered = ConversationListOrdering.sorted(tasks)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ordered }
        return ordered.filter { record in
            if record.title.localizedStandardContains(trimmed) { return true }
            guard let run = workspace.recentTaskRuns[record.id] else { return false }
            return run.goal.localizedStandardContains(trimmed)
        }
    }

    private func row(for record: ConversationRecord) -> some View {
        let run = workspace.recentTaskRuns[record.id]
        // A persisted nonterminal row is the LAST RECORDED state, not proof of
        // live ownership: only the workspace's actual current send spins.
        let sendingHere = workspace.isSending && workspace.selectedID == record.id
        return Button { onOpen(record.id) } label: {
            HStack(alignment: .center, spacing: 10) {
                if sendingHere {
                    ProgressView().controlSize(.mini)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(run.map { statusColor(for: $0.state) } ?? Color.clear)
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
                    caption(run: run, sendingHere: sendingHere)
                        .font(.caption)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(timeText(run?.startedAt ?? record.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(workspace.selectedID == record.id
                           ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityIdentifier("workspace.task.row.\(record.id.uuidString)")
    }

    private func caption(run: RunRecord?, sendingHere: Bool) -> Text {
        if sendingHere {
            var text = Text(t("运行中", "Running")).foregroundStyle(Color.blue)
            if let run, let duration = durationText(startedAt: run.startedAt, endedAt: run.endedAt) {
                text = text + Text(" · ").foregroundStyle(.secondary)
                    + Text(t("用时 ", "Took ") + duration).foregroundStyle(.secondary)
            }
            return text
        }
        guard let run else { return Text(" ").foregroundStyle(.secondary) }
        var text = Text(statusText(for: run.state)).foregroundStyle(statusColor(for: run.state))
        if let duration = durationText(startedAt: run.startedAt, endedAt: run.endedAt) {
            text = text + Text(" · ").foregroundStyle(.secondary)
                + Text(t("用时 ", "Took ") + duration).foregroundStyle(.secondary)
        }
        return text
    }

    private func title(for record: ConversationRecord) -> String {
        let trimmed = record.title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? t("未命名任务", "Untitled Task") : record.title
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
