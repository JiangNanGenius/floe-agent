// HostProtocolCheck — minimal real-chain check for the Floe Linux guest
// runner (FloeAgent/LinuxGuest/runner/floe_exec.c).
//
// The harness compiles the *real* host framing code (the `LinuxGuestFraming`
// enum extracted from FloeExecution/Linux/LinuxGuestCommandChannel.swift by
// host_protocol_check.sh) and drives a natively built runner through real
// pipes: real fork/exec, real stdout/stderr, real exit statuses, real
// cancellation. It is not a guest-image qualification and makes no claim
// about riscv64 execution; it proves that the wire format and the process
// semantics on both sides of the contract agree.
//
// Usage: host-protocol-check <path to floe-exec built for this host>

import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum CheckFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Collects the runner's own stderr (boot diagnostics only) on a side thread
/// so a full pipe can never block the runner.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One `floe-exec` child process, seen as a byte console: stdin is what the
/// host writes, stdout is the framed channel, stderr is diagnostics.
final class Runner {
    let process: Process
    private let writeFD: Int32
    private let readFD: Int32
    private let diagnostics: DataBox
    private var writeClosed = false

    init(path: String) throws {
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let box = DataBox()
        self.diagnostics = box
        self.process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        self.writeFD = input.fileHandleForWriting.fileDescriptor
        self.readFD = output.fileHandleForReading.fileDescriptor
        let errorHandle = errors.fileHandleForReading
        DispatchQueue.global().async {
            while true {
                let chunk = errorHandle.availableData
                if chunk.isEmpty { break }
                box.append(chunk)
            }
        }
    }

    func writeRaw(_ data: Data) throws {
        guard !writeClosed else { throw CheckFailure.message("console already closed") }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let wrote = write(writeFD, base.advanced(by: offset), raw.count - offset)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw CheckFailure.message("console write failed: \(String(cString: strerror(errno)))")
                }
                offset += wrote
            }
        }
    }

    /// nil = no bytes yet, empty Data = EOF.
    private func readChunk(timeoutMs: Int32) -> Data? {
        var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, timeoutMs)
        if ready <= 0 { return nil }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let got = buffer.withUnsafeMutableBytes { raw -> Int in
            read(readFD, raw.baseAddress, raw.count)
        }
        if got < 0 {
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return nil }
            return Data()
        }
        if got == 0 { return Data() }
        return Data(buffer[0..<got])
    }

    /// Waits for the END frame of `token` using the app's real parser.
    func awaitEnd(token: String, timeout: TimeInterval) throws -> LinuxCommandOutcome {
        var parser = LinuxGuestFraming.Parser(token: token, maxOutputBytes: 8 * 1024 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let chunk = readChunk(timeoutMs: 200) else { continue }
            if chunk.isEmpty {
                throw CheckFailure.message("runner console closed before END \(token)")
            }
            switch parser.feed(chunk) {
            case .needMore:
                continue
            case .finished(let code):
                return LinuxCommandOutcome(
                    exitCode: code,
                    stdout: parser.stdoutText,
                    stderr: parser.stderrText
                )
            case .failed(let reason):
                throw CheckFailure.message("guest framing failed: \(reason)")
            }
        }
        throw CheckFailure.message("timed out waiting for END \(token)")
    }

    func run(
        token: String,
        argv: [String],
        workingDirectory: String? = nil,
        standardInput: String? = nil,
        timeout: TimeInterval = 10
    ) throws -> LinuxCommandOutcome {
        let envelope = LinuxGuestFraming.execEnvelope(
            token: token,
            argv: argv,
            workingDirectory: workingDirectory,
            standardInput: standardInput
        )
        try writeRaw(envelope)
        return try awaitEnd(token: token, timeout: timeout)
    }

    private var rawBuffer = Data()

    /// Reads unframed guest bytes until `predicate` accepts the accumulated
    /// buffer. Used for the session/service frames that have no BEGIN.
    func readRaw(timeout: TimeInterval, until predicate: (Data) -> Bool) throws -> Data {
        rawBuffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(rawBuffer) { return rawBuffer }
            guard let chunk = readChunk(timeoutMs: 100) else { continue }
            if chunk.isEmpty {
                throw CheckFailure.message("runner console closed while waiting for a frame")
            }
            rawBuffer.append(chunk)
        }
        throw CheckFailure.message("timed out waiting for a frame")
    }

    func shutdown() {
        if !writeClosed {
            writeClosed = true
            close(writeFD)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}

struct LinuxCommandOutcome {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

// MARK: - Extension wire frames (host-confirmed chunked/PTY/SPAWN contract)

enum Wire {
    static func payload(_ fields: [Data]) -> Data {
        var out = Data()
        appendUInt32(UInt32(fields.count), to: &out)
        for field in fields {
            appendUInt32(UInt32(field.count), to: &out)
            out.append(field)
        }
        return out
    }

    static func execPayload(argv: [String], cwd: String = "", stdin: Data = Data()) -> Data {
        payload([Data(cwd.utf8), stdin] + argv.map { Data($0.utf8) })
    }

    static func openPayload(cwd: String, cols: Int, rows: Int, argv: [String]) -> Data {
        payload([
            Data("pty".utf8),
            Data(cwd.utf8),
            Data("\(cols)".utf8),
            Data("\(rows)".utf8),
        ] + argv.map { Data($0.utf8) })
    }

    static func spawnPayload(cwd: String, logPath: String, argv: [String]) -> Data {
        payload([Data(cwd.utf8), Data(logPath.utf8)] + argv.map { Data($0.utf8) })
    }

    /// Canonical chunked envelope: header, FLOE-CHUNK lines (≤3000 base64
    /// characters each, multiple of 4), then FLOE-RUN.
    static func chunked(_ name: String, token: String, payload: Data, chunkSize: Int = 1500) -> Data {
        let base64 = payload.base64EncodedString()
        var pieces: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            pieces.append(String(base64[index..<end]))
            index = end
        }
        var frames = Data("\u{1e}FLOE-\(name) \(token) \(payload.count) \(pieces.count)\u{1e}\n".utf8)
        for (chunkIndex, piece) in pieces.enumerated() {
            frames.append(Data("\u{1e}FLOE-CHUNK \(token) \(chunkIndex) \(piece)\u{1e}\n".utf8))
        }
        frames.append(Data("\u{1e}FLOE-RUN \(token)\u{1e}\n".utf8))
        return frames
    }

    /// Closing-0x1e frame without a trailing newline (IN uses a newline).
    static func frame(_ name: String, token: String, extra: String? = nil) -> Data {
        var text = "\u{1e}FLOE-\(name) \(token)"
        if let extra { text += " \(extra)" }
        text += "\u{1e}"
        return Data(text.utf8)
    }

    static func input(token: String, bytes: Data) -> Data {
        Data("\u{1e}FLOE-IN \(token) \(bytes.base64EncodedString())\n".utf8)
    }

    static func endCode(in data: Data, token: String) -> Int32? {
        let prefix = Data("\u{1e}FLOE-END \(token) ".utf8)
        guard let range = data.range(of: prefix) else { return nil }
        guard let terminator = data[range.upperBound...].firstIndex(of: 0x1e) else { return nil }
        let digits = String(decoding: data[range.upperBound..<terminator], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return Int32(digits)
    }

    static func pid(in data: Data, token: String) -> Int32? {
        let prefix = Data("\u{1e}FLOE-PID \(token) ".utf8)
        guard let range = data.range(of: prefix) else { return nil }
        guard let terminator = data[range.upperBound...].firstIndex(of: 0x1e) else { return nil }
        let digits = String(decoding: data[range.upperBound..<terminator], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return Int32(digits)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}

enum Checks {
    static var failures: [String] = []
    static var passes = 0

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition {
            passes += 1
        } else {
            failures.append(message())
        }
    }

    static func check(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            print("PASS  \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("FAIL  \(name): \(error)")
        }
    }
}

@main
enum HostProtocolCheck {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: host-protocol-check <floe-exec>\n".utf8))
            exit(2)
        }
        let runnerPath = CommandLine.arguments[1]
        print("host protocol check — runner: \(runnerPath)")

        let runner: Runner
        do {
            runner = try Runner(path: runnerPath)
        } catch {
            FileHandle.standardError.write(Data("cannot start runner: \(error)\n".utf8))
            exit(2)
        }
        defer { runner.shutdown() }

        checks(runner: runner)

        print("")
        print("checks passed: \(Checks.passes), failures: \(Checks.failures.count)")
        let diagnostics = runner.diagnosticsText
        if !diagnostics.isEmpty {
            print("runner diagnostics:\n\(diagnostics)")
        }
        if !Checks.failures.isEmpty {
            for failure in Checks.failures {
                print("FAILURE: \(failure)")
            }
            exit(1)
        }
    }

    /// Runs `/bin/pwd -P` with `directory` as cwd (a real subprocess, so the
    /// expected path matches what the guest's own pwd reports).
    static func resolvedPath(of directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/pwd")
        process.arguments = ["-P"]
        process.currentDirectoryURL = directory
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    static func checks(runner: Runner) {
        // 0. Host parser regression: output runs larger than one console
        //    chunk must survive any marker/data split (the bug this check
        //    originally found), and bounds/prelude behaviour is unchanged.
        Checks.check("parser_chunk_boundaries") {
            let token = "01234567-89ab-cdef-0123-456789abcdef"
            let outText = String(repeating: "A", count: 1000) + "\u{1e}middle"
            let errText = String(repeating: "B", count: 500) + "\n"
            var stream = LinuxGuestFraming.marker("BEGIN", token: token)
            stream.append(Data(outText.utf8))
            stream.append(LinuxGuestFraming.marker("OUT", token: token))
            stream.append(LinuxGuestFraming.marker("ERR", token: token))
            stream.append(Data(errText.utf8))
            stream.append(LinuxGuestFraming.endMarkerPrefix(token))
            stream.append(Data("0\u{1e}".utf8))

            for chunkSize in [1, 3, 7, 16, 47, 48, 49] {
                var parser = LinuxGuestFraming.Parser(token: token, maxOutputBytes: 1 << 20)
                var index = stream.startIndex
                var finished: Int32?
                while index < stream.endIndex {
                    let end = stream.index(index, offsetBy: chunkSize, limitedBy: stream.endIndex) ?? stream.endIndex
                    switch parser.feed(Data(stream[index..<end])) {
                    case .needMore:
                        break
                    case .finished(let code):
                        finished = code
                    case .failed(let reason):
                        throw CheckFailure.message("parser failed at chunk \(chunkSize): \(reason)")
                    }
                    index = end
                }
                Checks.expect(finished == 0, "chunk \(chunkSize): exit code")
                Checks.expect(parser.stdoutText == outText, "chunk \(chunkSize): stdout exact")
                Checks.expect(parser.stderrText == errText, "chunk \(chunkSize): stderr exact")
            }

            var bounded = LinuxGuestFraming.Parser(token: token, maxOutputBytes: 4)
            _ = bounded.feed(Data("boot noise".utf8))
            _ = bounded.feed(LinuxGuestFraming.marker("BEGIN", token: token))
            _ = bounded.feed(Data("0123456789".utf8))
            _ = bounded.feed(LinuxGuestFraming.endMarkerPrefix(token))
            _ = bounded.feed(Data("0\u{1e}".utf8))
            Checks.expect(bounded.stdoutText == "0123", "bounded stdout keeps first 4 bytes")
            Checks.expect(bounded.truncated, "bounded output marks truncation")
        }

        // 1. argv arrives byte-for-byte and is never re-parsed by a shell.
        Checks.check("argv_verbatim") {
            let args = [
                "plain",
                "with space",
                "quote\"single'",
                "dollar$HOME",
                "semi;colon",
                "back\\slash",
                "tab\there",
                "new\nline",
                "utf8-中文-🚀",
                "marker\u{1e}byte",
                "*glob*",
                "(paren)",
                "amp&ersand",
                "`backtick`",
                "-leading-dash",
            ]
            let script = "for a in \"$@\"; do printf '%s\\0' \"$a\"; done"
            let outcome = try runner.run(
                token: UUID().uuidString,
                argv: ["/bin/sh", "-c", script, "floe"] + args
            )
            Checks.expect(outcome.exitCode == 0, "argv_verbatim exit \(outcome.exitCode)")
            var expected = Data()
            for arg in args {
                expected.append(Data(arg.utf8))
                expected.append(0)
            }
            Checks.expect(
                Data(outcome.stdout.utf8) == expected,
                "argv_verbatim stdout mismatch: \(outcome.stdout.count) bytes"
            )
            Checks.expect(outcome.stderr.isEmpty, "argv_verbatim stderr: \(outcome.stderr)")
        }

        // 2. stdout and stderr stay separate; exit code is the real one.
        Checks.check("stdout_stderr_exit") {
            let outcome = try runner.run(
                token: UUID().uuidString,
                argv: ["/bin/sh", "-c", "printf out; printf err >&2; exit 7"]
            )
            Checks.expect(outcome.stdout == "out", "stdout was \(outcome.stdout.debugDescription)")
            Checks.expect(outcome.stderr == "err", "stderr was \(outcome.stderr.debugDescription)")
            Checks.expect(outcome.exitCode == 7, "exit was \(outcome.exitCode)")
        }

        // 3. stdin bytes (including NUL) reach the child; cwd is honored.
        Checks.check("stdin_cwd") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-check-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = "héllo\nworld\u{0}tail\n"
            let outcome = try runner.run(
                token: UUID().uuidString,
                argv: ["/bin/sh", "-c", "cat; /bin/pwd -P"],
                workingDirectory: directory.path,
                standardInput: input
            )
            // Resolve the directory the same way the guest shell does
            // (/bin/pwd -P): macOS /var is a symlink to /private/var.
            let resolved = (try? HostProtocolCheck.resolvedPath(of: directory)) ?? directory.resolvingSymlinksInPath().path
            Checks.expect(outcome.exitCode == 0, "stdin_cwd exit \(outcome.exitCode)")
            Checks.expect(
                outcome.stdout == input + resolved + "\n",
                "stdin_cwd stdout mismatch: \(outcome.stdout.debugDescription)"
            )
        }

        // 4. Binary/control bytes and marker-like bytes in output do not break
        //    the framing (the token in real markers is a UUID, never data).
        Checks.check("binary_and_marker_bytes") {
            let outcome = try runner.run(
                token: UUID().uuidString,
                argv: ["/bin/sh", "-c", "printf 'A\\036B\\001C\\n'; printf 'tail\\036marker'"]
            )
            var expected = Data([0x41, 0x1e, 0x42, 0x01, 0x43, 0x0a])
            expected.append(Data("tail\u{1e}marker".utf8))
            Checks.expect(outcome.exitCode == 0, "binary exit \(outcome.exitCode)")
            Checks.expect(
                Data(outcome.stdout.utf8) == expected,
                "binary stdout mismatch: \(outcome.stdout.debugDescription)"
            )
        }

        // 5. Long output is streamed intact.
        Checks.check("large_output") {
            let lines = 4000
            let program = "BEGIN{for(i=0;i<\(lines);i++){printf \"line-%04d\", i; printf \"%c\", 30; printf \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n\"}}"
            let outcome = try runner.run(
                token: UUID().uuidString,
                argv: ["/usr/bin/awk", program],
                timeout: 20
            )
            var expected = Data()
            for index in 0..<lines {
                expected.append(Data(String(format: "line-%04d", index).utf8))
                expected.append(0x1e)
                expected.append(Data(String(repeating: "x", count: 32).utf8))
                expected.append(0x0a)
            }
            Checks.expect(outcome.exitCode == 0, "large_output exit \(outcome.exitCode)")
            Checks.expect(
                Data(outcome.stdout.utf8) == expected,
                "large_output mismatch: got \(outcome.stdout.utf8.count) bytes, want \(expected.count)"
            )
        }

        // 6. Real failure modes: explicit exit code, missing command, bad cwd.
        Checks.check("exit_and_exec_errors") {
            let explicit = try runner.run(token: UUID().uuidString, argv: ["/bin/sh", "-c", "exit 42"])
            Checks.expect(explicit.exitCode == 42, "explicit exit \(explicit.exitCode)")

            let missing = try runner.run(token: UUID().uuidString, argv: ["/nonexistent/floe-cmd"])
            Checks.expect(missing.exitCode == 127, "missing command exit \(missing.exitCode)")
            Checks.expect(
                missing.stderr.contains("command not found"),
                "missing command stderr: \(missing.stderr.debugDescription)"
            )

            let badCwd = try runner.run(
                token: UUID().uuidString,
                argv: ["/bin/echo", "never"],
                workingDirectory: "/nonexistent-floe-dir"
            )
            Checks.expect(badCwd.exitCode == 126, "bad cwd exit \(badCwd.exitCode)")
            Checks.expect(
                badCwd.stderr.contains("chdir"),
                "bad cwd stderr: \(badCwd.stderr.debugDescription)"
            )
        }

        // 7. Ctrl-C (raw 0x03) kills only this command's process group: a TERM
        //    ignoring loop is SIGKILLed after the grace period (exit 130), and
        //    an unrelated process is untouched.
        Checks.check("cancel_own_group_only") {
            let unrelated = Process()
            unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
            unrelated.arguments = ["30"]
            try unrelated.run()
            defer {
                unrelated.terminate()
            }

            let token = UUID().uuidString
            let started = Date()
            try runner.writeRaw(LinuxGuestFraming.execEnvelope(
                token: token,
                argv: ["/bin/sh", "-c", "trap '' TERM INT; while :; do :; done"],
                workingDirectory: nil,
                standardInput: nil
            ))
            Thread.sleep(forTimeInterval: 0.4)
            try runner.writeRaw(Data([0x03]))
            let outcome = try runner.awaitEnd(token: token, timeout: 8)
            let elapsed = Date().timeIntervalSince(started)
            Checks.expect(outcome.exitCode == 130, "cancel exit \(outcome.exitCode)")
            Checks.expect(
                elapsed > 0.9 && elapsed < 6,
                "cancel took \(elapsed)s (expected SIGKILL escalation around 1.1s)"
            )
            Checks.expect(
                kill(unrelated.processIdentifier, 0) == 0,
                "unrelated process was killed by cancellation"
            )
        }

        // 8. After cancel and normal commands the channel keeps serving (no
        //    hang, no leaked pipes), and background children that hold the
        //    output pipe cannot stall the next command.
        Checks.check("sequential_reuse_and_background") {
            let background = try runner.run(
                token: UUID().uuidString,
                argv: ["/bin/sh", "-c", "sleep 3 & echo bg-started"],
                timeout: 5
            )
            Checks.expect(background.exitCode == 0, "background exit \(background.exitCode)")
            Checks.expect(background.stdout == "bg-started\n", "background stdout \(background.stdout.debugDescription)")

            for index in 0..<3 {
                let outcome = try runner.run(
                    token: UUID().uuidString,
                    argv: ["/bin/echo", "after-\(index)"],
                    timeout: 5
                )
                Checks.expect(outcome.exitCode == 0, "sequential \(index) exit \(outcome.exitCode)")
                Checks.expect(outcome.stdout == "after-\(index)\n", "sequential \(index) stdout \(outcome.stdout.debugDescription)")
            }
        }

        // 9. Canonical chunked envelope: a payload larger than the inline
        //    threshold is reassembled byte-for-byte across FLOE-CHUNK lines.
        Checks.check("chunked_exec_large_payload") {
            var stdin = Data()
            for index in 0..<900 {
                stdin.append(Data(String(format: "line-%04d-abcdef\n", index).utf8))
            }
            let token = UUID().uuidString
            let payload = Wire.execPayload(argv: ["/bin/cat"], stdin: stdin)
            Checks.expect(payload.count > 3800, "chunked payload should exceed the inline threshold")
            try runner.writeRaw(Wire.chunked("EXEC", token: token, payload: payload, chunkSize: 1500))
            let outcome = try runner.awaitEnd(token: token, timeout: 15)
            Checks.expect(outcome.exitCode == 0, "chunked exit \(outcome.exitCode)")
            Checks.expect(
                Data(outcome.stdout.utf8) == stdin,
                "chunked stdout mismatch: \(outcome.stdout.utf8.count) vs \(stdin.count) bytes"
            )
        }

        // 10. PTY session: chunked OPEN, base64 FLOE-IN input, WINCH signal,
        //     interactive shell exit status.
        Checks.check("pty_session_input_and_signal") {
            let token = UUID().uuidString
            let open = Wire.chunked(
                "OPEN",
                token: token,
                payload: Wire.openPayload(cwd: "", cols: 80, rows: 24, argv: ["/bin/sh"])
            )
            try runner.writeRaw(open)
            _ = try runner.readRaw(timeout: 5) { data in
                data.range(of: Data("\u{1e}FLOE-BEGIN \(token)\u{1e}".utf8)) != nil
            }
            try runner.writeRaw(Wire.input(token: token, bytes: Data("echo floe-pty-marker\n".utf8)))
            _ = try runner.readRaw(timeout: 5) { data in
                data.range(of: Data("floe-pty-marker".utf8)) != nil
            }
            try runner.writeRaw(Wire.frame("SIGNAL", token: token, extra: "WINCH 40 120"))
            try runner.writeRaw(Wire.input(token: token, bytes: Data("exit\n".utf8)))
            let raw = try runner.readRaw(timeout: 8) { Wire.endCode(in: $0, token: token) != nil }
            Checks.expect(
                Wire.endCode(in: raw, token: token) == 0,
                "pty exit \(String(describing: Wire.endCode(in: raw, token: token)))"
            )
        }

        // 11. PTY CLOSE kills only the session's process group and reports
        //     128+SIGTERM.
        Checks.check("pty_close_kills_group") {
            let token = UUID().uuidString
            try runner.writeRaw(Wire.chunked(
                "OPEN",
                token: token,
                payload: Wire.openPayload(cwd: "", cols: 80, rows: 24, argv: ["/bin/sh", "-c", "sleep 30"])
            ))
            _ = try runner.readRaw(timeout: 5) { data in
                data.range(of: Data("\u{1e}FLOE-BEGIN \(token)\u{1e}".utf8)) != nil
            }
            try runner.writeRaw(Wire.frame("CLOSE", token: token))
            let started = Date()
            let raw = try runner.readRaw(timeout: 6) { Wire.endCode(in: $0, token: token) != nil }
            Checks.expect(Wire.endCode(in: raw, token: token) == 143, "close exit \(String(describing: Wire.endCode(in: raw, token: token)))")
            Checks.expect(Date().timeIntervalSince(started) < 4, "CLOSE took too long")
        }

        // 12. Background service: SPAWN reports a pid without waiting, the
        //     log is appended, ALIVE/KILL only answer for owned pids, and the
        //     channel still serves EXEC afterwards.
        Checks.check("background_service_spawn_kill") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-svc-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let logPath = directory.appendingPathComponent("services/job.log").path
            let token = UUID().uuidString
            try runner.writeRaw(Wire.chunked(
                "SPAWN",
                token: token,
                payload: Wire.spawnPayload(
                    cwd: "",
                    logPath: logPath,
                    argv: ["/bin/sh", "-c", "echo svc-started; sleep 30"]
                )
            ))
            let spawnRaw = try runner.readRaw(timeout: 6) { Wire.endCode(in: $0, token: token) != nil }
            Checks.expect(Wire.endCode(in: spawnRaw, token: token) == 0, "SPAWN end code")
            guard let pid = Wire.pid(in: spawnRaw, token: token) else {
                Checks.expect(false, "SPAWN did not report a pid")
                return
            }

            var logged = ""
            let logDeadline = Date().addingTimeInterval(3)
            while Date() < logDeadline {
                if let text = try? String(contentsOfFile: logPath, encoding: .utf8), text.contains("svc-started") {
                    logged = text
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            Checks.expect(logged.contains("svc-started"), "service log missing: \(logged.debugDescription)")

            try runner.writeRaw(Wire.frame("ALIVE", token: token, extra: "\(pid)"))
            let aliveRaw = try runner.readRaw(timeout: 5) { Wire.endCode(in: $0, token: token) != nil }
            Checks.expect(Wire.endCode(in: aliveRaw, token: token) == 0, "ALIVE for an owned pid should be 0")

            try runner.writeRaw(Wire.frame("ALIVE", token: token, extra: "999999"))
            let unknownRaw = try runner.readRaw(timeout: 5) { Wire.endCode(in: $0, token: token) != nil }
            Checks.expect(Wire.endCode(in: unknownRaw, token: token) == 3, "ALIVE for an unknown pid should be 3")

            try runner.writeRaw(Wire.frame("KILL", token: token, extra: "\(pid)"))
            let killRaw = try runner.readRaw(timeout: 5) { Wire.endCode(in: $0, token: token) != nil }
            Checks.expect(Wire.endCode(in: killRaw, token: token) == 0, "KILL for an owned pid should be 0")

            var gone = false
            let goneDeadline = Date().addingTimeInterval(4)
            while Date() < goneDeadline {
                try runner.writeRaw(Wire.frame("ALIVE", token: token, extra: "\(pid)"))
                let probe = try runner.readRaw(timeout: 3) { Wire.endCode(in: $0, token: token) != nil }
                if Wire.endCode(in: probe, token: token) == 3 {
                    gone = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            Checks.expect(gone, "service still reported alive after KILL")
            Checks.expect(kill(pid, 0) != 0, "service pid \(pid) still exists after KILL")

            let outcome = try runner.run(token: UUID().uuidString, argv: ["/bin/echo", "after-service"], timeout: 5)
            Checks.expect(outcome.exitCode == 0, "EXEC after service failed: \(outcome.stderr)")
            Checks.expect(outcome.stdout == "after-service\n", "EXEC after service stdout \(outcome.stdout.debugDescription)")
        }
    }
}

extension Runner {
    var diagnosticsText: String { diagnostics.text }
}
