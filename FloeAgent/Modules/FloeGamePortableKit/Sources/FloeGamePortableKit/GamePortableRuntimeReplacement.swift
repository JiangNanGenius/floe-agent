// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Bounded metadata for an explicit user-rebuilt runtime component. It names
/// only mutable runtime files, never licenses, App code or a second trust root.
/// The user must supply a complete rebuilt resource tree; Floe validates it
/// against the immutable base and does not install or trust it automatically.
public struct GamePortableRuntimeReplacementMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let componentID: String
    public let baseManifestSHA256: String
    public let replaceablePaths: [String]
    public let replacementFiles: [GamePortableFileRecord]
    public let sourcePackages: [GamePortableSourceFileRecord]
    public let relinkReceipts: [GamePortableSourceFileRecord]
    public let notes: [String]

    public init(from data: Data) throws {
        do { self = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw GamePortableError.invalidResourceManifest("replacement JSON") }
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1, componentID == GamePortableUserRuntimeReplacement.componentID,
              GamePortableRuntimePin.isSHA256(baseManifestSHA256),
              !replaceablePaths.isEmpty, replaceablePaths.count <= 16,
              !replacementFiles.isEmpty, replacementFiles.count <= 16,
              !sourcePackages.isEmpty, !relinkReceipts.isEmpty,
              sourcePackages.count <= 64, relinkReceipts.count <= 64,
              notes.count <= 64 else {
            throw GamePortableError.invalidResourceManifest("replacement fields")
        }
        for path in replaceablePaths {
            guard GamePortableUserRuntimeReplacement.isAllowed(path) else {
                throw GamePortableError.invalidResourceManifest("replaceable path \(path)")
            }
        }
        var paths = Set<String>()
        for file in replacementFiles {
            guard GamePortableUserRuntimeReplacement.isAllowed(file.path.value),
                  GamePortableRuntimePin.isSHA256(file.sha256),
                  file.bytes >= 0, file.bytes <= 64 * 1_024 * 1_024,
                  paths.insert(file.path.value).inserted else {
                throw GamePortableError.invalidResourceManifest("replacement file \(file.path.value)")
            }
        }
        for record in sourcePackages + relinkReceipts {
            try record.validate()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, componentID, baseManifestSHA256, replaceablePaths
        case replacementFiles, sourcePackages, relinkReceipts, notes
    }
}

public enum GamePortableUserRuntimeReplacement {
    public static let componentID = "lovejs-11.4.1"

    /// Only generated runtime helpers/WASM are mutable. Licenses, notices,
    /// Floe source, the runtime manifest and user game bytes are not.
    public static func isAllowed(_ path: String) -> Bool {
        [
            "runtime/compat/love.js", "runtime/compat/love.wasm",
            "cli/src/compat/love.js", "cli/src/compat/love.wasm",
            "runtime/release/love.js", "runtime/release/love.wasm",
            "runtime/release/love.worker.js",
        ].contains(path)
    }

    /// Validates a complete user-rebuilt tree against the immutable base and
    /// returns a prepared-resource value for the caller's explicit run/export.
    /// It does not write the App installation, change the default pack, grant a
    /// tool permission or persist a trust decision.
    public static func validate(base: GamePortablePreparedResources,
                                replacementRoot: URL,
                                metadata: GamePortableRuntimeReplacementMetadata)
        throws -> GamePortablePreparedResources {
        try metadata.validate()
        try base.verify()
        guard metadata.componentID == base.id,
              metadata.baseManifestSHA256 == base.manifestDigest else {
            throw GamePortableError.invalidResourceManifest("replacement base identity")
        }
        let entries = try GamePortableFileAccess.enumerate(root: replacementRoot)
        let actual = Set(entries.filter { !$0.directory }.map(\.path.value))
        let expected = Set(base.manifest.files.map(\.path.value))
        guard actual == expected else {
            throw GamePortableError.resourceMismatch("replacement tree file set")
        }
        let replaceable = Set(metadata.replaceablePaths)
        let replacements = Dictionary(uniqueKeysWithValues: metadata.replacementFiles.map {
            ($0.path.value, $0)
        })
        guard Set(replacements.keys) == replaceable else {
            throw GamePortableError.invalidResourceManifest("replacement path set")
        }
        for file in base.manifest.files where !replaceable.contains(file.path.value) {
            let data = try GamePortableFileAccess.read(root: replacementRoot,
                path: file.path.value, maximumBytes: file.bytes + 1)
            guard data.count == file.bytes, GameDigest.sha256(data) == file.sha256 else {
                throw GamePortableError.resourceMismatch("immutable \(file.path.value)")
            }
        }
        for replacement in replacements.values {
            guard base.manifest.files.contains(where: { $0.path == replacement.path }) else {
                throw GamePortableError.invalidResourceManifest(
                    "replacement added file \(replacement.path.value)")
            }
            let data = try GamePortableFileAccess.read(root: replacementRoot,
                path: replacement.path.value, maximumBytes: replacement.bytes + 1)
            guard data.count == replacement.bytes,
                  GameDigest.sha256(data) == replacement.sha256 else {
                throw GamePortableError.resourceMismatch("replacement \(replacement.path.value)")
            }
        }
        let files = base.manifest.files.map { replacements[$0.path.value] ?? $0 }
        let manifest = GamePortableResourceManifest(
            id: base.manifest.id, pinID: base.manifest.pinID, engine: base.engine,
            version: base.manifest.version, runtimeID: base.runtimeID, files: files,
            notes: base.manifest.notes + [
                "Explicit user-rebuilt runtime validated against the immutable base; "
                + "not installed or trusted automatically.",
            ])
        let prepared = try GamePortablePreparedResources(rootURL: replacementRoot, manifest: manifest)
        try prepared.verify()
        return prepared
    }
}
