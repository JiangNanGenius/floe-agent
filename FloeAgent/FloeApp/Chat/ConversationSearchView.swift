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

struct ConversationSearchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @State private var query = ""
    @State private var results: [ConversationSearchHit] = []
    @State private var isSearching = false

    var body: some View {
        List {
            Section {
                TextField("搜索对话内容…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                if isSearching {
                    ProgressView()
                }
            }
            Section("结果") {
                if results.isEmpty, !query.isEmpty {
                    ContentUnavailableView("没有找到匹配的消息", systemImage: "magnifyingglass")
                } else {
                    ForEach(results) { hit in
                        Button {
                            router.openConversation(hit.conversationID)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.conversationTitle)
                                    .font(.headline)
                                Text(hit.snippet)
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
    }

    private func search() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let request = ConversationSearchRequest(query: query, limit: 50)
            results = try await environment.intelligenceStore.search(request)
        } catch {
            results = []
        }
    }
}
#endif
