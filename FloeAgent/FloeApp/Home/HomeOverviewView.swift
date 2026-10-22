// FloeApp — Home overview column (iPad second column).
//
// SPDX-License-Identifier: MPL-2.0
//
// The workbench overview shows at most three quiet
// sections — active tasks, pending approvals, recent threads — and stays
// empty-clean when there is nothing to show. Rows open the owning thread
// in Home's detail column via the router.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import AppIntents
import FloeCore
import FloeModels
import FloePersistence

/// The iPad Home content column: task overview for the launchpad.
struct HomeOverviewView: View {
    @ObservedObject private var center: ConversationCenter
    @StateObject private var viewModel: HomeLaunchpadViewModel
    @EnvironmentObject private var router: AppRouter
    @State private var searchText = ""
    @State private var schedules: [TaskScheduleRecord] = []
    @State private var showingSchedule = false
    @State private var editingSchedule: TaskScheduleRecord?
    @State private var automationSetupSchedule: TaskScheduleRecord?
    @State private var historySchedule: TaskScheduleRecord?
    @State private var historyOccurrences: [TaskScheduleOccurrence] = []
    @State private var cleanupReminders: [TaskScheduleCleanupReminder] = []
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingOccurrenceScheduleIDs: Set<UUID> = []
    @State private var batchStartingConversation: ConversationRecord?
    @State private var archivedTasks: [ConversationRecord] = []
    @State private var presentsTaskManagement = false
    @State private var managementFilter: ConversationBatchManagementView.Filter = .active
    @State private var restoreFailure: String?

    init(center: ConversationCenter) {
        self.center = center
        _viewModel = StateObject(wrappedValue: HomeLaunchpadViewModel(center: center))
    }

    var body: some View {
        List {
            if !runningTasks.isEmpty {
                Section("home.home_overview_view.running") {
                    ForEach(runningTasks) { conversation in
                        overviewRow(conversation, showsState: true)
                    }
                }
            }
            if !viewModel.pendingApprovals.isEmpty {
                Section("home.pending_approvals") {
                    ForEach(viewModel.pendingApprovals) { approval in
                        Button {
                            router.openThreadFromHome(approval.conversationID, runID: approval.runID)
                        } label: {
                            Label(approval.toolCall.toolName,
                                  systemImage: "exclamationmark.shield")
                                .foregroundStyle(FloeTheme.pending)
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                        .accessibilityLabel(
                            String(localized: "approval.required")
                                + " " + approval.toolCall.toolName
                        )
                    }
                }
            }
            if !failedTasks.isEmpty {
                Section("home.home_overview_view.failed_or_interrupted") {
                    ForEach(failedTasks) { conversation in
                        overviewRow(conversation, showsState: true)
                    }
                }
            }
            if !completedTasks.isEmpty {
                Section("home.home_overview_view.completed") {
                    ForEach(completedTasks) { conversation in
                        overviewRow(conversation, showsState: true)
                    }
                }
            }
            // Retired-schedule cleanup reminders: full list, every row
            // actionable (no hidden preview cap). They record that the USER
            // should remove the matching system automation; Floe cannot
            // detect or delete it. Rows exist only for plans whose actual
            // Shortcut handoff/confirmation was monitored (or that a stale
            // automation still fires for), survive deletion and relaunch,
            // and dedupe per schedule at the store level.
            if !cleanupReminders.isEmpty {
                Section(scheduleText(zh: "待清理的系统自动化", en: "Automation cleanup")) {
                    ForEach(cleanupReminders) { reminder in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(cleanupReasonCopy(reminder))
                                .font(.subheadline)
                            HStack(spacing: 12) {
                                ShortcutsLink { }
                                Button(TaskScheduleCleanupCopy.removed()) {
                                    Task { await resolveCleanup(reminder.id, removed: true) }
                                }
                                Button(TaskScheduleCleanupCopy.dismiss()) {
                                    Task { await resolveCleanup(reminder.id, removed: false) }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget,
                               alignment: .leading)
                        .accessibilityElement(children: .contain)
                    }
                }
            }
            if !schedules.isEmpty {
                Section("home.home_overview_view.scheduled") {
                    ForEach(schedules) { schedule in
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(schedule.title, systemImage: "calendar.badge.clock")
                                    .foregroundStyle(schedule.isEnabled ? .primary : .secondary)
                                if !schedule.isEnabled {
                                    Text(scheduleText(zh: "已停用", en: "Disabled"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let expected = schedule.nextExpectedAt {
                                    Text(FloeL10n.l("home.home_overview_view.estimated", expected.formatted(date: .abbreviated, time: .shortened)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let actual = schedule.lastStartedAt {
                                    Text(FloeL10n.l("home.home_overview_view.last_actual", actual.formatted(date: .abbreviated, time: .shortened)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if pendingOccurrenceScheduleIDs.contains(schedule.id) {
                                    Text(scheduleText(zh: "待执行（等待应用运行）", en: "Pending (waiting for the app to run)"))
                                        .font(.caption).foregroundStyle(FloeTheme.pending)
                                }
                            }
                            Spacer(minLength: 4)
                            if schedule.cadence == .once || schedule.cadence == .daily || schedule.cadence == .weekly {
                                Button {
                                    automationSetupSchedule = schedule
                                } label: {
                                    Label(scheduleText(zh: "系统定时", en: "Automation"), systemImage: "clock.badge.checkmark")
                                        .font(.subheadline)
                                        .frame(minHeight: FloeTheme.minimumTarget)
                                }
                                .buttonStyle(.borderless)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .contextMenu {
                            Button {
                                Task {
                                    let store = SQLiteTaskScheduleStore(database: viewModel.environment.database)
                                    _ = try? await store.runNow(id: schedule.id, at: Date())
                                    await viewModel.environment.backgroundRunCoordinator.runDueSchedulesNow()
                                    await load()
                                }
                            } label: { Label(scheduleText(zh: "立即运行", en: "Run now"), systemImage: "play.circle") }
                            Button {
                                Task {
                                    let store = SQLiteTaskScheduleStore(database: viewModel.environment.database)
                                    try? await store.setEnabled(id: schedule.id, enabled: !schedule.isEnabled, at: Date())
                                    // The shared pass reconciles the insurance-reminder set: a
                                    // disabled schedule must not keep a pre-registered reminder.
                                    await viewModel.environment.backgroundRunCoordinator.runDueSchedulesNow()
                                    await load()
                                }
                            } label: {
                                Label(
                                    schedule.isEnabled
                                        ? scheduleText(zh: "停用", en: "Disable")
                                        : scheduleText(zh: "启用", en: "Enable"),
                                    systemImage: schedule.isEnabled ? "pause.circle" : "play.circle")
                            }
                            if schedule.cadence == .once || schedule.cadence == .daily || schedule.cadence == .weekly {
                                Button {
                                    automationSetupSchedule = schedule
                                } label: { Label(scheduleText(zh: "系统定时", en: "Automation"), systemImage: "clock.badge.checkmark") }
                            }
                            Button {
                                editingSchedule = schedule
                            } label: { Label("workspace.workspace_canvas_view.edit", systemImage: "pencil") }
                            Button {
                                Task {
                                    historyOccurrences = (try? await SQLiteTaskScheduleStore(
                                        database: viewModel.environment.database
                                    ).occurrences(scheduleID: schedule.id, limit: 50)) ?? []
                                    historySchedule = schedule
                                }
                            } label: { Label(scheduleText(zh: "历史", en: "History"), systemImage: "clock.arrow.circlepath") }
                            Button(role: .destructive) {
                                Task {
                                    try? await SQLiteTaskScheduleStore(database: viewModel.environment.database)
                                        .delete(id: schedule.id)
                                    // Drop the deleted schedule's insurance reminder through
                                    // the same shared reconciliation pass.
                                    await viewModel.environment.backgroundRunCoordinator.runDueSchedulesNow()
                                    await load()
                                }
                            } label: { Label("home.home_overview_view.delete_schedule", systemImage: "trash") }
                        }
                    }
                }
            }
            if !archivedTasks.isEmpty {
                Section("settings.all_workspaces_files_view.archived") {
                    ForEach(archivedTasks) { conversation in
                        HStack {
                            Text(conversation.title.isEmpty ? String(localized: "chat.untitled") : conversation.title)
                                .lineLimit(1)
                            Spacer()
                            Button("canvas.drawingHistory.restore") {
                                Task { await restoreArchived(conversation) }
                            }
                            .buttonStyle(.borderless)
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                    }
                    // One canonical management surface for the archive too:
                    // selection, restore and delete happen in the same screen
                    // the Task Center and Settings open.
                    Button {
                        openTaskManagement(.archived)
                    } label: {
                        Label(
                            TaskManagementCopy.archivedRow(archivedTasks.count),
                            systemImage: "archivebox"
                        )
                    }
                    .accessibilityIdentifier("taskCenter.manageArchived")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if overviewIsEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("tab.workbench", systemImage: "rectangle.grid.2x2")
                } description: {
                    Text("home.overview.empty")
                }
            }
        }
        .navigationTitle("tab.workbench")
        .searchable(text: $searchText, prompt: "home.home_overview_view.search_tasks")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    openTaskManagement(.active)
                } label: {
                    Label(FloeL10n.l("settings.data_management_view.manage"), systemImage: "checklist")
                }
                .disabled(viewModel.isLoading)
                .accessibilityIdentifier("taskCenter.manage")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSchedule = true
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("home.home_overview_view.schedule_task")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.startNewTask()
                } label: {
                    Image(systemName: "plus")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("workbench.new_task")
                .accessibilityIdentifier("workbench.overview.new_task")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: scenePhase) { _, phase in
            // Foreground re-entry refreshes THIS inline list too (stale
            // fires, terminals and lost auxiliary writes received while
            // inactive must not sit invisibly until a manual pull-to-
            // refresh). The popup itself is the root-attached single
            // source (`floeScheduleCleanupPopup`), so no alert lives
            // here anymore — exactly one popup source app-wide.
            if phase == .active {
                Task { await load() }
            }
        }
        .sheet(item: $batchStartingConversation) { conversation in
            ConversationBatchManagementView(center: center, initialConversation: conversation)
        }
        // The canonical management surface, shared with Settings > Data
        // Management: selection, archive/restore and delete all run here
        // through the existing lifecycle commands.
        .sheet(isPresented: $presentsTaskManagement) {
            ConversationBatchManagementView(center: center, initialFilter: managementFilter)
                .id(managementFilter)
        }
        .sheet(isPresented: $showingSchedule) {
            TaskScheduleSheet {
                // A save must register its insurance reminder through the
                // shared pass instead of waiting for an unrelated due pass.
                await viewModel.environment.backgroundRunCoordinator.runDueSchedulesNow()
                await load()
            }
        }
        .sheet(item: $editingSchedule) { record in
            TaskScheduleSheet(editing: record) {
                await viewModel.environment.backgroundRunCoordinator.runDueSchedulesNow()
                await load()
            }
        }
        .sheet(item: $automationSetupSchedule) { record in
            TaskScheduleAutomationSetupView(
                schedule: record,
                cleanupStore: TaskScheduleCleanupReminderStore(
                    database: viewModel.environment.database))
        }
        .sheet(item: $historySchedule) { schedule in
            NavigationStack {
                List {
                    if historyOccurrences.isEmpty {
                        Text(scheduleText(zh: "暂无执行历史", en: "No run history yet"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(historyOccurrences) { occurrence in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(occurrence.scheduledFor.formatted(date: .abbreviated, time: .shortened))
                            Text(occurrenceStateLabel(occurrence.state))
                                .font(.caption)
                                .foregroundStyle(occurrence.state == .failed ? FloeTheme.destructive : .secondary)
                            if let error = occurrence.errorText {
                                Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
                .navigationTitle(schedule.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("workspace.workspace_canvas_view.cancel") { historySchedule = nil }
                    }
                }
            }
        }
        .alert("chat.conversation_list_view.action_failed", isPresented: Binding(
            get: { restoreFailure != nil },
            set: { if !$0 { restoreFailure = nil } }
        )) {
            Button("workspace.office_document_editor_view.ok", role: .cancel) { restoreFailure = nil }
        } message: {
            Text(restoreFailure ?? "")
        }
    }

    private func openTaskManagement(_ filter: ConversationBatchManagementView.Filter) {
        managementFilter = filter
        presentsTaskManagement = true
    }

    private func restoreArchived(_ conversation: ConversationRecord) async {
        do {
            try await center.restoreConversation(id: conversation.id)
            await load()
        } catch {
            restoreFailure = ConversationTaskBulkService.failureText(for: error)
        }
    }

    /// The empty-state overlay must never hide actionable rows: a pending
    /// cleanup reminder (often the ONLY leftover after the plan itself was
    /// deleted) keeps the overview non-empty so its inline row — and the
    /// popup surface built on the same list — stays reachable.
    private var overviewIsEmpty: Bool {
        runningTasks.isEmpty
            && viewModel.pendingApprovals.isEmpty
            && failedTasks.isEmpty
            && completedTasks.isEmpty
            && schedules.isEmpty
            && cleanupReminders.isEmpty
    }

    private var filteredConversations: [ConversationRecord] {
        guard !searchText.isEmpty else { return viewModel.recentConversations }
        return viewModel.recentConversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var runningTasks: [ConversationRecord] {
        filteredConversations.filter {
            guard let state = viewModel.latestRunStates[$0.id] else { return false }
            return !RunStateLocalizer.isTerminal(state) && state != "waitingApproval"
        }
    }

    private var failedTasks: [ConversationRecord] {
        filteredConversations.filter {
            guard let state = viewModel.latestRunStates[$0.id] else { return false }
            return ["failed", "interrupted", "checkpointed"].contains(state)
        }
    }

    private var completedTasks: [ConversationRecord] {
        filteredConversations.filter { viewModel.latestRunStates[$0.id] == "completed" }
    }

    /// Inline bilingual fallback for strings whose central catalog entry has
    /// not landed yet: a missing key must never render raw.
    private func scheduleText(zh: String, en: String) -> String {
        FloeL10n.isChinese ? zh : en
    }

    /// One short, actionable bilingual line per retired schedule — shared
    /// with the cleanup popup so the same event never reads differently
    /// in two places (see `TaskScheduleCleanupCopy`).
    private func cleanupReasonCopy(_ reminder: TaskScheduleCleanupReminder) -> String {
        TaskScheduleCleanupCopy.reason(reminder)
    }

    private func resolveCleanup(_ id: UUID, removed: Bool) async {
        let store = TaskScheduleCleanupReminderStore(database: viewModel.environment.database)
        // User-side marks only: neither branch touches schedules, occurrences
        // or the system. Neither claims Floe detected an automation removal.
        let didResolve: Bool
        do {
            if removed {
                try await store.markRemoved(id: id)
            } else {
                try await store.dismiss(id: id)
            }
            didResolve = true
        } catch {
            didResolve = false
        }
        if didResolve {
            // Successful durable write ONLY: release this row's
            // process-scoped popup marks so a FUTURE durable event for
            // the same row — notably the store-sanctioned case of a new
            // stale fire reopening a `removed` row at its same
            // monitoring epoch — presents fresh instead of inheriting
            // the answered-and-resolved round's suppression. This is a
            // presentation mark reset; it deletes nothing and claims no
            // system-automation removal.
            TaskScheduleCleanupPopupLedger.shared.releaseRowSuppressions(rowID: id)
        }
        cleanupReminders = (try? await store.openReminders()) ?? []
    }

    private func occurrenceStateLabel(_ state: TaskScheduleOccurrenceState) -> String {
        switch state {
        case .pending: scheduleText(zh: "待执行", en: "Pending")
        case .claimed, .running: String(localized: "home.home_overview_view.running")
        case .completed: scheduleText(zh: "已完成", en: "Completed")
        case .failed: scheduleText(zh: "失败", en: "Failed")
        case .cancelled: scheduleText(zh: "已取消", en: "Cancelled")
        case .skipped: scheduleText(zh: "已跳过（合并）", en: "Skipped (coalesced)")
        case .interrupted: scheduleText(zh: "已中断", en: "Interrupted")
        }
    }

    private func load() async {
        await viewModel.load()
        let store = SQLiteTaskScheduleStore(database: viewModel.environment.database)
        schedules = (try? await store.schedules()) ?? []
        let reminderStore = TaskScheduleCleanupReminderStore(
            database: viewModel.environment.database)
        // Load/foreground safety net: monitoring rows whose retirement write
        // was lost (crash, failed auxiliary write) open now; then read the
        // full open list. Neither step can touch schedule lifecycle.
        try? await reminderStore.reconcileMonitoring()
        cleanupReminders = (try? await reminderStore.openReminders()) ?? []
        let pending = (try? await store.pendingOccurrences(limit: 200)) ?? []
        pendingOccurrenceScheduleIDs = Set(pending.map(\.scheduleID))
        archivedTasks = ((try? await viewModel.environment.conversationStore
            .conversations(includeArchived: true)) ?? []).filter { $0.archivedAt != nil }
    }

    private func overviewRow(_ conversation: ConversationRecord, showsState: Bool) -> some View {
        Button {
            router.openThreadFromHome(conversation.id)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title.isEmpty
                         ? String(localized: "chat.untitled")
                         : conversation.title)
                        .font(FloeTheme.Typography.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(
                        conversation.updatedAt,
                        format: .dateTime.month(.abbreviated).day().hour().minute()
                    )
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if showsState, let state = viewModel.latestRunStates[conversation.id] {
                    Text(RunStateLocalizer.title(for: state))
                        .font(FloeTheme.Typography.metadata)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RunStateLocalizer.color(for: state).opacity(0.16),
                            in: Capsule()
                        )
                        .foregroundStyle(RunStateLocalizer.color(for: state))
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("home.home_overview_view.select_multiple", systemImage: "checkmark.circle") { batchStartingConversation = conversation }
                .accessibilityIdentifier("workbench.selectMultiple")
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel(conversation.title.isEmpty
            ? String(localized: "chat.untitled")
            : conversation.title)
    }
}
#endif
