// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeGameCore

/// Real engine starters with separate editable source/configuration and MIT
/// starter files. Upstream SDK licenses retain their own terms.
public enum GameScriptTemplate {
    public static func create(at target: URL, resources: GameEngineResourcePack, title: String) throws {
        guard target.isFileURL, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 256, !FileManager.default.fileExists(atPath: target.path) else { throw GameProjectError.invalidContext }
        let engine = resources.spec.engine
        guard [.kaplay, .babylon, .playcanvas].contains(engine) else { throw GameProjectError.unsupportedRoute(engine) }
        var files = try resources.verifiedFiles()
        let config = try JSONSerialization.data(withJSONObject: ["title": title, "speed": 180, "engine": engine.rawValue, "engineVersion": resources.spec.version, "unknownExample": ["preserved": true]], options: [.sortedKeys, .prettyPrinted])
        files[try GameRelativePath("game.json")] = config
        files[try GameRelativePath("package.json")] = try JSONSerialization.data(withJSONObject: ["private": true, "dependencies": [resources.spec.package: resources.spec.version]], options: [.sortedKeys])
        files[try GameRelativePath("index.html")] = Data(html.utf8)
        files[try GameRelativePath("game.js")] = try resource(engine.rawValue, "js")
        files[try GameRelativePath("common.js")] = try resource("common", "js")
        files[try GameRelativePath("licenses/FLOE-STARTER-MIT.txt")] = try resource("LICENSE", "txt")
        files[try GameRelativePath("engine-provenance.json")] = try JSONEncoder().encode(resources.spec)
        files[try GameRelativePath("floe-inputs.json")] = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "engine": engine.rawValue,
            "movement": ["left": ["left"], "right": ["right"], "up": ["up"], "down": ["down"]], "buttons": [[String: Any]]()] as [String: Any], options: [.sortedKeys])
        let parent = target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".game-template-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        for (path, bytes) in files {
            try Task.checkCancellation()
            let url = stage.appendingPathComponent(path.value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: [.atomic])
        }
        try Task.checkCancellation()
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw GameProjectError.destinationExists }
    }
    private static func resource(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources/Templates") else { throw GameProjectError.corruptStorage }
        return try Data(contentsOf: url)
    }
    private static let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Floe game</title><style>html,body{margin:0;background:#142630;color:#fff;font:16px system-ui;width:100%;height:100%;overflow:hidden}canvas{display:block;width:100%;height:100%;touch-action:none}#score{position:fixed;left:24px;top:12px;pointer-events:none}</style>
    <script src="runtime/engine.js"></script></head><body><canvas id="game" width="800" height="480"></canvas><p id="score"></p><script src="game.js"></script><script src="common.js"></script></body></html>
    """
}
