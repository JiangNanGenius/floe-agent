// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import FloeGameCore
import FloeRPGCore
import FloeRPGTilesetKit

/// Host render probe. It uses the real decoder, catalog, planner and
/// CoreGraphics rasterizer (the same code the iPad view uses for sprites), so
/// its PNGs are actual renderer output rather than mock screenshots.
@main
struct RPGTilesetRenderProbe {
    struct Fixture {
        let name: String
        let engine: RPGEngine
        let mapPath: String
    }

    static func main() async {
        let arguments = CommandLine.arguments
        guard let fixturesArgument = value(after: "--fixtures", in: arguments),
              let outputArgument = value(after: "--out", in: arguments) else {
            print("usage: floe-rpg-tileset-render --fixtures <dir> --out <dir>")
            exit(2)
        }
        let fixtures = URL(fileURLWithPath: fixturesArgument, isDirectory: true)
        let output = URL(fileURLWithPath: outputArgument, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cases: [Fixture] = [
            .init(name: "xp", engine: .rpgMakerXP, mapPath: "Data/Map001.rxdata"),
            .init(name: "vx", engine: .rpgMakerVX, mapPath: "Data/Map001.rvdata"),
            .init(name: "ace", engine: .rpgMakerVXAce, mapPath: "Data/Map001.rvdata2"),
            .init(name: "mv", engine: .rpgMakerMV, mapPath: "data/Map001.json"),
            .init(name: "mz", engine: .rpgMakerMZ, mapPath: "data/Map001.json")
        ]
        var summary: [[String: Any]] = []
        for item in cases {
            let root = fixtures.appendingPathComponent("\(item.name)-project", isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else {
                print("FAILED missing fixture \(item.name)")
                summary.append(["engine": item.name, "error": "Missing fixture directory"])
                continue
            }
            do {
                let record = try await renderCase(item, root: root, output: output.appendingPathComponent(item.name))
                summary.append(record)
                print("rendered \(item.name): \((record["map"] as? String) ?? "")")
            } catch {
                print("FAILED \(item.name): \(error)")
                summary.append(["engine": item.name, "error": String(describing: error)])
            }
        }
        let summaryURL = output.appendingPathComponent("summary.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: summary,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: summaryURL)
        } catch {
            print("FAILED writing renderer summary: \(error)")
            exit(1)
        }
        guard summary.count == cases.count,
              summary.allSatisfy({ $0["error"] == nil }) else { exit(1) }
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    static func renderCase(_ item: Fixture, root: URL, output: URL) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let files = try projectFiles(root: root)
        let mapURL = root.appendingPathComponent(item.mapPath)
        let mapBytes = try Data(contentsOf: mapURL)
        let document = try RPGMapDocument.decode(mapBytes, engine: item.engine,
                                                 pathName: item.mapPath)
        let map = try document.editableTileMap()
        let catalog = try await RPGTilesetCatalog.load(
            engine: item.engine, files: files,
            reader: { path in try read(path, root: root) })
        let index = RPGProjectFileIndex(paths: files)
        let presentation = RPGMapPresentationLoader.load(document: document, projectIndex: index)
        guard let definition = catalog.definition(id: presentation.tilesetID) else {
            throw ProbeError.missingTileset(presentation.tilesetID)
        }
        let store = RPGTilesetImageStore()
        let generation = await store.activate()
        var images: [String: CGImage] = [:]
        var sizes: [String: CGSize] = [:]
        var imageRecords: [[String: Any]] = []
        for path in imagePaths(definition) {
            do {
                guard let relative = try? GameRelativePath(path) else { continue }
                let decoded = try await store.image(
                    at: path, generation: generation,
                    reader: { try read(relative, root: root) })
                images[path] = decoded.image
                sizes[path] = decoded.size
                imageRecords.append(["path": path, "width": decoded.pixelWidth,
                                     "height": decoded.pixelHeight, "bytes": decoded.decodedBytes])
            } catch {
                imageRecords.append(["path": path, "error": String(describing: error)])
            }
        }
        var characterSizes: [String: CGSize] = [:]
        var characterImages: [String: CGImage] = [:]
        for event in presentation.events.values {
            guard let path = event.imagePath, characterImages[path] == nil,
                  let relative = try? GameRelativePath(path) else { continue }
            if let decoded = try? await store.image(
                at: path, generation: generation,
                reader: { try read(relative, root: root) }) {
                characterSizes[path] = decoded.size
                characterImages[path] = decoded.image
            }
        }
        let planner = RPGTileMapPlanner(
            map: map, definition: definition, presentation: presentation,
            engine: item.engine, imageSizes: sizes, characterImageSizes: characterSizes)
        let plan = planner.fullPlan()
        guard let image = RPGTileMapRasterizer.render(
            plan: plan, images: images.merging(characterImages) { current, _ in current },
            scale: 2, showGrid: true) else { throw ProbeError.renderFailed }
        try RPGImageWriter.writePNG(image, to: output.appendingPathComponent("map.png"))
        let palette = RPGTilePaletteBuilder.build(definition: definition, engine: item.engine,
                                                  imageSizes: sizes)
        var sheetRecords: [[String: Any]] = []
        for section in palette.sections {
            if let sheet = contactSheet(section: section, definition: definition,
                                        engine: item.engine, images: images, sizes: sizes) {
                let name = "palette-\(section.id).png"
                try RPGImageWriter.writePNG(sheet, to: output.appendingPathComponent(name))
                sheetRecords.append(["section": section.id, "items": section.items.count, "file": name])
            }
        }
        if let autotile = palette.sections.first(where: { $0.id == "a2" })?.items.first {
            let variants = palette.shapeVariants(for: autotile)
            if let sheet = contactSheet(items: variants, definition: definition,
                                        engine: item.engine, images: images, sizes: sizes,
                                        columns: 8) {
                try RPGImageWriter.writePNG(sheet, to: output.appendingPathComponent("autotile-a2-shapes.png"))
            }
        }
        if item.engine == .rpgMakerXP,
           let autotile = palette.sections.first(where: { $0.id.hasPrefix("xp-autotile") })?.items.first {
            let variants = palette.shapeVariants(for: autotile)
            if let sheet = contactSheet(items: variants, definition: definition,
                                        engine: item.engine, images: images, sizes: sizes,
                                        columns: 8) {
                try RPGImageWriter.writePNG(sheet, to: output.appendingPathComponent("autotile-xp-shapes.png"))
            }
        }
        let record: [String: Any] = [
            "engine": item.engine.rawValue,
            "map": item.mapPath,
            "tilesetID": presentation.tilesetID,
            "tilesetName": definition.name,
            "dataPath": catalog.dataPath ?? "",
            "imageCount": images.count,
            "images": imageRecords,
            "commands": plan.commands.count,
            "markers": plan.markers.count,
            "diagnostics": plan.diagnostics.map { ["code": $0.code, "message": $0.messageEN,
                                                   "path": $0.path ?? ""] },
            "palette": palette.sections.map { ["section": $0.id, "items": $0.items.count] },
            "paletteSheets": sheetRecords,
            "mapFile": "map.png"
        ]
        let json = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("render.json"))
        return record
    }

    static func imagePaths(_ definition: RPGTilesetDefinition) -> [String] {
        if definition.engine == .rpgMakerXP {
            var result: [String] = []
            if let path = definition.xpTilesetPath { result.append(path) }
            result.append(contentsOf: definition.xpAutotilePaths.compactMap { $0 })
            return Array(Set(result)).sorted()
        }
        return Array(Set(RPGTilesetSection.allCases.compactMap { definition.sectionPaths[$0] })).sorted()
    }

    static func contactSheet(section: RPGTilePaletteSection,
                             definition: RPGTilesetDefinition, engine: RPGEngine,
                             images: [String: CGImage],
                             sizes: [String: CGSize]) -> CGImage? {
        let columns = section.sheet == .xpTileset ? 8 : 16
        return contactSheet(items: section.items, definition: definition, engine: engine,
                            images: images, sizes: sizes, columns: columns)
    }

    static func contactSheet(items: [RPGTilePaletteItem], definition: RPGTilesetDefinition,
                             engine: RPGEngine, images: [String: CGImage],
                             sizes: [String: CGSize], columns: Int) -> CGImage? {
        guard !items.isEmpty else { return nil }
        let tile = engine.tileSize
        let rows = (items.count + columns - 1) / columns
        var plan = RPGTileRenderPlan(tileSize: tile,
                                     mapSize: .init(width: columns, height: rows),
                                     visibleCellRect: CGRect(x: 0, y: 0, width: CGFloat(columns), height: CGFloat(rows)))
        for (index, item) in items.enumerated() {
            guard let path = definition.imagePath(for: item.sheet) else { continue }
            let cell = CGRect(x: CGFloat(index % columns * tile),
                              y: CGFloat(index / columns * tile),
                              width: CGFloat(tile), height: CGFloat(tile))
            let destinations = RPGTileGeometry.destinationQuarters(for: cell,
                                                                    count: item.sourceQuarters.count)
            for (quarter, source) in item.sourceQuarters.enumerated()
            where destinations.indices.contains(quarter) {
                plan.commands.append(RPGTileDrawCommand(
                    imagePath: path, source: source, destination: destinations[quarter],
                    tileID: item.gid, sheet: item.sheet))
            }
        }
        return RPGTileMapRasterizer.render(plan: plan, images: images, scale: 1,
                                           showGrid: true, maxDimension: 4_096)
    }

    static func projectFiles(root: URL) throws -> [GameRelativePath] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            throw ProbeError.unreadableFixture(root.path)
        }
        var result: [GameRelativePath] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if let path = try? GameRelativePath(relative) { result.append(path) }
        }
        return result.sorted { $0.value < $1.value }
    }

    static func read(_ path: GameRelativePath, root: URL) throws -> Data {
        let url = root.appendingPathComponent(path.value)
        let standardized = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path + "/"
        guard standardized.hasPrefix(rootPath) else { throw ProbeError.unsafePath(path.value) }
        return try Data(contentsOf: url)
    }

    enum ProbeError: Error, CustomStringConvertible {
        case missingTileset(Int)
        case renderFailed
        case unreadableFixture(String)
        case unsafePath(String)
        var description: String {
            switch self {
            case .missingTileset(let id): return "missing tileset \(id)"
            case .renderFailed: return "rasterizer produced no map image"
            case .unreadableFixture(let path): return "unreadable fixture \(path)"
            case .unsafePath(let path): return "unsafe path \(path)"
            }
        }
    }
}
