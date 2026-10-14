// FloePersistenceTests — ConversationPromoter: the temporary-chat promotion
// must commit as ONE GRDB transaction (all rows + FTS index) or roll back to
// zero durable rows. No compensating deletes exist on this path.

import Foundation
import Testing
import GRDB
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("FloePersistence.ConversationPromoter")
struct ConversationPromoterTests {

    private func database() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    private func snapshot(
        conversationID: UUID,
        canary: String,
        messageCount: Int = 3,
        eventCount: Int = 4
    ) -> ConversationPromoter.Snapshot {
        let runID = UUID()
        var messages: [PersistedMessage] = []
        var events: [RunEventRecord] = []
        for index in 0..<messageCount {
            let message = PersistedMessage(
                id: UUID(),
                conversationID: conversationID,
                role: index % 2 == 0 ? "user" : "assistant",
                content: "\(canary)-\(index)",
                createdAt: Date().addingTimeInterval(TimeInterval(index)),
                runID: runID
            )
            messages.append(message)
        }
        for index in 0..<eventCount {
            events.append(RunEventRecord(
                runID: runID,
                sequence: index + 1,
                kind: .assistantText,
                payloadJSON: #"{"delta":"\#(canary)-e\#(index)"}"#
            ))
        }
        return ConversationPromoter.Snapshot(
            conversation: ConversationRecord(
                id: conversationID,
                title: canary,
                createdAt: Date(),
                updatedAt: Date(),
                purpose: .ordinary
            ),
            messages: messages,
            attachments: [],
            runs: [RunRecord(
                id: runID,
                conversationID: conversationID,
                state: "completed",
                goal: canary,
                startedAt: Date(),
                conversationMode: "chat"
            )],
            events: events,
            usage: [RunUsageRecord(
                runID: runID,
                inputTokens: 10,
                outputTokens: 20,
                recordedAt: Date()
            )],
            errors: [RunErrorRecord(
                runID: runID,
                kind: "notice",
                message: canary,
                recoverable: true
            )]
        )
    }

    @Test("Whole snapshot commits in one transaction, including the FTS index")
    func promoteCommitsAtomically() async throws {
        let database = try await database()
        let id = UUID()
        let canary = "promo-\(UUID().uuidString.prefix(8))"
        try await ConversationPromoter(database: database).promote(
            snapshot(conversationID: id, canary: canary)
        )
        let store = SQLiteConversationStore(database: database)
        #expect(try await store.messages(conversationID: id).count == 3)
        // FTS: the schema's triggers index message content during the same
        // transaction, so promoted content is immediately searchable.
        let ftsHits = try await database.reader { db in
            // Quote the canary: FTS5 treats a bare hyphen as the NOT
            // operator ("no such column"), not as token punctuation.
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?",
                arguments: ["\"\(canary)\""]
            ) ?? 0
        }
        #expect(ftsHits == 3)
        let runStore = SQLiteRunStore(database: database)
        let runs = try await runStore.runs(conversationID: id)
        #expect(runs.count == 1)
        #expect(try await runStore.events(runID: runs[0].id).count == 4)
        #expect(try await runStore.usage(runID: runs[0].id).count == 1)
        #expect(try await runStore.errors(runID: runs[0].id).count == 1)
    }

    @Test("Foreign-key violation rolls back everything: zero durable rows")
    func promoteRollsBackOnFailure() async throws {
        let database = try await database()
        let id = UUID()
        let canary = "rollback-\(UUID().uuidString.prefix(8))"
        var broken = snapshot(conversationID: id, canary: canary)
        broken.messages.append(PersistedMessage(
            id: UUID(),
            conversationID: UUID(), // not in the snapshot → FK violation
            role: "user",
            content: "\(canary)-orphan",
            createdAt: Date()
        ))
        await #expect(throws: (any Error).self) {
            try await ConversationPromoter(database: database).promote(broken)
        }
        // Zero rows of every kind — no partial history, no FTS residue.
        let counts = try await database.reader { db in
            (
                conversations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations WHERE id = ?", arguments: [id.uuidString]) ?? 0,
                messages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE conversation_id = ?", arguments: [id.uuidString]) ?? 0,
                runs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs WHERE conversation_id = ?", arguments: [id.uuidString]) ?? 0,
                events: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM run_events WHERE run_id IN (SELECT id FROM runs WHERE conversation_id = ?)", arguments: [id.uuidString]) ?? 0,
                fts: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?", arguments: ["\"\(canary)\""]) ?? 0
            )
        }
        #expect(counts.conversations == 0)
        #expect(counts.messages == 0)
        #expect(counts.runs == 0)
        #expect(counts.events == 0)
        #expect(counts.fts == 0)
    }

    @Test("Repeated promotion of the same snapshot is idempotent")
    func repeatedPromoteIsIdempotent() async throws {
        let database = try await database()
        let id = UUID()
        let snap = snapshot(conversationID: id, canary: "idem-\(UUID().uuidString.prefix(8))")
        let promoter = ConversationPromoter(database: database)
        try await promoter.promote(snap)
        try await promoter.promote(snap)
        let store = SQLiteConversationStore(database: database)
        #expect(try await store.messages(conversationID: id).count == 3)
        let runStore = SQLiteRunStore(database: database)
        #expect(try await runStore.runs(conversationID: id).count == 1)
        #expect(try await runStore.events(runID: snap.runs[0].id).count == 4)
        #expect(try await runStore.usage(runID: snap.runs[0].id).count == 1)
        #expect(try await runStore.errors(runID: snap.runs[0].id).count == 1)
    }

    // MARK: - Snapshot integrity (pre-commit validation)

    @Test("A snapshot row owned by another conversation is refused before any write")
    func promoteRejectsCrossConversationRows() async throws {
        let database = try await database()
        let id = UUID()
        let canary = "xowner-\(UUID().uuidString.prefix(8))"
        var malicious = snapshot(conversationID: id, canary: canary)
        malicious.messages.append(PersistedMessage(
            id: UUID(),
            conversationID: UUID(), // not the promoted conversation
            role: "user",
            content: "\(canary)-foreign",
            createdAt: Date()
        ))
        await #expect(throws: ConversationPromoter.ValidationError.self) {
            try await ConversationPromoter(database: database).promote(malicious)
        }
        let counts = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations WHERE id = ?", arguments: [id.uuidString]) ?? 0
        }
        #expect(counts == 0)
    }

    @Test("A part not owned by its message and an event outside the snapshot runs are refused")
    func promoteRejectsMismatchedIdentities() async throws {
        let database = try await database()
        let id = UUID()
        let canary = "xid-\(UUID().uuidString.prefix(8))"
        var badParts = snapshot(conversationID: id, canary: canary)
        var message = badParts.messages[0]
        message.parts = [MessagePart(
            messageID: UUID(), // not the owning message
            partIndex: 0,
            kind: .text,
            text: "rogue",
            createdAt: Date()
        )]
        badParts.messages[0] = message
        await #expect(throws: ConversationPromoter.ValidationError.self) {
            try await ConversationPromoter(database: database).promote(badParts)
        }

        var badEvents = snapshot(conversationID: id, canary: canary)
        badEvents.events.append(RunEventRecord(
            runID: UUID(), // no such run in the snapshot
            sequence: 99,
            kind: .status,
            payloadJSON: "{}"
        ))
        await #expect(throws: ConversationPromoter.ValidationError.self) {
            try await ConversationPromoter(database: database).promote(badEvents)
        }
    }

    @Test("Snapshot ids already durable under a different owner are rejected and the existing conversation is untouched")
    func promoteRejectsForeignConflicts() async throws {
        let database = try await database()
        // Pre-existing ordinary conversation with its own message.
        let existingID = UUID()
        let existingStore = SQLiteConversationStore(database: database)
        try await existingStore.saveConversation(ConversationRecord(
            id: existingID, title: "Existing", createdAt: Date(), updatedAt: Date(), purpose: .ordinary
        ))
        let existingMessage = PersistedMessage(
            id: UUID(), conversationID: existingID, role: "user",
            content: "existing-history", createdAt: Date()
        )
        try await existingStore.appendMessage(existingMessage)

        // A snapshot for a DIFFERENT conversation that reuses the existing
        // message id (collision) must fail closed, not rewrite the row.
        let targetID = UUID()
        var malicious = snapshot(conversationID: targetID, canary: "conflict-\(UUID().uuidString.prefix(8))")
        malicious.messages.append(PersistedMessage(
            id: existingMessage.id,
            conversationID: targetID,
            role: "user",
            content: "hijack",
            createdAt: Date()
        ))
        await #expect(throws: ConversationPromoter.ValidationError.self) {
            try await ConversationPromoter(database: database).promote(malicious)
        }
        // The existing conversation is byte-identical in shape.
        #expect(try await existingStore.messages(conversationID: existingID).map(\.content) == ["existing-history"])
        #expect(try await existingStore.conversation(id: existingID)?.title == "Existing")
        // And the target conversation has nothing.
        #expect(try await existingStore.conversation(id: targetID) == nil)
    }

    @Test("Attachments and multi-part messages commit in foreign-key order and stay searchable")
    func promoteCommitsAttachmentsAndParts() async throws {
        let database = try await database()
        let id = UUID()
        let runID = UUID()
        let canary = "parts-\(UUID().uuidString.prefix(8))"
        let attachmentID = UUID()
        let attachment = AttachmentRef(
            id: attachmentID,
            conversationID: id,
            messageID: nil,
            kind: .document,
            displayName: "note.txt",
            createdAt: Date()
        )
        let message = PersistedMessage(
            id: UUID(),
            conversationID: id,
            role: "user",
            content: canary,
            createdAt: Date(),
            parts: [
                MessagePart(messageID: UUID(), partIndex: 0, kind: .text, text: canary, createdAt: Date()),
                MessagePart(messageID: UUID(), partIndex: 1, kind: .file, attachmentID: attachmentID, createdAt: Date()),
            ],
            runID: runID
        )
        // Fix part ownership to the message (as the ephemeral store guarantees).
        let owned = PersistedMessage(
            id: message.id,
            conversationID: id,
            role: message.role,
            content: message.content,
            createdAt: message.createdAt,
            parts: message.parts.map { part in
                var p = part
                p.messageID = message.id
                return p
            },
            runID: runID
        )
        let snapshot = ConversationPromoter.Snapshot(
            conversation: ConversationRecord(
                id: id, title: canary, createdAt: Date(), updatedAt: Date(), purpose: .ordinary
            ),
            messages: [owned],
            attachments: [attachment],
            runs: [RunRecord(
                id: runID, conversationID: id, state: "completed",
                goal: canary, startedAt: Date(), conversationMode: "chat"
            )],
            events: [],
            usage: [],
            errors: []
        )
        try await ConversationPromoter(database: database).promote(snapshot)

        let store = SQLiteConversationStore(database: database)
        let parts = try await store.parts(messageID: owned.id)
        #expect(parts.count == 2)
        #expect(parts.first?.attachmentID == nil)
        #expect(parts.last?.attachmentID == attachmentID)
        #expect(try await store.attachment(id: attachmentID)?.displayName == "note.txt")
        let ftsHits = try await database.reader { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?",
                arguments: ["\"\(canary)\""]
            ) ?? 0
        }
        #expect(ftsHits == 1)
    }

    @Test("Pending inputs commit in the same transaction and roll back with it")
    func promoteCarriesPendingInputsAtomically() async throws {
        let database = try await database()
        let id = UUID()
        let canary = "inputs-\(UUID().uuidString.prefix(8))"
        var promo = snapshot(conversationID: id, canary: canary)
        let runID = promo.runs[0].id
        promo.inputs = [
            PendingUserInput(
                id: UUID(), conversationID: id, content: "\(canary)-queued",
                mode: .queue, status: .queued, position: 1
            ),
            PendingUserInput(
                id: UUID(), conversationID: id, targetRunID: runID,
                content: "\(canary)-steer", mode: .steer, status: .steerPending,
                position: 2
            )
        ]
        try await ConversationPromoter(database: database).promote(promo)
        let inputs = SQLiteRunningInputStore(database: database)
        let saved = try await inputs.pending(conversationID: id)
        #expect(saved.map(\.content) == ["\(canary)-queued", "\(canary)-steer"])
        #expect(saved.first?.status == .queued)
        #expect(saved.last?.status == .steerPending)
        #expect(saved.last?.targetRunID == runID)

        // Rollback: a foreign-owned input fails validation before any
        // write, so the whole transaction (inputs included) leaves nothing.
        let other = UUID()
        var broken = snapshot(conversationID: id, canary: "rollback-\(canary)")
        broken.inputs = [
            PendingUserInput(
                id: UUID(), conversationID: other, content: "foreign",
                mode: .queue, status: .queued, position: 1
            )
        ]
        await #expect(throws: (any Error).self) {
            try await ConversationPromoter(database: database).promote(broken)
        }
        #expect(try await inputs.pending(conversationID: id).count == 2)
        #expect(try await inputs.pending(conversationID: other).isEmpty)
    }

    @Test("An input id already durable under a different owner is rejected before any write")
    func promoteRejectsForeignInputConflict() async throws {
        let database = try await database()
        let target = UUID()
        let stranger = UUID()
        let promoter = ConversationPromoter(database: database)
        // The stranger conversation legitimately owns a pending input.
        var existing = snapshot(conversationID: stranger, canary: "existing-\(UUID().uuidString.prefix(8))", messageCount: 1, eventCount: 0)
        existing.inputs = [
            PendingUserInput(
                id: UUID(), conversationID: stranger, content: "stranger-input",
                mode: .queue, status: .queued, position: 1
            )
        ]
        try await promoter.promote(existing)
        // The target conversation promotes its own input (no conflict).
        var own = snapshot(conversationID: target, canary: "conflict-\(UUID().uuidString.prefix(8))", messageCount: 1, eventCount: 0)
        own.inputs = [
            PendingUserInput(
                id: UUID(), conversationID: target, content: "own-input",
                mode: .queue, status: .queued, position: 1
            )
        ]
        try await promoter.promote(own)
        // A snapshot whose input id already exists under the OTHER
        // conversation fails closed and mutates nothing.
        var malicious = snapshot(conversationID: target, canary: "malicious-\(UUID().uuidString.prefix(8))", messageCount: 1, eventCount: 0)
        let foreign = try #require(try await SQLiteRunningInputStore(database: database)
            .pending(conversationID: stranger).first)
        malicious.inputs = [
            PendingUserInput(
                id: foreign.id, conversationID: target, content: "overwritten",
                mode: .queue, status: .queued, position: 1
            )
        ]
        await #expect(throws: (any Error).self) {
            try await promoter.promote(malicious)
        }
        let intact = try await SQLiteRunningInputStore(database: database)
            .pending(conversationID: stranger)
        #expect(intact.count == 1)
        #expect(intact.first?.content == "stranger-input")
    }
}
