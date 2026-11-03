// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import GRDB
import FloeAndroidDataExchange
#if canImport(FloeAndroidCore)
@testable import FloeAndroidCore
#else
@testable import C07RestoreAdapterQualification
#endif

final class C07ModelPreferenceRollbackTests: XCTestCase {
    private enum Seeded: Error { case writerFailure }
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE model_preferences(id TEXT PRIMARY KEY, default_agent_model_id TEXT, general_auxiliary_llm_model_id TEXT, sync_revision INTEGER NOT NULL, updated_at TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO model_preferences VALUES ('default', 'original', NULL, 0, 'initial')")
        }
        return queue
    }
    private func merged(_ queue: DatabaseQueue, id: UUID) throws {
        try queue.write { db in
            let before = try C07ModelPreferenceRollback.capture(db)
            try db.execute(sql: "UPDATE model_preferences SET general_auxiliary_llm_model_id='restored', sync_revision=sync_revision+1, updated_at='restore'")
            try C07ModelPreferenceRollback.record(before: before, restoreID: id, db: db)
        }
    }
    func testRollbackUsesActualWriterBaselineNotEarlierPlanningSnapshot() throws {
        let queue = try database(); let id = UUID()
        try queue.write { db in try db.execute(sql: "UPDATE model_preferences SET default_agent_model_id='new-user-choice', sync_revision=1, updated_at='user'") }
        try merged(queue, id: id)
        try queue.write { db in try C07ModelPreferenceRollback.rollback(restoreID: id, legacyCount: 1, db: db) }
        try queue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT default_agent_model_id FROM model_preferences"), "new-user-choice")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT general_auxiliary_llm_model_id FROM model_preferences"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT sync_revision FROM model_preferences"), 1)
        }
    }
    func testNewerUserEditRefusesDestructiveRollback() throws {
        let queue = try database(); let id = UUID(); try merged(queue, id: id)
        try queue.write { db in try db.execute(sql: "UPDATE model_preferences SET default_agent_model_id='latest-user-choice', sync_revision=sync_revision+1") }
        XCTAssertThrowsError(try queue.write { db in
            try C07ModelPreferenceRollback.rollback(restoreID: id, legacyCount: 1, db: db)
            try db.execute(sql: "DELETE FROM model_preferences")
        })
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT default_agent_model_id FROM model_preferences") }, "latest-user-choice")
    }
    func testFailedWriterNeverPublishesRollbackReceipt() throws {
        let queue = try database(); let id = UUID()
        XCTAssertThrowsError(try queue.write { db in
            let before = try C07ModelPreferenceRollback.capture(db)
            try db.execute(sql: "UPDATE model_preferences SET default_agent_model_id='not-committed'")
            try C07ModelPreferenceRollback.record(before: before, restoreID: id, db: db)
            throw Seeded.writerFailure
        })
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM settings"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT default_agent_model_id FROM model_preferences"), "original")
        }
    }
    func testRepeatedRollbackCannotUndoLaterUserChoice() throws {
        let queue = try database(); let id = UUID(); try merged(queue, id: id)
        try queue.write { try C07ModelPreferenceRollback.rollback(restoreID: id, legacyCount: 1, db: $0) }
        try queue.write { try $0.execute(sql: "UPDATE model_preferences SET default_agent_model_id='after-rollback', sync_revision=sync_revision+1") }
        try queue.write { try C07ModelPreferenceRollback.rollback(restoreID: id, legacyCount: 1, db: $0) }
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT default_agent_model_id FROM model_preferences") }, "after-rollback")
    }
    func testLegacyUnknownMutationPreservesPreferences() throws {
        let queue = try database()
        XCTAssertThrowsError(try queue.write { try C07ModelPreferenceRollback.rollback(restoreID: UUID(), legacyCount: 1, db: $0) })
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT default_agent_model_id FROM model_preferences") }, "original")
    }
}
