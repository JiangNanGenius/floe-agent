#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloePersistence

import FloeCore
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

    private func privateOwner(_ workspace: WorkspaceRecord) -> UUID? {
        // Document assistants are absent from the ordinary chat inventory but
        // still own valid workspaces. Resolve access from canonical ownership.
        guard workspace.kind == .privateTask else { return nil }
        let ids = center.conversationWorkspaceIDs.filter { $0.value == workspace.id }.map(\.key)
        return ids.count == 1 ? ids.first : nil
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
            Picker("settings.all_workspaces_files_view.workspace", selection: $filter) {
                Text("settings.usage_statistics_view.all").tag(0)
                Text("settings.all_workspaces_files_view.project").tag(1)
                Text("settings.all_workspaces_files_view.chat").tag(2)
                Text("settings.all_workspaces_files_view.archived").tag(3)
            }.pickerStyle(.segmented)
            NavigationLink {
                DocumentRecoveryListView()
            } label: {
                Label("settings.all_workspaces_files_view.kept_documents", systemImage: "doc.badge.clock")
            }
            .accessibilityIdentifier("files.recovery.open")
            if pendingCleanupCount > 0 {
                Section {
                    Text(FloeL10n.l("settings.all_workspaces_files_view.deleted_tasks_still_have_files_to", pendingCleanupCount))
                    Button("settings.all_workspaces_files_view.retry_cleanup") {
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
                        conversationID: privateOwner(workspace))
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspace.name.isEmpty ? (owners(workspace).first?.title ?? "settings.all_workspaces_files_view.workspace") : workspace.name)
                            Text(workspace.kind == .project ? "settings.all_workspaces_files_view.shared_projects" : (isArchived(workspace) ? "settings.all_workspaces_files_view.archived_chats" : "settings.all_workspaces_files_view.chat_workspace"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: workspace.kind == .project ? "folder" : "bubble.left") }
                }
            }
            if visible.isEmpty { ContentUnavailableView("settings.all_workspaces_files_view.no_matching_workspaces", systemImage: "folder") }
        }
        .navigationTitle(FloeL10n.l("settings.all_workspaces_files_view.all_workspaces"))
        .searchable(text: $query, prompt: "settings.all_workspaces_files_view.search_workspaces_or_chats")
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
            if let error { ContentUnavailableView("settings.all_workspaces_files_view.could_not_open_the_workspace", systemImage: "folder.badge.questionmark", description: Text(error)) }
            else if opened {
                if let selectedPath {
                    FilePreviewView(relativePath: selectedPath, center: center)
                        .toolbar { ToolbarItem(placement: .topBarLeading) {
                            Button("settings.all_workspaces_files_view.back_to_files", systemImage: "chevron.left") { self.selectedPath = nil }
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
