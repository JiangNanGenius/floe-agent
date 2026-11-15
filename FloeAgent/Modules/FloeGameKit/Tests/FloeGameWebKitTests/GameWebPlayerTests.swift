// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameWebKit

/// The same real-engine assertions run inside a native AppKit event loop.
/// Original hidden-document XCTest failures are retained as qualification evidence.
@MainActor final class GameWebPlayerTests: XCTestCase {
    func testRealPhaserCreationEditingPlayingSavingAndRestarting() async throws {
#if os(macOS)
        let environment = ProcessInfo.processInfo.environment
        let executable = try XCTUnwrap(environment["FLOE_GAME_QUALIFICATION_BINARY"], "Build the explicit native qualification host")
        let output = try XCTUnwrap(environment["FLOE_GAME_TEST_EVIDENCE"])
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable); child.environment = environment
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            child.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try child.run() } catch { continuation.resume(throwing: error) }
        }
        let result = try Data(contentsOf: URL(fileURLWithPath: output).appendingPathComponent("runtime-result.json"))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(status, 0, String(decoding: result, as: UTF8.self))
        XCTAssertEqual(record["result"] as? String, "passed")
        let steps = try XCTUnwrap(record["steps"] as? [String])
        XCTAssertTrue(steps.contains("real-frames-input-score-screenshot-and-durable-progress"))
        XCTAssertTrue(steps.contains("external-network-csp-violation-proved"))
        XCTAssertTrue(steps.contains("stopped-restarted-and-restored-durable-progress"))
        XCTAssertTrue(steps.contains("stopped-runtime-no-longer-exists"))
#else
        XCTFail("Run this native host qualification on macOS; iOS object compilation is separate")
#endif
    }
}
