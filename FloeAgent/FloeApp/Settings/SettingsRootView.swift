// FloeApp — Settings center shell.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5. iPad uses a NavigationSplitView
// (category list left, detail right — never an empty detail column; the
// first category is selected by default). iPhone uses the standard
// NavigationStack push flow. Every category is routed.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// One settings category in the settings center.
enum SettingsSection: String, Hashable, CaseIterable, Identifiable, Sendable {
    case general, personalization, providers, auxiliary, localModels, webSearch, permissions, appleCapabilities, privacy, execution, backgroundExecution, files, sourceControl, sync, remote, usage, dataManagement, diagnostics

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "settings.section.general"
        case .personalization: "记忆与个性化"
        case .providers: "settings.section.providers"
        case .auxiliary: "settings.section.auxiliary"
        case .webSearch: "websearch.title"
        case .localModels: "localmodels.title"
        case .permissions: "settings.section.permissions"
        case .appleCapabilities: "Apple 能力"
        case .privacy: "settings.section.privacy"
        case .execution: "settings.section.execution"
        case .backgroundExecution: "settings.section.background_execution"
        case .files: "settings.section.files"
        case .sourceControl: "GitHub 与源码管理"
        case .sync: "settings.section.sync"
        case .remote: "settings.section.remote"
        case .usage: "settings.section.usage"
        case .dataManagement: "数据管理"
        case .diagnostics: "settings.section.diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .personalization: "person.crop.circle.badge.checkmark"
        case .providers: "antenna.radiowaves.left.and.right"
        case .auxiliary: "photo.badge.plus"
        case .webSearch: "magnifyingglass"
        case .localModels: "cpu"
        case .permissions: "checkmark.shield"
        case .appleCapabilities: "apple.logo"
        case .privacy: "hand.raised"
        case .execution: "terminal"
        case .backgroundExecution: "pip"
        case .files: "folder"
        case .sourceControl: "arrow.triangle.branch"
        case .sync: "icloud"
        case .remote: "server.rack"
        case .usage: "chart.bar"
        case .dataManagement: "archivebox"
        case .diagnostics: "stethoscope"
        }
    }
}

/// Settings shell: category list + per-category detail.
struct SettingsRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selection: SettingsSection? = .general

    var body: some View {
        if horizontalSizeClass == .regular {
            // iPad: master-detail with a preselected first category so the
            // detail column is never blank.
            NavigationSplitView {
                List(SettingsSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityIdentifier("settings.section.\(section.rawValue)")
                }
                .navigationTitle("settings.title")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("action.done") { dismiss() }
                    }
                }
            } detail: {
                // Wrap the detail column in a NavigationStack so NavigationLink
                // inside detail views (e.g. MemoryView's 用户画像/SOUL.md) can
                // push. Without this the links are silently dropped on iPad.
                NavigationStack {
                    detailView(for: selection ?? .general)
                }
            }
        } else {
            // The settings sheet has no outer navigation container. Own the
            // compact stack here so the same screen works both from the sheet
            // and from More without relying on an ancestor implementation
            // detail.
            NavigationStack {
                List(SettingsSection.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    .accessibilityIdentifier("settings.section.\(section.rawValue)")
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
                .navigationTitle("settings.title")
                .navigationDestination(for: SettingsSection.self) { section in
                    detailView(for: section)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("action.done") { dismiss() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(center: environment.settingsCenter)
        case .personalization:
            MemoryView(center: environment.memoryCenter)
        case .providers:
            ProvidersSettingsView(center: environment.conversationCenter)
        case .auxiliary:
            AuxiliarySettingsView(center: environment.conversationCenter)
        case .webSearch:
            WebSearchSettingsView(center: environment.webSearchSettingsCenter)
        case .localModels:
            LocalModelsSettingsView(center: environment.localModelsCenter)
        case .permissions:
            AgentPermissionsView(center: environment.settingsCenter)
        case .appleCapabilities:
            AppleCapabilitiesSettingsView()
        case .privacy:
            PrivacySecurityView(center: environment.settingsCenter)
        case .execution:
            ExecutionEnvironmentView(center: environment.settingsCenter)
        case .backgroundExecution:
            BackgroundExecutionSettingsView(
                center: environment.settingsCenter,
                videoService: environment.backgroundVideoService
            )
        case .files:
            FilesSettingsView(center: environment.settingsCenter)
        case .sourceControl:
            GitHubSettingsView(center: environment.sourceControlCenter)
        case .sync:
            SyncSettingsView(center: environment.settingsCenter)
        case .remote:
            RemoteSettingsView(center: environment.settingsCenter)
        case .usage:
            UsageStatisticsView()
        case .dataManagement:
            DataManagementView(
                environment: environment,
                conversationCenter: environment.conversationCenter
            )
        case .diagnostics:
            DiagnosticsAboutView(center: environment.settingsCenter)
        }
    }
}
#endif
