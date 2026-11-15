// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Upstream pin shipped with the component. It records where the exact runtime
/// came from and which license files must travel with it; it is not a download
/// permission or a promise that a remote URL will stay available.
public struct GamePortableRuntimePin: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let engine: GameEngineID
    public let version: String
    public let revision: String?
    public let upstreamURL: String
    public let artifactSHA256: String?
    public let license: String
    public let licenseFiles: [String]
    public let prepareScript: String
    public let buildKind: String
    public let notes: [String]

    public init(from data: Data) throws {
        do { self = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw GamePortableError.invalidResourceManifest("pin JSON") }
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1, GamePortableValidation.identifier(id),
              GamePortableValidation.identifier(version),
              URL(string: upstreamURL)?.scheme != nil,
              GamePortableValidation.identifier(license),
              GamePortableValidation.identifier(prepareScript),
              GamePortableValidation.identifier(buildKind),
              !licenseFiles.isEmpty else {
            throw GamePortableError.invalidResourceManifest("pin fields")
        }
        if let artifactSHA256 {
            guard Self.isSHA256(artifactSHA256) else { throw GamePortableError.invalidResourceManifest("pin digest") }
        }
        guard licenseFiles.allSatisfy({ (try? GameRelativePath($0)) != nil }) else {
            throw GamePortableError.invalidResourceManifest("license path")
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct GamePortableResourceManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let pinID: String
    public let engine: GameEngineID
    public let version: String
    public let runtimeID: String
    public let files: [GamePortableFileRecord]
    public let notes: [String]

    public init(schemaVersion: Int = 1, id: String, pinID: String, engine: GameEngineID,
                version: String, runtimeID: String, files: [GamePortableFileRecord],
                notes: [String] = []) {
        self.schemaVersion = schemaVersion; self.id = id; self.pinID = pinID
        self.engine = engine; self.version = version; self.runtimeID = runtimeID
        self.files = files; self.notes = notes
    }

    public init(from data: Data) throws {
        do { self = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw GamePortableError.invalidResourceManifest("manifest JSON") }
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1, GamePortableValidation.identifier(id),
              GamePortableValidation.identifier(pinID),
              GamePortableValidation.identifier(version),
              GamePortableValidation.identifier(runtimeID),
              files.count <= 10_000 else {
            throw GamePortableError.invalidResourceManifest("manifest fields")
        }
        var paths = Set<String>()
        var total = 0
        for file in files {
            guard paths.insert(file.path.value).inserted,
                  GamePortableRuntimePin.isSHA256(file.sha256), file.bytes >= 0,
                  file.bytes <= 512 * 1_024 * 1_024 else {
                throw GamePortableError.invalidResourceManifest("file record \(file.path.value)")
            }
            guard total <= 1_024 * 1_024 * 1_024 - file.bytes else {
                throw GamePortableError.limitExceeded("resourceBytes")
            }
            total += file.bytes
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public var sha256: String { GameDigest.sha256(try! encoded()) }
}

public struct GamePortablePreparedResources: Sendable {
    public let rootURL: URL
    public let manifest: GamePortableResourceManifest
    /// Hash of the canonical manifest JSON, recorded in artifact provenance.
    public let manifestDigest: String

    public init(rootURL: URL, manifestURL: URL) throws {
        guard rootURL.isFileURL, manifestURL.isFileURL else {
            throw GamePortableError.invalidResourceManifest("file URL")
        }
        let data = try GamePortableFileAccess.read(root: manifestURL.deletingLastPathComponent(),
            path: manifestURL.lastPathComponent, maximumBytes: 4 * 1_024 * 1_024)
        let manifest = try GamePortableResourceManifest(from: data)
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.manifest = manifest
        self.manifestDigest = GameDigest.sha256(try manifest.encoded())
    }

    /// Initializer for a bounded user/component replacement that already has a
    /// fully validated manifest value. The caller remains responsible for the
    /// root's path safety; ``verify`` re-hashes every declared file.
    public init(rootURL: URL, manifest: GamePortableResourceManifest) throws {
        guard rootURL.isFileURL else {
            throw GamePortableError.invalidResourceManifest("file URL")
        }
        try manifest.validate()
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.manifest = manifest
        self.manifestDigest = GameDigest.sha256(try manifest.encoded())
    }

    public var id: String { manifest.id }
    public var engine: GameEngineID { manifest.engine }
    public var runtimeID: String { manifest.runtimeID }

    public func fileURL(_ path: String) throws -> URL {
        guard manifest.files.contains(where: { $0.path.value == path }) else {
            throw GamePortableError.resourceMismatch(path)
        }
        return rootURL.appendingPathComponent(path)
    }

    public func read(_ path: String) throws -> Data {
        guard let file = manifest.files.first(where: { $0.path.value == path }) else {
            throw GamePortableError.resourceMismatch(path)
        }
        return try GamePortableFileAccess.read(root: rootURL, path: path, maximumBytes: file.bytes + 1)
    }

    /// Read-only check: exact file set, declared sizes and SHA-256 hashes.
    public func verify() throws {
        let entries = try GamePortableFileAccess.enumerate(root: rootURL)
        let actual = Set(entries.filter { !$0.directory }.map(\.path.value))
        let expected = Set(manifest.files.map(\.path.value))
        guard actual == expected else {
            let extra = actual.subtracting(expected).sorted().first ?? "?"
            let missing = expected.subtracting(actual).sorted().first ?? "?"
            throw GamePortableError.resourceMismatch("prepared tree extra=\(extra) missing=\(missing)")
        }
        for file in manifest.files {
            try Task.checkCancellation()
            let data = try GamePortableFileAccess.read(root: rootURL, path: file.path.value,
                maximumBytes: file.bytes + 1)
            guard data.count == file.bytes, GameDigest.sha256(data) == file.sha256 else {
                throw GamePortableError.resourceMismatch(file.path.value)
            }
        }
    }

    public func requireFile(_ path: String) throws -> GamePortableFileRecord {
        guard let file = manifest.files.first(where: { $0.path.value == path }) else {
            throw GamePortableError.resourceMismatch(path)
        }
        return file
    }
}
