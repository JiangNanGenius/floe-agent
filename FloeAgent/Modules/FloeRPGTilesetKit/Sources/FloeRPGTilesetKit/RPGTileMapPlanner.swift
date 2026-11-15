// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import FloeGameEditingCore
import FloeRPGCore

public struct RPGTileDrawCommand: Sendable {
    public var imagePath: String
    public var source: CGRect
    public var destination: CGRect
    public var tileID: Int
    public var sheet: RPGTileSheetKind
    public init(imagePath: String, source: CGRect, destination: CGRect,
                tileID: Int, sheet: RPGTileSheetKind) {
        self.imagePath = imagePath; self.source = source
        self.destination = destination; self.tileID = tileID; self.sheet = sheet
    }
}

public struct RPGRenderMarker: Sendable {
    public var rect: CGRect
    public var name: String
    public var eventID: Int?
    public init(rect: CGRect, name: String, eventID: Int? = nil) {
        self.rect = rect; self.name = name; self.eventID = eventID
    }
}

/// A render plan contains only the visible cells requested by the caller.
/// The UI can draw it directly; the rasterizer uses the same plan for PNG
/// evidence. Images are referenced by project-relative path, never borrowed
/// from another project or an RTP installation.
public struct RPGTileRenderPlan: Sendable {
    public var tileSize: Int
    public var mapSize: EditableTileMap.Size
    public var commands: [RPGTileDrawCommand]
    public var markers: [RPGRenderMarker]
    public var diagnostics: [RPGTileAssetDiagnostic]
    public var visibleCellRect: CGRect

    public var contentSize: CGSize {
        CGSize(width: CGFloat(mapSize.width * tileSize),
               height: CGFloat(mapSize.height * tileSize))
    }

    public init(tileSize: Int, mapSize: EditableTileMap.Size,
                commands: [RPGTileDrawCommand] = [], markers: [RPGRenderMarker] = [],
                diagnostics: [RPGTileAssetDiagnostic] = [],
                visibleCellRect: CGRect = .zero) {
        self.tileSize = tileSize; self.mapSize = mapSize
        self.commands = commands; self.markers = markers
        self.diagnostics = diagnostics; self.visibleCellRect = visibleCellRect
    }
}

public struct RPGTileMapPlanner: Sendable {
    public var map: EditableTileMap
    public var definition: RPGTilesetDefinition?
    public var presentation: RPGMapPresentation?
    public var geometry: RPGTileGeometry
    public var imageSizes: [String: CGSize]
    public var characterImageSizes: [String: CGSize]

    public init(map: EditableTileMap, definition: RPGTilesetDefinition?,
                presentation: RPGMapPresentation?, engine: RPGEngine,
                imageSizes: [String: CGSize] = [:],
                characterImageSizes: [String: CGSize] = [:]) {
        self.map = map; self.definition = definition; self.presentation = presentation
        self.geometry = RPGTileGeometry(engine: engine)
        self.imageSizes = imageSizes; self.characterImageSizes = characterImageSizes
    }

    /// `visibleCells` is in cell coordinates. Only cells intersecting it are
    /// resolved, so a 4096x4096 map never builds a full command list for a
    /// small viewport.
    public func plan(visibleCells: CGRect, animationFrame: Int = 0) -> RPGTileRenderPlan {
        let mapSize = map.mapSize
        let tileSize = geometry.tileSize
        let clampedCells = clampToMap(visibleCells, mapSize: mapSize)
        var plan = RPGTileRenderPlan(tileSize: tileSize, mapSize: mapSize,
                                     visibleCellRect: clampedCells)
        var diagnostics: [RPGTileAssetDiagnostic] = []
        var diagnosticKeys = Set<String>()
        func note(_ diagnostic: RPGTileAssetDiagnostic) {
            guard diagnostics.count < 200 else { return }
            if diagnosticKeys.insert(diagnostic.id).inserted { diagnostics.append(diagnostic) }
        }
        guard clampedCells.width > 0, clampedCells.height > 0 else {
            plan.diagnostics = diagnostics
            return plan
        }
        let xStart = max(0, Int(floor(clampedCells.minX)))
        let yStart = max(0, Int(floor(clampedCells.minY)))
        let xEnd = min(mapSize.width, max(0, Int(ceil(clampedCells.maxX))))
        let yEnd = min(mapSize.height, max(0, Int(ceil(clampedCells.maxY))))

        for layer in map.layers where layer.visible {
            switch layer.kind {
            case .tile:
                for y in yStart..<yEnd {
                    for x in xStart..<xEnd {
                        let gid = layer.tileAt(x: x, y: y)
                        guard gid > 0 else { continue }
                        let imageSize: CGSize? = {
                            guard let definition else { return nil }
                            guard let path = definition.imagePath(for: sheetForGID(gid)) else { return nil }
                            return imageSizes[path]
                        }()
                        let resolution = geometry.resolve(tileID: gid, imageSize: imageSize,
                                                          animationFrame: animationFrame)
                        if let diagnostic = resolution.diagnostic { note(diagnostic) }
                        guard let tile = resolution.tile else { continue }
                        let imagePath = definition?.imagePath(for: tile.sheet)
                            ?? "missing/\(sheetKey(tile.sheet))"
                        let cellRect = CGRect(x: CGFloat(x * tileSize), y: CGFloat(y * tileSize),
                                              width: CGFloat(tileSize), height: CGFloat(tileSize))
                        let destinations = RPGTileGeometry.destinationQuarters(for: cellRect,
                                                                               count: tile.sourceQuarters.count)
                        for (index, source) in tile.sourceQuarters.enumerated()
                        where destinations.indices.contains(index) {
                            plan.commands.append(RPGTileDrawCommand(
                                imagePath: imagePath, source: source,
                                destination: destinations[index], tileID: gid, sheet: tile.sheet))
                        }
                    }
                }
            case .object:
                for object in layer.objects {
                    let rect = CGRect(x: CGFloat(object.x), y: CGFloat(object.y),
                                      width: max(CGFloat(tileSize), CGFloat(object.width)),
                                      height: max(CGFloat(tileSize), CGFloat(object.height)))
                    guard rect.intersects(CGRect(x: clampedCells.minX * CGFloat(tileSize),
                                                 y: clampedCells.minY * CGFloat(tileSize),
                                                 width: clampedCells.width * CGFloat(tileSize),
                                                 height: clampedCells.height * CGFloat(tileSize))) else { continue }
                    let eventID = object.properties["eventId"]?.intValue
                    let graphic = eventID.flatMap { presentation?.events[$0] }
                    if let graphic, let imagePath = graphic.imagePath,
                       let size = characterImageSizes[imagePath],
                       let source = RPGCharacterSheetLayout(engine: geometry.engine).sourceRect(
                        characterIndex: graphic.characterIndex,
                        direction: graphic.direction,
                        pattern: graphic.pattern,
                        imageSize: size) {
                        let layout = RPGCharacterSheetLayout(engine: geometry.engine)
                        let destination = CGRect(
                            x: CGFloat(object.x),
                            y: CGFloat(object.y) + CGFloat(tileSize) - layout.frameSize.height,
                            width: layout.frameSize.width,
                            height: layout.frameSize.height)
                        plan.commands.append(RPGTileDrawCommand(
                            imagePath: imagePath, source: source, destination: destination,
                            tileID: eventID ?? 0, sheet: .character))
                    } else {
                        plan.markers.append(RPGRenderMarker(rect: rect, name: object.name,
                                                            eventID: eventID))
                    }
                }
            }
        }
        plan.diagnostics = diagnostics + (presentation?.diagnostics ?? [])
        return plan
    }

    public func sheetKey(_ sheet: RPGTileSheetKind) -> String {
        switch sheet {
        case .xpTileset: return "xp-tileset"
        case .xpAutotile(let index): return "xp-autotile-\(index)"
        case .section(let section): return section.rawValue
        case .character: return "character"
        }
    }

    public func sheetForGID(_ gid: Int) -> RPGTileSheetKind {
        if geometry.engine == .rpgMakerXP {
            if gid >= 384 { return .xpTileset }
            if gid >= 48 { return .xpAutotile(index: gid / 48 - 1) }
            return .xpTileset
        }
        if (1...1023).contains(gid) {
            let index = (gid - 1) / 256
            return .section([.b, .c, .d, .e][min(3, index)])
        }
        if (1536...1663).contains(gid) { return .section(.a5) }
        let kind = (gid - 2048) / 48
        switch kind {
        case 0..<16: return .section(.a1)
        case 16..<48: return .section(.a2)
        case 48..<80: return .section(.a3)
        default: return .section(.a4)
        }
    }

    /// Convenience for the full map (fixture/contact-sheet rendering). The
    /// view uses a viewport-limited rect instead.
    public func fullPlan(animationFrame: Int = 0) -> RPGTileRenderPlan {
        plan(visibleCells: CGRect(x: 0, y: 0, width: CGFloat(map.mapSize.width),
                                  height: CGFloat(map.mapSize.height)),
             animationFrame: animationFrame)
    }

    private func clampToMap(_ rect: CGRect, mapSize: EditableTileMap.Size) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let minX = max(0, rect.minX)
        let minY = max(0, rect.minY)
        let maxX = min(CGFloat(mapSize.width), rect.maxX)
        let maxY = min(CGFloat(mapSize.height), rect.maxY)
        guard maxX > minX, maxY > minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
