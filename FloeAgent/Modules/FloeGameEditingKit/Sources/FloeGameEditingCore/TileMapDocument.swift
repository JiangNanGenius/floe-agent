// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Editor-owned 2D tile map DTO. Engine adapters translate to/from native
/// engine formats; without an adapter this DTO persists as a clearly
/// namespaced editor staging document (see `stagingFileName`).
public struct EditableTileMap: Codable, Hashable, Sendable {
    public static let stagingFormatName = "floe-editing-tilemap"
    public static let stagingFormatVersion = 1

    public struct Size: Codable, Hashable, Sendable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width; self.height = height
        }
        public var isValid: Bool { width > 0 && height > 0 && width <= 4_096 && height <= 4_096 }
    }

    public struct TileSet: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var imagePath: GameRelativePath
        /// First global tile id served by this tileset; 0 always means empty.
        public var firstGID: Int
        public init(id: UUID = UUID(), imagePath: GameRelativePath, firstGID: Int) {
            self.id = id; self.imagePath = imagePath; self.firstGID = firstGID
        }
    }

    public enum LayerKind: String, Codable, Sendable {
        case tile
        case object
    }

    public struct Layer: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var kind: LayerKind
        public var size: Size
        /// Row-major tile GIDs for kind == .tile; 0 = empty. Ignored for object layers.
        public var tiles: [Int]
        public var objects: [TileMapObject]
        public var visible: Bool
        public init(id: UUID = UUID(), name: String, kind: LayerKind, size: Size,
                    tiles: [Int]? = nil, objects: [TileMapObject] = [], visible: Bool = true) {
            self.id = id; self.name = name; self.kind = kind; self.size = size
            self.tiles = tiles ?? Array(repeating: 0, count: size.width * size.height)
            self.objects = objects; self.visible = visible
        }
        public func tileIndex(x: Int, y: Int) -> Int? {
            guard x >= 0, y >= 0, x < size.width, y < size.height else { return nil }
            return y * size.width + x
        }
        public func tileAt(x: Int, y: Int) -> Int {
            guard let index = tileIndex(x: x, y: y), index < tiles.count else { return 0 }
            return tiles[index]
        }
    }

    public struct TileMapObject: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        /// Pixel coordinates in map space.
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var properties: [String: JSONValue]
        public init(id: UUID = UUID(), name: String, x: Double, y: Double,
                    width: Double, height: Double, properties: [String: JSONValue] = [:]) {
            self.id = id; self.name = name; self.x = x; self.y = y
            self.width = width; self.height = height; self.properties = properties
        }
    }

    public struct Selection: Codable, Hashable, Sendable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var isEmpty: Bool { width <= 0 || height <= 0 }
    }

    public var format: String
    public var formatVersion: Int
    public var name: String
    public var tileSize: Size
    public var layers: [Layer]
    public var tileSets: [TileSet]

    public init(name: String, tileSize: Size, layers: [Layer] = [], tileSets: [TileSet] = []) {
        self.format = Self.stagingFormatName
        self.formatVersion = Self.stagingFormatVersion
        self.name = name
        self.tileSize = tileSize
        self.layers = layers
        self.tileSets = tileSets
    }

    public var stagingFileName: String { name + ".floetilemap.json" }

    public func layer(id: UUID) -> Layer? { layers.first(where: { $0.id == id }) }

    /// Resolve a GID to its tileset (highest firstGID <= gid wins).
    public func tileSet(forGID gid: Int) -> TileSet? {
        guard gid > 0 else { return nil }
        return tileSets.filter { $0.firstGID <= gid }.max(by: { $0.firstGID < $1.firstGID })
    }

    // MARK: - Tile edits (pure; undo handled by the session)

    public func painting(gid: Int, atX x: Int, y: Int, layerID: UUID) -> EditableTileMap {
        var copy = self
        guard var layer = copy.layer(id: layerID), layer.kind == .tile,
              let index = layer.tileIndex(x: x, y: y) else { return self }
        guard index < layer.tiles.count else { return self }
        layer.tiles[index] = max(0, gid)
        copy.replace(layer)
        return copy
    }

    /// Bresenham line painting for drag strokes.
    public func paintingStroke(gid: Int, from start: (x: Int, y: Int), to end: (x: Int, y: Int),
                               layerID: UUID) -> EditableTileMap {
        var result = self
        let startX: Int = start.x
        let startY: Int = start.y
        let endX: Int = end.x
        let endY: Int = end.y
        let dx: Int = abs(endX - startX)
        let dy: Int = -abs(endY - startY)
        let sx: Int = startX < endX ? 1 : -1
        let sy: Int = startY < endY ? 1 : -1
        var error: Int = dx + dy
        var x: Int = startX
        var y: Int = startY
        while true {
            result = result.painting(gid: gid, atX: x, y: y, layerID: layerID)
            if x == endX && y == endY { break }
            let twice = 2 * error
            if twice >= dy { error += dy; x += sx }
            if twice <= dx { error += dx; y += sy }
        }
        return result
    }

    /// 4-way flood fill. Filling with gid 0 behaves as erase-fill.
    public func filling(gid: Int, fromX x: Int, y: Int, layerID: UUID) -> EditableTileMap {
        guard var layer = self.layer(id: layerID), layer.kind == .tile,
              let start = layer.tileIndex(x: x, y: y) else { return self }
        let target = layer.tiles[start]
        guard target != gid else { return self }
        var copy = self
        var stack = [(x, y)]
        var visited = Set<Int>()
        while let (cx, cy) = stack.popLast() {
            guard let index = layer.tileIndex(x: cx, y: cy), !visited.contains(index) else { continue }
            visited.insert(index)
            guard layer.tiles[index] == target else { continue }
            layer.tiles[index] = max(0, gid)
            stack.append((cx + 1, cy)); stack.append((cx - 1, cy))
            stack.append((cx, cy + 1)); stack.append((cx, cy - 1))
        }
        copy.replace(layer)
        return copy
    }

    // MARK: - Object edits

    public func placingObject(_ object: TileMapObject, layerID: UUID) -> EditableTileMap {
        var copy = self
        guard var layer = copy.layer(id: layerID), layer.kind == .object else { return self }
        layer.objects.removeAll { $0.id == object.id }
        layer.objects.append(object)
        layer.objects.sort { $0.name < $1.name }
        copy.replace(layer)
        return copy
    }

    public func movingObject(id: UUID, toX x: Double, y: Double, layerID: UUID) -> EditableTileMap {
        var copy = self
        guard var layer = copy.layer(id: layerID), let index = layer.objects.firstIndex(where: { $0.id == id }) else {
            return self
        }
        layer.objects[index].x = x
        layer.objects[index].y = y
        copy.replace(layer)
        return copy
    }

    public func deletingObject(id: UUID, layerID: UUID) -> EditableTileMap {
        var copy = self
        guard var layer = copy.layer(id: layerID) else { return self }
        layer.objects.removeAll { $0.id == id }
        copy.replace(layer)
        return copy
    }

    // MARK: - Layers

    public func addingLayer(name: String, kind: LayerKind) -> EditableTileMap {
        var copy = self
        copy.layers.append(Layer(name: name, kind: kind, size: mapSize))
        return copy
    }

    public func removingLayer(id: UUID) -> EditableTileMap {
        var copy = self
        copy.layers.removeAll { $0.id == id }
        return copy
    }

    public func movingLayer(id: UUID, toIndex destination: Int) -> EditableTileMap {
        guard let source = layers.firstIndex(where: { $0.id == id }) else { return self }
        let clamped = min(max(0, destination), layers.count - 1)
        var copy = self
        let layer = copy.layers.remove(at: source)
        copy.layers.insert(layer, at: clamped)
        return copy
    }

    /// Layers must agree on size for a coherent map.
    public var mapSize: Size {
        layers.first?.size ?? Size(width: 20, height: 15)
    }

    mutating func replace(_ layer: Layer) {
        guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        layers[index] = layer
    }

    // MARK: - Snapping / geometry

    public func snapped(_ coordinate: Double, enabled: Bool) -> Double {
        guard enabled else { return coordinate }
        let step = Double(max(1, tileSize.width))
        return (coordinate / step).rounded() * step
    }

    public func cellRect(for selection: Selection) -> (x: Int, y: Int, width: Int, height: Int) {
        let x = max(0, min(selection.x, selection.x + selection.width - (selection.width > 0 ? 1 : 0)))
        let y = max(0, min(selection.y, selection.y + selection.height - (selection.height > 0 ? 1 : 0)))
        let width = abs(selection.width), height = abs(selection.height)
        return (x, y, max(1, width), max(1, height))
    }

    // MARK: - Serialization

    public static func decode(_ bytes: Data) throws -> EditableTileMap {
        guard let root = try? JSONValue.parse(bytes),
              root["format"]?.stringValue == stagingFormatName else {
            throw GameProjectError.invalidManifest("tilemap.format")
        }
        guard root["formatVersion"]?.intValue == stagingFormatVersion else {
            throw GameProjectError.invalidManifest("tilemap.formatVersion")
        }
        let data: Data
        do { data = try root.serialized() } catch { throw GameProjectError.invalidManifest("tilemap.json") }
        let decoder = JSONDecoder()
        guard let map = try? decoder.decode(EditableTileMap.self, from: data) else {
            throw GameProjectError.invalidManifest("tilemap.decode")
        }
        guard map.tileSize.isValid else { throw GameProjectError.invalidManifest("tilemap.size") }
        for layer in map.layers where !layer.size.isValid || layer.tiles.count != layer.size.width * layer.size.height {
            throw GameProjectError.invalidManifest("tilemap.layer")
        }
        return map
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { throw GameProjectError.invalidEdit }
        // Guard the round-trip before handing bytes to the session.
        _ = try EditableTileMap.decode(data)
        return data
    }
}

/// A single undoable tile-map editor action. The UI commits these through
/// `EditableTileMap.apply(_:)`, a mutating call, so a returned value can never
/// be dropped by accident.
public enum TileMapEditorCommand: Sendable {
    case paint(gid: Int, x: Int, y: Int, layerID: UUID)
    case fill(gid: Int, fromX: Int, fromY: Int, layerID: UUID)
    case placeObject(EditableTileMap.TileMapObject, layerID: UUID)
    case moveObject(id: UUID, x: Double, y: Double, layerID: UUID)
    case deleteObject(id: UUID, layerID: UUID)
    case addLayer(name: String, kind: EditableTileMap.LayerKind)
    case removeLayer(id: UUID)
    case moveLayer(id: UUID, toIndex: Int)
    /// Replace full layer content (used to replay previewed strokes/layer edits).
    case replaceLayers([EditableTileMap.Layer])
}

extension EditableTileMap {
    public func applying(_ command: TileMapEditorCommand) -> EditableTileMap {
        switch command {
        case .paint(let gid, let x, let y, let layerID):
            return painting(gid: gid, atX: x, y: y, layerID: layerID)
        case .fill(let gid, let x, let y, let layerID):
            return filling(gid: gid, fromX: x, y: y, layerID: layerID)
        case .placeObject(let object, let layerID):
            return placingObject(object, layerID: layerID)
        case .moveObject(let id, let x, let y, let layerID):
            return movingObject(id: id, toX: x, y: y, layerID: layerID)
        case .deleteObject(let id, let layerID):
            return deletingObject(id: id, layerID: layerID)
        case .addLayer(let name, let kind):
            return addingLayer(name: name, kind: kind)
        case .removeLayer(let id):
            return removingLayer(id: id)
        case .moveLayer(let id, let index):
            return movingLayer(id: id, toIndex: index)
        case .replaceLayers(let layers):
            var copy = self
            copy.layers = layers
            return copy
        }
    }

    /// Mutating application: `map.apply(.fill(...))` cannot lose the result.
    public mutating func apply(_ command: TileMapEditorCommand) {
        self = applying(command)
    }
}
