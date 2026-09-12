// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

struct NotesKnowledgePicker: View {
    let conversationID: UUID
    let onSelect: @MainActor (NoteDocument, NotesStore) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [NoteDocument] = []
    @State private var store: NotesStore?
    @State private var query = ""
    @State private var allowEditing = false
    @State private var loading = true
    @State private var selecting = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("允许助手修改所选内容", isOn: $allowEditing)
                    Text("默认只读。修改仍使用 Floe 的工具权限与审批设置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("手记中的内容") {
                    ForEach(documents.filter { query.isEmpty || $0.searchableText.localizedStandardContains(query) }) { document in
                        Button {
                            guard let store, !selecting else { return }
                            selecting = true
                            Task {
                                defer { selecting = false }
                                do {
                                    try await store.grantAccess(conversationID: conversationID, documentID: document.id, canEdit: allowEditing)
                                    try await onSelect(document, store)
                                    dismiss()
                                } catch { failure = error.localizedDescription }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(document.title).foregroundStyle(.primary)
                                Text(document.kind == .office ? "Office 文件" : document.kind == .mindMap ? "思维导图" : "\(document.pages.count) 页")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(selecting)
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .searchable(text: $query, prompt: "搜索标题、正文与批注")
            .overlay { if loading { ProgressView("正在读取手记…") } }
            .navigationTitle("添加手记资料")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(selecting) } }
            .task {
                defer { loading = false }
                do {
                    let store = try await NotesRepository.shared.store()
                    documents = try await store.documents(); self.store = store
                } catch { failure = error.localizedDescription }
            }
        }
    }
}
#endif
