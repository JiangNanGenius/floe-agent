// SPDX-License-Identifier: MPL-2.0
//
// Verified remote identity for the public Floe electronics catalogue.
//
// A mirror only supplies bytes. Publication identity, asset sizes, hashes,
// approved repository origins and the exact model Git object all come from a
// trusted release receipt/index before any byte route is selected.

import CryptoKit
import Foundation

public enum ElectronicsRemoteError: Error, Equatable, LocalizedError, Sendable {
    case invalidRelease(String)
    case invalidCatalog(String)
    case invalidManifest(String)
    case invalidModel(String)
    case invalidAsset(String)
    case invalidTarget(String)
    case integrity(String)
    case unavailable(String)
    case limits(String)
    case notReady(String)
    case conflict(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidRelease(let detail): "Electronics release receipt is invalid: \(detail)"
        case .invalidCatalog(let detail): "Electronics catalogue is invalid: \(detail)"
        case .invalidManifest(let detail): "Electronics manifest is invalid: \(detail)"
        case .invalidModel(let detail): "Electronics model record is invalid: \(detail)"
        case .invalidAsset(let detail): "Electronics asset is invalid: \(detail)"
        case .invalidTarget(let detail): "Electronics download target is invalid: \(detail)"
        case .integrity(let detail): "Electronics data failed integrity verification: \(detail)"
        case .unavailable(let detail): "Electronics data is unavailable: \(detail)"
        case .limits(let detail): "Electronics data exceeds its bounded limit: \(detail)"
        case .notReady(let detail): "Electronics catalogue is not ready: \(detail)"
        case .conflict(let detail): "Electronics cache conflict: \(detail)"
        case .cancelled: "Electronics download was cancelled."
        }
    }
}

public enum ElectronicsRemoteLimits {
    public static let releaseReceiptBytes = 256 * 1_024
    public static let catalogBytes = 32 * 1_024 * 1_024
    public static let manifestBytes = 16 * 1_024 * 1_024
    public static let modelIndexCompressedBytes = 64 * 1_024 * 1_024
    public static let modelIndexExpandedBytes = 256 * 1_024 * 1_024
    public static let modelIndexRows = 50_000
    public static let modelLineBytes = 64 * 1_024
    public static let modelBytes = 64 * 1_024 * 1_024
    public static let packageBytes = 1_024 * 1_024 * 1_024
    public static let snapshotFiles = 100_000
    public static let sources = 256
    public static let assets = 4_096
}

public enum ElectronicsRemoteDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1_024 * 1_024), !block.isEmpty {
            hash.update(data: block)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Git source-object identity: SHA1("blob " + decimalByteCount + NUL + bytes).
    public static func gitBlobSHA1(byteCount: Int, data: Data) -> String {
        var material = Data("blob \(byteCount)\u{0}".utf8)
        material.append(data)
        return Insecure.SHA1.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    public static func gitBlobSHA1(fileAt url: URL, byteCount: Int) throws -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(byteCount)\u{0}".utf8))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var total = 0
        while let block = try handle.read(upToCount: 1_024 * 1_024), !block.isEmpty {
            total += block.count
            hash.update(data: block)
        }
        guard total == byteCount else { throw ElectronicsRemoteError.integrity("model byte count differs from its receipt") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func isGitObjectHash(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum ElectronicsRemoteValidation {
    public static func safeAssetName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, value != ".", value != "..",
              value == (value as NSString).lastPathComponent,
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        return true
    }

    public static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 4_096, !value.hasPrefix("/"),
              !value.contains("\\"), !value.contains("\u{0}"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static func safeSourceID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 96 else { return false }
        var iterator = value.utf8.makeIterator()
        guard let first = iterator.next(), (97...122).contains(first) || (48...57).contains(first) else { return false }
        while let byte = iterator.next() {
            guard (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 else { return false }
        }
        return true
    }

    /// Accepts only a canonical https repository identity without credentials,
    /// query, fragment or extra path components. A trailing `.git` is legal
    /// on the source policy but row/catalog comparisons normalize it away.
    public static func normalizeRepository(_ value: String, allow2DLibrary: Bool = false) throws -> String {
        guard var parts = URLComponents(string: value), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              let host = parts.host, host == "github.com" || host == "gitlab.com" else {
            throw ElectronicsRemoteError.invalidModel("repository is not a canonical GitHub/GitLab https origin")
        }
        var path = parts.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard path.hasPrefix("/"), !path.hasSuffix("/") else {
            throw ElectronicsRemoteError.invalidModel("repository path is not canonical")
        }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ElectronicsRemoteError.invalidModel("repository path is not canonical")
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        for component in components {
            guard component.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw ElectronicsRemoteError.invalidModel("repository component is not canonical")
            }
        }
        if host == "gitlab.com" {
            let approved: Set<String> = allow2DLibrary
                ? ["/kicad/libraries/kicad-packages3D", "/kicad/libraries/kicad-symbols", "/kicad/libraries/kicad-footprints"]
                : ["/kicad/libraries/kicad-packages3D"]
            guard approved.contains(path) else {
                throw ElectronicsRemoteError.invalidModel("GitLab repository is outside the pinned KiCad package origin")
            }
        } else {
            guard components.count == 2 else {
                throw ElectronicsRemoteError.invalidModel("GitHub repository must be exactly owner/repository")
            }
        }
        parts.percentEncodedPath = path
        guard let normalized = parts.url?.absoluteString else {
            throw ElectronicsRemoteError.invalidModel("repository is not a valid URL")
        }
        return normalized
    }

    public static func encodePath(_ path: String) throws -> String {
        guard safeRelativePath(path) else { throw ElectronicsRemoteError.invalidTarget("unsafe relative path") }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var encoded: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let value = String(component).addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw ElectronicsRemoteError.invalidTarget("path cannot be percent-encoded")
            }
            encoded.append(value)
        }
        return encoded.joined(separator: "/")
    }
}

public struct ElectronicsRemoteFile: Codable, Hashable, Sendable {
    public var path: String
    public var bytes: Int
    public var sha256: String
    public var role: String
    public var sourceID: String?

    public init(path: String, bytes: Int, sha256: String, role: String, sourceID: String? = nil) {
        self.path = path; self.bytes = bytes; self.sha256 = sha256; self.role = role; self.sourceID = sourceID
    }

    public func validate(label: String) throws {
        guard ElectronicsRemoteValidation.safeRelativePath(path),
              (0...ElectronicsRemoteLimits.packageBytes).contains(bytes),
              ElectronicsRemoteDigest.isSHA256(sha256),
              ElectronicsRemoteValidation.safeAssetName(role) || ElectronicsRemoteValidation.safeRelativePath(role),
              role.utf8.count <= 96,
              sourceID.map(ElectronicsRemoteValidation.safeSourceID) ?? true else {
            throw ElectronicsRemoteError.invalidManifest("invalid file identity at \(label)")
        }
    }
}

public struct ElectronicsRemoteReleaseAsset: Codable, Hashable, Sendable {
    public var name: String
    public var bytes: Int
    public var sha256: String
    public var role: String

    public init(name: String, bytes: Int, sha256: String, role: String) {
        self.name = name; self.bytes = bytes; self.sha256 = sha256; self.role = role
    }

    public func validate() throws {
        guard ElectronicsRemoteValidation.safeAssetName(name),
              (1...ElectronicsRemoteLimits.packageBytes).contains(bytes),
              ElectronicsRemoteDigest.isSHA256(sha256),
              ElectronicsRemoteValidation.safeRelativePath(role), role.utf8.count <= 96 else {
            throw ElectronicsRemoteError.invalidRelease("invalid asset \(name)")
        }
    }
}

public struct ElectronicsRemotePublication: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var tag: String
    public var dataVersion: String
    public var producerRevision: String
    public var datasetSHA256: String
    public var assets: [ElectronicsRemoteReleaseAsset]

    public init(tag: String, dataVersion: String, producerRevision: String,
                datasetSHA256: String, assets: [ElectronicsRemoteReleaseAsset]) {
        self.schemaVersion = 1; self.tag = tag; self.dataVersion = dataVersion
        self.producerRevision = producerRevision; self.datasetSHA256 = datasetSHA256; self.assets = assets
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= ElectronicsRemoteLimits.releaseReceiptBytes else {
            throw ElectronicsRemoteError.limits("release receipt")
        }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ElectronicsRemoteError.invalidRelease("receipt is not valid JSON") }
        try value.validate()
        return value
    }

    public func validate() throws {
        guard schemaVersion == 1,
              tag.range(of: "^data-v1-[0-9a-f]{20}$", options: .regularExpression) != nil,
              dataVersion.range(of: "^v1-[0-9a-f]{20}$", options: .regularExpression) != nil,
              tag == "data-" + dataVersion,
              ElectronicsRemoteDigest.isGitObjectHash(producerRevision),
              ElectronicsRemoteDigest.isSHA256(datasetSHA256),
              !assets.isEmpty, assets.count <= ElectronicsRemoteLimits.assets,
              Set(assets.map(\.name)).count == assets.count else {
            throw ElectronicsRemoteError.invalidRelease("identity, tag binding or asset set is invalid")
        }
        for asset in assets { try asset.validate() }
        for required in ["catalog.json", "manifest.json", "upstreams.lock.json"] {
            _ = try self.asset(named: required)
        }
    }

    public func asset(named name: String) throws -> ElectronicsRemoteReleaseAsset {
        guard let value = assets.first(where: { $0.name == name }) else {
            throw ElectronicsRemoteError.invalidRelease("required asset \(name) is absent")
        }
        return value
    }
}

public struct ElectronicsRemoteManifest: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var dataVersion: String
    public var datasetSHA256: String
    public var producerRevision: String
    public var toolingSHA256: String
    public var files: [ElectronicsRemoteFile]

    public init(dataVersion: String, datasetSHA256: String, producerRevision: String,
                toolingSHA256: String, files: [ElectronicsRemoteFile]) {
        self.schemaVersion = 1; self.dataVersion = dataVersion; self.datasetSHA256 = datasetSHA256
        self.producerRevision = producerRevision; self.toolingSHA256 = toolingSHA256; self.files = files
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= ElectronicsRemoteLimits.manifestBytes else {
            throw ElectronicsRemoteError.limits("manifest")
        }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ElectronicsRemoteError.invalidManifest("manifest is not valid JSON") }
        try value.validate()
        return value
    }

    public func validate() throws {
        guard schemaVersion == 1,
              dataVersion.range(of: "^v1-[0-9a-f]{20}$", options: .regularExpression) != nil,
              ElectronicsRemoteDigest.isSHA256(datasetSHA256),
              ElectronicsRemoteDigest.isGitObjectHash(producerRevision),
              ElectronicsRemoteDigest.isSHA256(toolingSHA256),
              !files.isEmpty, files.count <= ElectronicsRemoteLimits.snapshotFiles,
              Set(files.map(\.path)).count == files.count else {
            throw ElectronicsRemoteError.invalidManifest("identity or file set is invalid")
        }
        for file in files { try file.validate(label: file.path) }
    }

    public func file(path: String) throws -> ElectronicsRemoteFile {
        guard let value = files.first(where: { $0.path == path }) else {
            throw ElectronicsRemoteError.invalidManifest("manifest is missing \(path)")
        }
        return value
    }
}

public struct ElectronicsRemoteLicense: Codable, Hashable, Sendable {
    public var id: String
    public var attribution: String
    public var url: String?

    public init(id: String, attribution: String, url: String? = nil) {
        self.id = id; self.attribution = attribution; self.url = url
    }
}

public struct ElectronicsRemoteCatalog: Codable, Hashable, Sendable {
    public struct Source: Codable, Hashable, Sendable {
        public var id: String
        public var repository: String
        public var ref: String?
        public var commit: String
        public var license: ElectronicsRemoteLicense?
        public var recordCount: Int
        public var modifications: String?
        public var sourceStatus: String
        public var statuses: [String: Int]
        public var kinds: [String: Int]
        public var originalFileCount: Int
        public var originalBytes: Int
        public var index: ElectronicsRemoteFile
        public var chunks: [ElectronicsRemoteFile]
        public var originals: ElectronicsRemoteFile

        public init(id: String, repository: String, commit: String, license: ElectronicsRemoteLicense? = nil,
                    recordCount: Int, sourceStatus: String, statuses: [String: Int], kinds: [String: Int],
                    originalFileCount: Int, originalBytes: Int, index: ElectronicsRemoteFile,
                    chunks: [ElectronicsRemoteFile], originals: ElectronicsRemoteFile, ref: String? = nil,
                    modifications: String? = nil) {
            self.id = id; self.repository = repository; self.ref = ref; self.commit = commit; self.license = license
            self.recordCount = recordCount; self.modifications = modifications; self.sourceStatus = sourceStatus
            self.statuses = statuses; self.kinds = kinds; self.originalFileCount = originalFileCount
            self.originalBytes = originalBytes; self.index = index; self.chunks = chunks; self.originals = originals
        }

        public var downloadAssetName: String { id + "-2d.zip" }
    }

    public struct ModelSource: Codable, Hashable, Sendable {
        public var id: String
        public var licenseSourceID: String
        public var provider: String
        public var repository: String
        public var ref: String?
        public var commit: String
        public var license: ElectronicsRemoteLicense?

        public init(id: String, licenseSourceID: String, provider: String, repository: String,
                    commit: String, ref: String? = nil, license: ElectronicsRemoteLicense? = nil) {
            self.id = id; self.licenseSourceID = licenseSourceID; self.provider = provider
            self.repository = repository; self.ref = ref; self.commit = commit; self.license = license
        }
    }

    public var schemaVersion: Int
    public var format: String
    public var dataVersion: String
    public var datasetSHA256: String
    public var dimension: String
    public var nativeAppIntegration: String?
    public var producerRevision: String
    public var toolingSHA256: String
    public var sources: [Source]
    public var modelIndex: ElectronicsRemoteFile?
    public var modelCount: Int?
    public var modelSources: [ModelSource]?

    public init(dataVersion: String, datasetSHA256: String, producerRevision: String, toolingSHA256: String,
                sources: [Source], modelIndex: ElectronicsRemoteFile? = nil, modelCount: Int? = nil,
                modelSources: [ModelSource]? = nil, nativeAppIntegration: String? = nil) {
        self.schemaVersion = 1; self.format = "org.floe.electronics.exchange"; self.dataVersion = dataVersion
        self.datasetSHA256 = datasetSHA256; self.dimension = "2D"; self.nativeAppIntegration = nativeAppIntegration
        self.producerRevision = producerRevision; self.toolingSHA256 = toolingSHA256; self.sources = sources
        self.modelIndex = modelIndex; self.modelCount = modelCount; self.modelSources = modelSources
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= ElectronicsRemoteLimits.catalogBytes else {
            throw ElectronicsRemoteError.limits("catalogue")
        }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ElectronicsRemoteError.invalidCatalog("catalogue is not valid JSON") }
        try value.validate()
        return value
    }

    public func validate() throws {
        guard schemaVersion == 1, format == "org.floe.electronics.exchange", dimension == "2D",
              dataVersion.range(of: "^v1-[0-9a-f]{20}$", options: .regularExpression) != nil,
              ElectronicsRemoteDigest.isSHA256(datasetSHA256),
              ElectronicsRemoteDigest.isGitObjectHash(producerRevision),
              ElectronicsRemoteDigest.isSHA256(toolingSHA256),
              !sources.isEmpty, sources.count <= ElectronicsRemoteLimits.sources,
              Set(sources.map(\.id)).count == sources.count else {
            throw ElectronicsRemoteError.invalidCatalog("identity or source set is invalid")
        }
        if let modelCount {
            guard (0...ElectronicsRemoteLimits.modelIndexRows).contains(modelCount) else {
                throw ElectronicsRemoteError.invalidCatalog("model count is out of bounds")
            }
        }
        if let modelSources {
            guard modelSources.count <= ElectronicsRemoteLimits.sources,
                  Set(modelSources.map(\.id)).count == modelSources.count else {
                throw ElectronicsRemoteError.invalidCatalog("model source set is invalid")
            }
            for source in modelSources {
                guard ElectronicsRemoteValidation.safeSourceID(source.id),
                      ElectronicsRemoteValidation.safeSourceID(source.licenseSourceID),
                      ElectronicsRemoteDigest.isGitObjectHash(source.commit),
                      (try? ElectronicsRemoteValidation.normalizeRepository(source.repository)) != nil else {
                    throw ElectronicsRemoteError.invalidCatalog("model source \(source.id) is invalid")
                }
            }
        }
        var seenPaths = Set<String>()
        for source in sources {
            guard ElectronicsRemoteValidation.safeSourceID(source.id),
                  ElectronicsRemoteDigest.isGitObjectHash(source.commit),
                  (try? ElectronicsRemoteValidation.normalizeRepository(source.repository, allow2DLibrary: true)) != nil,
                  (0...250_000).contains(source.recordCount),
                  source.sourceStatus == "normalized" || source.sourceStatus == "empty-upstream",
                  (0...250_000).contains(source.originalFileCount),
                  (0...ElectronicsRemoteLimits.packageBytes).contains(source.originalBytes),
                  source.chunks.count <= 100_000 else {
                throw ElectronicsRemoteError.invalidCatalog("source \(source.id) identity is invalid")
            }
            for file in [source.index, source.originals] + source.chunks {
                try file.validate(label: "\(source.id)/\(file.path)")
                guard seenPaths.insert(file.path).inserted else {
                    throw ElectronicsRemoteError.invalidCatalog("duplicate artifact path \(file.path)")
                }
            }
            guard source.index.path == "indexes/\(source.id).jsonl.gz",
                  source.index.role == "search-index", source.index.sourceID == source.id,
                  source.originals.path == "originals/\(source.id).zip",
                  source.originals.role == "original-2d-sources", source.originals.sourceID == source.id,
                  source.chunks.allSatisfy({ $0.path.hasPrefix("records/\(source.id)/") && $0.role == "normalized-2d-records" && $0.sourceID == source.id }) else {
                throw ElectronicsRemoteError.invalidCatalog("source \(source.id) artifact roles/paths differ")
            }
        }
        if let modelIndex {
            guard modelIndex.path == "models.jsonl.gz", modelIndex.role == "model-index",
                  modelIndex.sourceID == nil else {
                throw ElectronicsRemoteError.invalidCatalog("model index identity is invalid")
            }
        }
        guard (modelIndex == nil) == (modelCount == nil) else {
            throw ElectronicsRemoteError.invalidCatalog("model index and count must appear together")
        }
    }

    public func source(id: String) throws -> Source {
        guard let value = sources.first(where: { $0.id == id }) else {
            throw ElectronicsRemoteError.invalidCatalog("library \(id) is absent from this catalogue")
        }
        return value
    }

    public func modelSource(id: String) throws -> ModelSource? {
        modelSources?.first(where: { $0.id == id })
    }

    public func allCatalogFiles() -> [ElectronicsRemoteFile] {
        sources.flatMap { [$0.index, $0.originals] + $0.chunks } + (modelIndex.map { [$0] } ?? [])
    }
}

/// Cross-binds the three publication documents before any snapshot replaces
/// the user's usable cache. Every hash here is from the canonical receipt.
public enum ElectronicsRemoteBinding {
    public static func validate(publication: ElectronicsRemotePublication,
                                catalog: ElectronicsRemoteCatalog,
                                manifest: ElectronicsRemoteManifest,
                                modelIndexBytes: Int?) throws {
        guard publication.dataVersion == catalog.dataVersion,
              publication.dataVersion == manifest.dataVersion,
              publication.datasetSHA256 == catalog.datasetSHA256,
              publication.datasetSHA256 == manifest.datasetSHA256,
              publication.producerRevision == catalog.producerRevision,
              publication.producerRevision == manifest.producerRevision,
              catalog.toolingSHA256 == manifest.toolingSHA256 else {
            throw ElectronicsRemoteError.invalidCatalog("release/catalogue/manifest binding differs")
        }
        let manifestByPath = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        for file in catalog.allCatalogFiles() {
            guard let listed = manifestByPath[file.path], listed.bytes == file.bytes,
                  listed.sha256 == file.sha256, listed.role == file.role,
                  listed.sourceID == file.sourceID else {
                throw ElectronicsRemoteError.invalidCatalog("manifest does not bind \(file.path) exactly")
            }
        }
        let releaseByName = Dictionary(uniqueKeysWithValues: publication.assets.map { ($0.name, $0) })
        for required in ["catalog.json", "manifest.json", "upstreams.lock.json"] {
            _ = try publication.asset(named: required)
        }
        if let index = catalog.modelIndex {
            guard let release = releaseByName[index.path], release.bytes == index.bytes,
                  release.sha256 == index.sha256 else {
                throw ElectronicsRemoteError.invalidCatalog("release does not bind the model index")
            }
            if let modelIndexBytes, modelIndexBytes != index.bytes {
                throw ElectronicsRemoteError.integrity("model index size differs from its receipt")
            }
        }
        for source in catalog.sources {
            guard let asset = releaseByName[source.downloadAssetName] else {
                throw ElectronicsRemoteError.invalidRelease("release is missing \(source.downloadAssetName)")
            }
            guard asset.role == "single-upstream-2d-library" else {
                throw ElectronicsRemoteError.invalidRelease("\(source.downloadAssetName) has the wrong role")
            }
        }
        guard releaseByName.values.contains(where: { $0.role == "all-2d-libraries" && $0.name.hasSuffix(".zip") }) else {
            throw ElectronicsRemoteError.invalidRelease("release has no full 2D package")
        }
    }
}

public enum ElectronicsRemoteMirrorRole: String, Codable, Hashable, Sendable {
    case releaseAssets
    case rawFiles
    case direct
}

/// One compiled transport route for a verified target. The canonical route
/// is always first and remains the authority; an approved alias may only be
/// tried after a definite availability failure and is still verified against
/// the same source Git object after its bytes arrive.
public struct ElectronicsRemoteRoute: Hashable, Sendable {
    public let url: URL
    public let mirrorRole: ElectronicsRemoteMirrorRole
    public init(url: URL, mirrorRole: ElectronicsRemoteMirrorRole) {
        self.url = url; self.mirrorRole = mirrorRole
    }
}

/// A target built only from a verified receipt/model row. A caller can never
/// pass an arbitrary remote URL: this type owns the fixed origins and the one
/// compiled GitHub alias for the official KiCad packages3D repository.
public struct ElectronicsRemoteTarget: Hashable, Sendable {
    /// Identity authority (GitLab for KiCad models, GitHub otherwise).
    public let canonicalURL: URL
    public let mirrorRole: ElectronicsRemoteMirrorRole
    /// Ordered routes: canonical authority first, then one approved alias.
    public let routes: [ElectronicsRemoteRoute]

    public static let dataOwner = "JiangNanGenius"
    public static let dataRepository = "floe-electronics-library"

    private init(url: URL, role: ElectronicsRemoteMirrorRole) {
        canonicalURL = url; mirrorRole = role
        routes = [.init(url: url, mirrorRole: role)]
    }

    private init(canonicalURL: URL, mirrorRole: ElectronicsRemoteMirrorRole,
                 aliasURL: URL) {
        self.canonicalURL = canonicalURL; self.mirrorRole = mirrorRole
        routes = [.init(url: canonicalURL, mirrorRole: .direct),
                  .init(url: aliasURL, mirrorRole: .rawFiles)]
    }

    /// Mutable latest pointer: fetched only from GitHub canonical bytes and
    /// never through a mirror (it selects the immutable tag to trust).
    public static func officialLatestReleaseReceipt() throws -> Self {
        guard let url = URL(string: "https://github.com/\(dataOwner)/\(dataRepository)/releases/latest/download/release.json") else {
            throw ElectronicsRemoteError.invalidTarget("latest release receipt")
        }
        return .init(url: url, role: .direct)
    }

    public static func releaseAsset(tag: String, name: String) throws -> Self {
        guard tag.range(of: "^data-v1-[0-9a-f]{20}$", options: .regularExpression) != nil,
              ElectronicsRemoteValidation.safeAssetName(name),
              let encoded = name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else {
            throw ElectronicsRemoteError.invalidTarget("release asset identity")
        }
        guard let url = URL(string: "https://github.com/\(dataOwner)/\(dataRepository)/releases/download/\(tag)/\(encoded)") else {
            throw ElectronicsRemoteError.invalidTarget("release asset URL")
        }
        return .init(url: url, role: .releaseAssets)
    }

    public static func dataFile(commit: String, path: String) throws -> Self {
        guard ElectronicsRemoteDigest.isGitObjectHash(commit) else {
            throw ElectronicsRemoteError.invalidTarget("data commit")
        }
        let encoded = try ElectronicsRemoteValidation.encodePath(path)
        guard let url = URL(string: "https://raw.githubusercontent.com/\(dataOwner)/\(dataRepository)/\(commit)/\(encoded)") else {
            throw ElectronicsRemoteError.invalidTarget("data file URL")
        }
        return .init(url: url, role: .rawFiles)
    }

    /// Builds the exact pinned file route for one verified model row.
    public static func repositoryFile(repository: String, revision: String, path: String) throws -> Self {
        guard ElectronicsRemoteDigest.isGitObjectHash(revision) else {
            throw ElectronicsRemoteError.invalidTarget("model revision")
        }
        let normalized = try ElectronicsRemoteValidation.normalizeRepository(repository)
        guard let parts = URLComponents(string: normalized), let host = parts.host else {
            throw ElectronicsRemoteError.invalidTarget("model repository")
        }
        let encoded = try ElectronicsRemoteValidation.encodePath(path)
        if host == "github.com" {
            let components = parts.path.dropFirst().split(separator: "/")
            guard components.count == 2 else { throw ElectronicsRemoteError.invalidTarget("GitHub model repository") }
            guard let url = URL(string: "https://raw.githubusercontent.com/\(components[0])/\(components[1])/\(revision)/\(encoded)") else {
                throw ElectronicsRemoteError.invalidTarget("GitHub model URL")
            }
            return .init(url: url, role: .rawFiles)
        }
        let project = parts.path.dropFirst() // kicad/libraries/kicad-packages3D
        guard let url = URL(string: "https://gitlab.com/\(project)/-/raw/\(revision)/\(encoded)") else {
            throw ElectronicsRemoteError.invalidTarget("GitLab model URL")
        }
        // One compiled alias only: the archived official mirror of the exact
        // KiCad packages3D repository. GitLab remains the version authority;
        // the alias is tried only after a definite availability failure and
        // the downloaded bytes still must match gitBlobSHA1.
        guard let alias = URL(string: "https://raw.githubusercontent.com/KiCad/kicad-packages3D/\(revision)/\(encoded)") else {
            throw ElectronicsRemoteError.invalidTarget("KiCad GitHub alias URL")
        }
        return .init(canonicalURL: url, mirrorRole: .direct, aliasURL: alias)
    }
}
