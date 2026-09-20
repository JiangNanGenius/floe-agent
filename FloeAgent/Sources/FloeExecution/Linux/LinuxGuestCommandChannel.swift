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
                    keepTail(longestMarker - 1)
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

        let buffer = LinuxGuestChunkBuffer()
        let consoleStream = await ensureStream()
        let reader = Task {
            for await chunk in consoleStream {
                await buffer.push(chunk)
            }
            await buffer.finish()
        }
        defer { reader.cancel() }

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

        for frame in LinuxGuestFraming.payloadHeader("EXEC", token: token, payload: payload) {
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

    /// Reads the console stream until the session ends. Runs as a detached
    /// task so `openSession` can return the live handle immediately.
    private func pumpSession(_ session: LinuxGuestInteractiveSession) async {
        let consoleStream = await ensureStream()
        while !Task.isCancelled {
            var parser = LinuxGuestFraming.SessionParser(sessionID: session.id)
            for await chunk in consoleStream {
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
            // Stream ended (guest stopped): finish the session.
            await session.finish(exit: -1)
            if activeSession === session { activeSession = nil }
            return
        }
    }

    /// Sends Ctrl-C and marks the guest state unknown. Safe to call while a
    /// command is in flight (the queued interrupt byte reaches the guest).
    public func interrupt() async {
        poisoned = true
        try? await transport.write([0x03])
    }

    public func close() async {
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
