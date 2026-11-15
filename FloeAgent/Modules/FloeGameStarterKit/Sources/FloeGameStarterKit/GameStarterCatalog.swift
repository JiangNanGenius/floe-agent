// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeGameCore

/// Deterministic, bundle-backed catalog for the exact 20 agreed engines.
/// The catalog is data, not permission: it cannot register a runtime, select an
/// environment, grant filesystem access or claim an engine was executed.
public struct GameStarterCatalog: Sendable {
    public let schemaVersion: Int
    public let catalogVersion: String
    public let generatedBy: String
    public let engines: [GameStarterDescriptor]

    public init(data: Data) throws {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw GameStarterError.invalidCatalog(String(describing: error)) }
        guard document.schemaVersion == 1,
              document.catalogVersion == "1.0.0",
              document.engines.count == GameEngineID.allCases.count,
              Set(document.engines.map(\.engine)) == Set(GameEngineID.allCases) else {
            throw GameStarterError.invalidCatalog("catalog schema, version or engine set")
        }
        for descriptor in document.engines {
            guard descriptor.defaultInput.engine == descriptor.engine,
                  !descriptor.displayName.isEmpty,
                  !descriptor.sourceLicense.isEmpty,
                  !descriptor.engineLicense.isEmpty,
                  !descriptor.expectedFiles.isEmpty,
                  descriptor.expectedFiles.contains(descriptor.entry) else {
                throw GameStarterError.invalidCatalog("descriptor \(descriptor.engine.rawValue)")
            }
            do { try descriptor.defaultInput.validate() }
            catch { throw GameStarterError.invalidCatalog("default input for \(descriptor.engine.rawValue)") }
            switch descriptor.templateKind {
            case .static:
                guard descriptor.templateRoot != nil, descriptor.runtimePack == nil,
                      !descriptor.files.isEmpty else {
                    throw GameStarterError.invalidCatalog("static descriptor \(descriptor.engine.rawValue)")
                }
            case .delegated:
                guard descriptor.provider != nil, descriptor.templateRoot == nil,
                      descriptor.runtimePack == nil, descriptor.files.isEmpty else {
                    throw GameStarterError.invalidCatalog("delegated descriptor \(descriptor.engine.rawValue)")
                }
            case .runtimePack:
                guard descriptor.provider != nil, descriptor.runtimePack != nil,
                      descriptor.files.isEmpty, descriptor.readiness == .runtimePackRequired else {
                    throw GameStarterError.invalidCatalog("runtime-pack descriptor \(descriptor.engine.rawValue)")
                }
            }
        }
        self.schemaVersion = document.schemaVersion
        self.catalogVersion = document.catalogVersion
        self.generatedBy = document.generatedBy
        self.engines = document.engines
    }

    /// Loads the exact resource in this package. A missing/corrupt resource is
    /// an actionable installation error, never an empty catalog.
    public static func bundled() throws -> GameStarterCatalog {
        let candidates = [
            Bundle.module.url(forResource: "engines", withExtension: "json", subdirectory: "Catalog"),
            Bundle.module.url(forResource: "engines", withExtension: "json"),
        ].compactMap { $0 }
        guard let url = candidates.first else {
            throw GameStarterError.invalidCatalog("engines.json is not in the resource bundle")
        }
        return try GameStarterCatalog(data: Data(contentsOf: url))
    }

    public func descriptor(for engine: GameEngineID) throws -> GameStarterDescriptor {
        guard let descriptor = engines.first(where: { $0.engine == engine }) else {
            throw GameStarterError.unsupportedEngine(engine)
        }
        return descriptor
    }

    /// Returns a deterministic manifest for hosts/tools that need to compare
    /// the installed catalog. It contains no dates, random IDs or absolute paths.
    public func manifest() throws -> Data {
        struct Manifest: Encodable {
            let schemaVersion: Int
            let catalogVersion: String
            let generatedBy: String
            let engines: [GameStarterDescriptor]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(Manifest(schemaVersion: schemaVersion,
                                           catalogVersion: catalogVersion,
                                           generatedBy: generatedBy,
                                           engines: engines))
    }

    /// Read-only engine recognition over the existing inspector output. An
    /// explicit preferred engine wins only if the inspection actually found it.
    public func recognizedEngine(in inspection: GameProjectInspection,
                                 preferred: GameEngineID? = nil) -> GameEngineID? {
        let found = Set(inspection.candidates.map(\.engine))
        if let preferred {
            return found.contains(preferred) && engines.contains(where: { $0.engine == preferred })
                ? preferred : nil
        }
        for engine in GameEngineID.allCases where found.contains(engine) {
            if engines.contains(where: { $0.engine == engine }) { return engine }
        }
        return nil
    }

    /// Marker/entry files that the existing inspector may use for recognition.
    /// This is metadata, not a replacement for inspecting the actual tree.
    public func recognitionPaths(for engine: GameEngineID) throws -> [GameRelativePath] {
        let descriptor = try descriptor(for: engine)
        var result = [descriptor.entry]
        if descriptor.entry.value.lowercased().hasSuffix(".json") == false {
            // Common project markers already recognized by GameProjectInspector.
            switch engine {
            case .rpgMakerXP: result += [try GameRelativePath("Game.ini")]
            case .rpgMakerVX: result += [try GameRelativePath("Game.ini")]
            case .rpgMakerVXAce: result += [try GameRelativePath("Game.ini")]
            case .rpgMakerMV: result += [try GameRelativePath("Game.rpgproject")]
            case .rpgMakerMZ: result += [try GameRelativePath("data/System.json")]
            case .godot: result += [try GameRelativePath("export_presets.cfg")]
            case .unity: result += [try GameRelativePath("ProjectSettings/ProjectVersion.txt")]
            case .cocosCreator: result += [try GameRelativePath("package.json")]
            case .phaser, .kaplay, .babylon, .playcanvas:
                result += [try GameRelativePath("package.json")]
            case .love: result += [try GameRelativePath("conf.lua")]
            case .renpy: result += [try GameRelativePath("game/options.rpy")]
            default: break
            }
        }
        return Array(Set(result)).sorted { $0.value < $1.value }
    }

    /// Verifies every bundled static template against the catalog hashes and
    /// rejects extra/missing files. Intended for CLI/tests and preflight.
    public func verifyBundledStaticTemplates() throws {
        for descriptor in engines where descriptor.templateKind == .static {
            guard let root = staticTemplateURL(for: descriptor) else {
                throw GameStarterError.invalidTemplate("missing \(descriptor.engine.rawValue)")
            }
            let actual = try enumerateRegularFiles(root: root)
            let expected = descriptor.files.map(\.path.value).sorted()
            guard actual == expected else {
                throw GameStarterError.invalidTemplate("file set mismatch \(descriptor.engine.rawValue)")
            }
            for file in descriptor.files {
                let url = root.appendingPathComponent(file.path.value)
                let data = try Data(contentsOf: url)
                guard data.count == file.bytes,
                      SHA256.hash(data: data).hexString == file.sha256 else {
                    throw GameStarterError.invalidTemplate("hash mismatch \(descriptor.engine.rawValue)/\(file.path.value)")
                }
            }
        }
    }

    public func staticTemplateURL(for descriptor: GameStarterDescriptor) -> URL? {
        guard descriptor.templateKind == .static,
              let root = descriptor.templateRoot else { return nil }
        let name = URL(fileURLWithPath: root).lastPathComponent
        guard let url = bundleDirectory(subdirectory: "Templates", name: name) else { return nil }
        return url
    }

    public func runtimeTemplateURL(_ name: String) -> URL? {
        if let root = Bundle.module.resourceURL {
            let direct = root
                .appendingPathComponent("Templates/runtime", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: nil,
                                          subdirectory: "Templates/runtime") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func licenseURL(_ name: String) -> URL? {
        if let root = Bundle.module.resourceURL {
            let direct = root.appendingPathComponent("Licenses", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: nil,
                                          subdirectory: "Licenses") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func bundleDirectory(subdirectory: String, name: String) -> URL? {
        if let root = Bundle.module.resourceURL {
            let direct = root
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: direct.path, isDirectory: &isDirectory),
               isDirectory.boolValue { return direct }
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: nil,
                                          subdirectory: subdirectory) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    private func enumerateRegularFiles(root: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants], errorHandler: { _, _ in false }) else {
            throw GameStarterError.invalidTemplate(root.lastPathComponent)
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
                throw GameStarterError.invalidTemplate("template escaped its root")
            }
            result.append(String(url.path.dropFirst(prefix.count)))
        }
        return result.sorted()
    }

    private struct Document: Decodable {
        let schemaVersion: Int
        let catalogVersion: String
        let generatedBy: String
        let engines: [GameStarterDescriptor]
    }
}

extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
