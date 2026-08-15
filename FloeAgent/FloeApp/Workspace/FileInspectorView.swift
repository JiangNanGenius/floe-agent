// FloeApp — Workspace file inspector.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §4: the iPad collapsible third
// column / iPhone sheet container. Shows the workspace picker when no
// workspace is open; otherwise a lazy file tree + search, drilling into
// preview / editor / Quick Look. Selecting a file records it as recent and
// persists the inspector selection state.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels

/// The file inspector surface: workspace header + tree/search + preview
/// navigation. Presented in the iPad third column or the iPhone sheet via
/// AppRouter's inspectorContent.
struct FileInspectorView: View {
    @ObservedObject var center: WorkspaceCenter
    @EnvironmentObject private var router: AppRouter

    @StateObject private var treeModel: FileTreeViewModel
    @State private var previewPath: String?
    @State private var showWorkspacePicker = false
    /// Prevents the tree's restoration task from reopening the file during
    /// the short async window in which the cleared selection is persisted.
    @State private var isClosingPreview = false

    init(center: WorkspaceCenter) {
        self.center = center
        _treeModel = StateObject(wrappedValue: FileTreeViewModel(center: center))
    }

    var body: some View {
        Group {
            if let workspace = center.currentWorkspace {
                inspectorBody(workspace)
            } else {
                WorkspacePickerView(center: center)
            }
        }
        .background(FloeTheme.readingSurface)
        .sheet(isPresented: $showWorkspacePicker) {
            NavigationStack {
                WorkspacePickerView(center: center) {
                    showWorkspacePicker = false
                    Task { await treeModel.loadRoot() }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("inspector.close") { showWorkspacePicker = false }
                            .frame(minHeight: FloeTheme.minimumTarget)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func inspectorBody(_ workspace: WorkspaceRecord) -> some View {
        if let previewPath {
            FilePreviewView(
                relativePath: previewPath,
                center: center,
                onAddToContext: { addToContext(previewPath) }
            )
            .id(previewPath)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        closePreview()
                    } label: {
                        Label("inspector.back", systemImage: "chevron.left")
                    }
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel("inspector.back")
                }
            }
        } else {
            VStack(spacing: 0) {
                workspaceHeader(workspace)
                Divider()
                FileTreeView(viewModel: treeModel) { path in
                    isClosingPreview = false
                    self.previewPath = path
                    Task { await persistSelection(path) }
                }
            }
            .navigationTitle("inspector.files")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.hideInspector()
                    } label: {
                        Label("inspector.close", systemImage: "xmark")
                    }
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel("inspector.close")
                }
            }
            .task {
                await treeModel.loadRoot()
                if !isClosingPreview,
                   let selected = workspace.inspectorState.selectedRelativePath {
                    previewPath = selected
                }
            }
        }
    }

    private func workspaceHeader(_ workspace: WorkspaceRecord) -> some View {
        Button {
            showWorkspacePicker = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(FloeTheme.primary)
                    .accessibilityHidden(true)
                Text(workspace.name)
                    .font(FloeTheme.Typography.section)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text("workspace.switch")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel("workspace.switch")
    }

    private func persistSelection(_ path: String) async {
        var state = center.currentWorkspace?.inspectorState ?? InspectorState()
        state.selectedRelativePath = path
        state.isExpanded = true
        await center.updateInspectorState(state)
    }

    /// Returns to the file tree and clears the durable selection. Without
    /// clearing the persisted path, the tree's `.task` immediately restores
    /// the same preview and makes the Back button appear unresponsive.
    private func closePreview() {
        // Set the guard before changing branches. Without this synchronous
        // latch, the file-tree `.task` can read the old persisted path and
        // immediately reopen the same file, making Back look broken.
        isClosingPreview = true
        previewPath = nil
        Task {
            var state = center.currentWorkspace?.inspectorState ?? InspectorState()
            state.selectedRelativePath = nil
            state.isExpanded = true
            await center.updateInspectorState(state)
            await treeModel.loadRoot()
            isClosingPreview = false
        }
    }

    /// Adds the file to the current conversation context: persists an
    /// attachment reference (relative path + metadata only) and a context
    /// message part, and links the conversation to the workspace.
    private func addToContext(_ relativePath: String) {
        Task { await center.addFileToConversationContext(
            relativePath: relativePath,
            conversationID: router.selectedConversationID
        ) }
    }
}
#endif
