// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import FloeRPGCore

public struct RPGTilePaletteItem: Identifiable, Sendable {
    public var id: String
    public var gid: Int
    public var sheet: RPGTileSheetKind
    public var sourceQuarters: [CGRect]
    public var titleEN: String
    public var titleZH: String
    public var sectionID: String
    public var autotileKind: Int?
    public var autotileShape: Int?

    public var isAutotile: Bool { autotileKind != nil }
}

public struct RPGTilePaletteSection: Identifiable, Sendable {
    public var id: String
    public var titleEN: String
    public var titleZH: String
    public var sheet: RPGTileSheetKind
    public var items: [RPGTilePaletteItem]
}

public struct RPGTilePalette: Sendable {
    public var sections: [RPGTilePaletteSection]
    public var diagnostics: [RPGTileAssetDiagnostic]
    public var engine: RPGEngine
    public var definition: RPGTilesetDefinition?
    public var imageSizes: [String: CGSize]

    public init(sections: [RPGTilePaletteSection],
                diagnostics: [RPGTileAssetDiagnostic] = [],
                engine: RPGEngine = .rpgMakerMV,
                definition: RPGTilesetDefinition? = nil,
                imageSizes: [String: CGSize] = [:]) {
        self.sections = sections; self.diagnostics = diagnostics
        self.engine = engine; self.definition = definition; self.imageSizes = imageSizes
    }

    public func section(id: String) -> RPGTilePaletteSection? {
        sections.first(where: { $0.id == id })
    }

    /// All shape variants for an autotile kind. Used only in the opened
    /// details sheet, never as the primary palette list.
    public func shapeVariants(for item: RPGTilePaletteItem) -> [RPGTilePaletteItem] {
        guard let kind = item.autotileKind else { return [item] }
        let shapeCount: Int
        switch item.sheet {
        case .section(.a3): shapeCount = 16
        case .section(.a4):
            let ty = kind / 8
            shapeCount = ty % 2 == 1 ? 16 : 48
        case .section(.a1):
            shapeCount = kind >= 5 && kind % 2 == 1 ? 4 : 48
        default: shapeCount = 48
        }
        let geometry = RPGTileGeometry(engine: engine)
        let imagePath = definition?.imagePath(for: item.sheet)
        let imageSize = imagePath.flatMap { imageSizes[$0] }
        return (0..<shapeCount).compactMap { shape in
            var variant = item
            variant.id = "\(item.id)-shape-\(shape)"
            variant.autotileShape = shape
            variant.gid = item.gid - (item.autotileShape ?? 0) + shape
            variant.titleEN = "\(item.titleEN) · shape \(shape)"
            variant.titleZH = "\(item.titleZH) · 形状 \(shape)"
            if let resolved = geometry.resolve(tileID: variant.gid, imageSize: imageSize).tile {
                variant.sourceQuarters = resolved.sourceQuarters
            }
            return variant
        }
    }
}

public enum RPGTilePaletteBuilder {
    /// Builds a visual palette from the actual resolved image paths. A
    /// missing image does not invent a sheet or borrow another project's art;
    /// its section is omitted and the map/catalog diagnostics explain why.
    public static func build(definition: RPGTilesetDefinition,
                             engine: RPGEngine,
                             imageSizes: [String: CGSize]) -> RPGTilePalette {
        let geometry = RPGTileGeometry(engine: engine)
        var sections: [RPGTilePaletteSection] = []
        var diagnostics: [RPGTileAssetDiagnostic] = []
        if engine == .rpgMakerXP {
            var autotileSections: [RPGTilePaletteSection] = []
            for index in 0..<7 {
                guard definition.xpAutotilePaths.indices.contains(index),
                      let path = definition.xpAutotilePaths[index] else { continue }
                if let size = imageSizes[path], size.width < 32 || size.height < 32 {
                    diagnostics.append(.init(code: "palette.xp.autotile.small", severity: .warning,
                        messageEN: "XP autotile \(index + 1) is smaller than one tile and cannot be previewed.",
                        messageZH: "XP 自动图块 \(index + 1) 小于一个图块，无法预览。", path: path))
                    continue
                }
                let shape = 47
                let gid = 48 + index * 48 + shape
                let resolution = geometry.resolve(tileID: gid, imageSize: imageSizes[path])
                guard let tile = resolution.tile else {
                    if let diagnostic = resolution.diagnostic { diagnostics.append(diagnostic) }
                    continue
                }
                let item = RPGTilePaletteItem(
                    id: "xp-autotile-\(index)-0", gid: gid,
                    sheet: .xpAutotile(index: index), sourceQuarters: tile.sourceQuarters,
                    titleEN: "Autotile \(index + 1)", titleZH: "自动图块 \(index + 1)",
                    sectionID: "xp-autotile-\(index)", autotileKind: index, autotileShape: shape)
                autotileSections.append(RPGTilePaletteSection(
                    id: "xp-autotile-\(index)", titleEN: "Autotile \(index + 1)",
                    titleZH: "自动图块 \(index + 1)",
                    sheet: .xpAutotile(index: index), items: [item]))
            }
            sections.append(contentsOf: autotileSections)
            if let path = definition.xpTilesetPath {
                let size = imageSizes[path] ?? CGSize(width: 0, height: 0)
                let rows = max(0, Int(size.height) / max(1, geometry.tileSize))
                let columns = 8
                let count = min(4_096, rows * columns)
                var items: [RPGTilePaletteItem] = []
                for local in 0..<count {
                    let gid = 384 + local
                    guard let rect = geometry.ordinaryRect(sheet: .xpTileset, localIndex: local),
                          fits(rect, size: size) else { continue }
                    items.append(RPGTilePaletteItem(
                        id: "xp-tiles-\(local)", gid: gid, sheet: .xpTileset,
                        sourceQuarters: [rect], titleEN: "Tile \(local + 1)",
                        titleZH: "图块 \(local + 1)", sectionID: "xp-tiles",
                        autotileKind: nil, autotileShape: nil))
                }
                if !items.isEmpty {
                    sections.append(RPGTilePaletteSection(
                        id: "xp-tiles", titleEN: "Tiles", titleZH: "图块",
                        sheet: .xpTileset, items: items))
                }
            }
            return RPGTilePalette(sections: sections, diagnostics: diagnostics,
                                  engine: engine, definition: definition, imageSizes: imageSizes)
        }

        for section in RPGTilesetSection.allCases {
            guard let path = definition.sectionPaths[section] else { continue }
            let size = imageSizes[path] ?? CGSize(width: 0, height: 0)
            if size.width <= 0 || size.height <= 0 { continue }
            let items: [RPGTilePaletteItem]
            switch section {
            case .a1, .a2, .a3, .a4:
                items = autotileItems(definition: definition, engine: engine, section: section,
                                      geometry: geometry, size: size)
            case .a5:
                items = normalItems(section: section, columns: 8, maximum: 128,
                                    baseGID: 1536, geometry: geometry, size: size)
            case .b, .c, .d, .e:
                let sectionIndex = section.index - 5
                items = normalItems(section: section, columns: 16, maximum: 256,
                                    baseGID: 1 + sectionIndex * 256, geometry: geometry, size: size)
            }
            if !items.isEmpty {
                sections.append(RPGTilePaletteSection(
                    id: section.rawValue, titleEN: section.rawValue.uppercased(),
                    titleZH: section.rawValue.uppercased(), sheet: .section(section), items: items))
            }
        }
        return RPGTilePalette(sections: sections, diagnostics: diagnostics,
                                  engine: engine, definition: definition, imageSizes: imageSizes)
    }

    private static func autotileItems(definition: RPGTilesetDefinition, engine: RPGEngine,
                                      section: RPGTilesetSection, geometry: RPGTileGeometry,
                                      size: CGSize) -> [RPGTilePaletteItem] {
        let range: Range<Int>
        switch section {
        case .a1: range = 0..<16
        case .a2: range = 16..<48
        case .a3: range = 48..<80
        case .a4: range = 80..<128
        default: return []
        }
        var items: [RPGTilePaletteItem] = []
        for kind in range {
            let shape: Int
            switch section {
            case .a3: shape = 0
            case .a4: shape = (kind / 8) % 2 == 1 ? 0 : 47
            case .a1: shape = (kind >= 5 && kind % 2 == 1) ? 0 : 47
            default: shape = 47
            }
            let gid = 2048 + kind * 48 + shape
            let resolution = geometry.resolve(tileID: gid, imageSize: size)
            guard let tile = resolution.tile,
                  tile.sourceQuarters.allSatisfy({ fits($0, size: size) }) else { continue }
            let indexInSection = kind - range.lowerBound
            items.append(RPGTilePaletteItem(
                id: "\(section.rawValue)-kind-\(kind)", gid: gid, sheet: .section(section),
                sourceQuarters: tile.sourceQuarters,
                titleEN: "\(section.rawValue.uppercased()) \(indexInSection + 1)",
                titleZH: "\(section.rawValue.uppercased()) \(indexInSection + 1)",
                sectionID: section.rawValue, autotileKind: kind, autotileShape: shape))
        }
        return items
    }

    private static func normalItems(section: RPGTilesetSection, columns: Int, maximum: Int,
                                    baseGID: Int, geometry: RPGTileGeometry,
                                    size: CGSize) -> [RPGTilePaletteItem] {
        let rows = max(0, Int(size.height) / max(1, geometry.tileSize))
        let capacity = min(maximum, rows * columns)
        var items: [RPGTilePaletteItem] = []
        for local in 0..<capacity {
            guard let rect = geometry.ordinaryRect(sheet: .section(section), localIndex: local),
                  fits(rect, size: size) else { continue }
            items.append(RPGTilePaletteItem(
                id: "\(section.rawValue)-\(local)", gid: baseGID + local,
                sheet: .section(section), sourceQuarters: [rect],
                titleEN: "\(section.rawValue.uppercased()) \(local + 1)",
                titleZH: "\(section.rawValue.uppercased()) \(local + 1)",
                sectionID: section.rawValue, autotileKind: nil, autotileShape: nil))
        }
        return items
    }

    private static func fits(_ rect: CGRect, size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 &&
        rect.minX >= 0 && rect.minY >= 0 &&
        rect.maxX <= size.width + 0.0001 && rect.maxY <= size.height + 0.0001
    }
}
