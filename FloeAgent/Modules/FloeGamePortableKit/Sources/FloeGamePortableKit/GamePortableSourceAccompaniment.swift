// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeGameCore

/// One exact notice, helper-source, relink or source-package file referenced by
/// the product source-accompaniment catalog. The path is relative to the root
/// supplied to the materializer; no URL or credential is stored here.
public struct GamePortableSourceFileRecord: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let bytes: Int

    public init(path: String, sha256: String, bytes: Int) {
        self.path = path; self.sha256 = sha256; self.bytes = bytes
    }

    public func validate() throws {
        guard (try? GameRelativePath(path)) != nil,
              GamePortableRuntimePin.isSHA256(sha256),
              bytes >= 0, bytes <= 8 * 1_024 * 1_024 * 1_024 else {
            throw GamePortableError.invalidResourceManifest("source file \(path)")
        }
    }
}

public struct GamePortableSourceBundleRecord: Codable, Equatable, Sendable {
    public let id: String
    public let sha256: String
    public let bytes: Int
    public let fileCount: Int?
    public let verifiedSourceFiles: Int?

    public init(id: String, sha256: String, bytes: Int,
                fileCount: Int? = nil, verifiedSourceFiles: Int? = nil) {
        self.id = id; self.sha256 = sha256; self.bytes = bytes
        self.fileCount = fileCount; self.verifiedSourceFiles = verifiedSourceFiles
    }

    public func validate() throws {
        guard GamePortableValidation.identifier(id),
              !id.contains("/"), !id.contains("\\"),
              GamePortableRuntimePin.isSHA256(sha256),
              bytes > 0, bytes <= 8 * 1_024 * 1_024 * 1_024 else {
            throw GamePortableError.invalidResourceManifest("source bundle")
        }
    }
}

public struct GamePortableSourcePublication: Codable, Equatable, Sendable {
    public let state: String
    public let distributionReady: Bool
    public let writtenOfferCreated: Bool
    public let publicURL: String?
    public let detail: String

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(String.self, forKey: .state)
        distributionReady = try values.decodeIfPresent(Bool.self, forKey: .distributionReady) ?? false
        writtenOfferCreated = try values.decodeIfPresent(Bool.self, forKey: .writtenOfferCreated) ?? false
        publicURL = try values.decodeIfPresent(String.self, forKey: .publicURL)
        detail = try values.decodeIfPresent(String.self, forKey: .detail) ?? ""
        guard GamePortableValidation.identifier(state),
              publicURL == nil || URL(string: publicURL!)?.scheme == "https" else {
            throw GamePortableError.invalidResourceManifest("source publication")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case state, distributionReady, writtenOfferCreated, publicURL, detail
    }
}

public struct GamePortableSourcePackAccompaniment: Codable, Equatable, Sendable {
    public let packID: String
    public let engines: [GameEngineID]
    public let profileID: String?
    /// Exact paired-source id used by the existing GameBuildKit distribution
    /// profile. Nil when this pack has no paired-source build profile.
    public let pairedSourceID: String?
    public let licenses: [GamePortableSourceFileRecord]
    public let helperSources: [GamePortableSourceFileRecord]
    public let relink: [GamePortableSourceFileRecord]
    public let sourcePackages: [GamePortableSourceFileRecord]
    public let sourceFiles: [GamePortableSourceFileRecord]?
    public let sourceBundle: GamePortableSourceBundleRecord?
    public let publication: GamePortableSourcePublication

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        packID = try values.decode(String.self, forKey: .packID)
        engines = try values.decode([GameEngineID].self, forKey: .engines)
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID)
        pairedSourceID = try values.decodeIfPresent(String.self, forKey: .pairedSourceID)
        licenses = try values.decodeIfPresent([GamePortableSourceFileRecord].self,
                                              forKey: .licenses) ?? []
        helperSources = try values.decodeIfPresent([GamePortableSourceFileRecord].self,
                                                   forKey: .helperSources) ?? []
        relink = try values.decodeIfPresent([GamePortableSourceFileRecord].self, forKey: .relink) ?? []
        sourcePackages = try values.decodeIfPresent([GamePortableSourceFileRecord].self,
                                                    forKey: .sourcePackages) ?? []
        sourceFiles = try values.decodeIfPresent([GamePortableSourceFileRecord].self,
                                                 forKey: .sourceFiles)
        sourceBundle = try values.decodeIfPresent(GamePortableSourceBundleRecord.self,
                                                  forKey: .sourceBundle)
        publication = try values.decode(GamePortableSourcePublication.self, forKey: .publication)
        try validate()
    }

    public func validate() throws {
        guard GamePortableValidation.identifier(packID), !engines.isEmpty,
              profileID == nil || GamePortableValidation.identifier(profileID!),
              pairedSourceID == nil || GamePortableValidation.identifier(pairedSourceID!) else {
            throw GamePortableError.invalidResourceManifest("source pack identity")
        }
        var identities: [String: GamePortableSourceFileRecord] = [:]
        for group in [licenses, helperSources, relink, sourcePackages, sourceFiles ?? []] {
            var paths = Set<String>()
            for record in group {
                try record.validate()
                guard paths.insert(record.path).inserted else {
                    throw GamePortableError.invalidResourceManifest("duplicate source path \(record.path)")
                }
                // One exact file can be both a notice and corresponding source.
                if let existing = identities[record.path], existing != record {
                    throw GamePortableError.invalidResourceManifest("conflicting source identity \(record.path)")
                }
                identities[record.path] = record
            }
        }
        try sourceBundle?.validate()
    }

    private enum CodingKeys: String, CodingKey {
        case packID, engines, profileID, pairedSourceID, licenses, helperSources, relink
        case sourcePackages, sourceFiles, sourceBundle, publication
    }
}

/// Decoded product catalog. The top-level product publication state is
/// independent from the presence of validated local bytes.
public struct GamePortableSourceAccompanimentCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let productionPublication: GamePortableSourcePublication
    public let packs: [String: GamePortableSourcePackAccompaniment]

    public init(from data: Data) throws {
        do { self = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw GamePortableError.invalidResourceManifest("source catalog JSON") }
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1,
              kind == "floe-game-runtime-source-accompaniment",
              !packs.isEmpty else {
            throw GamePortableError.invalidResourceManifest("source catalog header")
        }
        for (key, pack) in packs where key != pack.packID {
            throw GamePortableError.invalidResourceManifest("source catalog key \(key)")
        }
    }

    public func accompaniment(for engine: GameEngineID) -> GamePortableSourcePackAccompaniment? {
        packs.values.first { $0.engines.contains(engine) }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, productionPublication, packs
    }
}

/// Concrete roots for each logical file group. A root is required only when the
/// corresponding catalog group is non-empty. The materializer never reaches
/// outside these roots.
public struct GamePortableSourceOfferRoots: Sendable {
    public let licenses: URL?
    public let helperSources: URL?
    public let relink: URL?
    public let sourcePackages: URL?
    public let sourceFiles: URL?
    public let sourceBundle: URL?

    public init(licenses: URL? = nil, helperSources: URL? = nil, relink: URL? = nil,
                sourcePackages: URL? = nil, sourceFiles: URL? = nil, sourceBundle: URL? = nil) {
        self.licenses = licenses; self.helperSources = helperSources; self.relink = relink
        self.sourcePackages = sourcePackages; self.sourceFiles = sourceFiles
        self.sourceBundle = sourceBundle
    }
}

public enum GamePortableSourceOfferMode: String, Codable, Equatable, Sendable {
    /// Fails closed when the catalog says the source offer is unpublished.
    case distribution
    /// Materializes the local bytes with an explicit not-ready receipt.
    case privatePlayback
    /// Complete corresponding-source accompaniment for an engineering export.
    /// Every declared byte is still verified, but the catalog's public offer
    /// state is not required to be `published`; the receipt keeps the real
    /// public state and never claims distribution/App Store/legal approval.
    case sourceAccompaniedExport
}

public enum GamePortableSourceOfferError: Error, Equatable, Sendable {
    case notPublished(String)
    case missingRoot(String)
    case missingFile(String)
    case digestMismatch(String)
    case destinationExists
    case invalidBundle(String)
    case io(String)
}

public struct GamePortableSourceOfferReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let packID: String
    public let state: String
    public let distributionReady: Bool
    public let writtenOfferCreated: Bool
    public let mode: String
    public let files: [GamePortableFileRecord]
    public let sourceBundleID: String?
    public let sourceBundleSHA256: String?
    public let manifestSHA256: String
    public let note: String
    /// True only when every declared companion file was re-hashed and copied.
    /// This is engineering completeness, not a publication or legal status.
    public let engineeringComplete: Bool
    /// The unchanged catalog publication state recorded at export time.
    public let publicSourceState: String

    public init(schemaVersion: Int = 1, packID: String, state: String,
                distributionReady: Bool, writtenOfferCreated: Bool, mode: String,
                files: [GamePortableFileRecord], sourceBundleID: String?,
                sourceBundleSHA256: String?, manifestSHA256: String, note: String,
                engineeringComplete: Bool = false,
                publicSourceState: String = "unpublished") {
        self.schemaVersion = schemaVersion; self.packID = packID; self.state = state
        self.distributionReady = distributionReady
        self.writtenOfferCreated = writtenOfferCreated; self.mode = mode
        self.files = files; self.sourceBundleID = sourceBundleID
        self.sourceBundleSHA256 = sourceBundleSHA256
        self.manifestSHA256 = manifestSHA256; self.note = note
        self.engineeringComplete = engineeringComplete
        self.publicSourceState = publicSourceState
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Materializes the exact companion files for an exported game/source bundle.
/// It is a deterministic, staged, no-overwrite writer: every input is re-hashed,
/// every copied byte is re-hashed, and a failed or cancelled copy leaves no
/// destination. It never claims distribution readiness merely because local
/// bytes exist.
public enum GamePortableSourceOfferMaterializer {
    private static let maximumFiles = 200_000
    private static let maximumBytes = 8 * 1_024 * 1_024 * 1_024

    public static func materialize(catalog: GamePortableSourceAccompanimentCatalog,
                                   packID: String,
                                   roots: GamePortableSourceOfferRoots,
                                   to destination: URL,
                                   mode: GamePortableSourceOfferMode,
                                   fileManager: FileManager = .default) throws -> GamePortableSourceOfferReceipt {
        guard let pack = catalog.packs[packID] else {
            throw GamePortableSourceOfferError.missingFile(packID)
        }
        if mode == .distribution, pack.publication.state != "published" {
            throw GamePortableSourceOfferError.notPublished(packID)
        }
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else {
            throw GamePortableSourceOfferError.io("destination URL")
        }
        let destinationName = destination.lastPathComponent
        guard destinationName != ".", destinationName != "..",
              !destinationName.contains("/"),
              !destinationName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw GamePortableSourceOfferError.io("destination name")
        }
        if fileManager.fileExists(atPath: destination.path) {
            throw GamePortableSourceOfferError.destinationExists
        }

        let groups: [(String, URL?, [GamePortableSourceFileRecord])] = [
            ("license", roots.licenses, pack.licenses),
            ("helper-source", roots.helperSources, pack.helperSources),
            ("relink", roots.relink ?? roots.sourcePackages, pack.relink),
            ("source-package", roots.sourcePackages, pack.sourcePackages),
            ("source", roots.sourceFiles, pack.sourceFiles ?? []),
        ]
        var planned: [(role: String, root: URL, record: GamePortableSourceFileRecord)] = []
        for (role, root, records) in groups where !records.isEmpty {
            guard let root else { throw GamePortableSourceOfferError.missingRoot(role) }
            for record in records { planned.append((role, root, record)) }
        }
        if pack.sourceBundle != nil, roots.sourceBundle == nil {
            throw GamePortableSourceOfferError.missingRoot("source-bundle")
        }
        guard planned.count <= maximumFiles else {
            throw GamePortableSourceOfferError.io("too many source files")
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stagingName = ".floe-source-offer-" + UUID().uuidString.lowercased()
        let staging = try GamePortableAnchoredIO.createStagingDirectory(in: parent, name: stagingName)
        defer {
            Darwin.close(staging.fd)
            try? fileManager.removeItem(at: staging.url)
        }

        var receipts: [GamePortableFileRecord] = []
        var total = 0
        var destinations = Set<String>()
        for item in planned {
            try Task.checkCancellation()
            if !destinations.insert(item.record.path).inserted {
                // Check the other role's actual input even when both roles
                // share one declared destination in the exported tree.
                let source = try GamePortableAnchoredIO.openVerifiedRegularFile(
                    root: item.root, path: GameRelativePath(item.record.path),
                    expectedBytes: item.record.bytes, maximumBytes: maximumBytes)
                defer { Darwin.close(source.fd) }
                let identity = try GamePortableAnchoredIO.hash(descriptor: source.fd, maximumBytes: item.record.bytes)
                guard identity.bytes == item.record.bytes, identity.sha256 == item.record.sha256 else {
                    throw GamePortableSourceOfferError.digestMismatch(item.record.path)
                }
                continue
            }
            guard total <= maximumBytes - item.record.bytes else {
                throw GamePortableSourceOfferError.io("source offer byte limit")
            }
            total += item.record.bytes
            let record = try copyVerified(root: item.root, record: item.record,
                                          stagingRoot: staging.fd,
                                          relativePath: item.record.path)
            receipts.append(record)
        }
        if let bundle = pack.sourceBundle, let bundleRoot = roots.sourceBundle {
            let relative = "sources/exact/" + bundle.id
            guard destinations.insert(relative).inserted else {
                throw GamePortableSourceOfferError.io("duplicate bundle path")
            }
            guard total <= maximumBytes - bundle.bytes else {
                throw GamePortableSourceOfferError.io("source offer byte limit")
            }
            total += bundle.bytes
            let source = GamePortableSourceFileRecord(path: bundle.id, sha256: bundle.sha256,
                                                     bytes: bundle.bytes)
            _ = try copyVerified(root: bundleRoot, record: source,
                                 stagingRoot: staging.fd, relativePath: relative)
            receipts.append(.init(path: try GameRelativePath(relative),
                                  sha256: bundle.sha256, bytes: bundle.bytes))
        }

        let ready = pack.publication.distributionReady
            && pack.publication.state == "published"
            && mode == .distribution
        let note: String
        switch mode {
        case .distribution:
            note = ready
                ? "Exact source accompaniment verified and marked ready by the catalog."
                : "Exact local companion bytes were materialized. The catalog publication state is "
                  + "\(pack.publication.state); this bundle is not a published source offer and "
                  + "distributionReady remains false."
        case .privatePlayback:
            note = "Exact local companion bytes were materialized for private playback. The catalog "
                + "publication state is \(pack.publication.state); this is not a published source "
                + "offer and distributionReady remains false."
        case .sourceAccompaniedExport:
            note = "Exact local corresponding-source accompaniment for an engineering export. Every "
                + "declared file was re-hashed. The public source offer state is "
                + "\(pack.publication.state); no public offer, written offer, App Store approval or "
                + "legal clearance is claimed, and distributionReady remains false."
        }
        let engineeringComplete = true
        let profile: [String: Any] = [
            "schemaVersion": 1,
            "packID": pack.packID,
            "state": pack.publication.state,
            "publicSourceState": pack.publication.state,
            "distributionReady": ready,
            "engineeringComplete": engineeringComplete,
            "writtenOfferCreated": pack.publication.writtenOfferCreated,
            "mode": mode.rawValue,
            "sourceBundleID": pack.sourceBundle?.id ?? NSNull(),
            "sourceBundleSHA256": pack.sourceBundle?.sha256 ?? NSNull(),
            "files": receipts.map { ["path": $0.path.value, "sha256": $0.sha256, "bytes": $0.bytes] },
            "note": note,
        ]
        let profileData = try JSONSerialization.data(withJSONObject: profile,
                                                     options: [.prettyPrinted, .sortedKeys])
        try GamePortableAnchoredIO.write(profileData, directoryFD: staging.fd,
            path: try GameRelativePath("PAIRED-SOURCE.json"))
        let text = """
        Floe source accompaniment — \(pack.packID)

        State: \(pack.publication.state)
        Distribution ready: \(ready ? "yes" : "no")
        Engineering complete: yes
        Written offer created: \(pack.publication.writtenOfferCreated ? "yes" : "no")

        \(pack.publication.detail)

        Every listed file was re-hashed from the supplied local roots. This bundle
        does not claim App Store approval, legal clearance, a published offer or a
        distribution-ready status.
        """
        try GamePortableAnchoredIO.write(Data(text.utf8), directoryFD: staging.fd,
            path: try GameRelativePath("SOURCE-AND-LICENSES.txt"))

        var manifestFiles: [String: String] = [:]
        for entry in try GamePortableFileAccess.enumerate(root: staging.url) where !entry.directory {
            let file = try GamePortableAnchoredIO.openVerifiedRegularFile(
                root: staging.url, path: entry.path, expectedBytes: nil,
                maximumBytes: max(entry.bytes + 1, 1))
            defer { Darwin.close(file.fd) }
            let hashed = try GamePortableAnchoredIO.hash(descriptor: file.fd,
                maximumBytes: max(entry.bytes + 1, 1))
            manifestFiles[entry.path.value] = hashed.sha256
        }
        let manifestObject: [String: Any] = [
            "schemaVersion": 1,
            "packID": pack.packID,
            "state": pack.publication.state,
            "publicSourceState": pack.publication.state,
            "distributionReady": ready,
            "engineeringComplete": engineeringComplete,
            "sourceAccompaniedExport": mode == .sourceAccompaniedExport,
            "profileID": pack.profileID ?? NSNull(),
            "files": manifestFiles,
            "appStoreApprovalClaimed": false,
            "writtenOfferCreated": pack.publication.writtenOfferCreated,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject,
                                                      options: [.prettyPrinted, .sortedKeys])
        try GamePortableAnchoredIO.write(manifestData, directoryFD: staging.fd,
            path: try GameRelativePath("bundle-manifest.json"))

        let commitParent = try GamePortableAnchoredIO.openDirectory(parent)
        defer { Darwin.close(commitParent) }
        try GamePortableAnchoredIO.renameExclusive(directoryFD: commitParent,
            from: stagingName, to: destinationName)
        return .init(packID: pack.packID, state: pack.publication.state,
                     distributionReady: ready,
                     writtenOfferCreated: pack.publication.writtenOfferCreated,
                     mode: mode.rawValue, files: receipts,
                     sourceBundleID: pack.sourceBundle?.id,
                     sourceBundleSHA256: pack.sourceBundle?.sha256,
                     manifestSHA256: GameDigest.sha256(manifestData), note: note,
                     engineeringComplete: engineeringComplete,
                     publicSourceState: pack.publication.state)
    }

    /// Streaming copy for source packages up to hundreds of MB. The source is
    /// opened descriptor-relative with `O_NOFOLLOW`/`O_NONBLOCK`, hashed while
    /// writing into an anchored staging directory, and independently re-hashed
    /// through a fresh anchored read before returning.
    private static func copyVerified(root: URL, record: GamePortableSourceFileRecord,
                                     stagingRoot: Int32,
                                     relativePath: String) throws -> GamePortableFileRecord {
        guard record.bytes >= 0, record.bytes <= maximumBytes else {
            throw GamePortableSourceOfferError.missingFile(record.path)
        }
        let relative = try GameRelativePath(relativePath)
        let source = try GamePortableAnchoredIO.openVerifiedRegularFile(
            root: root, path: try GameRelativePath(record.path),
            expectedBytes: record.bytes, maximumBytes: maximumBytes)
        defer { Darwin.close(source.fd) }
        let parent = try GamePortableAnchoredIO.createParentDirectory(
            rootFD: stagingRoot, path: relative)
        defer { Darwin.close(parent.fd) }
        let destination = try GamePortableAnchoredIO.createExclusiveFile(
            directoryFD: parent.fd, name: parent.name)
        var open = true
        do {
            let digest = try GamePortableAnchoredIO.copy(
                source: source.fd, to: destination, expectedBytes: source.bytes)
            guard source.bytes == record.bytes, digest == record.sha256 else {
                throw GamePortableSourceOfferError.digestMismatch(record.path)
            }
            _ = Darwin.fsync(destination)
            Darwin.close(destination)
            open = false
        } catch {
            if open { Darwin.close(destination) }
            GamePortableAnchoredIO.unlink(directoryFD: parent.fd, name: parent.name)
            throw error
        }
        let readBack: (fd: Int32, bytes: Int)
        do {
            readBack = try GamePortableAnchoredIO.openVerifiedRegularFile(
                directoryFD: parent.fd, name: parent.name,
                expectedBytes: record.bytes, maximumBytes: maximumBytes)
        } catch {
            GamePortableAnchoredIO.unlink(directoryFD: parent.fd, name: parent.name)
            throw GamePortableSourceOfferError.digestMismatch("read back \(record.path)")
        }
        defer { Darwin.close(readBack.fd) }
        let hash: (bytes: Int, sha256: String)
        do {
            hash = try GamePortableAnchoredIO.hash(descriptor: readBack.fd,
                maximumBytes: maximumBytes)
        } catch {
            GamePortableAnchoredIO.unlink(directoryFD: parent.fd, name: parent.name)
            throw error
        }
        guard hash.bytes == record.bytes, hash.sha256 == record.sha256 else {
            GamePortableAnchoredIO.unlink(directoryFD: parent.fd, name: parent.name)
            throw GamePortableSourceOfferError.digestMismatch("read back \(record.path)")
        }
        return .init(path: relative, sha256: record.sha256, bytes: record.bytes)
    }
}

/// Copies the prepared resource's declared license/notice bytes into a built
/// artifact so an exported playable package carries the actual notices instead
/// of only referencing them. It never writes when the target is the imported
/// source tree, and it fails closed on a differing existing file.
public enum GamePortableResourceNoticeMaterializer {
    @discardableResult
    public static func materialize(_ resources: GamePortablePreparedResources,
                                   into root: URL) throws -> [GamePortableFileRecord] {
        var values: [GamePortableFileRecord] = []
        for file in resources.manifest.files where file.path.value.hasPrefix("licenses/") {
            try Task.checkCancellation()
            let data = try resources.read(file.path.value)
            guard data.count == file.bytes, GameDigest.sha256(data) == file.sha256 else {
                throw GamePortableError.resourceMismatch(file.path.value)
            }
            let target = root.appendingPathComponent(file.path.value)
            if FileManager.default.fileExists(atPath: target.path) {
                let existing = try GamePortableFileAccess.read(root: root,
                    path: file.path.value, maximumBytes: file.bytes + 1)
                guard existing.count == file.bytes, GameDigest.sha256(existing) == file.sha256 else {
                    throw GamePortableError.resourceMismatch("existing \(file.path.value)")
                }
            } else {
                try GamePortableFileAccess.writeAtomic(data, to: target)
            }
            values.append(file)
        }
        return values
    }
}
