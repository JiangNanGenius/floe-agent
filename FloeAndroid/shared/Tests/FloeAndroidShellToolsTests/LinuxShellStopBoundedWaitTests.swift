// SPDX-License-Identifier: MPL-2.0
//
// Bounded post-stop wait regression for the Android Linux one-shot backend.
//
// A caller cancellation is a stop REQUEST: the local waiter may answer
// without the engine's release proof once the loop observes `releaseGrace`
// from THAT stop. Transport operations have their own timeouts. It must not
// inherit the remaining original command deadline after an early cancellation.
// The unproven lease stays owned and visible to reconciliation, and a real
// engine terminal still outranks the local intent.
//
// Authored-only: the coordinator runs these against the synthetic fake
// transport; nothing here touches a device, runtime, model or provider.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class LinuxShellStopBoundedWaitTests: XCTestCase {

    private func makeBackend(
        releaseGrace: TimeInterval = 0.25,
        observation: TimeInterval = 1
    ) -> (AndroidLinuxShellBackend, FakeLinuxShellTransport) {
        let transport = FakeLinuxShellTransport()
        // In these fixtures the fake never proves a release just because a
        // stop was recorded; only an explicitly scripted released page can.
        transport.releaseAfterCancel = false
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: AndroidLinuxShellBackend.Configuration(
                pollIntervalNanos: 1_000_000,
                releaseGrace: releaseGrace,
                stdinWriteRetries: 4,
                reconcileIntervalNanos: 10_000_000,
                reconcileObservation: observation))
        return (backend, transport)
    }

    private func request(root: URL, timeout: TimeInterval,
                         session: String = "run:stop-bounded") -> ShellRunRequest {
        ShellRunRequest(command: "sleep 600", cwd: ".", rootURL: root,
                        timeout: timeout, gateTimeout: 0.5,
                        maxOutputBytes: 4096, sessionID: session,
                        runID: UUID(), conversationID: UUID())
    }

    /// Pre-fix counterexample: the ceiling was
    /// `max(executionAdmittedAt + timeout, stopIssuedAt) + releaseGrace`, so
    /// an early cancellation still waited for the ORIGINAL command deadline.
    /// With a long command timeout and an engine that does not prove release,
    /// the caller must get the honest `.cancelled` answer after the stop
    /// grace, and the lease must remain owned for reconciliation. The test
    /// uses 6 s instead of the production 600 s budget so the pre-fix
    /// behavior fails in seconds rather than minutes.
    func testEarlyCancellationIsAnchoredAtTheStopRequestNotTheOriginalTimeout() async throws {
        let root = try ShellTestRoot.make()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let (backend, transport) = makeBackend()
        let token = CancellationToken()
        transport.pollScript = { _, _, nth in
            if nth == 1 { token.cancel() }
            return nil // running; this fixture never proves the release
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let outcome = await backend.run(request(root: root, timeout: 6), cancellation: token)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2,
                                    "the configured stop grace is still observed before handing off")
        XCTAssertLessThan(elapsed, 2,
                          "an early cancel must be answered within the stop grace, not the 6 s command budget")
        XCTAssertGreaterThanOrEqual(transport.recordedCancelCount, 1)
        XCTAssertNil(transport.lastCancelReason,
                     "ordinary cancellation keeps the engine's legacy user-stop request")

        let owned = await backend.ownedSessions()
        XCTAssertEqual(owned.count, 1, "the unproven engine release keeps the lease owned")
        XCTAssertFalse(try XCTUnwrap(owned.first).leaseReleased,
                       "the local wait never claims a release the engine did not prove")
        let busy = await backend.isEngineSlotBusy()
        XCTAssertTrue(busy, "the role slot stays retained for reconciliation")
        let unreconciled = await backend.unreconciledSessions()
        XCTAssertEqual(unreconciled.count, 1, "the retained lease stays observable to reconciliation")
    }

    /// The timeout path keeps its original deadline semantics: the local
    /// wait still spans the command budget plus the stop grace, reports
    /// `.timedOut` with the partial output, and retains the unproven lease.
    func testTimeoutWithoutReleaseStillUsesDeadlineAndGrace() async throws {
        let root = try ShellTestRoot.make()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let (backend, transport) = makeBackend(releaseGrace: 0.3)
        transport.pollScript = { session, cursor, _ in
            FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "still running")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let outcome = await backend.run(request(root: root, timeout: 0.2), cancellation: nil)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        guard case .timedOut(let partialStdout, _, _) = outcome else {
            return XCTFail("a local deadline without a release proof must stay timedOut; got \(outcome)")
        }
        XCTAssertTrue(partialStdout.contains("still running"))
        XCTAssertGreaterThanOrEqual(elapsed, 0.35,
                                    "the timeout must still span its command budget plus the stop grace")
        XCTAssertLessThan(elapsed, 2, "the timeout wait stays bounded")
        XCTAssertEqual(transport.recordedCancelCount, 1,
                       "the timeout requests the engine stop exactly once")
        XCTAssertEqual(transport.lastCancelReason, .timeout)

        let owned = await backend.ownedSessions()
        XCTAssertEqual(owned.count, 1, "an unproven release is not freed by the timeout answer")
        XCTAssertFalse(try XCTUnwrap(owned.first).leaseReleased)
    }

    /// A real terminal that races the caller's stop stays a REAL exit: the
    /// local cancellation intent never rewrites the engine's released exit,
    /// and the proven release frees the record and the role slot.
    func testCancellationRaceWithRealExitKeepsTheEngineTerminal() async throws {
        let root = try ShellTestRoot.make()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let (backend, transport) = makeBackend()
        let token = CancellationToken()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 {
                token.cancel()
                return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "")
            }
            return FakeLinuxShellTransport.page(
                session: session, cursor: cursor, text: "",
                state: .terminated, released: true, exit: 0,
                workspaceStatus: "synced")
        }
        let outcome = await backend.run(request(root: root, timeout: 6), cancellation: token)

        guard case .exited(let code, _, _, _, _, _) = outcome else {
            return XCTFail("a real released exit must outrank the local cancel intent; got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertGreaterThanOrEqual(transport.recordedCancelCount, 1,
                                    "the caller's stop request was still delivered")
        let owned = await backend.ownedSessions()
        XCTAssertTrue(owned.isEmpty, "the engine-proven release retires the record")
        let busy = await backend.isEngineSlotBusy()
        XCTAssertFalse(busy, "a proven terminal frees the role slot")
    }
}
