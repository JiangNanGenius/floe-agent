// SPDX-License-Identifier: MPL-2.0

import FloeModels
import FloePersistence
import SwiftUI

struct MacTaskScheduleView: View {
    @ObservedObject var center: MacTaskScheduleCenter
    @ObservedObject var workspace: HostAgentWorkspace
    let projectID: UUID?
    var originTaskID: UUID? = nil
    let openTask: (UUID) -> Void

    private struct Edit: Identifiable {
        let id = UUID()
        let record: TaskScheduleRecord?
    }

    @Environment(\.dismiss) private var dismiss
    @State private var edit: Edit?
    @State private var deleting: TaskScheduleRecord?
    @State private var linkedIDs: Set<UUID> = []
    /// Result line for the last successful Skip Next (iPad parity).
    @State private var skipNotice: String?
    @State private var manualLaunchRequest: UUID?
    #if FLOE_MAC_HOST_SMOKE
    static var smokeRunNowFrames: [UUID: CGRect] = [:]
    #endif

    private var visibleRecords: [TaskScheduleRecord] {
        guard let originTaskID else { return center.records }
        return center.records.filter { $0.originConversationID == originTaskID || linkedIDs.contains($0.id) }
    }

    private var visibleRuns: [TaskScheduleOccurrence] {
        guard let originTaskID else { return center.recent }
        let schedules = Set(visibleRecords.map(\.id))
        return center.recent.filter { $0.conversationID == originTaskID || schedules.contains($0.scheduleID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(MacPermissionsText.t("定时任务", "Scheduled Tasks")).font(.headline)
                Spacer()
                Button(MacPermissionsText.t("新建", "New"), systemImage: "plus") { edit = Edit(record: nil) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("mac.schedule.create")
                Button(MacPermissionsText.t("完成", "Done")) {
                    manualLaunchRequest = nil
                    dismiss()
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("mac.schedule.done")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: FloeTheme.minimumTarget + 4)
            Divider()
            Form {
                if let error = center.errorMessage { Text(error).foregroundStyle(.red) }
                if let skipNotice { Text(skipNotice).foregroundStyle(.secondary) }
                if let notifications = workspace.taskNotifications { MacNotificationAuthorizationRow(center: notifications) }
                Section {
                    ForEach(visibleRecords) { record in planRow(record) }
                    if visibleRecords.isEmpty {
                        Text(MacPermissionsText.t("暂无定时任务", "No scheduled tasks yet")).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(MacPermissionsText.t("Agent 运行时执行。错过的运行可从这里补跑。", "Runs while Agent is active. Run missed tasks here."))
                }
                if !visibleRuns.isEmpty {
                    Section(MacPermissionsText.t("最近运行", "Recent Runs")) {
                        ForEach(visibleRuns) { occurrence in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(center.records.first(where: { $0.id == occurrence.scheduleID })?.title ??
                                         MacPermissionsText.t("定时任务", "Scheduled Task"))
                                    Text(occurrence.scheduledFor, format: .dateTime.day().month().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let error = occurrence.errorText { Text(error).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(status(occurrence.state, skippedByUser: occurrence.summary == TaskScheduleOccurrence.userSkippedSummary))
                                    .foregroundStyle(.secondary)
                                if let taskID = occurrence.conversationID,
                                   workspace.conversations.contains(where: { $0.id == taskID }) {
                                    Button(MacPermissionsText.t("打开任务", "Open Task")) { dismiss(); openTask(taskID) }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 690, height: 560)
        .task { await center.reload() }
        .onDisappear { manualLaunchRequest = nil }
        .task(id: center.recent) {
            if let originTaskID { linkedIDs = await center.linkedSchedules(for: originTaskID) }
        }
        .sheet(item: $edit) { edit in
            MacTaskScheduleEditor(center: center, workspace: workspace, editing: edit.record,
                                  projectID: projectID, originTaskID: originTaskID)
        }
        .alert(MacPermissionsText.t("删除这个定时任务？", "Delete This Schedule?"),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { record in
            Button(MacPermissionsText.t("删除", "Delete"), role: .destructive) { Task { await center.delete(record) } }
            Button("host.chat.cancel", role: .cancel) {}
        }
    }

    private func planRow(_ record: TaskScheduleRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).lineLimit(1)
                if record.isEnabled, let next = record.nextExpectedAt {
                    Text(next, format: .dateTime.day().month().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("mac.schedule.nextRun")
                } else if record.isEnabled, record.cadence == .afterSuccess {
                    Text(upstreamStatus(record)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(MacPermissionsText.t("已暂停或结束", "Paused or Ended")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(MacPermissionsText.t("立即运行", "Run Now")) {
                let request = UUID()
                manualLaunchRequest = request
                Task {
                    await center.runNow(record) { conversationID in
                        guard manualLaunchRequest == request else { return }
                        manualLaunchRequest = nil
                        dismiss()
                        openTask(conversationID)
                    }
                }
            }
            .accessibilityIdentifier("mac.schedule.runNow." + record.id.uuidString)
            .disabled(center.isBusy || center.running.contains(record.id) || center.launching.contains(record.id))
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader { Self.smokeRunNowFrames[record.id] = $0 })
            #endif
            Menu {
                Button(MacPermissionsText.t("编辑", "Edit")) { edit = Edit(record: record) }
                    .disabled(center.running.contains(record.id))
                if record.isEnabled {
                    Button(MacPermissionsText.t("暂停", "Pause")) { Task { await center.setEnabled(record, enabled: false) } }
                } else if record.cadence != .once || record.scheduledAt > Date() {
                    Button(MacPermissionsText.t("恢复", "Resume")) { Task { await center.setEnabled(record, enabled: true) } }
                }
                if record.cadence != .afterSuccess {
                    Button(MacPermissionsText.t("跳过下一次", "Skip Next"), systemImage: "forward.end") {
                        Task { await skipNext(record) }
                    }
                    .disabled(!record.isEnabled)
                }
                Button(MacPermissionsText.t("删除", "Delete"), role: .destructive) { deleting = record }
                    .disabled(center.running.contains(record.id))
            } label: { Image(systemName: "ellipsis.circle") }
            .menuIndicator(.hidden)
            .accessibilityLabel(MacPermissionsText.t("定时任务操作", "Schedule Actions"))
            .disabled(center.isBusy || center.launching.contains(record.id))
        }
        .accessibilityIdentifier("mac.schedule.plan")
    }

    private func skipNext(_ record: TaskScheduleRecord) async {
        guard let result = await center.skipNext(record) else { return }
        if let next = result.nextExpectedAt {
            skipNotice = MacPermissionsText.t(
                "已跳过这一次，下次 \(next.formatted(date: .abbreviated, time: .shortened))。",
                "Skipped this occurrence. Next \(next.formatted(date: .abbreviated, time: .shortened)).")
        } else if result.planDisabled {
            skipNotice = MacPermissionsText.t("已跳过这一次，计划已完成并停用。",
                                              "Skipped this occurrence. The plan is now finished.")
        } else {
            skipNotice = MacPermissionsText.t("已跳过这一次，计划继续。",
                                              "Skipped this occurrence; the plan continues.")
        }
    }

    private func upstreamStatus(_ record: TaskScheduleRecord) -> String {
        if let run = center.recent.first(where: { $0.scheduleID == record.id && $0.isUpstreamArmed }) {
            return status(run.state)
        }
        return MacPermissionsText.t("所选运行成功后执行", "Runs after the selected run succeeds")
    }

    private func status(_ value: TaskScheduleOccurrenceState, skippedByUser: Bool = false) -> String {
        switch value {
        case .pending, .claimed: MacPermissionsText.t("等待启动", "Waiting to Start")
        case .running: MacPermissionsText.t("运行中", "Running")
        case .completed: MacPermissionsText.t("已完成", "Completed")
        case .failed: MacPermissionsText.t("失败", "Failed")
        case .cancelled: MacPermissionsText.t("已停止", "Stopped")
        case .skipped: skippedByUser ? MacPermissionsText.t("已跳过", "Skipped") : MacPermissionsText.t("已错过", "Missed")
        case .interrupted: MacPermissionsText.t("待核对", "Needs Review")
        }
    }
}

private struct MacTaskScheduleEditor: View {
    @ObservedObject var center: MacTaskScheduleCenter
    @ObservedObject var workspace: HostAgentWorkspace
    let editing: TaskScheduleRecord?
    let originTaskID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var workspaceID: UUID?
    @State private var modelID: UUID?
    @State private var cadence: TaskScheduleCadence = .once
    @State private var scheduledAt = Date().addingTimeInterval(300)
    @State private var hours = 6
    @State private var upstreamRunID: UUID?
    @State private var recentRuns: [RecentRunSummary] = []
    @State private var approval: TaskApprovalMode = .ask
    @State private var saving = false
    @State private var saveFailed = false

    init(center: MacTaskScheduleCenter, workspace: HostAgentWorkspace, editing: TaskScheduleRecord?,
         projectID: UUID?, originTaskID: UUID?) {
        self.center = center
        self.workspace = workspace
        self.editing = editing
        self.originTaskID = originTaskID
        _workspaceID = State(initialValue: editing == nil ? projectID : editing?.workspaceID)
        _upstreamRunID = State(initialValue: editing?.upstreamRunID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? MacPermissionsText.t("新建定时任务", "New Schedule") :
                     MacPermissionsText.t("编辑定时任务", "Edit Schedule")).font(.headline)
                Spacer()
                Button("host.chat.cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Button("host.chat.save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || center.isBusy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (cadence == .afterSuccess && upstreamRunID == nil))
                    .accessibilityIdentifier("mac.schedule.save")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: FloeTheme.minimumTarget + 4)
            Divider()
            Form {
                FloeTaskScheduleTextFields(title: $title, prompt: $prompt)
                Section(MacPermissionsText.t("目录与时间", "Folder and Time")) {
                    Picker(MacPermissionsText.t("工作区", "Workspace"), selection: $workspaceID) {
                        Text(MacPermissionsText.t("会话默认目录", "Conversation Folder")).tag(UUID?.none)
                        ForEach(workspace.workspaces.filter { $0.kind == .project }) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    FloeTaskScheduleTimingFields(cadence: $cadence, scheduledAt: $scheduledAt,
                                                 intervalHours: $hours, allowsAfterSuccess: true)
                    if cadence == .afterSuccess {
                        Picker(MacPermissionsText.t("跟随运行", "Upstream Run"), selection: $upstreamRunID) {
                            Text(MacPermissionsText.t("选择一次运行", "Select a Run")).tag(UUID?.none)
                            ForEach(recentRuns) { run in
                                let title = run.conversationTitle.isEmpty ? MacPermissionsText.t("任务", "Task") : run.conversationTitle
                                Text("\(title) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .tag(Optional(run.id))
                            }
                            if let upstreamRunID, !recentRuns.contains(where: { $0.id == upstreamRunID }) {
                                Text(MacPermissionsText.t("已绑定的运行", "Previously Selected Run")).tag(Optional(upstreamRunID))
                            }
                        }
                        Text(MacPermissionsText.t("所选运行成功后触发一次。", "Runs once after the selected run succeeds."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker(MacPermissionsText.t("模型", "Model"), selection: $modelID) {
                        Text(MacPermissionsText.t("使用默认模型", "Use Default Model")).tag(UUID?.none)
                        ForEach(workspace.taskModelChoices.filter { $0.profile.isEnabled && $0.model.isEnabled && $0.model.capabilities.contains(.tools) }, id: \.model.id) { provider in
                            Text(provider.model.displayName).tag(Optional(provider.model.id))
                        }
                    }
                    Picker(MacPermissionsText.t("审批模式", "Approval Mode"), selection: $approval) {
                        ForEach(TaskApprovalMode.allCases, id: \.self) { mode in
                            Text(FloeTaskApprovalSection.title(mode)).tag(mode)
                        }
                    }
                }
                if saveFailed { Text(MacPermissionsText.t("无法保存定时任务。请检查时间或重试。", "Could not save. Check the schedule time or try again.")).foregroundStyle(.red) }
            }.formStyle(.grouped)
        }
        .frame(width: 550, height: 610)
        .task {
            recentRuns = await workspace.recentScheduleRuns()
            if upstreamRunID == nil, let originTaskID {
                upstreamRunID = recentRuns.first(where: { $0.conversationID == originTaskID })?.id
            }
        }
        .onAppear {
            guard let editing else { return }
            title = editing.title
            prompt = editing.prompt
            cadence = editing.cadence
            scheduledAt = editing.scheduledAt
            hours = max(1, min(168, (editing.intervalSeconds ?? 21600) / 3600))
            modelID = editing.modelID
            approval = editing.permissionJSON.flatMap { try? JSONDecoder().decode(DraftTaskPolicy.self, from: Data($0.utf8)) }?.approvalMode ?? .ask
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        if approval == .fullAccess, !(await workspace.authenticateScheduledFullAccess()) { return }
        let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cadence != .afterSuccess || upstreamRunID != nil else { saveFailed = true; return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        var record = editing ?? TaskScheduleRecord(title: "", prompt: cleaned, cadence: cadence, scheduledAt: scheduledAt)
        let calendarChanged = editing == nil || cadence != record.cadence || scheduledAt != record.scheduledAt ||
            (cadence == .interval && record.intervalSeconds != hours * 3600)
        if calendarChanged && cadence == .once && scheduledAt <= now { saveFailed = true; return }
        record.title = String((cleanTitle.isEmpty ? String(cleaned.prefix(40)) : cleanTitle).prefix(150))
        record.prompt = cleaned
        record.workspaceID = workspaceID
        record.modelID = modelID
        record.cadence = cadence
        record.scheduledAt = scheduledAt
        record.weekday = cadence == .weekly ? Calendar.current.component(.weekday, from: scheduledAt) : nil
        record.intervalSeconds = cadence == .interval ? hours * 3600 : nil
        record.upstreamRunID = cadence == .afterSuccess ? upstreamRunID : nil
        if editing == nil { record.originConversationID = originTaskID }
        record.anchorTimezone = editing?.anchorTimezone ?? TimeZone.current.identifier
        record.updatedAt = now
        let policy = DraftTaskPolicy(approvalMode: approval)
        guard let encoded = try? JSONEncoder().encode(policy) else { saveFailed = true; return }
        record.permissionJSON = String(decoding: encoded, as: UTF8.self)
        if calendarChanged {
            record.nextExpectedAt = record.isEnabled ? TaskSchedulePlanner.nextFireTime(after: now, record: record) : nil
        }
        if await center.save(record) { dismiss() } else { saveFailed = true }
    }
}
