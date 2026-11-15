// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameEditingCore
import FloeGameSpriteCore

enum SpriteTestSupport {
    static let owner = GameProjectOwner.conversation(
        conversationID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        workspaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-sprite-tests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func image(width: Int, height: Int, fill: SpriteRGBA = .clear) throws -> SpritePixelImage {
        try SpritePixelImage(width: width, height: height, fill: fill)
    }

    /// Deterministic multi-frame sheet. Each frame gets a distinct, fully
    /// opaque color and its top-left pixel becomes the frame's index color.
    static func sheet(columns: Int, rows: Int,
                      frameWidth: Int, frameHeight: Int) throws -> SpritePixelImage {
        var image = try SpritePixelImage(width: columns * frameWidth,
                                         height: rows * frameHeight,
                                         fill: .clear)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let color = SpriteRGBA(
                    red: UInt8((index * 37 + 11) % 256),
                    green: UInt8((index * 67 + 23) % 256),
                    blue: UInt8((index * 97 + 41) % 256),
                    alpha: 255)
                for y in (row * frameHeight)..<((row + 1) * frameHeight) {
                    for x in (column * frameWidth)..<((column + 1) * frameWidth) {
                        image.setColor(color, x: x, y: y)
                    }
                }
            }
        }
        return image
    }

    static func truncated(_ data: Data) -> Data {
        guard data.count > 24 else { return Data() }
        return data.prefix(data.count / 2)
    }

    static func makeProject(name: String,
                            sheet: SpritePixelImage) async throws
        -> (FileGameProjectRepository, GameEditingSession, GameRelativePath, [UInt8]) {
        let repositoryRoot = try temporaryDirectory(name + "-repo")
        let sourceRoot = try temporaryDirectory(name + "-source")
        try FileManager.default.createDirectory(at: sourceRoot.appendingPathComponent("assets"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot.appendingPathComponent("notes"),
                                                withIntermediateDirectories: true)
        let relative = try GameRelativePath("assets/hero.png")
        let png = try SpritePNG.encode(sheet)
        try png.write(to: sourceRoot.appendingPathComponent(relative.value))
        let unknown = Data("keep this unrelated file".utf8)
        try unknown.write(to: sourceRoot.appendingPathComponent("notes/keep.bin"))

        let repository = try FileGameProjectRepository(directory: repositoryRoot)
        let stored = try await repository.importProject(
            from: sourceRoot, projectID: UUID(), owner: owner,
            title: "Sprite \(name)", engine: .rpgMakerMV)
        let session = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: owner,
            adapter: GameUnknownEditingAdapter(engine: .rpgMakerMV))
        return (repository, session, relative, [UInt8](unknown))
    }
}
