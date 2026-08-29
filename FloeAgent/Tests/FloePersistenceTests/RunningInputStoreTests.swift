import Foundation
import Testing
@testable import FloePersistence
import FloeCore
import FloeModels

@Suite("FloePersistence.RunningInputStore")
struct RunningInputStoreTests {
    private func makeStore() async throws -> (SQLiteRunningInputStore, UUID, UUID) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationID = UUID()
        let runID = UUID()
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, 'Queue', '2026-08-17T00:00:00Z', '2026-08-17T00:00:00Z')
                """, arguments: [conversationID.uuidString])
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at)
                VALUES (?, ?, 'streamingModel', 'work', '2026-08-17T00:00:00Z')
                """, arguments: [runID.uuidString, conversationID.uuidString])
        }
        return (SQLiteRunningInputStore(database: database), conversationID, runID)
    }

    @Test("queue ordering, edit and remove are durable")
    func queueLifecycle() async throws {
        let (store, conversationID, runID) = try await makeStore()
        let first = try await store.enqueue(.init(
            conversationID: conversationID, targetRunID: runID, content: "first"
        ))
        let second = try await store.enqueue(.init(
            conversationID: conversationID, targetRunID: runID, content: "second"
        ))

        try await store.reorder(conversationID: conversationID, orderedIDs: [second.id, first.id])
        try await store.updateContent(id: first.id, content: "edited")
        #expect(try await store.pending(conversationID: conversationID).map(\.content) == ["second", "edited"])

        try await store.cancel(id: second.id)
        #expect(try await store.pending(conversationID: conversationID).map(\.id) == [first.id])
    }

    @Test("queue to steer promotion has one conditional consumer")
    func exactlyOnceSteerPromotion() async throws {
        let (store, conversationID, runID) = try await makeStore()
        let input = try await store.enqueue(.init(
            conversationID: conversationID, targetRunID: runID, content: "guide"
        ))

        let promoted = try await store.beginSteerPromotion(id: input.id, expectedRunID: runID)
        #expect(promoted?.status == .promoting)
        #expect(try await store.beginSteerPromotion(id: input.id, expectedRunID: runID) == nil)

        try await store.markSteerAccepted(id: input.id, runID: runID)
        #expect(try await store.input(id: input.id)?.status == .steerPending)
        try await store.markConsumed(id: input.id, runID: runID)
        try await store.markConsumed(id: input.id, runID: runID)
        let consumed = try #require(try await store.input(id: input.id))
        #expect(consumed.status == .consumed)
        #expect(consumed.consumedRunID == runID)
        #expect(try await store.pending(conversationID: conversationID).isEmpty)
    }

    @Test("cold launch restores unconsumed transient rows")
    func transientRecovery() async throws {
        let (store, conversationID, runID) = try await makeStore()
        let input = try await store.enqueue(.init(
            conversationID: conversationID, targetRunID: runID, content: "recover"
        ))
        _ = try await store.beginSteerPromotion(id: input.id, expectedRunID: runID)

        try await store.recoverTransientInputs()

        let recovered = try #require(try await store.input(id: input.id))
        #expect(recovered.status == .queued)
        #expect(recovered.mode == .queue)
        #expect(recovered.targetRunID == nil)
    }

    @Test("user-authored credentials are not rewritten in the running-input queue")
    func preservesCredentialsInAuthoredInput() async throws {
        let (store, conversationID, runID) = try await makeStore()
        let secret = "queue-secret-123"
        let input = try await store.enqueue(.init(
            conversationID: conversationID,
            targetRunID: runID,
            content: "连接设备，password is \(secret)"
        ))

        #expect(input.content.contains(secret))
        let persisted = try #require(try await store.input(id: input.id))
        #expect(persisted.content.contains(secret))

        try await store.updateContent(id: input.id, content: "更新凭据：密码为\(secret)")
        let edited = try #require(try await store.input(id: input.id))
        #expect(edited.content.contains(secret))
    }
}
