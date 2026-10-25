// FloePersistenceTests — focused real-SQLite coverage for
// ToolCaptureCleanupRequestStore: durable cleanup intents over app_settings.
//
// Meaningful checks only: persistence/recreation across a real file-backed
// database close/reopen, unique and idempotent request identity keyed by a
// canonical generated UUID with no user text, survival of the request
// through a CONFIRMED owner conversation deletion (the queue must not ride
// any FK cascade), bounded oldest-first listing with honest counts, exact
// single-row acknowledgement that never removes unrelated/live records,
// real write failures propagating instead of being swallowed as success
// while the durable request survives, and strict refusal to report a
// tampered row as a clean queue.

import Foundation
import Testing
import GRDB
@testable import FloePersistence

@Suite("FloePersistence.ToolCaptureCleanupRequestStore")
struct ToolCaptureCleanupRequestStoreTests {

    // MARK: - Fixtures

    private func makeFileDatabase() async throws -> (database: DatabaseManager, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-tool-capture-cleanup-\(UUID().uuidString).sqlite")
        let database = try DatabaseManager(path: url)
        try await database.migrate()
        return (database, url)
    }

    private func makeInMemoryDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    private func fixedDate(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_761_400_000 + offset)
    }

    /// Raw helper: the exact key the store must derive for a conversation.
    private func expectedKey(_ id: UUID) -> String {
        ToolCaptureCleanupRequestStore.requestKeyPrefix + id.uuidString
    }

    // MARK: 1. Unique, idempotent, canonical request identity

    @Test("Enqueue is idempotent on one canonical generated UUID key and stores no user text")
    func enqueueIsUniqueAndIdempotent() async throws {
        let database = try await makeInMemoryDatabase()
        let store = ToolCaptureCleanupRequestStore(database: database)
        let conversation = UUID()
        let first = fixedDate(0)
        let later = fixedDate(600)

        let created = try await store.enqueue(conversationID: conversation, now: first)
        #expect(created == ToolCaptureCleanupRequest(conversationID: conversation, requestedAt: first))

        // Re-enqueue must NOT mint a second identity or move the original
        // request time: the durable intent is exactly one row per UUID.
        let again = try await store.enqueue(conversationID: conversation, now: later)
        #expect(again == created)
        #expect(try await store.count() == 1)
        #expect(try await store.pendingConversationIDs() == [conversation])

        // Trusted canonical key: prefix + upper-case uuidString, value holds
        // only version/conversation UUID/request time.
        let stored = try await database.reader { db in
            try String.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?",
                                arguments: [expectedKey(conversation)])
        }
        #expect(stored?.contains("\"v\":\"1\"") == true)
        #expect(stored?.contains(conversation.uuidString) == true)
    }

    // MARK: 2. Persistence and recreation over a real SQLite file

    @Test("Requests survive a real file close/recreate and keep exact request times")
    func requestsRecreateFromDurableFile() async throws {
        let (database, url) = try await makeFileDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = UUID()
        let second = UUID()
        let store = ToolCaptureCleanupRequestStore(database: database)
        try await store.enqueue(conversationID: first, now: fixedDate(10))
        try await store.enqueue(conversationID: second, now: fixedDate(20))

        try await database.close()

        // Recreate the process-level stack: brand-new manager + brand-new
        // store over the same on-disk database.
        let reopened = try DatabaseManager(path: url)
        try await reopened.migrate()
        let rebuilt = ToolCaptureCleanupRequestStore(database: reopened)
        let pending = try await rebuilt.pendingRequests()
        #expect(pending == [
            ToolCaptureCleanupRequest(conversationID: first, requestedAt: fixedDate(10)),
            ToolCaptureCleanupRequest(conversationID: second, requestedAt: fixedDate(20)),
        ])
        #expect(try await rebuilt.hasRequest(conversationID: first))
        #expect(try await rebuilt.count() == 2)
        try await reopened.close()
    }

    // MARK: 3. The request outlives the confirmed owner deletion

    @Test("Request survives the confirmed owner conversation deletion (no FK cascade)")
    func requestSurvivesOwnerDeletion() async throws {
        let database = try await makeInMemoryDatabase()
        let conversations = SQLiteConversationStore(database: database)
        let store = ToolCaptureCleanupRequestStore(database: database)
        let conversation = UUID()
        let secretTitle = "Secret Quarterly Plan π"
        try await conversations.saveConversation(ConversationRecord(
            id: conversation, title: secretTitle,
            createdAt: fixedDate(0), updatedAt: fixedDate(0)))
        try await store.enqueue(conversationID: conversation, now: fixedDate(1))

        // The deletion the request was created to finish: this is the real
        // cascade path, not a synthetic row removal.
        try await conversations.deleteConversation(id: conversation)
        #expect(try await conversations.conversation(id: conversation) == nil)

        // The intent MUST still be pending — app_settings carries no FK to
        // conversations, and no cascade removes it.
        #expect(try await store.pendingConversationIDs() == [conversation])

        // Non-secret: neither the title nor any user text landed in SQLite.
        let stored = try await database.reader { db in
            try String.fetchOne(db, sql: """
                SELECT key || '|' || value_json FROM app_settings WHERE key = ?
                """, arguments: [expectedKey(conversation)])
        }
        #expect(stored?.contains("Secret") == false)
        #expect(stored?.contains("π") == false)

        #expect(try await store.acknowledge(conversationID: conversation))
        #expect(try await store.pendingConversationIDs().isEmpty)
    }

    // MARK: 4. Bounded oldest-first listing with honest counts

    @Test("Listing is bounded oldest-first while count reports the true backlog")
    func listingIsBoundedAndCountHonest() async throws {
        let database = try await makeInMemoryDatabase()
        let store = ToolCaptureCleanupRequestStore(database: database)
        var ids: [UUID] = []
        for index in 0..<5 {
            let id = UUID()
            try await store.enqueue(conversationID: id, now: fixedDate(TimeInterval(index) * 60))
            ids.append(id)
        }
        // Oldest-first deterministic window.
        #expect(try await store.pendingConversationIDs(limit: 3) == Array(ids[0..<3]))
        #expect(try await store.pendingConversationIDs(limit: 0).isEmpty)
        // Default window returns the full backlog under the cap.
        #expect(try await store.pendingConversationIDs().count == 5)
        // Honest total beyond any listing window.
        #expect(try await store.count() == 5)
    }

    // MARK: 5. Acknowledge removes only its own request

    @Test("Acknowledge deletes exactly one canonical request and never unrelated or live rows")
    func acknowledgeRemovesOnlyItsOwnRequest() async throws {
        let database = try await makeInMemoryDatabase()
        let store = ToolCaptureCleanupRequestStore(database: database)
        let alpha = UUID()
        let beta = UUID()
        try await store.enqueue(conversationID: alpha, now: fixedDate(0))
        try await store.enqueue(conversationID: beta, now: fixedDate(60))

        // Foreign rows: another app_settings consumer and a deliberately
        // prefix-ADJACENT key that must not match the namespace filter.
        try await database.writer { db in
            try db.execute(sql: "INSERT INTO app_settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                           arguments: ["chat.defaultMode", "\"focus\"", PersistenceCodec.encode(fixedDate(0))])
            try db.execute(sql: "INSERT INTO app_settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                           arguments: ["tools.captureCleanup.requests.sibling", "\"keepme\"",
                                       PersistenceCodec.encode(fixedDate(0))])
        }

        // Unknown request: honest `false`, not an error, nothing removed.
        #expect(!(try await store.acknowledge(conversationID: UUID())))

        #expect(try await store.acknowledge(conversationID: alpha))
        #expect(try await store.pendingConversationIDs() == [beta])
        // Double acknowledgement is not a false success claim: it is `false`.
        #expect(!(try await store.acknowledge(conversationID: alpha)))
        #expect(try await store.count() == 1)

        let survivors = try await database.reader { db in
            [
                "chat.defaultMode": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM app_settings WHERE key = ?",
                                                     arguments: ["chat.defaultMode"]) ?? 0,
                "sibling": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM app_settings WHERE key = ?",
                                            arguments: ["tools.captureCleanup.requests.sibling"]) ?? 0,
                "beta": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM app_settings WHERE key = ?",
                                         arguments: [expectedKey(beta)]) ?? 0,
            ]
        }
        #expect(survivors["chat.defaultMode"] == 1)
        #expect(survivors["sibling"] == 1)
        #expect(survivors["beta"] == 1)
    }

    // MARK: 6. Enqueue write failure propagates and persists nothing

    @Test("A real enqueue write failure throws and never leaves a false request or success")
    func enqueueWriteFailureIsNotSwallowed() async throws {
        let (database, url) = try await makeFileDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ToolCaptureCleanupRequestStore(database: database)
        try await store.enqueue(conversationID: UUID(), now: fixedDate(0))
        try await database.close()

        // DatabaseManager.close() renders the manager unusable: GRDB reads
        // and writes fail afterwards. The store must propagate, not claim.
        let late = UUID()
        await #expect(throws: DatabaseError.self) {
            try await store.enqueue(conversationID: late, now: fixedDate(1))
        }

        // No partial row from the failed call; only the earlier request
        // remains durable.
        let reopened = try DatabaseManager(path: url)
        try await reopened.migrate()
        let rebuilt = ToolCaptureCleanupRequestStore(database: reopened)
        #expect(try await rebuilt.count() == 1)
        #expect(!(try await rebuilt.hasRequest(conversationID: late)))
        try await reopened.close()
    }

    // MARK: 7. Acknowledge failure preserves the request; success removes it

    @Test("A failed acknowledge keeps the durable request and only a real delete removes it")
    func acknowledgeFailurePreservesRequest() async throws {
        let (database, url) = try await makeFileDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let conversation = UUID()
        let store = ToolCaptureCleanupRequestStore(database: database)
        try await store.enqueue(conversationID: conversation, now: fixedDate(0))
        try await database.close()

        await #expect(throws: DatabaseError.self) {
            try await store.acknowledge(conversationID: conversation)
        }

        // The request survived the failed acknowledgement: the cleanup is
        // still owed, and no code path reported it as acknowledged.
        let reopened = try DatabaseManager(path: url)
        try await reopened.migrate()
        let rebuilt = ToolCaptureCleanupRequestStore(database: reopened)
        #expect(try await rebuilt.pendingConversationIDs() == [conversation])

        // Only a real write removes the request now.
        #expect(try await rebuilt.acknowledge(conversationID: conversation))
        #expect(try await rebuilt.pendingConversationIDs().isEmpty)
        try await reopened.close()
    }

    // MARK: 8. Tampered rows are never reported as a clean queue

    @Test("Non-canonical rows under the prefix throw corruptState instead of hiding")
    func tamperedRowsKeepQueueUnknown() async throws {
        let database = try await makeInMemoryDatabase()
        let store = ToolCaptureCleanupRequestStore(database: database)
        let canonical = UUID()
        try await store.enqueue(conversationID: canonical, now: fixedDate(0))
        let mismatched = UUID()
        let other = UUID()
        let malformed = UUID()

        try await database.writer { db in
            // (a) non-UUID suffix; (b) UUID key whose value names a DIFFERENT
            // UUID; (c) unparseable value under a canonical key.
            try db.execute(sql: "INSERT INTO app_settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                           arguments: [ToolCaptureCleanupRequestStore.requestKeyPrefix + "not-a-uuid",
                                       "{\"v\":\"1\",\"conversationID\":\"\(other.uuidString)\","
                                       + "\"requestedAt\":\"\(PersistenceCodec.encode(fixedDate(0)))\"}",
                                       PersistenceCodec.encode(fixedDate(0))])
            try db.execute(sql: "INSERT INTO app_settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                           arguments: [expectedKey(mismatched),
                                       "{\"v\":\"1\",\"conversationID\":\"\(other.uuidString)\","
                                       + "\"requestedAt\":\"\(PersistenceCodec.encode(fixedDate(1)))\"}",
                                       PersistenceCodec.encode(fixedDate(1))])
            try db.execute(sql: "INSERT INTO app_settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                           arguments: [expectedKey(malformed), "\"not-json\"",
                                       PersistenceCodec.encode(fixedDate(2))])
        }

        // Listing and per-key reads refuse to skip silently.
        await #expect(throws: ToolCaptureCleanupRequestStoreError.corruptState) {
            _ = try await store.pendingConversationIDs()
        }
        await #expect(throws: ToolCaptureCleanupRequestStoreError.corruptState) {
            _ = try await store.hasRequest(conversationID: mismatched)
        }
        // The honest count still shows the full (tampered-inflated) backlog.
        #expect(try await store.count() == 4)

        // Exact-key acknowledgement is the recovery path for tampered
        // canonical keys, without ever parsing or trusting the value.
        #expect(try await store.acknowledge(conversationID: mismatched))
        #expect(try await store.acknowledge(conversationID: malformed))
        await #expect(throws: ToolCaptureCleanupRequestStoreError.corruptState) {
            _ = try await store.pendingRequests()
        }
        #expect(try await store.count() == 2)

        // The non-UUID suffix cannot be reached through the UUID-only API by
        // design: raw repair only. After raw removal the real queue reads
        // clean again.
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM app_settings WHERE key = ?",
                           arguments: [ToolCaptureCleanupRequestStore.requestKeyPrefix + "not-a-uuid"])
        }
        #expect(try await store.pendingConversationIDs() == [canonical])
    }
}
