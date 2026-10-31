// SPDX-License-Identifier: MPL-2.0
//
// Cold-preparation vs command-budget regressions for the ACTUAL 2026-10-31
// device failure (job-e58fe0969b844445). Authored for the existing
// `FloeAndroidShellToolsTests` target; NOT executed by the authoring lane.
//
// Actual evidence being pinned: the first `exec.shell` on a cold API37/16 KiB
// tablet asked for the default 10 s command, the engine spent 38.087 s in
// rootfs materialization before it spawned anything, and the tool returned
// `exit=124 durationMs=38583 status=timedOut effectiveTimeoutSeconds=10.0`
// although the engine log proved `run=151ms` and a real exit. The local
// deadline had been anchored BEFORE `shell.start`, so preparation consumed a
// budget that belonged to the command.
//
// These tests use a small deterministic preparation delay (hundreds of
// milliseconds) so the wrong anchoring fails fast; nothing here sleeps the
// real 38 s, opens a runtime, or calls a provider.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class LinuxShellColdPreparationBudgetTests: XCTestCase {

    private func makeBackend()
        -> (AndroidLinuxShellBackend, FakeLinuxShellTransport)
    {
        let transport = FakeLinuxShellTransport()
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: AndroidLinuxShellBackend.Configuration(
                pollIntervalNanos: 5_000_000,
                releaseGrace: 0.3,
                stdinWriteRetries: 4,
                reconcileIntervalNanos: 5_000_000,
                reconcileObservation: 5))
        return (backend, transport)
    }

    private func request(root: URL,
                         command: String,
                         timeout: TimeInterval) -> ShellRunRequest {
        ShellRunRequest(command: command, cwd: ".", rootURL: root,
                        timeout: timeout, gateTimeout: 0.5,
                        sessionID: "run:cold-prep:\(UUID().uuidString)",
                        runID: UUID())
    }

    /// The counterexample: slow cold preparation + fast command. The command
    /// must keep its FULL requested budget after real execution admission.
    /// The pre-fix code anchored the deadline at dispatch start, so the first
    /// post-start iteration already considered the command timed out and sent
    /// a stop even though it had just been admitted.
    func testSlowColdPreparationDoesNotConsumeCommandTimeout() async throws {
        let root = try ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        // Cold rootfs materialization stand-in, far longer than the command
        // timeout but well within the transport's preparation budget.
        transport.setStartDelay(nanoseconds: 400_000_000)
        transport.pollScript = { [weak transport] session, cursor, _ in
            if (transport?.recordedCancelCount ?? 0) > 0 {
                // Model the actual race: a stop issued while the engine is
                // finishing reports an engine-cancelled terminal. The fixed
                // client must never get here on preparation time alone.
                return FakeLinuxShellTransport.page(
                    session: session, cursor: cursor, text: "",
                    state: .terminated, released: true,
                    cancelled: true, stopReason: "user-stop", exit: 0,
                    workspaceStatus: "synced")
            }
            return FakeLinuxShellTransport.page(
                session: session, cursor: cursor, text: "G073B_SCHEDULE_OK\n",
                state: .terminated, released: true, exit: 0,
                workspaceStatus: "synced")
        }
        let report = await backend.runReportingPhases(
            request(root: root, command: "printf G073B_SCHEDULE_OK", timeout: 0.1),
            cancellation: nil)

        guard case .exited(let code, let stdout, _, _, _, let durationMs) = report.outcome else {
            return XCTFail("cold preparation must not fake a command timeout; got \(report.outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertTrue(stdout.contains("G073B_SCHEDULE_OK"))
        XCTAssertEqual(transport.recordedCancelCount, 0,
                       "preparation time must never trigger the command's stop")
        // The ORIGINAL dispatch duration still includes preparation (honest).
        XCTAssertGreaterThanOrEqual(durationMs, 400)
        let phases = try XCTUnwrap(report.phaseTimings)
        XCTAssertTrue(phases.contains("terminal=exited"), phases)
        XCTAssertTrue(phases.contains("start="), phases)
    }

    /// The repair must not weaken the bound: a genuinely slow command still
    /// reaches its requested deadline and still issues exactly the owned stop.
    func testGenuinelySlowCommandStillTimesOut() async throws {
        let root = try ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { [weak transport] session, cursor, _ in
            if (transport?.recordedCancelCount ?? 0) > 0 {
                return FakeLinuxShellTransport.page(
                    session: session, cursor: cursor, text: "",
                    state: .terminated, released: true,
                    cancelled: true, stopReason: "timeout", exit: nil,
                    workspaceStatus: "synced")
            }
            return FakeLinuxShellTransport.page(
                session: session, cursor: cursor, text: "working\n", state: .running)
        }
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let report = await backend.runReportingPhases(
            request(root: root, command: "sleep 30", timeout: 0.15),
            cancellation: nil)
        let wallMs = Int((DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000)

        guard case .timedOut(_, _, let durationMs) = report.outcome else {
            return XCTFail("a genuinely slow command must still time out; got \(report.outcome)")
        }
        XCTAssertGreaterThanOrEqual(durationMs, 140)
        XCTAssertGreaterThanOrEqual(wallMs, 140)
        XCTAssertLessThanOrEqual(wallMs, 2_000,
                                 "the timeout stays bounded; it may not become an unbounded wait")
        XCTAssertGreaterThanOrEqual(transport.recordedCancelCount, 1)
    }

    /// Cancellation BEFORE execution admission is an honest cancelled
    /// outcome: it must not report an engine failure, must not wait for the
    /// whole preparation, and must not admit a command afterwards.
    func testCancellationDuringPreparationEndsCancelledBeforeAdmission() async throws {
        let root = try ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.setStartDelay(nanoseconds: 2_000_000_000)
        let prepared = request(root: root, command: "printf never", timeout: 5)
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let run = Task { await backend.runReportingPhases(prepared, cancellation: nil) }
        try await Task.sleep(nanoseconds: 50_000_000)
        run.cancel()
        let report = await run.value
        let wallMs = Int((DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000)

        guard case .cancelled = report.outcome else {
            return XCTFail("preparation cancellation must be cancelled, not a failure; got \(report.outcome)")
        }
        XCTAssertLessThan(wallMs, 1_000,
                          "cancellation must not wait for the full preparation delay")
        XCTAssertEqual(transport.recordedStartCount, 0,
                       "a cancelled preparation must not admit a command")
        let phases = try XCTUnwrap(report.phaseTimings)
        XCTAssertTrue(phases.contains("terminal=cancelled"), phases)
    }
}
