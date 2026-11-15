// SPDX-License-Identifier: MPL-2.0
import Foundation

public extension RubyMarshal {
    /// Serializes a data graph to a Marshal 4.8 stream.
    ///
    /// For an unmodified graph parsed by `RubyMarshal.parse` the output is
    /// byte-identical to the input, including object link numbering, symbol
    /// table order and string encoding ivars (verified against Ruby itself).
    static func serialize(_ root: RubyNode, limits: MarshalParseLimits = MarshalParseLimits()) throws -> Data {
        let writer = MarshalStreamWriter(limits: limits)
        try writer.emitRoot(root)
        return writer.output
    }
}

/// Exact port of Ruby's `w_long` fixnum writer.
func marshalWriteLong(_ value: Int64, into emit: (UInt8) -> Void) {
    if value == 0 { emit(0); return }
    if value > 0 && value < 123 { emit(UInt8(value + 5)); return }
    if value > -124 && value < 0 { emit(UInt8(bitPattern: Int8(value - 5))); return }
    var bytes: [UInt8] = []
    var remaining = value
    for index in 1...8 {
        bytes.append(UInt8(truncatingIfNeeded: remaining))
        remaining >>= 8 // arithmetic shift
        if remaining == 0 { emit(UInt8(index)); break }
        if remaining == -1 { emit(UInt8(bitPattern: Int8(-index))); break }
    }
    for byte in bytes { emit(byte) }
}

/// Ruby dispatches fixnums outside ±2^30 (tagged value rule) to bignums.
private let fixnumMinimum: Int64 = -1 << 30
private let fixnumMaximum: Int64 = (1 << 30) - 1

final class MarshalStreamWriter {
    private(set) var output = Data()
    private let limits: MarshalParseLimits
    private var symbols: [String: Int] = [:]
    private var objects: [ObjectIdentifier: Int] = [:]
    private var usedIndices: Set<Int> = []
    private var nextFreeIndex = 0
    private var nodeCount = 0
    /// Per-dump intern table for named-encoding strings (Ruby reuses one
    /// interned name value per dump, so repeats serialize as object links).
    private var encodingNames: [String: RubyNode] = [:]

    init(limits: MarshalParseLimits) {
        self.limits = limits
    }

    func emitRoot(_ root: RubyNode) throws {
        output.append(RubyMarshal.majorVersion)
        output.append(RubyMarshal.minorVersion)
        try emitNode(root, depth: 0)
    }

    private func emit(_ byte: UInt8) {
        output.append(byte)
    }

    private func emit(bytes: Data) {
        output.append(bytes)
    }

    private func emitLong(_ value: Int64) {
        marshalWriteLong(value) { self.output.append($0) }
    }

    private func emitLong(_ value: Int) {
        marshalWriteLong(Int64(value)) { self.output.append($0) }
    }

    private func emitLengthPrefixed(_ bytes: Data) {
        emitLong(bytes.count)
        emit(bytes: bytes)
    }

    // MARK: - Symbol table (mirrors w_symbol/w_unique)

    private func emitSymbol(_ name: String) throws {
        if let index = symbols[name] {
            emit(0x3b) // ';'
            emitLong(index)
            return
        }
        guard let data = name.data(using: .utf8) else { throw MarshalError.malformed("symbol not UTF-8") }
        symbols[name] = symbols.count
        emit(0x3a) // ':'
        emitLengthPrefixed(data)
    }

    // MARK: - Object table

    private func register(_ node: RubyNode) throws -> Int {
        let identifier = ObjectIdentifier(node)
        if let existing = objects[identifier] { return existing }
        // Reuse the node's original slot so object links keep byte-identical
        // numbering; new nodes take the next free slot above the originals.
        var index: Int
        if let original = node.originalMarshalIndex, !usedIndices.contains(original) {
            index = original
        } else {
            while usedIndices.contains(nextFreeIndex) { nextFreeIndex += 1 }
            index = nextFreeIndex
        }
        usedIndices.insert(index)
        while usedIndices.contains(nextFreeIndex) { nextFreeIndex += 1 }
        objects[identifier] = index
        nodeCount += 1
        if nodeCount > limits.maximumNodes { throw MarshalError.nodeLimitExceeded }
        return index
    }

    private func isRegistered(_ node: RubyNode) -> Int? {
        objects[ObjectIdentifier(node)]
    }

    // MARK: - Nodes

    private func emitIVars(_ ivars: [RubyIvar], depth: Int) throws {
        emitLong(ivars.count)
        for ivar in ivars {
            try emitSymbol(ivar.name)
            try emitEncodingAwareValue(ivar.value, depth: depth)
        }
    }

    /// Ivar values are constants; encoding-name strings use the interned
    /// per-dump node so repeated named encodings serialize as links.
    private func emitEncodingAwareValue(_ node: RubyNode, depth: Int) throws {
        switch node.value.kind {
        case .bool(let value):
            emit(value ? 0x54 : 0x46)
        case .string(let string):
            try emitEncodingNameString(string, depth: depth)
        default:
            try emitNode(node, depth: depth)
        }
    }

    private func emitEncodingNameString(_ string: RubyString, depth: Int) throws {
        guard case .named(let name) = string.encoding else {
            // Plain constant string (custom ivar payload): full write.
            emit(0x22)
            emitLengthPrefixed(string.bytes)
            return
        }
        if let interned = encodingNames[name] {
            if let index = isRegistered(interned) {
                emit(0x40) // '@'
                emitLong(index)
                return
            }
        }
        let node = RubyNode(RubyValue(kind: .string(RubyString(bytes: string.bytes, encoding: .utf8))))
        encodingNames[name] = node
        emit(0x22) // '"'
        emitLengthPrefixed(string.bytes)
        _ = try register(node)
    }

    /// Ivars for a node: strings derive encoding ivars from their payload;
    /// other kinds use the raw ivar list attached to the value.
    private func effectiveIVars(_ node: RubyNode) -> [RubyIvar] {
        switch node.value.kind {
        case .string(let string):
            return string.encoding.ivarList.map { name, constant in RubyIvar(name: name, value: RubyNode(constant.nodeValue)) }
                + string.extraIVars.map { name, constant in RubyIvar(name: name, value: RubyNode(constant.nodeValue)) }
        default:
            return node.value.ivars
        }
    }

    private func emitNode(_ node: RubyNode, depth: Int) throws {
        guard depth <= limits.maximumDepth else { throw MarshalError.depthLimitExceeded }
        let kind = node.value.kind
        let ivars = effectiveIVars(node)
        let hasIVars = !ivars.isEmpty

        // Unregistered kinds.
        switch kind {
        case .`nil`: emit(0x30); return
        case .bool(let value): emit(value ? 0x54 : 0x46); return
        case .symbol(let name): try emitSymbol(name); return
        case .integer(let value):
            // A node parsed from a Bignum keeps that wire form (and slot).
            if value >= fixnumMinimum && value <= fixnumMaximum && node.originalMarshalIndex == nil {
                emit(0x69)
                emitLong(value)
            } else {
                // Ruby routes fixnums outside the tagged range through the
                // Bignum path, which numbers the object in the link table.
                _ = try register(node)
                try emitBigInteger(RubyBigInt(value))
            }
            return
        default:
            break
        }

        // Registered kinds: links for already-written nodes.
        if kind.isRegisteredKind, let index = isRegistered(node) {
            emit(0x40) // '@'
            emitLong(index)
            return
        }

        if hasIVars { emit(0x49) } // 'I' wrapper

        switch kind {
        case .bigInteger(let big):
            _ = try register(node)
            try emitBigInteger(big)

        case .float(let float):
            _ = try register(node)
            emit(0x66) // 'f'
            let bytes = Data(float.text.utf8)
            emitLengthPrefixed(bytes)

        case .string(let string):
            _ = try register(node)
            emit(0x22) // '"'
            emitLengthPrefixed(string.bytes)

        case .regexp(let pattern, let options):
            _ = try register(node)
            emit(0x2f) // '/'
            emitLengthPrefixed(pattern)
            emit(options)

        case .array(let items):
            _ = try register(node)
            emit(0x5b) // '['
            emitLong(items.count)
            for item in items { try emitNode(item, depth: depth + 1) }

        case .hash(let hash):
            _ = try register(node)
            if hash.defaultValue != nil { emit(0x7d) } else { emit(0x7b) }
            emitLong(hash.pairs.count)
            for pair in hash.pairs {
                try emitNode(pair.key, depth: depth + 1)
                try emitNode(pair.value, depth: depth + 1)
            }
            if let defaultValue = hash.defaultValue {
                try emitNode(defaultValue, depth: depth + 1)
            }

        case .object(let className, let members):
            _ = try register(node)
            emit(0x6f) // 'o'
            try emitSymbol(className)
            emitLong(members.count)
            for member in members {
                try emitSymbol(member.name)
                try emitNode(member.value, depth: depth + 1)
            }

        case .struct(let className, let members):
            _ = try register(node)
            emit(0x53) // 'S'
            try emitSymbol(className)
            emitLong(members.count)
            for member in members {
                try emitSymbol(member.name)
                try emitNode(member.value, depth: depth + 1)
            }

        case .userDefined(let className, let data):
            emit(0x75) // 'u'
            try emitSymbol(className)
            emitLengthPrefixed(data)
            // Ruby numbers user-defined objects only after their payload.
            _ = try register(node)

        case .userMarshal(let className, let value):
            _ = try register(node)
            emit(0x55) // 'U'
            try emitSymbol(className)
            try emitNode(value, depth: depth + 1)

        case .extended(let modules, let value):
            // Mirrors Ruby's reader: the extended wrapper is not numbered.
            emit(0x65) // 'e'
            for moduleName in modules { try emitSymbol(moduleName) }
            try emitNode(value, depth: depth + 1)

        case .classObject(let name):
            _ = try register(node)
            emit(0x63) // 'c'
            emitLengthPrefixed(Data(name.utf8))

        case .moduleObject(let name):
            _ = try register(node)
            emit(0x6d) // 'm'
            emitLengthPrefixed(Data(name.utf8))

        default:
            throw MarshalError.malformed("unsupported node kind")
        }

        if hasIVars { try emitIVars(ivars, depth: depth) }
    }

    private func emitBigInteger(_ big: RubyBigInt) throws {
        emit(0x6c) // 'l'
        emit(big.negative ? UInt8(0x2d) : UInt8(0x2b))
        emitLong(big.words.count)
        for word in big.words {
            emit(UInt8(truncatingIfNeeded: word))
            emit(UInt8(truncatingIfNeeded: word >> 8))
        }
    }
}
