// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import Combine
import FloeDocuments
import FloeWorkspace

/// An IDE pins one workspace for its lifetime, including terminal ownership.
///
/// The code tab hosts the native Swift/UIKit text editor
/// (`IDENativeTextPane`) — the only text editor in the IDE — with its own
/// multi-file buffer strip, find/replace, conflict review and the guarded save
/// contract. The chrome is a VS Code-style activity rail, collapsible
/// sidebar, bottom panel and status bar.
///
/// PDF/Office and the remaining routed kinds use typed outer tabs; the
/// sidebar's file tree/search comes from the native `FileTreeView`. Every
/// open Office document still gets exactly one `OfficeFileSession`, so a tab
/// close can always offer save / discard / keep-copy against one working copy.
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
    @State private var showsCloseConfirmation = false
    @State private var nativeCloseRequest: String?
    /// A refused native open (budget full with every buffer dirty, or an
    /// invalid path) is surfaced with its bilingual recovery reason instead of
    /// dropping the tap; no draft is evicted to make room.
    @State private var nativeOpenRefusal: IDENativeTextOpenRefusal?
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
    /// Regular-width sessions open with the Explorer visible, matching the
    /// VS Code workbench; a user collapse is respected for the rest of the
    /// session. Compact (iPhone) starts unobstructed with no sidebar.
    @State private var didSeedInitialSidebar = false
    /// Collapsible sidebar width, proportional to the available width so the
    /// editor keeps the majority of the workbench even in iPad split view.
    /// Clamped to a readable 200...300pt range.
    private func resolvedSidebarWidth(availableWidth: CGFloat) -> CGFloat {
        min(300, max(200, availableWidth * 0.3))
    }
    @State private var forwardedInitialNativeTextPath = false
    /// In-flight Office share snapshot. The owning tab session reclaims it on
    /// dismiss via `finishSaveCopy()`.
    @State private var officeShareSnapshot: DocumentExportSnapshot?

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
                    GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // Persistent VS Code-style activity rail: files, search
                        // and source control are reached from the left, never
                        // from a crowded top bar. On compact widths the same
                        // rail opens the slide-over drawer.
                        IDEActivityBar(
                            mode: $sidebar,
                            panelVisible: Binding(
                                get: { showsTerminal },
                                set: { visible in
                                    if visible { openTerminalPanel() } else { showsTerminal = false }
                                }
                            ),
                            disabled: workspaceID == nil
                        )
                        if let sidebar, sizeClass != .compact {
                            IDESidebar(
                                mode: sidebar,
                                center: center,
                                workspaceID: workspaceID,
                                workspaceName: workspaceName,
                                pinnedRootURL: root,
                                onClose: { self.sidebar = nil },
                                onOpenFile: { openRoutedPath($0) }
                            )
                            .frame(width: resolvedSidebarWidth(availableWidth: geometry.size.width))
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            Divider()
                        }
                        VStack(spacing: 0) {
                            tabStrip
                            Divider()
                            content
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if showsTerminal, let terminalOwner {
                                bottomPanel(terminalOwner, availableHeight: geometry.size.height)
                            }
                            IDEStatusBar(
                                sourceControl: center.environment.sourceControlCenter,
                                identityMatches: pinnedWorkspaceIsCurrent,
                                dirtyBuffers: state.nativeText.dirtyPaths.count
                            )
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
                                    pinnedRootURL: root,
                                    onClose: { self.sidebar = nil },
                                    onOpenFile: {
                                        openRoutedPath($0)
                                        self.sidebar = nil
                                    }
                                )
                            }
                        }
                    }
                    }
                } else { ContentUnavailableView("ide.workspace.unavailable", systemImage: "folder.badge.questionmark") }
            }
            .navigationTitle(workspaceName)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { seedInitialSidebar() }
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
                    Button {
                        openActiveInRoutedSurface()
                    } label: { Label("ide.open.editor", systemImage: "doc.richtext") }
                    .disabled(tabs.activeTab == nil || root == nil)
                    .accessibilityIdentifier("workspace.ide.richEditor")
                    // Files, search, source control and the terminal live in
                    // the persistent left activity rail and bottom panel, so
                    // the compact top bar only keeps the high-frequency run,
                    // save and routed-surface actions.
                }
                // The IDE text editor is native Swift/UIKit only; there is no
                // Web/Monaco text kernel or kernel-switch entry, and no
                // editor test-injection controls in the product UI. Tests
                // drive the real UITextView through XCTest typing instead.
            }
        }
        .interactiveDismissDisabled(state.saving || hasOfficeEdits || state.nativeText.hasDirty)
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
        .sheet(item: $officeShareSnapshot, onDismiss: {
            // Only the session that produced this snapshot holds it; the
            // others no-op on their own export store.
            Task {
                for tab in tabs.tabs { await tab.officeSession?.finishSaveCopy() }
            }
        }) { snapshot in
            OfficeDocumentShareSheet(url: snapshot.fileURL)
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
        .onChange(of: state.nativeText.activePath) { _, _ in
            state.updateNativeActivePath(state.nativeText.activePath)
        }
        .task {
            // Text/code editing is native-only; open the initial document in
            // its typed surface directly.
            guard let initialRelativePath else { return }
            openInitialPath(initialRelativePath)
        }
        .onDisappear {
            // A swipe-dismiss edge case must not strand an Office working copy.
            Task {
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
                .frame(minHeight: FloeTheme.minimumTarget)
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
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
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
            // The native pane is mounted for the IDE lifetime: each open
            // buffer keeps its editor (undo stack, selection, find bar) while
            // another tab is active. Text/code editing is native-only.
            IDENativeTextPane(
                model: nativePane,
                isActive: codeTabVisible,
                onRun: { presentRun() },
                onSaved: { onSaved() },
                onRequestClose: { requestNativeClose($0) }
            )
            .opacity(codeTabVisible ? 1 : 0)
            .allowsHitTesting(codeTabVisible)
            .accessibilityHidden(!codeTabVisible)
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
    }

    /// True while the code tab (native text/code editor) is the active tab.
    private var codeTabVisible: Bool {
        tabs.activeTab?.kind == .code
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
                OfficeDocumentSurface(session: session) {
                    // Deterministic retry: recovery re-arms a pre-mount failure
                    // to `.idle` (its task already ran and will not re-run while
                    // the tab stays mounted), so the loader must be re-driven
                    // explicitly. A mounted recovery keeps its controller and
                    // the open guard below turns this into a no-op.
                    Task { await openOfficeDocument(tab: tab, session: session) }
                }
                officeActionBar(session: session)
            }
            // A verified original-file commit from this tab (including the
            // engine's own toolbar save) refreshes every sibling entry.
            .onAppear { session.onCommitted = { onSaved() } }
            .task {
                // The tab owns exactly one Office session; resolving and
                // opening the document here is what moves the surface off the
                // "opening" spinner. Without this the session never left
                // `.idle`, so every IDE Word/Excel/PPT tab spun forever while
                // the same documents opened fine outside the IDE.
                await openOfficeDocument(tab: tab, session: session)
            }
        }
    }

    /// Opens the tab's document in its shared Office session, mirroring
    /// `FilePreviewView`'s staging contract: a local path resolves through the
    /// workspace guard resolver; a cloud/network path is staged into a private
    /// read-only snapshot that can never masquerade as a remote save. A
    /// resolution failure is reported to the session as a recoverable failed
    /// open (the surface then offers recovery), never left as an unowned
    /// spinner that no watchdog owns.
    private func openOfficeDocument(tab: IDEWorkspaceTab, session: OfficeFileSession) async {
        // A mounted controller — loading, ready, or failed-with-a-retained-
        // working-copy — already owns this tab's document. Re-opening would
        // tear down a live or recoverable session (and abandon its editing
        // copy), so only a never-mounted session is opened here; after a clean
        // release the controller is nil and the open re-arms.
        guard IDEOfficeOpenDecision.decide(controllerMounted: session.controller != nil) == .openNow else { return }
        // This task is cancelled when the tab closes or the IDE disappears; a
        // late resume after `release()` completed must not revive the removed
        // tab's session (release itself is deferred behind an in-flight open
        // by the session's own serialization — the exposed race is this
        // loader's pre-open awaits).
        func tabAlive() -> Bool {
            // Object identity, not path identity: closing and immediately
            // reopening the same path creates a new tab, which must not let
            // this old tab's loader finish and revive the old released
            // session.
            !Task.isCancelled && tabs.tabs.contains { $0 === tab }
        }
        guard tabAlive() else { return }
        guard let service = center.fileService else {
            session.reportOpenFailure(NSError(
                domain: "org.floeagent.ide.office",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: IDELanguageRunText.t(
                    "工作区文件服务不可用，无法打开该文档。",
                    "The workspace file service is unavailable, so this document cannot be opened.")]))
            return
        }
        do {
            let remote = center.isCloudWorkspacePath(tab.relativePath)
                || center.isNetworkWorkspacePath(tab.relativePath)
            let url: URL
            if remote {
                let bytes = try await center.readRemotePreview(relativePath: tab.relativePath)
                guard tabAlive() else { return }
                // Per-tab staging store: staging another remote tab must never
                // delete this tab's active staged snapshot.
                url = try tab.remotePreview.store(bytes, fileName: tab.title)
            } else {
                url = try service.guardResolver.resolve(tab.relativePath)
                try service.guardResolver.assertReadableSize(url)
            }
            guard tabAlive() else { return }
            session.isRemoteSnapshot = remote
            await session.open(url)
            guard tabAlive() else { return }
            await center.recordRecentFile(relativePath: tab.relativePath, displayName: tab.title)
        } catch {
            // A cancelled or removed tab is not a failure the surface must show.
            guard tabAlive() else { return }
            session.reportOpenFailure(error)
        }
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
        tabs.tabs.contains { $0.hasUnsavedChanges }
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
        if showsTerminal {
            withAnimation(.snappy) { showsTerminal = false }
        } else {
            openTerminalPanel()
        }
    }

    /// Opens the Explorer sidebar automatically the first time a regular
    /// width session appears, like the familiar workbench. Compact widths
    /// start clear, and collapsing it later is not undone within the IDE
    /// session.
    private func seedInitialSidebar() {
        guard !didSeedInitialSidebar else { return }
        didSeedInitialSidebar = true
        guard sizeClass != .compact else { return }
        if sidebar == nil { sidebar = .files }
    }

    /// Opens the bottom panel without recreating its terminal session: the
    /// owner is created at most once per IDE lifetime, so collapsing the
    /// panel and switching layout never spawns a second terminal.
    private func openTerminalPanel() {
        guard let workspaceID, let root else { return }
        if terminalOwner == nil {
            terminalOwner = center.environment.localTerminals.owner(workspaceID: workspaceID, root: root)
        }
        withAnimation(.snappy) { showsTerminal = true }
    }

    /// True only while the app's current workspace is the one this IDE was
    /// opened for; used to bind the status bar and panel state to the pinned
    /// workspace rather than to whatever the global center switched to.
    private var pinnedWorkspaceIsCurrent: Bool {
        guard let workspaceID else { return false }
        return center.currentWorkspace?.id == workspaceID
    }

    /// Collapsible bottom panel. Height is proportional to the workbench so
    /// the editor always keeps a minimum working area; collapsing hides it
    /// but keeps the terminal owner alive.
    @ViewBuilder
    private func bottomPanel(_ owner: LocalTerminalOwner, availableHeight: CGFloat = 600) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Label(IDELanguageRunText.t("终端", "Terminal"), systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy) { showsTerminal = false }
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(IDELanguageRunText.t("收起终端面板", "Collapse terminal panel"))
                .accessibilityIdentifier("workspace.ide.panel.close")
            }
            .padding(.horizontal, 10)
            .frame(height: FloeTheme.minimumTarget)
            .background(FloeTheme.sidebarSurface)
            LocalTerminalView(owner: owner, embedded: true)
        }
        .frame(height: min(280, max(160, availableHeight * 0.42)))
        .background(FloeTheme.readingSurface)
        // An explicit container keeps the panel discoverable as one element;
        // without it SwiftUI inherits the identifier into every child and no
        // `otherElements` query can find the panel itself.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.ide.terminalPanel")
    }

    private func openActiveInRoutedSurface() {
        guard let path = state.activePath else { return }
        if isNativeDocumentPath(path) {
            // PDF/Office keep their typed outer tab (Office session / PDFKit
            // reader); there is no Web workbench to overlay.
            tabs.open(relativePath: path)
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

    /// Opens a workspace path in the surface that owns it. Text/code open a
    /// native buffer; PDF/Office and other typed documents use their typed
    /// outer tab. Text editing is native-only.
    private func openRoutedPath(_ path: String) {
        switch WorkspaceTextPolicy.kind(forPath: path) {
        case .text, .code, .unknown:
            openNativeText(path)
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

    /// Opens the path the IDE was launched with in the surface that owns it.
    private func openInitialPath(_ path: String) {
        switch WorkspaceTextPolicy.kind(forPath: path) {
        case .text, .code, .unknown:
            guard IDENativeTextPolicy.supportsNativeEditing(path),
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
            if state.nativeText.hasDirty || hasOfficeEdits {
                showsCloseConfirmation = true
            } else {
                await finishClose()
            }
        }
    }

    /// Saves every surface in the pinned workspace: the native text buffers
    /// first (the run flow reads the files next), then every Office session.
    private func saveAllSurfaces() async -> Bool {
        var saved = await state.saveAll()
        for tab in tabs.tabs {
            guard let session = tab.officeSession, !session.readOnly else { continue }
            if !(await session.saveInPlace()) { saved = false }
        }
        return saved
    }

    private func finishClose() async {
        // Do not leave a run-owned session behind when the IDE closes.
        if let runController { await runController.stop() }
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
#endif
