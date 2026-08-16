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

    init(center: ConversationCenter) {
        self.center = center
        _viewModel = StateObject(wrappedValue: HomeLaunchpadViewModel(center: center))
    }

    var body: some View {
        List {
            if !runningTasks.isEmpty {
                Section("运行中") {
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
                Section("失败或中断") {
                    ForEach(failedTasks) { conversation in
                        overviewRow(conversation, showsState: true)
                    }
                }
            }
            if !completedTasks.isEmpty {
                Section("已完成") {
                    ForEach(completedTasks) { conversation in
                        overviewRow(conversation, showsState: true)
                    }
                }
            }
            if !schedules.isEmpty {
                Section("已安排") {
                    ForEach(schedules) { schedule in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(schedule.title, systemImage: "calendar.badge.clock")
                            if let expected = schedule.nextExpectedAt {
                                Text("预计 \(expected.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let actual = schedule.lastStartedAt {
                                Text("最近实际 \(actual.formatted(date: .abbreviated, time: .shortened))")
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
                            } label: { Label("删除安排", systemImage: "trash") }
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
        .searchable(text: $searchText, prompt: "搜索任务")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSchedule = true
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("安排任务")
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
        .sheet(isPresented: $showingSchedule) {
            TaskScheduleSheet { await load() }
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
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel(conversation.title.isEmpty
            ? String(localized: "chat.untitled")
            : conversation.title)
    }
}
#endif
