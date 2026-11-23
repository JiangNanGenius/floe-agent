// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeMacSelfCore
import FloeMacToolbox
import FloePersistence
import FloeTools
import SwiftUI
import UniformTypeIdentifiers

enum MacSpacePage: Hashable {
    case files, toolbox
}

private enum MacWorkspaceDestination: Hashable {
    case temporary, newTask(UUID?)
    case taskCenter, projectTasks(UUID), space(MacSpacePage), creative, images, browser, conversation(UUID)
}

private enum MacTaskInspector: Hashable {
    case files, browser(UUID), changes(UUID), terminal(UUID), childAgents(UUID), progress(UUID)

    var ownerID: UUID? {
        switch self {
        case .files: nil
        case .browser(let id), .changes(let id), .terminal(let id), .childAgents(let id), .progress(let id): id
        }
    }
}

private struct MacTaskPermissionsPresentation: Identifiable {
    let id: UUID
    let isDraft: Bool
}

private struct MacTaskSchedulePresentation: Identifiable {
    let id: UUID
    let projectID: UUID?
}

struct MacTaskConnectionPresentation: Identifiable {
    let owner: MacTaskRemoteConnectionsOwner
    let catalog: MacRemoteConnectionsCatalog
    var id: UUID { owner.taskID }
}

struct MacWorkspaceRootView: View {
    #if FLOE_MAC_HOST_SMOKE
    static var smokeTaskCenterFrame: CGRect?
    static var smokeNewTaskFrame: CGRect?
    static var smokeTemporaryFrame: CGRect?
    static var smokeSpaceProjectPickerFrame: CGRect?
    static var smokeSidebarFrames: [String: CGRect] = [:]
    static let smokeRevealProjectRow = Notification.Name("FloeWorkbenchSmokeRevealProjectRow")
    #endif
    @ObservedObject var workspace: HostAgentWorkspace
    let openSettings: () -> Void
    let openModelSettings: () -> Void
    let openPermissionSettings: () -> Void
    let openToolbox: (String) -> Void
    let openTerminal: (UUID, WorkspaceRecord) throws -> MacTaskTerminalOwner?
    let openConnections: (MacTaskTerminalOwner) -> MacTaskConnectionPresentation?
    let settingsContent: () -> AnyView
    let imageContent: (((URL) -> Bool)?) -> AnyView
    let creativeContent: (((URL) async -> Bool)?) -> AnyView
    var remembersFileRoot = true
    @ObservedObject var draftStore: MacWorkspaceDraftStore
    @ObservedObject var browserWorkbench: MacBrowserWorkbenchController
    let temporaryChat: MacTemporaryChatModel
    @AppStorage("floe.mac.workspace.lastConversation") private var lastConversation = ""
    @AppStorage("floe.mac.workspace.spaceProject") private var lastSpaceProject = ""
    @AppStorage("floe.mac.workspace.spaceFilesRoot") private var spaceFilesRootRaw = ""

    @State private var selectedDestination: MacWorkspaceDestination? = .newTask(nil)
    private var destination: MacWorkspaceDestination? {
        get { selectedDestination }
        nonmutating set {
            guard newValue != selectedDestination else { return }
            if selectedDestination == .temporary { temporaryChat.discard() }
            if newValue == .temporary { temporaryChat.begin() }
            selectedDestination = newValue
        }
    }
    @State private var requestedConversation: UUID?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var imageReturnDestination: MacWorkspaceDestination = .space(.toolbox)
    @State private var creativeReturnDestination: MacWorkspaceDestination?
    @State private var creativeTaskBinding: (owner: UUID, workspace: UUID)?
    @State private var browserReturnDestination: MacWorkspaceDestination?
    @State private var restoredInitialDestination = false
    @State private var inspector: MacTaskInspector?
    @State private var currentTerminal: MacTaskTerminalOwner?
    @State private var currentConnections: MacTaskConnectionPresentation?
    @State private var remoteSheet: MacTaskConnectionPresentation?
    @State private var showTerminalError = false
    @State private var taskPermissions: MacTaskPermissionsPresentation?
    @State private var taskSchedule: MacTaskSchedulePresentation?
    @State private var contextUsage: ThreadUsageSummary?
    @State private var showsContextUsage = false
    @State private var browserExpanded = false
    @State private var compactDetail = false
    @State private var inspectorWidth: CGFloat = 340
    @GestureState private var dividerTranslation: CGFloat = 0
    @State private var showHistorySearch = false
    @FocusState private var historySearchFocused: Bool
    @State private var historySearch = ""
    @State private var searchResultTarget: (conversation: UUID, message: UUID)?
    @State private var conversationFindRequest: UUID?
    @State private var fileFindRequest: UUID?
    @State private var taskCenterFindRequest: UUID?
    @State private var toolboxFindRequest: UUID?
    @State private var taskToRename: ConversationRecord?
    @State private var taskTitle = ""
    @State private var showRename = false
    @State private var showExportError = false
    @State private var isExportingConversation = false
    @State private var showMetadataError = false
    @State private var taskToDelete: ConversationRecord?
    @State private var showDelete = false
    @State private var taskToMove: ConversationRecord?
    @State private var showMove = false
    @State private var showMoveError = false
    @State private var spaceFilesRoot: MacSpaceFilesRoot = .conversations
    @State private var addingProject = false
    @State private var showProjectError = false
    @State private var projectToRename: WorkspaceRecord?
    @State private var projectName = ""
    @State private var showProjectRename = false
    @State private var showProjectFolderError = false
    @State private var displayedFileRoot: WorkspaceRecord?
    @State private var openedFilesPane: AnyHashable?
    @State private var expandedWorkspaceIDs: Set<UUID> = []

    private var boundLayout: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer()
                        sidebarToggle(show: false)
                    }
                    .padding(.trailing, 8)
                    .frame(minHeight: FloeTheme.minimumTarget + 8)
                    .background { titlebarDragArea }
                }
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
                .ignoresSafeArea(.container, edges: .top)
        } detail: {
            workspacePanes
                .ignoresSafeArea(.container, edges: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .coordinateSpace(name: "floe.workbench.window")
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $workspace.isSettingsPresented, content: settingsContent)
        .sheet(item: $taskPermissions) { presentation in
            MacTaskPermissionsSheet(workspace: workspace, selectionID: presentation.id, isDraft: presentation.isDraft)
        }
        .sheet(item: $taskSchedule) { presentation in
            MacTaskScheduleView(center: workspace.taskSchedules, workspace: workspace, projectID: presentation.projectID,
                                originTaskID: presentation.id, openTask: openTask)
        }
        .sheet(item: $remoteSheet) { presentation in
            MacRemoteConnectionsView(owner: presentation.owner, catalog: presentation.catalog)
                .frame(width: 800, height: 570)
        }
        .onChange(of: workspace.draftSelectionID) { _, selection in
            if taskPermissions?.id != selection { taskPermissions = nil }
        }
        .onChange(of: workspace.notificationTaskID, initial: true) { _, _ in openNotifiedTask() }
        .onChange(of: workspace.windowCommand?.id, initial: true) {
            guard let command = workspace.windowCommand else { return }
            workspace.windowCommand = nil
            switch command.action {
            case .newTask: startNewTask()
            case .findTask: findInActiveView()
            case .findTaskTitles: focusTaskSearch()
            case .toggleFiles: toggleInspector()
            case .openSpace(let page): destination = .space(page)
            case .stopTask: workspace.stop()
            }
        }
        .disabled(workspace.isTerminating)
        .task { await workspace.prepare() }
        .task(id: workspace.isReady) {
            guard workspace.isReady, !restoredInitialDestination else { return }
            restoredInitialDestination = true
            // Restore the Space Files root (default conversations directory,
            // explicit project, or the remembered ad-hoc folder), migrating
            // the pre-project-UX remembered project when present.
            if remembersFileRoot {
                spaceFilesRoot = MacSpaceFilesRoot.restored(
                    raw: spaceFilesRootRaw.isEmpty ? nil : spaceFilesRootRaw,
                    legacyProjectRaw: lastSpaceProject,
                    projects: projects,
                    hasRememberedCustomFolder: UserDefaults.standard
                        .data(forKey: MacSpaceFilesRoot.customBookmarkKey) != nil,
                    remembers: remembersFileRoot)
            }
            openNotifiedTask()
            guard destination == .newTask(nil) else { return }
            if remembersFileRoot, let savedID = UUID(uuidString: lastConversation),
               workspace.conversations.contains(where: { $0.id == savedID && $0.isVisibleInOrdinaryList }) {
                destination = .conversation(savedID)
            } else if workspace.selectedID != nil {
                await workspace.select(nil)
            }
        }
        .task(id: requestedConversation) {
            guard !Task.isCancelled, workspace.isReady, let id = requestedConversation,
                  destination == .conversation(id), id != workspace.selectedID else { return }
            workspace.clearStagedAttachments()
            await workspace.select(id)
        }
        .onDisappear { draftStore.flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            draftStore.flushBeforeClosing()
        }
        .onChange(of: workspace.admittedDraftID) { _, id in
            if let id, case .newTask = destination, workspace.selectedID == id {
                destination = .conversation(id)
            }
        }
        .modifier(BrowserWorkbenchNavigation(browser: browserWorkbench, openURL: openInWorkbenchBrowser,
                                             show: showWorkbenchBrowser, returnToTask: returnFromWorkbenchBrowser))
        .onChange(of: browserWorkbench.taskPresentRequest?.nonce) { _, _ in
            guard let request = browserWorkbench.taskPresentRequest,
                  visibleTaskOwner == request.owner else { return }
            inspector = .browser(request.owner)
        }
        .onChange(of: destination) { previous, newDestination in
            taskPermissions = nil
            draftStore.flush()
            if newDestination == .creative {
                creativeReturnDestination = previous
                let cameFromTask = switch previous {
                case .conversation(let id): id == workspace.selectedID
                case .newTask: workspace.selectedID == nil
                default: false
                }
                creativeTaskBinding = cameFromTask
                    ? workspace.fileWorkspaceForCurrentTask.map { (workspace.attachmentOwnerID, $0.id) }
                    : nil
            } else if previous == .creative {
                creativeReturnDestination = nil
                creativeTaskBinding = nil
            }
            if newDestination != searchResultTarget.map({ .conversation($0.conversation) }) { searchResultTarget = nil }
            conversationFindRequest = nil
            fileFindRequest = nil
            toolboxFindRequest = nil
            taskCenterFindRequest = nil
            if case .conversation(let id) = newDestination { requestedConversation = id }
            else { requestedConversation = nil }
            #if FLOE_MAC_HOST_SMOKE
            workspace.smokeSpacePage = activeSpacePage
            #endif
            if newDestination == nil { destination = .taskCenter }
            if !showsTask { inspector = nil }
            if let owner = inspector?.ownerID, owner != visibleTaskOwner { closeInspector() }
            showsContextUsage = false
            contextUsage = nil
            guard remembersFileRoot else { return }
            if case .conversation(let id) = newDestination { lastConversation = id.uuidString }
            if case .newTask = newDestination { lastConversation = "" }
        }
        .onChange(of: showsTask, initial: true) { _, active in
            workspace.windowShowsTask = active
        }
        .onChange(of: inspector) { _, _ in browserExpanded = false }
        #if FLOE_MAC_HOST_SMOKE
        .onChange(of: browserVisible, initial: true) { _, shown in browserWorkbench.isPresented = shown }
        #endif
        .onChange(of: preferredFileRoot, initial: true) { _, root in
            if !workspace.hasPendingWorkspaceFileChanges { displayedFileRoot = root }
        }
        .onChange(of: filesVisible, initial: true) { _, visible in
            if visible { openedFilesPane = filesPaneIdentity }
        }
        .onChange(of: filesPaneIdentity) { _, identity in
            openedFilesPane = filesVisible ? identity : nil
        }
    }

    var body: some View {
        boundLayout
        .alert("mac.workspace.rename", isPresented: $showRename) {
            TextField("mac.workspace.taskName", text: $taskTitle)
            Button("host.chat.cancel", role: .cancel) {}
            Button("host.chat.save") {
                guard let task = taskToRename else { return }
                let title = taskTitle
                updateTask(id: task.id, change: .rename(title))
            }
        }
        .alert("mac.workspace.exportFailed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        }
        .alert(workspaceText("终端暂不可用", "Terminal Unavailable"), isPresented: $showTerminalError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspaceText("请检查任务目录，或先结束此任务已打开的终端。", "Check the task folder, or stop this task’s open terminal first."))
        }
        .alert("mac.workspace.saveFailed", isPresented: $showMetadataError) {
            Button("OK", role: .cancel) {}
        }
        .alert("mac.workspace.moveFailed", isPresented: $showMoveError) {
            Button("OK", role: .cancel) {}
        }
        .alert("host.chat.workspaceSaveFailed", isPresented: $showProjectError) {
            Button("OK", role: .cancel) {}
        }
        .alert("mac.workspace.renameProject", isPresented: $showProjectRename, presenting: projectToRename) { project in
            TextField("mac.workspace.projectName", text: $projectName)
            Button("host.chat.cancel", role: .cancel) {}
            Button("host.chat.save") {
                let name = projectName
                Task { if !(await workspace.renameProject(project.id, name: name)) { showProjectError = true } }
            }
            .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projectName.utf8.count > 200)
        }
        .alert("mac.workspace.projectFolderUnavailable", isPresented: $showProjectFolderError) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog("mac.workspace.moveTask", isPresented: $showMove, presenting: taskToMove) { task in
            ForEach(workspace.workspaces.filter { $0.kind == .project }) { project in
                Button { moveTask(task.id, to: project.id) } label: { Text(verbatim: project.name) }
            }
            Button("mac.workspace.moveToPersonal") { moveTask(task.id, to: nil) }
            Button("host.chat.cancel", role: .cancel) {}
        } message: { task in
            Text(task.workbenchDisplayTitle)
        }
        .alert(workspaceText("删除任务？", "Delete Task?"), isPresented: $showDelete, presenting: taskToDelete) { task in
            Button("host.chat.cancel", role: .cancel) {}
            Button(workspaceText("删除任务", "Delete Task"), role: .destructive) {
                updateTask(id: task.id, change: .delete)
            }
        } message: { task in
            Text(workspaceText("「\(task.title)」及其会话记录将被永久删除。",
                               "“\(task.title)” and its conversation history will be deleted permanently."))
        }
    }

    private var workspacePanes: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let compact = width < 760
            let fullPanel = showsSpaceFiles || (showsTaskInspector && (compact || browserExpanded))
            let split = showsTaskInspector && !fullPanel
            let panelWidth = fullPanel ? width : (split ? clampedInspectorWidth(inspectorWidth - dividerTranslation, in: width) : 0)
            VStack(spacing: 0) {
                // The native window controls stay at the leading edge when the split collapses.
                header(leadingWindowInset: max(0, 84 - geometry.frame(in: .named("floe.workbench.window")).minX))
                Divider()
                HStack(spacing: 0) {
                    detail
                        .frame(width: max(0, width - panelWidth - (split ? 6 : 0)))
                        .frame(maxHeight: .infinity)
                        .clipped()
                        .opacity(fullPanel ? 0 : 1)
                        .disabled(fullPanel)
                        .allowsHitTesting(!fullPanel)
                        .accessibilityHidden(fullPanel)
                    if split { inspectorDivider(in: width) }
                    inspectorPane
                        .frame(width: panelWidth)
                        .frame(maxHeight: .infinity)
                        .clipped()
                }
            }
            .frame(width: width, height: geometry.size.height)
            .background(FloeTheme.readingSurface)
            .onChange(of: compact, initial: true) { _, isCompact in compactDetail = isCompact }
        }
        #if FLOE_MAC_HOST_SMOKE
        .onChange(of: inspector == .files, initial: true) { _, shown in
            workspace.smokeInspectorShown = shown
        }
        .onChange(of: filesTakeDetail && showsTask, initial: true) { _, presented in
            workspace.smokeFilesTakeDetail = presented
        }
        #endif
    }

    private var inspectorPane: some View {
        ZStack {
            if filesVisible || openedFilesPane == filesPaneIdentity || workspace.hasPendingWorkspaceFileChanges {
                filesPane
            }
            if showsTask, let inspector { taskInspector(inspector) }
        }
    }

    @ViewBuilder
    private func taskInspector(_ panel: MacTaskInspector) -> some View {
        switch panel {
        case .files:
            EmptyView()
        case .browser(let owner):
            browserDetail(owner: owner, close: closeInspector)
        case .changes(let id):
            taskActivity(id, content: .changes)
        case .progress(let id):
            taskActivity(id, content: .progress)
        case .childAgents(let id):
            VStack(spacing: 0) {
                inspectorHeader(FloeTaskInspectorItem.childAgents.titleKey)
                MacChildTasksView(controller: workspace.childSubagents, conversationID: id, isInspector: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .terminal(let owner):
            if let currentTerminal, currentTerminal.taskID == owner {
                VStack(spacing: 0) {
                    inspectorHeader(FloeTaskInspectorItem.terminal.titleKey) {
                        if let currentConnections, currentConnections.id == owner {
                            Button(workspaceText("远程主机", "Remote Hosts"), systemImage: "network") {
                                remoteSheet = currentConnections
                            }
                            .accessibilityIdentifier("workspace.terminal.remoteHosts")
                        }
                    }
                    MacTaskTerminalInspector(owner: currentTerminal, connections: currentConnections?.owner, catalog: currentConnections?.catalog)
                        .id(owner)
                        .task { await currentConnections?.catalog.reload() }
                }
            }
        }
    }

    private func taskActivity(_ id: UUID, content: MacTaskActivityInspectorView.Content) -> some View {
        let title = content == .changes ? FloeTaskInspectorItem.changes.titleKey : FloeTaskInspectorItem.progress.titleKey
        let reader: MacTaskActivityArtifactReader?
        if content == .changes {
            reader = { receipt in try readTaskChange(receipt) }
        } else {
            reader = nil
        }
        return VStack(spacing: 0) {
            inspectorHeader(title)
            if workspace.selectedID == id, !workspace.isLoadingHistory {
                if content == .progress, let output = workspace.liveShellOutput(for: id).last {
                    MacLiveShellOutput(output: output, stop: workspace.stop)
                }
                MacTaskActivityInspectorView(
                    snapshot: .init(runs: workspace.transcriptRuns, events: workspace.transcriptEventsByRun),
                    content: content, artifactReader: reader
                )
                .id(inspector)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func inspectorHeader(_ title: LocalizedStringKey) -> some View {
        inspectorHeader(title) { EmptyView() }
    }

    private func inspectorHeader<Actions: View>(_ title: LocalizedStringKey, @ViewBuilder actions: () -> Actions) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            actions()
            Button(action: closeInspector) { Image(systemName: "sidebar.trailing") }
                .accessibilityLabel(workspaceText("隐藏检查器", "Hide Inspector"))
        }.padding(10)
    }

    private func readTaskChange(_ receipt: ToolArtifactReference) throws -> Data? {
        let parts = receipt.relativePath.split(separator: "/")
        guard parts.count == 3, let runID = UUID(uuidString: String(parts[1])),
              workspace.transcriptRuns.contains(where: { $0.id == runID && $0.conversationID == workspace.selectedID }) else { return nil }
        return try FloeArtifactStore.verifiedData(receipt.relativePath, allowed: [.change], maxBytes: 512 * 1024,
                                                   expectedSHA256: receipt.sha256, root: workspace.runOutputArtifactRoot)
    }

    private func clampedInspectorWidth(_ requested: CGFloat, in width: CGFloat) -> CGFloat {
        min(max(requested, 280), min(520, width - 436))
    }

    private func inspectorDivider(in width: CGFloat) -> some View {
        Divider()
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.set() }
                else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($dividerTranslation) { value, translation, _ in translation = value.translation.width }
                    .onEnded { value in
                        inspectorWidth = clampedInspectorWidth(inspectorWidth - value.translation.width, in: width)
                    }
            )
            .accessibilityHidden(true)
    }

    private var filesPane: some View {
        let selectionID = workspace.draftSelectionID
        let rootID = displayedFileRoot?.id
        return MacWorkspaceFilesView(
            insertInDraft: { text in
                guard selectionID == workspace.draftSelectionID, rootID == displayedFileRoot?.id else { return }
                insertFileText(text)
            },
            canInsertInDraft: canUseFileInTask,
            remembersRoot: remembersFileRoot && showsSpaceFiles,
            fixedRootBookmark: displayedFileRootBookmark,
            fixedRootURL: spaceFilesFixedURL,
            fixedPrivateWorkspace: displayedFileRoot?.kind == .privateTask ? displayedFileRoot : nil,
            privateTaskRootBase: workspace.personalTaskLeaseBase,
            managedConversationsRoot: workspace.defaultConversationsDirectory,
            recentlyDeletedDirectory: workspace.personalTaskLeaseBase.appendingPathComponent("RecentlyDeleted", isDirectory: true),
            workspaceRevision: workspace.workspaceRevision,
            taskAttachmentURLs: Set(workspace.stagedAttachments.map(\.url)),
            protectedDraftFiles: { draftStore.attachmentURLs.union(workspace.stagedAttachments.map(\.url)) },
            onFolderPicked: registerPickedFolder,
            onAttachmentsChanged: { files in
                guard selectionID == workspace.draftSelectionID, rootID == displayedFileRoot?.id else { return }
                updateFileAttachments(files)
            },
            canChangeFiles: { !workspace.isTerminating },
            onPendingChanges: { pending in
                guard workspace.hasPendingWorkspaceFileChanges != pending else { return }
                workspace.hasPendingWorkspaceFileChanges = pending
                if !pending { displayedFileRoot = preferredFileRoot }
            },
            layout: showsSpaceFiles ? .adaptive : .inspector,
            findRequest: fileFindRequest,
            rootFolderLabels: spaceRootFolderLabels,
            requiresTaskRoot: showsTask && (displayedFileRoot == nil || !currentTaskFileRootUsable),
            onChooseProject: chooseProjectForTask
        )
        .id(filesPaneIdentity)
        .opacity(filesVisible ? 1 : 0)
        .disabled(!filesVisible)
        .allowsHitTesting(filesVisible)
        .accessibilityHidden(!filesVisible)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sidebarNavigation.id("sidebar.navigation")
                        Divider().padding(.horizontal, 14)
                        sidebarHistory
                    }
                }
                .onChange(of: showHistorySearch) { _, shown in
                    if shown { proxy.scrollTo("sidebar.navigation", anchor: .top) }
                }
                #if FLOE_MAC_HOST_SMOKE
                .onReceive(NotificationCenter.default.publisher(for: Self.smokeRevealProjectRow)) { note in
                    guard note.object as? HostAgentWorkspace === workspace,
                          let id = note.userInfo?["project"] as? UUID else { return }
                    proxy.scrollTo(id, anchor: .top)
                }
                #endif
            }
            Divider()
            Button(action: openSettings) {
                Label("more.settings", systemImage: "gearshape")
                    .labelStyle(MacWorkspaceLabelStyle())
                    .font(.body)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.settings")
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
    }

    private var sidebarNavigation: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                if showHistorySearch {
                    TextField("mac.workspace.findTask", text: $historySearch)
                        .textFieldStyle(.roundedBorder)
                        .focused($historySearchFocused)
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { historySearchFocused = true })
                        .accessibilityIdentifier("workspace.taskSearch")
                        .onAppear {
                            historySearchFocused = true
                            #if FLOE_MAC_HOST_SMOKE
                            workspace.smokeTaskSearchMounted = true
                            #endif
                        }
                        #if FLOE_MAC_HOST_SMOKE
                        .onDisappear { workspace.smokeTaskSearchMounted = false }
                        #endif
                        .onSubmit {
                            guard !historySearchQuery.isEmpty else { return }
                            if let result = filteredConversations.first { openTask(result.id) }
                            else { searchConversationContent() }
                        }
                        .onExitCommand(perform: closeTaskSearch)
                    Button(action: closeTaskSearch) {
                        Label("host.chat.cancel", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .macWorkspaceIconTarget()
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button(action: focusTaskSearch) {
                        Label("mac.workspace.findTask", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .font(.callout)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("mac.workspace.findTask")
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: FloeTheme.minimumTarget)
            sidebarLink(.newTask(nil), title: "workbench.new_task", icon: "square.and.pencil")
                .accessibilityIdentifier("sidebar.workbench.new_task")
                .disabled(!canSelectTask)
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { Self.smokeNewTaskFrame = $0 })
                #endif
            sidebarLink(.taskCenter, title: "app.floe_agent_app.task_center", icon: "checklist")
                .accessibilityIdentifier("workspace.taskCenter")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { Self.smokeTaskCenterFrame = $0 })
                #endif
            sidebarLink(.space(.files), title: "space.title", icon: "square.stack.3d.up")
                .accessibilityIdentifier("workspace.space")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { workspace.smokeSpaceFrame = $0 })
                #endif
            sidebarLink(.creative, title: "mac.creative.title", icon: "paintpalette")
                .accessibilityIdentifier("workspace.creative")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { workspace.smokeCreativeFrame = $0 })
                #endif
        }
        .padding(8)
    }

    private var sidebarHistory: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            if historySearchQuery.isEmpty {
                projectSidebar
                personalHistory
            } else {
                Button(action: searchConversationContent) {
                    Label("mac.workspace.searchConversationContent", systemImage: "text.magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.horizontal, 8)
                ForEach(filteredConversations) { conversationSidebarRow($0) }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private var projectSidebar: some View {
        HStack {
            sidebarHeading("workspace.title")
            Spacer(minLength: 4)
            Button(action: chooseProjectFolder) {
                Label("mac.workspace.addProject", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .macWorkspaceIconTarget()
            }
            .buttonStyle(.borderless)
            .help("mac.workspace.addProject")
            .accessibilityIdentifier("workspace.addProject")
            .disabled(!canChooseProject)
        }
        .padding(.trailing, 2)
        if workspace.projectTasksUnavailable {
            HStack {
                Text("mac.workspace.projectTasksUnavailable").foregroundStyle(.secondary)
                Button { Task { await workspace.retryProjectTasks() } } label: {
                    Text("host.chat.tryAgain")
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.leading, 9)
        }
        ForEach(projects) { project in
            projectRow(project)
                .padding(.horizontal, 2)
                .disabled(!canSelectTask)
                #if FLOE_MAC_HOST_SMOKE
                .id(project.id)
                #endif
        }
    }

    private func projectRow(_ project: WorkspaceRecord) -> some View {
        let members = workspace.projectTaskMembership?[project.id] ?? []
        let row = FloeWorkbenchProjectRow(
            workspaceID: project.id, name: project.name,
            isExpanded: Binding(
                get: { expandedWorkspaceIDs.contains(project.id) },
                set: { expanded in
                    if expanded { expandedWorkspaceIDs.insert(project.id) }
                    else { expandedWorkspaceIDs.remove(project.id) }
                }
            ),
            openWorkspace: { startNewTask(in: project.id) }
        ) {
            Button { startNewTask(in: project.id) } label: {
                Image(systemName: "plus")
                    .macWorkspaceIconTarget()
            }
            .buttonStyle(.borderless)
            .help(workspaceText("在\(project.name)新建任务", "New Task in \(project.name)"))
            .accessibilityLabel(workspaceText("在\(project.name)新建任务", "New Task in \(project.name)"))
            .accessibilityIdentifier("sidebar.workspace.new.\(project.id.uuidString)")
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader { frame in
                workspace.smokeProjectNewTaskFrames[project.id] = frame
            })
            #endif
        } content: {
            ForEach(filteredConversations.filter { members.contains($0.id) }) {
                conversationSidebarRow($0)
            }
        }
        #if FLOE_MAC_HOST_SMOKE
        var instrumented = row
        instrumented.onDisclosureFrame = { frame in Self.smokeSidebarFrames["sidebar.workspace.disclosure." + project.id.uuidString] = frame }
        instrumented.onOpenFrame = { frame in workspace.smokeProjectNameFrames[project.id] = frame }
        return instrumented.contextMenu { projectActions(project) }
        #else
        return row.contextMenu { projectActions(project) }
        #endif
    }

    @ViewBuilder private func projectActions(_ project: WorkspaceRecord, includeBrowse: Bool = true) -> some View {
        Button("mac.workspace.projectTasks", systemImage: "checklist") { destination = .projectTasks(project.id) }
            .disabled(workspace.hasPendingWorkspaceFileChanges)
        if includeBrowse {
            Button("mac.workspace.browseFiles", systemImage: "folder") {
                selectSpaceRoot(.project(project.id))
            }
            .disabled(!canSwitchSpaceRoot(to: .project(project.id)))
        }
        Button("mac.workspace.revealProjectFolder", systemImage: "arrow.up.forward.app") { revealProjectFolder(project) }
        Button("workbench.new_task", systemImage: "square.and.pencil") { startNewTask(in: project.id) }
            .disabled(!canSelectTask)
        Divider()
        Button("mac.workspace.renameProject", systemImage: "pencil") {
            projectToRename = project
            projectName = project.name
            showProjectRename = true
        }
        .disabled(!workspace.isReady || workspace.isTerminating)
    }

    @ViewBuilder
    private var personalHistory: some View {
        if workspace.projectTaskMembership != nil || workspace.workspaces.isEmpty {
            let projectIDs = Set(workspace.projectTaskMembership?.values.flatMap { $0 } ?? [])
            let personal = filteredConversations.filter { !projectIDs.contains($0.id) }
            if !personal.isEmpty {
                sidebarHeading("settings.all_workspaces_files_view.chat")
                ForEach(personal) { conversationSidebarRow($0) }
            }
        }
    }

    private func sidebarHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 9)
            .padding(.vertical, 5)
            .accessibilityAddTraits(.isHeader)
    }

    private func conversationSidebarRow(_ conversation: ConversationRecord) -> some View {
        HStack(spacing: 2) {
            sidebarLink(.conversation(conversation.id), title: LocalizedStringKey(conversation.workbenchDisplayTitle),
                        icon: conversation.isPinned ? "pin" : "bubble.left", conversationTitle: conversation.workbenchDisplayTitle)
                .disabled(!canSelectTask && workspace.selectedID != conversation.id)
                .help(conversation.workbenchDisplayTitle)
            Menu {
                conversationActions(conversation)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .macWorkspaceIconTarget()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(workspaceText("\(conversation.workbenchDisplayTitle)的操作", "Actions for \(conversation.workbenchDisplayTitle)"))
            .help(workspaceText("任务操作", "Task Actions"))
            .accessibilityIdentifier("sidebar.task.actions.\(conversation.id.uuidString)")
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader { frame in
                Self.smokeSidebarFrames["sidebar.task.actions." + conversation.id.uuidString] = frame
            })
            #endif
        }
        .contextMenu { conversationActions(conversation) }
    }

    @ViewBuilder private func conversationActions(_ conversation: ConversationRecord) -> some View {
        let changing = !canSelectTask || workspace.isTaskRunning(conversation.id)
        if workspace.isTaskRunning(conversation.id) {
            Button("host.chat.stop", systemImage: "stop.circle") { workspace.stopTask(conversation.id) }
        }
        Button(LocalizedStringKey(conversation.isPinned ? "mac.workspace.unpin" : "mac.workspace.pin"),
               systemImage: conversation.isPinned ? "pin.slash" : "pin") {
            updateTask(id: conversation.id, change: .pin(!conversation.isPinned))
        }
        .disabled(changing)
        Button("mac.workspace.rename", systemImage: "pencil") {
            taskToRename = conversation
            taskTitle = conversation.title
            showRename = true
        }
        .disabled(changing)
        Button("mac.workspace.moveTask", systemImage: "folder") { chooseTaskWorkspace(conversation) }
            .disabled(changing)
        Button("mac.workspace.archiveTask", systemImage: "archivebox") {
            updateTask(id: conversation.id, change: .archive(true))
        }
        .disabled(changing)
        Button(workspaceText("删除任务…", "Delete Task…"), systemImage: "trash", role: .destructive) {
            confirmDelete(conversation)
        }
        .disabled(changing)
    }

    private func sidebarLink(_ route: MacWorkspaceDestination, title: LocalizedStringKey, icon: String,
                             conversationTitle: String? = nil) -> some View {
        sidebarLinkButton(route) {
            if let conversationTitle {
                Label { Text(verbatim: conversationTitle) } icon: { Image(systemName: icon) }
            } else {
                FloeWorkbenchSidebarItem(title: title, systemImage: icon)
            }
        }
    }

    private func sidebarLinkButton<Label: View>(_ route: MacWorkspaceDestination,
                                                @ViewBuilder label: @escaping () -> Label) -> some View {
        let selected = destination == route || (route == .space(.files) && isInSpace)
        let font: Font = if case .conversation = route { .callout } else { .body }
        return Button {
            if case .newTask(let projectID) = route { startNewTask(in: projectID) }
            else { destination = route }
        } label: {
            HStack(spacing: 6) {
                label()
                if case .conversation(let id) = route, workspace.isTaskRunning(id) {
                    Spacer(minLength: 0)
                    let approval = workspace.hasPendingApproval(in: id)
                    let question = workspace.isWaitingForAnswer(in: id)
                    Image(systemName: approval ? "hand.raised.fill" : (question ? "questionmark.bubble.fill" : "circle.fill"))
                        .font(.caption2)
                        .foregroundStyle(approval || question ? .orange : .accentColor)
                        .accessibilityHidden(true)
                }
            }
            .labelStyle(MacWorkspaceLabelStyle())
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .font(font.weight(selected ? .medium : .regular))
            .frame(minHeight: FloeTheme.minimumTarget)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var historySearchQuery: String { historySearch.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredConversations: [ConversationRecord] {
        let query = historySearchQuery
        return workspace.conversations.filter {
            $0.isVisibleInOrdinaryList && (query.isEmpty || $0.workbenchDisplayTitle.localizedStandardContains(query))
        }
    }

    private var canSelectTask: Bool {
        workspace.isReady && !workspace.isTerminating && !workspace.isAcceptingPlan
    }

    private var canEditVisibleDraft: Bool { canSelectTask && !workspace.isSending && !workspace.isLoadingHistory }

    private var projects: [WorkspaceRecord] { workspace.workspaces.filter { $0.kind == .project } }

    private var taskCenterProjectID: UUID? {
        if case .projectTasks(let id) = destination { return id }
        return nil
    }

    private var spaceProject: WorkspaceRecord? {
        if case .project(let id) = spaceFilesRoot { return projects.first { $0.id == id } }
        return nil
    }

    private var selectedTaskProject: WorkspaceRecord? {
        if workspace.selectedID != nil {
            let owner = workspace.selectedConversationWorkspace
            return owner?.kind == .project ? owner : nil
        }
        return projects.first { $0.id == workspace.selectedWorkspaceID }
    }

    /// The file workspace of the current task: the explicit project when the
    /// task is bound to one, otherwise the host-provided per-task workspace
    /// (every conversation, including the unsaved draft, owns one). Nil when
    /// the host cannot resolve the root; the task inspector then shows its
    /// unavailable state — never a saved or ad-hoc folder.
    private var currentTaskFileRecord: WorkspaceRecord? { workspace.fileWorkspaceForCurrentTask }

    private var preferredFileRoot: WorkspaceRecord? {
        switch destination {
        case .conversation(let id) where id == workspace.selectedID:
            return currentTaskFileRecord
        case .newTask where workspace.selectedID == nil:
            return currentTaskFileRecord
        case .space(.files):
            return spaceProject
        default:
            return nil
        }
    }

    private var displayedFileRootBookmark: Data? {
        guard let record = displayedFileRoot, !record.rootBookmark.isEmpty else { return nil }
        return record.rootBookmark
    }

    /// The Space files default: the host's app-owned conversations directory,
    /// only while Space is the visible destination and no explicit project is
    /// selected. Task destinations always root at the per-task record.
    private var spaceFilesFixedURL: URL? {
        guard case .space(.files) = destination, case .conversations = spaceFilesRoot else { return nil }
        return workspace.defaultConversationsDirectory
    }

    /// Ownership labels for the immediate per-task folders of the default
    /// conversations root: real folder name (task UUID) → known conversation
    /// title. Space + default root only; project roots and task inspectors
    /// receive none, so nothing else is ever relabeled.
    private var spaceRootFolderLabels: [String: String] {
        guard case .space(.files) = destination, case .conversations = spaceFilesRoot else { return [:] }
        return workspace.conversations.reduce(into: [:]) { labels, conversation in
            labels[conversation.id.uuidString] = conversation.workbenchDisplayTitle
        }
    }

    /// Keep an editor mounted against its displayed scope until pending file
    /// work finishes. The new scope gets its own browser instance afterward.
    private var filesPaneIdentity: AnyHashable {
        if let record = displayedFileRoot { return AnyHashable(record.id) }
        return AnyHashable(spaceFilesRoot)
    }

    private var currentTaskFileRootUsable: Bool {
        guard let record = currentTaskFileRecord else { return false }
        return record.kind == .privateTask
            ? record.internalRelativePath != nil && record.isDisposableTaskWorkspace
            : !record.rootBookmark.isEmpty
    }

    private var canUseFileInTask: Bool {
        guard canEditVisibleDraft, !showsTask || destinationConversationID == workspace.selectedID else { return false }
        return currentTaskFileRootUsable && displayedFileRoot?.id == currentTaskFileRecord?.id
    }

    private var activeSpacePage: MacSpacePage? {
        if case .space(let page) = destination { return page }
        return nil
    }

    private var isInSpace: Bool {
        activeSpacePage != nil || (destination == .images && imageReturnDestination == .space(.toolbox))
    }

    private var showsSpaceFiles: Bool { activeSpacePage == .files }
    private var filesVisible: Bool { showsSpaceFiles || (showsTask && inspector == .files) }
    private var filesTakeDetail: Bool { showsSpaceFiles || (inspector == .files && inspectorTakesDetail) }
    private var showsTaskInspector: Bool { showsTask && inspector != nil }
    private var inspectorTakesDetail: Bool { showsTaskInspector && (compactDetail || browserExpanded) }
    private var browserVisible: Bool {
        if showsTask, case .browser = inspector { return true }
        return destination == .browser
    }

    private var showsTask: Bool {
        switch destination {
        case .newTask, .conversation: true
        default: false
        }
    }

    private var destinationConversationID: UUID? {
        if case .conversation(let id) = destination { return id }
        return nil
    }

    private var visibleTaskOwner: UUID? {
        switch destination {
        case .conversation(let id) where id == workspace.selectedID: id
        case .newTask where workspace.selectedID == nil: workspace.attachmentOwnerID
        default: nil
        }
    }

    private func taskDraft(for id: UUID) -> Binding<String> {
        Binding(get: { draftStore.text(for: id) }, set: { draftStore.setText($0, for: id) })
    }

    private var recoverableDrafts: [(id: UUID, date: Date)] {
        var known = workspace.idsWithRuns
        known.formUnion(workspace.conversations.map(\.id))
        known.insert(workspace.uncommittedDraftID)
        return draftStore.uncommittedDrafts(excluding: known)
    }

    private var title: String {
        switch destination {
        case .newTask: String(localized: "mac.workspace.newTask")
        case .conversation(let id): workspace.conversations.first { $0.id == id }?.workbenchDisplayTitle
            ?? String(localized: "mac.workspace.untitledTask")
        case .projectTasks(let id): projects.first { $0.id == id }?.name ?? String(localized: "mac.workspace.taskCenter")
        case .space: String(localized: "space.title")
        case .creative: String(localized: "mac.creative.title")
        case .images: String(localized: "mac.settings.images")
        case .temporary: workspaceText("临时聊天", "Temporary Chat")
        case .browser: workspaceText("浏览器", "Browser")
        default: String(localized: "mac.workspace.taskCenter")
        }
    }

    private var titlebarDragArea: some View {
        Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
            .accessibilityHidden(true)
    }

    private func sidebarToggle(show: Bool) -> some View {
        let label = show ? workspaceText("显示侧边栏", "Show Sidebar") : workspaceText("隐藏侧边栏", "Hide Sidebar")
        return Button {
            withAnimation { sidebarVisibility = show ? .all : .detailOnly }
        } label: {
            FloeWorkbenchControlIcon(systemImage: "sidebar.left")
                .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .accessibilityIdentifier("workspace.sidebar.toggle")
    }

    private func header(leadingWindowInset: CGFloat) -> some View {
        HStack(spacing: 8) {
            if leadingWindowInset > 0 {
                sidebarToggle(show: true)
            }
            if destination == .images || inspectorTakesDetail {
                Button {
                    if destination == .images { destination = imageReturnDestination }
                    else { closeInspector() }
                } label: {
                    Label(LocalizedStringKey(showsTask ? "mac.workspace.backToTask" : "mac.workspace.back"),
                          systemImage: "chevron.left")
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("workspace.detail.back")
            }
            if destination == .creative, let back = creativeReturnDestination {
                Button(action: { destination = back }) {
                    Label("mac.workspace.back", systemImage: "chevron.left")
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("workspace.creative.return")
            }
            if let page = activeSpacePage {
                Picker("space.title", selection: Binding(get: { page }, set: { destination = .space($0) })) {
                    Text("mac.workspace.spaceFiles").tag(MacSpacePage.files)
                    Text("mac.workspace.toolbox").tag(MacSpacePage.toolbox)
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .labelsHidden()
                .frame(width: 168)
                .accessibilityIdentifier("workspace.space.section")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { workspace.smokeSpacePickerFrame = $0 })
                #endif
                if showsSpaceFiles { spaceProjectControl }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.headline).lineLimit(1)
                        .truncationMode(.tail)
                        .help(title)
                    if showsTask, !filesTakeDetail, destinationConversationID == workspace.selectedID,
                       let project = selectedTaskProject {
                        Text(verbatim: project.name)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            headerActions
        }
        .padding(.leading, leadingWindowInset > 0 ? leadingWindowInset : 16)
        .padding(.trailing, 12)
        .frame(minHeight: FloeTheme.minimumTarget + 8)
        .background { titlebarDragArea }
        .background(FloeTheme.chromeMaterial)
    }

    private var spaceProjectControl: some View {
        MacSpaceFilesRootPicker(
            projects: projects,
            root: spaceFilesRoot,
            defaultAvailable: workspace.defaultConversationsDirectory != nil,
            canAddProject: canChooseProject,
            canSwitch: canSwitchSpaceRoot,
            select: selectSpaceRoot,
            addProject: chooseProjectFolder
        ) { project in
            projectActions(project, includeBrowse: false)
        }
        #if FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader { Self.smokeSpaceProjectPickerFrame = $0 })
        #endif
    }

    /// Pending workspace-file edits may only move to the root that is
    /// already displayed; everything else would abandon unsaved work.
    private func canSwitchSpaceRoot(to target: MacSpaceFilesRoot) -> Bool {
        guard workspace.hasPendingWorkspaceFileChanges else { return true }
        if case .project(let id) = target { return displayedFileRoot?.id == id }
        return displayedFileRoot == nil
    }

    private var headerActions: some View {
        HStack(spacing: compactDetail ? 2 : 6) {
            if case .newTask = destination {
                Button { destination = .temporary } label: {
                    FloeWorkbenchControlIcon(systemImage: "bubble.left")
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .disabled(!canSelectTask || workspace.composerProvider == nil)
                .accessibilityLabel(workspaceText("临时聊天", "Temporary Chat"))
                .help(workspaceText("临时聊天", "Temporary Chat"))
                .accessibilityIdentifier("home.temporary.toggle")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { Self.smokeTemporaryFrame = $0 })
                #endif
            }
            if activeSpacePage == .toolbox {
                Button(action: openImageWorkbench) {
                    Label("mac.settings.images", systemImage: "photo.badge.plus")
                        .frame(minHeight: FloeTheme.minimumTarget).contentShape(Rectangle())
                }
                .accessibilityIdentifier("workspace.toolbox.images")
            }
            if showsSpaceFiles {
                Button(workspaceText("画布", "Canvas"), systemImage: "rectangle.and.pencil.and.ellipsis") {
                    destination = .creative
                }
                .accessibilityIdentifier("workspace.space.canvas")
            }
            if workspace.isSending {
                if showsTask {
                    activeTaskStatus
                } else {
                    Button {
                        destination = workspace.selectedID.map(MacWorkspaceDestination.conversation)
                            ?? .newTask(workspace.selectedWorkspaceID)
                    } label: {
                        activeTaskStatus
                    }
                    .help("mac.workspace.returnToActiveTask")
                    .accessibilityLabel("mac.workspace.returnToActiveTask")
                    .accessibilityIdentifier("workspace.returnToActiveTask")
                }
            }
            if !workspace.backgroundTaskIDs.isEmpty {
                Menu {
                    ForEach(workspace.backgroundTaskIDs, id: \.self) { id in
                        Button(workspace.conversations.first { $0.id == id }?.workbenchDisplayTitle
                               ?? String(localized: "mac.workspace.untitledTask")) { openTask(id) }
                    }
                } label: {
                    Label("mac.workspace.backgroundTasks", systemImage: "square.stack")
                        .labelStyle(.iconOnly)
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("mac.workspace.backgroundTasks")
            }
            if case .newTask(let projectID) = destination, !filesTakeDetail {
                let drafts = recoverableDrafts
                if !drafts.isEmpty {
                    let label = workspaceText("恢复未发送草稿", "Recover Unsent Draft")
                    Menu {
                        ForEach(drafts, id: \.id) { draft in
                            Button(draft.date.formatted(date: .abbreviated, time: .standard)) {
                                startNewTask(in: projectID, recovering: draft.id)
                            }
                        }
                    } label: {
                        FloeWorkbenchControlIcon(systemImage: "doc.badge.clock")
                            .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .accessibilityLabel(label)
                    .help(label)
                }
            }
            if showsTask && !inspectorTakesDetail {
                Menu {
                    ForEach(FloeTaskInspectorItem.allCases) { item in
                        if destinationConversationID != nil || [.workspaceFiles, .browser, .terminal].contains(item) {
                            Button(item.titleKey, systemImage: item.icon) { openInspector(item) }
                                .disabled(item == .terminal && !currentTaskFileRootUsable)
                                .accessibilityIdentifier(inspectorEntryID(item))
                        }
                    }
                    if workspace.goal != nil {
                        Button("mac.agent.editGoal", systemImage: "target") {
                            workspace.goalBuilderRequest = UUID()
                        }
                        .disabled(!canSelectTask || destinationConversationID != workspace.selectedID || workspace.isChangingSelectedGoal)
                        .accessibilityIdentifier("workspace.task.editGoal")
                    }
                    if let id = destinationConversationID {
                        Button(workspaceText("定时任务", "Scheduled Tasks"), systemImage: "calendar.badge.clock") {
                            let project = workspace.selectedConversationWorkspace.flatMap { $0.kind == .project ? $0.id : nil }
                            taskSchedule = MacTaskSchedulePresentation(id: id, projectID: project)
                        }
                        .accessibilityIdentifier("workspace.task.schedules")
                    }
                    if showsTaskInspector {
                        Divider()
                        Button(workspaceText("隐藏检查器", "Hide Inspector"), systemImage: "sidebar.trailing", action: closeInspector)
                    }
                } label: {
                    FloeWorkbenchControlIcon(systemImage: "sidebar.trailing")
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help(workspaceText("任务检查器", "Task Inspector"))
                .accessibilityLabel(workspaceText("任务检查器", "Task Inspector"))
                .accessibilityIdentifier("workspace.inspector.menu")
            }
            if let id = destinationConversationID, !inspectorTakesDetail, workspace.hasContextWindow(for: id) {
                Button {
                    showsContextUsage.toggle()
                } label: {
                    ContextUsageRing(fraction: contextUsage?.contextFraction ?? 0)
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("chat.thread_detail_view.context_window")
                .help("chat.thread_detail_view.context_window")
                .popover(isPresented: $showsContextUsage) {
                    Group {
                        if let contextUsage { ContextUsageDetails(summary: contextUsage) }
                        else { ProgressView().padding() }
                    }
                    .task(id: workspace.transcriptLiveRunID) { contextUsage = await workspace.contextUsage(for: id) }
                }
            }
            if case .conversation = destination, !inspectorTakesDetail {
                Button(action: findInActiveView) {
                    FloeWorkbenchControlIcon(systemImage: "magnifyingglass")
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .help("mac.workspace.findConversation")
                .accessibilityLabel("mac.workspace.findConversation")
                .disabled(workspace.isLoadingHistory || destinationConversationID != workspace.selectedID)
                Menu {
                    Button(workspaceText("完整任务（含工具记录）", "Full Task with Tool Records"), systemImage: "doc.badge.gearshape") {
                        exportConversation(.structured)
                    }
                    Button(workspaceText("对话文本", "Conversation Text"), systemImage: "doc.plaintext") {
                        exportConversation(.plainText)
                    }
                    Button(workspaceText("对话 Markdown", "Conversation Markdown"), systemImage: "doc.richtext") {
                        exportConversation(.markdown)
                    }
                } label: {
                    FloeWorkbenchControlIcon(systemImage: "square.and.arrow.up")
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("workspace.conversation.export")
                .help("mac.workspace.exportChat")
                .accessibilityLabel("mac.workspace.exportChat")
                .disabled(!canSelectTask || isExportingConversation || workspace.isLoadingHistory || workspace.isSending
                          || destinationConversationID != workspace.selectedID)
            }
        }
        .buttonStyle(.borderless)
    }

    private var activeTaskStatus: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(runStatusTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var runStatusTitle: LocalizedStringKey {
        if workspace.isStopping || workspace.runPhase == .cancelling {
            return "mac.workspace.runStopping"
        }
        if workspace.pendingApproval != nil { return "mac.agent.waitingForApproval" }
        if workspace.isReviewingApproval { return "mac.permissions.reviewing" }
        if workspace.runPhase == nil { return "mac.workspace.runPreparing" }
        return "mac.workspace.inspector.running"
    }

    private var currentToolImageWorkspace: MacToolImageWorkspace? {
        guard let conversation = destinationConversationID, conversation == workspace.selectedID,
              let owner = workspace.selectedConversationWorkspace else { return nil }
        return .init(conversationID: conversation, workspace: owner, privateTaskRootBase: workspace.personalTaskLeaseBase)
    }

    @ViewBuilder private var detail: some View {
        switch destination {
        case .newTask, .conversation:
            if !workspace.isReady || destinationConversationID == workspace.selectedID {
                let draftOwner = destinationConversationID ?? workspace.attachmentOwnerID
                VStack(spacing: 0) {
                    if draftStore.saveFailed {
                        let language = Locale.preferredLanguages.first ?? "en"
                        ErrorEventView(message: language.hasPrefix("zh") ? "草稿保存失败。" : "The draft could not be saved.")
                            .padding(.horizontal)
                    }
                    HostAgentWorkspaceView(workspace: workspace, workspaceDraft: taskDraft(for: draftOwner),
                                           captureDraftCommit: { draftStore.captureSendCommit(for: draftOwner) },
                                           openModelSettings: openModelSettings, openPermissionSettings: openPermissionSettings,
                                           openFiles: { inspector = .files }, openTaskPermissions: {
                                               taskPermissions = .init(id: workspace.draftSelectionID, isDraft: destinationConversationID == nil)
                                           },
                                           openImageWorkbench: openImageWorkbench,
                                           findRequest: conversationFindRequest,
                                           findConversationID: destinationConversationID,
                                           requestedMessageID: searchResultTarget?.conversation == destinationConversationID ? searchResultTarget?.message : nil,
                                           didHandleSearchResult: { conversation, message in
                                                if searchResultTarget?.conversation == conversation, searchResultTarget?.message == message {
                                                    searchResultTarget = nil
                                                }
                                            })
                        .id(destinationConversationID ?? workspace.attachmentOwnerID)
                        .environment(\.macToolImageWorkspace, currentToolImageWorkspace)
                        .environment(\.openURL, OpenURLAction { url in
                            // Chat content is untrusted model output. http(s)
                            // links open inside the guarded workbench browser;
                            // only explicit safe system schemes keep system
                            // behavior; every other scheme (file, custom,
                            // credential-bearing) is discarded.
                            if MacBrowserAddress.allows(url) {
                                openInWorkbenchBrowser(url)
                                return .handled
                            }
                            if let scheme = url.scheme?.lowercased(), scheme == "mailto" || scheme == "tel" {
                                return .systemAction
                            }
                            return .handled
                        })
                }
            } else {
                ProgressView("host.chat.opening")
            }
        case .temporary:
            MacTemporaryChatView(model: temporaryChat, provider: workspace.composerProvider, search: workspace.webSearch.access,
                                 save: workspace.keepTemporaryConversation,
                                 didKeep: { id in
                                     guard destination == .temporary else { return }
                                     if !temporaryChat.draft.isEmpty { draftStore.setText(temporaryChat.draft, for: id) }
                                     destination = .conversation(id)
                                 })
        case .browser:
            browserDetail(owner: nil, close: returnFromWorkbenchBrowser)
        case .space(.toolbox):
            MacWorkspaceToolboxView(findRequest: toolboxFindRequest, openToolbox: openToolbox)
        case .space(.files): EmptyView()
        case .creative:
            creativeContent(saveCreativeResultToTask)
                #if FLOE_MAC_HOST_SMOKE
                .onAppear { workspace.smokeCreativeMounted = true }
                .onDisappear { workspace.smokeCreativeMounted = false }
                #endif
        case .images:
            imageWorkbench
        default:
            MacWorkspaceTaskCenter(workspace: workspace, projectID: taskCenterProjectID, findRequest: taskCenterFindRequest,
                                   onOpen: openTask, onNew: { startNewTask(in: taskCenterProjectID) },
                                   onArchive: { updateTask(id: $0, change: .archive($1)) },
                                   onMove: chooseTaskWorkspace, onDelete: confirmDelete,
                                   didDeleteArchived: { draftStore.clear(for: $0) },
                                   onOpenMatch: { conversation, message in
                                       guard canSelectTask || workspace.selectedID == conversation else { return }
                                       searchResultTarget = (conversation, message)
                                       openTask(conversation)
                                   }, didArchiveTask: { id in Task { await taskDidLeaveHistory(id) } })
                .id(taskCenterProjectID)
        }
    }

    private var imageWorkbench: AnyView {
        switch imageReturnDestination {
        case .newTask, .conversation:
            imageContent { url in attachGeneratedImage(url) }
        default:
            imageContent(nil)
        }
    }

    private var saveCreativeResultToTask: ((URL) async -> Bool)? {
        guard let target = creativeTaskBinding else { return nil }
        return { source in
            guard destination == .creative, creativeTaskBinding?.owner == target.owner,
                  creativeTaskBinding?.workspace == target.workspace else { return false }
            let saved = await workspace.saveGeneratedMedia(source, owner: target.owner, workspaceID: target.workspace)
            if saved, destination == .creative, workspace.attachmentOwnerID == target.owner,
               let back = creativeReturnDestination {
                destination = back
                inspector = .files
            }
            return saved
        }
    }

    private func browserDetail(owner: UUID?, close: @escaping () -> Void) -> some View {
        // The page representable returns the session's existing WKWebView, so
        // the owner identity forces a remount when the binding changes; this
        // is what keeps a task's page from lingering under another owner.
        let toggleExpansion: (() -> Void)? = owner != nil && !compactDetail ? { browserExpanded.toggle() } : nil
        return browserWorkbench.makeWorkbenchView(
            owner: owner,
            onReturn: close,
            onOpenExternal: { NSWorkspace.shared.open($0) },
            expanded: browserExpanded,
            onToggleExpansion: toggleExpansion
        )
        .id(owner)
    }

    private func startNewTask() {
        startNewTask(in: nil)
    }

    private func startNewTask(in projectID: UUID?, recovering draftID: UUID? = nil) {
        guard workspace.selectNewDraft(in: projectID, recovering: draftID) else { return }
        requestedConversation = nil
        if let projectID { expandedWorkspaceIDs.insert(projectID) }
        inspector = nil
        destination = .newTask(projectID)
    }

    private var canChooseProject: Bool {
        workspace.isReady && !workspace.isTerminating && !addingProject && !workspace.hasPendingWorkspaceFileChanges
    }

    private func selectSpaceRoot(_ root: MacSpaceFilesRoot) {
        guard canSwitchSpaceRoot(to: root) else { return }
        spaceFilesRoot = root
        if remembersFileRoot { spaceFilesRootRaw = root.persistedToken }
        destination = .space(.files)
    }

    private func revealProjectFolder(_ project: WorkspaceRecord) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: project.rootBookmark,
                                 options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale else {
            showProjectFolderError = true
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            showProjectFolderError = true
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func chooseProjectForTask() {
        chooseProjectFolder(forTask: true)
    }

    private func chooseProjectFolder() {
        chooseProjectFolder(forTask: false)
    }

    private func chooseProjectFolder(forTask: Bool) {
        guard canChooseProject, let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "mac.workspace.addProjectAction")
        let selection = workspace.draftSelectionID
        let route = destination
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url, route == destination,
                  !forTask || (workspace.draftSelectionID == selection && canEditVisibleDraft) else { return }
            registerProject(folder, openInSpace: !forTask)
        }
    }

    private func registerPickedFolder(_ folder: URL) {
        if showsSpaceFiles { registerProject(folder, openInSpace: true) }
        else if case .newTask = destination { registerProject(folder, openInSpace: false) }
    }

    private func registerProject(_ folder: URL, openInSpace: Bool) {
        guard canChooseProject else { return }
        let startingDestination = destination
        let startingSpaceRoot = spaceFilesRoot
        let startingDraftProjectID = workspace.selectedWorkspaceID
        let startingSelection = workspace.draftSelectionID
        addingProject = true
        Task {
            defer { addingProject = false }
            let root = folder.resolvingSymlinksInPath().standardizedFileURL
            guard let project = await workspace.addWorkspace(name: root.lastPathComponent, rootURL: root,
                                                             selectForNewTask: false) else {
                showProjectError = true
                return
            }
            expandedWorkspaceIDs.insert(project.id)
            guard destination == startingDestination, openInSpace || workspace.draftSelectionID == startingSelection else { return }
            if openInSpace, startingSpaceRoot == spaceFilesRoot {
                selectSpaceRoot(.project(project.id))
            } else if !openInSpace, case .newTask = destination, workspace.selectedID == nil,
                      startingDraftProjectID == workspace.selectedWorkspaceID {
                workspace.selectWorkspace(project.id)
            } else if !openInSpace, case .conversation(let id) = destination, workspace.selectedID == id, canEditVisibleDraft {
                if !(await workspace.moveTask(id, to: project.id)) { showMoveError = true }
            }
        }
    }

    private func openImageWorkbench() {
        guard let destination, destination != .images else { return }
        imageReturnDestination = destination
        self.destination = .images
    }

    /// In-app route for http(s) links tapped in chat. The shared scheme guard
    /// is the single authority here; unsafe URLs never reach this method
    /// because the chat openURL action discards them first.
    private func openInWorkbenchBrowser(_ url: URL) {
        guard MacBrowserAddress.allows(url) else { return }
        if let owner = visibleTaskOwner {
            browserWorkbench.openTaskURL(url, owner: owner)
            inspector = .browser(owner)
        } else if !showsTask {
            browserWorkbench.generalBrowser().open(url)
            showGeneralBrowser()
        }
    }

    private func showWorkbenchBrowser() {
        if let owner = visibleTaskOwner {
            browserWorkbench.taskSession(for: owner)
            inspector = .browser(owner)
        } else if !showsTask {
            showGeneralBrowser()
        }
    }

    private func showGeneralBrowser() {
        guard destination != .browser else { return }
        browserReturnDestination = destination
        destination = .browser
    }

    private func returnFromWorkbenchBrowser() {
        if case .browser = inspector {
            closeInspector()
        } else if destination == .browser {
            destination = browserReturnDestination ?? .taskCenter
            browserReturnDestination = nil
        }
    }

    private func attachGeneratedImage(_ url: URL) -> Bool {
        guard destination == .images, canEditVisibleDraft else { return false }
        switch imageReturnDestination {
        case .newTask:
            guard workspace.selectedID == nil else { return false }
        case .conversation(let id):
            guard workspace.selectedID == id else { return false }
        default:
            return false
        }
        guard !workspace.stageAttachments([url]).isEmpty else { return false }
        destination = imageReturnDestination
        return true
    }

    private func focusTaskSearch() {
        sidebarVisibility = .all
        showHistorySearch = true
        historySearchFocused = true
        #if FLOE_MAC_HOST_SMOKE
        workspace.smokeTaskFindInvocations += 1
        #endif
    }

    private func searchConversationContent() {
        workspace.taskCenterShowsArchived = false
        workspace.taskCenterQuery = historySearchQuery
        closeTaskSearch()
        destination = .taskCenter
    }

    private func closeTaskSearch() {
        historySearch = ""
        showHistorySearch = false
    }

    private func toggleInspector() {
        guard showsTask else { return }
        if inspector == .files { closeInspector() }
        else { inspector = .files }
    }

    private func closeInspector() {
        inspector = nil
        currentTerminal = nil
        currentConnections = nil
        remoteSheet = nil
        fileFindRequest = nil
    }

    private func findInActiveView() {
        if filesTakeDetail {
            fileFindRequest = UUID()
        } else if destination == .taskCenter || taskCenterProjectID != nil {
            taskCenterFindRequest = UUID()
        } else if activeSpacePage == .toolbox {
            toolboxFindRequest = UUID()
        } else if case .conversation(let id) = destination, id == workspace.selectedID {
            conversationFindRequest = UUID()
        } else {
            focusTaskSearch()
        }
    }

    private func insertFileText(_ text: String) {
        guard canUseFileInTask, filesVisible else { return }
        let id = workspace.selectedID
        let storageID = id ?? workspace.uncommittedDraftID
        let current = draftStore.text(for: storageID)
        draftStore.setText(current.isEmpty ? text : current + "\n\n" + text, for: storageID)
        if !showsTask { destination = id.map(MacWorkspaceDestination.conversation) ?? .newTask(workspace.selectedWorkspaceID) }
    }

    private func updateFileAttachments(_ files: [URL]) {
        guard canUseFileInTask else { return }
        let wanted = Set(files)
        let alreadyStaged = Set(workspace.stagedAttachments.map(\.url))
        for draft in workspace.stagedAttachments where !wanted.contains(draft.url) {
            workspace.unstageAttachment(draft.id)
        }
        let additions = files.filter { !alreadyStaged.contains($0) }
        let staged = workspace.stageAttachments(additions)
        if staged.count < additions.count {
            workspace.notice = String(localized: "mac.workspace.attachFailed")
        }
        if !showsTask && !additions.isEmpty {
            destination = workspace.selectedID.map(MacWorkspaceDestination.conversation) ?? .newTask(workspace.selectedWorkspaceID)
        }
    }

    private func openTask(_ id: UUID) {
        if canSelectTask || workspace.selectedID == id { destination = .conversation(id) }
    }

    private func openNotifiedTask() {
        guard workspace.isReady, let id = workspace.notificationTaskID else { return }
        workspace.notificationTaskID = nil
        if workspace.conversations.contains(where: { $0.id == id }) { openTask(id) }
    }

    private func openInspector(_ item: FloeTaskInspectorItem) {
        switch item {
        case .workspaceFiles: inspector = .files
        case .browser: showWorkbenchBrowser()
        case .terminal: showTaskTerminal()
        case .changes: inspector = destinationConversationID.map(MacTaskInspector.changes)
        case .childAgents: inspector = destinationConversationID.map(MacTaskInspector.childAgents)
        case .progress: inspector = destinationConversationID.map(MacTaskInspector.progress)
        }
    }

    private func inspectorEntryID(_ item: FloeTaskInspectorItem) -> String {
        switch item {
        case .workspaceFiles: "workspace.files.open"
        case .browser: "workspace.browser.open"
        case .terminal: "workspace.terminal.open"
        default: "thread.inspector.open.\(item.rawValue)"
        }
    }

    private func showTaskTerminal() {
        guard let id = visibleTaskOwner, let root = currentTaskFileRecord else { return }
        do {
            guard let owner = try openTerminal(id, root) else { return }
            currentTerminal = owner
            currentConnections = workspace.selectedTaskPolicy?.remoteExecutionAllowed == false ? nil : openConnections(owner)
            inspector = .terminal(id)
        } catch { showTerminalError = true }
    }

    private func updateTask(id: UUID, change: FloeMacSelfRuntime.ConversationMetadataChange) {
        Task {
            let saved = await workspace.changeConversationMetadata(id: id, change: change)
            if !saved {
                showMetadataError = true
            } else {
                switch change {
                case .delete:
                    draftStore.clear(for: id)
                    browserWorkbench.discard(owner: id)
                    if inspector == .browser(id) { closeInspector() }
                    if browserReturnDestination == .conversation(id) {
                        browserReturnDestination = nil
                    }
                    fallthrough
                case .archive(true):
                    await taskDidLeaveHistory(id)
                default:
                    break
                }
            }
        }
    }

    private func taskDidLeaveHistory(_ id: UUID) async {
        if remembersFileRoot, lastConversation == id.uuidString { lastConversation = "" }
        if workspace.selectedID == id {
            requestedConversation = nil
            workspace.clearStagedAttachments()
            await workspace.select(nil)
            destination = .taskCenter
        }
    }

    private func confirmDelete(_ task: ConversationRecord) {
        guard canSelectTask, !workspace.isTaskRunning(task.id) else { return }
        taskToDelete = task
        showDelete = true
    }

    private func chooseTaskWorkspace(_ task: ConversationRecord) {
        guard canSelectTask, !workspace.isTaskRunning(task.id) else { return }
        taskToMove = task
        showMove = true
    }

    private func moveTask(_ id: UUID, to workspaceID: UUID?) {
        Task {
            if !(await workspace.moveTask(id, to: workspaceID)) { showMoveError = true }
        }
    }

    private func workspaceText(_ chinese: String, _ english: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
    }

    private enum ExportFormat: String {
        case structured = "jsonl"
        case plainText = "txt"
        case markdown = "md"
    }

    private func exportConversation(_ format: ExportFormat) {
        guard canSelectTask, !isExportingConversation, let id = destinationConversationID,
              id == workspace.selectedID else { return }
        let name = workspace.conversations.first { $0.id == id }?.title ?? String(localized: "mac.workspace.task")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.nameFieldStringValue = "Floe Conversation.\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExportingConversation = true
        Task {
            defer { isExportingConversation = false }
            do {
                if format == .structured {
                    try await workspace.exportStructuredConversation(conversationID: id, to: url)
                    return
                }
                let messages = try await workspace.transcript(conversationID: id)
                let output = Self.readableTranscript(name: name, messages: messages, markdown: format == .markdown)
                try await Task.detached(priority: .utility) {
                    try Data(output.utf8).write(to: url, options: .atomic)
                }.value
            } catch {
                showExportError = true
            }
        }
    }

    static func markdownTranscript(name: String, messages: [PersistedMessage]) -> String {
        readableTranscript(name: name, messages: messages, markdown: true)
    }

    static func readableTranscript(name: String, messages: [PersistedMessage], markdown: Bool) -> String {
        var sections = [markdown ? "# \(name)" : name]
        sections += messages.compactMap { message in
            let role: String
            switch message.role {
            case "user": role = String(localized: "thread.role.user")
            case "assistant": role = String(localized: "thread.role.assistant")
            default: return nil
            }
            let text = CredentialMessagePart.clipboardText(message.content)
            let files = AttachmentChipItem.items(in: message.parts).map(\.name)
            let paragraphs = [text].compactMap { $0 } + files.map { markdown ? "- \($0)" : $0 }
            guard !paragraphs.isEmpty else { return nil }
            let body = paragraphs.joined(separator: "\n\n")
            return markdown ? "## \(role)\n\n\(body)" : "\(role): \(body)"
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}

extension ConversationRecord {
    var workbenchDisplayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "mac.workspace.untitledTask")
            : title
    }
}

private extension View {
    func macWorkspaceIconTarget() -> some View {
        frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget).contentShape(Rectangle())
    }
}

private struct MacWorkspaceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon
                .foregroundStyle(Color.accentColor)
                .frame(width: 19)
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}

/// Browser presentation and return requests, kept out of the root body chain
/// so the window expression stays within the type-check limit. Nonce-tagged
/// requests are observed on every publish, even when values repeat.
private struct BrowserWorkbenchNavigation: ViewModifier {
    @ObservedObject var browser: MacBrowserWorkbenchController
    let openURL: (URL) -> Void
    let show: () -> Void
    let returnToTask: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: browser.presentRequest) { _, request in
                guard let request else { return }
                switch request.presentation {
                case .url(let url): openURL(url)
                case .empty: show()
                }
            }
            .onChange(of: browser.returnRequest) { _, request in
                guard request != nil else { return }
                returnToTask()
            }
    }
}
