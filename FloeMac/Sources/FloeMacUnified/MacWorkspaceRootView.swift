// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeMacSelfCore
import FloePersistence
import SwiftUI
import UniformTypeIdentifiers

enum MacSpacePage: Hashable {
    case files, toolbox
}

private enum MacWorkspaceDestination: Hashable {
    case newTask(UUID?)
    case taskCenter, space(MacSpacePage), creative, images, conversation(UUID)
}

struct MacWorkspaceRootView: View {
    #if FLOE_MAC_HOST_SMOKE
    static var smokeTaskCenterFrame: CGRect?
    #endif
    @ObservedObject var workspace: HostAgentWorkspace
    let openSettings: () -> Void
    let openModelSettings: () -> Void
    let openPermissionSettings: () -> Void
    let openToolbox: (String) -> Void
    let settingsContent: () -> AnyView
    let imageContent: (((URL) -> Bool)?) -> AnyView
    let creativeContent: () -> AnyView
    var remembersFileRoot = true
    @ObservedObject var draftStore: MacWorkspaceDraftStore
    @AppStorage("floe.mac.workspace.lastConversation") private var lastConversation = ""
    @AppStorage("floe.mac.workspace.spaceProject") private var lastSpaceProject = ""
    @AppStorage("floe.mac.workspace.spaceFilesRoot") private var spaceFilesRootRaw = ""

    @State private var destination: MacWorkspaceDestination? = .newTask(nil)
    @State private var requestedConversation: UUID?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var imageReturnDestination: MacWorkspaceDestination = .space(.toolbox)
    @State private var restoredInitialDestination = false
    @State private var showInspector = false
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
    @State private var displayedFileRoot: WorkspaceRecord?
    @State private var expandedWorkspaceIDs: Set<UUID> = []

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            workspacePanes
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $workspace.isSettingsPresented, content: settingsContent)
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
            guard destination == .newTask(nil) else { return }
            if remembersFileRoot, let savedID = UUID(uuidString: lastConversation),
               workspace.conversations.contains(where: { $0.id == savedID && $0.isVisibleInOrdinaryList }) {
                destination = .conversation(savedID)
            } else if workspace.selectedID != nil {
                await workspace.select(nil)
            }
        }
        .task(id: requestedConversation) {
            guard workspace.isReady, let id = requestedConversation, id != workspace.selectedID else { return }
            workspace.clearStagedAttachments()
            await workspace.select(id)
        }
        .onDisappear { draftStore.flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            draftStore.flush()
        }
        .onChange(of: workspace.admittedDraftID) { _, id in
            if let id, case .newTask = destination, workspace.selectedID == id {
                destination = .conversation(id)
            }
        }
        .onChange(of: destination) { _, newDestination in
            draftStore.flush()
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
            if !showsTask { showInspector = false }
            guard remembersFileRoot else { return }
            if case .conversation(let id) = newDestination { lastConversation = id.uuidString }
            if case .newTask = newDestination { lastConversation = "" }
        }
        .onChange(of: showsTask, initial: true) { _, active in
            workspace.windowShowsTask = active
        }
        .onChange(of: preferredFileRoot, initial: true) { _, root in
            if !workspace.hasPendingWorkspaceFileChanges { displayedFileRoot = root }
        }
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
        .alert("mac.workspace.saveFailed", isPresented: $showMetadataError) {
            Button("OK", role: .cancel) {}
        }
        .alert("mac.workspace.moveFailed", isPresented: $showMoveError) {
            Button("OK", role: .cancel) {}
        }
        .alert("host.chat.workspaceSaveFailed", isPresented: $showProjectError) {
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
            let fullFiles = showsSpaceFiles || (showsTask && showInspector && compact)
            let split = filesVisible && !fullFiles
            let fileWidth = fullFiles ? width : (split ? clampedInspectorWidth(inspectorWidth - dividerTranslation, in: width) : 0)
            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    detail
                        .frame(width: max(0, width - fileWidth - (split ? 6 : 0)))
                        .frame(maxHeight: .infinity)
                        .clipped()
                        .opacity(fullFiles ? 0 : 1)
                        .disabled(fullFiles)
                        .allowsHitTesting(!fullFiles)
                        .accessibilityHidden(fullFiles)
                    if split { inspectorDivider(in: width) }
                    filesPane
                        .frame(width: fileWidth)
                        .frame(maxHeight: .infinity)
                        .clipped()
                }
            }
            .frame(width: width, height: geometry.size.height)
            .background(FloeTheme.readingSurface)
            .onChange(of: compact, initial: true) { _, isCompact in compactDetail = isCompact }
        }
        #if FLOE_MAC_HOST_SMOKE
        .onChange(of: showInspector, initial: true) { _, shown in
            workspace.smokeInspectorShown = shown
        }
        .onChange(of: filesTakeDetail && showsTask, initial: true) { _, presented in
            workspace.smokeFilesTakeDetail = presented
        }
        #endif
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
        let rootID = preferredFileRoot?.id
        return MacWorkspaceFilesView(
            insertInDraft: { text in
                guard selectionID == workspace.draftSelectionID, rootID == displayedFileRoot?.id else { return }
                insertFileText(text)
            },
            canInsertInDraft: canUseFileInTask,
            remembersRoot: remembersFileRoot,
            fixedRootBookmark: displayedFileRootBookmark,
            fixedRootURL: spaceFilesFixedURL,
            workspaceRevision: workspace.workspaceRevision,
            taskAttachmentURLs: Set(workspace.stagedAttachments.map(\.url)),
            onFolderPicked: registerPickedFolder,
            onAttachmentsChanged: { files in
                guard selectionID == workspace.draftSelectionID, rootID == displayedFileRoot?.id else { return }
                updateFileAttachments(files)
            },
            canChangeFiles: { !workspace.isTerminating },
            onPendingChanges: { pending in
                workspace.hasPendingWorkspaceFileChanges = pending
                if !pending { displayedFileRoot = preferredFileRoot }
            },
            layout: showsSpaceFiles ? .adaptive : .inspector,
            findRequest: fileFindRequest,
            rootFolderLabels: spaceRootFolderLabels,
            requiresTaskRoot: showsTask && !currentTaskFileRootUsable,
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
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    if showHistorySearch {
                        TextField("mac.workspace.findTask", text: $historySearch)
                            .textFieldStyle(.roundedBorder)
                            .focused($historySearchFocused)
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
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    } else {
                        Button(action: focusTaskSearch) {
                            Label("mac.workspace.findTask", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("mac.workspace.findTask")
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                sidebarLink(.newTask(nil), title: "workbench.new_task", icon: "square.and.pencil")
                    .disabled(!canSelectTask)
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
            Divider().padding(.horizontal, 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if historySearchQuery.isEmpty {
                        projectSidebar
                        personalHistory
                    } else {
                        Button(action: searchConversationContent) {
                            Label("mac.workspace.searchConversationContent", systemImage: "text.magnifyingglass")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .padding(6)
                        ForEach(filteredConversations) { conversationSidebarRow($0) }
                    }
                }
                .padding(8)
            }
            Divider()
            HStack {
                Button(action: openSettings) {
                    Label("more.settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("sidebar.settings")
                Spacer()
            }
            .padding(.horizontal, 15)
            .frame(height: 36)
        }
    }

    @ViewBuilder
    private var projectSidebar: some View {
        HStack {
            sidebarHeading("workspace.title")
            Spacer(minLength: 4)
            Button(action: chooseProjectFolder) {
                Label("mac.workspace.addProject", systemImage: "plus")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("mac.workspace.addProject")
            .accessibilityIdentifier("workspace.addProject")
            .disabled(!canChooseProject)
        }
        .padding(.trailing, 9)
        if workspace.projectTasksUnavailable {
            HStack {
                Text("mac.workspace.projectTasksUnavailable").foregroundStyle(.secondary)
                Button("host.chat.tryAgain") { Task { await workspace.retryProjectTasks() } }
            }
            .font(.caption)
            .padding(.leading, 9)
        }
        ForEach(projects) { project in
            projectRow(project)
                .padding(.horizontal, 9)
                .disabled(!canSelectTask)
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
            }
            .buttonStyle(.borderless)
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
        instrumented.onOpenFrame = { frame in workspace.smokeProjectNameFrames[project.id] = frame }
        return instrumented.contextMenu { projectActions(project) }
        #else
        return row.contextMenu { projectActions(project) }
        #endif
    }

    @ViewBuilder private func projectActions(_ project: WorkspaceRecord) -> some View {
        Button("mac.workspace.browseFiles", systemImage: "folder") {
            selectSpaceRoot(.project(project.id))
        }
        .disabled(workspace.hasPendingWorkspaceFileChanges && displayedFileRoot?.id != project.id)
        Button("workbench.new_task", systemImage: "square.and.pencil") { startNewTask(in: project.id) }
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
    }

    private func conversationSidebarRow(_ conversation: ConversationRecord) -> some View {
        let changing = !canSelectTask || workspace.isTaskRunning(conversation.id)
        return sidebarLink(.conversation(conversation.id), title: LocalizedStringKey(conversation.workbenchDisplayTitle),
                           icon: conversation.isPinned ? "pin" : "bubble.left", conversationTitle: conversation.workbenchDisplayTitle)
            .disabled(!canSelectTask && workspace.selectedID != conversation.id)
            .contextMenu {
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
    }

    private func sidebarLink(_ route: MacWorkspaceDestination, title: LocalizedStringKey, icon: String,
                             conversationTitle: String? = nil) -> some View {
        let selected = destination == route || (route == .space(.files) && isInSpace)
        return Button {
            if case .newTask(let projectID) = route { startNewTask(in: projectID) }
            else { destination = route }
        } label: {
            HStack(spacing: 6) {
                if let conversationTitle {
                    Label { Text(verbatim: conversationTitle) } icon: { Image(systemName: icon) }
                } else {
                    FloeWorkbenchSidebarItem(title: title, systemImage: icon)
                }
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
            .font(.callout)
            .frame(minHeight: 25)
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

    /// Per-task workspace rows carry an empty bookmark by design, so only a
    /// non-empty, resolvable bookmark may fix the files root; the host's
    /// presentation record is expected to populate it exactly like a project
    /// row.
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

    /// One identity per root source so switching tasks, projects or Space
    /// modes resets the browser; two personal tasks never share a root.
    private var filesPaneIdentity: AnyHashable {
        if let record = preferredFileRoot { return AnyHashable(record.id) }
        return AnyHashable(spaceFilesRoot)
    }

    /// A task-mode file root is usable only when the host provides a
    /// per-task record with a resolvable bookmark (the presentation record
    /// populates it like a project row). Anything else keeps the inspector
    /// in its unavailable state — staging from a saved or ad-hoc folder is
    /// never allowed for a personal task.
    private var currentTaskFileRootUsable: Bool {
        currentTaskFileRecord?.rootBookmark.isEmpty == false
    }

    private var canUseFileInTask: Bool {
        guard canEditVisibleDraft, !showsTask || destinationConversationID == workspace.selectedID else { return false }
        guard let record = currentTaskFileRecord, !record.rootBookmark.isEmpty else { return false }
        return displayedFileRoot?.id == record.id
    }

    private var activeSpacePage: MacSpacePage? {
        if case .space(let page) = destination { return page }
        return nil
    }

    private var isInSpace: Bool {
        activeSpacePage != nil || (destination == .images && imageReturnDestination == .space(.toolbox))
    }

    private var showsSpaceFiles: Bool { activeSpacePage == .files }
    private var filesVisible: Bool { showsSpaceFiles || showInspector }
    private var filesTakeDetail: Bool { showsSpaceFiles || (showsTask && showInspector && compactDetail) }

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

    private var taskDraft: Binding<String> {
        let id = destinationConversationID
        return Binding(get: { draftStore.text(for: id) }, set: { draftStore.setText($0, for: id) })
    }

    private var title: String {
        switch destination {
        case .newTask: String(localized: "mac.workspace.newTask")
        case .conversation(let id): workspace.conversations.first { $0.id == id }?.workbenchDisplayTitle
            ?? String(localized: "mac.workspace.untitledTask")
        case .space: String(localized: "space.title")
        case .creative: String(localized: "mac.creative.title")
        case .images: String(localized: "mac.settings.images")
        default: String(localized: "mac.workspace.taskCenter")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if destination == .images || (showsTask && filesTakeDetail) {
                Button {
                    if destination == .images { destination = imageReturnDestination }
                    else { toggleInspector() }
                } label: {
                    Label(LocalizedStringKey(showsTask ? "mac.workspace.backToTask" : "mac.workspace.back"),
                          systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("workspace.detail.back")
            }
            if let page = activeSpacePage {
                Picker("space.title", selection: Binding(get: { page }, set: { destination = .space($0) })) {
                    Text("mac.workspace.spaceFiles").tag(MacSpacePage.files)
                    Text("mac.workspace.toolbox").tag(MacSpacePage.toolbox)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
                .accessibilityIdentifier("workspace.space.section")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { workspace.smokeSpacePickerFrame = $0 })
                #endif
                if showsSpaceFiles { spaceProjectControl }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.body.weight(.semibold)).lineLimit(1)
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
        .padding(.horizontal, 14)
        .frame(minHeight: 37)
        .background(FloeTheme.chromeMaterial)
    }

    private var spaceProjectControl: some View {
        MacSpaceFilesRootPicker(
            projects: projects,
            root: spaceFilesRoot,
            defaultAvailable: workspace.defaultConversationsDirectory != nil,
            canAddProject: canChooseProject,
            canStartTask: canSelectTask,
            canSwitch: canSwitchSpaceRoot,
            select: selectSpaceRoot,
            addProject: chooseProjectFolder,
            newTask: { startNewTask(in: $0) }
        )
    }

    /// Pending workspace-file edits may only move to the root that is
    /// already displayed; everything else would abandon unsaved work.
    private func canSwitchSpaceRoot(to target: MacSpaceFilesRoot) -> Bool {
        guard workspace.hasPendingWorkspaceFileChanges else { return true }
        if case .project(let id) = target { return displayedFileRoot?.id == id }
        return displayedFileRoot == nil
    }

    private var headerActions: some View {
        HStack(spacing: 6) {
            if activeSpacePage == .toolbox {
                Button(action: openImageWorkbench) {
                    Label("mac.settings.images", systemImage: "photo.badge.plus")
                }
                .accessibilityIdentifier("workspace.toolbox.images")
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
                }
                .menuStyle(.borderlessButton)
                .help("mac.workspace.backgroundTasks")
            }
            if showsTask && !filesTakeDetail {
                Button(action: toggleInspector) {
                    FloeWorkbenchControlIcon(systemImage: "sidebar.trailing")
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                }
                .buttonStyle(.plain)
                .help("mac.workspace.files")
                .accessibilityLabel("mac.workspace.files")
                .accessibilityIdentifier("workspace.files.toggle")
                .accessibilityAddTraits(showInspector ? .isSelected : [])
            }
            if case .conversation = destination, !filesTakeDetail {
                Button(action: findInActiveView) {
                    FloeWorkbenchControlIcon(systemImage: "magnifyingglass")
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                }
                .buttonStyle(.plain)
                .help("mac.workspace.findConversation")
                .accessibilityLabel("mac.workspace.findConversation")
                .disabled(workspace.isLoadingHistory || destinationConversationID != workspace.selectedID)
                Button(action: exportConversation) {
                    FloeWorkbenchControlIcon(systemImage: "square.and.arrow.up")
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                }
                .buttonStyle(.plain)
                .help("mac.workspace.exportChat")
                .accessibilityLabel("mac.workspace.exportChat")
                .disabled(!canSelectTask || isExportingConversation || workspace.messages.isEmpty
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

    @ViewBuilder private var detail: some View {
        switch destination {
        case .newTask, .conversation:
            if !workspace.isReady || destinationConversationID == workspace.selectedID {
                VStack(spacing: 0) {
                    if draftStore.saveFailed {
                        let language = Locale.preferredLanguages.first ?? "en"
                        ErrorEventView(message: language.hasPrefix("zh") ? "草稿保存失败。" : "The draft could not be saved.")
                            .padding(.horizontal)
                    }
                    HostAgentWorkspaceView(workspace: workspace, workspaceDraft: taskDraft,
                                           openModelSettings: openModelSettings, openPermissionSettings: openPermissionSettings,
                                           openFiles: { showInspector = true },
                                           openImageWorkbench: openImageWorkbench,
                                           findRequest: conversationFindRequest,
                                           findConversationID: destinationConversationID,
                                           requestedMessageID: searchResultTarget?.conversation == destinationConversationID ? searchResultTarget?.message : nil,
                                           didHandleSearchResult: { conversation, message in
                                               if searchResultTarget?.conversation == conversation, searchResultTarget?.message == message {
                                                   searchResultTarget = nil
                                               }
                                           })
                        .id(destinationConversationID)
                }
            } else {
                ProgressView("host.chat.opening")
            }
        case .space(.toolbox):
            MacWorkspaceToolboxView(findRequest: toolboxFindRequest, openToolbox: openToolbox)
        case .space(.files): EmptyView()
        case .creative:
            creativeContent()
                #if FLOE_MAC_HOST_SMOKE
                .onAppear { workspace.smokeCreativeMounted = true }
                .onDisappear { workspace.smokeCreativeMounted = false }
                #endif
        case .images:
            imageWorkbench
        default:
            MacWorkspaceTaskCenter(workspace: workspace, findRequest: taskCenterFindRequest, onOpen: openTask, onNew: startNewTask,
                                   onArchive: { updateTask(id: $0, change: .archive($1)) },
                                   onMove: chooseTaskWorkspace, onDelete: confirmDelete,
                                   didDeleteArchived: { draftStore.clear(for: $0) },
                                   onOpenMatch: { conversation, message in
                                       guard canSelectTask || workspace.selectedID == conversation else { return }
                                       searchResultTarget = (conversation, message)
                                       openTask(conversation)
                                   })
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

    private func startNewTask() {
        startNewTask(in: nil)
    }

    private func startNewTask(in projectID: UUID?) {
        guard workspace.selectNewDraft(in: projectID) else { return }
        if let projectID { expandedWorkspaceIDs.insert(projectID) }
        showInspector = false
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
        showInspector.toggle()
        if !showInspector { fileFindRequest = nil }
    }

    private func findInActiveView() {
        if filesTakeDetail {
            fileFindRequest = UUID()
        } else if destination == .taskCenter {
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
        let current = draftStore.text(for: id)
        draftStore.setText(current.isEmpty ? text : current + "\n\n" + text, for: id)
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

    private func updateTask(id: UUID, change: FloeMacSelfRuntime.ConversationMetadataChange) {
        Task {
            let saved = await workspace.changeConversationMetadata(id: id, change: change)
            if !saved {
                showMetadataError = true
            } else {
                switch change {
                case .delete:
                    draftStore.clear(for: id)
                    fallthrough
                case .archive(true):
                    if remembersFileRoot, lastConversation == id.uuidString { lastConversation = "" }
                    if workspace.selectedID == id {
                        requestedConversation = nil
                        workspace.clearStagedAttachments()
                        await workspace.select(nil)
                        destination = .taskCenter
                    }
                default:
                    break
                }
            }
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

    private func exportConversation() {
        guard canSelectTask, !isExportingConversation, let id = destinationConversationID,
              id == workspace.selectedID else { return }
        let name = workspace.conversations.first { $0.id == id }?.title ?? String(localized: "mac.workspace.task")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Floe Conversation.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExportingConversation = true
        Task {
            defer { isExportingConversation = false }
            do {
                let messages = try await workspace.transcript(conversationID: id)
                let output = Self.markdownTranscript(name: name, messages: messages)
                try await Task.detached(priority: .utility) {
                    try Data(output.utf8).write(to: url, options: .atomic)
                }.value
            } catch {
                showExportError = true
            }
        }
    }

    static func markdownTranscript(name: String, messages: [PersistedMessage]) -> String {
        var sections = ["# \(name)"]
        sections += messages.compactMap { message in
            let role: String
            switch message.role {
            case "user": role = String(localized: "thread.role.user")
            case "assistant": role = String(localized: "thread.role.assistant")
            default: return nil
            }
            let text = CredentialMessagePart.clipboardText(message.content)
            let files = AttachmentChipItem.items(in: message.parts).map(\.name)
            let paragraphs = [text].compactMap { $0 } + files.map { "- \($0)" }
            guard !paragraphs.isEmpty else { return nil }
            let body = paragraphs.joined(separator: "\n\n")
            return "## \(role)\n\n\(body)"
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
