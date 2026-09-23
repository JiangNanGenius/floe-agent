// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import Combine
import FloeDocuments
import FloeWorkspace

/// An IDE pins one workspace for its lifetime, including terminal ownership.
///
/// The code tab hosts two editor kernels and keeps both mounted:
///
/// * the native Swift/UIKit pane (`IDENativeTextPane`), the default for files
///   the typed router verifies as text/code, with its own multi-file buffer
///   strip, find/replace, conflict review and the same guarded save contract;
/// * the Web CodeBlitz workbench, kept as the explicit fallback for the
///   features it still owns. Its internal editor tabs also own PDF/Office
///   documents through a custom document component whose rectangle stream the
///   native surfaces overlay while it is visible.
///
/// In the native kernel PDF/Office use typed outer tabs instead (no overlay
/// floats over a hidden workbench) and the sidebar's file tree/search comes
/// from the native `FileTreeView`. Other routed documents
/// (CAD/image/media/Quick Look) keep their typed native tab in the strip.
/// Every open Office document still gets exactly one `OfficeFileSession`, so a
/// tab close can always offer save / discard / keep-copy against one working
/// copy.
struct WorkspaceIDEView: View {
    @ObservedObject var center: WorkspaceCenter
    let initialRelativePath: String?
    let onSaved: () -> Void
    @StateObject private var state: IDEWorkbenchState
    @StateObject private var tabs: IDEWorkspaceTabStore
    /// Native text/code kernel state (buffers + per-file editor UI).
    @State private var nativePane: IDENativeTextPaneModel
    private let workspaceID: UUID?
    private let workspaceName: String
    private let root: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// User choice of editing kernel, persisted. Native is the default for
    /// files the typed router verifies as text/code; the Web workbench stays
    /// mounted as the explicit fallback for everything it still owns
    /// (multicursor/folding, its explorer, any future language features).
    @AppStorage("workspace.ide.nativeTextEditor") private var usesNativeEditor = true
    @State private var showsCloseConfirmation = false
    @State private var nativeCloseRequest: String?
    /// A refused native open (budget full with every buffer dirty, or an
    /// invalid path) is surfaced with its bilingual recovery reason instead of
    /// dropping the tap; no draft is evicted to make room.
    @State private var nativeOpenRefusal: IDENativeTextOpenRefusal?
    @State private var pendingModeSwitch: IDENativeTextSurfaceMode?
    @State private var nativeInsertResult: String?
    @State private var terminalOwner: LocalTerminalOwner?
    @State private var showsTerminal = false
    @State private var runController: IDELanguageRunController?
    @State private var showsRunSheet = false
    @State private var showsRunTerminal = false
    @State private var pendingRunTerminal = false
    @State private var officeCloseRequest: OfficeCloseRequest?
    @State private var routingNotice: String?
    /// Integrated left sidebar (file tree or source control), replacing the
    /// modal sheet.
    @State private var sidebar: IDESidebarMode?
    /// Office session backing an internal CodeBlitz tab overlay, keyed by
    /// workspace-relative path. One session per open document, created on
    /// demand and released when its internal tab unmounts.
    @StateObject private var nativeDocs = IDENativeDocumentStore()
    /// An Office internal tab was closed with edits still in its session;
    /// the save/discard decision happens here because the tab is already gone.
    @State private var internalOfficeClose: String?
    @State private var forwardedInitialNativePath = false
    @State private var forwardedInitialNativeTextPath = false
    /// In-flight Office share snapshot. The owning tab session reclaims it on
    /// dismiss via `finishSaveCopy()`.
    @State private var officeShareSnapshot: DocumentExportSnapshot?
    @StateObject private var remoteOfficeCopy = RemoteFilePreviewCopy()

    private struct OfficeCloseRequest: Identifiable {
        let id: String
        let tab: IDEWorkspaceTab
    }

    init(initialRelativePath: String? = nil, center: WorkspaceCenter, onSaved: @escaping () -> Void = {}) {
        self.center = center; self.initialRelativePath = initialRelativePath; self.onSaved = onSaved
        self.workspaceID = center.currentWorkspace?.id
        self.workspaceName = center.currentWorkspace?.name ?? String(localized: "ide.workspace")
        self.root = center.currentRootURL
        let workbench = IDEWorkbenchState(files: center.fileService)
        _state = StateObject(wrappedValue: workbench)
        _tabs = StateObject(wrappedValue: IDEWorkspaceTabStore(initialRelativePath: initialRelativePath))
        _nativePane = State(wrappedValue: IDENativeTextPaneModel(workspace: workbench.nativeText))
    }

    private var editorMode: IDENativeTextSurfaceMode { usesNativeEditor ? .native : .web }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).padding(10)
                }
                if let routingNotice {
                    Label(routingNotice, systemImage: "arrowshape.turn.up.right")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.bar)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if root != nil {
                    HStack(spacing: 0) {
                        if let sidebar, sizeClass != .compact {
                            IDESidebar(
                                mode: sidebar,
                                center: center,
                                workspaceID: workspaceID,
                                workspaceName: workspaceName,
                                onClose: { self.sidebar = nil },
                                onOpenFile: { openRoutedPath($0) }
                            )
                            .frame(width: 320)
                            Divider()
                        }
                        VStack(spacing: 0) {
                            tabStrip
                            Divider()
                            content
                            if showsTerminal, let terminalOwner {
                                Divider()
                                LocalTerminalView(owner: terminalOwner, embedded: true)
                                    .frame(height: 280)
                                    .background(FloeTheme.readingSurface)
                                    .accessibilityIdentifier("workspace.ide.terminalPanel")
                            }
                        }
                    }
                    .overlay(alignment: .leading) {
                        if let sidebar, sizeClass == .compact {
                            IDESidebarDrawer(onDismiss: { self.sidebar = nil }) {
                                IDESidebar(
                                    mode: sidebar,
                                    center: center,
                                    workspaceID: workspaceID,
                                    workspaceName: workspaceName,
                                    onClose: { self.sidebar = nil },
                                    onOpenFile: { openRoutedPath($0) }
                                )
                            }
                        }
                    }
                } else { ContentUnavailableView("ide.workspace.unavailable", systemImage: "folder.badge.questionmark") }
            }
            .navigationTitle(workspaceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { requestCloseIDE() } label: {
                        Label("ide.close", systemImage: "chevron.down")
                    }.frame(minWidth: 44, minHeight: 44).disabled(state.saving)
                    .accessibilityIdentifier("workspace.ide.close")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { presentRun() } label: {
                        Label(IDELanguageRunText.t("运行", "Run"), systemImage: "play.fill")
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(state.activePath == nil || root == nil || center.currentWorkspace?.id != workspaceID)
                    .accessibilityIdentifier("workspace.ide.run")
                    Button { Task { if await saveAllSurfaces() { onSaved() } } } label: {
                        Label("ide.save.all", systemImage: "square.and.arrow.down")
                    }.disabled(!state.canSave).accessibilityIdentifier("workspace.ide.save").keyboardShortcut("s", modifiers: .command)
                    // Kernel switch: the native editor is the default for
                    // verified text/code files, and the Web workbench stays
                    // one tap away for the features it still owns. Both
                    // kernels keep their buffers, so switching loses nothing.
                    Button {
                        requestModeSwitch(to: editorMode.opposite)
                    } label: {
                        Label(
                            editorMode == .native
                                ? IDELanguageRunText.t("Web 编辑器", "Web editor")
                                : IDELanguageRunText.t("原生编辑器", "Native editor"),
                            systemImage: editorMode == .native ? "safari" : "chevron.left.forwardslash.chevron.right"
                        )
                    }
                    .disabled(root == nil)
                    .accessibilityIdentifier("workspace.ide.editorMode")
                    Button {
                        openActiveInRoutedSurface()
                    } label: { Label("ide.open.editor", systemImage: "doc.richtext") }
                    .disabled(tabs.activeTab == nil || root == nil)
                    .accessibilityIdentifier("workspace.ide.richEditor")
                    // Workspace file tree/search inside the native chrome so
                    // the native kernel keeps the explorer it needs.
                    Button {
                        sidebar = sidebar == .files ? nil : .files
                    } label: { Label(IDELanguageRunText.t("文件", "Files"), systemImage: "folder") }
                    .disabled(root == nil || workspaceID == nil)
                    .accessibilityIdentifier("workspace.ide.files")
                    // Common source-control entries (status, diff, stage,
                    // commit, branch) for the IDE's pinned workspace.
                    Button {
                        sidebar = sidebar == .sourceControl ? nil : .sourceControl
                    } label: { Label(IDELanguageRunText.t("源码管理", "Source control"), systemImage: "arrow.triangle.branch") }
                    .disabled(root == nil || workspaceID == nil)
                    .accessibilityIdentifier("workspace.ide.sourceControl")
                    Button {
                        toggleTerminal()
                    } label: { Label("ide.terminal", systemImage: "terminal") }
                    .disabled(root == nil || workspaceID == nil).accessibilityIdentifier("workspace.ide.terminal")
                }
                // The UI-test edit hooks live in the bottom bar on purpose:
                // the trailing group overflows on compact widths, and a hook
                // hidden inside the system overflow menu is not reachable by
                // the query the tests use. The bottom bar keeps both hooks on
                // screen for iPad and iPhone; they only exist under
                // `-ui-testing` and never ship in a normal launch.
                if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
                    ToolbarItemGroup(placement: .bottomBar) {
                        // Web insert hook (Monaco's hidden textarea cannot be
                        // reached by XCTest keystrokes). Native mode uses the
                        // native hook below instead.
                        Button("IDE-INSERT") {
                            Task {
                                guard let path = state.activePath else { return }
                                _ = await state.insertTextForTesting(path: path, text: "")
                            }
                        }.disabled(!state.ready || usesNativeEditor)
                        .accessibilityIdentifier("workspace.ide.insertTestText")
                        .accessibilityValue(state.lastInsertResult ?? "")
                        // Native insert hook: an emulated keystroke path would
                        // not reach a background test device reliably, so the
                        // marker is appended to the real native buffer and
                        // saved through the real save button exactly like
                        // typed text.
                        Button("IDE-NATIVE-INSERT") {
                            guard let buffer = state.nativeText.activeBuffer, buffer.isLoaded else {
                                nativeInsertResult = "no-buffer"
                                return
                            }
                            let payload = "saved-" + UUID().uuidString.prefix(8)
                            buffer.text += (buffer.text.hasSuffix("\n") ? "" : "\n") + payload + "\n"
                            nativeInsertResult = "inserted:\(payload)"
                        }
                        .disabled(!usesNativeEditor || !(state.nativeText.activeBuffer?.isLoaded ?? false))
                        .accessibilityIdentifier("workspace.ide.nativeInsertTestText")
                        .accessibilityValue(nativeInsertResult ?? "")
                    }
                }
            }
        }
        .interactiveDismissDisabled(state.dirty || state.saving || hasOfficeEdits || state.nativeText.hasDirty)
        .sheet(isPresented: $showsRunSheet, onDismiss: {
            if pendingRunTerminal {
                pendingRunTerminal = false
                showsRunTerminal = true
            }
        }) {
            if let runController { IDELanguageRunView(controller: runController, state: state) }
        }
        .sheet(isPresented: $showsRunTerminal) {
            if let runController { IDERunTerminalView(controller: runController) }
        }
        .sheet(item: $state.conflict) { review in
            TextConflictReviewView(conflict: review, onResolve: { content in
                await state.resolve(review, content: content)
                if state.conflict == nil && !state.dirty { onSaved() }
            }, onCancel: { state.conflict = nil }).id(review.id)
        }

        .sheet(item: $officeShareSnapshot, onDismiss: {
            // Only the session that produced this snapshot holds it; the
            // others no-op on their own export store.
            Task {
                for tab in tabs.tabs { await tab.officeSession?.finishSaveCopy() }
                for session in nativeDocs.all { await session.finishSaveCopy() }
            }
        }) { snapshot in
            OfficeDocumentShareSheet(url: snapshot.fileURL)
        }
        .confirmationDialog(
            IDELanguageRunText.t("关闭标签前处理修改？", "Handle changes before closing this tab?"),
            isPresented: Binding(get: { internalOfficeClose != nil }, set: { if !$0 { internalOfficeClose = nil } }),
            titleVisibility: .visible
        ) {
            if let path = internalOfficeClose {
                let session = nativeDocs.existing(path)
                if session?.readOnly == false {
                    Button(IDELanguageRunText.t("保存并关闭", "Save and close")) {
                        Task {
                            let saved = await session?.saveAndReturn() ?? false
                            if saved { await nativeDocs.release(path) }
                            internalOfficeClose = nil
                        }
                    }
                    Button(IDELanguageRunText.t("保留副本并关闭", "Keep a copy and close")) {
                        Task {
                            let kept = await session?.keepChangesAndReturn() ?? false
                            if kept { await nativeDocs.release(path) }
                            internalOfficeClose = nil
                        }
                    }
                }
                Button(IDELanguageRunText.t("放弃修改并关闭", "Discard and close"), role: .destructive) {
                    Task {
                        let discarded = await session?.discardAndReturn() ?? false
                        if discarded { await nativeDocs.release(path) }
                        internalOfficeClose = nil
                    }
                }
            }
        }
        .confirmationDialog("ide.unsaved", isPresented: $showsCloseConfirmation, titleVisibility: .visible) {
            Button("ide.save.close") { Task { if await saveAllSurfaces() { await finishClose() } } }
            Button("ide.discard.close", role: .destructive) { Task { await finishClose() } }
            Button("ide.continue", role: .cancel) {}
        }
        .confirmationDialog(
            IDELanguageRunText.t("关闭标签前处理修改？", "Handle changes before closing this tab?"),
            isPresented: Binding(get: { officeCloseRequest != nil }, set: { if !$0 { officeCloseRequest = nil } }),
            titleVisibility: .visible
        ) {
            if let request = officeCloseRequest {
                // A read-only preview cannot save; only an editable session is
                // offered Save. A failed save/discard never closes the tab.
                if request.tab.officeSession?.readOnly == false {
                    Button(IDELanguageRunText.t("保存并关闭", "Save and close")) {
                        Task {
                            let saved = await request.tab.officeSession?.saveAndReturn() ?? false
                            if saved { await tabs.close(request.id) }
                            officeCloseRequest = nil
                        }
                    }
                }
                Button(IDELanguageRunText.t("放弃修改并关闭", "Discard and close"), role: .destructive) {
                    Task {
                        let discarded = await request.tab.officeSession?.discardAndReturn() ?? false
                        if discarded { await tabs.close(request.id) }
                        officeCloseRequest = nil
                    }
                }
            }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { officeCloseRequest = nil }
        }
        .confirmationDialog(
            IDELanguageRunText.t("关闭标签前处理修改？", "Handle changes before closing this tab?"),
            isPresented: Binding(get: { nativeCloseRequest != nil }, set: { if !$0 { nativeCloseRequest = nil } }),
            titleVisibility: .visible
        ) {
            if let path = nativeCloseRequest {
                Button(IDELanguageRunText.t("保存并关闭", "Save and close")) {
                    Task {
                        // A failed save (including a conflict that opens the
                        // review sheet) never closes the tab.
                        if await state.nativeText.save(path) {
                            state.nativeText.close(path, force: true)
                        }
                        nativeCloseRequest = nil
                    }
                }
                .accessibilityIdentifier("workspace.ide.nativeTab.saveClose")
                Button(IDELanguageRunText.t("放弃修改并关闭", "Discard and close"), role: .destructive) {
                    state.nativeText.close(path, force: true)
                    nativeCloseRequest = nil
                }
                .accessibilityIdentifier("workspace.ide.nativeTab.discardClose")
            }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { nativeCloseRequest = nil }
        }
        .confirmationDialog(
            IDELanguageRunText.t("切换编辑器内核？", "Switch editor kernel?"),
            isPresented: Binding(get: { pendingModeSwitch != nil }, set: { if !$0 { pendingModeSwitch = nil } }),
            titleVisibility: .visible
        ) {
            if let target = pendingModeSwitch {
                Button(IDELanguageRunText.t("保存后切换", "Save and switch")) {
                    Task {
                        let saved = await state.saveAll()
                        pendingModeSwitch = nil
                        if saved {
                            applyModeSwitch(target)
                        } else {
                            // The unresolved buffer keeps its text and shows
                            // its conflict/save error; the switch waits.
                            showRoutingNotice(IDELanguageRunText.t(
                                "仍有未保存或待评审的修改",
                                "Changes are still unsaved or under review"
                            ))
                        }
                    }
                }
                .accessibilityIdentifier("workspace.ide.editorMode.saveSwitch")
                Button(IDELanguageRunText.t("保留修改并切换", "Keep changes and switch")) {
                    pendingModeSwitch = nil
                    // Both kernels keep their buffers; the dirty side stays
                    // dirty and its own save path (baseline + conflict
                    // review) still protects the file on disk.
                    applyModeSwitch(target)
                }
                .accessibilityIdentifier("workspace.ide.editorMode.keepSwitch")
            }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { pendingModeSwitch = nil }
        }
        .alert(
            IDELanguageRunText.t("无法打开新文件", "Cannot open another file"),
            isPresented: Binding(get: { nativeOpenRefusal != nil }, set: { if !$0 { nativeOpenRefusal = nil } }),
            presenting: nativeOpenRefusal
        ) { refusal in
            if case .bufferBudgetReached = refusal.reason {
                Button(IDELanguageRunText.t("全部保存", "Save all")) {
                    Task {
                        let report = await state.nativeText.saveAll()
                        // Conflicts keep their own review sheet; this notice
                        // only reports whether the budget is recoverable now.
                        showRoutingNotice(report.isClean
                            ? IDELanguageRunText.t(
                                "已保存全部缓冲区；可再次打开该文件。",
                                "All buffers saved; open the file again."
                            )
                            : IDELanguageRunText.t(
                                "仍有未保存或待评审的缓冲区；处理后重试。",
                                "Some buffers are still unsaved or under review; resolve them and retry."
                            ))
                    }
                }
                .accessibilityIdentifier("workspace.ide.nativeOpen.saveAll")
            }
            Button(IDELanguageRunText.t("好", "OK"), role: .cancel) {}
        } message: { refusal in
            Text(refusal.message)
        }
        .onChange(of: state.pendingNativePath) { _, value in
            guard let value else { return }
            openRoutedPath(value)
            state.pendingNativePath = nil
        }
        .onChange(of: state.nativeDocuments) { _, newValue in
            // An internal tab unmounted: settle its Office session. With
            // edits outstanding the save/discard decision is the user's;
            // a clean preview releases immediately.
            for path in nativeDocs.officePaths where newValue[path] == nil {
                settleInternalOfficeClose(path)
            }
        }
        .onChange(of: state.ready) { _, ready in
            guard ready, !forwardedInitialNativePath, let initialRelativePath else { return }
            switch WorkspaceTextPolicy.kind(forPath: initialRelativePath) {
            case .pdf, .office:
                // The internal Web document tab needs the workbench ready.
                guard editorMode == .web else { return }
                forwardedInitialNativePath = true
                Task { await state.openNativeDocument(initialRelativePath) }
            default:
                break
            }
        }
        .onChange(of: state.nativeText.activePath) { _, _ in
            state.updateNativeActivePath(state.nativeText.activePath)
        }
        .task {
            // The kernel choice is known at appear time; open the initial
            // document in the kernel that owns it without waiting for the Web
            // workbench to report ready.
            state.setNativeEditorActive(editorMode == .native)
            guard let initialRelativePath else { return }
            openInitialPath(initialRelativePath)
        }
        .onDisappear {
            // A swipe-dismiss edge case must not strand an Office working copy.
            Task {
                await nativeDocs.releaseAll()
                await tabs.releaseAll()
            }
        }
    }

    // MARK: - Tab strip

    @ViewBuilder private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs.tabs) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .accessibilityIdentifier("workspace.ide.tabs")
    }

    @ViewBuilder private func tabButton(_ tab: IDEWorkspaceTab) -> some View {
        let active = tabs.activeTab?.id == tab.id
        HStack(spacing: 6) {
            Button {
                tabs.activate(tab.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tab.kind.systemImage)
                        .font(.caption)
                    Text(tab.kind == .code
                         ? IDELanguageRunText.t("代码", "Code")
                         : tab.title)
                        .lineLimit(1)
                    if let session = tab.officeSession {
                        // Observe the session so the unsaved dot follows an
                        // Office save/discard without waiting for a tab switch.
                        IDETabUnsavedBadge(session: session)
                    } else if tab.hasUnsavedChanges {
                        Circle().fill(FloeTheme.primary).frame(width: 6, height: 6)
                            .accessibilityLabel(IDELanguageRunText.t("有未保存的修改", "Unsaved changes"))
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(active ? FloeTheme.primary.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.ide.tab.\(tab.kind.rawValue)")

            if tab.kind != .code {
                Button {
                    requestClose(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(IDELanguageRunText.t("关闭标签", "Close tab"))
                .accessibilityIdentifier("workspace.ide.tab.close")
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, tab.kind == .code ? 8 : 0)
        .overlay(alignment: .bottom) {
            if active {
                Rectangle().fill(FloeTheme.primary).frame(height: 2)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        ZStack(alignment: .topLeading) {
            // The web workbench stays mounted for the IDE lifetime so unsaved
            // Monaco buffers survive native tab switches (and a kernel switch
            // back does not have to reload it).
            IDEWorkbenchWebView(state: state, initialPath: codeInitialPath)
                .opacity(webKernelVisible ? 1 : 0)
                .allowsHitTesting(webKernelVisible)
                .accessibilityHidden(!webKernelVisible)
            // The native pane is mounted for the IDE lifetime too: each open
            // buffer keeps its editor (undo stack, selection, find bar) even
            // while the Web kernel is showing or another tab is active. Only
            // its visibility follows the kernel choice.
            IDENativeTextPane(
                model: nativePane,
                isActive: nativeKernelVisible,
                onRun: { presentRun() },
                onSwitchToWeb: { requestModeSwitch(to: .web) },
                onSaved: { onSaved() },
                onRequestClose: { requestNativeClose($0) }
            )
            .opacity(nativeKernelVisible ? 1 : 0)
            .allowsHitTesting(nativeKernelVisible)
            .accessibilityHidden(!nativeKernelVisible)
            if tabs.activeTab?.kind == .code, editorMode == .web {
                // Native PDF/Office surfaces overlay the web workbench at the
                // exact rectangles reported by the internal editor tabs, and
                // follow tab switches and resizes through the same stream.
                // Hidden tabs stay mounted (invisible, no hit testing) so a
                // PDF keeps its reading position and an Office session keeps
                // its editor state across switches. A PDF overlay is also
                // gated on the workbench's own active resource being that
                // document: closing the web tab can leave a stale rect in the
                // stream, and it must never float over an unrelated active
                // text editor.
                ForEach(nativeDocumentRequests, id: \.path) { request in
                    nativeDocumentOverlay(request)
                        .frame(width: max(0, request.rect.width), height: max(0, request.rect.height))
                        // Clip in the document's local bounds before moving
                        // it into the editor pane. Clipping after offset cuts
                        // away the right/bottom by the pane's origin offset.
                        .clipped()
                        .offset(x: request.rect.minX, y: request.rect.minY)
                        .opacity(overlayVisible(request) ? 1 : 0)
                        .allowsHitTesting(overlayVisible(request))
                }
            }
            if let tab = tabs.activeTab {
                switch tab.kind {
                case .code:
                    EmptyView()
                case .office:
                    officeSurface(tab)
                case .document:
                    if WorkspaceFileType.isArchive(tab.relativePath) {
                        // Archives browse as a tree with bounded on-demand
                        // extraction; they never enter the text workbench.
                        ArchiveBrowserView(relativePath: tab.relativePath, center: center, showsClose: false)
                            .id(tab.id)
                    } else {
                        FilePreviewView(relativePath: tab.relativePath, center: center, allowsIDEExpansion: false)
                            .id(tab.id)
                    }
                }
            }
        }
        // Office loading lives on the stable container, not on an overlay
        // branch tab switching replaces: activating another tab while a
        // document is still opening must not cancel the open. The in-flight
        // open is owned by the session; an edit intent from the action bar is
        // serialized by the session queue.
        .task(id: officeLoadKey) {
            for request in state.nativeDocuments.values where request.kind == .office {
                let session = nativeDocs.session(for: request.path)
                guard Self.needsOfficeLoad(session) else { continue }
                // A cloud/network tab edits only a private temporary copy, so
                // the session must stay a read-only snapshot; nothing may
                // present a temp-copy save as a successful remote save.
                session.isRemoteSnapshot = center.isCloudWorkspacePath(request.path)
                    || center.isNetworkWorkspacePath(request.path)
                do {
                    let url = try await resolveOfficeURL(relativePath: request.path)
                    await session.open(url)
                } catch {
                    // Resolve/open errors must reach a terminal, recoverable
                    // state: an endless "opening" spinner never re-arms retries.
                    session.reportOpenFailure(error)
                }
            }
        }
    }

    /// Re-runs the office loader when any internal office tab has no surface:
    /// the first open, or a save/discard that returned the session to `.idle`
    /// so the embedded read-only preview must come back.
    private var officeLoadKey: String {
        state.nativeDocuments.values
            .filter { $0.kind == .office }
            .map { "\($0.path)#\(Self.needsOfficeLoad(nativeDocs.session(for: $0.path)))" }
            .sorted()
            .joined(separator: "|")
    }

    private var nativeDocumentRequests: [IDEWorkbenchState.IDENativeDocumentRequest] {
        state.nativeDocuments.values.sorted { $0.path < $1.path }
    }

    /// Whether a native PDF/Office overlay may show right now. The web stream
    /// reports intersection visibility, but a closed or backgrounded web tab
    /// can leave a stale rect with `visible == true` behind; only the document
    /// the workbench reports as its active resource may actually cover the
    /// editor, so a PDF never floats over an unrelated active text file.
    private func overlayVisible(_ request: IDEWorkbenchState.IDENativeDocumentRequest) -> Bool {
        guard request.visible else { return false }
        return state.activePath == request.path
    }

    @ViewBuilder private func nativeDocumentOverlay(_ request: IDEWorkbenchState.IDENativeDocumentRequest) -> some View {
        switch request.kind {
        case .pdf:
            IDEPDFDocumentOverlay(relativePath: request.path, center: center)
        case .office:
            officeOverlay(request.path)
        }
    }

    /// Text files are handed to the workbench only when the typed router says
    /// the code editor owns them. The launch file is opened in both kernels:
    /// the native pane loads it as a buffer and the Web workbench opens it in
    /// its own model, so the explicit Web fallback starts on the same file
    /// instead of an empty explorer. Each kernel keeps its own baseline, so a
    /// save from the other side surfaces the existing conflict review rather
    /// than silently overwriting.
    private var codeInitialPath: String? {
        guard let initialRelativePath else { return nil }
        return WorkspaceFileRouter.destination(for: initialRelativePath) == .codeEditor ? initialRelativePath : nil
    }

    @ViewBuilder private func officeSurface(_ tab: IDEWorkspaceTab) -> some View {
        if let session = tab.officeSession {
            // The Office document stays embedded in its own IDE tab: preview,
            // editing, save and discard all happen against this one session,
            // and no second app window ever re-parents the native controller.
            VStack(spacing: 0) {
                if let reason = session.editUnavailableReason {
                    HStack(spacing: 8) {
                        Label(reason, systemImage: "lock")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(IDELanguageRunText.t("重试编辑", "Retry editing")) {
                            Task { await session.requestEditing() }
                        }
                        .font(.footnote)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.bar)
                }
                OfficeDocumentSurface(session: session)
                officeActionBar(session: session)
            }
            // A verified original-file commit from this tab (including the
            // engine's own toolbar save) refreshes every sibling entry.
            .onAppear { session.onCommitted = { onSaved() } }
        }
    }

    /// The internal-tab Office overlay: one session per document path, opened
    /// by the session itself (never cancelled by tab switches — the request
    /// stream drives visibility, the open owns the session).
    @ViewBuilder private func officeOverlay(_ path: String) -> some View {
        let session = nativeDocs.session(for: path)
        VStack(spacing: 0) {
            if let reason = session.editUnavailableReason {
                HStack(spacing: 8) {
                    Label(reason, systemImage: "lock")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(IDELanguageRunText.t("重试编辑", "Retry editing")) {
                        Task { await session.requestEditing() }
                    }
                    .font(.footnote)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }
            OfficeDocumentSurface(session: session)
            officeActionBar(session: session)
        }
        // A verified original-file commit refreshes every sibling entry.
        .onAppear { session.onCommitted = { onSaved() } }
    }

    private static func needsOfficeLoad(_ session: OfficeFileSession) -> Bool {
        session.controller == nil && session.phase == .idle
    }

    /// Settles an Office session whose internal tab already unmounted. A
    /// clean preview releases at once; outstanding edits hand the decision to
    /// the user (the tab itself cannot be vetoed after the fact).
    private func settleInternalOfficeClose(_ path: String) {
        guard let session = nativeDocs.existing(path) else { return }
        let decision = IDEOfficeCloseDecision.decide(
            readOnly: session.readOnly,
            hasUncommittedChanges: session.hasUncommittedChanges,
            isReady: session.phase == .ready
        )
        if decision == .askUser {
            internalOfficeClose = path
        } else {
            Task { await nativeDocs.release(path) }
        }
    }

    /// Local documents resolve straight through the guard; cloud/network
    /// documents are snapshotted into a private temporary copy (never decoded
    /// as text and never pointing at a network path the engine cannot read).
    private func resolveOfficeURL(relativePath: String) async throws -> URL {
        guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
        if center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath) {
            let bytes = try await center.readRemotePreview(relativePath: relativePath)
            return try remoteOfficeCopy.store(bytes, fileName: (relativePath as NSString).lastPathComponent)
        }
        let url = try service.guardResolver.resolve(relativePath)
        try service.guardResolver.assertReadableSize(url)
        return url
    }

    @ViewBuilder private func officeActionBar(session: OfficeFileSession) -> some View {
        // Saving belongs to the Office engine's own toolbar (bridged through
        // OfficeExplicitSaveBridge to the verified original-file commit) and
        // to the IDE's Command-S save-all; closing a dirty tab offers the
        // save/discard/cancel decision. No parallel bottom-left save cluster
        // competes with the engine chrome while editing.
        let bar = HStack(spacing: 10) {
            if session.readOnly {
                if session.isRemoteSnapshot {
                    // No real remote write-back exists yet; the snapshot is
                    // preview-only and the edit entry stays hidden so a
                    // temp-copy edit can never masquerade as a remote save.
                    Label(OfficeFileSession.remoteSnapshotHint, systemImage: "icloud.and.arrow.down")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The hint text is the whole message; never let the
                        // compact icon-only action style strip it.
                        .labelStyle(.titleAndIcon)
                        .accessibilityIdentifier("workspace.ide.office.remoteHint")
                } else {
                    Button {
                        Task { await session.requestEditing() }
                    } label: {
                        Label(IDELanguageRunText.t("编辑", "Edit"), systemImage: "square.and.pencil")
                            .frame(minWidth: 44, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canAct)
                    .accessibilityIdentifier("workspace.ide.office.edit")
                }
            }
            Spacer(minLength: 0)
            // Explicit share of this document without leaving the tab: a
            // verified snapshot copy goes to the system share sheet.
            Button {
                Task { officeShareSnapshot = await session.prepareShareCopy() }
            } label: {
                Label(IDELanguageRunText.t("分享", "Share"), systemImage: "square.and.arrow.up")
                    .frame(minWidth: 44, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .disabled(!session.canAct)
            .accessibilityIdentifier("workspace.ide.office.share")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        // `.iconOnly` and `.titleAndIcon` are distinct concrete styles; a
        // ternary cannot mix them, so branch between the two modifiers.
        if sizeClass == .compact {
            bar.labelStyle(.iconOnly)
        } else {
            bar.labelStyle(.titleAndIcon)
        }
    }

    private var hasOfficeEdits: Bool {
        nativeDocs.hasEdits || tabs.tabs.contains { $0.hasUnsavedChanges }
    }

    // MARK: - Actions

    /// The run controller is created once per pinned workspace and reuses the
    /// same pinned values for every dispatch. A successful dispatch asks the
    /// IDE to reveal the run-owned output surface after the sheet closes —
    /// the same surface renders the local session stream and the captured
    /// remote result.
    private func presentRun() {
        guard let workspaceID, root != nil, let path = state.activePath, !path.isEmpty else { return }
        let controller = runController ?? IDELanguageRunController(
            workspaceID: workspaceID, root: root, center: center, state: state
        )
        controller.onRequestRunTerminal = {
            pendingRunTerminal = true
            showsRunSheet = false
        }
        runController = controller
        showsRunSheet = true
    }

    private func toggleTerminal() {
        guard let workspaceID, let root else { return }
        if terminalOwner == nil {
            terminalOwner = center.environment.localTerminals.owner(workspaceID: workspaceID, root: root)
        }
        withAnimation(.snappy) { showsTerminal.toggle() }
    }

    private func openActiveInRoutedSurface() {
        guard let path = state.activePath else { return }
        if isNativeDocumentPath(path) {
            if editorMode == .web {
                // In Web mode PDF/Office actives live in internal CodeBlitz
                // tabs; re-assert the internal tab instead of spawning any
                // native chrome.
                Task { await state.openNativeDocument(path) }
            } else {
                // In native mode they keep their typed outer tab (Office
                // session / PDFKit reader) instead of overlaying the hidden
                // workbench.
                tabs.open(relativePath: path)
            }
            return
        }
        if let active = tabs.activeTab, active.kind == .office {
            // An Office document stays embedded in its own IDE tab; opening it
            // must never spawn a second window.
            tabs.activate(active.id)
            return
        }
        tabs.open(relativePath: path)
    }

    // MARK: - Native text kernel

    /// The Web workbench is the visible editor only on the code tab in Web
    /// mode; it stays mounted either way so Monaco buffers survive a switch.
    private var webKernelVisible: Bool {
        tabs.activeTab?.kind == .code && editorMode == .web
    }

    private var nativeKernelVisible: Bool {
        tabs.activeTab?.kind == .code && editorMode == .native
    }

    /// Opens a workspace path in the surface that owns it. Text/code open a
    /// native buffer while the native kernel is on; PDF/Office use the Web
    /// workbench's internal document tab in Web mode and their typed outer tab
    /// in native mode (the overlay only exists over the visible workbench).
    private func openRoutedPath(_ path: String) {
        switch WorkspaceTextPolicy.kind(forPath: path) {
        case .pdf, .office:
            if editorMode == .web {
                Task { await state.openNativeDocument(path) }
            } else {
                tabs.open(relativePath: path)
            }
        case .text, .code, .unknown:
            if editorMode == .native {
                openNativeText(path)
            } else {
                // There is no narrow bridge call to open a text file in the
                // Web workbench (only its own explorer can), so point at it
                // instead of pretending the tap did nothing.
                showRoutingNotice(IDELanguageRunText.t(
                    "Web 内核请在编辑器文件浏览器中打开该文件；原生缓冲区仍保留。",
                    "In the Web kernel, open that file from the editor's explorer; native buffers are kept."
                ))
            }
        default:
            tabs.open(relativePath: path)
            showRoutingNotice(WorkspaceFileRouter.surfaceName(for: path))
        }
    }

    private func openNativeText(_ path: String) {
        Task {
            await state.nativeText.open(path)
            state.updateNativeActivePath(state.nativeText.activePath)
            // A refused open (full dirty budget or invalid path) is reported
            // with its recovery reason; no buffer was evicted for it.
            if let refusal = state.nativeText.openRefusal, refusal.relativePath == path {
                nativeOpenRefusal = refusal
            }
        }
    }

    private func requestNativeClose(_ path: String) {
        switch state.nativeText.closeDecision(for: path) {
        case .closeImmediately:
            state.nativeText.close(path, force: true)
        case .askUser:
            nativeCloseRequest = path
        }
    }

    private func requestModeSwitch(to mode: IDENativeTextSurfaceMode) {
        guard mode != editorMode else { return }
        let plan = state.nativeText.planSurfaceSwitch(to: mode, webHasUnsavedChanges: state.dirty)
        if plan.requiresConfirmation {
            pendingModeSwitch = mode
        } else {
            applyModeSwitch(mode)
        }
    }

    /// Switches the visible kernel. Buffers in both kernels stay alive: the
    /// Web workbench keeps its Monaco models and the native pane keeps every
    /// buffer, cursor, find state and undo stack.
    private func applyModeSwitch(_ mode: IDENativeTextSurfaceMode) {
        usesNativeEditor = (mode == .native)
        state.setNativeEditorActive(mode == .native)
        switch mode {
        case .native:
            // Bring the file the Web workbench had active into the native pane
            // so the hand-off does not require re-navigating the tree.
            if let path = state.lastWebActivePath, IDENativeTextPolicy.supportsNativeEditing(path) {
                openNativeText(path)
            }
        case .web:
            showRoutingNotice(IDELanguageRunText.t(
                "已切换到 Web 编辑器；原生缓冲区仍保留，可在其文件浏览器中打开文件使用多光标/折叠。",
                "Switched to the Web editor. Native buffers are kept; open files from its explorer for multicursor/folding."
            ))
        }
    }

    /// Opens the path the IDE was launched with, in the kernel that owns it.
    private func openInitialPath(_ path: String) {
        switch WorkspaceTextPolicy.kind(forPath: path) {
        case .pdf, .office:
            if editorMode == .web {
                // The internal Web document tab needs the workbench ready;
                // `onChange(of: state.ready)` forwards it.
                return
            }
            forwardedInitialNativePath = true
            tabs.open(relativePath: path)
        case .text, .code, .unknown:
            // The Web kernel receives the path as `codeInitialPath` at
            // creation; only the native kernel needs an explicit open.
            guard editorMode == .native,
                  IDENativeTextPolicy.supportsNativeEditing(path),
                  !forwardedInitialNativeTextPath else { return }
            forwardedInitialNativeTextPath = true
            openNativeText(path)
        default:
            tabs.open(relativePath: path)
        }
    }

    private func isNativeDocumentPath(_ path: String) -> Bool {
        switch WorkspaceTextPolicy.kind(forPath: path) {
        case .pdf, .office: return true
        default: return false
        }
    }

    private func requestClose(_ tab: IDEWorkspaceTab) {
        guard let session = tab.officeSession else {
            Task { await tabs.close(tab.id) }
            return
        }
        let decision = IDEOfficeCloseDecision.decide(
            readOnly: session.readOnly,
            hasUncommittedChanges: session.hasUncommittedChanges,
            isReady: session.phase == .ready
        )
        if decision == .askUser {
            officeCloseRequest = OfficeCloseRequest(id: tab.id, tab: tab)
        } else {
            Task { await tabs.close(tab.id) }
        }
    }

    private func requestCloseIDE() {
        Task {
            await state.refreshDirty()
            if state.dirty || state.nativeText.hasDirty || hasOfficeEdits {
                showsCloseConfirmation = true
            } else {
                await finishClose()
            }
        }
    }

    /// Saves every surface in the pinned workspace: the native text buffers
    /// first (the run flow reads the files next), then the Web workbench and
    /// every Office session.
    private func saveAllSurfaces() async -> Bool {
        var saved = await state.saveAll()
        for session in nativeDocs.all where !session.readOnly {
            if !(await session.saveInPlace()) { saved = false }
        }
        for tab in tabs.tabs {
            guard let session = tab.officeSession, !session.readOnly else { continue }
            if !(await session.saveInPlace()) { saved = false }
        }
        return saved
    }

    private func finishClose() async {
        // Do not leave a run-owned session behind when the IDE closes.
        if let runController { await runController.stop() }
        await nativeDocs.releaseAll()
        await tabs.releaseAll()
        onSaved()
        dismiss()
    }

    private func showRoutingNotice(_ text: String) {
        withAnimation(.snappy) { routingNotice = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { routingNotice = nil }
        }
    }
}
/// Live unsaved-state badge for an Office tab. The tab model itself is not an
/// observed session, so the badge observes the shared Office session directly.
private struct IDETabUnsavedBadge: View {
    @ObservedObject var session: OfficeFileSession

    var body: some View {
        if session.hasUncommittedChanges || (!session.readOnly && session.phase == .ready) {
            Circle().fill(FloeTheme.primary).frame(width: 6, height: 6)
                .accessibilityLabel(IDELanguageRunText.t("有未保存的修改", "Unsaved changes"))
        }
    }
}

/// Owns the `OfficeFileSession` behind each internal CodeBlitz Office tab,
/// keyed by workspace-relative path. Sessions are created on demand and
/// released only through here so a tab close or IDE close never strands a
/// working copy.
@MainActor
final class IDENativeDocumentStore: ObservableObject {
    private var sessions: [String: OfficeFileSession] = [:]
    private var observations: [String: AnyCancellable] = [:]

    func session(for path: String) -> OfficeFileSession {
        if let existing = sessions[path] { return existing }
        let created = OfficeFileSession()
        sessions[path] = created
        observations[path] = created.objectWillChange.sink { [weak self] in
            // OfficeFileSession is main-actor owned. Forward on the next turn
            // so the parent's edit controls read the updated child state.
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
        return created
    }

    func existing(_ path: String) -> OfficeFileSession? { sessions[path] }
    var all: [OfficeFileSession] { Array(sessions.values) }
    var officePaths: [String] { Array(sessions.keys) }

    var hasEdits: Bool {
        sessions.values.contains { $0.hasUncommittedChanges || (!$0.readOnly && $0.phase == .ready) }
    }

    func release(_ path: String) async {
        observations.removeValue(forKey: path)
        guard let session = sessions.removeValue(forKey: path) else { return }
        objectWillChange.send()
        await session.release()
    }

    func releaseAll() async {
        let owned = Array(sessions.values)
        observations.removeAll()
        sessions.removeAll()
        objectWillChange.send()
        for session in owned { await session.release() }
    }
}

/// Read-only PDF surface for an internal IDE tab. Resolution mirrors
/// `FilePreviewView`: local files pass the guard resolver, cloud/network
/// files become a private snapshot copy (never decoded as text). Rendering is
/// the shared PDFKit-gated `InlinePDFReader`.
private struct IDEPDFDocumentOverlay: View {
    let relativePath: String
    let center: WorkspaceCenter
    @State private var url: URL?
    @State private var loadError: String?
    @StateObject private var remoteCopy = RemoteFilePreviewCopy()

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("inspector.preview.error", systemImage: "exclamationmark.triangle")
                } description: { Text(loadError) } actions: {
                    Button("pdf.reader.retry") { Task { await load() } }
                }
            } else if let url {
                InlinePDFReader(url: url, validateRead: { try validate(url: url) })
                    .id(url)
            } else {
                ProgressView("inspector.preview.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: relativePath) { await load() }
    }

    private func load() async {
        guard let service = center.fileService else {
            loadError = String(localized: "ide.workspace.unavailable")
            return
        }
        do {
            if center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath) {
                let bytes = try await center.readRemotePreview(relativePath: relativePath)
                url = try remoteCopy.store(bytes, fileName: (relativePath as NSString).lastPathComponent)
            } else {
                let resolved = try service.guardResolver.resolve(relativePath)
                try service.guardResolver.assertReadableSize(resolved)
                url = resolved
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func validate(url: URL) throws {
        if remoteCopy.url == url { return }
        guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
        guard let resolved = try? service.guardResolver.resolve(relativePath),
              resolved.standardizedFileURL == url.standardizedFileURL else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
#endif
