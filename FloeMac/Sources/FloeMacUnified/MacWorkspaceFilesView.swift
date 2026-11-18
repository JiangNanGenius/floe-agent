// SPDX-License-Identifier: MPL-2.0

import AppKit
import Darwin
import FloeMacBridgeProtocol
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
}

/// Real Mac workspace files + preview surface.
///
/// One shared view backs both the full "Files" workspace column and the task
/// inspector sidebar; embed it in either location without any changes.
///
/// Optional wiring callbacks (all default to nil, so the existing
/// `MacWorkspaceFilesView(insertInDraft:canInsertInDraft:)` call site keeps
/// compiling unchanged):
/// - `onRootChanged`: fired whenever the user-granted root folder changes —
///   after the panel choice, after restoring the persisted bookmark on launch,
///   and with `nil` when the folder is cleared. Receives the resolved,
///   symlink-free root URL.
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
/// explicit control.
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
/// editing (UTF-8, at most 32 KB, no NUL bytes) never overwrites the original:
/// saving publishes an exclusive copy (`RENAME_EXCL` hard-link exchange inside
/// a pinned directory) and the editor switches to that new file, with bounded
/// read-back verification before the save is accepted.
struct MacWorkspaceFilesView: View {
    let insertInDraft: (String) -> Void
    var canInsertInDraft: Bool
    var remembersRoot: Bool = true
    /// When the host composer tracks staged file URLs for the active task it
    /// injects them here; while non-nil the UI reads this set verbatim and
    /// mutations only propose candidates through `onAttachmentsChanged`.
    var taskAttachmentURLs: Set<URL>? = nil
    var onRootChanged: ((URL?) -> Void)? = nil
    var onAttachmentsChanged: (([URL]) -> Void)? = nil
    var onArtifact: ((MacWorkspaceArtifactEvent) -> Void)? = nil
    var layout: MacWorkspaceFilesLayout = .adaptive

    @Environment(\.locale) private var locale
    @AppStorage("floe.mac.workspace.files.rootBookmark") private var savedRootBookmark: Data?
    @State private var root: URL?
    @State private var directory: URL?
    @State private var entries: [MacWorkspaceFileEntry] = []
    @State private var selection: Set<URL> = []
    @State private var focused: URL?
    @State private var filter = ""
    @State private var reloadID = UUID()
    @State private var loading = false
    @State private var limited = false
    @State private var failed = false
    @State private var attachments: Set<URL> = []
    @State private var editing: MacWorkspaceTextEditSession?
    @State private var importingText = false
    @State private var showTextImportError = false
    @State private var showSaveError = false
    @State private var showConflict = false
    @State private var showDiscard = false
    @State private var showScopeAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if directory == nil {
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
                ContentUnavailableView(t("无法读取此文件夹", "Couldn’t Read This Folder"), systemImage: "folder.badge.questionmark")
            } else {
                adaptiveContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: restoreSavedRoot)
        .task(id: reloadID) { await loadDirectory() }
        .onChange(of: selection) { _, newSelection in
            guard newSelection.count == 1, let url = newSelection.first,
                  let entry = entries.first(where: { $0.url == url }), entry.openable else { return }
            focused = url
            onArtifact?(.previewed(url))
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
        .alert(t("副本校验失败", "Copy Verification Failed"), isPresented: $showConflict) {
            Button(t("重新加载", "Reload")) { reloadEdits() }
            Button(t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(t("写入后回读的内容与保存内容不一致。请重新加载后重试。",
                   "What was read back after saving doesn’t match what was written. Reload and try again."))
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
                        if directory != nil {
                            Button(t("清除此文件夹", "Clear Folder"), role: .destructive, action: clearFolder)
                        }
                    }
                Spacer()
                if directory != nil {
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
                    Button(t("更换文件夹…", "Change Folder…"), action: chooseFolder)
                        .accessibilityIdentifier("workspace.files.changeFolder")
                    Button { chooseFiles() } label: {
                        Image(systemName: "doc.badge.plus")
                    }
                    .help(t("选择文件…", "Choose Files…"))
                    .accessibilityLabel(t("选择文件…", "Choose Files…"))
                    .accessibilityIdentifier("workspace.files.chooseFiles")
                    attachmentsMenu
                }
            }
            if let directory {
                Text(verbatim: directory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding()
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
        }
    }

    private var fileSidebar: some View {
        VStack(spacing: 0) {
            TextField(t("筛选当前文件夹", "Filter This Folder"), text: $filter)
                .textFieldStyle(.roundedBorder)
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
                                Label(entry.name, systemImage: entry.folder ? "folder" : "doc")
                                    .lineLimit(1)
                                    .tag(entry.url)
                                    .contextMenu { actions(for: entry) }
                                    .onDrag {
                                        NSItemProvider(item: entry.url as NSURL,
                                                       typeIdentifier: UTType.fileURL.identifier)
                                    }
                            } else {
                                Label(entry.name, systemImage: entry.folder ? "folder" : "doc")
                                    .lineLimit(1)
                                    .tag(entry.url)
                                    .contextMenu { actions(for: entry) }
                            }
                        }
                        .accessibilityIdentifier("workspace.files.row.\(entry.name)")
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                if limited {
                    Text(t("仅显示扫描到的前 2,000 项", "Showing the first 2,000 scanned items"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !selectedEntries.isEmpty {
                    selectionActions(selectedEntries)
                }
            }
            .padding(8)
            .controlSize(.small)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
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
            Label(entry.name, systemImage: "folder")
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
            if entry.openable {
                Button { open(entry) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help(t("打开", "Open"))
                    .accessibilityLabel(t("打开", "Open"))
                    .accessibilityIdentifier("workspace.files.open")
                if isEditableText(entry) {
                    Button { edit(entry) } label: { Image(systemName: "pencil") }
                        .help(t("编辑", "Edit"))
                        .accessibilityLabel(t("编辑", "Edit"))
                        .accessibilityIdentifier("workspace.files.edit")
                }
                if UTType(filenameExtension: entry.url.pathExtension)?.conforms(to: .text) == true {
                    Button { quoteText(entry) } label: { Image(systemName: "text.quote") }
                        .help(t("将文本插入新任务", "Insert Text in New Task"))
                        .accessibilityLabel(t("将文本插入新任务", "Insert Text in New Task"))
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
                .accessibilityIdentifier("workspace.files.attach")
            }
            Button {
                if canAccess(entry, allowLink: true) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            } label: { Image(systemName: "folder") }
            .help(t("在 Finder 中显示", "Show in Finder"))
            .accessibilityLabel(t("在 Finder 中显示", "Show in Finder"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .controlSize(.small)
    }

    @ViewBuilder private func editorPane(_ session: MacWorkspaceTextEditSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: session.entry.name).font(.headline).lineLimit(1)
                if session.dirty {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Spacer()
                Button { saveEdits() } label: { Image(systemName: "doc.on.doc") }
                    .help(t("另存副本", "Save a Copy"))
                    .accessibilityLabel(t("另存副本", "Save a Copy"))
                    .accessibilityIdentifier("workspace.files.save")
                    .keyboardShortcut("s", modifiers: .command)
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
            Divider()
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
    }

    private var editorBinding: Binding<String> {
        Binding(get: { editing?.text ?? "" }, set: { newValue in editing?.text = newValue })
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

    private var visible: [MacWorkspaceFileEntry] {
        entries.filter { filter.isEmpty || $0.name.localizedStandardContains(filter) }
    }

    private var selectedEntries: [MacWorkspaceFileEntry] {
        visible.filter { selection.contains($0.url) }
    }

    private var focusedEntry: MacWorkspaceFileEntry? {
        guard let focused else { return nil }
        return entries.first { $0.url == focused }
    }

    private func isEditableText(_ entry: MacWorkspaceFileEntry) -> Bool {
        guard entry.openable, canAccess(entry) else { return false }
        let ext = entry.url.pathExtension.lowercased()
        let textLike: Set<String> = ["txt", "text", "md", "markdown", "json", "csv", "log",
                                     "xml", "html", "htm", "css", "js", "ts", "swift", "py",
                                     "sh", "yml", "yaml", "toml", "ini", "conf"]
        return textLike.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .text) == true
    }

    // MARK: - Row & selection actions

    @ViewBuilder private func actions(for entry: MacWorkspaceFileEntry) -> some View {
        if entry.folder || entry.openable {
            Button(t("打开", "Open")) { open(entry) }
        }
        if entry.openable {
            Button(t("快速查看", "Quick Look")) { focusPreview(of: entry) }
            if isEditableText(entry) {
                Button(t("编辑", "Edit")) { edit(entry) }
            }
            if UTType(filenameExtension: entry.url.pathExtension)?.conforms(to: .text) == true {
                Button(t("将文本插入新任务", "Insert Text in New Task")) { quoteText(entry) }
                    .disabled(!canInsertInDraft || importingText)
            }
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
        Button(t("在 Finder 中显示", "Show in Finder")) {
            if canAccess(entry, allowLink: true) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        }
    }

    @ViewBuilder private func selectionActions(_ selected: [MacWorkspaceFileEntry]) -> some View {
        if selected.count == 1, let entry = selected.first {
            actions(for: entry)
        } else {
            let files = selected.filter { $0.openable }
            if !files.isEmpty {
                Button(t("打开 \(files.count) 项", "Open \(files.count) Items")) {
                    for entry in files { open(entry) }
                }
            }
            if !files.isEmpty {
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

    // MARK: - Root folder

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            setRoot(url.resolvingSymlinksInPath().standardizedFileURL)
        }
    }

    private func setRoot(_ resolved: URL) {
        root = resolved
        if remembersRoot {
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
        onRootChanged?(resolved)
    }

    private func restoreSavedRoot() {
#if FLOE_MAC_HOST_SMOKE
        return
#else
        guard remembersRoot, root == nil, let bookmark = savedRootBookmark else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.resolvingSymlinksInPath().path == resolved.path,
                  FileManager.default.isReadableFile(atPath: resolved.path),
                  (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                savedRootBookmark = nil
                return
            }
            if stale {
                savedRootBookmark = try? resolved.bookmarkData(options: [],
                                                               includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            setRoot(resolved)
        } catch {
            savedRootBookmark = nil
        }
#endif
    }

    private func clearFolder() {
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
        onRootChanged?(nil)
    }

    private func navigate(to url: URL) {
        directory = url
        selection = []
        focused = nil
        filter = ""
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
            NSWorkspace.shared.open(entry.url)
            onArtifact?(.opened(entry.url))
        }
    }

    private func focusPreview(of entry: MacWorkspaceFileEntry) {
        guard entry.openable, canAccess(entry) else { return }
        focused = entry.url
        onArtifact?(.previewed(entry.url))
    }

    private func updateAttachments(_ urls: Set<URL>) {
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
        guard let root else { return }
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
        guard let root, let directory else { return false }
        return MacWorkspaceFolderSnapshot.containsPhysicalDirectory(directory, in: root)
            && FileManager.default.isWritableFile(atPath: directory.path)
    }

    /// Dragging files in from Finder copies them into the current directory.
    /// Sources are validated (regular file, not a credential path) and the
    /// destination is created through the same pinned-directory descriptor
    /// discipline as text saves, with `O_EXCL` so nothing is overwritten.
    private func importDroppedFiles(_ providers: [NSItemProvider]) {
        guard canWriteInDirectory, let root, let directory else { return }
        Task {
            var imported = 0
            for provider in providers {
                guard let source = await loadDroppedURL(provider) else { continue }
                let resolved = source.resolvingSymlinksInPath().standardizedFileURL
                let copied = await Task.detached(priority: .userInitiated) {
                    Result { try MacWorkspaceFolderSnapshot.importFile(resolved, into: directory, in: root) }
                }.value
                if case .success = copied { imported += 1 }
            }
            if imported > 0 { reloadID = UUID() }
        }
    }

    private func loadDroppedURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: object as? URL)
            }
        }
    }

    // MARK: - Text quoting (unchanged behavior)

    private func quoteText(_ entry: MacWorkspaceFileEntry) {
        guard canInsertInDraft, !importingText, let root, canAccess(entry) else { return }
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
        guard isEditableText(entry), let root else { return }
        focused = entry.url
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try MacWorkspaceFolderSnapshot.readEditableText(entry.url, in: root)
                }.value
                guard self.root != nil, self.directory != nil else { return }
                editing = MacWorkspaceTextEditSession(entry: entry, text: loaded.text,
                                                      savedText: loaded.text, baseline: loaded.identity)
            } catch {
                showTextImportError = true
            }
        }
    }

    private func saveEdits() {
        guard let session = editing, session.dirty, !session.saving, let directory, let root else { return }
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
        let worker = Task.detached(priority: .userInitiated) { try MacWorkspaceFolderSnapshot.read(directory, in: root) }
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
}

// MARK: - File entry

private struct MacWorkspaceFileEntry: Identifiable, Sendable {
    let url: URL
    let name: String
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

    /// Original quoted-text reader; behavior is unchanged from the first
    /// version of this view (UTF-8, at most 32 KB, no NUL bytes).
    static func readPlainText(_ url: URL, in root: URL) throws -> String {
        let limit = textLimit
        guard let rootPath = physicalPath(root.path), let requested = physicalPath(url.path),
              contains(URL(fileURLWithPath: requested), in: URL(fileURLWithPath: rootPath)),
              !BridgeAbsoluteFileRead.isSecretPath(requested) else { throw CocoaError(.fileReadNoPermission) }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              fcntl(descriptor, F_GETPATH, &path) == 0, let openedPath = path.withUnsafeBufferPointer({ buffer in
                  buffer.baseAddress.flatMap { String(validatingCString: $0) }
              }),
              physicalPath(openedPath) == requested else {
            throw CocoaError(.fileReadNoPermission)
        }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= limit, !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    /// Loads editable text together with the on-disk revision identity used
    /// later for conflict rejection. Same guard set as `readPlainText`.
    static func readEditableText(_ url: URL, in root: URL) throws -> (text: String, identity: MacWorkspaceFileIdentity) {
        let (descriptor, _) = try openVerifiedRegularFile(url, in: root)
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let limit = textLimit
        guard info.st_size <= limit else { throw MacWorkspaceFileEditError.tooLarge }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit, !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
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

    static func read(_ directory: URL, in root: URL) throws -> Self {
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
        for (index, item) in enumerator.enumerated() {
            try Task.checkCancellation()
            guard index < 2_000 else { limited = true; break }
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: keys) else { continue }
            let real = values.isSymbolicLink == false && values.isAliasFile == false
            entries.append(MacWorkspaceFileEntry(url: url, name: values.localizedName ?? url.lastPathComponent,
                                                 folder: real && values.isDirectory == true && values.isPackage != true,
                                                 openable: real && values.isRegularFile == true))
        }
        if let enumerationError { throw enumerationError }
        entries.sort {
            if $0.folder != $1.folder { return $0.folder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Self(entries: entries, limited: limited)
    }
}

private struct MacWorkspaceQuickLook: NSViewRepresentable {
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
