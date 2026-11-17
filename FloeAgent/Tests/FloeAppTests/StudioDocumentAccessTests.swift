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
    @Test func workspaceRootIntentSurvivesRestartAndRejectsDifferentIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-root-intent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let access = try StudioDocumentAccess(root: root), workspace = UUID()
        let intent = StudioWorkspaceVideoRootIntent(workspaceID: workspace, relativePath: "Floe Studio 12345678",
            rootIdentity: "root-id", stagingName: ".floe-studio-" + UUID().uuidString, containerIdentity: "stage-id")
        try await access.reserveWorkspaceVideoRoot(intent)
        let reopened = try StudioDocumentAccess(root: root)
        #expect(try await reopened.workspaceVideoRootIntent(workspaceID: workspace) == intent)
        let forged = StudioWorkspaceVideoRootIntent(workspaceID: workspace, relativePath: intent.relativePath,
            rootIdentity: intent.rootIdentity, stagingName: intent.stagingName, containerIdentity: "different")
        await #expect(throws: (any Error).self) { try await reopened.finishWorkspaceVideoRoot(forged) }
        try await reopened.finishWorkspaceVideoRoot(intent)
        #expect(try await reopened.workspaceVideoRootIntent(workspaceID: workspace) == nil)
        #expect(try await reopened.workspaceVideoRoot(workspaceID: workspace)?.containerIdentity == intent.containerIdentity)
    }
    @Test func workspaceVideoBindingRequiresReservedCreationAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-video-authority-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let access = try StudioDocumentAccess(root: root)
        let conversation = UUID(), workspace = UUID()
        let project = try await access.reserveCreation(operationKey: "run/call", digest: "approved")
        let binding = StudioWorkspaceVideoBinding(projectID: project, conversationID: conversation, workspaceID: workspace,
            relativePath: "Studio/Video.floeproject", rootIdentity: "root-identity", projectIdentity: "project-identity", mediaIdentity: "media-identity", storeIdentity: "store-identity")
        await #expect(throws: (any Error).self) {
            try await access.finishWorkspaceVideoCreation(binding, operationKey: "unreserved", digest: "approved")
        }
        #expect(try await !access.canAccess(conversationID: conversation, projectID: project, editing: true))
        let rootIntent = StudioWorkspaceVideoRootIntent(workspaceID: workspace, relativePath: "Studio", rootIdentity: binding.rootIdentity,
            stagingName: ".floe-studio-" + UUID().uuidString, containerIdentity: "container-identity")
        try await access.reserveWorkspaceVideoRoot(rootIntent)
        try await access.finishWorkspaceVideoRoot(rootIntent)
        try await access.reserveWorkspaceVideoProject(.init(projectID: project, conversationID: conversation,
            workspaceID: workspace, operationKey: "run/call", digest: "approved", rootIdentity: binding.rootIdentity,
            containerIdentity: "container-identity", stagingName: ".floe-project-" + UUID().uuidString,
            finalName: "Video.floeproject", projectIdentity: binding.projectIdentity,
            mediaIdentity: binding.mediaIdentity, storeIdentity: binding.storeIdentity))
        try await access.finishWorkspaceVideoCreation(binding, operationKey: "run/call", digest: "approved")
        let reopened = try StudioDocumentAccess(root: root)
        #expect(try await reopened.workspaceVideoBinding(conversationID: conversation, workspaceID: workspace, projectID: project) == binding)
        #expect(try await reopened.canAccess(conversationID: conversation, projectID: project, editing: true))
        #expect(try await reopened.workspaceVideoBinding(conversationID: UUID(), workspaceID: workspace, projectID: project) == nil)
        #expect(try await reopened.workspaceVideoBinding(conversationID: conversation, workspaceID: UUID(), projectID: project) == nil)
        let forged = StudioWorkspaceVideoBinding(projectID: project, conversationID: conversation, workspaceID: workspace,
            relativePath: "Studio/other.floeproject", rootIdentity: "root-identity", projectIdentity: "project-identity", mediaIdentity: "media-identity", storeIdentity: "store-identity")
        await #expect(throws: (any Error).self) {
            try await reopened.finishWorkspaceVideoCreation(forged, operationKey: "run/call", digest: "approved")
        }
    }
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
