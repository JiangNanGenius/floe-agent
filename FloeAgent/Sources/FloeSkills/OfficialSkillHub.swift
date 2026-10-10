import Foundation
import Crypto
import ZIPFoundation
import FloeCore

/// The signed catalog is data, never a source of new trust roots or native code.
public enum OfficialSkillHub {
    public static let owner = "JiangNanGenius"
    public static let repository = "floe-agent"
    public static let catalogPath = "skill-hub/catalog.json"
    public static let skillIDs: Set<String> = ["floe-pdf", "floe-office", "floe-network", "floe-video"]
    /// App-signed bundles may advance an unmodified official install offline.
    /// This does not authorize imports, downgrades, or same-version rewrites.
    public static func acceptsBundledUpgrade(id: String, sourceURL: String?,
                                             installedVersion: String, bundledVersion: String,
                                             sourceDigest: String?, installedDigest: String) -> Bool {
        guard skillIDs.contains(id), sourceDigest == installedDigest,
              let installed = try? SignedContentVersion(installedVersion),
              let bundled = try? SignedContentVersion(bundledVersion), installed < bundled else { return false }
        if sourceURL == BundledDomainSkills.sourceURL(for: id) { return true }
        guard let sourceURL, let url = URL(string: sourceURL), url.scheme == "https",
              url.host == "github.com", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        return parts.count == 6 && parts[0] == owner && parts[1] == repository
            && parts[2] == "blob" && parts[4] == "skill-hub" && parts[5] == "catalog.json"
    }
    public static func source() throws -> GitHubSkillSource {
        try GitHubSkillSource(owner: owner, repository: repository, ref: "main", path: catalogPath)
    }

    public struct Catalog: Codable, Sendable {
        public let schemaVersion: Int
        public let publisher: String
        public let packages: [Package]
    }
    public struct Package: Codable, Sendable {
        public let id: String
        public let version: String
        public let path: String
        public let size: Int
        public let sha256: String
        public let contentDigest: String
        public let minimumAppVersion: String
        public let releaseNotes: [String: String]
    }
    public struct Signature: Codable, Sendable {
        public let keyID: String
        public let signature: String
    }
    public enum Failure: Error, Equatable, LocalizedError {
        case source, signature, catalog, incompatible, archive, immutableVersion
        public var errorDescription: String? {
            switch self {
            case .source: "Official skills can update only from JiangNanGenius/floe-agent/skill-hub"
            case .signature: "Official Skill Hub signature verification failed"
            case .catalog: "Invalid official Skill Hub catalog or package identity"
            case .incompatible: "Update Floe before installing this skill version"
            case .archive: "Unsafe, oversized or corrupt skill ZIP"
            case .immutableVersion: "Published skill versions cannot change content; publish a new version"
            }
        }
    }

    public static func validateSource(_ source: GitHubSkillSource) throws {
        guard source.owner == owner, source.repository == repository,
              source.path == catalogPath else { throw Failure.source }
    }

    public static func verifiedPackage(catalog bytes: Data, signature: Data, id: String,
                                       appVersion: String, trustedKeys: [String: Data]) throws -> Package {
        do {
            _ = try SignedContentFeedVerifier.verifyEnvelope(
                bytes: bytes, signature: signature, trustedKeys: trustedKeys
            )
        } catch {
            throw Failure.signature
        }
        let catalog: Catalog
        do {
            catalog = try JSONDecoder().decode(Catalog.self, from: bytes)
        } catch {
            throw Failure.catalog
        }
        guard [1, 2].contains(catalog.schemaVersion), catalog.publisher == owner,
              catalog.packages.count == skillIDs.count,
              Set(catalog.packages.map(\.id)) == skillIDs else { throw Failure.catalog }
        for package in catalog.packages {
            guard (try? SignedContentVersion(package.version)) != nil,
                  (try? SignedContentVersion(package.minimumAppVersion)) != nil,
                  package.path == "skill-hub/packages/\(package.id)/\(package.version)/\(package.id).zip",
                  (1...8_388_608).contains(package.size),
                  [package.sha256, package.contentDigest].allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }),
                  package.releaseNotes["zh-Hans"]?.isEmpty == false,
                  package.releaseNotes["en"]?.isEmpty == false else { throw Failure.catalog }
        }
        guard let package = catalog.packages.first(where: { $0.id == id }) else { throw Failure.catalog }
        guard let app = try? SignedContentVersion(appVersion),
              let minimum = try? SignedContentVersion(package.minimumAppVersion),
              minimum <= app else { throw Failure.incompatible }
        return package
    }

    public static func stage(id: String, appVersion: String, installed: SkillContentSnapshot,
                             at root: URL, trustedKeys: [String: Data],
                             resolve: GitHubSkillDownload.ResolveCommit,
                             fetch: GitHubSkillDownload.FetchFile) async throws -> SkillUpgradeCandidate {
        let source = try source()
        let commit = try await resolve(source)
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else { throw SkillUpgradeError.invalidCommit }
        let catalog = try await fetch(source, commit, catalogPath)
        let signature = try await fetch(source, commit, "skill-hub/catalog.sig")
        let package = try verifiedPackage(catalog: catalog, signature: signature, id: id,
                                          appVersion: appVersion, trustedKeys: trustedKeys)
        guard installed.package.manifest.id == id else { throw Failure.catalog }
        let zip = try await fetch(source, commit, package.path)
        guard zip.count == package.size, digest(zip) == package.sha256.lowercased() else { throw SkillUpgradeError.hashMismatch(package.path) }
        let proposed = try unpack(zip, at: root)
        do {
            guard proposed.package.manifest.id == id, proposed.package.manifest.version == package.version,
                  proposed.package.canonicalSHA256 == package.contentDigest.lowercased() else { throw Failure.catalog }
            return try SkillUpgradeCandidate(verifiedSource: source, commit: commit, installed: installed, proposed: proposed, releaseNotes: package.releaseNotes)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// Bounded in-memory extraction validates every entry before creating files.
    /// A fresh root and no symlinks prevent output paths escaping staging.
    /// The shared archive gate owns path/size/checksum bounds; the skill
    /// validator owns the package contract.
    public static func unpack(_ zip: Data, at root: URL) throws -> SkillContentSnapshot {
        let allowedTopLevel: Set<String> = ["SKILL.md", "floe.json", "scripts", "references", "assets", "agents"]
        do {
            let files = try SignedContentArchive.extract(
                zip, at: root,
                limits: SignedContentArchiveLimits(
                    maximumEntries: 128,
                    maximumFileBytes: 2_097_152,
                    maximumTotalBytes: 8_388_608
                ),
                allowedTopLevel: allowedTopLevel
            )
            guard files["SKILL.md"] != nil, files["floe.json"] != nil else { throw Failure.archive }
            let package = try SkillPackageValidator().validate(packageAt: root)
            return try SkillContentSnapshot(root: root, expectedDigest: package.canonicalSHA256)
        } catch let failure as Failure {
            try? FileManager.default.removeItem(at: root)
            throw failure
        } catch let validation as SkillValidationError {
            try? FileManager.default.removeItem(at: root)
            throw validation
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw Failure.archive
        }
    }

    private static func digest(_ bytes: Data) -> String {
        FloeDigest.sha256Hex(bytes)
    }
}
