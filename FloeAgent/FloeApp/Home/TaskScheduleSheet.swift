#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloePersistence

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
                Section("任务") {
                    TextField("名称", text: $title)
                    TextEditor(text: $prompt).frame(minHeight: 120)
                }
                Section("项目与时间") {
                    Picker("工作区", selection: $workspaceID) {
                        Text("聊天（私有工作区）").tag(Optional<UUID>.none)
                        ForEach(environment.workspaceCenter.projectWorkspaces) { workspace in
                            Text(workspace.name).tag(Optional(workspace.id))
                        }
                    }
                    Picker("重复", selection: $cadence) {
                        Text("一次").tag(TaskScheduleCadence.once)
                        Text("每天").tag(TaskScheduleCadence.daily)
                        Text("每周").tag(TaskScheduleCadence.weekly)
                    }
                    DatePicker("预计执行", selection: $scheduledAt)
                }
                Section {
                    Text("iOS 会按系统资源尽力唤醒；预计时间不是分钟级保证，任务中心会同时显示最近实际执行时间。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("安排任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
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
