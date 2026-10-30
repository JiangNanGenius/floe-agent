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
    /// The explicit foreground work session (Task Center control). The
    /// coordinator owns the instance; this view only reads its published
    /// record and sends the two user intents.
    @ObservedObject private var workSession: BackgroundWorkSessionController
    @EnvironmentObject private var authoring: SkillAuthoringCoordinator
    @EnvironmentObject private var router: AppRouter
    @State private var searchText = ""
    @State private var schedules: [TaskScheduleRecord] = []
    @State private var showingSchedule = false
    @State private var editingSchedule: TaskScheduleRecord?
    @State private var automationSetupSchedule: TaskScheduleRecord?
    @State private var detailSchedule: ScheduleDetailRequest?
    @State private var cleanupReminders: [TaskScheduleCleanupReminder] = []
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingOccurrenceScheduleIDs: Set<UUID> = []
    @State private var archivedTasks: [ConversationRecord] = []
    @State private var presentsTaskManagement = false
    @State private var managementFilter: ConversationBatchManagementView.Filter = .active
    @State private var restoreFailure: String?
    /// Long-press multi-select in this overview (no management sheet; bulk
    /// archive/delete run through the existing task bulk engine). The
    /// dedicated archived-management page keeps its own restore surface.
    @StateObject private var selection = InlineConversationSelectionModel()

    init(center: ConversationCenter) {
        self.center = center
        let launchpad = HomeLaunchpadViewModel(center: center)
        _viewModel = StateObject(wrappedValue: launchpad)
        _workSession = ObservedObject(
            wrappedValue: launchpad.environment.backgroundRunCoordinator.workSession)
    }

    var body: some View {
        List {
            // The work-session row is always present: the user must see the
            // honest state (idle/armed/running/waiting/interrupted) and the
            // real counts, and can start or stop from the foreground only.
            Section {
                workSessionRow
            }
            if !authoring.taskCenterRecords.isEmpty {
                Section { SkillAuthoringRows(coordinator: authoring, taskCenter: true) }
            }
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
                            Button {
                                detailSchedule = ScheduleDetailRequest(scheduleID: schedule.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(schedule.title, systemImage: "calendar.badge.clock")
                                        .foregroundStyle(schedule.isEnabled ? .primary : .secondary)
                                    if !schedule.isEnabled {
                                        Text(ScheduleCopy.paused)
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home.schedule.row.\(schedule.id.uuidString)")
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
                                    _ = try? await TaskScheduleCommands.runNow(
                                        scheduleID: schedule.id,
                                        environment: viewModel.environment)
                                    await load()
                                }
                            } label: { Label(ScheduleCopy.runNow, systemImage: "play.circle") }
                            .disabled(!schedule.isEnabled)
                            if schedule.isEnabled, schedule.cadence != .afterSuccess {
                                Button {
                                    Task {
                                        _ = try? await TaskScheduleCommands.skipNext(
                                            scheduleID: schedule.id,
                                            environment: viewModel.environment)
                                        await load()
                                    }
                                } label: { Label(ScheduleCopy.skipNext, systemImage: "forward.end") }
                            }
                            if schedule.isEnabled {
                                Button(role: .destructive) {
                                    Task {
                                        try? await TaskScheduleCommands.cancelFuture(
                                            scheduleID: schedule.id,
                                            environment: viewModel.environment)
                                        await load()
                                    }
                                } label: {
                                    Label(ScheduleCopy.cancelFuture, systemImage: "pause.circle")
                                }
                            } else {
                                Button {
                                    Task {
                                        let store = SQLiteTaskScheduleStore(
                                            database: viewModel.environment.database)
                                        try? await store.setEnabled(
                                            id: schedule.id, enabled: true, at: Date())
                                        await viewModel.environment.backgroundRunCoordinator
                                            .runDueSchedulesNow()
                                        await load()
                                    }
                                } label: {
                                    Label(scheduleText(zh: "启用", en: "Enable"),
                                          systemImage: "play.circle")
                                }
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
                                detailSchedule = ScheduleDetailRequest(scheduleID: schedule.id)
                            } label: { Label(ScheduleCopy.detail, systemImage: "info.circle") }
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
        .disabled(selection.busy)
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
                    // The Tasks entry now opens the SAME inline selection the
                    // long press uses — circles appear inside this list; no
                    // selection sheet is launched.
                    selection.begin(with: nil)
                } label: {
                    Label(FloeL10n.l("settings.data_management_view.manage"), systemImage: "checklist")
                }
                .disabled(viewModel.isLoading || selection.busy)
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
                .accessibilityIdentifier("home.schedule.add")
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
        .task { await authoring.reload(); await load() }
        .refreshable { await authoring.reload(); await load() }
        .onChange(of: authoring.records.filter(\.isPromoted).map(\.id)) { _, _ in
            Task { await load() }
        }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.isActive {
                InlineConversationSelectionBar(
                    model: selection,
                    center: center,
                    visibleIDs: { visibleTaskIDs },
                    selectedItems: { selectedTaskItems }
                )
            }
        }
        .inlineConversationSelectionChrome(
            model: selection,
            center: center,
            afterRun: {
                await load()
                selection.pruneInvisible(visibleTaskIDs)
            }
        )
        .onChange(of: visibleTaskIDList) { _, ids in
            // A search or a finished run moving rows between sections must
            // never leave an invisible pending selection behind.
            selection.pruneInvisible(Set(ids))
        }
        // The canonical management surface, shared with Settings > Data
        // Management: selection, archive/restore and delete all run here
        // through the existing lifecycle commands. Reached from the
        // archived section; the Tasks toolbar entry now starts the same
        // inline selection the long press uses.
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
        .sheet(item: $detailSchedule, onDismiss: {
            Task { await load() }
        }) { request in
            TaskScheduleDetailView(scheduleID: request.scheduleID)
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
            && authoring.taskCenterRecords.isEmpty
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

    private func load() async {
        await viewModel.load()
        // The work-session row shows durable facts; refresh them alongside
        // the rest of the overview (no separate polling loop).
        await workSession.refresh()
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

    // MARK: - Work session row (foreground start/stop; honest counts only)

    /// One compact row: honest state capsule, real counts line, explicit
    /// start/stop button. A saved/armed record is never presented as an
    /// accepted result, and no invented progress percent is ever rendered —
    /// every visible number comes from the durable stores via the
    /// controller's counts snapshot.
    private var workSessionRow: some View {
        let snapshot = workSession.snapshot
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sessionTitle(for: snapshot.state))
                    .font(FloeTheme.Typography.body.weight(.medium))
                let detail = sessionDetail(for: snapshot)
                if !detail.isEmpty {
                    Text(detail)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workbench.session.detail")
                }
            }
            Spacer(minLength: 8)
            Text(sessionStateLabel(for: snapshot.state))
                .font(FloeTheme.Typography.metadata)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(sessionStateColor(for: snapshot.state).opacity(0.16), in: Capsule())
                .foregroundStyle(sessionStateColor(for: snapshot.state))
                .accessibilityIdentifier("workbench.session.state")
            Button {
                Task {
                    switch snapshot.state {
                    case .idle, .armed, .interrupted:
                        await workSession.foregroundStart()
                    case .running, .waiting:
                        await workSession.foregroundStop()
                    }
                    await load()
                }
            } label: {
                Text(sessionActionLabel(for: snapshot.state))
                    .frame(minHeight: FloeTheme.minimumTarget)
            }
            .buttonStyle(.borderless)
            .disabled(selection.busy)
            .accessibilityIdentifier("workbench.session.control")
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityElement(children: .contain)
    }

    private func sessionTitle(for state: BackgroundWorkSessionState) -> String {
        switch state {
        case .interrupted:
            return scheduleText(zh: "后台工作", en: "Background work")
        case .idle:
            return scheduleText(zh: "后台工作", en: "Background work")
        case .armed, .running, .waiting:
            return scheduleText(zh: "后台工作", en: "Background work")
        }
    }

    private func sessionStateLabel(for state: BackgroundWorkSessionState) -> String {
        switch state {
        case .idle: return scheduleText(zh: "未开始", en: "Not started")
        case .armed: return scheduleText(zh: "待命", en: "Ready")
        case .running: return String(localized: "home.home_overview_view.running")
        case .waiting: return scheduleText(zh: "等待中", en: "Waiting")
        case .interrupted: return scheduleText(zh: "已中断", en: "Interrupted")
        }
    }

    private func sessionStateColor(for state: BackgroundWorkSessionState) -> Color {
        switch state {
        case .running: return FloeTheme.success
        case .waiting, .armed: return FloeTheme.pending
        case .interrupted: return FloeTheme.destructive
        case .idle: return .secondary
        }
    }

    private func sessionActionLabel(for state: BackgroundWorkSessionState) -> String {
        switch state {
        case .idle, .armed: return scheduleText(zh: "开始", en: "Start")
        case .interrupted: return scheduleText(zh: "重新开始", en: "Restart")
        case .running, .waiting: return scheduleText(zh: "停止", en: "Stop")
        }
    }

    /// The honest line: real durable counts and, while waiting, the named
    /// blocker. Nothing is inferred and nothing is padded.
    private func sessionDetail(for snapshot: BackgroundWorkSessionSnapshot) -> String {
        var parts: [String] = []
        let counts = snapshot.counts
        if counts.liveRuns > 0 {
            parts.append(FloeL10n.isChinese ? "运行 \(counts.liveRuns)" : "runs \(counts.liveRuns)")
        }
        if counts.runningJobs > 0 {
            parts.append(FloeL10n.isChinese ? "任务 \(counts.runningJobs)" : "jobs \(counts.runningJobs)")
        }
        if counts.queuedJobs > 0 {
            parts.append(FloeL10n.isChinese ? "排队 \(counts.queuedJobs)" : "queued \(counts.queuedJobs)")
        }
        if counts.claimedScheduleOccurrences > 0 {
            parts.append(FloeL10n.isChinese ? "排程 \(counts.claimedScheduleOccurrences)" : "schedules \(counts.claimedScheduleOccurrences)")
        }
        if counts.pendingApprovals > 0 {
            parts.append(FloeL10n.isChinese ? "待批准 \(counts.pendingApprovals)" : "approvals \(counts.pendingApprovals)")
        }
        if snapshot.state == .waiting, let reason = snapshot.waitReason {
            parts.append(waitReasonText(reason))
        }
        if snapshot.state == .interrupted {
            return scheduleText(
                zh: "点按重新开始以继续处理任务",
                en: "Restart to continue processing tasks."
            )
        }
        if snapshot.state == .armed {
            return ""
        }
        // A live session reports the REAL framework qualification: the
        // continued-processing request/acceptance state, not the saved
        // toggle. A stored choice is never shown as accepted.
        if snapshot.state.isActiveSurface {
            switch workSession.qualification {
            case .accepted:
                parts.append(scheduleText(zh: "可后台运行", en: "background ready"))
            case .requested:
                parts.append(scheduleText(zh: "等待系统", en: "waiting for system"))
            case .none:
                parts.append(scheduleText(zh: "仅前台运行", en: "foreground only"))
            }
        }
        if parts.isEmpty {
            switch snapshot.state {
            case .idle:
                return ""
            case .running:
                return scheduleText(zh: "正在处理当前队列", en: "Processing the current queues")
            case .waiting:
                return scheduleText(zh: "等待任务", en: "Waiting for work")
            default:
                return ""
            }
        }
        return parts.joined(separator: " · ")
    }

    private func waitReasonText(_ reason: BackgroundWorkSessionWaitReason) -> String {
        switch reason {
        case .approvals:
            return scheduleText(zh: "等待你批准", en: "waiting on your approval")
        case .environmentBusy:
            return scheduleText(zh: "等待环境空闲", en: "waiting for the busy environment")
        case .network:
            return scheduleText(zh: "等待网络", en: "waiting for network")
        case .dueWork:
            return scheduleText(zh: "等待到期任务", en: "waiting for due work")
        }
    }

    private func overviewRow(_ conversation: ConversationRecord, showsState: Bool) -> some View {
        Button {
            if selection.isActive {
                selection.toggle(conversation.id)
            } else {
                router.openThreadFromHome(conversation.id)
            }
        } label: {
            HStack(spacing: 10) {
                if selection.isActive {
                    InlineSelectionCircle(
                        conversationID: conversation.id,
                        isSelected: selection.selectedIDs.contains(conversation.id)
                    )
                }
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
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel(conversation.title.isEmpty
            ? String(localized: "chat.untitled")
            : conversation.title)
        .accessibilityIdentifier("workbench.row.\(conversation.id.uuidString)")
        .inlineSelectionRowTraits(model: selection, conversationID: conversation.id)
        // Long press enters the inline selection in this list directly; it
        // never launches a management sheet and the release never navigates.
        .inlineSelectionLongPress(conversationID: conversation.id, model: selection)
    }

    /// The conversation rows the user can currently see as manageable
    /// tasks. Archived rows are a disjoint scope: their restore semantics
    /// stay on the inline restore button and the dedicated archived
    /// management page, exactly like the canonical filter split.
    private var visibleTaskIDs: Set<UUID> {
        Set(visibleTaskIDList)
    }

    private var visibleTaskIDList: [UUID] {
        var ids: [UUID] = []
        ids.append(contentsOf: runningTasks.map(\.id))
        ids.append(contentsOf: failedTasks.map(\.id))
        ids.append(contentsOf: completedTasks.map(\.id))
        return ids
    }

    /// Selected visible task rows with visible titles, frozen by the
    /// confirmation dialog.
    private var selectedTaskItems: [TaskBulkItem] {
        (runningTasks + failedTasks + completedTasks)
            .filter { selection.selectedIDs.contains($0.id) }
            .map { TaskBulkItem(id: $0.id, title: InlineSelectionCopy.untitled($0.title)) }
    }
}
#endif
