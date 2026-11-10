// FloePersistenceTests — Schema v1 build, cascades, FTS5, user_version,
// writer serialization, audit append-only.

import Foundation
import Testing
@testable import FloePersistence
import GRDB
import FloeCore

@Suite("FloePersistence.DatabaseManager")
struct DatabaseManagerTests {

    private func makeManager() async throws -> DatabaseManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-test-\(UUID().uuidString).sqlite")
        let manager = try DatabaseManager(path: url)
        try await manager.migrate()
        return manager
    }

    @Test("Migrations create app and sync tables plus FTS virtual table")
    func v1CreatesSchema() async throws {
        let manager = try await makeManager()
        let tables = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'message_fts%'
                ORDER BY name
                """)
        }
        let required = Set([
            "app_settings", "approval_grants", "approvals", "attachments", "audit_entries", "checkpoints",
            "config_sync_metadata", "conversations", "documents", "hosts", "images", "known_hosts",
            "message_parts", "messages", "model_preferences", "models", "providers",
            "remote_sessions", "run_errors", "run_events", "run_usage", "runs",
            "sync_engine_state", "tool_calls", "vnc_sessions",
            "workspace_conversations", "workspace_recent_files", "workspaces",
            "plan_drafts", "conversation_goals", "memory_entries", "skills",
            "browser_sessions", "browser_tabs", "context_compactions", "run_relations"
        ])
        #expect(required.isSubset(of: Set(tables)))
        let fts = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'message_fts'
                """)
        }
        #expect(fts == ["message_fts"])
    }

    @Test("user_version aligns with applied migrations")
    func userVersionAligned() async throws {
        let manager = try await makeManager()
        let version = try await manager.userVersion()
        #expect(version == DatabaseManager.currentSchemaVersion)
        let applied = try await manager.appliedMigrations()
        #expect(applied.contains("v1"))
        #expect(applied.contains("v2"))
        #expect(applied.contains("v3"))
        #expect(applied.contains("v4"))
        #expect(applied.contains("v5"))
        #expect(applied.contains("v6"))
        #expect(applied.contains("v7"))
    }

    @Test("Migration is idempotent (second migrate is a no-op)")
    func idempotentMigration() async throws {
        let manager = try await makeManager()
        try await manager.migrate()
        let version = try await manager.userVersion()
        #expect(version == DatabaseManager.currentSchemaVersion)
    }

    @Test("Foreign key cascade: deleting a conversation removes messages")
    func foreignKeyCascade() async throws {
        let manager = try await makeManager()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES ('c1', 'test', '2024-01-01T00:00:00Z', '2024-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES ('m1', 'c1', 'user', 'hello', '2024-01-01T00:00:00Z')
                """)
        }
        var count = try await manager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
        #expect(count == 1)
        try await manager.writer { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = 'c1'")
        }
        count = try await manager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
        #expect(count == 0)
    }

    @Test("FTS5 trigger sync and tokenization contract")
    func ftsQuery() async throws {
        let manager = try await makeManager()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES ('c1', 't', '2024-01-01T00:00:00Z', '2024-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES ('m1', 'c1', 'user', '请帮我分析这份报告的第三季度数据', '2024-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES ('m2', 'c1', 'assistant', 'unrelated english text', '2024-01-01T00:00:01Z')
                """)
        }
        // FTS5 unicode61 tokenizes a CJK run as ONE token, so a bare CJK
        // substring query matches nothing. Pin this contract: CJK search
        // needs a segmenting tokenizer or wildcard queries (M2+ decision).
        let cjkHits = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT m.id FROM messages m
                JOIN message_fts f ON m.rowid = f.rowid
                WHERE message_fts MATCH '报'
                """)
        }
        #expect(cjkHits.isEmpty)

        // The trigger pipeline itself works: English tokens match the
        // exact row synced from messages.
        let englishHits = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT m.id FROM messages m
                JOIN message_fts f ON m.rowid = f.rowid
                WHERE message_fts MATCH 'english'
                """)
        }
        #expect(englishHits == ["m2"])
    }

    @Test("Concurrent writers serialize without error")
    func concurrentWritersSerialize() async throws {
        let manager = try await makeManager()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES ('c1', 't', '2024-01-01T00:00:00Z', '2024-01-01T00:00:00Z')
                """)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await manager.writer { db in
                        try db.execute(
                            sql: """
                                INSERT INTO messages (id, conversation_id, role, content, created_at)
                                VALUES (?, 'c1', 'user', ?, '2024-01-01T00:00:00Z')
                                """,
                            arguments: ["m\(index)", "msg \(index)"]
                        )
                    }
                }
            }
            try await group.waitForAll()
        }
        let count = try await manager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
        #expect(count == 20)
    }

    @Test("audit_entries rejects UPDATE and DELETE (append-only)")
    func auditAppendOnly() async throws {
        let manager = try await makeManager()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO audit_entries
                    (id, sequence, timestamp, run_id, model_remote_id, tool_name,
                     target, policy_used, decision, exit_status,
                     output_digest_sha256, prev_hash_sha256, entry_hash_sha256)
                VALUES ('a1', 1, '2024-01-01T00:00:00Z', 'r1', 'm', 't', '', '', '', NULL, '',
                        '0000000000000000000000000000000000000000000000000000000000000000',
                        '1111111111111111111111111111111111111111111111111111111111111111')
                """)
        }
        await #expect(throws: (any Error).self) {
            try await manager.writer { db in
                try db.execute(sql: "UPDATE audit_entries SET decision = 'x' WHERE id = 'a1'")
            }
        }
        await #expect(throws: (any Error).self) {
            try await manager.writer { db in
                try db.execute(sql: "DELETE FROM audit_entries WHERE id = 'a1'")
            }
        }
        // INSERT still allowed.
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO audit_entries
                    (id, sequence, timestamp, run_id, model_remote_id, tool_name,
                     target, policy_used, decision, exit_status,
                     output_digest_sha256, prev_hash_sha256, entry_hash_sha256)
                VALUES ('a2', 2, '2024-01-01T00:00:01Z', 'r1', 'm', 't', '', '', '', NULL, '',
                        '1111111111111111111111111111111111111111111111111111111111111111',
                        '2222222222222222222222222222222222222222222222222222222222222222')
                """)
        }
    }
}

private final class SuspensionCallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private struct SuspensionDatabaseFixture: Sendable {
    let manager: DatabaseManager
    let directory: URL

    init() throws {
        let base = ProcessInfo.processInfo.environment["FLOE_RQ26_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("rq26-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Use the production file-backed WAL pool. GRDB's named in-memory
        // queue initializer intentionally skips suspension observers.
        manager = try DatabaseManager(path: directory.appendingPathComponent("store.sqlite"))
    }

    func close() async throws {
        try await manager.close()
        try FileManager.default.removeItem(at: directory)
    }
}

/// These exercise process-wide GRDB notifications. Run this suite as a
/// focused group, rather than concurrently with unrelated database suites.
@Suite("Database suspension generation and fan-out", .serialized)
struct DatabaseSuspensionRaceTests {
    @Test("A late fence cannot override a newer resume or its successful write")
    func lateFenceAfterResumeIsRejected() async throws {
        DatabaseManager.resumeConnections()
        defer { DatabaseManager.resumeConnections() }
        let fixture = try SuspensionDatabaseFixture()
        let manager = fixture.manager
        let stale = DatabaseManager.suspensionGeneration()
        DatabaseManager.suspendConnections()
        DatabaseManager.resumeConnections()
        #expect(!DatabaseManager.suspendConnections(ifCurrent: stale))
        #expect(!DatabaseManager.connectionsAreSuspended)
        try await manager.writer { db in try db.execute(sql: "CREATE TABLE ready(value INTEGER)") }
        try await fixture.close()
    }

    @Test("A genuine current background fence still aborts before the write closure, without replay")
    func actualSuspensionKeepsAbortAndSingleWrite() async throws {
        DatabaseManager.resumeConnections()
        defer { DatabaseManager.resumeConnections() }
        let fixture = try SuspensionDatabaseFixture()
        let manager = fixture.manager
        try await manager.writer { db in try db.execute(sql: "CREATE TABLE once_only(value INTEGER)") }
        let calls = SuspensionCallCount()
        #expect(DatabaseManager.suspendConnections(ifCurrent: DatabaseManager.suspensionGeneration()))
        do {
            try await manager.writer { db in
                calls.increment()
                try db.execute(sql: "INSERT INTO once_only VALUES (1)")
            }
            Issue.record("A genuine suspension admitted a transaction")
        } catch let error as DatabaseError {
            #expect(error.resultCode == .SQLITE_ABORT || error.resultCode == .SQLITE_INTERRUPT)
        }
        #expect(calls.count == 0)
        DatabaseManager.resumeConnections()
        try await manager.writer { db in
            calls.increment()
            try db.execute(sql: "INSERT INTO once_only VALUES (1)")
        }
        #expect(calls.count == 1)
        let count = try await manager.reader { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM once_only") }
        #expect(count == 1)
        try await fixture.close()
    }

    @Test("A manager opened during a fence inherits it, then becomes usable after resume")
    func newlyOpenedConnectionInheritsSuspension() async throws {
        DatabaseManager.resumeConnections()
        defer { DatabaseManager.resumeConnections() }
        DatabaseManager.suspendConnections()
        let fixture = try SuspensionDatabaseFixture()
        let manager = fixture.manager
        await #expect(throws: DatabaseError.self) {
            try await manager.writer { db in try db.execute(sql: "CREATE TABLE should_wait(value INTEGER)") }
        }
        DatabaseManager.resumeConnections()
        try await manager.writer { db in try db.execute(sql: "CREATE TABLE should_wait(value INTEGER)") }
        try await fixture.close()
    }

    @Test("A resume racing the middle of suspend fan-out leaves both actual queues usable")
    func concurrentFanoutDoesNotLeaveTailSuspended() async throws {
        DatabaseManager.resumeConnections()
        defer { DatabaseManager.resumeConnections() }
        let firstFixture = try SuspensionDatabaseFixture()
        let first = firstFixture.manager
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let resumed = DispatchSemaphore(value: 0)
        let once = SuspensionCallCount()
        let token = NotificationCenter.default.addObserver(forName: Database.suspendNotification, object: nil, queue: nil) { _ in
            once.increment()
            if once.count == 1 {
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        defer { release.signal(); NotificationCenter.default.removeObserver(token) }
        // Registered after the pausing observer: an uncoordinated old suspend
        // post can reach this queue after a concurrent resume already ended.
        let secondFixture = try SuspensionDatabaseFixture()
        let second = secondFixture.manager
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let work = DispatchGroup()
                work.enter()
                DispatchQueue.global().async { DatabaseManager.suspendConnections(); work.leave() }
                guard entered.wait(timeout: .now() + 3) == .success else {
                    release.signal(); continuation.resume(returning: false); return
                }
                work.enter()
                DispatchQueue.global().async { DatabaseManager.resumeConnections(); resumed.signal(); work.leave() }
                // Old code can complete resume before the tail of suspend.
                // Ordered code waits until this one bounded pause is released.
                _ = resumed.wait(timeout: .now() + 0.1)
                release.signal()
                continuation.resume(returning: work.wait(timeout: .now() + 3) == .success)
            }
        }
        #expect(finished)
        #expect(!DatabaseManager.connectionsAreSuspended)
        try await first.writer { db in try db.execute(sql: "CREATE TABLE first_ready(value INTEGER)") }
        try await second.writer { db in try db.execute(sql: "CREATE TABLE second_ready(value INTEGER)") }
        try await firstFixture.close()
        try await secondFixture.close()
    }

    @Test("Storage-full and other SQL failures retain their original error and execute once")
    func realStorageErrorsAreNotRetriedOrRelabelled() async throws {
        DatabaseManager.resumeConnections()
        defer { DatabaseManager.resumeConnections() }
        let fixture = try SuspensionDatabaseFixture()
        let manager = fixture.manager
        let full = SuspensionCallCount()
        let calls = SuspensionCallCount()
        let token = NotificationCenter.default.addObserver(forName: StorageSpaceFailure.notification, object: nil, queue: nil) { _ in full.increment() }
        defer { NotificationCenter.default.removeObserver(token) }
        for code in [ResultCode.SQLITE_FULL, .SQLITE_CORRUPT] {
            do {
                try await manager.writer { _ in
                    calls.increment()
                    throw DatabaseError(resultCode: code, message: "owned fixture")
                }
                Issue.record("Expected the original storage error")
            } catch let error as DatabaseError {
                #expect(error.resultCode == code)
            }
        }
        #expect(calls.count == 2)
        #expect(full.count == 1)
        try await fixture.close()
    }
}
