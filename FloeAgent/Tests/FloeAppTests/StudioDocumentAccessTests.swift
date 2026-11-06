// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeMusicCore
import FloeTools
import FloePersistence
@testable import FloeApp

@Suite("Personal work authority and durable edits", .serialized)
@MainActor struct StudioDocumentAccessTests {
    @Test func archivedAssistantRemainsOutsideOrdinaryListAfterAnUpdate() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let now = Date(), assistantID = UUID(), ordinaryID = UUID()
        try await store.saveConversation(.init(id: assistantID, title: "Work assistant", createdAt: now, updatedAt: now))
        try await store.saveConversation(.init(id: ordinaryID, title: "Ordinary task", createdAt: now, updatedAt: now))
        try await store.setArchived(id: assistantID, archived: true)
        // The session publisher rereads this record when its native editor
        // opens. The incremental projection must match the real SQL list.
        let assistant = try #require(try await store.conversation(id: assistantID))
        #expect(!assistant.isVisibleInOrdinaryList)
        #expect(try await store.conversations().map(\.id) == [ordinaryID])
        try await store.saveConversation(.init(id: assistantID, title: "Work assistant updated", createdAt: now, updatedAt: now.addingTimeInterval(1)))
        #expect(try await store.conversation(id: assistantID)?.isVisibleInOrdinaryList == false)
        #expect(try await store.conversations().map(\.id) == [ordinaryID])
    }
    @Test func actualRegisteredRunnerRejectsTemporaryChatBeforeCreatingAWork() async throws {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: "studio.create"))
        #expect(runner.isAvailable())
        #expect(ToolCatalog.descriptor(named: "studio.read")?.isSideEffecting == false)
        let context = ToolContext(runID: UUID(), toolCallID: "temporary-create", cancellation: CancellationToken(), temporaryReadOnly: true)
        do {
            _ = try await runner.execute(argumentsJSON: Data(#"{"kind":"diagram","title":"Must not be created"}"#.utf8), context: context)
            Issue.record("Temporary chat created a persistent personal work.")
        } catch {
            #expect(error.localizedDescription.contains("saved task"))
        }
    }
    @Test func nativeBindingsAreDurableAndNeverGrantAnotherConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-authority-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID(), conversation = UUID(), stranger = UUID()
        let authority = try StudioDocumentAccess(root: root)
        #expect(try await !authority.canAccess(conversationID: conversation, projectID: project, editing: true))
        try await authority.bindAssistant(conversationID: conversation, projectID: project)
        #expect(try await authority.canAccess(conversationID: conversation, projectID: project, editing: true))
        #expect(try await !authority.canAccess(conversationID: stranger, projectID: project, editing: false))
        let reopened = try StudioDocumentAccess(root: root)
        #expect(try await reopened.assistant(projectID: project) == conversation)
        #expect(try await reopened.assistantProject(conversationID: conversation) == project)
        #expect(try await reopened.projectIDs(conversationID: stranger).isEmpty)
        #expect(try await reopened.projectIDs(conversationID: conversation) == [project])
    }

    @Test func retriedCreationHasOneIdentityAndRejectsChangedPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-create-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let access = try StudioDocumentAccess(root: root.appendingPathComponent("Authority"))
        let id = try await access.reserveCreation(operationKey: "run/call", digest: "same-approved-payload")
        let reopened = try StudioDocumentAccess(root: root.appendingPathComponent("Authority"))
        #expect(try await reopened.reserveCreation(operationKey: "run/call", digest: "same-approved-payload") == id)
        do {
            _ = try await reopened.reserveCreation(operationKey: "run/call", digest: "different-payload")
            Issue.record("A changed call reused a document reservation.")
        } catch PersonalContentError.changedDocument {}
        let service = PersonalContentService(root: root.appendingPathComponent("Library"))
        let first = try await service.create(kind: .diagram, title: "Actual diagram", id: id)
        let retried = try await service.create(kind: .diagram, title: "Actual diagram", id: id)
        #expect(retried.id == first.id)
        let records = try await service.library().records()
        #expect(records.count == 1)
        // An editor package is an owned original, never an organizational folder.
        do {
            _ = try await service.library().folderURL(["forged.floeproject"])
            Issue.record("A project package was accepted as a folder.")
        } catch PersonalContentError.invalidName {}
    }

    @Test func decodedMusicEditsCommitThroughTheNativeStoreAndSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-music-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NativeMusicRepository(root: root)
        let original = try MusicDocument(name: "Before")
        _ = try await repository.save(document: original, expectedRevision: nil, fence: nil)
        let store = try await MusicProjectStore.open(projectID: original.id, repository: repository)
        let handle = await store.beginSession(ownerToken: "studio-tool-test")
        let wire = Data(#"[{"setName":{"_0":"After"}},{"setTempo":{"atTick":{"value":0},"bpm":135,"beatsPerBar":4,"beatUnit":4}}]"#.utf8)
        let operations = try JSONDecoder().decode([MusicEditOp].self, from: wire)
        let changed = try await store.commit(.init(baseRevision: original.revision, author: "assistant", ops: operations), as: handle)
        #expect(changed.name == "After")
        #expect(changed.revision > original.revision)
        let reopened = try await NativeMusicRepository(root: root).load(projectID: original.id)
        #expect(reopened == changed)
        do {
            _ = try await store.commit(.init(baseRevision: original.revision, ops: [.setName("Stale")]), as: handle)
            Issue.record("A stale assistant edit replaced the saved work.")
        } catch MusicError.staleRevision {}
        #expect(try await repository.load(projectID: original.id).name == "After")
    }
}
#endif
