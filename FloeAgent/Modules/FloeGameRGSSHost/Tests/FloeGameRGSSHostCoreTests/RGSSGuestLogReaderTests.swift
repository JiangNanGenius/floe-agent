// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameRGSSHostCore

final class RGSSGuestLogReaderTests: XCTestCase {
    func testReadsActualBoundedTailInsteadOfPhaseText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("owned.log")
        try Data((String(repeating: "old", count: 10_000) + "LATEST ERROR").utf8).write(to: log)
        let text = try RGSSGuestLogReader.tail(of: log, maximumBytes: 12)
        XCTAssertEqual(text, "LATEST ERROR")
    }

    func testEmptyLogIsEmptyAndInvalidLimitIsRejected() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }
        XCTAssertEqual(try RGSSGuestLogReader.tail(of: log), "")
        XCTAssertThrowsError(try RGSSGuestLogReader.tail(of: log, maximumBytes: 0))
    }

    func testSymlinkCannotReadAnotherFilesContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("other")
        try Data("other project".utf8).write(to: target)
        let link = root.appendingPathComponent("owned.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try RGSSGuestLogReader.tail(of: link))
    }
}
