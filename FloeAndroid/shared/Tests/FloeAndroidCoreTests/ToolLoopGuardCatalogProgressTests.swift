// SPDX-License-Identifier: MPL-2.0
//
// Catalog enumeration stop-scope regressions: the fatal third-listing stop is
// scoped to the current committed-progress epoch, while the whole-turn warning
// and every other loop/failure guard stay unchanged. Private patch only; this
// suite is proposed, not executed by the worker.

import XCTest
import Foundation
import FloeModels
@testable import FloeAgentRuntime

final class ToolLoopGuardCatalogProgressTests: XCTestCase {
    private func call(_ tool: String, _ arguments: String, id: String) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: tool,
            argumentsJSON: Data(arguments.utf8),
            scope: .local
        )
    }

    private func ok(_ call: ToolCall, _ summary: String) -> ToolResult {
        ToolResult(callID: call.id, status: .ok, outputSummary: summary, outputDigest: "")
    }

    private func failed(_ call: ToolCall, _ summary: String) -> ToolResult {
        ToolResult(callID: call.id, status: .failed, outputSummary: summary, outputDigest: "")
    }

    private func record(
        _ guardUnderTest: inout ToolLoopGuard,
        call: ToolCall,
        result: ToolResult,
        isSideEffecting: Bool,
        countsAsProgress: Bool = true
    ) -> ToolLoopGuardrailDecision? {
        guardUnderTest.record(
            call: call,
            result: result,
            isSideEffecting: isSideEffecting,
            countsAsProgress: countsAsProgress
        )
    }

    private func catalog(_ id: String) throws -> ToolCall {
        try call("tools.list", #"{"group":"device"}"#, id: id)
    }

    private func progressWrite(_ id: String) throws -> ToolCall {
        try call("workspace.writeFile", #"{"path":"output/catalog-progress.txt"}"#, id: id)
    }

    private func read(_ path: String, id: String) throws -> ToolCall {
        try call("workspace.readFile", #"{"path":"\#(path)"}"#, id: id)
    }

    /// The observed Full115 failure: two identical `tools.list(group=device)`
    /// calls, real committed side effects, then a third listing. The whole-turn
    /// count still warns, but it must not fatal across the progress epoch.
    func testCatalogListingAfterCommittedProgressWarnsWithoutFatalStop() throws {
        var guardUnderTest = ToolLoopGuard()

        let first = try catalog("catalog-1")
        let firstDecision = record(
            &guardUnderTest,
            call: first,
            result: ok(first, "device page v1"),
            isSideEffecting: false
        )
        XCTAssertNil(firstDecision)

        let second = try catalog("catalog-2")
        let repeatBeforeProgressDecision = record(
            &guardUnderTest,
            call: second,
            result: ok(second, "device page v1"),
            isSideEffecting: false
        )
        let repeatBeforeProgress = try XCTUnwrap(repeatBeforeProgressDecision)
        XCTAssertFalse(repeatBeforeProgress.shouldStop)
        XCTAssertTrue(repeatBeforeProgress.message.contains("already performed earlier in this turn"))

        // A real committed mutation opens a fresh progress epoch.
        let write = try progressWrite("progress-1")
        let writeDecision = record(
            &guardUnderTest,
            call: write,
            result: ok(write, "wrote output/catalog-progress.txt"),
            isSideEffecting: true
        )
        XCTAssertNil(writeDecision)

        let third = try catalog("catalog-3")
        let afterProgressDecision = record(
            &guardUnderTest,
            call: third,
            result: ok(third, "device page v2"),
            isSideEffecting: false
        )
        let afterProgress = try XCTUnwrap(afterProgressDecision)
        XCTAssertFalse(
            afterProgress.shouldStop,
            "the third listing in the user turn must not fatal after real committed progress"
        )
        XCTAssertTrue(afterProgress.message.contains("already performed earlier in this turn"))

        // The reset budget is still a real threshold in the new epoch.
        let fourth = try catalog("catalog-4")
        let secondAfterProgressDecision = record(
            &guardUnderTest,
            call: fourth,
            result: ok(fourth, "device page v2"),
            isSideEffecting: false
        )
        let secondAfterProgress = try XCTUnwrap(secondAfterProgressDecision)
        XCTAssertFalse(secondAfterProgress.shouldStop)

        let fifth = try catalog("catalog-5")
        let thirdAfterProgressDecision = record(
            &guardUnderTest,
            call: fifth,
            result: ok(fifth, "device page v3"),
            isSideEffecting: false
        )
        let thirdAfterProgress = try XCTUnwrap(thirdAfterProgressDecision)
        XCTAssertTrue(
            thirdAfterProgress.shouldStop,
            "three re-listings inside one progress epoch must still stop at the original threshold"
        )
    }

    /// Without any committed progress the original behavior is unchanged:
    /// second listing warns, third listing stops.
    func testSameEpochCatalogListingStillStopsAtOriginalThreshold() throws {
        var guardUnderTest = ToolLoopGuard()

        let first = try catalog("catalog-1")
        let firstDecision = record(
            &guardUnderTest,
            call: first,
            result: ok(first, "device page v1"),
            isSideEffecting: false
        )
        XCTAssertNil(firstDecision)

        let second = try catalog("catalog-2")
        let warningDecision = record(
            &guardUnderTest,
            call: second,
            result: ok(second, "device page v1"),
            isSideEffecting: false
        )
        let warning = try XCTUnwrap(warningDecision)
        XCTAssertFalse(warning.shouldStop)

        let third = try catalog("catalog-3")
        let stoppedDecision = record(
            &guardUnderTest,
            call: third,
            result: ok(third, "device page v1"),
            isSideEffecting: false
        )
        let stopped = try XCTUnwrap(stoppedDecision)
        XCTAssertTrue(stopped.shouldStop)
        XCTAssertTrue(stopped.message.contains("without new committed progress since the last real step"))
    }

    /// A differing read-only observation is new evidence, not progress: it
    /// must not wash the catalog stop budget clean.
    func testChangingReadOnlyObservationsDoNotResetCatalogStopBudget() throws {
        var guardUnderTest = ToolLoopGuard()

        let first = try catalog("catalog-1")
        let firstDecision = record(
            &guardUnderTest,
            call: first,
            result: ok(first, "device page v1"),
            isSideEffecting: false
        )
        XCTAssertNil(firstDecision)

        let readA = try read("a.txt", id: "read-a")
        let readADecision = record(
            &guardUnderTest,
            call: readA,
            result: ok(readA, "alpha"),
            isSideEffecting: false
        )
        XCTAssertNil(readADecision)

        let second = try catalog("catalog-2")
        let warningDecision = record(
            &guardUnderTest,
            call: second,
            result: ok(second, "device page v1"),
            isSideEffecting: false
        )
        let warning = try XCTUnwrap(warningDecision)
        XCTAssertFalse(warning.shouldStop)

        let readB = try read("b.txt", id: "read-b")
        let readBDecision = record(
            &guardUnderTest,
            call: readB,
            result: ok(readB, "beta"),
            isSideEffecting: false
        )
        XCTAssertNil(readBDecision)

        let third = try catalog("catalog-3")
        let stoppedDecision = record(
            &guardUnderTest,
            call: third,
            result: ok(third, "device page v1"),
            isSideEffecting: false
        )
        let stopped = try XCTUnwrap(stoppedDecision)
        XCTAssertTrue(
            stopped.shouldStop,
            "a changed read-only observation must not reset the catalog progress-epoch counter"
        )
    }

    /// A recovered/synthesized `ok` result was not dispatched. Even when its
    /// descriptor is side-effecting, it must not advance the progress epoch.
    func testRecoveredReplayDoesNotResetCatalogStopBudget() throws {
        var guardUnderTest = ToolLoopGuard()

        let first = try catalog("catalog-1")
        let firstDecision = record(
            &guardUnderTest,
            call: first,
            result: ok(first, "device page v1"),
            isSideEffecting: false
        )
        XCTAssertNil(firstDecision)

        let replay = try progressWrite("recovered-1")
        let replayDecision = record(
            &guardUnderTest,
            call: replay,
            result: ok(replay, "wrote output/catalog-progress.txt"),
            isSideEffecting: true,
            countsAsProgress: false
        )
        XCTAssertNil(replayDecision)

        let second = try catalog("catalog-2")
        let warningDecision = record(
            &guardUnderTest,
            call: second,
            result: ok(second, "device page v1"),
            isSideEffecting: false
        )
        let warning = try XCTUnwrap(warningDecision)
        XCTAssertFalse(warning.shouldStop)

        let third = try catalog("catalog-3")
        let stoppedDecision = record(
            &guardUnderTest,
            call: third,
            result: ok(third, "device page v1"),
            isSideEffecting: false
        )
        let stopped = try XCTUnwrap(stoppedDecision)
        XCTAssertTrue(
            stopped.shouldStop,
            "a recovered replay must not open a fresh catalog enumeration window"
        )
    }

    /// Failed enumerations remain excluded from the repeat budget.
    func testFailedCatalogEnumerationsDoNotConsumeEpochStopBudget() throws {
        var guardUnderTest = ToolLoopGuard()

        let failedCall = try catalog("catalog-failed")
        let failedDecision = record(
            &guardUnderTest,
            call: failedCall,
            result: failed(failedCall, "temporarily unavailable"),
            isSideEffecting: false
        )
        XCTAssertNil(failedDecision)

        let first = try catalog("catalog-1")
        let firstDecision = record(
            &guardUnderTest,
            call: first,
            result: ok(first, "device page v1"),
            isSideEffecting: false
        )
        XCTAssertNil(firstDecision)

        let second = try catalog("catalog-2")
        let warningDecision = record(
            &guardUnderTest,
            call: second,
            result: ok(second, "device page v1"),
            isSideEffecting: false
        )
        let warning = try XCTUnwrap(warningDecision)
        XCTAssertFalse(warning.shouldStop)

        let third = try catalog("catalog-3")
        let stoppedDecision = record(
            &guardUnderTest,
            call: third,
            result: ok(third, "device page v1"),
            isSideEffecting: false
        )
        let stopped = try XCTUnwrap(stoppedDecision)
        XCTAssertTrue(stopped.shouldStop)
    }
}
