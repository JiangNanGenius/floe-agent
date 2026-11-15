// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeGameCore

/// Where an exact source bundle was found. The producer recipes written by the
/// Python check and by ``GamePortableSourceOfferMaterializer`` use different
/// layouts; both are accepted, but only at their recorded relative path.
public enum GamePortableSourceOfferLayout: String, Codable, Equatable, Sendable {
    /// The caller selected the exact ZIP itself.
    case directBundleFile
    /// `<root>/sources/exact/<bundle.id>` written by the PortableKit
    /// materializer.
    case materializedSourceOffer
    /// `<root>/<bundle.id>` written by the Python producer.
    case flatSourceOffer
}

public struct GamePortableSourceOfferResolution: Equatable, Sendable {
    public let packID: String
    public let bundleID: String
    public let bundleURL: URL
    public let sha256: String
    public let bytes: Int
    public let layout: GamePortableSourceOfferLayout
    public let relativePath: String

    public init(packID: String, bundleID: String, bundleURL: URL,
                sha256: String, bytes: Int,
                layout: GamePortableSourceOfferLayout, relativePath: String) {
        self.packID = packID
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.sha256 = sha256
        self.bytes = bytes
        self.layout = layout
        self.relativePath = relativePath
    }
}

/// Resolves the exact source bundle for a paired-source distribution export.
///
/// The catalog's recorded `id`, byte count and SHA-256 are the only authority.
/// A producer's `PAIRED-SOURCE.json`/`bundle-manifest.json` is never read as a
/// substitute for hashing the actual bytes. Directory layouts are traversed
/// descriptor-relative with `O_NOFOLLOW`, so a symlinked file, a symlinked
/// intermediate directory or a FIFO fails closed instead of escaping the
/// selected root or blocking the caller.
public enum GamePortableSourceOfferResolver {
    private static let maximumBundleBytes = 8 * 1_024 * 1_024 * 1_024

    public static func resolve(catalog: GamePortableSourceAccompanimentCatalog,
                               engine: GameEngineID,
                               root: URL) throws -> GamePortableSourceOfferResolution {
        guard let pack = catalog.accompaniment(for: engine) else {
            throw GamePortableSourceOfferError.invalidBundle("no source pack for engine")
        }
        return try resolve(pack: pack, root: root)
    }

    public static func resolve(pack: GamePortableSourcePackAccompaniment,
                               root: URL) throws -> GamePortableSourceOfferResolution {
        guard let bundle = pack.sourceBundle else {
            throw GamePortableSourceOfferError.invalidBundle("source pack has no exact bundle")
        }
        guard GamePortableRuntimePin.isSHA256(bundle.sha256), bundle.bytes > 0 else {
            throw GamePortableSourceOfferError.invalidBundle(bundle.id)
        }
        let standardized = root.standardizedFileURL
        switch GamePortableAnchoredIO.kind(standardized) {
        case .regularFile:
            return try verifyBundleFile(standardized, packID: pack.packID,
                bundleID: bundle.id, sha256: bundle.sha256, bytes: bundle.bytes)
        case .directory:
            return try resolve(directory: standardized, packID: pack.packID, bundle: bundle)
        case .symlink:
            // A document-provider root may itself be an alias. Resolve that one
            // final component once, then anchor every descendant with openat.
            let resolved = standardized.resolvingSymlinksInPath()
            if GamePortableAnchoredIO.kind(resolved) == .directory {
                return try resolve(directory: resolved, packID: pack.packID, bundle: bundle)
            }
            throw GamePortableSourceOfferError.invalidBundle("source root symlink")
        case .missing:
            throw GamePortableSourceOfferError.missingFile(bundle.id)
        case .other:
            throw GamePortableSourceOfferError.invalidBundle("source root is not a file or directory")
        }
    }

    /// Verifies one user-selected exact bundle file. The file name is not used
    /// as authority; the recorded size and SHA-256 are.
    public static func verifyBundleFile(_ url: URL, packID: String, bundleID: String,
                                        sha256: String,
                                        bytes: Int) throws -> GamePortableSourceOfferResolution {
        guard GamePortableRuntimePin.isSHA256(sha256), bytes > 0, bytes <= maximumBundleBytes else {
            throw GamePortableSourceOfferError.invalidBundle(bundleID)
        }
        let hashed = try GamePortableAnchoredIO.hashStandaloneRegularFile(
            url, maximumBytes: maximumBundleBytes)
        guard hashed.bytes == bytes, hashed.sha256 == sha256 else {
            throw GamePortableSourceOfferError.digestMismatch(bundleID)
        }
        return .init(packID: packID, bundleID: bundleID,
                     bundleURL: url.standardizedFileURL, sha256: sha256, bytes: bytes,
                     layout: .directBundleFile, relativePath: url.lastPathComponent)
    }

    private static func resolve(directory: URL, packID: String,
                                bundle: GamePortableSourceBundleRecord) throws -> GamePortableSourceOfferResolution {
        let materialized = try GameRelativePath("sources/exact/" + bundle.id)
        if try GamePortableAnchoredIO.exists(root: directory, path: materialized) {
            return try verify(root: directory, path: materialized, packID: packID,
                              bundle: bundle, layout: .materializedSourceOffer)
        }
        let flat = try GameRelativePath(bundle.id)
        if try GamePortableAnchoredIO.exists(root: directory, path: flat) {
            return try verify(root: directory, path: flat, packID: packID,
                              bundle: bundle, layout: .flatSourceOffer)
        }
        throw GamePortableSourceOfferError.missingFile(bundle.id)
    }

    private static func verify(root: URL, path: GameRelativePath, packID: String,
                               bundle: GamePortableSourceBundleRecord,
                               layout: GamePortableSourceOfferLayout) throws -> GamePortableSourceOfferResolution {
        let file = try GamePortableAnchoredIO.openVerifiedRegularFile(
            root: root, path: path, expectedBytes: bundle.bytes,
            maximumBytes: maximumBundleBytes)
        defer { Darwin.close(file.fd) }
        let hashed = try GamePortableAnchoredIO.hash(descriptor: file.fd,
            maximumBytes: maximumBundleBytes)
        guard hashed.bytes == bundle.bytes, hashed.sha256 == bundle.sha256 else {
            throw GamePortableSourceOfferError.digestMismatch(bundle.id)
        }
        return .init(packID: packID, bundleID: bundle.id,
                     bundleURL: root.appendingPathComponent(path.value).standardizedFileURL,
                     sha256: bundle.sha256, bytes: bundle.bytes,
                     layout: layout, relativePath: path.value)
    }
}
