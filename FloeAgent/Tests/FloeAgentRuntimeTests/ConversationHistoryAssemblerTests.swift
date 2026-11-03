import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloePersistence
@testable import FloeModels

@Suite("FloeAgentRuntime.ConversationHistoryAssembler")
struct ConversationHistoryAssemblerTests {
    @Test("Five turns remain one ordered task context")
    func keepsFiveTurns() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let conversationID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "Continuous", createdAt: Date(), updatedAt: Date()
        ))
        for turn in 1...5 {
            try await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "user",
                content: "requirement-\(turn)", createdAt: Date().addingTimeInterval(Double(turn * 2))
            ))
            try await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "assistant",
                content: "decision-\(turn)", createdAt: Date().addingTimeInterval(Double(turn * 2 + 1))
            ))
        }

        let history = try await ConversationHistoryAssembler(store: store).build(
            conversationID: conversationID
        )
        #expect(history.count == 10)
        #expect(history.first?.content == "requirement-1")
        #expect(history.last?.content == "decision-5")
    }

    @Test("Older turns become a bounded sourced summary")
    func summarizesOlderTurns() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let conversationID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "Compressed", createdAt: Date(), updatedAt: Date()
        ))
        for index in 0..<8 {
            try await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID,
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "message-\(index)", createdAt: Date().addingTimeInterval(Double(index))
            ))
        }

        let history = try await ConversationHistoryAssembler(
            store: store, maximumMessages: 4
        ).build(conversationID: conversationID)
        #expect(history.count == 5)
        #expect(history[0].role == "system")
        #expect(history[0].content.contains("sourceMessageIDs="))
        #expect(history[0].content.contains("sourceDigest="))
        #expect(history[0].content.contains("User requests and corrections"))
        #expect(history[0].content.contains("resume the latest unfinished request directly"))
        #expect(history[1].content == "message-4")
    }

    @Test("Legacy workspace context notices are not model turns")
    func filtersLegacyWorkspaceContextNotice() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let conversationID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "Context", createdAt: Date(), updatedAt: Date()
        ))
        try await store.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: "已将工作区文件加入上下文：report.pdf", createdAt: Date()
        ))
        try await store.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: "请总结报告", createdAt: Date().addingTimeInterval(1)
        ))

        let history = try await ConversationHistoryAssembler(store: store)
            .build(conversationID: conversationID)

        #expect(history.map(\.content) == ["请总结报告"])
    }

    @Test("App-owned staged images are inlined after the picker scope closes")
    func inlinesApplicationSupportImage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let bytes = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        try bytes.write(to: attachments.appendingPathComponent("picked.png"))
        let attachment = AttachmentRef(
            kind: .image,
            displayName: "picked.png",
            uti: "public.png",
            byteCount: bytes.count,
            storage: .applicationSupport,
            relativePath: "picked.png"
        )

        let images = ConversationHistoryAssembler.inlineImages(
            [attachment],
            applicationSupportRoot: root
        )

        #expect(images.count == 1)
        #expect(images[0].base64 == bytes.base64EncodedString())
        #expect(images[0].mimeType == "image/png")
    }

    @Test("Image MIME follows real bytes instead of stale attachment metadata")
    func detectsImageBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try jpeg.write(to: attachments.appendingPathComponent("legacy.svg"))
        let attachment = AttachmentRef(
            kind: .image,
            displayName: "legacy.svg",
            uti: "public.svg-image",
            byteCount: jpeg.count,
            storage: .applicationSupport,
            relativePath: "legacy.svg"
        )

        let images = ConversationHistoryAssembler.inlineImages(
            [attachment], applicationSupportRoot: root
        )
        #expect(images.first?.mimeType == "image/jpeg")
        #expect(images.first?.base64 == jpeg.base64EncodedString())
    }

    @Test("A staged-image relative path cannot escape its app-owned directory")
    func rejectsApplicationSupportTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Attachments", isDirectory: true),
            withIntermediateDirectories: true
        )
        let outside = root.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        let attachment = AttachmentRef(
            kind: .image,
            displayName: "outside.png",
            uti: "public.png",
            byteCount: 7,
            storage: .applicationSupport,
            relativePath: "../outside.png"
        )

        #expect(ConversationHistoryAssembler.inlineImages(
            [attachment],
            applicationSupportRoot: root
        ).isEmpty)
    }
}

@Suite("FloeAgentRuntime.ContextHistoryRecovery", .serialized)
struct ContextHistoryRecoveryTests {
    private struct Fixture {
        let database: DatabaseManager
        let conversations: SQLiteConversationStore
        let intelligence: SQLiteIntelligenceStore
        let conversationID: UUID
        let runID: UUID
    }

    private func fixture(database: DatabaseManager? = nil) async throws -> Fixture {
        let db = try database ?? DatabaseManager.inMemory()
        try await db.migrate()
        let conversations = SQLiteConversationStore(database: db)
        let runs = SQLiteRunStore(database: db)
        let conversationID = UUID(), runID = UUID()
        try await conversations.saveConversation(.init(id: conversationID, title: "Context recovery",
            createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: runID, conversationID: conversationID,
            state: "completed", goal: "Continue the existing task", startedAt: Date()))
        return Fixture(database: db, conversations: conversations,
            intelligence: SQLiteIntelligenceStore(database: db), conversationID: conversationID, runID: runID)
    }

    private func append(_ contents: [String], to fixture: Fixture) async throws -> [PersistedMessage] {
        var rows: [PersistedMessage] = []
        for (index, content) in contents.enumerated() {
            let row = PersistedMessage(id: UUID(), conversationID: fixture.conversationID,
                role: index.isMultiple(of: 2) ? "user" : "assistant", content: content,
                createdAt: Date(timeIntervalSince1970: Double(index)))
            try await fixture.conversations.appendMessage(row)
            rows.append(row)
        }
        return rows
    }

    @Test("Count and byte omissions all enter the sourced historical summary")
    func byteBoundaryHasNoUncoveredGap() async throws {
        let fixture = try await fixture()
        var contents = Array(repeating: String(repeating: "x", count: 8_192), count: 80)
        contents[15] = "BYTE_LIMIT_REQUIRED_CORRECTION " + contents[15]
        let rows = try await append(contents, to: fixture)
        let history = try await ConversationHistoryAssembler(store: fixture.conversations)
            .build(conversationID: fixture.conversationID)
        let summary = try #require(history.first(where: ContextHistorySnapshot.isSummary))
        let accounted = Set(history.flatMap { [$0.id] + ($0.contextSourceMessageIDs ?? []) })
        #expect(rows.allSatisfy { accounted.contains($0.id) })
        #expect(summary.content.contains("BYTE_LIMIT_REQUIRED_CORRECTION"))
        #expect(history.reduce(0, { $0 + $1.content.utf8.count }) <= 512 * 1_024)
        #expect(try await fixture.conversations.messages(conversationID: fixture.conversationID).count == 80)
    }

    @Test("Hundreds of source IDs cannot displace the historical prose")
    func identifierListHasIndependentBudget() async throws {
        let fixture = try await fixture()
        let rows = try await append((0..<600).map { "past-evidence-\($0)" }, to: fixture)
        let history = try await ConversationHistoryAssembler(store: fixture.conversations)
            .build(conversationID: fixture.conversationID)
        let summary = try #require(history.first(where: ContextHistorySnapshot.isSummary))
        #expect(summary.content.utf8.count <= 16_000)
        #expect(summary.content.contains("past-evidence-0"))
        #expect(summary.content.contains("past-evidence-479"))
        #expect(summary.contextSourceMessageIDs?.count == 480)
        #expect(Set(summary.contextSourceMessageIDs ?? []) == Set(rows.prefix(480).map(\.id)))
        #expect(summary.content.contains("sourceMessageCount=480"))
    }

    @Test("Automatic snapshots restore before limits and a newer snapshot replaces their full coverage")
    func automaticSnapshotsAcrossNewRuns() async throws {
        let fixture = try await fixture()
        let rows = try await append((0..<200).map { "original-turn-\($0)" }, to: fixture)
        let first = ContextCompactionRecord(sourceMessageIDs: rows.prefix(160).map(\.id),
            sourceDigest: "first", beforeEstimatedTokens: 4_000, afterEstimatedTokens: 400)
        let firstText = ContextHistorySnapshot.automaticPrefix + "[Context compaction notice]\nHistorical summary:\nOriginal objective ORIGINAL_WORK_743; preserve the existing installation."
        try await fixture.intelligence.saveCompaction(runID: fixture.runID, record: first, summary: firstText)
        let firstHistory = try await ConversationHistoryAssembler(store: fixture.conversations,
            compactionStore: SQLiteIntelligenceStore(database: fixture.database)).build(conversationID: fixture.conversationID)
        #expect(firstHistory.count == 41)
        #expect(firstHistory.first?.id == first.id)
        #expect(firstHistory.first?.content.contains("ORIGINAL_WORK_743") == true)
        #expect(!firstHistory.contains { $0.content == "original-turn-159" })
        #expect(firstHistory.contains { $0.id == rows[160].id })
        let second = ContextCompactionRecord(sourceMessageIDs: [first.id] + rows[160..<180].map(\.id),
            sourceDigest: "second", beforeEstimatedTokens: 2_000, afterEstimatedTokens: 300)
        try await fixture.intelligence.saveCompaction(runID: fixture.runID, record: second,
            summary: ContextHistorySnapshot.automaticPrefix + "[Context compaction notice]\nHistorical summary:\nORIGINAL_WORK_743; newer correction CORRECTION_951.")
        let secondHistory = try await ConversationHistoryAssembler(store: fixture.conversations,
            compactionStore: SQLiteIntelligenceStore(database: fixture.database)).build(conversationID: fixture.conversationID)
        #expect(secondHistory.count == 21)
        #expect(secondHistory.filter(ContextHistorySnapshot.isSummary).map(\.id) == [second.id])
        #expect(secondHistory[0].content.contains("CORRECTION_951"))
        #expect(Set(rows.prefix(180).map(\.id)).isSubset(of: Set(secondHistory[0].contextSourceMessageIDs ?? [])))
        #expect(try await fixture.conversations.messages(conversationID: fixture.conversationID).count == 200)
    }

    @Test("A legacy manual summary and an automatic successor remain idempotent")
    func manualAutomaticLineage() async throws {
        let fixture = try await fixture()
        let rows = try await append(["old requirement", "new correction"], to: fixture)
        let manual = ContextCompactionRecord(sourceMessageIDs: [rows[0].id], sourceDigest: "manual",
            beforeEstimatedTokens: 100, afterEstimatedTokens: 50)
        try await fixture.intelligence.saveCompaction(runID: fixture.runID, record: manual,
            summary: ContextHistorySnapshot.manualPrefix + "[Context compaction notice]\nHistorical summary: manual")
        let automatic = ContextCompactionRecord(sourceMessageIDs: [manual.id], sourceDigest: "auto",
            beforeEstimatedTokens: 50, afterEstimatedTokens: 30)
        try await fixture.intelligence.saveCompaction(runID: fixture.runID, record: automatic,
            summary: ContextHistorySnapshot.automaticPrefix + "[Context compaction notice]\nHistorical summary: merged")
        let raw = rows.map { ConversationMessage(id: $0.id, role: $0.role, content: $0.content) }
        let restored = try await fixture.intelligence.applyingCompactions(raw, conversationID: fixture.conversationID)
        let again = try await fixture.intelligence.applyingCompactions(restored, conversationID: fixture.conversationID)
        #expect(restored.map(\.content) == again.map(\.content))
        #expect(restored.map(\.contextSourceMessageIDs) == again.map(\.contextSourceMessageIDs))
        #expect(restored.map(\.id) == [automatic.id, rows[1].id])
        #expect(restored[0].contextSourceMessageIDs?.contains(rows[0].id) == true)
    }

    @Test("A cancelled durable save leaves the previous checkpoint selected")
    func cancelledSaveKeepsPriorSnapshot() async throws {
        let fixture = try await fixture()
        let rows = try await append(["original"], to: fixture)
        let first = ContextCompactionRecord(sourceMessageIDs: [rows[0].id], sourceDigest: "first",
            beforeEstimatedTokens: 100, afterEstimatedTokens: 40)
        try await fixture.intelligence.saveCompaction(runID: fixture.runID, record: first,
            summary: ContextHistorySnapshot.automaticPrefix + "[Context compaction notice]\nHistorical summary: committed")
        let rejected = ContextCompactionRecord(sourceMessageIDs: [first.id], sourceDigest: "cancelled",
            beforeEstimatedTokens: 40, afterEstimatedTokens: 20)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.intelligence.saveCompaction(runID: fixture.runID, record: rejected,
                summary: ContextHistorySnapshot.automaticPrefix + "[Context compaction notice]\nHistorical summary: must not commit")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let restored = try await fixture.intelligence.applyingCompactions([], conversationID: fixture.conversationID)
        #expect(restored.map(\.id) == [first.id])
    }
}

extension ContextHistoryRecoveryTests {
    @Test("A fresh database manager rebuilds the committed automatic checkpoint from disk")
    func diskSnapshotRecovery() async throws {
        let parent = ProcessInfo.processInfo.environment["FLOE_CONTEXT_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("context-reopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("history.sqlite")
        func writeInitial() async throws -> (UUID, UUID) {
            let fixture = try await fixture(database: DatabaseManager(path: path))
            let rows = try await append(["original objective", "completed evidence", "latest correction"], to: fixture)
            let record = ContextCompactionRecord(sourceMessageIDs: rows.prefix(2).map(\.id),
                sourceDigest: "disk", beforeEstimatedTokens: 100, afterEstimatedTokens: 40)
            try await fixture.intelligence.saveCompaction(runID: fixture.runID, record: record,
                summary: ContextHistorySnapshot.automaticPrefix + "[Context compaction notice]\nHistorical summary:\nDISK_OBJECTIVE_637 and completed evidence.")
            return (fixture.conversationID, record.id)
        }
        let (conversationID, summaryID) = try await writeInitial()
        let reopened = try DatabaseManager(path: path)
        try await reopened.migrate()
        let conversations = SQLiteConversationStore(database: reopened)
        let history = try await ConversationHistoryAssembler(store: conversations,
            compactionStore: SQLiteIntelligenceStore(database: reopened)).build(conversationID: conversationID)
        #expect(history.count == 2)
        #expect(history.first?.id == summaryID)
        #expect(history.first?.content.contains("DISK_OBJECTIVE_637") == true)
        #expect(history.last?.content == "latest correction")
        #expect(try await conversations.messages(conversationID: conversationID).count == 3)
    }

    @Test("A snapshot from another conversation cannot change this history")
    func snapshotOwnership() async throws {
        let fixture = try await fixture()
        let rows = try await append(["own objective", "own correction"], to: fixture)
        let record = ContextCompactionRecord(sourceMessageIDs: [rows[0].id], sourceDigest: "owner",
            beforeEstimatedTokens: 100, afterEstimatedTokens: 40)
        try await fixture.intelligence.saveCompaction(runID: fixture.runID, record: record,
            summary: ContextHistorySnapshot.automaticPrefix + "[Context compaction notice]\nHistorical summary: owner only")
        let raw = rows.map { ConversationMessage(id: $0.id, role: $0.role, content: $0.content) }
        let other = try await fixture.intelligence.applyingCompactions(raw, conversationID: UUID())
        #expect(other == raw)
    }
}
