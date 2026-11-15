// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import FloeGameExecutionBridge
@testable import FloeApp

/// Source-only contract for the project's one-slot launch lifecycle. The real
/// session gate is exercised without starting a player or engine.
final class GameLaunchSerialGateContractTests: XCTestCase {
    func testOverlappingLaunchIsRejectedAndFinishOpensTheSlot() throws {
        var gate = GameLaunchSerialGate()
        let first = try gate.begin()
        XCTAssertTrue(gate.isCurrent(first))
        XCTAssertThrowsError(try gate.begin()) { error in
            XCTAssertEqual(error as? GameWorkspaceRegistryError,
                           GameWorkspaceRegistryError.launchInProgress)
        }
        gate.finish(first)
        XCTAssertFalse(gate.isCurrent(first))
        let second = try gate.begin()
        XCTAssertTrue(gate.isCurrent(second))
        XCTAssertNotEqual(first, second)
    }

    func testCancelMakesALateCompletionStale() throws {
        var gate = GameLaunchSerialGate()
        let old = try gate.begin()
        gate.cancel()
        XCTAssertFalse(gate.isCurrent(old))
        let replacement = try gate.begin()
        XCTAssertTrue(gate.isCurrent(replacement))
        XCTAssertFalse(gate.isCurrent(old))
    }

    func testStaleFinishCannotClearANewerLaunch() throws {
        var gate = GameLaunchSerialGate()
        let first = try gate.begin()
        gate.finish(first)
        let second = try gate.begin()
        gate.finish(first) // stale completion
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testStopUnconfirmedIsAnActionableError() {
        let error = GameWorkspaceRegistryError.stopUnconfirmed
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    func testWorkStopUnconfirmedIsDistinctAndNamesTheOwnedWork() {
        let error = GameWorkspaceRegistryError.workStopUnconfirmed(
            "The build has not confirmed stopping.")
        XCTAssertNotEqual(error, GameWorkspaceRegistryError.stopUnconfirmed)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("build") || description.contains("构建"))
        XCTAssertTrue(description.contains("The build has not confirmed stopping."))
    }

    func testUnconfirmedCloseRetainsOwnedOperationIDs() {
        let outcome = GameWorkspaceCloseOutcome.unconfirmed(
            ids: ["build:fixture", "ci:42"],
            detail: "The remote job did not reach a terminal state.")
        XCTAssertFalse(outcome.isConfirmed)
        XCTAssertEqual(outcome.ownedOperations, ["build:fixture", "ci:42"])
        XCTAssertTrue(GameWorkspaceCloseOutcome.confirmed.isConfirmed)
    }
}
#endif
