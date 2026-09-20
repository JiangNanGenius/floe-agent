// ChannelRouterCheck — host-side transport/router check for the Floe Linux
// guest command channel (protocol 3).
//
// The check compiles the *production* `LinuxGuestCommandChannel` (extracted
// verbatim from FloeExecution/Linux/LinuxGuestCommandChannel.swift by
// host_protocol_check.sh, together with its real supporting types) and drives
// it through a scripted `LinuxGuestConsoleTransport`. Unlike a parser-only
// test this exercises the real actor: the token router, the per-token bounded
// streams, capability negotiation, targeted cancellation bookkeeping and the
// interactive-session pump.
//
// What it proves:
//   * HELLO/CAPS negotiation and the fail-closed legacy-runner path;
//   * the router preserves raw 0x1e bytes and output-leading newlines that
//     are not valid FLOE frames, while demultiplexing real frames by token;
//   * interleaved command output is routed per token with no cross-talk;
//   * a timeout/cancellation sends FLOE-SIGNAL INT and keeps the token
//     registered until the guest answers END (reaped) or FAILED (quarantine);
//     an unanswered interrupt fails as quarantine, never as "stopped";
//   * an output-less or failed PTY session still resolves (no hang) and a
//     session FAILED is a distinct failure, not a terminal exit.
//
// Usage: channel-router-check

import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - check recorder

enum CheckFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _passes = 0
    private var _failures: [String] = []

    var passes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _passes
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _failures
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        lock.lock()
        defer { lock.unlock() }
        if condition {
            _passes += 1
        } else {
            _failures.append(message())
        }
    }

    private func recordPass() {
        lock.lock()
        defer { lock.unlock() }
        _passes += 1
    }

    private func markAborted() {
        lock.lock()
        defer { lock.unlock() }
        _aborted = true
    }

    /// Synchronous helper: NSLock must not be taken directly inside an async
    /// context.
    private func recordFailure(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        _failures.append(message)
    }

    /// True once a check timed out: the harness stops at the first
    /// unexpected timeout instead of spending the full deadline on every
    /// later case.
    private var _aborted = false

    var aborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _aborted
    }

    /// Runs one check with a hard per-check deadline. The body runs in an
    /// independent task; completion is observed through a flag instead of
    /// awaiting the task, so a body that hangs on a continuation can never
    /// block the harness (the process-level watchdog is the final bound).
    func check(
        _ name: String,
        timeout: TimeInterval = 10,
        _ body: @Sendable @escaping () async throws -> Void
    ) async {
        if aborted {
            print("SKIP  \(name) (harness stopped after a timeout)")
            fflush(stdout)
            return
        }
        print("RUN   \(name)")
        fflush(stdout)
        let state = CheckState()
        _ = Task {
            do {
                try await body()
                state.finish(error: nil)
            } catch {
                state.finish(error: "\(error)")
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline, !state.isDone {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if !state.isDone {
            state.markTimedOut()
            markAborted()
            recordFailure("\(name): timed out after \(Int(timeout))s (check watchdog)")
            print("FAIL  \(name): timed out after \(Int(timeout))s — stopping at the first timeout")
        } else if let error = state.error {
            recordFailure("\(name): \(error)")
            print("FAIL  \(name): \(error)")
        } else {
            recordPass()
            print("PASS  \(name)")
        }
        fflush(stdout)
    }
}

final class CheckState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var failure: String?
    private var timedOut = false

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    var error: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func finish(error: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done, !timedOut else { return }
        done = true
        failure = error
    }

    func markTimedOut() {
        lock.lock()
        defer { lock.unlock() }
        timedOut = true
    }
}

// MARK: - scripted console

/// Scripted console. The responder receives the token of the frame just
/// written and returns the console chunks to emit for it; `push` injects
/// chunks out of band (for late FAILED/END frames).
final class ScriptedConsole: LinuxGuestConsoleTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private var responder: (@Sendable (String, [UInt8]) -> [Data])?
    private var writtenBytes: [UInt8] = []
    /// Optional per-write delay, widening the window for interleaving bugs.
    var writeDelay: TimeInterval = 0
    /// One entry per console write that carried a FLOE frame, in order.
    private var frameLog: [(name: String, token: String)] = []

    init() {
        var captured: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    var written: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return writtenBytes
    }

    var writtenText: String { String(decoding: written, as: UTF8.self) }

    func count(of needle: String) -> Int {
        writtenText.components(separatedBy: needle).count - 1
    }

    func setResponder(_ responder: @escaping @Sendable (String, [UInt8]) -> [Data]) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    private var outputCalls = 0

    var outputCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outputCalls
    }

    func output() async -> AsyncStream<Data> {
        recordOutputCall()
        return stream
    }

    private func recordOutputCall() {
        lock.lock()
        defer { lock.unlock() }
        outputCalls += 1
    }

    func write(_ bytes: [UInt8]) async throws {
        if writeDelay > 0 {
            try? await Task.sleep(for: .seconds(writeDelay))
        }
        // Synchronous helper: NSLock must not be taken directly inside an
        // async context.
        let responder = record(bytes)
        guard let responder, let token = Self.token(in: bytes) else { return }
        for chunk in responder(token, bytes) {
            continuation.yield(chunk)
        }
    }

    private func record(_ bytes: [UInt8]) -> (@Sendable (String, [UInt8]) -> [Data])? {
        lock.lock()
        defer { lock.unlock() }
        writtenBytes.append(contentsOf: bytes)
        if let frame = Self.frame(in: bytes) {
            frameLog.append(frame)
        }
        return responder
    }

    /// Per-token positions in the console write order. Frames of one payload
    /// group must occupy contiguous positions.
    func frameGroups() -> [String: [Int]] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: [Int]] = [:]
        for (index, entry) in frameLog.enumerated() {
            result[entry.token, default: []].append(index)
        }
        return result
    }

    /// Name and token of the first FLOE frame in `bytes`.
    static func frame(in bytes: [UInt8]) -> (name: String, token: String)? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        for name in ["EXEC", "HELLO", "SPAWN", "KILL", "ALIVE", "OPEN", "SIGNAL", "CLOSE", "IN", "CHUNK", "RUN"] {
            if let range = text.range(of: "\u{1e}FLOE-\(name) ") {
                let token = text[range.upperBound...].prefix { character in
                    character != " " && character != "\u{1e}" && character != "\n" && character != "\r"
                }
                if !token.isEmpty { return (name, String(token)) }
            }
        }
        return nil
    }

    func push(_ chunks: [Data]) {
        for chunk in chunks { continuation.yield(chunk) }
    }

    func finish() {
        continuation.finish()
    }

    func close() async { finish() }

    /// Token of the first FLOE frame in `bytes`. Stops at the frame
    /// terminator: the token never contains 0x1e, a space or a newline, so a
    /// naive split would return "uuid\u{1e}\n".
    static func token(in bytes: [UInt8]) -> String? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        for name in ["EXEC", "HELLO", "SPAWN", "KILL", "ALIVE", "OPEN", "SIGNAL", "CLOSE", "IN", "CHUNK", "RUN"] {
            if let range = text.range(of: "\u{1e}FLOE-\(name) ") {
                let token = text[range.upperBound...].prefix { character in
                    character != " " && character != "\u{1e}" && character != "\n" && character != "\r"
                }
                return token.isEmpty ? nil : String(token)
            }
        }
        return nil
    }

    static func tokenCount(in bytes: [UInt8], name: String) -> Int {
        String(decoding: bytes, as: UTF8.self).components(separatedBy: "\u{1e}FLOE-\(name) ").count - 1
    }

    static func tokens(in bytes: [UInt8], name: String) -> [String] {
        let text = String(decoding: bytes, as: UTF8.self)
        var result: [String] = []
        var search = text.startIndex
        let marker = "\u{1e}FLOE-\(name) "
        while let range = text.range(of: marker, range: search..<text.endIndex) {
            let token = text[range.upperBound...].prefix { character in
                character != " " && character != "\u{1e}" && character != "\n" && character != "\r"
            }
            if !token.isEmpty {
                result.append(String(token))
            }
            search = range.upperBound
        }
        return result
    }
}


/// Mutable handshake state for the legacy-upgrade check. The responder runs
/// on the channel's writer, the check flips the mode between phases.
final class LegacyUpgradeState: @unchecked Sendable {
    private let lock = NSLock()
    private var current = false

    var protocolCurrent: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}

// MARK: - wire helpers

enum Wire {
    static func marker(_ name: String, _ token: String) -> Data {
        Data("\u{1e}FLOE-\(name) \(token)\u{1e}".utf8)
    }

    static func end(_ token: String, _ code: Int32) -> Data {
        Data("\u{1e}FLOE-END \(token) \(code)\u{1e}".utf8)
    }

    static func failed(_ token: String, _ reason: String) -> Data {
        Data("\u{1e}FLOE-FAILED \(token) \(reason)\u{1e}".utf8)
    }

    static func caps(_ token: String) -> Data {
        Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4\u{1e}".utf8)
    }

    static func pid(_ token: String, _ value: Int32) -> Data {
        Data("\u{1e}FLOE-PID \(token) \(value)\u{1e}".utf8)
    }

    /// Splits a byte stream into one-byte chunks.
    static func bytewise(_ data: Data) -> [Data] {
        data.map { Data([$0]) }
    }

    static func capsAndEnd(_ token: String) -> [Data] {
        [caps(token), end(token, 0)]
    }
}

// MARK: - harness

@main
enum ChannelRouterCheck {
    static func waitUntil(
        timeout: TimeInterval,
        _ predicate: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    static func main() async {
        let recorder = Recorder()

        // Process-level backstop: even a bug in the per-check watchdog must
        // not let verification run unbounded.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 300, repeating: .never)
        watchdog.setEventHandler {
            FileHandle.standardError.write(Data("channel-router-check watchdog: 300s elapsed; exiting\n".utf8))
            exit(3)
        }
        watchdog.resume()

        await recorder.check("hello_caps_negotiation") {
            let console = ScriptedConsole()
            console.setResponder { token, _ in
                token.hasPrefix("hello-") ? Wire.capsAndEnd(token) : []
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            let caps = try await channel.probeCapabilities(timeout: 2, requireCurrentProtocol: true)
            try expect(caps?.contains("protocol=3") == true, "caps: \(caps ?? "nil")")
        }

        await recorder.check("hello_caps_split_across_chunks") {
            let console = ScriptedConsole()
            console.setResponder { token, _ in
                guard token.hasPrefix("hello-") else { return [] }
                var stream = Data()
                stream.append(Wire.caps(token))
                stream.append(Wire.end(token, 0))
                return Wire.bytewise(stream)
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            let caps = try await channel.probeCapabilities(timeout: 2, requireCurrentProtocol: true)
            try expect(caps?.contains("protocol=3") == true, "caps: \(caps ?? "nil")")
        }

        await recorder.check("legacy_runner_fails_closed") {
            let console = ScriptedConsole()
            console.setResponder { _, _ in [] } // pre-protocol-3 runner answers nothing
            let channel = LinuxGuestCommandChannel(transport: console)
            do {
                _ = try await channel.probeCapabilities(timeout: 0.5, requireCurrentProtocol: true)
                throw CheckFailure.message("legacy runner did not fail the upgrade check")
            } catch let error as LinuxGuestError {
                guard case .runnerUpgradeRequired = error else {
                    throw CheckFailure.message("unexpected error \(error)")
                }
            }
            do {
                try await channel.acceptExternalNegotiation(capabilities: "runner=1.0.0 protocol=2 maxCommands=1 maxSessions=1")
                throw CheckFailure.message("protocol 2 negotiation was accepted")
            } catch let error as LinuxGuestError {
                guard case .runnerUpgradeRequired = error else {
                    throw CheckFailure.message("unexpected error \(error)")
                }
            }
        }

        await recorder.check("router_preserves_raw_rs_and_leading_lf") {
            let console = ScriptedConsole()
            // Payload: leading LF, RS bytes that are not valid frame headers,
            // an RS + "FLOE-X" that is not a frame (no token), and a trailing
            // RS directly before the END frame (the case a header scanner
            // gets wrong).
            var payloadBytes: [UInt8] = [0x0a, 0x1e, 0x1e]
            payloadBytes.append(contentsOf: Array("mid".utf8))
            payloadBytes.append(0x1e)
            payloadBytes.append(contentsOf: Array("FLOE-X".utf8))
            payloadBytes.append(contentsOf: [0x1e, 0x0a, 0x1e])
            let payload = Data(payloadBytes)
            console.setResponder { token, _ in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                var stream = Data()
                stream.append(Wire.marker("BEGIN", token))
                stream.append(Wire.marker("OUT", token))
                stream.append(payload)
                stream.append(Wire.end(token, 0))
                return Wire.bytewise(stream)
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            let result = try await channel.run(argv: ["/bin/echo"], timeout: 5)
            try expect(result.stdout == String(decoding: payload, as: UTF8.self),
                       "stdout \(result.stdout.debugDescription) != \(String(decoding: payload, as: UTF8.self).debugDescription)")
            try expect(result.stderr.isEmpty, "stderr \(result.stderr.debugDescription)")
            try expect(result.exitCode == 0, "exit \(result.exitCode)")
        }

        await recorder.check("router_interleaved_tokens") {
            let console = ScriptedConsole()
            console.setResponder { token, _ in
                token.hasPrefix("hello-") ? Wire.capsAndEnd(token) : []
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            async let first = channel.run(argv: ["/bin/echo", "a"], timeout: 5)
            async let second = channel.run(argv: ["/bin/echo", "b"], timeout: 5)
            guard await waitUntil(timeout: 3, { ScriptedConsole.tokenCount(in: console.written, name: "EXEC") == 2 }) else {
                throw CheckFailure.message("two EXEC frames were not written")
            }
            let tokens = ScriptedConsole.tokens(in: console.written, name: "EXEC")
            guard tokens.count == 2 else { throw CheckFailure.message("expected two tokens, got \(tokens)") }
            let a = tokens[0]
            let b = tokens[1]
            // Realistic shape: each command announces its own BEGIN at
            // start, then both streams interleave.
            // The task/token mapping is not deterministic (both tasks write
            // their EXEC concurrently), so assert by token content instead:
            // each token must see exactly its own bytes.
            var stream = Data()
            stream.append(Wire.marker("BEGIN", a))
            stream.append(Wire.marker("BEGIN", b))
            stream.append(Wire.marker("OUT", a))
            stream.append(Data("alpha-1".utf8))
            stream.append(Wire.marker("OUT", b))
            stream.append(Data("beta-1".utf8))
            stream.append(Wire.marker("OUT", a))
            stream.append(Data("alpha-2".utf8))
            stream.append(Wire.end(b, 0))
            stream.append(Wire.end(a, 0))
            console.push(Wire.bytewise(stream))
            let resultA = try await first
            let resultB = try await second
            let outputs = Set([resultA.stdout, resultB.stdout])
            try expect(outputs == Set(["alpha-1alpha-2", "beta-1"]),
                       "interleaved routing leaked: \(outputs)")
            try expect(resultA.stderr.isEmpty && resultB.stderr.isEmpty,
                       "stderr \(resultA.stderr.debugDescription)/\(resultB.stderr.debugDescription)")
            try expect(resultB.exitCode == 0 && resultA.exitCode == 0, "exits \(resultA.exitCode)/\(resultB.exitCode)")
        }

        await recorder.check("timeout_keeps_token_for_late_failed") {
            let console = ScriptedConsole()
            console.setResponder { token, bytes in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                if String(decoding: bytes, as: UTF8.self).contains("FLOE-SIGNAL") { return [] }
                return [Wire.marker("BEGIN", token)]
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            async let runTask = channel.run(argv: ["/bin/sleep", "100"], timeout: 0.3)
            guard await waitUntil(timeout: 3, { console.writtenText.contains("FLOE-SIGNAL") && ScriptedConsole.tokenCount(in: console.written, name: "SIGNAL") > 0 }) else {
                throw CheckFailure.message("targeted SIGNAL was not sent")
            }
            let tokens = ScriptedConsole.tokens(in: console.written, name: "SIGNAL")
            guard let token = tokens.first else { throw CheckFailure.message("no SIGNAL token") }
            try expect(console.writtenText.contains("FLOE-SIGNAL \(token) INT"), "SIGNAL was not INT")
            try expect(!console.written.contains(0x03), "legacy interrupt-all byte was used")
            // Late FAILED (quarantine): the token must still be registered and
            // the failure must be a quarantine, never a timeout/"stopped".
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                console.push([Wire.failed(token, "unreaped")])
            }
            do {
                _ = try await runTask
                throw CheckFailure.message("late FAILED was not surfaced")
            } catch let error as LinuxGuestError {
                guard case .consoleUnavailable(let detail) = error else {
                    throw CheckFailure.message("unexpected error \(error)")
                }
                try expect(detail.contains("abandoned") || detail.contains("unreaped"),
                           "quarantine detail: \(detail)")
            }
            let poisoned = await channel.isPoisoned
            try expect(poisoned, "quarantine must poison the channel")
        }

        await recorder.check("timeout_surfaces_after_confirmed_end") {
            let console = ScriptedConsole()
            console.setResponder { token, bytes in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                if String(decoding: bytes, as: UTF8.self).contains("FLOE-SIGNAL") {
                    return [Wire.end(token, 130)]
                }
                return [Wire.marker("BEGIN", token)]
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            do {
                _ = try await channel.run(argv: ["/bin/sleep", "100"], timeout: 0.3)
                throw CheckFailure.message("expected a timeout")
            } catch let error as LinuxGuestError {
                guard case .timedOut = error else {
                    throw CheckFailure.message("unexpected error \(error)")
                }
            }
            let poisoned = await channel.isPoisoned
            try expect(!poisoned, "a confirmed reap must not poison the channel")
            try expect(console.writtenText.contains("FLOE-SIGNAL"), "INT was not sent")
            try expect(!console.written.contains(0x03), "legacy interrupt-all byte was used")
        }

        await recorder.check("cancellation_surfaces_after_confirmed_end") {
            let console = ScriptedConsole()
            console.setResponder { token, bytes in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                if String(decoding: bytes, as: UTF8.self).contains("FLOE-SIGNAL") {
                    return [Wire.end(token, 130)]
                }
                return [Wire.marker("BEGIN", token)]
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            let token = CancellationToken()
            let task = Task {
                try await channel.run(argv: ["/bin/sleep", "100"], timeout: 30, cancellation: token)
            }
            try? await Task.sleep(for: .milliseconds(200))
            token.cancel()
            do {
                _ = try await task.value
                throw CheckFailure.message("expected cancellation")
            } catch FloeError.cancelled {
                // expected
            }
            let poisoned = await channel.isPoisoned
            try expect(!poisoned, "a confirmed reap must not poison the channel")
        }

        await recorder.check("unanswered_interrupt_is_bounded_quarantine") {
            let console = ScriptedConsole()
            console.setResponder { token, _ in
                token.hasPrefix("hello-") ? Wire.capsAndEnd(token) : [Wire.marker("BEGIN", token)]
            }
            // Window = interruptGrace + 8s (channel-side bound).
            let channel = LinuxGuestCommandChannel(
                transport: console,
                limits: LinuxGuestLimits(interruptGrace: 0.1)
            )
            let started = Date()
            do {
                _ = try await channel.run(argv: ["/bin/sleep", "100"], timeout: 0.2)
                throw CheckFailure.message("expected a quarantine failure")
            } catch let error as LinuxGuestError {
                guard case .consoleUnavailable(let detail) = error else {
                    throw CheckFailure.message("unexpected error \(error)")
                }
                try expect(detail.contains("did not confirm"), "detail: \(detail)")
            }
            try expect(Date().timeIntervalSince(started) < 15, "quarantine window was not bounded")
            let poisoned = await channel.isPoisoned
            try expect(poisoned, "quarantine must poison the channel")
        }

        await recorder.check("control_spawn_alive_kill") {
            let console = ScriptedConsole()
            console.setResponder { token, bytes in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                let text = String(decoding: bytes, as: UTF8.self)
                if text.contains("FLOE-SPAWN") {
                    return [Wire.pid(token, 4242), Wire.end(token, 0)]
                }
                if text.contains("FLOE-ALIVE") { return [Wire.end(token, 3)] }
                if text.contains("FLOE-KILL") { return [Wire.end(token, 0)] }
                return []
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            let pid = try await channel.spawnService(argv: ["/bin/sleep", "30"], logPath: "/tmp/svc.log", timeout: 3)
            try expect(pid == 4242, "pid \(pid)")
            let alive = try await channel.serviceAlive(pid: pid, timeout: 3)
            try expect(!alive, "unknown pid must answer not-alive")
            let killed = try await channel.killService(pid: pid, timeout: 3)
            try expect(killed, "owned pid must be killable")
        }

        await recorder.check("session_output_and_exit") {
            let console = ScriptedConsole()
            let sessionID = "sess-1"
            let payload = Data([0x0a, 0x1e, 0x41, 0x1e]) + Data("done".utf8)
            console.setResponder { token, bytes in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                let text = String(decoding: bytes, as: UTF8.self)
                guard text.contains("\u{1e}FLOE-OPEN \(sessionID) ") else { return [] }
                var stream = Data()
                stream.append(Wire.marker("BEGIN", sessionID))
                stream.append(Wire.marker("OUT", sessionID))
                stream.append(payload)
                stream.append(Wire.end(sessionID, 5))
                return Wire.bytewise(stream)
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            let session = try await channel.openSession(
                sessionID: sessionID, argv: ["/bin/sh"], workingDirectory: nil, columns: 80, rows: 24
            )
            var output = Data()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let chunk = await session.nextOutput(timeoutMs: 100) {
                    output.append(chunk)
                } else if await session.isFinished {
                    break
                }
            }
            try expect(output == payload, "session output \(output.debugDescription)")
            let exit = await session.terminalExitCode
            try expect(exit == 5, "session exit \(String(describing: exit))")
        }

        await recorder.check("session_output_less_still_finishes") {
            // Regression: the runner announces a session with BEGIN; a child
            // that prints nothing must still resolve (BEGIN + END), not hang.
            let console = ScriptedConsole()
            let sessionID = "sess-quiet"
            console.setResponder { token, bytes in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                let text = String(decoding: bytes, as: UTF8.self)
                guard text.contains("\u{1e}FLOE-OPEN \(sessionID) ") else { return [] }
                return [Wire.marker("BEGIN", sessionID), Wire.end(sessionID, 0)]
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            let session = try await channel.openSession(
                sessionID: sessionID, argv: ["/bin/true"], workingDirectory: nil, columns: 80, rows: 24
            )
            var finished = false
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if await session.isFinished {
                    finished = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            try expect(finished, "output-less session did not finish")
            let exit = await session.terminalExitCode
            try expect(exit == 0, "exit \(String(describing: exit))")
        }

        await recorder.check("session_failed_is_not_a_stopped_state") {
            let console = ScriptedConsole()
            let sessionID = "sess-failed"
            console.setResponder { token, bytes in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                let text = String(decoding: bytes, as: UTF8.self)
                guard text.contains("\u{1e}FLOE-OPEN \(sessionID) ") else { return [] }
                return [Wire.failed(sessionID, "unreaped")]
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            let session = try await channel.openSession(
                sessionID: sessionID, argv: ["/bin/sh"], workingDirectory: nil, columns: 80, rows: 24
            )
            _ = await waitUntil(timeout: 3) { Task { await session.isFinished } as? Bool ?? false }
            let failure = await session.failure
            let exit = await session.terminalExitCode
            try expect(failure?.contains("unreaped") == true, "failure \(String(describing: failure))")
            try expect(exit == nil, "a quarantined session must not report a terminal exit code")
            let poisoned = await channel.isPoisoned
            try expect(poisoned, "session quarantine must poison the channel")
        }

        await recorder.check("session_open_failure_surfaces_message") {
            // The runner answers an OPEN failure with OUT + reason + END 125
            // (there is no ERR section in a session stream): the session must
            // resolve with the real code and the message as output.
            let console = ScriptedConsole()
            let sessionID = "sess-full"
            console.setResponder { token, bytes in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                let text = String(decoding: bytes, as: UTF8.self)
                guard text.contains("\u{1e}FLOE-OPEN \(sessionID) ") else { return [] }
                var stream = Data()
                stream.append(Wire.marker("OUT", sessionID))
                stream.append(Data("floe-exec: session table full\n".utf8))
                stream.append(Wire.end(sessionID, 125))
                return [stream]
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            let session = try await channel.openSession(
                sessionID: sessionID, argv: ["/bin/sh"], workingDirectory: nil, columns: 80, rows: 24
            )
            var output = Data()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let chunk = await session.nextOutput(timeoutMs: 100) {
                    output.append(chunk)
                } else if await session.isFinished {
                    break
                }
            }
            let text = String(decoding: output, as: UTF8.self)
            try expect(text.contains("session table full"), "session output \(text.debugDescription)")
            let exit = await session.terminalExitCode
            try expect(exit == 125, "exit \(String(describing: exit))")
            let failure = await session.failure
            try expect(failure == nil, "open failure is not a quarantine: \(String(describing: failure))")
        }

        await recorder.check("legacy_silent_transport_probe_is_bounded") {
            // A pre-protocol-3 runner never answers HELLO. The probe must
            // fail closed on its own deadline instead of awaiting the console
            // stream forever (the observed hang this check guards).
            let console = ScriptedConsole()
            console.setResponder { _, _ in [] }
            let channel = LinuxGuestCommandChannel(transport: console)
            let started = Date()
            do {
                _ = try await channel.probeCapabilities(timeout: 0.5, requireCurrentProtocol: true)
                throw CheckFailure.message("silent runner was accepted")
            } catch let error as LinuxGuestError {
                guard case .runnerUpgradeRequired = error else {
                    throw CheckFailure.message("unexpected error \(error)")
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            try expect(elapsed < 3, "silent probe took \(elapsed)s (must be bounded)")
            // The probe token must be released and the channel usable for the
            // upgrade decision (a second probe with the same silence is still
            // bounded, not blocked by a stale waiter).
            let second = Date()
            _ = try? await channel.probeCapabilities(timeout: 0.3, requireCurrentProtocol: true)
            try expect(Date().timeIntervalSince(second) < 3, "second silent probe was not bounded")
        }

        await recorder.check("router_preserves_unknown_floe_sequences") {
            let console = ScriptedConsole()
            // Sequences that look like FLOE frames but are not valid guest
            // frames must survive as section payload byte-for-byte.
            var payloadBytes: [UInt8] = []
            payloadBytes.append(contentsOf: Array("\u{1e}FLOE-UNKNOWN abcd\u{1e}".utf8))
            payloadBytes.append(contentsOf: Array("middle".utf8))
            payloadBytes.append(contentsOf: Array("\u{1e}FLOE-\u{1e}".utf8))
            payloadBytes.append(contentsOf: Array("tail".utf8))
            let payload = Data(payloadBytes)
            console.setResponder { token, _ in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                var stream = Data()
                stream.append(Wire.marker("BEGIN", token))
                stream.append(Wire.marker("OUT", token))
                stream.append(payload)
                stream.append(Wire.end(token, 0))
                return Wire.bytewise(stream)
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            let result = try await channel.run(argv: ["/bin/cat"], timeout: 5)
            try expect(result.stdout == String(decoding: payload, as: UTF8.self),
                       "payload \(result.stdout.debugDescription) != \(String(decoding: payload, as: UTF8.self).debugDescription)")
        }

        await recorder.check("concurrent_payload_groups_stay_contiguous") {
            // Two concurrent chunked EXEC transfers: every frame of one
            // token's payload group must be contiguous in the console write
            // stream (the guest's line parser reassembles per-token chunk
            // groups). Without the channel's serialized writer, the slow
            // transport lets the second command interleave its frames.
            let console = ScriptedConsole()
            console.writeDelay = 0.004
            console.setResponder { token, bytes in
                if token.hasPrefix("hello-") { return Wire.capsAndEnd(token) }
                let text = String(decoding: bytes, as: UTF8.self)
                if text.contains("\u{1e}FLOE-RUN ") {
                    var stream = Data()
                    stream.append(Wire.marker("BEGIN", token))
                    stream.append(Wire.end(token, 0))
                    return [stream]
                }
                return []
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            // Force the chunked path (payload above the inline line limit) so
            // each token writes a real multi-frame group.
            let big = String(repeating: "x", count: 6000)
            async let first = channel.run(argv: ["/bin/cat"], standardInput: big, timeout: 10)
            async let second = channel.run(argv: ["/bin/cat"], standardInput: big, timeout: 10)
            _ = try await first
            _ = try await second
            let groups = console.frameGroups()
            try expect(groups.count >= 2, "expected two chunked payload groups, got \(groups.count)")
            for (token, indices) in groups {
                let contiguous = indices.count == 1 ||
                    (indices.last! - indices.first! + 1) == indices.count
                try expect(contiguous,
                           "token \(token) frames interleaved with another group: \(indices)")
            }
        }

        await recorder.check("legacy_mode_switch_keeps_single_reader") {
            // The console must be consumed by exactly ONE reader for the
            // whole upgrade: cancelling a for-await reader terminates the
            // transport AsyncStream permanently, so the channel switches to
            // legacy serial mode in place instead of building a second
            // reader. The same reader then negotiates protocol 3 again after
            // the reboot.
            let console = ScriptedConsole()
            let state = LegacyUpgradeState()
            console.setResponder { token, bytes in
                let text = String(decoding: bytes, as: UTF8.self)
                if text.contains("FLOE-HELLO") {
                    // Legacy runner first (silent), protocol-3 runner after
                    // the simulated reboot.
                    return state.protocolCurrent ? Wire.capsAndEnd(token) : []
                }
                if text.contains("FLOE-EXEC") {
                    var stream = Data()
                    stream.append(Wire.marker("BEGIN", token))
                    stream.append(Wire.marker("OUT", token))
                    stream.append(Data("legacy-ok\n".utf8))
                    stream.append(Wire.end(token, 0))
                    return [stream]
                }
                return []
            }
            let channel = LinuxGuestCommandChannel(transport: console)
            do {
                _ = try await channel.probeCapabilities(timeout: 0.3, requireCurrentProtocol: true)
                throw CheckFailure.message("legacy runner was accepted")
            } catch let error as LinuxGuestError {
                guard case .runnerUpgradeRequired = error else {
                    throw CheckFailure.message("unexpected error \(error)")
                }
            }
            try await channel.enterLegacySerialMode()
            let result = try await channel.run(argv: ["/bin/true"], timeout: 3)
            try expect(result.exitCode == 0, "legacy serial exit \(result.exitCode)")
            try expect(result.stdout == "legacy-ok\n", "legacy serial stdout \(result.stdout.debugDescription)")
            // Reboot boundary: stale protocol state is dropped, the reader is
            // not touched, and the mode returns to protocol 3.
            await channel.resetRouterState()
            await channel.leaveLegacySerialMode()
            state.protocolCurrent = true
            let caps = try await channel.probeCapabilities(timeout: 2, requireCurrentProtocol: true)
            try expect(caps?.contains("protocol=3") == true, "post-reboot caps: \(caps ?? "nil")")
            try expect(console.outputCallCount == 1,
                       "the console was attached to \(console.outputCallCount) readers; the upgrade must keep one")
        }

        print("")
        print("checks passed: \(recorder.passes), failures: \(recorder.failures.count)")
        if !recorder.failures.isEmpty {
            for failure in recorder.failures {
                print("FAILURE: \(failure)")
            }
            exit(1)
        }
    }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw CheckFailure.message(message()) }
    }
}
