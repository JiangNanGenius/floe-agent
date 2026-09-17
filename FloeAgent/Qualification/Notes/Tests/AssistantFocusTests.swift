import Foundation
import Testing
import FloeNotes

struct AssistantFocusTests {
    @Test func focusIsScopedAndFollowsLivePageAndRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        var value = NoteDocument(title: "Untrusted title must not enter runtime instructions")
        value.pages.append(NotePage())
        let document = try await store.create(value)
        let conversation = UUID(), page = document.pages[1].id
        await #expect(throws: NoteError.self) {
            try await store.setAssistantFocus(conversationID: conversation, documentID: document.id, pageID: page)
        }
        try await store.bindAssistant(conversationID: conversation, documentID: document.id, canEdit: true)
        try await store.setAssistantFocus(conversationID: conversation, documentID: document.id, pageID: page)
        let context = try #require(await store.assistantRuntimeContext(conversationID: conversation))
        #expect(context.contains("currentPageID=\(page.uuidString); pageNumber=2"))
        #expect(!context.contains(document.title))
        let changed = try await store.apply(.init(documentID: document.id, expectedRevision: document.revision,
            title: "Remove focused page", edits: [.deletePage(page)]))
        let refreshed = try #require(await store.assistantRuntimeContext(conversationID: conversation))
        #expect(refreshed.contains("revision=\(changed.revision)"))
        #expect(!refreshed.contains("currentPageID="))
        try await store.revokeAccess(conversationID: conversation, documentID: document.id)
        #expect(try await store.assistantRuntimeContext(conversationID: conversation) == nil)
        try await store.grantAccess(conversationID: conversation, documentID: document.id, canEdit: false)
        #expect(try await store.assistantRuntimeContext(conversationID: conversation)?.contains("currentPageID=") == false)
    }
}
