// FloeApp — one scheduled task's detail surface.
//
// SPDX-License-Identifier: MPL-2.0
//
// Opened from the in-chat pill or the task center. Shows the durable prompt,
// cadence/timezone, current status, bound model/environment/workspace, origin
// chat linkage and the REAL occurrence history (manual rows distinct, actual
// automatic ordinals). Actions live in one native menu — no row of oversized
// buttons — and use the shared store/coordinator: Run now is an extra manual
// occurrence, Skip next records a skipped occurrence and advances the plan,
// and Cancel future pauses the plan while keeping its record and history.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence

struct TaskScheduleDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    let scheduleID: UUID

    @State private var record: TaskScheduleRecord?
    @State private var occurrences: [TaskScheduleOccurrence] = []
    @State private var startedAutomaticCount = 0
    @State private var isLoading = true
    @State private var busyAction: String?
    @State private var notice: String?
    @State private var failure: String?
    @State private var showingEdit = false
    @State private var confirmingCancel = false

    var body: some View {
        NavigationStack {
            Group {
                if let record {
                    content(record)
                } else if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "home.home_overview_view.scheduled",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text(ScheduleCopy.noNextRun))
                }
            }
            .navigationTitle(record?.title ?? String(localized: "home.home_overview_view.scheduled"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "workspace.workspace_canvas_view.cancel")) {
                        dismiss()
                    }
                }
                if let record {
                    ToolbarItem(placement: .primaryAction) {
                        actionMenu(record)
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingEdit, onDismiss: { Task { await load() } }) {
            if let record {
                TaskScheduleSheet(editing: record) { await load() }
            }
        }
        .confirmationDialog(
            ScheduleCopy.cancelFuture,
            isPresented: $confirmingCancel,
            titleVisibility: .visible
        ) {
            Button(ScheduleCopy.cancelFuture, role: .destructive) {
                Task { await cancelFuture() }
            }
            Button(String(localized: "workspace.workspace_canvas_view.cancel"), role: .cancel) {}
        } message: {
            Text(ScheduleCopy.cancelFutureNote)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ record: TaskScheduleRecord) -> some View {
        List {
            Section {
                statusRows(record)
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("schedule.detail.notice")
                }
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(FloeTheme.destructive)
                        .accessibilityIdentifier("schedule.detail.error")
                }
            }
            Section(ScheduleCopy.prompt) {
                Text(record.prompt)
                    .font(FloeTheme.Typography.body)
                    .textSelection(.enabled)
            }
            Section(ScheduleCopy.timing) {
                LabeledContent(
                    ScheduleCopy.localized("schedule.cadence", zh: "重复", en: "Repeat"),
                    value: ScheduleCopy.cadence(record))
                    .accessibilityIdentifier("schedule.detail.cadence")
                LabeledContent(
                    ScheduleCopy.timezone,
                    value: record.anchorTimezone ?? TimeZone.current.identifier)
                LabeledContent(
                    String(localized: "home.task_schedule_sheet.estimated_execution"),
                    value: record.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                if let last = record.lastStartedAt {
                    LabeledContent(
                        String(localized: "home.home_overview_view.last_actual"),
                        value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section(ScheduleCopy.bindings) {
                if let origin = record.originConversationID {
                    Label(ScheduleCopy.linkedChat, systemImage: "bubble.left.and.bubble.right")
                        .accessibilityIdentifier("schedule.detail.originLinked")
                    Button {
                        dismiss()
                        router.openConversation(origin)
                    } label: {
                        Label(
                            String(localized: "chat.thread_detail_view.open"),
                            systemImage: "arrow.up.forward.app")
                    }
                } else {
                    Label(ScheduleCopy.notLinked, systemImage: "bubble.left")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("schedule.detail.originUnbound")
                }
                LabeledContent(
                    ScheduleCopy.localized("schedule.binding.model", zh: "模型", en: "Model"),
                    value: boundModelName(record))
                LabeledContent(
                    ScheduleCopy.localized("schedule.binding.workspace", zh: "工作区", en: "Workspace"),
                    value: boundWorkspaceName(record))
                LabeledContent(
                    ScheduleCopy.localized(
                        "schedule.binding.environment", zh: "执行环境", en: "Execution environment"),
                    value: record.environmentID == nil
                        ? ScheduleCopy.localized(
                            "schedule.binding.task_workspace", zh: "任务工作区", en: "Task workspace")
                        : ScheduleCopy.localized(
                            "schedule.binding.frozen_environment",
                            zh: "已绑定执行环境", en: "Bound execution environment"))
            }
            Section(ScheduleCopy.history) {
                if occurrences.isEmpty {
                    Text(ScheduleCopy.localized(
                        "schedule.history.empty", zh: "暂无执行历史", en: "No runs yet"))
                        .foregroundStyle(.secondary)
                } else {
                    let ordinals = TaskSchedulePresentation.automaticOrdinals(
                        occurrences: occurrences,
                        totalStartedAutomatic: startedAutomaticCount)
                    ForEach(occurrences) { occurrence in
                        occurrenceRow(occurrence, ordinals: ordinals)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    @ViewBuilder
    private func statusRows(_ record: TaskScheduleRecord) -> some View {
        HStack(spacing: 8) {
            Text(record.isEnabled ? ScheduleCopy.active : ScheduleCopy.paused)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    (record.isEnabled ? FloeTheme.success : Color.secondary).opacity(0.16),
                    in: Capsule())
                .foregroundStyle(record.isEnabled ? FloeTheme.success : .secondary)
                .accessibilityIdentifier("schedule.detail.state")
            Spacer(minLength: 4)
            Text(record.cadence == .afterSuccess
                ? ScheduleCopy.completedRuns(startedAutomaticCount)
                : ScheduleCopy.ordinal(automaticOrdinal))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        if record.cadence == .afterSuccess {
            Text(ScheduleCopy.waitingUpstream)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if !record.isEnabled {
            Text(ScheduleCopy.noNextRun)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let next = record.nextExpectedAt {
            HStack(spacing: 6) {
                Text(ScheduleCopy.nextRun(next))
                if next > Date() {
                    Text(timerInterval: Date()...next, countsDown: true)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .accessibilityIdentifier("schedule.detail.nextRun")
        } else {
            Text(ScheduleCopy.noNextRun)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func occurrenceRow(
        _ occurrence: TaskScheduleOccurrence,
        ordinals: [UUID: Int]
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(TaskSchedulePresentation.occurrenceLabel(
                    occurrence, automaticOrdinal: ordinals[occurrence.id]))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                Text(ScheduleCopy.occurrenceState(occurrence.state))
                    .font(.caption)
                    .foregroundStyle(occurrence.state == .failed
                        ? FloeTheme.destructive : Color.secondary)
            }
            Text(occurrence.scheduledFor.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let summary = occurrence.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let error = occurrence.errorText, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(FloeTheme.destructive)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let conversationID = occurrence.conversationID else { return }
            dismiss()
            router.openConversation(conversationID, runID: occurrence.runID)
        }
        .accessibilityIdentifier("schedule.detail.occurrence.\(occurrence.id.uuidString)")
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionMenu(_ record: TaskScheduleRecord) -> some View {
        Menu {
            Button {
                Task { await runNow() }
            } label: {
                Label(ScheduleCopy.runNow, systemImage: "play.circle")
            }
            .disabled(!record.isEnabled || busyAction != nil)
            if record.cadence != .afterSuccess {
                Button {
                    Task { await skipNext() }
                } label: {
                    Label(ScheduleCopy.skipNext, systemImage: "forward.end")
                }
                .disabled(!record.isEnabled || busyAction != nil)
            }
            Button(role: .destructive) {
                confirmingCancel = true
            } label: {
                Label(ScheduleCopy.cancelFuture, systemImage: "pause.circle")
            }
            .disabled(!record.isEnabled || busyAction != nil)
            Divider()
            Button {
                showingEdit = true
            } label: {
                Label(ScheduleCopy.edit, systemImage: "pencil")
            }
            .disabled(busyAction != nil)
        } label: {
            if busyAction != nil {
                ProgressView().controlSize(.small)
            } else {
                Label("workspace.workspace_canvas_view.more", systemImage: "ellipsis.circle")
            }
        }
        .accessibilityIdentifier("schedule.detail.menu")
    }

    private func runNow() async {
        guard busyAction == nil else { return } // double-tap fence; durable claim also fences
        busyAction = "runNow"
        defer { busyAction = nil }
        do {
            let receipt = try await TaskScheduleCommands.runNow(
                scheduleID: scheduleID, environment: environment)
            dismiss()
            router.openConversation(receipt.conversationID, runID: receipt.runID)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func skipNext() async {
        guard busyAction == nil else { return }
        busyAction = "skipNext"
        defer { busyAction = nil }
        do {
            let result = try await TaskScheduleCommands.skipNext(
                scheduleID: scheduleID, environment: environment)
            if let result {
                notice = ScheduleCopy.localized(
                    "schedule.skip.done",
                    zh: "已跳过这一次，计划继续。",
                    en: "Skipped this occurrence; the plan continues.")
                if let next = result.nextExpectedAt {
                    notice = ScheduleCopy.localized(
                        "schedule.skip.done_next",
                        zh: "已跳过这一次，下次 \(next.formatted(date: .abbreviated, time: .shortened))。",
                        en: "Skipped this occurrence. Next \(next.formatted(date: .abbreviated, time: .shortened))."
                    )
                } else if result.planDisabled {
                    notice = ScheduleCopy.localized(
                        "schedule.skip.retired",
                        zh: "已跳过这一次。这是一次性计划，现已停用。",
                        en: "Skipped this occurrence. This one-time plan is now paused.")
                }
            }
            await load()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func cancelFuture() async {
        guard busyAction == nil else { return }
        busyAction = "cancelFuture"
        defer { busyAction = nil }
        do {
            try await TaskScheduleCommands.cancelFuture(
                scheduleID: scheduleID, environment: environment)
            notice = ScheduleCopy.localized(
                "schedule.cancel_future.done",
                zh: "已停止后续运行，记录与历史已保留。",
                en: "Future runs stopped. The record and history are kept.")
            await load()
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Load / binding labels

    private var automaticOrdinal: Int { startedAutomaticCount + 1 }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let store = SQLiteTaskScheduleStore(database: environment.database)
        do {
            record = try await store.schedule(id: scheduleID)
            occurrences = try await store.occurrences(scheduleID: scheduleID, limit: 50)
            startedAutomaticCount = try await store.startedAutomaticOccurrenceCount(
                scheduleID: scheduleID)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func boundModelName(_ record: TaskScheduleRecord) -> String {
        guard let modelID = record.modelID else {
            return String(localized: "model.default")
        }
        if let resolved = environment.conversationCenter.providerAndModel(modelID: modelID) {
            return resolved.1.displayName
        }
        return ScheduleCopy.localized(
            "schedule.binding.model_unavailable",
            zh: "已绑定模型不可用",
            en: "Bound model unavailable")
    }

    private func boundWorkspaceName(_ record: TaskScheduleRecord) -> String {
        guard let workspaceID = record.workspaceID else {
            return String(localized: "home.task_schedule_sheet.chat_private_workspace")
        }
        return environment.workspaceCenter.projectWorkspaces
            .first(where: { $0.id == workspaceID })?.name
            ?? ScheduleCopy.localized(
                "schedule.binding.workspace_unavailable",
                zh: "工作区不可用",
                en: "Workspace unavailable")
    }
}
#endif
