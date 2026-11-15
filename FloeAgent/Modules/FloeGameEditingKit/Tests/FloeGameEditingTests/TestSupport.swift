// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import ImageIO
import FloeGameCore
@testable import FloeGameEditingCore

struct TestSupport {
    static func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-editing-tests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func jsonBytes(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A small but real synthetic project: one parameter JSON, one tile map
    /// staging file, one narrative staging file, one text script referencing
    /// the image, and one original PNG asset.
    static func createSampleProject(at root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("maps"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"),
                                                withIntermediateDirectories: true)
        try jsonBytes([
            "characters": [["id": 1, "name": "Mira", "level": 3, "class": "mage",
                            "portrait": "assets/hero.png",
                            "equipment": ["weapon": "wand"], "customField": ["note": "keep"]]]
        ]).write(to: root.appendingPathComponent("data/characters.json"))
        try jsonBytes([
            "map": "maps/home.floetilemap.json",
            "heroSprite": "assets/hero.png"
        ]).write(to: root.appendingPathComponent("data/manifest.json"))
        try Data("spawn = assets/hero.png\nbackground assets/hero.png\n".utf8)
            .write(to: root.appendingPathComponent("data/spawn.lua"))
        try pngData(side: 8, rgb: (120, 170, 220)).write(to: root.appendingPathComponent("assets/hero.png"))

        let map = EditableTileMap(name: "home", tileSize: .init(width: 16, height: 16),
                                  layers: [.init(name: "Ground", kind: .tile,
                                                 size: .init(width: 8, height: 6)),
                                           .init(name: "Objects", kind: .object,
                                                 size: .init(width: 8, height: 6))],
                                  tileSets: [.init(imagePath: try GameRelativePath("assets/hero.png"),
                                                   firstGID: 1)])
        try map.encode().write(to: root.appendingPathComponent("maps/home.floetilemap.json"))

        let narrative = NarrativeDocument(title: "intro",
            labels: [.init(name: "start")],
            commands: [
                .init(code: "dialog", parameters: ["speaker": .string("Mira"),
                                                   "text": .string("Hello.")]),
                .init(code: "mysteryPluginCall", parameters: ["raw": .number(7)],
                      isSupported: false, originalPayload: .object(["raw": .number(7)]))
            ])
        try narrative.encode().write(to: root.appendingPathComponent("events/intro.json"))
    }

    /// Deterministic original PNG (solid color), license-clean.
    static func pngData(side: Int, rgb: (Int, Int, Int)) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                             blue: CGFloat(rgb.2) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }

    static func makeRepository(name: String) throws -> (URL, FileGameProjectRepository) {
        let root = try makeTemporaryDirectory(name)
        return (root, try FileGameProjectRepository(directory: root))
    }

    static let owner = GameProjectOwner.conversation(
        conversationID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        workspaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    static func sampleSchema() -> GameParameterSchema {
        GameParameterSchema(id: "characters", title: GameEditCopy("Characters", "角色"), fields: [
            .init(label: GameEditCopy("Name", "名称"),
                  path: JSONFieldPath([.key("characters"), .index(0), .key("name")]), kind: .text),
            .init(label: GameEditCopy("Level", "等级"),
                  path: JSONFieldPath([.key("characters"), .index(0), .key("level")]),
                  kind: .integer(1, 99)),
            .init(label: GameEditCopy("Class", "职业"),
                  path: JSONFieldPath([.key("characters"), .index(0), .key("class")]),
                  kind: .choice(["mage", "ranger", "guard"]))
        ])
    }
}
