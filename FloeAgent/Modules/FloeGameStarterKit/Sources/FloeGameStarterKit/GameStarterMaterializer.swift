// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeGameCore
import FloeGameTouch
import FloeRPGCore
import FloeGamePortableKit
import FloeGameNarrativeKit
import FloeGameGDevelopKit

/// Optional prepared engine packs. The host's existing GameEnginePackStore is
/// the normal producer; this type is only the handoff to the scaffolder.
public struct GameStarterResources: Sendable {
    public var phaser: URL?
    public var enginePacks: [GameEngineID: URL]

    public init(phaser: URL? = nil, enginePacks: [GameEngineID: URL] = [:]) {
        self.phaser = phaser
        self.enginePacks = enginePacks
    }

    public func pack(for engine: GameEngineID) -> URL? {
        if engine == .phaser { return phaser ?? enginePacks[engine] }
        return enginePacks[engine]
    }

    /// Convenience for CLI/preflight: recognizes the checked prepared-pack
    /// directory names used by the existing qualification artifacts.
    public static func from(root: URL) -> GameStarterResources {
        let fileManager = FileManager.default
        let root = root.standardizedFileURL
        var result = GameStarterResources()
        if fileManager.fileExists(atPath: root.appendingPathComponent("phaser.js").path) {
            result.phaser = root
        }
        let children = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for child in children {
            let name = child.lastPathComponent.lowercased()
            if name.hasPrefix("phaser"), result.phaser == nil,
               fileManager.fileExists(atPath: child.appendingPathComponent("phaser.js").path) {
                result.phaser = child
            }
            for engine in [GameEngineID.kaplay, .babylon, .playcanvas] where name.hasPrefix(engine.rawValue) {
                if fileManager.fileExists(atPath: child.appendingPathComponent("runtime/engine.js").path) {
                    result.enginePacks[engine] = child
                }
            }
        }
        return result
    }
}

struct GameStarterMaterializer: Sendable {
    let catalog: GameStarterCatalog
    let resources: GameStarterResources
    let limits: GameStarterLimits

    func materialize(descriptor: GameStarterDescriptor, title: String, stage: URL) throws {
        guard !FileManager.default.fileExists(atPath: stage.path) else {
            throw GameStarterError.invalidTemplate("stage already exists")
        }
        switch descriptor.templateKind {
        case .static:
            try installStatic(descriptor: descriptor, title: title, stage: stage)
        case .runtimePack:
            try installRuntimePack(descriptor: descriptor, title: title, stage: stage)
        case .delegated:
            try installDelegated(descriptor: descriptor, title: title, stage: stage)
        }
        guard FileManager.default.fileExists(atPath: stage.path) else {
            throw GameStarterError.invalidTemplate("provider did not create the project")
        }
        try finalize(descriptor: descriptor, title: title, stage: stage)
    }

    // MARK: - Static templates

    private func installStatic(descriptor: GameStarterDescriptor, title: String, stage: URL) throws {
        guard let source = catalog.staticTemplateURL(for: descriptor) else {
            throw GameStarterError.invalidTemplate("missing static template \(descriptor.engine.rawValue)")
        }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let actual = try enumerate(source)
        guard actual == descriptor.files.map(\.path.value).sorted() else {
            throw GameStarterError.invalidTemplate("file set mismatch \(descriptor.engine.rawValue)")
        }
        for file in descriptor.files {
            try Task.checkCancellation()
            let from = source.appendingPathComponent(file.path.value)
            let data = try GameStarterFileSupport.read(from, maximum: limits.maximumFileBytes)
            guard data.count == file.bytes,
                  SHA256.hash(data: data).hexString == file.sha256 else {
                throw GameStarterError.invalidTemplate("hash mismatch \(file.path.value)")
            }
            try GameStarterFileSupport.write(data, to: stage.appendingPathComponent(file.path.value))
        }
        try personalizeStatic(descriptor: descriptor, title: title, stage: stage)
    }

    private func personalizeStatic(descriptor: GameStarterDescriptor, title: String, stage: URL) throws {
        let engine = descriptor.engine
        switch engine {
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            try GameStarterFileSupport.replaceText(
                in: stage.appendingPathComponent("Game.ini"),
                from: "Title=Glimmerfen", to: "Title=" + title)
            try normalizeLegacyRPGData(engine: engine, title: title, stage: stage)
        case .rpgMakerMZ:
            try GameStarterFileSupport.updateJSON(
                stage.appendingPathComponent("data/System.json")) { object in
                object["gameTitle"] = title
            }
        case .godot:
            try GameStarterFileSupport.updateJSON(
                stage.appendingPathComponent("game.json")) { object in
                object["title"] = title
            }
            try GameStarterFileSupport.replaceText(
                in: stage.appendingPathComponent("project.godot"),
                from: "config/name=\"Floe Godot game\"",
                to: "config/name=\"" + godotEscaped(title) + "\"")
        case .unity:
            try GameStarterFileSupport.replaceText(
                in: stage.appendingPathComponent("ProjectSettings/ProjectSettings.asset"),
                from: "productName: Glimmerfen",
                to: "productName: \"" + yamlEscaped(title) + "\"")
        case .cocosCreator:
            break
        default:
            break
        }
        for name in ["README.md", "README"] {
            let url = stage.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try GameStarterFileSupport.replaceFirstOccurrence(
                    in: url, from: "Glimmerfen", to: title)
            }
        }
    }

    /// Normalizes every standard legacy RPG data file through FloeRPGCore
    /// before the repository imports it. This is the real production codec
    /// path, not a second parser: the static template bytes are decoded,
    /// edited where needed, re-encoded, and checked against the starter data
    /// contract. A malformed template fails closed before any commit.
    private func normalizeLegacyRPGData(engine: GameEngineID, title: String, stage: URL) throws {
        let rpgEngine: RPGEngine
        let ext: String
        switch engine {
        case .rpgMakerXP: rpgEngine = .rpgMakerXP; ext = "rxdata"
        case .rpgMakerVX: rpgEngine = .rpgMakerVX; ext = "rvdata"
        case .rpgMakerVXAce: rpgEngine = .rpgMakerVXAce; ext = "rvdata2"
        default: return
        }
        let dataDirectory = stage.appendingPathComponent("Data", isDirectory: true)
        let names = ["Actors", "Classes", "Skills", "Items", "Weapons", "Armors",
                     "Enemies", "Troops", "States", "Animations", "Tilesets",
                     "CommonEvents", "System", "MapInfos"]
        for name in names {
            let path = "Data/\(name).\(ext)"
            let url = dataDirectory.appendingPathComponent("\(name).\(ext)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let bytes = try GameStarterFileSupport.read(url, maximum: limits.maximumFileBytes)
            let kind = RPGDataFileKind.classify(path, engine: rpgEngine)
            if kind == .system, engine != .rpgMakerXP {
                var document = try RPGDataDocument.decode(bytes, kind: .system, engine: rpgEngine)
                guard let root = document.root else {
                    throw GameStarterError.invalidTemplate("System data has no root")
                }
                root.setStringMember("@game_title", title)
                document = RPGDataDocument(kind: .system, engine: rpgEngine, root: root)
                let encoded = try document.encode()
                try GameStarterFileSupport.write(encoded, to: url)
            } else {
                let document = try RPGDataDocument.decode(bytes, kind: kind, engine: rpgEngine)
                let encoded = try document.encode()
                try GameStarterFileSupport.write(encoded, to: url)
            }
        }
        let mapURL = dataDirectory.appendingPathComponent("Map001.\(ext)")
        let mapBytes = try GameStarterFileSupport.read(mapURL, maximum: limits.maximumFileBytes)
        let map = try RPGMapDocument.decode(mapBytes, engine: rpgEngine,
                                            pathName: "Map001.\(ext)")
        guard map.width == 12, map.height == 10, map.events.count == 2,
              map.events.map(\.name).sorted() == ["Ferry Keeper", "Notice Stone"],
              map.table != nil else {
            throw GameStarterError.invalidTemplate("legacy RPG map contract")
        }
        let encodedMap = try map.encode()
        try GameStarterFileSupport.write(encodedMap, to: mapURL)

        let scriptURL = dataDirectory.appendingPathComponent("Scripts.\(ext)")
        let scriptBytes = try GameStarterFileSupport.read(scriptURL, maximum: limits.maximumFileBytes)
        let scripts = try RPGScriptArchive.decode(scriptBytes)
        guard scripts.count == 1,
              scripts[0].title.utf8String == "FloeStarter",
              String(decoding: scripts[0].source, as: UTF8.self).contains("FloeStarterScene") else {
            throw GameStarterError.invalidTemplate("legacy RPG script contract")
        }
        let encodedScripts = try RPGScriptArchive.encode(scripts)
        try GameStarterFileSupport.write(encodedScripts, to: scriptURL)

        let actorURL = dataDirectory.appendingPathComponent("Actors.\(ext)")
        let actorBytes = try GameStarterFileSupport.read(actorURL, maximum: limits.maximumFileBytes)
        let actors = try RPGDataDocument.decode(actorBytes, kind: .actors, engine: rpgEngine)
        guard actors.binaryRecords().count > 1,
              actors.binaryRecords()[1]?.stringMember("@name") == "Kestrel" else {
            throw GameStarterError.invalidTemplate("legacy RPG actor contract")
        }
    }

    // MARK: - Runtime-pack templates

    private func installRuntimePack(descriptor: GameStarterDescriptor, title: String, stage: URL) throws {
        guard let pack = resources.pack(for: descriptor.engine) else {
            let expected = descriptor.runtimePack?.files.map(\.path.value) ?? []
            throw GameStarterError.missingRuntimePack(
                engine: descriptor.engine,
                packID: descriptor.runtimePack?.id ?? "unknown",
                expectedFiles: expected)
        }
        if descriptor.engine == .phaser {
            try GamePhaserTemplate.create(at: stage, resources: pack, title: title)
            return
        }
        guard let runtime = descriptor.runtimePack else {
            throw GameStarterError.invalidTemplate("runtime pack descriptor")
        }
        for file in runtime.files {
            let url = pack.appendingPathComponent(file.path.value)
            let data = try GameStarterFileSupport.read(url, maximum: limits.maximumFileBytes)
            guard data.count == file.bytes,
                  SHA256.hash(data: data).hexString == file.sha256 else {
                throw GameStarterError.invalidTemplate("runtime pack hash mismatch \(file.path.value)")
            }
        }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        guard let index = catalog.runtimeTemplateURL("index.html"),
              let common = catalog.runtimeTemplateURL("common.js"),
              let game = catalog.runtimeTemplateURL(descriptor.engine.rawValue + ".js"),
              let license = catalog.runtimeTemplateURL("LICENSE-FLOE-STARTER-MIT.txt") else {
            throw GameStarterError.invalidTemplate("runtime template resources")
        }
        let files: [(URL, String)] = [
            (index, "index.html"), (common, "common.js"),
            (game, "game.js"), (license, "licenses/FLOE-STARTER-MIT.txt"),
        ]
        for (source, destination) in files {
            let data = try GameStarterFileSupport.read(source, maximum: limits.maximumFileBytes)
            try GameStarterFileSupport.write(data, to: stage.appendingPathComponent(destination))
        }
        for file in runtime.files {
            let data = try GameStarterFileSupport.read(pack.appendingPathComponent(file.path.value),
                                                       maximum: limits.maximumFileBytes)
            try GameStarterFileSupport.write(data, to: stage.appendingPathComponent(file.path.value))
        }
        let package: String
        switch descriptor.engine {
        case .kaplay: package = "kaplay"
        case .babylon: package = "babylonjs"
        case .playcanvas: package = "playcanvas"
        default: throw GameStarterError.unsupportedEngine(descriptor.engine)
        }
        let config: [String: Any] = [
            "title": title, "speed": 180, "engine": descriptor.engine.rawValue,
            "engineVersion": runtime.engineVersion,
            "unknownExample": ["preserved": true],
        ]
        let configData = try JSONSerialization.data(withJSONObject: config,
                                                    options: [.sortedKeys, .prettyPrinted])
        try GameStarterFileSupport.write(configData + Data([10]),
                                         to: stage.appendingPathComponent("game.json"))
        let packageData = try JSONSerialization.data(
            withJSONObject: ["private": true, "dependencies": [package: runtime.engineVersion]],
            options: [.sortedKeys, .prettyPrinted])
        try GameStarterFileSupport.write(packageData + Data([10]),
                                         to: stage.appendingPathComponent("package.json"))
        let provenance = try JSONEncoder.sorted.encode(runtime)
        try GameStarterFileSupport.write(provenance + Data([10]),
                                         to: stage.appendingPathComponent("engine-provenance.json"))
        let inputs = try descriptor.defaultInput.encoded()
        try GameStarterFileSupport.write(inputs,
                                         to: stage.appendingPathComponent("floe-inputs.json"))
    }

    // MARK: - Delegated component starters

    private func installDelegated(descriptor: GameStarterDescriptor, title: String, stage: URL) throws {
        switch descriptor.engine {
        case .rpgMakerMV:
            _ = try GamePortableTemplateCatalog.install(.mv, to: stage)
        case .love:
            _ = try GamePortableTemplateCatalog.install(.love, to: stage)
        case .renpy:
            _ = try GamePortableTemplateCatalog.install(.renpy, to: stage)
        case .ink:
            try GameInkAdapter.createProject(at: stage, title: title)
        case .twine:
            try GameTwineAdapter.createProject(at: stage, title: title)
            try GameStarterFileSupport.rewriteTwineIFID(at: stage, title: title)
        case .tic80:
            try GameTIC80Adapter.createProject(at: stage, title: title)
        case .wasm4:
            try GameWasm4Adapter.createProject(at: stage, title: title)
        case .microStudio:
            try GameMicroStudioAdapter.createProject(at: stage, title: title)
        case .gdevelop:
            try installGDevelop(title: title, stage: stage)
        default:
            throw GameStarterError.unsupportedEngine(descriptor.engine)
        }
    }

    private func installGDevelop(title: String, stage: URL) throws {
        let projectUUID = GameStarterDeterminism.uuid("gdevelop:" + title)
        let files = try GameGDevelopTemplate.makeProject(title: title, projectUUID: projectUUID)
        for (path, data) in files {
            try GameStarterFileSupport.write(data, to: stage.appendingPathComponent(path.value))
        }
        guard let mit = catalog.licenseURL("FLOE-STARTER-MIT.txt"),
              let notices = catalog.licenseURL("GDEVELOP-THIRD-PARTY-NOTICES.txt") else {
            throw GameStarterError.invalidTemplate("GDevelop notices")
        }
        try GameStarterFileSupport.write(
            try GameStarterFileSupport.read(mit, maximum: 1_024 * 1_024),
            to: stage.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt"))
        try GameStarterFileSupport.write(
            try GameStarterFileSupport.read(notices, maximum: 1_024 * 1_024),
            to: stage.appendingPathComponent("licenses/GDEVELOP-THIRD-PARTY-NOTICES.txt"))
    }

    // MARK: - Shared finalization

    private func finalize(descriptor: GameStarterDescriptor, title: String, stage: URL) throws {
        let inputs = stage.appendingPathComponent("floe-inputs.json")
        if descriptor.templateKind == .static || descriptor.templateKind == .runtimePack ||
            !FileManager.default.fileExists(atPath: inputs.path) {
            let declaration = try descriptor.defaultInput.encoded()
            try GameStarterFileSupport.write(declaration, to: inputs)
        } else {
            let data = try GameStarterFileSupport.read(
                inputs, maximum: GameTouchProjectBindings.maximumDeclarationBytes)
            _ = try GameTouchProjectBindings(json: data, engine: descriptor.engine)
        }
        let readme = stage.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            let text = """
            # \(title)

            Original Floe starter for \(descriptor.displayName).
            Entry: `\(descriptor.entry.value)`.
            Source license: \(descriptor.sourceLicense)
            Engine/license prerequisite: \(descriptor.engineLicense)

            Read `floe-game.json` for the exact starter, runtime pack and user
            prerequisites. This generated project does not claim that an engine,
            editor or build was executed.
            """
            try GameStarterFileSupport.write(Data(text.utf8), to: readme)
        }
        let licenseRoot = stage.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt")
        let licenseFlat = stage.appendingPathComponent("LICENSE-FLOE-STARTER-MIT.txt")
        if !FileManager.default.fileExists(atPath: licenseRoot.path),
           !FileManager.default.fileExists(atPath: licenseFlat.path) {
            guard let license = catalog.licenseURL("FLOE-STARTER-MIT.txt") else {
                throw GameStarterError.invalidTemplate("Floe starter MIT license resource")
            }
            try GameStarterFileSupport.write(
                try GameStarterFileSupport.read(license, maximum: 1_024 * 1_024),
                to: licenseRoot)
        }
        let metadata = try GameStarterMetadata(descriptor: descriptor, title: title).encoded()
        try GameStarterFileSupport.write(metadata,
                                         to: stage.appendingPathComponent("floe-game.json"))
    }

    private func enumerate(_ root: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants], errorHandler: { _, _ in false }) else {
            throw GameStarterError.invalidTemplate("template enumeration")
        }
        var result: [String] = []
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= 10_000 else { throw GameStarterError.limitExceeded("templateEntries") }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw GameStarterError.invalidTemplate("non-regular template entry")
            }
            let prefix = root.path + "/"
            guard url.path.hasPrefix(prefix) else {
                throw GameStarterError.invalidTemplate("template escaped root")
            }
            result.append(String(url.path.dropFirst(prefix.count)))
        }
        return result.sorted()
    }
}

private func godotEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func yamlEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }
}
