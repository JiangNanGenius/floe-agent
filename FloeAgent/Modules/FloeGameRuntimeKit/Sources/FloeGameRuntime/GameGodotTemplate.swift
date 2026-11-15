// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeGameCore

/// Original GDScript starter. Building is delegated to the existing Linux/CI
/// build service; no native Godot executable is downloaded into the iOS App.
public enum GameGodotTemplate {
    public static let qualifiedVersion = "4.7.2.stable"
    public static func create(at target: URL, title: String) throws {
        guard target.isFileURL, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 256, !FileManager.default.fileExists(atPath: target.path) else { throw GameProjectError.invalidContext }
        let parent = target.deletingLastPathComponent(), stage = parent.appendingPathComponent(".godot-template-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        var files: [String: Data] = [:]
        for name in ["project.godot", "main.tscn", "main.gd", "bridge.js"] { files[name] = try resource(name, subdirectory: "Godot") }
        files["licenses/GODOT-LICENSE.txt"] = try resource("LICENSE.txt", subdirectory: "Godot")
        files["licenses/GODOT-THIRD-PARTY.txt"] = try resource("COPYRIGHT.txt", subdirectory: "Godot")
        files["licenses/FLOE-STARTER-MIT.txt"] = try resource("LICENSE.txt", subdirectory: "Templates")
        files["game.json"] = try JSONSerialization.data(withJSONObject: ["title": title, "speed": 180, "engine": "godot", "unknownExample": ["preserved": true]], options: [.sortedKeys, .prettyPrinted])
        files["export_presets.cfg"] = Data(preset.utf8)
        files["floe-inputs.json"] = Data(#"{"schemaVersion":1,"engine":"godot","movement":{"left":["left"],"right":["right"],"up":["up"],"down":["down"]},"buttons":[]}"#.utf8)
        for (path, bytes) in files {
            try Task.checkCancellation()
            let file = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: [.atomic])
        }
        try Task.checkCancellation()
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw GameProjectError.destinationExists }
    }
    private static func resource(_ name: String, subdirectory: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/" + subdirectory) else { throw GameProjectError.corruptStorage }
        return try Data(contentsOf: url)
    }
    /// Godot packs source resources into .pck. Browser-side bridge and license
    /// files must also be visible alongside the exported HTML, not only in .pck.
    public static func finalizeWebExport(sourceDirectory: URL, exportDirectory: URL) throws {
        guard sourceDirectory.isFileURL, exportDirectory.isFileURL,
              FileManager.default.fileExists(atPath: exportDirectory.appendingPathComponent("index.html").path) else { throw GameProjectError.invalidArtifact }
        for name in ["bridge.js", "floe-inputs.json", "licenses/GODOT-LICENSE.txt", "licenses/GODOT-THIRD-PARTY.txt", "licenses/FLOE-STARTER-MIT.txt"] {
            let source = sourceDirectory.appendingPathComponent(name), target = exportDirectory.appendingPathComponent(name)
            guard source.resolvingSymlinksInPath().path.hasPrefix(sourceDirectory.resolvingSymlinksInPath().path + "/"),
                  (try source.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])).isSymbolicLink != true,
                  (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 262_144 else { throw GameProjectError.invalidArtifact }
            guard !FileManager.default.fileExists(atPath: target.path) else { throw GameProjectError.destinationExists }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try Data(contentsOf: source)
            try bytes.write(to: target, options: [.withoutOverwriting])
            guard try Data(contentsOf: target) == bytes else { throw GameProjectError.corruptStorage }
        }
    }
    private static let preset = """
    [preset.0]
    name="Web"
    platform="Web"
    runnable=true
    export_filter="all_resources"
    include_filter="game.json,bridge.js,floe-inputs.json,licenses/*"
    exclude_filter=""
    export_path="build/index.html"

    [preset.0.options]
    custom_template/debug=""
    custom_template/release=""
    variant/extensions_support=false
    variant/thread_support=false
    vram_texture_compression/for_desktop=true
    vram_texture_compression/for_mobile=false
    html/export_icon=false
    html/custom_html_shell=""
    html/head_include="<script src='bridge.js'></script>"
    html/canvas_resize_policy=2
    html/focus_canvas_on_start=true
    progressive_web_app/enabled=false
    """
}
