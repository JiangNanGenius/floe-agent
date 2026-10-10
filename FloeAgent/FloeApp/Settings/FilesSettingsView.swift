// FloeApp — Files & iCloud settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 6: workspace list + default
// project (WorkspaceStore / app_settings), and a real cache/temp cleanup with
// a count echo.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels

struct FilesSettingsView: View {
    @ObservedObject var center: SettingsCenter
    @State private var workspacePendingDeletion: WorkspaceRecord?

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AllWorkspacesFilesView(environment: center.environment)
                } label: {
                    Label("settings.files_settings_view.browse_and_manage_files", systemImage: "folder")
                }.accessibilityIdentifier("settings.files.manage")
            } header: {
                Text("settings.files_settings_view.files")
            } footer: {
                Text("settings.files_settings_view.find_all_workspaces_by_project_or")
            }

            Section("settings.files.workspaces") {
                if center.workspaces.isEmpty {
                    Text("settings.files.workspaces.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(center.workspaces.filter { $0.kind == .project }) { workspace in
                        HStack {
                            Text(workspace.name.isEmpty
                                 ? String(localized: "settings.files.workspace.untitled")
                                 : workspace.name)
                            Spacer()
                            if workspace.id == center.defaultWorkspaceID {
                                Text("settings.files.workspace.default")
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(FloeTheme.primary)
                            }
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await center.setDefaultWorkspace(id: workspace.id) }
                        }
                        .accessibilityAddTraits(
                            workspace.id == center.defaultWorkspaceID ? .isSelected : []
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                workspacePendingDeletion = workspace
                            } label: {
                                Label("localmodels.remove", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                workspacePendingDeletion = workspace
                            } label: {
                                Label("settings.files_settings_view.remove_workspace", systemImage: "trash")
                            }
                        }
                    }
                    if center.defaultWorkspaceID != nil {
                        Button("settings.files.workspace.clear_default") {
                            Task { await center.setDefaultWorkspace(id: nil) }
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                    }
                }
            }

        }
        .navigationTitle(FloeL10n.l("settings.section.files"))
        .task { await center.load() }
        .confirmationDialog("settings.files_settings_view.remove_workspace_2",
            isPresented: Binding(
                get: { workspacePendingDeletion != nil },
                set: { if !$0 { workspacePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("localmodels.remove", role: .destructive) {
                guard let workspace = workspacePendingDeletion else { return }
                workspacePendingDeletion = nil
                Task {
                    try? await center.environment.workspaceCenter.deleteWorkspace(id: workspace.id)
                    await center.load()
                }
            }
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) { workspacePendingDeletion = nil }
        } message: {
            Text("settings.files_settings_view.only_the_workspace_record_is_removed")
        }
    }

}
#endif
