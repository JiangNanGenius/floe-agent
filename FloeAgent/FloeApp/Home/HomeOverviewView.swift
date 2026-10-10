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
    @State private var batchStartingConversation: ConversationRecord?
    @State private var archivedTasks: [ConversationRecord] = []
    @State private var selectedArchivedIDs: Set<UUID> = []
    @State private var confirmingArchiveDeletion = false

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
            if !schedules.isEmpty {
                Section("home.home_overview_view.scheduled") {
                    ForEach(schedules) { schedule in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(schedule.title, systemImage: "calendar.badge.clock")
                            if let expected = schedule.nextExpectedAt {
                                Text(FloeL10n.l("home.home_overview_view.estimated", expected.formatted(date: .abbreviated, time: .shortened)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let actual = schedule.lastStartedAt {
                                Text(FloeL10n.l("home.home_overview_view.last_actual", actual.formatted(date: .abbreviated, time: .shortened)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task {
                                    try? await SQLiteTaskScheduleStore(database: viewModel.environment.database)
                                        .delete(id: schedule.id)
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
                            Image(systemName: selectedArchivedIDs.contains(conversation.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(FloeTheme.primary)
                            Text(conversation.title.isEmpty ? String(localized: "chat.untitled") : conversation.title)
                                .lineLimit(1)
                            Spacer()
                            Button("canvas.drawingHistory.restore") {
                                Task {
                                    try? await center.restoreConversation(id: conversation.id)
                                    await load()
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedArchivedIDs.contains(conversation.id) {
                                selectedArchivedIDs.remove(conversation.id)
                            } else {
                                selectedArchivedIDs.insert(conversation.id)
                            }
                        }
                    }
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSchedule = true
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("home.home_overview_view.schedule_task")
            }
            if !selectedArchivedIDs.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("home.home_overview_view.restore_selection") {
                        Task {
                            for id in selectedArchivedIDs { try? await center.restoreConversation(id: id) }
                            selectedArchivedIDs.removeAll()
                            await load()
                        }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("home.home_overview_view.delete_selection", role: .destructive) { confirmingArchiveDeletion = true }
                }
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
        .sheet(item: $batchStartingConversation) { conversation in
            ConversationBatchManagementView(center: center, initialConversation: conversation)
        }
        .sheet(isPresented: $showingSchedule) {
            TaskScheduleSheet { await load() }
        }
        .alert("home.home_overview_view.permanently_delete_archived_tasks", isPresented: $confirmingArchiveDeletion) {
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) {}
            Button("workspace.workspace_canvas_view.delete", role: .destructive) {
                Task {
                    for id in selectedArchivedIDs { try? await center.deleteConversation(id: id) }
                    selectedArchivedIDs.removeAll()
                    await load()
                }
            }
        } message: {
            Text("home.home_overview_view.the_selected_tasks_and_their_private")
        }
    }

    private var overviewIsEmpty: Bool {
        runningTasks.isEmpty
            && viewModel.pendingApprovals.isEmpty
            && failedTasks.isEmpty
            && completedTasks.isEmpty
            && schedules.isEmpty
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

    private func load() async {
        await viewModel.load()
        schedules = (try? await SQLiteTaskScheduleStore(database: viewModel.environment.database)
            .schedules().filter(\.isEnabled)) ?? []
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
