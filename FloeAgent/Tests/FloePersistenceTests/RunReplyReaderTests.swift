import Foundation
import Testing
import FloeModels
import FloePersistence

@Suite("FloePersistence.RunReplyReader")
struct RunReplyReaderTests {
    @Test("The reply belongs to this exact run and conversation")
    func exactRunAndOwner() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let owner = UUID(), other = UUID(), runID = UUID(), laterRun = UUID()
        for id in [owner, other] {
            try await store.saveConversation(.init(id: id, title: "Synthetic reply owner",
                createdAt: Date(), updatedAt: Date()))
        }
        let runs = SQLiteRunStore(database: database)
        for id in [runID, laterRun] {
            try await runs.saveRun(.init(id: id, conversationID: owner, state: "completed",
                goal: "Synthetic reply", startedAt: Date(), endedAt: Date()))
        }
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "Exact original reply", createdAt: Date(), runID: runID))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "Later run's reply", createdAt: Date(), runID: laterRun))
        try await store.appendMessage(.init(id: UUID(), conversationID: other, role: "assistant",
            content: "Foreign owner's row", createdAt: Date(), runID: runID))
        let reader = SQLiteRunReplyReader(database: database)
        #expect(try await reader.latestAssistantText(runID: runID, conversationID: owner) == "Exact original reply")
        #expect(try await reader.latestAssistantText(runID: laterRun, conversationID: owner) == "Later run's reply")
        #expect(try await reader.latestAssistantText(runID: laterRun, conversationID: other) == nil)
    }

    @Test("Clock rollback cannot replace the final answer with a pre-tool step")
    func clockRollbackAndRoleFiltering() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let owner = UUID(), runID = UUID()
        try await store.saveConversation(.init(id: owner, title: "Synthetic clock correction",
            createdAt: Date(), updatedAt: Date()))
        try await SQLiteRunStore(database: database).saveRun(.init(id: runID,
            conversationID: owner, state: "completed", goal: "Synthetic clock correction",
            startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 3_000)))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "Earlier tool step", createdAt: Date(timeIntervalSince1970: 2_000), runID: runID))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "Full final reply\n第二行 👩🏽‍🚀", createdAt: Date(timeIntervalSince1970: 1_000), runID: runID))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "tool",
            content: "Not an assistant result", createdAt: Date(), runID: runID))
        #expect(try await SQLiteRunReplyReader(database: database)
            .latestAssistantText(runID: runID, conversationID: owner) == "Full final reply\n第二行 👩🏽‍🚀")
    }

    @Test("An empty final row never falls back to an earlier step")
    func emptyFinalRowIsNotBackfilled() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let owner = UUID(), runID = UUID()
        try await store.saveConversation(.init(id: owner, title: "Synthetic empty final",
            createdAt: Date(), updatedAt: Date()))
        try await SQLiteRunStore(database: database).saveRun(.init(id: runID,
            conversationID: owner, state: "completed", goal: "Synthetic empty final",
            startedAt: Date(), endedAt: Date()))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "I will check", createdAt: Date(timeIntervalSince1970: 1_000), runID: runID))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "", createdAt: Date(timeIntervalSince1970: 2_000), runID: runID))
        #expect(try await SQLiteRunReplyReader(database: database)
            .latestAssistantText(runID: runID, conversationID: owner) == "")
    }

    @Test("The proven read resolves exactly the designated message by id, run, owner and role")
    func provenFinalReplyExactRead() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let owner = UUID(), other = UUID(), runID = UUID(), otherRun = UUID()
        for id in [owner, other] {
            try await store.saveConversation(.init(id: id, title: "Synthetic proof owner",
                createdAt: Date(), updatedAt: Date()))
        }
        let runs = SQLiteRunStore(database: database)
        for id in [runID, otherRun] {
            try await runs.saveRun(.init(id: id, conversationID: owner, state: "completed",
                goal: "Synthetic proof", startedAt: Date(), endedAt: Date()))
        }
        let stepRow = UUID()
        let draftRow = UUID()
        let laterRunRow = UUID()
        try await store.appendMessage(.init(id: stepRow, conversationID: owner, role: "assistant",
            content: "I will check", createdAt: Date(), runID: runID))
        try await store.appendMessage(.init(id: draftRow, conversationID: owner, role: "assistant",
            content: "Confirmed draft answer", createdAt: Date(), runID: runID))
        try await store.appendMessage(.init(id: laterRunRow, conversationID: owner, role: "assistant",
            content: "Other run answer", createdAt: Date(timeIntervalSince1970: 9_999), runID: otherRun))
        let toolRow = UUID()
        try await store.appendMessage(.init(id: toolRow, conversationID: owner, role: "tool",
            content: "tool output", createdAt: Date(), runID: runID))
        let reader = SQLiteRunReplyReader(database: database)

        // The designated draft resolves even though an older step row and a
        // NEWER other-run row exist — no latest-row inference is involved.
        #expect(try await reader.provenFinalReplyText(
            runID: runID, conversationID: owner, messageID: draftRow) == "Confirmed draft answer")
        #expect(try await reader.provenFinalReplyText(
            runID: runID, conversationID: owner, messageID: stepRow) == "I will check")
        // Cross-run, cross-owner and role mismatches resolve to nothing.
        #expect(try await reader.provenFinalReplyText(
            runID: runID, conversationID: owner, messageID: laterRunRow) == nil)
        #expect(try await reader.provenFinalReplyText(
            runID: runID, conversationID: other, messageID: draftRow) == nil)
        #expect(try await reader.provenFinalReplyText(
            runID: otherRun, conversationID: owner, messageID: draftRow) == nil)
        #expect(try await reader.provenFinalReplyText(
            runID: runID, conversationID: owner, messageID: toolRow) == nil)
        // An unknown/forged id and an empty designated row keep their honest
        // distinctions: nothing at all vs the persisted empty answer.
        #expect(try await reader.provenFinalReplyText(
            runID: runID, conversationID: owner, messageID: UUID()) == nil)
        let emptyRow = UUID()
        try await store.appendMessage(.init(id: emptyRow, conversationID: owner, role: "assistant",
            content: "", createdAt: Date(), runID: runID))
        #expect(try await reader.provenFinalReplyText(
            runID: runID, conversationID: owner, messageID: emptyRow) == "")
    }

    @Test("Another run's later assistant row cannot fill a missing reply")
    func otherRunCannotFillGap() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let owner = UUID(), targetRun = UUID(), laterRun = UUID()
        try await store.saveConversation(.init(id: owner, title: "Synthetic later run",
            createdAt: Date(), updatedAt: Date()))
        let runs = SQLiteRunStore(database: database)
        for id in [targetRun, laterRun] {
            try await runs.saveRun(.init(id: id, conversationID: owner, state: "completed",
                goal: "Synthetic later run", startedAt: Date(), endedAt: Date()))
        }
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "I will check", createdAt: Date(timeIntervalSince1970: 1_000), runID: targetRun))
        try await store.appendMessage(.init(id: UUID(), conversationID: owner, role: "assistant",
            content: "Later task answer", createdAt: Date(timeIntervalSince1970: 2_000), runID: laterRun))
        #expect(try await SQLiteRunReplyReader(database: database)
            .latestAssistantText(runID: targetRun, conversationID: owner) == "I will check")
        #expect(try await SQLiteRunReplyReader(database: database)
            .latestAssistantText(runID: laterRun, conversationID: owner) == "Later task answer")
    }
}
