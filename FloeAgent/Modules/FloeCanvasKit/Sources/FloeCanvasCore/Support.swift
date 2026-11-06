import Foundation

/// JSON tree used to retain legacy and unknown payload values across
/// import/export round trips. Numbers are stored as their EXACT source
/// literal text (e.g. `1.0`, `9007199254740993`, `1e400`), so unknown
/// numeric fields — big integers beyond Int64, high-precision decimals,
/// exponent forms — are never silently re-typed or truncated.
///
/// Fidelity guarantee: values parsed by `JSONFidelity.parse` and re-emitted
/// by `JSONFidelity.serialize` keep their exact literal spelling. The
/// `Codable` conformance exists so `JSONValue` can embed inside kit-native
/// Codable DTOs; the native encoder/decoder pair is an IDENTITY for every
/// legal `JSONValue` — numbers always travel as tagged exact literals
/// (plain number emission cannot guarantee spelling: Int64/Double re-typing
/// and JSONEncoder's `2.0` → `2` both lose it), and user objects that
/// collide with a marker shape are explicitly escaped. Foreign decoders
/// normalize spelling only for data they wrote themselves.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    /// Exact numeric literal text from the source document.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    fileprivate static let rawNumberMarker = "$floecanvas.rawNumber"
    /// Objects that themselves collide with a marker shape are wrapped under
    /// this key so encode→decode is an identity for EVERY legal `JSONValue`,
    /// including user data that happens to look like a marker.
    fileprivate static let escapeMarker = "$floecanvas.rawNumber.escape"

    /// Convenience access used by adapters and tests.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    public var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    /// The exact numeric literal, when this value is a number.
    public var numberLiteral: String? {
        guard case .number(let literal) = self else { return nil }
        return literal
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number("\(value)")
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(String(value))
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            // Object family. The escape wrapper is detected on the KEYED
            // container FIRST, before any generic [String: JSONValue] decode,
            // so its payload string is never routed through marker
            // recognition (see `encode(to:)`).
            let keyed = try decoder.container(keyedBy: MarkerCodingKeys.self)
            let keys = keyed.allKeys
            if keys.count == 1, keys[0].stringValue == JSONValue.escapeMarker,
               let serialized = try? keyed.decode(String.self, forKey: keys[0]),
               case .object(let object)? = try? JSONFidelity.parse(
                   Data(serialized.utf8)) {
                // Escaped user object that collided with a marker shape
                // (see `encode(to:)`); the fidelity parse bypasses marker
                // recognition entirely, restoring the exact original tree.
                self = .object(object)
            } else if keys.count == 1, keys[0].stringValue == JSONValue.rawNumberMarker {
                if let raw = try? keyed.decode(String.self, forKey: keys[0]),
                   JSONFidelity.isValidNumberLiteral(raw) {
                    // P0 flat marker, kept so existing P0 snapshots decode.
                    self = .number(raw)
                } else if let wrapper = try? keyed.decode(
                    [String: JSONValue].self, forKey: keys[0]),
                    wrapper.count == 1,
                    case .string(let raw)? = wrapper["literal"],
                    JSONFidelity.isValidNumberLiteral(raw) {
                    // Tagged number written by this kit.
                    self = .number(raw)
                } else {
                    // Marker-shaped foreign/user data that is not a valid
                    // tagged number: preserve the complete object.
                    self = .object(try keyed.decode(
                        [String: JSONValue].self, forKey: keys[0]))
                }
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }
    }
}

private enum MarkerCodingKeys: CodingKey {
    case known(String)

    init?(stringValue: String) { self = .known(stringValue) }
    var stringValue: String {
        switch self { case .known(let value): return value }
    }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension JSONValue {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let literal):
            // Native Codable round trip must preserve the EXACT source
            // literal. Plain JSON number emission cannot guarantee that
            // (Int64/Double re-typing, and JSONEncoder even emits Double 2.0
            // as `2`), so every number travels under an explicit tagged
            // literal. Raw external documents keep using `JSONFidelity`,
            // which preserves literals without any tagging.
            try container.encode([
                JSONValue.rawNumberMarker: ["literal": literal]
            ])
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let object):
            // Identity guarantee: a user object whose single key collides
            // with a marker key is wrapped under the escape key. The payload
            // travels as an opaque fidelity-serialized string, so decoding
            // it can never re-interpret marker-shaped user data at any
            // nesting depth.
            if object.count == 1,
               let key = object.keys.first,
               key == JSONValue.rawNumberMarker || key == JSONValue.escapeMarker {
                let serialized = try JSONFidelity.serialize(.object(object))
                try container.encode([
                    JSONValue.escapeMarker: String(decoding: serialized, as: UTF8.self)
                ])
            } else {
                try container.encode(object)
            }
        }
    }
}

/// High-fidelity JSON parser/serializer pair for compatibility work.
/// `parse` preserves exact number literals; `serialize` emits them
/// verbatim, so unknown legacy values survive read/write unchanged.
public enum JSONFidelity {
    // MARK: Parse

    /// Resource bounds for `parse`. Hosts decode untrusted documents with
    /// these limits so a hostile archive cannot exhaust memory (input size)
    /// or stack (nesting depth). Defaults cover every legitimate legacy and
    /// native canvas document; both are configurable per call.
    public struct ParseOptions: Sendable, Hashable {
        public var maxByteCount: Int
        public var maxDepth: Int

        public init(maxByteCount: Int = 64 * 1024 * 1024, maxDepth: Int = 128) {
            self.maxByteCount = maxByteCount
            self.maxDepth = maxDepth
        }
    }

    /// Parses `data` into a `JSONValue`, preserving exact number literals.
    /// Throws (without consuming or mutating the input) when the document
    /// exceeds the resource bounds or is not well-formed JSON.
    public static func parse(
        _ data: Data,
        options: ParseOptions = ParseOptions()
    ) throws -> JSONValue {
        guard data.count <= options.maxByteCount else {
            throw CanvasKitError.io(
                "JSON input is \(data.count) bytes, exceeding the \(options.maxByteCount) byte limit")
        }
        var bytes = Array(data)
        // Strip a UTF-8 BOM if present.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        var parser = Parser(bytes: bytes, maxDepth: options.maxDepth)
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw CanvasKitError.io("trailing bytes after JSON document at offset \(parser.offset)")
        }
        return value
    }

    // MARK: Serialize

    public struct SerializeOptions: Sendable, Hashable {
        public var sortedKeys: Bool
        public var prettyPrinted: Bool
        public init(sortedKeys: Bool = true, prettyPrinted: Bool = false) {
            self.sortedKeys = sortedKeys
            self.prettyPrinted = prettyPrinted
        }
    }

    public static func serialize(
        _ value: JSONValue,
        options: SerializeOptions = SerializeOptions()
    ) throws -> Data {
        var output = ""
        write(value, into: &output, options: options, indent: 0)
        return Data(output.utf8)
    }

    private static func write(
        _ value: JSONValue,
        into output: inout String,
        options: SerializeOptions,
        indent: Int
    ) {
        let pad = options.prettyPrinted ? String(repeating: "  ", count: indent) : ""
        let nextPad = options.prettyPrinted ? String(repeating: "  ", count: indent + 1) : ""
        let newline: String = options.prettyPrinted ? "\n" : ""
        let space: String = options.prettyPrinted ? " " : ""
        switch value {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let literal):
            // Validate the literal defensively; unknown spellings that are
            // not valid JSON numbers must not produce corrupt JSON.
            if isValidNumberLiteral(literal) {
                output += literal
            } else {
                write(.string(literal), into: &output, options: options, indent: indent)
            }
        case .string(let string):
            output += "\"\(escape(string))\""
        case .array(let array):
            if array.isEmpty {
                output += "[]"
            } else {
                output += "[" + newline
                for (index, element) in array.enumerated() {
                    output += nextPad
                    write(element, into: &output, options: options, indent: indent + 1)
                    if index < array.count - 1 { output += "," }
                    output += newline
                }
                output += pad + "]"
            }
        case .object(let object):
            if object.isEmpty {
                output += "{}"
            } else {
                let keys = options.sortedKeys
                    ? object.keys.sorted()
                    : Array(object.keys)
                output += "{" + newline
                for (index, key) in keys.enumerated() {
                    output += nextPad + "\"\(escape(key))\":\(space)"
                    write(object[key]!, into: &output, options: options, indent: indent + 1)
                    if index < keys.count - 1 { output += "," }
                    output += newline
                }
                output += pad + "}"
            }
        }
    }

    /// Strict JSON number grammar check: `-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?`.
    /// Shared by the parser (malformed literals are rejected instead of
    /// becoming bogus `.number` values), the serializer (defensive fallback
    /// to string) and the tagged-number decoder (marker verification).
    static func isValidNumberLiteral(_ literal: String) -> Bool {
        // JSON number grammar: -?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?
        var iterator = literal.unicodeScalars.makeIterator()
        func peekable() -> [Unicode.Scalar] { Array(literal.unicodeScalars) }
        let scalars = peekable()
        var index = 0
        func advance() -> Unicode.Scalar? {
            guard index < scalars.count else { return nil }
            defer { index += 1 }
            return scalars[index]
        }
        var current = advance()
        if current == "-" { current = advance() }
        guard let firstDigit = current, firstDigit.value >= 48, firstDigit.value <= 57 else {
            return false
        }
        if firstDigit.value == 48 {
            current = advance()
        } else {
            while let scalar = current, scalar.value >= 48, scalar.value <= 57 {
                current = advance()
            }
        }
        if current == "." {
            current = advance()
            guard let scalar = current, scalar.value >= 48, scalar.value <= 57 else {
                return false
            }
            while let scalar = current, scalar.value >= 48, scalar.value <= 57 {
                current = advance()
            }
        }
        if current == "e" || current == "E" {
            current = advance()
            if current == "+" || current == "-" { current = advance() }
            guard let scalar = current, scalar.value >= 48, scalar.value <= 57 else {
                return false
            }
            while let scalar = current, scalar.value >= 48, scalar.value <= 57 {
                current = advance()
            }
        }
        return current == nil
    }

    private static func escape(_ string: String) -> String {
        var result = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    // MARK: Parser

    private struct Parser {
        let bytes: [UInt8]
        let maxDepth: Int
        var offset = 0

        init(bytes: [UInt8], maxDepth: Int) {
            self.bytes = bytes
            self.maxDepth = maxDepth
        }

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func skipWhitespace() {
            while offset < bytes.count {
                let byte = bytes[offset]
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                    offset += 1
                } else {
                    return
                }
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth <= maxDepth else {
                throw CanvasKitError.io(
                    "JSON nesting exceeds the maximum depth of \(maxDepth)")
            }
            skipWhitespace()
            guard offset < bytes.count else {
                throw CanvasKitError.io("unexpected end of JSON input")
            }
            switch bytes[offset] {
            case UInt8(ascii: "{"):
                return try parseObject(depth: depth)
            case UInt8(ascii: "["):
                return try parseArray(depth: depth)
            case UInt8(ascii: "\""):
                return .string(try parseString())
            case UInt8(ascii: "t"):
                try expectKeyword("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expectKeyword("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expectKeyword("null")
                return .null
            default:
                return try parseNumber()
            }
        }

        private mutating func parseObject(depth: Int) throws -> JSONValue {
            offset += 1 // {
            var object: [String: JSONValue] = [:]
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "}") {
                offset += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                guard offset < bytes.count, bytes[offset] == UInt8(ascii: "\"") else {
                    throw CanvasKitError.io("expected object key at offset \(offset)")
                }
                let key = try parseString()
                skipWhitespace()
                guard offset < bytes.count, bytes[offset] == UInt8(ascii: ":") else {
                    throw CanvasKitError.io("expected ':' at offset \(offset)")
                }
                offset += 1
                let value = try parseValue(depth: depth + 1)
                object[key] = value
                skipWhitespace()
                guard offset < bytes.count else {
                    throw CanvasKitError.io("unterminated object")
                }
                if bytes[offset] == UInt8(ascii: ",") {
                    offset += 1
                    continue
                }
                if bytes[offset] == UInt8(ascii: "}") {
                    offset += 1
                    return .object(object)
                }
                throw CanvasKitError.io("expected ',' or '}' at offset \(offset)")
            }
        }

        private mutating func parseArray(depth: Int) throws -> JSONValue {
            offset += 1 // [
            var array: [JSONValue] = []
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "]") {
                offset += 1
                return .array(array)
            }
            while true {
                array.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard offset < bytes.count else {
                    throw CanvasKitError.io("unterminated array")
                }
                if bytes[offset] == UInt8(ascii: ",") {
                    offset += 1
                    continue
                }
                if bytes[offset] == UInt8(ascii: "]") {
                    offset += 1
                    return .array(array)
                }
                throw CanvasKitError.io("expected ',' or ']' at offset \(offset)")
            }
        }

        private mutating func parseString() throws -> String {
            offset += 1 // opening quote
            var scalars = String.UnicodeScalarView()
            while offset < bytes.count {
                let byte = bytes[offset]
                if byte == UInt8(ascii: "\"") {
                    offset += 1
                    return String(String.UnicodeScalarView(scalars))
                }
                if byte == UInt8(ascii: "\\") {
                    offset += 1
                    guard offset < bytes.count else {
                        throw CanvasKitError.io("unterminated escape")
                    }
                    let escapeByte = bytes[offset]
                    offset += 1
                    switch escapeByte {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        guard let scalar = try parseUnicodeEscape() else {
                            throw CanvasKitError.io("bad \\u escape at offset \(offset)")
                        }
                        scalars.append(scalar)
                    default:
                        throw CanvasKitError.io("unknown escape at offset \(offset)")
                    }
                } else {
                    // Consume one UTF-8 scalar directly from bytes.
                    var end = offset + 1
                    while end < bytes.count && (bytes[end] & 0xC0) == 0x80 {
                        end += 1
                    }
                    let chunk = String(decoding: bytes[offset..<end], as: UTF8.self)
                    guard chunk.unicodeScalars.count == 1,
                          let scalar = chunk.unicodeScalars.first else {
                        throw CanvasKitError.io("invalid UTF-8 at offset \(offset)")
                    }
                    scalars.append(scalar)
                    offset = end
                }
            }
            throw CanvasKitError.io("unterminated string")
        }

        private mutating func parseUnicodeEscape() throws -> Unicode.Scalar? {
            let first = try parseHex4()
            if first >= 0xD800, first <= 0xDBFF {
                // High surrogate: require a following \uXXXX low surrogate.
                guard offset + 1 < bytes.count,
                      bytes[offset] == UInt8(ascii: "\\"),
                      bytes[offset + 1] == UInt8(ascii: "u") else {
                    throw CanvasKitError.io("unpaired surrogate at offset \(offset)")
                }
                offset += 2
                let second = try parseHex4()
                guard second >= 0xDC00, second <= 0xDFFF else {
                    throw CanvasKitError.io("unpaired surrogate at offset \(offset)")
                }
                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                return Unicode.Scalar(combined)
            }
            return Unicode.Scalar(first)
        }

        private mutating func parseHex4() throws -> UInt32 {
            guard offset + 4 <= bytes.count else {
                throw CanvasKitError.io("truncated \\u escape")
            }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[offset]
                offset += 1
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"):
                    digit = UInt32(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"):
                    digit = UInt32(byte - UInt8(ascii: "A")) + 10
                default:
                    throw CanvasKitError.io("bad hex digit at offset \(offset)")
                }
                value = value * 16 + digit
            }
            return value
        }

        private mutating func expectKeyword(_ keyword: String) throws {
            let scalars = Array(keyword.utf8)
            guard offset + scalars.count <= bytes.count else {
                throw CanvasKitError.io("unexpected end at offset \(offset)")
            }
            for (index, byte) in scalars.enumerated() where bytes[offset + index] != byte {
                throw CanvasKitError.io("invalid literal at offset \(offset)")
            }
            offset += scalars.count
        }

        private mutating func parseNumber() throws -> JSONValue {
            let start = offset
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "-") {
                offset += 1
            }
            while offset < bytes.count, isDigit(bytes[offset]) {
                offset += 1
            }
            if offset < bytes.count, bytes[offset] == UInt8(ascii: ".") {
                offset += 1
                while offset < bytes.count, isDigit(bytes[offset]) {
                    offset += 1
                }
            }
            if offset < bytes.count,
               bytes[offset] == UInt8(ascii: "e") || bytes[offset] == UInt8(ascii: "E") {
                offset += 1
                if offset < bytes.count,
                   bytes[offset] == UInt8(ascii: "+") || bytes[offset] == UInt8(ascii: "-") {
                    offset += 1
                }
                while offset < bytes.count, isDigit(bytes[offset]) {
                    offset += 1
                }
            }
            guard offset > start else {
                throw CanvasKitError.io("invalid JSON value at offset \(offset)")
            }
            let literal = String(decoding: bytes[start..<offset], as: UTF8.self)
            // The scanner above is permissive about partial spellings
            // ("-", "1.", "1e", leading zeros). Reject anything that does not
            // satisfy the strict JSON number grammar so malformed archives
            // surface as parse errors instead of bogus number literals.
            guard JSONFidelity.isValidNumberLiteral(literal) else {
                throw CanvasKitError.io(
                    "invalid JSON number literal '\(literal)' at offset \(start)")
            }
            return .number(literal)
        }

        private func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
    }
}

/// All errors thrown by FloeCanvasKit. Every failure carries enough context
/// for a host to surface a recoverable message; nothing here logs or crashes.
public enum CanvasKitError: Error, Hashable, Sendable {
    /// A document/page/node identifier does not exist in the snapshot.
    case missingEntity(String)
    /// A commit arrived with a stale expected revision; the current revision
    /// is included so the caller can reload and rebase.
    case revisionConflict(expected: Int64, current: Int64)
    /// A commit used an already-known request ID but different content bytes.
    case requestIDConflict(requestID: UUID)
    /// One or more edits violated locked nodes or the selected edit scope.
    case editScopeViolations([CanvasEditViolation])
    /// The flow graph is not a valid outer DAG or breaks structured rules.
    case invalidFlowGraph([CanvasFlowIssue])
    /// Legacy package schema is outside the accepted adapter range.
    case unsupportedLegacySchema(Int)
    /// Source refresh could not resolve the referenced source.
    case sourceUnavailable(UUID)
    /// A repository was asked to operate outside its explicit root.
    case repositoryRootViolation(String)
    /// Underlying I/O failure with a recoverable description.
    case io(String)
    /// The stored snapshot itself is structurally invalid (e.g. duplicate
    /// durable IDs). Never silently repaired; the store stays untouched.
    case invalidSnapshot(String)
    /// An operation was cancelled by the caller (explicit token or task
    /// cancellation) before it could complete. No partial effects landed.
    case cancelled

    public var isRecoverable: Bool {
        switch self {
        case .revisionConflict, .requestIDConflict, .editScopeViolations,
             .invalidFlowGraph, .sourceUnavailable, .cancelled:
            return true
        case .missingEntity, .unsupportedLegacySchema, .repositoryRootViolation, .io,
             .invalidSnapshot:
            return false
        }
    }
}

/// Canvas coordinate geometry. Namespaced (instead of free `CanvasPoint`)
/// so a future host target can import both FloeCore and FloeCanvasCore in
/// one file without ambiguity.
public enum CanvasGeometry {
    public struct Point: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
        public static let zero = Point(x: 0, y: 0)
    }

    public struct Size: Codable, Hashable, Sendable {
        public var width: Double
        public var height: Double
        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// Center-anchored node frame, matching the legacy canvas convention
    /// (`position` is the node's center).
    public struct Frame: Codable, Hashable, Sendable {
        public var center: Point
        public var size: Size
        public init(center: Point, size: Size) {
            self.center = center
            self.size = size
        }
        public var minX: Double { center.x - size.width / 2 }
        public var maxX: Double { center.x + size.width / 2 }
        public var minY: Double { center.y - size.height / 2 }
        public var maxY: Double { center.y + size.height / 2 }
    }
}
