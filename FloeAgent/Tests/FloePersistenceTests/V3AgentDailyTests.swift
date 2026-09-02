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

    @Test("Migration preserves v3 and reaches the current schema")
    func migratesToV3() async throws {
        let database = try await makeDatabase()
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)
        let applied = try await database.appliedMigrations()
        #expect(applied.contains("v1"))
        #expect(applied.contains("v2"))
        #expect(applied.contains("v3"))
        #expect(applied.contains("v4"))
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

    @Test("Timeline migrations install keyset indexes")
    func timelineIndexesExist() async throws {
        let database = try await makeDatabase()
        let indexes = try await database.reader { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index'"
            )
        }
        #expect(indexes.contains("idx_messages_conversation_cursor_v31"))
        #expect(indexes.contains("idx_runs_conversation_cursor_v31"))
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

    @Test("Recent message window returns the newest page in chronological order")
    func recentMessageWindow() async throws {
        let db = try await makeDatabase()
        let store = makeConversationStore(db)
        let conversationID = UUID()
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "Long task", createdAt: origin, updatedAt: origin
        ))
        for index in 0..<5 {
            try await store.appendMessage(PersistedMessage(
                id: UUID(),
                conversationID: conversationID,
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "message-\(index)",
                createdAt: origin.addingTimeInterval(Double(index))
            ))
        }

        let recent = try await store.recentMessages(conversationID: conversationID, limit: 3)
        #expect(recent.map(\.content) == ["message-2", "message-3", "message-4"])
    }

    @Test("Message cursor pages do not repeat or omit equal-timestamp rows")
    func messageCursorPages() async throws {
        let db = try await makeDatabase()
        let store = makeConversationStore(db)
        let conversationID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_100)
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "Paged", createdAt: timestamp, updatedAt: timestamp
        ))
        let IDs = (0..<7).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        for (index, id) in IDs.enumerated() {
            try await store.appendMessage(PersistedMessage(
                id: id, conversationID: conversationID, role: "user",
                content: "message-\(index)", createdAt: timestamp
            ))
        }

        let newest = try await store.messagePage(
            conversationID: conversationID, before: nil, limit: 3
        )
        let middle = try await store.messagePage(
            conversationID: conversationID, before: newest.earlierCursor, limit: 3
        )
        let oldest = try await store.messagePage(
            conversationID: conversationID, before: middle.earlierCursor, limit: 3
        )

        #expect(newest.hasEarlier)
        #expect(middle.hasEarlier)
        #expect(!oldest.hasEarlier)
        let all = oldest.messages + middle.messages + newest.messages
        #expect(all.map(\.id) == IDs)
        #expect(Set(all.map(\.id)).count == 7)
    }

    @Test("Ten-thousand-message page stays bounded and batch-hydrates parts")
    func hugeConversationWindow() async throws {
        let db = try await makeDatabase()
        let store = makeConversationStore(db)
        let conversationID = UUID()
        let origin = Date(timeIntervalSince1970: 1_700_010_000)
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "Huge", createdAt: origin, updatedAt: origin
        ))
        let ids = (0..<10_000).map { _ in UUID() }
        try await db.writer { database in
            for (index, id) in ids.enumerated() {
                try database.execute(
                    sql: """
                        INSERT INTO messages (id, conversation_id, role, content, created_at)
                        VALUES (?, ?, 'assistant', ?, ?)
                        """,
                    arguments: [
                        id.uuidString, conversationID.uuidString, "message-\(index)",
                        PersistenceCodec.encode(origin.addingTimeInterval(Double(index)))
                    ]
                )
                if index >= 9_950 {
                    try database.execute(
                        sql: """
                            INSERT INTO message_parts (
                                id, message_id, part_index, kind, text,
                                metadata_json, created_at
                            ) VALUES (?, ?, 0, 'text', ?, '{}', ?)
                            """,
                        arguments: [
                            UUID().uuidString, id.uuidString, "part-\(index)",
                            PersistenceCodec.encode(origin.addingTimeInterval(Double(index)))
                        ]
                    )
                }
            }
        }

        let page = try await store.messagePage(
            conversationID: conversationID, before: nil, limit: 100
        )
        #expect(page.messages.count == 100)
        #expect(page.hasEarlier)
        #expect(page.messages.first?.content == "message-9900")
        #expect(page.messages.last?.content == "message-9999")
        #expect(page.messages.suffix(50).allSatisfy { $0.parts.count == 1 })
        let plan: [String] = try await db.reader { database in
            try Row.fetchAll(
                database,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT * FROM messages
                    WHERE conversation_id = ?
                    ORDER BY created_at DESC, id DESC
                    LIMIT 101
                """,
                arguments: [conversationID.uuidString]
            ).map { $0["detail"] }
        }
        #expect(plan.joined(separator: " ").contains("idx_messages_conversation_cursor_v31"))
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

    @Test("Recent run and event windows are newest-first bounded queries")
    func boundedRunWindows() async throws {
        let db = try await makeDatabase()
        let runStore = makeRunStore(db)
        let (conversationID, runID) = try await seedConversationAndRun(db)
        let origin = Date().addingTimeInterval(1_000)
        for index in 0..<8 {
            try await runStore.saveRun(RunRecord(
                id: UUID(),
                conversationID: conversationID,
                state: index == 6 ? "runningTool" : "completed",
                goal: "run-\(index)",
                startedAt: origin.addingTimeInterval(Double(index))
            ))
        }
        try await db.writer { database in
            for sequence in 1...1_500 {
                try database.execute(
                    sql: """
                        INSERT INTO run_events (id, run_id, sequence, kind, payload_json, created_at)
                        VALUES (?, ?, ?, 'status', '{}', ?)
                        """,
                    arguments: [
                        UUID().uuidString, runID.uuidString, sequence,
                        PersistenceCodec.encode(origin.addingTimeInterval(Double(sequence)))
                    ]
                )
            }
        }

        let runs = try await runStore.recentRuns(conversationID: conversationID, limit: 3)
        #expect(runs.map(\.goal) == ["run-7", "run-6", "run-5"])
        let active = try await runStore.nonTerminalRuns()
        #expect(active.contains { $0.goal == "run-6" })
        #expect(active.contains { $0.id == runID })
        let events = try await runStore.recentEvents(runID: runID, limit: 1_000)
        #expect(events.count == 1_000)
        #expect(events.first?.sequence == 501)
        #expect(events.last?.sequence == 1_500)
        let resumed = try await runStore.events(
            runID: runID, afterSequence: 1_490, limit: 6
        )
        #expect(resumed.map(\.sequence) == [1_491, 1_492, 1_493, 1_494, 1_495, 1_496])
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
