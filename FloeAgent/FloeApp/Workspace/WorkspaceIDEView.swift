// FloeApp — Full-screen workspace IDE.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI

/// A focused, full-screen editing surface. The ordinary trailing inspector
/// remains the quick browser; opening a source file promotes the workspace to
/// this IDE with a persistent tree on the left and the editor on the right.
struct WorkspaceIDEView: View {
    @ObservedObject var center: WorkspaceCenter
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var treeModel: FileTreeViewModel
    @State private var selectedPath: String?
    @State private var selectedFileIsDirty = false
    @State private var pendingSelection: String?
    @State private var pendingDismissal = false
    @State private var showsUnsavedAlert = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarPanel: SidebarPanel = .files

    private enum SidebarPanel: String, CaseIterable, Identifiable {
        case files
        case sourceControl

        var id: String { rawValue }
        var title: String { self == .files ? "文件" : "源码管理" }
        var icon: String { self == .files ? "folder" : "arrow.triangle.branch" }
    }

    init(
        initialRelativePath: String,
        center: WorkspaceCenter,
        onSaved: @escaping () -> Void = {}
    ) {
        self.center = center
        self.onSaved = onSaved
        _treeModel = StateObject(wrappedValue: FileTreeViewModel(center: center))
        _selectedPath = State(initialValue: initialRelativePath)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            NavigationStack {
                editorDetail
                    .toolbar { closeToolbar }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(FloeTheme.readingSurface)
        .task { await treeModel.loadRoot() }
        .interactiveDismissDisabled(selectedFileIsDirty)
        .alert("有未保存的更改", isPresented: $showsUnsavedAlert) {
            Button("放弃更改", role: .destructive) { discardAndContinue() }
            Button("继续编辑", role: .cancel) { clearPendingAction() }
        } message: {
            Text("请先保存当前文件，或放弃更改后再切换文件或关闭编辑器。")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            Picker("IDE 面板", selection: $sidebarPanel) {
                ForEach(SidebarPanel.allCases) { panel in
                    Label(panel.title, systemImage: panel.icon).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if sidebarPanel == .files {
                FileTreeView(viewModel: treeModel, onSelectFile: requestSelection)
            } else {
                SourceControlView(center: center.environment.sourceControlCenter)
            }
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("工作区")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(FloeTheme.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(center.currentWorkspace?.name ?? "工作区")
                    .font(FloeTheme.Typography.section)
                    .lineLimit(1)
                if let selectedPath {
                    Text(selectedPath)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var editorDetail: some View {
        if let selectedPath {
            if WorkspaceFileType.isText(selectedPath),
               !center.isCloudWorkspacePath(selectedPath) {
                VStack(spacing: 0) {
                    pathBar(selectedPath)
                    Divider()
                    TextFileEditorView(
                        relativePath: selectedPath,
                        center: center,
                        onSaved: {
                            selectedFileIsDirty = false
                            onSaved()
                        },
                        embeddedInIDE: true,
                        onDirtyChange: { dirty in
                            guard self.selectedPath == selectedPath else { return }
                            selectedFileIsDirty = dirty
                        }
                    )
                    .id(selectedPath)
                }
            } else {
                FilePreviewView(
                    relativePath: selectedPath,
                    center: center,
                    allowsIDEExpansion: false
                )
                .id(selectedPath)
            }
        } else {
            ContentUnavailableView {
                Label("选择文件", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("从左侧工作区选择一个文件开始查看或编辑。")
            }
        }
    }

    private func pathBar(_ path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(FloeTheme.primary)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if selectedFileIsDirty {
                Label("未保存", systemImage: "circle.fill")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.pending)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(FloeTheme.chromeMaterial)
    }

    @ToolbarContentBuilder
    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                requestDismissal()
            } label: {
                Label("关闭编辑器", systemImage: "xmark")
            }
            .keyboardShortcut("w", modifiers: .command)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("关闭编辑器")
        }
    }

    private func requestSelection(_ path: String) {
        guard path != selectedPath else { return }
        if selectedFileIsDirty {
            pendingSelection = path
            pendingDismissal = false
            showsUnsavedAlert = true
        } else {
            select(path)
        }
    }

    private func requestDismissal() {
        if selectedFileIsDirty {
            pendingSelection = nil
            pendingDismissal = true
            showsUnsavedAlert = true
        } else {
            dismiss()
        }
    }

    private func discardAndContinue() {
        selectedFileIsDirty = false
        if let pendingSelection {
            select(pendingSelection)
        } else if pendingDismissal {
            dismiss()
        }
        clearPendingAction()
    }

    private func select(_ path: String) {
        selectedPath = path
        selectedFileIsDirty = false
        Task {
            await center.recordRecentFile(
                relativePath: path,
                displayName: (path as NSString).lastPathComponent
            )
        }
    }

    private func clearPendingAction() {
        pendingSelection = nil
        pendingDismissal = false
    }
}
#endif
