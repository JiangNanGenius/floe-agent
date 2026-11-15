// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GamePortableStarter: String, CaseIterable, Codable, Equatable, Sendable {
    case mv = "rpgMakerMVStarter"
    case love = "loveStarter"
    case renpy = "renpyStarter"

    public var engine: GameEngineID {
        switch self { case .mv: .rpgMakerMV; case .love: .love; case .renpy: .renpy }
    }
    var directory: String {
        switch self { case .mv: "mv"; case .love: "love"; case .renpy: "renpy" }
    }
    var sourceEntry: GameRelativePath {
        switch self {
        case .mv: GamePortableAdapterSupport.path("index.html")
        case .love: GamePortableAdapterSupport.path("main.lua")
        case .renpy: GamePortableAdapterSupport.path("game/script.rpy")
        }
    }
}

public struct GamePortableTemplateSummary: Codable, Equatable, Sendable {
    public let starter: GamePortableStarter
    public let engine: GameEngineID
    public let entry: GameRelativePath
    public let files: Int
    public let bytes: Int
    public init(starter: GamePortableStarter, engine: GameEngineID,
                entry: GameRelativePath, files: Int, bytes: Int) {
        self.starter = starter; self.engine = engine; self.entry = entry
        self.files = files; self.bytes = bytes
    }
}

public struct GamePortableTemplate: Sendable {
    public let starter: GamePortableStarter
    public let engine: GameEngineID
    public let rootURL: URL
    public let entry: GameRelativePath
    public let files: [GamePortableFileRecord]
    public var summary: GamePortableTemplateSummary {
        .init(starter: starter, engine: engine, entry: entry, files: files.count,
              bytes: files.reduce(0) { $0 + $1.bytes })
    }
}

public enum GamePortableTemplateCatalog {
    public static func load(_ starter: GamePortableStarter) throws -> GamePortableTemplate {
        guard let templates = Bundle.module.url(forResource: "Templates", withExtension: nil) else {
            throw GamePortableError.templateMissing("Templates")
        }
        let root = templates.appendingPathComponent(starter.directory, isDirectory: true)
        let entries = try GamePortableFileAccess.enumerate(root: root)
        guard entries.contains(where: { !$0.directory && $0.path == starter.sourceEntry }) else {
            throw GamePortableError.templateMissing(starter.rawValue)
        }
        let files = try entries.filter { !$0.directory }.map {
            try GamePortableFileAccess.record(root: root, path: $0.path.value,
                maximumBytes: max($0.bytes + 1, 1))
        }
        return .init(starter: starter, engine: starter.engine, rootURL: root,
                     entry: starter.sourceEntry, files: files)
    }

    public static func install(_ starter: GamePortableStarter, to destination: URL) throws -> GamePortableTemplateSummary {
        let template = try load(starter)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GamePortableError.destinationExists
        }
        _ = try GamePortableFileAccess.copyTree(from: template.rootURL, to: destination)
        return template.summary
    }

    public static func summaries() throws -> [GamePortableTemplateSummary] {
        try GamePortableStarter.allCases.map { try load($0).summary }
    }
}

/// Build-time overlays are original Floe adapter files. They are applied to a
/// built artifact only; the imported source tree is never rewritten.
public enum GamePortableOverlayInstaller {
    public static func install(engine: GameEngineID, into directory: URL) throws {
        guard engine == .love || engine == .renpy else {
            if engine == .rpgMakerMV { return }
            throw GamePortableError.unsupportedEngine(engine)
        }
        guard let overlays = Bundle.module.url(forResource: "Overlays", withExtension: nil) else {
            throw GamePortableError.templateMissing("Overlays")
        }
        let folder = overlays.appendingPathComponent(engine == .love ? "love" : "renpy", isDirectory: true)
        for name in ["floe_bridge.js", "floe-inputs.json"] {
            let target = directory.appendingPathComponent(name)
            // A project-provided declaration wins; only the bridge is refreshed.
            if name == "floe-inputs.json" && FileManager.default.fileExists(atPath: target.path) { continue }
            let data = try GamePortableFileAccess.read(root: folder, path: name, maximumBytes: 262_144)
            try GamePortableFileAccess.writeAtomic(data, to: target)
        }
        let indexURL = directory.appendingPathComponent("index.html")
        let index = try GamePortableFileAccess.read(root: directory, path: "index.html", maximumBytes: 4 * 1_024 * 1_024)
        guard var text = String(data: index, encoding: .utf8) else {
            throw GamePortableError.invalidArtifact("index.html encoding")
        }
        if !text.contains("floe_bridge.js") {
            let tag = "  <script src=\"floe_bridge.js\"></script>\n"
            if let range = text.range(of: "</body>") {
                text.insert(contentsOf: tag, at: range.lowerBound)
            } else if let range = text.range(of: "</html>") {
                text.insert(contentsOf: tag, at: range.lowerBound)
            } else {
                text += "\n" + tag
            }
            try GamePortableFileAccess.writeAtomic(Data(text.utf8), to: indexURL)
        }
    }
}

public enum GamePortableRuntimePins {
    public static func load() throws -> [GamePortableRuntimePin] {
        guard let root = Bundle.module.url(forResource: "Manifests", withExtension: nil) else {
            throw GamePortableError.invalidResourceManifest("Manifests bundle")
        }
        let entries = try GamePortableFileAccess.enumerate(root: root)
        var pins: [GamePortableRuntimePin] = []
        var ids = Set<String>()
        for entry in entries where !entry.directory && entry.path.value.hasSuffix(".json") {
            let data = try GamePortableFileAccess.read(root: root, path: entry.path.value,
                maximumBytes: 262_144)
            let pin = try GamePortableRuntimePin(from: data)
            guard ids.insert(pin.id).inserted else {
                throw GamePortableError.invalidResourceManifest("duplicate pin \(pin.id)")
            }
            pins.append(pin)
        }
        guard pins.count == 3 else { throw GamePortableError.invalidResourceManifest("three runtime pins") }
        return pins.sorted { $0.id < $1.id }
    }

    public static func pin(id: String) throws -> GamePortableRuntimePin {
        guard let pin = try load().first(where: { $0.id == id }) else {
            throw GamePortableError.invalidResourceManifest("unknown pin \(id)")
        }
        return pin
    }
}
