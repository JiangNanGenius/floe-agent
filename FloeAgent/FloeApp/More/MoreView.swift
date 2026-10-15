// FloeApp — More tab root.
//
// SPDX-License-Identifier: MPL-2.0
//
// The More tab: operational surfaces only. Pure informational privacy pages
// are intentionally absent; actionable data controls live in Settings.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence
import FloeCore

/// The More tab root list.
struct MoreView: View {
    @StateObject private var viewModel: MoreViewModel

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: MoreViewModel(center: center))
    }

    var body: some View {
        List {
            ForEach(MoreDestination.visibleCases) { sub in
                NavigationLink(value: sub) {
                    Label(sub.title, systemImage: sub.systemImage)
                }
            }
        }
        .navigationTitle("tab.more")
        .navigationDestination(for: MoreDestination.self) { sub in
            MoreDestinationRouter(sub: sub, viewModel: viewModel)
        }
    }
}

/// Routes a More sub-destination to its screen.
private struct MoreDestinationRouter: View {
    let sub: MoreDestination
    let viewModel: MoreViewModel

    var body: some View {
        switch sub {
        case .notes:
            NotesRootView()
        case .creative:
            CreativeModeHubView()
        case .runs:
            RunsHistoryView(viewModel: viewModel)
        case .setupGuide:
            SetupGuideLauncherView()
        case .providers:
            ProviderListView(center: viewModel.center)
        case .auxiliaryModels:
            AuxiliaryModelsView(center: viewModel.center)
        case .skills:
            SkillsView(center: viewModel.environment.skillsCenter)
        case .memory:
            MemoryView(center: viewModel.environment.memoryCenter)
        case .settings:
            SettingsRootView(environment: viewModel.environment)
        case .diagnostics:
            DiagnosticsAboutView(center: viewModel.environment.settingsCenter)
        }
    }
}

/// Runs history: every run with honest, localized state. Each row names its
/// OWNING TASK (conversation identity) so a run is never confused with the
/// task it belongs to; bulk task management is one tap away and acts on task
/// identities (the same canonical screen the Task Center opens). Internal so
/// the iPad router in FloeAgentApp can reach the same screen the iPhone More
/// tab uses.
struct RunsHistoryView: View {
    let viewModel: MoreViewModel
    @State private var presentsTaskManagement = false

    var body: some View {
        Group {
            if viewModel.runs.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("more.runs", systemImage: "play.rectangle")
                } description: {
                    Text("empty.runs")
                }
            } else {
                List(viewModel.runs) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(taskTitle(for: run))
                            .font(FloeTheme.Typography.body)
                            .lineLimit(1)
                        if !run.goal.isEmpty {
                            Text(run.goal)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack {
                            Text(
                                run.startedAt,
                                format: .dateTime.month(.abbreviated).day().hour().minute()
                            )
                            Text("·")
                            Text(RunStateLocalizer.title(for: run.state))
                        }
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
            }
        }
        .navigationTitle("more.runs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentsTaskManagement = true
                } label: {
                    Label(FloeL10n.l("settings.data_management_view.manage"), systemImage: "checklist")
                }
                .accessibilityIdentifier("runs.manageTasks")
            }
        }
        .sheet(isPresented: $presentsTaskManagement) {
            ConversationBatchManagementView(center: viewModel.center)
        }
        .task { await viewModel.loadRuns() }
        .refreshable { await viewModel.loadRuns() }
    }

    private func taskTitle(for run: RunRecord) -> String {
        let title = viewModel.center.conversations.first { $0.id == run.conversationID }?.title ?? ""
        return title.isEmpty ? String(localized: "chat.untitled") : title
    }
}

#endif
