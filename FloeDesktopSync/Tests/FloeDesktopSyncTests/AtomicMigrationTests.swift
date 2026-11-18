import Foundation
import XCTest
@testable import FloeDesktopSync

final class AtomicMigrationTests: XCTestCase {
    func testCorruptV4NeverCommitsVersionOrNewTables() async throws {
        let db = try TestDatabase(); defer { db.remove() }
        let device = try TestIDs.device(1), task = try TestIDs.task(7), entity = try TestIDs.entity(7)
        let initial = try db.makeStore(deviceID: device)
        _ = try await initial.commitLocalRecord(try SyncRecord.test(entityID: entity, revision: 1,
            originDeviceID: device, taskID: task, payload: .object(["title": .string("synthetic retained")])) )
        await initial.close()
        let old = try db.rawConnection()
        try old.execute("BEGIN IMMEDIATE")
        do {
            for sql in [
                "DROP TABLE incremental_receipts",
                "DROP TABLE sync_scope_authorizations",
                "ALTER TABLE records DROP COLUMN base_digest",
                "PRAGMA user_version=4"
            ] { try old.execute(sql) }
            try old.execute("COMMIT")
        } catch { _ = try? old.execute("ROLLBACK"); old.close(); throw error }
        old.close()
        do {
            let unexpected = try db.makeStore(deviceID: device)
            await unexpected.close()
            XCTFail("corrupt v4 should not migrate")
        } catch SyncStoreError.schemaCorrupt(let detail) {
            XCTAssertTrue(detail.contains("records.base_digest"))
        }
        let after = try db.rawConnection(); defer { after.close() }
        XCTAssertEqual(try after.userVersionValue(), 4)
        let query = try after.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('sync_scope_authorizations','incremental_receipts')")
        XCTAssertTrue(try query.step()); XCTAssertEqual(query.int64(0), 0)
        let rows = try after.prepare("SELECT COUNT(*) FROM records WHERE entity_id=?")
        try rows.bind(1, entity.canonical); XCTAssertTrue(try rows.step()); XCTAssertEqual(rows.int64(0), 1)
    }
}
