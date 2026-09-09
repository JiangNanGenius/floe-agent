#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloePersistence

struct AllWorkspacesFilesView: View {
    @StateObject private var center: WorkspaceCenter
    @State private var conversations: [UUID: ConversationRecord] = [:]
    @State private var query = ""
    @State private var filter = 0
    @State private var pendingCleanupCount = 0
    @State private var retryingCleanup = false

    init(environment: AppEnvironment) {
        _center = StateObject(wrappedValue: WorkspaceCenter(environment: environment, publishesSharedState: false))
    }

    private func owners(_ workspace: WorkspaceRecord) -> [ConversationRecord] {
        center.conversationWorkspaceIDs.compactMap { id, workspaceID in
            workspaceID == workspace.id ? conversations[id] : nil
        }
    }

    private func isArchived(_ workspace: WorkspaceRecord) -> Bool {
        let tasks = owners(workspace)
        return workspace.kind == .privateTask && !tasks.isEmpty && tasks.allSatisfy { $0.archivedAt != nil }
    }

    private var visible: [WorkspaceRecord] {
        center.workspaces.filter { workspace in
            let matchesType = filter == 0 || (filter == 1 && workspace.kind == .project)
                || (filter == 2 && workspace.kind == .privateTask && !isArchived(workspace))
                || (filter == 3 && isArchived(workspace))
            return matchesType && (query.isEmpty || workspace.name.localizedStandardContains(query)
                || owners(workspace).contains { $0.title.localizedStandardContains(query) })
        }
    }

    var body: some View {
        List {
            Picker("工作区", selection: $filter) {
                Text("全部").tag(0)
                Text("项目").tag(1)
                Text("聊天").tag(2)
                Text("已归档").tag(3)
            }.pickerStyle(.segmented)
            NavigationLink {
                DocumentRecoveryListView()
            } label: {
                Label("保留的文档", systemImage: "doc.badge.clock")
            }
            .accessibilityIdentifier("files.recovery.open")
            if pendingCleanupCount > 0 {
                Section {
                    Text("\(pendingCleanupCount) 个已删除任务的文件尚未清理")
                    Button("重试清理") {
                        Task {
                            retryingCleanup = true
                            _ = await center.retryPendingLocalCleanup()
                            await load()
                            retryingCleanup = false
                        }
                    }.disabled(retryingCleanup)
                }
            }
            if let error = center.actionError { Text(error).foregroundStyle(.red) }
            ForEach(visible) { workspace in
                NavigationLink {
                    ManagedWorkspaceFilesView(center: center, workspace: workspace,
                        conversationID: owners(workspace).first?.id)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspace.name.isEmpty ? (owners(workspace).first?.title ?? "工作区") : workspace.name)
                            Text(workspace.kind == .project ? "共享项目" : (isArchived(workspace) ? "已归档聊天" : "聊天工作区"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: workspace.kind == .project ? "folder" : "bubble.left") }
                }
            }
            if visible.isEmpty { ContentUnavailableView("没有匹配的工作区", systemImage: "folder") }
        }
        .navigationTitle("所有工作区")
        .searchable(text: $query, prompt: "搜索工作区或聊天")
        .onAppear { center.closeCurrentWorkspace() }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        await center.reload()
        do {
            pendingCleanupCount = try await SQLiteWorkspaceStore(database: center.environment.database).pendingLocalCleanup().count
            let all = try await center.environment.conversationStore.conversations(includeArchived: true)
            conversations = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        } catch { center.actionError = error.localizedDescription }
    }
}

private struct ManagedWorkspaceFilesView: View {
    @ObservedObject var center: WorkspaceCenter
    let workspace: WorkspaceRecord
    let conversationID: UUID?
    @StateObject private var tree: FileTreeViewModel
    @State private var opened = false
    @State private var selectedPath: String?
    @State private var error: String?

    init(center: WorkspaceCenter, workspace: WorkspaceRecord, conversationID: UUID?) {
        self.center = center; self.workspace = workspace; self.conversationID = conversationID
        _tree = StateObject(wrappedValue: FileTreeViewModel(center: center))
    }

    var body: some View {
        Group {
            if let error { ContentUnavailableView("无法打开工作区", systemImage: "folder.badge.questionmark", description: Text(error)) }
            else if opened {
                if let selectedPath {
                    FilePreviewView(relativePath: selectedPath, center: center)
                        .toolbar { ToolbarItem(placement: .topBarLeading) {
                            Button("返回文件", systemImage: "chevron.left") { self.selectedPath = nil }
                                .accessibilityIdentifier("workspace.preview.backToFiles")
                        } }
                } else {
                    FileTreeView(viewModel: tree) { selectedPath = $0 }
                }
            } else { ProgressView() }
        }
        .navigationTitle(workspace.name)
        .navigationBarBackButtonHidden(selectedPath != nil)
        .task(id: workspace.id) {
            do {
                if workspace.kind == .project { try await center.openWorkspace(id: workspace.id) }
                else if let conversationID { try await center.openTaskWorkspace(conversationID: conversationID) }
                else { throw CocoaError(.fileNoSuchFile) }
                try Task.checkCancellation()
                await tree.loadRoot()
                opened = true
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
#endif
