// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import GRDB
import FloeModels
import FloePersistence
import FloeInteractiveContentCore
@testable import FloeApp

@Suite("Interactive presentation transaction", .serialized)
@MainActor struct InteractiveStateIntegrationTests {
    @Test func keepStateCASAndOwnerDeletionUseActualDatabase() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let id = UUID(), runID = UUID(), sourceID = UUID(), now = Date()
        let document = try InteractiveDocument(owner: .init(conversationID: id, runID: runID, messageID: sourceID),
            kind: "calculator", title: "Synthetic calculator", html: "<p>Calculator</p>", fallbackText: "Calculator")
        let state = InteractiveState(document: document)
        let conversation = ConversationRecord(id: id, title: "Synthetic presentation", createdAt: now, updatedAt: now)
        let run = RunRecord(id: runID, conversationID: id, state: "completed", goal: "Fixture", startedAt: now, endedAt: now)
        let message = PersistedMessage(id: sourceID, conversationID: id, role: "assistant", content: "Calculator", createdAt: now, runID: runID)
        let snapshot = ConversationPromoter.Snapshot(conversation: conversation, messages: [message], attachments: [],
            runs: [run], events: [], usage: [], errors: [], presentations: [try InteractiveHostCodec.record(document, state)])
        try await ConversationPromoter(database: database).promote(snapshot)
        let repository = InteractiveHostRepository(database: database)
        #expect(try await repository.load(document: document).revision == 0)
        let next = try await repository.compareAndSwap(document: document, expectedRevision: 0,
            modelContent: .object(["amount": .number(42)]), privateContent: .object(["expanded": .bool(true)]))
        #expect(next.revision == 1)
        await #expect(throws: (any Error).self) {
            _ = try await repository.compareAndSwap(document: document, expectedRevision: 0, modelContent: .null, privateContent: .null)
        }
        #expect(try await repository.load(document: document) == next)
        let store = SQLiteConversationStore(database: database)
        try await store.deleteConversation(id: id)
        let count = try await database.reader { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM conversation_presentations") }
        #expect(count == 0)
        await #expect(throws: (any Error).self) {
            _ = try await repository.compareAndSwap(document: document, expectedRevision: 0, modelContent: .null, privateContent: .null)
        }
    }

    @Test func presentationCommitFailureRollsBackWholeKeep() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        try await database.writer { db in
            try ConversationPresentationSQL.prepare(db)
            try db.execute(sql: "CREATE TRIGGER fixture_presentation_failure BEFORE INSERT ON conversation_presentations BEGIN SELECT RAISE(ABORT, 'synthetic presentation failure'); END")
        }
        let id = UUID(), runID = UUID(), sourceID = UUID(), now = Date()
        let document = try InteractiveDocument(owner: .init(conversationID: id, runID: runID, messageID: sourceID),
            kind: "chart", title: "Synthetic chart", html: "<p>Chart</p>", fallbackText: "Chart")
        let snapshot = ConversationPromoter.Snapshot(
            conversation: .init(id: id, title: "Must roll back", createdAt: now, updatedAt: now),
            messages: [.init(id: sourceID, conversationID: id, role: "assistant", content: "Chart", createdAt: now, runID: runID)],
            attachments: [], runs: [.init(id: runID, conversationID: id, state: "completed", goal: "Fixture", startedAt: now)],
            events: [], usage: [], errors: [], presentations: [try InteractiveHostCodec.record(document, .init(document: document))])
        do { try await ConversationPromoter(database: database).promote(snapshot); Issue.record("Keep committed after the actual presentation INSERT failed") }
        catch { #expect(error.localizedDescription.contains("synthetic presentation failure")) }
        #expect(try await SQLiteConversationStore(database: database).conversation(id: id) == nil)
        #expect(try await SQLiteRunStore(database: database).run(id: runID) == nil)
    }
}
#endif
