// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite: the Android Linux shell backend
// (job-1bd4fcce5eca4856). NOT executed by the authoring job; host-runnable
// once Main adds the `FloeAndroidShellToolsTests` target. All engine
// interaction rides the synthetic `FakeLinuxShellTransport`; nothing here
// touches a device, the runtime component, files outside the test temporary
// directory, or any credential.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class LinuxShellBackendTests: XCTestCase {

    private func makeBackend(qualified: Bool = true,
                             transport: FakeLinuxShellTransport = FakeLinuxShellTransport())
        -> (AndroidLinuxShellBackend, FakeLinuxShellTransport)
    {
        let configuration = AndroidLinuxShellBackend.Configuration(
            pollIntervalNanos: 1_000_000,
            releaseGrace: 0.2,
            stdinWriteRetries: 8,
            reconcileIntervalNanos: 5_000_000,
            reconcileObservation: 30
        )
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: qualified),
            configuration: configuration)
        return (backend, transport)
    }

    private func runRequest(root: URL,
                            runID: UUID? = UUID(),
                            conversationID: UUID? = nil,
                            environment: [String: String] = [:],
                            stdin: String? = nil,
                            timeout: TimeInterval = 1,
                            gateTimeout: TimeInterval = 0.5,
                            maxOutputBytes: Int = 64 * 1024) -> ShellRunRequest {
        ShellRunRequest(command: "echo test", cwd: ".", rootURL: root,
                        environment: environment, stdin: stdin,
                        timeout: timeout, gateTimeout: gateTimeout,
                        maxOutputBytes: maxOutputBytes,
                        sessionID: "run:unit-test:call-1",
                        runID: runID, toolEnvironment: nil,
                        conversationID: conversationID)
    }

    func testSuccessfulProcessWithoutSavedWorkspaceIsFailure() async throws {
        for status in [nil, "conflict"] as [String?] {
            let root = try ShellTestRoot.make()
            let (backend, transport) = makeBackend()
            transport.pollScript = { session, cursor, _ in
                FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "process output",
                    state: .terminated, released: true, exit: 0, workspaceStatus: status)
            }
            let outcome = await backend.run(runRequest(root: root), cancellation: nil)
            guard case .failed(let message) = outcome else { return XCTFail("unsaved files must not be successful exit") }
            XCTAssertTrue(message.contains("not fully saved"))
            let busy = await backend.isEngineSlotBusy()
            XCTAssertFalse(busy, "actual process release is distinct from file outcome")
        }
    }

    // MARK: - Fail-closed authority

    func testMissingRunOwnerFailsClosedWithoutTouchingTransport() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        let outcome = await backend.run(runRequest(root: root, runID: nil), cancellation: nil)
        guard case .failed(let message) = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertTrue(message.contains("run owner"))
        XCTAssertEqual(transport.recordedStartCount, 0)
    }

    func testUnqualifiedReadinessFailsClosedWithoutTouchingTransport() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend(qualified: false)
        let outcome = await backend.run(runRequest(root: root), cancellation: nil)
        guard case .failed(let message) = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertTrue(message.contains("test-guidance"))
        XCTAssertEqual(transport.recordedStartCount, 0)
    }

    func testExplicitEnvIsCarriedUnchangedWithinEngineBounds() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "") }
            return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "",
                                                state: .terminated, released: true, exit: 0)
        }
        let outcome = await backend.run(runRequest(root: root, environment: ["BUILD_MODE": "debug"]), cancellation: nil)
        guard case .exited = outcome else { return XCTFail("expected exited, got \(outcome)") }
        XCTAssertEqual(transport.starts.first?.environment, ["BUILD_MODE": "debug"],
                       "the explicit caller env rides the typed start request unchanged")
    }

    func testAuthorityReservedEnvKeysFailClosedBeforeDispatch() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        let outcome = await backend.run(runRequest(root: root, environment: ["FLOE_TOKEN": "x"]), cancellation: nil)
        guard case .failed(let message) = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertTrue(message.contains("reserved"), message)
        XCTAssertEqual(transport.recordedStartCount, 0, "a reserved key never reaches the engine")
    }

    func testOverlongCommandRefusedLocally() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        var request = runRequest(root: root)
        request.command = String(repeating: "a", count: 17 * 1024)
        let outcome = await backend.run(request, cancellation: nil)
        guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertEqual(transport.recordedStartCount, 0)
    }

    // MARK: - Merged-output honesty

    func testRunMapsMergedPTYOutputToExitedWithEmptyStderr() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        let conversation = UUID()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 {
                return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "merged line\n")
            }
            return FakeLinuxShellTransport.page(session: session, cursor: cursor + 12, text: "",
                                                state: .terminated, released: true, exit: 0)
        }
        let outcome = await backend.run(runRequest(root: root, conversationID: conversation), cancellation: nil)
        guard case .exited(let code, let stdout, let stderr, let truncated, let stderrTruncated, let durationMs) = outcome else {
            return XCTFail("expected exited, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout, "merged line\n")
        XCTAssertEqual(stderr, "", "no invented stdout/stderr split: merged bytes go to the output only")
        XCTAssertFalse(truncated)
        XCTAssertFalse(stderrTruncated)
        XCTAssertGreaterThanOrEqual(durationMs, 0)
        // Engine start carried the exact owner identities unchanged.
        XCTAssertEqual(transport.starts.count, 1)
        XCTAssertEqual(transport.starts[0].conversationID, conversation)
        XCTAssertEqual(transport.starts[0].cwd, ".")
    }

    func testProjectIDIsStableForCanonicalRootAndNotRandom() async {
        let root = try! ShellTestRoot.make()
        let first = LinuxShellProjectMapping.projectID(forCanonicalCoreWorkspaceRoot: root)
        // A REAL alias of the SAME root (redundant "." component resolved by
        // standardization), not the parent directory: identical canonical
        // roots must map to one stable project UUID; parent/child identities
        // must stay distinct (asserted below).
        let sameRootAlias = root.appendingPathComponent(".").standardizedFileURL
        let second = LinuxShellProjectMapping.projectID(forCanonicalCoreWorkspaceRoot: sameRootAlias)
        XCTAssertEqual(first, second, "canonicalized identical roots map to one stable project UUID")
        let other = LinuxShellProjectMapping.projectID(forCanonicalCoreWorkspaceRoot: try! ShellTestRoot.make(name: "other"))
        XCTAssertNotEqual(first, other)
    }

    func testOutputCapTruncatesAndGapBytesAreHonest() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 {
                return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "0123456789", gap: 3)
            }
            return FakeLinuxShellTransport.page(session: session, cursor: cursor + 10, text: "",
                                                state: .terminated, released: true, exit: 0)
        }
        let outcome = await backend.run(runRequest(root: root, maxOutputBytes: 4), cancellation: nil)
        guard case .exited(_, let stdout, _, let truncated, _, _) = outcome else {
            return XCTFail("expected exited, got \(outcome)")
        }
        XCTAssertEqual(stdout.utf8.count, 4)
        XCTAssertTrue(truncated, "both the caller cap AND engine gapBytes must surface as truncation")
    }

    func testSignalTerminatedWithoutFabricatedExit() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 {
                return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "partial")
            }
            return FakeLinuxShellTransport.page(session: session, cursor: cursor + 7, text: "",
                                                state: .terminated, released: true, exit: nil, termSig: 9)
        }
        let outcome = await backend.run(runRequest(root: root), cancellation: nil)
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else {
            return XCTFail("expected exited, got \(outcome)")
        }
        XCTAssertEqual(code, 128 + 9, "signalled terminal maps to the documented POSIX convention")
        XCTAssertEqual(stdout, "partial")
    }

    func testWaitErrnoIsNeverBenign() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { session, cursor, _ in
            var page = FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "",
                                                    state: .terminated, released: true, exit: 0)
            page.waitErrno = 4
            return page
        }
        let outcome = await backend.run(runRequest(root: root), cancellation: nil)
        guard case .failed(let message) = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertTrue(message.contains("waitErrno=4"))
    }

    // MARK: - Timeouts, cancellation, gate

    func testRunTimeoutIsReportedHonestAndLeaseRetainedUntilRelease() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.releaseAfterCancel = false
        transport.pollScript = { session, cursor, _ in
            FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "still running", more: false)
        }
        let outcome = await backend.run(runRequest(root: root, timeout: 0.05), cancellation: nil)
        guard case .timedOut(let partialStdout, _, _) = outcome else {
            return XCTFail("expected timedOut, got \(outcome)")
        }
        XCTAssertTrue(partialStdout.contains("still running"))
        XCTAssertEqual(transport.recordedCancelCount, 1, "a timeout requests the engine stop exactly once")
        // EOF != exit: the local answer timedOut does NOT free the slot while
        // the engine lease is unreconciled.
        let busy = await backend.isEngineSlotBusy()
        XCTAssertTrue(busy)
        var unreconciled = await backend.unreconciledSessions()
        XCTAssertEqual(unreconciled.count, 1)
        // When the engine finally proves the release, reconciliation frees the gate.
        let sessionID = unreconciled[0].engineSessionID
        transport.pollScript = { session, cursor, _ in
            session == sessionID
                ? FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "",
                                               state: .terminated, released: true, exit: nil, termSig: 15)
                : nil
        }
        let drained = await shellWaitUntil {
            let unreconciled = await backend.unreconciledSessions()
            let busy = await backend.isEngineSlotBusy()
            return unreconciled.isEmpty && !busy
        }
        XCTAssertTrue(drained, "the retained lease must settle exactly when the engine reports leaseReleased")
        unreconciled = await backend.unreconciledSessions()
        XCTAssertTrue(unreconciled.isEmpty)
    }

    func testEngineStopReasonTimeoutOutranksLocalIntent() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        // The engine's OWN deadline fires first (stopReason=timeout) while
        // the local wait still has budget left: the engine truth must win.
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "work") }
            return FakeLinuxShellTransport.page(session: session, cursor: cursor + 4, text: "",
                                                state: .terminated, released: true,
                                                cancelled: true, stopReason: "timeout",
                                                exit: nil, termSig: 15)
        }
        let outcome = await backend.run(runRequest(root: root, timeout: 5), cancellation: nil)
        guard case .timedOut(let partialStdout, _, _) = outcome else {
            return XCTFail("expected timedOut from the engine stop reason, got \(outcome)")
        }
        XCTAssertTrue(partialStdout.contains("work"))
        let busy = await backend.isEngineSlotBusy()
        XCTAssertFalse(busy, "a released lease frees the slot exactly when proven")
    }

    func testRunCancellationRequestsRemoteStopAndWaitsForRealRelease() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        let token = CancellationToken()
        // Region-safe (Swift 6): the transport's OWN script must not capture
        // the transport instance. The pre-cancel phase is exactly the
        // default busy page, so no script is needed.
        transport.pollScript = nil
        // Build the request OUTSIDE the Task (region-safe: the test class is
        // not Sendable; the Task only captures the actor + value types).
        let request = runRequest(root: root, timeout: 5)
        let runTask = Task {
            await backend.run(request, cancellation: token)
        }
        // Let it start, then cancel the Core-side wait.
        while transport.recordedStartCount == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
        token.cancel()
        // The release proof arrives via the cancel-aware default poll.
        // The first poll after the flip answers the NONTERMINAL cancelling
        // page (still no release proof); every later poll falls back to the
        // transport's stop-driven default, which releases ONLY once the
        // engine actually saw the stop. The closure captures a small
        // counter box, never the transport itself (region-safe).
        let flipCounter = PollFlipCounter()
        transport.pollScript = { session, cursor, _ in
            if flipCounter.nextIsFirst() {
                return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "",
                                                    state: .cancelling, released: false)
            }
            return nil
        }
        let outcome = await runTask.value
        guard case .cancelled = outcome else { return XCTFail("expected cancelled, got \(outcome)") }
        XCTAssertEqual(transport.recordedCancelCount, 1)
        let drained = await shellWaitUntil { !(await backend.isEngineSlotBusy()) }
        XCTAssertTrue(drained)
    }

    func testGateBusyReportsNotStartedNeverFakeTimeout() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        // Occupy the slot with an interactive session.
        let open = ShellOpenRequest(cwd: ".", rootURL: root, sessionID: "session-held", runID: UUID())
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "$ ") }
            return nil
        }
        _ = try! await backend.openSession(open, cancellation: nil)
        transport.pollScript = nil
        let outcome = await backend.run(runRequest(root: root, gateTimeout: 0.05), cancellation: nil)
        guard case .notStarted(let reason) = outcome else { return XCTFail("expected notStarted, got \(outcome)") }
        XCTAssertTrue(reason.contains("slot is occupied"))
        XCTAssertEqual(transport.starts.count, 1, "the gated run never reached the engine")
    }

    // MARK: - Sessions

    func testOpenSessionDrainsInitialPromptAndKeepsAlive() async throws {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "sh-5.1# ") }
            return nil
        }
        let result = try await backend.openSession(
            ShellOpenRequest(command: "exec /bin/sh", cwd: ".", rootURL: root,
                             sessionID: "sess-1", runID: UUID(), conversationID: UUID()),
            cancellation: nil)
        XCTAssertTrue(result.alive)
        XCTAssertEqual(result.initialOutput, "sh-5.1# ")
        XCTAssertEqual(result.sessionID, "sess-1")
    }

    func testExchangeWritesInputAndAdvancesCursor() async throws {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "$ ") }
            if nth == 2 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "hi\r\n") }
            return nil
        }
        _ = try await backend.openSession(
            ShellOpenRequest(command: "", cwd: ".", rootURL: root, sessionID: "sess-2", runID: UUID()),
            cancellation: nil)
        let result = try await backend.exchangeSession(
            ShellExchangeRequest(sessionID: "sess-2", input: "echo hi\n", waitMs: 200, maxBytes: 64 * 1024),
            cancellation: nil)
        XCTAssertTrue(result.alive)
        XCTAssertEqual(result.output, "hi\r\n")
        XCTAssertGreaterThan(result.bytesRead, 0)
        XCTAssertEqual(transport.written.last?.bytes, Data("echo hi\n".utf8))
        XCTAssertGreaterThan(result.bytesWritten, 0)
    }

    func testSignalInterruptWritesCtrlCByteKillRequestsEngineStop() async throws {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "$ ") }
            return nil
        }
        _ = try await backend.openSession(
            ShellOpenRequest(cwd: ".", rootURL: root, sessionID: "sess-3", runID: UUID()),
            cancellation: nil)
        await backend.signalSession(sessionID: "sess-3", signal: .interrupt)
        XCTAssertEqual(transport.written.last?.bytes, Data([0x03]))
        XCTAssertEqual(transport.recordedCancelCount, 0)
        await backend.signalSession(sessionID: "sess-3", signal: .kill)
        XCTAssertEqual(transport.recordedCancelCount, 1, "TERM/KILL both map to the single engine-owned stop")
    }

    func testCloseRetainsOwnershipUntilLeaseReleased() async throws {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.releaseAfterCancel = false
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "$ ") }
            return nil
        }
        _ = try await backend.openSession(
            ShellOpenRequest(cwd: ".", rootURL: root, sessionID: "sess-4", runID: UUID()),
            cancellation: nil)
        await backend.closeSession(sessionID: "sess-4")
        XCTAssertEqual(transport.recordedCancelCount, 1)
        let unreconciled = await backend.unreconciledSessions()
        XCTAssertEqual(unreconciled.count, 1, "close is a stop REQUEST; ownership stays until release")
        // Engine proves the release.
        let engineID = unreconciled[0].engineSessionID
        transport.releaseAfterCancel = true
        transport.pollScript = nil
        _ = engineID
        let drained = await shellWaitUntil {
            let unreconciled = await backend.unreconciledSessions()
            let busy = await backend.isEngineSlotBusy()
            return unreconciled.isEmpty && !busy
        }
        XCTAssertTrue(drained)
    }

    func testResizePassesExactDimensions() async throws {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "$ ") }
            return nil
        }
        _ = try await backend.openSession(
            ShellOpenRequest(cwd: ".", rootURL: root, sessionID: "sess-5", runID: UUID()),
            cancellation: nil)
        await backend.resizeSession(sessionID: "sess-5", columns: 120, rows: 40)
        XCTAssertEqual(transport.resizes.last?.columns, 120)
        XCTAssertEqual(transport.resizes.last?.rows, 40)
    }

    func testStdinOneShotWritesThenEot() async throws {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "") }
            return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "",
                                                state: .terminated, released: true, exit: 0)
        }
        let outcome = await backend.run(runRequest(root: root, stdin: "feed me\n"), cancellation: nil)
        guard case .exited = outcome else { return XCTFail("expected exited, got \(outcome)") }
        let all = transport.written.map(\.bytes).reduce(Data(), +)
        XCTAssertEqual(all, Data("feed me\n\u{04}".utf8), "stdin rides shell.input chunks then the PTY EOT byte")
    }

    func testTransportFailureSurfacesFailedWithoutAssumingAnything() async {
        let root = try! ShellTestRoot.make()
        let (backend, transport) = makeBackend()
        transport.startError = LinuxShellTransportError.notBound
        let outcome = await backend.run(runRequest(root: root), cancellation: nil)
        guard case .failed(let message) = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertTrue(message.contains("not bound"))
        let busy = await backend.isEngineSlotBusy()
        XCTAssertFalse(busy, "a refused start must not keep the gate")
    }
}

/// Lock-guarded one-shot marker for the post-cancel poll flip (test-only,
/// region-isolation-safe: the transport script captures THIS, not the
/// transport instance).
private final class PollFlipCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    func nextIsFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        seen += 1
        return seen == 1
    }
}
