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


    // MARK: - Shared normalizer / typed search

    @Test("Shared query normalizer applies whitespace AND, phrases and mixed scripts")
    func typedQueryNormalizer() {
        let query = ConversationSearchQuery(raw: "  报告 \"quarterly results\" beta  ")
        #expect(query.terms == [.word("报告"), .phrase("quarterly results"), .word("beta")])
        #expect(query.matches("Beta 报告 for the Quarterly Results"))
        #expect(!query.matches("报告 beta"))
        #expect(!query.matches("quarterly results beta"))
        #expect(query.ranges(in: "报告 Quarterly Results beta").count == 3)
        let duplicates = ConversationSearchQuery(raw: "Alpha alpha ALPHA")
        #expect(duplicates.terms == [.word("Alpha")])
        #expect(ConversationSearchQuery(raw: "   ").isEmpty)
    }

    @Test("Visible-text projection flattens Markdown and never exposes link targets")
    func typedVisibleText() {
        let source = """
        # Title

        A **bold** [link](https://secret.example/path) and `code_x`.
        - item
        ```swift
        let x = 1
        ```
        """
        let visible = ConversationSearchText.visibleText(markdown: source)
        #expect(visible.contains("Title"))
        #expect(visible.contains("bold link and code_x."))
        #expect(visible.contains("item"))
        #expect(visible.contains("let x = 1"))
        #expect(!visible.contains("https://secret.example"))
        #expect(!visible.contains("```"))
        #expect(!ConversationSearchQuery(raw: "secret").matches(visible))
        let ranges = ConversationSearchQuery(raw: "bold link").ranges(in: visible)
        #expect(ranges.count == 2)
        let characters = Array(visible)
        #expect(String(characters[ranges[0].lowerBound..<ranges[0].upperBound]) == "bold")
        #expect(String(characters[ranges[1].lowerBound..<ranges[1].upperBound]) == "link")
    }

    @Test("Typed library search names the exact message and keeps title-only rows body-free")
    func typedLibrarySearch() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let base = Date(timeIntervalSince1970: 1_701_000_000)
        let bodyConversation = UUID(), titleConversation = UUID(), notesConversation = UUID()
        try await conversations.saveConversation(ConversationRecord(
            id: bodyConversation, title: "Ordinary body", createdAt: base, updatedAt: base
        ))
        let bodyMessage = PersistedMessage(
            id: UUID(), conversationID: bodyConversation, role: "user",
            content: "Alpha 报告 内容", createdAt: base
        )
        try await conversations.appendMessage(bodyMessage)
        // Same terms split across two messages: whitespace-AND requires ONE
        // message to contain every term, so this must not match.
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: bodyConversation, role: "assistant",
            content: "only alpha here", createdAt: base.addingTimeInterval(1)))
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: bodyConversation, role: "assistant",
            content: "only 报告 here", createdAt: base.addingTimeInterval(2)))
        try await conversations.saveConversation(ConversationRecord(
            id: titleConversation, title: "季度总结 计划", createdAt: base, updatedAt: base
        ))
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: titleConversation, role: "user",
            content: "unrelated body", createdAt: base))
        try await conversations.saveConversation(ConversationRecord(
            id: notesConversation, title: "季度总结 计划", createdAt: base, updatedAt: base,
            purpose: .notes
        ))
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: notesConversation, role: "user",
            content: "Alpha 报告 内容", createdAt: base))

        let bodyHits = try await store.conversationSearchMatches("alpha 报告")
        #expect(bodyHits.count == 1)
        #expect(bodyHits.first?.messageID == bodyMessage.id)
        #expect(bodyHits.first?.conversationID == bodyConversation)
        #expect(bodyHits.first?.isTitleOnly == false)
        #expect(bodyHits.first?.snippet.contains("Alpha") == true)
        #expect(bodyHits.map(\.conversationID).contains(notesConversation) == false)

        let titleHits = try await store.conversationSearchMatches("季度总结 计划")
        #expect(titleHits.count == 1)
        #expect(titleHits.first?.conversationID == titleConversation)
        #expect(titleHits.first?.messageID == nil)
        #expect(titleHits.first?.isTitleOnly == true)
        #expect(titleHits.map(\.conversationID).contains(notesConversation) == false)

        // A title match never fabricates a body hit when the conversation also
        // has body hits: those rows keep their real message ids instead.
        let mixed = try await store.conversationSearchMatches("季度总结")
        #expect(mixed.contains { $0.conversationID == titleConversation && $0.messageID == nil })
    }

    @Test("In-conversation hits are chronological and the window is bounded")
    func typedConversationWindow() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let conversationID = UUID()
        let base = Date(timeIntervalSince1970: 1_701_100_000)
        try await conversations.saveConversation(ConversationRecord(
            id: conversationID, title: "Window", createdAt: base, updatedAt: base
        ))
        var targetID: UUID?
        for index in 0..<60 {
            let content = index == 20 ? "needle 老消息 内容" : "filler \(index)"
            let message = PersistedMessage(
                id: UUID(), conversationID: conversationID,
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: content,
                createdAt: base.addingTimeInterval(Double(index))
            )
            if index == 20 { targetID = message.id }
            try await conversations.appendMessage(message)
        }
        let target = try #require(targetID)
        let matches = try await store.conversationMessageMatches(
            conversationID: conversationID, rawQuery: "needle 老消息")
        #expect(matches.map(\.messageID) == [target])
        #expect(matches.first?.role == "user")
        let window = try await store.conversationMessageWindow(
            conversationID: conversationID, around: target, before: 3, after: 2)
        #expect(window.count == 6)
        #expect(window.contains(where: { $0.id == target }))
        #expect(window.map(\.createdAt) == window.map(\.createdAt).sorted())
        // Neighbouring rows are real persisted rows, not synthetic hits.
        #expect(window.allSatisfy { $0.conversationID == conversationID })
    }

    // MARK: - Visible-text retrieval regressions

    @Test("Typed search matches rendered Markdown and Unicode-folded text with exact message ids")
    func typedSearchVisibleTextRetrieval() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let conversationID = UUID()
        let base = Date(timeIntervalSince1970: 1_701_200_000)
        try await conversations.saveConversation(ConversationRecord(
            id: conversationID, title: "Rendered text", createdAt: base, updatedAt: base
        ))
        let assistantSource = "The rendered answer is hello **world** today."
        let assistantID = UUID()
        try await conversations.appendMessage(PersistedMessage(
            id: assistantID, conversationID: conversationID, role: "assistant",
            content: assistantSource, createdAt: base
        ))
        let unicodeSource = "Order a Café at １２：３０ for ＡＢＣ."
        let unicodeID = UUID()
        try await conversations.appendMessage(PersistedMessage(
            id: unicodeID, conversationID: conversationID, role: "user",
            content: unicodeSource, createdAt: base.addingTimeInterval(1)
        ))
        // Raw LIKE matches this row through the URL/comment only; the reader
        // never sees "needle" in the rendered body.
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "assistant",
            content: "Read [the note](https://hidden.example/needle) and <!-- needle --> finish.",
            createdAt: base.addingTimeInterval(2)
        ))

        // A quoted phrase split by inline Markdown is a rendered match even
        // though the raw bytes never contain "hello world".
        let phraseHits = try await store.conversationSearchMatches("\"hello world\"")
        #expect(phraseHits.count == 1)
        #expect(phraseHits.first?.messageID == assistantID)
        #expect(phraseHits.first?.snippet.contains("hello world") == true)
        #expect(phraseHits.first?.snippet.contains("**") == false)
        let visible = ConversationSearchText.visibleText(
            role: "assistant", content: assistantSource)
        let phraseRanges = ConversationSearchQuery(raw: "\"hello world\"").ranges(in: visible)
        #expect(phraseRanges.count == 1)
        if let range = phraseRanges.first {
            let characters = Array(visible)
            #expect(String(characters[range.lowerBound..<range.upperBound]) == "hello world")
        }

        // Case/diacritic/width folding must work before the result limit is
        // applied, and highlight ranges stay on the visible string.
        let accentHits = try await store.conversationSearchMatches("CAFE")
        #expect(accentHits.contains { $0.messageID == unicodeID })
        #expect(accentHits.first?.snippet.contains("Café") == true)
        let widthHits = try await store.conversationSearchMatches("\"12:30\"")
        #expect(widthHits.contains { $0.messageID == unicodeID })
        let ascii = try await store.conversationMessageMatches(
            conversationID: conversationID, rawQuery: "abc")
        #expect(ascii.map(\.messageID) == [unicodeID])
        let unicodeVisible = ConversationSearchText.visibleText(
            role: "user", content: unicodeSource)
        let widthRanges = ConversationSearchQuery(raw: "\"12:30\"").ranges(in: unicodeVisible)
        #expect(widthRanges.count == 1)
        if let range = widthRanges.first {
            let characters = Array(unicodeVisible)
            #expect(String(characters[range.lowerBound..<range.upperBound]) == "１２：３０")
        }

        // Hidden link targets/comments are not body results on either surface.
        #expect(try await store.conversationSearchMatches("needle").isEmpty)
        #expect(try await store.conversationMessageMatches(
            conversationID: conversationID, rawQuery: "needle").isEmpty)
    }

    @Test("Typed search never spends its limit on hidden raw matches before visible results")
    func typedSearchHiddenMatchesDoNotStarve() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let conversationID = UUID()
        let base = Date(timeIntervalSince1970: 1_701_300_000)
        try await conversations.saveConversation(ConversationRecord(
            id: conversationID, title: "Starving candidates", createdAt: base, updatedAt: base
        ))
        // Six older and six newer hidden-only rows pump the old raw candidate
        // window on both scan directions; the one real visible row is in the
        // middle. Only a matcher applied inside SQL can find it with limit 1.
        for index in 0..<6 {
            try await conversations.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "assistant",
                content: "Old [note](https://hidden.example/needle-old-\(index)) body.",
                createdAt: base.addingTimeInterval(Double(index))
            ))
        }
        let visibleID = UUID()
        try await conversations.appendMessage(PersistedMessage(
            id: visibleID, conversationID: conversationID, role: "user",
            content: "visible needle body", createdAt: base.addingTimeInterval(10)
        ))
        for index in 0..<6 {
            try await conversations.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "assistant",
                content: "New <!-- needle-new-\(index) --> body.",
                createdAt: base.addingTimeInterval(Double(11 + index))
            ))
        }

        let global = try await store.conversationSearchMatches("needle", limit: 1)
        #expect(global.map(\.messageID) == [visibleID])
        let inChat = try await store.conversationMessageMatches(
            conversationID: conversationID, rawQuery: "needle", limit: 1)
        #expect(inChat.map(\.messageID) == [visibleID])
    }

    @Test("Typed title search uses the same normalizer and stays title-only")
    func typedTitleSearchUnicode() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let base = Date(timeIntervalSince1970: 1_701_400_000)
        let title = "Résumé – 季度 计划"
        let ordinaryID = UUID(), notesID = UUID(), hiddenID = UUID()
        try await conversations.saveConversation(ConversationRecord(
            id: ordinaryID, title: title, createdAt: base, updatedAt: base
        ))
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinaryID, role: "user",
            content: "unrelated body", createdAt: base
        ))
        try await conversations.saveConversation(ConversationRecord(
            id: notesID, title: title, createdAt: base, updatedAt: base,
            purpose: .notes
        ))
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: notesID, role: "user",
            content: "unrelated body", createdAt: base
        ))
        try await conversations.saveConversation(ConversationRecord(
            id: hiddenID, title: title, createdAt: base, updatedAt: base
        ))
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: hiddenID, role: "user",
            content: "unrelated body", createdAt: base
        ))
        try await database.writer { db in
            try db.execute(sql: "UPDATE conversations SET is_searchable = 0 WHERE id = ?",
                           arguments: [hiddenID.uuidString])
        }

        // Diacritic folding and the quoted phrase apply to titles too;
        // Notes and non-searchable conversations stay excluded.
        let accent = try await store.conversationSearchMatches("resume")
        #expect(accent.count == 1)
        #expect(accent.first?.conversationID == ordinaryID)
        #expect(accent.first?.messageID == nil)
        #expect(accent.first?.isTitleOnly == true)
        #expect(accent.first?.snippet == title)

        let phrase = try await store.conversationSearchMatches("\"季度 计划\"")
        #expect(phrase.count == 1)
        #expect(phrase.first?.conversationID == ordinaryID)
        #expect(phrase.first?.messageID == nil)
    }

    @Test("Typed search keeps ordinary/searchable filters and ignores non-body roles")
    func typedSearchDurableFilters() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let base = Date(timeIntervalSince1970: 1_701_500_000)
        let ordinaryID = UUID(), notesID = UUID(), hiddenID = UUID()
        try await conversations.saveConversation(ConversationRecord(
            id: ordinaryID, title: "ordinary", createdAt: base, updatedAt: base
        ))
        let ordinaryMessageID = UUID()
        try await conversations.appendMessage(PersistedMessage(
            id: ordinaryMessageID, conversationID: ordinaryID, role: "user",
            content: "visible filterword body", createdAt: base
        ))
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinaryID, role: "system",
            content: "visible filterword system", createdAt: base.addingTimeInterval(1)
        ))
        try await conversations.saveConversation(ConversationRecord(
            id: notesID, title: "notes filterword", createdAt: base,
            updatedAt: base, purpose: .notes
        ))
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: notesID, role: "user",
            content: "visible filterword notes", createdAt: base
        ))
        try await conversations.saveConversation(ConversationRecord(
            id: hiddenID, title: "hidden filterword", createdAt: base,
            updatedAt: base
        ))
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: hiddenID, role: "user",
            content: "visible filterword hidden", createdAt: base
        ))
        try await database.writer { db in
            try db.execute(sql: "UPDATE conversations SET is_searchable = 0 WHERE id = ?",
                           arguments: [hiddenID.uuidString])
        }

        let global = try await store.conversationSearchMatches("filterword")
        #expect(global.count == 1)
        #expect(global.first?.conversationID == ordinaryID)
        #expect(global.first?.messageID == ordinaryMessageID)
        #expect(global.first?.role == "user")
        #expect(try await store.conversationMessageMatches(
            conversationID: notesID, rawQuery: "filterword").isEmpty)
        #expect(try await store.conversationMessageMatches(
            conversationID: hiddenID, rawQuery: "filterword").isEmpty)
        let inChat = try await store.conversationMessageMatches(
            conversationID: ordinaryID, rawQuery: "filterword")
        #expect(inChat.map(\.messageID) == [ordinaryMessageID])
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
