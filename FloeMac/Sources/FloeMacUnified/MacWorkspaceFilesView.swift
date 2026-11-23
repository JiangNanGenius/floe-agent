// SPDX-License-Identifier: MPL-2.0

import AppKit
import Darwin
import FloeMacBridgeProtocol
import FloeModels
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// An open/preview artifact event reported by the workspace files UI.
/// Shared by the full Files workspace and the task inspector embedding.
enum MacWorkspaceArtifactEvent: Sendable, Equatable {
    /// The user asked to open the file with its default macOS application.
    case opened(URL)
    /// The file became the focused inline preview.
    case previewed(URL)
}

/// The same descriptor-pinned publication used when the user imports a file
/// from Finder into the task inspector.
enum MacWorkspaceFileImport {
    static func save(_ source: URL, in root: URL) throws -> URL {
        let name = try MacWorkspaceFolderSnapshot.importFile(source, into: root, in: root)
        return root.appendingPathComponent(name)
    }
}

/// How the inline preview/editor is arranged next to the file list.
enum MacWorkspaceFilesLayout: Sendable {
    /// Pick side-by-side or stacked automatically from the available width.
    /// This is the default and is safe for both the full Files workspace
    /// column and the narrow task-inspector column.
    case adaptive
    /// Always show the file list and the inline preview/editor side by side.
    case split
    /// Always stack the file list above the inline preview/editor.
    case stacked
    /// Inspector browsing flow for the narrow task-sidebar column, mirroring
    /// the iPad `FileInspectorView`: the file list fills the whole column
    /// first, and selecting a file pushes its preview (or the text editor)
    /// as the next page in place of the list, with a Back button returning
    /// to the list. Unlike `.stacked`, the preview/editor never squeezes the
    /// list into a half-height pair inside the narrow column.
    case inspector
}

/// Real Mac workspace files + preview surface.
///
/// One shared view backs both the full "Files" workspace column and the task
/// inspector sidebar; embed it in either location without any changes.
///
/// Optional wiring callbacks (all default to nil, so the existing
/// `MacWorkspaceFilesView(insertInDraft:canInsertInDraft:)` call site keeps
/// compiling unchanged):
/// - `onFolderPicked`: receives the resolved root the user selects in the
///   folder picker. Restoring a bookmark only opens the folder.
/// - `onAttachmentsChanged`: fired with the current tracked attachment URLs
///   (sorted by name) every time the set changes. Attachments are verified
///   regular files inside the granted root; nothing outside the root is ever
///   reported. When `taskAttachmentURLs` is non-nil this callback carries the
///   candidate set after each add/remove and the view stores nothing (see
///   below).
/// - `onArtifact`: fired with `.opened` when a file is opened in its default
///   app, and `.previewed` when a file becomes the focused inline preview.
///
/// `taskAttachmentURLs`: when the host composer already tracks staged file
/// URLs for the active task, inject them here. While non-nil, every
/// attachment badge/add/remove reads this set verbatim and each mutation only
/// proposes the candidate set through `onAttachmentsChanged` — the view keeps
/// no copy, so the display can never go stale after a send or after a
/// composer-side removal. While nil, the view falls back to tracking the set
/// locally (the original behavior). The "a run is in progress" attach gate is
/// the host's `canInsertInDraft`.
///
/// `layout` selects the inline arrangement: `.adaptive` (the default) measures
/// the available width and switches between side-by-side and stacked, so one
/// instance works both as the full Files workspace and inside the task
/// inspector; `.split` and `.stacked` pin the arrangement when the host wants
/// explicit control; `.inspector` gives the narrow task-inspector column the
/// iPad file-inspector browsing flow — list first, preview/editor pushed in
/// place, Back returning to the list — and leaves every selection,
/// attachment, editing and security behavior to the existing paths.
///
/// `fixedRootURL` (default `nil`) pins the root to a host-resolved directory
/// that carries no bookmark — the app-owned default conversations directory
/// is the current use. It behaves exactly like `fixedRootBookmark`: the user
/// cannot close or change the folder, nothing is persisted here, and an
/// unreadable or missing directory shows the fixed-root unavailable state
/// instead of the picker.
///
/// `remembersRoot` (default `true`) persists the chosen root as a bookmark so
/// the folder survives relaunch. Smoke/embedder hosts that must never touch
/// production state pass `false`; in addition, `FLOE_MAC_HOST_SMOKE` builds
/// never restore a saved bookmark.
///
/// Security model (unchanged from the original view): every read, preview,
/// drag, attach, import, and save goes through `MacWorkspaceFolderSnapshot`
/// containment checks, `O_NOFOLLOW` descriptor verification, and
/// `BridgeAbsoluteFileRead.isSecretPath`, so no path outside the chosen root —
/// and no credential material — is ever read or written. Lightweight text
/// editing (UTF-8, at most 32 KB, no NUL bytes) saves in place on Command-S:
/// the bytes are staged as an exclusive temp file inside the pinned
/// directory with the opened file's metadata (permissions, ACLs, extended
/// attributes) and atomically exchanged with it (`renameatx_np(RENAME_SWAP)`
/// — never a plain rename) after the on-disk revision still matches the
/// identity captured at open, so an external edit or a path replacement is a
/// conflict that leaves the original recoverable and keeps the user's text in
/// the editor. The
/// separate "Save a Copy" keeps the earlier behavior: the text is published
/// under a new, previously non-existing name (`RENAME_EXCL` hard-link
/// exchange inside a pinned directory) and the editor switches to that file,
/// with bounded read-back verification before the save is accepted.
struct MacWorkspaceFilesView: View {
    #if FLOE_MAC_HOST_SMOKE
    static let syncEditorRequest = Notification.Name("FloeMacWorkspaceFilesView.SyncEditorRequest")

    @MainActor
    final class SyncEditorRequest {
        let url: URL
        let replacement: String?
        var accepted = false
        var text: String?
        var panel: String?

        init(url: URL, replacement: String?) {
            self.url = url
            self.replacement = replacement
        }
    }
    #endif

    let insertInDraft: (String) -> Void
    var canInsertInDraft: Bool
    var remembersRoot: Bool = true
    var fixedRootBookmark: Data?
    var fixedRootURL: URL? = nil
    var fixedPrivateWorkspace: WorkspaceRecord? = nil
    var privateTaskRootBase: URL? = nil
    var managedConversationsRoot: URL? = nil
    var recentlyDeletedDirectory: URL? = nil
    var workspaceRevision: UUID? = nil
    /// When the host composer tracks staged file URLs for the active task it
    /// injects them here; while non-nil the UI reads this set verbatim and
    /// mutations only propose candidates through `onAttachmentsChanged`.
    var taskAttachmentURLs: Set<URL>? = nil
    var protectedDraftFiles: () -> Set<URL> = { [] }
    var onFolderPicked: ((URL) -> Void)? = nil
    var onAttachmentsChanged: (([URL]) -> Void)? = nil
    var canChangeFiles: () -> Bool = { true }
    var onPendingChanges: ((Bool) -> Void)? = nil
    var onArtifact: ((MacWorkspaceArtifactEvent) -> Void)? = nil
    var layout: MacWorkspaceFilesLayout = .adaptive
    var findRequest: UUID? = nil
    /// Display-only ownership labels for immediate folder children of the
    /// app-owned default conversations root, keyed by real folder basename
    /// (the per-task UUID). The host supplies known conversation titles;
    /// every filesystem operation keeps the real name and URL.
    var rootFolderLabels: [String: String] = [:]
    /// Task-inspector mode without a usable host-provided per-task root: the
    /// surface shows an unavailable state with a choose-project action instead
    /// of the folder picker, and the remembered ad-hoc bookmark is never
    /// restored. Space's custom selection is a different mode and keeps its
    /// own restore path.
    var requiresTaskRoot = false
    var onChooseProject: (() -> Void)? = nil

    @FocusState private var filterFocused: Bool
    @Environment(\.locale) private var locale
    @AppStorage("floe.mac.workspace.files.rootBookmark") private var savedRootBookmark: Data?
    @State private var root: URL?
    @State private var directory: URL?
    @State private var entries: [MacWorkspaceFileEntry] = []
    @State private var selection: Set<URL> = []
    @State private var focused: URL?
    @State private var filter = ""
    @State private var restoringRoot = true
    @State private var reloadID = UUID()
    @State private var loading = false
    @State private var limited = false
    @State private var failed = false
    @State private var attachments: Set<URL> = []
    @State private var editing: MacWorkspaceTextEditSession?
    @State private var importingText = false
    @State private var fileImportsInProgress = 0
    @State private var dropImportStatus: String?
    @State private var showTextImportError = false
    @State private var showSaveError = false
    @State private var showConflict = false
    @State private var showDiscard = false
    @State private var showScopeAlert = false
    @State private var htmlSite: MacWorkspaceHTMLSite?
    @State private var mutationRequest: FileMutationRequest?
    @State private var mutationError: String?
    @State private var mutationInProgress = false
    @State private var restoreHistory: [MacWorkspaceFileOperations.TrashReceipt] = []
    @State private var showRecentlyDeleted = false
    @State private var recentDeletions: [MacWorkspaceTrashRecord] = []
    @State private var unavailableDeletions: Set<UUID> = []
    @State private var deletionSelection: Set<UUID> = []
    @State private var deletionNotice: String?
    @State private var loadingDeletions = false
    @State private var deletionLoadFailed = false
    @State private var latestTrashIDs: Set<UUID> = []
    @State private var showTrashFinderNotice = false
    @State private var trashFinderDirectory: URL?
    @State private var trashOriginalDirectory: URL?

    private struct FileMutationRequest: Identifiable, Sendable {
        enum Action: Sendable { case create, rename, trash }
        let id = UUID()
        let action: Action
        let root: URL
        let operations: MacWorkspaceFileOperations
        /// Identities pinned when the user opened the action. Empty for
        /// create; exactly one for rename; one per selected item for trash,
        /// where a batch shares this single confirmation and per-item guard.
        let items: [MacWorkspaceFileOperations.Item]
        /// Selected rows that could not even be pinned (inaccessible or
        /// already gone when the action opened). They are reported as
        /// failures of the same confirmed run instead of vanishing silently.
        let skipped: [MacWorkspaceFileOperations.TrashBatchFailure]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if restoringRoot {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if directory == nil && fixedRootBookmark != nil {
                ContentUnavailableView(t("无法读取项目文件夹", "Project Folder Unavailable"),
                                       systemImage: "folder.badge.questionmark")
            } else if directory == nil && (fixedRootURL != nil || fixedPrivateWorkspace != nil) {
                ContentUnavailableView(t("无法读取任务文件夹", "Task Files Unavailable"),
                                       systemImage: "folder.badge.questionmark")
            } else if directory == nil && requiresTaskRoot {
                ContentUnavailableView {
                    Label(t("任务文件不可用", "Task Files Unavailable"), systemImage: "folder.badge.questionmark")
                } description: {
                    Text(t("此任务还没有可用的文件工作区。为任务选择一个项目后即可浏览和附加文件。",
                           "This task has no file workspace yet. Choose a project to browse and attach files."))
                } actions: {
                    if let onChooseProject {
                        Button(t("选择项目…", "Choose Project…")) { onChooseProject() }
                            .disabled(!canChangeFiles())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if directory == nil {
                ContentUnavailableView {
                    Label(t("选择文件夹", "Choose a Folder"), systemImage: "folder")
                } description: {
                    Text(t("查看文件，或在其他应用中打开。", "Browse files and open them in other apps."))
                } actions: {
                    Button(t("选择文件夹…", "Choose Folder…"), action: chooseFolder)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                ContentUnavailableView {
                    Label(t("无法读取此文件夹", "Couldn’t Read This Folder"), systemImage: "folder.badge.questionmark")
                } actions: {
                    Button(t("重试", "Retry")) { reloadID = UUID() }
                }
            } else {
                adaptiveContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(mutationInProgress)
        .task { await restoreSavedRoot() }
        .task(id: reloadID) { await loadDirectory() }
        .onChange(of: hasPendingChanges, initial: true) { _, pending in onPendingChanges?(pending) }
        #if FLOE_MAC_HOST_SMOKE
        .onReceive(NotificationCenter.default.publisher(for: Self.syncEditorRequest)) { notification in
            guard let request = notification.object as? SyncEditorRequest, !request.accepted else { return }
            request.panel = "folder=\(directory?.lastPathComponent ?? "none"), files=\(entries.map(\.name)), loading=\(loading)"
            let requestedPath = request.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard let entry = entries.first(where: { $0.url.standardizedFileURL.path == requestedPath }),
                  isEditableText(entry) else { return }
            request.accepted = true
            if editing?.entry.url != entry.url { edit(entry) }
            Task { @MainActor in
                let deadline = ContinuousClock.now + .seconds(2)
                while editing?.entry.url != entry.url && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                guard editing?.entry.url == entry.url else { return }
                if let replacement = request.replacement { editorBinding.wrappedValue = replacement }
                request.text = editing?.text
            }
        }
        #endif
        .onChange(of: workspaceRevision) { reloadID = UUID() }
        .onChange(of: findRequest) { _, request in
            if request != nil, directory != nil, !loading, !failed { filterFocused = true }
        }
        .onChange(of: selection) { _, newSelection in
            guard newSelection.count == 1, let url = newSelection.first,
                  let entry = entries.first(where: { $0.url == url }), entry.openable else { return }
            focused = url
            onArtifact?(.previewed(url))
        }
        .sheet(item: $htmlSite) { site in
            MacWorkspaceHTMLPreview(site: site)
        }
        .onChange(of: root) { _, _ in
            htmlSite = nil; mutationRequest = nil; restoreHistory = []; latestTrashIDs = []
            showRecentlyDeleted = false; recentDeletions = []; unavailableDeletions = []
        }
        .sheet(isPresented: $showRecentlyDeleted) { recentlyDeletedSheet }
        .sheet(item: $mutationRequest) { request in
            FileActionSheet(
                title: mutationTitle(request.action), initial: request.action == .rename ? request.items.first?.name ?? "" : "",
                trashName: request.action == .trash ? trashConfirmationText(request.items) : nil,
                confirm: { name in perform(request, name: name) }
            )
        }
        .alert(t("文件操作未完成", "File Action Couldn’t Finish"), isPresented: Binding(
            get: { mutationError != nil }, set: { if !$0 { mutationError = nil } }
        )) { Button(t("好", "OK"), role: .cancel) {} } message: {
            Text(verbatim: mutationError ?? "")
        }
        .alert(t("已移到废纸篓", "Moved to Trash"), isPresented: $showTrashFinderNotice) {
            Button(t("在 Finder 中打开废纸篓", "Open Trash in Finder")) {
                openTrashInFinder(directory: trashFinderDirectory)
            }
            Button(t("打开原文件夹", "Open Original Folder")) {
                if let trashOriginalDirectory { _ = NSWorkspace.shared.open(trashOriginalDirectory) }
            }
            Button(t("好", "OK"), role: .cancel) {}
        } message: {
            Text(t("如需恢复，请将项目从 Finder 的废纸篓拖回原文件夹。", "To restore the item, drag it from the Trash in Finder to its original folder."))
        }
        .alert(t("无法读取文本", "Couldn’t Read Text"), isPresented: $showTextImportError) {
            Button(t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(t("请选择 32 KB 以内的 UTF-8 文本文件。", "Choose a UTF-8 text file of 32 KB or less."))
        }
        .alert(t("无法保存文件", "Couldn’t Save File"), isPresented: $showSaveError) {
            Button(t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(t("请确认文件仍在所选文件夹内，且未被其他应用锁定。",
                   "Make sure the file is still inside the chosen folder and not locked by another app."))
        }
        .alert(t("保存冲突", "Save Conflict"), isPresented: $showConflict) {
            Button(t("取消", "Cancel"), role: .cancel) {}
            Button(t("重新加载", "Reload")) { reloadEdits() }
            Button(t("另存副本", "Save a Copy")) { saveEditsAsCopy() }
        } message: {
            Text(t("文件在打开后被其他应用修改或替换，因此没有覆盖它。你的更改仍保留在编辑器中，可另存副本或重新加载。",
                   "The file was changed or replaced by another app after it was opened, so it was not overwritten. Your edits remain in the editor; save a copy or reload."))
        }
        .alert(t("放弃未保存的更改？", "Discard Unsaved Changes?"), isPresented: $showDiscard) {
            Button(t("放弃更改", "Discard Changes"), role: .destructive) { editing = nil }
            Button(t("继续编辑", "Keep Editing"), role: .cancel) {}
        } message: {
            Text(t("关闭编辑器将丢弃此文件未保存的修改。", "Closing the editor discards unsaved changes to this file."))
        }
        .alert(t("超出所选文件夹", "Outside the Chosen Folder"), isPresented: $showScopeAlert) {
            Button(t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(t("只能引用或导入所选文件夹内的文件。", "Only files inside the chosen folder can be referenced or imported."))
        }
    }

    // MARK: - Layout

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(directory?.lastPathComponent.nonEmpty ?? t("文件", "Files"), systemImage: "folder")
                    .font(.headline)
                    .lineLimit(1)
                    .contextMenu {
                        if directory != nil && !rootIsFixed {
                            Button(t("关闭文件夹", "Close Folder"), action: clearFolder)
                                .disabled(hasPendingChanges)
                        }
                    }
                Spacer()
                if directory != nil {
                    Menu {
                        Button(mutationTitle(.create), systemImage: "folder.badge.plus") { prepare(.create) }
                            .disabled(!canManageHere)
                        if let entry = selectedEntries.count == 1 ? selectedEntries.first : (selection.isEmpty ? focusedEntry : nil) {
                            mutationItems(entry)
                        } else if selectedEntries.count > 1 {
                            batchTrashItem(selectedEntries)
                        }
                        if recentlyDeletedDirectory != nil {
                            Divider()
                            Button(t("最近删除", "Recently Deleted"), systemImage: "trash") { showRecentlyDeleted = true }
                                .accessibilityIdentifier("workspace.files.recentlyDeleted")
                        }
                        if let receipt = restoreHistory.last {
                            Divider()
                            Button(t("放回“\(receipt.item.name)”", "Put Back “\(receipt.item.name)”"), systemImage: "arrow.uturn.backward") {
                                restore(receipt)
                            }
                            .disabled(!canChangeFiles() || hasPendingChanges)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(t("管理文件", "Manage Files"))
                    .accessibilityLabel(t("管理文件", "Manage Files"))
                    .accessibilityIdentifier("workspace.files.manage")
                    if let receipt = restoreHistory.last {
                        Button { restore(receipt) } label: { Image(systemName: "arrow.uturn.backward") }
                            .help(t("放回“\(receipt.item.name)”", "Put Back “\(receipt.item.name)”"))
                            .accessibilityLabel(t("放回“\(receipt.item.name)”", "Put Back “\(receipt.item.name)”"))
                            .accessibilityIdentifier("workspace.files.restore")
                            .disabled(!canChangeFiles() || hasPendingChanges)
                    }
                    Button { goUp() } label: { Image(systemName: "arrow.up") }
                        .help(t("上一级", "Enclosing Folder"))
                        .accessibilityLabel(t("上一级", "Enclosing Folder"))
                        .accessibilityIdentifier("workspace.files.up")
                        .keyboardShortcut(.upArrow, modifiers: .command)
                        .disabled(directory == root)
                    Button { reloadID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                        .help(t("刷新", "Refresh"))
                        .accessibilityLabel(t("刷新", "Refresh"))
                        .accessibilityIdentifier("workspace.files.reload")
                    Button(action: revealRootInFinder) {
                        Image(systemName: "folder")
                    }
                    .help(t("在 Finder 中显示根文件夹", "Reveal Root in Finder"))
                    .accessibilityLabel(t("在 Finder 中显示根文件夹", "Reveal Root in Finder"))
                    .accessibilityIdentifier("workspace.files.revealRoot")
                    if let application = MacExternalFileOpening.codeApplication {
                        Button {
                            guard let root, let operations = try? MacWorkspaceFileOperations(root: root, directory: root,
                                managedConversationsRoot: managedConversationsRoot ?? fixedRootURL) else { return }
                            MacExternalFileOpening.open(operations.directory, in: application)
                        } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                        .help("mac.external.projectInCode")
                        .accessibilityLabel("mac.external.projectInCode")
                        .accessibilityIdentifier("workspace.files.openProjectInCode")
                    }
                    if !rootIsFixed {
                        Button(action: chooseFolder) {
                            Label(t("更换文件夹…", "Change Folder…"), systemImage: "folder.badge.gearshape")
                        }
                        .labelStyle(.iconOnly)
                        .help(t("更换文件夹…", "Change Folder…"))
                        .accessibilityIdentifier("workspace.files.changeFolder")
                        .disabled(hasPendingChanges)
                    }
                    if canInsertInDraft {
                        Button { chooseFiles() } label: { Image(systemName: "doc.badge.plus") }
                            .help(t("添加附件…", "Add Attachments…"))
                            .accessibilityLabel(t("添加附件…", "Add Attachments…"))
                            .accessibilityIdentifier("workspace.files.chooseFiles")
                        if !effectiveAttachments.isEmpty { attachmentsMenu }
                    }
                }
            }
            if let directory, let root, directory != root {
                HStack(spacing: 5) {
                    Button(root.lastPathComponent) { navigate(to: root) }
                        .buttonStyle(.plain)
                        .help(root.path)
                    Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
                    Text(verbatim: String(directory.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1))))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(directory.path)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .controlSize(.small)
    }

    @ViewBuilder private var attachmentsMenu: some View {
        let sorted = effectiveAttachments.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        Menu {
            if sorted.isEmpty {
                Text(t("没有附件", "No Attachments"))
            } else {
                ForEach(sorted, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        selection = [url]
                        focused = url
                    }
                }
                Divider()
                Button(t("全部移除", "Remove All"), role: .destructive) { updateAttachments([]) }
            }
        } label: {
            Image(systemName: "paperclip")
        }
        .help(t("附件", "Attachments"))
        .accessibilityLabel(t("附件", "Attachments"))
        .accessibilityIdentifier("workspace.files.attachments")
        .disabled(sorted.isEmpty)
        .overlay(alignment: .topTrailing) {
            if !sorted.isEmpty {
                Text("\(sorted.count)")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .background(Circle().fill(.tint))
                    .offset(x: 6, y: -6)
            }
        }
    }

    /// Wide layout: list and inline preview side by side.
    private var wideContent: some View {
        HSplitView {
            fileSidebar
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
            detailPane
                .frame(minWidth: 260, idealWidth: 380)
                .layoutPriority(1)
        }
    }

    /// Narrow layout (for example inside the task inspector): list above, inline
    /// preview below whenever a file is focused or being edited.
    private var narrowContent: some View {
        VStack(spacing: 0) {
            fileSidebar
            if editing != nil || focusedEntry?.openable == true {
                Divider()
                detailPane
                    .frame(minHeight: 170, idealHeight: 280)
            }
        }
    }

    @ViewBuilder private var adaptiveContent: some View {
        switch layout {
        case .adaptive:
            ViewThatFits(in: .horizontal) {
                wideContent
                narrowContent
            }
        case .split:
            wideContent
        case .stacked:
            narrowContent
        case .inspector:
            inspectorContent
        }
    }

    // MARK: - Inspector layout (iPad FileInspectorView browsing flow)

    /// The narrow task-inspector column behaves like the iPad file
    /// inspector: the file list is the first page, and the focused preview
    /// or the active editor becomes the next page shown in its place. There
    /// is deliberately no list-above-detail stacking here — at sidebar width
    /// that pairing squeezed both halves; pushing the detail keeps the
    /// preview, editor and its toolbar at full column height.
    @ViewBuilder private var inspectorContent: some View {
        if editing != nil || focusedEntry?.openable == true {
            inspectorDetailPage
        } else {
            fileSidebar
        }
    }

    /// Preview/editor page for `.inspector`. The header rows are the
    /// existing preview toolbar and editor toolbar with a Back button
    /// prepended, so every action (Open, Edit, quote, attachments, save,
    /// conflict, discard) is literally the existing control set.
    @ViewBuilder private var inspectorDetailPage: some View {
        VStack(spacing: 0) {
            if let session = editing {
                editorBar(session, showsBack: true)
                Divider()
                editorBody(session)
            } else if let entry = focusedEntry, entry.openable {
                inspectorPreviewBar(entry)
                Divider()
                MacWorkspaceQuickLook(url: entry.url)
            }
        }
    }

    /// Inspector preview header: Back, the file name, then the same action
    /// buttons as the wide/narrow preview toolbar.
    @ViewBuilder private func inspectorPreviewBar(_ entry: MacWorkspaceFileEntry) -> some View {
        HStack(spacing: 10) {
            inspectorBackButton()
            Text(verbatim: entry.name).font(.headline).lineLimit(1)
            Spacer()
            previewActions(entry)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .controlSize(.small)
    }

    private func inspectorBackButton() -> some View {
        Button(action: inspectorBack) {
            Label(t("返回", "Back"), systemImage: "chevron.left")
        }
        .help(t("返回文件列表", "Back to File List"))
        .accessibilityLabel(t("返回", "Back"))
        .accessibilityIdentifier("workspace.files.back")
    }

    /// Inspector Back navigation. From the editor this is exactly the
    /// existing Done path: a dirty session still passes through the
    /// "Discard Unsaved Changes?" confirmation before it closes. From a
    /// preview it clears the focused file and removes it from the selection
    /// (without touching any other multi-selection) so the list page
    /// reappears and the same row can be selected again. No data path
    /// changes: the same selection, attachment, conflict, discard and
    /// security-domain checks keep governing what the pages show and do.
    private func inspectorBack() {
        if editing != nil {
            closeEdits()
        } else if let focused {
            selection.remove(focused)
            self.focused = nil
        }
    }

    private var fileSidebar: some View {
        VStack(spacing: 0) {
            TextField(t("筛选当前文件夹", "Filter This Folder"), text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onExitCommand { filter = "" }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .accessibilityIdentifier("workspace.files.filter")
            let shown = visible
            if shown.isEmpty {
                ContentUnavailableView(t("没有匹配的文件", "No Matching Files"), systemImage: "doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(shown) { entry in
                        Group {
                            if canAccess(entry) {
                                Label(displayTitle(entry), systemImage: entry.folder ? "folder" : "doc")
                                    .lineLimit(1)
                                    .tag(entry.url)
                                    .contextMenu { actions(for: entry) }
                                    .onDrag {
                                        NSItemProvider(item: entry.url as NSURL,
                                                       typeIdentifier: UTType.fileURL.identifier)
                                    }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { open(entry) })
                            } else {
                                Label(displayTitle(entry), systemImage: entry.folder ? "folder" : "doc")
                                    .lineLimit(1)
                                    .tag(entry.url)
                                    .contextMenu { actions(for: entry) }
                            }
                        }
                        .accessibilityIdentifier("workspace.files.row.\(entry.name)")
                    }
                }
                .listStyle(.inset)
                .onKeyPress(.downArrow, phases: .down) { event in
                    guard event.modifiers == .command, selectedEntries.count == 1,
                          let entry = selectedEntries.first, canAccess(entry) else { return .ignored }
                    open(entry)
                    return .handled
                }
                .onKeyPress("n", phases: .down) { key in
                    guard key.modifiers == [.command, .shift], canManageHere else { return .ignored }
                    prepare(.create)
                    return .handled
                }
                .onKeyPress("a", phases: .down) { key in
                    // Select exactly what is on screen now: the filtered,
                    // sorted visible rows — never hidden entries.
                    guard key.modifiers == .command, !visible.isEmpty else { return .ignored }
                    selection = Set(visible.map(\.url))
                    return .handled
                }
                .onKeyPress("d", phases: .down) { key in
                    guard key.modifiers == .command, selectedEntries.count == 1,
                          let entry = selectedEntries.first, entry.openable, !entry.folder, canManageHere else { return .ignored }
                    transfer(entry, action: .duplicate)
                    return .handled
                }
                .onKeyPress("z", phases: .down) { key in
                    guard key.modifiers == .command, !latestTrashIDs.isEmpty, !hasPendingChanges else { return .ignored }
                    restore(restoreHistory.filter { latestTrashIDs.contains($0.id) })
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { key in
                    guard key.modifiers.isEmpty, selectedEntries.count == 1,
                          let entry = selectedEntries.first, canManage(entry) else { return .ignored }
                    prepare(.rename, [entry])
                    return .handled
                }
                .onKeyPress(.delete, phases: .down) { key in
                    // Command-Delete uses the same single confirmation for
                    // one item or the whole current selection; each row's
                    // guards still decide its own fate inside the batch.
                    guard key.modifiers == .command, !selectedEntries.isEmpty, canManageHere else { return .ignored }
                    prepare(.trash, selectedEntries)
                    return .handled
                }
            }
            Divider()
            HStack(spacing: 10) {
                if let dropImportStatus {
                    Text(verbatim: dropImportStatus)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if limited {
                    Text(t("仅显示扫描到的前 2,000 项", "Showing the first 2,000 scanned items"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !selectedEntries.isEmpty {
                    Text(t("已选 \(selectedEntries.count) 项", "\(selectedEntries.count) selected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu {
                        selectionActions(selectedEntries)
                    } label: {
                        Label(t("操作", "Actions"), systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .padding(8)
            .controlSize(.small)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard canWriteInDirectory else { return false }
            importDroppedFiles(providers)
            return true
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let session = editing {
            editorPane(session)
        } else if let entry = focusedEntry {
            if entry.openable {
                VStack(spacing: 0) {
                    previewToolbar(entry)
                    Divider()
                    MacWorkspaceQuickLook(url: entry.url)
                }
            } else if entry.folder {
                folderPane(entry)
            } else {
                ContentUnavailableView(t("无法预览此项目", "Can’t Preview This Item"), systemImage: "eye.slash")
            }
        } else {
            ContentUnavailableView {
                Label(t("选择文件以预览", "Select a File to Preview"), systemImage: "eye")
            } description: {
                Text(t("选中一个文件即可在此安全预览。", "Select a file to preview it here safely."))
            }
        }
    }

    private func folderPane(_ entry: MacWorkspaceFileEntry) -> some View {
        ContentUnavailableView {
            Label(displayTitle(entry), systemImage: "folder")
        } description: {
            Text(t("打开此文件夹以浏览其内容。", "Open this folder to browse its contents."))
        } actions: {
            Button(t("打开", "Open")) { open(entry) }
        }
    }

    @ViewBuilder private func previewToolbar(_ entry: MacWorkspaceFileEntry) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: entry.name).font(.headline).lineLimit(1)
            Spacer()
            previewActions(entry)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .controlSize(.small)
    }

    /// The preview action buttons (Open / Edit / quote / attach / Finder)
    /// shared verbatim by the wide/narrow preview toolbar and the inspector
    /// preview header.
    @ViewBuilder private func previewActions(_ entry: MacWorkspaceFileEntry) -> some View {
        if entry.openable {
            let acceptsText = isEditableText(entry)
            let webPage = MacWorkspaceHTMLSite.isPage(entry.url)
            let openTitle = webPage ? t("在内置浏览器中打开", "Open in Built-in Browser") : t("打开", "Open")
            Button { open(entry) } label: { Image(systemName: webPage ? "safari" : "arrow.up.forward.app") }
                .help(openTitle)
                .accessibilityLabel(openTitle)
                .accessibilityIdentifier("workspace.files.open")
            if acceptsText {
                Button { edit(entry) } label: { Image(systemName: "pencil") }
                    .help(t("编辑", "Edit"))
                    .accessibilityLabel(t("编辑", "Edit"))
                    .accessibilityIdentifier("workspace.files.edit")
            }
            if acceptsText {
                Button { quoteText(entry) } label: { Image(systemName: "text.quote") }
                    .help(t("引用到任务输入框", "Quote in Task"))
                    .accessibilityLabel(t("引用到任务输入框", "Quote in Task"))
                    .disabled(!canInsertInDraft || importingText)
            }
            Button {
                if effectiveAttachments.contains(entry.url) {
                    updateAttachments(effectiveAttachments.subtracting([entry.url]))
                } else {
                    updateAttachments(effectiveAttachments.union([entry.url]))
                }
            } label: {
                Image(systemName: effectiveAttachments.contains(entry.url) ? "paperclip.fill" : "paperclip")
            }
            .help(effectiveAttachments.contains(entry.url) ? t("从附件移除", "Remove Attachment") : t("添加为附件", "Add as Attachment"))
            .accessibilityLabel(effectiveAttachments.contains(entry.url) ? t("从附件移除", "Remove Attachment") : t("添加为附件", "Add as Attachment"))
            .accessibilityIdentifier("workspace.files.attach")
            .disabled(!canInsertInDraft)
            Button {
                if canAccess(entry, allowLink: true) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            } label: { Image(systemName: "folder") }
            .help(t("在 Finder 中显示", "Show in Finder"))
            .accessibilityLabel(t("在 Finder 中显示", "Show in Finder"))
        }
    }

    @ViewBuilder private func editorPane(_ session: MacWorkspaceTextEditSession) -> some View {
        VStack(spacing: 0) {
            editorBar(session, showsBack: false)
            Divider()
            editorBody(session)
        }
    }

    /// Editor header row shared by the wide/narrow editor pane and the
    /// inspector editor page. `showsBack` prepends the inspector Back
    /// navigation; the name, dirty marker and every action (Save, Save a
    /// Copy, Reload, Done with the unsaved-changes guard) are unchanged.
    @ViewBuilder private func editorBar(_ session: MacWorkspaceTextEditSession, showsBack: Bool) -> some View {
        HStack(spacing: 10) {
            if showsBack {
                inspectorBackButton()
            }
            Text(verbatim: session.entry.name).font(.headline).lineLimit(1)
            if session.dirty {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer()
            Button { saveEdits() } label: { Image(systemName: "square.and.arrow.down") }
                .help(t("保存", "Save"))
                .accessibilityLabel(t("保存", "Save"))
                .accessibilityIdentifier("workspace.files.save")
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!session.dirty || session.saving)
            Button { saveEditsAsCopy() } label: { Image(systemName: "doc.on.doc") }
                .help(t("另存副本", "Save a Copy"))
                .accessibilityLabel(t("另存副本", "Save a Copy"))
                .accessibilityIdentifier("workspace.files.saveCopy")
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!session.dirty || session.saving)
            Button { reloadEdits() } label: { Image(systemName: "arrow.clockwise") }
                .help(t("重新加载", "Reload From Disk"))
                .accessibilityLabel(t("重新加载", "Reload From Disk"))
                .disabled(session.saving)
            Button { closeEdits() } label: { Image(systemName: "xmark") }
                .help(t("完成", "Done"))
                .accessibilityLabel(t("完成", "Done"))
                .keyboardShortcut(.cancelAction)
                .disabled(session.saving)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .controlSize(.small)
    }

    /// Text editor surface and status footer shared by all layouts.
    @ViewBuilder private func editorBody(_ session: MacWorkspaceTextEditSession) -> some View {
        TextEditor(text: editorBinding)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .accessibilityIdentifier("workspace.files.editor")
        Divider()
        HStack(spacing: 8) {
            Text(byteCountLabel(session.text))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Label(sessionStatus(session), systemImage: sessionStatusIcon(session))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var editorBinding: Binding<String> {
        Binding(get: { editing?.text ?? "" }, set: { newValue in
            guard canChangeFiles() else { return }
            editing?.text = newValue
            onPendingChanges?(hasPendingChanges)
        })
    }

    private var hasPendingChanges: Bool {
        editing?.dirty == true || editing?.saving == true || fileImportsInProgress > 0 || mutationInProgress
    }

    private func byteCountLabel(_ text: String) -> String {
        let bytes = text.utf8.count
        let limit = 32 * 1024
        return "\(bytes.formatted()) / \(limit.formatted()) B"
    }

    private func sessionStatus(_ session: MacWorkspaceTextEditSession) -> String {
        if session.saving { return t("保存中…", "Saving…") }
        return session.dirty ? t("有未保存的更改", "Unsaved Changes") : t("已保存", "Saved")
    }

    private func sessionStatusIcon(_ session: MacWorkspaceTextEditSession) -> String {
        if session.saving { return "ellipsis.circle" }
        return session.dirty ? "pencil.circle" : "checkmark.circle"
    }

    // MARK: - Entries & selection

    /// What the user reads in the list: the ownership label when the host
    /// provided one (known conversation title for a per-task folder of the
    /// default conversations root), otherwise the real on-disk name.
    private func displayTitle(_ entry: MacWorkspaceFileEntry) -> String {
        entry.displayName ?? entry.name
    }

    private var visible: [MacWorkspaceFileEntry] {
        entries.filter {
            filter.isEmpty
                || $0.name.localizedStandardContains(filter)
                || displayTitle($0).localizedStandardContains(filter)
        }
    }

    private var selectedEntries: [MacWorkspaceFileEntry] {
        visible.filter { selection.contains($0.url) }
    }

    private var focusedEntry: MacWorkspaceFileEntry? {
        guard let focused else { return nil }
        return entries.first { $0.url == focused }
    }

    private func isEditableText(_ entry: MacWorkspaceFileEntry) -> Bool {
        entry.openable && WorkspaceTextPolicy.isTextualPath(entry.name) && canAccess(entry)
    }

    // MARK: - Row & selection actions

    @ViewBuilder private func actions(for entry: MacWorkspaceFileEntry) -> some View {
        if entry.folder || entry.openable {
            Button(t("打开", "Open")) { open(entry) }
        }
        if entry.openable {
            let acceptsText = isEditableText(entry)
            Button(t("快速查看", "Quick Look")) { focusPreview(of: entry) }
            if acceptsText {
                Button(t("编辑", "Edit")) { edit(entry) }
            }
            Button("mac.external.openWith") {
                guard canAccess(entry) else { return }
                MacExternalFileOpening.chooseApplication(for: entry.url, isCurrent: { canAccess(entry) })
            }
            .accessibilityIdentifier("workspace.files.openWith")
            if acceptsText {
                Button(t("引用到任务输入框", "Quote in Task")) { quoteText(entry) }
                    .disabled(!canInsertInDraft || importingText)
            }
            if canInsertInDraft {
                if effectiveAttachments.contains(entry.url) {
                    Button(t("从附件移除", "Remove Attachment")) {
                        updateAttachments(effectiveAttachments.subtracting([entry.url]))
                    }
                } else {
                    Button(t("添加为附件", "Add as Attachment")) {
                        updateAttachments(effectiveAttachments.union([entry.url]))
                    }
                }
            }
        }
        if (entry.folder || isEditableText(entry)), let application = MacExternalFileOpening.codeApplication {
            Button("mac.external.openInCode") {
                if canAccess(entry) { MacExternalFileOpening.open(entry.url, in: application) }
            }
            .accessibilityIdentifier("workspace.files.openInCode")
        }
        mutationItems(entry)
        Button(t("在 Finder 中显示", "Show in Finder")) {
            if canAccess(entry, allowLink: true) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        }
    }

    @ViewBuilder private func selectionActions(_ selected: [MacWorkspaceFileEntry]) -> some View {
        if selected.count == 1, let entry = selected.first {
            actions(for: entry)
        } else {
            batchTrashItem(selected)
            let files = selected.filter { $0.openable }
            if !files.isEmpty {
                Button(t("打开 \(files.count) 项", "Open \(files.count) Items")) {
                    for entry in files { open(entry) }
                }
            }
            if !files.isEmpty && canInsertInDraft {
                Button(t("添加为附件", "Add as Attachments")) {
                    updateAttachments(effectiveAttachments.union(files.map(\.url)))
                }
            }
            Button(t("在 Finder 中显示", "Show in Finder")) {
                let urls = selected.filter { canAccess($0, allowLink: true) }.map(\.url)
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
        }
    }

    // MARK: - User-initiated file management

    private var canManageHere: Bool {
        guard canWriteInDirectory, !hasPendingChanges, let root, let directory else { return false }
        let managed = managedConversationsRoot ?? fixedRootURL
        return managed?.resolvingSymlinksInPath().standardizedFileURL != directory.resolvingSymlinksInPath().standardizedFileURL
            && MacWorkspaceFolderSnapshot.containsPhysicalDirectory(directory, in: root)
    }

    private func canManage(_ entry: MacWorkspaceFileEntry) -> Bool {
        canManageHere && (entry.openable || entry.folder) && canAccess(entry)
            && MacWorkspaceFileOperations.canMove(entry.url, protecting: effectiveAttachments,
                    managedConversationsRoot: managedConversationsRoot ?? fixedRootURL)
    }

    @ViewBuilder private func mutationItems(_ entry: MacWorkspaceFileEntry) -> some View {
        Button(mutationTitle(.rename), systemImage: "pencil") { prepare(.rename, [entry]) }
            .disabled(!canManage(entry))
        if entry.folder || entry.openable {
            Button(t("移到文件夹…", "Move to Folder…"), systemImage: "folder") { transfer(entry, action: .move) }
                .accessibilityIdentifier("workspace.files.move")
                .disabled(!canManage(entry))
        }
        if entry.openable && !entry.folder {
            Button(t("制作副本", "Duplicate"), systemImage: "plus.square.on.square") { transfer(entry, action: .duplicate) }
                .accessibilityIdentifier("workspace.files.duplicate")
                .disabled(!canManageHere || !canAccess(entry))
        }
        Button(mutationTitle(.trash), systemImage: "trash", role: .destructive) { prepare(.trash, [entry]) }
            .disabled(!canManage(entry))
    }

    /// Batch trash for a multi-selection: one confirmation, per-item guards.
    @ViewBuilder private func batchTrashItem(_ entries: [MacWorkspaceFileEntry]) -> some View {
        let candidates = entries.filter { $0.folder || $0.openable }
        if !candidates.isEmpty {
            Button(t("移到废纸篓（\(candidates.count) 项）", "Move to Trash (\(candidates.count))"),
                   systemImage: "trash", role: .destructive) { prepare(.trash, candidates) }
                .accessibilityIdentifier("workspace.files.batchTrash")
                .disabled(!canManageHere)
        }
    }

    private func mutationTitle(_ action: FileMutationRequest.Action) -> String {
        switch action {
        case .create: t("新建文件夹", "New Folder")
        case .rename: t("重命名", "Rename")
        case .trash: t("移到废纸篓", "Move to Trash")
        }
    }

    /// One confirmation for single and batch trash alike. A single item is
    /// named; a batch states its count and lists the first few names so the
    /// destructive scope is explicit before anything is pinned again.
    private func trashConfirmationText(_ items: [MacWorkspaceFileOperations.Item]) -> String? {
        guard let first = items.first else { return nil }
        guard items.count > 1 else { return first.name }
        let listed = items.prefix(3).map(\.name).joined(separator: "、")
        let more = items.count > 3 ? t(" 等", ", …") : ""
        return t("所选 \(items.count) 项：\(listed)\(more)", "\(items.count) selected: \(listed)\(more)")
    }

    private enum TransferAction { case move, duplicate }

    private func transfer(_ entry: MacWorkspaceFileEntry, action: TransferAction) {
        guard canManageHere, canAccess(entry), let root, let directory else { return }
        let managed = managedConversationsRoot ?? fixedRootURL
        do {
            let source = try MacWorkspaceFileOperations(root: root, directory: directory, managedConversationsRoot: managed)
            let item = try source.capture(entry.name)
            let destination: MacWorkspaceFileOperations?
            switch action {
            case .move:
                guard checkDraftFiles(entry.url) else { return }
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = false
                panel.allowsMultipleSelection = false
                panel.resolvesAliases = false
                panel.directoryURL = directory
                panel.message = t("在当前工作区内选择目标文件夹。", "Choose a destination folder in this workspace.")
                panel.prompt = t("移到这里", "Move Here")
                guard panel.runModal() == .OK, let folder = panel.url else { return }
                guard canManageHere, self.root == root, self.directory == directory, checkDraftFiles(entry.url) else { return }
                guard MacWorkspaceFolderSnapshot.containsPhysicalDirectory(folder, in: root) else {
                    mutationError = t("请选择当前工作区内的文件夹。", "Choose a folder inside this workspace.")
                    return
                }
                destination = try MacWorkspaceFileOperations(root: root, directory: folder, managedConversationsRoot: managed)
                guard destination?.directoryIdentity != source.directoryIdentity else {
                    mutationError = t("项目已经在此文件夹中。", "This item is already in that folder.")
                    return
                }
            case .duplicate:
                guard entry.openable, !entry.folder else { return }
                destination = nil
            }
            let protected = effectiveAttachments.union(protectedDraftFiles())
            let suffix = t("副本", "copy")
            mutationInProgress = true
            Task {
                defer { mutationInProgress = false; reloadID = UUID() }
                do {
                    let copiedName = try await Task.detached(priority: .userInitiated) { () -> String? in
                        if let destination {
                            try source.move(item, to: destination, protecting: protected, managedConversationsRoot: managed)
                            return nil
                        }
                        return try source.duplicate(item, suffix: suffix)
                    }.value
                    guard self.root == root, self.directory == directory else { return }
                    if let copiedName {
                        dropImportStatus = t("已创建“\(copiedName)”", "Created “\(copiedName)”")
                        selection = [directory.appendingPathComponent(copiedName)]
                    } else {
                        selection.remove(entry.url)
                        if focused == entry.url { focused = nil }
                        if editing?.entry.url == entry.url { editing = nil }
                        if let destination {
                            dropImportStatus = t("已移到“\(destination.directory.lastPathComponent)”", "Moved to “\(destination.directory.lastPathComponent)”")
                        }
                    }
                } catch { reportMutationFailure(error) }
            }
        } catch { reportMutationFailure(error) }
    }

    private func checkDraftFiles(_ url: URL) -> Bool {
        let protected = effectiveAttachments.union(protectedDraftFiles())
        guard MacWorkspaceFileOperations.canMove(url, protecting: protected, managedConversationsRoot: managedConversationsRoot ?? fixedRootURL) else {
            mutationError = t("此项目属于会话，或仍有附件在草稿中使用。", "This item belongs to a conversation or contains an attachment used by a draft.")
            return false
        }
        return true
    }

    private func prepare(_ action: FileMutationRequest.Action, _ entries: [MacWorkspaceFileEntry] = []) {
        guard canManageHere, let root, let directory else { return }
        do {
            let managed = managedConversationsRoot ?? fixedRootURL
            let ops = try MacWorkspaceFileOperations(root: root, directory: directory, managedConversationsRoot: managed)
            var targets: [MacWorkspaceFileOperations.Item] = []
            switch action {
            case .create:
                break
            case .rename:
                guard entries.count == 1, let entry = entries.first,
                      canManage(entry), checkDraftFiles(entry.url) else { return }
                targets = [try ops.capture(entry.url.lastPathComponent)]
            case .trash:
                guard !entries.isEmpty else { return }
                // Batch trash mirrors iPad: every selected row joins one
                // confirmed run. Per-item guards (attachments, drafts,
                // managed roots, pinned identity) decide each fate inside the
                // operation and are reported per survivor; rows that cannot
                // be pinned at all are carried as skipped failures so nothing
                // the user selected disappears without an explanation.
                var skipped: [MacWorkspaceFileOperations.TrashBatchFailure] = []
                for entry in entries where entry.folder || entry.openable {
                    guard canAccess(entry) else {
                        skipped.append(.init(name: entry.name, kind: .denied))
                        continue
                    }
                    do {
                        targets.append(try ops.capture(entry.url.lastPathComponent))
                    } catch let error as NSError {
                        let missing = (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
                            || (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileNoSuchFile.rawValue)
                        skipped.append(.init(name: entry.name, kind: missing ? .missing : .denied))
                    }
                }
                guard !targets.isEmpty || !skipped.isEmpty else { return }
                let request = FileMutationRequest(action: action, root: root, operations: ops,
                                                  items: targets, skipped: skipped)
                if targets.isEmpty { applyTrashOutcome(request, outcome: .init()) }
                else { mutationRequest = request }
                return
            }
            mutationRequest = FileMutationRequest(action: action, root: root, operations: ops,
                                                  items: targets, skipped: [])
        } catch { reportMutationFailure(error) }
    }

    private func perform(_ request: FileMutationRequest, name: String) {
        guard canManageHere, request.root == root,
              request.operations.directory.resolvingSymlinksInPath().standardizedFileURL.path == directory?.resolvingSymlinksInPath().standardizedFileURL.path else { return }
        if request.action == .rename, let item = request.items.first {
            let url = request.operations.directory.appendingPathComponent(item.name)
            guard checkDraftFiles(url) else { return }
        }
        mutationInProgress = true
        let history = recentlyDeletedDirectory
        let protected = effectiveAttachments.union(protectedDraftFiles())
        let managed = managedConversationsRoot ?? fixedRootURL
        Task {
            defer { mutationInProgress = false; reloadID = UUID() }
            do {
                switch request.action {
                case .create:
                    try await Task.detached(priority: .userInitiated) {
                        try request.operations.createFolder(name)
                    }.value
                    latestTrashIDs = []
                case .rename:
                    guard let item = request.items.first else { throw CocoaError(.fileNoSuchFile) }
                    try await Task.detached(priority: .userInitiated) {
                        try request.operations.rename(item, to: name)
                    }.value
                    latestTrashIDs = []
                case .trash:
                    let outcome = try await Task.detached(priority: .userInitiated) {
                        request.operations.trashBatch(request.items, protecting: protected,
                                                      managedConversationsRoot: managed, recordingIn: history)
                    }.value
                    applyTrashOutcome(request, outcome: outcome)
                }
            } catch { reportMutationFailure(error) }
        }
    }

    /// Batch-trash bookkeeping shared by the confirmed run: survivors stay
    /// selected with their reasons, successful items leave focus/selection/
    /// the editor, and every verified receipt becomes immediately put-back-
    /// able (menu, ⌘Z and Recently Deleted alike). The moved count comes from
    /// the batch itself, not from receipts, so restricted-Trash Macs still
    /// report honestly while the Finder-only fallback stays distinguishable
    /// from a real failure.
    @MainActor private func applyTrashOutcome(_ request: FileMutationRequest,
                                              outcome: MacWorkspaceFileOperations.TrashBatchOutcome) {
        var failures = outcome.failures
        failures.append(contentsOf: request.skipped)
        restoreHistory.append(contentsOf: outcome.receipts)
        if !outcome.moved.isEmpty { latestTrashIDs = Set(outcome.receipts.map(\.id)) }
        let movedPaths = Set(outcome.moved.map {
            request.operations.directory.appendingPathComponent($0).standardizedFileURL.path
        })
        if let focused, movedPaths.contains(focused.standardizedFileURL.path) { self.focused = nil }
        if let editing, movedPaths.contains(editing.entry.url.standardizedFileURL.path) { self.editing = nil }
        selection = selection.filter { !movedPaths.contains($0.standardizedFileURL.path) }
        if !failures.isEmpty {
            let detail = failures.prefix(3).map { "“\($0.name)”：\(trashFailureReason($0.kind))" }
                .joined(separator: "\n")
            mutationError = t("已移到废纸篓 \(outcome.moved.count) 项，\(failures.count) 项未能完成。",
                              "Moved \(outcome.moved.count) item(s) to the Trash; \(failures.count) could not be completed.")
                + "\n" + detail
        } else if outcome.moved.count == request.items.count, outcome.receipts.isEmpty, !request.items.isEmpty {
            // The system Trash accepted every item but no receipt could be
            // verified on this Mac; point at Finder instead of a put-back.
            trashOriginalDirectory = request.operations.directory
            trashFinderDirectory = try? FileManager.default.url(
                for: .trashDirectory, in: .userDomainMask,
                appropriateFor: request.operations.directory, create: false
            )
            showTrashFinderNotice = true
        }
    }

    private func trashFailureReason(_ kind: MacWorkspaceFileOperations.TrashFailureKind) -> String {
        switch kind {
        case .protected:
            t("此项目属于会话，或仍有附件在草稿中使用。", "This item belongs to a conversation or contains an attachment used by a draft.")
        case .changed:
            t("项目已更改或已被替换，请刷新后重试。", "The item changed or was replaced. Refresh and try again.")
        case .missing:
            t("项目已不在原位置。", "The item is no longer in its original location.")
        case .denied:
            t("请确认文件夹可写，并且项目仍在原处。", "Check that the folder is writable and the item is still in its original location.")
        }
    }

    private func restore(_ receipt: MacWorkspaceFileOperations.TrashReceipt) {
        restore([receipt])
    }

    private func restore(_ receipts: [MacWorkspaceFileOperations.TrashReceipt]) {
        guard canChangeFiles(), !hasPendingChanges, !receipts.isEmpty else { return }
        mutationInProgress = true
        Task {
            defer { mutationInProgress = false; reloadID = UUID() }
            var failures: [String] = []
            for receipt in receipts {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try MacWorkspaceFileOperations.restore(receipt)
                    }.value
                    restoreHistory.removeAll { $0.id == receipt.id }
                    latestTrashIDs.remove(receipt.id)
                } catch {
                    failures.append("“\(receipt.item.name)”：\(restoreFailureReason(error))")
                }
            }
            if !failures.isEmpty {
                mutationError = t("已恢复 \(receipts.count - failures.count) 项，\(failures.count) 项未能完成。",
                                  "Restored \(receipts.count - failures.count) item(s); \(failures.count) could not be completed.")
                    + "\n" + failures.prefix(3).joined(separator: "\n")
            }
        }
    }

    private var recentlyDeletedSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("最近删除", "Recently Deleted")).font(.headline)
                Spacer()
                let restorable = recentDeletions.filter { !unavailableDeletions.contains($0.id) }
                let allSelected = !restorable.isEmpty && deletionSelection == Set(restorable.map(\.id))
                if !restorable.isEmpty {
                    Button(allSelected ? t("取消全选", "Deselect All") : t("全选", "Select All")) {
                        deletionSelection = allSelected ? [] : Set(restorable.map(\.id))
                    }
                    .accessibilityIdentifier("workspace.files.trash.selectAll")
                }
                Button { reloadID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(t("刷新", "Refresh"))
                    .disabled(loadingDeletions || mutationInProgress)
                Button(t("完成", "Done")) { showRecentlyDeleted = false }
                    .keyboardShortcut(.cancelAction)
            }
            if loadingDeletions {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if deletionLoadFailed {
                ContentUnavailableView(t("无法读取最近删除", "Couldn’t Read Recently Deleted"),
                                       systemImage: "exclamationmark.triangle")
            } else if recentDeletions.isEmpty {
                ContentUnavailableView(t("没有最近删除的项目", "No Recently Deleted Items"), systemImage: "trash")
            } else {
                List(recentDeletions, selection: $deletionSelection) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: record.name).lineLimit(1)
                            let folder = record.subdirectory.isEmpty ? root?.lastPathComponent ?? "" : record.subdirectory
                            Text(verbatim: folder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        Spacer()
                        if unavailableDeletions.contains(record.id) {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(t("请在 Finder 中查看，或连接原磁盘。", "Check in Finder or reconnect the original disk."))
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(t("在 Finder 中查看", "Show in Finder")) {
                                    if let item = record.finderTrashItemURL {
                                        NSWorkspace.shared.activateFileViewerSelecting([item])
                                    } else {
                                        openTrashInFinder(directory: nil)
                                    }
                                }
                                Button(t("打开原文件夹", "Open Original Folder")) {
                                    openOriginalFolder(for: record)
                                }
                            }
                        } else {
                            Button(t("放回", "Put Back")) { putBack(record) }
                                .disabled(!canChangeFiles() || hasPendingChanges)
                                .accessibilityIdentifier("workspace.files.putBack")
                        }
                    }
                    .tag(record.id)
                }
                HStack(spacing: 10) {
                    let selected = recentDeletions.filter { deletionSelection.contains($0.id) && !unavailableDeletions.contains($0.id) }
                    Button(t("放回所选（\(selected.count) 项）", "Put Back Selected (\(selected.count))")) {
                        putBackSelected(selected)
                    }
                    .disabled(selected.isEmpty || !canChangeFiles() || hasPendingChanges || mutationInProgress)
                    .accessibilityIdentifier("workspace.files.putBackSelected")
                    Spacer()
                    if !selected.isEmpty {
                        Text(t("已选 \(selected.count) 项", "\(selected.count) selected"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 260)
        .task(id: reloadID) { await loadDeletedItems() }
        .alert(t("未能完成", "Unable to Finish"), isPresented: Binding(
            get: { deletionNotice != nil }, set: { if !$0 { deletionNotice = nil } }
        )) {
            Button(t("好", "OK"), role: .cancel) { deletionNotice = nil }
        } message: {
            Text(verbatim: deletionNotice ?? "")
        }
    }

    @MainActor private func loadDeletedItems() async {
        guard let root, let history = recentlyDeletedDirectory else { return }
        loadingDeletions = true
        let managed = managedConversationsRoot ?? fixedRootURL
        do {
            let (entries, unavailable) = try await Task.detached(priority: .userInitiated) {
                var entries: [MacWorkspaceTrashRecord] = []
                var unavailable: Set<UUID> = []
                for record in try MacWorkspaceTrashRecord.entries(for: root, in: history) {
                    switch record.availability(root: root, history: history, managed: managed) {
                    case .available: entries.append(record)
                    case .unavailable:
                        // Keep interrupted/pre-move records as well: a later
                        // metadata save may have failed after the system move.
                        entries.append(record); unavailable.insert(record.id)
                    case .removed: MacWorkspaceTrashRecord.forget(record.id, in: history)
                    }
                }
                return (entries, unavailable)
            }.value
            guard !Task.isCancelled, self.root == root else { return }
            deletionLoadFailed = false
            recentDeletions = entries
            unavailableDeletions = unavailable
            let live = Set(entries.map(\.id))
            restoreHistory.removeAll { !live.contains($0.id) }
            // Never keep a selection on a row that vanished or became
            // unverifiable while the sheet was closed.
            deletionSelection.formIntersection(live.subtracting(unavailable))
        } catch {
            guard !Task.isCancelled, self.root == root else { return }
            deletionLoadFailed = true
        }
        loadingDeletions = false
    }

    /// Batch put-back mirrors iPad: every selected record goes through the
    /// same availability-checked restore as a single put-back; one failure
    /// never blocks the rest, survivors stay selected, and the notice names
    /// the count plus the first reasons.
    private func putBackSelected(_ records: [MacWorkspaceTrashRecord]) {
        guard let root, let history = recentlyDeletedDirectory, canChangeFiles(), !hasPendingChanges,
              !records.isEmpty else { return }
        let managed = managedConversationsRoot ?? fixedRootURL
        mutationInProgress = true
        Task {
            defer { mutationInProgress = false; reloadID = UUID() }
            var failures: [(id: UUID, name: String, reason: String)] = []
            for record in records {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try record.restore(root: root, history: history, managed: managed)
                    }.value
                    restoreHistory.removeAll { $0.id == record.id }
                    latestTrashIDs.remove(record.id)
                } catch {
                    failures.append((record.id, record.name, restoreFailureReason(error)))
                }
            }
            deletionSelection = Set(failures.map(\.id))
            if !failures.isEmpty {
                let restoredCount = records.count - failures.count
                let detail = failures.prefix(3).map { "“\($0.name)”：\($0.reason)" }.joined(separator: "\n")
                deletionNotice = t("已恢复 \(restoredCount) 项，\(failures.count) 项未能完成。",
                                   "Restored \(restoredCount) item(s); \(failures.count) could not be completed.")
                    + "\n" + detail
            }
        }
    }

    private func restoreFailureReason(_ error: Error) -> String {
        if let failure = error as? MacWorkspaceTrashRecord.HistoryError {
            switch failure {
            case .removed: return t("该项目已离开废纸篓。", "This item is no longer in the Trash.")
            case .unavailable: return t("请连接原磁盘，并确认原文件夹和废纸篓可访问。", "Connect the original disk and check access to the folder and Trash.")
            }
        }
        return t("请确认文件夹可写，并且项目仍在废纸篓中。", "Check that the folder is writable and the item is still in the Trash.")
    }

    private func putBack(_ record: MacWorkspaceTrashRecord) {
        guard let root, let history = recentlyDeletedDirectory, canChangeFiles(), !hasPendingChanges else { return }
        let managed = managedConversationsRoot ?? fixedRootURL
        mutationInProgress = true
        Task {
            defer { mutationInProgress = false; reloadID = UUID() }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try record.restore(root: root, history: history, managed: managed)
                }.value
                restoreHistory.removeAll { $0.id == record.id }
                latestTrashIDs.remove(record.id)
            } catch {
                showRecentlyDeleted = false
                reportMutationFailure(error)
            }
        }
    }

    private func openTrashInFinder(directory: URL?) {
        let volumeBin = root.flatMap { try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                                     appropriateFor: $0, create: false) }
        let bin = directory ?? volumeBin ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
        _ = NSWorkspace.shared.open(bin)
    }

    private func openOriginalFolder(for record: MacWorkspaceTrashRecord) {
        guard let root else { return }
        let directory = record.subdirectory.isEmpty ? root : root.appendingPathComponent(record.subdirectory, isDirectory: true)
        guard let operations = try? MacWorkspaceFileOperations(root: root, directory: directory,
                                                                 managedConversationsRoot: managedConversationsRoot ?? fixedRootURL)
        else { return }
        _ = NSWorkspace.shared.open(operations.directory)
    }

    private func reportMutationFailure(_ error: Error) {
        if let failure = error as? MacWorkspaceTrashRecord.HistoryError {
            switch failure {
            case .removed:
                mutationError = t("该项目已离开废纸篓。", "This item is no longer in the Trash.")
            case .unavailable:
                mutationError = t("请连接原磁盘，并确认原文件夹和废纸篓可访问。", "Connect the original disk and check access to the folder and Trash.")
            }
            return
        }
        let ns = error as NSError
        if (ns.domain == NSPOSIXErrorDomain && ns.code == Int(EEXIST)) || (ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteFileExists.rawValue) {
            mutationError = t("名称已被使用，或所选项目已更改。请刷新后重试。", "The name is in use or the selected item changed. Refresh and try again.")
        } else {
            mutationError = t("请确认文件夹可写，并且项目仍在原处。", "Check that the folder is writable and the item is still in its original location.")
        }
    }

    // MARK: - Root folder

    /// The root is host-fixed (project bookmark or default directory): the
    /// user cannot close or change it, and the choice is never persisted.
    private var rootIsFixed: Bool { fixedRootBookmark != nil || fixedRootURL != nil || fixedPrivateWorkspace != nil }

    /// Reveals the current root folder in Finder. The root is either
    /// host-verified (fixed) or was picked through the guarded panel, so this
    /// only ever exposes a directory the surface already browses.
    private func revealRootInFinder() {
        guard let root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    private func chooseFolder() {
        guard !rootIsFixed, !hasPendingChanges else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            guard !hasPendingChanges else { return }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            setRoot(resolved)
            onFolderPicked?(resolved)
        }
    }

    private func setRoot(_ resolved: URL, remember: Bool = true) {
        root = resolved
        if remember && !rootIsFixed && remembersRoot {
            savedRootBookmark = try? resolved.bookmarkData(options: [],
                                                           includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        if taskAttachmentURLs == nil {
            let kept = attachments.filter { MacWorkspaceFolderSnapshot.canReference($0, in: resolved) }
            if kept.count != attachments.count { updateAttachments(Set(kept)) }
        }
        if let session = editing, !MacWorkspaceFolderSnapshot.canReference(session.entry.url, in: resolved) {
            editing = nil
        }
        navigate(to: resolved)
    }

    private func restoreSavedRoot() async {
        // A task inspector without a usable per-task root stays empty: the
        // remembered ad-hoc folder must never load or stage here. Space's
        // custom selection restores through this same bookmark branch, so
        // the guard keys on the task mode only.
        defer { restoringRoot = false }
        guard !Task.isCancelled, !requiresTaskRoot, root == nil else { return }
        let fixed = rootIsFixed
        let privateWorkspace = fixedPrivateWorkspace
        let leaseBase = privateTaskRootBase
        let fixedURL = fixedRootURL
        #if FLOE_MAC_HOST_SMOKE
        let bookmark = fixedRootBookmark
        #else
        let bookmark = fixedRootBookmark ?? (remembersRoot && !fixed ? savedRootBookmark : nil)
        #endif
        guard fixed || bookmark != nil else { return }

        let worker = Task.detached(priority: .userInitiated) { () -> (url: URL, updatedBookmark: Data?)? in
            guard !Task.isCancelled else { return nil }
            var stale = false
            let url: URL
            if let privateWorkspace {
                guard let root = try? MacAgentWorkspaceTools.resolvePrivateTaskRoot(privateWorkspace, base: leaseBase) else { return nil }
                url = root
            } else if let fixedURL {
                url = fixedURL
            } else {
                guard let bookmark,
                      let root = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                          relativeTo: nil, bookmarkDataIsStale: &stale),
                      !fixed || !stale else { return nil }
                url = root
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            // Foundation can spell a pinned /private/var directory as /var.
            // Compare its physical path with the already verified task root.
            guard privateWorkspace == nil || MacAgentWorkspacePinSupport.physicalPath(resolved.path) == url.path,
                  FileManager.default.isReadableFile(atPath: resolved.path),
                  (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                return nil
            }
            let refreshed = stale && !fixed ? try? resolved.bookmarkData() : nil
            return (resolved, refreshed)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, root == nil else { return }
        if let result {
            if let updatedBookmark = result.updatedBookmark, savedRootBookmark == bookmark {
                savedRootBookmark = updatedBookmark
            }
            setRoot(result.url, remember: false)
        } else if !fixed, savedRootBookmark == bookmark {
            savedRootBookmark = nil
        }
    }

    private func clearFolder() {
        guard !hasPendingChanges else { return }
        root = nil
        directory = nil
        entries = []
        selection = []
        focused = nil
        editing = nil
        // The composer owns an injected attachment set; clearing the folder
        // must not propose wiping it.
        if taskAttachmentURLs == nil { updateAttachments([]) }
        savedRootBookmark = nil
    }

    private func navigate(to url: URL) {
        directory = url
        selection = []
        focused = nil
        filter = ""
        dropImportStatus = nil
        entries = []
        reloadID = UUID()
    }

    private func goUp() {
        guard let root, let directory, directory != root else { return }
        navigate(to: directory.deletingLastPathComponent())
    }

    // MARK: - Files & attachments

    private func open(_ entry: MacWorkspaceFileEntry) {
        guard canAccess(entry) else { return }
        if entry.folder { navigate(to: entry.url) }
        else if entry.openable {
            if MacWorkspaceHTMLSite.isPage(entry.url), let root {
                do {
                    htmlSite = try MacWorkspaceHTMLSite(page: entry.url, workspace: root)
                    onArtifact?(.previewed(entry.url))
                } catch { showScopeAlert = true }
            } else if NSWorkspace.shared.open(entry.url) {
                onArtifact?(.opened(entry.url))
            }
        }
    }

    private func focusPreview(of entry: MacWorkspaceFileEntry) {
        guard entry.openable, canAccess(entry) else { return }
        focused = entry.url
        onArtifact?(.previewed(entry.url))
    }

    private func updateAttachments(_ urls: Set<URL>) {
        guard taskAttachmentURLs == nil || canInsertInDraft else { return }
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        if taskAttachmentURLs == nil {
            attachments = urls
        }
        // With an injected composer set this only proposes the candidate set;
        // the host applies it and re-injects the authoritative list.
        onAttachmentsChanged?(sorted)
    }

    /// The attachment set shown by badges/menus: the injected composer set
    /// when present, otherwise the locally tracked set.
    private var effectiveAttachments: Set<URL> {
        taskAttachmentURLs ?? attachments
    }

    /// Choosing files only accepts regular files that stay inside the granted
    /// root; anything else is rejected with a scope alert.
    private func chooseFiles() {
        guard canInsertInDraft, let root else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = directory
        guard panel.runModal() == .OK else { return }
        let accepted = panel.urls.filter { MacWorkspaceFolderSnapshot.canReference($0, in: root) }
        guard !accepted.isEmpty else {
            showScopeAlert = true
            return
        }
        updateAttachments(effectiveAttachments.union(accepted))
    }

    private var canWriteInDirectory: Bool {
        guard canChangeFiles(), let root, let directory else { return false }
        return MacWorkspaceFolderSnapshot.containsPhysicalDirectory(directory, in: root)
            && FileManager.default.isWritableFile(atPath: directory.path)
    }

    /// Dragging files in from Finder copies them into the current directory.
    /// Sources are validated (regular file, not a credential path) and the
    /// destination is created through the same pinned-directory descriptor
    /// discipline as text saves, with `O_EXCL` so nothing is overwritten.
    private func importDroppedFiles(_ providers: [NSItemProvider]) {
        guard canWriteInDirectory, let root, let directory else { return }
        fileImportsInProgress += 1
        dropImportStatus = nil
        onPendingChanges?(true)
        Task {
            defer {
                fileImportsInProgress -= 1
                onPendingChanges?(hasPendingChanges)
            }
            var imported = 0
            for provider in providers {
                guard let source = await loadDroppedURL(provider) else { continue }
                let resolved = source.resolvingSymlinksInPath().standardizedFileURL
                let copied = await Task.detached(priority: .userInitiated) {
                    Result { try MacWorkspaceFolderSnapshot.importFile(resolved, into: directory, in: root) }
                }.value
                if case .success = copied { imported += 1 }
            }
            guard self.root == root, self.directory == directory else { return }
            if imported > 0 { reloadID = UUID() }
            let failedCount = providers.count - imported
            if failedCount == 0 {
                dropImportStatus = t("已导入 \(imported) 项", "Imported \(imported) items")
            } else if imported == 0 {
                dropImportStatus = t("无法导入所选文件", "Couldn’t import the selected files")
            } else {
                dropImportStatus = t("已导入 \(imported) 项，\(failedCount) 项失败",
                                     "Imported \(imported) items. \(failedCount) failed.")
            }
        }
    }

    private func loadDroppedURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: object as? URL)
            }
        }
    }

    // MARK: - Text quoting

    private func quoteText(_ entry: MacWorkspaceFileEntry) {
        guard canInsertInDraft, !importingText, let root, isEditableText(entry) else { return }
        importingText = true
        Task {
            defer { importingText = false }
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try MacWorkspaceFolderSnapshot.readPlainText(entry.url, in: root)
                }.value
                guard self.root == root, canAccess(entry) else { return }
                let name = entry.name.components(separatedBy: .newlines).joined(separator: " ")
                let quote = text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
                insertInDraft("\(name)\n\n\(quote)")
            } catch { showTextImportError = true }
        }
    }

    // MARK: - Lightweight editing

    private func edit(_ entry: MacWorkspaceFileEntry) {
        guard isEditableText(entry), let root, let directory else { return }
        focused = entry.url
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try MacWorkspaceFolderSnapshot.readEditableText(entry.url, in: root)
                }.value
                guard self.root == root, self.directory == directory, focused == entry.url, canAccess(entry) else { return }
                editing = MacWorkspaceTextEditSession(entry: entry, text: loaded.text,
                                                      savedText: loaded.text, baseline: loaded.identity)
            } catch {
                showTextImportError = true
            }
        }
    }

    /// Command-S: atomically replaces the open file's contents in place. Any
    /// external modification or path replacement since the file was opened is
    /// a conflict: the original stays on disk and the session keeps the
    /// user's text.
    private func saveEdits() {
        guard canChangeFiles(), let session = editing, session.dirty, !session.saving,
              let root else { return }
        editing?.saving = true
        let text = session.text
        let entryURL = session.entry.url
        let fileName = entryURL.lastPathComponent
        let fileDirectory = entryURL.deletingLastPathComponent()
        let baseline = session.baseline
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MacWorkspaceFolderSnapshot.saveEditInPlace(
                    text, fileName: fileName, in: fileDirectory, root: root, expected: baseline) }
            }.value
            self.reloadID = UUID()
            guard self.editing?.entry.url == entryURL else { return }
            switch result {
            case .success(let identity):
                if var session = self.editing {
                    session.savedText = text
                    session.baseline = identity
                    session.saving = false
                    self.editing = session
                }
            case .failure(let error as MacWorkspaceFileEditError) where error == .conflict:
                // Disk revision untouched (or restored); keep the user's text.
                self.editing?.saving = false
                self.showConflict = true
            case .failure:
                self.editing?.saving = false
                self.showSaveError = true
            }
        }
    }

    /// "Save a Copy": publishes the edited text under a new, previously
    /// non-existing name in the current folder and switches the editor to
    /// that file; the file that was opened is left untouched.
    private func saveEditsAsCopy() {
        guard canChangeFiles(), let session = editing, session.dirty, !session.saving,
              let directory, let root else { return }
        editing?.saving = true
        let text = session.text
        let baseName = session.entry.name
        let entryURL = session.entry.url
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MacWorkspaceFolderSnapshot.saveEditCopy(text, in: directory, root: root, baseName: baseName) }
            }.value
            self.reloadID = UUID()
            guard self.editing?.entry.url == entryURL else { return }
            switch result {
            case .success(let saved):
                // The editor now tracks the published copy; the original file
                // on disk is untouched.
                let newURL = directory.appendingPathComponent(saved.name)
                let newEntry = MacWorkspaceFileEntry(url: newURL, name: saved.name, folder: false, openable: true)
                self.focused = newURL
                self.selection = [newURL]
                self.editing = MacWorkspaceTextEditSession(entry: newEntry, text: text,
                                                           savedText: text, baseline: saved.identity)
            case .failure(let error as MacWorkspaceFileEditError) where error == .conflict:
                self.editing?.saving = false
                self.showConflict = true
            case .failure:
                self.editing?.saving = false
                self.showSaveError = true
            }
        }
    }

    private func reloadEdits() {
        guard let session = editing, let root else { return }
        let entry = session.entry
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try MacWorkspaceFolderSnapshot.readEditableText(entry.url, in: root)
                }.value
                guard self.editing?.entry.url == entry.url else { return }
                editing = MacWorkspaceTextEditSession(entry: entry, text: loaded.text,
                                                      savedText: loaded.text, baseline: loaded.identity)
            } catch {
                editing = nil
                showSaveError = true
            }
        }
    }

    private func closeEdits() {
        if editing?.dirty == true { showDiscard = true } else { editing = nil }
    }

    // MARK: - Access & loading (unchanged guards)

    private func canAccess(_ entry: MacWorkspaceFileEntry, allowLink: Bool = false) -> Bool {
        guard let root, let directory, entry.url.deletingLastPathComponent().path == directory.path,
              MacWorkspaceFolderSnapshot.contains(directory, in: root),
              directory.resolvingSymlinksInPath().path == directory.path else { return false }
        if allowLink { return true }
        let freshURL = URL(fileURLWithPath: entry.url.path, isDirectory: entry.folder)
        guard let values = try? freshURL.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey,
                                                                 .isDirectoryKey, .isPackageKey, .isRegularFileKey]),
              values.isAliasFile == false, values.isSymbolicLink == false,
              freshURL.resolvingSymlinksInPath().path == freshURL.path else { return false }
        return entry.folder ? values.isDirectory == true && values.isPackage != true : values.isRegularFile == true
    }

    private func loadDirectory() async {
        guard let root, let directory else { return }
        loading = true
        failed = false
        let labels = rootFolderLabels
        let worker = Task.detached(priority: .userInitiated) {
            try MacWorkspaceFolderSnapshot.read(directory, in: root, ownershipLabels: labels)
        }
        let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
        guard !Task.isCancelled, self.directory == directory else { return }
        switch result {
        case .success(let snapshot):
            entries = snapshot.entries
            limited = snapshot.limited
        case .failure:
            entries = []
            limited = false
            failed = true
        }
        loading = false
    }

    private func t(_ chinese: String, _ english: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? chinese : english
    }
}

// MARK: - Editing session

private struct MacWorkspaceTextEditSession {
    let entry: MacWorkspaceFileEntry
    var text: String
    var savedText: String
    var baseline: MacWorkspaceFileIdentity
    var saving = false

    var dirty: Bool { text != savedText }
}

private enum MacWorkspaceFileEditError: Error, Equatable {
    case tooLarge
    case conflict
    case vanished
    /// Another app holds a non-blocking-incompatible exclusive lock.
    case locked
    /// The filesystem cannot perform the required atomic exchange; the save
    /// fails closed (Save a Copy remains available).
    case unsupported
}

// MARK: - File entry

private struct MacWorkspaceFileEntry: Identifiable, Sendable {
    let url: URL
    /// Real basename on disk; every filesystem operation uses this or the URL.
    let name: String
    /// Ownership label (known conversation title) for per-task folders of the
    /// app-owned conversations root; display-only.
    var displayName: String? = nil
    let folder: Bool
    let openable: Bool
    var id: URL { url }
}

// MARK: - Folder snapshot, identity, and guarded I/O

private struct MacWorkspaceFileIdentity: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
    var changedSeconds: Int64
    var changedNanoseconds: Int64

    init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

private struct MacWorkspaceFolderSnapshot: Sendable {
    let entries: [MacWorkspaceFileEntry]
    let limited: Bool

    static let textLimit = 32 * 1024

    static func contains(_ directory: URL, in root: URL) -> Bool {
        directory.pathComponents.starts(with: root.pathComponents)
    }

    static func containsPhysicalDirectory(_ directory: URL, in root: URL) -> Bool {
        guard let physicalRoot = physicalPath(root.path), let physicalDirectory = physicalPath(directory.path) else {
            return false
        }
        return contains(URL(fileURLWithPath: physicalDirectory), in: URL(fileURLWithPath: physicalRoot))
    }

    /// Shared verified-open preamble: physical containment inside the root,
    /// the credential denylist, an `O_NOFOLLOW` regular-file descriptor, and
    /// `F_GETPATH` equivalence with the requested path. Returns the opened
    /// descriptor (caller closes it) and the canonical requested path.
    private static func openVerifiedRegularFile(_ url: URL, in root: URL) throws -> (Int32, String) {
        guard let rootPath = physicalPath(root.path), let requested = physicalPath(url.path),
              contains(URL(fileURLWithPath: requested), in: URL(fileURLWithPath: rootPath)),
              !BridgeAbsoluteFileRead.isSecretPath(requested) else { throw CocoaError(.fileReadNoPermission) }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        var info = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              fcntl(descriptor, F_GETPATH, &path) == 0, let openedPath = path.withUnsafeBufferPointer({ buffer in
                  buffer.baseAddress.flatMap { String(validatingCString: $0) }
              }),
              physicalPath(openedPath) == requested else {
            close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
        return (descriptor, requested)
    }

    /// Quote a bounded, nonempty text file through the same path as the editor.
    static func readPlainText(_ url: URL, in root: URL) throws -> String {
        let loaded = try readEditableText(url, in: root)
        guard !loaded.text.isEmpty else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return loaded.text
    }

    /// Loads editable text together with the on-disk revision identity used
    /// later for conflict rejection.
    static func readEditableText(_ url: URL, in root: URL) throws -> (text: String, identity: MacWorkspaceFileIdentity) {
        guard WorkspaceTextPolicy.isTextualPath(url.lastPathComponent) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let (descriptor, _) = try openVerifiedRegularFile(url, in: root)
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let limit = textLimit
        guard info.st_size <= limit else { throw MacWorkspaceFileEditError.tooLarge }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit, let text = WorkspaceTextPolicy.decodeUTF8(bytes) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return (text, MacWorkspaceFileIdentity(info))
    }

    /// Stages the edited text as a temp file inside the pinned directory
    /// (`openat`/`O_NOFOLLOW` per component), fsyncs it, then publishes it
    /// under a unique, previously non-existing name with an exclusive
    /// `renameatx_np(RENAME_EXCL)` (hard-link fallback), so the original file
    /// is never replaced and no existing file can be clobbered. The published
    /// copy is re-opened through the pinned descriptor with `O_NONBLOCK` and
    /// verified against the written bytes; any divergence is a conflict.
    /// Returns the published name and its on-disk identity.
    static func saveEditCopy(_ text: String, in directory: URL, root: URL,
                             baseName: String) throws -> (name: String, identity: MacWorkspaceFileIdentity) {
        let limit = textLimit
        guard let data = text.data(using: .utf8), data.count <= limit, !data.contains(0) else {
            throw MacWorkspaceFileEditError.tooLarge
        }
        let dirfd = try openPinnedDirectory(directory, in: root)
        defer { Darwin.close(dirfd) }

        // Stage an exclusive temp file inside the pinned directory.
        let tempName = ".floe-edit-\(UUID().uuidString).tmp"
        let fd = openat(dirfd, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let bytes = [UInt8](data)
        var offset = 0
        var writeFailed = false
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!, raw.count)
            }
            if written <= 0 { writeFailed = true; break }
            offset += written
        }
        let syncOK = !writeFailed && fsync(fd) == 0
        Darwin.close(fd)
        guard syncOK else {
            unlinkat(dirfd, tempName, 0)
            throw CocoaError(.fileWriteUnknown)
        }

        defer { unlinkat(dirfd, tempName, 0) }
        let name = try publishTemporaryCopy(tempName, baseName: baseName, directory: dirfd)

        let verifyFD = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard verifyFD >= 0 else { throw MacWorkspaceFileEditError.vanished }
        let verify = FileHandle(fileDescriptor: verifyFD, closeOnDealloc: true)
        var finalInfo = stat()
        guard fstat(verifyFD, &finalInfo) == 0, finalInfo.st_mode & S_IFMT == S_IFREG,
              finalInfo.st_size == data.count,
              try (verify.read(upToCount: limit + 1) ?? Data()) == data else {
            throw MacWorkspaceFileEditError.conflict
        }
        return (name, MacWorkspaceFileIdentity(finalInfo))
    }

    /// Atomically replaces the contents of the tracked file while keeping
    /// its name and parent directory, preserving the metadata (mode, ACLs,
    /// extended attributes) of the opened revision.
    ///
    /// Mirrors the proven `MacAgentWorkspaceReplaceTextTool` exchange. The
    /// revision the editor opened is re-opened `O_NOFOLLOW` through the
    /// pinned descriptor and locked `flock(LOCK_EX | LOCK_NB)`; its device/
    /// inode/size/timestamps must still equal the identity captured at open,
    /// otherwise the save is rejected as `.conflict` and the file is never
    /// touched. The edited bytes are staged as an exclusive temp file inside
    /// the pinned directory carrying the original's metadata
    /// (`fcopyfile(COPYFILE_METADATA)`), fsynced and verified. After
    /// re-validating the pinned parent and both names, the staged file and
    /// the tracked file are exchanged with `renameatx_np(RENAME_SWAP)` —
    /// never a plain rename, which could overwrite a distinct inode a
    /// concurrent editor swapped into the path. The displaced entry lands at
    /// the temp name and is validated against the original identity, and the
    /// still-open original descriptor is re-read, so both a path replacement
    /// and an in-place write inside the window are observed; either triggers
    /// a guarded swap-back that restores whatever occupied the path, and the
    /// save fails closed as `.conflict`. Filesystems without exchange support
    /// fail closed as `.unsupported` ("Save a Copy" remains available there).
    /// Only after every check does the displaced original get unlinked, and
    /// the published identity is returned.
    static func saveEditInPlace(_ text: String, fileName: String, in directory: URL, root: URL,
                                expected baseline: MacWorkspaceFileIdentity) throws -> MacWorkspaceFileIdentity {
        let limit = textLimit
        guard let data = text.data(using: .utf8), data.count <= limit, !data.contains(0) else {
            throw MacWorkspaceFileEditError.tooLarge
        }
        let dirfd = try openPinnedDirectory(directory, in: root)
        defer { Darwin.close(dirfd) }
        guard let directoryPath = physicalPath(directory.path) else {
            throw CocoaError(.fileReadNoPermission)
        }

        // 1) Open and exclusively lock the tracked revision; it must still be
        //    the revision the editor opened.
        let originalFD = openat(dirfd, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard originalFD >= 0 else {
            if errno == ENOENT { throw MacWorkspaceFileEditError.vanished }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { Darwin.close(originalFD) }
        guard flock(originalFD, LOCK_EX | LOCK_NB) == 0 else {
            throw MacWorkspaceFileEditError.locked
        }
        var originalInfo = stat()
        guard fstat(originalFD, &originalInfo) == 0, originalInfo.st_mode & S_IFMT == S_IFREG else {
            throw MacWorkspaceFileEditError.vanished
        }
        guard originalInfo.st_mode & (S_ISUID | S_ISGID) == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard MacWorkspaceFileIdentity(originalInfo) == baseline else {
            throw MacWorkspaceFileEditError.conflict
        }
        let originalBytes = try readAll(originalFD, limit: limit)

        // 2) Stage the edited bytes beside the original with its metadata.
        let tempName = ".floe-edit-\(UUID().uuidString).tmp"
        let stagedFD = openat(dirfd, tempName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard stagedFD >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var stagedInfo = stat()
        guard fstat(stagedFD, &stagedInfo) == 0 else {
            Darwin.close(stagedFD)
            unlinkat(dirfd, tempName, 0)
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            // Unlink only the inode we staged: after a successful exchange
            // this name holds the displaced original (removed explicitly
            // below), and after a failed or restored exchange it may hold a
            // concurrent writer's entry, which must be kept.
            if matches(stagedInfo, named: tempName, in: dirfd) {
                unlinkat(dirfd, tempName, 0)
            }
            Darwin.close(stagedFD)
        }
        guard fcopyfile(originalFD, stagedFD, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writeAll(stagedFD, bytes: [UInt8](data))
        guard fsync(stagedFD) == 0, try readAll(stagedFD, limit: limit) == data else {
            throw CocoaError(.fileWriteUnknown)
        }

        // 3) Re-validate the pinned parent, both names and the open revision
        //    immediately before the exchange.
        var heldParent = stat(), currentParent = stat()
        guard fstat(dirfd, &heldParent) == 0, stat(directoryPath, &currentParent) == 0,
              heldParent.st_dev == currentParent.st_dev, heldParent.st_ino == currentParent.st_ino,
              matches(originalInfo, named: fileName, in: dirfd),
              matches(stagedInfo, named: tempName, in: dirfd),
              try readAll(originalFD, limit: limit) == originalBytes else {
            throw MacWorkspaceFileEditError.conflict
        }

        // 4) Atomic exchange; fail closed when the filesystem cannot swap.
        guard renameatx_np(dirfd, tempName, dirfd, fileName, UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOTSUP || errno == EOPNOTSUPP { throw MacWorkspaceFileEditError.unsupported }
            throw CocoaError(.fileWriteNoPermission)
        }

        // 5) The target must now hold the staged inode and the temp name the
        //    original; anything else means a concurrent writer displaced the
        //    tracked revision, in which case the path is handed back.
        var displaced = stat()
        let foundDisplaced = fstatat(dirfd, tempName, &displaced, AT_SYMLINK_NOFOLLOW) == 0
        guard matches(stagedInfo, named: fileName, in: dirfd),
              matches(originalInfo, named: tempName, in: dirfd),
              (try? readAll(originalFD, limit: limit)) == originalBytes else {
            if foundDisplaced,
               matches(stagedInfo, named: fileName, in: dirfd),
               matches(displaced, named: tempName, in: dirfd),
               renameatx_np(dirfd, tempName, dirfd, fileName, UInt32(RENAME_SWAP)) == 0 {
                // The path again holds whatever displaced our revision; only
                // our staged bytes remain at the temp name, and the defer
                // above unlinks exactly those.
                throw MacWorkspaceFileEditError.conflict
            }
            throw MacWorkspaceFileEditError.conflict
        }

        // 6) Durability, then remove the displaced original — only while it
        //    is still the exact revision we opened — and report the new
        //    identity.
        guard fsync(dirfd) == 0,
              (try? readAll(stagedFD, limit: limit)) == data,
              matches(stagedInfo, named: fileName, in: dirfd) else {
            throw MacWorkspaceFileEditError.conflict
        }
        if matches(originalInfo, named: tempName, in: dirfd) {
            unlinkat(dirfd, tempName, 0)
        }
        var published = stat()
        guard fstatat(dirfd, fileName, &published, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw MacWorkspaceFileEditError.vanished
        }
        return MacWorkspaceFileIdentity(published)
    }

    /// Reads exactly the bytes of a regular-file descriptor, refusing to
    /// exceed `limit`. Offset-free (`pread`), so it stays correct when the
    /// descriptor is shared with verification reads.
    private static func readAll(_ descriptor: Int32, limit: Int) throws -> Data {
        var bytes: [UInt8] = []
        var offset: off_t = 0
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw in
                Darwin.pread(descriptor, raw.baseAddress!, raw.count, offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            bytes.append(contentsOf: chunk[0..<count])
            offset += off_t(count)
            guard bytes.count <= limit else { throw MacWorkspaceFileEditError.tooLarge }
        }
        return Data(bytes)
    }

    /// Writes every byte at the descriptor's start (offset-free `pwrite`).
    private static func writeAll(_ descriptor: Int32, bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { raw in
                Darwin.pwrite(descriptor, raw.baseAddress!, raw.count, off_t(offset))
            }
            if written <= 0 { throw CocoaError(.fileWriteUnknown) }
            offset += written
        }
    }

    /// Identity-plus-shape check for a name inside the pinned directory:
    /// same device/inode, exactly one link and still a regular file. The
    /// single-link requirement makes multi-link files fail closed instead of
    /// letting an exchange detach a shared inode.
    private static func matches(_ expected: stat, named name: String, in parent: Int32) -> Bool {
        var actual = stat()
        return fstatat(parent, name, &actual, AT_SYMLINK_NOFOLLOW) == 0
            && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
            && actual.st_nlink == 1 && actual.st_mode & S_IFMT == S_IFREG
    }

    private static func publishTemporaryCopy(_ tempName: String, baseName: String, directory: Int32) throws -> String {
        let base = (baseName as NSString).deletingPathExtension
        let ext = (baseName as NSString).pathExtension
        for attempt in 0..<100 {
            let name = attempt == 0 ? baseName
                : (ext.isEmpty ? "\(base) \(attempt + 1)" : "\(base) \(attempt + 1).\(ext)")
            if renameatx_np(directory, tempName, directory, name, UInt32(RENAME_EXCL)) == 0 {
                return name
            }
            if errno == EEXIST { continue }
            if errno == ENOTSUP {
                if linkat(directory, tempName, directory, name, 0) == 0 { return name }
                if errno == EEXIST { continue }
            }
            throw CocoaError(.fileWriteNoPermission)
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Copies `source` into `directory` (which must be contained in `root`)
    /// through the same pinned-directory descriptor as edit saves. The source
    /// is opened `O_NOFOLLOW` and its real opened path is checked with
    /// `F_GETPATH` against the credential denylist. Bytes are staged through
    /// an exclusive temporary file and published without overwriting.
    @discardableResult
    static func importFile(_ source: URL, into directory: URL, in root: URL) throws -> String {
        let dirfd = try openPinnedDirectory(directory, in: root)
        defer { Darwin.close(dirfd) }
        let srcFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard srcFD >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(srcFD) }
        var srcInfo = stat()
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(srcFD, &srcInfo) == 0, srcInfo.st_mode & S_IFMT == S_IFREG,
              fcntl(srcFD, F_GETPATH, &pathBuffer) == 0,
              let openedPath = pathBuffer.withUnsafeBufferPointer({ buffer in
                  buffer.baseAddress.flatMap { String(validatingCString: $0) }
              }),
              let physical = physicalPath(openedPath),
              !BridgeAbsoluteFileRead.isSecretPath(physical) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let tempName = ".floe-import-\(UUID().uuidString).tmp"
        let dstFD = openat(dirfd, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard dstFD >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer {
            Darwin.close(dstFD)
            unlinkat(dirfd, tempName, 0)
        }

        var copied: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            try Task.checkCancellation()
            let readCount = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(srcFD, raw.baseAddress!, raw.count)
            }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount >= 0 else { throw CocoaError(.fileReadUnknown) }
            if readCount == 0 { break }
            copied += Int64(readCount)
            guard copied <= srcInfo.st_size else { throw MacWorkspaceFileEditError.conflict }
            var writtenTotal = 0
            while writtenTotal < readCount {
                let written = buffer[writtenTotal..<readCount].withUnsafeBytes { raw in
                    Darwin.write(dstFD, raw.baseAddress!, raw.count)
                }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                writtenTotal += written
            }
        }
        var finalSource = stat()
        guard fstat(srcFD, &finalSource) == 0, copied == srcInfo.st_size,
              MacWorkspaceFileIdentity(finalSource) == MacWorkspaceFileIdentity(srcInfo) else {
            throw MacWorkspaceFileEditError.conflict
        }
        guard fchmod(dstFD, srcInfo.st_mode & 0o777) == 0, fsync(dstFD) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try publishTemporaryCopy(tempName, baseName: source.lastPathComponent, directory: dirfd)
    }

    /// Opens `directory` — which must be contained in `root` and free of
    /// symlinks itself — by walking each path component from `/` with
    /// `openat(O_DIRECTORY | O_NOFOLLOW)`, verifying the device/inode of the
    /// pinned descriptor against the canonical path at each boundary, so no
    /// component can be swapped for a link after verification. The caller
    /// owns the returned descriptor.
    private static func openPinnedDirectory(_ directory: URL, in root: URL) throws -> Int32 {
        guard let rootPath = physicalPath(root.path), let directoryPath = physicalPath(directory.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = Darwin.open("/", flags)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        for component in rootPath.split(separator: "/") {
            let child = openat(descriptor, String(component), flags)
            Darwin.close(descriptor)
            guard child >= 0 else { throw CocoaError(.fileReadNoPermission) }
            descriptor = child
        }
        var expectedRoot = stat(), pinnedRoot = stat()
        guard stat(rootPath, &expectedRoot) == 0, fstat(descriptor, &pinnedRoot) == 0,
              pinnedRoot.st_dev == expectedRoot.st_dev, pinnedRoot.st_ino == expectedRoot.st_ino else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
        let rootComponents = rootPath.split(separator: "/").map(String.init)
        let directoryComponents = directoryPath.split(separator: "/").map(String.init)
        guard directoryComponents.count >= rootComponents.count,
              Array(directoryComponents.prefix(rootComponents.count)) == rootComponents else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
        for component in directoryComponents.dropFirst(rootComponents.count) {
            let child = openat(descriptor, component, flags)
            Darwin.close(descriptor)
            guard child >= 0 else { throw CocoaError(.fileReadNoPermission) }
            descriptor = child
        }
        var expectedDirectory = stat(), pinnedDirectory = stat()
        guard stat(directoryPath, &expectedDirectory) == 0, fstat(descriptor, &pinnedDirectory) == 0,
              pinnedDirectory.st_dev == expectedDirectory.st_dev,
              pinnedDirectory.st_ino == expectedDirectory.st_ino else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
        return descriptor
    }

    static func identity(of url: URL, in root: URL) throws -> MacWorkspaceFileIdentity {
        let (descriptor, _) = try openVerifiedRegularFile(url, in: root)
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw MacWorkspaceFileEditError.vanished }
        return MacWorkspaceFileIdentity(info)
    }

    /// Attachment/drag-out eligibility: a regular file, no symlinks, inside
    /// the granted root, and not credential material.
    static func canReference(_ url: URL, in root: URL) -> Bool {
        guard let rootPath = physicalPath(root.path),
              let target = physicalPath(url.resolvingSymlinksInPath().standardizedFileURL.path),
              contains(URL(fileURLWithPath: target), in: URL(fileURLWithPath: rootPath)),
              !BridgeAbsoluteFileRead.isSecretPath(target) else { return false }
        guard let values = try? URL(fileURLWithPath: target).resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return true
    }

    private static func physicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingCString: resolved)
    }

    static func read(_ directory: URL, in root: URL, ownershipLabels: [String: String] = [:]) throws -> Self {
        guard containsPhysicalDirectory(directory, in: root),
              FileManager.default.isReadableFile(atPath: directory.path),
              try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadNoPermission)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
                                         .isRegularFileKey, .localizedNameKey]
        var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var entries: [MacWorkspaceFileEntry] = []
        var limited = false
        let showOwnership = !ownershipLabels.isEmpty && directory.standardizedFileURL == root.standardizedFileURL
        for (index, item) in enumerator.enumerated() {
            try Task.checkCancellation()
            guard index < 2_000 else { limited = true; break }
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: keys) else { continue }
            let real = values.isSymbolicLink == false && values.isAliasFile == false
            let isFolder = real && values.isDirectory == true && values.isPackage != true
            let name = values.localizedName ?? url.lastPathComponent
            // FileManager can return a different spelling of the same parent.
            // Keep immediate children under the directory the browser verified.
            let childURL = directory.appendingPathComponent(url.lastPathComponent, isDirectory: values.isDirectory == true)
            // Ownership labels apply only to the immediate folders of the
            // app-owned conversations root itself, never inside them. Keys
            // are real basenames (per-task UUIDs), not localized names.
            let ownership = showOwnership && isFolder ? ownershipLabels[url.lastPathComponent] : nil
            entries.append(MacWorkspaceFileEntry(url: childURL, name: name, displayName: ownership,
                                                 folder: isFolder,
                                                 openable: real && values.isRegularFile == true))
        }
        if let enumerationError { throw enumerationError }
        entries.sort {
            if $0.folder != $1.folder { return $0.folder }
            let left = $0.displayName ?? $0.name, right = $1.displayName ?? $1.name
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return Self(entries: entries, limited: limited)
    }
}

#if FLOE_MAC_HOST_SMOKE
// MARK: - Synthetic edit checks

/// Bounded, host-free checks for the workspace file editor. Every check
/// creates a unique temporary root under the system temporary directory,
/// exercises one save path through the same pinned-descriptor primitives the
/// view uses, and removes the fixture on return. Nothing outside the fixture
/// root is read or written, so the checks are safe to run from any smoke
/// host, including `FLOE_MAC_HOST_SMOKE` builds.
enum MacWorkspaceFileEditingSmoke {
    /// Runs the save, conflict and save-a-copy checks and returns one
    /// failure description per broken invariant; an empty array means every
    /// check passed. Purely synchronous; no window, device or network.
    static func runSyntheticChecks() -> [String] {
        var failures: [String] = []
        checkInPlaceSave(&failures)
        checkConflictPreservesOriginal(&failures)
        checkSaveCopy(&failures)
        checkSharedTextPolicy(&failures)
        return failures
    }

    private static func checkSharedTextPolicy(_ failures: inout [String]) {
        do {
            let root = try makeFixtureRoot("shared-text-policy")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("handoff.floetext")
            let original = Data("\u{FEFF}original\n".utf8)
            try original.write(to: file, options: .withoutOverwriting)
            let loaded = try MacWorkspaceFolderSnapshot.readEditableText(file, in: root)
            let quoted = try MacWorkspaceFolderSnapshot.readPlainText(file, in: root)
            guard Data(loaded.text.utf8) == original, quoted == loaded.text else {
                failures.append("shared-text-policy: the reader changed the UTF-8 text")
                return
            }
            let edited = loaded.text + "edited\n"
            _ = try MacWorkspaceFolderSnapshot.saveEditInPlace(edited, fileName: file.lastPathComponent,
                in: root, root: root, expected: loaded.identity)
            guard try Data(contentsOf: file) == Data(edited.utf8) else {
                failures.append("shared-text-policy: saving changed the UTF-8 byte order mark")
                return
            }
            let pdf = root.appendingPathComponent("document.pdf")
            try original.write(to: pdf, options: .withoutOverwriting)
            do {
                _ = try MacWorkspaceFolderSnapshot.readEditableText(pdf, in: root)
                failures.append("shared-text-policy: a PDF was accepted by the text editor")
            } catch let error as CocoaError where error.code == .fileReadInapplicableStringEncoding {
            }
        } catch {
            failures.append("shared-text-policy: \(error.localizedDescription)")
        }
    }

    private static func makeFixtureRoot(_ label: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-edit-smoke-\(label).XXXXXX", isDirectory: true)
        var template = Array(base.path.utf8CString)
        let root = template.withUnsafeMutableBufferPointer { buffer -> URL? in
            mkdtemp(buffer.baseAddress).map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }
        }
        guard let root else { throw CocoaError(.fileWriteUnknown) }
        return root
    }

    private static func permissions(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
            .flatMap { $0?.intValue } ?? -1
    }

    /// Command-S path: content lands at the same path, declared UNIX
    /// permissions survive, the new baseline matches a fresh read, and a
    /// save attempted against the stale baseline is rejected as a conflict
    /// without touching the file.
    private static func checkInPlaceSave(_ failures: inout [String]) {
        let label = "save"
        do {
            let root = try makeFixtureRoot(label)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("note.txt")
            try Data("hello\n".utf8).write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
            let loaded = try MacWorkspaceFolderSnapshot.readEditableText(file, in: root)
            guard loaded.text == "hello\n" else {
                failures.append("\(label): initial read returned \(loaded.text.debugDescription)")
                return
            }
            let identity = try MacWorkspaceFolderSnapshot.saveEditInPlace(
                "world\n", fileName: "note.txt", in: root, root: root, expected: loaded.identity)
            guard String(data: try Data(contentsOf: file), encoding: .utf8) == "world\n" else {
                failures.append("\(label): in-place save did not update the file contents")
                return
            }
            guard permissions(of: file) == 0o640 else {
                failures.append("\(label): declared permissions not preserved (got \(String(permissions(of: file), radix: 8)))")
                return
            }
            let reloaded = try MacWorkspaceFolderSnapshot.readEditableText(file, in: root)
            guard reloaded.text == "world\n", reloaded.identity == identity else {
                failures.append("\(label): post-save baseline does not match a fresh read")
                return
            }
            let residue = try FileManager.default.contentsOfDirectory(atPath: root.path)
            guard residue == ["note.txt"] else {
                failures.append("\(label): successful save left residue \(residue)")
                return
            }
            do {
                _ = try MacWorkspaceFolderSnapshot.saveEditInPlace(
                    "again\n", fileName: "note.txt", in: root, root: root, expected: loaded.identity)
                failures.append("\(label): stale baseline was accepted")
            } catch MacWorkspaceFileEditError.conflict {
                // Expected: the on-disk revision no longer matches.
            }
            guard String(data: try Data(contentsOf: file), encoding: .utf8) == "world\n" else {
                failures.append("\(label): rejected stale save still modified the file")
                return
            }
        } catch {
            failures.append("\(label): \(error.localizedDescription)")
        }
    }

    /// Both conflict shapes — an atomic replace (new inode) and an in-place
    /// append (same inode) — are rejected, leave the external content on
    /// disk, and the caller can still read the on-disk revision to reload.
    private static func checkConflictPreservesOriginal(_ failures: inout [String]) {
        // Path replacement: external writer swaps the file (new inode).
        do {
            let label = "conflict-replace"
            let root = try makeFixtureRoot(label)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("note.txt")
            try Data("v1\n".utf8).write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let loaded = try MacWorkspaceFolderSnapshot.readEditableText(file, in: root)
            try Data("v2\n".utf8).write(to: file, options: .atomic)
            do {
                _ = try MacWorkspaceFolderSnapshot.saveEditInPlace(
                    "mine\n", fileName: "note.txt", in: root, root: root, expected: loaded.identity)
                failures.append("\(label): save succeeded despite a replaced path")
            } catch MacWorkspaceFileEditError.conflict {
            } catch {
                failures.append("\(label): unexpected error \(error.localizedDescription)")
            }
            guard String(data: try Data(contentsOf: file), encoding: .utf8) == "v2\n" else {
                failures.append("\(label): external content was not preserved")
                return
            }
            let onDisk = try MacWorkspaceFolderSnapshot.readEditableText(file, in: root)
            guard onDisk.text == "v2\n" else {
                failures.append("\(label): on-disk revision is not readable for a reload")
                return
            }
        } catch {
            failures.append("conflict-replace: \(error.localizedDescription)")
        }
        // In-place external append: same inode, new mtime/size/ctime.
        do {
            let label = "conflict-append"
            let root = try makeFixtureRoot(label)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("note.txt")
            try Data("a\n".utf8).write(to: file, options: .withoutOverwriting)
            let loaded = try MacWorkspaceFolderSnapshot.readEditableText(file, in: root)
            let handle = try FileHandle(forWritingTo: file)
            handle.seekToEndOfFile()
            handle.write(Data("b\n".utf8))
            try handle.close()
            do {
                _ = try MacWorkspaceFolderSnapshot.saveEditInPlace(
                    "mine\n", fileName: "note.txt", in: root, root: root, expected: loaded.identity)
                failures.append("\(label): save succeeded despite an in-place external write")
            } catch MacWorkspaceFileEditError.conflict {
            } catch {
                failures.append("\(label): unexpected error \(error.localizedDescription)")
            }
            guard String(data: try Data(contentsOf: file), encoding: .utf8) == "a\nb\n" else {
                failures.append("\(label): in-place external write was overwritten")
                return
            }
        } catch {
            failures.append("conflict-append: \(error.localizedDescription)")
        }
    }

    /// Save a Copy keeps publishing under a fresh name without touching the
    /// opened file; the published copy carries the existing 0o600 staging
    /// mode (documented behavior of this action).
    private static func checkSaveCopy(_ failures: inout [String]) {
        let label = "copy"
        do {
            let root = try makeFixtureRoot(label)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("note.txt")
            try Data("original\n".utf8).write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            _ = try MacWorkspaceFolderSnapshot.readEditableText(file, in: root)
            let first = try MacWorkspaceFolderSnapshot.saveEditCopy(
                "edited\n", in: root, root: root, baseName: "note.txt")
            guard first.name != "note.txt" else {
                failures.append("\(label): copy was not published under a fresh name")
                return
            }
            let firstURL = URL(fileURLWithPath: root.path).appendingPathComponent(first.name)
            guard String(data: try Data(contentsOf: file), encoding: .utf8) == "original\n" else {
                failures.append("\(label): save-a-copy modified the opened file")
                return
            }
            guard String(data: try Data(contentsOf: firstURL), encoding: .utf8) == "edited\n",
                  permissions(of: firstURL) == 0o600 else {
                failures.append("\(label): published copy content or mode is wrong")
                return
            }
            let second = try MacWorkspaceFolderSnapshot.saveEditCopy(
                "edited again\n", in: root, root: root, baseName: "note.txt")
            guard second.name != first.name else {
                failures.append("\(label): second copy reused the first name")
                return
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            guard names.filter({ $0.hasPrefix("note") }).count == 3 else {
                failures.append("\(label): expected original plus two copies, got \(names)")
                return
            }
        } catch {
            failures.append("\(label): \(error.localizedDescription)")
        }
    }
}

#endif

struct MacWorkspaceQuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        if let view = QLPreviewView(frame: .zero, style: .normal) {
            container.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        (container.subviews.first as? QLPreviewView)?.previewItem = url as NSURL
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private struct FileActionSheet: View {
    let title: String
    let previousName: String
    let trashName: String?
    let confirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var name: String

    init(title: String, initial: String, trashName: String?, confirm: @escaping (String) -> Void) {
        self.title = title
        previousName = initial
        self.trashName = trashName
        self.confirm = confirm
        _name = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title).font(.headline)
            if let trashName {
                Text(verbatim: trashName).lineLimit(2)
            } else {
                TextField(MacPermissionsText.t("名称", "Name"), text: $name)
                    .focused($focused)
                    .accessibilityIdentifier("workspace.files.name")
            }
            HStack {
                Spacer()
                Button(MacPermissionsText.t("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(title, role: trashName == nil ? nil : .destructive) {
                    dismiss()
                    confirm(name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trashName == nil && (!MacWorkspaceFileOperations.validName(name) || name == previousName))
                .accessibilityIdentifier("workspace.files.confirmAction")
            }
        }
        .frame(width: 320)
        .padding(18)
        .onAppear { focused = trashName == nil }
    }
}
