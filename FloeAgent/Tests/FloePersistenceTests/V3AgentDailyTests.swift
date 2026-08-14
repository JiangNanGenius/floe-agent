// FloePersistenceTests — Schema v3 migration, conversation/run/session
// stores, event-thread ordering, checkpoint upsert, v1/v2 preservation.

import Foundation
import Testing
import GRDB
@testable import FloePersistence
import FloeModels

@Suite("FloePersistence.V3AgentDaily")
struct V3AgentDailyTests {

    private func makeDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    // MARK: Migration

    @Test("Migration reaches schema v3 and registers all migrations")
    func migratesToV3() async throws {
        let database = try await makeDatabase()
        #expect(try await database.userVersion() == 3)
        let applied = try await database.appliedMigrations()
        #expect(applied.contains("v1"))
        #expect(applied.contains("v2"))
        #expect(applied.contains("v3"))
    }

    @Test("v3 creates the new thread/session tables")
    func v3TablesExist() async throws {
        let database = try await makeDatabase()
        let tables = try await database.reader { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
        for expected in [
            "message_parts", "attachments", "run_events",
            "run_usage", "run_errors", "checkpoints", "remote_sessions"
        ] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }
    }

    @Test("v1/v2 core tables survive the v3 migration")
    func priorTablesPreserved() async throws {
        let database = try await makeDatabase()
        let tables = try await database.reader { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        for expected in ["providers", "models", "conversations", "messages", "runs", "audit_entries", "hosts", "config_sync_metadata"] {
            #expect(tables.contains(expected), "lost table \(expected)")
        }
    }

    // MARK: ConversationStore

    private func makeConversationStore(_ db: DatabaseManager) -> SQLiteConversationStore {
        SQLiteConversationStore(database: db)
    }

    @Test("Conversation + message + parts round-trip in order")
    func conversationMessageParts() async throws {
        let db = try await makeDatabase()
        let store = makeConversationStore(db)
        let conversationID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "Test", createdAt: Date(), updatedAt: Date()
        ))

        let messageID = UUID()
        // Create a real attachment so the image part's FK reference is valid.
        let attachmentID = UUID()
        try await store.saveAttachment(AttachmentRef(
            id: attachmentID, conversationID: conversationID, kind: .image,
            displayName: "shot.png", storage: .applicationSupport, relativePath: "x/shot.png"
        ))
        let parts = [
            MessagePart(messageID: messageID, partIndex: 0, kind: .text, text: "hello"),
            MessagePart(messageID: messageID, partIndex: 1, kind: .reasoning, text: "thinking"),
            MessagePart(messageID: messageID, partIndex: 2, kind: .image, attachmentID: attachmentID, metadata: ["w": "512"])
        ]
        try await store.appendMessage(PersistedMessage(
            id: messageID, conversationID: conversationID,
            role: "assistant", content: "hello", createdAt: Date(), parts: parts
        ))

        let loaded = try await store.messages(conversationID: conversationID)
        #expect(loaded.count == 1)
        #expect(loaded[0].parts.count == 3)
        #expect(loaded[0].parts.map(\.partIndex) == [0, 1, 2])
        #expect(loaded[0].parts[2].metadata["w"] == "512")
    }

    @Test("Attachment round-trip preserves security-scoped bookmark bytes")
    func attachmentRoundTrip() async throws {
        let db = try await makeDatabase()
        let store = makeConversationStore(db)
        let conversationID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()
        ))
        let bookmark = Data([0x01, 0x02, 0xFF, 0x00])
        let attachment = AttachmentRef(
            conversationID: conversationID, kind: .document, displayName: "a.docx",
            uti: "org.openxmlformats.wordprocessingml.document",
            byteCount: 1024, sha256: "abc", storage: .securityScopedBookmark,
            urlBookmark: bookmark
        )
        try await store.saveAttachment(attachment)
        let loaded = try await store.attachment(id: attachment.id)
        #expect(loaded?.urlBookmark == bookmark)
        #expect(loaded?.storage == .securityScopedBookmark)
        #expect(loaded?.byteCount == 1024)
    }

    @Test("Deleting a conversation cascades messages, parts and attachments")
    func conversationCascade() async throws {
        let db = try await makeDatabase()
        let store = makeConversationStore(db)
        let conversationID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()
        ))
        let messageID = UUID()
        try await store.appendMessage(PersistedMessage(
            id: messageID, conversationID: conversationID, role: "user",
            content: "hi", createdAt: Date(),
            parts: [MessagePart(messageID: messageID, partIndex: 0, kind: .text, text: "hi")]
        ))
        try await store.saveAttachment(AttachmentRef(conversationID: conversationID, kind: .image))

        try await store.deleteConversation(id: conversationID)
        #expect(try await store.messages(conversationID: conversationID).isEmpty)
        #expect(try await store.attachments(conversationID: conversationID).isEmpty)
        #expect(try await store.parts(messageID: messageID).isEmpty)
    }

    // MARK: RunStore

    private func makeRunStore(_ db: DatabaseManager) -> SQLiteRunStore {
        SQLiteRunStore(database: db)
    }

    private func seedConversationAndRun(
        _ db: DatabaseManager
    ) async throws -> (conversationID: UUID, runID: UUID) {
        let conversationStore = makeConversationStore(db)
        let runStore = makeRunStore(db)
        let conversationID = UUID()
        let runID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()
        ))
        try await runStore.saveRun(RunRecord(
            id: runID, conversationID: conversationID, state: "streamingModel",
            goal: "do a thing", startedAt: Date()
        ))
        return (conversationID, runID)
    }

    @Test("Run events append with monotonic per-run sequence")
    func runEventSequence() async throws {
        let db = try await makeDatabase()
        let runStore = makeRunStore(db)
        let (_, runID) = try await seedConversationAndRun(db)

        let first = try await runStore.appendEvent(runID: runID, kind: .assistantText, payloadJSON: #"{"text":"a"}"#)
        let second = try await runStore.appendEvent(runID: runID, kind: .toolRequest, payloadJSON: "{}")
        let third = try await runStore.appendEvent(runID: runID, kind: .status, payloadJSON: "{}")

        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(third.sequence == 3)

        let events = try await runStore.events(runID: runID)
        #expect(events.map(\.sequence) == [1, 2, 3])
        #expect(events.map(\.kind) == [.assistantText, .toolRequest, .status])
    }

    @Test("Usage and structured errors round-trip")
    func usageAndErrors() async throws {
        let db = try await makeDatabase()
        let runStore = makeRunStore(db)
        let (_, runID) = try await seedConversationAndRun(db)

        try await runStore.recordUsage(RunUsageRecord(runID: runID, inputTokens: 120, outputTokens: 45, costEstimate: "0.0023"))
        try await runStore.recordError(RunErrorRecord(
            runID: runID, kind: "rateLimited", message: "slow down", httpStatus: 429, recoverable: true
        ))

        let usage = try await runStore.usage(runID: runID)
        #expect(usage.count == 1)
        #expect(usage[0].inputTokens == 120)
        #expect(usage[0].costEstimate == "0.0023")

        let errors = try await runStore.errors(runID: runID)
        #expect(errors.count == 1)
        #expect(errors[0].httpStatus == 429)
        #expect(errors[0].recoverable)
    }

    @Test("Checkpoint upserts by run and reads back body")
    func checkpointRoundTrip() async throws {
        let db = try await makeDatabase()
        let runStore = makeRunStore(db)
        let (conversationID, runID) = try await seedConversationAndRun(db)

        try await runStore.saveCheckpoint(
            runID: runID, conversationID: conversationID,
            formatVersion: 1, state: "preparing", bodyJSON: #"{"v":1}"#
        )
        #expect(try await runStore.checkpointBody(runID: runID) == #"{"v":1}"#)

        // Upsert replaces the body.
        try await runStore.saveCheckpoint(
            runID: runID, conversationID: conversationID,
            formatVersion: 1, state: "preparing", bodyJSON: #"{"v":2}"#
        )
        #expect(try await runStore.checkpointBody(runID: runID) == #"{"v":2}"#)

        try await runStore.deleteCheckpoint(runID: runID)
        #expect(try await runStore.checkpointBody(runID: runID) == nil)
    }

    // MARK: RemoteSessionRegistry

    @Test("Remote session lifecycle: upsert, active filter, state update, remove")
    func remoteSessionLifecycle() async throws {
        let db = try await makeDatabase()
        // A session references a host; create a minimal host row directly.
        let hostID = UUID()
        try await db.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO hosts (id, display_name, address, port, user, auth_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    hostID.uuidString, "box", "192.168.1.10", 22, "me", "{}",
                    PersistenceCodec.encode(Date()), PersistenceCodec.encode(Date())
                ]
            )
        }

        let registry = SQLiteRemoteSessionRegistry(database: db)
        let session = RemoteSessionRecord(hostID: hostID, kind: .sshTerminal, state: .connected)
        try await registry.upsert(session)

        var active = try await registry.activeSessions()
        #expect(active.count == 1)

        try await registry.updateState(id: session.id, state: .suspended, lastHeartbeatAt: Date())
        let suspended = try await registry.session(id: session.id)
        #expect(suspended?.state == .suspended)
        #expect(suspended?.lastHeartbeatAt != nil)

        try await registry.updateState(id: session.id, state: .disconnected, lastHeartbeatAt: nil)
        active = try await registry.activeSessions()
        #expect(active.isEmpty)

        try await registry.removeSession(id: session.id)
        #expect(try await registry.session(id: session.id) == nil)
    }
}
