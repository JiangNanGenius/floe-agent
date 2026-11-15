// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameEditingCore

/// One event placed on a map (both engine families).
public struct RPGMapEvent: Sendable {
    public var id: Int
    public var name: String
    /// Tile coordinates.
    public var x: Int
    public var y: Int
    /// Binary: the event node (pages, commands). JSON: the event object.
    public var node: RubyNode?
    public var json: JSONValue?

    public init(id: Int, name: String, x: Int, y: Int, node: RubyNode? = nil, json: JSONValue? = nil) {
        self.id = id; self.name = name; self.x = x; self.y = y
        self.node = node; self.json = json
    }
}

/// A document over one RPG Maker map file: 2D tile layers plus object events.
/// Binary maps keep tiles in an `RPG::Table`; MV/MZ maps keep a flat JSON
/// tile array. Tile edits write back through the original container, so
/// unknown sibling content (parallax, note fields, ...) is preserved.
public struct RPGMapDocument: Sendable {
    public let engine: RPGEngine
    public let pathName: String
    public private(set) var root: RubyNode?
    public private(set) var json: JSONValue?

    public init(engine: RPGEngine, pathName: String, root: RubyNode) {
        self.engine = engine; self.pathName = pathName; self.root = root
    }

    public init(engine: RPGEngine, pathName: String, json: JSONValue) {
        self.engine = engine; self.pathName = pathName; self.json = json
    }

    public static func decode(_ data: Data, engine: RPGEngine, pathName: String,
                              marshalLimits: MarshalParseLimits = MarshalParseLimits()) throws -> RPGMapDocument {
        if engine.usesJSONData {
            return RPGMapDocument(engine: engine, pathName: pathName, json: try JSONValue.parse(data))
        }
        let root = try RubyMarshal.parse(data, limits: marshalLimits)
        guard root.value.kind.className == "RPG::Map" else {
            throw RPGCodecError.malformedArchive("not an RPG::Map (class \(root.value.kind.className ?? "?"))")
        }
        return RPGMapDocument(engine: engine, pathName: pathName, root: root)
    }

    public func encode(marshalLimits: MarshalParseLimits = MarshalParseLimits()) throws -> Data {
        if let json { return try json.serialized() }
        guard let root else { throw RPGCodecError.malformedArchive("empty map") }
        return try RubyMarshal.serialize(root, limits: marshalLimits)
    }

    // MARK: Geometry

    public var width: Int {
        if let json { return json["width"]?.intValue ?? 0 }
        return Int(root?.intMember("@width") ?? 0)
    }

    public var height: Int {
        if let json { return json["height"]?.intValue ?? 0 }
        return Int(root?.intMember("@height") ?? 0)
    }

    public var tileLayerCount: Int { table?.zSize ?? engine.defaultTileLayers }

    // MARK: Tiles

    /// Binary tile table (nil for MV/MZ maps).
    public var table: RPGTable? {
        guard let data = root?[member: "@data"]?.value.kind.userDefinedData, data.className == "Table" else { return nil }
        return try? RPGTable.decode(data.data)
    }

    /// Tile id at (x, y, z). z indexes the vertical tile layer.
    public func tile(x: Int, y: Int, z: Int) -> Int {
        if let table { return Int(table.value(x: x, y: y, z: z) ?? 0) }
        guard let json, let data = json["data"]?.arrayValue else { return 0 }
        guard x >= 0, y >= 0, z >= 0, x < width, y < height, z < engine.defaultTileLayers else { return 0 }
        let index = (z * height + y) * width + x
        guard data.indices.contains(index) else { return 0 }
        return data[index].intValue ?? 0
    }

    /// All tiles of one layer, row-major. Layer order matches the engine.
    public func tiles(z: Int) -> [Int] {
        (0..<height).flatMap { y in (0..<width).map { x in tile(x: x, y: y, z: z) } }
    }

    public mutating func setTile(_ value: Int, x: Int, y: Int, z: Int) throws {
        guard value >= 0, value <= 0x1fff_ffff else { throw RPGCodecError.invalidTable("tile id out of range") }
        if var table {
            try table.setValue(Int16(truncatingIfNeeded: value), x: x, y: y, z: z)
            guard let node = root else { throw RPGCodecError.malformedArchive("missing map root") }
            node[member: "@data"] = RubyNode(RubyValue(kind: .userDefined(className: "Table", data: table.encoded)))
            return
        }
        guard var json, var data = json["data"]?.arrayValue else { throw RPGCodecError.invalidTable("missing tile data") }
        guard x >= 0, y >= 0, z >= 0, x < width, y < height, z < engine.defaultTileLayers else {
            throw RPGCodecError.invalidTable("coordinates out of range")
        }
        let index = (z * height + y) * width + x
        guard data.indices.contains(index) else { throw RPGCodecError.invalidTable("tile index out of range") }
        data[index] = .number(Double(value))
        json.setKey(.array(data), "data")
        self.json = json
    }

    // MARK: Events

    public var events: [RPGMapEvent] {
        if let json {
            guard let list = json["events"]?.arrayValue else { return [] }
            return list.compactMap { event in
                guard let object = event.objectValue, let id = object["id"]?.intValue else { return nil }
                return RPGMapEvent(id: id,
                                   name: object["name"]?.stringValue ?? "",
                                   x: object["x"]?.intValue ?? 0,
                                   y: object["y"]?.intValue ?? 0,
                                   json: event)
            }
        }
        guard let eventsNode = root?[member: "@events"], let hash = eventsNode.value.kind.hashValue else { return [] }
        return hash.pairs.compactMap { pair in
            guard let id = pair.key.value.kind.int64Value,
                  let event = pair.value.value.kind.className == "RPG::Event" ? pair.value : nil else { return nil }
            return RPGMapEvent(id: Int(id),
                               name: event.stringMember("@name") ?? "",
                               x: Int(event.intMember("@x") ?? 0),
                               y: Int(event.intMember("@y") ?? 0),
                               node: event)
        }
        .sorted { $0.id < $1.id }
    }

    public mutating func moveEvent(id: Int, x: Int, y: Int) throws {
        guard x >= 0, y >= 0, x < width, y < height else { throw RPGCodecError.invalidTable("event position out of range") }
        if var json {
            guard var list = json["events"]?.arrayValue, list.indices.contains(id) else {
                throw RPGCodecError.malformedArchive("event \(id) not found")
            }
            guard var object = list[id].objectValue else { throw RPGCodecError.malformedArchive("event \(id) malformed") }
            object["x"] = .number(Double(x))
            object["y"] = .number(Double(y))
            list[id] = .object(object)
            json.setKey(.array(list), "events")
            self.json = json
            return
        }
        guard let eventsNode = root?[member: "@events"], let hash = eventsNode.value.kind.hashValue else {
            throw RPGCodecError.malformedArchive("event \(id) not found")
        }
        guard let pair = hash.pairs.first(where: { $0.key.value.kind.int64Value == Int64(id) }) else {
            throw RPGCodecError.malformedArchive("event \(id) not found")
        }
        pair.value.setIntMember("@x", Int64(x))
        pair.value.setIntMember("@y", Int64(y))
    }

    /// Removes one event from the original container. JSON maps keep the
    /// standard event-array slot as null so ids remain aligned; binary maps
    /// remove the hash pair while preserving every other event node.
    public mutating func removeEvent(id: Int) throws {
        if var json {
            guard var list = json["events"]?.arrayValue, list.indices.contains(id) else {
                throw RPGCodecError.malformedArchive("event \(id) not found")
            }
            list[id] = .null
            json.setKey(.array(list), "events")
            self.json = json
            return
        }
        guard let eventsNode = root?[member: "@events"],
              var hash = eventsNode.value.kind.hashValue else {
            throw RPGCodecError.malformedArchive("event \(id) not found")
        }
        guard hash.pairs.contains(where: { $0.key.value.kind.int64Value == Int64(id) }) else {
            throw RPGCodecError.malformedArchive("event \(id) not found")
        }
        hash.pairs.removeAll { $0.key.value.kind.int64Value == Int64(id) }
        root?[member: "@events"] = RubyNode(RubyValue(kind: .hash(hash)))
    }

    /// Adds or replaces an event. Binary events must be supplied as full
    /// `RPG::Event` nodes (clone an existing event's node as a template).
    public mutating func upsertEvent(_ event: RPGMapEvent) throws {
        if var json {
            var object = event.json?.objectValue ?? [
                "id": .number(Double(event.id)),
                "name": .string(event.name),
                "x": .number(Double(event.x)),
                "y": .number(Double(event.y)),
                "pages": .array([]),
            ]
            object["id"] = .number(Double(event.id))
            object["name"] = .string(event.name)
            object["x"] = .number(Double(event.x))
            object["y"] = .number(Double(event.y))
            var list = json["events"]?.arrayValue ?? []
            while list.count <= event.id { list.append(.null) }
            list[event.id] = .object(object)
            json.setKey(.array(list), "events")
            self.json = json
            return
        }
        guard let eventsNode = root?[member: "@events"] else { throw RPGCodecError.malformedArchive("missing @events") }
        guard let eventNode = event.node, eventNode.value.kind.className == "RPG::Event" else {
            throw RPGCodecError.malformedArchive("binary upsert requires an RPG::Event node")
        }
        eventNode.setIntMember("@x", Int64(event.x))
        eventNode.setIntMember("@y", Int64(event.y))
        eventNode.setStringMember("@name", event.name)
        var hash = eventsNode.value.kind.hashValue ?? RubyHash(pairs: [])
        hash.pairs.removeAll { $0.key.value.kind.int64Value == Int64(event.id) }
        hash.pairs.append((RubyNode(RubyValue(kind: .integer(Int64(event.id)))), eventNode))
        root?[member: "@events"] = RubyNode(RubyValue(kind: .hash(hash)))
    }

    // MARK: Event commands

    /// Command list of one event page (binary: @list of RPG::EventCommand;
    /// MV/MZ: page.list of {code, indent, parameters}).
    public func eventCommands(eventID: Int, pageIndex: Int) -> [RPGEventCommand] {
        if let json {
            guard let list = json["events"]?.arrayValue, list.indices.contains(eventID),
                  let pages = list[eventID]["pages"]?.arrayValue, pages.indices.contains(pageIndex),
                  let commands = pages[pageIndex]["list"]?.arrayValue else { return [] }
            return commands.compactMap { item in
                guard let object = item.objectValue,
                      let code = object["code"]?.intValue, let indent = object["indent"]?.intValue else { return nil }
                return RPGEventCommand(code: code, indent: indent,
                                       jsonParameters: object["parameters"]?.arrayValue ?? [])
            }
        }
        guard let event = binaryEvent(eventID), let pages = event[member: "@pages"]?.value.kind.arrayValue,
              pages.indices.contains(pageIndex) else { return [] }
        return RPGMapDocument.binaryCommandList(pages[pageIndex])
    }

    public mutating func updateEventCommands(eventID: Int, pageIndex: Int,
                                             _ commands: [RPGEventCommand]) throws {
        if var json {
            guard var list = json["events"]?.arrayValue, list.indices.contains(eventID),
                  var pages = list[eventID]["pages"]?.arrayValue, pages.indices.contains(pageIndex),
                  var page = pages[pageIndex].objectValue else { throw RPGCodecError.malformedArchive("event page not found") }
            let payload: [JSONValue] = try commands.map { command in
                guard command.parameters.isEmpty else {
                    throw RPGCodecError.unsupportedData("MV/MZ commands carry JSON parameters only")
                }
                return .object([
                    "code": .number(Double(command.code)),
                    "indent": .number(Double(command.indent)),
                    "parameters": .array(command.jsonParameters),
                ])
            }
            page["list"] = .array(payload)
            pages[pageIndex] = .object(page)
            var event = list[eventID].objectValue ?? [:]
            event["pages"] = .array(pages)
            list[eventID] = .object(event)
            json.setKey(.array(list), "events")
            self.json = json
            return
        }
        guard let event = binaryEvent(eventID), let pagesNode = event[member: "@pages"],
              var pages = pagesNode.value.kind.arrayValue, pages.indices.contains(pageIndex) else {
            throw RPGCodecError.malformedArchive("event page not found")
        }
        pages[pageIndex] = RPGMapDocument.binaryCommandNode(commands)
        event[member: "@pages"] = RubyNode(RubyValue(kind: .array(pages)))
    }

    private func binaryEvent(_ id: Int) -> RubyNode? {
        guard let hash = root?[member: "@events"]?.value.kind.hashValue else { return nil }
        return hash.pairs.first(where: { $0.key.value.kind.int64Value == Int64(id) })?.value
    }

    static func binaryCommandList(_ page: RubyNode) -> [RPGEventCommand] {
        guard let list = page[member: "@list"]?.value.kind.arrayValue else { return [] }
        return list.compactMap { item in
            guard item.value.kind.className == "RPG::EventCommand",
                  let code = item.intMember("@code"), let indent = item.intMember("@indent"),
                  let params = item[member: "@parameters"]?.value.kind.arrayValue else { return nil }
            return RPGEventCommand(code: Int(code), indent: Int(indent), parameters: params.map(binaryParameter))
        }
    }

    /// Rebuilds an @list node from commands. Parameters map back to Ruby
    /// scalars; callers editing narrative text typically only touch strings
    /// on known codes and keep everything else identical.
    static func binaryCommandNode(_ commands: [RPGEventCommand]) -> RubyNode {
        let items = commands.map { command -> RubyNode in
            let params = command.parameters.map { parameter -> RubyNode in
                switch parameter {
                case .`nil`: return RubyNode(RubyValue(kind: .`nil`))
                case .bool(let value): return RubyNode(RubyValue(kind: .bool(value)))
                case .integer(let value): return RubyNode(RubyValue(kind: .integer(value)))
                case .float(let value): return RubyNode(RubyValue(kind: .float(RubyFloat(value))))
                case .string(let value): return RubyNode(RubyValue(kind: .string(.utf8(value))))
                case .binary(let data): return RubyNode(RubyValue(kind: .string(RubyString(bytes: data, encoding: .binary))))
                }
            }
            return RubyNode(RubyValue(kind: .object(className: "RPG::EventCommand", ivars: [
                RubyIvar(name: "@code", value: RubyNode(RubyValue(kind: .integer(Int64(command.code))))),
                RubyIvar(name: "@indent", value: RubyNode(RubyValue(kind: .integer(Int64(command.indent))))),
                RubyIvar(name: "@parameters", value: RubyNode(RubyValue(kind: .array(params)))),
            ])))
        }
        return RubyNode(RubyValue(kind: .array(items)))
    }

    static func binaryParameter(_ node: RubyNode) -> RPGCommandParameter {
        switch node.value.kind {
        case .`nil`: return .`nil`
        case .bool(let value): return .bool(value)
        case .integer(let value): return .integer(value)
        case .bigInteger(let big): return .string(big.decimalString)
        case .float(let value): return .float(value.doubleValue)
        case .string(let string): return string.utf8String.map { .string($0) } ?? .binary(string.bytes)
        default: return .binary(Data())
        }
    }
}
