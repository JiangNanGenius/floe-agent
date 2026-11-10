// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeNotes
@testable import FloeApp

@Suite("Chat answers saved to independent Notes")
@MainActor struct NextRoundChatNoteTests {
    @Test func newNotePreservesFullAnswerAndConversationProvenanceAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-note-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root), sourceID = UUID(), noteID = UUID()
        let text = "# Answer\n\n" + String(repeating: "Full original **text**.\n", count: 100)
        let saved = try await ChatAnswerNoteWriter.save(text: text, title: "Saved answer", conversationID: sourceID,
            destination: nil, newDocumentID: noteID, requestID: UUID().uuidString, store: store)
        #expect(saved.id == noteID && saved.pages.count > 1)
        let reopened = try await NotesStore(root: root).document(noteID)
        #expect(reopened.textSources?.values.contains(text) == true)
        #expect(reopened.pages.flatMap(\.elements).allSatisfy { $0.source?.space == .conversation && $0.source?.documentID == sourceID })
        #expect(reopened.pages.flatMap(\.elements).allSatisfy { $0.isAIGenerated })
    }

    @Test func appendPreservesExistingPageAndRejectsStaleDestinationWithoutPartialEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-note-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let original = try await store.create(NoteDocument(title: "Existing"))
        let saved = try await ChatAnswerNoteWriter.save(text: "Additional answer", title: "Ignored", conversationID: UUID(),
            destination: original, newDocumentID: UUID(), requestID: UUID().uuidString, store: store)
        #expect(saved.pages.first == original.pages.first)
        #expect(saved.pages.count > original.pages.count)
        do {
            _ = try await ChatAnswerNoteWriter.save(text: "A stale answer", title: "Ignored", conversationID: UUID(),
                destination: original, newDocumentID: UUID(), requestID: UUID().uuidString, store: store)
            Issue.record("Stale destination was accepted")
        } catch NoteError.conflict { }
        #expect(try await store.document(original.id) == saved)
        #expect(try await store.documents().count == 1)
    }

    @Test func duplicateConfirmedRequestDoesNotAppendTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-note-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root), conversationID = UUID(), requestID = UUID().uuidString
        let original = try await store.create(NoteDocument(title: "Existing"))
        let first = try await ChatAnswerNoteWriter.save(text: "One answer", title: "Ignored", conversationID: conversationID,
            destination: original, newDocumentID: UUID(), requestID: requestID, store: store)
        let replay = try await ChatAnswerNoteWriter.save(text: "One answer", title: "Ignored", conversationID: conversationID,
            destination: original, newDocumentID: UUID(), requestID: requestID, store: store)
        #expect(replay == first)
        #expect(try await store.document(original.id) == first)
    }
}
#endif
