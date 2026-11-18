// SPDX-License-Identifier: MPL-2.0

import FloePersistence
import SwiftUI

private enum MacWorkspaceDestination: Hashable {
    case newTask, taskCenter, files, toolbox, services, conversation(UUID)
}

struct MacWorkspaceRootView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let openBridge: () -> Void
    let openToolbox: (String) -> Void

    @State private var destination: MacWorkspaceDestination? = .taskCenter
    @State private var showInspector = false
    @State private var showModelSettings = false
    @State private var historySearch = ""
    @State private var drafts: [UUID?: String] = [:]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 234, max: 320)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                ZStack {
                    MacWorkspaceFilesView()
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
        .task { await workspace.prepare() }
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
            HostAgentProviderForm(workspace: workspace, isPresented: $showModelSettings)
        }
    }

    private var sidebar: some View {
        List(selection: $destination) {
            Section {
                Label("mac.workspace.newTask", systemImage: "square.and.pencil")
                    .tag(MacWorkspaceDestination.newTask)
                    .disabled(!canSelectTask)
                Label("mac.workspace.taskCenter", systemImage: "checklist")
                    .tag(MacWorkspaceDestination.taskCenter)
                Label("mac.workspace.files", systemImage: "folder")
                    .tag(MacWorkspaceDestination.files)
                Label("host.menu.tools", systemImage: "wrench.and.screwdriver")
                    .tag(MacWorkspaceDestination.toolbox)
                Label("mac.workspace.services", systemImage: "slider.horizontal.3")
                    .tag(MacWorkspaceDestination.services)
            }
            Section("host.chat.history") {
                if !workspace.conversations.isEmpty {
                    TextField("mac.workspace.findTask", text: $historySearch)
                        .textFieldStyle(.roundedBorder)
                }
                ForEach(filteredConversations) { conversation in
                    Label(conversation.title, systemImage: conversation.isPinned ? "pin" : "bubble.left")
                        .lineLimit(1)
                        .tag(MacWorkspaceDestination.conversation(conversation.id))
                        .disabled(!canSelectTask && workspace.selectedID != conversation.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("host.role.agent")
    }

    private var filteredConversations: [ConversationRecord] {
        workspace.conversations.filter {
            $0.isVisibleInOrdinaryList && (historySearch.isEmpty || $0.title.localizedStandardContains(historySearch))
        }
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
            if showsTask {
                Button { showInspector.toggle() } label: {
                    Label("mac.workspace.inspector", systemImage: "sidebar.trailing")
                }
                .labelStyle(.iconOnly)
                .help("mac.workspace.inspector")
            }
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder private var detail: some View {
        switch destination {
        case .newTask, .conversation:
            if destinationConversationID == workspace.selectedID {
                HostAgentWorkspaceView(workspace: workspace, workspaceDraft: taskDraft)
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

    private func openTask(_ id: UUID) {
        if canSelectTask || workspace.selectedID == id { destination = .conversation(id) }
    }
}
