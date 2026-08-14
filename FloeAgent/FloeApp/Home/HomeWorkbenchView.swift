// FloeApp — Home task workbench.
//
// SPDX-License-Identifier: MPL-2.0
//
// The Home tab: a task workbench, NOT a card grid. Compact new-task
// composer on top, then Active Tasks, Pending Approvals, Recent Sessions
// and Connection Status. Every section shows an honest empty/loading
// state; nothing invents live data.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloePersistence

/// The Home tab root: compact composer + task/approval/session/status.
struct HomeWorkbenchView: View {
    @StateObject private var viewModel: HomeWorkbenchViewModel
    @EnvironmentObject private var router: AppRouter

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: HomeWorkbenchViewModel(center: center))
    }

    var body: some View {
        VStack(spacing: 0) {
            NewTaskComposerView(
                draft: $viewModel.draft,
                modelName: viewModel.activeModelName,
                canSend: viewModel.canSend,
                providerConfigured: viewModel.hasConfiguredProvider,
                onSend: sendTask
            )
            Divider()
            workbenchList
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("tab.home")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    // MARK: - Sections

    private var workbenchList: some View {
        List {
            if !viewModel.hasConfiguredProvider {
                connectionStatusSection
            }
            activeTasksSection
            pendingApprovalsSection
            recentSessionsSection
        }
        .listStyle(.insetGrouped)
        .overlay {
            if viewModel.isLoading && viewModel.activeTasks.isEmpty {
                ProgressView()
            }
        }
    }

    /// Active (non-terminal) runs.
    private var activeTasksSection: some View {
        Section("home.active_tasks") {
            if viewModel.activeTasks.isEmpty {
                Text("home.no_active")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.activeTasks) { run in
                    Button {
                        openRun(run)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.goal.isEmpty ? String(localized: "chat.untitled") : run.goal)
                                    .font(FloeTheme.Typography.body)
                                    .lineLimit(1)
                                Text(run.startedAt, style: .relative)
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(state: run.state)
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Pending approvals across all live runs.
    private var pendingApprovalsSection: some View {
        Section("home.pending_approvals") {
            if viewModel.pendingApprovals.isEmpty {
                Text("home.no_pending")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.pendingApprovals) { approval in
                    ApprovalCardView(approval: approval) { decision in
                        Task { await viewModel.center.resolve(approval, decision: decision) }
                    }
                }
            }
        }
    }

    /// Recent SSH/VNC sessions with honest lifecycle state.
    private var recentSessionsSection: some View {
        Section("home.recent") {
            if viewModel.recentSessions.isEmpty {
                Text("home.no_sessions")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.recentSessions) { session in
                    HStack {
                        Image(systemName: session.kind == .vnc ? "display" : "terminal")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(session.kind == .vnc
                             ? String(localized: "session.vnc")
                             : String(localized: "session.ssh"))
                            .font(FloeTheme.Typography.body)
                        Spacer()
                        SessionStatePill(state: session.state)
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
            }
        }
    }

    /// Connection status, shown only when no provider is configured.
    private var connectionStatusSection: some View {
        Section("home.connection") {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(FloeTheme.pending)
                    .accessibilityHidden(true)
                Text("chat.add_provider.hint")
                    .font(FloeTheme.Typography.body)
                Spacer()
                Button("chat.add_provider") {
                    router.navigate(to: .more)
                    router.sidebarSelection = .more(.providers)
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: FloeTheme.minimumTarget)
            }
        }
    }

    // MARK: - Navigation

    private func sendTask() {
        Task {
            if let conversationID = await viewModel.sendNewTask() {
                router.navigate(to: .chat)
                router.selectedConversationID = conversationID
            }
        }
    }

    private func openRun(_ run: RunRecord) {
        router.navigate(to: .chat)
        router.selectedConversationID = run.conversationID
        router.selectedRunID = run.id
    }
}

/// A run state pill with honest color semantics.
private struct StatusPill: View {
    let state: String

    var body: some View {
        Text(displayText)
            .font(FloeTheme.Typography.metadata)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var displayText: String {
        switch state {
        case "completed": String(localized: "state.completed")
        case "failed": String(localized: "state.failed")
        case "waitingApproval": String(localized: "state.waiting_approval")
        case "streamingModel", "executingTool", "preparing": String(localized: "state.running")
        default: state
        }
    }

    private var color: Color {
        switch state {
        case "completed": FloeTheme.success
        case "failed": FloeTheme.destructive
        case "waitingApproval": FloeTheme.pending
        case "streamingModel", "executingTool", "preparing": FloeTheme.primary
        default: FloeTheme.unknown
        }
    }
}

/// A remote-session lifecycle pill (connected/suspended/unknown honest).
private struct SessionStatePill: View {
    let state: RemoteSessionRecord.State

    var body: some View {
        Text(displayText)
            .font(FloeTheme.Typography.metadata)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var displayText: String {
        switch state {
        case .connected: String(localized: "session.connected")
        case .connecting: String(localized: "session.connecting")
        case .suspended: String(localized: "session.suspended")
        case .disconnected: String(localized: "state.disconnected")
        case .unknown: String(localized: "state.unknown")
        }
    }

    private var color: Color {
        switch state {
        case .connected: FloeTheme.success
        case .connecting: FloeTheme.primary
        case .suspended: FloeTheme.pending
        case .disconnected: FloeTheme.destructive
        case .unknown: FloeTheme.unknown
        }
    }
}
#endif
