import Foundation
import Testing
@testable import FloeCore
@testable import FloeAgentRuntime
@testable import FloeModels
@testable import FloePersistence
import FloeTools

@Suite("Conversation full-text search")
struct ConversationSearchTests {
    @Test("Notes assistant conversations are absent from ordinary history tools")
    func dedicatedNotesHistory() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let ordinary = UUID(), notes = UUID(), now = Date()
        for id in [ordinary, notes] {
            try await conversations.saveConversation(.init(id: id, title: "Identical title", createdAt: now, updatedAt: now,
                purpose: id == notes ? .notes : .ordinary))
            try await conversations.appendMessage(.init(id: UUID(), conversationID: id, role: "user", content: "uniquehistoryword", createdAt: now))
        }
        #expect(try await store.matchingConversationSnippets("uniquehistoryword").keys.sorted { $0.uuidString < $1.uuidString } == [ordinary])
        #expect(try await store.search(.init(query: "uniquehistoryword", includeAllWorkspaces: true)).map(\.conversationID) == [ordinary])
        await #expect(throws: (any Error).self) { try await store.read(.init(conversationID: notes)) }
        #expect(try await conversations.messages(conversationID: notes).count == 1)
        #expect(try await conversations.conversation(id: notes)?.purpose == .notes)
    }

    @Test("Library search includes CJK message substrings, literal wildcard characters and old conversations")
    func libraryContentsSearch() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let id = UUID()
        try await conversations.saveConversation(.init(id: id, title: "Unrelated title", createdAt: Date(), updatedAt: Date()))
        for index in 0..<60 {
            try await conversations.appendMessage(.init(id: UUID(), conversationID: id, role: "user", content: "第\(index) 条包含边际成本和100%_混合 English", createdAt: Date()))
        }
        #expect(try await store.matchingConversationSnippets("边际成本").keys.sorted { $0.uuidString < $1.uuidString } == [id])
        #expect(try await store.matchingConversationSnippets("100%_")[id]?.contains("100%_") == true)
        #expect(try await store.matchingConversationSnippets("missing").isEmpty)
        #expect(try await store.matchingConversationSnippets(" ").isEmpty)
    }

    @Test("Search ranks FTS hits without bm25 auxiliary-function context error")
    func searchRanksHits() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationStore = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let conversationID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_200_000)
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Searchable", createdAt: base, updatedAt: base
        ))
        let frequent = UUID()
        try await conversationStore.appendMessage(PersistedMessage(
            id: frequent, conversationID: conversationID, role: "user",
            content: "alpha beta beta beta", createdAt: base
        ))
        try await conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "assistant",
            content: "beta appears once", createdAt: base.addingTimeInterval(1)
        ))
        try await conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "assistant",
            content: "unrelated content", createdAt: base.addingTimeInterval(2)
        ))

        // This query previously threw "SQLite error 1: unable to use function
        // bm25 in the requested context" because bm25()/snippet() were
        // evaluated in the ORDER BY of a GROUP BY aggregate.
        let hits = try await store.search(ConversationSearchRequest(query: "beta"))
        #expect(hits.count == 2)
        #expect(hits.first?.messageID == frequent)
        #expect(hits.allSatisfy { $0.conversationID == conversationID })
        #expect(hits.first?.snippet.contains("[beta]") == true)
        #expect(hits.first?.conversationTitle == "Searchable")
    }

    @Test("Search honours workspace ownership filter and date range")
    func searchFilters() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationStore = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let base = Date(timeIntervalSince1970: 1_700_300_000)

        let ownedConversation = UUID()
        let otherConversation = UUID()
        for (id, title) in [(ownedConversation, "Owned"), (otherConversation, "Other")] {
            try await conversationStore.saveConversation(ConversationRecord(
                id: id, title: title, createdAt: base, updatedAt: base
            ))
            try await conversationStore.appendMessage(PersistedMessage(
                id: UUID(), conversationID: id, role: "user",
                content: "shared needle", createdAt: base
            ))
        }
        let workspaceID = UUID()
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO workspaces (id, name, root_bookmark, created_at, updated_at)
                VALUES (?, 'ws', X'00', ?, ?)
                """, arguments: [workspaceID.uuidString, Self.iso(base), Self.iso(base)])
            try db.execute(sql: """
                INSERT INTO conversation_workspace_ownership (conversation_id, workspace_id, assigned_at)
                VALUES (?, ?, ?)
                """, arguments: [ownedConversation.uuidString, workspaceID.uuidString, Self.iso(base)])
        }

        let filtered = try await store.search(ConversationSearchRequest(query: "needle", workspaceID: workspaceID))
        #expect(filtered.count == 1)
        #expect(filtered.first?.conversationID == ownedConversation)
        #expect(filtered.first?.workspaceID == workspaceID)

        let unfiltered = try await store.search(ConversationSearchRequest(query: "needle"))
        #expect(unfiltered.count == 2)

        let futureOnly = try await store.search(ConversationSearchRequest(
            query: "needle", startDate: base.addingTimeInterval(60)
        ))
        #expect(futureOnly.isEmpty)
    }

    @Test("Agent search matches Chinese substrings, titles and respects date range")
    func agentSearchSubstringFallback() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationStore = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let base = Date(timeIntervalSince1970: 1_700_400_000)

        // Content hit: the CJK run is one unicode61 token ("季度总结报告"),
        // so the shorter substring can only match through the literal
        // fallback, never through FTS.
        let contentHit = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: contentHit, title: "无关标题", createdAt: base, updatedAt: base
        ))
        try await conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: contentHit, role: "user",
            content: "请整理这份季度总结报告", createdAt: base
        ))
        // Title-only hit: no message contains the query.
        let titleHit = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: titleHit, title: "季度总结草稿", createdAt: base, updatedAt: base
        ))
        try await conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: titleHit, role: "user",
            content: "unrelated body", createdAt: base
        ))
        // Out-of-range message must not surface through the fallback either.
        let outOfRange = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: outOfRange, title: "季度总结旧任务", createdAt: base, updatedAt: base
        ))
        try await conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: outOfRange, role: "user",
            content: "季度总结报告（旧）", createdAt: base.addingTimeInterval(-86_400 * 30)
        ))
        let notesConversation = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: notesConversation, title: "季度总结手记", createdAt: base, updatedAt: base,
            purpose: .notes
        ))
        try await conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: notesConversation, role: "user",
            content: "季度总结报告", createdAt: base
        ))

        let hits = try await store.search(ConversationSearchRequest(query: "季度总结"))
        #expect(hits.map(\.conversationID).contains(contentHit))
        #expect(hits.map(\.conversationID).contains(titleHit))
        #expect(hits.first(where: { $0.conversationID == titleHit })?.snippet.hasPrefix("[title match]") == true)
        #expect(hits.map(\.conversationID).contains(notesConversation) == false)
        // Both candidates have an in-range message, so the old conversation
        // still matches an unbounded query; the range filter is what drops it.
        let ranged = try await store.search(ConversationSearchRequest(
            query: "季度总结", startDate: base.addingTimeInterval(-3_600)
        ))
        #expect(ranged.map(\.conversationID).contains(outOfRange) == false)
        #expect(ranged.map(\.conversationID).contains(contentHit))
        // Title anchor messages are date-filtered too: the old conversation's
        // only message is out of range, so its title match disappears.
        #expect(ranged.map(\.conversationID).contains(titleHit))
    }

    @Test("Substring fallback excludes FTS-hit conversations in SQL so they cannot consume the limit")
    func substringFallbackExcludesFTSHits() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationStore = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let base = Date(timeIntervalSince1970: 1_700_500_000)

        // Five conversations produce FTS hits (whole-token "anchor"). Three
        // more match only as a literal substring inside a longer token. With
        // limit=8, a fallback that re-returned the five FTS conversations
        // from its own SQL allowance would hide one of the substring-only
        // tasks; SQL-side exclusion surfaces all three.
        var ftsIDs: [UUID] = []
        for index in 0..<5 {
            let id = UUID()
            ftsIDs.append(id)
            try await conversationStore.saveConversation(ConversationRecord(
                id: id, title: "fts \(index)", createdAt: base, updatedAt: base
            ))
            try await conversationStore.appendMessage(PersistedMessage(
                id: UUID(), conversationID: id, role: "user",
                content: "anchor item \(index)", createdAt: base
            ))
        }
        var substringIDs: [UUID] = []
        for (index, body) in ["anchorage details", "theanchorpoint", "ananchoredlisting"].enumerated() {
            let id = UUID()
            substringIDs.append(id)
            try await conversationStore.saveConversation(ConversationRecord(
                id: id, title: "substring \(index)", createdAt: base, updatedAt: base
            ))
            try await conversationStore.appendMessage(PersistedMessage(
                id: UUID(), conversationID: id, role: "user",
                content: body, createdAt: base
            ))
        }

        let hits = try await store.search(ConversationSearchRequest(query: "anchor", limit: 8))
        #expect(hits.count == 8)
        #expect(ftsIDs.allSatisfy { hits.map(\.conversationID).contains($0) })
        #expect(substringIDs.allSatisfy { hits.map(\.conversationID).contains($0) })
        // No conversation is duplicated across the two passes.
        #expect(Set(hits.map(\.conversationID)).count == hits.count)
    }

    @Test("conversation.list returns recent searchable tasks and excludes Notes sessions")
    func conversationListDiscovery() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationStore = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let base = Date(timeIntervalSince1970: 1_700_600_000)
        let older = UUID(), newer = UUID(), notes = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: older, title: "older", createdAt: base, updatedAt: base
        ))
        try await conversationStore.saveConversation(ConversationRecord(
            id: newer, title: "newer", createdAt: base, updatedAt: base.addingTimeInterval(120)
        ))
        try await conversationStore.saveConversation(ConversationRecord(
            id: notes, title: "notes", createdAt: base, updatedAt: base.addingTimeInterval(240),
            purpose: .notes
        ))
        let entries = try await store.list(ConversationListRequest())
        #expect(entries.map(\.conversationID) == [newer, older])
        #expect(entries.map(\.title) == ["newer", "older"])

        let tool = ConversationListTool(reader: store) { _ in newer }
        let output = try await tool.execute(.init(), context: ToolContext(runID: UUID(), cancellation: CancellationToken(), conversationID: newer))
        let text = output.summary
        // The current conversation is filtered out of the discovery envelope.
        #expect(text.contains(newer.uuidString) == false)
        #expect(text.contains(older.uuidString))
        #expect(text.contains("\"trust\":\"untrustedHistoricalData\""))
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
