// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import ImageIO
import FloeGameCore
import FloeGameEditingCore
import FloeRPGCore
@testable import FloeRPGTilesetKit

enum FixtureSupport {
    static var root: URL {
        if let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) {
            return url
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static let owner = GameProjectOwner.conversation(
        conversationID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        workspaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    struct ProjectFixture {
        let name: String
        let engine: RPGEngine
        let mapPath: String
        let referencePNG: String
    }

    static let projects: [ProjectFixture] = [
        .init(name: "xp-project", engine: .rpgMakerXP, mapPath: "Data/Map001.rxdata",
              referencePNG: "Graphics/Tilesets/FloeXP_Tiles.png"),
        .init(name: "vx-project", engine: .rpgMakerVX, mapPath: "Data/Map001.rvdata",
              referencePNG: "Graphics/System/FloeVX_A2.png"),
        .init(name: "ace-project", engine: .rpgMakerVXAce, mapPath: "Data/Map001.rvdata2",
              referencePNG: "Graphics/System/FloeAce_A2.png"),
        .init(name: "mv-project", engine: .rpgMakerMV, mapPath: "data/Map001.json",
              referencePNG: "img/tilesets/FloeMV_A2.png"),
        .init(name: "mz-project", engine: .rpgMakerMZ, mapPath: "data/Map001.json",
              referencePNG: "img/tilesets/FloeMZ_A2.png")
    ]

    static func projectRoot(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    static func files(in root: URL) throws -> [GameRelativePath] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
        var result: [GameRelativePath] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true || values.isRegularFile != true { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if let path = try? GameRelativePath(relative) { result.append(path) }
        }
        return result.sorted { $0.value < $1.value }
    }

    static func read(_ path: GameRelativePath, root: URL) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path.value))
    }

    static func reader(root: URL) -> @Sendable (GameRelativePath) async throws -> Data {
        { path in try Data(contentsOf: root.appendingPathComponent(path.value)) }
    }

    static func loadCatalog(_ fixture: ProjectFixture) async throws -> RPGTilesetCatalog {
        let root = projectRoot(fixture.name)
        let files = try files(in: root)
        return try await RPGTilesetCatalog.load(
            engine: fixture.engine, files: files, reader: reader(root: root))
    }

    static func loadDocument(_ fixture: ProjectFixture) throws -> RPGMapDocument {
        let root = projectRoot(fixture.name)
        let path = try GameRelativePath(fixture.mapPath)
        let bytes = try read(path, root: root)
        return try RPGMapDocument.decode(bytes, engine: fixture.engine, pathName: fixture.mapPath)
    }

    static func loadImageSet(_ definition: RPGTilesetDefinition, root: URL) throws -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        for path in imagePaths(definition) {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let image = try RPGTilesetImageStore.decode(data, path: path,
                limits: .init(maximumEncodedBytes: 8 * 1_024 * 1_024,
                              maximumPixelDimension: 8_192,
                              maximumPixelCount: 16_777_216,
                              maximumDecodedBytes: 64 * 1_024 * 1_024,
                              maximumCachedImages: 32,
                              maximumImageDecodedBytes: 16 * 1_024 * 1_024))
            result[path] = image.image
        }
        return result
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

    static func imageSizes(_ images: [String: CGImage]) -> [String: CGSize] {
        images.mapValues { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) }
    }

    static func pixel(of image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let result: (UInt8, UInt8, UInt8, UInt8) = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0, 0) }
            context.interpolationQuality = .none
            let sample = CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)
            guard let cropped = image.cropping(to: sample) else { return (0, 0, 0, 0) }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (buffer[0], buffer[1], buffer[2], buffer[3])
        }
        return result
    }

    static func shasum(_ bytes: Data) -> String { GameDigest.sha256(bytes) }

    static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rpg-tileset-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
