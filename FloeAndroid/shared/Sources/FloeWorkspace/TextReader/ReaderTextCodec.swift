// FloeWorkspace — Text reader encoding detection, validation and decoding.
//
// SPDX-License-Identifier: MPL-2.0
//
// The reader never guesses silently: an encoding is chosen only after a
// bounded probe and then validated over the WHOLE stream while the index is
// built. A stream that cannot be validated fails honestly instead of showing
// replacement characters. GB18030 is offered only when the platform really
// has that codec (probed at first use); no new dependency is introduced.
//
// Nothing here ever writes to the source: decoding is read-only and the
// reader never saves decoded text back over the original bytes.

import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Encodings the reader can validate and decode.
public enum ReaderTextEncoding: String, Codable, Sendable, CaseIterable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case gb18030

    /// Short label for the settings/readout UI.
    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .gb18030: "GB18030"
        }
    }

    /// The platform codec backing this encoding, when it exists.
    public var stringEncoding: String.Encoding? {
        switch self {
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .gb18030: String.Encoding.floeGB18030
        }
    }

    /// True when a line break is the single byte 0x0A and multibyte sequences
    /// never contain it (UTF-8 and GB18030 are ASCII-transparent).
    public var isASCIICompatible: Bool {
        self == .utf8 || self == .gb18030
    }

    /// True when characters are encoded in 2-byte code units.
    public var isUTF16: Bool {
        self == .utf16LittleEndian || self == .utf16BigEndian
    }
}

public extension String.Encoding {
    /// Platform GB18030 codec, verified with a known Chinese sequence so the
    /// reader never advertises GB18030 when the runtime cannot decode it.
    static let floeGB18030: String.Encoding? = {
        #if canImport(CoreFoundation)
        let converted = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard converted != kCFStringEncodingInvalidId else { return nil }
        let encoding = String.Encoding(rawValue: converted)
        // 中 D6D0 / 文 CEC4 in GB18030.
        guard String(data: Data([0xD6, 0xD0, 0xCE, 0xC4]), encoding: encoding) == "中文" else { return nil }
        return encoding
        #else
        return nil
        #endif
    }()
}

/// Result of the bounded probe over the first bytes of a document.
public struct ReaderEncodingProbe: Sendable, Equatable {
    public var encoding: ReaderTextEncoding
    /// Bytes of byte-order mark to skip before the content starts.
    public var bomLength: Int
    /// The encoding was declared by a BOM (not recovered heuristically).
    public var fromBOM: Bool

    public init(encoding: ReaderTextEncoding, bomLength: Int, fromBOM: Bool) {
        self.encoding = encoding
        self.bomLength = bomLength
        self.fromBOM = fromBOM
    }
}

public enum ReaderTextCodec {

    /// True when the runtime GB18030 codec exists and decodes a known probe.
    public static var gb18030CodecAvailable: Bool { String.Encoding.floeGB18030 != nil }

    // MARK: - Probe

    /// Chooses an encoding from the first bytes of a stream.
    ///
    /// Order: BOM declaration, UTF-16 without BOM (NUL pattern), strict UTF-8
    /// over the whole sample, then GB18030 when the platform codec exists and
    /// the sample decodes as text. Returns nil when nothing is defensible —
    /// the caller must fail with `.unrecognizedEncoding` rather than display
    /// decoded garbage.
    public static func probe(_ sample: Data) -> ReaderEncodingProbe? {
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) {
            return ReaderEncodingProbe(encoding: .utf8, bomLength: 3, fromBOM: true)
        }
        if sample.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || sample.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            // UTF-32 is deliberately unsupported; say so by refusing to guess.
            return nil
        }
        if sample.starts(with: [0xFF, 0xFE]) {
            return ReaderEncodingProbe(encoding: .utf16LittleEndian, bomLength: 2, fromBOM: true)
        }
        if sample.starts(with: [0xFE, 0xFF]) {
            return ReaderEncodingProbe(encoding: .utf16BigEndian, bomLength: 2, fromBOM: true)
        }
        // UTF-16 without BOM: text in either endianness is full of NUL bytes at
        // a fixed parity; a UTF-8/CJK file has none.
        if let utf16 = probeBOMLessUTF16(sample) { return utf16 }
        // A NUL byte means binary: never treat it as UTF-8 text. The sample
        // may end mid-sequence, so only a bounded prefix is validated here;
        // the streaming validator still checks the whole stream.
        if !sample.contains(0), utf8ValidPrefix(sample) {
            return ReaderEncodingProbe(encoding: .utf8, bomLength: 0, fromBOM: false)
        }
        if let gb = String.Encoding.floeGB18030,
           let text = decodePrefix(sample, as: gb),
           looksLikeText(text) {
            return ReaderEncodingProbe(encoding: .gb18030, bomLength: 0, fromBOM: false)
        }
        return nil
    }

    /// True when `sample` starts with an encoding mark that a manual choice
    /// for `encoding` cannot match: a Unicode BOM declares a different
    /// encoding (UTF-32 marks have no supported match at all), so the choice
    /// is contradictory and must fail explicitly rather than decode with the
    /// wrong backend. A matching BOM is skipped, as for automatic detection.
    public static func manualChoiceConflictsWithBOM(_ encoding: ReaderTextEncoding, sample: Data) -> Bool {
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) { return encoding != .utf8 }
        if sample.starts(with: [0xFF, 0xFE, 0x00, 0x00])
            || sample.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return true // UTF-32 is deliberately unsupported.
        }
        if sample.starts(with: [0xFF, 0xFE]) { return encoding != .utf16LittleEndian }
        if sample.starts(with: [0xFE, 0xFF]) { return encoding != .utf16BigEndian }
        return false
    }

    /// Decodes a bounded sample for the manual path's textiness gate. A
    /// trailing partial sequence (or a lone trailing surrogate) is dropped so
    /// only the sample, never the whole stream, is approximated here; the
    /// streaming validator still checks every byte of the real stream.
    public static func sampleText(_ sample: Data, as encoding: ReaderTextEncoding, bomLength: Int) -> String? {
        guard let stringEncoding = encoding.stringEncoding else { return nil }
        let start = min(max(0, bomLength), sample.count)
        let body = sample.dropFirst(start)
        if encoding.isUTF16 {
            return decodePrefix(evenLengthSuffix(Data(body)), as: stringEncoding)
        }
        return decodePrefix(Data(body), as: stringEncoding)
    }

    /// Decodes as much of `data` as forms complete sequences (drops at most a
    /// trailing partial sequence), for sample probes only.
    static func decodePrefix(_ data: Data, as encoding: String.Encoding) -> String? {
        if let text = String(data: data, encoding: encoding) { return text }
        for drop in 1...3 where drop < data.count {
            if let text = String(data: Data(data.prefix(data.count - drop)), encoding: encoding) {
                return text
            }
        }
        return nil
    }

    /// UTF-8 validity of a prefix: an incomplete trailing sequence is
    /// tolerated (the stream validator still checks the real end).
    public static func utf8ValidPrefix(_ data: Data) -> Bool {
        var validator = ReaderTextValidator(encoding: .utf8, startOffset: 0)
        return validator.consume(data, isLast: false) == nil
    }

    private static func probeBOMLessUTF16(_ sample: Data) -> ReaderEncodingProbe? {
        guard sample.count >= 4 else { return nil }
        let bytes = [UInt8](sample)
        var evenNUL = 0
        var oddNUL = 0
        for (index, byte) in bytes.enumerated() where byte == 0 {
            if index % 2 == 0 { evenNUL += 1 } else { oddNUL += 1 }
        }
        let nulCount = evenNUL + oddNUL
        guard nulCount * 5 >= bytes.count else { return nil } // ≥20% NUL bytes
        // A NUL at an EVEN index means the high byte of a big-endian unit is
        // zero; NULs at ODD indexes mean little-endian.
        let encoding: ReaderTextEncoding
        if evenNUL >= 8 * max(1, oddNUL) {
            encoding = .utf16BigEndian
        } else if oddNUL >= 8 * max(1, evenNUL) {
            encoding = .utf16LittleEndian
        } else {
            return nil
        }
        // Even-length samples must decode; a lonely high surrogate fails.
        guard let stringEncoding = encoding.stringEncoding,
              let text = decodePrefix(evenLengthSuffix(sample), as: stringEncoding),
              looksLikeText(text) else { return nil }
        return ReaderEncodingProbe(encoding: encoding, bomLength: 0, fromBOM: false)
    }

    /// Drops a trailing odd byte for sample use only; the streaming validator
    /// still has to accept the real stream.
    private static func evenLengthSuffix(_ data: Data) -> Data {
        data.count % 2 == 0 ? data : data.prefix(data.count - 1)
    }

    // MARK: - Textiness

    /// True when the decoded sample is plausibly human text: control
    /// characters (other than tab/newline/return) stay below 5%.
    public static func looksLikeText(_ text: String, controlRatioLimit: Double = 0.05) -> Bool {
        guard !text.isEmpty else { return false }
        var scalars = 0
        var controls = 0
        for scalar in text.unicodeScalars {
            scalars += 1
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D { continue }
            if scalar.value == 0xFFFD || CharacterSet.controlCharacters.contains(scalar) {
                controls += 1
            }
        }
        guard scalars > 0 else { return false }
        return Double(controls) / Double(scalars) <= controlRatioLimit
    }

    // MARK: - UTF-8 validation (single pass, no allocation)

    /// Strict UTF-8 check: rejects overlong forms, surrogates and invalid
    /// lead/continuation bytes. NUL bytes are considered binary by `probe`.
    public static func utf8Valid(_ data: Data) -> Bool {
        var validator = ReaderTextValidator(encoding: .utf8, startOffset: 0)
        return validator.consume(data, isLast: true) == nil
    }

    // MARK: - Window/line decoding

    /// Decodes one line-aligned raw slice. Returns nil only for truly
    /// undecodable bytes (the caller reports `.corruptText`).
    public static func decode(_ data: Data, as encoding: ReaderTextEncoding) -> String? {
        guard let stringEncoding = encoding.stringEncoding else { return nil }
        return String(data: data, encoding: stringEncoding)
    }
}

/// Incremental validity checker used while the index streams the file.
///
/// A caller feeds chunks in order and must report the last chunk with
/// `isLast: true`. `consume` returns nil while the stream is valid, or the
/// absolute byte offset of the first invalid sequence. Up to three raw bytes
/// are carried across chunk boundaries, so a sequence is never split
/// incorrectly.
public struct ReaderTextValidator: Sendable {
    public let encoding: ReaderTextEncoding
    private var pending: [UInt8] = []
    /// Absolute byte offset of `pending[0]`.
    private var pendingOffset: Int64
    /// Strict manual selections refuse NUL bytes for ASCII-compatible
    /// encodings (UTF-8 / GB18030): binary content must fail instead of being
    /// displayed with embedded NUL characters.
    private let rejectsNUL: Bool

    public init(encoding: ReaderTextEncoding, startOffset: Int64, rejectsNUL: Bool = false) {
        self.encoding = encoding
        self.pendingOffset = startOffset
        self.rejectsNUL = rejectsNUL
    }

    public mutating func consume(_ data: Data, isLast: Bool) -> Int64? {
        for byte in data {
            pending.append(byte)
            if let failure = resolve(isLast: false) { return failure }
        }
        return resolve(isLast: isLast)
    }

    private mutating func consume(_ count: Int) {
        pending.removeFirst(count)
        pendingOffset += Int64(count)
    }

    /// Resolves every complete sequence currently buffered. Incomplete
    /// sequences are kept (or reported when `isLast`).
    private mutating func resolve(isLast: Bool) -> Int64? {
        switch encoding {
        case .utf8: return resolveUTF8(isLast: isLast)
        case .utf16LittleEndian, .utf16BigEndian: return resolveUTF16(isLast: isLast)
        case .gb18030: return resolveGB18030(isLast: isLast)
        }
    }

    private mutating func resolveUTF8(isLast: Bool) -> Int64? {
        while !pending.isEmpty {
            let lead = pending[0]
            if rejectsNUL, lead == 0 { return pendingOffset }
            if lead < 0x80 { consume(1); continue }
            let needed: Int
            var firstMin: UInt8 = 0x80
            var firstMax: UInt8 = 0xBF
            switch lead {
            case 0xC2...0xDF: needed = 2
            case 0xE0: needed = 3; firstMin = 0xA0
            case 0xE1...0xEC: needed = 3
            case 0xED: needed = 3; firstMax = 0x9F
            case 0xEE...0xEF: needed = 3
            case 0xF0: needed = 4; firstMin = 0x90
            case 0xF1...0xF3: needed = 4
            case 0xF4: needed = 4; firstMax = 0x8F
            default: return pendingOffset
            }
            guard pending.count >= needed else {
                return isLast ? pendingOffset : nil
            }
            for index in 1..<needed {
                let byte = pending[index]
                let lower = index == 1 ? firstMin : 0x80
                let upper = index == 1 ? firstMax : 0xBF
                guard byte >= lower, byte <= upper else { return pendingOffset + Int64(index) }
            }
            consume(needed)
        }
        return nil
    }

    private mutating func resolveUTF16(isLast: Bool) -> Int64? {
        let little = encoding == .utf16LittleEndian
        while pending.count >= 2 {
            let unit: UInt16 = little
                ? UInt16(pending[0]) | (UInt16(pending[1]) << 8)
                : (UInt16(pending[0]) << 8) | UInt16(pending[1])
            if (0xD800...0xDBFF).contains(unit) {
                guard pending.count >= 4 else {
                    return isLast ? pendingOffset : nil
                }
                let low: UInt16 = little
                    ? UInt16(pending[2]) | (UInt16(pending[3]) << 8)
                    : (UInt16(pending[2]) << 8) | UInt16(pending[3])
                guard (0xDC00...0xDFFF).contains(low) else { return pendingOffset }
                consume(4)
            } else if (0xDC00...0xDFFF).contains(unit) {
                return pendingOffset
            } else {
                consume(2)
            }
        }
        if !pending.isEmpty, isLast { return pendingOffset }
        return nil
    }

    private mutating func resolveGB18030(isLast: Bool) -> Int64? {
        while !pending.isEmpty {
            let lead = pending[0]
            if rejectsNUL, lead == 0 { return pendingOffset }
            if lead <= 0x80 { consume(1); continue }
            guard lead <= 0xFE else { return pendingOffset }
            guard pending.count >= 2 else { return isLast ? pendingOffset : nil }
            let second = pending[1]
            if (0x30...0x39).contains(second) {
                guard pending.count >= 4 else { return isLast ? pendingOffset : nil }
                guard (0x81...0xFE).contains(pending[2]) else { return pendingOffset + 2 }
                guard (0x30...0x39).contains(pending[3]) else { return pendingOffset + 3 }
                consume(4)
            } else if (0x40...0x7E).contains(second) || (0x80...0xFE).contains(second) {
                consume(2)
            } else {
                return pendingOffset + 1
            }
        }
        return nil
    }
}
