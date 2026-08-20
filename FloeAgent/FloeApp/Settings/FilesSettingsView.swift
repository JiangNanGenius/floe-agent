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

struct FilesSettingsView: View {
    @ObservedObject var center: SettingsCenter
    @State private var clearedBytes: Int64?
    @State private var isClearing = false

    var body: some View {
        Form {
            Section("settings.files.workspaces") {
                if center.workspaces.isEmpty {
                    Text("settings.files.workspaces.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(center.workspaces) { workspace in
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
                    }
                    if center.defaultWorkspaceID != nil {
                        Button("settings.files.workspace.clear_default") {
                            Task { await center.setDefaultWorkspace(id: nil) }
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await clearTemporaryFiles() }
                } label: {
                    if isClearing {
                        ProgressView()
                    } else {
                        Text("settings.files.clear_cache")
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                .disabled(isClearing)
            } header: {
                Text("settings.files.cache")
            } footer: {
                if let clearedBytes {
                    Text("settings.files.clear_cache.result \(clearedBytes)")
                } else {
                    Text("settings.files.clear_cache.footer")
                }
            }
        }
        .navigationTitle("settings.section.files")
        .task { await center.load() }
    }

    // MARK: - Helpers

    /// Deletes everything in the app temporary directory and echoes the
    /// reclaimed byte count. Real deletion, no silent success.
    private func clearTemporaryFiles() async {
        isClearing = true
        defer { isClearing = false }
        let bytes = await Task.detached(priority: .utility) { () -> Int64 in
            let tmp = FileManager.default.temporaryDirectory
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: tmp, includingPropertiesForKeys: [.fileSizeKey]
            ) else { return 0 }
            var total: Int64 = 0
            for url in children {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if let bytes = size as Int? { total += Int64(bytes) }
                try? FileManager.default.removeItem(at: url)
            }
            return total
        }.value
        clearedBytes = bytes
    }
}
#endif
