// FloeApp — Conversation list (Chat tab root).
//
// SPDX-License-Identifier: MPL-2.0
//
// Chat is where history is MANAGED and CONTINUED: searchable list, new
// conversation entry, explicit selection on iPad, push navigation on
// iPhone. When no provider is configured the empty state is actionable
// (add a provider), never a fake message list. All strings resolve
// through the catalog.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence

/// The Chat tab root: conversation list → thread detail.
struct ConversationListView: View {
    @StateObject private var viewModel: ConversationListViewModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pendingDeletion: ConversationRecord?
    @State private var selectedIDs: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var presentsArchive = false
    @State private var batchStartingConversation: ConversationRecord?
    @State private var confirmsBatchDelete = false

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: ConversationListViewModel(center: center))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.conversations.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.conversations.isEmpty {
                emptyState
            } else {
                conversationList
            }
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("tab.chat")
        .toolbar { toolbarContent }
        .task { await viewModel.load() }
        .task(id: viewModel.searchText) { await viewModel.searchContents() }
        .refreshable { await viewModel.load() }
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: Text("chat.search.prompt")
        )
        .navigationDestination(for: UUID.self) { conversationID in
            ThreadDetailView(conversationID: conversationID, center: viewModel.center)
        }
        .environment(\.editMode, $editMode)
        .sheet(item: $batchStartingConversation) { conversation in
            ConversationBatchManagementView(center: viewModel.center, initialConversation: conversation)
        }
        .alert("chat.conversation_list_view.action_failed", isPresented: Binding(get: { viewModel.actionError != nil }, set: { if !$0 { viewModel.actionError = nil } })) {
            Button("workspace.office_document_editor_view.ok", role: .cancel) { viewModel.actionError = nil }
        } message: { Text(viewModel.actionError ?? "") }
        .confirmationDialog("chat.conversation_list_view.delete_the_selected_tasks", isPresented: $confirmsBatchDelete, titleVisibility: .visible) {
            Button("workspace.workspace_canvas_view.delete", role: .destructive) {
                let ids = selectedIDs
                Task { await viewModel.delete(ids: ids); selectedIDs.formIntersection(Set(viewModel.conversations.map(\.id))) }
            }
        } message: { Text("chat.conversation_batch_management_view.the_task_and_its_private_workspace") }
        .sheet(isPresented: $presentsArchive) {
            NavigationStack { ArchivedConversationsView(center: viewModel.center) }
        }
        .alert("app.floe_agent_app.delete_task", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) { pendingDeletion = nil }
            Button("workspace.workspace_canvas_view.delete", role: .destructive) {
                guard let target = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await viewModel.delete(target) }
            }
        } message: {
            Text("chat.conversation_list_view.the_task_private_workspace_and_temporary")
        }
    }

    // MARK: - Empty state (honest, actionable)

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.needsProvider {
            ContentUnavailableView {
                Label("empty.providers", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("chat.add_provider.hint")
            } actions: {
                Button("setup.launcher.open") {
                    router.presentedSetup = .manual
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: FloeTheme.minimumTarget)
            }
        } else {
            ContentUnavailableView {
                Label("tab.chat", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("empty.conversations")
            } actions: {
                Button("chat.new") { createAndOpen() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: FloeTheme.minimumTarget)
            }
        }
    }

    // MARK: - List

    private var conversationList: some View {
        List(selection: $selectedIDs) {
            if viewModel.filteredConversations.isEmpty {
                // A search with no matches is an honest state, not an
                // empty history list.
                ContentUnavailableView {
                    Label("chat.search.no_results", systemImage: "magnifyingglass")
                } description: {
                    Text(viewModel.searchText)
                        .font(FloeTheme.Typography.metadata)
                }
            } else {
                ForEach(viewModel.filteredConversations) { conversation in
                    Button {
                        if editMode.isEditing {
                            if !selectedIDs.insert(conversation.id).inserted { selectedIDs.remove(conversation.id) }
                        } else { router.openConversation(conversation.id) }
                    } label: {
                        HStack {
                            ConversationRow(
                            conversation: conversation,
                            fallbackTitle: String(localized: "chat.untitled"),
                            searchSnippet: viewModel.searchSnippets[conversation.id],
                            isSelected: horizontalSizeClass == .regular
                                && router.selectedConversationID == conversation.id
                        )
                            ConversationActivityBadge(conversationID: conversation.id, center: viewModel.center)
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(conversation.id)
                    .accessibilityHint("chat.open.hint")
                    .accessibilityIdentifier("chat.row.\(conversation.id.uuidString)")
                    .contextMenu {
                        Button("home.home_overview_view.select_multiple", systemImage: "checkmark.circle") { batchStartingConversation = conversation }
                            .accessibilityIdentifier("chat.selectMultiple")
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await viewModel.archive(conversation) }
                        } label: { Label("app.floe_agent_app.archive", systemImage: "archivebox") }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = conversation
                        } label: { Label("workspace.workspace_canvas_view.delete", systemImage: "trash") }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                presentsArchive = true
            } label: {
                Image(systemName: "archivebox")
            }
            .accessibilityLabel("chat.conversation_list_view.archive")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                createAndOpen()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("chat.new")
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .disabled(viewModel.needsProvider)
            .accessibilityIdentifier("chat.new")
        }
        if editMode.isEditing, !selectedIDs.isEmpty {
            ToolbarItem(placement: .bottomBar) {
                Button("chat.conversation_list_view.archive_selection") {
                    let ids = selectedIDs
                    selectedIDs.removeAll()
                    editMode = .inactive
                    Task { await viewModel.archive(ids: ids) }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("home.home_overview_view.delete_selection", role: .destructive) {
                    confirmsBatchDelete = true
                }
            }
        }
    }

    private func createAndOpen() {
        Task {
            if let conversation = try? await viewModel.createConversation() {
                router.openConversation(conversation.id)
            }
        }
    }
}

struct ArchivedConversationsView: View {
    let center: ConversationCenter
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [ConversationRecord] = []
    @State private var selection: Set<UUID> = []
    @State private var confirmsDelete = false
    @State private var confirmsDeleteAll = false
    @State private var conversationPendingDeletion: ConversationRecord?

    var body: some View {
        List(conversations, selection: $selection) { conversation in
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title.isEmpty ? String(localized: "chat.untitled") : conversation.title)
                if let archivedAt = conversation.archivedAt {
                    Text(archivedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: FloeTheme.minimumTarget)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Task { await restore(ids: [conversation.id]) }
                } label: {
                    Label("canvas.drawingHistory.restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    conversationPendingDeletion = conversation
                } label: {
                    Label("notes.notes_root_view.delete_permanently", systemImage: "trash")
                }
            }
        }
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView("chat.conversation_list_view.the_archive_is_empty", systemImage: "archivebox")
            }
        }
        .navigationTitle("chat.conversation_list_view.archive")
        .environment(\.editMode, .constant(.active))
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("workspace.workspace_canvas_view.done") { dismiss() }
                }
            }
            if !selection.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("home.home_overview_view.restore_selection") { Task { await restoreSelection() } }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("notes.notes_root_view.delete_permanently", role: .destructive) { confirmsDelete = true }
                }
            }
            if !conversations.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("chat.conversation_list_view.clear", role: .destructive) { confirmsDeleteAll = true }
                }
            }
        }
        .task { await load() }
        .alert("chat.conversation_list_view.permanently_delete_the_selected_tasks", isPresented: $confirmsDelete) {
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) {}
            Button("workspace.workspace_canvas_view.delete", role: .destructive) { Task { await delete(ids: selection) } }
        } message: { Text("chat.conversation_list_view.the_task_generated_content_private_workspace") }
        .alert("chat.conversation_list_view.clear_the_archive", isPresented: $confirmsDeleteAll) {
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) {}
            Button("settings.privacy.clear_history.confirm", role: .destructive) {
                Task { await delete(ids: Set(conversations.map(\.id))) }
            }
        } message: { Text("chat.conversation_list_view.all_tasks_in_the_archive_and") }
        .alert("chat.conversation_list_view.permanently_delete_this_task",
            isPresented: Binding(
                get: { conversationPendingDeletion != nil },
                set: { if !$0 { conversationPendingDeletion = nil } }
            )
        ) {
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) { conversationPendingDeletion = nil }
            Button("workspace.workspace_canvas_view.delete", role: .destructive) {
                guard let conversation = conversationPendingDeletion else { return }
                conversationPendingDeletion = nil
                Task { await delete(ids: [conversation.id]) }
            }
        } message: {
            Text("chat.conversation_list_view.the_task_generated_content_private_workspace_2")
        }
    }

    private func load() async {
        conversations = ((try? await center.environment.conversationStore
            .conversations(includeArchived: true)) ?? [])
            .filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? $0.updatedAt) > ($1.archivedAt ?? $1.updatedAt) }
        selection.formIntersection(Set(conversations.map(\.id)))
    }

    private func restoreSelection() async {
        await restore(ids: selection)
    }

    private func restore(ids: Set<UUID>) async {
        for id in ids { try? await center.restoreConversation(id: id) }
        selection.removeAll()
        await load()
    }

    private func delete(ids: Set<UUID>) async {
        for id in ids { try? await center.deleteConversation(id: id) }
        selection.removeAll()
        await load()
    }
}

/// One conversation row: title + updated time, with an explicit selected
/// treatment on iPad. No invented live data — the row shows only what is
/// persisted.
private struct ConversationRow: View {
    let conversation: ConversationRecord
    let fallbackTitle: String
    var searchSnippet: String? = nil
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title.isEmpty ? fallbackTitle : conversation.title)
                    .font(FloeTheme.Typography.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let searchSnippet { Text(searchSnippet).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(FloeTheme.primary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .frame(minHeight: FloeTheme.minimumTarget)
        .background(
            isSelected ? FloeTheme.primary.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
