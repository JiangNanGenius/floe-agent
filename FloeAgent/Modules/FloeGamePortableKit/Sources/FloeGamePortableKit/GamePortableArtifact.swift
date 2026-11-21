// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct GamePortableArtifactVerification: Codable, Equatable, Sendable {
    public let engine: GameEngineID
    public let entry: GameRelativePath
    public let files: [GamePortableFileRecord]
    public let totalBytes: Int
    public let runtimeHashVerified: Bool
    public let inputDeclaration: GamePortableInputDeclaration?
    public let warnings: [GamePortableWarning]
    public init(engine: GameEngineID, entry: GameRelativePath, files: [GamePortableFileRecord],
                totalBytes: Int, runtimeHashVerified: Bool,
                inputDeclaration: GamePortableInputDeclaration?,
                warnings: [GamePortableWarning]) {
        self.engine = engine; self.entry = entry; self.files = files
        self.totalBytes = totalBytes; self.runtimeHashVerified = runtimeHashVerified
        self.inputDeclaration = inputDeclaration; self.warnings = warnings
    }
}

/// Provenance file written into a compiled/template-built artifact. It contains
/// relative paths only and is not a permission or a signature.
public struct GamePortableArtifactManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let engine: GameEngineID
    public let runtimeID: String
    public let sourceProjectID: UUID
    public let sourceRevision: String
    public let resourceManifestID: String?
    public let entry: GameRelativePath
    public let capabilities: GamePortableCapabilities
    public let inputDeclarationSHA256: String?

    public init(schemaVersion: Int = 1, engine: GameEngineID, runtimeID: String,
                sourceProjectID: UUID, sourceRevision: String, resourceManifestID: String?,
                entry: GameRelativePath, capabilities: GamePortableCapabilities,
                inputDeclarationSHA256: String?) {
        self.schemaVersion = schemaVersion; self.engine = engine; self.runtimeID = runtimeID
        self.sourceProjectID = sourceProjectID; self.sourceRevision = sourceRevision
        self.resourceManifestID = resourceManifestID; self.entry = entry
        self.capabilities = capabilities; self.inputDeclarationSHA256 = inputDeclarationSHA256
    }

    public init(from data: Data) throws {
        do { self = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw GamePortableError.invalidArtifact("artifact manifest JSON") }
        guard schemaVersion == 1, GamePortableValidation.identifier(runtimeID),
              GamePortableValidation.identifier(sourceRevision) else {
            throw GamePortableError.invalidArtifact("artifact manifest fields")
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct GamePortableArtifactReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let engine: GameEngineID
    public let runtimeID: String
    public let resourceManifestID: String?
    public let resourceManifestDigest: String?
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let environmentID: String?
    public let sourceRevision: String
    public let entry: GameRelativePath
    public let buildKind: GamePortableBuildKind
    public let artifactDigest: String
    public let files: [GamePortableFileRecord]
    public let capabilities: GamePortableCapabilities
    public let inputDeclarationSHA256: String?

    public init(engine: GameEngineID, runtimeID: String, resourceManifestID: String?,
                resourceManifestDigest: String?, projectID: UUID, owner: GameProjectOwner,
                environmentID: String?, sourceRevision: String, entry: GameRelativePath,
                buildKind: GamePortableBuildKind, artifactDigest: String,
                files: [GamePortableFileRecord], capabilities: GamePortableCapabilities,
                inputDeclarationSHA256: String?) {
        self.schemaVersion = 1; self.engine = engine; self.runtimeID = runtimeID
        self.resourceManifestID = resourceManifestID; self.resourceManifestDigest = resourceManifestDigest
        self.projectID = projectID; self.owner = owner; self.environmentID = environmentID
        self.sourceRevision = sourceRevision; self.entry = entry; self.buildKind = buildKind
        self.artifactDigest = artifactDigest; self.files = files
        self.capabilities = capabilities; self.inputDeclarationSHA256 = inputDeclarationSHA256
    }

    /// The host calls this after every await and before a launch side effect.
    public func validate(current: GameProjectContext) throws {
        guard projectID == current.projectID, owner == current.owner,
              environmentID == current.environmentID, sourceRevision == current.savedRevision else {
            throw GamePortableError.staleRevision(expected: sourceRevision, actual: current.savedRevision)
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct GamePortableSealedArtifact: Sendable {
    public let package: GameWebArtifactPackage
    public let receipt: GamePortableArtifactReceipt
    public init(package: GameWebArtifactPackage, receipt: GamePortableArtifactReceipt) {
        self.package = package; self.receipt = receipt
    }
    public func validate(current: GameProjectContext) throws {
        try package.prepared.source.validate(current: current)
        try receipt.validate(current: current)
    }
}

public enum GamePortableArtifactVerifier {
    private static let prohibitedExtensions: Set<String> = [
        "app", "exe", "dll", "dylib", "so", "a", "o", "framework", "xcframework",
        "ipa", "node", "jar", "swf"
    ]

    public static func verify(directory: URL, engine: GameEngineID,
                              profile: GamePortableProfile?,
                              resources: GamePortablePreparedResources?) throws -> GamePortableArtifactVerification {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw GamePortableError.invalidArtifact("artifact root")
        }
        let entries = try GamePortableFileAccess.enumerate(root: root)
        let files = entries.filter { !$0.directory }
        guard files.count <= 10_000 else { throw GamePortableError.limitExceeded("artifactEntries") }
        let total = files.reduce(0) { $0 + $1.bytes }
        guard total <= 512 * 1_024 * 1_024 else { throw GamePortableError.limitExceeded("artifactBytes") }
        var warnings: [GamePortableWarning] = []
        for entry in files {
            let ext = (entry.path.value as NSString).pathExtension.lowercased()
            if prohibitedExtensions.contains(ext) {
                throw GamePortableError.invalidArtifact("native executable \(entry.path.value)")
            }
        }
        let set = Set(files.map(\.path.value))
        func require(_ paths: [String]) throws {
            for path in paths where !set.contains(path) {
                throw GamePortableError.invalidArtifact("missing \(path)")
            }
        }
        let entry: GameRelativePath
        switch engine {
        case .rpgMakerMV:
            try require(["index.html", "js/main.js", "js/plugins.js", "data/System.json",
                         "js/rpg_core.js", "js/rpg_managers.js", "js/rpg_objects.js",
                         "js/rpg_scenes.js", "js/rpg_sprites.js", "js/rpg_windows.js"])
            entry = profile?.entry ?? (try! GameRelativePath("index.html"))
        case .love:
            try require(["index.html", "love.wasm", "game.data", "love.js"])
            entry = profile?.entry ?? (try! GameRelativePath("index.html"))
        case .renpy:
            try require(["index.html", "renpy.wasm", "renpy.js"])
            entry = profile?.entry ?? (try! GameRelativePath("index.html"))
        default:
            throw GamePortableError.unsupportedEngine(engine)
        }
        guard set.contains(entry.value), ["html", "htm"].contains((entry.value as NSString).pathExtension.lowercased()) else {
            throw GamePortableError.invalidArtifact("HTML entry")
        }
        if engine == .love {
            try requireWASM(root: root, path: "love.wasm")
            guard try GamePortableFileAccess.read(root: root, path: "game.data", maximumBytes: 512 * 1_024 * 1_024).count > 0 else {
                throw GamePortableError.invalidArtifact("empty game.data")
            }
        }
        if engine == .renpy {
            try requireWASM(root: root, path: "renpy.wasm")
            let archive = set.contains("game.zip") ? "game.zip" : "game.data"
            try require([archive])
            try requireZIP(root: root, path: archive)
        }
        if engine == .rpgMakerMV {
            _ = try GamePortableFileAccess.read(root: root, path: "data/System.json", maximumBytes: 4 * 1_024 * 1_024)
        }
        var inputDeclaration: GamePortableInputDeclaration?
        if set.contains("floe-inputs.json") {
            let data = try GamePortableFileAccess.read(root: root, path: "floe-inputs.json", maximumBytes: 65_536)
            let declaration = try GamePortableInputDeclaration.decode(data)
            guard declaration.engine == engine else {
                throw GamePortableError.invalidInputDeclaration("artifact engine mismatch")
            }
            inputDeclaration = declaration
        } else {
            warnings.append(.init(code: .unknownInputs,
                message: "Artifact has no floe-inputs.json; bindings remain unknown and must not be assumed."))
        }
        if set.contains("floe-portable-artifact.json") {
            let data = try GamePortableFileAccess.read(root: root, path: "floe-portable-artifact.json",
                maximumBytes: 262_144)
            let manifest = try GamePortableArtifactManifest(from: data)
            guard manifest.engine == engine, manifest.entry == entry else {
                throw GamePortableError.invalidArtifact("provenance engine/entry mismatch")
            }
        }
        var runtimeHashVerified = false
        if let resources {
            guard resources.engine == engine else { throw GamePortableError.resourceMismatch("engine") }
            try resources.verify()
            var mappings: [(String, String)]
            switch engine {
            case .rpgMakerMV:
                mappings = ["rpg_core", "rpg_managers", "rpg_objects", "rpg_scenes", "rpg_sprites", "rpg_windows"]
                    .map { ("js/\($0).js", "js/\($0).js") }
                // Optional prepared web libraries are checked when the artifact
                // carries them; imported projects may supply their own reviewed libs.
                mappings += resources.manifest.files
                    .filter { $0.path.value.hasPrefix("js/libs/") && set.contains($0.path.value) }
                    .map { ($0.path.value, $0.path.value) }
            case .love:
                mappings = [("love.wasm", "runtime/compat/love.wasm"),
                            ("love.js", "runtime/compat/love.js")]
            case .renpy:
                mappings = [("renpy.wasm", "web/renpy.wasm"), ("renpy.js", "web/renpy.js")]
            default: mappings = []
            }
            for (artifactPath, resourcePath) in mappings {
                guard set.contains(artifactPath) else { throw GamePortableError.invalidArtifact(artifactPath) }
                let artifact = try GamePortableFileAccess.read(root: root, path: artifactPath,
                    maximumBytes: 512 * 1_024 * 1_024)
                let prepared = try resources.read(resourcePath)
                guard artifact.count == prepared.count, GameDigest.sha256(artifact) == GameDigest.sha256(prepared) else {
                    throw GamePortableError.resourceMismatch(artifactPath)
                }
            }
            runtimeHashVerified = true
        } else {
            warnings.append(.init(code: .runtimeUnverified,
                message: "Prepared runtime was not supplied; only structure and WASM magic were checked."))
        }
        let records = try files.map { entry in
            try GamePortableFileAccess.record(root: root, path: entry.path.value,
                maximumBytes: max(entry.bytes + 1, 1))
        }
        return .init(engine: engine, entry: entry, files: records, totalBytes: total,
            runtimeHashVerified: runtimeHashVerified, inputDeclaration: inputDeclaration,
            warnings: warnings)
    }

    private static func requireWASM(root: URL, path: String) throws {
        let data = try GamePortableFileAccess.read(root: root, path: path, maximumBytes: 64 * 1_024 * 1_024)
        guard data.count >= 8, Array(data.prefix(4)) == [0x00, 0x61, 0x73, 0x6d] else {
            throw GamePortableError.invalidArtifact("WASM magic \(path)")
        }
    }

    private static func requireZIP(root: URL, path: String) throws {
        let data = try GamePortableFileAccess.read(root: root, path: path, maximumBytes: 512 * 1_024 * 1_024)
        guard data.count >= 22, Array(data.prefix(4)) == [0x50, 0x4b, 0x03, 0x04],
              let tail = String(data: Data(data.suffix(min(65_557, data.count))), encoding: .isoLatin1),
              tail.contains("PK\u{05}\u{06}") else {
            throw GamePortableError.invalidArtifact("ZIP \(path)")
        }
    }
}

public enum GamePortableArtifactSealer {
    public static func seal(source: GameProjectContext, engine: GameEngineID,
                            entry: GameRelativePath, contentRoot: URL, to destination: URL,
                            profile: GamePortableProfile, resources: GamePortablePreparedResources?,
                            buildKind: GamePortableBuildKind) throws -> GamePortableSealedArtifact {
        guard source.rootURL == contentRoot.standardizedFileURL.resolvingSymlinksInPath()
                || !contentRoot.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(source.rootURL.path + "/") else {
            throw GamePortableError.invalidArtifact("content root")
        }
        _ = try GamePortableArtifactVerifier.verify(directory: contentRoot, engine: engine,
            profile: profile, resources: resources)
        // A built artifact (not the imported source tree) carries the actual
        // license/notice bytes declared by the prepared runtime. This is the
        // export companion material, not a substitute for the LGPL source
        // offer; that remains a separate source-offer receipt.
        if let resources,
           contentRoot.standardizedFileURL.resolvingSymlinksInPath()
            != source.rootURL.standardizedFileURL.resolvingSymlinksInPath() {
            _ = try GamePortableResourceNoticeMaterializer.materialize(resources, into: contentRoot)
        }
        let inputHash = try profile.inputDeclaration.map { GameDigest.sha256(try $0.encoded()) }
        let manifest = GamePortableArtifactManifest(engine: engine, runtimeID: profile.runtime.id,
            sourceProjectID: source.projectID, sourceRevision: source.savedRevision,
            resourceManifestID: resources?.id, entry: entry,
            capabilities: profile.capabilities, inputDeclarationSHA256: inputHash)
        if contentRoot.standardizedFileURL.resolvingSymlinksInPath() != source.rootURL {
            try GamePortableFileAccess.writeAtomic(try manifest.encoded(),
                to: contentRoot.appendingPathComponent("floe-portable-artifact.json"))
        }
        let package = try GameWebArtifactPackage.build(source: source, engine: engine, entry: entry,
            to: destination, contentRoot: contentRoot)
        let receipt = GamePortableArtifactReceipt(engine: engine, runtimeID: profile.runtime.id,
            resourceManifestID: resources?.id, resourceManifestDigest: resources?.manifestDigest,
            projectID: source.projectID, owner: source.owner, environmentID: source.environmentID,
            sourceRevision: source.savedRevision, entry: entry, buildKind: buildKind,
            artifactDigest: package.prepared.sha256,
            files: package.files.map { GamePortableFileRecord(path: $0.path, sha256: $0.sha256, bytes: $0.bytes, executable: $0.executable) },
            capabilities: profile.capabilities, inputDeclarationSHA256: inputHash)
        return .init(package: package, receipt: receipt)
    }
}
