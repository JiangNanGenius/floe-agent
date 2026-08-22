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
        .sheet(isPresented: $presentsArchive) {
            NavigationStack { ArchivedConversationsView(center: viewModel.center) }
        }
        .alert("删除任务？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) {
                guard let target = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await viewModel.delete(target) }
            }
        } message: {
            Text("任务、私有工作区和临时凭据将被删除，此操作不可撤销。")
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
                        router.openConversation(conversation.id)
                    } label: {
                        ConversationRow(
                            conversation: conversation,
                            fallbackTitle: String(localized: "chat.untitled"),
                            isSelected: horizontalSizeClass == .regular
                                && router.selectedConversationID == conversation.id
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("chat.open.hint")
                    .accessibilityIdentifier("chat.row.\(conversation.id.uuidString)")
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await viewModel.archive(conversation) }
                        } label: { Label("归档", systemImage: "archivebox") }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = conversation
                        } label: { Label("删除", systemImage: "trash") }
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
            .accessibilityLabel("归档区")
        }
        ToolbarItem(placement: .primaryAction) { EditButton() }
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
                Button("归档所选") {
                    let ids = selectedIDs
                    selectedIDs.removeAll()
                    editMode = .inactive
                    Task { await viewModel.archive(ids: ids) }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("删除所选", role: .destructive) {
                    let ids = selectedIDs
                    selectedIDs.removeAll()
                    editMode = .inactive
                    Task { await viewModel.delete(ids: ids) }
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

private struct ArchivedConversationsView: View {
    let center: ConversationCenter
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [ConversationRecord] = []
    @State private var selection: Set<UUID> = []
    @State private var confirmsDelete = false
    @State private var confirmsDeleteAll = false

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
        }
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView("归档区为空", systemImage: "archivebox")
            }
        }
        .navigationTitle("归档区")
        .environment(\.editMode, .constant(.active))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            if !selection.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("恢复所选") { Task { await restoreSelection() } }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("永久删除", role: .destructive) { confirmsDelete = true }
                }
            }
            if !conversations.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("清空", role: .destructive) { confirmsDeleteAll = true }
                }
            }
        }
        .task { await load() }
        .alert("永久删除所选任务？", isPresented: $confirmsDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await delete(ids: selection) } }
        } message: { Text("任务、生成内容、私有工作区和附件引用将被永久删除。") }
        .alert("清空归档区？", isPresented: $confirmsDeleteAll) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) {
                Task { await delete(ids: Set(conversations.map(\.id))) }
            }
        } message: { Text("归档区内的所有任务及其私有数据将被永久删除。") }
    }

    private func load() async {
        conversations = ((try? await center.environment.conversationStore
            .conversations(includeArchived: true)) ?? [])
            .filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? $0.updatedAt) > ($1.archivedAt ?? $1.updatedAt) }
        selection.formIntersection(Set(conversations.map(\.id)))
    }

    private func restoreSelection() async {
        for id in selection { try? await center.restoreConversation(id: id) }
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
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title.isEmpty ? fallbackTitle : conversation.title)
                    .font(FloeTheme.Typography.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
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
