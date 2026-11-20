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
    case taskCenter, space(MacSpacePage), images, conversation(UUID)
}

struct MacWorkspaceRootView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let openSettings: () -> Void
    let openModelSettings: () -> Void
    let openToolbox: (String) -> Void
    let settingsContent: () -> AnyView
    let imageContent: (((URL) -> Bool)?) -> AnyView
    var remembersFileRoot = true
    @ObservedObject var draftStore: MacWorkspaceDraftStore
    @AppStorage("floe.mac.workspace.lastConversation") private var lastConversation = ""

    @State private var destination: MacWorkspaceDestination? = .newTask(nil)
    @State private var imageReturnDestination: MacWorkspaceDestination = .space(.toolbox)
    @State private var restoredInitialDestination = false
    @State private var showInspector = false
    @State private var showHistorySearch = false
    @FocusState private var historySearchFocused: Bool
    @State private var historySearch = ""
    @State private var conversationFindRequest: UUID?
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
    @State private var grantedFolder: URL?
    @State private var registeredFolder: URL?
    @State private var displayedFileProject: WorkspaceRecord?
    @State private var expandedWorkspaceIDs: Set<UUID> = []

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 234, max: 320)
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
            case .openSpace(let page): destination = .space(page)
            case .stopTask:
                if showsTask, destinationConversationID == workspace.selectedID { workspace.stop() }
            }
        }
        .disabled(workspace.isTerminating)
        .task { await workspace.prepare() }
        .task(id: workspace.isReady) {
            guard workspace.isReady, !restoredInitialDestination else { return }
            restoredInitialDestination = true
            guard destination == .newTask(nil) else { return }
            if remembersFileRoot, let savedID = UUID(uuidString: lastConversation),
               workspace.conversations.contains(where: { $0.id == savedID && $0.isVisibleInOrdinaryList }) {
                destination = .conversation(savedID)
            } else if workspace.selectedID != nil {
                await workspace.select(nil)
            }
        }
        .task(id: destination) {
            draftStore.flush()
            guard workspace.isReady else { return }
            switch destination {
            case .conversation(let id):
                if id != workspace.selectedID {
                    workspace.clearStagedAttachments()
                    await workspace.select(id)
                }
            default: break
            }
        }
        .onDisappear { draftStore.flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            draftStore.flush()
        }
        .task(id: canSelectTask ? grantedFolder : nil) {
            guard canSelectTask, let folder = grantedFolder, folder != registeredFolder else { return }
            if await workspace.addWorkspace(name: folder.lastPathComponent, rootURL: folder) {
                registeredFolder = folder
            }
        }
        .onChange(of: workspace.admittedDraftID) { _, id in
            if let id, case .newTask = destination, workspace.selectedID == id {
                destination = .conversation(id)
            }
        }
        .onChange(of: destination) { _, newDestination in
            conversationFindRequest = nil
            #if FLOE_MAC_HOST_SMOKE
            workspace.smokeSpacePage = activeSpacePage
            #endif
            if newDestination == nil { destination = .taskCenter }
            if !showsTask { showInspector = false }
            guard remembersFileRoot else { return }
            if case .conversation(let id) = newDestination { lastConversation = id.uuidString }
            if case .newTask = newDestination { lastConversation = "" }
        }
        .onChange(of: preferredFileProject, initial: true) { _, project in
            if !workspace.hasPendingWorkspaceFileChanges { displayedFileProject = project }
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
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                if !showsSpaceFiles {
                    detail
                        .frame(minWidth: filesVisible ? 260 : 0, maxWidth: .infinity, maxHeight: .infinity)
                        .background(FloeTheme.readingSurface)
                }
                filesPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filesPane: some View {
        MacWorkspaceFilesView(
            insertInDraft: insertFileText,
            canInsertInDraft: canUseFileInTask,
            remembersRoot: remembersFileRoot,
            fixedRootBookmark: displayedFileProject?.rootBookmark,
            workspaceRevision: workspace.workspaceRevision,
            taskAttachmentURLs: Set(workspace.stagedAttachments.map(\.url)),
            onRootChanged: { grantedFolder = $0 },
            onAttachmentsChanged: updateFileAttachments,
            canChangeFiles: { !workspace.isTerminating },
            onPendingChanges: { pending in
                workspace.hasPendingWorkspaceFileChanges = pending
                if !pending { displayedFileProject = preferredFileProject }
            },
            layout: showsSpaceFiles ? .adaptive : .inspector
        )
        .id(displayedFileProject?.id)
        .frame(minWidth: filesVisible ? 250 : 0, idealWidth: filesVisible ? 400 : 0,
               maxWidth: showsSpaceFiles ? .infinity : (filesVisible ? 520 : 0))
        .background(FloeTheme.readingSurface)
        .clipped()
        .opacity(filesVisible ? 1 : 0)
        .allowsHitTesting(filesVisible)
        .accessibilityHidden(!filesVisible)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("host.role.agent").font(.headline)
                Spacer(minLength: 8)
                Button(action: focusTaskSearch) {
                    Label("mac.workspace.findTask", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("mac.workspace.findTask")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
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
                    .onExitCommand {
                        historySearch = ""
                        showHistorySearch = false
                    }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    sidebarLink(.newTask(nil), title: "workbench.new_task", icon: "square.and.pencil")
                        .disabled(!canSelectTask)
                    sidebarLink(.taskCenter, title: "app.floe_agent_app.task_center", icon: "checklist")
                    sidebarLink(.space(.files), title: "space.title", icon: "square.stack.3d.up")
                        .accessibilityIdentifier("workspace.space")
                        #if FLOE_MAC_HOST_SMOKE
                        .background(MacWorkbenchButtonFrameReader { workspace.smokeSpaceFrame = $0 })
                        #endif
                    projectSidebar
                    personalHistory
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            FloeWorkbenchSidebarFooter(openSettings: openSettings)
        }
        .background(FloeTheme.sidebarSurface)
    }

    @ViewBuilder
    private var projectSidebar: some View {
        let projects = workspace.workspaces.filter { $0.kind == .project }
        if !projects.isEmpty {
            sidebarHeading("workspace.title")
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
    }

    private func projectRow(_ project: WorkspaceRecord) -> some View {
        let members = workspace.projectTaskMembership?[project.id] ?? []
        let row = FloeWorkbenchProjectRow(
            workspaceID: project.id, name: project.name,
            isExpanded: Binding(
                get: { expandedWorkspaceIDs.contains(project.id) || !historySearch.isEmpty },
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
        return instrumented
        #else
        return row
        #endif
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
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 9)
            .padding(.top, 18)
            .padding(.bottom, 4)
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
                    Image(systemName: workspace.hasPendingApproval(in: id) ? "hand.raised.fill" : "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(selected ? Color.white : (workspace.hasPendingApproval(in: id) ? .orange : .accentColor))
                        .accessibilityHidden(true)
                }
            }
            .labelStyle(MacWorkspaceLabelStyle(selected: selected))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(selected ? FloeTheme.primary : Color.clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var filteredConversations: [ConversationRecord] {
        workspace.conversations.filter {
            $0.isVisibleInOrdinaryList && (historySearch.isEmpty || $0.title.localizedStandardContains(historySearch))
        }
    }

    private var canSelectTask: Bool {
        workspace.isReady && !workspace.isTerminating && !workspace.isAcceptingPlan
    }

    private var canEditVisibleDraft: Bool { canSelectTask && !workspace.isSending && !workspace.isLoadingHistory }

    private var preferredFileProject: WorkspaceRecord? {
        switch destination {
        case .conversation(let id) where id == workspace.selectedID:
            guard workspace.selectedConversationWorkspace?.kind == .project else { return nil }
            return workspace.selectedConversationWorkspace
        case .newTask where workspace.selectedID == nil:
            return workspace.workspaces.first { $0.id == workspace.selectedWorkspaceID && $0.kind == .project }
        default:
            return nil
        }
    }

    private var canUseFileInTask: Bool {
        canEditVisibleDraft && displayedFileProject?.id == preferredFileProject?.id
            && (!showsTask || destinationConversationID == workspace.selectedID)
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
        case .images: String(localized: "mac.settings.images")
        default: String(localized: "mac.workspace.taskCenter")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack {
                if destination == .images {
                    Button { destination = imageReturnDestination } label: {
                        Label("mac.workspace.back", systemImage: "chevron.left")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("mac.workspace.back")
                }
                Spacer()
            }
            .frame(width: 80)
            Group {
                if let page = activeSpacePage {
                    Picker("space.title", selection: Binding(get: { page }, set: { destination = .space($0) })) {
                        Text("mac.workspace.spaceFiles").tag(MacSpacePage.files)
                        Text("mac.workspace.toolbox").tag(MacSpacePage.toolbox)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("workspace.space.section")
                    #if FLOE_MAC_HOST_SMOKE
                    .background(MacWorkbenchButtonFrameReader { workspace.smokeSpacePickerFrame = $0 })
                    #endif
                } else {
                    Text(title).font(.headline).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            headerActions
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 46)
        .background(FloeTheme.chromeMaterial)
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
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
            if showsTask {
                Button { showInspector.toggle() } label: {
                    Label("mac.workspace.files", systemImage: "sidebar.trailing")
                }
                .labelStyle(.iconOnly)
                .help("mac.workspace.files")
                .accessibilityIdentifier("workspace.files.toggle")
                .accessibilityAddTraits(showInspector ? .isSelected : [])
            }
            if case .conversation = destination {
                Button(action: findInActiveView) {
                    Label("mac.workspace.findConversation", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .help("mac.workspace.findConversation")
                .disabled(workspace.isLoadingHistory || destinationConversationID != workspace.selectedID)
                Button(action: exportConversation) {
                    Label("mac.workspace.exportChat", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .help("mac.workspace.exportChat")
                .disabled(!canSelectTask || isExportingConversation || workspace.messages.isEmpty
                          || destinationConversationID != workspace.selectedID)
            }
        }
        .buttonStyle(.borderless)
        .frame(minWidth: 80, alignment: .trailing)
    }

    private var activeTaskStatus: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(runStatusTitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var runStatusTitle: LocalizedStringKey {
        if workspace.isStopping || workspace.runPhase == .cancelling {
            return "mac.workspace.runStopping"
        }
        if workspace.pendingApproval != nil { return "mac.agent.waitingForApproval" }
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
                                           openModelSettings: openModelSettings,
                                           openFiles: { showInspector = true },
                                           openImageWorkbench: openImageWorkbench,
                                           findRequest: conversationFindRequest,
                                           findConversationID: destinationConversationID)
                        .id(destinationConversationID)
                }
            } else {
                ProgressView("host.chat.opening")
            }
        case .space(.toolbox):
            MacWorkspaceToolboxView(openToolbox: openToolbox)
        case .space(.files): EmptyView()
        case .images:
            imageWorkbench
        default:
            MacWorkspaceTaskCenter(workspace: workspace, onOpen: openTask, onNew: startNewTask,
                                   onArchive: { updateTask(id: $0, change: .archive($1)) },
                                   onMove: chooseTaskWorkspace, onDelete: confirmDelete)
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
        showHistorySearch = true
        historySearchFocused = true
        #if FLOE_MAC_HOST_SMOKE
        workspace.smokeTaskFindInvocations += 1
        #endif
    }

    private func findInActiveView() {
        if case .conversation(let id) = destination, id == workspace.selectedID {
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
        _ = workspace.stageAttachments(files.filter { !alreadyStaged.contains($0) })
        if !showsTask && !files.isEmpty {
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
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon
                .foregroundStyle(selected ? Color.white : .accentColor)
                .frame(width: 19)
            configuration.title
                .foregroundStyle(selected ? Color.white : .primary)
        }
    }
}
