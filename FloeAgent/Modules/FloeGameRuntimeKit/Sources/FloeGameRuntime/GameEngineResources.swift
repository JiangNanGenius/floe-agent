// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeGameCore

public struct GameEngineResourceFile: Codable, Sendable, Equatable {
    public let path: GameRelativePath
    public let packagePath: String
    public let sha256: String
    public let bytes: Int
    public let url: URL
}

public struct GameEngineResourceSpec: Codable, Sendable, Equatable {
    public let engine: GameEngineID
    public let package: String
    public let version: String
    public let license: String
    public let gitHead: String
    public let tarballURL: URL
    public let tarballIntegrity: String
    public let files: [GameEngineResourceFile]
}

/// Pins come from this signed module's resource, never imported project metadata.
public enum GameEngineResourceCatalog {
    public static func all() throws -> [GameEngineResourceSpec] {
        struct Index: Decodable { let version: Int; let packs: [GameEngineResourceSpec] }
        guard let url = Bundle.module.url(forResource: "RuntimePins", withExtension: "json", subdirectory: "Resources") else { throw GameProjectError.corruptStorage }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
        // Only the reviewed permissive resource pins belong to this catalog.
        // Imported games are independent files and never pass this filter.
        // A package.json label alone is not a license review: the corresponding
        // license bytes are pinned and retained with each prepared resource.
        guard index.version == 1,
              index.packs.allSatisfy({ ["MIT", "Apache-2.0"].contains($0.license) }) else {
            throw GameProjectError.corruptStorage
        }
        return index.packs
    }
    public static func spec(_ engine: GameEngineID) throws -> GameEngineResourceSpec {
        guard let value = try all().first(where: { $0.engine == engine }) else { throw GameProjectError.unsupportedRoute(engine) }
        return value
    }
}

public struct GameEngineResourcePack: Sendable {
    public let spec: GameEngineResourceSpec
    public let directory: URL
    public init(engine: GameEngineID, directory: URL) throws {
        guard directory.isFileURL else { throw GameProjectError.invalidContext }
        self.spec = try GameEngineResourceCatalog.spec(engine)
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        _ = try verifiedFiles()
    }
    public func verifiedFiles() throws -> [GameRelativePath: Data] {
        var result: [GameRelativePath: Data] = [:]
        for file in spec.files {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(file.path.value)
            let canonical = url.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(directory.path + "/"),
                  try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue == file.bytes,
                  file.bytes <= 16_777_216 else { throw GameProjectError.corruptStorage }
            let bytes = try Data(contentsOf: url)
            guard bytes.count == file.bytes, Self.digest(bytes) == file.sha256 else { throw GameProjectError.corruptStorage }
            result[file.path] = bytes
        }
        return result
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// The App can inject its download service; this protocol grants no execution.
public protocol GameEngineResourceTransport: Sendable {
    func fetch(_ file: GameEngineResourceFile) async throws -> Data
}

public struct GameEngineHTTPTransport: GameEngineResourceTransport {
    public init() {}
    public func fetch(_ file: GameEngineResourceFile) async throws -> Data {
        guard file.url.scheme == "https", file.url.host == "cdn.jsdelivr.net", file.bytes <= 16_777_216 else { throw GameProjectError.invalidArtifact }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: file.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue == file.bytes else { throw GameProjectError.invalidArtifact }
        let data = try Data(contentsOf: temporary)
        guard GameEngineResourcePack.digest(data) == file.sha256 else { throw GameProjectError.corruptStorage }
        return data
    }
}

/// Host-owned on-demand resource preparation. A prepared pack is reverified for
/// offline use; cancellation/failure preserves the previously prepared version.
public actor GameEnginePackStore {
    public let directory: URL
    private var preparing: [GameEngineID: Task<GameEngineResourcePack, any Error>] = [:]
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw GameProjectError.invalidContext }
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    public func prepared(_ engine: GameEngineID) throws -> GameEngineResourcePack {
        let spec = try GameEngineResourceCatalog.spec(engine)
        return try .init(engine: engine, directory: directory.appendingPathComponent(spec.engine.rawValue + "-" + spec.version))
    }
    public func prepare(_ engine: GameEngineID, transport: any GameEngineResourceTransport = GameEngineHTTPTransport()) async throws -> GameEngineResourcePack {
        if let pack = try? prepared(engine) { return pack }
        if let job = preparing[engine] { return try await job.value }
        let root = directory, spec = try GameEngineResourceCatalog.spec(engine)
        let job = Task<GameEngineResourcePack, any Error> {
            let stage = root.appendingPathComponent(".prepare-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: stage) }
            for file in spec.files {
                try Task.checkCancellation()
                let bytes = try await transport.fetch(file)
                guard bytes.count == file.bytes, GameEngineResourcePack.digest(bytes) == file.sha256 else { throw GameProjectError.corruptStorage }
                let url = stage.appendingPathComponent(file.path.value)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url, options: [.atomic])
            }
            _ = try GameEngineResourcePack(engine: engine, directory: stage)
            try Task.checkCancellation()
            let target = root.appendingPathComponent(spec.engine.rawValue + "-" + spec.version)
            // Never replace an existing pack. Corrupt cached data is explicit;
            // the host can remove/retry it through its ordinary resource UI.
            try FileManager.default.moveItem(at: stage, to: target)
            return try GameEngineResourcePack(engine: engine, directory: target)
        }
        preparing[engine] = job
        defer { preparing.removeValue(forKey: engine) }
        return try await job.value
    }
    public func cancelPreparation(_ engine: GameEngineID) async {
        let job = preparing[engine]; job?.cancel()
        if let job { _ = await job.result }
        preparing.removeValue(forKey: engine)
    }
}
