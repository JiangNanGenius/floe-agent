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

    let center: ConversationCenter

    init(center: ConversationCenter) {
        self.center = center
    }

    /// Conversations in recency order, straight from the center.
    var conversations: [ConversationRecord] {
        center.conversations
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
        let targets = offsets.map { center.conversations[$0] }
        for conversation in targets {
            try? await center.environment.conversationStore
                .deleteConversation(id: conversation.id)
        }
        await center.reload()
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
