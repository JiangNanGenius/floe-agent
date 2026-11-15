// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Strict, bounded parser for Ruby Marshal 4.8 streams (the container used by
/// RPG Maker XP .rxdata, VX .rvdata and VX Ace .rvdata2 files).
///
/// Semantics mirror Ruby 2.x `Marshal.load`: object links resolve against
/// Ruby's reader-side object numbering, symbols against a per-stream symbol
/// table, and `I` wrapper ivars attach to the wrapped node. No classes are
/// resolved and no code executes; class names are preserved as strings.
public enum RubyMarshal {
    public static let majorVersion: UInt8 = 4
    public static let minorVersion: UInt8 = 8
}

public struct MarshalParseLimits: Sendable {
    /// Maximum input byte count.
    public var maximumBytes: Int
    /// Maximum container nesting depth.
    public var maximumDepth: Int
    /// Maximum numbered objects (guard against decompression-style bombs).
    public var maximumNodes: Int
    /// Maximum string/bytes payload in a single node.
    public var maximumNodeBytes: Int

    public init(maximumBytes: Int = 64 * 1_024 * 1_024,
                maximumDepth: Int = 256,
                maximumNodes: Int = 8_000_000,
                maximumNodeBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumBytes = maximumBytes
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
        self.maximumNodeBytes = maximumNodeBytes
    }
}

public enum MarshalError: Error, Equatable, CustomStringConvertible {
    case truncated
    case unsupportedVersion(Int, Int)
    case malformed(String)
    case depthLimitExceeded
    case nodeLimitExceeded
    case collectionSizeExceedsInput
    case linkIndexOutOfRange(Int)
    case symbolIndexOutOfRange(Int)
    case integerOutOfRange

    public var description: String {
        switch self {
        case .truncated: return "marshal stream truncated"
        case .unsupportedVersion(let major, let minor): return "unsupported marshal version \(major).\(minor)"
        case .malformed(let detail): return "malformed marshal data: \(detail)"
        case .depthLimitExceeded: return "marshal depth limit exceeded"
        case .nodeLimitExceeded: return "marshal node limit exceeded"
        case .collectionSizeExceedsInput: return "collection size exceeds remaining input"
        case .linkIndexOutOfRange(let index): return "object link index \(index) out of range"
        case .symbolIndexOutOfRange(let index): return "symbol link index \(index) out of range"
        case .integerOutOfRange: return "integer does not fit in 64 bits"
        }
    }
}

public extension RubyMarshal {
    static func parse(_ data: Data, limits: MarshalParseLimits = MarshalParseLimits()) throws -> RubyNode {
        let reader = try MarshalStreamReader(data: data, limits: limits)
        return try reader.parseRoot()
    }
}

final class MarshalStreamReader {
    private let data: Data
    private let limits: MarshalParseLimits
    private var cursor: Data.Index
    private var symbols: [String] = []
    private var objects: [RubyNode] = []

    init(data: Data, limits: MarshalParseLimits) throws {
        guard data.count <= limits.maximumBytes else { throw MarshalError.malformed("input exceeds \(limits.maximumBytes) bytes") }
        self.data = data
        self.limits = limits
        self.cursor = data.startIndex
    }

    func parseRoot() throws -> RubyNode {
        let major = try readByte()
        let minor = try readByte()
        guard major == RubyMarshal.majorVersion else { throw MarshalError.unsupportedVersion(Int(major), Int(minor)) }
        guard minor <= RubyMarshal.minorVersion else { throw MarshalError.unsupportedVersion(Int(major), Int(minor)) }
        return try readObject(depth: 0)
    }

    // MARK: - Primitives

    private var remaining: Int { data.distance(from: cursor, to: data.endIndex) }

    private func readByte() throws -> UInt8 {
        guard cursor < data.endIndex else { throw MarshalError.truncated }
        defer { cursor = data.index(after: cursor) }
        return data[cursor]
    }

    /// Exact port of Ruby's `r_long` fixnum reader.
    private func readLong() throws -> Int64 {
        let c = Int(Int8(bitPattern: try readByte()))
        if c == 0 { return 0 }
        if c > 0 {
            if c > 4 && c < 128 { return Int64(c) - 5 }
            let count = c
            guard count <= 8 else { throw MarshalError.integerOutOfRange }
            var value: UInt64 = 0
            for index in 0..<count {
                let byte = UInt64(try readByte())
                value |= byte << (8 * index)
            }
            return Int64(bitPattern: value)
        }
        if c > -129 && c < -4 { return Int64(c) + 5 }
        let count = -c
        guard count <= 8 else { throw MarshalError.integerOutOfRange }
        var value: UInt64 = 0xffff_ffff_ffff_ffff
        for index in 0..<count {
            let byte = UInt64(try readByte())
            value = (value & ~(UInt64(0xff) << (8 * index))) | (byte << (8 * index))
        }
        return Int64(bitPattern: value)
    }

    private func readLengthPrefixedBytes() throws -> Data {
        let length = try readLong()
        guard length >= 0 else { throw MarshalError.malformed("negative byte count") }
        guard length <= limits.maximumNodeBytes else { throw MarshalError.malformed("byte count exceeds node limit") }
        guard length <= remaining else { throw MarshalError.truncated }
        let end = data.index(cursor, offsetBy: Int(length))
        defer { cursor = end }
        // Normalize to zero-based Data: consumers use integer offsets.
        return Data(data[cursor..<end])
    }

    private func readCollectionCount() throws -> Int {
        let count = try readLong()
        guard count >= 0 else { throw MarshalError.malformed("negative collection count") }
        // Every element costs at least one tag byte in a valid stream.
        guard count <= remaining else { throw MarshalError.collectionSizeExceedsInput }
        return Int(count)
    }

    // MARK: - Object graph

    private func register(_ node: RubyNode) throws {
        node.originalMarshalIndex = objects.count
        objects.append(node)
        if objects.count > limits.maximumNodes { throw MarshalError.nodeLimitExceeded }
    }

    private func readSymbolName() throws -> String {
        let bytes = try readLengthPrefixedBytes()
        guard let name = String(data: bytes, encoding: .utf8) else {
            throw MarshalError.malformed("symbol name is not UTF-8")
        }
        return name
    }

    private func readUniqueSymbol() throws -> String {
        // A class-name slot: ':' fresh symbol or ';' symbol link.
        let tag = try readByte()
        if tag == 0x3a { // ':'
            let name = try readSymbolName()
            symbols.append(name)
            if symbols.count > limits.maximumNodes { throw MarshalError.nodeLimitExceeded }
            return name
        }
        if tag == 0x3b { // ';'
            let index = try readLong()
            guard symbols.indices.contains(Int(index)) else { throw MarshalError.symbolIndexOutOfRange(Int(index)) }
            return symbols[Int(index)]
        }
        throw MarshalError.malformed("expected symbol, found tag 0x\(String(tag, radix: 16))")
    }

    private func readIVars() throws -> [RubyIvar] {
        let count = try readLong()
        guard count >= 0, count <= remaining / 2 + 1 else { throw MarshalError.malformed("bad ivar count") }
        var ivars: [RubyIvar] = []
        ivars.reserveCapacity(Int(count))
        for _ in 0..<count {
            let name = try readUniqueSymbol()
            let value = try readObject(depth: 0) // ivar values are constants; depth reset
            ivars.append(RubyIvar(name: name, value: value))
        }
        return ivars
    }

    private func readObject(depth: Int) throws -> RubyNode {
        guard depth <= limits.maximumDepth else { throw MarshalError.depthLimitExceeded }
        let tag = try readByte()
        switch tag {
        case 0x30: // '0'
            return RubyNode(RubyValue(kind: .`nil`))
        case 0x54: // 'T'
            return RubyNode(RubyValue(kind: .bool(true)))
        case 0x46: // 'F'
            return RubyNode(RubyValue(kind: .bool(false)))
        case 0x69: // 'i'
            return RubyNode(RubyValue(kind: .integer(try readLong())))

        case 0x40: // '@' object link
            let index = Int(try readLong())
            guard objects.indices.contains(index) else { throw MarshalError.linkIndexOutOfRange(index) }
            return objects[index]

        case 0x3b: // ';' symbol link
            let index = Int(try readLong())
            guard symbols.indices.contains(index) else { throw MarshalError.symbolIndexOutOfRange(index) }
            return RubyNode(RubyValue(kind: .symbol(symbols[index])))

        case 0x3a: // ':' fresh symbol
            let name = try readSymbolName()
            symbols.append(name)
            if symbols.count > limits.maximumNodes { throw MarshalError.nodeLimitExceeded }
            return RubyNode(RubyValue(kind: .symbol(name)))

        case 0x49: // 'I' ivar wrapper
            let wrapped = try readObject(depth: depth + 1)
            let ivars = try readIVars()
            wrapped.value.ivars = mergeEncodingIVars(into: wrapped, ivars: ivars)
            return wrapped

        case 0x66: // 'f' float
            let bytes = try readLengthPrefixedBytes()
            guard let text = String(data: bytes, encoding: .ascii) else {
                throw MarshalError.malformed("float text is not ASCII")
            }
            let node = RubyNode(RubyValue(kind: .float(RubyFloat(text: text))))
            try register(node)
            return node

        case 0x22: // '"' string
            let bytes = try readLengthPrefixedBytes()
            let node = RubyNode(RubyValue(kind: .string(RubyString(bytes: bytes, encoding: .binary))))
            try register(node)
            return node

        case 0x2f: // '/' regexp
            let pattern = try readLengthPrefixedBytes()
            let options = try readByte()
            let node = RubyNode(RubyValue(kind: .regexp(pattern: pattern, options: options)))
            try register(node)
            return node

        case 0x6c: // 'l' bignum
            let sign = try readByte()
            guard sign == 0x2b || sign == 0x2d else { throw MarshalError.malformed("bad bignum sign") }
            let wordCount = try readLong()
            guard wordCount > 0, wordCount <= remaining / 2 else { throw MarshalError.collectionSizeExceedsInput }
            var words: [UInt16] = []
            words.reserveCapacity(Int(wordCount))
            for _ in 0..<wordCount {
                let low = UInt16(try readByte())
                let high = UInt16(try readByte())
                words.append(low | (high << 8))
            }
            let big = RubyBigInt(negative: sign == 0x2d, words: words)
            let node = RubyNode(RubyValue(kind: big.int64Value.map { RubyKind.integer($0) } ?? .bigInteger(big)))
            try register(node)
            return node

        case 0x5b: // '[' array
            let count = try readCollectionCount()
            let node = RubyNode(RubyValue(kind: .array([])))
            try register(node)
            var items: [RubyNode] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try readObject(depth: depth + 1)) }
            node.value.kind = .array(items)
            return node

        case 0x7b, 0x7d: // '{' / '}' hash (+ default)
            let hasDefault = tag == 0x7d
            let count = try readCollectionCount()
            let node = RubyNode(RubyValue(kind: .hash(RubyHash(pairs: []))))
            try register(node)
            var pairs: [(key: RubyNode, value: RubyNode)] = []
            pairs.reserveCapacity(count)
            for _ in 0..<count {
                let key = try readObject(depth: depth + 1)
                let value = try readObject(depth: depth + 1)
                pairs.append((key, value))
            }
            let defaultValue = hasDefault ? try readObject(depth: depth + 1) : nil
            node.value.kind = .hash(RubyHash(pairs: pairs, defaultValue: defaultValue))
            return node

        case 0x6f, 0x53: // 'o' object / 'S' struct
            let className = try readUniqueSymbol()
            let count = try readCollectionCount()
            let node = RubyNode(RubyValue(kind: tag == 0x6f
                ? .object(className: className, ivars: [])
                : .struct(className: className, members: [])))
            try register(node)
            var ivars: [RubyIvar] = []
            ivars.reserveCapacity(count)
            for _ in 0..<count {
                let name = try readUniqueSymbol()
                let value = try readObject(depth: depth + 1)
                ivars.append(RubyIvar(name: name, value: value))
            }
            node.value.kind = tag == 0x6f
                ? .object(className: className, ivars: ivars)
                : .struct(className: className, members: ivars)
            return node

        case 0x75: // 'u' user-defined (_dump)
            let className = try readUniqueSymbol()
            let payload = try readLengthPrefixedBytes()
            let node = RubyNode(RubyValue(kind: .userDefined(className: className, data: payload)))
            try register(node)
            return node

        case 0x55: // 'U' user-marshal (marshal_dump)
            let className = try readUniqueSymbol()
            let node = RubyNode(RubyValue(kind: .userMarshal(className: className, value: RubyNode(RubyValue(kind: .`nil`)))))
            try register(node)
            let value = try readObject(depth: depth + 1)
            node.value.kind = .userMarshal(className: className, value: value)
            return node

        case 0x65: // 'e' extended (module prepended)
            let moduleName = try readUniqueSymbol()
            let value = try readObject(depth: depth + 1)
            return RubyNode(RubyValue(kind: .extended(modules: [moduleName], value: value)))

        case 0x63, 0x6d: // 'c' class / 'm' module
            let bytes = try readLengthPrefixedBytes()
            guard let name = String(data: bytes, encoding: .utf8) else {
                throw MarshalError.malformed("class/module name is not UTF-8")
            }
            let node = RubyNode(RubyValue(kind: tag == 0x63 ? .classObject(name: name) : .moduleObject(name: name)))
            try register(node)
            return node

        case 0x43: // 'C' subclassed builtin (annotation dropped; never in RPG Maker data)
            _ = try readUniqueSymbol()
            return try readObject(depth: depth + 1)

        default:
            throw MarshalError.malformed("unknown type tag 0x\(String(tag, radix: 16))")
        }
    }

    /// Converts encoding ivars on strings into `RubyString.encoding`; keeps
    /// other ivars verbatim. Non-string nodes keep raw ivars.
    private func mergeEncodingIVars(into node: RubyNode, ivars: [RubyIvar]) -> [RubyIvar] {
        guard case .string(var string) = node.value.kind else { return ivars }
        let constants: [(String, RubyConstant)] = ivars.compactMap { ivar in
            guard let constant = ivar.value.constantValue else { return nil }
            return (ivar.name, constant)
        }
        if constants.count == ivars.count, let parsed = RubyStringEncoding.fromIVars(constants) {
            string.encoding = parsed.encoding
            string.extraIVars = parsed.extra
            node.value.kind = .string(string)
            return []
        }
        // Unrecognized form: preserve everything as raw ivars.
        string.encoding = .binary
        node.value.kind = .string(string)
        return ivars
    }
}
