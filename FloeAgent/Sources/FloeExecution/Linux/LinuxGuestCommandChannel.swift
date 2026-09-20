// FloeExecution — Linux guest console command channel (protocol v2).
//
// The guest image runs one long-lived Floe runner on the virtio console. All
// host→guest payloads travel as base64 chunks so a payload can exceed the
// console tty's canonical line limit (a 64 KiB script is ~22 chunks), and the
// runner reassembles them before executing:
//
//   \x1eFLOE-EXEC <token> <payloadBytes> <chunkCount>\x1e\n
//   \x1eFLOE-CHUNK <token> <index> <base64>\x1e\n      (chunkCount lines)
//   \x1eFLOE-RUN <token>\x1e\n
//   payload = u32 fieldCount, then per field u32 byteCount + raw bytes,
//             field order = [cwd, stdin, argv0, argv1, ...]
//
// Command responses:
//   \x1eFLOE-BEGIN <token>\x1e
//   \x1eFLOE-OUT <token>\x1e <stdout bytes until the next marker>
//   \x1eFLOE-ERR <token>\x1e <stderr bytes until the next marker>
//   \x1eFLOE-END <token> <exit code>\x1e
//
// Interactive PTY sessions (shell.*) take over the console until they end
// (frame names agreed with the guest-runner worker):
//   \x1eFLOE-OPEN <id> <payloadBytes> <chunkCount>\x1e\n + CHUNKs + RUN
//   payload = [mode="pty", cwd, columns, rows, argv0, argv1, ...]
//   host:  \x1eFLOE-IN <id> <base64>\x1e, \x1eFLOE-SIGNAL <id> INT|TERM|WINCH [rows]\x1e,
//          \x1eFLOE-CLOSE <id>\x1e
//   guest: \x1eFLOE-OUT <id>\x1e <raw pty bytes> \x1eFLOE-END <id> <exit>\x1e
//   (host input is always framed base64: the serial console has no reliable
//    raw channel and 0x1e/0x03 would collide with framing / the tty.)
//
// Bytes before BEGIN (boot logs, console echo) are discarded. Output is
// capped while streaming, commands have a wall-clock timeout, and
// cancellation/timeout sends Ctrl-C and poisons the channel so the service
// can stop a guest whose state is no longer known.

import Foundation
import FloeCore
import FloeTools

enum LinuxGuestFraming {
    static let markerByte: UInt8 = 0x1e
    /// Base64 characters per console line; the guest tty canonical buffer is
    /// 4096 bytes, so this stays well below it.
    static let maxChunkCharacters = 3000
    /// One-shot payloads whose whole EXEC line fits here are sent inline (the
    /// form the guest runner's parser handles without reassembly); anything
    /// larger uses CHUNK frames so no single console line exceeds the tty
    /// buffer.
    static let inlineLineLimit = 3800

    static func marker(_ name: String, token: String) -> Data {
        Data("\u{1e}FLOE-\(name) \(token)\u{1e}".utf8)
    }

    static func endMarkerPrefix(_ token: String) -> Data {
        Data("\u{1e}FLOE-END \(token) ".utf8)
    }

    static func controlLine(_ name: String, token: String, arguments: [String] = []) -> Data {
        let suffix = arguments.isEmpty ? "" : " " + arguments.joined(separator: " ")
        return Data("\u{1e}FLOE-\(name) \(token)\(suffix)\u{1e}\n".utf8)
    }

    static func payload(of argv: [String], workingDirectory: String?, standardInput: String?) -> Data {
        var payload = Data()
        let fields: [String] = [workingDirectory ?? "", standardInput ?? ""] + argv
        appendUInt32(UInt32(fields.count), to: &payload)
        for field in fields {
            let bytes = Data(field.utf8)
            appendUInt32(UInt32(bytes.count), to: &payload)
            payload.append(bytes)
        }
        return payload
    }

    /// Payload for a background service: `[cwd, logPath, argv...]`. The
    /// runner appends stdout/stderr to `logPath` (a guest path inside the
    /// environment share) and never waits for the process.
    static func servicePayload(of argv: [String], workingDirectory: String?, logPath: String) -> Data {
        var payload = Data()
        let fields: [String] = [workingDirectory ?? "", logPath] + argv
        appendUInt32(UInt32(fields.count), to: &payload)
        for field in fields {
            let bytes = Data(field.utf8)
            appendUInt32(UInt32(bytes.count), to: &payload)
            payload.append(bytes)
        }
        return payload
    }

    /// Inline EXEC envelope: `\x1eFLOE-EXEC <token> <base64 payload>\n`.
    /// Dedicated helper so the guest runner's native protocol check can drive
    /// the exact host bytes.
    static func execEnvelope(
        token: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?
    ) -> Data {
        inlineEnvelope(name: "EXEC", token: token, payload: payload(of: argv, workingDirectory: workingDirectory, standardInput: standardInput))
    }

    static func inlineEnvelope(name: String, token: String, payload: Data) -> Data {
        Data("\u{1e}FLOE-\(name) \(token) \(payload.base64EncodedString())\n".utf8)
    }

    /// Frames for one payload transfer. EXEC accepts the inline fast path
    /// (the guest runner decodes both forms); OPEN and SPAWN are chunked only
    /// because the runner's session/service assemblers expect the header form.
    static func payloadFrames(name: String, token: String, payload: Data, allowInline: Bool = true) -> [Data] {
        if allowInline {
            let inline = inlineEnvelope(name: name, token: token, payload: payload)
            if inline.count <= inlineLineLimit { return [inline] }
        }
        return payloadHeader(name, token: token, payload: payload)
    }

    /// Frames for one payload transfer: header, base64 chunks, RUN.
    static func payloadHeader(_ name: String, token: String, payload: Data) -> [Data] {
        var lines: [String] = []
        let base64 = payload.base64EncodedString()
        var start = base64.startIndex
        while start < base64.endIndex {
            let end = base64.index(start, offsetBy: maxChunkCharacters, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[start..<end]))
            start = end
        }
        if lines.isEmpty { lines.append("") }
        var frames: [Data] = [controlLine(name, token: token, arguments: ["\(payload.count)", "\(lines.count)"])]
        for (index, chunk) in lines.enumerated() {
            frames.append(controlLine("CHUNK", token: token, arguments: ["\(index)", chunk]))
        }
        frames.append(controlLine("RUN", token: token))
        return frames
    }

    static func sessionPayload(argv: [String], workingDirectory: String?, columns: Int, rows: Int) -> Data {
        var payload = Data()
        let fields: [String] = ["pty", workingDirectory ?? "", "\(max(1, columns))", "\(max(1, rows))"] + argv
        appendUInt32(UInt32(fields.count), to: &payload)
        for field in fields {
            let bytes = Data(field.utf8)
            appendUInt32(UInt32(bytes.count), to: &payload)
            payload.append(bytes)
        }
        return payload
    }

    static func sessionInputLine(sessionID: String, bytes: Data) -> Data {
        controlLine("IN", token: sessionID, arguments: [bytes.base64EncodedString()])
    }

    static func sessionSignalLine(sessionID: String, signal: String, rows: Int?, columns: Int?) -> Data {
        var arguments = [signal]
        if let rows { arguments.append("\(max(1, rows))") }
        if let columns { arguments.append("\(max(1, columns))") }
        return controlLine("SIGNAL", token: sessionID, arguments: arguments)
    }

    static func sessionCloseLine(sessionID: String) -> Data {
        controlLine("CLOSE", token: sessionID)
    }

    /// Raw PTY output starts at the OUT marker and ends at END, matching the
    /// one-shot channel so the guest runner reuses one writer.
    static func sessionOutputMarker(_ sessionID: String) -> Data {
        marker("OUT", token: sessionID)
    }

    static func sessionEndPrefix(_ sessionID: String) -> Data {
        Data("\u{1e}FLOE-END \(sessionID) ".utf8)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    enum Section {
        case stdout
        case stderr
    }

    enum Progress: Equatable {
        case needMore
        case finished(Int32)
        case failed(String)
    }

    /// Streaming parser for one command token. Bounded: section buffers never
    /// exceed `maxOutputBytes`, and unparsed tails keep only the bytes a
    /// split marker could still need.
    struct Parser {
        let token: String
        let maxOutputBytes: Int
        private(set) var stdout = Data()
        private(set) var stderr = Data()
        private(set) var truncated = false
        private var pending = Data()
        private var sawBegin = false
        /// The END prefix was consumed; the pending bytes are the exit code
        /// digits and must not be flushed as command output.
        private var awaitingExitCode = false
        private var section: Section = .stdout

        init(token: String, maxOutputBytes: Int) {
            self.token = token
            self.maxOutputBytes = maxOutputBytes
        }

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }

        mutating func feed(_ data: Data) -> Progress {
            pending.append(data)
            let begin = LinuxGuestFraming.marker("BEGIN", token: token)
            let out = LinuxGuestFraming.marker("OUT", token: token)
            let err = LinuxGuestFraming.marker("ERR", token: token)
            let end = LinuxGuestFraming.endMarkerPrefix(token)
            let longestMarker = max(begin.count, out.count, err.count, end.count)

            while true {
                if !sawBegin {
                    guard let range = pending.range(of: begin) else {
                        keepTail(longestMarker - 1)
                        return .needMore
                    }
                    pending.removeSubrange(pending.startIndex..<range.upperBound)
                    sawBegin = true
                    section = .stdout
                    continue
                }

                if awaitingExitCode {
                    guard let terminator = pending.firstIndex(of: LinuxGuestFraming.markerByte) else {
                        if pending.count > 32 {
                            return .failed("guest exit marker is malformed")
                        }
                        return .needMore
                    }
                    let digits = String(decoding: pending[pending.startIndex..<terminator], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    pending.removeSubrange(pending.startIndex...terminator)
                    return .finished(Int32(digits) ?? -1)
                }

                var earliest: (range: Range<Data.Index>, kind: UInt8)?
                for (kind, marker) in [(UInt8(0), out), (UInt8(1), err), (UInt8(2), end)] {
                    if let range = pending.range(of: marker) {
                        if let current = earliest {
                            if range.lowerBound < current.range.lowerBound {
                                earliest = (range, kind)
                            }
                        } else {
                            earliest = (range, kind)
                        }
                    }
                }

                guard let hit = earliest else {
                    // No marker yet: everything except a suffix that could
                    // still be the start of a split marker belongs to the
                    // current section. (Dropping it here would silently
                    // truncate output that spans more than one console chunk.)
                    flushPendingPrefix(markers: [begin, out, err, end])
                    return .needMore
                }

                append(pending[pending.startIndex..<hit.range.lowerBound])
                pending.removeSubrange(pending.startIndex..<hit.range.upperBound)
                switch hit.kind {
                case 0:
                    section = .stdout
                case 1:
                    section = .stderr
                default:
                    awaitingExitCode = true
                    continue
                }
            }
        }

        private mutating func append(_ bytes: Data.SubSequence) {
            guard !bytes.isEmpty else { return }
            var target = section == .stdout ? stdout : stderr
            let room = maxOutputBytes - target.count
            if room <= 0 {
                truncated = true
                return
            }
            if bytes.count > room {
                target.append(contentsOf: bytes.prefix(room))
                truncated = true
            } else {
                target.append(contentsOf: bytes)
            }
            if section == .stdout { stdout = target } else { stderr = target }
        }

        /// Appends the parseable prefix of `pending` to the current section
        /// and retains only the longest suffix that is still a proper prefix
        /// of one of `markers` (a marker split across console chunks). Used
        /// once BEGIN has been seen; the prelude before BEGIN is still
        /// discarded by `keepTail`.
        private mutating func flushPendingPrefix(markers: [Data]) {
            let maxTail = max(0, (markers.map(\.count).max() ?? 1) - 1)
            var retain = min(maxTail, pending.count)
            while retain > 0 {
                let tail = pending.suffix(retain)
                if markers.contains(where: { $0.starts(with: tail) }) { break }
                retain -= 1
            }
            let flushEnd = pending.index(pending.endIndex, offsetBy: -retain)
            append(pending[pending.startIndex..<flushEnd])
            pending.removeSubrange(pending.startIndex..<flushEnd)
        }

        private mutating func keepTail(_ count: Int) {
            guard count > 0, pending.count > count else { return }
            pending.removeFirst(pending.count - count)
        }
    }

    /// Streaming parser for one interactive session: everything between
    /// SESSION-BEGIN and SESSION-END is raw terminal output.
    struct SessionParser {
        let sessionID: String
        private var pending = Data()
        private var sawBegin = false

        init(sessionID: String) {
            self.sessionID = sessionID
        }

        enum Progress: Equatable {
            case needMore
            case output(Data)
            case outputAndFinished(Data, Int32)
            case finished(Int32)
        }

        mutating func feed(_ data: Data) -> Progress {
            pending.append(data)
            let begin = LinuxGuestFraming.sessionOutputMarker(sessionID)
            let end = LinuxGuestFraming.sessionEndPrefix(sessionID)
            if !sawBegin {
                guard let range = pending.range(of: begin) else {
                    trimToTail(begin.count - 1)
                    return .needMore
                }
                pending.removeSubrange(pending.startIndex..<range.upperBound)
                sawBegin = true
            }

            if let endRange = pending.range(of: end) {
                guard let terminator = pending[endRange.upperBound...].firstIndex(of: LinuxGuestFraming.markerByte) else {
                    // Exit digits are still in flight; emit everything before
                    // the END prefix and keep waiting for the rest.
                    let output = Data(pending[pending.startIndex..<endRange.lowerBound])
                    pending.removeSubrange(pending.startIndex..<endRange.lowerBound)
                    return output.isEmpty ? .needMore : .output(output)
                }
                let output = Data(pending[pending.startIndex..<endRange.lowerBound])
                let digits = String(decoding: pending[endRange.upperBound..<terminator], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                pending.removeSubrange(pending.startIndex...terminator)
                let exit = Int32(digits) ?? -1
                return output.isEmpty ? .finished(exit) : .outputAndFinished(output, exit)
            }

            let tail = max(end.count, begin.count) - 1
            guard pending.count > tail else { return .needMore }
            let output = Data(pending.prefix(pending.count - tail))
            pending.removeFirst(pending.count - tail)
            return output.isEmpty ? .needMore : .output(output)
        }

        private mutating func trimToTail(_ count: Int) {
            guard count > 0, pending.count > count else { return }
            pending.removeFirst(pending.count - count)
        }
    }

    /// Parser for control responses (SPAWN → PID + END, KILL/ALIVE → END).
    /// Unlike the command parser it tolerates a missing BEGIN and keeps only
    /// bounded text (guest diagnostics), because control commands have no
    /// output sections.
    struct ControlParser {
        let token: String
        let maxTextBytes = 64 * 1024
        private(set) var pid: Int32?
        private(set) var text = Data()
        private var pending = Data()
        private var section: Section = .stdout

        init(token: String) {
            self.token = token
        }

        var textString: String { String(decoding: text, as: UTF8.self) }

        enum Progress: Equatable {
            case needMore
            case finished(exit: Int32)
        }

        mutating func feed(_ data: Data) -> Progress {
            pending.append(data)
            // PID is `\x1eFLOE-PID <token> <pid>\x1e`: the value follows the
            // token, so only the token plus a space is the marker prefix (a
            // closed marker would never match a real PID frame).
            let pidPrefix = Data("\u{1e}FLOE-PID \(token) ".utf8)
            let begin = marker("BEGIN", token: token)
            let out = marker("OUT", token: token)
            let err = marker("ERR", token: token)
            let end = endMarkerPrefix(token)
            let longest = max(pidPrefix.count, begin.count, out.count, err.count, end.count)
            while true {
                var earliest: (range: Range<Data.Index>, kind: UInt8)?
                for (kind, candidate) in [(UInt8(0), pidPrefix), (UInt8(1), begin), (UInt8(2), out), (UInt8(3), err), (UInt8(4), end)] {
                    if let range = pending.range(of: candidate) {
                        if let current = earliest {
                            if range.lowerBound < current.range.lowerBound { earliest = (range, kind) }
                        } else {
                            earliest = (range, kind)
                        }
                    }
                }
                guard let hit = earliest else {
                    keepTail(longest - 1)
                    return .needMore
                }
                appendText(pending[pending.startIndex..<hit.range.lowerBound])
                pending.removeSubrange(pending.startIndex..<hit.range.upperBound)
                switch hit.kind {
                case 0:
                    guard let terminator = pending.firstIndex(of: LinuxGuestFraming.markerByte) else {
                        if pending.count > 32 { return .finished(exit: -1) }
                        return .needMore
                    }
                    let digits = String(decoding: pending[pending.startIndex..<terminator], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    pending.removeSubrange(pending.startIndex...terminator)
                    pid = Int32(digits)
                case 1:
                    continue
                case 2:
                    section = .stdout
                case 3:
                    section = .stderr
                default:
                    guard let terminator = pending.firstIndex(of: LinuxGuestFraming.markerByte) else {
                        if pending.count > 32 { return .finished(exit: -1) }
                        return .needMore
                    }
                    let digits = String(decoding: pending[pending.startIndex..<terminator], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    pending.removeSubrange(pending.startIndex...terminator)
                    return .finished(exit: Int32(digits) ?? -1)
                }
            }
        }

        private mutating func appendText(_ bytes: Data.SubSequence) {
            guard !bytes.isEmpty, text.count < maxTextBytes else { return }
            text.append(contentsOf: bytes.prefix(maxTextBytes - text.count))
        }

        private mutating func keepTail(_ count: Int) {
            guard count > 0, pending.count > count else { return }
            pending.removeFirst(pending.count - count)
        }
    }
}

/// Single-consumer chunk queue fed by the console reader task. `next()`
/// suspends until a chunk arrives; `finish()` or `fail()` releases it, so no
/// continuation is ever abandoned on cancellation.
private actor LinuxGuestChunkBuffer {
    private var chunks: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var finished = false
    private var failure: (any Error & Sendable)?

    func push(_ data: Data) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            chunks.append(data)
        }
    }

    func next() async -> Data? {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            if finished || !chunks.isEmpty {
                continuation.resume(returning: chunks.isEmpty ? nil : chunks.removeFirst())
            } else {
                waiter = continuation
            }
        }
    }

    func finish() {
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func fail(_ error: any Error & Sendable) {
        failure = error
        finish()
    }

    func takeFailure() -> (any Error & Sendable)? {
        let error = failure
        failure = nil
        return error
    }
}

/// One interactive guest terminal. Output is an ordered stream of raw PTY
/// bytes; input frames are base64 so binary keys never collide with markers.
public actor LinuxGuestInteractiveSession {
    public nonisolated let id: String
    private let transport: any LinuxGuestConsoleTransport
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let outputStream: AsyncStream<Data>
    private var exitCode: Int32?
    private var finished = false

    init(id: String, transport: any LinuxGuestConsoleTransport) {
        self.id = id
        self.transport = transport
        var continuation: AsyncStream<Data>.Continuation!
        self.outputStream = AsyncStream { continuation = $0 }
        self.outputContinuation = continuation
    }

    public func output() -> AsyncStream<Data> { outputStream }

    public var isFinished: Bool { finished }
    public var terminalExitCode: Int32? { exitCode }

    private var pendingChunks: [Data] = []
    private var outputWaiter: CheckedContinuation<Data?, Never>?

    /// Next buffered output chunk, waiting up to `timeoutMs`. Returns nil on
    /// timeout or when the session ended.
    public func nextOutput(timeoutMs: Int) async -> Data? {
        if !pendingChunks.isEmpty { return pendingChunks.removeFirst() }
        if finished { return nil }
        let chunk: Data? = await withTaskGroup(of: Data?.self) { group in
            group.addTask { await self.waitForChunk() }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(max(0, timeoutMs)))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            self.cancelOutputWaiter()
            return first
        }
        if let chunk { return chunk }
        if !pendingChunks.isEmpty { return pendingChunks.removeFirst() }
        return nil
    }

    private func waitForChunk() async -> Data? {
        if !pendingChunks.isEmpty { return pendingChunks.removeFirst() }
        if finished { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !pendingChunks.isEmpty {
                    continuation.resume(returning: pendingChunks.removeFirst())
                } else if finished {
                    continuation.resume(returning: nil)
                } else {
                    outputWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelOutputWaiter() }
        }
    }

    private func cancelOutputWaiter() {
        guard let waiter = outputWaiter else { return }
        outputWaiter = nil
        waiter.resume(returning: nil)
    }

    public func write(_ text: String) async throws {
        guard !finished else { throw LinuxGuestError.consoleUnavailable("session \(id) has ended") }
        try await transport.write(Array(LinuxGuestFraming.sessionInputLine(sessionID: id, bytes: Data(text.utf8))))
    }

    public func signal(_ signal: LinuxGuestSessionSignal, rows: Int? = nil, columns: Int? = nil) async {
        guard !finished else { return }
        try? await transport.write(Array(LinuxGuestFraming.sessionSignalLine(
            sessionID: id,
            signal: signal.rawValue,
            rows: rows,
            columns: columns
        )))
    }

    public func close() async {
        guard !finished else { return }
        finished = true
        try? await transport.write(Array(LinuxGuestFraming.sessionCloseLine(sessionID: id)))
        outputContinuation.finish()
    }

    fileprivate func deliver(_ data: Data) {
        guard !finished else { return }
        if let waiter = outputWaiter {
            outputWaiter = nil
            waiter.resume(returning: data)
        } else {
            pendingChunks.append(data)
        }
        outputContinuation.yield(data)
    }

    fileprivate func finish(exit: Int32) {
        guard !finished else { return }
        finished = true
        exitCode = exit
        if let waiter = outputWaiter {
            outputWaiter = nil
            waiter.resume(returning: nil)
        }
        outputContinuation.finish()
    }
}

public enum LinuxGuestSessionSignal: String, Sendable {
    case interrupt = "INT"
    case terminate = "TERM"
    case kill = "KILL"
    case window = "WINCH"
}

/// Runs one command at a time over one guest console, plus at most one
/// interactive session at a time. The actor is the serialization point that
/// makes a single guest interpreter safe to share between shell, localPython
/// and localService callers.
public actor LinuxGuestCommandChannel {
    private let transport: any LinuxGuestConsoleTransport
    private let limits: LinuxGuestLimits
    private var stream: AsyncStream<Data>?
    /// One long-lived console reader for the channel's lifetime. Cancelling a
    /// per-command reader would terminate the AsyncStream, so a guest could
    /// serve exactly one command; the reader keeps pumping chunks and each
    /// command (or session) consumes them from this buffer in turn.
    private var consoleBuffer: LinuxGuestChunkBuffer?
    private var consoleReader: Task<Void, Never>?
    private var activeToken: String?
    private var activeSession: LinuxGuestInteractiveSession?
    private var poisoned = false

    public init(transport: any LinuxGuestConsoleTransport, limits: LinuxGuestLimits = .standard) {
        self.transport = transport
        self.limits = limits
    }

    /// True while a command or interactive session is in flight.
    public var isBusy: Bool { activeToken != nil || activeSession != nil }

    /// True when a timeout or cancellation left the guest in an unknown
    /// state; the owner should stop the guest instead of reusing it.
    public var isPoisoned: Bool { poisoned }

    public func run(
        argv: [String],
        workingDirectory: String? = nil,
        standardInput: String? = nil,
        timeout: TimeInterval? = nil,
        maxOutputBytes: Int? = nil,
        cancellation: CancellationToken? = nil
    ) async throws -> LinuxCommandResult {
        guard !argv.isEmpty else {
            throw LinuxGuestError.invalidConfiguration("argv must not be empty")
        }
        guard argv.allSatisfy({ !$0.contains("\u{0}") }) else {
            throw LinuxGuestError.invalidConfiguration("argv must not contain NUL bytes")
        }
        guard activeToken == nil, activeSession == nil else {
            throw LinuxGuestError.invalidConfiguration("another guest command or session is still running")
        }

        let token = UUID().uuidString
        activeToken = token
        defer { activeToken = nil }

        let effectiveTimeout = limits.clampedTimeout(timeout)
        let effectiveLimit = limits.clampedOutputBytes(maxOutputBytes)
        let payload = LinuxGuestFraming.payload(
            of: argv,
            workingDirectory: workingDirectory,
            standardInput: standardInput
        )
        guard payload.count <= limits.maxCommandBytes else {
            throw LinuxGuestError.invalidConfiguration("command exceeds the \(limits.maxCommandBytes) byte guest limit")
        }

        let buffer = await ensureConsoleBuffer()

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(effectiveTimeout))
            guard !Task.isCancelled else { return }
            await self.failRun(
                token: token,
                buffer: buffer,
                error: LinuxGuestError.timedOut(seconds: effectiveTimeout)
            )
        }
        defer { timeoutTask.cancel() }

        let cancellationTask = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true {
                    await self.failRun(
                        token: token,
                        buffer: buffer,
                        error: FloeError.cancelled
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { cancellationTask.cancel() }

        for frame in LinuxGuestFraming.payloadFrames(name: "EXEC", token: token, payload: payload) {
            try await transport.write(Array(frame))
        }

        var parser = LinuxGuestFraming.Parser(token: token, maxOutputBytes: effectiveLimit)
        while true {
            guard let chunk = await buffer.next() else {
                if let failure = await buffer.takeFailure() {
                    throw failure
                }
                throw LinuxGuestError.consoleUnavailable("guest console closed before the command reported completion")
            }
            switch parser.feed(chunk) {
            case .needMore:
                continue
            case .finished(let exitCode):
                return LinuxCommandResult(
                    stdout: parser.stdoutText,
                    stderr: parser.stderrText,
                    exitCode: exitCode
                )
            case .failed(let reason):
                poisoned = true
                throw LinuxGuestError.consoleUnavailable(reason)
            }
        }
    }

    // MARK: background services (exec.localService)

    private struct ControlOutcome {
        var pid: Int32?
        var exit: Int32
        var text: String
    }

    /// Starts one detached guest service (`FLOE-SPAWN`): the runner forks a
    /// process group, appends its stdout/stderr to `logPath` (a guest path in
    /// the environment share) and reports the pid without waiting for it. The
    /// channel is free for the next command as soon as the pid arrives.
    public func spawnService(
        argv: [String],
        workingDirectory: String? = nil,
        logPath: String,
        timeout: TimeInterval? = nil,
        cancellation: CancellationToken? = nil
    ) async throws -> Int32 {
        guard !argv.isEmpty else {
            throw LinuxGuestError.invalidConfiguration("service argv must not be empty")
        }
        guard argv.allSatisfy({ !$0.contains("\u{0}") }), !logPath.contains("\u{0}") else {
            throw LinuxGuestError.invalidConfiguration("service argv and log path must not contain NUL bytes")
        }
        let payload = LinuxGuestFraming.servicePayload(of: argv, workingDirectory: workingDirectory, logPath: logPath)
        guard payload.count <= limits.maxCommandBytes else {
            throw LinuxGuestError.invalidConfiguration("service command exceeds the \(limits.maxCommandBytes) byte guest limit")
        }
        let outcome = try await performControl(
            name: "SPAWN",
            payload: payload,
            timeout: limits.clampedTimeout(timeout ?? limits.defaultCommandTimeout),
            cancellation: cancellation
        )
        guard outcome.exit == 0, let pid = outcome.pid, pid > 0 else {
            let detail = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LinuxGuestError.startFailed(
                detail.isEmpty ? "the guest did not report a service pid (exit \(outcome.exit))" : detail
            )
        }
        return pid
    }

    /// Kills one pid the guest runner itself spawned. Returns false when the
    /// guest reports that pid unknown (it already exited).
    public func killService(
        pid: Int32,
        timeout: TimeInterval? = nil,
        cancellation: CancellationToken? = nil
    ) async throws -> Bool {
        guard pid > 0 else {
            throw LinuxGuestError.invalidConfiguration("service pid must be positive")
        }
        let outcome = try await performControl(
            name: "KILL",
            arguments: [String(pid)],
            timeout: limits.clampedTimeout(timeout ?? 10),
            cancellation: cancellation
        )
        switch outcome.exit {
        case 0: return true
        case 3: return false
        default:
            let detail = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LinuxGuestError.startFailed(detail.isEmpty ? "guest rejected KILL \(pid) (exit \(outcome.exit))" : detail)
        }
    }

    /// True while the pid is alive in the guest. The runner only answers for
    /// pids it spawned, so a recycled host pid can never be mistaken for a
    /// Floe service.
    public func serviceAlive(
        pid: Int32,
        timeout: TimeInterval? = nil,
        cancellation: CancellationToken? = nil
    ) async throws -> Bool {
        guard pid > 0 else {
            throw LinuxGuestError.invalidConfiguration("service pid must be positive")
        }
        let outcome = try await performControl(
            name: "ALIVE",
            arguments: [String(pid)],
            timeout: limits.clampedTimeout(timeout ?? 10),
            cancellation: cancellation
        )
        switch outcome.exit {
        case 0: return true
        case 3: return false
        default:
            let detail = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LinuxGuestError.startFailed(detail.isEmpty ? "guest rejected ALIVE \(pid) (exit \(outcome.exit))" : detail)
        }
    }

    /// Serializes one control exchange (`SPAWN`/`KILL`/`ALIVE`) through the
    /// same single-consumer console path as commands and sessions.
    private func performControl(
        name: String,
        arguments: [String] = [],
        payload: Data? = nil,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> ControlOutcome {
        guard activeToken == nil, activeSession == nil else {
            throw LinuxGuestError.invalidConfiguration("another guest command or session is still running")
        }
        guard !poisoned else {
            throw LinuxGuestError.consoleUnavailable("the guest channel was poisoned by an earlier interrupted command")
        }
        let token = UUID().uuidString
        activeToken = token
        defer { activeToken = nil }

        let frames = payload.map {
            LinuxGuestFraming.payloadFrames(name: name, token: token, payload: $0, allowInline: false)
        } ?? [LinuxGuestFraming.controlLine(name, token: token, arguments: arguments)]

        let buffer = await ensureConsoleBuffer()

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self.failRun(
                token: token,
                buffer: buffer,
                error: LinuxGuestError.timedOut(seconds: timeout)
            )
        }
        defer { timeoutTask.cancel() }

        let cancellationTask = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true {
                    await self.failRun(token: token, buffer: buffer, error: FloeError.cancelled)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { cancellationTask.cancel() }

        for frame in frames {
            try await transport.write(Array(frame))
        }

        var parser = LinuxGuestFraming.ControlParser(token: token)
        while true {
            guard let chunk = await buffer.next() else {
                if let failure = await buffer.takeFailure() {
                    throw failure
                }
                throw LinuxGuestError.consoleUnavailable("guest console closed before the \(name) exchange completed")
            }
            switch parser.feed(chunk) {
            case .needMore:
                continue
            case .finished(let exit):
                return ControlOutcome(pid: parser.pid, exit: exit, text: parser.textString)
            }
        }
    }

    /// Opens an interactive PTY session in the guest. The channel is busy
    /// until the session ends; the returned handle streams raw terminal bytes.
    public func openSession(
        sessionID: String,
        argv: [String],
        workingDirectory: String?,
        columns: Int,
        rows: Int
    ) async throws -> LinuxGuestInteractiveSession {
        guard !argv.isEmpty else {
            throw LinuxGuestError.invalidConfiguration("session argv must not be empty")
        }
        guard activeToken == nil, activeSession == nil else {
            throw LinuxGuestError.invalidConfiguration("another guest command or session is still running")
        }
        let session = LinuxGuestInteractiveSession(id: sessionID, transport: transport)
        activeSession = session

        let payload = LinuxGuestFraming.sessionPayload(
            argv: argv,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows
        )
        for frame in LinuxGuestFraming.payloadHeader("OPEN", token: sessionID, payload: payload) {
            try await transport.write(Array(frame))
        }
        Task { await self.pumpSession(session) }
        return session
    }

    /// Reads console chunks until the session ends. Runs as a detached task so
    /// `openSession` can return the live handle immediately; it consumes the
    /// channel's shared console buffer, like commands do.
    private func pumpSession(_ session: LinuxGuestInteractiveSession) async {
        let buffer = await ensureConsoleBuffer()
        while !Task.isCancelled {
            var parser = LinuxGuestFraming.SessionParser(sessionID: session.id)
            while true {
                guard let chunk = await buffer.next() else {
                    // Guest stopped: finish the session instead of hanging.
                    await session.finish(exit: -1)
                    if activeSession === session { activeSession = nil }
                    return
                }
                switch parser.feed(chunk) {
                case .needMore:
                    continue
                case .output(let data):
                    await session.deliver(data)
                case .outputAndFinished(let data, let exit):
                    await session.deliver(data)
                    await session.finish(exit: exit)
                    if activeSession === session { activeSession = nil }
                    return
                case .finished(let exit):
                    await session.finish(exit: exit)
                    if activeSession === session { activeSession = nil }
                    return
                }
            }
        }
    }

    /// Sends Ctrl-C and marks the guest state unknown. Safe to call while a
    /// command is in flight (the queued interrupt byte reaches the guest).
    public func interrupt() async {
        poisoned = true
        try? await transport.write([0x03])
    }

    public func close() async {
        consoleReader?.cancel()
        consoleReader = nil
        if let buffer = consoleBuffer {
            await buffer.finish()
        }
        consoleBuffer = nil
        stream = nil
        let session = activeSession
        activeSession = nil
        if let session {
            await session.close()
        }
        await transport.close()
    }

    private func ensureStream() async -> AsyncStream<Data> {
        if let stream { return stream }
        let stream = await transport.output()
        self.stream = stream
        return stream
    }

    /// The channel's single console buffer, with one reader task that lives
    /// until `close()`. Sequential commands each consume from the same buffer,
    /// so a guest keeps serving after the first command.
    private func ensureConsoleBuffer() async -> LinuxGuestChunkBuffer {
        if let consoleBuffer { return consoleBuffer }
        let buffer = LinuxGuestChunkBuffer()
        consoleBuffer = buffer
        let stream = await ensureStream()
        consoleReader = Task {
            for await chunk in stream {
                await buffer.push(chunk)
            }
            await buffer.finish()
        }
        return buffer
    }

    private func failRun(
        token: String,
        buffer: LinuxGuestChunkBuffer,
        error: any Error & Sendable
    ) async {
        guard activeToken == token else { return }
        if !poisoned {
            poisoned = true
            try? await transport.write([0x03])
        }
        await buffer.fail(error)
    }
}
