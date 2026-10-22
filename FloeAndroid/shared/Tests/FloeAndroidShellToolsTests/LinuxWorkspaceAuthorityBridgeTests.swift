// FloeAndroidShellToolsTests — G03-R2 workspace bridge lifetime (job-4d35db884ec64d95,
// coordinator steer 20261022, Main review).
//
// `LinuxWorkspaceAuthority.bridge` runs on Binder/pump WORKER threads. A
// timeout is a cancellation request + refusal, NEVER proof the async
// operation finished: the C call must stay held until the underlying task
// actually settles, otherwise the Core grant IO latch could report drained
// while a late resolver still touches the original stores/files.
// Host-runnable; deterministic delayed operation; no device, no timers
// shorter than the observed settle.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class LinuxWorkspaceAuthorityBridgeTests: XCTestCase {

    /// Deterministic slow operation: ignores its own result but observes
    /// cancellation cooperatively, finishing a fixed settle AFTER any
    /// plausible bridge timeout. The fixture asserts the bridge did NOT
    /// return before the operation actually settled.
    func testBridgeTimeoutRefusesButNeverDrainsBeforeActualSettle() async throws {
        final class Settled: @unchecked Sendable {
            private let lock = NSLock()
            private var flag = false
            var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
            func mark() { lock.lock(); flag = true; lock.unlock() }
        }
        let settled = Settled()
        let started = Date()
        // 0.1 s bridge deadline vs an operation that settles only after ~0.6 s
        // (post-cancellation cooperative drain). The pre-fix code returned at
        // ~0.1 s WHILE THE TASK KEPT RUNNING — exactly the false-drain this
        // repair removes.
        let result = await Task.detached { () -> String? in
            LinuxWorkspaceAuthority.bridge(timeoutSeconds: 0.1) { () async -> String? in
                // Cooperative long operation: notice cancellation, then a
                // bounded ACTUAL completion that cannot observe it (a real
                // SQLite/materialization step already dispatched behaves this
                // way; Task.sleep would unwind on cancellation and prove
                // nothing). Settle is recorded LAST.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                // Swift 6 forbids Thread.sleep in async contexts; a wall-clock
                // spin is the honest uncancellable tail (it IGNORES Task
                // cancellation exactly like an already-dispatched store step).
                let tailDeadline = Date().addingTimeInterval(0.25)
                while Date() < tailDeadline { }
                settled.mark()
                return nil
            }
        }.value
        XCTAssertNil(result, "timeout must be a refusal")
        XCTAssertTrue(settled.value,
                      "the bridge must NOT return until the underlying operation actually settled (no early IO drain)")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.3,
                                    "refusal happened only after the real settle tail, not at the bare deadline")
    }

    /// Control: an operation that finishes before the deadline returns its
    /// value with no refusal and no extra waiting.
    func testBridgeReturnsValueWhenOperationSettlesInTime() async {
        let result = LinuxWorkspaceAuthority.bridge(timeoutSeconds: 2.0) { () async -> String? in
            "settled"
        }
        XCTAssertEqual(result, "settled")
    }

    /// Control: a nil result from a settled operation is an honest nil, not
    /// a timeout; and the call returns promptly.
    func testBridgeNilResultIsNotRetriedOrReplayed() async {
        final class Runs: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func bump() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let runs = Runs()
        let result = LinuxWorkspaceAuthority.bridge(timeoutSeconds: 2.0) { () async -> Int? in
            runs.bump()
            return nil
        }
        XCTAssertNil(result)
        XCTAssertEqual(runs.value, 1, "exactly ONE operation; timeout/refusal never starts a replay")
    }
}
