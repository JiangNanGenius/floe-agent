// FloeApp — Conversation list (Chat tab root).
//
// SPDX-License-Identifier: MPL-2.0
//
// Lists conversations and pushes the canonical thread detail. When no
// provider is configured the empty state is actionable (add a provider),
// never a fake message list. All strings resolve through the catalog.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence

/// The Chat tab root: conversation list → thread detail.
struct ConversationListView: View {
    @StateObject private var viewModel: ConversationListViewModel
    @EnvironmentObject private var router: AppRouter

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
        .navigationDestination(for: UUID.self) { conversationID in
            ThreadDetailView(conversationID: conversationID, center: viewModel.center)
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
            ForEach(viewModel.conversations) { conversation in
                Button {
                    router.openConversation(conversation.id)
                } label: {
                    ConversationRow(
                        conversation: conversation,
                        fallbackTitle: String(localized: "chat.untitled")
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("chat.open.hint")
            }
            .onDelete { offsets in
                Task { await viewModel.delete(at: offsets) }
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

/// One conversation row: title + updated time. No invented live data —
/// the row shows only what is persisted.
private struct ConversationRow: View {
    let conversation: ConversationRecord
    let fallbackTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title.isEmpty ? fallbackTitle : conversation.title)
                .font(FloeTheme.Typography.body)
                .lineLimit(1)
            Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .frame(minHeight: FloeTheme.minimumTarget)
    }
}
#endif
