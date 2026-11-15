// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import ImageIO
import FloeGameCore
import FloeGameEditingCore

/// Adapter used by the sample: asset classification, a character parameter
/// schema, and codecs for the editor staging tile/narrative formats. Real
/// engine owners (e.g. FloeRPGProjectKit) provide the same contract for
/// engine-native bytes.
struct SampleAdapter: GameEditingAdapter {
    let engine: GameEngineID = .phaser

    func assetKind(for path: GameRelativePath, in project: GameStoredProject) -> GameAssetKind? {
        if path.value.hasSuffix(".png") { return .image }
        if path.value.hasSuffix(".floetilemap.json") { return .map }
        if path.value.hasSuffix(".lua") { return .script }
        if path.value.hasSuffix(".json") { return .data }
        return nil
    }

    func parameterSchemas(in project: GameStoredProject) -> [GameParameterSchema] {
        [GameParameterSchema(id: "characters", title: GameEditCopy("Characters", "角色"), fields: [
            .init(label: GameEditCopy("Name", "名称"),
                  path: JSONFieldPath([.key("characters"), .index(0), .key("name")]), kind: .text),
            .init(label: GameEditCopy("Level", "等级"),
                  path: JSONFieldPath([.key("characters"), .index(0), .key("level")]),
                  kind: .integer(1, 99)),
            .init(label: GameEditCopy("Class", "职业"),
                  path: JSONFieldPath([.key("characters"), .index(0), .key("class")]),
                  kind: .choice(["mage", "ranger", "guard"]))
        ])]
    }

    func tileMapBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameTileMapBinding? {
        guard path.value.hasSuffix(".floetilemap.json") else { return nil }
        return GameTileMapBinding(decode: { try EditableTileMap.decode($0) },
                                  encode: { try $0.encode() })
    }

    func narrativeBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameNarrativeBinding? {
        guard path.value.contains("events"), path.value.hasSuffix(".json") else { return nil }
        return GameNarrativeBinding(
            knownCommands: [
                GameNarrativeCommandSpec(code: "dialog", title: GameEditCopy("Dialog", "对话"), fields: [
                    .init(label: GameEditCopy("Speaker", "说话人"),
                          path: JSONFieldPath([.key("speaker")]), kind: .text),
                    .init(label: GameEditCopy("Text", "文本"),
                          path: JSONFieldPath([.key("text")]), kind: .multiline)
                ])
            ],
            decode: { try NarrativeDocument.decode($0) },
            encode: { try $0.encode() })
    }
}

enum SampleProjectFactory {
    /// Original synthetic assets, generated programmatically (license-clean).
    static func pngData(side: Int, rgb: (Int, Int, Int)) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                             blue: CGFloat(rgb.2) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Creates a fresh repository, imports a new sample project, and opens an
    /// editing session on it. Mirrors the product flow: create project ->
    /// import full structure -> edit/play.
    static func makeSession() async throws -> (FileGameProjectRepository, GameEditingSession, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-game-editing-sample-\(UUID().uuidString)")
        let source = base.appendingPathComponent("import")
        let repositoryDirectory = base.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        try writeSampleTree(at: source)
        let repository = try FileGameProjectRepository(directory: repositoryDirectory)
        let stored = try await repository.importProject(
            from: source, projectID: UUID(), owner: SampleSupport.owner,
            title: "Sample Quest", engine: .phaser)
        let session = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: SampleSupport.owner,
            adapter: SampleAdapter())
        return (repository, session, base)
    }

    static func writeSampleTree(at root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("maps"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"),
                                                withIntermediateDirectories: true)
        try json([
            "characters": [["id": 1, "name": "Mira", "level": 3, "class": "mage",
                            "portrait": "assets/hero.png", "customField": ["note": "keep"]]]
        ]).write(to: root.appendingPathComponent("data/characters.json"))
        try json(["map": "maps/home.floetilemap.json", "heroSprite": "assets/hero.png"])
            .write(to: root.appendingPathComponent("data/manifest.json"))
        try Data("spawn = assets/hero.png\n".utf8).write(to: root.appendingPathComponent("data/spawn.lua"))
        try pngData(side: 16, rgb: (120, 170, 220)).write(to: root.appendingPathComponent("assets/hero.png"))
        try pngData(side: 16, rgb: (240, 200, 90)).write(to: root.appendingPathComponent("assets/coin.png"))

        let map = EditableTileMap(name: "home", tileSize: .init(width: 16, height: 16),
            layers: [.init(name: "Ground", kind: .tile, size: .init(width: 16, height: 12)),
                     .init(name: "Objects", kind: .object, size: .init(width: 16, height: 12))],
            tileSets: [.init(imagePath: try GameRelativePath("assets/hero.png"), firstGID: 1)])
        try map.encode().write(to: root.appendingPathComponent("maps/home.floetilemap.json"))

        let narrative = NarrativeDocument(title: "intro",
            labels: [.init(name: "start")],
            commands: [
                .init(code: "dialog", parameters: ["speaker": .string("Mira"),
                                                   "text": .string("Welcome to the sample.")]),
                .init(code: "legacyPluginCall", parameters: ["opaque": .bool(true)],
                      isSupported: false, originalPayload: .object(["opaque": .bool(true)]))
            ])
        try narrative.encode().write(to: root.appendingPathComponent("events/intro.json"))
    }
}

enum SampleSupport {
    static let owner = GameProjectOwner.conversation(
        conversationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        workspaceID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
}
