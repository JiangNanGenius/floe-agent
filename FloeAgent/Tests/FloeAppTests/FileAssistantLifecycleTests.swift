// FloeAppTests — Document-bound file assistant lifecycle: real binding
// queries, task-center projection grouping, and the archive migration that
// restores persistence without unarchiving unrelated chats. All fixtures
// are synthetic; no real StudioAuthority store or user data is touched.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.FileAssistantLifecycle", .serialized)
@MainActor
struct FileAssistantLifecycleTests {

    // MARK: - StudioDocumentAccess binding truth

    @Test("Bindings round-trip: bulk query, rebind uniqueness, removal")
    func documentAccessBindingsRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-file-assistant-tests-\(UUID().uuidString)")
        let access = try StudioDocumentAccess(root: root)
        let projectA = UUID(), projectB = UUID()
        let assistantA = UUID(), assistantANew = UUID(), assistantB = UUID()

        try await access.bindAssistant(conversationID: assistantA, projectID: projectA)
        try await access.bindAssistant(conversationID: assistantB, projectID: projectB)
        // One row per project: rebinding replaces the conversation, never duplicates.
        try await access.bindAssistant(conversationID: assistantANew, projectID: projectA)

        let bindings = try await access.assistantBindings()
        #expect(bindings.count == 2)
        #expect(bindings.contains(StudioAssistantBinding(projectID: projectA, conversationID: assistantANew)))
        #expect(bindings.contains(StudioAssistantBinding(projectID: projectB, conversationID: assistantB)))
        #expect(try await access.assistant(projectID: projectA) == assistantANew)
        #expect(try await access.assistantProject(conversationID: assistantB) == projectB)
        #expect(try await access.canAccess(conversationID: assistantANew, projectID: projectA, editing: true))

        try await access.removeAssistant(projectID: projectA)
        let remaining = try await access.assistantBindings()
        #expect(remaining.count == 1)
        #expect(remaining.contains(StudioAssistantBinding(projectID: projectB, conversationID: assistantB)))
        #expect(try await access.assistant(projectID: projectA) == nil)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Task-center projection

    private func record(_ id: UUID, title: String, updated: Double) -> ConversationRecord {
        ConversationRecord(
            id: id, title: title,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: updated))
    }

    @Test("Projection separates bound assistants without duplicating identity")
    func projectionSeparatesBoundAssistants() {
        let ordinaryRunning = record(UUID(), title: "chat", updated: 9)
        let ordinaryDone = record(UUID(), title: "done chat", updated: 8)
        let boundRunning = record(UUID(), title: "作品助手 · running", updated: 7)
        let boundFailed = record(UUID(), title: "作品助手 · failed", updated: 6)
        let boundDone = record(UUID(), title: "作品助手 · done", updated: 5)
        let boundIdle = record(UUID(), title: "作品助手 · idle", updated: 4)
        let bound = Set([boundRunning.id, boundFailed.id, boundDone.id, boundIdle.id])
        let states: [UUID: String] = [
            ordinaryRunning.id: "streamingModel",
            ordinaryDone.id: "completed",
            boundRunning.id: "executingTool",
            boundFailed.id: "failed",
            boundDone.id: "completed",
        ]
        // The REAL entry HomeLaunchpadViewModel.load() consumes.
        let sections = FileAssistantTaskProjection.sections(
            records: [ordinaryRunning, ordinaryDone, boundRunning, boundFailed, boundDone, boundIdle, boundRunning, boundIdle],
            boundConversationIDs: bound,
            latestRunState: { states[$0] }
        )
        #expect(sections.ordinary.map(\.id) == [ordinaryRunning.id, ordinaryDone.id])
        #expect(sections.fileArea.map(\.id) == [boundDone.id, boundIdle.id])
        // Merged global buckets: the running file task is globally active…
        #expect(sections.running.map(\.id) == [ordinaryRunning.id, boundRunning.id])
        // …the failed file task stays globally discoverable…
        #expect(sections.failed.map(\.id) == [boundFailed.id])
        // …and only ORDINARY completed rows enter the completed bucket: a
        // finished file task returns to the file area instead of duplicating.
        #expect(sections.completed.map(\.id) == [ordinaryDone.id])
        // Global rows and the file area are mutually exclusive, including
        // when a caller supplies the same conversation more than once.
        let rendered = sections.running + sections.failed + sections.completed + sections.fileArea.map(\.conversation)
        #expect(Set(rendered.map(\.id)).count == rendered.count)
        #expect(rendered.count == 6)
        for task in sections.fileArea {
            #expect(task.conversation.purpose == .ordinary)
        }
        #expect(!sections.fileArea.contains { $0.id == boundRunning.id || $0.id == boundFailed.id })
        #expect(sections.fileArea.first(where: { $0.id == boundIdle.id })?.state == nil)
    }

    @Test("Terminal and attention state mirrors the §6.2 mapping")
    func projectionStateMirrorsRunStateLocalizer() {
        let bound = UUID()
        let record = record(bound, title: "作品助手 · x", updated: 1)
        for terminal in ["completed", "failed", "recoveryFailed", "interrupted",
                         "cancelled", "noProgress", "budgetLimited", "truncated", "checkpointed"] {
            let projection = FileAssistantTaskProjection.project(
                records: [record], boundConversationIDs: [bound], latestRunState: { _ in terminal })
            #expect(projection.running.isEmpty, "\(terminal) must not run")
        }
        for active in ["streamingModel", "executingTool", "preparing", "waitingUser"] {
            let projection = FileAssistantTaskProjection.project(
                records: [record], boundConversationIDs: [bound], latestRunState: { _ in active })
            #expect(projection.running.map(\.id) == [bound], "\(active) must run")
            #expect(projection.fileArea.isEmpty)
        }
        // waitingApproval parks like the global running section excludes it.
        let waiting = FileAssistantTaskProjection.project(
            records: [record], boundConversationIDs: [bound], latestRunState: { _ in "waitingApproval" })
        #expect(waiting.running.isEmpty)
        #expect(waiting.failed.isEmpty)
    }

    // MARK: - ConversationCenter migration + recovery candidates

    private final class Fixture: @unchecked Sendable {
        let environment: AppEnvironment
        let center: ConversationCenter
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-editor-identity-\(UUID().uuidString)")
        let library: PersonalContentLibrary
        let access: StudioDocumentAccess

        @MainActor
        init() throws {
            library = PersonalContentLibrary(root: root.appendingPathComponent("Library"))
            access = try StudioDocumentAccess(root: root.appendingPathComponent("Authority"))
            environment = AppEnvironment.preview()
            environment.studioCoordinator = StudioCoordinator(environment: environment, authority: access, library: library)
            center = environment.conversationCenter
            center.canvasAssistantOwnershipOverride = .init()
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() async throws -> Fixture {
        let fixture = try Fixture()
        try await fixture.environment.database.migrate()
        return fixture
    }

    @Test("Reload migrates archived bound assistants only; unrelated chats stay archived")
    func reloadMigratesBoundAssistantsOnly() async throws {
        let fixture = try await makeFixture()
        let store = fixture.environment.conversationStore
        let bound = try await fixture.center.createConversation(title: "作品助手 · 文档A")
        let archivedChat = try await fixture.center.createConversation(title: "ordinary archived")
        let plain = try await fixture.center.createConversation(title: "plain chat")
        try await store.setArchived(id: bound.id, archived: true)
        try await store.setArchived(id: archivedChat.id, archived: true)
        fixture.center.studioAssistantBindingsOverride = [
            StudioAssistantBinding(projectID: UUID(), conversationID: bound.id)
        ]

        await fixture.center.reload()

        let migrated = try #require(await store.conversation(id: bound.id))
        #expect(migrated.archivedAt == nil)
        #expect(fixture.center.fileAssistantConversations.map(\.id) == [bound.id])
        #expect(migrated.editorOwnership?.kind == .file)
        #expect(!fixture.center.conversations.contains { $0.id == bound.id })
        #expect(try await store.conversations(includeArchived: true).allSatisfy { $0.id != bound.id })
        // Ordinary archive semantics are untouched.
        let stillArchived = try #require(await store.conversation(id: archivedChat.id))
        #expect(stillArchived.archivedAt != nil)
        #expect(!fixture.center.fileAssistantConversations.contains { $0.id == archivedChat.id })
        #expect(!fixture.center.conversations.contains { $0.id == archivedChat.id })
        #expect(fixture.center.conversations.contains { $0.id == plain.id })

        // Idempotent: a steady-state reload must not churn updated_at again.
        let firstUpdated = migrated.updatedAt
        try? await Task.sleep(for: .milliseconds(20))
        await fixture.center.reload()
        let after = try #require(await store.conversation(id: bound.id))
        #expect(after.updatedAt == firstUpdated)
        #expect(fixture.center.fileAssistantConversations.map(\.id) == [bound.id])
    }

    @Test("A rebound assistant keeps one identity across the projections")
    func reboundAssistantKeepsSingleIdentity() async throws {
        let fixture = try await makeFixture()
        let project = UUID()
        let first = try await fixture.center.createConversation(title: "作品助手 · v1")
        fixture.center.studioAssistantBindingsOverride = [
            StudioAssistantBinding(projectID: project, conversationID: first.id)
        ]
        await fixture.center.reload()
        // Rebind to a fresh conversation (document rebound): the new binding
        // wins, the old row leaves the file projection.
        let second = try await fixture.center.createConversation(title: "作品助手 · v2")
        fixture.center.studioAssistantBindingsOverride = [
            StudioAssistantBinding(projectID: project, conversationID: second.id)
        ]
        await fixture.center.reload()
        #expect(fixture.center.fileAssistantConversations.map(\.id) == [second.id])
        #expect(fixture.center.isFileAssistantConversation(second.id))
        #expect(!fixture.center.isFileAssistantConversation(first.id))
        #expect(try await fixture.environment.conversationStore.conversation(id: first.id)?.editorOwnership == .file(project))
        #expect(!fixture.center.conversations.contains { $0.id == first.id || $0.id == second.id })
    }

    @Test("Native file creation, streaming refresh and same-file restart retain exact editor ownership")
    func nativeFileAssistantNeverBecomesOrdinaryHistory() async throws {
        let fixture = try await makeFixture()
        defer { fixture.clean() }
        let file = try await fixture.library.create(kind: .document, title: "Shared title") { directory, _ in
            let original = directory.appendingPathComponent("Original")
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            try Data("original remains\n".utf8).write(to: original.appendingPathComponent("Document.md"))
        }
        let center = fixture.center, store = fixture.environment.conversationStore
        let ordinary = try await center.createConversation(title: "Work assistant · Shared title")
        let first = try await fixture.environment.studioCoordinator.assistant(for: file)
        let firstRecord = try #require(await store.conversation(id: first))
        #expect(firstRecord.editorOwnership == .file(file.id))
        #expect(firstRecord.purpose == .ordinary, "Editor isolation cannot change ordinary execution purpose")
        #expect(!firstRecord.isVisibleInOrdinaryList)
        #expect(try await store.conversations().map(\.id) == [ordinary.id])
        #expect(!center.conversations.contains { $0.id == first })
        let message = PersistedMessage(id: UUID(), conversationID: first, role: "user", content: "Retained history", createdAt: Date())
        try await store.appendMessage(message)
        try await store.renameConversation(id: first, title: "Now exactly an ordinary title")
        try await store.setArchived(id: first, archived: true)
        try await store.setArchived(id: first, archived: false)
        await center.authoringConversationBecameVisible(first)
        #expect(!center.conversations.contains { $0.id == first })
        #expect(center.fileAssistantConversations.contains { $0.id == first })
        let oldWorkspace = try await SQLiteWorkspaceStore(database: fixture.environment.database).workspaceID(conversationID: first)

        let next = try await fixture.environment.studioCoordinator.restartAssistant(for: file, expectedConversationID: first)
        await center.authoringConversationBecameVisible(first)
        #expect(center.fileAssistantConversations.map(\.id) == [next], "A late old callback cannot replace the current file session")
        #expect(next != first)
        #expect(try await fixture.access.assistant(projectID: file.id) == next)
        #expect(try await store.conversation(id: first)?.editorOwnership == .file(file.id))
        #expect(try await store.conversation(id: first)?.archivedAt != nil)
        #expect(try await store.conversation(id: next)?.archivedAt == nil)
        #expect(try await store.conversation(id: next)?.editorOwnership == .file(file.id))
        #expect(try await store.messages(conversationID: first).map(\.id) == [message.id])
        #expect(try await SQLiteWorkspaceStore(database: fixture.environment.database).workspaceID(conversationID: first) == oldWorkspace)
        await #expect(throws: (any Error).self) { try await center.restoreConversation(id: first) }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.environment.studioCoordinator.restartAssistant(for: file, expectedConversationID: first)
        }
        #expect(try await fixture.access.assistant(projectID: file.id) == next, "A stale window must not rebind a newer session")
        let reopened = ConversationCenter(environment: fixture.environment)
        reopened.canvasAssistantOwnershipOverride = .init()
        await reopened.reload()
        #expect(reopened.fileAssistantConversations.map(\.id) == [next])
        #expect(reopened.conversations.map(\.id) == [ordinary.id])
        #expect(Set(reopened.foregroundRecoveryConversations().map(\.id)) == [ordinary.id, next])
        #expect(try await store.conversations(includeArchived: true).map(\.id) == [ordinary.id])
        #expect(try Data(contentsOf: (try await fixture.library.resolve(file.id)).url
            .appendingPathComponent("Original/Document.md")) == Data("original remains\n".utf8))
        let trashed = try await PersonalLibraryFileActions.delete(file, environment: fixture.environment, library: fixture.library)
        #expect(try await store.conversation(id: first)?.archivedAt != nil)
        #expect(try await store.conversation(id: next)?.archivedAt == nil)
        #expect(center.fileAssistantConversations.isEmpty)
        try await PersonalLibraryFileActions.restore(trashed, environment: fixture.environment, library: fixture.library)
        #expect(center.fileAssistantConversations.map(\.id) == [next])
        #expect(try await store.conversation(id: first)?.archivedAt != nil)
        let trashAgain = try await PersonalLibraryFileActions.delete(file, environment: fixture.environment, library: fixture.library)
        let plan = try #require(try await PersonalLibraryFileActions.permanentDeletionPlans([trashAgain], environment: fixture.environment, library: fixture.library).first)
        _ = try await PersonalLibraryFileActions.permanentlyDelete(plan, environment: fixture.environment, library: fixture.library)
        #expect(try await store.conversation(id: first) == nil)
        #expect(try await store.conversation(id: next) == nil)
        #expect(try await store.conversation(id: ordinary.id) != nil, "A normal task merely referring to the file must survive")
    }

    @Test("Canvas native IDs restore ownership; names never hide ordinary chats and global task visibility survives")
    func canvasBindingsStayEditorOwnedAcrossRestoreAndTaskProjection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.clean() }
        let center = fixture.center, store = fixture.environment.conversationStore
        let current = try await center.createConversation(title: "renamed canvas session")
        let old = try await center.createConversation(title: "old editor history")
        let ordinary = try await center.createConversation(title: CanvasAgentIdentity.conversationTitlePrefix + "ordinary")
        let document = CanvasDocument(name: "Page")
        var project = CanvasProject(id: UUID(), name: "Native canvas", documents: [document], selectedDocumentID: document.id)
        project.agentConversationIDsByDocument = [document.id: current.id]
        project.agentConversationID = current.id
        project.assistantSessions = [.init(conversationID: old.id, title: "Old session")]
        try await store.claimEditorOwnership(id: old.id, owner: .canvas(project.id, documentID: document.id))
        try await store.setArchived(id: old.id, archived: true)
        let directory = fixture.root.appendingPathComponent("Canvases")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try CanvasProjectCodec.encode(project, encoder: encoder)
            .write(to: directory.appendingPathComponent(project.id.uuidString + ".json"))
        let bindings = try WorkspaceCanvasRegistry.assistantOwnerships(in: directory)
        center.canvasAssistantOwnershipOverride = bindings
        try await store.setArchived(id: current.id, archived: true)
        let firstTouch = try await center.sessionSnapshot(conversationID: current.id)
        #expect(firstTouch.conversation.editorOwnership == .canvas(project.id, documentID: document.id))
        #expect(firstTouch.conversation.archivedAt == nil, "The exact legacy current binding remains usable")
        #expect(!center.conversations.contains { $0.id == current.id }, "Legacy first touch must repair ownership before full reload")
        try await store.setArchived(id: current.id, archived: true)
        await center.reload()
        let owned = try #require(await store.conversation(id: current.id))
        #expect(owned.editorOwnership == .canvas(project.id, documentID: document.id))
        #expect(CanvasAgentIdentity.isCanvasConversation(owned))
        #expect(!CanvasAgentIdentity.isCanvasConversation(ordinary), "A title is not editor ownership")
        #expect(center.canvasAssistantConversations.map(\.id) == [current.id])
        #expect(center.conversations.map(\.id) == [ordinary.id])
        #expect(Set(center.foregroundRecoveryConversations().map(\.id)) == [ordinary.id, current.id])
        try await store.setArchived(id: current.id, archived: false)
        await center.authoringConversationBecameVisible(current.id)
        #expect(!center.conversations.contains { $0.id == current.id || $0.id == old.id })
        await #expect(throws: (any Error).self) { try await center.restoreConversation(id: current.id) }
        #expect(try await store.conversation(id: old.id)?.editorOwnership == .canvas(project.id, documentID: document.id),
            "Legacy project-wide history metadata cannot replace the exact stored document owner")
        let sections = FileAssistantTaskProjection.sections(
            records: center.conversations + center.canvasAssistantConversations,
            boundConversationIDs: [], latestRunState: { $0 == current.id ? "executingTool" : nil })
        #expect(sections.ordinary.map(\.id) == [ordinary.id])
        #expect(sections.running.map(\.id) == [current.id], "Editor work stays globally discoverable in Task Center")
        #expect(sections.fileArea.isEmpty)
        let approvals = FileAssistantTaskProjection.sections(records: [owned], boundConversationIDs: [],
            latestRunState: { _ in "waitingApproval" })
        #expect(approvals.ordinary.isEmpty)
        #expect(approvals.fileArea.map(\.id) == [current.id])
        let originalOwner = owned.editorOwnership
        center.canvasAssistantOwnershipOverride = .init(all: [current.id: .canvas(UUID(), documentID: document.id)], current: [current.id])
        await center.reload()
        #expect(!center.conversations.contains { $0.id == current.id || $0.id == old.id })
        #expect(try await store.conversation(id: current.id)?.editorOwnership == originalOwner,
            "A failed foreign backfill must retain data and remain excluded from normal history")
    }
}
#endif
