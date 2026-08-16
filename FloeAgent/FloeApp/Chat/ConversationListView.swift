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
        List {
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
    }

    private func createAndOpen() {
        Task {
            if let conversation = try? await viewModel.createConversation() {
                router.openConversation(conversation.id)
            }
        }
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
