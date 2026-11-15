// FloeProviders — Incremental SSE parser.
// See blazing-aurora-darwin.md §5.3: handles CRLF/LF/lone-CR line endings,
// multi-line data concatenation, event/id/retry fields, comment lines,
// UTF-8 BOM, multi-byte UTF-8 split across feeds, and stream interruption.

import Foundation

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

    /// Provider streams should contain small JSON events. These ceilings
    /// prevent a hostile endpoint from growing one line/event without bound.
    // Allow a full 1 MiB data payload plus its SSE field prefix while still
    // bounding pathological single lines.
    private static let maximumLineBytes = 1 * 1_024 * 1_024 + 64
    private static let maximumEventBytes = 4 * 1_024 * 1_024

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
    private var lineOverflowed = false

    // Per-event field accumulation. All mutations happen via methods taking
    // `inout SSEParser` — never through closure captures of computed
    // properties, which would break value semantics.
    private var pendingData = ""
    private var pendingEvent: String = ""
    private var pendingID: String?
    private var pendingRetry: Int?
    /// True once any data line arrived for the event under construction.
    private var pendingHasData = false
    private var pendingDataBytes = 0
    private var pendingEventOverflowed = false

    public init() {}

    // MARK: Public API

    /// Feeds raw bytes. Returns all events completed during this feed.
    public mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if let event = feed(byte) { events.append(event) }
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
            if let event = feed(byte) { events.append(event) }
        }
        return events
    }

    /// Signals end-of-stream. Flushes any trailing line and pending event.
    /// - Throws: `SSEParserError.truncatedUTF8` when the final line buffer
    ///   ends mid-codepoint.
    public mutating func finish() throws -> [SSEEvent] {
        if state == .inLine, !lineBuffer.isEmpty,
           String(validating: lineBuffer, as: UTF8.self) == nil {
            throw SSEParserError.truncatedUTF8
        }
        // An incomplete BOM stays in the line as content. A trailing CR has
        // already dispatched its line, so only the pending event needs flushing.
        if !lineBuffer.isEmpty { _ = dispatchLine() }
        state = .streamStart
        // Flush an event terminated by EOF instead of a blank line.
        if let event = flushEvent() { return [event] }
        return []
    }

    // MARK: Byte processing

    /// URLSession.AsyncBytes feeds one byte at a time. A terminator can
    /// complete at most one event, which the caller can deliver immediately.
    mutating func feed(_ byte: UInt8) -> SSEEvent? {
        switch state {
        case .streamStart:
            if byte == 0xEF {
                lineBuffer.append(byte)
                state = .bomPending(1)
                return nil
            }
            state = .inLine

        case .bomPending(let seen):
            if seen == 1 && byte == 0xBB {
                lineBuffer.append(byte)
                state = .bomPending(2)
                return nil
            }
            state = .inLine
            if seen == 2 && byte == 0xBF {
                lineBuffer.removeAll(keepingCapacity: true)
                return nil
            }
            // The partial prefix already in lineBuffer belongs to this line.
        case .afterCR:
            state = .inLine
            if byte == 0x0A { return nil }
        case .inLine:
            break
        }

        switch byte {
        case 0x0A:
            return dispatchLine()
        case 0x0D:
            state = .afterCR
            return dispatchLine()
        default:
            if lineBuffer.count < Self.maximumLineBytes {
                lineBuffer.append(byte)
            } else {
                lineOverflowed = true
            }
            return nil
        }
    }

    // MARK: Line dispatch

    /// Decodes the buffered line and processes it as an SSE line.
    /// Mid-stream invalid UTF-8 is replaced with U+FFFD (not fatal); only
    /// a truncated final codepoint at `finish()` raises.
    private mutating func dispatchLine() -> SSEEvent? {
        defer {
            lineBuffer.removeAll(keepingCapacity: true)
            lineOverflowed = false
        }
        if lineOverflowed {
            pendingEventOverflowed = true
            return nil
        }
        guard !lineBuffer.isEmpty else {
            // Blank line: dispatch pending event.
            return flushEvent()
        }
        guard !pendingEventOverflowed, lineBuffer.first != 0x3A else { return nil }
        // SSE field delimiters are ASCII bytes, even when the value starts
        // with a combining scalar. Decode only the value of a recognized field.
        let fieldEnd = lineBuffer.firstIndex(of: 0x3A) ?? lineBuffer.endIndex
        var valueStart = fieldEnd
        if valueStart < lineBuffer.endIndex {
            valueStart += 1
            if valueStart < lineBuffer.endIndex && lineBuffer[valueStart] == 0x20 {
                valueStart += 1
            }
        }
        let bytes = lineBuffer[valueStart...]
        switch String(decoding: lineBuffer[..<fieldEnd], as: UTF8.self) {
        case "data":
            let value = String(decoding: bytes, as: UTF8.self)
            let addedBytes = value.utf8.count + (pendingHasData ? 1 : 0)
            guard addedBytes <= Self.maximumEventBytes - pendingDataBytes else {
                pendingEventOverflowed = true
                return nil
            }
            if pendingHasData {
                pendingData.append("\n")
                pendingData.append(value)
            } else {
                pendingData = value
                pendingHasData = true
            }
            pendingDataBytes += addedBytes
        case "event":
            pendingEvent = String(decoding: bytes, as: UTF8.self)
        case "id":
            // IDs containing NUL are ignored per spec.
            if !bytes.contains(0) {
                pendingID = String(decoding: bytes, as: UTF8.self)
            }
        case "retry":
            if let retry = Int(String(decoding: bytes, as: UTF8.self)), retry >= 0 {
                pendingRetry = retry
            }
        default:
            // Unknown field names are ignored (forward compatibility).
            break
        }
        return nil
    }

    /// Emits the pending event if it carries data, then resets field state.
    private mutating func flushEvent() -> SSEEvent? {
        defer {
            pendingData = ""
            pendingEvent = ""
            pendingRetry = nil
            pendingHasData = false
            pendingDataBytes = 0
            pendingEventOverflowed = false
            // The event id buffer persists across events per the SSE spec,
            // but provider streams always resend the ids we consume; reset
            // to avoid leaking across logical events.
            pendingID = nil
        }
        if pendingEventOverflowed {
            return SSEEvent(
                event: "__floe_sse_error__",
                data: "Provider SSE event exceeded the 4 MiB limit"
            )
        }
        guard pendingHasData else { return nil }
        return SSEEvent(
            event: pendingEvent,
            data: pendingData,
            id: pendingID,
            retry: pendingRetry
        )
    }
}
