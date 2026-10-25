// SPDX-License-Identifier: MPL-2.0
// Meaningful synthetic tests for the G04 embedded terminal domain
// (job-dda32d23d55e4460): owner fencing, session settlement truth, bounded
// ring accounting, cadence parity with the ORIGINAL iOS owner, run policy
// quoting/probing, and the closed host mailbox bounds. Nothing here pokes
// the real engine: the typed transport seam is injected exactly like the
// G03 mailbox tests do.
import XCTest
import FloeCore
@testable import FloeAndroidCore
import FloeAndroidShellTools

/// Deterministic fake of the frozen engine transport: records dispatches,
/// emits scripted PTY pages, and proves settlement ONLY through the real
/// `leaseReleased` fields (EOF != exit stays test-enforced upstream).
final class FakeTerminalTransport: LinuxShellTransport, @unchecked Sendable {
    struct Dispatch { let operation: String; let payload: [String: Any] }

    private let lock = NSLock()
    private var storedDispatches: [Dispatch] = []
    var pollScript: [LinuxShellPollReply] = []
    var startReply: LinuxShellStartReply?
    var startError: Error?
    var inputError: Error?
    var resizeError: Error?
    var cancelAfterStop = true

    var dispatches: [Dispatch] { lock.lock(); defer { lock.unlock() }; return storedDispatches }

    func record(_ operation: String, _ payload: Data) {
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        lock.lock(); storedDispatches.append(Dispatch(operation: operation, payload: object)); lock.unlock()
    }

    func shellStart(_ request: LinuxShellStartRequest) async throws -> LinuxShellStartReply {
        record("shell.start", try MailboxLinuxShellTransport.jsonData(["command": request.command]))
        if let error = startError { throw error }
        return startReply ?? LinuxShellStartReply(sessionID: "engine-session-1", environmentID: "env-1")
    }

    func shellPoll(_ request: LinuxShellPollRequest) async throws -> LinuxShellPollReply {
        record("shell.poll", try MailboxLinuxShellTransport.jsonData(["sessionID": request.sessionID]))
        let reply = lock.g04Locked { pollScript.isEmpty ? nil : pollScript.removeFirst() }
        return reply ?? LinuxShellPollReply(sessionID: request.sessionID, mergedOutput: Data(),
                                             cursor: request.cursor, gapBytes: 0, more: false,
                                             droppedBytes: 0, state: .running, leaseReleased: false)
    }

    func shellInput(_ request: LinuxShellInputRequest) async throws -> LinuxShellInputReply {
        record("shell.input", try MailboxLinuxShellTransport.jsonData(
            ["sessionID": request.sessionID, "bytes": request.bytes.count]))
        if let error = inputError { throw error }
        return LinuxShellInputReply(acceptedBytes: request.bytes.count)
    }

    func shellResize(_ request: LinuxShellResizeRequest) async throws -> LinuxShellResizeReply {
        record("shell.resize", try MailboxLinuxShellTransport.jsonData(
            ["sessionID": request.sessionID, "rows": request.rows, "columns": request.columns]))
        if let error = resizeError { throw error }
        return LinuxShellResizeReply(resized: true)
    }

    func shellCancel(_ request: LinuxShellCancelRequest) async throws -> LinuxShellCancelReply {
        record("shell.cancel", try MailboxLinuxShellTransport.jsonData(["sessionID": request.sessionID]))
        return LinuxShellCancelReply(state: "stop_requested")
    }
}

private final class RecordingSink: G04TerminalEventSink, @unchecked Sendable {
    private let lock = NSLock()
    var controls: [[String: Any]] = []
    var outputs: [(token: String, seq: Int64, bytes: Data)] = []
    func emitControl(_ object: [String: Any]) {
        lock.lock(); controls.append(object); lock.unlock()
    }
    func emitOutput(sessionToken: String, seq: Int64, bytes: Data) {
        lock.lock(); outputs.append((sessionToken, seq, bytes)); lock.unlock()
    }
    func replies(ok: Bool? = nil) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return controls.filter { ($0["type"] as? String) == "actionReply"
            && (ok == nil || ($0["ok"] as? Bool) == ok) }
    }
    func statuses() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return controls.filter { ($0["type"] as? String) == "terminalStatus" }
    }
}

final class G04TerminalDomainTests: XCTestCase {
    // MARK: Cadence parity with the ORIGINAL iOS owner

    func testPollCadenceMatchesOriginalSemantics() {
        var cadence = G04TerminalPollCadence()
        // Input or output -> zero pacing (transport speed).
        XCTAssertEqual(cadence.delayAfterExchange(sentInput: true, bytesRead: 0), 0)
        XCTAssertEqual(cadence.delayAfterExchange(sentInput: false, bytesRead: 7), 0)
        // Idle rounds back off 10, 20, ..., capped at 100 ms.
        var last: UInt64 = 0
        for _ in 1..<15 { last = cadence.delayAfterExchange(sentInput: false, bytesRead: 0) }
        XCTAssertEqual(last, 100_000_000)
        // Inactive rounds back off to 150 ms; opening/exchange stays busy.
        cadence.noteLive()
        for _ in 1..<12 { _ = cadence.delayWhileInactive(opening: false, exchangeInFlight: false) }
        XCTAssertEqual(cadence.delayWhileInactive(opening: false, exchangeInFlight: false), 150_000_000)
        XCTAssertEqual(cadence.delayWhileInactive(opening: true, exchangeInFlight: false), 20_000_000)
    }

    // MARK: Backend session truth through the REAL center + backend

    private func makeCenter(transport: FakeTerminalTransport) -> ShellSessionCenter {
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: LinuxShellInjectedReadiness { true },
            configuration: AndroidLinuxShellBackend.Configuration(pollIntervalNanos: 1_000_000,
                                                                  releaseGrace: 1))
        return ShellSessionCenter(backend: backend)
    }

    func testExchangeCarriesRawTerminalBytesUnsanitized() async throws {
        // The domain forwards `terminalOutput` (raw PTY) — the ORIGINAL iOS
        // owner rule — while the model `output` stays sanitized. Prove the
        // backend keeps the raw channel exact.
        let transport = FakeTerminalTransport()
        // The ACCEPTED production openSession runs a bounded initial drain
        // that consumes whatever is already scripted (prompt semantics,
        // byte-identical to the accepted G02 backend — this cohort did not
        // change it). Keep the raw page reserved for exchange: start with an
        // empty script and queue the page only after open returns.
        let rawPage = LinuxShellPollReply(
            sessionID: "engine-session-1",
            mergedOutput: Data("\u{1B}[31msecret-prompt\u{1B}[0m\r\n".utf8),
            cursor: 19, gapBytes: 0, more: false, droppedBytes: 0,
            state: .running, leaseReleased: false)
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: LinuxShellInjectedReadiness { true },
            configuration: AndroidLinuxShellBackend.Configuration(pollIntervalNanos: 1_000_000))
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("floe-term-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let open = try await backend.openSession(ShellOpenRequest(
            command: "", cwd: ".", rootURL: root, environment: [:], columns: 80, rows: 24,
            gateTimeout: 2, sessionID: runID.uuidString.lowercased(), runID: runID,
            toolEnvironment: nil, conversationID: runID, prepareLinuxIfMissing: false),
            cancellation: nil)
        transport.pollScript = [rawPage]
        let collected = try await backend.exchangeSession(ShellExchangeRequest(
            sessionID: open.sessionID, input: nil, waitMs: 60, maxBytes: 64 * 1024),
            cancellation: nil)
        XCTAssertEqual(collected.terminalOutput,
                       Data("\u{1B}[31msecret-prompt\u{1B}[0m\r\n".utf8))
    }

    // MARK: Host mailbox bounds + closed grammar

    func testMailboxRefusesBeforeQueueing() {
        let mailbox = G04TerminalHostMailbox()
        // Unbound: every action refuses without queueing.
        let descriptor = Data("{\"action\":\"capabilities\",\"requestID\":\"r1\"}".utf8)
        XCTAssertLessThan(mailbox.submitAction(descriptor: descriptor, payload: nil), 0)
        // Bind with a positive epoch (no live-root cross-check at the
        // class level; the @_cdecl export performs that one).
        XCTAssertTrue(mailbox.bind(newEpoch: 999_997))
        // Oversized control descriptor is refused, not truncated.
        let huge = Data(repeating: 0x41, count: G04TerminalHostLimits.maximumFrameBytes + 1)
        XCTAssertEqual(mailbox.submitAction(descriptor: huge, payload: nil), -106)
        let hugePayload = Data(repeating: 0x42, count: G04TerminalHostLimits.maximumPayloadBytes + 1)
        XCTAssertEqual(mailbox.submitAction(descriptor: descriptor, payload: hugePayload), -107)
        // A stale-epoch close cannot fence a live generation.
        XCTAssertFalse(mailbox.close(closingEpoch: 123))
        // Exact-epoch close fences; actions refuse afterwards.
        XCTAssertTrue(mailbox.close(closingEpoch: 999_997))
        XCTAssertLessThan(mailbox.submitAction(descriptor: descriptor, payload: nil), 0)
    }

    func testOlderEpochRebindIsRefused() {
        let mailbox = G04TerminalHostMailbox()
        XCTAssertTrue(mailbox.bind(newEpoch: 500))
        XCTAssertFalse(mailbox.bind(newEpoch: 500))
        XCTAssertFalse(mailbox.bind(newEpoch: 499))
        _ = mailbox.close(closingEpoch: 500)
    }

    func testOutputEventRingEvictsOnlyOutputAndCounts() {
        let mailbox = G04TerminalHostMailbox()
        XCTAssertTrue(mailbox.bind(newEpoch: 700))
        // Fill with output events beyond the live cap.
        for index in 0..<(G04TerminalHostLimits.maximumLiveEvents + 8) {
            mailbox.emitOutput(sessionToken: "t1", seq: Int64(index),
                               bytes: Data(repeating: 0x5A, count: 1024))
        }
        // Then a control event: it must never be evicted by output pressure.
        mailbox.emitControl(["type": "actionReply", "requestID": "keep", "ok": true])
        let stats = mailbox.statsJSON()
        XCTAssertTrue(stats.contains("evictedOutput"))
        // Drain everything: the control event survived and output seq gaps
        // are honest (the renderer tolerates by seq).
        var sawControl = false
        while true {
            let event = mailbox.nextEvent(timeoutMillis: 0)
            if event <= 0 { break }
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = mailbox.describe(event: event, buffer: &buffer, capacity: Int32(buffer.count))
            if length > 0 {
                let text = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
                                  as: UTF8.self)
                if text.contains("\"keep\"") { sawControl = true }
            }
            XCTAssertEqual(mailbox.ack(event: event), 0)
        }
        XCTAssertTrue(sawControl)
        _ = mailbox.close(closingEpoch: 700)
    }

    // MARK: Run policy (ported ORIGINAL table)

    func testRunPolicyQuotingAndProbing() throws {
        // CJK filename with a quote and a space rides one escaped element.
        let command = try G04LanguageRunPolicy.startCommand(languageID: "python",
                                                            relativePath: "笔记/it's here.py")
        XCTAssertTrue(command.contains("command -v 'python3'"))
        XCTAssertTrue(command.contains("'\\''"))   // the quote-escape idiom
        XCTAssertTrue(command.hasPrefix("if !"))
        // Traversal / absolute paths refuse before any command is built.
        XCTAssertThrowsError(try G04LanguageRunPolicy.plan(languageID: "python",
                                                            relativePath: "/etc/passwd"))
        XCTAssertThrowsError(try G04LanguageRunPolicy.plan(languageID: "python",
                                                            relativePath: "../escape.py"))
        XCTAssertThrowsError(try G04LanguageRunPolicy.plan(languageID: "ruby", relativePath: "a.rb"))
        // C plans compile into guest scratch, never the workspace.
        let cCommand = try G04LanguageRunPolicy.startCommand(languageID: "c", relativePath: "main.c")
        XCTAssertTrue(cCommand.contains("/tmp/.floe-run.out"))
        XCTAssertTrue(cCommand.contains("trap 'rm -f /tmp/.floe-run.out' EXIT"))
    }

    func testShellQuoteIsElementWise() {
        XCTAssertEqual(G04LanguageRunPolicy.shellQuote("plain"), "'plain'")
        XCTAssertEqual(G04LanguageRunPolicy.shellQuote("a b"), "'a b'")
        XCTAssertEqual(G04LanguageRunPolicy.shellQuote("it's"), "'it'\\''s'")
    }

    // MARK: Token sanitizer

    func testFaultTokenIsBoundedAndSafe() {
        let token = G04TerminalStore.faultToken("engine reported the request failed (code=operation_failed)")
        XCTAssertLessThanOrEqual(token.count, 128)
        XCTAssertTrue(token.allSatisfy { !$0.isWhitespace || $0 == "_" })
    }

    // MARK: Single engine slot truth (device 2026-10-25: Retry/run/reset refusals)

    func testOpenSessionRefusesWhileSingleEngineSlotHeld() async throws {
        // The single runtime-UID workload gate is held by a live session: a
        // second interactive open must refuse with the occupied-slot error
        // and dispatch NO second shell.start. This is the exact condition
        // the G04 lanes now surface pre-dispatch as typed saturated /
        // engineSlotBusy (terminal open, run draft, LSP start) instead of
        // collapsing into a generic backendFailed after the gate timeout.
        let transport = FakeTerminalTransport()
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: LinuxShellInjectedReadiness { true },
            configuration: AndroidLinuxShellBackend.Configuration(pollIntervalNanos: 1_000_000))
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("floe-slot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runA = UUID()
        _ = try await backend.openSession(ShellOpenRequest(
            command: "", cwd: ".", rootURL: root, environment: [:], columns: 80, rows: 24,
            gateTimeout: 2, sessionID: runA.uuidString.lowercased(), runID: runA,
            toolEnvironment: nil, conversationID: runA, prepareLinuxIfMissing: false),
            cancellation: nil)
        let slotIsBusy = await backend.isEngineSlotBusy()
        XCTAssertTrue(slotIsBusy)
        let runB = UUID()
        do {
            _ = try await backend.openSession(ShellOpenRequest(
                command: "", cwd: ".", rootURL: root, environment: [:], columns: 80, rows: 24,
                gateTimeout: 0.2, sessionID: runB.uuidString.lowercased(), runID: runB,
                toolEnvironment: nil, conversationID: runB, prepareLinuxIfMissing: false),
                cancellation: nil)
            XCTFail("the second open must refuse while the single slot is held")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("single Linux workload slot is occupied"),
                          String(describing: error))
        }
        XCTAssertEqual(transport.dispatches.filter { $0.operation == "shell.start" }.count, 1,
                       "the refused open must never reach the engine transport")
    }
}
