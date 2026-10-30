// FloeApp — Conversation full-text search.
//
// SPDX-License-Identifier: MPL-2.0
//
// Searches every searchable ordinary conversation with the shared multi-term
// normalizer (whitespace AND, quoted phrase). A body hit is shown as its
// actual message hit line and opens that EXACT message; a title-only match
// opens the conversation without inventing a body hit. Notes/other purposes
// and non-searchable tasks stay excluded by the durable store filters.
//
// A temporary chat lives only in RAM and is intentionally absent here; the
// in-chat find is the memory-only search for that session.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

struct ConversationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @State private var query = ""
    @State private var matches: [ConversationSearchMatch] = []
    @State private var searchError: String?
    @State private var isSearching = false

    var body: some View {
        List {
            Section {
                TextField("chat.conversation_search_view.search_conversations", text: $query)
                    .textFieldStyle(.roundedBorder)
                if isSearching {
                    ProgressView()
                }
            }
            Section("chat.conversation_search_view.result") {
                if let searchError { Text(searchError).foregroundStyle(.red) }
                if matches.isEmpty, !query.isEmpty, !isSearching, searchError == nil {
                    ContentUnavailableView(
                        "chat.conversation_search_view.no_matching_messages_found",
                        systemImage: "magnifyingglass")
                } else {
                    ForEach(matches) { hit in
                        Button {
                            open(hit)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(hit.conversationTitle)
                                        .font(.headline)
                                        .lineLimit(1)
                                    if hit.isTitleOnly {
                                        Text(ThreadSearchCopy.titleOnly)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(hit.snippet)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(hit.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityIdentifier(
                            "globalSearch.hit.\(hit.messageID?.uuidString ?? hit.conversationID.uuidString)")
                    }
                }
            }
        }
        .navigationTitle("chat.search.prompt")
        .task(id: query) { await search() }
    }

    private func open(_ hit: ConversationSearchMatch) {
        dismiss()
        router.openConversation(hit.conversationID)
        // Title-only: open the conversation and stop. Only a real message hit
        // asks the thread to reveal/highlight an exact row.
        if let messageID = hit.messageID {
            ThreadSearchJumpCenter.request(
                conversationID: hit.conversationID, messageID: messageID)
        }
    }

    private func search() async {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            matches = []
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(220))
            let results = try await environment.intelligenceStore
                .conversationSearchMatches(value, limit: 40)
            guard !Task.isCancelled, value == query.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            // Internal Canvas agent conversations are not ordinary library
            // history (the previous screen excluded them by the same durable
            // marker). The durable store filters stay authoritative.
            matches = results.filter {
                !$0.conversationTitle.hasPrefix(CanvasAgentIdentity.conversationTitlePrefix)
            }
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            isSearching = false
            searchError = error.localizedDescription
        }
    }
}
#endif
