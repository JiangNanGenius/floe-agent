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

@Suite("FloeApp.FileAssistantLifecycle")
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

        @MainActor
        init() throws {
            environment = AppEnvironment.preview()
            center = ConversationCenter(environment: environment)
        }
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
        #expect(fixture.center.conversations.contains { $0.id == bound.id })
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
    }
}
#endif
