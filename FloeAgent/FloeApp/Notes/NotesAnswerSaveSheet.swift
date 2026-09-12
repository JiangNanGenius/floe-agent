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
                    Picker("保存位置", selection: $insert) {
                        Text("当前页面或导图").tag(true)
                        Text("新的整理手记").tag(false)
                    }
                }
                Section("回答内容") { TextEditor(text: $text).frame(minHeight: 280) }
                Section { Text("保留 AI 来源与原资料引用。插入内容可以撤销；新建的整理手记可以移到回收站。").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("保存回答")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(text, insert) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 65_536)
                }
            }
        }.presentationDetents([.large])
    }
}
#endif
