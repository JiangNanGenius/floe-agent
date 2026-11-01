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
}
