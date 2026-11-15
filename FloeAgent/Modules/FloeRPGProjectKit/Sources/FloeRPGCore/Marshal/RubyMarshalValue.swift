// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A Ruby Marshal data graph node. Identity is significant: object links and
/// reference cycles resolve to shared node instances, exactly like the Ruby
/// object graph Marshal describes.
///
/// Concurrency contract: a graph is transferred by ownership. It is safe to
/// move one fully-built graph between isolation domains, but two tasks must
/// never mutate the same graph concurrently. Editing sessions serialize
/// document access, which is why the container is declared unchecked Sendable.
public final class RubyNode: @unchecked Sendable {
    public var value: RubyValue
    /// Object-table slot this node occupied in the stream it was parsed from.
    /// The writer reuses these numbers so links re-serialize byte-identically
    /// even where Ruby's dump-side numbering has special cases.
    public var originalMarshalIndex: Int?

    public init(_ value: RubyValue) {
        self.value = value
    }

    /// Convenience access to object/struct members by symbol name.
    public subscript(member name: String) -> RubyNode? {
        get {
            switch value.kind {
            case .object(_, let ivars), .struct(_, let ivars):
                return ivars.first(where: { $0.name == name })?.value
            default: return nil
            }
        }
        set {
            switch value.kind {
            case .object(let className, var ivars):
                RubyNode.apply(newValue, name: name, to: &ivars)
                value.kind = .object(className: className, ivars: ivars)
            case .struct(let className, var members):
                RubyNode.apply(newValue, name: name, to: &members)
                value.kind = .struct(className: className, members: members)
            default: return
            }
        }
    }

    static func apply(_ newValue: RubyNode?, name: String, to list: inout [RubyIvar]) {
        if let index = list.firstIndex(where: { $0.name == name }) {
            if let newValue { list[index].value = newValue } else { list.remove(at: index) }
        } else if let newValue {
            list.append(RubyIvar(name: name, value: newValue))
        }
    }

    /// Typed scalar accessors (nil when the member is absent or mismatched).
    public func stringMember(_ name: String) -> String? {
        (self[member: name]).flatMap { $0.value.kind.stringValue?.utf8String }
    }

    public func intMember(_ name: String) -> Int64? {
        self[member: name].flatMap { $0.value.kind.int64Value }
    }

    public func setStringMember(_ name: String, _ text: String) {
        self[member: name] = RubyNode(RubyValue(kind: .string(.utf8(text))))
    }

    public func setIntMember(_ name: String, _ number: Int64) {
        self[member: name] = RubyNode(RubyValue(kind: .integer(number)))
    }
}

/// One named member: a symbol name (including any leading `@`) and value.
public struct RubyIvar {
    public var name: String
    public var value: RubyNode
    public init(name: String, value: RubyNode) {
        self.name = name; self.value = value
    }
}

/// Arbitrary precision integer, Marshal-compatible: sign plus 16-bit
/// magnitude words, least significant word first.
public struct RubyBigInt: Hashable, Sendable {
    public let negative: Bool
    /// Magnitude words, little-endian (words[0] is least significant).
    public let words: [UInt16]

    public init(negative: Bool, words: [UInt16]) {
        var trimmed = words
        while trimmed.last == 0 { trimmed.removeLast() }
        self.negative = trimmed.isEmpty ? false : negative
        self.words = trimmed
    }

    public init(_ value: Int64) {
        if value == 0 {
            self.init(negative: false, words: [])
            return
        }
        var remaining = value < 0 ? (~UInt64(bitPattern: value)) &+ 1 : UInt64(bitPattern: value)
        if value == Int64.min { remaining = UInt64(Int64.max) &+ 1 }
        var words: [UInt16] = []
        while remaining > 0 {
            words.append(UInt16(remaining & 0xffff))
            remaining >>= 16
        }
        self.init(negative: value < 0, words: words)
    }

    public var int64Value: Int64? {
        if words.count > 4 { return nil }
        var magnitude: UInt64 = 0
        for (index, word) in words.enumerated() {
            magnitude |= UInt64(word) << (16 * index)
        }
        if negative {
            if magnitude > UInt64(Int64.max) &+ 1 { return nil }
            if magnitude == UInt64(Int64.max) &+ 1 { return Int64.min }
            return -Int64(magnitude)
        }
        if magnitude > UInt64(Int64.max) { return nil }
        return Int64(magnitude)
    }

    /// Decimal string for display and diagnostics.
    public var decimalString: String {
        if words.isEmpty { return "0" }
        var work = words
        var digits = ""
        while !work.isEmpty {
            var remainder: UInt32 = 0
            var quotient: [UInt16] = []
            quotient.reserveCapacity(work.count)
            for word in work.reversed() {
                let current = (remainder << 16) | UInt32(word)
                let q = current / 10
                remainder = current % 10
                quotient.insert(UInt16(q), at: 0)
            }
            digits = String(remainder) + digits
            while quotient.first == 0 { quotient.removeFirst() }
            work = quotient
        }
        return (negative ? "-" : "") + (digits.isEmpty ? "0" : digits)
    }
}

/// A Ruby float. The original Marshal decimal text is preserved verbatim so
/// untouched graphs re-serialize byte-identically; editing re-formats with
/// Ruby's `%.16g` convention.
public struct RubyFloat: Hashable, Sendable {
    public private(set) var text: String

    public init(text: String) {
        self.text = text
    }

    public init(_ value: Double) {
        if value.isNaN { text = "nan" }
        else if value == .infinity { text = "inf" }
        else if value == -.infinity { text = "-inf" }
        else { text = String(format: "%.16g", value) }
    }

    public var doubleValue: Double {
        switch text {
        case "inf", "Infinity": return .infinity
        case "-inf", "-Infinity": return -.infinity
        case "nan", "NaN": return .nan
        default: return Double(text) ?? 0
        }
    }
}

/// Encoding of a Ruby string as recorded by Marshal `I` wrapper ivars.
/// `.binary` means no encoding ivars at all (ASCII-8BIT).
public enum RubyStringEncoding: Sendable {
    case binary
    case utf8        // :E true
    case usAscii     // :E false
    case named(String)  // :encoding "Name"
    /// Any other encoding ivar form, preserved exactly.
    case custom([(String, RubyConstant)])

    public static func fromIVars(_ ivars: [(String, RubyConstant)])
        -> (encoding: RubyStringEncoding, extra: [(String, RubyConstant)])? {
        guard !ivars.isEmpty else { return (.binary, []) }
        switch ivars[0] {
        case ("E", .bool(true)): return (.utf8, Array(ivars.dropFirst()))
        case ("E", .bool(false)): return (.usAscii, Array(ivars.dropFirst()))
        case ("encoding", .string(let name)): return (.named(name), Array(ivars.dropFirst()))
        default: return (.custom(ivars), [])
        }
    }

    public var ivarList: [(String, RubyConstant)] {
        switch self {
        case .binary: return []
        case .utf8: return [("E", .bool(true))]
        case .usAscii: return [("E", .bool(false))]
        case .named(let name): return [("encoding", .string(name))]
        case .custom(let list): return list
        }
    }
}

/// Scalar constants usable inside encoding ivars (kept tiny on purpose).
public enum RubyConstant: Hashable, Sendable {
    case bool(Bool)
    case string(String)
}

public struct RubyString: Sendable {
    public var bytes: Data
    /// Encoding recorded on the wire via `I` wrapper ivars.
    public var encoding: RubyStringEncoding
    /// Non-encoding ivars carried by the string (rare; preserved verbatim).
    public var extraIVars: [(String, RubyConstant)]

    public init(bytes: Data, encoding: RubyStringEncoding = .binary, extraIVars: [(String, RubyConstant)] = []) {
        self.bytes = bytes; self.encoding = encoding; self.extraIVars = extraIVars
    }

    public var utf8String: String? { String(data: bytes, encoding: .utf8) }

    public static func utf8(_ text: String) -> RubyString {
        RubyString(bytes: Data(text.utf8), encoding: .utf8)
    }
}

public struct RubyHash {
    public var pairs: [(key: RubyNode, value: RubyNode)]
    public var defaultValue: RubyNode?

    public init(pairs: [(key: RubyNode, value: RubyNode)], defaultValue: RubyNode? = nil) {
        self.pairs = pairs; self.defaultValue = defaultValue
    }
}

/// A node value: the payload kind plus the `I` wrapper instance variables
/// Ruby attaches to any object (strings/regexps/user-defined objects normally
/// carry encoding ivars; other kinds rarely carry any).
public struct RubyValue {
    public var kind: RubyKind
    /// `I` wrapper instance variables, in original wire order.
    public var ivars: [RubyIvar]

    public init(kind: RubyKind, ivars: [RubyIvar] = []) {
        self.kind = kind; self.ivars = ivars
    }
}

/// The payload of a Marshal node.
public enum RubyKind {
    case `nil`
    case bool(Bool)
    case integer(Int64)
    case bigInteger(RubyBigInt)
    case float(RubyFloat)
    case string(RubyString)
    case symbol(String)
    case array([RubyNode])
    case hash(RubyHash)
    case `struct`(className: String, members: [RubyIvar])
    case object(className: String, ivars: [RubyIvar])
    /// `_dump` user-defined object (Table, Color, Tone, ...).
    case userDefined(className: String, data: Data)
    /// `marshal_dump` user-marshal object.
    case userMarshal(className: String, value: RubyNode)
    case regexp(pattern: Data, options: UInt8)
    case extended(modules: [String], value: RubyNode)
    case classObject(name: String)
    case moduleObject(name: String)
}

public extension RubyKind {
    /// True for kinds Ruby numbers in the Marshal object table (link targets).
    var isRegisteredKind: Bool {
        switch self {
        case .`nil`, .bool, .integer, .symbol: return false
        default: return true
        }
    }

    var className: String? {
        switch self {
        case .struct(let name, _), .object(let name, _), .userDefined(let name, _),
             .userMarshal(let name, _): return name
        default: return nil
        }
    }

    var stringValue: RubyString? {
        if case .string(let string) = self { return string }
        return nil
    }

    var symbolValue: String? {
        if case .symbol(let name) = self { return name }
        return nil
    }

    var int64Value: Int64? {
        switch self {
        case .integer(let value): return value
        case .bigInteger(let big): return big.int64Value
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [RubyNode]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var hashValue: RubyHash? {
        if case .hash(let hash) = self { return hash }
        return nil
    }

    var userDefinedData: (className: String, data: Data)? {
        if case .userDefined(let name, let data) = self { return (name, data) }
        return nil
    }
}

extension RubyConstant {
    var nodeValue: RubyValue {
        switch self {
        case .bool(let value): return RubyValue(kind: .bool(value))
        case .string(let value): return RubyValue(kind: .string(.init(bytes: Data(value.utf8), encoding: .utf8)))
        }
    }
}

extension RubyNode {
    /// Scalar constant view of a node, for encoding ivars.
    var constantValue: RubyConstant? {
        switch value.kind {
        case .bool(let value): return .bool(value)
        case .string(let string): return string.utf8String.map { .string($0) }
        default: return nil
        }
    }
}
