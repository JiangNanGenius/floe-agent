// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes
import FloeCore

struct SaveChatAnswerToNotesSheet: View {
    let conversationID: UUID
    @State private var text: String
    @State private var title = IDELanguageRunText.t("聊天回答", "Chat answer")
    @State private var documents: [NoteDocument] = []
    @State private var destinationID: UUID?
    @State private var store: NotesStore?
    @State private var saving = false
    @State private var error: String?
    @State private var saved: NoteDocument?
    @State private var newDocumentID = UUID()
    @State private var requestID = UUID().uuidString
    @State private var editor = NotesSession()
    @Environment(\.dismiss) private var dismiss

    init(text: String, conversationID: UUID) { _text = State(initialValue: text); self.conversationID = conversationID }

    var body: some View {
        NavigationStack {
            Group {
                if let saved {
                    VStack(spacing: 18) {
                        Label(IDELanguageRunText.t("已保存到手记", "Saved to Notes"), systemImage: "checkmark.circle.fill").font(.title2)
                        Text(saved.title).font(.headline)
                        Button(IDELanguageRunText.t("打开手记", "Open note")) {
                            Task { await editor.open(using: store); _ = await editor.select(saved) }
                        }.buttonStyle(.borderedProminent).frame(minHeight: 44)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("chat.notes.saved")
                } else {
                    Form {
                        Section {
                            Picker(IDELanguageRunText.t("保存位置", "Save to"), selection: $destinationID) {
                                Text(IDELanguageRunText.t("新手记", "New note")).tag(Optional<UUID>.none)
                                ForEach(documents) { document in Text(document.title).tag(Optional(document.id)) }
                            }.accessibilityIdentifier("chat.notes.destination")
                            if destinationID == nil {
                                TextField(IDELanguageRunText.t("名称", "Title"), text: $title).accessibilityIdentifier("chat.notes.title")
                            }
                        } footer: {
                            Text(IDELanguageRunText.t("可另存为新手记，或追加到笔记、思维导图。", "Save a new note, or append to a notebook or mind map."))
                        }
                        Section(IDELanguageRunText.t("回答", "Answer")) { TextEditor(text: $text).frame(minHeight: 260) }
                        if let error {
                            Section {
                                Text(error).foregroundStyle(.red)
                                Button(IDELanguageRunText.t("重新载入手记列表", "Reload notes")) { Task { await load() } }
                            }
                        }
                    }.disabled(saving)
                }
            }
            .navigationTitle(IDELanguageRunText.t("存到手记", "Save to Notes"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(saved == nil ? IDELanguageRunText.t("取消", "Cancel") : IDELanguageRunText.t("完成", "Done")) { dismiss() }.disabled(saving) }
                if saved == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(IDELanguageRunText.t("保存", "Save")) { save() }
                            .disabled(saving || store == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 65_536)
                            .accessibilityIdentifier("chat.notes.save")
                    }
                }
            }
            .overlay { if saving { ProgressView() } }
        }
        .interactiveDismissDisabled(saving)
        .task { await load() }
        .fullScreenCover(isPresented: Binding(get: { editor.document != nil }, set: { if !$0 { Task { _ = await editor.select(nil) } } })) {
            if let document = editor.document {
                NavigationStack {
                    NotesDocumentEditor(session: editor, document: document).id(document.id)
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
    }

    private func load() async {
        do {
            let value = try await NotesRepository.shared.store()
            let candidates = try await value.documents().filter { $0.kind == .notebook || $0.kind == .mindMap }
            store = value; documents = candidates; error = nil
            if let destinationID, !candidates.contains(where: { $0.id == destinationID }) { self.destinationID = nil }
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let store, !saving else { return }
        let destination = destinationID.flatMap { id in documents.first { $0.id == id } }
        // Never silently turn a vanished destination into a newly created note.
        guard destinationID == nil || destination != nil else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                saved = try await ChatAnswerNoteWriter.save(text: text, title: title, conversationID: conversationID,
                    destination: destination, newDocumentID: newDocumentID, requestID: requestID, store: store)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
