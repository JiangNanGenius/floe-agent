// FloeApp — Integrated IDE left sidebar.
//
// SPDX-License-Identifier: MPL-2.0
//
// The IDE's own left sidebar replaces the modal source-control sheet: the
// same `SourceControlCenter`/`SourceControlView` services render inside the
// workbench chrome, so staged/unstaged/untracked trees, diff, stage, unstage,
// commit and safe initialize stay available while the editor is visible.
// Ownership is pinned to the workspace the IDE was opened for; a global
// workspace or task switch is reported instead of silently showing another
// repository.
//
// The same sidebar hosts the native file tree/search mode
// (`FileTreeView`/`FileTreeViewModel`), so the native editing kernel keeps a
// workspace tree with rename/move/create/delete and file+content search
// without depending on the Web workbench.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeWorkspace

enum IDESidebarMode: String, Identifiable, CaseIterable {
    case files
    case search
    case sourceControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: IDELanguageRunText.t("文件", "Files")
        case .search: IDELanguageRunText.t("搜索", "Search")
        case .sourceControl: IDELanguageRunText.t("源码管理", "Source Control")
        }
    }

    var systemImage: String {
        switch self {
        case .files: "folder"
        case .search: "magnifyingglass"
        case .sourceControl: "arrow.triangle.branch"
        }
    }
}

struct IDESidebar: View {
    let mode: IDESidebarMode
    @ObservedObject var center: WorkspaceCenter
    /// The workspace this IDE session was opened for; nil when it was opened
    /// without one.
    let workspaceID: UUID?
    let workspaceName: String
    /// The workspace root this IDE session was opened for. The source-control
    /// pane is pinned to it: a switch to another workspace locks its writes
    /// instead of operating the global center's new repository.
    let pinnedRootURL: URL?
    var onClose: () -> Void
    /// Native file-tree selection. The IDE routes the path to the native text
    /// pane or to the typed viewer tab, never to a text decode.
    var onOpenFile: (String) -> Void = { _ in }

    @StateObject private var tree: FileTreeViewModel

    init(
        mode: IDESidebarMode,
        center: WorkspaceCenter,
        workspaceID: UUID?,
        workspaceName: String,
        pinnedRootURL: URL?,
        onClose: @escaping () -> Void,
        onOpenFile: @escaping (String) -> Void = { _ in }
    ) {
        self.mode = mode
        self.center = center
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.pinnedRootURL = pinnedRootURL
        self.onClose = onClose
        self.onOpenFile = onOpenFile
        _tree = StateObject(wrappedValue: FileTreeViewModel(center: center))
    }

    private var pinnedWorkspaceIsCurrent: Bool {
        guard let workspaceID else { return false }
        return center.currentWorkspace?.id == workspaceID
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(mode.title, systemImage: mode.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                .disabled(!pinnedWorkspaceIsCurrent)
                .accessibilityLabel(IDELanguageRunText.t("刷新", "Refresh"))
                .accessibilityIdentifier("workspace.ide.sidebar.refresh")
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                .accessibilityLabel(IDELanguageRunText.t("关闭侧边栏", "Close sidebar"))
                .accessibilityIdentifier("workspace.ide.sidebar.close")
            }
            .padding(.horizontal, 8)
            .frame(minHeight: FloeTheme.minimumTarget)
            .background(FloeTheme.sidebarSurface)
            Divider()
            if !pinnedWorkspaceIsCurrent {
                Label(
                    String(format: IDELanguageRunText.t("当前工作区已切换；此处仍显示“%@”。", "The current workspace changed; this still shows “%@”."), workspaceName),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
                .accessibilityIdentifier("workspace.ide.sidebar.ownershipNotice")
            }
            switch mode {
            case .files, .search:
                // Files and search share one tree view model so typing a
                // query never rescans from a second enumeration of the tree.
                FileTreeView(viewModel: tree, showsToolbar: mode == .search, dense: true) { path in
                    onOpenFile(path)
                }
                .task { await tree.loadRoot() }
                .disabled(!pinnedWorkspaceIsCurrent)
                .accessibilityIdentifier(mode == .search ? "workspace.ide.sidebar.search" : "workspace.ide.sidebar.files")
            case .sourceControl:
                // The ordinary source-control surface, pinned to the
                // workspace this IDE was opened for: one refresh per pinned
                // workspace identity, its own error alert, and a read-only
                // lock (with no refresh and no writes) after a switch.
                SourceControlView(
                    center: center.environment.sourceControlCenter,
                    pinnedRootURL: pinnedRootURL
                )
                .id(workspaceID?.uuidString ?? "no-workspace")
            }
        }
        .background(FloeTheme.readingSurface)
        .accessibilityIdentifier("workspace.ide.sidebar")
    }

    private func refresh() {
        switch mode {
        case .files, .search:
            Task { await tree.loadRoot() }
        case .sourceControl:
            // A locked (switched-away) pane never drives a global refresh.
            if pinnedWorkspaceIsCurrent {
                Task { await center.environment.sourceControlCenter.refreshRepository() }
            }
        }
    }
}

/// Compact-width presentation: a slide-over drawer over the workbench with a
/// dismiss scrim, so iPhone keeps the editor visible underneath.
struct IDESidebarDrawer<Content: View>: View {
    var onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
                .accessibilityLabel(IDELanguageRunText.t("关闭侧边栏", "Close sidebar"))
            content()
                .frame(width: 320)
                .frame(maxHeight: .infinity)
                .background(FloeTheme.readingSurface)
                .transition(.move(edge: .leading))
        }
        .accessibilityIdentifier("workspace.ide.sidebar.drawer")
    }
}
#endif
