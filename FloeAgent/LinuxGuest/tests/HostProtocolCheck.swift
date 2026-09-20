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

    /// Waits for the END frame of `token`, honoring an outcome buffered by
    /// an earlier concurrent await.
    func awaitEnd(token: String, timeout: TimeInterval) throws -> LinuxCommandOutcome {
        if let buffered = bufferedEnd(token: token) { return buffered }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // The demuxer may have completed this token with bytes already
            // buffered while a previous awaiter was active.
            if try drainDemux(awaitedToken: token) {
                pendingParsers[token] = nil
                guard let outcome = bufferedEnd(token: token) else {
                    throw CheckFailure.message("demuxer finished \(token) without an outcome")
                }
                return outcome
            }
            guard let chunk = readChunk(timeoutMs: 200) else { continue }
            if chunk.isEmpty {
                throw CheckFailure.message("runner console closed before END \(token)")
            }
            if try feedDemux(chunk, awaitedToken: token) {
                pendingParsers[token] = nil
                guard let outcome = bufferedEnd(token: token) else {
                    throw CheckFailure.message("demuxer finished \(token) without an outcome")
                }
                return outcome
            }
        }
        throw CheckFailure.message("timed out waiting for END \(token)")
    }

    /// Per-token parsers for frames the current awaiter does not own.
    private var pendingParsers: [String: LinuxGuestFraming.Parser] = [:]
    /// Buffered END outcomes for tokens whose END arrived while awaiting
    /// another token.
    private var finishedOutcomes: [String: LinuxCommandOutcome] = [:]
    private var demuxSectionOwner: String?
    private var demuxBuffer = Data()

    /// Feeds one console chunk through the demuxer. Returns true when the
    /// awaited token reached END/FAILED; the unprocessed remainder stays in
    /// demuxBuffer for the next awaitEnd call, so concurrent tokens can be
    /// awaited in any order without losing frames.
    private func feedDemux(_ chunk: Data, awaitedToken: String) throws -> Bool {
        demuxBuffer.append(chunk)
        return try drainDemux(awaitedToken: awaitedToken)
    }

    private func drainDemux(awaitedToken: String) throws -> Bool {
        while true {
            guard let mark = demuxBuffer.firstIndex(of: 0x1e) else {
                if try feed(owner: demuxSectionOwner, bytes: demuxBuffer[...], awaitedToken: awaitedToken) {
                    demuxBuffer.removeAll(keepingCapacity: true)
                    return true
                }
                demuxBuffer.removeAll(keepingCapacity: true)
                return false
            }
            let afterMark = demuxBuffer.index(after: mark)
            guard afterMark < demuxBuffer.endIndex else {
                // Lone trailing 0x1e: could start a header. Flush everything
                // before it to the current owner and wait.
                if mark > demuxBuffer.startIndex {
                    if try feed(owner: demuxSectionOwner, bytes: demuxBuffer[..<mark], awaitedToken: awaitedToken) {
                        demuxBuffer.removeSubrange(demuxBuffer.startIndex..<mark)
                        return true
                    }
                    demuxBuffer.removeSubrange(demuxBuffer.startIndex..<mark)
                }
                return false
            }
            guard let closing = demuxBuffer[afterMark...].firstIndex(of: 0x1e) else {
                // No closing 0x1e yet. If the text after the mark cannot be
                // a FLOE header prefix, the mark is section data; otherwise
                // flush what precedes it and wait for the rest.
                let tail = String(decoding: demuxBuffer[afterMark...], as: UTF8.self)
                let couldBeHeader = "FLOE-".hasPrefix(tail) || tail.hasPrefix("FLOE-")
                if !couldBeHeader {
                    let through = demuxBuffer.index(after: mark)
                    if try feed(owner: demuxSectionOwner, bytes: demuxBuffer[..<through], awaitedToken: awaitedToken) {
                        demuxBuffer.removeSubrange(demuxBuffer.startIndex..<through)
                        return true
                    }
                    demuxBuffer.removeSubrange(demuxBuffer.startIndex..<through)
                    continue
                }
                if mark > demuxBuffer.startIndex {
                    if try feed(owner: demuxSectionOwner, bytes: demuxBuffer[..<mark], awaitedToken: awaitedToken) {
                        demuxBuffer.removeSubrange(demuxBuffer.startIndex..<mark)
                        return true
                    }
                    demuxBuffer.removeSubrange(demuxBuffer.startIndex..<mark)
                }
                return false
            }
            let headerText = String(decoding: demuxBuffer[afterMark..<closing], as: UTF8.self)
            var isHeader = false
            var name = ""
            var token = ""
            if headerText.hasPrefix("FLOE-") {
                let parts = headerText.dropFirst(5).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count >= 2, !parts[1].isEmpty {
                    isHeader = true
                    name = String(parts[0])
                    token = String(parts[1])
                }
            }
            if !isHeader {
                // This 0x1e is section payload: flush through it.
                let through = demuxBuffer.index(after: mark)
                if try feed(owner: demuxSectionOwner, bytes: demuxBuffer[..<through], awaitedToken: awaitedToken) {
                    demuxBuffer.removeSubrange(demuxBuffer.startIndex..<through)
                    return true
                }
                demuxBuffer.removeSubrange(demuxBuffer.startIndex..<through)
                continue
            }
            let takesValue = false // END/FAILED carry the value inside the header (parts[2]); the closing 0x1e IS the terminator
            var valueLimit = demuxBuffer.index(after: closing)
            if valueLimit < demuxBuffer.endIndex, demuxBuffer[valueLimit] == UInt8(ascii: "\n") {
                valueLimit = demuxBuffer.index(after: valueLimit)
            }
            _ = takesValue
            // Section bytes before the header belong to the prior owner.
            if try feed(owner: demuxSectionOwner, bytes: demuxBuffer[..<mark], awaitedToken: awaitedToken) {
                demuxBuffer.removeSubrange(demuxBuffer.startIndex..<mark)
                return true
            }
            // The header (plus any value) belongs to its own token.
            if try feed(owner: token, bytes: demuxBuffer[mark..<valueLimit], awaitedToken: awaitedToken) {
                demuxBuffer.removeSubrange(demuxBuffer.startIndex..<valueLimit)
                return true
            }
            switch name {
            case "BEGIN", "OUT", "ERR":
                demuxSectionOwner = token
            case "END", "FAILED":
                demuxSectionOwner = nil
            default:
                break
            }
            demuxBuffer.removeSubrange(demuxBuffer.startIndex..<valueLimit)
        }
    }

    /// Feeds bytes to one token's parser. Returns true when that token is
    /// the awaited one AND it just reached END/FAILED.
    private func feed(owner: String?, bytes: Data.SubSequence, awaitedToken: String) throws -> Bool {
        guard !bytes.isEmpty, let owner else { return false }
        var parser = pendingParsers[owner] ?? LinuxGuestFraming.Parser(token: owner, maxOutputBytes: 8 * 1024 * 1024)
        pendingParsers[owner] = parser
        let progress = parser.feed(bytes)
        pendingParsers[owner] = parser
        switch progress {
        case .finished(let code):
            let outcome = LinuxCommandOutcome(exitCode: code, stdout: parser.stdoutText, stderr: parser.stderrText)
            finishedOutcomes[owner] = outcome
            pendingParsers[owner] = nil
            return owner == awaitedToken
        case .failed(let reason):
            throw CheckFailure.message("guest framing failed for \(owner): \(reason)")
        case .needMore:
            return false
        }
    }

    /// Drains an END already buffered for `token`, if any.
    func bufferedEnd(token: String) -> LinuxCommandOutcome? {
        if let outcome = finishedOutcomes.removeValue(forKey: token) {
            return outcome
        }
        return nil
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
    /// buffer. Used for the session/service frames that have no BEGIN. The
    /// bytes also flow through the demuxer (which consumes them from its own
    /// buffer) so a later `awaitEnd` still sees every frame — reading raw
    /// bytes off the pipe must never steal a token's BEGIN/END.
    func readRaw(timeout: TimeInterval, until predicate: (Data) -> Bool) throws -> Data {
        rawBuffer = demuxBuffer // bytes already read but not yet demuxed
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(rawBuffer) { return rawBuffer }
            guard let chunk = readChunk(timeoutMs: 100) else { continue }
            if chunk.isEmpty {
                throw CheckFailure.message("runner console closed while waiting for a frame")
            }
            rawBuffer.append(chunk)
            // No awaited token: feed the demuxer in parallel so framed tokens
            // are parsed exactly once, in order.
            _ = try feedDemux(chunk, awaitedToken: "\u{0}no-await")
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

        // 13. HELLO/CAPS negotiation: the runner reports its protocol and
        //     concurrency tables.
        Checks.check("hello_caps") {
            let token = UUID().uuidString
            try runner.writeRaw(Wire.frame("HELLO", token: token))
            let raw = try runner.readRaw(timeout: 5) { Wire.endCode(in: $0, token: token) != nil }
            Checks.expect(Wire.endCode(in: raw, token: token) == 0, "HELLO end code")
            let capsPrefix = Data("\u{1e}FLOE-CAPS \(token) ".utf8)
            guard let range = raw.range(of: capsPrefix),
                  let terminator = raw[range.upperBound...].firstIndex(of: 0x1e) else {
                Checks.expect(false, "no CAPS frame in \(String(decoding: raw, as: UTF8.self))")
                return
            }
            let caps = String(decoding: raw[range.upperBound..<terminator], as: UTF8.self)
            Checks.expect(caps.contains("protocol=3"), "CAPS protocol: \(caps)")
            Checks.expect(caps.contains("maxCommands=8"), "CAPS maxCommands: \(caps)")
            Checks.expect(caps.contains("maxSessions=4"), "CAPS maxSessions: \(caps)")
            Checks.expect(caps.contains("runner="), "CAPS runner version: \(caps)")
        }

        // 14. Two commands run genuinely concurrently: a 2s sleeper and an
        //     echo issued together both complete, and the echo does not wait
        //     for the sleeper.
        Checks.check("concurrent_commands") {
            let slow = UUID().uuidString
            let fast = UUID().uuidString
            let started = Date()
            try runner.writeRaw(LinuxGuestFraming.execEnvelope(
                token: slow,
                argv: ["/bin/sh", "-c", "sleep 2; echo slow-done"],
                workingDirectory: nil,
                standardInput: nil
            ))
            try runner.writeRaw(LinuxGuestFraming.execEnvelope(
                token: fast,
                argv: ["/bin/echo", "fast-done"],
                workingDirectory: nil,
                standardInput: nil
            ))
            let fastOutcome = try runner.awaitEnd(token: fast, timeout: 8)
            let fastElapsed = Date().timeIntervalSince(started)
            let slowOutcome = try runner.awaitEnd(token: slow, timeout: 8)
            Checks.expect(fastOutcome.exitCode == 0, "fast exit \(fastOutcome.exitCode)")
            Checks.expect(fastOutcome.stdout == "fast-done\n", "fast stdout \(fastOutcome.stdout.debugDescription)")
            Checks.expect(fastElapsed < 1.8, "fast waited for slow (\(fastElapsed)s) — not concurrent")
            Checks.expect(slowOutcome.exitCode == 0, "slow exit \(slowOutcome.exitCode)")
            Checks.expect(slowOutcome.stdout == "slow-done\n", "slow stdout \(slowOutcome.stdout.debugDescription)")
        }

        // 15. Concurrent outputs stay separated per token: two interleaved
        //     printers never leak into each other's sections.
        Checks.check("concurrent_output_isolation") {
            let a = UUID().uuidString
            let b = UUID().uuidString
            let scriptA = "for i in 1 2 3 4 5; do echo A-$i; sleep 0.05; done"
            let scriptB = "for i in 1 2 3 4 5; do echo B-$i; sleep 0.05; done"
            try runner.writeRaw(LinuxGuestFraming.execEnvelope(
                token: a, argv: ["/bin/sh", "-c", scriptA], workingDirectory: nil, standardInput: nil
            ))
            try runner.writeRaw(LinuxGuestFraming.execEnvelope(
                token: b, argv: ["/bin/sh", "-c", scriptB], workingDirectory: nil, standardInput: nil
            ))
            let outcomeA = try runner.awaitEnd(token: a, timeout: 10)
            let outcomeB = try runner.awaitEnd(token: b, timeout: 10)
            Checks.expect(outcomeA.exitCode == 0 && outcomeB.exitCode == 0, "exits \(outcomeA.exitCode)/\(outcomeB.exitCode)")
            Checks.expect(!outcomeA.stdout.contains("B-"), "A leaked B output: \(outcomeA.stdout.debugDescription)")
            Checks.expect(!outcomeB.stdout.contains("A-"), "B leaked A output: \(outcomeB.stdout.debugDescription)")
            Checks.expect(outcomeA.stdout.contains("A-1") && outcomeA.stdout.contains("A-5"), "A output incomplete: \(outcomeA.stdout.debugDescription)")
            Checks.expect(outcomeB.stdout.contains("B-1") && outcomeB.stdout.contains("B-5"), "B output incomplete: \(outcomeB.stdout.debugDescription)")
        }

        // 16. Two independent PTY sessions run at the same time (A/B
        //     terminals): separate output, separate input, separate exit.
        Checks.check("concurrent_pty_sessions") {
            let a = UUID().uuidString
            let b = UUID().uuidString
            try runner.writeRaw(Wire.chunked(
                "OPEN", token: a,
                payload: Wire.openPayload(cwd: "", cols: 80, rows: 24, argv: ["/bin/sh"])
            ))
            try runner.writeRaw(Wire.chunked(
                "OPEN", token: b,
                payload: Wire.openPayload(cwd: "", cols: 80, rows: 24, argv: ["/bin/sh"])
            ))
            _ = try runner.readRaw(timeout: 5) { data in
                data.range(of: Data("\u{1e}FLOE-BEGIN \(a)\u{1e}".utf8)) != nil
            }
            _ = try runner.readRaw(timeout: 5) { data in
                data.range(of: Data("\u{1e}FLOE-BEGIN \(b)\u{1e}".utf8)) != nil
            }
            try runner.writeRaw(Wire.input(token: a, bytes: Data("echo marker-A\n".utf8)))
            try runner.writeRaw(Wire.input(token: b, bytes: Data("echo marker-B\n".utf8)))
            _ = try runner.readRaw(timeout: 6) { data in
                data.range(of: Data("marker-A".utf8)) != nil && data.range(of: Data("marker-B".utf8)) != nil
            }
            try runner.writeRaw(Wire.input(token: a, bytes: Data("exit 3\n".utf8)))
            try runner.writeRaw(Wire.input(token: b, bytes: Data("exit 5\n".utf8)))
            let raw = try runner.readRaw(timeout: 8) { data in
                Wire.endCode(in: data, token: a) != nil && Wire.endCode(in: data, token: b) != nil
            }
            Checks.expect(Wire.endCode(in: raw, token: a) == 3, "session A exit \(String(describing: Wire.endCode(in: raw, token: a)))")
            Checks.expect(Wire.endCode(in: raw, token: b) == 5, "session B exit \(String(describing: Wire.endCode(in: raw, token: b)))")
        }

        // 17. Targeted cancellation: SIGNAL INT kills only the addressed
        //     command's process group; a concurrently running command is
        //     untouched.
        Checks.check("targeted_signal_cancel") {
            let victim = UUID().uuidString
            let survivor = UUID().uuidString
            try runner.writeRaw(LinuxGuestFraming.execEnvelope(
                token: victim,
                argv: ["/bin/sh", "-c", "trap '' TERM INT; sleep 30"],
                workingDirectory: nil, standardInput: nil
            ))
            try runner.writeRaw(LinuxGuestFraming.execEnvelope(
                token: survivor,
                argv: ["/bin/sh", "-c", "sleep 1; echo survivor-done"],
                workingDirectory: nil, standardInput: nil
            ))
            Thread.sleep(forTimeInterval: 0.3)
            try runner.writeRaw(Wire.frame("SIGNAL", token: victim, extra: "INT"))
            let survivorOutcome = try runner.awaitEnd(token: survivor, timeout: 8)
            Checks.expect(survivorOutcome.exitCode == 0, "survivor exit \(survivorOutcome.exitCode)")
            Checks.expect(survivorOutcome.stdout == "survivor-done\n", "survivor stdout \(survivorOutcome.stdout.debugDescription)")
            let victimOutcome = try runner.awaitEnd(token: victim, timeout: 10)
            Checks.expect(victimOutcome.exitCode == 130, "victim exit \(victimOutcome.exitCode) (want 130 after TERM->KILL escalation)")
        }

        // 18. Fragmented frames: markers split across console chunks still
        //     parse (the real console delivers arbitrary chunking). The
        //     host-side parser must hold marker-prefix tails; the runner
        //     must hold partial frames. Drive a chunked EXEC whose frames
        //     are written byte-by-byte.
        Checks.check("fragmented_frames") {
            let token = UUID().uuidString
            let payload = Wire.execPayload(argv: ["/bin/sh", "-c", "echo fragmented-ok"], stdin: Data())
            let frames = Wire.chunked("EXEC", token: token, payload: payload, chunkSize: 1500)
            for byte in frames {
                try runner.writeRaw(Data([byte]))
            }
            let outcome = try runner.awaitEnd(token: token, timeout: 10)
            Checks.expect(outcome.exitCode == 0, "fragmented exit \(outcome.exitCode)")
            Checks.expect(outcome.stdout == "fragmented-ok\n", "fragmented stdout \(outcome.stdout.debugDescription)")
        }

        // 19. Host parser: FAILED split across feeds (including pre-BEGIN)
        //     resolves to .failed with the reason, never silently dropped.
        Checks.check("parser_failed_frame_split") {
            let token = "01234567-89ab-cdef-0123-456789abcdef"
            let stream = LinuxGuestFraming.failedMarkerPrefix(token) + Data("unreaped\u{1e}".utf8)
            for chunkSize in [1, 3, 7, 13] {
                var parser = LinuxGuestFraming.Parser(token: token, maxOutputBytes: 1 << 20)
                var failed: String?
                var index = stream.startIndex
                while index < stream.endIndex {
                    let end = stream.index(index, offsetBy: chunkSize, limitedBy: stream.endIndex) ?? stream.endIndex
                    switch parser.feed(Data(stream[index..<end])) {
                    case .needMore: break
                    case .finished(let code): failed = "unexpected finish \(code)"
                    case .failed(let reason): failed = reason
                    }
                    index = end
                }
                Checks.expect(failed?.contains("unreaped") == true, "chunk \(chunkSize): FAILED reason lost (\(failed ?? "nil"))")
            }
        }

        // 20. Host control parser: PID/CAPS/END values split across feeds
        //     keep their state (regression: prefix consumption before the
        //     value arrived used to lose it).
        Checks.check("control_parser_split_values") {
            let token = "ctl-1"
            var stream = Data("\u{1e}FLOE-PID \(token) 4321\u{1e}".utf8)
            stream.append(Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8\u{1e}".utf8))
            stream.append(Data("\u{1e}FLOE-END \(token) 0\u{1e}".utf8))
            for chunkSize in [1, 2, 5, 11] {
                var parser = LinuxGuestFraming.ControlParser(token: token)
                var exit: Int32?
                var index = stream.startIndex
                while index < stream.endIndex {
                    let end = stream.index(index, offsetBy: chunkSize, limitedBy: stream.endIndex) ?? stream.endIndex
                    switch parser.feed(Data(stream[index..<end])) {
                    case .needMore: break
                    case .finished(let code): exit = code
                    }
                    index = end
                }
                Checks.expect(exit == 0, "chunk \(chunkSize): control exit \(String(describing: exit))")
                Checks.expect(parser.pid == 4321, "chunk \(chunkSize): pid \(String(describing: parser.pid))")
                Checks.expect(parser.protocolVersion == 3, "chunk \(chunkSize): protocol \(String(describing: parser.protocolVersion))")
            }
        }

        // 21. Host session parser: FAILED-before-BEGIN and split END both
        //     resolve; no frame is dropped when the terminator's value is
        //     fragmented.
        Checks.check("session_parser_split_frames") {
            let id = "sess-1"
            for chunkSize in [1, 4, 9] {
                var parser = LinuxGuestFraming.SessionParser(sessionID: id)
                var stream = Data("boot-noise".utf8)
                stream.append(LinuxGuestFraming.failedMarkerPrefix(id))
                stream.append(Data("unreaped\u{1e}".utf8))
                var failed: String?
                var index = stream.startIndex
                while index < stream.endIndex {
                    let end = stream.index(index, offsetBy: chunkSize, limitedBy: stream.endIndex) ?? stream.endIndex
                    switch parser.feed(Data(stream[index..<end])) {
                    case .needMore, .output: break
                    case .outputAndFinished(_, let code): failed = "unexpected finish \(code)"
                    case .finished(let code): failed = "unexpected finish \(code)"
                    case .failed(let reason): failed = reason
                    }
                    index = end
                }
                Checks.expect(failed?.contains("unreaped") == true, "chunk \(chunkSize): session FAILED lost (\(failed ?? "nil"))")
            }
        }

        // 22. Runner quarantine: a cancelled command whose process cannot
        //     die promptly never reports END 130 while it is still running —
        //     the runner escalates and only ENDs after the reap. (A truly
        //     SIGKILL-proof process needs kernel state we cannot synthesize
        //     here; this proves the reap-before-END ordering and that the
        //     channel serves the next command immediately after.)
        Checks.check("cancel_reap_before_end") {
            let token = UUID().uuidString
            try runner.writeRaw(LinuxGuestFraming.execEnvelope(
                token: token,
                argv: ["/bin/sh", "-c", "trap '' TERM INT; while :; do :; done"],
                workingDirectory: nil, standardInput: nil
            ))
            Thread.sleep(forTimeInterval: 0.3)
            try runner.writeRaw(Wire.frame("SIGNAL", token: token, extra: "INT"))
            let outcome = try runner.awaitEnd(token: token, timeout: 10)
            Checks.expect(outcome.exitCode == 130, "cancel exit \(outcome.exitCode)")
            // The reaped group is gone: no matching child remains.
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            probe.arguments = ["-f", "trap '' TERM INT; while :; do :; done"]
            try? probe.run()
            probe.waitUntilExit()
            Checks.expect(probe.terminationStatus != 0, "cancelled process group survived the reported END")
            let next = try runner.run(token: UUID().uuidString, argv: ["/bin/echo", "channel-alive"], timeout: 5)
            Checks.expect(next.exitCode == 0, "channel dead after cancel: \(next.stderr)")
            Checks.expect(next.stdout == "channel-alive\n", "next stdout \(next.stdout.debugDescription)")
        }

        // 23. Control exchanges stay responsive while commands and a session
        //     run (prioritized control channel): ALIVE for an unknown pid
        //     answers promptly between two long-running commands.
        Checks.check("control_channel_during_commands") {
            let longA = UUID().uuidString
            let longB = UUID().uuidString
            let ctl = UUID().uuidString
            try runner.writeRaw(LinuxGuestFraming.execEnvelope(
                token: longA, argv: ["/bin/sleep", "2"], workingDirectory: nil, standardInput: nil
            ))
            try runner.writeRaw(LinuxGuestFraming.execEnvelope(
                token: longB, argv: ["/bin/sleep", "2"], workingDirectory: nil, standardInput: nil
            ))
            Thread.sleep(forTimeInterval: 0.2)
            let started = Date()
            try runner.writeRaw(Wire.frame("ALIVE", token: ctl, extra: "424242"))
            let raw = try runner.readRaw(timeout: 5) { Wire.endCode(in: $0, token: ctl) != nil }
            Checks.expect(Wire.endCode(in: raw, token: ctl) == 3, "ALIVE unknown pid code")
            Checks.expect(Date().timeIntervalSince(started) < 2, "control blocked behind commands")
            _ = try runner.awaitEnd(token: longA, timeout: 8)
            _ = try runner.awaitEnd(token: longB, timeout: 8)
        }
    }
}

extension Runner {
    var diagnosticsText: String { diagnostics.text }
}
