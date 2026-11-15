// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
@testable import FloeGamePortableKit

enum TestSupport {
    static func temporaryDirectory(_ name: String = "floe-portable-test") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to root: URL, path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: [.atomic])
    }

    static func write(_ data: Data, to root: URL, path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    static func mvInputDeclaration() -> GamePortableInputDeclaration {
        try! .init(engine: .rpgMakerMV,
            movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
            buttons: [.init(id: "confirm", label: "Z", keys: ["z", "enter"]),
                      .init(id: "action1", label: "Shift", keys: ["shift"])])
    }

    static func makeMVWebProject() throws -> URL {
        let root = try temporaryDirectory("mv-web")
        try write("<html></html>", to: root, path: "index.html")
        try write("var SceneManager={};", to: root, path: "js/rpg_core.js")
        try write("var SceneManager={};", to: root, path: "js/rpg_managers.js")
        try write("var SceneManager={};", to: root, path: "js/rpg_objects.js")
        try write("var SceneManager={};", to: root, path: "js/rpg_scenes.js")
        try write("var SceneManager={};", to: root, path: "js/rpg_sprites.js")
        try write("var SceneManager={};", to: root, path: "js/rpg_windows.js")
        try write("PluginManager.setup($plugins);", to: root, path: "js/main.js")
        try write("var $plugins=[];", to: root, path: "js/plugins.js")
        try write("{}", to: root, path: "data/System.json")
        try write("{}", to: root, path: "js/floe_bridge.js")
        try write(String(data: try mvInputDeclaration().encoded(), encoding: .utf8)!,
                  to: root, path: "floe-inputs.json")
        return root
    }

    static func makeLoveWebProject() throws -> URL {
        let root = try temporaryDirectory("love-web")
        try write("<html><body></body></html>", to: root, path: "index.html")
        try write(Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]), to: root, path: "love.wasm")
        try write("PK", to: root, path: "game.data")
        try write("function Love(){}", to: root, path: "love.js")
        try write("// bridge", to: root, path: "floe_bridge.js")
        try write("""
        {"schemaVersion":1,"engine":"love","movement":{"left":["left"],"right":["right"],"up":["up"],"down":["down"]},"buttons":[{"id":"confirm","label":"Z","keys":["z"]}]}
        """, to: root, path: "floe-inputs.json")
        return root
    }

    static func makeRenPyWebProject() throws -> URL {
        let root = try temporaryDirectory("renpy-web")
        try write("<html><body></body></html>", to: root, path: "index.html")
        try write(Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]), to: root, path: "renpy.wasm")
        try write("var Module={};", to: root, path: "renpy.js")
        var zip = Data([0x50, 0x4b, 0x03, 0x04])
        zip.append(Data(repeating: 0, count: 26))
        zip.append(Data("PK\u{05}\u{06}".utf8))
        try write(zip, to: root, path: "game.zip")
        try write("// bridge", to: root, path: "floe_bridge.js")
        try write("""
        {"schemaVersion":1,"engine":"renpy","movement":{"left":["left"],"right":["right"],"up":["up"],"down":["down"]},"buttons":[{"id":"confirm","label":"Enter","keys":["enter"]}]}
        """, to: root, path: "floe-inputs.json")
        return root
    }

    static func makePreparedResources() throws -> (root: URL, manifest: URL, resources: GamePortablePreparedResources) {
        let root = try temporaryDirectory("mv-resources")
        let files: [(String, Data)] = [
            ("js/rpg_core.js", Data("var core=1;".utf8)),
            ("js/rpg_managers.js", Data("var managers=1;".utf8)),
            ("js/rpg_objects.js", Data("var objects=1;".utf8)),
            ("js/rpg_scenes.js", Data("var scenes=1;".utf8)),
            ("js/rpg_sprites.js", Data("var sprites=1;".utf8)),
            ("js/rpg_windows.js", Data("var windows=1;".utf8)),
            ("js/libs/pixi.js", Data("var PIXI=1;".utf8)),
            ("licenses/RPG-MAKER-MV-CORESCRIPT-MIT.txt", Data("MIT".utf8))
        ]
        var records: [GamePortableFileRecord] = []
        for (path, data) in files {
            try write(data, to: root, path: path)
            records.append(.init(path: try GameRelativePath(path), sha256: GameDigest.sha256(data), bytes: data.count))
        }
        let manifest = GamePortableResourceManifest(id: "test-mv", pinID: "rpg-maker-mv-corescript",
            engine: .rpgMakerMV, version: "1.3b", runtimeID: "rpg-maker-mv-corescript", files: records)
        let manifestURL = root.deletingLastPathComponent().appendingPathComponent("test-mv.manifest.json")
        try GamePortableFileAccess.writeAtomic(try manifest.encoded(), to: manifestURL)
        return (root, manifestURL, try GamePortablePreparedResources(rootURL: root, manifestURL: manifestURL))
    }

    static func makeContext(root: URL, revision: String = "rev-1") throws -> GameProjectContext {
        let projectID = UUID()
        return try GameProjectContext(projectID: projectID, owner: .space(recordID: projectID),
            rootURL: root, savedRevision: revision)
    }
}
