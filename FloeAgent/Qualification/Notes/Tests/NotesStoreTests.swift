// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeNotes

struct NotesStoreTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func durableHistoryAndCAS() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let document = try await store.create(NoteDocument(title: "经济学"))
        let ink = root.appendingPathComponent("ink.drawing")
        try Data("opaque pencil data".utf8).write(to: ink)
        let resource = try await store.importResource(from: ink, mediaType: "application/test")
        let duplicate = try await store.importResource(from: ink, mediaType: "application/test")
        #expect(resource == duplicate)
        let changed = try await store.apply(.init(documentID: document.id, expectedRevision: 1, title: "书写", edits: [.drawing(pageID: document.pages[0].id, resourceID: resource)]))
        #expect(changed.revision == 2)
        let reopened = try NotesStore(root: root)
        let restored = try await reopened.document(document.id)
        #expect(restored.pages[0].drawingResourceID == resource)
        let undone = try await reopened.undo(document.id, expectedRevision: 2)
        #expect(undone.revision == 3)
        #expect(undone.pages[0].drawingResourceID == nil)
        let redone = try await reopened.undo(document.id, expectedRevision: 3, redo: true)
        #expect(redone.pages[0].drawingResourceID == resource)
        let resourceURL = try await reopened.resourceURL(resource)
        #expect(try Data(contentsOf: resourceURL) == Data("opaque pencil data".utf8))
    }

    @Test func rejectedBatchIsAtomicAndStaleEditsFail() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let value = try await store.create(NoteDocument(title: "Original"))
        await #expect(throws: (any Error).self) {
            try await store.apply(.init(documentID: value.id, expectedRevision: 1, title: "invalid", edits: [.rename("Partial"), .deletePage(value.pages[0].id)]))
        }
        #expect(try await store.document(value.id).title == "Original")
        let result = try await store.apply(.init(documentID: value.id, expectedRevision: 1, title: "rename", edits: [.rename("Current")]))
        await #expect(throws: (any Error).self) {
            try await store.apply(.init(documentID: value.id, expectedRevision: 1, title: "stale", edits: [.rename("Stale")]))
        }
        #expect(try await store.document(value.id) == result)
    }

    @Test func receiptsSurviveRestartWithoutDuplicateEdits() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let value = try await store.create(NoteDocument(title: "Original"))
        let batch = NoteEditBatch(documentID: value.id, expectedRevision: 1, title: "new page", edits: [.insertPage(NotePage(), at: 1)], requestID: "run:call")
        let first = try await store.apply(batch)
        let reopened = try NotesStore(root: root)
        #expect(try await reopened.apply(batch) == first)
        #expect(try await reopened.editReceipt(requestID: "run:call", documentID: value.id) == first)
        #expect(try await reopened.document(value.id).pages.count == 2)
    }

    @Test func assistantScopesAndTrashAreIndependentFromChat() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let first = try await store.create(NoteDocument(title: "A"))
        let second = try await store.create(NoteDocument(title: "B"))
        let conversation = UUID()
        try await store.bindAssistant(conversationID: conversation, documentID: first.id, canEdit: false)
        try await store.authorize(conversationID: conversation, documentID: first.id, editing: false)
        await #expect(throws: (any Error).self) { try await store.authorize(conversationID: conversation, documentID: first.id, editing: true) }
        await #expect(throws: (any Error).self) { try await store.authorize(conversationID: conversation, documentID: second.id, editing: false) }
        let trashed = try await store.setTrashed(first.id, expectedRevision: 1, trashed: true)
        #expect(try await store.scopedDocuments(conversationID: conversation).isEmpty)
        await #expect(throws: (any Error).self) { try await store.authorize(conversationID: conversation, documentID: first.id, editing: false) }
        _ = try await store.setTrashed(first.id, expectedRevision: trashed.revision, trashed: false)
        #expect(try await store.scopedDocuments(conversationID: conversation).count == 1)
    }

    @Test func mindMapRejectsCyclesWithoutChangingPersistedTree() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let value = try await store.create(NoteDocument(kind: .mindMap, title: "Exam"))
        let child = MindMapNode(parentID: value.nodes[0].id, title: "Topic")
        let valid = try await store.apply(.init(documentID: value.id, expectedRevision: 1, title: "child", edits: [.upsertNode(child)]))
        var cyclic = child; cyclic.parentID = child.id
        await #expect(throws: (any Error).self) {
            try await store.apply(.init(documentID: value.id, expectedRevision: 2, title: "cycle", edits: [.upsertNode(cyclic)]))
        }
        #expect(try await store.document(value.id) == valid)
    }

    @Test func literalChineseSearchDoesNotTreatWildcardsAsAuthority() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let value = try await store.create(NoteDocument(title: "中文_公式100%"))
        _ = try await store.create(NoteDocument(title: "Other"))
        #expect(try await store.search("中文").map(\.id) == [value.id])
        #expect(try await store.search("%").map(\.id) == [value.id])
        #expect(try await store.search("' OR 1=1 --").isEmpty)
    }

    @Test func editableArchiveRestoresResourcesAsIndependentDocumentAndRejectsTampering() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root.appendingPathComponent("source"))
        let resourceFile = root.appendingPathComponent("ink.drawing")
        let bytes = Data("unique opaque PencilKit fixture 987654321".utf8)
        try bytes.write(to: resourceFile)
        let resource = try await store.importResource(from: resourceFile, mediaType: "application/test")
        var value = NoteDocument(title: "课件 English")
        value.pages[0].drawingResourceID = resource
        value.pages[0].elements = [.init(text: "批注", source: .init(documentID: value.id, revision: 1, pageID: value.pages[0].id), isAIGenerated: true)]
        value = try await store.create(value)
        let archive = root.appendingPathComponent("document.floenote")
        try await NotesArchive.export(document: value, store: store, to: archive)
        let destination = try NotesStore(root: root.appendingPathComponent("destination"))
        let draft = try await NotesArchive.importDocument(from: archive, notebookID: nil, store: destination)
        let imported = try await destination.create(draft)
        #expect(imported.id != value.id)
        #expect(imported.pages[0].elements[0].source?.documentID == imported.id)
        #expect(imported.pages[0].elements[0].isAIGenerated)
        let restoredResource = try #require(imported.pages[0].drawingResourceID)
        let restoredURL = try await destination.resourceURL(restoredResource)
        #expect(try Data(contentsOf: restoredURL) == bytes)
        #expect(try await destination.assistantConversation(documentID: imported.id) == nil)
        var damaged = try Data(contentsOf: archive)
        let range = try #require(damaged.range(of: bytes))
        damaged[range.lowerBound] ^= 1
        let bad = root.appendingPathComponent("damaged.floenote")
        try damaged.write(to: bad)
        await #expect(throws: (any Error).self) {
            try await NotesArchive.importDocument(from: bad, notebookID: nil, store: destination)
        }
        #expect(try await destination.documents().count == 1)
        #expect(try await store.document(value.id) == value)
    }

    @Test func deletingMapBranchKeepsSurvivingSummaryAndUndoRestoresFullMap() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        var value = NoteDocument(kind: .mindMap, title: "课程")
        let center = value.nodes[0].id
        let nodes = (0..<3).map { MindMapNode(parentID: center, title: "Topic \($0)", order: $0) }
        value.nodes += nodes
        value.nodes[1].style = ["fontWeight": "bold", "background": "#123456"]
        value.nodes[1].tags = ["重点"]
        value.summaries = [.init(label: "复习", parent: center, start: 0, end: 2)]
        value = try await store.create(value)
        let deleted = try await store.apply(.init(documentID: value.id, expectedRevision: value.revision, title: "删除主题", edits: [.deleteBranch(nodes[1].id)]))
        #expect(deleted.summaries?.first?.end == 1)
        #expect(deleted.summaries?.first?.label == "复习")
        let restored = try await store.undo(value.id, expectedRevision: deleted.revision)
        #expect(restored.nodes == value.nodes)
        #expect(restored.summaries == value.summaries)
        #expect(try await NotesStore(root: root).document(value.id).nodes == value.nodes)
    }
}
