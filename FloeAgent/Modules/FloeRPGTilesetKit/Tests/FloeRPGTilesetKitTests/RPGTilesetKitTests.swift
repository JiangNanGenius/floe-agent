// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import Testing
import FloeGameCore
import FloeGameEditingCore
import FloeRPGCore
@testable import FloeRPGTilesetKit

@Suite("RPG tileset catalog and geometry")
struct RPGTilesetKitTests {
    @Test("five generations resolve tileset records and real image paths")
    func catalogLoadsAllFiveGenerations() async throws {
        for fixture in FixtureSupport.projects {
            let catalog = try await FixtureSupport.loadCatalog(fixture)
            #expect(catalog.dataPath != nil, "\(fixture.name) data path")
            let definition = try #require(catalog.definition(id: 1))
            #expect(definition.engine == fixture.engine)
            if fixture.engine == .rpgMakerXP {
                #expect(definition.xpTilesetPath != nil)
                #expect(definition.xpAutotilePaths.compactMap { $0 }.count == 7)
            } else {
                #expect(definition.sectionPaths.count == 9, "\(fixture.name) sections")
                for section in RPGTilesetSection.allCases {
                    #expect(definition.sectionPaths[section] != nil, "\(fixture.name) \(section)")
                }
            }
            #expect(catalog.diagnostics.filter { $0.severity == .error }.isEmpty)
            for path in FixtureSupport.imagePaths(definition) {
                let url = FixtureSupport.projectRoot(fixture.name).appendingPathComponent(path)
                #expect(FileManager.default.fileExists(atPath: url.path), "\(fixture.name) \(path)")
            }
        }
    }

    @Test("tile ids map to the correct sheet and quarter layout")
    func tileIDMappingAllGenerations() async throws {
        for fixture in FixtureSupport.projects {
            let catalog = try await FixtureSupport.loadCatalog(fixture)
            let definition = try #require(catalog.definition(id: 1))
            let images = try FixtureSupport.loadImageSet(definition,
                root: FixtureSupport.projectRoot(fixture.name))
            let sizes = FixtureSupport.imageSizes(images)
            let geometry = RPGTileGeometry(engine: fixture.engine)
            func check(_ gid: Int, sheet: RPGTileSheetKind, quarters: Int,
                       sourcePath: String) throws -> RPGResolvedTile {
                let resolution = geometry.resolve(tileID: gid, imageSize: sizes[sourcePath])
                #expect(resolution.diagnostic == nil, "\(fixture.name) gid \(gid): \(resolution.diagnostic?.messageEN ?? "")")
                let tile = try #require(resolution.tile)
                #expect(tile.sheet == sheet, "\(fixture.name) gid \(gid) sheet")
                #expect(tile.sourceQuarters.count == quarters)
                let imageSize = try #require(sizes[sourcePath])
                for rect in tile.sourceQuarters {
                    #expect(rect.minX >= 0 && rect.minY >= 0)
                    #expect(rect.maxX <= imageSize.width && rect.maxY <= imageSize.height,
                            "\(fixture.name) gid \(gid) rect \(rect) outside \(imageSize)")
                }
                return tile
            }
            switch fixture.engine {
            case .rpgMakerXP:
                _ = try check(48, sheet: .xpAutotile(index: 0), quarters: 4,
                              sourcePath: try #require(definition.xpAutotilePaths[0]))
                _ = try check(384, sheet: .xpTileset, quarters: 1,
                              sourcePath: try #require(definition.xpTilesetPath))
                _ = try check(383, sheet: .xpAutotile(index: 6), quarters: 4,
                              sourcePath: try #require(definition.xpAutotilePaths[6]))
            default:
                let pathA2 = try #require(definition.sectionPaths[.a2])
                let pathA3 = try #require(definition.sectionPaths[.a3])
                let pathA4 = try #require(definition.sectionPaths[.a4])
                let pathA5 = try #require(definition.sectionPaths[.a5])
                let pathB = try #require(definition.sectionPaths[.b])
                let pathE = try #require(definition.sectionPaths[.e])
                _ = try check(2095, sheet: .section(.a1), quarters: 4,
                              sourcePath: try #require(definition.sectionPaths[.a1]))
                _ = try check(2863, sheet: .section(.a2), quarters: 4, sourcePath: pathA2)
                _ = try check(4352, sheet: .section(.a3), quarters: 4, sourcePath: pathA3)
                _ = try check(5935, sheet: .section(.a4), quarters: 4, sourcePath: pathA4)
                _ = try check(5936, sheet: .section(.a4), quarters: 4, sourcePath: pathA4)
                _ = try check(6272, sheet: .section(.a4), quarters: 4, sourcePath: pathA4)
                _ = try check(1536, sheet: .section(.a5), quarters: 1, sourcePath: pathA5)
                _ = try check(1, sheet: .section(.b), quarters: 1, sourcePath: pathB)
                _ = try check(1023, sheet: .section(.e), quarters: 1, sourcePath: pathE)
            }
        }
    }

    @Test("autotile shapes select distinct corners, edges, water and wall quarters")
    func autotileShapeVariants() async throws {
        for fixture in FixtureSupport.projects where fixture.engine != .rpgMakerXP {
            let catalog = try await FixtureSupport.loadCatalog(fixture)
            let definition = try #require(catalog.definition(id: 1))
            let images = try FixtureSupport.loadImageSet(definition,
                root: FixtureSupport.projectRoot(fixture.name))
            let sizes = FixtureSupport.imageSizes(images)
            let geometry = RPGTileGeometry(engine: fixture.engine)
            let a2Path = try #require(definition.sectionPaths[.a2])
            let a2Size = try #require(sizes[a2Path])
            let shape47 = try #require(geometry.resolve(tileID: 2816 + 47, imageSize: a2Size).tile)
            #expect(shape47.sourceQuarters[0] == CGRect(x: 0, y: 0,
                width: CGFloat(geometry.half), height: CGFloat(geometry.half)))
            #expect(shape47.sourceQuarters[1].minX == CGFloat(geometry.half))
            #expect(shape47.sourceQuarters[2].minY == CGFloat(geometry.half))
            let shape0 = try #require(geometry.resolve(tileID: 2816, imageSize: a2Size).tile)
            // Official pinned CoreScript: table[i][0] is qsx, table[i][1] qsy.
            // Shape0's top-left source is (2,4), not transposed to (4,2).
            #expect(shape0.sourceQuarters[0] == CGRect(x: CGFloat(2 * geometry.half), y: CGFloat(4 * geometry.half),
                width: CGFloat(geometry.half), height: CGFloat(geometry.half)))
            #expect(shape0.sourceQuarters != shape47.sourceQuarters)

            let a3Path = try #require(definition.sectionPaths[.a3])
            let a3Size = try #require(sizes[a3Path])
            let wall = try #require(geometry.resolve(tileID: 4352, imageSize: a3Size).tile)
            #expect(wall.sourceQuarters.count == 4)
            #expect(geometry.resolve(tileID: 4352 + 16, imageSize: a3Size).tile == nil)

            let a4Path = try #require(definition.sectionPaths[.a4])
            let a4Size = try #require(sizes[a4Path])
            let a4Wall = try #require(geometry.resolve(tileID: 5888 + 48, imageSize: a4Size).tile)
            #expect(a4Wall.sourceQuarters.count == 4)

            let a1Path = try #require(definition.sectionPaths[.a1])
            let a1Size = try #require(sizes[a1Path])
            let waterfall = try #require(geometry.resolve(tileID: 2048 + 5 * 48, imageSize: a1Size).tile)
            #expect(waterfall.sourceQuarters.count == 4)
            #expect(waterfall.sourceQuarters.allSatisfy {
                $0.maxX <= a1Size.width && $0.maxY <= a1Size.height
            })
        }
        let xpCatalog = try await FixtureSupport.loadCatalog(FixtureSupport.projects[0])
        let xpDefinition = try #require(xpCatalog.definition(id: 1))
        let xpImages = try FixtureSupport.loadImageSet(xpDefinition,
            root: FixtureSupport.projectRoot(FixtureSupport.projects[0].name))
        let xpGeometry = RPGTileGeometry(engine: .rpgMakerXP)
        let xpPath = try #require(xpDefinition.xpAutotilePaths[0])
        let xpSize = try #require(FixtureSupport.imageSizes(xpImages)[xpPath])
        let xp0 = try #require(xpGeometry.resolve(tileID: 48, imageSize: xpSize).tile)
        let xp47 = try #require(xpGeometry.resolve(tileID: 95, imageSize: xpSize).tile)
        #expect(xp0.sourceQuarters.count == 4)
        #expect(xp0.sourceQuarters != xp47.sourceQuarters)
    }

    @Test("viewport plans only include visible cells")
    func viewportBoundedPlan() async throws {
        let fixture = FixtureSupport.projects[3]
        let catalog = try await FixtureSupport.loadCatalog(fixture)
        let definition = try #require(catalog.definition(id: 1))
        let document = try FixtureSupport.loadDocument(fixture)
        let map = try document.editableTileMap()
        let images = try FixtureSupport.loadImageSet(definition,
            root: FixtureSupport.projectRoot(fixture.name))
        let planner = RPGTileMapPlanner(map: map, definition: definition,
                                        presentation: nil, engine: fixture.engine,
                                        imageSizes: FixtureSupport.imageSizes(images))
        let full = planner.fullPlan()
        let visible = planner.plan(visibleCells: CGRect(x: 1, y: 1, width: 2, height: 2))
        #expect(!full.commands.isEmpty)
        #expect(visible.commands.count < full.commands.count)
        #expect(visible.commands.count <= 2 * 2 * 4 * 4 + 2)
        let visiblePixels = CGRect(x: 32, y: 32, width: 96, height: 96)
        for command in visible.commands {
            #expect(command.destination.intersects(visiblePixels))
        }
    }

    @Test("render output is deterministic, non-blank and multi-layer")
    func deterministicRender() async throws {
        for fixture in FixtureSupport.projects {
            let catalog = try await FixtureSupport.loadCatalog(fixture)
            let definition = try #require(catalog.definition(id: 1))
            let document = try FixtureSupport.loadDocument(fixture)
            let map = try document.editableTileMap()
            let images = try FixtureSupport.loadImageSet(definition,
                root: FixtureSupport.projectRoot(fixture.name))
            let planner = RPGTileMapPlanner(map: map, definition: definition,
                                            presentation: nil, engine: fixture.engine,
                                            imageSizes: FixtureSupport.imageSizes(images))
            let plan = planner.fullPlan()
            let first = try #require(RPGTileMapRasterizer.render(plan: plan, images: images, scale: 1))
            let second = try #require(RPGTileMapRasterizer.render(plan: plan, images: images, scale: 1))
            let data1 = try #require(RPGImageWriter.pngData(first))
            let data2 = try #require(RPGImageWriter.pngData(second))
            #expect(data1 == data2)
            #expect(data1.count > 1_000)
            #expect(distinctColors(first) > 8, "\(fixture.name) output should not be blank")
            if fixture.engine == .rpgMakerMV {
                let sheets = Set(plan.commands.map(\.sheet))
                #expect(sheets.contains(.section(.a2)))
                #expect(sheets.contains(.section(.a3)))
                #expect(sheets.contains(.section(.a4)))
                #expect(sheets.contains(.section(.a5)))
                #expect(sheets.contains(.section(.b)))
                #expect(sheets.contains(.section(.c)))
            }
        }
    }

    @Test("palette exposes every standard section with real thumbnails")
    func paletteSections() async throws {
        for fixture in FixtureSupport.projects {
            let catalog = try await FixtureSupport.loadCatalog(fixture)
            let definition = try #require(catalog.definition(id: 1))
            let images = try FixtureSupport.loadImageSet(definition,
                root: FixtureSupport.projectRoot(fixture.name))
            let palette = RPGTilePaletteBuilder.build(
                definition: definition, engine: fixture.engine,
                imageSizes: FixtureSupport.imageSizes(images))
            #expect(!palette.sections.isEmpty)
            if fixture.engine == .rpgMakerXP {
                #expect(palette.sections.filter { $0.id.hasPrefix("xp-autotile") }.count == 7)
                #expect(palette.sections.contains { $0.id == "xp-tiles" && !$0.items.isEmpty })
            } else {
                #expect(palette.section(id: "a2")?.items.count == 32)
                #expect(palette.section(id: "a5")?.items.count == 128)
                #expect(palette.section(id: "b")?.items.count == 256)
                let item = try #require(palette.section(id: "a2")?.items.first)
                #expect(item.sourceQuarters.count == 4)
                let variants = palette.shapeVariants(for: item)
                #expect(variants.count == 48)
                #expect(variants.first?.sourceQuarters != variants.last?.sourceQuarters)
            }
        }
    }

    @Test("missing, malformed, oversized, ambiguous and traversal assets fail safely")
    func assetFailureModes() async throws {
        let fixture = FixtureSupport.projects[3]
        let root = FixtureSupport.projectRoot(fixture.name)
        let allFiles = try FixtureSupport.files(in: root)
        let catalog = try await FixtureSupport.loadCatalog(fixture)
        let definition = try #require(catalog.definition(id: 1))
        let imagePath = try #require(definition.sectionPaths[.a2])
        let withoutImage = allFiles.filter { $0.value != imagePath }
        let missingCatalog = try await RPGTilesetCatalog.load(
            engine: fixture.engine, files: withoutImage,
            reader: FixtureSupport.reader(root: root))
        #expect(missingCatalog.diagnostics.contains { $0.code == "tileset.asset.missing" })

        let temp = try FixtureSupport.temporaryDirectory("bad-assets")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("data"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("img/tilesets"),
                                                withIntermediateDirectories: true)
        let tilesetJSON: [String: Any] = ["tilesetNames": ["../../evil", "", "", "", "", "", "", "", ""]]
        let jsonData = try JSONSerialization.data(withJSONObject: [NSNull(), tilesetJSON])
        try jsonData.write(to: temp.appendingPathComponent("data/Tilesets.json"))
        let traversalFiles = [try GameRelativePath("data/Tilesets.json")]
        let traversal = try await RPGTilesetCatalog.load(
            engine: .rpgMakerMV, files: traversalFiles,
            reader: { path in try Data(contentsOf: temp.appendingPathComponent(path.value)) })
        #expect(traversal.diagnostics.contains { $0.code == "tileset.name.unsafe" })

        try FileManager.default.createDirectory(at: temp.appendingPathComponent("img/tilesets"),
                                                withIntermediateDirectories: true)
        let brokenJSON: [String: Any] = ["tilesetNames": ["Broken", "Broken", "Broken", "Broken",
                                                          "Broken", "Broken", "Broken", "Broken", "Broken"]]
        try JSONSerialization.data(withJSONObject: [NSNull(), brokenJSON])
            .write(to: temp.appendingPathComponent("data/Tilesets.json"))
        try Data("not a png".utf8).write(to: temp.appendingPathComponent("img/tilesets/Broken.png"))
        let brokenFiles = [try GameRelativePath("data/Tilesets.json"),
                           try GameRelativePath("img/tilesets/Broken.png")]
        let brokenCatalog = try await RPGTilesetCatalog.load(
            engine: .rpgMakerMV, files: brokenFiles,
            reader: { path in try Data(contentsOf: temp.appendingPathComponent(path.value)) })
        #expect(brokenCatalog.definition(id: 1) != nil)
        let brokenData = try Data(contentsOf: temp.appendingPathComponent("img/tilesets/Broken.png"))
        do {
            _ = try RPGTilesetImageStore.decode(brokenData, path: "Broken",
                                                limits: .init())
            #expect(Bool(false))
        } catch let error as RPGTilesetImageError {
            if case .invalidImage = error {} else { #expect(Bool(false)) }
        }

        let goodData = try Data(contentsOf: root.appendingPathComponent(imagePath))
        do {
            _ = try RPGTilesetImageStore.decode(goodData, path: imagePath,
                limits: .init(maximumEncodedBytes: 32 * 1_024 * 1_024,
                              maximumPixelDimension: 8,
                              maximumPixelCount: 64,
                              maximumDecodedBytes: 1_024,
                              maximumCachedImages: 1,
                              maximumImageDecodedBytes: 1_024))
            #expect(Bool(false))
        } catch let error as RPGTilesetImageError {
            if case .oversizedImage = error {} else { #expect(Bool(false)) }
        }

        let ambiguousRoot = try FixtureSupport.temporaryDirectory("ambiguous")
        defer { try? FileManager.default.removeItem(at: ambiguousRoot) }
        try FileManager.default.createDirectory(at: ambiguousRoot.appendingPathComponent("data"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ambiguousRoot.appendingPathComponent("img/tilesets"),
                                                withIntermediateDirectories: true)
        let ambiguousJSON: [String: Any] = ["tilesetNames": ["Floe", "", "", "", "", "", "", "", ""]]
        try JSONSerialization.data(withJSONObject: [NSNull(), ambiguousJSON])
            .write(to: ambiguousRoot.appendingPathComponent("data/Tilesets.json"))
        try goodData.write(to: ambiguousRoot.appendingPathComponent("img/tilesets/Floe.png"))
        try goodData.write(to: ambiguousRoot.appendingPathComponent("img/tilesets/floe.png"))
        // Case-insensitive APFS collapses these two physical filenames.
        // Imported archive manifests can still contain both distinct entries;
        // exercise that exact catalog input independently of host filesystem.
        let ambiguousFiles = try ["data/Tilesets.json", "img/tilesets/Floe.png",
                                  "img/tilesets/floe.png"].map(GameRelativePath.init)
        let ambiguous = try await RPGTilesetCatalog.load(
            engine: .rpgMakerMV, files: ambiguousFiles,
            reader: { path in try Data(contentsOf: ambiguousRoot.appendingPathComponent(path.value)) })
        #expect(ambiguous.diagnostics.contains { $0.code == "tileset.asset.ambiguous" })
    }

    @Test("image generation changes cancel stale decodes")
    func generationCancellation() async throws {
        let fixture = FixtureSupport.projects[3]
        let catalog = try await FixtureSupport.loadCatalog(fixture)
        let definition = try #require(catalog.definition(id: 1))
        let path = try #require(definition.sectionPaths[.a2])
        let data = try Data(contentsOf: FixtureSupport.projectRoot(fixture.name)
            .appendingPathComponent(path))
        let store = RPGTilesetImageStore()
        let generation = await store.activate()
        let task = Task {
            try await store.image(at: path, generation: generation, reader: {
                try await Task.sleep(for: .milliseconds(200))
                return data
            })
        }
        _ = await store.activate()
        do {
            _ = try await task.value
            #expect(Bool(false), "stale image must not be returned")
        } catch let error as RPGTilesetImageError {
            #expect(error == .cancelled)
        }
    }
}

private func distinctColors(_ image: CGImage) -> Int {
    var colors = Set<UInt32>()
    let step = 7
    var y = 0
    while y < image.height {
        var x = 0
        while x < image.width {
            let value = FixtureSupport.pixel(of: image, x: x, y: y)
            colors.insert(UInt32(value.0) << 24 | UInt32(value.1) << 16 |
                          UInt32(value.2) << 8 | UInt32(value.3))
            x += step
        }
        y += step
    }
    return colors.count
}
