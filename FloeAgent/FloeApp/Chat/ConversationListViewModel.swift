// FloeApp — Conversation list view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Presentation state for the Chat tab's conversation list. Holds only
// presentation state and delegates all work to ConversationCenter; it
// never touches stores or runtimes directly.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloePersistence

/// View model for the conversation list (Chat tab root).
@MainActor
final class ConversationListViewModel: ObservableObject {

    /// Whether a load is in flight (drives the honest loading state).
    @Published private(set) var isLoading = false
    /// The Chat list search query.
    @Published var searchText = ""

    let center: ConversationCenter

    init(center: ConversationCenter) {
        self.center = center
    }

    /// Conversations in recency order, straight from the center.
    var conversations: [ConversationRecord] {
        center.conversations
    }

    /// Conversations filtered by the search query (title substring,
    /// case-insensitive). An empty query returns the full list.
    var filteredConversations: [ConversationRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// True when no provider+model is configured — the list must show the
    /// actionable add-a-provider state instead of a bare empty list.
    var needsProvider: Bool {
        !center.hasConfiguredProvider
    }

    /// Reloads conversations and provider configuration.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        await center.reload()
    }

    /// Creates a conversation and returns it so the view can navigate.
    @discardableResult
    func createConversation() async throws -> ConversationRecord {
        try await center.createConversation(title: nil)
    }

    /// Deletes conversations at the given offsets.
    func delete(at offsets: IndexSet) async {
        // Offsets belong to the currently rendered (possibly searched)
        // list, not the center's unfiltered backing array.
        let visible = filteredConversations
        let targets = offsets.compactMap { visible.indices.contains($0) ? visible[$0] : nil }
        for conversation in targets {
            try? await center.deleteConversation(id: conversation.id)
        }
    }

    func archive(_ conversation: ConversationRecord) async {
        try? await center.archiveConversation(id: conversation.id)
    }

    func archive(ids: Set<UUID>) async {
        for id in ids { try? await center.archiveConversation(id: id) }
    }

    func delete(_ conversation: ConversationRecord) async {
        try? await center.deleteConversation(id: conversation.id)
    }

    func delete(ids: Set<UUID>) async {
        for id in ids { try? await center.deleteConversation(id: id) }
    }

    /// Display title: the stored title, falling back to the latest run's
    /// goal, finally to a localized untitled label handled by the view.
    func title(for conversation: ConversationRecord) -> String {
        conversation.title
    }

    /// Latest run state name for a conversation, for the status row.
    func latestRunState(for conversationID: UUID) async -> String? {
        await center.latestRun(conversationID: conversationID)?.state
    }
}
#endif
