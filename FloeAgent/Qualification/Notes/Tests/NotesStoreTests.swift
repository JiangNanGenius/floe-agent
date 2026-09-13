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

    @Test func linkedMapsKeepIndependentHistoryAndArchiveAttachments() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root.appendingPathComponent("source"))
        var original = NoteDocument(title: "PDF lesson")
        original.pages.append(NotePage())
        let parent = try await store.create(original)
        let pageID = parent.pages[0].id
        var map = try await store.createLinkedMindMap(parentID: parent.id, expectedRevision: parent.revision, title: "Revision map", pageID: pageID)
        let file = root.appendingPathComponent("chart.png")
        try Data("attachment bytes".utf8).write(to: file)
        let resource = try await store.importResource(from: file, mediaType: "image/png")
        var node = map.nodes[0]
        node.attachments = [MindMapAttachment(resourceID: resource, fileName: "chart.png", mediaType: "image/png", kind: .image, caption: "Economic chart", source: .init(documentID: parent.id, revision: 2, pageID: pageID))]
        node.imageResourceID = resource
        map = try await store.apply(.init(documentID: map.id, expectedRevision: map.revision, title: "Attach chart", edits: [.upsertNode(node)]))
        let withoutPage = try await store.apply(.init(documentID: parent.id, expectedRevision: 2, title: "Delete page", edits: [.deletePage(pageID)]))
        #expect(withoutPage.linkedMindMaps?.first?.pageID == nil)
        #expect(try await store.document(map.id) == map)
        let restored = try await store.undo(parent.id, expectedRevision: withoutPage.revision)
        #expect(restored.linkedMindMaps?.first?.pageID == pageID)
        #expect(try await store.document(map.id) == map)
        let archive = root.appendingPathComponent("lesson.floenote")
        try await NotesArchive.export(document: restored, store: store, to: archive)
        let destination = try NotesStore(root: root.appendingPathComponent("destination"))
        let imported = try await NotesArchive.importDocuments(from: archive, notebookID: nil, store: destination)
        #expect(imported.count == 2)
        let created = try await destination.createBundle(imported)
        let newParent = created[0], newMap = created[1]
        #expect(newParent.id != parent.id && newMap.id != map.id)
        #expect(newParent.linkedMindMaps?.first?.documentID == newMap.id)
        #expect(newParent.linkedMindMaps?.first?.pageID == pageID)
        #expect(newMap.nodes[0].attachments?.first?.source?.documentID == newParent.id)
        #expect(newMap.nodes[0].attachments?.first?.source?.revision == newParent.revision)
        let attachment = try #require(newMap.nodes[0].attachments?.first)
        let copied = try await destination.resourceURL(attachment.resourceID)
        #expect(try Data(contentsOf: copied) == Data("attachment bytes".utf8))
        #expect(newMap.resourceIDs == [attachment.resourceID])
        let reopened = try NotesStore(root: root.appendingPathComponent("destination"))
        #expect(try await reopened.document(newParent.id).linkedMindMaps == newParent.linkedMindMaps)
        let unlinked = try await reopened.apply(.init(documentID: newParent.id, expectedRevision: 1, title: "Unlink", edits: [.unlinkMindMap(try #require(newParent.linkedMindMaps?.first?.id))]))
        #expect(unlinked.linkedMindMaps?.isEmpty == true)
        #expect(try await reopened.document(newMap.id) == newMap)
    }

    @Test func linkingIsAtomicAndRequiresSeparateAgentScope() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let parent = try await store.create(NoteDocument(title: "Lesson"))
        await #expect(throws: (any Error).self) {
            try await store.createLinkedMindMap(parentID: parent.id, expectedRevision: 9, title: "Must not exist", pageID: nil)
        }
        await #expect(throws: (any Error).self) {
            try await store.createLinkedMindMap(parentID: parent.id, expectedRevision: 1, title: "Bad page", pageID: UUID())
        }
        #expect(try await store.documents().count == 1)
        let map = try await store.create(NoteDocument(kind: .mindMap, title: "Independent"))
        let conversation = UUID()
        try await store.grantAccess(conversationID: conversation, documentID: parent.id, canEdit: true)
        let batch = NoteEditBatch(documentID: parent.id, expectedRevision: 1, title: "Link", edits: [.linkMindMap(.init(documentID: map.id))])
        await #expect(throws: (any Error).self) { try await store.apply(batch, authorizedConversationID: conversation) }
        #expect(try await store.document(parent.id).linkedMindMaps == nil)
        try await store.grantAccess(conversationID: conversation, documentID: map.id, canEdit: false)
        _ = try await store.apply(batch, authorizedConversationID: conversation)
        let trashed = try await store.setTrashed(map.id, expectedRevision: 1, trashed: true)
        let archive = root.appendingPathComponent("unavailable.floenote")
        let linked = try await store.document(parent.id)
        await #expect(throws: (any Error).self) { try await NotesArchive.export(document: linked, store: store, to: archive) }
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        _ = try await store.setTrashed(map.id, expectedRevision: trashed.revision, trashed: false)
        var invalid = NoteDocument(title: "Bad import")
        invalid.linkedMindMaps = [.init(documentID: UUID())]
        let innocent = NoteDocument(kind: .mindMap, title: "Must rollback")
        await #expect(throws: (any Error).self) { try await store.createBundle([invalid, innocent]) }
        await #expect(throws: (any Error).self) { try await store.document(innocent.id) }
    }

    @Test func attachmentsRejectPathsAndRoundTripWithoutNewFields() throws {
        for name in ["../secret", "/absolute", "..", "a\\b", "a:b", "control\n"] {
            let attachment = MindMapAttachment(resourceID: UUID(), fileName: name, mediaType: "text/plain")
            #expect(throws: (any Error).self) { try attachment.validate() }
        }
        let old = NoteDocument(kind: .mindMap, title: "Legacy")
        let encoded = try JSONEncoder().encode(old)
        let restored = try JSONDecoder().decode(NoteDocument.self, from: encoded)
        #expect(restored.linkedMindMaps == nil && restored.nodes[0].attachments == nil)
        try restored.validate()
    }

    @Test func recentOpeningSurvivesRestartWithoutChangingContentOrUndo() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let first = try await store.create(NoteDocument(title: "A"))
        let second = try await store.create(NoteDocument(title: "B"))
        try await store.markOpened(second.id, at: Date(timeIntervalSince1970: 10))
        try await store.markOpened(first.id, at: Date(timeIntervalSince1970: 20))
        let reopened = try NotesStore(root: root)
        #expect(try await reopened.recentDocuments().map(\.id) == [first.id, second.id])
        #expect(try await reopened.document(first.id) == first)
        #expect(try await reopened.historyState(first.id).canUndo == false)
        _ = try await reopened.setTrashed(first.id, expectedRevision: first.revision, trashed: true)
        #expect(try await reopened.recentDocuments().map(\.id) == [second.id])
        await #expect(throws: (any Error).self) { try await reopened.markOpened(first.id) }
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

    @Test func revokingScopeSurvivesRestartAndPreservesOtherConversationAndDocument() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let document = try await store.create(NoteDocument(title: "Shared material"))
        let first = UUID(), second = UUID()
        try await store.grantAccess(conversationID: first, documentID: document.id, canEdit: false)
        try await store.grantAccess(conversationID: second, documentID: document.id, canEdit: true)
        #expect(try await store.accessGrants(conversationID: first)[document.id] == false)
        try await store.revokeAccess(conversationID: first, documentID: document.id)
        let reopened = try NotesStore(root: root)
        #expect(try await reopened.accessGrants(conversationID: first).isEmpty)
        await #expect(throws: (any Error).self) { try await reopened.authorize(conversationID: first, documentID: document.id, editing: false) }
        try await reopened.authorize(conversationID: second, documentID: document.id, editing: true)
        let batch = NoteEditBatch(documentID: document.id, expectedRevision: document.revision, title: "late edit", edits: [.rename("Late")])
        await #expect(throws: (any Error).self) { try await reopened.apply(batch, authorizedConversationID: first) }
        #expect(try await reopened.document(document.id) == document)
        #expect(try await reopened.apply(batch, authorizedConversationID: second).title == "Late")
    }

    @Test func mindMapImageBudgetRejectsExcessResources() throws {
        var document = NoteDocument(kind: .mindMap, title: "Illustrated")
        let root = document.nodes[0].id
        for index in 0..<64 {
            document.nodes.append(MindMapNode(parentID: root, title: "Image \(index)", order: index, imageResourceID: UUID()))
        }
        try document.validate()
        document.nodes.append(MindMapNode(parentID: root, title: "Too many", order: 64, imageResourceID: UUID()))
        #expect(throws: (any Error).self) { try document.validate() }
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

@Test func permanentDeletionPreservesSharedHistoryAndActiveReaders() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("chart.dat")
    try Data("shared diagram".utf8).write(to: file)
    let storage = root.appendingPathComponent("store")
    func exerciseReaders() async throws -> URL {
    let store = try NotesStore(root: storage)
    let resource = try await store.importResource(from: file, mediaType: "application/octet-stream")
    var draft = NoteDocument(kind: .mindMap, title: "One")
    draft.nodes[0].imageResourceID = resource
    let first = try await store.create(draft)
    draft.id = UUID(); draft.title = "Two"
    let second = try await store.create(draft)
    await #expect(throws: (any Error).self) { try await store.permanentlyDelete(first.id, expectedRevision: first.revision) }
    let firstTrash = try await store.setTrashed(first.id, expectedRevision: first.revision, trashed: true)
    try await store.permanentlyDelete(first.id, expectedRevision: firstTrash.revision)
    #expect(try await store.document(second.id).title == "Two")
    let activeURL = try await store.resourceURL(resource)
    var node = second.nodes[0]; node.imageResourceID = nil
    let edited = try await store.apply(.init(documentID: second.id, expectedRevision: second.revision, title: "Remove image", edits: [.upsertNode(node)]))
    #expect(try await store.collectDeletedResources() == 0)
    // A new store has no active URL leases, but must retain undo references.
    let reopened = try NotesStore(root: storage)
    #expect(try await reopened.collectDeletedResources() == 0)
    let trash = try await store.setTrashed(edited.id, expectedRevision: edited.revision, trashed: true)
    await #expect(throws: (any Error).self) { try await store.permanentlyDelete(trash.id, expectedRevision: edited.revision) }
    try await store.permanentlyDelete(trash.id, expectedRevision: trash.revision)
    #expect(try await store.collectDeletedResources() == 0)
    #expect(try Data(contentsOf: activeURL) == Data("shared diagram".utf8))
    #expect(try await reopened.collectDeletedResources() == 0, "Other store handles must honor active reader leases")
    return activeURL
    }
    let activeURL = try await exerciseReaders()
    // A later store lifetime after all active consumers have closed.
    let finalStore = try NotesStore(root: storage)
    #expect(try await finalStore.collectDeletedResources() == 1)
    #expect(try await finalStore.collectDeletedResources() == 0)
    #expect(!FileManager.default.fileExists(atPath: activeURL.path))
    #expect(try await finalStore.documents(includeTrash: true).isEmpty)
}
