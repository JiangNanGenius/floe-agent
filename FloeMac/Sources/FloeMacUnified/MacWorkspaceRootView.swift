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
    @Environment(\.colorScheme) private var colorScheme

    @State private var destination: MacWorkspaceDestination? = .newTask
    @State private var showInspector = false
    @State private var showModelSettings = false
    @State private var historySearch = ""
    @State private var drafts: [UUID?: String] = [:]
    @State private var taskToRename: ConversationRecord?
    @State private var taskTitle = ""
    @State private var showRename = false
    @State private var showExportError = false
    @State private var showMetadataError = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 234, max: 320)
        } detail: {
            VStack(spacing: 0) {
                header
                Rectangle().fill(FloeTheme.separator.opacity(0.45)).frame(height: 1)
                ZStack {
                    MacWorkspaceFilesView(insertInDraft: insertFileText, canInsertInDraft: canSelectTask)
                        .opacity(destination == .files ? 1 : 0)
                        .allowsHitTesting(destination == .files)
                        .accessibilityHidden(destination != .files)
                    if destination != .files { detail }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .inspector(isPresented: $showInspector) {
                inspector
                    .inspectorColumnWidth(min: 235, ideal: 275, max: 340)
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
            case .newTask: await workspace.select(nil)
            case .conversation(let id):
                if id != workspace.selectedID { await workspace.select(id) }
            default: break
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
            List(selection: $destination) {
                Section {
                    FloeWorkbenchSidebarItem(title: "workbench.new_task", systemImage: "square.and.pencil", foreground: sidebarText(for: .newTask))
                        .tag(MacWorkspaceDestination.newTask)
                        .disabled(!canSelectTask)
                    FloeWorkbenchSidebarItem(title: "app.floe_agent_app.task_center", systemImage: "checklist", foreground: sidebarText(for: .taskCenter))
                        .tag(MacWorkspaceDestination.taskCenter)
                    FloeWorkbenchSidebarItem(title: "mac.workspace.files", systemImage: "folder", foreground: sidebarText(for: .files))
                        .tag(MacWorkspaceDestination.files)
                    FloeWorkbenchSidebarItem(title: "host.menu.tools", systemImage: "wrench.and.screwdriver", foreground: sidebarText(for: .toolbox))
                        .tag(MacWorkspaceDestination.toolbox)
                }
                if !workspace.conversations.isEmpty {
                    Section {
                        TextField("mac.workspace.findTask", text: $historySearch)
                            .textFieldStyle(.roundedBorder)
                        ForEach(filteredConversations) { conversation in
                            Label(conversation.title, systemImage: conversation.isPinned ? "pin" : "bubble.left")
                                .foregroundStyle(sidebarText(for: .conversation(conversation.id)))
                                .lineLimit(1)
                                .tag(MacWorkspaceDestination.conversation(conversation.id))
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
                    } header: { Text("host.chat.history").foregroundStyle(.secondary) }
                }
            }
            .listStyle(.sidebar)
            FloeWorkbenchSidebarFooter { destination = .services }
        }
        .navigationTitle("app.name")
    }

    private var filteredConversations: [ConversationRecord] {
        workspace.conversations.filter {
            $0.isVisibleInOrdinaryList && (historySearch.isEmpty || $0.title.localizedStandardContains(historySearch))
        }
    }

    private func sidebarText(for row: MacWorkspaceDestination) -> Color {
        if destination == row { return .white }
        return colorScheme == .dark ? Color(white: 0.90) : .primary
    }

    private var canSelectTask: Bool { workspace.isReady && !workspace.isSending && !workspace.isTerminating }

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
            if case .conversation = destination {
                Button(action: exportConversation) {
                    Label("mac.workspace.exportChat", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .help("mac.workspace.exportChat")
                .disabled(!canSelectTask || workspace.messages.isEmpty || destinationConversationID != workspace.selectedID)
                Button { showInspector.toggle() } label: {
                    Label("mac.workspace.inspector", systemImage: "sidebar.trailing")
                }
                .labelStyle(.iconOnly)
                .help("mac.workspace.inspector")
            }
            if destination != .newTask {
                Button { showModelSettings = true } label: {
                    Label(workspace.modelName ?? String(localized: "host.chat.provider"), systemImage: "cpu")
                        .lineLimit(1)
                }
                .disabled(!canSelectTask)
                Button(action: startNewTask) {
                    Label("mac.workspace.newTask", systemImage: "plus")
                }
                .disabled(!canSelectTask)
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(FloeTheme.chromeMaterial)
    }

    @ViewBuilder private var detail: some View {
        switch destination {
        case .newTask, .conversation:
            if destinationConversationID == workspace.selectedID {
                HostAgentWorkspaceView(workspace: workspace, workspaceDraft: taskDraft) { showModelSettings = true }
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
                Section("mac.workspace.pendingServices") {
                    Text("mac.workspace.pendingServicesList").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        default:
            MacWorkspaceTaskCenter(workspace: workspace, onOpen: openTask, onNew: startNewTask)
        }
    }

    private var inspector: some View {
        Form {
            Section("mac.workspace.task") {
                LabeledContent("mac.workspace.inspector.messages", value: workspace.messages.count.formatted())
                if workspace.isSending {
                    Label("mac.workspace.inspector.running", systemImage: "bolt.horizontal")
                }
                if let id = workspace.selectedID,
                   let conversation = workspace.conversations.first(where: { $0.id == id }) {
                    LabeledContent("mac.workspace.inspector.updated") {
                        Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                    }
                }
            }
            Section("mac.workspace.files") {
                Button("mac.workspace.browseFiles") { destination = .files }
            }
        }
        .formStyle(.grouped)
    }

    private func startNewTask() {
        if canSelectTask { destination = .newTask }
    }

    private func insertFileText(_ text: String) {
        guard canSelectTask, destination == .files else { return }
        let current = drafts[nil] ?? ""
        drafts[nil] = current.isEmpty ? text : current + "\n\n" + text
        destination = .newTask
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
