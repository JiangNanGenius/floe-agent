// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(AppIntents)
import AppIntents
import Foundation
import Testing
import FloeCore
import FloeNotes
@testable import FloeApp

@Suite("System Notes actions", .serialized)
@MainActor
struct FloeNoteIntentsIntegrationTests {
    @Test func textCreationCommitsToTheNotesAuthorityAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("siri-note-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let saved = try await FloeNoteIntentService.create(
            text: "今天的会议：保留原始笔记。\nNext: review the plan.",
            title: "System note", notebook: nil, store: store)
        #expect(saved.revision == 1)
        let reopened = try NotesStore(root: root)
        let read = try await reopened.document(saved.id)
        #expect(read.title == "System note")
        #expect(read.searchableText.contains("保留原始笔记"))
        #expect(read.searchableText.contains("review the plan"))
        let again = try await FloeNoteIntentService.create(
            text: "同样的文字仍然是一份独立手记", title: "System note", notebook: nil, store: store)
        #expect(saved.id != again.id)
    }

    @Test func datePredicateIsAppliedBeforeTheSearchLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("note-date-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let first = try await store.create(NoteDocument(title: "共同检索 first"))
        let second = try await store.create(NoteDocument(title: "共同检索 second"))
        #expect(first.updatedAt < second.updatedAt)
        let found = try await store.search("共同检索", limit: 1, modifiedBefore: first.updatedAt)
        #expect(found.map(\.id) == [first.id])
        let latest = try await store.search("共同检索", limit: 1, modifiedAfter: second.updatedAt)
        #expect(latest.map(\.id) == [second.id])
        await #expect(throws: NoteError.self) {
            try await store.search("共同检索", modifiedAfter: second.updatedAt, modifiedBefore: first.updatedAt)
        }
    }

    @Test func explicitEntityRestorationDoesNotReadOrEnumeratePrivateTitles() async throws {
        let id = UUID()
        let entities = try await FloeNoteEntityQuery().entities(for: [id.uuidString, "not-an-id"])
        #expect(entities.count == 1)
        #expect(entities[0].id == id.uuidString)
        #expect(entities[0].modifiedAt == nil)
        #expect(try await FloeNoteEntityQuery().suggestedEntities().isEmpty)
        #expect(CreateFloeNoteIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
        #expect(FindFloeNotesIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
        #expect(OpenFloeNoteIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
        #expect(FindFloeRunsIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
    }

    @Test func systemOpeningUsesOneSceneAndDoesNotInventAnImportReceipt() throws {
        let center = DocumentIntakeCenter(root: nil)
        center.presentSystemNote(documentID: UUID(), title: "Existing note", sceneID: "scene-system")
        let request = try #require(center.noteOpenRequest)
        #expect(request.source == .systemAction)
        #expect(request.sceneID == "scene-system")
        #expect(center.claimNoteOpen(request))
        #expect(!center.claimNoteOpen(request))
        center.completeNoteOpen(request, opened: false)
        #expect(center.notice?.eventID == nil)
        #expect(center.lastReceipt == nil)
        #expect(try FloeAppEntryRoute.parse(FloeAppEntryRoute.note(request.documentID).url) == .note(request.documentID))
    }
}
#endif
