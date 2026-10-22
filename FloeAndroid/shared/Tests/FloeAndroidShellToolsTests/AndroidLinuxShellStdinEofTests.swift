// SPDX-License-Identifier: MPL-2.0
//
// R3 one-shot stdin REAL-EOF caller regression (job-c012c50e636f4fbb).
// LIVE in shared/Tests after Main's ingest (export snapshot retained at
// r3/stdin-eof-caller, digest 5849d779…). The host-focused-04 crash round
// (job-fa9b8d7b2984484e, r3/eof-host-behavior) strengthened this file:
// the fake transport now gates NATURAL lease release on the EOF command
// actually having been recorded (a cat-like child cannot exit before the
// pipe descriptor closes), and page indexing is behind observable
// count guards so a contract mismatch fails instead of trapping
// (ContiguousArrayBuffer "Index out of range" killed the whole Shell
// suite). The paired production repair keeps the engine's documented
// EAGAIN/partial cursor contract: errno=11 on a partial data reply means
// "re-send only the remainder", not a terminal write failure
// (AndroidLinuxShellBackend.writeInput).
//
// Self-contained on purpose: it declares its OWN fake transport and
// fixtures and depends on NO other test-target file, so it cannot collide
// with the moving Core-owned support (FakeLinuxShellTransport etc.).
// Everything here is synthetic data + a typed-protocol stand-in: no device,
// no engine, no process, no network, no credentials.
//
// Covered caller contracts (stdin-eof-patch CONTRACT.md §5 plus the APPLIED
// LinuxRuntimeOperations.kt reply shapes):
// * one-shot run() starts with stdinDelivery == .pipe; interactive
//   openSession() leaves the field nil (wire key omitted → engine "pty").
// * nil / empty / nonempty stdin are each followed by EXACTLY ONE trailing
//   EMPTY shell.input page (the real EOF command), never routed through
//   writeInput's data paging + acceptedBytes==0 no-progress guard, and
//   never an EOT byte: an embedded literal 0x04 stays ordinary data inside
//   a data page; no standalone Data([0x04]) page is ever emitted.
// * EOF replies: closed / closed-idempotent → no note; failed → honest
//   errno note; rejected (+reason) → honest note; unknown / absent →
//   unconfirmed note; transport failure → request-failed note. None of
//   them fabricates delivery success and none replaces the engine terminal
//   proof: output + exit still settle from the leaseReleased page.
// * data-page accepted/partial cursor honored (short writes resume at the
//   cursor; oversized stdin pages at the 16 KiB engine bound), and
//   cancellation during input stops at the cursor while EOF is still
//   commanded once and the run settles .cancelled via shell.cancel.
// * legacy interactive semantics unchanged: no automatic EOF page, Ctrl-C
//   still rides a 0x03 data write, close still rides the one shell.cancel.
// * engine wire vocabulary honored by the fixture: a partial data reply
//   may carry errno=11 (EAGAIN) with a positive progress cursor — the
//   caller re-sends only the remainder — while any other errno is an
//   honest terminal (Failed reply shape carries no partial flag).
// * deterministic lifecycle sync (no sleeps-until-green): one-shot tests
//   arm `catTerminalText`, and the fake refuses to announce a natural
//   released terminal until the session's EMPTY EOF page is recorded.
//   Because production run() commands EOF before its first poll, this
//   never delays a correct caller; a future regression that skipped the
//   always-EOF contract would settle as an observable bounded-wait failure
//   instead of silently passing. The early-exit rejection test keeps its
//   intentionally distinct immediate-release script.

import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

// MARK: - Scripted reply shapes (mirroring the applied engine data)

private struct StdinEofDataReply {
    var acceptedBytes: Int
    var partial: Bool = false
    var errnoCode: Int32? = nil
}

private struct StdinEofEofReply {
    /// nil models an EOF page whose reply carries no stdinEof field (a
    /// transport that has not decoded it, or a PTY no-op data page).
    var stdinEof: String?
    var errnoCode: Int32? = nil
    var reason: String? = nil
}

// MARK: - Private fake transport (no dependency on other test files)

private final class StdinEofFakeTransport: LinuxShellTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [LinuxShellStartRequest] = []
    private var pages: [(sessionID: String, bytes: Data)] = []
    private var cancels: [LinuxShellCancelRequest] = []
    private var pollsPerSession: [String: Int] = [:]

    /// 1-based recorded-page index → scripted data reply.
    /// nil → accept the whole page (unchanged legacy engine success shape).
    var dataScript: (@Sendable (Int, Data) -> StdinEofDataReply?)?
    /// Fired (outside the lock) right after the nth data page is recorded.
    var afterDataPage: (@Sendable (Int) -> Void)?
    /// Scripted answer to the EMPTY EOF command page.
    var eofReply: StdinEofEofReply = StdinEofEofReply(stdinEof: "closed")
    /// Optional transport error for the EOF request (settles before reply).
    var eofError: Error?
    /// nth poll for a session → scripted page; nil → scripted default below.
    var pollScript: (@Sendable (String, UInt64, Int) -> LinuxShellPollReply?)?
    /// Lifecycle gate for cat-like one-shot commands: when set, the fake
    /// reports the child RUNNING until the session's EMPTY EOF command page
    /// is recorded, and only THEN releases the lease with this engine text.
    /// A pipe-fed `cat`-like child cannot reach its natural terminal before
    /// the descriptor EOF exists, so an unconditional immediate release
    /// would let a regression that skips EOF settle anyway. This is
    /// deterministic state, not a sleep/retry-until-green: production
    /// commands EOF before its first poll, so a correct caller sees the
    /// release on poll #1 exactly as before.
    var catTerminalText: String?
    private var eofCommandedSessions: Set<String> = []

    func shellStart(_ request: LinuxShellStartRequest) async throws -> LinuxShellStartReply {
        let index = startStepLocked(request)
        return LinuxShellStartReply(sessionID: "lease-\(index)-stdin-eof-fake",
                                    environmentID: request.environmentID ?? "linux.local")
    }

    private func startStepLocked(_ request: LinuxShellStartRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        starts.append(request)
        return starts.count
    }

    func shellInput(_ request: LinuxShellInputRequest) async throws -> LinuxShellInputReply {
        if request.bytes.isEmpty {
            // EMPTY PAGE ON A PIPE SESSION = the EOF command; the real
            // engine answers stdinEof here, never data acceptance.
            let (error, reply) = eofStepLocked(request.sessionID)
            if let error { throw error }
            return LinuxShellInputReply(acceptedBytes: 0, partial: false,
                                        errnoCode: reply.errnoCode,
                                        stdinEof: reply.stdinEof,
                                        stdinEofReason: reply.reason)
        }
        let step = dataStepLocked(request)
        step.hook?(step.nth)
        return LinuxShellInputReply(acceptedBytes: step.reply.acceptedBytes,
                                    partial: step.reply.partial,
                                    errnoCode: step.reply.errnoCode)
    }

    private struct DataStep {
        let nth: Int
        let reply: StdinEofDataReply
        let hook: (@Sendable (Int) -> Void)?
    }

    private func dataStepLocked(_ request: LinuxShellInputRequest) -> DataStep {
        lock.lock(); defer { lock.unlock() }
        pages.append((request.sessionID, request.bytes))
        let nth = pages.count
        let scriptedRaw: StdinEofDataReply?
        if let script = dataScript {
            scriptedRaw = script(nth, request.bytes)
        } else {
            scriptedRaw = nil
        }
        let scripted = scriptedRaw ?? StdinEofDataReply(acceptedBytes: request.bytes.count)
        let reply = StdinEofDataReply(acceptedBytes: min(scripted.acceptedBytes, request.bytes.count),
                                      partial: scripted.partial,
                                      errnoCode: scripted.errnoCode)
        return DataStep(nth: nth, reply: reply, hook: afterDataPage)
    }

    private func eofStepLocked(_ sessionID: String) -> (Error?, StdinEofEofReply) {
        lock.lock(); defer { lock.unlock() }
        pages.append((sessionID, Data()))
        // The command EXISTS from this point on, even when its reply errors
        // or reports failed/rejected: the child's natural-terminal gate
        // opens, and honesty lives in the note, not in hiding the attempt.
        eofCommandedSessions.insert(sessionID)
        return (eofError, eofReply)
    }

    func shellPoll(_ request: LinuxShellPollRequest) async throws -> LinuxShellPollReply {
        let step = pollStepLocked(request)
        if let scripted = step.scripted { return scripted }
        if step.stopRequested {
            // A recorded stop releases as the engine truth: cancelled +
            // user-stop, synced, whole-UID quiescence proven.
            return LinuxShellPollReply(sessionID: request.sessionID, mergedOutput: Data(),
                                       cursor: request.cursor, gapBytes: 0, more: false,
                                       droppedBytes: 0, state: .terminated, leaseReleased: true,
                                       cancelled: true, stopReason: "user-stop",
                                       exitCode: nil, termSig: 2, waitErrno: nil,
                                       workspaceStatus: "synced")
        }
        if let text = step.naturalTerminal {
            // The EOF command exists for this session: the cat-like child
            // now exits naturally and the engine releases the lease with
            // its real terminal evidence.
            return StdinEofFixtures.releasedPage(session: request.sessionID,
                                                 cursor: request.cursor, text: text)
        }
        return LinuxShellPollReply(sessionID: request.sessionID, mergedOutput: Data(),
                                   cursor: request.cursor, gapBytes: 0, more: false,
                                   droppedBytes: 0, state: .running, leaseReleased: false)
    }

    private func pollStepLocked(_ request: LinuxShellPollRequest)
        -> (scripted: LinuxShellPollReply?, stopRequested: Bool,
            naturalTerminal: String?) {
        lock.lock(); defer { lock.unlock() }
        let nth = (pollsPerSession[request.sessionID] ?? 0) + 1
        pollsPerSession[request.sessionID] = nth
        let scripted: LinuxShellPollReply?
        if let script = pollScript {
            scripted = script(request.sessionID, request.cursor, nth)
        } else {
            scripted = nil
        }
        let stopRequested = cancels.contains { $0.sessionID == request.sessionID }
        // Gated natural terminal: released only once the EOF page is
        // recorded; otherwise the default RUNNING page below applies.
        let naturalTerminal = eofCommandedSessions.contains(request.sessionID)
            ? catTerminalText : nil
        return (scripted, stopRequested, naturalTerminal)
    }

    func shellResize(_ request: LinuxShellResizeRequest) async throws -> LinuxShellResizeReply {
        recordResizeLocked(request)
        return LinuxShellResizeReply(resized: true)
    }

    private var resizes: [LinuxShellResizeRequest] = []
    private func recordResizeLocked(_ request: LinuxShellResizeRequest) {
        lock.lock(); resizes.append(request); lock.unlock()
    }

    func shellCancel(_ request: LinuxShellCancelRequest) async throws -> LinuxShellCancelReply {
        recordCancelLocked(request)
        return LinuxShellCancelReply(state: "stop_requested")
    }

    private func recordCancelLocked(_ request: LinuxShellCancelRequest) {
        lock.lock(); cancels.append(request); lock.unlock()
    }

    // Lock-guarded views (Swift 6 race-safe synchronous sections).
    var recordedStarts: [LinuxShellStartRequest] {
        lock.lock(); defer { lock.unlock() }; return starts
    }
    var recordedPages: [(sessionID: String, bytes: Data)] {
        lock.lock(); defer { lock.unlock() }; return pages
    }
    var recordedCancelCount: Int {
        lock.lock(); defer { lock.unlock() }; return cancels.count
    }
    var recordedEmptyPageCount: Int {
        recordedPages.filter { $0.bytes.isEmpty }.count
    }
}

// MARK: - Fixtures

private struct StdinEofQualifiedReadiness: LinuxShellReadiness {
    var isQualifiedForLinuxShell: Bool { true }
    var refusalGuidance: String { "test: linux engine not qualified" }
}

private enum StdinEofFixtures {
    static func makeBackend() -> (AndroidLinuxShellBackend, StdinEofFakeTransport) {
        let fake = StdinEofFakeTransport()
        let backend = AndroidLinuxShellBackend(
            transport: fake,
            readiness: StdinEofQualifiedReadiness(),
            configuration: AndroidLinuxShellBackend.Configuration(
                pollIntervalNanos: 1_000_000,
                releaseGrace: 2,
                stdinWriteRetries: 8,
                reconcileIntervalNanos: 50_000_000,
                reconcileObservation: 2))
        return (backend, fake)
    }

    static func makeRoot(name: String = "workspace") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-stdin-eof-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func runRequest(root: URL, stdin: String?,
                           sessionID: String = "run:stdin-eof:call",
                           timeout: TimeInterval = 10) -> ShellRunRequest {
        ShellRunRequest(command: "cat /dev/stdin", cwd: ".", rootURL: root,
                        environment: [:], stdin: stdin,
                        timeout: timeout, gateTimeout: 2,
                        maxOutputBytes: 64 * 1024, sessionID: sessionID,
                        runID: UUID(), toolEnvironment: nil,
                        conversationID: UUID())
    }

    /// Engine truth: real terminal, reaped root child, workspace synced.
    static func releasedPage(session: String, cursor: UInt64, text: String) -> LinuxShellPollReply {
        let bytes = Data(text.utf8)
        return LinuxShellPollReply(sessionID: session, mergedOutput: bytes,
                                   cursor: cursor + UInt64(bytes.count), gapBytes: 0,
                                   more: false, droppedBytes: 0, state: .terminated,
                                   leaseReleased: true, cancelled: false, stopReason: nil,
                                   exitCode: 0, termSig: 0, waitErrno: nil,
                                   workspaceStatus: "synced")
    }

    static func runningPage(session: String, cursor: UInt64, text: String,
                            more: Bool = false) -> LinuxShellPollReply {
        let bytes = Data(text.utf8)
        return LinuxShellPollReply(sessionID: session, mergedOutput: bytes,
                                   cursor: cursor + UInt64(bytes.count), gapBytes: 0,
                                   more: more, droppedBytes: 0, state: .running,
                                   leaseReleased: false)
    }
}

// MARK: - Non-trapping page extraction
//
// A direct `pages[i]` subscript after a merely non-fatal count assertion is
// what crashed the whole host Shell suite once (ContiguousArrayBuffer
// "Index out of range", host-focused-04). The count assertion stays
// REQUIRED and observable — a mismatch records a failure and the test
// RETURNS instead of trapping; the indexed content expectations are kept
// unchanged and only run on a page list long enough to hold them.
private func stdinEofPages(_ fake: StdinEofFakeTransport,
                           expectedCount: Int,
                           _ explanation: String,
                           file: StaticString = #filePath,
                           line: UInt = #line) -> [(sessionID: String, bytes: Data)]? {
    let pages = fake.recordedPages
    XCTAssertEqual(pages.count, expectedCount, explanation, file: file, line: line)
    guard pages.count >= expectedCount else { return nil }
    return pages
}

// MARK: - Tests

final class AndroidLinuxShellStdinEofTests: XCTestCase {

    // MARK: one-shot mode selection + always-explicit EOF

    func testNilStdinSelectsPipeAndCommandsExactlyOneEmptyEofPage() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        fake.catTerminalText = "done\n"
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(StdinEofFixtures.runRequest(root: root, stdin: nil),
                                        cancellation: nil)
        guard case .exited(let code, let stdout, let stderr, _, _, _) = outcome else {
            return XCTFail("expected a real engine exit, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout, "done\n", "engine terminal evidence is the only outcome source")
        XCTAssertEqual(stderr, "", "confirmed EOF must add no metadata note")
        let starts = fake.recordedStarts
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].stdinDelivery, .pipe,
                       "the trusted platform one-shot adapter selects the descriptor pipe")
        guard let pages = stdinEofPages(fake, expectedCount: 1,
                                        "nil stdin still commands exactly one EOF page and no data")
        else { return }
        XCTAssertTrue(pages[0].bytes.isEmpty, "the EOF page is zero bytes, intentional")
        // Lease/gate fully released on the real terminal, not on the EOF.
        let slotBusyAfterExit = await backend.isEngineSlotBusy()
        XCTAssertFalse(slotBusyAfterExit)
    }

    func testEmptyStringStdinCommandsEofNotWriteInputNoProgressGuard() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        fake.catTerminalText = "ok\n"
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(StdinEofFixtures.runRequest(root: root, stdin: ""),
                                        cancellation: nil)
        guard case .exited(_, let stdout, let stderr, _, _, _) = outcome else {
            return XCTFail("expected a real engine exit, got \(outcome)")
        }
        XCTAssertEqual(stdout, "ok\n")
        XCTAssertEqual(stderr, "",
                       "EOF must bypass the data paging no-progress guard: an empty page "
                       + "is the intentional EOF command, never a -4 error and never dropped")
        guard let pages = stdinEofPages(fake, expectedCount: 1,
                                        "empty stdin commands exactly one empty EOF page")
        else { return }
        XCTAssertTrue(pages[0].bytes.isEmpty)
    }

    func testNonemptyStdinPagesThenOneEofPageWithLiteralEotAsData() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        fake.catTerminalText = "echoed\n"
        let payload = "alpha\n\u{0004}beta\n"
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(StdinEofFixtures.runRequest(root: root, stdin: payload),
                                        cancellation: nil)
        guard case .exited(let code, let stdout, let stderr, _, _, _) = outcome else {
            return XCTFail("expected a real engine exit, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout, "echoed\n")
        XCTAssertEqual(stderr, "")
        guard let pages = stdinEofPages(fake, expectedCount: 2,
                                        "one data page then exactly one EOF page") else { return }
        XCTAssertEqual(pages[0].bytes, Data(payload.utf8),
                       "the whole stdin INCLUDING the literal 0x04 byte rides as ordinary data")
        XCTAssertTrue(pages[0].bytes.contains(0x04))
        XCTAssertFalse(pages.contains { $0.bytes == Data([0x04]) },
                       "the deleted EOT emulation must never return as a standalone page")
        XCTAssertTrue(pages[1].bytes.isEmpty, "EOF is the trailing zero-byte command page")
    }

    func testOversizedStdinPagesAtEngineBoundThenExactlyOneEofPage() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        fake.catTerminalText = ""
        let payload = String(repeating: "a", count: 40_000)
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(StdinEofFixtures.runRequest(root: root, stdin: payload),
                                        cancellation: nil)
        guard case .exited(_, _, let stderr, _, _, _) = outcome else {
            return XCTFail("expected a real engine exit, got \(outcome)")
        }
        XCTAssertEqual(stderr, "")
        guard let pages = stdinEofPages(fake, expectedCount: 4,
                                        "16384 + 16384 + 7232 data pages + one EOF page")
        else { return }
        XCTAssertEqual(pages[0].bytes.count, 16_384)
        XCTAssertEqual(pages[1].bytes.count, 16_384)
        XCTAssertEqual(pages[2].bytes.count, 7_232)
        XCTAssertTrue(pages[3].bytes.isEmpty)
        let delivered = pages[0...2].reduce(Data()) { $0 + $1.bytes }
        XCTAssertEqual(delivered, Data(payload.utf8), "paging preserves the full byte stream")
    }

    // MARK: EOF reply honesty (never success, never an exit substitute)

    func testEofClosedIdempotentIsConfirmedWithoutNote() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        fake.eofReply = StdinEofEofReply(stdinEof: "closed-idempotent")
        fake.catTerminalText = "x\n"
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(StdinEofFixtures.runRequest(root: root, stdin: nil),
                                        cancellation: nil)
        guard case .exited(_, _, let stderr, _, _, _) = outcome else {
            return XCTFail("expected a real engine exit, got \(outcome)")
        }
        XCTAssertEqual(stderr, "", "closed-idempotent is a confirmed close")
    }

    func testEofFailedAddsHonestErrnoNoteAndKeepsRealExit() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        fake.eofReply = StdinEofEofReply(stdinEof: "failed", errnoCode: 32)
        fake.catTerminalText = "out\n"
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(StdinEofFixtures.runRequest(root: root, stdin: "in\n"),
                                        cancellation: nil)
        guard case .exited(let code, let stdout, let stderr, _, _, _) = outcome else {
            return XCTFail("a failed EOF close must not replace the engine terminal, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout, "out\n", "the real output/exit is never lost to an EOF note")
        XCTAssertTrue(stderr.hasPrefix("[metadata]"), "backend metadata is labelled, never merged")
        XCTAssertTrue(stderr.contains("stdin EOF close failed"))
        XCTAssertTrue(stderr.contains("errno=32"))
        XCTAssertFalse(stderr.contains("confirmed"), "no delivery success is invented")
    }

    func testEofRejectedAfterFastExitPreservesTerminalEvidence() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        fake.eofReply = StdinEofEofReply(
            stdinEof: "rejected",
            reason: "job is terminated; lifecycle owns the stdin descriptor")
        // INTENTIONALLY distinct from the gated cat fixtures: this child
        // exits BEFORE the caller's EOF page, so the engine already owns
        // the descriptor and releases the lease immediately — the EOF
        // command is honestly rejected, never silently dropped or re-
        // labelled. The run must still settle on this real terminal.
        fake.pollScript = { session, cursor, _ in
            StdinEofFixtures.releasedPage(session: session, cursor: cursor, text: "bye\n")
        }
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(StdinEofFixtures.runRequest(root: root, stdin: nil),
                                        cancellation: nil)
        guard case .exited(let code, let stdout, let stderr, _, _, _) = outcome else {
            return XCTFail("an early-exited command must keep its real terminal, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout, "bye\n", "EOF != exit: the engine terminal is the only exit source")
        XCTAssertTrue(stderr.hasPrefix("[metadata]"))
        XCTAssertTrue(stderr.contains("engine rejected"))
        XCTAssertTrue(stderr.contains("lifecycle owns the stdin descriptor"),
                      "the bounded engine reason rides through unchanged")
        XCTAssertFalse(stderr.contains("delivered as a command (engine closed"))
    }

    func testEofAbsentReplyIsUnconfirmedNotSuccess() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        // Models a reply from a transport that has not decoded stdinEof
        // yet (e.g. the mailbox mapping still pending): honest note only.
        fake.eofReply = StdinEofEofReply(stdinEof: nil)
        fake.catTerminalText = "y\n"
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(StdinEofFixtures.runRequest(root: root, stdin: nil),
                                        cancellation: nil)
        guard case .exited(_, _, let stderr, _, _, _) = outcome else {
            return XCTFail("expected a real engine exit, got \(outcome)")
        }
        XCTAssertTrue(stderr.contains("unconfirmed"),
                      "an EOF reply without stdinEof is never treated as delivery success")
        XCTAssertTrue(stderr.contains("no delivery was assumed"))
    }

    func testEofTransportFailureNoteKeepsExit() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        fake.eofError = LinuxShellTransportError.remoteFailed(code: "operation_failed")
        fake.catTerminalText = "z\n"
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(StdinEofFixtures.runRequest(root: root, stdin: nil),
                                        cancellation: nil)
        guard case .exited(_, let stdout, let stderr, _, _, _) = outcome else {
            return XCTFail("expected a real engine exit, got \(outcome)")
        }
        XCTAssertEqual(stdout, "z\n")
        XCTAssertTrue(stderr.contains("stdin EOF request failed"))
        XCTAssertTrue(stderr.contains("operation_failed"))
    }

    // MARK: data-cursor + write-failure honesty preserved alongside EOF

    func testBackpressureShortWritesResumeAtCursorThenOneEofPage() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        // Real engine shape for a full pipe: the native pump retries EAGAIN
        // inside its OWN bounded budget, then answers Partial with the
        // progress cursor AND errno=11 on the wire (CONTRACT: "errno is now
        // also present on partial"; "the caller re-sends only the remainder
        // after partial/errno"). The Swift caller must therefore resume at
        // the cursor — NOT abort the remaining stdin as a terminal failure.
        fake.dataScript = { nth, _ in
            switch nth {
            case 1: return StdinEofDataReply(acceptedBytes: 3, partial: true, errnoCode: 11)
            default: return nil  // full accept
            }
        }
        fake.catTerminalText = "got\n"
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(
            StdinEofFixtures.runRequest(root: root, stdin: "hello world"),
            cancellation: nil)
        guard case .exited(_, _, let stderr, _, _, _) = outcome else {
            return XCTFail("expected a real engine exit, got \(outcome)")
        }
        XCTAssertEqual(stderr, "", "bounded partial retries that complete are not a failure")
        guard let pages = stdinEofPages(fake, expectedCount: 3,
                                        "first page, cursor-resumed remainder, EOF page")
        else { return }
        XCTAssertEqual(pages[0].bytes, Data("hello world".utf8))
        XCTAssertEqual(pages[1].bytes, Data("lo world".utf8),
                       "the accepted-bytes cursor is honored: never duplicated, never dropped")
        XCTAssertTrue(pages[2].bytes.isEmpty)
    }

    func testIncompleteWriteNoteAndFailedEofNoteBothSurface() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        // Engine Failed shape: EPIPE with zero accepted bytes carries the
        // errno but NOT the partial flag (only Partial-with-progress does).
        // A non-EAGAIN errno is an honest terminal — bounded by definition,
        // and the retry ceiling (local -2) still bounds genuine EAGAIN
        // stalls in the backpressure contract above.
        fake.dataScript = { _, _ in
            StdinEofDataReply(acceptedBytes: 0, errnoCode: 32)
        }
        fake.eofReply = StdinEofEofReply(stdinEof: "failed", errnoCode: 9)
        fake.catTerminalText = "t\n"  // command still completes honestly
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(
            StdinEofFixtures.runRequest(root: root, stdin: "some data"),
            cancellation: nil)
        guard case .exited(_, _, let stderr, _, _, _) = outcome else {
            return XCTFail("expected the real engine terminal, got \(outcome)")
        }
        XCTAssertTrue(stderr.contains("stdin write incomplete"),
                      "the honest write note is preserved")
        XCTAssertTrue(stderr.contains("stdin EOF close failed"),
                      "the EOF state is reported alongside, never instead")
        XCTAssertTrue(stderr.hasPrefix("[metadata]"))
    }

    // MARK: cancellation during input

    func testCancellationDuringInputStopsAtCursorStillCommandsEofAndCancelsOnce() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        let token = CancellationToken()
        fake.afterDataPage = { nth in
            if nth == 1 { token.cancel() }
        }
        let payload = String(repeating: "b", count: 20_000)
        let root = try StdinEofFixtures.makeRoot()
        let outcome = await backend.run(
            StdinEofFixtures.runRequest(root: root, stdin: payload),
            cancellation: token)
        XCTAssertEqual(outcome, .cancelled,
                       "a cancelled run is honest .cancelled — EOF never fakes a stop or exit")
        guard let pages = stdinEofPages(fake, expectedCount: 2,
                                        "one data page (cursor honored), then the explicit "
                                        + "EOF command") else { return }
        XCTAssertEqual(pages[0].bytes.count, 16_384)
        XCTAssertTrue(pages[1].bytes.isEmpty)
        XCTAssertEqual(fake.recordedCancelCount, 1,
                       "exactly one engine stop REQUEST; release is the poll's proof")
    }

    // MARK: interactive legacy semantics unchanged

    func testInteractiveSessionsOmitStdinDeliveryAndNeverCommandEofPages() async throws {
        let (backend, fake) = StdinEofFixtures.makeBackend()
        fake.pollScript = { session, cursor, nth in
            if nth == 1 {
                return StdinEofFixtures.runningPage(session: session, cursor: cursor,
                                                    text: "$ ")
            }
            return nil  // defaults: running empty before stop, released after stop
        }
        let root = try StdinEofFixtures.makeRoot()
        let open = try await backend.openSession(
            ShellOpenRequest(command: "", cwd: ".", rootURL: root,
                             sessionID: "sess-stdin-eof", runID: UUID()),
            cancellation: nil)
        XCTAssertTrue(open.alive)
        XCTAssertEqual(open.initialOutput, "$ ")
        let starts = fake.recordedStarts
        XCTAssertEqual(starts.count, 1)
        XCTAssertNil(starts[0].stdinDelivery,
                     "interactive open MUST stay legacy PTY: the wire key is omitted, never null")

        _ = try await backend.exchangeSession(
            ShellExchangeRequest(sessionID: "sess-stdin-eof", input: "echo hi\n",
                                 waitMs: 150, maxBytes: 4096),
            cancellation: nil)
        await backend.signalSession(sessionID: "sess-stdin-eof", signal: .interrupt)

        let pages = fake.recordedPages
        XCTAssertEqual(pages.map { $0.bytes },
                       [Data("echo hi\n".utf8), Data([0x03])],
                       "legacy interactive input and Ctrl-C ride unchanged data pages")
        XCTAssertTrue(pages.allSatisfy { !$0.bytes.isEmpty },
                      "interactive sessions never command the pipe EOF page")
        let ownedSessions = await backend.ownedSessions()
        XCTAssertTrue(ownedSessions.contains { $0.sessionKey == "sess-stdin-eof" },
                      "the session stays owned until a real release")
        await backend.closeSession(sessionID: "sess-stdin-eof")
        XCTAssertEqual(fake.recordedCancelCount, 1, "close is the one engine stop request")
        // The reconciliation settles the release on the fake's post-stop default.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let busy = await backend.isEngineSlotBusy()
            if !busy { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let busyAfterClose = await backend.isEngineSlotBusy()
        XCTAssertFalse(busyAfterClose)
    }
}
