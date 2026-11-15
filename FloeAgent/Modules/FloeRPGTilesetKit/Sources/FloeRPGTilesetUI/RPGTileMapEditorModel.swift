// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import Combine
import FloeGameCore
import FloeGameEditingCore
import FloeRPGCore
import FloeRPGTilesetKit

/// Main-actor state for the RPG visual map editor. All reads go through the
/// existing session (repository revision + edit/undo/save); this model never
/// writes a file directly.
@MainActor
public final class RPGTileMapEditorModel: ObservableObject {
    public let session: GameEditingSession
    public let path: GameRelativePath
    public let engine: RPGEngine

    @Published public private(set) var map: EditableTileMap?
    @Published public private(set) var catalog: RPGTilesetCatalog?
    @Published public private(set) var definition: RPGTilesetDefinition?
    @Published public private(set) var presentation: RPGMapPresentation?
    @Published public private(set) var palette: RPGTilePalette?
    @Published public private(set) var tilesetImages: [String: CGImage] = [:]
    @Published public private(set) var imageSizes: [String: CGSize] = [:]
    @Published public private(set) var characterImages: [String: CGImage] = [:]
    @Published public private(set) var characterImageSizes: [String: CGSize] = [:]
    @Published public private(set) var diagnostics: [RPGTileAssetDiagnostic] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var loadError: String?

    private let context: RPGTilesetContext
    private var loadToken = UUID()
    private var generation: UUID?
    private var cropCache: [String: CGImage] = [:]
    private var boundProjectID: UUID?
    private var boundRevision: String?

    public init(session: GameEditingSession, path: GameRelativePath, engine: RPGEngine) {
        self.session = session; self.path = path; self.engine = engine
        self.context = RPGTilesetContext(engine: engine)
    }

    public var selectedTilesetID: Int? { presentation?.tilesetID }
    public var hasMissingTileset: Bool { definition == nil && (catalog?.isEmpty ?? true) == false }

    /// Reloads map bytes, tileset records, images and event presentation
    /// metadata for the current authoritative revision. A project/revision
    /// change creates a new image-cache generation; late decodes are dropped.
    public func reload() async {
        let token = UUID()
        loadToken = token
        let projectID = session.projectID
        if boundProjectID != projectID || boundRevision != session.expectedRevision {
            boundProjectID = projectID
            boundRevision = session.expectedRevision
            tilesetImages = [:]
            imageSizes = [:]
            characterImages = [:]
            characterImageSizes = [:]
            cropCache = [:]
            map = nil
            palette = nil
            definition = nil
            presentation = nil
        }
        isLoading = true
        loadError = nil
        do {
            guard let scope = RPGMapAssetScope(map: path, engine: engine) else {
                throw GameProjectError.invalidRelativePath
            }
            let bytes = try await session.documentBytes(at: path)
            let document = try RPGMapDocument.decode(bytes, engine: engine, pathName: path.value)
            let newMap = try document.editableTileMap()
            let files = session.baseProject.files.compactMap { scope.assetPath(for: $0.path) }
            let repository = session.repository
            let projectID = session.projectID
            let owner = session.owner
            let revision = session.expectedRevision
            let baseReader: @Sendable (GameRelativePath) async throws -> Data = { path in
                try await repository.read(projectID, owner: owner, revision: revision,
                                          path: scope.repositoryPath(for: path))
            }
            let newCatalog = try await RPGTilesetCatalog.load(
                engine: engine, files: files, reader: baseReader)
            guard loadToken == token else { return }
            let index = RPGProjectFileIndex(paths: files)
            let newPresentation = RPGMapPresentationLoader.load(document: document, projectIndex: index)
            let newDefinition = newCatalog.definition(id: newPresentation.tilesetID)
            let newGeneration = await context.bind(projectID: projectID,
                                                    revision: session.expectedRevision)
            await context.update(catalog: newCatalog)
            guard loadToken == token else { return }
            generation = newGeneration

            var images: [String: CGImage] = [:]
            var sizes: [String: CGSize] = [:]
            var newDiagnostics = newCatalog.diagnostics + newPresentation.diagnostics
            if let newDefinition {
                let paths = Set(imagePaths(for: newDefinition))
                for imagePath in paths.sorted() {
                    do {
                        guard let relative = try? GameRelativePath(imagePath) else { continue }
                        let decoded = try await context.image(
                            at: imagePath, generation: newGeneration,
                            reader: { try await baseReader(relative) })
                        guard loadToken == token else { return }
                        images[imagePath] = decoded.image
                        sizes[imagePath] = decoded.size
                    } catch {
                        newDiagnostics.append(.init(
                            code: "tileset.image.decode", severity: .warning,
                            messageEN: "The tileset image \(imagePath) could not be decoded; its map data is kept.",
                            messageZH: "图块图片 \(imagePath) 无法解码；地图数据会保留。", path: imagePath))
                    }
                }
            }

            var characters: [String: CGImage] = [:]
            var characterSizes: [String: CGSize] = [:]
            for event in newPresentation.events.values {
                guard let imagePath = event.imagePath, characters[imagePath] == nil,
                      let relative = try? GameRelativePath(imagePath) else { continue }
                do {
                    let decoded = try await context.image(
                        at: imagePath, generation: newGeneration,
                        reader: { try await baseReader(relative) })
                    guard loadToken == token else { return }
                    characters[imagePath] = decoded.image
                    characterSizes[imagePath] = decoded.size
                } catch {
                    newDiagnostics.append(.init(
                        code: "character.image.decode", severity: .info,
                        messageEN: "A character image could not be decoded; the event marker is kept.",
                        messageZH: "行走图无法解码；已保留事件标记。", path: imagePath))
                }
            }
            guard loadToken == token else { return }
            map = newMap
            catalog = newCatalog
            definition = newDefinition
            presentation = newPresentation
            tilesetImages = images
            imageSizes = sizes
            characterImages = characters
            characterImageSizes = characterSizes
            diagnostics = newDiagnostics
            palette = newDefinition.map {
                RPGTilePaletteBuilder.build(definition: $0, engine: engine, imageSizes: sizes)
            }
            cropCache = [:]
            isLoading = false
        } catch {
            guard loadToken == token else { return }
            isLoading = false
            loadError = String(describing: error)
            diagnostics = [.init(code: "map.load.failed", severity: .error,
                messageEN: "This map could not be opened. The original file is kept; open it in the IDE or ask AI to inspect it.",
                messageZH: "无法打开此地图。原文件已保留，可打开 IDE 或让 AI 检查。", path: path.value)]
        }
    }

    public func plan(visibleCells: CGRect, animationFrame: Int = 0) -> RPGTileRenderPlan? {
        guard let map else { return nil }
        let planner = RPGTileMapPlanner(
            map: map, definition: definition, presentation: presentation,
            engine: engine, imageSizes: imageSizes, characterImageSizes: characterImageSizes)
        return planner.plan(visibleCells: visibleCells, animationFrame: animationFrame)
    }

    public func fullPlan(animationFrame: Int = 0) -> RPGTileRenderPlan? {
        guard let map else { return nil }
        let planner = RPGTileMapPlanner(
            map: map, definition: definition, presentation: presentation,
            engine: engine, imageSizes: imageSizes, characterImageSizes: characterImageSizes)
        return planner.fullPlan(animationFrame: animationFrame)
    }

    /// Cropped sprite for Canvas/SwiftUI. CGImage cropping shares the decoded
    /// backing store; the small LRU avoids repeating the same crop per frame.
    public func sprite(path imagePath: String, source: CGRect) -> CGImage? {
        guard let image = tilesetImages[imagePath] ?? characterImages[imagePath] else { return nil }
        let key = "\(imagePath)|\(Int(source.minX)),\(Int(source.minY)),\(Int(source.width)),\(Int(source.height))"
        if let cached = cropCache[key] { return cached }
        let integral = CGRect(x: source.minX.rounded(), y: source.minY.rounded(),
                              width: source.width.rounded(), height: source.height.rounded())
        guard let cropped = image.cropping(to: integral) else { return nil }
        if cropCache.count >= 4_096 { cropCache.removeAll(keepingCapacity: true) }
        cropCache[key] = cropped
        return cropped
    }

    public func characterSheetImage(path: String) -> CGImage? { characterImages[path] }

    public func commit(summary: GameEditCopy,
                       _ transform: @escaping (inout EditableTileMap) -> Void) async throws {
        try await session.editTileMapDocument(
            at: path, binding: session.adapter.tileMapBinding(for: path, in: session.baseProject),
            summary: summary, transform)
        await reload()
    }

    private func imagePaths(for definition: RPGTilesetDefinition) -> [String] {
        if definition.engine == .rpgMakerXP {
            var result: [String] = []
            if let path = definition.xpTilesetPath { result.append(path) }
            result.append(contentsOf: definition.xpAutotilePaths.compactMap { $0 })
            return result
        }
        return RPGTilesetSection.allCases.compactMap { definition.sectionPaths[$0] }
    }
}
