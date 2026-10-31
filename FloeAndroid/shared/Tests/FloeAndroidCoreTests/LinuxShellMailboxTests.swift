// SPDX-License-Identifier: MPL-2.0
//
// Cold-preparation vs command-budget regressions for the ORIGINAL Linux shell
// mailbox (G07.3B job-e58fe0969b844445). Authored for the existing
// `FloeAndroidCoreTests` target; NOT executed by the authoring lane.
//
// Actual failure being pinned: the first `exec.shell` on a cold API37/16 KiB
// tablet reported `exit=124 durationMs=38583 status=timedOut
// effectiveTimeoutSeconds=10.0` while the engine log proved
// `materialize=38087ms ... run=151ms` and a real exit. `shell.start` carries
// cold rootfs materialization/import, so its wait is a PREPARATION budget;
// the caller's command timeout is a separate budget that starts only at real
// execution admission. These tests drive the raw mailbox (claim/complete/
// shouldStop) with its real bounded waiter clock: no runtime component, no Binder, no
// device and no provider call.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeAndroidShellTools

final class LinuxShellMailboxPreparationBudgetTests: XCTestCase {

    /// A loaded device can oversleep every 20 ms poll. This clock makes that
    /// deterministic: each requested interval advances REAL time by the
    /// requested amount plus a fixed overshoot, exactly what `Task.sleep`
    /// did on the actual run (6,000 nominal 20 ms waits took 148.4 s).
    private final class OversleepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var nowNanos: UInt64 = 0
        private var sleeps = 0
        let overshootNanos: UInt64

        init(overshootNanos: UInt64 = 4_700_000) {
            self.overshootNanos = overshootNanos
        }

        func now() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return nowNanos
        }

        func advance(by requested: UInt64) {
            lock.lock(); defer { lock.unlock() }
            nowNanos &+= requested &+ overshootNanos
            sleeps += 1
        }

        var sleepCount: Int {
            lock.lock(); defer { lock.unlock() }
            return sleeps
        }
    }

    private func makeMailbox() -> LinuxShellMailbox {
        // Use the real bounded waiter clock: shortening each sleep while the
        // watchdog charges the full poll interval would expire the budget
        // before the real preparation delay in this regression.
        LinuxShellMailbox()
    }

    private func claim(_ mailbox: LinuxShellMailbox,
                       file: StaticString = #filePath, line: UInt = #line) throws -> Int64 {
        let claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0, "the host must claim the submitted preparation", file: file, line: line)
        return claim
    }

    @discardableResult
    private func complete(_ mailbox: LinuxShellMailbox, claim: Int64,
                          status: Int32, json: String) -> Int32 {
        let data = Data(json.utf8)
        return data.withUnsafeBytes { raw in
            mailbox.complete(claim: claim, status: status,
                             value: raw.bindMemory(to: UInt8.self).baseAddress,
                             valueLen: Int32(data.count))
        }
    }

    private func awaitResult(_ task: Task<Result<Data, LinuxShellTransportError>, Never>)
        async -> Result<Data, LinuxShellTransportError>
    {
        await task.value
    }

    // MARK: - Budget separation

    /// `startBudgetMillis` is the explicit PREPARATION budget. A start that
    /// takes longer than the payload's `timeoutSeconds` (the command's own
    /// budget) must still settle: the mailbox may not charge preparation time
    /// to the command.
    func testPreparationLongerThanCommandTimeoutStillSettles() async throws {
        let mailbox = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 1))
        let payload = try JSONSerialization.data(withJSONObject: [
            "command": "printf G073B_SCHEDULE_OK",
            "timeoutSeconds": 0.05,
        ])
        let waiter = Task { try await mailbox.submit(
            operation: "shell.start", payload: payload, timeoutMillis: 1_500) }
        let claim = try claim(mailbox)
        // Cold preparation stand-in: 250 ms >> the 50 ms command timeout and
        // far below the mailbox preparation budget.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(complete(mailbox, claim: claim, status: 0,
                                json: #"{"sessionID":"lease-cold","environmentID":"linux.local"}"#), 0)
        let reply = try await waiter.value
        let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        XCTAssertEqual(object?["sessionID"] as? String, "lease-cold")
        XCTAssertEqual(object?["environmentID"] as? String, "linux.local")
    }

    func testPreparationBudgetIsExplicitAndBounded() {
        XCTAssertEqual(LinuxShellMailboxLimits.preparationBudgetMillis, 120_000)
        XCTAssertEqual(LinuxShellMailboxLimits.startBudgetMillis,
                       LinuxShellMailboxLimits.preparationBudgetMillis,
                       "the legacy name must not silently become a different budget")
    }

    // MARK: - Bounded preparation failure retains real ownership

    /// The preparation budget is a REAL bound: when it expires the waiter is
    /// released with the typed error, but a CLAIMED preparation stays live and
    /// stoppable. No settlement, cancellation or exit is fabricated.
    func testPreparationBudgetExpiryLeavesClaimedWorkStoppableAndSettlesOnce() async throws {
        let mailbox = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 1))
        let payload = Data(#"{"command":"printf x","timeoutSeconds":10}"#.utf8)
        let waiter = Task { () -> Result<Data, LinuxShellTransportError> in
            do {
                return .success(try await mailbox.submit(
                    operation: "shell.start", payload: payload, timeoutMillis: 500))
            } catch let error as LinuxShellTransportError {
                return .failure(error)
            } catch {
                return .failure(.hostFenced)
            }
        }
        let claim = try claim(mailbox)
        let result = await awaitResult(waiter)
        guard case .failure(.waitBudgetExpired) = result else {
            return XCTFail("expected the bounded preparation waiter to expire, got \(result)")
        }
        XCTAssertEqual(mailbox.isLive(claim: claim), 1,
                       "a claimed preparation must stay owned, never fabricated settled")
        XCTAssertEqual(mailbox.shouldStop(claim: claim), 1,
                       "the host must be able to stop the pending preparation")
        XCTAssertEqual(complete(mailbox, claim: claim, status: 1,
                                json: #"{"code":"runtime_start_stopped"}"#), 0)
        XCTAssertEqual(mailbox.ticketState(token: claim), .hostSettled)
        XCTAssertEqual(complete(mailbox, claim: claim, status: 1,
                                json: #"{"code":"runtime_start_stopped"}"#), -101,
                       "a duplicate late settlement is classified, never replayed")
    }

    /// Actual 2026-10-31 regression: the watchdog counted nominal 20 ms
    /// intervals instead of elapsed time. Under load each wait overslept, so a
    /// 120 s budget really expired after 148.4 s and the cold start kept
    /// copying. With a fixed monotonic deadline the same oversleep pattern
    /// must expire on REAL time (here 500 ms, with 4.7 ms overshoot per poll),
    /// not after the old 25 nominal waits (617 ms). The claimed ticket stays
    /// live/stoppable and is not fabricated settled.
    func testPreparationBudgetUsesElapsedDeadlineUnderOversleep() async throws {
        let clock = OversleepClock()
        let mailbox = LinuxShellMailbox(
            sleeper: { requested in
                // Let the host claim this ticket before the first fake tick;
                // otherwise the instantaneous fake clock could expire a
                // still-queued ticket and retire it before `claim` runs.
                if clock.sleepCount == 0 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                clock.advance(by: requested)
            },
            clock: { clock.now() })
        XCTAssertTrue(mailbox.bind(epoch: 1))
        let payload = Data(#"{"command":"printf x","timeoutSeconds":10}"#.utf8)
        let waiter = Task { () -> Result<Data, LinuxShellTransportError> in
            do {
                return .success(try await mailbox.submit(
                    operation: "shell.start", payload: payload, timeoutMillis: 500))
            } catch let error as LinuxShellTransportError {
                return .failure(error)
            } catch {
                return .failure(.hostFenced)
            }
        }
        let claim = try claim(mailbox)
        let result = await awaitResult(waiter)
        guard case .failure(.waitBudgetExpired) = result else {
            return XCTFail("expected the 500 ms preparation waiter to expire, got \(result)")
        }
        // 500 ms / (20 ms requested + 4.7 ms overshoot) = 21 real sleeps.
        XCTAssertGreaterThanOrEqual(clock.sleepCount, 20)
        XCTAssertLessThanOrEqual(clock.sleepCount, 22,
                                 "the deadline must use elapsed time, not 25 nominal intervals")
        XCTAssertEqual(mailbox.isLive(claim: claim), 1)
        XCTAssertEqual(mailbox.shouldStop(claim: claim), 1,
                       "the host must observe the real expiry and stop the pending start")
        XCTAssertEqual(complete(mailbox, claim: claim, status: 1,
                                json: #"{"code":"runtime_start_stopped"}"#), 0)
    }

    /// A caller cancellation releases only the WAITER. The real preparation
    /// stays owned until the host completes it, and that one real completion
    /// settles exactly once. This is what prevents a late command/exit from
    /// being invented after a stop.
    func testCancelledStartWaiterRetainsPreparationAndSettlesExactlyOnce() async throws {
        let mailbox = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 1))
        let payload = Data(#"{"command":"printf x","timeoutSeconds":10}"#.utf8)
        let waiter = Task { () -> Result<Data, LinuxShellTransportError> in
            do {
                return .success(try await mailbox.submit(
                    operation: "shell.start", payload: payload, timeoutMillis: 5_000))
            } catch let error as LinuxShellTransportError {
                return .failure(error)
            } catch {
                return .failure(.hostFenced)
            }
        }
        let claim = try claim(mailbox)
        waiter.cancel()
        let result = await awaitResult(waiter)
        guard case .failure(.waitBudgetExpired) = result else {
            return XCTFail("a cancelled waiter must be released, got \(result)")
        }
        XCTAssertEqual(mailbox.isLive(claim: claim), 1)
        XCTAssertEqual(mailbox.shouldStop(claim: claim), 1)
        XCTAssertEqual(complete(mailbox, claim: claim, status: 0,
                                json: #"{"sessionID":"lease-after-stop","environmentID":"linux.local"}"#), 0)
        XCTAssertEqual(mailbox.ticketState(token: claim), .hostSettled)
        let stats = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(mailbox.statsJSON().utf8)) as? [String: Any])
        let counters = try XCTUnwrap(stats["counters"] as? [String: Any])
        XCTAssertEqual(counters["waitBudgetExpired"] as? Int, 1)
        XCTAssertEqual(counters["completed"] as? Int, 1)
        XCTAssertEqual(counters["lateSettle"] as? Int, 0)
    }

    // MARK: - Warm semantics unchanged

    /// A warm start (no preparation delay) still settles immediately and
    /// carries no budget/ownership difference from the cold path.
    func testWarmStartStillSettlesImmediately() async throws {
        let mailbox = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 1))
        let payload = Data(#"{"command":"printf ok","timeoutSeconds":10}"#.utf8)
        let waiter = Task { try await mailbox.submit(
            operation: "shell.start", payload: payload, timeoutMillis: 2_000) }
        let claim = try claim(mailbox)
        XCTAssertEqual(complete(mailbox, claim: claim, status: 0,
                                json: #"{"sessionID":"lease-warm","environmentID":"linux.local"}"#), 0)
        let reply = try await waiter.value
        let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        XCTAssertEqual(object?["sessionID"] as? String, "lease-warm")
    }
}
