// FloeExecution — Linux guest console command channel.
//
// The guest image runs one long-lived Floe guest runner on the virtio
// console. The host frames each command as
//
//   \x1eFLOE-EXEC <token> <base64 payload>\n
//   payload: u32 fieldCount, then per field u32 byteCount + raw bytes,
//            field order = [cwd, stdin, argv0, argv1, ...]
//
// and the runner answers on the same console with
//
//   \x1eFLOE-BEGIN <token>\x1e
//   \x1eFLOE-OUT <token>\x1e <stdout bytes until the next marker>
//   \x1eFLOE-ERR <token>\x1e <stderr bytes until the next marker>
//   \x1eFLOE-END <token> <exit code>\x1e
//
// Bytes before BEGIN (boot logs, console echo) are discarded. Output is
// capped while streaming, the command has a wall-clock timeout, and
// cancellation/timeout sends Ctrl-C and poisons the channel so the service
// can stop a guest whose state is no longer known. The framed format is part
// of the guest image qualification contract, not a security boundary.

import Foundation
import FloeCore
import FloeTools

enum LinuxGuestFraming {
    static let markerByte: UInt8 = 0x1e

    static func marker(_ name: String, token: String) -> Data {
        Data("\u{1e}FLOE-\(name) \(token)\u{1e}".utf8)
    }

    static func endMarkerPrefix(_ token: String) -> Data {
        Data("\u{1e}FLOE-END \(token) ".utf8)
    }

    static func execEnvelope(
        token: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?
    ) -> Data {
        var payload = Data()
        let fields: [String] = [workingDirectory ?? "", standardInput ?? ""] + argv
        appendUInt32(UInt32(fields.count), to: &payload)
        for field in fields {
            let bytes = Data(field.utf8)
            appendUInt32(UInt32(bytes.count), to: &payload)
            payload.append(bytes)
        }
        var envelope = Data("\u{1e}FLOE-EXEC \(token) ".utf8)
        envelope.append(Data(payload.base64EncodedString().utf8))
        envelope.append(0x0a)
        return envelope
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

/// Runs one command at a time over one guest console. The actor is the
/// serialization point that makes a single guest interpreter safe to share
/// between shell, localPython and localService callers.
public actor LinuxGuestCommandChannel {
    private let transport: any LinuxGuestConsoleTransport
    private let limits: LinuxGuestLimits
    private var stream: AsyncStream<Data>?
    private var activeToken: String?
    private var poisoned = false

    public init(transport: any LinuxGuestConsoleTransport, limits: LinuxGuestLimits = .standard) {
        self.transport = transport
        self.limits = limits
    }

    /// True while a command is in flight.
    public var isBusy: Bool { activeToken != nil }

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
        guard activeToken == nil else {
            throw LinuxGuestError.invalidConfiguration("another guest command is still running")
        }

        let token = UUID().uuidString
        activeToken = token
        defer { activeToken = nil }

        let effectiveTimeout = limits.clampedTimeout(timeout)
        let effectiveLimit = limits.clampedOutputBytes(maxOutputBytes)
        let envelope = LinuxGuestFraming.execEnvelope(
            token: token,
            argv: argv,
            workingDirectory: workingDirectory,
            standardInput: standardInput
        )
        guard envelope.count <= limits.maxCommandBytes else {
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

        try await transport.write(Array(envelope))

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

    /// Sends Ctrl-C and marks the guest state unknown. Safe to call while a
    /// command is in flight (the queued interrupt byte reaches the guest).
    public func interrupt() async {
        poisoned = true
        try? await transport.write([0x03])
    }

    public func close() async {
        stream = nil
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
