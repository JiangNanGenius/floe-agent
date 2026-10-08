// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

struct NotesAnswerSaveSheet: View {
    @State private var text: String
    @State private var insert: Bool
    let canInsert: Bool
    let save: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    init(text: String, canInsert: Bool, save: @escaping (String, Bool) -> Void) {
        _text = State(initialValue: text); _insert = State(initialValue: canInsert)
        self.canInsert = canInsert; self.save = save
    }
    var body: some View {
        NavigationStack {
            Form {
                if canInsert {
                    Picker("notes.notes_answer_save_sheet.save_location", selection: $insert) {
                        Text("notes.notes_answer_save_sheet.current_page_or_mind_map").tag(true)
                        Text("notes.notes_answer_save_sheet.new_organized_note").tag(false)
                    }
                }
                Section("notes.notes_answer_save_sheet.response") { TextEditor(text: $text).frame(minHeight: 280) }
                Section { Text("notes.notes_answer_save_sheet.keeps_ai_source_and_original_material").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("notes.notes_answer_save_sheet.save_response")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("workspace.workspace_canvas_view.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("workspace.workspace_canvas_view.save") { save(text, insert) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 65_536)
                }
            }
        }.presentationDetents([.large])
    }
}
#endif
