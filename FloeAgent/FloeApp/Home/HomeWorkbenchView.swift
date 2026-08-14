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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                workbenchHeader
                NewTaskComposerView(
                    draft: $viewModel.draft,
                    modelName: viewModel.activeModelName,
                    canSend: viewModel.canSend,
                    providerConfigured: viewModel.hasConfiguredProvider,
                    onSend: sendTask
                )
                if !viewModel.hasConfiguredProvider {
                    connectionStatusSection
                }
                activeTasksSection
                pendingApprovalsSection
                recentSessionsSection
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(FloeTheme.groupedSurface)
        .navigationTitle("tab.home")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .overlay {
            if viewModel.isLoading && viewModel.activeTasks.isEmpty {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }

    // MARK: - Sections

    private var workbenchHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("home.workspace.title")
                    .font(.title2.weight(.bold))
                Text("home.workspace.subtitle")
                    .font(FloeTheme.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.title2)
                .foregroundStyle(FloeTheme.brandGradient)
                .frame(width: 48, height: 48)
                .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
        }
    }

    /// Active (non-terminal) runs.
    private var activeTasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkbenchSectionHeader(
                title: "home.active_tasks",
                icon: "bolt.horizontal.circle",
                count: viewModel.activeTasks.count
            )
            if viewModel.activeTasks.isEmpty {
                WorkbenchEmptyRow(
                    title: "home.no_active",
                    detail: "home.no_active.detail",
                    icon: "checkmark.circle"
                )
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
                        .padding(.horizontal, 14)
                        .frame(minHeight: 58)
                        .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Pending approvals across all live runs.
    private var pendingApprovalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkbenchSectionHeader(
                title: "home.pending_approvals",
                icon: "checkmark.shield",
                count: viewModel.pendingApprovals.count,
                tint: viewModel.pendingApprovals.isEmpty ? .secondary : FloeTheme.pending
            )
            if viewModel.pendingApprovals.isEmpty {
                WorkbenchEmptyRow(
                    title: "home.no_pending",
                    detail: "home.no_pending.detail",
                    icon: "shield.checkered"
                )
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
        VStack(alignment: .leading, spacing: 12) {
            WorkbenchSectionHeader(
                title: "home.recent",
                icon: "terminal",
                count: viewModel.recentSessions.count
            )
            if viewModel.recentSessions.isEmpty {
                WorkbenchEmptyRow(
                    title: "home.no_sessions",
                    detail: "home.no_sessions.detail",
                    icon: "rectangle.connected.to.line.below"
                )
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
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    /// Connection status, shown only when no provider is configured.
    private var connectionStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkbenchSectionHeader(
                title: "home.connection",
                icon: "antenna.radiowaves.left.and.right",
                count: nil,
                tint: FloeTheme.pending
            )
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
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
            .padding(14)
            .background(FloeTheme.pending.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(FloeTheme.pending.opacity(0.18), lineWidth: 1)
            }
        }
    }

    // MARK: - Navigation

    private func sendTask() {
        Task {
            if let conversationID = await viewModel.sendNewTask() {
                router.openConversation(conversationID)
            }
        }
    }

    private func openRun(_ run: RunRecord) {
        router.openConversation(run.conversationID, runID: run.id)
    }
}

/// A deliberate iPad detail surface for Home. The middle column remains the
/// actionable workbench while this column explains what can be opened there.
struct HomeOverviewDetailView: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(FloeTheme.brandGradient)
                    .frame(width: 108, height: 108)
                    .shadow(color: FloeTheme.primary.opacity(0.2), radius: 24, y: 10)
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            VStack(spacing: 9) {
                Text("home.detail.title")
                    .font(.largeTitle.weight(.bold))
                Text("home.detail.subtitle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 12) {
                HomeCapability(icon: "bubble.left.and.text.bubble.right", title: "home.capability.threads")
                HomeCapability(icon: "checkmark.shield", title: "home.capability.approvals")
                HomeCapability(icon: "terminal", title: "home.capability.remote")
            }
            Spacer()
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FloeTheme.readingSurface)
        .navigationTitle("app.name")
    }
}

private struct HomeCapability: View {
    let icon: String
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(FloeTheme.primary)
            Text(title)
                .font(FloeTheme.Typography.metadata.weight(.medium))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 132, minHeight: 90)
        .padding(10)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct WorkbenchSectionHeader: View {
    let title: LocalizedStringKey
    let icon: String
    let count: Int?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(FloeTheme.Typography.section)
            Spacer()
            if let count {
                Text(count, format: .number)
                    .font(FloeTheme.Typography.metadata.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                    .accessibilityLabel(String(count))
            }
        }
    }
}

private struct WorkbenchEmptyRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FloeTheme.Typography.body.weight(.medium))
                Text(detail)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 14))
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
