// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameEditingCore

/// Total, lossless interchange between a Ruby Marshal data graph and the
/// typed JSON tree used by the auxiliary editors ("floe-rpg-marshal" v1).
///
/// Every node form round-trips exactly, including:
/// - string encodings (`$encoding`: utf-8 / us-ascii / binary / named)
/// - symbols, bignums, floats (text preserved verbatim)
/// - object/struct classes and all instance variables (unknown fields kept)
/// - user-defined payloads (Table/Color/Tone, base64)
/// - shared references and cycles (`$id` / `$ref`)
///
/// This is the stable data adapter interface consumed by parameter editing
/// over binary RPG Maker database files.
public enum RPGMarshalJSON {
    public static let formatName = "floe-rpg-marshal"
    public static let formatVersion = 1

    // MARK: - Encode (graph -> JSON)

    public static func encode(_ root: RubyNode) -> JSONValue {
        var registry: [ObjectIdentifier: Int] = [:]
        var counter = SequenceCounter()
        return encodeNode(root, registry: &registry, nextID: &counter)
    }

    public static func encodeDocument(_ root: RubyNode) -> JSONValue {
        .object([
            "format": .string(formatName),
            "formatVersion": .number(Double(formatVersion)),
            "root": encode(root),
        ])
    }

    private final class SequenceCounter {
        var value = 0
    }

    private static func encodeNode(_ node: RubyNode, registry: inout [ObjectIdentifier: Int],
                                   nextID: inout SequenceCounter) -> JSONValue {
        let identifier = ObjectIdentifier(node)
        if let existing = registry[identifier] {
            return .object(["$ref": .number(Double(existing))])
        }
        let assigned: Int?
        if node.value.kind.isRegisteredKind {
            assigned = nextID.value
            registry[identifier] = nextID.value
            nextID.value += 1
        } else {
            assigned = nil
        }
        var encoded = encodeKind(node.value.kind, registry: &registry, nextID: &nextID)
        if let assigned {
            // "$slot" carries the original Marshal object-table index so the
            // writer reproduces byte-identical link numbering even when the
            // graph is routed through JSON.
            var extra: [String: JSONValue] = ["$id": .number(Double(assigned))]
            if let original = node.originalMarshalIndex {
                extra["$slot"] = .number(Double(original))
            }
            if case .object(var object) = encoded {
                for (key, value) in extra { object[key] = value }
                encoded = .object(object)
            } else {
                extra["$value"] = encoded
                encoded = .object(extra)
            }
        }
        return encoded
    }

    private static func encodeString(_ string: RubyString) -> JSONValue {
        var object: [String: JSONValue] = [:]
        switch string.encoding {
        case .binary:
            if let text = string.utf8String {
                object["$string"] = .string(text)
            } else {
                object["$bytes"] = .array(string.bytes.map { .number(Double($0)) })
            }
            object["$encoding"] = .string("binary")
        case .utf8:
            object["$string"] = .string(string.utf8String ?? "")
            object["$encoding"] = .string("utf-8")
        case .usAscii:
            object["$string"] = .string(string.utf8String ?? "")
            object["$encoding"] = .string("us-ascii")
        case .named(let name):
            if let text = string.utf8String {
                object["$string"] = .string(text)
            } else {
                object["$bytes"] = .array(string.bytes.map { .number(Double($0)) })
            }
            object["$encoding"] = .string(name)
        case .custom(let list):
            if let text = string.utf8String {
                object["$string"] = .string(text)
            } else {
                object["$bytes"] = .array(string.bytes.map { .number(Double($0)) })
            }
            object["$encodingIvars"] = .array(list.map { name, constant in
                .array([.string(name), encodeConstant(constant)])
            })
        }
        for (name, constant) in string.extraIVars {
            object[name] = encodeConstant(constant)
        }
        return .object(object)
    }

    private static func encodeConstant(_ constant: RubyConstant) -> JSONValue {
        switch constant {
        case .bool(let value): return .bool(value)
        case .string(let value): return .string(value)
        }
    }

    private static func encodeIVars(_ ivars: [RubyIvar], registry: inout [ObjectIdentifier: Int],
                                    nextID: inout SequenceCounter) -> [String: JSONValue] {
        var object: [String: JSONValue] = [:]
        for ivar in ivars {
            object[ivar.name] = encodeNode(ivar.value, registry: &registry, nextID: &nextID)
        }
        return object
    }

    /// Instance variables are emitted twice: a keyed object for editing and
    /// an explicit order array so byte-identical re-serialization does not
    /// depend on JSON key ordering.
    private static func encodeIVarBlock(_ ivars: [RubyIvar], registry: inout [ObjectIdentifier: Int],
                                        nextID: inout SequenceCounter) -> [String: JSONValue] {
        [
            "$ivars": .object(encodeIVars(ivars, registry: &registry, nextID: &nextID)),
            "$ivarOrder": .array(ivars.map { .string($0.name) }),
        ]
    }

    private static func encodeKind(_ kind: RubyKind, registry: inout [ObjectIdentifier: Int],
                                   nextID: inout SequenceCounter) -> JSONValue {
        switch kind {
        case .nil: return .null
        case .bool(let value): return .bool(value)
        case .integer(let value): return .number(Double(value))
        case .bigInteger(let big): return .object(["$bigint": .string(big.decimalString)])
        case .float(let float): return .object(["$float": .string(float.text)])
        case .string(let string): return encodeString(string)
        case .symbol(let name): return .object(["$symbol": .string(name)])
        case .array(let items):
            return .array(items.map { encodeNode($0, registry: &registry, nextID: &nextID) })
        case .hash(let hash):
            var object: [String: JSONValue] = [
                "$pairs": .array(hash.pairs.map { pair in
                    .object([
                        "$key": encodeNode(pair.key, registry: &registry, nextID: &nextID),
                        "$value": encodeNode(pair.value, registry: &registry, nextID: &nextID),
                    ])
                })
            ]
            if let defaultValue = hash.defaultValue {
                object["$default"] = encodeNode(defaultValue, registry: &registry, nextID: &nextID)
            }
            return .object(object)
        case .object(let className, let ivars):
            var object: [String: JSONValue] = ["$class": .string(className)]
            for (key, value) in encodeIVarBlock(ivars, registry: &registry, nextID: &nextID) {
                object[key] = value
            }
            return .object(object)
        case .struct(let className, let members):
            var object: [String: JSONValue] = ["$class": .string(className), "$struct": .bool(true)]
            for (key, value) in encodeIVarBlock(members, registry: &registry, nextID: &nextID) {
                object[key] = value
            }
            return .object(object)
        case .userDefined(let className, let data):
            return .object(["$class": .string(className), "$userdata": .string(data.base64EncodedString())])
        case .userMarshal(let className, let value):
            return .object(["$class": .string(className), "$marshal": encodeNode(value, registry: &registry, nextID: &nextID)])
        case .regexp(let pattern, let options):
            var object: [String: JSONValue] = ["$options": .number(Double(options))]
            if let text = String(data: pattern, encoding: .utf8) {
                object["$regexp"] = .string(text)
            } else {
                object["$regexpBytes"] = .array(pattern.map { .number(Double($0)) })
            }
            return .object(object)
        case .extended(let modules, let value):
            return .object([
                "$extended": .array(modules.map { .string($0) }),
                "$value": encodeNode(value, registry: &registry, nextID: &nextID),
            ])
        case .classObject(let name):
            return .object(["$classObject": .string(name)])
        case .moduleObject(let name):
            return .object(["$moduleObject": .string(name)])
        }
    }

    // MARK: - Decode (JSON -> graph)

    public static func decode(_ value: JSONValue) throws -> RubyNode {
        var registry: [Int: RubyNode] = [:]
        return try decodeNode(value, registry: &registry)
    }

    public static func decodeDocument(_ value: JSONValue) throws -> RubyNode {
        guard value["format"]?.stringValue == formatName,
              value["formatVersion"]?.intValue == formatVersion else {
            throw RPGCodecError.malformedArchive("bad floe-rpg-marshal document header")
        }
        guard let root = value["root"] else { throw RPGCodecError.malformedArchive("missing root") }
        return try decode(root)
    }

    private static func decodeNode(_ value: JSONValue, registry: inout [Int: RubyNode]) throws -> RubyNode {
        // $ref fast path.
        if let reference = value["$ref"]?.intValue {
            guard let node = registry[reference] else {
                throw RPGCodecError.malformedArchive("dangling $ref \(reference)")
            }
            return node
        }
        var id: Int? = nil
        var payload = value
        if let assigned = value["$id"]?.intValue {
            id = assigned
            if let wrapped = value["$value"] { payload = wrapped }
        }
        guard let id else {
            return try decodeKind(payload, registry: &registry)
        }
        // Register a placeholder before decoding children so self-references
        // and shared links inside the node resolve to the same instance.
        let placeholder = RubyNode(RubyValue(kind: .`nil`))
        if let slot = value["$slot"]?.intValue {
            placeholder.originalMarshalIndex = slot
        }
        registry[id] = placeholder
        let decoded = try decodeKind(payload, registry: &registry)
        placeholder.value = decoded.value
        return placeholder
    }

    private static func decodeString(_ object: [String: JSONValue]) throws -> RubyString {
        let bytes: Data
        if let text = object["$string"]?.stringValue {
            bytes = Data(text.utf8)
        } else if let list = object["$bytes"]?.arrayValue {
            bytes = Data(list.compactMap { $0.numberValue }.map { UInt8(truncatingIfNeeded: Int64($0)) })
        } else {
            throw RPGCodecError.malformedArchive("string node without $string/$bytes")
        }
        var extraIVars: [(String, RubyConstant)] = []
        for (key, value) in object where key.hasPrefix("$") == false {
            guard let constant = decodeConstant(value) else {
                throw RPGCodecError.malformedArchive("non-constant string ivar \(key)")
            }
            extraIVars.append((key, constant))
        }
        let encoding: RubyStringEncoding
        if let ivars = object["$encodingIvars"]?.arrayValue {
            let list = try ivars.map { item -> (String, RubyConstant) in
                guard let pair = item.arrayValue, pair.count == 2,
                      let name = pair[0].stringValue, let constant = decodeConstant(pair[1]) else {
                    throw RPGCodecError.malformedArchive("bad $encodingIvars entry")
                }
                return (name, constant)
            }
            encoding = .custom(list)
        } else if let name = object["$encoding"]?.stringValue {
            switch name {
            case "binary": encoding = .binary
            case "utf-8", "UTF-8": encoding = .utf8
            case "us-ascii", "US-ASCII": encoding = .usAscii
            default: encoding = .named(name)
            }
        } else {
            encoding = .binary
        }
        return RubyString(bytes: bytes, encoding: encoding, extraIVars: extraIVars)
    }

    private static func decodeConstant(_ value: JSONValue) -> RubyConstant? {
        if let bool = value.boolValue { return .bool(bool) }
        if let string = value.stringValue { return .string(string) }
        return nil
    }

    private static func decodeIVars(_ object: [String: JSONValue],
                                    order: [JSONValue]? = nil,
                                    registry: inout [Int: RubyNode]) throws -> [RubyIvar] {
        var ivars: [RubyIvar] = []
        if let order {
            for entry in order {
                guard let name = entry.stringValue, let value = object[name] else { continue }
                ivars.append(RubyIvar(name: name, value: try decodeNode(value, registry: &registry)))
            }
            // Defensive: any key not listed in the order array is appended last.
            let known = Set(ivars.map(\.name))
            for name in object.keys.sorted() where !known.contains(name) {
                ivars.append(RubyIvar(name: name, value: try decodeNode(object[name]!, registry: &registry)))
            }
            return ivars
        }
        for name in object.keys.sorted() {
            guard let value = object[name] else { continue }
            ivars.append(RubyIvar(name: name, value: try decodeNode(value, registry: &registry)))
        }
        return ivars
    }

    private static func decodeKind(_ value: JSONValue, registry: inout [Int: RubyNode]) throws -> RubyNode {
        switch value {
        case .null:
            return RubyNode(RubyValue(kind: .nil))
        case .bool(let bool):
            return RubyNode(RubyValue(kind: .bool(bool)))
        case .number(let number):
            if number.rounded() == number, number >= -9.0e15, number <= 9.0e15 {
                return RubyNode(RubyValue(kind: .integer(Int64(number))))
            }
            return RubyNode(RubyValue(kind: .float(RubyFloat(text: String(format: "%.16g", number)))))
        case .string(let text):
            return RubyNode(RubyValue(kind: .string(.utf8(text))))
        case .array(let items):
            var children: [RubyNode] = []
            children.reserveCapacity(items.count)
            for item in items { children.append(try decodeNode(item, registry: &registry)) }
            return RubyNode(RubyValue(kind: .array(children)))
        case .object(let object):
            if let _ = object["$bigint"] {
                guard let decimal = object["$bigint"]?.stringValue else { throw RPGCodecError.malformedArchive("bad $bigint") }
                return RubyNode(RubyValue(kind: .bigInteger(try parseDecimalBigInt(decimal))))
            }
            if let _ = object["$float"] {
                guard let text = object["$float"]?.stringValue else { throw RPGCodecError.malformedArchive("bad $float") }
                return RubyNode(RubyValue(kind: .float(RubyFloat(text: text))))
            }
            if object["$string"] != nil || object["$bytes"] != nil {
                return RubyNode(RubyValue(kind: .string(try decodeString(object))))
            }
            if let name = object["$symbol"]?.stringValue {
                return RubyNode(RubyValue(kind: .symbol(name)))
            }
            if let _ = object["$pairs"] {
                guard let pairs = object["$pairs"]?.arrayValue else { throw RPGCodecError.malformedArchive("bad $pairs") }
                var decoded: [(key: RubyNode, value: RubyNode)] = []
                decoded.reserveCapacity(pairs.count)
                for pair in pairs {
                    guard let entry = pair.objectValue,
                          let key = entry["$key"], let value = entry["$value"] else {
                        throw RPGCodecError.malformedArchive("bad hash pair")
                    }
                    decoded.append((try decodeNode(key, registry: &registry), try decodeNode(value, registry: &registry)))
                }
                let defaultValue = try object["$default"].map { try decodeNode($0, registry: &registry) }
                return RubyNode(RubyValue(kind: .hash(RubyHash(pairs: decoded, defaultValue: defaultValue))))
            }
            if let className = object["$class"]?.stringValue {
                let memberObject = object["$ivars"]?.objectValue ?? object["$object"]?.objectValue
                    ?? object["$struct"]?.objectValue
                let memberOrder = object["$ivarOrder"]?.arrayValue
                let isStruct = object["$struct"] != nil && object["$struct"] != .object([:])
                if let members = memberObject {
                    let ivars = try decodeIVars(members, order: memberOrder, registry: &registry)
                    return RubyNode(RubyValue(kind: isStruct
                        ? .struct(className: className, members: ivars)
                        : .object(className: className, ivars: ivars)))
                }
                if let data = object["$userdata"]?.stringValue {
                    guard let bytes = Data(base64Encoded: data) else { throw RPGCodecError.malformedArchive("bad $userdata base64") }
                    return RubyNode(RubyValue(kind: .userDefined(className: className, data: bytes)))
                }
                if let payload = object["$marshal"] {
                    return RubyNode(RubyValue(kind: .userMarshal(className: className, value: try decodeNode(payload, registry: &registry))))
                }
                throw RPGCodecError.malformedArchive("class node without payload")
            }
            if let modules = object["$extended"]?.arrayValue {
                guard let payload = object["$value"] else { throw RPGCodecError.malformedArchive("extended without value") }
                return RubyNode(RubyValue(kind: .extended(
                    modules: modules.compactMap { $0.stringValue },
                    value: try decodeNode(payload, registry: &registry))))
            }
            if let name = object["$classObject"]?.stringValue {
                return RubyNode(RubyValue(kind: .classObject(name: name)))
            }
            if let name = object["$moduleObject"]?.stringValue {
                return RubyNode(RubyValue(kind: .moduleObject(name: name)))
            }
            if let patternText = object["$regexp"]?.stringValue {
                let options = UInt8(object["$options"]?.numberValue ?? 0)
                return RubyNode(RubyValue(kind: .regexp(pattern: Data(patternText.utf8), options: options)))
            }
            if let patternBytes = object["$regexpBytes"]?.arrayValue {
                let options = UInt8(object["$options"]?.numberValue ?? 0)
                let data = Data(patternBytes.compactMap { $0.numberValue }.map { UInt8(truncatingIfNeeded: Int64($0)) })
                return RubyNode(RubyValue(kind: .regexp(pattern: data, options: options)))
            }
            throw RPGCodecError.malformedArchive("unrecognized node object")
        }
    }

    private static func parseDecimalBigInt(_ decimal: String) throws -> RubyBigInt {
        let negative = decimal.hasPrefix("-")
        let digits = negative ? String(decimal.dropFirst()) : decimal
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else {
            throw RPGCodecError.malformedArchive("bad bigint decimal")
        }
        var words: [UInt16] = []
        for character in digits {
            var carry = UInt32(character.wholeNumberValue ?? 0)
            for index in words.indices {
                let value = UInt32(words[index]) * 10 + carry
                words[index] = UInt16(value & 0xffff)
                carry = value >> 16
            }
            while carry > 0 {
                words.append(UInt16(carry & 0xffff))
                carry >>= 16
            }
        }
        return RubyBigInt(negative: negative, words: words)
    }
}
