#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloePersistence

import FloeCore
struct TaskScheduleSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var workspaceID: UUID?
    @State private var cadence: TaskScheduleCadence = .once
    @State private var scheduledAt = Date().addingTimeInterval(300)
    @State private var intervalHours = 6
    /// The CONCRETE upstream run an after-success schedule follows.
    @State private var upstreamRunID: UUID?
    @State private var modelID: UUID?
    @State private var approvalMode: TaskApprovalMode = .ask
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var recentRuns: [RecentRunSummary] = []
    /// Nil creates; a record edits that schedule in place (same id, so its
    /// occurrence history is preserved).
    let editing: TaskScheduleRecord?
    let onSaved: () async -> Void

    init(editing: TaskScheduleRecord? = nil, onSaved: @escaping () async -> Void) {
        self.editing = editing
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("background.task.name_fallback") {
                    TextField("notes.notes_root_view.name", text: $title)
                        .accessibilityIdentifier("home.schedule.title")
                    TextEditor(text: $prompt)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("home.schedule.prompt")
                }
                Section("home.task_schedule_sheet.project_and_time") {
                    Picker("settings.all_workspaces_files_view.workspace", selection: $workspaceID) {
                        Text("home.task_schedule_sheet.chat_private_workspace").tag(Optional<UUID>.none)
                        ForEach(environment.workspaceCenter.projectWorkspaces) { workspace in
                            Text(workspace.name).tag(Optional(workspace.id))
                        }
                    }
                    Picker(
                        sheetText(zh: "重复", en: "Repeat"),
                        selection: $cadence
                    ) {
                        Text("home.task_schedule_sheet.once").tag(TaskScheduleCadence.once)
                        Text("home.task_schedule_sheet.daily").tag(TaskScheduleCadence.daily)
                        Text("home.task_schedule_sheet.weekly").tag(TaskScheduleCadence.weekly)
                        Text(sheetText(zh: "固定间隔", en: "Interval")).tag(TaskScheduleCadence.interval)
                        Text(sheetText(zh: "任务成功后", en: "After a task succeeds")).tag(TaskScheduleCadence.afterSuccess)
                    }
                    .accessibilityIdentifier("home.schedule.cadence")
                    if cadence == .interval {
                        Stepper(value: $intervalHours, in: 1...168) {
                            Text(sheetText(zh: "每 \(intervalHours) 小时", en: "Every \(intervalHours) hours"))
                        }
                    }
                    if cadence == .afterSuccess {
                        // Bound to the concrete RUN selected here (the
                        // "current selected run"), never to a schedule or a
                        // future round of a conversation.
                        Picker(sheetText(zh: "上游运行（当前选中的任务）", en: "Upstream run (current selected task)"),
                               selection: $upstreamRunID) {
                            Text("—").tag(Optional<UUID>.none)
                            ForEach(recentRuns) { run in
                                Text(runLabel(run)).tag(Optional(run.id))
                            }
                        }
                        Text(sheetText(
                            zh: "该计划只会在所选运行成功完成后触发一次。",
                            en: "This schedule fires once, after the selected run succeeds."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DatePicker(FloeL10n.l("home.task_schedule_sheet.estimated_execution"), selection: $scheduledAt)
                    }
                    Text(sheetText(zh: "时区锚点", en: "Time zone anchor")
                         + ": " + TimeZone.current.identifier)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("home.draft_task_permissions_sheet.approval_mode", selection: $approvalMode) {
                        Text("settings.agent_permissions_view.ask").tag(TaskApprovalMode.ask)
                        Text("settings.agent_permissions_view.auto_approve").tag(TaskApprovalMode.automatic)
                        Text("settings.agent_permissions_view.full_access").tag(TaskApprovalMode.fullAccess)
                    }
                    Picker("settings.agent_permissions_view.approval_model", selection: $modelID) {
                        // Nil keeps "resolve the current default at
                        // execution"; a concrete model is frozen here.
                        Text("model.default").tag(Optional<UUID>.none)
                        ForEach(environment.conversationCenter.modelsByProvider
                            .flatMap { $0.value }
                            .sorted { $0.displayName < $1.displayName }) { model in
                            Text(model.displayName).tag(Optional(model.id))
                        }
                    }
                }
                Section {
                    Text("home.task_schedule_sheet.ios_wakes_the_app_based_on")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("home.home_overview_view.schedule_task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("workspace.workspace_canvas_view.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("workspace.workspace_canvas_view.save") { Task { await save() } }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                        .accessibilityIdentifier("home.schedule.save")
                }
            }
            .task { await loadState() }
        }
    }

    private func sheetText(zh: String, en: String) -> String {
        FloeL10n.isChinese ? zh : en
    }

    private func runLabel(_ run: RecentRunSummary) -> String {
        let title = run.conversationTitle.isEmpty
            ? sheetText(zh: "未命名任务", en: "Untitled task")
            : run.conversationTitle
        let when = run.startedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(title) · \(when) · \(run.state)"
    }

    private func loadState() async {
        recentRuns = (try? await SQLiteRunStore(database: environment.database)
            .recentRunSummaries(limit: 20)) ?? []
        guard let editing else { return }
        title = editing.title
        prompt = editing.prompt
        workspaceID = editing.workspaceID
        cadence = editing.cadence
        scheduledAt = editing.scheduledAt
        intervalHours = max(1, (editing.intervalSeconds ?? 21_600) / 3_600)
        upstreamRunID = editing.upstreamRunID
        modelID = editing.modelID
        if let json = editing.permissionJSON,
           let policy = try? JSONDecoder().decode(DraftTaskPolicy.self, from: Data(json.utf8)) {
            approvalMode = policy.approvalMode
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let timezone = TimeZone.current.identifier
            // An after-success schedule without a selected upstream run could
            // never fire; the model-facing tool refuses the same state, so the
            // sheet must not silently persist an inert record either.
            if cadence == .afterSuccess, upstreamRunID == nil {
                errorMessage = sheetText(
                    zh: "请选择一个要跟随的上游任务运行后再保存。",
                    en: "Select the upstream task run this schedule follows before saving.")
                return
            }
            var record = editing ?? TaskScheduleRecord(
                title: cleanTitle.isEmpty ? String(cleanPrompt.prefix(40)) : cleanTitle,
                prompt: cleanPrompt,
                workspaceID: workspaceID,
                cadence: cadence,
                scheduledAt: scheduledAt,
                weekday: cadence == .weekly ? Calendar.current.component(.weekday, from: scheduledAt) : nil
            )
            record.title = cleanTitle.isEmpty ? String(cleanPrompt.prefix(40)) : cleanTitle
            record.prompt = cleanPrompt
            record.workspaceID = workspaceID
            record.cadence = cadence
            record.scheduledAt = scheduledAt
            record.weekday = cadence == .weekly
                ? Calendar.current.component(.weekday, from: scheduledAt)
                : nil
            record.anchorTimezone = timezone
            record.intervalSeconds = cadence == .interval ? intervalHours * 3_600 : nil
            record.upstreamRunID = cadence == .afterSuccess ? upstreamRunID : nil
            record.modelID = modelID
            record.permissionJSON = String(
                decoding: try JSONEncoder().encode(DraftTaskPolicy(approvalMode: approvalMode)),
                as: UTF8.self)
            if cadence == .afterSuccess {
                record.nextExpectedAt = nil
            } else {
                record.nextExpectedAt = TaskSchedulePlanner.nextFireTime(after: Date(), record: record)
                    ?? scheduledAt
            }
            record.updatedAt = Date()
            try await SQLiteTaskScheduleStore(database: environment.database).save(record)
            if record.isEnabled, let next = record.nextExpectedAt {
                BackgroundPolicyRegistry.shared.scheduleRefresh(earliest: next)
            }
            await onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
