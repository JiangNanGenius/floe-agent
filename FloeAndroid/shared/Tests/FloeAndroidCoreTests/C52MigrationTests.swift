// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import GRDB
@testable import FloePersistence

final class C52MigrationTests: XCTestCase {
    func testProductionRegistryInstallsCoordinatedSchemaAndKeepsDataOnRepeat() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let taskID = UUID().uuidString
        try await database.writer { db in
            try db.execute(sql: "INSERT INTO conversations (id,title,created_at,updated_at,purpose,pinned_at) VALUES (?, 'saved', '2026-01-01', '2026-01-01', 'ordinary', '2026-01-02')", arguments: [taskID])
            for name in ["calendar_todos", "task_execution_targets", "task_execution_target_migrations",
                         "task_run_execution_targets", "task_remote_command_receipts", "task_continuity_pauses", "mail_accounts"] {
                XCTAssertTrue(try db.tableExists(name), name)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 52)
        }
        try await database.migrate()
        try await database.reader { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT pinned_at FROM conversations WHERE id = ?", arguments: [taskID]), "2026-01-02")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v52_android_code_closure'"), 1)
        }
        try await database.close()
    }

    func testCoordinatedMigrationFailureRollsBackAllNewTablesAndVersion() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = 51")
            try db.execute(sql: "CREATE TABLE conversations(id TEXT PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE runs(id TEXT PRIMARY KEY)")
            // Force the calendar index creation to fail: an existing view
            // cannot acquire a table index. No later table may leak through.
            try db.execute(sql: "CREATE VIEW calendar_todos AS SELECT 0 AS completed, NULL AS due_at")
        }
        var migrator = DatabaseMigrator()
        V52AndroidCodeClosure.register(into: &migrator)
        XCTAssertThrowsError(try migrator.migrate(queue))
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 51)
            XCTAssertFalse(try db.tableExists("task_execution_targets"))
            XCTAssertFalse(try db.tableExists("task_continuity_pauses"))
            XCTAssertFalse(try db.tableExists("calendar_todos"))
        }
    }
}
