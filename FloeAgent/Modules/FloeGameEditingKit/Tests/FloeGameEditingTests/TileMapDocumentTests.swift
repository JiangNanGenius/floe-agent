// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameEditingCore

@Suite("Tile map documents")
struct TileMapDocumentTests {
    func makeMap() -> EditableTileMap {
        EditableTileMap(name: "test", tileSize: .init(width: 16, height: 16),
                        layers: [.init(name: "Ground", kind: .tile, size: .init(width: 4, height: 4)),
                                 .init(name: "Objects", kind: .object, size: .init(width: 4, height: 4))],
                        tileSets: [.init(imagePath: try! GameRelativePath("assets/tiles.png"), firstGID: 1)])
    }

    @Test("Paint, erase and stroke write the right cells")
    @MainActor
    func painting() async throws {
        let map = makeMap()
        let layer = map.layers[0].id
        var edited = map.painting(gid: 1, atX: 1, y: 1, layerID: layer)
        edited = edited.painting(gid: 2, atX: 2, y: 2, layerID: layer)
        #expect(edited.layers[0].tileAt(x: 1, y: 1) == 1)
        #expect(edited.layers[0].tileAt(x: 2, y: 2) == 2)
        edited = edited.painting(gid: 0, atX: 1, y: 1, layerID: layer)
        #expect(edited.layers[0].tileAt(x: 1, y: 1) == 0)
        // Out-of-bounds writes are ignored.
        #expect(edited.painting(gid: 5, atX: -1, y: 0, layerID: layer) == edited)
        // Stroke connects diagonal points with a continuous line.
        let stroked = map.paintingStroke(gid: 3, from: (0, 0), to: (3, 3), layerID: layer)
        #expect(stroked.layers[0].tileAt(x: 0, y: 0) == 3)
        #expect(stroked.layers[0].tileAt(x: 3, y: 3) == 3)
        #expect(stroked.layers[0].tiles.filter { $0 == 3 }.count >= 4)
    }

    @Test("Flood fill respects boundaries and erase-fill clears regions")
    @MainActor
    func fill() async throws {
        let map = makeMap()
        let layer = map.layers[0].id
        // Wall at y=2 separating two regions.
        var walled = map
        for x in 0..<4 { walled = walled.painting(gid: 9, atX: x, y: 2, layerID: layer) }
        let filled = walled.filling(gid: 4, fromX: 0, y: 0, layerID: layer)
        #expect(filled.layers[0].tileAt(x: 0, y: 0) == 4)
        #expect(filled.layers[0].tileAt(x: 3, y: 1) == 4)
        #expect(filled.layers[0].tileAt(x: 0, y: 3) == 0) // other side of the wall
        #expect(filled.layers[0].tileAt(x: 0, y: 2) == 9) // wall untouched
        let erased = filled.filling(gid: 0, fromX: 0, y: 0, layerID: layer)
        #expect(erased.layers[0].tiles.filter { $0 == 4 }.isEmpty)
        // Fill with same gid is a no-op.
        #expect(filled.filling(gid: 4, fromX: 0, y: 0, layerID: layer) == filled)
    }

    @Test("Object placement, move and delete")
    @MainActor
    func objects() async throws {
        let map = makeMap()
        let layer = map.layers[1].id
        let spawn = EditableTileMap.TileMapObject(name: "spawn", x: 10, y: 20, width: 16, height: 16)
        var edited = map.placingObject(spawn, layerID: layer)
        #expect(edited.layers[1].objects.count == 1)
        edited = edited.movingObject(id: spawn.id, toX: 40, y: 50, layerID: layer)
        #expect(edited.layers[1].objects.first?.x == 40)
        edited = edited.deletingObject(id: spawn.id, layerID: layer)
        #expect(edited.layers[1].objects.isEmpty)
        // Placing never duplicates an id.
        edited = edited.placingObject(spawn, layerID: layer)
        edited = edited.placingObject(spawn, layerID: layer)
        #expect(edited.layers[1].objects.count == 1)
    }

    @Test("Layer add, remove, reorder")
    @MainActor
    func layers() async throws {
        let map = makeMap()
        var edited = map.addingLayer(name: "Above", kind: .tile)
        #expect(edited.layers.count == 3)
        let above = edited.layers[2]
        edited = edited.movingLayer(id: above.id, toIndex: 0)
        #expect(edited.layers[0].name == "Above")
        edited = edited.removingLayer(id: above.id)
        #expect(edited.layers.count == 2)
        #expect(edited.layers[0].name == "Ground")
    }

    @Test("Selection normalization and snapping")
    @MainActor
    func geometry() async throws {
        let map = makeMap()
        let selection = EditableTileMap.Selection(x: 3, y: 3, width: -3, height: -2)
        let rect = map.cellRect(for: selection)
        #expect(rect.x == 0 || rect.x == 3 - 3) // normalized to a real cell range
        #expect(rect.width == 3)
        #expect(rect.height == 2)
        #expect(map.snapped(37.0, enabled: true) == 32.0)
        #expect(map.snapped(41.0, enabled: true) == 48.0)
        #expect(map.snapped(37.0, enabled: false) == 37.0)
        #expect(map.tileSet(forGID: 1)?.firstGID == 1)
        #expect(map.tileSet(forGID: 0) == nil)
    }

    @Test("Serialization round-trips byte-stably and rejects foreign formats")
    @MainActor
    func serialization() async throws {
        let map = makeMap()
        let bytes = try map.encode()
        let reopened = try EditableTileMap.decode(bytes)
        #expect(reopened == map)
        #expect(try reopened.encode() == bytes)
        do {
            _ = try EditableTileMap.decode(Data("{\"format\":\"other\"}".utf8))
            Issue.record("Foreign format must be rejected")
        } catch {}
    }
}

@Suite("Tile map editor command path")
struct TileMapCommandTests {
    func makeMap() -> EditableTileMap {
        EditableTileMap(name: "cmd", tileSize: .init(width: 16, height: 16),
                        layers: [.init(name: "Ground", kind: .tile, size: .init(width: 4, height: 4)),
                                 .init(name: "Objects", kind: .object, size: .init(width: 4, height: 4))],
                        tileSets: [.init(imagePath: try! GameRelativePath("assets/tiles.png"), firstGID: 1)])
    }

    @Test("Editor commands mutate the map through the same path the UI commits")
    @MainActor
    func commandsMutate() async throws {
        var map = makeMap()
        let ground = map.layers[0].id
        let objects = map.layers[1].id

        map.apply(.fill(gid: 5, fromX: 0, fromY: 0, layerID: ground))
        #expect(map.layers[0].tiles.allSatisfy { $0 == 5 })

        map.apply(.paint(gid: 0, x: 0, y: 0, layerID: ground))
        #expect(map.layers[0].tileAt(x: 0, y: 0) == 0)
        #expect(map.layers[0].tileAt(x: 1, y: 1) == 5)

        let chest = EditableTileMap.TileMapObject(name: "chest", x: 0, y: 0, width: 16, height: 16)
        map.apply(.placeObject(chest, layerID: objects))
        #expect(map.layers[1].objects.count == 1)
        map.apply(.moveObject(id: chest.id, x: 32, y: 32, layerID: objects))
        #expect(map.layers[1].objects.first?.x == 32)
        map.apply(.deleteObject(id: chest.id, layerID: objects))
        #expect(map.layers[1].objects.isEmpty)

        map.apply(.addLayer(name: "Above", kind: .tile))
        #expect(map.layers.count == 3)
        let above = map.layers[2].id
        map.apply(.moveLayer(id: above, toIndex: 0))
        #expect(map.layers[0].name == "Above")
        map.apply(.removeLayer(id: above))
        #expect(map.layers.count == 2)

        // The UI also commits previewed strokes as replaced layers.
        let preview = map.paintingStroke(gid: 3, from: (0, 0), to: (3, 3), layerID: ground)
        map.apply(.replaceLayers(preview.layers))
        #expect(map.layers[0].tileAt(x: 3, y: 3) == 3)

        // Persisted bytes round-trip the command edits.
        let reopened = try EditableTileMap.decode(try map.encode())
        #expect(reopened == map)
    }
}
