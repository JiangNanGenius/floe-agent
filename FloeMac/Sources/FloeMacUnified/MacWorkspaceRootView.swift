// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeMacSelfCore
import FloePersistence
import SwiftUI
import UniformTypeIdentifiers

private enum MacWorkspaceDestination: Hashable {
    case newTask, taskCenter, files, toolbox, services, conversation(UUID)
}

struct MacWorkspaceRootView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let openBridge: () -> Void
    let openToolbox: (String) -> Void
    var remembersFileRoot = true

    @State private var destination: MacWorkspaceDestination? = .newTask
    @State private var showInspector = false
    @State private var showModelSettings = false
    @State private var showHistorySearch = false
    @FocusState private var historySearchFocused: Bool
    @State private var historySearch = ""
    @State private var drafts: [UUID?: String] = [:]
    @State private var taskToRename: ConversationRecord?
    @State private var taskTitle = ""
    @State private var showRename = false
    @State private var showExportError = false
    @State private var showMetadataError = false
    @State private var grantedFolder: URL?
    @State private var registeredFolder: URL?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 234, max: 320)
        } detail: {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                HStack(spacing: 0) {
                    if destination != .files { detail.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    if showInspector && destination != .files { Divider() }
                    MacWorkspaceFilesView(
                        insertInDraft: insertFileText,
                        canInsertInDraft: canSelectTask,
                        remembersRoot: remembersFileRoot,
                        taskAttachmentURLs: Set(workspace.stagedAttachments.map(\.url)),
                        onRootChanged: { grantedFolder = $0 },
                        onAttachmentsChanged: updateFileAttachments
                    )
                        .frame(minWidth: filesVisible ? 270 : 0,
                               maxWidth: destination == .files ? .infinity : (filesVisible ? 310 : 0))
                        .background(FloeTheme.readingSurface)
                        .clipped()
                        .opacity(filesVisible ? 1 : 0)
                        .allowsHitTesting(filesVisible)
                        .accessibilityHidden(!filesVisible)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await workspace.prepare()
            if destination == .newTask, workspace.selectedID != nil { await workspace.select(nil) }
        }
        .task(id: destination) {
            guard workspace.isReady else { return }
            switch destination {
            case .newTask:
                if workspace.selectedID != nil {
                    workspace.clearStagedAttachments()
                    await workspace.select(nil)
                }
            case .conversation(let id):
                if id != workspace.selectedID {
                    workspace.clearStagedAttachments()
                    await workspace.select(id)
                }
            default: break
            }
        }
        .task(id: canSelectTask ? grantedFolder : nil) {
            guard canSelectTask, let folder = grantedFolder, folder != registeredFolder else { return }
            if await workspace.addWorkspace(name: folder.lastPathComponent, rootURL: folder) {
                registeredFolder = folder
            }
        }
        .onChange(of: workspace.selectedID) { _, id in
            if let id, destination == .newTask, workspace.isSending { destination = .conversation(id) }
        }
        .onChange(of: destination) { _, newDestination in
            if newDestination == nil { destination = .taskCenter }
            if !showsTask { showInspector = false }
        }
        .sheet(isPresented: $showModelSettings) {
            MacProviderSettingsView(workspace: workspace, isPresented: $showModelSettings)
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
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("host.role.agent").font(.headline)
                Spacer(minLength: 8)
                Button {
                    showHistorySearch.toggle()
                    if !showHistorySearch { historySearch = "" }
                } label: {
                    Label("mac.workspace.findTask", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("mac.workspace.findTask")
                .keyboardShortcut("f", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            if showHistorySearch {
                TextField("mac.workspace.findTask", text: $historySearch)
                    .textFieldStyle(.roundedBorder)
                    .focused($historySearchFocused)
                    .onAppear { historySearchFocused = true }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    sidebarLink(.newTask, title: "workbench.new_task", icon: "square.and.pencil")
                        .disabled(!canSelectTask)
                        .keyboardShortcut("n", modifiers: .command)
                    sidebarLink(.taskCenter, title: "app.floe_agent_app.task_center", icon: "checklist")
                    sidebarLink(.files, title: "mac.workspace.files", icon: "folder")
                    sidebarLink(.toolbox, title: "host.menu.tools", icon: "wrench.and.screwdriver")
                    if !workspace.conversations.isEmpty {
                        Text("host.chat.history")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 9)
                            .padding(.top, 18)
                            .padding(.bottom, 4)
                    }
                    ForEach(filteredConversations) { conversation in
                        sidebarLink(.conversation(conversation.id), title: LocalizedStringKey(conversation.title),
                                    icon: conversation.isPinned ? "pin" : "bubble.left", conversationTitle: conversation.title)
                            .disabled(!canSelectTask && workspace.selectedID != conversation.id)
                            .contextMenu {
                                Button(LocalizedStringKey(conversation.isPinned ? "mac.workspace.unpin" : "mac.workspace.pin"),
                                       systemImage: conversation.isPinned ? "pin.slash" : "pin") {
                                    updateTask(id: conversation.id, change: .pin(!conversation.isPinned))
                                }
                                .disabled(!canSelectTask)
                                Button("mac.workspace.rename", systemImage: "pencil") {
                                    taskToRename = conversation
                                    taskTitle = conversation.title
                                    showRename = true
                                }
                                .disabled(!canSelectTask)
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            FloeWorkbenchSidebarFooter { destination = .services }
        }
        .background(FloeTheme.sidebarSurface)
    }

    private func sidebarLink(_ route: MacWorkspaceDestination, title: LocalizedStringKey, icon: String,
                             conversationTitle: String? = nil) -> some View {
        Button { destination = route } label: {
            Group {
                if let conversationTitle {
                    Label { Text(verbatim: conversationTitle) } icon: { Image(systemName: icon) }
                } else {
                    FloeWorkbenchSidebarItem(title: title, systemImage: icon)
                }
            }
            .labelStyle(MacWorkspaceLabelStyle())
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(destination == route ? FloeTheme.fieldSurface : Color.clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(destination == route ? .isSelected : [])
    }

    private var filteredConversations: [ConversationRecord] {
        workspace.conversations.filter {
            $0.isVisibleInOrdinaryList && (historySearch.isEmpty || $0.title.localizedStandardContains(historySearch))
        }
    }

    private var canSelectTask: Bool { workspace.isReady && !workspace.isSending && !workspace.isTerminating }

    private var filesVisible: Bool { destination == .files || showInspector }

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
        return Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 })
    }

    private var title: String {
        switch destination {
        case .newTask: String(localized: "mac.workspace.newTask")
        case .conversation(let id): workspace.conversations.first { $0.id == id }?.title ?? String(localized: "mac.workspace.task")
        case .files: String(localized: "mac.workspace.files")
        case .toolbox: String(localized: "host.menu.tools")
        case .services: String(localized: "mac.workspace.services")
        default: String(localized: "mac.workspace.taskCenter")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(title).font(.headline).lineLimit(1)
            Spacer(minLength: 8)
            if showsTask {
                if workspace.isSending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(runStatusTitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { showInspector.toggle() } label: {
                    Label("mac.workspace.files", systemImage: "sidebar.trailing")
                }
                .labelStyle(.iconOnly)
                .help("mac.workspace.files")
                .accessibilityIdentifier("workspace.files.toggle")
                .keyboardShortcut("i", modifiers: [.command, .option])
                .accessibilityAddTraits(showInspector ? .isSelected : [])
            }
            if case .conversation = destination {
                Button(action: exportConversation) {
                    Label("mac.workspace.exportChat", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .help("mac.workspace.exportChat")
                .disabled(!canSelectTask || workspace.messages.isEmpty || destinationConversationID != workspace.selectedID)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .frame(minHeight: 44)
        .background(FloeTheme.chromeMaterial)
    }

    private var runStatusTitle: LocalizedStringKey {
        if workspace.isStopping || workspace.runPhase == .cancelling {
            return "mac.workspace.runStopping"
        }
        if workspace.runPhase == nil { return "mac.workspace.runPreparing" }
        return "mac.workspace.inspector.running"
    }

    @ViewBuilder private var detail: some View {
        switch destination {
        case .newTask, .conversation:
            if destinationConversationID == workspace.selectedID {
                HostAgentWorkspaceView(workspace: workspace, workspaceDraft: taskDraft,
                                       openModelSettings: { showModelSettings = true },
                                       openFiles: { showInspector = true })
            } else {
                ProgressView("host.chat.opening")
            }
        case .files: EmptyView()
        case .toolbox:
            MacWorkspaceToolboxView(openToolbox: openToolbox)
        case .services:
            Form {
                Section("mac.workspace.connections") {
                    Button("host.role.bridge", action: openBridge)
                    Button("host.chat.provider") { showModelSettings = true }
                        .disabled(!canSelectTask)
                }
            }
            .formStyle(.grouped)
        default:
            MacWorkspaceTaskCenter(workspace: workspace, onOpen: openTask, onNew: startNewTask)
        }
    }

    private func startNewTask() {
        if canSelectTask { destination = .newTask }
    }

    private func insertFileText(_ text: String) {
        guard canSelectTask, filesVisible else { return }
        let id = destinationConversationID
        let current = drafts[id] ?? ""
        drafts[id] = current.isEmpty ? text : current + "\n\n" + text
        if !showsTask { destination = .newTask }
    }

    private func updateFileAttachments(_ files: [URL]) {
        guard canSelectTask else { return }
        let wanted = Set(files)
        let alreadyStaged = Set(workspace.stagedAttachments.map(\.url))
        for draft in workspace.stagedAttachments where !wanted.contains(draft.url) {
            workspace.unstageAttachment(draft.id)
        }
        _ = workspace.stageAttachments(files.filter { !alreadyStaged.contains($0) })
        if !showsTask && !files.isEmpty {
            destination = workspace.selectedID.map(MacWorkspaceDestination.conversation) ?? .newTask
        }
    }

    private func openTask(_ id: UUID) {
        if canSelectTask || workspace.selectedID == id { destination = .conversation(id) }
    }

    private func updateTask(id: UUID, change: FloeMacSelfRuntime.ConversationMetadataChange) {
        Task {
            let saved = await workspace.changeConversationMetadata(id: id, change: change)
            if !saved { showMetadataError = true }
        }
    }

    private func exportConversation() {
        guard canSelectTask, let id = destinationConversationID, id == workspace.selectedID else { return }
        let name = workspace.conversations.first { $0.id == id }?.title ?? String(localized: "mac.workspace.task")
        var sections = ["# \(name)"]
        sections += workspace.messages.compactMap { message in
            let role: String
            switch message.role {
            case "user": role = String(localized: "thread.role.user")
            case "assistant": role = String(localized: "thread.role.assistant")
            default: return nil
            }
            guard let text = CredentialMessagePart.clipboardText(message.content) else { return nil }
            return "## \(role)\n\n\(text)"
        }
        let output = sections.joined(separator: "\n\n") + "\n"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Floe Conversation.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(output.utf8).write(to: url, options: .atomic) }
        catch { showExportError = true }
    }
}

private struct MacWorkspaceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon
                .foregroundStyle(Color.accentColor)
                .frame(width: 19)
            configuration.title
        }
    }
}
