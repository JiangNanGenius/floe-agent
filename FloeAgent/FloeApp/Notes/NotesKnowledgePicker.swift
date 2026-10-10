// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

import FloeCore
struct NotesKnowledgePicker: View {
    let conversationID: UUID
    let onSelect: @MainActor (NoteDocument, NotesStore) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [NoteDocument] = []
    @State private var store: NotesStore?
    @State private var grants: [UUID: Bool] = [:]
    @State private var query = ""
    @State private var allowEditing = false
    @State private var loading = true
    @State private var selecting = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("notes.notes_knowledge_picker.allow_the_assistant_to_edit_selected", isOn: $allowEditing)
                    Text("notes.notes_knowledge_picker.read_only_by_default_modifications_still")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !grants.isEmpty {
                    Section("notes.notes_knowledge_picker.sources_available_to_this_conversation") {
                        ForEach(documents.filter { grants[$0.id] != nil }) { document in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(document.title)
                                    Text(grants[document.id] == true ? "notes.notes_knowledge_picker.can_read_and_modify" : "workspace.file_inspector_view.read_only").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("notes.notes_knowledge_picker.remove_access", systemImage: "minus.circle") {
                                    guard let store else { return }
                                    selecting = true
                                    Task {
                                        defer { selecting = false }
                                        do {
                                            try await store.revokeAccess(conversationID: conversationID, documentID: document.id)
                                            grants.removeValue(forKey: document.id)
                                        } catch { failure = error.localizedDescription }
                                    }
                                }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(selecting)
                            }
                        }
                        Text("notes.notes_knowledge_picker.after_removal_the_assistant_can_no")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("notes.notes_knowledge_picker.notes_content") {
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
                                Text(document.kind == .office ? "notes.notes_knowledge_picker.office_files" : document.kind == .mindMap ? "notes.notes_office_view.mind_map" : document.kind == .engineering ? (document.engineeringFileName ?? String(localized: "notes.kind.engineering")) : FloeL10n.plural("notes.notes_knowledge_picker.pages", count: document.pages.count))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(selecting)
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .searchable(text: $query, prompt: "notes.notes_knowledge_picker.search_titles_body_text_and_annotations")
            .overlay { if loading { ProgressView("notes.notes_knowledge_picker.reading_note") } }
            .navigationTitle("workspace.workspace_canvas_view.add_note_material")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("workspace.workspace_canvas_view.cancel") { dismiss() }.disabled(selecting) } }
            .task {
                defer { loading = false }
                do {
                    let store = try await NotesRepository.shared.store()
                    documents = try await store.documents()
                    grants = try await store.accessGrants(conversationID: conversationID)
                    self.store = store
                } catch { failure = error.localizedDescription }
            }
        }
    }
}
#endif
