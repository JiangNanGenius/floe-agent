// FloeApp — Conversation full-text search.
//
// Provides a UI to search all conversation messages using the existing FTS5
// index. Results show the conversation title and a snippet; tapping a result
// jumps to that conversation.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

struct ConversationSearchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @State private var query = ""
    @State private var results: [ConversationRecord] = []
    @State private var snippets: [UUID: String] = [:]
    @State private var searchError: String?
    @State private var isSearching = false

    var body: some View {
        List {
            Section {
                TextField("搜索对话内容…", text: $query)
                    .textFieldStyle(.roundedBorder)

                if isSearching {
                    ProgressView()
                }
            }
            Section("结果") {
                if let searchError { Text(searchError).foregroundStyle(.red) }
                if results.isEmpty, !query.isEmpty, !isSearching, searchError == nil {
                    ContentUnavailableView("没有找到匹配的消息", systemImage: "magnifyingglass")
                } else {
                    ForEach(results) { hit in
                        Button {
                            router.openConversation(hit.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.title)
                                    .font(.headline)
                                Text(snippets[hit.id] ?? hit.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                Text(hit.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("搜索对话")
        .task(id: query) { await search() }
    }

    private func search() async {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; snippets = [:]; searchError = nil
        guard !value.isEmpty else { isSearching = false; return }
        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(220))
            let matches = try await environment.intelligenceStore.matchingConversationSnippets(value)
            let conversations = try await environment.conversationStore.conversations(includeArchived: true)
            guard !Task.isCancelled else { return }
            snippets = matches
            results = conversations.filter { !CanvasAgentIdentity.isCanvasConversation($0) && ($0.title.localizedStandardContains(value) || matches[$0.id] != nil) }
            isSearching = false
        } catch is CancellationError { return }
        catch { guard !Task.isCancelled else { return }; isSearching = false; searchError = error.localizedDescription }
    }
}
#endif
