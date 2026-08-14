// FloeApp — Settings center shell.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5. iPad uses a NavigationSplitView
// (category list left, detail right — never an empty detail column; the
// first category is selected by default). iPhone uses the standard
// NavigationStack push flow. T08 landed General/Providers/Auxiliary; T09
// lands Permissions/Execution/Files/Remote/Privacy; Diagnostics lands in
// T10.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// One settings category in the settings center.
enum SettingsSection: String, Hashable, CaseIterable, Identifiable, Sendable {
    case general, providers, auxiliary, permissions, execution, files, remote, privacy

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "settings.section.general"
        case .providers: "settings.section.providers"
        case .auxiliary: "settings.section.auxiliary"
        case .permissions: "settings.section.permissions"
        case .execution: "settings.section.execution"
        case .files: "settings.section.files"
        case .remote: "settings.section.remote"
        case .privacy: "settings.section.privacy"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .providers: "antenna.radiowaves.left.and.right"
        case .auxiliary: "photo.badge.plus"
        case .permissions: "checkmark.shield"
        case .execution: "terminal"
        case .files: "folder"
        case .remote: "server.rack"
        case .privacy: "hand.raised"
        }
    }
}

/// Settings shell: category list + per-category detail.
struct SettingsRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
                }
                .navigationTitle("settings.title")
            } detail: {
                detailView(for: selection ?? .general)
            }
        } else {
            // iPhone: the More tab already hosts a NavigationStack, so the
            // category list is the pushed screen and rows navigate deeper.
            List(SettingsSection.allCases) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            }
            .navigationTitle("settings.title")
            .navigationDestination(for: SettingsSection.self) { section in
                detailView(for: section)
            }
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(center: environment.settingsCenter)
        case .providers:
            ProvidersSettingsView(center: environment.conversationCenter)
        case .auxiliary:
            AuxiliarySettingsView(center: environment.conversationCenter)
        case .permissions:
            AgentPermissionsView(center: environment.settingsCenter)
        case .execution:
            ExecutionEnvironmentView(center: environment.settingsCenter)
        case .files:
            FilesSettingsView(center: environment.settingsCenter)
        case .remote:
            RemoteSettingsView(center: environment.settingsCenter)
        case .privacy:
            PrivacySecurityView(center: environment.settingsCenter)
        }
    }
}
#endif
