import Foundation

/// Minimal JSON model for protocol payloads.
///
/// Numbers are restricted to signed 64-bit integers. The protocol draft uses
/// decimal strings for all 64-bit counters, byte counts, revisions and
/// execution epochs, so accepting floating-point numbers would make the
/// canonical digest vulnerable to differing formatter output. Floats are
/// rejected instead of silently rounded.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    /// Deterministic JSON: object keys sorted by UTF-8 bytes, no insignificant
    /// whitespace, minimal string escaping, integer numbers only.
    public func canonicalJSON() -> String {
        var output = ""
        writeCanonical(to: &output)
        return output
    }

    public var canonicalUTF8: [UInt8] {
        Array(canonicalJSON().utf8)
    }

    /// Counts the canonical UTF-8 encoding without materializing it, stopping
    /// as soon as `limit` is exceeded. The result is `limit + 1` when the
    /// payload is too large, so callers can reject untrusted input before
    /// building a large string or hashing it.
    public func canonicalByteCount(upTo limit: Int) -> Int {
        var total = 0
        return countCanonical(into: &total, limit: limit) ? total : limit + 1
    }

    private func countCanonical(into total: inout Int, limit: Int) -> Bool {
        switch self {
        case .null:
            return JSONValue.add(4, to: &total, limit: limit)
        case .bool(let value):
            return JSONValue.add(value ? 4 : 5, to: &total, limit: limit)
        case .integer(let value):
            return JSONValue.add(String(value).utf8.count, to: &total, limit: limit)
        case .string(let value):
            return JSONValue.countString(value, into: &total, limit: limit)
        case .array(let values):
            guard JSONValue.add(2, to: &total, limit: limit) else { return false }
            for (index, value) in values.enumerated() {
                if index > 0, !JSONValue.add(1, to: &total, limit: limit) { return false }
                guard value.countCanonical(into: &total, limit: limit) else { return false }
            }
            return true
        case .object(let object):
            guard JSONValue.add(2, to: &total, limit: limit) else { return false }
            let keys = object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (index, key) in keys.enumerated() {
                if index > 0, !JSONValue.add(1, to: &total, limit: limit) { return false }
                guard JSONValue.countString(key, into: &total, limit: limit),
                      JSONValue.add(1, to: &total, limit: limit),
                      let value = object[key],
                      value.countCanonical(into: &total, limit: limit) else {
                    return false
                }
            }
            return true
        }
    }

    private static func countString(
        _ value: String,
        into total: inout Int,
        limit: Int
    ) -> Bool {
        guard JSONValue.add(2, to: &total, limit: limit) else { return false }
        for scalar in value.unicodeScalars {
            let bytes: Int
            switch scalar.value {
            case 0x22, 0x5C, 0x08, 0x0C, 0x0A, 0x0D, 0x09:
                bytes = 2
            case 0x00...0x1F:
                bytes = 6
            default:
                switch scalar.value {
                case 0...0x7F: bytes = 1
                case 0x80...0x7FF: bytes = 2
                case 0x800...0xFFFF: bytes = 3
                default: bytes = 4
                }
            }
            guard JSONValue.add(bytes, to: &total, limit: limit) else { return false }
        }
        return true
    }

    private static func add(_ count: Int, to total: inout Int, limit: Int) -> Bool {
        let (sum, overflow) = total.addingReportingOverflow(count)
        total = overflow ? limit + 1 : sum
        return !overflow && total <= limit
    }

    private func writeCanonical(to output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .integer(let value):
            output += String(value)
        case .string(let value):
            JSONValue.writeString(value, to: &output)
        case .array(let values):
            output.append("[")
            for (index, value) in values.enumerated() {
                if index > 0 { output.append(",") }
                value.writeCanonical(to: &output)
            }
            output.append("]")
        case .object(let object):
            output.append("{")
            let keys = object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (index, key) in keys.enumerated() {
                if index > 0 { output.append(",") }
                JSONValue.writeString(key, to: &output)
                output.append(":")
                object[key]?.writeCanonical(to: &output)
            }
            output.append("}")
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                output += "\\\""
            case 0x5C:
                output += "\\\\"
            case 0x08:
                output += "\\b"
            case 0x0C:
                output += "\\f"
            case 0x0A:
                output += "\\n"
            case 0x0D:
                output += "\\r"
            case 0x09:
                output += "\\t"
            case 0x00...0x1F:
                let hex = String(scalar.value, radix: 16, uppercase: false)
                output += "\\u"
                output += String(repeating: "0", count: 4 - hex.count)
                output += hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output.append("\"")
    }

    public static func parse(
        _ text: String,
        maxBytes: Int = 1_048_576,
        maxNodes: Int = 100_000
    ) throws -> JSONValue {
        guard !text.isEmpty else { throw JSONValueParseError.emptyInput }
        // Check the String's UTF-8 byte count before copying it into an array.
        guard text.utf8.count <= maxBytes else {
            throw JSONValueParseError.inputTooLarge(maxBytes)
        }
        let bytes = Array(text.utf8)
        return try parse(utf8: bytes, maxBytes: maxBytes, maxNodes: maxNodes)
    }

    public static func parse(
        utf8 bytes: [UInt8],
        maxBytes: Int = 1_048_576,
        maxNodes: Int = 100_000
    ) throws -> JSONValue {
        guard !bytes.isEmpty else { throw JSONValueParseError.emptyInput }
        guard bytes.count <= maxBytes else {
            throw JSONValueParseError.inputTooLarge(maxBytes)
        }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw JSONValueParseError.invalidUTF8
        }
        var parser = JSONParser(bytes: bytes, maxNodes: maxNodes)
        return try parser.parseDocument()
    }
}

public enum JSONValueParseError: Error, Equatable, CustomStringConvertible {
    case emptyInput
    case inputTooLarge(Int)
    case invalidUTF8
    case invalidSyntax(String, offset: Int)
    case unsupportedNumber(String, offset: Int)
    case duplicateKey(String, offset: Int)
    case depthLimitExceeded
    case nodeLimitExceeded(Int)
    case trailingData(offset: Int)

    public var description: String {
        switch self {
        case .emptyInput:
            return "JSON input is empty"
        case .inputTooLarge(let limit):
            return "JSON input exceeds \(limit) bytes"
        case .invalidUTF8:
            return "JSON input is not valid UTF-8"
        case .invalidSyntax(let detail, let offset):
            return "invalid JSON at byte \(offset): \(detail)"
        case .unsupportedNumber(let text, let offset):
            return "unsupported JSON number \(text) at byte \(offset); use an integer or a decimal string"
        case .duplicateKey(let key, let offset):
            return "duplicate JSON object key \(key) at byte \(offset)"
        case .depthLimitExceeded:
            return "JSON nesting is too deep"
        case .nodeLimitExceeded(let limit):
            return "JSON document has more than \(limit) nodes"
        case .trailingData(let offset):
            return "unexpected trailing JSON data at byte \(offset)"
        }
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0
    let maxDepth = 64
    let maxNodes: Int
    var nodeCount = 0

    init(bytes: [UInt8], maxNodes: Int) {
        self.bytes = bytes
        self.maxNodes = maxNodes
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw JSONValueParseError.trailingData(offset: index)
        }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= maxDepth else { throw JSONValueParseError.depthLimitExceeded }
        nodeCount += 1
        guard nodeCount <= maxNodes else {
            throw JSONValueParseError.nodeLimitExceeded(maxNodes)
        }
        skipWhitespace()
        guard index < bytes.count else {
            throw JSONValueParseError.invalidSyntax("unexpected end of input", offset: index)
        }
        switch bytes[index] {
        case 0x7B:
            return try parseObject(depth: depth)
        case 0x5B:
            return try parseArray(depth: depth)
        case 0x22:
            return .string(try parseString())
        case 0x74:
            try expectLiteral("true")
            return .bool(true)
        case 0x66:
            try expectLiteral("false")
            return .bool(false)
        case 0x6E:
            try expectLiteral("null")
            return .null
        default:
            return .integer(try parseInteger())
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        skipWhitespace()
        var object: [String: JSONValue] = [:]
        if peek() == 0x7D {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard peek() == 0x22 else {
                throw JSONValueParseError.invalidSyntax("object key must be a string", offset: index)
            }
            let key = try parseString()
            skipWhitespace()
            guard peek() == 0x3A else {
                throw JSONValueParseError.invalidSyntax("expected ':'", offset: index)
            }
            index += 1
            let value = try parseValue(depth: depth + 1)
            guard object[key] == nil else {
                throw JSONValueParseError.duplicateKey(key, offset: index)
            }
            object[key] = value
            skipWhitespace()
            switch peek() {
            case 0x2C:
                index += 1
            case 0x7D:
                index += 1
                return .object(object)
            default:
                throw JSONValueParseError.invalidSyntax("expected ',' or '}'", offset: index)
            }
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        skipWhitespace()
        var values: [JSONValue] = []
        if peek() == 0x5D {
            index += 1
            return .array(values)
        }
        while true {
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            switch peek() {
            case 0x2C:
                index += 1
            case 0x5D:
                index += 1
                return .array(values)
            default:
                throw JSONValueParseError.invalidSyntax("expected ',' or ']'", offset: index)
            }
        }
    }

    private mutating func parseInteger() throws -> Int64 {
        let start = index
        guard peek() != nil else {
            throw JSONValueParseError.invalidSyntax("expected a value", offset: index)
        }
        if peek() == 0x2D {
            index += 1
            guard let byte = peek(), isDigit(byte) else {
                throw JSONValueParseError.invalidSyntax("expected a digit after '-'", offset: index)
            }
        }
        guard let first = peek(), isDigit(first) else {
            throw JSONValueParseError.invalidSyntax("expected a JSON value", offset: index)
        }
        if first == 0x30 {
            index += 1
            if let next = peek(), isDigit(next) {
                throw JSONValueParseError.invalidSyntax("leading zero in number", offset: start)
            }
        } else {
            while let byte = peek(), isDigit(byte) {
                index += 1
            }
        }
        if let byte = peek(), byte == 0x2E || byte == 0x65 || byte == 0x45 {
            let snippetEnd = min(bytes.count, index + 8)
            let snippet = String(decoding: bytes[start..<snippetEnd], as: UTF8.self)
            throw JSONValueParseError.unsupportedNumber(snippet, offset: start)
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Int64(text) else {
            throw JSONValueParseError.unsupportedNumber(text, offset: start)
        }
        return value
    }

    private mutating func parseString() throws -> String {
        guard peek() == 0x22 else {
            throw JSONValueParseError.invalidSyntax("expected a string", offset: index)
        }
        index += 1
        var output: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                guard let text = String(bytes: output, encoding: .utf8) else {
                    throw JSONValueParseError.invalidUTF8
                }
                return text
            }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else {
                    throw JSONValueParseError.invalidSyntax("unterminated escape", offset: index)
                }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 0x22: output.append(0x22)
                case 0x5C: output.append(0x5C)
                case 0x2F: output.append(0x2F)
                case 0x62: output.append(0x08)
                case 0x66: output.append(0x0C)
                case 0x6E: output.append(0x0A)
                case 0x72: output.append(0x0D)
                case 0x74: output.append(0x09)
                case 0x75:
                    let scalar = try parseUnicodeScalar()
                    output.append(contentsOf: String(scalar).utf8)
                default:
                    throw JSONValueParseError.invalidSyntax("invalid escape", offset: index - 1)
                }
                continue
            }
            guard byte >= 0x20 else {
                throw JSONValueParseError.invalidSyntax("unescaped control character", offset: index)
            }
            output.append(byte)
            index += 1
        }
        throw JSONValueParseError.invalidSyntax("unterminated string", offset: index)
    }

    private mutating func parseUnicodeScalar() throws -> Unicode.Scalar {
        let first = try parseHex4()
        if (0xD800...0xDBFF).contains(first) {
            guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                throw JSONValueParseError.invalidSyntax("unpaired high surrogate", offset: index)
            }
            index += 2
            let second = try parseHex4()
            guard (0xDC00...0xDFFF).contains(second) else {
                throw JSONValueParseError.invalidSyntax("invalid low surrogate", offset: index)
            }
            let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else {
                throw JSONValueParseError.invalidSyntax("invalid Unicode scalar", offset: index)
            }
            return scalar
        }
        guard !(0xDC00...0xDFFF).contains(first),
              let scalar = Unicode.Scalar(first) else {
            throw JSONValueParseError.invalidSyntax("unpaired low surrogate", offset: index)
        }
        return scalar
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw JSONValueParseError.invalidSyntax("short Unicode escape", offset: index)
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let nibble = hexNibble(bytes[index]) else {
                throw JSONValueParseError.invalidSyntax("invalid Unicode escape", offset: index)
            }
            value = (value << 4) | nibble
            index += 1
        }
        return value
    }

    private mutating func expectLiteral(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count else {
            throw JSONValueParseError.invalidSyntax("unexpected end of input", offset: index)
        }
        for (offset, byte) in literalBytes.enumerated() where bytes[index + offset] != byte {
            throw JSONValueParseError.invalidSyntax("invalid literal", offset: index)
        }
        index += literalBytes.count
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private func hexNibble(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: return UInt32(byte - 0x30)
        case 0x41...0x46: return UInt32(byte - 0x41 + 10)
        case 0x61...0x66: return UInt32(byte - 0x61 + 10)
        default: return nil
        }
    }
}
