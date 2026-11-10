// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeNotes

@MainActor
enum ChatAnswerNoteWriter {
    static func save(text: String, title: String, conversationID: UUID, destination: NoteDocument?,
                     newDocumentID: UUID, requestID: String, store: NotesStore) async throws -> NoteDocument {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65_536 else {
            throw NoteError.invalidOperation(IDELanguageRunText.t("回答为空或过长，请调整后保存。", "The answer is empty or too long. Adjust it before saving."))
        }
        let source = NoteSourceReference(space: .conversation, documentID: conversationID, revision: 0)
        if let destination {
            guard destination.deletedAt == nil else { throw NoteError.notFound }
            let edits: [NoteEdit]
            switch destination.kind {
            case .notebook:
                let format = NotesTextLayout.formattedPages(text: text, source: source)
                edits = [.textSource(id: format.sourceID, text: text)]
                    + format.pages.enumerated().map { .insertPage($0.element, at: destination.pages.count + $0.offset) }
            case .mindMap:
                guard let root = destination.nodes.first(where: { $0.parentID == nil }) else { throw NoteError.conflict }
                var node = MindMapNode(parentID: root.id, title: IDELanguageRunText.t("聊天回答", "Chat answer"), note: text,
                                       order: destination.nodes.filter { $0.parentID == root.id }.count, source: source)
                node.isAIGenerated = true
                edits = [.upsertNode(node)]
            case .office, .engineering:
                throw NoteError.invalidOperation(IDELanguageRunText.t("请选择笔记或思维导图，或另存为新手记。", "Choose a notebook or mind map, or save as a new note."))
            }
            return try await store.apply(.init(documentID: destination.id, expectedRevision: destination.revision,
                                                title: IDELanguageRunText.t("保存聊天回答", "Save chat answer"), edits: edits, requestID: requestID))
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 4096 else { throw NoteError.invalidOperation(IDELanguageRunText.t("请输入手记名称。", "Enter a note title.")) }
        var document = NoteDocument(id: newDocumentID, title: name)
        let format = NotesTextLayout.formattedPages(text: text, source: source)
        document.schemaVersion = 2
        document.pages = format.pages
        document.textSources = [format.sourceID.uuidString: text]
        return try await store.create(document)
    }
}
#endif
