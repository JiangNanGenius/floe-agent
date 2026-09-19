// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeDocuments
import FloeWorkspace

/// An IDE pins one workspace for its lifetime, including terminal ownership.
///
/// The IDE is a unified native tab host: the code workbench (CodeBlitz/Monaco)
/// plus one tab per routed native document. Office documents get exactly one
/// `OfficeFileSession` per tab and stay embedded in that tab for preview and
/// editing — opening one never spawns a second app window — so a tab close can
/// always offer save / discard / cancel against one working copy.
struct WorkspaceIDEView: View {
    @ObservedObject var center: WorkspaceCenter
    let initialRelativePath: String?
    let onSaved: () -> Void
    @StateObject private var state: IDEWorkbenchState
    @StateObject private var tabs: IDEWorkspaceTabStore
    private let workspaceID: UUID?
    private let workspaceName: String
    private let root: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsCloseConfirmation = false
    @State private var terminalOwner: LocalTerminalOwner?
    @State private var showsTerminal = false
    @State private var runController: IDELanguageRunController?
    @State private var showsRunSheet = false
    @State private var showsRunTerminal = false
    @State private var pendingRunTerminal = false
    @State private var officeCloseRequest: OfficeCloseRequest?
    @State private var routingNotice: String?
    @State private var showsSourceControl = false
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
        _state = StateObject(wrappedValue: IDEWorkbenchState(files: center.fileService))
        _tabs = StateObject(wrappedValue: IDEWorkspaceTabStore(initialRelativePath: initialRelativePath))
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
                    }.disabled(!state.ready || state.saving).accessibilityIdentifier("workspace.ide.save").keyboardShortcut("s", modifiers: .command)
                    if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
                        Button("IDE-INSERT") {
                            Task {
                                guard let path = state.activePath else { return }
                                _ = await state.insertTextForTesting(path: path, text: "")
                            }
                        }.disabled(!state.ready)
                        .accessibilityIdentifier("workspace.ide.insertTestText")
                        .accessibilityValue(state.lastInsertResult ?? "")
                    }
                    Button {
                        openActiveInRoutedSurface()
                    } label: { Label("ide.open.editor", systemImage: "doc.richtext") }
                    .disabled(tabs.activeTab == nil || root == nil)
                    .accessibilityIdentifier("workspace.ide.richEditor")
                    // Common source-control entries (status, diff, stage,
                    // commit, branch) for the IDE's pinned workspace.
                    Button {
                        showsSourceControl = true
                    } label: { Label(IDELanguageRunText.t("源码管理", "Source control"), systemImage: "arrow.triangle.branch") }
                    .disabled(root == nil || workspaceID == nil || center.currentWorkspace?.id != workspaceID)
                    .accessibilityIdentifier("workspace.ide.sourceControl")
                    Button {
                        toggleTerminal()
                    } label: { Label("ide.terminal", systemImage: "terminal") }
                    .disabled(root == nil || workspaceID == nil).accessibilityIdentifier("workspace.ide.terminal")
                }
            }
        }
        .interactiveDismissDisabled(state.dirty || state.saving || hasOfficeEdits)
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
        .sheet(isPresented: $showsSourceControl) {
            NavigationStack {
                SourceControlView(center: center.environment.sourceControlCenter)
                    .navigationTitle(IDELanguageRunText.t("源码管理", "Source control"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(IDELanguageRunText.t("完成", "Done")) { showsSourceControl = false }
                        }
                    }
            }
        }
        .sheet(item: $officeShareSnapshot, onDismiss: {
            // Only the session that produced this snapshot holds it; the
            // others no-op on their own export store.
            Task { for tab in tabs.tabs { await tab.officeSession?.finishSaveCopy() } }
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
        .onChange(of: state.pendingNativePath) { _, value in
            guard let value else { return }
            tabs.open(relativePath: value)
            showRoutingNotice(WorkspaceFileRouter.surfaceName(for: value))
            state.pendingNativePath = nil
        }
        .onDisappear {
            // A swipe-dismiss edge case must not strand an Office working copy.
            Task { await tabs.releaseAll() }
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
        ZStack {
            // The web workbench stays mounted for the IDE lifetime so unsaved
            // Monaco buffers survive native tab switches.
            IDEWorkbenchWebView(state: state, initialPath: codeInitialPath)
                .opacity(tabs.activeTab?.kind == .code ? 1 : 0)
                .allowsHitTesting(tabs.activeTab?.kind == .code)
                .accessibilityHidden(tabs.activeTab?.kind != .code)
            if let tab = tabs.activeTab {
                switch tab.kind {
                case .code:
                    EmptyView()
                case .office:
                    officeSurface(tab)
                case .document:
                    FilePreviewView(relativePath: tab.relativePath, center: center, allowsIDEExpansion: false)
                        .id(tab.id)
                }
            }
        }
        // Office loading lives on the stable container, not on a branch that
        // tab switching replaces: activating another tab while a document is
        // still opening must not cancel the open. An edit intent raised from
        // the tab's action bar is serialized by the session queue.
        .task(id: officeLoadKey) {
            guard let tab = tabs.activeTab, tab.kind == .office,
                  let session = tab.officeSession, Self.needsOfficeLoad(session) else { return }
            do {
                // A cloud/network tab edits only a private temporary copy, so
                // the session must stay a read-only snapshot; nothing may
                // present a temp-copy save as a successful remote save.
                session.isRemoteSnapshot = center.isCloudWorkspacePath(tab.relativePath)
                    || center.isNetworkWorkspacePath(tab.relativePath)
                let url = try await resolveOfficeURL(relativePath: tab.relativePath)
                await session.open(url)
            } catch {
                session.error = error.localizedDescription
            }
        }
    }

    /// Re-runs the office loader when the active office tab has no surface:
    /// the first open, or a save/discard that returned the session to `.idle`
    /// so the embedded read-only preview must come back. The in-flight open
    /// itself is owned by the session, never by this view, so a key change
    /// cannot cancel a load.
    private var officeLoadKey: String {
        guard let tab = tabs.activeTab, tab.kind == .office,
              let session = tab.officeSession else { return "code" }
        return "\(tab.id)#\(Self.needsOfficeLoad(session))"
    }

    private static func needsOfficeLoad(_ session: OfficeFileSession) -> Bool {
        session.controller == nil && session.phase == .idle
    }

    /// Text files are handed to the workbench only when the typed router says
    /// the code editor owns them.
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
                officeActionBar(tab: tab, session: session)
            }
            // A verified original-file commit from this tab (including the
            // engine's own toolbar save) refreshes every sibling entry.
            .onAppear { session.onCommitted = { onSaved() } }
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

    @ViewBuilder private func officeActionBar(tab: IDEWorkspaceTab, session: OfficeFileSession) -> some View {
        // The tab owns every Office action; opening never spawns another
        // window. On compact widths the row switches to icon-only buttons so
        // Save/Discard/Share keep their 36pt targets without overflowing.
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
            } else {
                Button {
                    // A verified commit already fired `session.onCommitted`,
                    // which refreshes every sibling entry; calling onSaved()
                    // here as well would refresh everything twice.
                    Task { _ = await session.saveAndReturn() }
                } label: {
                    Label(IDELanguageRunText.t("保存", "Save"), systemImage: "checkmark")
                        .frame(minWidth: 44, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canAct)
                .accessibilityIdentifier("workspace.ide.office.save")
                Button {
                    Task { _ = await session.discardAndReturn() }
                } label: {
                    Label(IDELanguageRunText.t("放弃修改", "Discard"), systemImage: "arrow.uturn.backward")
                        .frame(minWidth: 44, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(!session.canAct)
                .accessibilityIdentifier("workspace.ide.office.discard")
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
        guard let workspaceID, let root else { return }
        if terminalOwner == nil {
            terminalOwner = center.environment.localTerminals.owner(workspaceID: workspaceID, root: root)
        }
        withAnimation(.snappy) { showsTerminal.toggle() }
    }

    private func openActiveInRoutedSurface() {
        if let active = tabs.activeTab, active.kind == .office {
            // An Office document stays embedded in its own IDE tab; opening it
            // must never spawn a second window.
            tabs.activate(active.id)
            return
        }
        if let path = state.activePath { tabs.open(relativePath: path) }
    }

    private func requestClose(_ tab: IDEWorkspaceTab) {
        guard let session = tab.officeSession else {
            Task { await tabs.close(tab.id) }
            return
        }
        if !session.readOnly || session.hasUncommittedChanges {
            officeCloseRequest = OfficeCloseRequest(id: tab.id, tab: tab)
        } else {
            Task { await tabs.close(tab.id) }
        }
    }

    private func requestCloseIDE() {
        Task {
            await state.refreshDirty()
            if state.dirty || hasOfficeEdits {
                showsCloseConfirmation = true
            } else {
                await finishClose()
            }
        }
    }

    private func saveAllSurfaces() async -> Bool {
        var saved = true
        if state.ready { saved = await state.saveAll() }
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
