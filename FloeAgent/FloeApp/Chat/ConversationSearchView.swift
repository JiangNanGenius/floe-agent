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

#if canImport(SwiftUI)
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

struct FloeConversationSearchList: View {
    let searchMatches: (String) async throws -> [ConversationSearchMatch]
    let openMatch: (ConversationSearchMatch) -> Void

    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var resultsQuery = ""
    @State private var matches: [ConversationSearchMatch] = []
    @State private var searchError: String?
    @State private var isSearching = false

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var currentMatches: [ConversationSearchMatch] { resultsQuery == term ? matches : [] }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                searchField
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: FloeTheme.minimumTarget)
            Divider()
            List { resultsSection }.listStyle(.inset)
        }
        .defaultFocus($searchFocused, true)
        .onExitCommand { dismiss() }
        .task(id: term) { await search(term) }
        #else
        List {
            Section {
                searchField
                if isSearching { ProgressView().controlSize(.small) }
            }
            resultsSection
        }
        .task(id: term) { await search(term) }
        #endif
    }

    private var searchField: some View {
        TextField("chat.conversation_search_view.search_conversations", text: $query)
            .textFieldStyle(.roundedBorder)
            .focused($searchFocused)
            .accessibilityIdentifier("workspace.taskSearch")
            #if os(macOS)
            .onSubmit { if let first = currentMatches.first { openMatch(first) } }
            #endif
    }

    private var resultsSection: some View {
        Section("chat.conversation_search_view.result") {
            if let searchError, resultsQuery == term { Text(searchError).foregroundStyle(FloeTheme.destructive) }
            if currentMatches.isEmpty, !term.isEmpty, resultsQuery == term, !isSearching, searchError == nil {
                ContentUnavailableView(
                    "chat.conversation_search_view.no_matching_messages_found",
                    systemImage: "magnifyingglass")
            } else {
                ForEach(currentMatches) { hit in resultButton(hit) }
            }
        }
    }

    private func resultButton(_ hit: ConversationSearchMatch) -> some View {
        Button {
            guard resultsQuery == term else { return }
            openMatch(hit)
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
            .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("globalSearch.hit.\(hit.messageID?.uuidString ?? hit.conversationID.uuidString)")
        #if os(macOS) && FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader {
            Self.smokeSearchResultFrames[hit.messageID ?? hit.conversationID] = $0
        })
        #endif
    }

    #if os(macOS) && FLOE_MAC_HOST_SMOKE
    static var smokeSearchResultFrames: [UUID: CGRect] = [:]
    #endif

    private func search(_ value: String) async {
        guard !Task.isCancelled, value == term else { return }
        matches = []
        searchError = nil
        resultsQuery = ""
        guard !value.isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        defer { if !Task.isCancelled, value == term { isSearching = false } }
        do {
            try await Task.sleep(for: .milliseconds(220))
            let results = try await searchMatches(value)
            guard !Task.isCancelled, value == term else { return }
            matches = results
            resultsQuery = value
        } catch {
            guard !Task.isCancelled, value == term else { return }
            resultsQuery = value
            searchError = error.localizedDescription
        }
    }
}

#if canImport(UIKit)
struct ConversationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        FloeConversationSearchList { value in
            try await environment.intelligenceStore.conversationSearchMatches(value, limit: 40).filter {
                !$0.conversationTitle.hasPrefix(CanvasAgentIdentity.conversationTitlePrefix)
            }
        } openMatch: { hit in
            dismiss()
            router.openConversation(hit.conversationID)
            if let messageID = hit.messageID {
                ThreadSearchJumpCenter.request(conversationID: hit.conversationID, messageID: messageID)
            }
        }
        .navigationTitle("chat.search.prompt")
    }
}
#endif
#endif
