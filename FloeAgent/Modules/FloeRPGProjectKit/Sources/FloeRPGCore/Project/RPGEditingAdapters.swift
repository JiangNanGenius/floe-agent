// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameEditingCore

/// GameEditingAdapter implementation for one RPG Maker engine. The adapter is
/// stateless; all bytes go through the data adapters in this package.
public struct RPGEditingAdapter: GameEditingAdapter {
    /// Engine-native adapter identity for this package's codecs.
    public let rpgEngine: RPGEngine

    /// Bridge identity (protocol requirement is the shared enum).
    public var engine: GameEngineID { rpgEngine.gameEngineID }

    public init(engine: RPGEngine) {
        self.rpgEngine = engine
    }

    public func assetKind(for path: GameRelativePath, in project: GameStoredProject) -> GameAssetKind? {
        let value = path.value
        let name = (value as NSString).lastPathComponent
        let lower = name.lowercased()
        let lowerPath = value.lowercased()
        // Semantic matches first: maps, tilesets and scripts are more specific
        // than their file extension, and tileset sheets are more specific than
        // generic images.
        if lower.hasPrefix("map") && (lower.hasSuffix(".rxdata") || lower.hasSuffix(".rvdata")
            || lower.hasSuffix(".rvdata2") || lower.hasSuffix(".json")) {
            return .map
        }
        if lowerPath.contains("tilesets/") || lowerPath.contains("tileset/") { return .tileset }
        if lower == "plugins.js" || lower.hasSuffix(".js") { return .script }
        if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".bmp") || lower.hasSuffix(".webp") {
            return .image
        }
        if lower.hasSuffix(".ogg") || lower.hasSuffix(".m4a") || lower.hasSuffix(".wav") || lower.hasSuffix(".mp3") { return .audio }
        if lower.hasSuffix(".rxdata") || lower.hasSuffix(".rvdata") || lower.hasSuffix(".rvdata2") || lower.hasSuffix(".json") { return .data }
        if lower.hasSuffix(".txt") || lower.hasSuffix(".ini") { return .manifest }
        return .unknown
    }

    /// Engine-neutral parameter binding from `GameEditingAdapter`: binary
    /// rxdata/rvdata/rvdata2 documents convert to the documented
    /// "floe-rpg-marshal" interchange JSON for the shared parameter form, and
    /// edits convert back to native engine bytes. Unknown fields, object
    /// links and string encodings round-trip byte-identically when untouched.
    public func parameterBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameParameterBinding? {
        guard !rpgEngine.usesJSONData,
              project.files.contains(where: { $0.path == path }) else { return nil }
        let kind = RPGDataFileKind.classify(path.value, engine: rpgEngine)
        guard kind != .map, kind != .scripts, kind != .other else { return nil }
        return GameParameterBinding(
            decodeDataToJSON: { bytes in
                let document = try RPGDataDocument.decode(bytes, kind: kind, engine: rpgEngine)
                guard let root = document.root else { throw RPGCodecError.malformedArchive("no graph") }
                return try RPGMarshalJSON.encodeDocument(root).serialized()
            },
            encodeJSONToData: { jsonBytes in
                let value = try JSONValue.parse(jsonBytes)
                let root = try RPGMarshalJSON.decodeDocument(value)
                return try RubyMarshal.serialize(root)
            })
    }

    /// All-files schema list. Deliberately empty: a form opened on one file
    /// must never be able to write another file's fields, so discovery now
    /// goes through the per-file methods below.
    public func parameterSchemas(in project: GameStoredProject) -> [GameParameterSchema] {
        []
    }

    /// Per-file base schema (used before the record picker resolves actual
    /// records). Never returns schemas for other files.
    public func parameterSchemas(for path: GameRelativePath, in project: GameStoredProject) -> [GameParameterSchema] {
        schema(for: path, in: project).map { [$0] } ?? []
    }

    /// Record-aware schemas over the decoded parameter JSON: one schema per
    /// actual non-null record with stable ids and record-name titles. For
    /// binary engines the JSON is the "floe-rpg-marshal" interchange
    /// document, so paths address that document's real graph layout.
    public func parameterSchemas(for path: GameRelativePath, json: Data,
                                 in project: GameStoredProject) throws -> [GameParameterSchema] {
        let kind = RPGDataFileKind.classify(path.value, engine: rpgEngine)
        guard [.actors, .classes, .skills, .items, .weapons, .armors, .enemies, .troops,
               .states, .animations, .tilesets, .system, .commonEvents].contains(kind),
              project.files.contains(where: { $0.path == path }) else { return [] }
        let root = try JSONValue.parse(json)
        if rpgEngine.usesJSONData {
            return jsonRecordSchemas(kind: kind, path: path, root: root)
        }
        return binaryRecordSchemas(kind: kind, path: path, interchange: root)
    }

    /// One schema per editable database file found in the project (kept for
    /// callers that need discovery; forms use the per-file methods).
    public func schema(for path: GameRelativePath, in project: GameStoredProject) -> GameParameterSchema? {
        let kind = RPGDataFileKind.classify(path.value, engine: rpgEngine)
        guard [.actors, .classes, .skills, .items, .weapons, .armors, .enemies, .troops,
               .states, .animations, .tilesets, .system, .commonEvents].contains(kind),
              project.files.contains(where: { $0.path == path }) else { return nil }
        if rpgEngine.usesJSONData {
            return jsonSchema(kind: kind, path: path)
        }
        return binarySchema(kind: kind, path: path)
    }

    // MARK: Field specs

    private struct FieldSpec {
        let en: String
        let zh: String
        /// Components relative to the record member container.
        let suffix: [JSONFieldComponent]
        let kind: GameParameterField.FieldKind
    }

    /// Field specs relative to a record's member container (binary `$ivars`
    /// or the JSON record object). VX/Ace use @max_level where XP uses
    /// @final_level.
    private func fieldSpecs(kind: RPGDataFileKind) -> [FieldSpec] {
        switch kind {
        case .actors:
            let maxLevelName = rpgEngine == .rpgMakerXP ? "@final_level" : "@max_level"
            if rpgEngine.usesJSONData {
                return [
                    FieldSpec(en: "Name", zh: "名称", suffix: [.key("name")], kind: .text),
                    FieldSpec(en: "Nickname", zh: "昵称", suffix: [.key("nickname")], kind: .text),
                    FieldSpec(en: "Profile", zh: "简介", suffix: [.key("profile")], kind: .multiline),
                    FieldSpec(en: "Class ID", zh: "职业 ID", suffix: [.key("classId")], kind: .integer(1, nil)),
                    FieldSpec(en: "Initial level", zh: "初始等级", suffix: [.key("initialLevel")], kind: .integer(1, 99)),
                    FieldSpec(en: "Max level", zh: "最大等级", suffix: [.key("maxLevel")], kind: .integer(1, 999)),
                    FieldSpec(en: "Character image", zh: "行走图", suffix: [.key("characterName")], kind: .text),
                ]
            }
            return [
                FieldSpec(en: "Name", zh: "名称", suffix: [.key("@name"), .key("$string")], kind: .text),
                FieldSpec(en: "Class ID", zh: "职业 ID", suffix: [.key("@class_id")], kind: .integer(1, nil)),
                FieldSpec(en: "Initial level", zh: "初始等级", suffix: [.key("@initial_level")], kind: .integer(1, 99)),
                FieldSpec(en: "Max/Final level", zh: "最大等级", suffix: [.key(maxLevelName)], kind: .integer(1, 999)),
                FieldSpec(en: "Character image", zh: "行走图", suffix: [.key("@character_name"), .key("$string")], kind: .text),
            ]
        case .items, .weapons, .armors:
            if rpgEngine.usesJSONData {
                return [
                    FieldSpec(en: "Name", zh: "名称", suffix: [.key("name")], kind: .text),
                    FieldSpec(en: "Description", zh: "说明", suffix: [.key("description")], kind: .multiline),
                    FieldSpec(en: "Price", zh: "价格", suffix: [.key("price")], kind: .integer(0, nil)),
                ]
            }
            return [
                FieldSpec(en: "Name", zh: "名称", suffix: [.key("@name"), .key("$string")], kind: .text),
                FieldSpec(en: "Description", zh: "说明", suffix: [.key("@description"), .key("$string")], kind: .multiline),
                FieldSpec(en: "Price", zh: "价格", suffix: [.key("@price")], kind: .integer(0, nil)),
            ]
        case .enemies:
            if rpgEngine.usesJSONData {
                return [
                    FieldSpec(en: "Name", zh: "名称", suffix: [.key("name")], kind: .text),
                    FieldSpec(en: "HP", zh: "生命值", suffix: [.key("params"), .index(0)], kind: .integer(1, nil)),
                    FieldSpec(en: "MP", zh: "魔法值", suffix: [.key("params"), .index(1)], kind: .integer(0, nil)),
                    FieldSpec(en: "Attack", zh: "攻击力", suffix: [.key("params"), .index(2)], kind: .integer(1, nil)),
                    FieldSpec(en: "Defense", zh: "防御力", suffix: [.key("params"), .index(3)], kind: .integer(1, nil)),
                ]
            }
            return [
                FieldSpec(en: "Name", zh: "名称", suffix: [.key("@name"), .key("$string")], kind: .text),
                FieldSpec(en: "HP", zh: "生命值", suffix: [.key("@maxhp")], kind: .integer(1, nil)),
                FieldSpec(en: "SP", zh: "魔法值", suffix: [.key("@maxsp")], kind: .integer(0, nil)),
                FieldSpec(en: "Attack", zh: "攻击力", suffix: [.key("@atk")], kind: .integer(1, nil)),
                FieldSpec(en: "Defense", zh: "防御力", suffix: [.key("@def")], kind: .integer(1, nil)),
            ]
        case .states:
            if rpgEngine.usesJSONData {
                return [
                    FieldSpec(en: "Name", zh: "名称", suffix: [.key("name")], kind: .text),
                    FieldSpec(en: "Restriction", zh: "限制", suffix: [.key("restriction")], kind: .integer(0, 4)),
                ]
            }
            return [
                FieldSpec(en: "Name", zh: "名称", suffix: [.key("@name"), .key("$string")], kind: .text),
                FieldSpec(en: "Restriction", zh: "限制", suffix: [.key("@restriction")], kind: .integer(0, 4)),
            ]
        case .system:
            if rpgEngine.usesJSONData {
                return [
                    FieldSpec(en: "Game title", zh: "游戏标题", suffix: [.key("gameTitle")], kind: .text),
                    FieldSpec(en: "Currency", zh: "货币单位", suffix: [.key("currencyUnit")], kind: .text),
                ]
            }
            // XP keeps the game title in Game.ini; its System data holds the
            // title/windowskin image names. VX/VX Ace store @game_title.
            var specs: [FieldSpec] = []
            if rpgEngine != .rpgMakerXP {
                specs.append(FieldSpec(en: "Game title", zh: "游戏标题",
                                       suffix: [.key("@game_title"), .key("$string")], kind: .text))
            }
            specs.append(FieldSpec(en: "Title image", zh: "标题图片",
                                   suffix: [.key("@title_name"), .key("$string")], kind: .text))
            specs.append(FieldSpec(en: "Windowskin", zh: "窗口皮肤",
                                   suffix: [.key("@windowskin_name"), .key("$string")], kind: .text))
            return specs
        default:
            if rpgEngine.usesJSONData {
                return [FieldSpec(en: "Name", zh: "名称", suffix: [.key("name")], kind: .text)]
            }
            return [FieldSpec(en: "Name", zh: "名称", suffix: [.key("@name"), .key("$string")], kind: .text)]
        }
    }

    private func makeSchema(id: String, title: GameEditCopy, kind: RPGDataFileKind,
                            prefix: [JSONFieldComponent]) -> GameParameterSchema {
        let fields = fieldSpecs(kind: kind).map { spec in
            GameParameterField(label: GameEditCopy(spec.en, spec.zh),
                               path: JSONFieldPath(prefix + spec.suffix), kind: spec.kind)
        }
        return GameParameterSchema(id: id, title: title, fields: fields)
    }

    private func schemaTitle(path: GameRelativePath, kind: RPGDataFileKind,
                             index: Int?, name: String?) -> GameEditCopy {
        let file = (path.value as NSString).lastPathComponent
        if let name, !name.isEmpty {
            if let index {
                return GameEditCopy("\(file) #\(index): \(name)", "\(file) 第\(index)条：\(name)")
            }
            return GameEditCopy("\(file): \(name)", "\(file)：\(name)")
        }
        if let index {
            return GameEditCopy("\(file) #\(index)", "\(file) 第\(index)条")
        }
        return GameEditCopy("\(file) parameters", "\(file) 参数")
    }

    // MARK: Binary record schemas (paths into the interchange document)

    private func binaryRecordSchemas(kind: RPGDataFileKind, path: GameRelativePath,
                                     interchange: JSONValue) -> [GameParameterSchema] {
        guard let graphRoot = interchange["root"] else { return [] }
        // Record files wrap the root array as {"$id":..,"$value":[..]}.
        if let records = graphRoot["$value"]?.arrayValue {
            var schemas: [GameParameterSchema] = []
            for index in records.indices {
                let record = records[index]
                guard record.objectValue != nil else { continue }
                let name = record["$ivars"]?["@name"]?["$string"]?.stringValue
                let graphID = record["$id"]?.intValue
                let idSuffix = graphID.map { "id-\($0)" } ?? "index-\(index)"
                schemas.append(makeSchema(
                    id: "rxdata:\(path.value)#\(idSuffix)",
                    title: schemaTitle(path: path, kind: kind, index: index, name: name),
                    kind: kind,
                    prefix: [.key("root"), .key("$value"), .index(index), .key("$ivars")]))
            }
            return schemas
        }
        // System and other single-object graphs.
        if graphRoot["$ivars"]?.objectValue != nil {
            let name = graphRoot["$ivars"]?["@game_title"]?["$string"]?.stringValue
            return [makeSchema(id: "rxdata:\(path.value)#root",
                               title: schemaTitle(path: path, kind: kind, index: nil, name: name),
                               kind: kind, prefix: [.key("root"), .key("$ivars")])]
        }
        return []
    }

    // MARK: MV/MZ record schemas (raw arrays; System is a single object)

    private func jsonRecordSchemas(kind: RPGDataFileKind, path: GameRelativePath,
                                   root: JSONValue) -> [GameParameterSchema] {
        if let records = root.arrayValue {
            var schemas: [GameParameterSchema] = []
            for index in records.indices {
                let record = records[index]
                guard record.objectValue != nil else { continue }
                let name = record["name"]?.stringValue
                schemas.append(makeSchema(
                    id: "json:\(path.value)#\(index)",
                    title: schemaTitle(path: path, kind: kind, index: index, name: name),
                    kind: kind, prefix: [.index(index)]))
            }
            return schemas
        }
        if root.objectValue != nil {
            let name = root["gameTitle"]?.stringValue
            return [makeSchema(id: "json:\(path.value)#root",
                               title: schemaTitle(path: path, kind: kind, index: nil, name: name),
                               kind: kind, prefix: [])]
        }
        return []
    }

    // MARK: Legacy single-record schemas (per-file base)

    private func binarySchema(kind: RPGDataFileKind, path: GameRelativePath) -> GameParameterSchema {
        makeSchema(id: "rxdata:\(path.value)",
                   title: schemaTitle(path: path, kind: kind, index: nil, name: nil),
                   kind: kind, prefix: [.key("root"), .key("$value"), .index(1), .key("$ivars")])
    }

    private func jsonSchema(kind: RPGDataFileKind, path: GameRelativePath) -> GameParameterSchema {
        makeSchema(id: "json:\(path.value)",
                   title: schemaTitle(path: path, kind: kind, index: nil, name: nil),
                   kind: kind, prefix: [.index(1)])
    }

    // MARK: - Tile maps

    public func tileMapBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameTileMapBinding? {
        let kind = RPGDataFileKind.classify(path.value, engine: rpgEngine)
        guard kind == .map, project.files.contains(where: { $0.path == path }) else { return nil }
        let engine = rpgEngine
        // The bridge hands only the DTO to encode; the original bytes are
        // captured at decode time so unknown content merges back untouched.
        let original = OriginalBytesBox()
        return GameTileMapBinding(
            decode: { bytes in
                original.set(bytes)
                let document = try RPGMapDocument.decode(bytes, engine: engine, pathName: path.value)
                return try document.editableTileMap()
            },
            encode: { tileMap in
                var document = try RPGMapDocument.decode(try original.get(), engine: engine, pathName: path.value)
                try document.applyEditableTileMap(tileMap)
                return try document.encode()
            })
    }

    // MARK: - Narrative

    public func narrativeBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameNarrativeBinding? {
        guard project.files.contains(where: { $0.path == path }) else { return nil }
        let kind = RPGDataFileKind.classify(path.value, engine: rpgEngine)
        let isMap = kind == .map
        guard isMap || kind == .commonEvents else { return nil }
        let engine = rpgEngine
        let codec = RPGNarrativeCodec(engine: engine)
        let original = OriginalBytesBox()
        let specs = (engine.usesJSONData ? RPGCommandSpec.jsonCommon : RPGCommandSpec.binaryCommon).map { spec in
            let fields: [GameParameterField]
            let title: GameEditCopy
            func field(_ name: String, _ en: String, _ zh: String, _ kind: GameParameterField.FieldKind = .text) -> GameParameterField {
                .init(label: GameEditCopy(en, zh), path: JSONFieldPath([.key(name)]), kind: kind)
            }
            // Expose only fields actually applied by RPGNarrativeCodec. Other
            // commands keep their original payload and read-only parameters.
            switch spec.code {
            case 101:
                if engine == .rpgMakerXP {
                    title = GameEditCopy("Dialogue", "对白")
                    fields = [field("faceName", "Text", "文字")]
                } else {
                    title = GameEditCopy("Dialogue settings", "对白设置")
                    fields = [field("faceName", "Portrait file", "头像文件"), field("faceIndex", "Portrait index", "头像序号", .integer(0, 7)),
                              field("background", "Background", "背景", .integer(0, 2)), field("position", "Position", "位置", .integer(0, 2))]
                }
            case 401:
                title = GameEditCopy("Dialogue", "对白"); fields = [field("text", "Text", "文字")]
            case 408:
                title = GameEditCopy("Comment", "注释"); fields = [field("text", "Text", "文字")]
            case 355, 655:
                title = GameEditCopy("Script", "脚本"); fields = [field("line", "Source", "代码", .multiline)]
            case 117:
                title = GameEditCopy("Common event", "公共事件"); fields = [field("commonEventId", "Event", "事件", .integer(1, nil))]
            default:
                title = GameEditCopy(spec.id, spec.id); fields = []
            }
            return GameNarrativeCommandSpec(code: String(spec.code), title: title, fields: fields)
        }
        return GameNarrativeBinding(
            knownCommands: specs,
            decode: { bytes in
                original.set(bytes)
                if engine.usesJSONData {
                    let root = try JSONValue.parse(bytes)
                    return try codec.decodeJSONEventContainer(root, title: path.value)
                }
                let root = try RubyMarshal.parse(bytes)
                return try codec.decodeBinaryEventContainer(root, title: path.value)
            },
            encode: { document in
                let bytes = try original.get()
                if engine.usesJSONData {
                    let root = try JSONValue.parse(bytes)
                    let merged = try codec.encodeJSONEventContainer(document, mergingInto: root)
                    return try merged.serialized()
                }
                let root = try RubyMarshal.parse(bytes)
                let merged = try codec.encodeBinaryEventContainer(document, mergingInto: root)
                return try RubyMarshal.serialize(merged)
            })
    }
}

/// Thread-safe one-slot box carrying original file bytes from the bridge's
/// decode call to its encode call (the DTO intentionally holds no bytes).
final class OriginalBytesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    func set(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes = data
    }
    func get() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let bytes else { throw RPGCodecError.malformedArchive("encode before decode") }
        return bytes
    }
}

// MARK: - Tile map DTO translation

extension RPGMapDocument {
    /// Translates to the editor tile map DTO: one tile layer per z layer plus
    /// one object layer carrying the events.
    public func editableTileMap() throws -> EditableTileMap {
        let grid = engine.tileSize
        var layers: [EditableTileMap.Layer] = []
        for z in 0..<tileLayerCount {
            let tiles = tiles(z: z)
            layers.append(EditableTileMap.Layer(
                id: stableUUID(for: "tile-layer-\(z)"),
                name: "z\(z)", kind: .tile,
                size: .init(width: width, height: height),
                tiles: tiles, objects: [], visible: true))
        }
        let objects = events.map { event in
            EditableTileMap.TileMapObject(
                id: stableUUID(for: "event-\(event.id)"),
                name: event.name.isEmpty ? "Event \(event.id)" : event.name,
                x: Double(event.x * grid), y: Double(event.y * grid),
                width: Double(grid), height: Double(grid),
                properties: ["eventId": .number(Double(event.id))])
        }
        layers.append(EditableTileMap.Layer(
            id: stableUUID(for: "events-layer"),
            name: "events", kind: .object,
            size: .init(width: width, height: height),
            tiles: [], objects: objects, visible: true))
        return EditableTileMap(name: pathName, tileSize: .init(width: grid, height: grid),
                               layers: layers, tileSets: [])
    }

    /// Applies editor tile map edits back onto this document. Tile layers
    /// write per-cell through `setTile` (original container preserved); the
    /// object layer moves/creates events. Unknown layers are ignored.
    public mutating func applyEditableTileMap(_ tileMap: EditableTileMap) throws {
        for (z, layer) in tileMap.layers.enumerated() where layer.kind == .tile {
            guard z < tileLayerCount, layer.tiles.count == width * height else { continue }
            for y in 0..<height {
                for x in 0..<width {
                    let value = layer.tiles[y * width + x]
                    if value != tile(x: x, y: y, z: z) {
                        try setTile(value, x: x, y: y, z: z)
                    }
                }
            }
        }
        guard let objectLayer = tileMap.layers.first(where: { $0.kind == .object }) else { return }
        let grid = engine.tileSize
        let keptEventIDs = Set(objectLayer.objects.compactMap { $0.properties["eventId"]?.intValue })
        let removedEventIDs = events.map(\.id).filter { !keptEventIDs.contains($0) }
        for eventID in removedEventIDs {
            try removeEvent(id: eventID)
        }
        for object in objectLayer.objects {
            guard let eventID = object.properties["eventId"]?.intValue else { continue }
            let x = Int((object.x / Double(grid)).rounded())
            let y = Int((object.y / Double(grid)).rounded())
            if events.contains(where: { $0.id == eventID }) {
                try moveEvent(id: eventID, x: x, y: y)
            } else if json != nil {
                try upsertEvent(RPGMapEvent(id: eventID, name: object.name, x: x, y: y))
            } else {
                throw RPGCodecError.unsupportedData("new binary events require an RPG::Event template node; use upsertEvent")
            }
        }
    }

    /// Stable UUID derivation so repeated decodes produce identical DTOs.
    private func stableUUID(for key: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var index = 0
        for byte in stableEditorDigest(key)[0..<16] {
            bytes[index] = byte
            index += 1
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// All source bytes contribute to every UUID byte. Using just independent
/// hash lanes made neighboring layer/event/command identifiers collide.
func stableEditorDigest(_ string: String) -> [UInt8] {
    let hex = Array(GameDigest.sha256(Data(string.utf8)).utf8)
    func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
    return stride(from: 0, to: hex.count, by: 2).map { index in
        (nibble(hex[index]) << 4) | nibble(hex[index + 1])
    }
}
