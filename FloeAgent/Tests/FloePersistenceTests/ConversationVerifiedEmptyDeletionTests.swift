// FloePersistenceTests — atomic verified-empty conversation removal.
//
// The temporary-chat in-place conversion removes the ordinary conversation
// row. That removal is only safe while the row owns NOTHING durable, so the
// store verifies every conversation-scoped table and performs the DELETE in
// ONE writer transaction. These tests pin the contract: a bare row is
// removed (`true`), any owned resource refuses (`false`) and is left intact,
// and a store failure throws without removing anything.

import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("Conversation verified-empty deletion")
struct ConversationVerifiedEmptyDeletionTests {
    private func makeStore() async throws -> (DatabaseManager, SQLiteConversationStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return (database, SQLiteConversationStore(database: database))
    }

    private func makeConversation(
        _ store: SQLiteConversationStore,
        title: String = ""
    ) async throws -> ConversationRecord {
        let record = ConversationRecord(
            id: UUID(), title: title, createdAt: Date(), updatedAt: Date()
        )
        try await store.saveConversation(record)
        return record
    }

    @Test("A bare conversation is removed by the one transaction and reports true")
    func bareConversationIsRemoved() async throws {
        let (_, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id))
        #expect(try await store.conversation(id: conversation.id) == nil)
    }

    @Test("A missing conversation reports false and removes nothing")
    func missingConversationRefuses() async throws {
        let (_, store) = try await makeStore()
        #expect(try await store.deleteConversationIfVerifiedEmpty(id: UUID()) == false)
    }

    @Test("A message refuses the removal and stays readable")
    func messageRefusesRemoval() async throws {
        let (_, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        let message = PersistedMessage(
            id: UUID(), conversationID: conversation.id, role: "user",
            content: "owned-message", createdAt: Date()
        )
        try await store.appendMessage(message)

        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id) == false)
        #expect(try await store.conversation(id: conversation.id) != nil)
        #expect(try await store.messages(conversationID: conversation.id).count == 1)
    }

    @Test("An attachment refuses the removal and stays readable")
    func attachmentRefusesRemoval() async throws {
        let (_, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        let attachment = AttachmentRef(
            id: UUID(), conversationID: conversation.id, kind: .document,
            displayName: "owned.txt", byteCount: 3, sha256: "abc",
            storage: .none, createdAt: Date()
        )
        try await store.saveAttachment(attachment)

        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id) == false)
        #expect(try await store.attachments(conversationID: conversation.id).map(\.id) == [attachment.id])
    }

    @Test("A run row refuses the removal; only a verified-empty row is ever deleted")
    func runRefusesRemoval() async throws {
        let (database, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO runs (id, conversation_id, state, goal, started_at)
                    VALUES (?, ?, 'preparing', 'pending-run', ?)
                    """,
                arguments: [UUID().uuidString, conversation.id.uuidString, "2026-01-01T00:00:00.000Z"]
            )
        }

        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id) == false)
        #expect(try await store.conversation(id: conversation.id) != nil)
        let runs = try await database.reader { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM runs WHERE conversation_id = ?",
                arguments: [conversation.id.uuidString]
            ) ?? 0
        }
        #expect(runs == 1)
    }

    @Test("A pending user input refuses the removal and stays queued")
    func pendingInputRefusesRemoval() async throws {
        let (database, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        let inputs = SQLiteRunningInputStore(database: database)
        let queued = try await inputs.enqueue(PendingUserInput(
            conversationID: conversation.id, content: "queued-input"
        ))

        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id) == false)
        #expect(try await inputs.input(id: queued.id) != nil)
    }

    @Test("Workspace ownership refuses the removal and never enqueues private-file cleanup")
    func workspaceOwnershipRefusesRemoval() async throws {
        let (database, store) = try await makeStore()
        let workspaces = SQLiteWorkspaceStore(database: database)
        let conversation = try await makeConversation(store)
        let owned = try await workspaces.ensureWorkspace(
            conversationID: conversation.id, title: conversation.title
        )

        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id) == false)
        // The row, the ownership link and the workspace survive; the
        // `queue_private_task_cleanup` trigger must never have fired.
        #expect(try await store.conversation(id: conversation.id) != nil)
        #expect(try await workspaces.workspaceID(conversationID: conversation.id) == owned.id)
        #expect(try await workspaces.workspace(id: owned.id) != nil)
        #expect(try await workspaces.pendingLocalCleanup().isEmpty)
    }

    @Test("A saved task policy refuses the removal")
    func taskPolicyRefusesRemoval() async throws {
        let (database, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        try await SQLiteWorkspaceStore(database: database).saveTaskPolicy(
            TaskPolicy(conversationID: conversation.id, recoveryPolicy: .alwaysRetry)
        )

        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id) == false)
        #expect(try await store.conversation(id: conversation.id) != nil)
    }

    @Test("A conversation-scoped memory refuses the removal")
    func conversationMemoryRefusesRemoval() async throws {
        let (database, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO memory_entries (
                        id, scope, status, content, normalized_content, source_kind,
                        created_at, updated_at, conversation_id
                    ) VALUES (?, 'task', 'active', 'owned-memory', 'owned-memory',
                              'fixture', ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, "2026-01-01T00:00:00.000Z",
                    "2026-01-01T00:00:00.000Z", conversation.id.uuidString,
                ]
            )
        }

        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id) == false)
        #expect(try await store.conversation(id: conversation.id) != nil)
    }

    @Test("A probe failure throws and the conversation is never partially removed")
    func probeFailureFailsClosed() async throws {
        let (database, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        // Real failure path: one of the probed resource tables is missing, so
        // the verification transaction cannot complete. The failure must
        // surface (never a silent `false`), and the row must survive.
        try await database.writer { db in
            try db.execute(sql: "DROP TABLE messages")
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.deleteConversationIfVerifiedEmpty(id: conversation.id)
        }
        #expect(try await store.conversation(id: conversation.id) != nil)
    }

    // MARK: - Target metadata (the row itself must be a blank ordinary chat)

    @Test("A blank Notes assistant refuses the removal; purpose and title survive")
    func notesPurposeRefusesRemoval() async throws {
        let (_, store) = try await makeStore()
        let record = ConversationRecord(
            id: UUID(), title: "文档助手", createdAt: Date(), updatedAt: Date(),
            purpose: .notes
        )
        try await store.saveConversation(record)
        #expect(try await store.deleteConversationIfVerifiedEmpty(id: record.id) == false)
        let row = try #require(try await store.conversation(id: record.id))
        #expect(row.purpose == .notes)
        #expect(row.title == "文档助手")
    }

    @Test("A manually named conversation refuses the removal and keeps its name")
    func manualTitleRefusesRemoval() async throws {
        let (_, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        try await store.renameConversation(id: conversation.id, title: "我的任务")
        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id) == false)
        let row = try #require(try await store.conversation(id: conversation.id))
        #expect(row.title == "我的任务")
        #expect(row.titleOrigin == .manual)
    }

    @Test("An automatically titled conversation refuses the removal")
    func automaticTitleRefusesRemoval() async throws {
        let (_, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        #expect(try await store.setAutomaticTitle(id: conversation.id, title: "自动标题"))
        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id) == false)
        let row = try #require(try await store.conversation(id: conversation.id))
        #expect(row.title == "自动标题")
        #expect(row.titleOrigin == .automatic)
    }

    @Test("An archived conversation refuses the removal and stays archived")
    func archivedRefusesRemoval() async throws {
        let (_, store) = try await makeStore()
        let conversation = try await makeConversation(store)
        try await store.setArchived(id: conversation.id, archived: true)
        #expect(try await store.deleteConversationIfVerifiedEmpty(id: conversation.id) == false)
        let row = try #require(try await store.conversation(id: conversation.id))
        #expect(row.archivedAt != nil)
    }
}
