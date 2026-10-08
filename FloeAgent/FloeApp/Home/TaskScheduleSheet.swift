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
    @State private var errorMessage: String?
    @State private var isSaving = false
    let onSaved: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("background.task.name_fallback") {
                    TextField("notes.notes_root_view.name", text: $title)
                    TextEditor(text: $prompt).frame(minHeight: 120)
                }
                Section("home.task_schedule_sheet.project_and_time") {
                    Picker("settings.all_workspaces_files_view.workspace", selection: $workspaceID) {
                        Text("home.task_schedule_sheet.chat_private_workspace").tag(Optional<UUID>.none)
                        ForEach(environment.workspaceCenter.projectWorkspaces) { workspace in
                            Text(workspace.name).tag(Optional(workspace.id))
                        }
                    }
                    Picker("shortcuts.floe_shortcuts.duplicate", selection: $cadence) {
                        Text("home.task_schedule_sheet.once").tag(TaskScheduleCadence.once)
                        Text("home.task_schedule_sheet.daily").tag(TaskScheduleCadence.daily)
                        Text("home.task_schedule_sheet.weekly").tag(TaskScheduleCadence.weekly)
                    }
                    DatePicker(FloeL10n.l("home.task_schedule_sheet.estimated_execution"), selection: $scheduledAt)
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
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let schedule = TaskScheduleRecord(
                title: cleanTitle.isEmpty ? String(cleanPrompt.prefix(40)) : cleanTitle,
                prompt: cleanPrompt,
                workspaceID: workspaceID,
                cadence: cadence,
                scheduledAt: scheduledAt,
                weekday: cadence == .weekly ? Calendar.current.component(.weekday, from: scheduledAt) : nil
            )
            try await SQLiteTaskScheduleStore(database: environment.database).save(schedule)
            BackgroundPolicyRegistry.shared.scheduleRefresh(earliest: scheduledAt)
            await onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
