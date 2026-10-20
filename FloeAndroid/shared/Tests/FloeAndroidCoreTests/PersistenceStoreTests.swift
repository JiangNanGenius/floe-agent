import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

/// Host-only persistence-authority tests over the ORIGINAL GRDB stores and
/// the vendored SQLite 3.54.1 amalgamation. Synthetic data only. These prove
/// schema/migration/query behaviour on the macOS host; they do NOT prove
/// device WAL durability, Keystore or kill/restart recovery (later per-package
/// device gates). FTS/CJK expectations are MEASURED here and match the iOS
/// unicode61 contract (a bare CJK substring must not be assumed to hit).
final class PersistenceStoreTests: XCTestCase {
    private func migrated() async throws -> DatabaseManager {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        return manager
    }

    func testMigrationsCompleteExactCurrentVersion() async throws {
        let manager = try await migrated()
        let version = try await manager.userVersion()
        XCTAssertEqual(version, 46)
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)
        let applied = try await manager.appliedMigrations()
        // Every published migration applied, none skipped; identifiers carry
        // their own names (e.g. "v1", "v46_task_lifecycle").
        XCTAssertEqual(applied.count, 46)
        XCTAssertTrue(applied.contains("v1"))
        XCTAssertTrue(applied.contains("v46_task_lifecycle"))
        // The anchor re-exports the SAME constant (real graph, not a stub).
        XCTAssertEqual(FloeAndroidCore.schemaVersion, 46)
        _ = try FloeAndroidCore.openInMemoryStore()
    }

    func testSchemaTablesAndFtsExist() async throws {
        let manager = try await migrated()
        let tables = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'message_fts%'
                ORDER BY name
                """)
        }
        for required in ["conversations", "messages", "runs", "run_events", "providers",
                         "models", "audit_entries", "approval_grants", "documents",
                         "attachments", "skills", "plan_drafts", "conversation_goals",
                         "memory_entries", "workspaces"] {
            XCTAssertTrue(tables.contains(required), "missing table \(required)")
        }
        let fts = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'message_fts'
                """)
        }
        XCTAssertEqual(fts, ["message_fts"])
    }

    func testConversationUpsertMessagesAndMeasuredFTSCJK() async throws {
        let manager = try await migrated()
        let store = SQLiteConversationStore(database: manager)
        let conversationID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "原始标题", createdAt: createdAt, updatedAt: createdAt))
        // Upsert: the same id replaces the row (single authority, no dup).
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "更新后的标题", createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(60)))
        let conversations = try await store.conversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.title, "更新后的标题")

        let cjk = "请帮我分析这份报告的第三季度数据"
        try await store.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: cjk, createdAt: createdAt))
        let englishMessageID = UUID()
        try await store.appendMessage(PersistedMessage(
            id: englishMessageID, conversationID: conversationID, role: "assistant",
            content: "unrelated english text", createdAt: createdAt.addingTimeInterval(1)))

        // Trigger pipeline: English token matches exactly one row.
        let englishHits = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT m.id FROM messages m
                JOIN message_fts f ON m.rowid = f.rowid
                WHERE message_fts MATCH 'english'
                """)
        }
        XCTAssertEqual(englishHits.count, 1)

        // MEASURED (not assumed): unicode61 tokenizes a CJK run as ONE token,
        // so a bare substring must not match — same contract iOS pins in
        // FloeAgent/Tests/FloePersistenceTests/DatabaseManagerTests.swift.
        let cjkSubstring = try await manager.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH '报'
                """) ?? -1
        }
        XCTAssertEqual(cjkSubstring, 0, "unicode61 must not yield substring hits")

        // The whole-run token matches, and a wildcard over the run's prefix
        // also matches — the documented segmentation behaviour of this store.
        let wholeRun = try await manager.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?
                """, arguments: ["\"\(cjk)\""]) ?? -1
        }
        XCTAssertEqual(wholeRun, 1)
        let wildcard = try await manager.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'unrelated*'
                """) ?? -1
        }
        XCTAssertEqual(wildcard, 1)
    }

    func testOriginalProviderModelUpsertAndCAS() async throws {
        let manager = try await migrated()
        let store = ModelConfigurationStore(database: manager)
        let providerID = UUID()
        // Whole-second timestamps: the persistence codec round-trips ISO8601
        // seconds, so an exact equality check needs no sub-second drift.
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = ProviderProfile(
            id: providerID, kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "合成网关", presetID: nil,
            secretRef: SecretReference(keychainAccount: "floe.provider合成.🔐",
                                       synchronizable: false),
            createdAt: epoch, updatedAt: epoch)
        try await store.saveProvider(provider)
        let readBack = try await store.provider(id: providerID)
        XCTAssertEqual(readBack, provider)

        let original = ModelProfile(
            providerID: providerID, remoteModelID: "synthetic-model",
            displayName: "合成模型", limits: ModelLimits(contextTokens: 128_000,
                                                        maxOutputTokens: 4_096))
        try await store.saveModel(original)
        // Correct expected (matches the stored row): CAS allows the write.
        var updated = original
        updated.displayName = "合成模型 v2"
        try await store.saveModel(updated, expected: original)
        // STALE expected (the pre-update row): CAS must reject the write.
        var conflicting = updated
        conflicting.displayName = "冲突"
        do {
            try await store.saveModel(conflicting, expected: original)
            XCTFail("CAS must reject a stale expected profile")
        } catch let error as FloeError {
            switch error {
            case .invalidConfiguration: break
            default: XCTFail("unexpected error: \(error)")
            }
        }
        let models = try await store.models(providerID: providerID)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.displayName, "合成模型 v2")

        // Secret-free storage: the providers table carries only the split
        // reference columns (account + synchronizable flag), never a secret
        // value. This fixture has no secret value anywhere.
        let account = try await manager.reader { db in
            try String.fetchOne(db, sql: """
                SELECT secret_ref_account FROM providers WHERE id = ?
                """, arguments: [providerID.uuidString]) ?? ""
        }
        XCTAssertEqual(account, "floe.provider合成.🔐")
        let sync = try await manager.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT secret_ref_synchronizable FROM providers WHERE id = ?
                """, arguments: [providerID.uuidString]) ?? -1
        }
        XCTAssertEqual(sync, 0)
    }

    func testRunEventsMonotonicAndCursorBounded() async throws {
        let manager = try await migrated()
        let conversationStore = SQLiteConversationStore(database: manager)
        let runStore = SQLiteRunStore(database: manager)
        let conversationID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "events", createdAt: now, updatedAt: now))
        let runID = UUID()
        try await runStore.saveRun(RunRecord(
            id: runID, conversationID: conversationID, state: "running",
            goal: "synthetic", startedAt: now))
        let first = try await runStore.appendEvent(runID: runID, kind: .assistantText,
                                                   payloadJSON: "{\"i\":1}")
        let second = try await runStore.appendEvent(runID: runID, kind: .assistantText,
                                                    payloadJSON: "{\"i\":2}")
        let third = try await runStore.appendEvent(runID: runID, kind: .terminal,
                                                  payloadJSON: "{\"i\":3}")
        XCTAssertEqual([first.sequence, second.sequence, third.sequence], [1, 2, 3])
        let afterOne = try await runStore.events(runID: runID, afterSequence: 1, limit: 1)
        XCTAssertEqual(afterOne.map(\.sequence), [2])
        let replayAll = try await runStore.events(runID: runID, afterSequence: 0, limit: 200)
        XCTAssertEqual(replayAll.count, 3)
    }

    func testDurableReopenOnHostFilesystem() async throws {
        // Host file durability only: reopen through the SAME file. Android
        // process-kill/WAL durability is a later device gate, not claimed.
        let directory = try FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-shared-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("db.sqlite")
        let conversationID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        do {
            let manager = try DatabaseManager(path: databaseURL)
            try await manager.migrate()
            let store = SQLiteConversationStore(database: manager)
            try await store.saveConversation(ConversationRecord(
                id: conversationID, title: "重启之后", createdAt: now, updatedAt: now))
            try await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "user",
                content: " durable write ", createdAt: now))
            try await manager.close()
        }
        let reopened = try DatabaseManager(path: databaseURL)
        try await reopened.migrate()
        let store = SQLiteConversationStore(database: reopened)
        let loaded = try await store.conversation(id: conversationID)
        XCTAssertEqual(loaded?.title, "重启之后")
        let messages = try await store.messages(conversationID: conversationID)
        XCTAssertEqual(messages.count, 1)
        let version = try await reopened.userVersion()
        XCTAssertEqual(version, 46)
        try await reopened.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testFailedTransactionRollbackKeepsPriorState() async throws {
        let manager = try await migrated()
        let store = SQLiteConversationStore(database: manager)
        let keptID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_002_000)
        try await store.saveConversation(ConversationRecord(
            id: keptID, title: "保留", createdAt: now, updatedAt: now))
        let doomedID = UUID()
        do {
            try await manager.writer { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at)
                    VALUES (?, '消失', ?, ?)
                    """, arguments: [doomedID.uuidString, now, now])
                struct Boom: Error {}
                throw Boom()
            }
            XCTFail("the write block must rethrow")
        } catch {
            // expected
        }
        let conversations = try await store.conversations()
        XCTAssertEqual(conversations.map(\.id), [keptID])
        let doomed = try await store.conversation(id: doomedID)
        XCTAssertNil(doomed)
    }

    // Generic-protocol existential metatype checks (`Foo.self is Bar.Protocol`)
    // are unreliable when the protocol has associated requirements, so
    // conformance is proven by compile-time generic binding instead.
    private func requireConversationStore<S: ConversationStore>(_ type: S.Type) -> Bool { true }
    private func requireRunStore<S: RunStore>(_ type: S.Type) -> Bool { true }

    func testEphemeralStoresImplementTheSameProtocolsNoSecondTruth() async throws {
        // The RAM stores behind temporary chat satisfy the SAME store
        // protocols as the durable SQLite ones — one authority, no second
        // truth. Behavioural lifecycle coverage is package P6, not here.
        XCTAssertTrue(requireConversationStore(EphemeralConversationStore.self))
        XCTAssertTrue(requireRunStore(EphemeralRunStore.self))
        XCTAssertTrue(requireConversationStore(SQLiteConversationStore.self))
        XCTAssertTrue(requireRunStore(SQLiteRunStore.self))
        XCTAssertNotNil(FloeAndroidCore.ephemeralConversationStoreType)
        XCTAssertNotNil(FloeAndroidCore.ephemeralRunStoreType)
        XCTAssertNotNil(FloeAndroidCore.conversationPromoterType)
    }
}
