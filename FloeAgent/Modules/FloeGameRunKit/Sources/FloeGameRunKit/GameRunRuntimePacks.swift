// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameRuntime

/// Host-supplied runtime packs keyed by engine. This is useful for reviewed
/// packs outside `GameEngineResourceCatalog` (for example the Phaser 3.90.0
/// starter pack) and for deterministic component tests.
public struct GameRunStaticRuntimePackProvider: GameRunRuntimePackProviding, Sendable {
    public let packs: [GameEngineID: GameRunRuntimePack]

    public init(_ packs: [GameEngineID: GameRunRuntimePack]) {
        self.packs = packs
    }

    public func runtimePack(for engine: GameEngineID) async throws -> GameRunRuntimePack? {
        packs[engine]
    }
}

/// Bridges the reviewed `GameEnginePackStore` pins for KAPLAY/Babylon/PlayCanvas.
/// A missing prepared directory returns nil (the host can prepare it through its
/// ordinary resource UI). A present but corrupt pack throws and stays visible.
public struct GameEngineResourcePackProvider: GameRunRuntimePackProviding, Sendable {
    public let store: GameEnginePackStore

    public init(store: GameEnginePackStore) {
        self.store = store
    }

    public func runtimePack(for engine: GameEngineID) async throws -> GameRunRuntimePack? {
        let all = try GameEngineResourceCatalog.all()
        guard let spec = all.first(where: { $0.engine == engine }) else { return nil }
        let storeDirectory = await store.directory
        let directory = storeDirectory.appendingPathComponent(
            spec.engine.rawValue + "-" + spec.version, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let pack = try await store.prepared(engine)
        let verified = try pack.verifiedFiles()
        var files: [GameRunRuntimeFile] = []
        for file in spec.files {
            guard let bytes = verified[file.path], bytes.count == file.bytes else {
                throw GameRunPreparationError.invalidConfiguration(
                    "runtime pack \(spec.engine.rawValue) file \(file.path.value)")
            }
            let record = try GameRunRuntimeFile(source: file.path, destination: file.path,
                                                sha256: file.sha256, bytes: file.bytes)
            files.append(record)
        }
        return try GameRunRuntimePack(engine: engine, id: spec.package, version: spec.version,
                                      license: spec.license, directory: pack.directory,
                                      files: files)
    }
}

extension GameRunRuntimePack {
    /// Convenience for a reviewed host pack with explicit artifact destinations.
    /// Every source file is read and hashed once, then reverified by the main
    /// initializer. Unknown extra files in `directory` are ignored.
    public init(engine: GameEngineID, id: String, version: String, license: String,
                directory: URL, mappings: [(source: String, destination: String)]) throws {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard !mappings.isEmpty else {
            throw GameRunPreparationError.invalidConfiguration("runtime pack mappings")
        }
        var files: [GameRunRuntimeFile] = []
        for mapping in mappings {
            let source: GameRelativePath
            let destination: GameRelativePath
            do {
                source = try GameRelativePath(mapping.source)
                destination = try GameRelativePath(mapping.destination)
            } catch {
                throw GameRunPreparationError.invalidConfiguration("runtime pack path")
            }
            let bytes = try GameRunFileIO.read(root: root, path: source,
                maximumBytes: 256 * 1_024 * 1_024)
            let record = try GameRunRuntimeFile(source: source, destination: destination,
                                                sha256: GameDigest.sha256(bytes),
                                                bytes: bytes.count)
            files.append(record)
        }
        try self.init(engine: engine, id: id, version: version, license: license,
                      directory: root, files: files)
    }
}
