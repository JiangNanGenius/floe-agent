import Foundation
import Crypto
import FloeCore

/// Explicit source identity. The mutable ref is resolved once, and every file
/// thereafter is fetched from the resulting immutable commit.
public struct GitHubSkillSource: Codable, Equatable, Sendable {
    public let owner: String
    public let repository: String
    public let ref: String
    public let path: String

    private enum CodingKeys: String, CodingKey { case owner, repository, ref, path }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(owner: values.decode(String.self, forKey: .owner), repository: values.decode(String.self, forKey: .repository),
            ref: values.decode(String.self, forKey: .ref), path: values.decode(String.self, forKey: .path))
    }

    public init(owner: String, repository: String, ref: String, path: String) throws {
        for component in [owner, repository] {
            guard !component.isEmpty, component.count <= 100,
                  component.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
                  component != ".", component != ".." else { throw SkillUpgradeError.invalidSource }
        }
        guard !ref.isEmpty, ref.count <= 200, !ref.contains(".."),
              !ref.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "?" || $0 == "#" }) else { throw SkillUpgradeError.invalidSource }
        try Self.validatePath(path)
        self.owner = owner; self.repository = repository; self.ref = ref; self.path = path
    }

    public static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("%"), !path.contains("\0"),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw SkillUpgradeError.invalidSource }
    }
}

public enum SkillUpgradeError: Error, Equatable, Sendable, LocalizedError {
    case invalidSource, invalidCommit, invalidInventory, hashMismatch(String), localConflict, identityChanged, versionRegression, reviewRequired
    public var errorDescription: String? {
        switch self {
        case .invalidSource: "Invalid GitHub source or relative package path"
        case .invalidCommit: "GitHub did not return an immutable commit"
        case .invalidInventory: "Invalid or oversized skill package inventory"
        case .hashMismatch(let path): "Downloaded file failed integrity verification: \(path)"
        case .localConflict: "The installed skill changed; review the update again"
        case .identityChanged: "An update cannot change the skill identifier"
        case .versionRegression: "Use explicit rollback to restore an older skill version"
        case .reviewRequired: "The exact package changes must be reviewed before applying"
        }
    }
}

/// A package entry file lists exactly the files allowed to be downloaded.
/// Links inside Markdown are never traversed. Native payloads are subsequently
/// rejected by SkillPackageValidator, even if their hashes match this index.
public struct GitHubSkillInventory: Codable, Equatable, Sendable {
    public let files: [String: String]
    public init(files: [String: String]) { self.files = files }
}

public struct SkillUpgradeCandidate: Sendable {
    public let source: GitHubSkillSource
    public let commit: String
    public let expectedInstalledDigest: String
    public let snapshot: SkillContentSnapshot
    public let installedSnapshot: SkillContentSnapshot
    public let changedFiles: [String]
    public let addedCapabilities: Set<String>
    public let addedTools: Set<String>
    public let releaseNotes: [String: String]

    public init(source: GitHubSkillSource, commit: String, installed: SkillContentSnapshot, proposed: SkillContentSnapshot) throws {
        guard !OfficialSkillHub.skillIDs.contains(proposed.package.manifest.id) else { throw OfficialSkillHub.Failure.signature }
        try self.init(verifiedSource: source, commit: commit, installed: installed, proposed: proposed)
    }

    init(verifiedCurated staged: CuratedSkillHub.StagedSkill, installed: SkillContentSnapshot) throws {
        let receipt = staged.receipt
        let proposed = staged.content
        guard receipt.feedStatus == .production,
              receipt.feedSignatureKeyID == CuratedSkillHub.productionKeyID,
              receipt.reviewKeyID == CuratedSkillHub.productionKeyID,
              receipt.reviewDecision == .approve,
              receipt.contentDigest == proposed.package.canonicalSHA256,
              receipt.entryID == proposed.package.manifest.id,
              receipt.entryVersion == proposed.package.manifest.version else {
            throw CuratedSkillHubFailure.review("A verified production package is required for this upgrade")
        }
        guard installed.package.manifest.id == proposed.package.manifest.id else { throw SkillUpgradeError.identityChanged }
        guard receipt.publicationCommit.count == 40, receipt.publicationCommit.allSatisfy(\.isHexDigit) else { throw SkillUpgradeError.invalidCommit }
        let oldVersion = try SignedContentVersion(installed.package.manifest.version)
        let newVersion = try SignedContentVersion(proposed.package.manifest.version)
        guard !(newVersion < oldVersion) else { throw SkillUpgradeError.versionRegression }
        if installed.package.manifest.version == proposed.package.manifest.version,
           installed.package.canonicalSHA256 != proposed.package.canonicalSHA256 {
            throw CuratedSkillHubFailure.immutableVersion("A published version cannot change its package bytes")
        }
        source = try CuratedSkillHub.source(channel: receipt.channel)
        commit = receipt.publicationCommit
        releaseNotes = [:]
        expectedInstalledDigest = installed.package.canonicalSHA256
        snapshot = proposed
        installedSnapshot = installed
        changedFiles = Set(installed.files.keys).union(proposed.files.keys).filter { installed.files[$0] != proposed.files[$0] }.sorted()
        addedCapabilities = Set(proposed.package.manifest.capabilities).subtracting(installed.package.manifest.capabilities)
        addedTools = Set(proposed.package.manifest.tools).subtracting(installed.package.manifest.tools)
    }

    /// Module-internal entry used only after OfficialSkillHub has verified the
    /// signed catalog, package ZIP and canonical digest. App callers cannot
    /// manufacture an official update merely by supplying an allowed URL.
    init(verifiedSource source: GitHubSkillSource, commit: String, installed: SkillContentSnapshot, proposed: SkillContentSnapshot, releaseNotes: [String: String] = [:]) throws {
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else { throw SkillUpgradeError.invalidCommit }
        guard installed.package.manifest.id == proposed.package.manifest.id else { throw SkillUpgradeError.identityChanged }
        if OfficialSkillHub.skillIDs.contains(proposed.package.manifest.id) {
            try OfficialSkillHub.validateSource(source)
            if installed.package.manifest.version == proposed.package.manifest.version,
               installed.package.canonicalSHA256 != proposed.package.canonicalSHA256 {
                throw OfficialSkillHub.Failure.immutableVersion
            }
        }
        let oldVersion = installed.package.manifest.version.split(separator: ".").compactMap { Int($0) }
        let newVersion = proposed.package.manifest.version.split(separator: ".").compactMap { Int($0) }
        if let difference = zip(oldVersion, newVersion).first(where: { $0.0 != $0.1 }), difference.1 < difference.0 {
            throw SkillUpgradeError.versionRegression
        }
        self.source = source; self.commit = commit.lowercased()
        self.releaseNotes = releaseNotes
        expectedInstalledDigest = installed.package.canonicalSHA256
        snapshot = proposed
        installedSnapshot = installed
        changedFiles = Set(installed.files.keys).union(proposed.files.keys).filter { installed.files[$0] != proposed.files[$0] }.sorted()
        addedCapabilities = Set(proposed.package.manifest.capabilities).subtracting(installed.package.manifest.capabilities)
        addedTools = Set(proposed.package.manifest.tools).subtracting(installed.package.manifest.tools)
    }
}

public enum GitHubSkillDownload {
    /// Transport owns authentication and redirect policy. The updater never
    /// receives, persists or prints a credential.
    public typealias ResolveCommit = @Sendable (GitHubSkillSource) async throws -> String
    public typealias FetchFile = @Sendable (GitHubSkillSource, String, String) async throws -> Data

    public static func stage(source: GitHubSkillSource, at root: URL, markdownBase: SkillContentSnapshot? = nil, resolve: ResolveCommit, fetch: FetchFile) async throws -> (String, SkillContentSnapshot) {
        let commit = try await resolve(source)
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else { throw SkillUpgradeError.invalidCommit }
        if !source.path.lowercased().hasSuffix(".json") {
            return (commit.lowercased(), try await stageDirectory(source: source, commit: commit, at: root, fetch: fetch))
        }
        let entry = try await fetch(source, commit, source.path)
        guard entry.count <= 262_144 else { throw SkillUpgradeError.invalidInventory }
        let inventory = try JSONDecoder().decode(GitHubSkillInventory.self, from: entry)
        guard inventory.files.count <= 128, inventory.files["SKILL.md"] != nil else { throw SkillUpgradeError.invalidInventory }
        let parent = source.path.split(separator: "/").dropLast().joined(separator: "/")
        var files: [String: Data] = [:], total = 0
        // Validate the complete inventory before any additional request.
        for (path, hash) in inventory.files {
            try GitHubSkillSource.validatePath(path)
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw SkillUpgradeError.invalidInventory }
        }
        for path in inventory.files.keys.sorted() {
            try Task.checkCancellation()
            let bytes = try await fetch(source, commit, parent.isEmpty ? path : parent + "/" + path)
            total += bytes.count
            guard bytes.count <= 2_097_152, total <= 8_388_608 else { throw SkillUpgradeError.invalidInventory }
            let hash = FloeDigest.sha256Hex(bytes)
            guard hash == inventory.files[path]?.lowercased() else { throw SkillUpgradeError.hashMismatch(path) }
            files[path] = bytes
        }
        return (commit.lowercased(), try materialize(files, at: root))
    }

    private struct DirectoryEntry: Decodable {
        var name: String
        var path: String
        var type: String
        var size: Int
        var sha: String
        var target: String?
        var submodule_git_url: String?
    }

    /// GitHub's Contents endpoint returns arrays for directories even with
    /// raw+json Accept. Reuse the authenticated fixed-host file transport,
    /// pinned to ONE resolved commit; never follow download_url or Markdown.
    private static func stageDirectory(source: GitHubSkillSource, commit: String,
                                       at root: URL, fetch: FetchFile) async throws -> SkillContentSnapshot {
        let parent = source.path.lowercased().hasSuffix(".md")
            ? source.path.split(separator: "/").dropLast().joined(separator: "/") : source.path
        var pending = [(parent, 0)]
        var seen = Set<String>(), normalizedFiles = Set<String>()
        var files: [String: Data] = [:]
        var total = 0, entries = 0
        while let (directory, depth) = pending.popLast() {
            try Task.checkCancellation()
            guard depth <= 16, seen.insert(directory).inserted else { throw SkillUpgradeError.invalidInventory }
            let listing = try await fetch(source, commit, directory)
            guard listing.count <= 2_097_152,
                  let children = try? JSONDecoder().decode([DirectoryEntry].self, from: listing),
                  children.count < 1_000 else { throw SkillUpgradeError.invalidInventory }
            entries += children.count
            guard entries <= 512 else { throw SkillUpgradeError.invalidInventory }
            for child in children.sorted(by: { $0.path < $1.path }) {
                try GitHubSkillSource.validatePath(child.path)
                let expected = directory.isEmpty ? child.name : directory + "/" + child.name
                guard child.path == expected, !child.name.contains("/"), child.target == nil,
                      child.submodule_git_url == nil,
                      child.sha.count == 40, child.sha.allSatisfy(\.isHexDigit) else {
                    throw SkillUpgradeError.invalidInventory
                }
                let relative = parent.isEmpty ? child.path : String(child.path.dropFirst(parent.count + 1))
                try GitHubSkillSource.validatePath(relative)
                if child.type == "dir" {
                    pending.append((child.path, depth + 1))
                } else if child.type == "file" {
                    guard child.size >= 0, child.size <= 2_097_152,
                          files.count < 128, normalizedFiles.insert(relative.lowercased()).inserted else {
                        throw SkillUpgradeError.invalidInventory
                    }
                    let bytes = try await fetch(source, commit, child.path)
                    total += bytes.count
                    guard bytes.count == child.size, total <= 8_388_608 else { throw SkillUpgradeError.invalidInventory }
                    var blob = Insecure.SHA1()
                    blob.update(data: Data("blob \(bytes.count)\0".utf8))
                    blob.update(data: bytes)
                    guard blob.finalize().map({ String(format: "%02x", $0) }).joined() == child.sha.lowercased() else {
                        throw SkillUpgradeError.hashMismatch(relative)
                    }
                    files[relative] = bytes
                } else {
                    throw SkillUpgradeError.invalidInventory // no symlink/submodule traversal
                }
            }
        }
        guard files["SKILL.md"] != nil else { throw SkillUpgradeError.invalidInventory }
        return try materialize(files, at: root)
    }

    private static func materialize(_ files: [String: Data], at root: URL) throws -> SkillContentSnapshot {
        // Caller supplies a fresh temporary directory, never the live package.
        guard !FileManager.default.fileExists(atPath: root.path) else { throw SkillUpgradeError.localConflict }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for (path, bytes) in files {
                try GitHubSkillSource.validatePath(path)
                let target = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target, options: .atomic)
            }
            let package = try SkillPackageValidator().validate(packageAt: root, requireManifest: false)
            return try SkillContentSnapshot(root: root, expectedDigest: package.canonicalSHA256, manifestOverride: package.manifest)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
