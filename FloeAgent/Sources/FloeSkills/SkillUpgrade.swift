import Foundation
import Crypto

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

    public init(source: GitHubSkillSource, commit: String, installed: SkillContentSnapshot, proposed: SkillContentSnapshot) throws {
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
        let entry = try await fetch(source, commit, source.path)
        guard entry.count <= 262_144 else { throw SkillUpgradeError.invalidInventory }
        if source.path.lowercased().hasSuffix(".md") {
            guard let markdownBase else { throw SkillUpgradeError.invalidInventory }
            var files = markdownBase.files
            files["SKILL.md"] = entry
            return (commit.lowercased(), try materialize(files, at: root))
        }
        let inventory = try JSONDecoder().decode(GitHubSkillInventory.self, from: entry)
        guard inventory.files.count <= 128, inventory.files["SKILL.md"] != nil, inventory.files["floe.json"] != nil else { throw SkillUpgradeError.invalidInventory }
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
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard hash == inventory.files[path]?.lowercased() else { throw SkillUpgradeError.hashMismatch(path) }
            files[path] = bytes
        }
        return (commit.lowercased(), try materialize(files, at: root))
    }

    private static func materialize(_ files: [String: Data], at root: URL) throws -> SkillContentSnapshot {
        // Caller supplies a fresh temporary directory, never the live package.
        guard !FileManager.default.fileExists(atPath: root.path) else { throw SkillUpgradeError.localConflict }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for (path, bytes) in files {
                let target = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target, options: .atomic)
            }
            let package = try SkillPackageValidator().validate(packageAt: root)
            return try SkillContentSnapshot(root: root, expectedDigest: package.canonicalSHA256)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
