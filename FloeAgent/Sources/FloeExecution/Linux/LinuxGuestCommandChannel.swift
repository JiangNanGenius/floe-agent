// FloeExecution — Linux guest console command channel (protocol v3).
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
//   \x1eFLOE-FAILED <token> <reason>\x1e   (process abandoned alive; never END)
//
// Capability negotiation (protocol 3): the host sends
//   \x1eFLOE-HELLO <token>\x1e
// and the runner answers
//   \x1eFLOE-CAPS <token> runner=<version> protocol=3 maxCommands=N maxSessions=M\x1e
//   \x1eFLOE-END <token> 0\x1e
// The channel refuses guests whose runner predates protocol 3 with
// LinuxGuestError.runnerUpgradeRequired — concurrent tokens are only safe
// when the guest really routes them.
//
// Interactive PTY sessions (shell.*) are concurrent too (protocol 3):
//   \x1eFLOE-OPEN <id> <payloadBytes> <chunkCount>\x1e\n + CHUNKs + RUN
//   payload = [mode="pty", cwd, columns, rows, argv0, argv1, ...]
//   host:  \x1eFLOE-IN <id> <base64>\x1e, \x1eFLOE-SIGNAL <id> INT|TERM|KILL|WINCH [rows]\x1e,
//          \x1eFLOE-CLOSE <id>\x1e
//   guest: \x1eFLOE-OUT <id>\x1e <raw pty bytes> \x1eFLOE-END <id> <exit>\x1e
//   (host input is always framed base64: the serial console has no reliable
//    raw channel and 0x1e/0x03 would collide with framing / the tty.)
//
// Multiple commands (bounded by LinuxGuestLimits.maxConcurrentCommands) and
// multiple PTY sessions (bounded by maxConcurrentSessions) run in parallel.
// The single console reader demultiplexes every guest frame by token into
// per-token bounded streams, so one chatty command cannot starve another,
// and control exchanges (SPAWN/KILL/ALIVE/HELLO) are prioritized ahead of
// bulk output delivery.
//
// Cancellation is token-local: the host sends FLOE-SIGNAL <token> INT, the
// guest escalates TERM -> KILL -> reap, and END arrives only after the
// process group is actually reaped. FLOE-FAILED means the child survived
// SIGKILL past the hard deadline; the channel marks itself poisoned so the
// owner resets the guest instead of believing anything stopped.
//
// Bytes before a token's BEGIN (boot logs, console echo) are discarded for
// that token. Output is capped while streaming, commands have a wall-clock
// timeout. The legacy raw 0x03 interrupt-all byte is only used by
// interrupt() as a last resort.
//
// Wire escape constraint: the console is in-band, so the router recognizes a
// frame boundary by the bytes themselves. A 0x1e followed by anything other
// than `FLOE-<known name> <valid token>` is preserved verbatim as section
// payload — raw 0x1e bytes, leading newlines, `\x1eFLOE-UNKNOWN …` and
// `\x1eFLOE-` without a token all survive byte-for-byte. The one sequence
// that cannot be represented is command output containing a byte-exact
// `\x1eFLOE-<known name> <token>\x1e` frame: it is (correctly) interpreted
// as that frame. Producers that must emit such bytes have to encode them.

import Foundation
import FloeCore
import FloeTools

enum LinuxGuestFraming {
    static let markerByte: UInt8 = 0x1e
    /// Guest→host frame names the router accepts. Anything else after a
    /// 0x1e marker is section payload, not a frame.
    static let guestFrameNames: Set<String> = ["BEGIN", "OUT", "ERR", "END", "FAILED", "PID", "CAPS"]
    /// Longest accepted token (guest MAX_TOKEN). Tokens are printable ASCII
    /// without spaces, so a frame header is unambiguous.
    static let maxTokenBytes = 96

    static func isValidGuestToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.utf8.count <= maxTokenBytes else { return false }
        return token.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7f }
    }
    /// Base64 characters per console line; the guest tty canonical buffer is
    /// 4096 bytes, so this stays well below it.
    static let maxChunkCharacters = 3000
    /// One-shot payloads whose whole EXEC line fits here are sent inline (the
    /// form the guest runner's parser handles without reassembly); anything
    /// larger uses CHUNK frames so no single console line exceeds the tty
    /// buffer.
    static let inlineLineLimit = 3800
    /// Guest protocol this host speaks. The runner reports its own protocol
    /// through FLOE-CAPS; anything below this fails channel setup.
    static let requiredProtocol = 3

    static func marker(_ name: String, token: String) -> Data {
        Data("\u{1e}FLOE-\(name) \(token)\u{1e}".utf8)
    }

    static func endMarkerPrefix(_ token: String) -> Data {
        Data("\u{1e}FLOE-END \(token) ".utf8)
    }

    static func failedMarkerPrefix(_ token: String) -> Data {
        Data("\u{1e}FLOE-FAILED \(token) ".utf8)
    }

    static func capsMarkerPrefix(_ token: String) -> Data {
        Data("\u{1e}FLOE-CAPS \(token) ".utf8)
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
        /// The FAILED prefix was consumed; the pending bytes are the reason.
        private var awaitingFailureReason = false
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
            let failed = LinuxGuestFraming.failedMarkerPrefix(token)
            let longestMarker = max(begin.count, out.count, err.count, end.count, failed.count)

            while true {
                if !sawBegin {
                    // BEGIN or FAILED can open the token's stream (FAILED
                    // arrives for a quarantine that raced the BEGIN). Both
                    // candidates are located before anything is consumed so
                    // a marker split across chunks is never half-eaten.
                    let beginRange = pending.range(of: begin)
                    let failedRange = pending.range(of: failed)
                    switch (beginRange, failedRange) {
                    case (nil, nil):
                        keepTail(longestMarker - 1)
                        return .needMore
                    case let (b?, f?) where b.lowerBound < f.lowerBound:
                        pending.removeSubrange(pending.startIndex..<b.upperBound)
                        sawBegin = true
                        section = .stdout
                        continue
                    case let (b?, nil):
                        pending.removeSubrange(pending.startIndex..<b.upperBound)
                        sawBegin = true
                        section = .stdout
                        continue
                    case let (_, f?):
                        pending.removeSubrange(pending.startIndex..<f.upperBound)
                        sawBegin = true
                        awaitingFailureReason = true
                        continue
                    }
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

                if awaitingFailureReason {
                    guard let terminator = pending.firstIndex(of: LinuxGuestFraming.markerByte) else {
                        if pending.count > 64 {
                            return .failed("guest failure marker is malformed")
                        }
                        return .needMore
                    }
                    let reason = String(decoding: pending[pending.startIndex..<terminator], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    pending.removeSubrange(pending.startIndex...terminator)
                    return .failed("guest abandoned the process alive (\(reason)); the guest state is unknown")
                }

                var earliest: (range: Range<Data.Index>, kind: UInt8)?
                for (kind, marker) in [(UInt8(0), out), (UInt8(1), err), (UInt8(2), end), (UInt8(3), failed)] {
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
                    flushPendingPrefix(markers: [begin, out, err, end, failed])
                    return .needMore
                }

                append(pending[pending.startIndex..<hit.range.lowerBound])
                pending.removeSubrange(pending.startIndex..<hit.range.upperBound)
                switch hit.kind {
                case 0:
                    section = .stdout
                case 1:
                    section = .stderr
                case 2:
                    awaitingExitCode = true
                    continue
                default:
                    awaitingFailureReason = true
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

    /// Streaming parser for one interactive session: everything between the
    /// opening marker (the runner's session BEGIN, or the first OUT) and END
    /// is raw terminal output.
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
            case failed(String)
        }

        mutating func feed(_ data: Data) -> Progress {
            pending.append(data)
            // The runner announces a session with BEGIN and re-announces
            // output bursts with OUT; either opens the stream (a session
            // whose child produced no output still gets a BEGIN + END). Every
            // OUT after the opener is a section re-announcement caused by
            // interleaved command output and is STRIPPED, not delivered as
            // terminal bytes.
            let out = LinuxGuestFraming.sessionOutputMarker(sessionID)
            let begin = LinuxGuestFraming.marker("BEGIN", token: sessionID)
            let end = LinuxGuestFraming.sessionEndPrefix(sessionID)
            let failed = LinuxGuestFraming.failedMarkerPrefix(sessionID)
            var output = Data()
            while true {
                if !sawBegin {
                    // Earliest of OUT/BEGIN/FAILED wins; candidates are
                    // located before anything is consumed so a split marker
                    // is never half-eaten.
                    var opener: Range<Data.Index>?
                    var openerIsFailure = false
                    for (candidate, isFailure) in [(out, false), (begin, false), (failed, true)] {
                        guard let range = pending.range(of: candidate) else { continue }
                        if let current = opener {
                            if range.lowerBound < current.lowerBound {
                                opener = range
                                openerIsFailure = isFailure
                            }
                        } else {
                            opener = range
                            openerIsFailure = isFailure
                        }
                    }
                    guard let opener else {
                        trimToTail(max(out.count, begin.count, failed.count) - 1)
                        return output.isEmpty ? .needMore : .output(output)
                    }
                    if openerIsFailure {
                        // Quarantined before any PTY output: consume only up
                        // to the FAILED prefix and parse the reason below.
                        output.append(pending[pending.startIndex..<opener.lowerBound])
                        pending.removeSubrange(pending.startIndex..<opener.lowerBound)
                        sawBegin = true
                    } else {
                        pending.removeSubrange(pending.startIndex..<opener.upperBound)
                        sawBegin = true
                    }
                    continue
                }

                // Earliest of OUT (strip), END (clean exit) and FAILED
                // (quarantine) wins. Values are parsed from their prefix, so
                // a split value keeps the parser state instead of being lost.
                var hit: (range: Range<Data.Index>, kind: UInt8)?
                for (kind, candidate) in [(UInt8(0), out), (UInt8(1), end), (UInt8(2), failed)] {
                    guard let range = pending.range(of: candidate) else { continue }
                    if let current = hit {
                        if range.lowerBound < current.range.lowerBound { hit = (range, kind) }
                    } else {
                        hit = (range, kind)
                    }
                }
                guard let hit else {
                    // No marker yet: everything except a suffix that could
                    // still be the start of a split marker is output.
                    let tail = max(out.count, end.count, failed.count) - 1
                    guard pending.count > tail else {
                        return output.isEmpty ? .needMore : .output(output)
                    }
                    output.append(pending.prefix(pending.count - tail))
                    pending.removeFirst(pending.count - tail)
                    return output.isEmpty ? .needMore : .output(output)
                }
                output.append(pending[pending.startIndex..<hit.range.lowerBound])
                if hit.kind == 0 {
                    pending.removeSubrange(pending.startIndex..<hit.range.upperBound)
                    continue
                }
                guard let terminator = pending[hit.range.upperBound...].firstIndex(of: LinuxGuestFraming.markerByte) else {
                    // Value bytes still in flight; emit everything before the
                    // prefix and keep the prefix for the next feed.
                    pending.removeSubrange(pending.startIndex..<hit.range.lowerBound)
                    return output.isEmpty ? .needMore : .output(output)
                }
                let value = String(decoding: pending[hit.range.upperBound..<terminator], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                pending.removeSubrange(pending.startIndex...terminator)
                if hit.kind == 2 {
                    return .failed("guest abandoned the session process alive (\(value))")
                }
                let exit = Int32(value) ?? -1
                return output.isEmpty ? .finished(exit) : .outputAndFinished(output, exit)
            }
        }

        private mutating func trimToTail(_ count: Int) {
            guard count > 0, pending.count > count else { return }
            pending.removeFirst(pending.count - count)
        }
    }

    /// Parser for control responses (HELLO → CAPS + END, SPAWN → PID + END,
    /// KILL/ALIVE → END). Unlike the command parser it tolerates a missing
    /// BEGIN and keeps only bounded text (guest diagnostics), because
    /// control commands have no output sections.
    struct ControlParser {
        let token: String
        let maxTextBytes = 64 * 1024
        private(set) var pid: Int32?
        private(set) var capabilities: String?
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
            // closed marker would never match a real PID frame). CAPS is the
            // same shape. For both, the value is consumed only when its
            // closing 0x1e is already buffered — a frame split mid-value
            // keeps the prefix instead of losing the value.
            let pidPrefix = Data("\u{1e}FLOE-PID \(token) ".utf8)
            let capsPrefix = LinuxGuestFraming.capsMarkerPrefix(token)
            let begin = marker("BEGIN", token: token)
            let out = marker("OUT", token: token)
            let err = marker("ERR", token: token)
            let end = endMarkerPrefix(token)
            let longest = max(pidPrefix.count, capsPrefix.count, begin.count, out.count, err.count, end.count)
            while true {
                var earliest: (range: Range<Data.Index>, kind: UInt8)?
                for (kind, candidate) in [(UInt8(0), pidPrefix), (UInt8(1), begin), (UInt8(2), out), (UInt8(3), err), (UInt8(4), end), (UInt8(5), capsPrefix)] {
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
                switch hit.kind {
                case 0, 5:
                    // Value frame: wait for the closing marker first.
                    guard let terminator = pending[hit.range.upperBound...].firstIndex(of: LinuxGuestFraming.markerByte) else {
                        if pending.count > 512 { return .finished(exit: -1) }
                        return .needMore
                    }
                    appendText(pending[pending.startIndex..<hit.range.lowerBound])
                    let value = String(decoding: pending[hit.range.upperBound..<terminator], as: UTF8.self)
                        .trimmingCharacters(in: hit.kind == 0 ? .whitespaces : .whitespacesAndNewlines)
                    pending.removeSubrange(pending.startIndex...terminator)
                    if hit.kind == 0 {
                        pid = Int32(value)
                    } else {
                        capabilities = value
                    }
                    continue
                case 1, 2, 3:
                    appendText(pending[pending.startIndex..<hit.range.lowerBound])
                    pending.removeSubrange(pending.startIndex..<hit.range.upperBound)
                    if hit.kind == 2 { section = .stdout }
                    if hit.kind == 3 { section = .stderr }
                    continue
                default:
                    // END: consume only when the exit digits are complete.
                    guard let terminator = pending[hit.range.upperBound...].firstIndex(of: LinuxGuestFraming.markerByte) else {
                        if pending.count > hit.range.upperBound + 32 { return .finished(exit: -1) }
                        return .needMore
                    }
                    appendText(pending[pending.startIndex..<hit.range.lowerBound])
                    let digits = String(decoding: pending[hit.range.upperBound..<terminator], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    pending.removeSubrange(pending.startIndex...terminator)
                    return .finished(exit: Int32(digits) ?? -1)
                }
            }
        }

        /// Parsed `protocol=N` from the CAPS payload, nil when absent.
        var protocolVersion: Int? {
            guard let capabilities else { return nil }
            for field in capabilities.split(separator: " ") {
                if field.hasPrefix("protocol="), let value = Int(field.dropFirst("protocol=".count)) {
                    return value
                }
            }
            return nil
        }

        /// Validation seam for a CAPS payload obtained out of band (the
        /// registry's upgrade path reports the guest's answer verbatim).
        mutating func setCapabilitiesForValidation(_ value: String) {
            capabilities = value
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

/// One bounded per-token output stream. The console router pushes demuxed
/// chunks here; the token's consumer awaits them. `finish`/`fail` release
/// exactly one waiter, so cancellation can never abandon a continuation.
/// There is no hard failure on buffer pressure: a guest can always print
/// faster than the console drains, so the stream keeps the newest bytes
/// within its bound and drops the oldest — a token parser that stops
/// consuming can never block the router, and with it every other token.
actor LinuxGuestTokenStream {
    private var chunks: [Data] = []
    private var buffered = 0
    private let maxBufferedBytes: Int
    private var waiter: CheckedContinuation<Data?, Never>?
    private var finished = false
    private var failure: (any Error & Sendable)?

    init(maxBufferedBytes: Int = 4 * 1024 * 1024) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    func push(_ data: Data) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
            return
        }
        chunks.append(data)
        buffered += data.count
        while buffered > maxBufferedBytes, !chunks.isEmpty {
            buffered -= chunks.removeFirst().count
        }
    }

    func next() async -> Data? {
        if !chunks.isEmpty {
            let chunk = chunks.removeFirst()
            buffered -= chunk.count
            return chunk
        }
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            if finished || !chunks.isEmpty {
                if chunks.isEmpty {
                    continuation.resume(returning: nil)
                } else {
                    let chunk = chunks.removeFirst()
                    buffered -= chunk.count
                    continuation.resume(returning: chunk)
                }
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

    /// Wakes a waiting reader with nil WITHOUT finishing the stream: a probe
    /// deadline uses this so the caller can still distinguish "the runner
    /// stayed silent" (stream open) from "the console closed".
    func wake() {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func isFinished() -> Bool { finished }

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
    /// Writes one frame through the owning channel's serialized console
    /// writer, so session input can never interleave mid-frame with command
    /// or control traffic.
    private let sendFrame: @Sendable (Data) async throws -> Void
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let outputStream: AsyncStream<Data>
    private var exitCode: Int32?
    private var failedReason: String?
    private var finished = false
    private var closeRequested = false

    init(id: String, sendFrame: @escaping @Sendable (Data) async throws -> Void) {
        self.id = id
        self.sendFrame = sendFrame
        var continuation: AsyncStream<Data>.Continuation!
        self.outputStream = AsyncStream { continuation = $0 }
        self.outputContinuation = continuation
    }

    public func output() -> AsyncStream<Data> { outputStream }

    public var isFinished: Bool { finished }
    public var terminalExitCode: Int32? { exitCode }
    /// Non-nil when the guest abandoned the session process alive (quarantined).
    public var failure: String? { failedReason }

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
        try await sendFrame(LinuxGuestFraming.sessionInputLine(sessionID: id, bytes: Data(text.utf8)))
    }

    public func signal(_ signal: LinuxGuestSessionSignal, rows: Int? = nil, columns: Int? = nil) async {
        guard !finished else { return }
        try? await sendFrame(LinuxGuestFraming.sessionSignalLine(
            sessionID: id,
            signal: signal.rawValue,
            rows: rows,
            columns: columns
        ))
    }

    /// Signals the guest to close the session (TERM escalation) and returns
    /// immediately; the session stays registered until the guest's END
    /// (reaped) or FAILED arrives on the token stream, so the close is
    /// confirmed rather than assumed.
    public func close() async {
        guard !finished else { return }
        closeRequested = true
        try? await sendFrame(LinuxGuestFraming.sessionCloseLine(sessionID: id))
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

    fileprivate func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        failedReason = reason
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

/// Concurrent command/session channel over one guest console (protocol 3).
/// One router task demultiplexes the console byte stream into per-token
/// bounded streams; commands, sessions and control exchanges consume their
/// own token's stream, so they proceed independently. The actor serializes
/// registration only; guest work is never serialized across tokens.
public actor LinuxGuestCommandChannel {
    private let transport: any LinuxGuestConsoleTransport
    private let limits: LinuxGuestLimits
    private var stream: AsyncStream<Data>?
    private var consoleReader: Task<Void, Never>?
    private var negotiated = false
    /// Live per-token streams. The router writes, token owners read.
    private var tokenStreams: [String: LinuxGuestTokenStream] = [:]
    /// Console byte residue between router reads (frames split across chunks).
    private var routerPending = Data()
    private var runningCommands: Set<String> = []
    private var sessions: [String: LinuxGuestInteractiveSession] = [:]
    /// Interrupts (timeout/cancellation) signaled to the guest but not yet
    /// confirmed by END/FAILED. The command's caller keeps consuming its
    /// token until the guest proves the process group is reaped (END) or
    /// admits it is not (FAILED → poison). Key = command token.
    private var pendingInterrupts: [String: any Error & Sendable] = [:]
    private var poisoned = false
    private var closed = false

    public init(transport: any LinuxGuestConsoleTransport, limits: LinuxGuestLimits = .standard) {
        self.transport = transport
        self.limits = limits
    }

    /// Upgrade-mode channel: speaks to a legacy (pre-HELLO) runner strictly
    /// one exchange at a time. Used only by the registry's in-guest runner
    /// upgrade path, which runs a bounded serial command sequence before any
    /// concurrent work is allowed. Never negotiate; run() skips HELLO and
    /// rejects any concurrency.
    init(transport: any LinuxGuestConsoleTransport, limits: LinuxGuestLimits, legacySerialMode: Bool) {
        self.transport = transport
        self.limits = limits
        self.legacySerialMode = legacySerialMode
    }

    private var legacySerialMode = false

    /// True while at least one command or interactive session is in flight.
    public var isBusy: Bool { !runningCommands.isEmpty || !sessions.isEmpty }

    /// True when the guest abandoned a process alive or violated the framing
    /// protocol; the owner should reset the guest instead of reusing it.
    public var isPoisoned: Bool { poisoned }

    /// Bounded stop-recovery window after a targeted interrupt: the guest
    /// must answer END (process group reaped) or FAILED (unreaped) inside
    /// this window. Silence is a quarantine — the channel poisons and the
    /// owner resets the guest — never a "stopped" claim. The window covers
    /// the guest's own signal escalation (requested signal -> TERM -> KILL
    /// -> reap) plus console latency, with margin over the configured
    /// `interruptGrace`.
    private var interruptRecoveryWindow: TimeInterval {
        max(1, limits.interruptGrace + 8)
    }

    // MARK: capability negotiation

    /// In-flight HELLO negotiation shared by concurrent callers, so N
    /// simultaneous run() calls produce one probe, not N.
    private var negotiationTask: Task<String?, Error>?

    /// Sends FLOE-HELLO and requires protocol >= 3. Idempotent; concurrent
    /// callers await the same probe.
    private func ensureNegotiated() async throws {
        if negotiated || legacySerialMode { return }
        if let negotiationTask {
            _ = try await negotiationTask.value
            return
        }
        let task = Task { [weak self] () throws -> String? in
            guard let self else { return nil }
            return try await self.probeCapabilities(timeout: 10, requireCurrentProtocol: true)
        }
        negotiationTask = task
        defer { negotiationTask = nil }
        _ = try await task.value
        negotiated = true
    }

    /// Raw capability probe: sends FLOE-HELLO and returns the CAPS payload
    /// the runner answered (nil when the runner predates HELLO — a legacy
    /// runner never answers, so the probe times out). When
    /// `requireCurrentProtocol` is set, a missing/old protocol throws
    /// runnerUpgradeRequired instead of returning.
    public func probeCapabilities(
        timeout: TimeInterval = 10,
        requireCurrentProtocol: Bool = false
    ) async throws -> String? {
        guard !closed else {
            throw LinuxGuestError.consoleUnavailable("the guest channel is closed")
        }
        let token = "hello-" + UUID().uuidString
        let tokenStream = LinuxGuestTokenStream()
        registerToken(token, stream: tokenStream)
        defer { unregisterToken(token) }
        try await ensureRouter()
        try await send([LinuxGuestFraming.controlLine("HELLO", token: token)])

        var parser = LinuxGuestFraming.ControlParser(token: token)
        // Monotonic deadline: a wall-clock jump must never extend or cut the
        // bounded probe.
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining <= .zero { break }
            // A silent legacy runner (no HELLO support) must not hang the
            // probe: the read races the remaining time and the sleep side
            // wakes the token stream's waiter, so the await is bounded even
            // when the guest never answers.
            guard let chunk = await boundedNext(tokenStream, timeout: remaining) else {
                if await tokenStream.isFinished() {
                    throw LinuxGuestError.consoleUnavailable(
                        "guest console closed before the runner answered capability negotiation"
                    )
                }
                break
            }
            switch parser.feed(chunk) {
            case .needMore:
                continue
            case .finished(let exit):
                guard exit == 0 else {
                    if requireCurrentProtocol {
                        throw LinuxGuestError.runnerUpgradeRequired(
                            required: "protocol \(LinuxGuestFraming.requiredProtocol)",
                            found: parser.capabilities
                        )
                    }
                    return nil
                }
                guard let capabilities = parser.capabilities else {
                    if requireCurrentProtocol {
                        throw LinuxGuestError.runnerUpgradeRequired(
                            required: "protocol \(LinuxGuestFraming.requiredProtocol)",
                            found: nil
                        )
                    }
                    return nil
                }
                if requireCurrentProtocol,
                   (parser.protocolVersion ?? 0) < LinuxGuestFraming.requiredProtocol {
                    throw LinuxGuestError.runnerUpgradeRequired(
                        required: "protocol \(LinuxGuestFraming.requiredProtocol)",
                        found: capabilities
                    )
                }
                return capabilities
            }
        }
        if requireCurrentProtocol {
            throw LinuxGuestError.runnerUpgradeRequired(
                required: "protocol \(LinuxGuestFraming.requiredProtocol)",
                found: parser.capabilities
            )
        }
        return nil
    }

    /// Waits for one console chunk but never longer than `timeout`; the
    /// losing sleep wakes the token stream (a token-local finish that the
    /// caller's unregister makes invisible to the router) so the child task
    /// can never keep the task group alive past the deadline.
    private func boundedNext(_ stream: LinuxGuestTokenStream, timeout: Duration) async -> Data? {
        guard timeout > .zero else { return nil }
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask { await stream.next() }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled because the read won: leave the token stream
                    // open for the next chunk.
                    return nil
                }
                // Only the real deadline wakes the waiter; the stream stays
                // open so the caller can tell "silent runner" from "console
                // closed" (the token is unregistered right after).
                await stream.wake()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Marks capability negotiation as already satisfied by an out-of-band
    /// upgrade (the registry ran and verified the runner upgrade on a legacy
    /// serial channel). A subsequent run() skips HELLO but still requires
    /// the recorded protocol to be current.
    func acceptExternalNegotiation(capabilities: String) throws {
        var parser = LinuxGuestFraming.ControlParser(token: "external")
        parser.setCapabilitiesForValidation(capabilities)
        guard (parser.protocolVersion ?? 0) >= LinuxGuestFraming.requiredProtocol else {
            throw LinuxGuestError.runnerUpgradeRequired(
                required: "protocol \(LinuxGuestFraming.requiredProtocol)",
                found: capabilities
            )
        }
        negotiated = true
    }

    // MARK: token routing

    private func registerToken(_ token: String, stream: LinuxGuestTokenStream) {
        tokenStreams[token] = stream
    }

    private func unregisterToken(_ token: String) {
        tokenStreams.removeValue(forKey: token)
    }

    // MARK: serialized console writes

    /// One console writer at a time. The guest's line parser requires every
    /// frame (and every chunked payload group) to reach the console
    /// contiguously; without this gate two concurrent commands could
    /// interleave their frames, and a transport that accepts a prefix would
    /// leave a frame's tail behind another writer's bytes.
    private var sendBusy = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireSend() async {
        if !sendBusy {
            sendBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            sendWaiters.append(continuation)
        }
    }

    private func releaseSend() {
        if sendWaiters.isEmpty {
            sendBusy = false
        } else {
            let next = sendWaiters.removeFirst()
            next.resume()
        }
    }

    /// Releases queued writers (channel close): they either observe the
    /// closed transport or fail their exchange, but never wait forever.
    private func failSendWaiters() {
        sendBusy = false
        let waiters = sendWaiters
        sendWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Writes frames as one contiguous group on the console.
    func send(_ frames: [Data]) async throws {
        guard !frames.isEmpty else { return }
        await acquireSend()
        defer { releaseSend() }
        for frame in frames {
            try await transport.write(Array(frame))
        }
    }

    /// Starting guard: `transport.output()` suspends, so without it two
    /// concurrent callers would each start a router and both iterate the
    /// same AsyncStream, splitting frames between two consumers.
    private var routerStarting = false

    /// Starts the single long-lived console router. Exactly one reader ever
    /// iterates the transport stream; concurrent callers wait for it.
    private func ensureRouter() async throws {
        if consoleReader != nil { return }
        while routerStarting {
            if closed {
                throw LinuxGuestError.consoleUnavailable("the guest channel is closed")
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        if consoleReader != nil { return }
        routerStarting = true
        defer { routerStarting = false }
        let output = await transport.output()
        self.stream = output
        consoleReader = Task { [weak self] in
            guard let self else { return }
            for await chunk in output {
                await self.route(chunk)
            }
            await self.routerDidFinish()
        }
    }

    /// Router-side console chunk handler: splits the byte stream into frames
    /// and delivers each frame to its token's stream. BEGIN/OUT/ERR/END/
    /// FAILED/PID/CAPS payloads are routed by the token inside the frame;
    /// everything else (section payload — including 0x1e bytes and leading
    /// newlines that are legitimate command output) belongs to the current
    /// section owner verbatim. Awaiting each push keeps frame order strict.
    private func route(_ chunk: Data) async {
        routerPending.append(chunk)
        // Frames are `\x1eFLOE-<name> <token>...\x1e`; bytes that are not a
        // validated frame header are section payload for the current owner.
        while true {
            guard let mark = routerPending.firstIndex(of: LinuxGuestFraming.markerByte) else {
                // No marker: everything goes to the section owner.
                let bytes = routerPending
                routerPending.removeAll(keepingCapacity: true)
                await routeSectionBytes(bytes)
                return
            }
            if mark > routerPending.startIndex {
                let prefix = Data(routerPending[routerPending.startIndex..<mark])
                routerPending.removeSubrange(routerPending.startIndex..<mark)
                await routeSectionBytes(prefix)
            }
            switch await extractMarkerFrame() {
            case .incomplete:
                return
            case .notAFrame:
                // The 0x1e at the head is section payload (binary output);
                // route exactly that byte and rescan from the next one.
                let byte = Data([routerPending.removeFirst()])
                await routeSectionBytes(byte)
            case .frame(let name, let token, let arguments):
                await routeMarkerFrame(name, token, arguments)
            }
        }
    }

    /// Token whose output section currently owns unmarked bytes. Kept
    /// router-side so a chunk without any marker still reaches the command
    /// that is printing.
    private var sectionOwner: String?

    private func routeSectionBytes(_ bytes: Data) async {
        guard !bytes.isEmpty, let owner = sectionOwner,
              let stream = tokenStreams[owner] else { return }
        await stream.push(bytes)
    }

    private enum MarkerExtraction {
        /// Not enough bytes to decide; keep routerPending for the next chunk.
        case incomplete
        /// The leading 0x1e does not start a valid frame; it is payload.
        case notAFrame
        case frame(name: String, token: String, arguments: String)
    }

    /// Parses one frame header at the start of routerPending
    /// (`\x1eFLOE-<name> <token>[ args]\x1e`). Only a validated, complete
    /// header is consumed; anything else leaves routerPending untouched so
    /// payload bytes (including 0x1e and leading newlines) are never eaten.
    /// The runner's emit_* functions write no newline after frames, and a
    /// newline that does follow a frame is the command's own output — the
    /// router never strips it.
    private func extractMarkerFrame() async -> MarkerExtraction {
        guard routerPending.first == LinuxGuestFraming.markerByte else { return .notAFrame }
        let afterMark = routerPending.index(after: routerPending.startIndex)
        guard afterMark < routerPending.endIndex else { return .incomplete }
        guard let closing = routerPending[afterMark...].firstIndex(of: LinuxGuestFraming.markerByte) else {
            // No closing yet. Decide only when the buffered text already
            // rules out a FLOE header; otherwise wait for more bytes.
            let text = String(decoding: routerPending[afterMark...], as: UTF8.self)
            let prefix = "FLOE-"
            if prefix.hasPrefix(text) || text.hasPrefix(prefix) {
                if routerPending.count > 4096 {
                    // A "header" this long is noise; treat the 0x1e as
                    // payload instead of buffering forever.
                    return .notAFrame
                }
                return .incomplete
            }
            return .notAFrame
        }
        let body = routerPending[afterMark..<closing]
        guard body.starts(with: Data("FLOE-".utf8)) else { return .notAFrame }
        let text = String(decoding: body.dropFirst(5), as: UTF8.self)
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return .notAFrame }
        let name = String(parts[0])
        let token = String(parts[1])
        // Only a real guest frame name with a plausible token is consumed as
        // a frame. Arbitrary `\x1eFLOE-<word> …` bytes in command output are
        // preserved as section payload (the wire-escape note in the header
        // documents the one unavoidable exception: a byte-exact known frame).
        guard LinuxGuestFraming.guestFrameNames.contains(name),
              LinuxGuestFraming.isValidGuestToken(token) else { return .notAFrame }
        // Consume exactly the frame (opening 0x1e through closing 0x1e).
        routerPending.removeSubrange(routerPending.startIndex...closing)
        return .frame(name: name, token: token, arguments: parts.count > 2 ? String(parts[2]) : "")
    }

    private func routeMarkerFrame(_ name: String, _ token: String, _ arguments: String) async {
        switch name {
        case "OUT", "ERR", "BEGIN":
            sectionOwner = token
            await forwardMarker(name, token: token)
        case "END", "FAILED", "PID", "CAPS":
            if name == "END" || name == "FAILED" { sectionOwner = nil }
            await forwardMarker(name, token: token, arguments: arguments)
        default:
            break
        }
    }

    private func forwardMarker(_ name: String, token: String, arguments: String = "") async {
        guard let stream = tokenStreams[token] else { return }
        var frame = LinuxGuestFraming.marker(name, token: token)
        if !arguments.isEmpty {
            frame.removeLast() // drop closing 0x1e
            frame.append(Data(" \(arguments)\u{1e}".utf8))
        }
        await stream.push(frame)
    }

    private func routerDidFinish() async {
        let streams = tokenStreams
        tokenStreams.removeAll()
        for (_, stream) in streams {
            await stream.finish()
        }
    }

    // MARK: commands

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
        guard !poisoned else {
            throw LinuxGuestError.consoleUnavailable("the guest channel was poisoned by an earlier failed command")
        }
        guard !closed else {
            throw LinuxGuestError.consoleUnavailable("the guest channel is closed")
        }
        if legacySerialMode {
            // One in-flight exchange at a time; the legacy runner cannot
            // route concurrent tokens.
            guard runningCommands.isEmpty, sessions.isEmpty else {
                throw LinuxGuestError.invalidConfiguration("the guest runner is busy (legacy serial channel)")
            }
        } else {
            guard runningCommands.count < limits.maxConcurrentCommands else {
                throw LinuxGuestError.invalidConfiguration("too many guest commands in flight (max \(limits.maxConcurrentCommands))")
            }
        }
        try await ensureNegotiated()

        let token = UUID().uuidString
        let tokenStream = LinuxGuestTokenStream()
        registerToken(token, stream: tokenStream)
        runningCommands.insert(token)
        defer {
            unregisterToken(token)
            runningCommands.remove(token)
            pendingInterrupts.removeValue(forKey: token)
        }

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

        // Interrupt bookkeeping: timeout/cancellation tasks record the
        // pending error and signal the guest; the token stays registered and
        // the caller keeps consuming until END (reaped) or FAILED (poison).
        // A bounded stop-recovery window after the signal covers a guest
        // that answers neither.
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(effectiveTimeout))
            guard !Task.isCancelled else { return }
            await self.requestInterrupt(
                token: token,
                error: LinuxGuestError.timedOut(seconds: effectiveTimeout)
            )
        }
        defer { timeoutTask.cancel() }

        let cancellationTask = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true {
                    await self.requestInterrupt(token: token, error: FloeError.cancelled)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { cancellationTask.cancel() }

        let recoveryTask = Task {
            // Watch the interrupt state; once one is pending, give the guest
            // a bounded window to reap+answer before declaring the command
            // unrecoverable (quarantine state: poison the channel so the
            // owner resets the guest, and fail this caller honestly). The
            // window covers the guest's own TERM grace + hard deadline with
            // margin for console latency.
            var signaled = false
            while !Task.isCancelled {
                // The Task inherits this actor's isolation, so the lookup is
                // a synchronous actor-local read.
                if self.pendingInterruptError(token: token) != nil {
                    signaled = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard signaled else { return }
            try? await Task.sleep(for: .seconds(self.interruptRecoveryWindow))
            guard !Task.isCancelled else { return }
            await self.failUnresponsiveToken(token)
        }
        defer { recoveryTask.cancel() }

        // Startup watchdog: the token must produce its first frame (BEGIN,
        // FAILED or a fork-failure END) promptly; silence here means the
        // guest never started the command at all, which the interrupt path
        // cannot confirm either.
        let startupWatchdog = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self.failSilentStartup(token)
        }

        try await send(LinuxGuestFraming.payloadFrames(name: "EXEC", token: token, payload: payload))

        var parser = LinuxGuestFraming.Parser(token: token, maxOutputBytes: effectiveLimit)
        while true {
            guard let chunk = await tokenStream.next() else {
                startupWatchdog.cancel()
                // Router finished or the recovery path failed the token.
                if let failure = await tokenStream.takeFailure() {
                    throw failure
                }
                if let interruptError = pendingInterrupts[token] {
                    // Console died after we asked for an interrupt: the
                    // process state is unknown — quarantine, not "stopped".
                    poisoned = true
                    throw LinuxGuestError.consoleUnavailable(
                        "guest console closed while an interrupt was pending (\(interruptError.localizedDescription)); the guest state is unknown"
                    )
                }
                throw LinuxGuestError.consoleUnavailable("guest console closed before the command reported completion")
            }
            startupWatchdog.cancel()
            switch parser.feed(chunk) {
            case .needMore:
                continue
            case .finished(let exitCode):
                if let interruptError = pendingInterrupts[token] {
                    // The guest really reaped the process group; only now is
                    // the timeout/cancellation allowed to surface.
                    throw interruptError
                }
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
    /// channel is free for the next exchange as soon as the pid arrives;
    /// control exchanges never wait for commands/sessions.
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

    /// One control exchange (`SPAWN`/`KILL`/`ALIVE`) on its own token. The
    /// control channel is prioritized: it never queues behind command output
    /// because it consumes only its own token's stream.
    private func performControl(
        name: String,
        arguments: [String] = [],
        payload: Data? = nil,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> ControlOutcome {
        guard !poisoned else {
            throw LinuxGuestError.consoleUnavailable("the guest channel was poisoned by an earlier failed command")
        }
        guard !closed else {
            throw LinuxGuestError.consoleUnavailable("the guest channel is closed")
        }
        try await ensureNegotiated()
        let token = "ctl-" + UUID().uuidString
        let tokenStream = LinuxGuestTokenStream()
        registerToken(token, stream: tokenStream)
        defer { unregisterToken(token) }

        let frames = payload.map {
            LinuxGuestFraming.payloadFrames(name: name, token: token, payload: $0, allowInline: false)
        } ?? [LinuxGuestFraming.controlLine(name, token: token, arguments: arguments)]

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self.failToken(token, error: LinuxGuestError.timedOut(seconds: timeout), interrupt: false)
        }
        defer { timeoutTask.cancel() }

        let cancellationTask = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true {
                    await self.failToken(token, error: FloeError.cancelled, interrupt: false)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { cancellationTask.cancel() }

        try await send(frames)

        var parser = LinuxGuestFraming.ControlParser(token: token)
        while true {
            guard let chunk = await tokenStream.next() else {
                if let failure = await tokenStream.takeFailure() {
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

    // MARK: interactive sessions

    /// Opens an interactive PTY session in the guest. Multiple sessions run
    /// concurrently (bounded by limits.maxConcurrentSessions); the returned
    /// handle streams raw terminal bytes for its own token only.
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
        guard !poisoned else {
            throw LinuxGuestError.consoleUnavailable("the guest channel was poisoned by an earlier failed command")
        }
        guard !closed else {
            throw LinuxGuestError.consoleUnavailable("the guest channel is closed")
        }
        guard sessions[sessionID] == nil else {
            throw LinuxGuestError.invalidConfiguration("session \(sessionID) already exists")
        }
        guard sessions.count < limits.maxConcurrentSessions else {
            throw LinuxGuestError.invalidConfiguration("too many guest sessions in flight (max \(limits.maxConcurrentSessions))")
        }
        try await ensureNegotiated()

        let session = LinuxGuestInteractiveSession(id: sessionID) { [weak self] frame in
            guard let self else {
                throw LinuxGuestError.consoleUnavailable("the guest channel was released")
            }
            try await self.send([frame])
        }
        let tokenStream = LinuxGuestTokenStream()
        registerToken(sessionID, stream: tokenStream)
        sessions[sessionID] = session

        let payload = LinuxGuestFraming.sessionPayload(
            argv: argv,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows
        )
        do {
            try await send(LinuxGuestFraming.payloadHeader("OPEN", token: sessionID, payload: payload))
        } catch {
            unregisterToken(sessionID)
            sessions.removeValue(forKey: sessionID)
            throw error
        }
        Task { await self.pumpSession(session, stream: tokenStream) }
        return session
    }

    /// Reads the session's token stream until the session ends. Detached so
    /// `openSession` returns the live handle immediately.
    private func pumpSession(_ session: LinuxGuestInteractiveSession, stream: LinuxGuestTokenStream) async {
        var parser = LinuxGuestFraming.SessionParser(sessionID: session.id)
        while true {
            guard let chunk = await stream.next() else {
                // Guest stopped or token failed: finish the session instead
                // of hanging.
                await session.finish(exit: -1)
                endSession(session.id)
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
                endSession(session.id)
                return
            case .finished(let exit):
                await session.finish(exit: exit)
                endSession(session.id)
                return
            case .failed(let reason):
                await session.fail(reason)
                poisoned = true
                endSession(session.id)
                return
            }
        }
    }

    private func endSession(_ sessionID: String) {
        unregisterToken(sessionID)
        sessions.removeValue(forKey: sessionID)
    }

    // MARK: runner-upgrade mode switch (single console reader)

    /// Switches this channel into legacy (pre-protocol-3) serial mode for the
    /// in-guest runner upgrade. The console reader is deliberately NOT
    /// stopped: cancelling a for-await reader finishes the transport's
    /// AsyncStream permanently, so a replacement channel would read nothing.
    /// Instead the one router stays alive and only the exchange policy
    /// changes: no HELLO negotiation, one exchange at a time.
    ///
    /// Only legal while idle: the upgrade must not race concurrent work.
    func enterLegacySerialMode() throws {
        guard !closed else {
            throw LinuxGuestError.consoleUnavailable("the guest channel is closed")
        }
        guard runningCommands.isEmpty, sessions.isEmpty else {
            throw LinuxGuestError.invalidConfiguration(
                "the guest channel must be idle before the legacy runner upgrade"
            )
        }
        legacySerialMode = true
        negotiated = false
    }

    /// Returns to protocol-3 mode after the guest rebooted into the new
    /// runner. The next run()/probe sends HELLO again on the same reader.
    func leaveLegacySerialMode() {
        legacySerialMode = false
        negotiated = false
    }

    /// Drops router protocol state at a reboot boundary: buffered partial
    /// frames, the current section owner and every token stream from the old
    /// boot are stale and must not leak into the new runner's tokens. The
    /// console reader and transport are untouched.
    func resetRouterState() async {
        routerPending.removeAll(keepingCapacity: false)
        sectionOwner = nil
        let streams = tokenStreams
        tokenStreams.removeAll()
        for (_, tokenStream) in streams {
            await tokenStream.finish()
        }
        runningCommands.removeAll()
        pendingInterrupts.removeAll()
    }

    /// Last-resort legacy interrupt: sends the raw 0x03 byte, which the guest
    /// treats as interrupt-all. Prefer targeted cancellation via the
    /// CancellationToken passed to run(...).
    public func interrupt() async {
        try? await send([Data([0x03])])
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        failSendWaiters()
        consoleReader?.cancel()
        consoleReader = nil
        stream = nil
        let openSessions = sessions
        sessions.removeAll()
        for (_, session) in openSessions {
            await session.close()
        }
        let streams = tokenStreams
        tokenStreams.removeAll()
        for (_, tokenStream) in streams {
            await tokenStream.finish()
        }
        await transport.close()
    }

    /// Fails one control token from a timeout/cancellation task. Control
    /// exchanges (KILL/ALIVE/SPAWN) own no long-lived process group, so the
    /// token is failed immediately; command tokens instead go through
    /// requestInterrupt so the guest's reap proof is observed first.
    private func failToken(_ token: String, error: any Error & Sendable, interrupt: Bool) async {
        guard let stream = tokenStreams[token] else { return }
        if interrupt {
            try? await send([LinuxGuestFraming.sessionSignalLine(
                sessionID: token, signal: "INT", rows: nil, columns: nil
            )])
        }
        await stream.fail(error)
    }

    /// Records an interrupt for a command token and signals the guest. The
    /// caller keeps consuming until END (reaped → the recorded error
    /// surfaces) or FAILED (quarantine → poison). Idempotent.
    private func requestInterrupt(token: String, error: any Error & Sendable) async {
        guard runningCommands.contains(token), pendingInterrupts[token] == nil else { return }
        pendingInterrupts[token] = error
        try? await send([LinuxGuestFraming.sessionSignalLine(
            sessionID: token, signal: "INT", rows: nil, columns: nil
        )])
    }

    private func pendingInterruptError(token: String) -> (any Error & Sendable)? {
        pendingInterrupts[token]
    }

    /// Recovery path: the guest neither reaped (END) nor quarantined
    /// (FAILED) the interrupted command within the bounded window. The
    /// process state is unknown, so the channel is poisoned (the owner
    /// resets the guest) and the caller fails with a quarantine error —
    /// never a "stopped" claim.
    private func failUnresponsiveToken(_ token: String) async {
        guard pendingInterrupts[token] != nil, let stream = tokenStreams[token] else { return }
        poisoned = true
        await stream.fail(LinuxGuestError.consoleUnavailable(
            "guest did not confirm the interrupted command stopped within the stop-recovery window; the process state is unknown and the guest must be reset"
        ))
    }

    /// Startup watchdog path: the guest never emitted a single frame for a
    /// command that was fully written. The process state is unknown (the
    /// EXEC may or may not have started), so this poisons the channel.
    private func failSilentStartup(_ token: String) async {
        guard runningCommands.contains(token), let stream = tokenStreams[token] else { return }
        poisoned = true
        await stream.fail(LinuxGuestError.consoleUnavailable(
            "guest produced no response to an accepted command within 30s; the process state is unknown and the guest must be reset"
        ))
    }
}
