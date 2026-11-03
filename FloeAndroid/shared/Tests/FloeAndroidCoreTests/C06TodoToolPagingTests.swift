// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeTools
@testable import FloeAndroidCore

final class C06TodoToolPagingTests: XCTestCase {
    func testLongRecordPagesRemainCompleteAndReachEveryID() throws {
        let rows = (0..<25).map { index in
            C06TodoRecord(title: "item-\(index) " + String(repeating: "x", count: 496))
        }
        var offset = 0
        var seen = Set<UUID>()
        while offset < rows.count {
            let text = C06TodoListTool.pageSummary(
                rows: Array(rows.dropFirst(offset)), total: rows.count, offset: offset
            )
            let delivered = ToolExecutionOutput(digesting: text)
            XCTAssertEqual(delivered.summary, text)
            XCTAssertLessThanOrEqual(text.count, 4_096)
            let field = try XCTUnwrap(text.split(separator: "\n").first?
                .split(separator: " ").first { $0.hasPrefix("nextOffset=") })
            for row in rows where text.contains("id=\(row.id.uuidString.lowercased()) ") {
                XCTAssertTrue(seen.insert(row.id).inserted)
                XCTAssertTrue(text.contains("title=\(String(reflecting: row.title)) completed=false"))
            }
            let value = String(field.dropFirst("nextOffset=".count))
            if value == "none" { break }
            let next = try XCTUnwrap(Int(value))
            XCTAssertGreaterThan(next, offset)
            offset = next
        }
        XCTAssertEqual(seen, Set(rows.map(\.id)))
    }

    func testEmbeddedNewlineDoesNotForgeAnotherRecordLine() {
        let row = C06TodoRecord(title: "first\nid=fake")
        let text = C06TodoListTool.pageSummary(rows: [row], total: 1, offset: 0)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.contains("nextOffset=none"))
        XCTAssertTrue(text.contains(String(reflecting: row.title)))
    }
    func testHostPagesFitWireBudgetAndReassembleEveryRecord() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = (0..<100).map { index in
            C06TodoRecord(title: "item-\(index) " + String(repeating: "x", count: 496),
                          dueAt: now, dueTimeZone: "America/Los_Angeles",
                          recurrence: C06TodoRecurrence(kind: .monthly, interval: 1, until: now),
                          reminderMinutesBefore: 15, ownerConversationID: UUID(),
                          ownerTaskID: UUID(), ownerEnvironmentID: String(repeating: "e", count: 128),
                          lastReminderAt: now, lastReminderOccurrence: String(repeating: "o", count: 64))
        }
        var offset = 0
        var seen: [String] = []
        while offset < rows.count {
            var page = C06CalendarBridge.todoListProjection(
                rows: Array(rows.dropFirst(offset)), total: rows.count,
                offset: offset, includeCompleted: true
            )
            let emitted = try XCTUnwrap(page["todos"] as? [[String: Any]])
            XCTAssertFalse(emitted.isEmpty)
            page["ok"] = true
            page["requestID"] = String(repeating: "r", count: 128)
            page["operation"] = "c06.todo.list"
            page["schema"] = C06CalendarWire.schema
            page["version"] = 13
            let bytes = try JSONSerialization.data(withJSONObject: page)
            XCTAssertLessThanOrEqual(bytes.count, C06CalendarWire.maximumResponseBytes)
            seen += try emitted.map { try XCTUnwrap($0["id"] as? String) }
            offset += emitted.count
            if offset < rows.count { XCTAssertEqual(page["nextOffset"] as? Int, offset) }
        }
        XCTAssertEqual(seen, rows.map { $0.id.uuidString.lowercased() })
    }

}
