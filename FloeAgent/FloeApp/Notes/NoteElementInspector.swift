// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

import FloeCore
struct NoteElementInspector: View {
    @State private var draft: NoteElement
    @State private var saving = false
    @State private var error: String?
    let page: NotePage
    let save: (NoteElement) async throws -> Void
    let delete: () async throws -> Void
    let openSource: ((NoteSourceReference) -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(element: NoteElement, page: NotePage, save: @escaping (NoteElement) async throws -> Void, delete: @escaping () async throws -> Void, openSource: ((NoteSourceReference) -> Void)? = nil) {
        _draft = State(initialValue: element); self.page = page; self.save = save; self.delete = delete
        self.openSource = openSource
    }

    var body: some View {
        NavigationStack {
            Form {
                if let source = draft.source {
                    Section("skills.review.source") {
                        Label(draft.isAIGenerated ? "notes.note_element_inspector.ai_generated_summary" : "notes.note_element_inspector.cited_content", systemImage: "quote.opening")
                        Text(FloeL10n.l("notes.note_element_inspector.cited_version", source.revision)).font(.caption).foregroundStyle(.secondary)
                        if source.space == .notes, let openSource {
                            Button("notes.note_element_inspector.open_the_current_page_of_the") { openSource(source) }
                        }
                    }
                }
                if draft.kind == .text {
                    Section("notes.notes_document_editor.text") {
                        TextEditor(text: $draft.text).frame(minHeight: 160)
                        Stepper(FloeL10n.l("notes.note_element_inspector.font_size", Int(draft.fontSize)), value: $draft.fontSize, in: 8...128, step: 1)
                    }
                }
                if draft.kind != .image {
                    Section("notes.notes_ink_preferences.color") {
                        HStack(spacing: 16) {
                            ForEach(["#202020", "#D32F2F", "#1565C0", "#2E7D32", "#7B1FA2", "#E65100"], id: \.self) { hex in
                                Button { draft.color = hex } label: {
                                    Circle().fill(Color(uiColor: NotePageRenderer.color(hex)))
                                        .overlay { if draft.color == hex { Image(systemName: "checkmark").foregroundStyle(.white) } }
                                        .frame(width: 36, height: 36)
                                }.buttonStyle(.plain).accessibilityLabel(hex)
                            }
                        }
                    }
                }
                Section("notes.note_element_inspector.position_and_size") {
                    dimension(FloeL10n.l("notes.note_element_inspector.horizontal"), value: $draft.frame.x, maximum: page.width)
                    dimension(FloeL10n.l("notes.note_element_inspector.vertical"), value: $draft.frame.y, maximum: page.height)
                    dimension(FloeL10n.l("workspace.workspace_canvas_view.width_2"), value: $draft.frame.width, minimum: min(20, page.width), maximum: page.width)
                    dimension(FloeL10n.l("workspace.workspace_canvas_view.height"), value: $draft.frame.height, minimum: min(20, page.height), maximum: page.height)
                    Button("notes.note_element_inspector.center") {
                        draft.frame.x = max(0, (page.width - draft.frame.width) / 2)
                        draft.frame.y = max(0, (page.height - draft.frame.height) / 2)
                    }
                }
                Section {
                    Button("notes.note_element_inspector.delete_this_content", role: .destructive) { perform { try await delete() } }
                } footer: { Text("notes.note_element_inspector.edits_and_deletions_can_both_be") }
            }
            .navigationTitle("notes.note_element_inspector.page_content")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("workspace.workspace_canvas_view.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("workspace.workspace_canvas_view.done") { perform { try await save(draft) } }
                        .disabled(!draft.frame.isValid || (draft.kind == .text && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .disabled(saving)
            .alert("notes.notes_root_view.notes", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("workspace.office_document_editor_view.ok") { error = nil }
            } message: { Text(error ?? "") }
        }.presentationDetents([.large]).interactiveDismissDisabled(saving)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        saving = true
        Task {
            defer { saving = false }
            do { try await action(); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func dimension(_ title: String, value: Binding<Double>, minimum: Double = 0, maximum: Double) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(0))).foregroundStyle(.secondary) }
            Slider(value: value, in: minimum...maximum)
        }
    }
}
#endif
