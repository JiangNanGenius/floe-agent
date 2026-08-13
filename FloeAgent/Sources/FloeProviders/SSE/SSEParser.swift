// FloeProviders — Incremental SSE parser.
// See blazing-aurora-darwin.md §5.3: handles CRLF/LF/lone-CR line endings,
// multi-line data concatenation, event/id/retry fields, comment lines,
// UTF-8 BOM, multi-byte UTF-8 split across feeds, and stream interruption.

import Foundation
import FloeCore

/// Errors raised by `SSEParser.finish()` when the stream ends malformed.
public enum SSEParserError: Error, Sendable, Hashable {
    /// Stream ended with an incomplete UTF-8 sequence.
    case truncatedUTF8
}

/// Incremental, byte-oriented Server-Sent Events parser.
///
/// Feed arbitrary byte chunks via `feed(_:)`; completed events are returned.
/// Call `finish()` at end-of-stream to flush any final event and to surface
/// truncation errors.
public struct SSEParser: Sendable {

    // MARK: Internal state machine

    private enum State: Sendable, Hashable {
        /// Waiting for the first bytes; a UTF-8 BOM is stripped here.
        case streamStart
        /// Possibly consuming a UTF-8 BOM; value = BOM bytes seen so far.
        case bomPending(Int)
        /// Mid-line.
        case inLine
        /// Last byte was CR; a following LF must be consumed silently.
        case afterCR
    }

    private var state: State = .streamStart

    /// Bytes of the current line not yet dispatched (may hold a partial
    /// multi-byte UTF-8 sequence at the tail).
    private var lineBuffer: [UInt8] = []

    // Per-event field accumulation. All mutations happen via methods taking
    // `inout SSEParser` — never through closure captures of computed
    // properties, which would break value semantics.
    private var pendingData: [String] = []
    private var pendingEvent: String = ""
    private var pendingID: String?
    private var pendingRetry: Int?
    /// True once any data line arrived for the event under construction.
    private var pendingHasData = false

    public init() {}

    // MARK: Public API

    /// Feeds raw bytes. Returns all events completed during this feed.
    public mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            processByte(byte, into: &events)
        }
        return events
    }

    /// Convenience overload for any byte collection (Array, Data, slices…).
    /// `@inline(never)`: Swift 6.4 miscompiles this generic specialization
    /// when called concurrently with distinct collection types under
    /// `-enable-testing` (observed as ContiguousArrayBuffer index traps).
    @inline(never)
    public mutating func feed<C: Collection<UInt8>>(_ data: C) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in data {
            processByte(byte, into: &events)
        }
        return events
    }

    /// Signals end-of-stream. Flushes any trailing line and pending event.
    /// - Throws: `SSEParserError.truncatedUTF8` when the final line buffer
    ///   ends mid-codepoint.
    public mutating func finish() throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        switch state {
        case .streamStart:
            break
        case .bomPending:
            // BOM prefix bytes never completed: treat them as content.
            state = .inLine
            if !lineBuffer.isEmpty {
                dispatchLine(into: &events)
            }
        case .inLine:
            if !lineBuffer.isEmpty {
                guard decodeLineBuffer() != nil else {
                    throw SSEParserError.truncatedUTF8
                }
                dispatchLine(into: &events)
            }
        case .afterCR:
            // A trailing lone CR terminated the final line.
            dispatchLine(into: &events)
        }
        // Flush an event terminated by EOF instead of a blank line.
        if let event = flushEvent() {
            events.append(event)
        }
        state = .streamStart
        return events
    }

    // MARK: Byte processing

    private mutating func processByte(_ byte: UInt8, into events: inout [SSEEvent]) {
        switch state {
        case .streamStart:
            if byte == 0xEF {
                lineBuffer.append(byte)
                state = .bomPending(1)
            } else {
                state = .inLine
                processContentByte(byte, into: &events)
            }

        case .bomPending(let seen):
            let expected: [UInt8] = [0xEF, 0xBB, 0xBF]
            if byte == expected[seen] {
                lineBuffer.append(byte)
                if seen + 1 == expected.count {
                    // Complete BOM consumed; drop it.
                    lineBuffer.removeAll(keepingCapacity: true)
                    state = .inLine
                } else {
                    state = .bomPending(seen + 1)
                }
            } else {
                // Not a BOM: replay buffered prefix bytes as content, then
                // process the current byte.
                let buffered = lineBuffer
                lineBuffer.removeAll(keepingCapacity: true)
                state = .inLine
                for b in buffered { processContentByte(b, into: &events) }
                processContentByte(byte, into: &events)
            }

        case .inLine, .afterCR:
            processContentByte(byte, into: &events)
        }
    }

    private mutating func processContentByte(_ byte: UInt8, into events: inout [SSEEvent]) {
        switch state {
        case .inLine:
            switch byte {
            case 0x0A: // LF terminates the line.
                dispatchLine(into: &events)
            case 0x0D: // CR terminates the line; swallow a following LF.
                dispatchLine(into: &events)
                state = .afterCR
            default:
                lineBuffer.append(byte)
            }
        case .afterCR:
            switch byte {
            case 0x0A: // Second half of CRLF.
                state = .inLine
            case 0x0D: // CRCR: another empty line terminated by CR.
                dispatchLine(into: &events)
                state = .afterCR
            default:
                state = .inLine
                lineBuffer.append(byte)
            }
        default:
            // Only reachable when misused from `.streamStart`/`.bomPending`.
            lineBuffer.append(byte)
        }
    }

    // MARK: Line dispatch

    /// Decodes the buffered line and processes it as an SSE line.
    /// Mid-stream invalid UTF-8 is replaced with U+FFFD (not fatal); only
    /// a truncated final codepoint at `finish()` raises.
    private mutating func dispatchLine(into events: inout [SSEEvent]) {
        defer { lineBuffer.removeAll(keepingCapacity: true) }
        if state != .afterCR { state = .inLine }
        guard !lineBuffer.isEmpty else {
            // Blank line: dispatch pending event.
            if let event = flushEvent() {
                events.append(event)
            }
            return
        }
        let line = decodeLineBuffer() ?? String(decoding: lineBuffer, as: UTF8.self)
        processLine(line)
    }

    /// Strict UTF-8 decode of the line buffer; nil when invalid.
    private func decodeLineBuffer() -> String? {
        if lineBuffer.allSatisfy({ $0 < 0x80 }) {
            return String(decoding: lineBuffer, as: UTF8.self)
        }
        var iterator = lineBuffer.makeIterator()
        var codec = UTF8()
        while true {
            switch codec.decode(&iterator) {
            case .scalarValue:
                continue
            case .emptyInput:
                return String(decoding: lineBuffer, as: UTF8.self)
            case .error:
                return nil
            }
        }
    }

    private mutating func processLine(_ line: String) {
        if line.hasPrefix(":") {
            // Comment / heartbeat line — ignored by design.
            return
        }

        let field: Substring
        let value: Substring
        if let colonIndex = line.firstIndex(of: ":") {
            field = line[..<colonIndex]
            var rest = line[line.index(after: colonIndex)...]
            // One leading space after the colon is stripped per spec.
            if rest.hasPrefix(" ") {
                rest = rest.dropFirst()
            }
            value = rest
        } else {
            // Field name only, empty value.
            field = Substring(line)
            value = ""
        }

        switch field {
        case "data":
            pendingData.append(String(value))
            pendingHasData = true
        case "event":
            pendingEvent = String(value)
        case "id":
            // IDs containing NUL are ignored per spec.
            if !value.contains("\0") {
                pendingID = String(value)
            }
        case "retry":
            if let retry = Int(value), retry >= 0 {
                pendingRetry = retry
            }
        default:
            // Unknown field names are ignored (forward compatibility).
            return
        }
    }

    /// Emits the pending event if it carries data, then resets field state.
    private mutating func flushEvent() -> SSEEvent? {
        defer {
            pendingData.removeAll(keepingCapacity: true)
            pendingEvent = ""
            pendingRetry = nil
            pendingHasData = false
            // The event id buffer persists across events per the SSE spec,
            // but provider streams always resend the ids we consume; reset
            // to avoid leaking across logical events.
            pendingID = nil
        }
        guard pendingHasData else { return nil }
        return SSEEvent(
            event: pendingEvent,
            data: pendingData.joined(separator: "\n"),
            id: pendingID,
            retry: pendingRetry
        )
    }
}
