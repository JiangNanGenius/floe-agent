// SPDX-License-Identifier: MPL-2.0
//
// G04LanguageServerFraming — the REAL Content-Length UTF-8 base framing for
// stdio JSON-RPC (LSP) traffic over the ORIGINAL resolved Linux engine PTY
// session transport (job-dda32d23d55e4460, D3/D8 language support scope).
//
// This file is pure Foundation and fully testable without a device:
//  * the parser accepts FRAGMENTED frames (engine poll pages are <=16 KiB
//    merged PTY bytes and break anywhere), COALESCED frames (several frames
//    inside one page) and permissive-but-valid header forms
//    ("Content-Length: <n>\r\n\r\n", an optional additional header line, and
//    the bare-LF separator some servers emit), always counting BYTES, never
//    characters;
//  * any byte that cannot belong to a syntactically valid header start is
//    FRAMING CONTAMINATION (shell echo, prompt text, banner on stderr riding
//    the merged PTY, ANSI bytes): it is surfaced as a typed failure with the
//    offending prefix, never skipped, never "resynchronised by search",
//    because silently swallowing contamination is how a JSON body split
//    across the loss becomes an undebuggable truncation;
//  * the writer emits canonical single-line JSON with an exact UTF-8
//    Content-Length, and refuses bodies containing NUL or exceeding the
//    bound BEFORE any byte is queued.
//
// Framing bounds are independent of the 64 KiB control envelope: a complete
// frame body may be larger (a big didChange), but every frame stays under a
// hard bound and the session owns bounded pending-queue totals (see
// G04LanguageServer). A frame that cannot fit is a typed refusal, never a
// truncation, never a second "partial save" story.
import Foundation

// MARK: - Limits

public enum G04LspFramingLimits {
    /// Largest header block before the body separator (Content-Length plus
    /// at most one optional header line) — beyond this the stream is not
    /// valid framing at the current boundary.
    public static let maximumHeaderBytes = 8 * 1024
    /// Largest single JSON-RPC frame body. 4 MiB matches the shared native
    /// document bound (G04WorkspaceDocumentSession.maximumDocumentBytes) so
    /// a full-text didChange of the largest admitted document always fits
    /// exactly one frame, and nothing larger can be smuggled.
    public static let maximumBodyBytes = 4 * 1024 * 1024
    /// How many leading contamination bytes are retained in the typed error
    /// for diagnostics (bounded, printable-escaped, never the whole ring).
    public static let maximumReportedPrefixBytes = 256
}

// MARK: - Errors

public enum G04LspFramingError: Error, Sendable, Equatable {
    /// Bytes before the frame boundary that cannot be a header: e.g. shell
    /// echo, a prompt, or an ANSI sequence riding the merged PTY output.
    /// `prefix` is the bounded printable-escaped offending start. The parser
    /// state is poisoned from this point on: the session must be torn down.
    case framingContaminated(prefix: String)
    /// The header block exceeded the bound before a separator arrived.
    case headerTooLarge
    /// A header line lacked the mandatory `Content-Length` field.
    case missingContentLength
    /// `Content-Length` was present but not a canonical positive decimal.
    case invalidContentLength(String)
    /// The declared body exceeds the frame bound (refused BEFORE the body is
    /// accumulated — never a truncated parse presented as success).
    case bodyTooLarge(declared: Int)
    /// A frame body contained NUL or could not be read as UTF-8 JSON text.
    case bodyNotUTF8
}

// MARK: - Parser

/// Streaming frame reader. `feed` appends raw merged PTY bytes; `nextFrame`
/// returns exactly one complete body (Data of the JSON-RPC message) or nil
/// when more bytes are needed. After a `G04LspFramingError` the parser is
/// terminal: every further call returns the same failure (the caller must
/// close the session — frames never resynchronise by searching for the next
/// "Content-Length", that is the swallowing rule this lane forbids).
public final class G04LspFrameParser {
    private enum State {
        case awaitingHeader
        case awaitingBody(expected: Int)
        case poisoned(G04LspFramingError)
    }

    private var buffer: [UInt8] = []
    private var consumed = 0
    private var state: State = .awaitingHeader

    public init() {}

    /// Live-buffer byte count (header backlog not yet parsed).
    public var pendingByteCount: Int { buffer.count - consumed }

    public func feed(_ data: Data) {
        buffer.append(contentsOf: data)
        // Keep the backlog bounded to a window: never re-parse consumed head.
        if consumed > 1 << 20 {
            buffer.removeFirst(consumed)
            consumed = 0
        }
    }

    /// Drops everything retained (frame boundary only; never called
    /// mid-frame by production code — mid-frame drops are contamination).
    public func reset() {
        buffer.removeAll(keepingCapacity: false)
        consumed = 0
        state = .awaitingHeader
    }

    public func nextFrame() -> Result<Data?, G04LspFramingError> {
        if case .poisoned(let error) = state { return .failure(error) }
        switch state {
        case .awaitingHeader:
            return parseHeader()
        case .awaitingBody(let expected):
            return parseBody(expected)
        case .poisoned:
            return .failure(.headerTooLarge) // unreachable; poisoned handled above
        }
    }

    // MARK: internals

    private func remaining() -> ArraySlice<UInt8> { buffer[consumed..<buffer.count] }

    private func poison(_ error: G04LspFramingError) -> Result<Data?, G04LspFramingError> {
        state = .poisoned(error)
        return .failure(error)
    }

    private func parseHeader() -> Result<Data?, G04LspFramingError> {
        var contentLength: Int?
        var index = consumed
        var lineStart = consumed
        var sawSeparator = false
        while index < buffer.count {
            let byte = buffer[index]
            if byte == 0x0A { // LF: end of a header line (or separator)
                let line = Array(buffer[lineStart..<index])
                let trimmed = line.last == 0x0D ? Array(line.dropLast()) : line
                if trimmed.isEmpty {
                    sawSeparator = true
                    index += 1
                    break
                }
                let (name, value, valid) = Self.splitHeader(trimmed)
                guard valid else {
                    return poison(.framingContaminated(prefix: Self.escape(line)))
                }
                if String(decoding: name, as: UTF8.self).lowercased() == "content-length" {
                    guard let parsed = Self.canonicalPositiveDecimal(value), parsed > 0 else {
                        return poison(.invalidContentLength(String(decoding: value, as: UTF8.self)))
                    }
                    contentLength = parsed
                }
                lineStart = index + 1
                index += 1
                if index - consumed > G04LspFramingLimits.maximumHeaderBytes {
                    return poison(.headerTooLarge)
                }
                continue
            }
            // Control chars other than CR may not appear in a header line
            // body; an early NUL/ANSI ESC is contamination, not framing.
            if byte < 0x20 && byte != 0x0D {
                return poison(.framingContaminated(prefix: Self.escape(Array(buffer[lineStart...index]))))
            }
            index += 1
            if index - consumed > G04LspFramingLimits.maximumHeaderBytes {
                return poison(.headerTooLarge)
            }
        }
        guard sawSeparator else {
            return .success(nil) // need more bytes
        }
        guard let length = contentLength else {
            return poison(.missingContentLength)
        }
        guard length <= G04LspFramingLimits.maximumBodyBytes else {
            return poison(.bodyTooLarge(declared: length))
        }
        consumed = index
        state = .awaitingBody(expected: length)
        return parseBody(length)
    }

    private func parseBody(_ expected: Int) -> Result<Data?, G04LspFramingError> {
        guard remaining().count >= expected else { return .success(nil) }
        let body = Array(remaining().prefix(expected))
        consumed += expected
        state = .awaitingHeader
        if body.contains(0) { return poison(.bodyNotUTF8) }
        guard String(decoding: body, as: UTF8.self).utf8.count == body.count else {
            // UTF-8 replacement happened: the bytes were not valid UTF-8.
            return poison(.bodyNotUTF8)
        }
        return .success(Data(body))
    }

    private static func splitHeader(_ line: [UInt8]) -> (name: [UInt8], value: [UInt8], valid: Bool) {
        guard let colon = line.firstIndex(of: 0x3A) else { return ([], [], false) }
        let name = Array(line[..<colon])
        guard !name.isEmpty else { return ([], [], false) }
        var start = colon + 1
        while start < line.count, line[start] == 0x20 || line[start] == 0x09 { start += 1 }
        // Header names are RFC 7230 tokens: visible ASCII that is neither a
        // space/control NOR a separator character (a real "@"/"(" here is a
        // prompt fragment or echoed keystroke — contamination, not a header;
        // the previous permissive 0x21...0x7E range let "admin@guest:~$ " pass
        // as an "unknown field" instead of poisoning, contradicting this
        // enum's own documented contract. Host cohort evidence
        // test-145137.log G04LanguageServerTests/testContaminationRefusesAndPoisons.)
        let valid = name.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||   // A-Z a-z
            (byte >= 0x30 && byte <= 0x39) ||                                     // 0-9
            byte == 0x21 || (byte >= 0x23 && byte <= 0x27) ||                     // ! # $ % & '
            byte == 0x2A || byte == 0x2B || byte == 0x2D || byte == 0x2E ||       // * + - .
            byte == 0x5E || byte == 0x5F || byte == 0x60 ||                       // ^ _ `
            byte == 0x7C || byte == 0x7E                                           // | ~
        }
        return (name, Array(line[start..<line.count]), valid)
    }

    private static func canonicalPositiveDecimal(_ value: [UInt8]) -> Int? {
        guard !value.isEmpty else { return nil }
        // Canonical decimal: no leading zeros ("0" itself is not positive).
        guard value.first! >= 0x31, value.first! <= 0x39 else { return nil }
        // Digit ceiling 15: far below Int64 overflow (arm64/macOS and
        // Android both use 64-bit Int). Sizes ABOVE maximumBodyBytes stay
        // a parseable number here so the header guard classifies them as
        // the documented typed `bodyTooLarge(declared:)` refusal BEFORE any
        // body accumulates; the previous clamp-to-nil here made that public
        // case unreachable and mislabeled well-formed huge lengths as
        // invalidContentLength (host cohort evidence test-145137.log
        // G04LanguageServerTests/testBodyTooLargeRefusedBeforeAccumulation).
        guard value.count <= 15 else { return nil }
        var number = 0
        for byte in value {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            number = number * 10 + Int(byte - 0x30)
        }
        return number
    }

    /// Bounded printable escape for diagnostics: non-printables become
    /// `\xHH`, never raw control bytes into the UI.
    static func escape(_ bytes: [UInt8]) -> String {
        let capped = Array(bytes.prefix(G04LspFramingLimits.maximumReportedPrefixBytes))
        var result = ""
        for byte in capped {
            if byte >= 0x20, byte < 0x7F { result.append(Character(UnicodeScalar(byte))) }
            else { result.append(String(format: "\\x%02X", byte)) }
        }
        return result
    }
}

// MARK: - Writer

/// Frame writer: canonical `Content-Length` framing of compact JSON. All
/// validation happens BEFORE any byte is produced (a refused frame writes
/// nothing at all).
public enum G04LspFrameWriter {
    public enum WriteError: Error, Sendable, Equatable {
        case bodyTooLarge(Int)
        case bodyContainsNUL
        case notAJSONObject
    }

    /// Serializes one JSON-RPC object into a complete frame. `object` must
    /// serialize to a standard JSON OBJECT (dictionary), compact, UTF-8.
    public static func frame(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw WriteError.notAJSONObject }
        let body = try JSONSerialization.data(withJSONObject: object, options: [])
        return try frame(body: body)
    }

    public static func frame(body: Data) throws -> Data {
        guard body.count <= G04LspFramingLimits.maximumBodyBytes else {
            throw WriteError.bodyTooLarge(body.count)
        }
        var source = body
        if source.withUnsafeBytes({ raw in raw.contains(0) }) { throw WriteError.bodyContainsNUL }
        // Reuse the buffer: header is "<prefix>Content-Length: <n>\r\n\r\n".
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var result = Data(header.utf8)
        result.append(source)
        return result
    }

    /// Header-only check helper used by tests and the bounded queue: the
    /// declared byte length of a frame given its body size.
    public static func declaredFrameBytes(bodyBytes: Int) -> Int {
        "Content-Length: \(bodyBytes)\r\n\r\n".utf8.count + bodyBytes
    }
}
