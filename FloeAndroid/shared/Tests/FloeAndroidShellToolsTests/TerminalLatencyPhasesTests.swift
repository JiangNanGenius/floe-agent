// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite: bounded terminal-latency phase diagnostics
// (G07.1 terminal04, job-c5eec0e0881346ff). NOT executed by the authoring
// job; host-runnable once Main compiles the cohort.
//
// What is pinned here:
//  1. The renderer is CLOSED and BOUNDED: fixed phase/terminal vocabulary plus
//     non-negative integers, no command text, no paths, no identifiers, and a
//     truthful `unobserved=` fact naming what the client cannot separate.
//  2. A phase is measured ONCE; a repeated mark cannot rewrite real timing and
//     a backwards clock reading records 0 ms instead of inventing time.
//  3. The backend reports the REAL composition of the terminal it returned
//     (exited / notStarted / failed) while `durationMs` keeps its ORIGINAL
//     meaning (wall clock from before the local gate).
//  4. The confirmed redundant wait is repaired: a page that already reports
//     buffered bytes (`more`) does not pay the fixed inter-poll sleep, while an
//     idle page keeps the ORIGINAL cadence (no busy loop).
//  5. The journal carries the composition ADDITIVELY: the legacy line still
//     decodes (absent key ⇒ nil) and durationMs/outcome are unchanged.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class TerminalLatencyPhasesTests: XCTestCase {

    // MARK: - Pure renderer

    func testLatencyRenderIsClosedAndBounded() {
        var phases = TerminalLatencyPhases(originNanos: 1_000_000_000)
        phases.mark(.gate, at: 1_000_000_000)          // 0 ms
        phases.mark(.start, at: 21_340_000_000)        // 20340 ms
        phases.mark(.stdin, at: 21_342_000_000)        // 2 ms
        phases.mark(.run, at: 21_360_000_000)          // 18 ms
        phases.mark(.settle, at: 21_361_000_000)       // 1 ms
        let text = phases.render(terminal: .exited)

        XCTAssertEqual(text,
            "latency v1 terminal=exited gate=0ms start=20340ms stdin=2ms run=18ms settle=1ms"
            + " total=20361ms unobserved=engineStartInternals,engineStopAndExport")
        // Bounded by construction: far below any diagnostic field cap.
        XCTAssertLessThan(text.utf8.count, 512)
        for phase in TerminalLatencyPhases.Phase.allCases {
            XCTAssertTrue(text.contains("\(phase.rawValue)="),
                          "every reached phase must be named: \(phase.rawValue)")
        }
    }

    func testUnreachedPhaseIsAbsentNeverZeroed() {
        var phases = TerminalLatencyPhases(originNanos: 500)
        phases.mark(.gate, at: 500)
        let text = phases.render(terminal: .notStarted)
        XCTAssertEqual(text, "latency v1 terminal=notStarted gate=0ms total=0ms"
            + " unobserved=engineStartInternals,engineStopAndExport")
        XCTAssertFalse(text.contains("start="), "an unreached phase is absent, never 0ms")
        XCTAssertFalse(text.contains("run="))
    }

    func testRepeatedMarksKeepFirstMeasuredSpan() {
        var phases = TerminalLatencyPhases(originNanos: 0)
        phases.mark(.gate, at: 10_000_000)      // 10 ms
        phases.mark(.gate, at: 900_000_000)     // must NOT overwrite
        let text = phases.render(terminal: .exited)
        XCTAssertTrue(text.contains("gate=10ms"), text)
    }

    func testBackwardClockNeverInventsTime() {
        var phases = TerminalLatencyPhases(originNanos: 1_000_000_000)
        phases.mark(.gate, at: 900_000_000)     // anomaly: records 0, not negative
        let text = phases.render(terminal: .failed)
        XCTAssertTrue(text.contains("gate=0ms"), text)
        XCTAssertTrue(text.contains("total=0ms"), text)
        XCTAssertFalse(text.contains("=-"), "never a negative duration")
    }

    // MARK: - Backend composition

    private func makeBackend(pollIntervalNanos: UInt64 = 1_000_000,
                             transport: FakeLinuxShellTransport = FakeLinuxShellTransport())
        -> (AndroidLinuxShellBackend, FakeLinuxShellTransport)
    {
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: AndroidLinuxShellBackend.Configuration(
                pollIntervalNanos: pollIntervalNanos,
                releaseGrace: 0.2,
                stdinWriteRetries: 4,
                reconcileIntervalNanos: 5_000_000,
                reconcileObservation: 5))
        return (backend, transport)
    }

    private func request(root: URL, command: String = "echo sensitive-command-text",
                         timeout: TimeInterval = 5,
                         gateTimeout: TimeInterval = 0.5) -> ShellRunRequest {
        ShellRunRequest(command: command, cwd: ".", rootURL: root,
                        timeout: timeout, gateTimeout: gateTimeout,
                        sessionID: "run:latency:\(UUID().uuidString)",
                        runID: UUID())
    }

    func testOneShotExitedReportsEveryReachedPhase() async throws {
        let root = try ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { session, cursor, _ in
            FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "hi\n",
                                         state: .terminated, released: true, exit: 0,
                                         workspaceStatus: "synced")
        }
        let reportIn = await backend.runReportingPhases(request(root: root), cancellation: nil)
        let outcome = reportIn.outcome
        guard case .exited(let code, _, _, _, _, let durationMs) = outcome else {
            return XCTFail("expected a real exit, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        // ORIGINAL duration meaning preserved: a non-negative wall duration
        // measured from before the local gate.
        XCTAssertGreaterThanOrEqual(durationMs, 0)

        let report = try XCTUnwrap(reportIn.phaseTimings)
        XCTAssertTrue(report.hasPrefix("latency v1 terminal=exited "), report)
        for phase in ["gate=", "start=", "stdin=", "run=", "settle=", "total="] {
            XCTAssertTrue(report.contains(phase), "missing \(phase) in \(report)")
        }
        XCTAssertTrue(report.contains("unobserved=engineStartInternals,engineStopAndExport"), report)
        // Closed vocabulary: no command text, no output, no identifiers.
        XCTAssertFalse(report.contains("sensitive-command-text"), report)
        XCTAssertFalse(report.contains("hi\n"), report)
        XCTAssertFalse(report.contains("lease-"), report)
        XCTAssertLessThan(report.utf8.count, 512)

        // The bounded diagnostic-UI accessor mirrors the last REPORTED call.
        // It is deliberately NOT the journal's attribution source.
        let diagnostic = await backend.lastRunPhaseDiagnostics()
        XCTAssertEqual(diagnostic, report)
    }

    func testGateNotStartedReportsGateOnly() async throws {
        let root = try ShellTestRoot.make()
        // 20 idle pages at a 50 ms cadence ≈ 1 s of owned slot time, so the
        // contender really observes a busy engine instead of racing a 3 ms run.
        let (backend, transport) = makeBackend(pollIntervalNanos: 50_000_000)
        transport.pollScript = { session, cursor, nth in
            nth <= 20 ? FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "busy\n")
                      : FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "",
                                                     state: .terminated, released: true, exit: 0,
                                                     workspaceStatus: "synced")
        }
        // The request is built OUTSIDE the task: the XCTestCase instance is not
        // Sendable, so only the Sendable request crosses into it.
        let heldRequest = request(root: root)
        let first = Task { await backend.run(heldRequest, cancellation: nil) }
        _ = await shellWaitUntil { await backend.isEngineSlotBusy() }
        let second = await backend.runReportingPhases(request(root: root, gateTimeout: 0.05),
                                                     cancellation: nil)
        _ = await first.value

        guard case .notStarted = second.outcome else {
            return XCTFail("a busy engine must answer notStarted, got \(second.outcome)")
        }
        let report = try XCTUnwrap(second.phaseTimings)
        XCTAssertTrue(report.contains("terminal=notStarted"), report)
        XCTAssertFalse(report.contains("start="), report)
        XCTAssertFalse(report.contains("run="), report)
    }

    func testStartFailureReportsFailedTerminalBeforeExecution() async throws {
        let root = try ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.startError = LinuxShellTransportError.remoteFailed(code: "operation_failed")
        let reportIn = await backend.runReportingPhases(request(root: root), cancellation: nil)
        guard case .failed = reportIn.outcome else {
            return XCTFail("expected failed, got \(reportIn.outcome)")
        }
        let report = try XCTUnwrap(reportIn.phaseTimings)
        XCTAssertTrue(report.contains("terminal=failed"), report)
        XCTAssertTrue(report.contains("start="), report)
        XCTAssertFalse(report.contains("run="), report)
        XCTAssertFalse(report.contains("sensitive-command-text"), report)
    }

    // MARK: - Confirmed redundant-wait repair

    func testBufferedPageSkipsInterPollSleep() async throws {
        let root = try ShellTestRoot.make()
        // A 2 s idle cadence makes the repaired path unambiguous.
        let (backend, transport) = makeBackend(pollIntervalNanos: 2_000_000_000)
        transport.pollScript = { session, cursor, nth in
            nth == 1
                ? FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "part1",
                                               more: true, state: .running)
                : FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "part2",
                                               state: .terminated, released: true, exit: 0,
                                               workspaceStatus: "synced")
        }
        let started = Date()
        let outcome = await backend.run(request(root: root), cancellation: nil)
        let elapsed = Date().timeIntervalSince(started)
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else {
            return XCTFail("expected exit, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout, "part1part2", "both buffered pages must be drained in order")
        XCTAssertLessThan(elapsed, 1.5,
                          "a page that already reports buffered bytes must not pay the inter-poll sleep")
    }

    func testIdlePageKeepsOriginalPollCadence() async throws {
        let root = try ShellTestRoot.make()
        let (backend, transport) = makeBackend(pollIntervalNanos: 250_000_000)
        transport.pollScript = { session, cursor, nth in
            nth == 1
                ? FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "", more: false)
                : FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "",
                                               state: .terminated, released: true, exit: 0,
                                               workspaceStatus: "synced")
        }
        let started = Date()
        _ = await backend.run(request(root: root), cancellation: nil)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15,
            "an idle page must keep the ORIGINAL bounded cadence (no busy loop)")
    }


    // MARK: - Per-call attribution under interleaved dispatch

    /// Main review correction (2026-10-30): the journal must attribute the
    /// phase composition of the dispatch it describes. The backend is an actor
    /// and is reentrant across awaits, so a "last timing" global read after
    /// `run` returns could be replaced by a concurrently REFUSED or NEW call.
    /// This drives two REAL services over one backend and one journal: a slow
    /// call that really runs, and a second call refused by the busy engine
    /// slot. Each line must carry its own composition.
    func testJournalAttributionIsPerCallUnderInterleavedDispatch() async throws {
        let root = try ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        // 140 idle pages at a 50 ms cadence ≈ 7 s: longer than the ONE bounded
        // gate window (5 s) a second service may wait behind the busy slot.
        transport.pollScript = { session, cursor, nth in
            nth <= 140
                ? FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "slow\n")
                : FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "",
                                               state: .terminated, released: true, exit: 0,
                                               workspaceStatus: "synced")
        }
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: AndroidLinuxShellBackend.Configuration(
                pollIntervalNanos: 50_000_000, releaseGrace: 0.2, stdinWriteRetries: 4,
                reconcileIntervalNanos: 5_000_000, reconcileObservation: 5))
        let journal = ShellOperationJournal(rootURL: root)
        let slowService = LocalShellService(backend: backend, journal: journal, rootProvider: { root })
        let deniedService = LocalShellService(backend: backend, journal: journal, rootProvider: { root })
        let slowContext = ToolContext(runID: UUID(), toolCallID: "call-slow",
                                      workspaceRootURL: root, cancellation: CancellationToken())
        let deniedContext = ToolContext(runID: UUID(), toolCallID: "call-denied",
                                        workspaceRootURL: root, cancellation: CancellationToken())
        let slow = Task {
            await slowService.run(command: "echo slow", cwd: ".", environment: [:], stdin: nil,
                                  timeout: 30, maxOutputBytes: 8192, isBackground: false,
                                  context: slowContext)
        }
        _ = await shellWaitUntil { await backend.isEngineSlotBusy() }
        let denied = await deniedService.run(command: "echo denied", cwd: ".", environment: [:],
                                            stdin: nil, timeout: 5, maxOutputBytes: 4096,
                                            isBackground: false, context: deniedContext)
        _ = await slow.value
        guard case .outcome(.notStarted) = denied else {
            return XCTFail("the busy slot must answer notStarted, got \(denied)")
        }

        let journalURL = root.appendingPathComponent(ShellOperationJournal.defaultFileName)
        let text = try String(contentsOf: journalURL, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, text)
        var exitedLine: [String: Any]?
        var notStartedLine: [String: Any]?
        for line in lines {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                                       "journal line is not JSON: \(line)")
            switch object["outcome"] as? String ?? "" {
            case let value where value.hasPrefix("exited:"): exitedLine = object
            case let value where value.hasPrefix("notStarted:"): notStartedLine = object
            default: break
            }
        }
        let exited = try XCTUnwrap(exitedLine)
        let deniedLine = try XCTUnwrap(notStartedLine)
        let exitedPhases = try XCTUnwrap(exited["phaseTimings"] as? String)
        let deniedPhases = try XCTUnwrap(deniedLine["phaseTimings"] as? String)

        XCTAssertTrue(exitedPhases.contains("terminal=exited"), exitedPhases)
        XCTAssertTrue(exitedPhases.contains("run="), exitedPhases)
        XCTAssertTrue(deniedPhases.contains("terminal=notStarted"), deniedPhases)
        XCTAssertFalse(deniedPhases.contains("run="),
                       "a refused call must never inherit the running call's timing: \(deniedPhases)")
        XCTAssertFalse(deniedPhases.contains("start="), deniedPhases)
        XCTAssertNotEqual(exitedPhases, deniedPhases)
        // The ORIGINAL journal columns keep their meaning for both lines.
        XCTAssertNotNil(exited["durationMs"] as? Int)
        XCTAssertNotNil(deniedLine["durationMs"] as? Int)
    }

    // MARK: - Journal additive shape

    private func legacyJournalLine() throws -> Data {
        let legacy: [String: Any] = [
            "timestamp": "2026-10-29T00:00:00Z",
            "runID": "11111111-2222-3333-4444-555555555555",
            "sessionID": "session-1",
            "commandSHA256": String(repeating: "a", count: 64),
            "cwd": ".",
            "stdoutBytes": 0,
            "stderrBytes": 0,
            "truncated": false,
            "durationMs": 42,
            "outcome": "exited:0",
        ]
        return try JSONSerialization.data(withJSONObject: legacy)
    }

    func testJournalEntryKeepsLegacyDecodeAndAddsPhases() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let legacy = try decoder.decode(ShellOperationJournal.Entry.self, from: try legacyJournalLine())
        XCTAssertNil(legacy.phaseTimings, "a pre-feature line keeps working with no phase composition")

        let entry = ShellOperationJournal.Entry(
            runID: "11111111-2222-3333-4444-555555555555",
            toolCallID: "call-1",
            sessionID: "session-1",
            commandSHA256: String(repeating: "b", count: 64),
            cwd: ".",
            exitCode: 0,
            stdoutBytes: 3,
            stderrBytes: 0,
            truncated: false,
            durationMs: 25_577,
            outcome: "exited:0",
            approvalGrantID: nil,
            phaseTimings: "latency v1 terminal=exited gate=0ms start=25500ms total=25577ms"
                + " unobserved=engineStartInternals,engineStopAndExport")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(entry)
        let decoded = try decoder.decode(ShellOperationJournal.Entry.self, from: encoded)
        XCTAssertEqual(decoded.phaseTimings, entry.phaseTimings)
        XCTAssertEqual(decoded.durationMs, 25_577)

        // A nil composition keeps the ORIGINAL key set (optional ⇒ omitted).
        let plain = ShellOperationJournal.Entry(
            runID: "11111111-2222-3333-4444-555555555555", toolCallID: nil, sessionID: "session-1",
            commandSHA256: String(repeating: "c", count: 64), cwd: ".", exitCode: 0,
            stdoutBytes: 0, stderrBytes: 0, truncated: false, durationMs: 1,
            outcome: "exited:0", approvalGrantID: nil)
        let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(text.contains("phaseTimings"), "an unmeasured run must not emit the key: \(text)")
    }

    func testServiceJournalRecordsPhaseCompositionWithoutChangingReceipt() async throws {
        let root = try ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        transport.pollScript = { session, cursor, _ in
            FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "ok\n",
                                         state: .terminated, released: true, exit: 0,
                                         workspaceStatus: "synced")
        }
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: AndroidLinuxShellBackend.Configuration(
                pollIntervalNanos: 1_000_000, releaseGrace: 0.2, stdinWriteRetries: 4,
                reconcileIntervalNanos: 5_000_000, reconcileObservation: 5))
        let service = LocalShellService(backend: backend,
                                        journal: ShellOperationJournal(rootURL: root),
                                        rootProvider: { root })
        let context = ToolContext(runID: UUID(), toolCallID: "call-latency",
                                  workspaceRootURL: root, cancellation: CancellationToken())
        let result = await service.run(command: "echo journal-phase-token", cwd: ".",
                                       environment: [:], stdin: nil, timeout: 5,
                                       maxOutputBytes: 4096, isBackground: false, context: context)
        guard case .outcome(.exited(let code, let stdout, _, _, _, let durationMs)) = result else {
            return XCTFail("expected a real exit through the service, got \(result)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertTrue(stdout.contains("ok"), stdout)
        XCTAssertGreaterThanOrEqual(durationMs, 0)

        let journalURL = root.appendingPathComponent(ShellOperationJournal.defaultFileName)
        let text = try String(contentsOf: journalURL, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").last.map(String.init))
        XCTAssertTrue(line.contains("\"phaseTimings\""), line)
        XCTAssertTrue(line.contains("latency v1 terminal=exited"), line)
        XCTAssertTrue(line.contains("\"durationMs\":"), line)
        XCTAssertTrue(line.contains("\"outcome\":\"exited:0\""), line)
        XCTAssertFalse(line.contains("journal-phase-token"), "the journal keeps only the command digest")
    }
}
