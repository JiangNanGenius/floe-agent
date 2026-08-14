// FloeApp — More tab root.
//
// SPDX-License-Identifier: MPL-2.0
//
// The More tab: Runs history, Providers, Settings, Privacy, and (DEBUG)
// Diagnostics. Runs history lists every run honestly; the rest route to
// their screens. Diagnostics stays DEBUG-only.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence

/// The More tab root list.
struct MoreView: View {
    @StateObject private var viewModel: MoreViewModel
    @EnvironmentObject private var router: AppRouter

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

    @EnvironmentObject private var router: AppRouter

    var body: some View {
        switch sub {
        case .runs:
            RunsHistoryView(viewModel: viewModel)
        case .setupGuide:
            SetupGuideLauncherView()
        case .providers:
            ProviderListView(center: viewModel.center)
        case .auxiliaryModels:
            AuxiliaryModelsView(center: viewModel.center)
        case .settings:
            SettingsPlaceholder()
        case .privacy:
            PrivacyView()
        case .diagnostics:
#if DEBUG
            M0DiagnosticsView(model: router.diagnostics)
#else
            ShellPlaceholder()
#endif
        }
    }
}

/// Runs history: every run with honest state.
private struct RunsHistoryView: View {
    let viewModel: MoreViewModel

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
                        Text(run.goal.isEmpty ? String(localized: "chat.untitled") : run.goal)
                            .font(FloeTheme.Typography.body)
                            .lineLimit(1)
                        HStack {
                            Text(run.startedAt, style: .relative)
                            Text("·")
                            Text(run.state)
                        }
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
            }
        }
        .navigationTitle("more.runs")
        .task { await viewModel.loadRuns() }
        .refreshable { await viewModel.loadRuns() }
    }
}

/// Settings placeholder (real settings land later; honest empty state).
private struct SettingsPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("more.settings", systemImage: "gearshape")
        } description: {
            Text("empty.settings")
        }
        .navigationTitle("more.settings")
    }
}

/// Privacy: honest statement of the data model (secrets in Keychain,
/// no analytics/ads, no Floe backend).
private struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Label("privacy.point.secrets", systemImage: "key.fill")
                Label("privacy.point.local", systemImage: "internaldrive")
                Label("privacy.point.no_backend", systemImage: "icloud.slash")
                Label("privacy.point.no_tracking", systemImage: "eye.slash")
            }
        }
        .navigationTitle("more.privacy")
    }
}

/// DEBUG-only placeholder for non-DEBUG diagnostics routing.
private struct ShellPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("more.diagnostics", systemImage: "stethoscope")
        } description: {
            Text("empty.diagnostics")
        }
    }
}
#endif
