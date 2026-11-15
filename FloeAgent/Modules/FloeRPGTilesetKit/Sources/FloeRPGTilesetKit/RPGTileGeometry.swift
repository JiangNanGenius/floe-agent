// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import FloeGameCore
import FloeRPGCore

/// One resolved tile: an image sheet plus the source rectangle(s) to draw.
/// Ordinary tiles have one source rectangle; autotiles have four (TL, TR, BL,
/// BR destination quarters). Source rectangles are in image pixels.
public struct RPGResolvedTile: Sendable {
    public var sheet: RPGTileSheetKind
    public var sourceQuarters: [CGRect]
    public var tileSize: Int
    public var isAutotile: Bool
    public var autotileKind: Int?
    public var autotileShape: Int?
    public var animationFrame: Int
    public var animationFrames: Int

    public init(sheet: RPGTileSheetKind, sourceQuarters: [CGRect], tileSize: Int,
                isAutotile: Bool, autotileKind: Int? = nil, autotileShape: Int? = nil,
                animationFrame: Int = 0, animationFrames: Int = 1) {
        self.sheet = sheet; self.sourceQuarters = sourceQuarters; self.tileSize = tileSize
        self.isAutotile = isAutotile; self.autotileKind = autotileKind
        self.autotileShape = autotileShape; self.animationFrame = animationFrame
        self.animationFrames = animationFrames
    }
}

public struct RPGTileResolution: Sendable {
    public var tile: RPGResolvedTile?
    public var diagnostic: RPGTileAssetDiagnostic?
    public init(tile: RPGResolvedTile?, diagnostic: RPGTileAssetDiagnostic? = nil) {
        self.tile = tile; self.diagnostic = diagnostic
    }
}

/// Pure, engine-specific source geometry. It uses factual sheet dimensions
/// and the permitted MIT/Apache quarter tables in RPGAutotileTables.swift.
/// It never decodes or mutates an image.
public struct RPGTileGeometry: Sendable {
    public let engine: RPGEngine
    public let tileSize: Int

    public init(engine: RPGEngine) {
        self.engine = engine
        self.tileSize = engine.tileSize
    }

    public var half: Int { max(1, tileSize / 2) }

    /// Resolves a map/database tile id. `imageSize` is optional so a missing
    /// image can still be represented honestly by the editor; when supplied,
    /// every source rect must fit inside the image.
    public func resolve(tileID: Int, imageSize: CGSize? = nil,
                        animationFrame: Int = 0) -> RPGTileResolution {
        guard tileID > 0 else { return RPGTileResolution(tile: nil) }
        if engine == .rpgMakerXP {
            return resolveXP(tileID: tileID, imageSize: imageSize, animationFrame: animationFrame)
        }
        return resolveVXAceFamily(tileID: tileID, imageSize: imageSize, animationFrame: animationFrame)
    }

    /// Source rectangle for one ordinary sheet cell.
    public func ordinaryRect(sheet: RPGTileSheetKind, localIndex: Int) -> CGRect? {
        switch sheet {
        case .xpTileset:
            guard localIndex >= 0 else { return nil }
            let column = localIndex % 8
            let row = localIndex / 8
            return CGRect(x: CGFloat(column * tileSize), y: CGFloat(row * tileSize),
                          width: CGFloat(tileSize), height: CGFloat(tileSize))
        case .xpAutotile, .character:
            return nil
        case .section(let section):
            switch section {
            case .a5:
                guard localIndex >= 0, localIndex < 128 else { return nil }
                let column = localIndex % 8
                let row = localIndex / 8
                return CGRect(x: CGFloat(column * tileSize), y: CGFloat(row * tileSize),
                              width: CGFloat(tileSize), height: CGFloat(tileSize))
            case .b, .c, .d, .e:
                guard localIndex >= 0, localIndex < 256 else { return nil }
                let column = localIndex % 16
                let row = localIndex / 16
                return CGRect(x: CGFloat(column * tileSize), y: CGFloat(row * tileSize),
                              width: CGFloat(tileSize), height: CGFloat(tileSize))
            case .a1, .a2, .a3, .a4:
                return nil
            }
        }
    }

    // MARK: XP

    private func resolveXP(tileID: Int, imageSize: CGSize?, animationFrame: Int) -> RPGTileResolution {
        if tileID >= 384 {
            guard let rect = ordinaryRect(sheet: .xpTileset, localIndex: tileID - 384) else {
                return unsupported(tileID: tileID, reason: "XP ordinary tile index is out of range.")
            }
            if let imageSize, !fits(rect, in: imageSize) {
                return outOfBounds(tileID: tileID, sheet: .xpTileset, imageSize: imageSize)
            }
            return RPGTileResolution(tile: RPGResolvedTile(
                sheet: .xpTileset, sourceQuarters: [rect], tileSize: tileSize,
                isAutotile: false))
        }
        guard tileID >= 48 else {
            // XP reserves 1..47 as blank/invalid ids in map data.
            return RPGTileResolution(tile: nil)
        }
        let autotileIndex = tileID / 48 - 1
        let shape = tileID % 48
        guard autotileIndex >= 0, autotileIndex < 7 else {
            return unsupported(tileID: tileID, reason: "XP autotile index is outside the seven standard autotiles.")
        }
        guard shape < RPGAutotileTables.xp[0].count else {
            return unsupported(tileID: tileID, reason: "XP autotile shape is out of range.")
        }
        var quarters: [CGRect] = []
        for quadrant in 0..<4 {
            let sourceIndex = RPGAutotileTables.xp[quadrant][shape]
            let rect = CGRect(x: CGFloat((sourceIndex % 6) * 16),
                              y: CGFloat((sourceIndex / 6) * 16),
                              width: 16, height: 16)
            if let imageSize, !fits(rect, in: imageSize) {
                return outOfBounds(tileID: tileID, sheet: .xpAutotile(index: autotileIndex),
                                   imageSize: imageSize)
            }
            quarters.append(rect)
        }
        // XP's 96x128 sheet mixes the 6x8 quarter layout used by the 48
        // shapes with the animation strip. The permissive Tapir reference uses
        // the full table as a stable representative pattern; no horizontal
        // frame shift is applied. The editor reports that animation is not
        // interpolated for XP instead of silently choosing wrong quarters.
        return RPGTileResolution(tile: RPGResolvedTile(
            sheet: .xpAutotile(index: autotileIndex), sourceQuarters: quarters,
            tileSize: tileSize, isAutotile: true, autotileKind: autotileIndex,
            autotileShape: shape, animationFrame: 0, animationFrames: 1))
    }

    // MARK: VX / Ace / MV / MZ

    private func resolveVXAceFamily(tileID: Int, imageSize: CGSize?, animationFrame: Int) -> RPGTileResolution {
        if tileID >= 1 && tileID <= 1023 {
            let sectionIndex = (tileID - 1) / 256
            let sections: [RPGTilesetSection] = [.b, .c, .d, .e]
            let section = sections[min(3, max(0, sectionIndex))]
            let local = (tileID - 1) % 256
            guard let rect = ordinaryRect(sheet: .section(section), localIndex: local) else {
                return unsupported(tileID: tileID, reason: "Ordinary tile index is out of range.")
            }
            if let imageSize, !fits(rect, in: imageSize) {
                return outOfBounds(tileID: tileID, sheet: .section(section), imageSize: imageSize)
            }
            return RPGTileResolution(tile: RPGResolvedTile(
                sheet: .section(section), sourceQuarters: [rect], tileSize: tileSize,
                isAutotile: false))
        }
        if tileID >= 1536 && tileID <= 1663 {
            let local = tileID - 1536
            guard let rect = ordinaryRect(sheet: .section(.a5), localIndex: local) else {
                return unsupported(tileID: tileID, reason: "A5 tile index is out of range.")
            }
            if let imageSize, !fits(rect, in: imageSize) {
                return outOfBounds(tileID: tileID, sheet: .section(.a5), imageSize: imageSize)
            }
            return RPGTileResolution(tile: RPGResolvedTile(
                sheet: .section(.a5), sourceQuarters: [rect], tileSize: tileSize,
                isAutotile: false))
        }
        guard tileID >= 2048 else {
            return unsupported(tileID: tileID, reason: "Tile id is outside the standard RPG Maker A/B..E ranges.")
        }
        let kind = (tileID - 2048) / 48
        let shape = (tileID - 2048) % 48
        guard kind >= 0, kind < 128 else {
            return unsupported(tileID: tileID, reason: "Autotile kind is outside the standard 0..127 range.")
        }
        let placement = autotilePlacement(kind: kind, animationFrame: animationFrame)
        guard let placement else {
            return unsupported(tileID: tileID, reason: "Autotile kind is not valid for this engine.")
        }
        guard shape < placement.table.count else {
            return unsupported(tileID: tileID,
                               reason: "Autotile shape \(shape) is not defined for \(placement.section.rawValue.uppercased()) in this engine.")
        }
        var quarters: [CGRect] = []
        for quadrant in 0..<4 {
            let pair = placement.table[shape][quadrant]
            let qsx = pair.0
            let qsy = pair.1
            let rect = CGRect(x: CGFloat((placement.originX * 2 + qsx) * half),
                              y: CGFloat((placement.originY * 2 + qsy) * half),
                              width: CGFloat(half), height: CGFloat(half))
            if let imageSize, !fits(rect, in: imageSize) {
                return outOfBounds(tileID: tileID, sheet: .section(placement.section),
                                   imageSize: imageSize)
            }
            quarters.append(rect)
        }
        return RPGTileResolution(tile: RPGResolvedTile(
            sheet: .section(placement.section), sourceQuarters: quarters,
            tileSize: tileSize, isAutotile: true, autotileKind: kind,
            autotileShape: shape, animationFrame: animationFrame,
            animationFrames: placement.animationFrames))
    }

    private struct AutotilePlacement {
        var section: RPGTilesetSection
        /// In tiles (32 or 48 px cells).
        var originX: Int
        var originY: Int
        var table: [[(Int, Int)]]
        var animationFrames: Int
    }

    private func autotilePlacement(kind: Int, animationFrame: Int) -> AutotilePlacement? {
        let isMV = engine == .rpgMakerMV || engine == .rpgMakerMZ
        if kind < 16 {
            // A1: animated water/waterfall block.
            if isMV {
                let waterSurfaceFrame = [0, 1, 2, 1][max(0, animationFrame) % 4]
                let waterfallFrame = max(0, animationFrame) % 3
                var bx = 0
                var by = 0
                var table = RPGAutotileTables.floor
                let tx = kind % 8
                let ty = kind / 8
                switch kind {
                case 0:
                    bx = waterSurfaceFrame * 2
                case 1:
                    bx = waterSurfaceFrame * 2
                    by = 3
                case 2:
                    bx = 6
                case 3:
                    bx = 6
                    by = 3
                default:
                    bx = (tx / 4) * 8
                    by = ty * 6 + ((tx / 2) % 2) * 3
                    if kind % 2 == 0 {
                        bx += waterSurfaceFrame * 2
                    } else {
                        bx += 6
                        table = RPGAutotileTables.waterfall
                        by += waterfallFrame
                    }
                }
                return AutotilePlacement(section: .a1, originX: bx, originY: by,
                                         table: table, animationFrames: 3)
            }
            // VX/Ace A1 placement follows the permissive Tapir lookup. Stable
            // representative frame: no silent claim of full waterfall animation.
            var id = kind
            if id == 1 || id == 2 { id ^= 3 }
            let id0 = id % 2
            let id1 = (id / 2) % 2
            let id2 = (id / 4) % 2
            let id3 = id / 8
            let frame = max(0, animationFrame) % 3
            let bx = id2 * 8 + (id0 == 0 ? frame * 2 : 6)
            let by = (id1 + id3 * 2) * 3
            return AutotilePlacement(section: .a1, originX: bx, originY: by,
                                     table: RPGAutotileTables.floor, animationFrames: 3)
        }
        if kind < 48 {
            let tx = kind % 8
            let ty = kind / 8 - 2
            return AutotilePlacement(section: .a2, originX: tx * 2, originY: ty * 3,
                                     table: RPGAutotileTables.floor, animationFrames: 1)
        }
        if kind < 80 {
            let tx = kind % 8
            let ty = kind / 8 - 6
            return AutotilePlacement(section: .a3, originX: tx * 2, originY: ty * 2,
                                     table: RPGAutotileTables.wall, animationFrames: 1)
        }
        guard kind < 128 else { return nil }
        let tx = kind % 8
        let ty = kind / 8 // 10...15
        let wall = ty % 2 == 1
        let by = Int(floor(Double((ty - 10) * 5) / 2.0 + (wall ? 0.5 : 0)))
        return AutotilePlacement(section: .a4, originX: tx * 2, originY: by,
                                 table: wall ? RPGAutotileTables.wall : RPGAutotileTables.floor,
                                 animationFrames: 1)
    }

    private func fits(_ rect: CGRect, in imageSize: CGSize) -> Bool {
        rect.minX >= 0 && rect.minY >= 0 &&
        rect.maxX <= imageSize.width + 0.0001 &&
        rect.maxY <= imageSize.height + 0.0001
    }

    private func unsupported(tileID: Int, reason: String) -> RPGTileResolution {
        RPGTileResolution(tile: nil, diagnostic: .init(
            code: "tileset.tile.unsupported", severity: .warning,
            messageEN: "Tile \(tileID) cannot be drawn: \(reason)",
            messageZH: "图块 \(tileID) 无法绘制：\(reason)"))
    }

    private func outOfBounds(tileID: Int, sheet: RPGTileSheetKind, imageSize: CGSize) -> RPGTileResolution {
        let name: String
        switch sheet {
        case .xpTileset: name = "Graphics/Tilesets"
        case .xpAutotile(let index): name = "XP autotile \(index + 1)"
        case .section(let section): name = section.rawValue.uppercased()
        case .character: name = "character sheet"
        }
        return RPGTileResolution(tile: nil, diagnostic: .init(
            code: "tileset.tile.outOfBounds", severity: .warning,
            messageEN: "Tile \(tileID) lies outside \(name) (\(Int(imageSize.width))x\(Int(imageSize.height))). The map value is kept.",
            messageZH: "图块 \(tileID) 超出 \(name) 的图片范围（\(Int(imageSize.width))x\(Int(imageSize.height))），地图数据会保留。"))
    }

    /// Destination quarter rectangles for a tile cell, in the same order as
    /// `RPGResolvedTile.sourceQuarters`.
    public static func destinationQuarters(for rect: CGRect, count: Int) -> [CGRect] {
        guard count == 4 else { return [rect] }
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        return [
            CGRect(x: rect.minX, y: rect.minY, width: halfWidth, height: halfHeight),
            CGRect(x: rect.midX, y: rect.minY, width: halfWidth, height: halfHeight),
            CGRect(x: rect.minX, y: rect.midY, width: halfWidth, height: halfHeight),
            CGRect(x: rect.midX, y: rect.midY, width: halfWidth, height: halfHeight)
        ]
    }
}
