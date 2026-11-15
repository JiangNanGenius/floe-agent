// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameEditingCore

/// Document over one RPG Maker database data file. Binary engines decode to a
/// Marshal graph; MV/MZ decode to the typed JSON tree. Edits are structural:
/// unknown fields, entries and plugin content stay untouched.
public struct RPGDataDocument: Sendable {
    public let kind: RPGDataFileKind
    public let engine: RPGEngine
    /// Binary engines: the Marshal graph root (array of records for database
    /// files, event list for CommonEvents, archive array for Scripts).
    public private(set) var root: RubyNode?
    /// MV/MZ: the JSON document root.
    public private(set) var json: JSONValue?

    public init(kind: RPGDataFileKind, engine: RPGEngine, root: RubyNode) {
        self.kind = kind; self.engine = engine; self.root = root
    }

    public init(kind: RPGDataFileKind, engine: RPGEngine, json: JSONValue) {
        self.kind = kind; self.engine = engine; self.json = json
    }

    // MARK: Decode / encode

    public static func decode(_ data: Data, kind: RPGDataFileKind, engine: RPGEngine,
                              marshalLimits: MarshalParseLimits = MarshalParseLimits()) throws -> RPGDataDocument {
        if engine.usesJSONData {
            guard kind != .scripts else { throw RPGCodecError.unsupportedData("MV/MZ scripts live in js/plugins.js, not a data file") }
            return RPGDataDocument(kind: kind, engine: engine, json: try JSONValue.parse(data))
        }
        return RPGDataDocument(kind: kind, engine: engine, root: try RubyMarshal.parse(data, limits: marshalLimits))
    }

    public func encode(marshalLimits: MarshalParseLimits = MarshalParseLimits()) throws -> Data {
        if let json {
            return try json.serialized()
        }
        guard let root else { throw RPGCodecError.malformedArchive("empty document") }
        return try RubyMarshal.serialize(root, limits: marshalLimits)
    }

    // MARK: - Binary record access (XP/VX/VX Ace)

    /// Records of a binary database file: index-aligned (0 is nil in engine
    /// convention). Returns record nodes in index order.
    public func binaryRecords() -> [RubyNode?] {
        guard let root, case .array(let items) = root.value.kind else { return [] }
        return items.map { $0.value.kind.isNil ? nil : $0 }
    }

    /// Typed field access for one record. Unknown ivars remain on the node.
    public func binaryRecord(_ index: Int) -> RubyNode? {
        guard let records = root?.value.kind.arrayValue, records.indices.contains(index) else { return nil }
        let node = records[index]
        return node.value.kind.isNil ? nil : node
    }

    public mutating func setBinaryRecord(_ index: Int, _ node: RubyNode?) throws {
        guard var items = root?.value.kind.arrayValue, items.indices.contains(index) else {
            throw RPGCodecError.malformedArchive("record index \(index) out of range")
        }
        items[index] = node ?? RubyNode(RubyValue(kind: .`nil`))
        root?.value.kind = .array(items)
    }

    // MARK: - JSON record access (MV/MZ)

    /// JSON database records. Standard MV/MZ database files are RAW arrays
    /// with index 0 = null; a keyed object form is tolerated as a legacy
    /// fallback only.
    public func jsonRecords() -> [JSONValue] {
        guard let json else { return [] }
        if let array = json.arrayValue { return array }
        if let key = jsonRootKey, let list = json[key]?.arrayValue { return list }
        return []
    }

    /// Root key holding the record list for this file kind ("actors", ...).
    public var jsonRootKey: String? {
        switch kind {
        case .actors: return "actors"
        case .classes: return "classes"
        case .skills: return "skills"
        case .items: return "items"
        case .weapons: return "weapons"
        case .armors: return "armors"
        case .enemies: return "enemies"
        case .troops: return "troops"
        case .states: return "states"
        case .animations: return "animations"
        case .tilesets: return engine == .rpgMakerMZ ? "tilesets" : "tilesets"
        case .commonEvents: return "events"
        default: return nil
        }
    }

    /// Structural replacement of one JSON record; sibling and unknown fields
    /// in the record object are preserved by the caller's in-place mutation.
    public mutating func updateJSONRecord(_ index: Int, _ transform: (inout JSONValue) throws -> Void) throws {
        guard var json else { throw RPGCodecError.malformedArchive("empty document") }
        if var array = json.arrayValue {
            guard array.indices.contains(index) else {
                throw RPGCodecError.malformedArchive("record index \(index) out of range")
            }
            try transform(&array[index])
            json = .array(array)
            self.json = json
            return
        }
        guard let key = jsonRootKey, var list = json[key]?.arrayValue, list.indices.contains(index) else {
            throw RPGCodecError.malformedArchive("record index \(index) out of range")
        }
        try transform(&list[index])
        json.setKey(.array(list), key)
        self.json = json
    }
}

public extension RubyKind {
    var isNil: Bool {
        if case .`nil` = self { return true }
        return false
    }
}

// MARK: - Typed record views

/// One editable database record (actor/item/enemy/...) with common RPG Maker
/// fields; every access is optional and unknown fields are preserved because
/// edits write back through the node/document, never a rebuilt schema.
public struct RPGRecordView {
    public let node: RubyNode

    public init(node: RubyNode) {
        self.node = node
    }

    public var id: Int64? { node.intMember("@id") ?? node.intMember("@ID") }
    public var name: String? { node.stringMember("@name") }

    public mutating func setName(_ text: String) {
        node.setStringMember("@name", text)
    }

    /// Numeric parameter arrays such as `@parameters` (VX/VX Ace actors).
    public func parameters() -> [Int64] {
        guard let list = node[member: "@parameters"]?.value.kind.arrayValue else { return [] }
        return list.compactMap { $0.value.kind.int64Value }
    }

    public func setParameter(_ index: Int, _ value: Int64) throws {
        guard var list = node[member: "@parameters"]?.value.kind.arrayValue, list.indices.contains(index) else {
            throw RPGCodecError.malformedArchive("parameter \(index) out of range")
        }
        list[index] = RubyNode(RubyValue(kind: .integer(value)))
        node[member: "@parameters"] = RubyNode(RubyValue(kind: .array(list)))
    }

    /// Max-level parameter curve (XP actors use @final_level etc.; VX/Ace use
    /// @max_level plus curves) — exposed as raw nodes to keep this total.
    public func memberNode(_ name: String) -> RubyNode? { node[member: name] }

    public func intMember(_ name: String) -> Int64? { node.intMember(name) }
    public func stringMember(_ name: String) -> String? { node.stringMember(name) }
    public func boolMember(_ name: String) -> Bool? { node[member: name]?.value.kind.boolValue }
}

public extension JSONValue {
    /// Structural key mutation (get-only subscripts upstream), preserving the
    /// object form and all sibling keys.
    mutating func setKey(_ value: JSONValue?, _ key: String) {
        var object = objectValue ?? [:]
        object[key] = value
        self = .object(object)
    }
}
