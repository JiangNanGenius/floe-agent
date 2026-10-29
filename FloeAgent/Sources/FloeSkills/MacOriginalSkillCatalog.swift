import Foundation
import FloeCore

/// A separately signed upstream-original channel. It makes no Linux guest
/// qualification claim; immutable source/files are the installation identity.
public struct MacOriginalSkillCatalog: Codable, Sendable {
    public struct File: Codable, Sendable, Equatable, Hashable {
        public let path: String
        public let sourcePath: String
        public let sha256: String
        public let bytes: Int64
        public let mode: String
    }
    public struct Entry: Codable, Sendable, Identifiable, Hashable {
        public let id: String
        public let name: CuratedSkillLocalizedText
        public let description: CuratedSkillLocalizedText
        public let category: CuratedSkillCategory
        public let version: String
        public let minimumAppVersion: String
        public let repository: String
        public let subdirectory: String
        public let commit: String
        public let license: String
        public let licensePath: String
        public let digest: String
        public let files: [File]
    }
    public let schemaVersion: Int
    public let channel: String
    public let entries: [Entry]
    public static let catalogPath = "macos/catalog.json"
    public static let signaturePath = "macos/catalog.json.sig"
    public static let maximumBytes = 4 * 1_024 * 1_024
    public static let maximumPackageBytes: Int64 = 16 * 1_024 * 1_024

    public static func verified(bytes: Data, signature: Data) throws -> Self {
        _ = try SignedContentFeedVerifier.verifyEnvelope(bytes: bytes, signature: signature,
            trustedKeys: CuratedSkillHub.productionTrustedKeys, maximumBytes: maximumBytes)
        let feed = try JSONDecoder().decode(Self.self, from: bytes)
        try feed.validate()
        return feed
    }
    public func validate() throws {
        guard schemaVersion == 1, channel == "macos-original", entries.count <= 256,
              Set(entries.map(\.id)).count == entries.count else { throw SignedContentFailure.feed }
        for entry in entries {
            try SkillIdentifier.validate(entry.id)
            _ = try SignedContentVersion(entry.version)
            _ = try SignedContentVersion(entry.minimumAppVersion)
            let repository = entry.repository.split(separator: "/", omittingEmptySubsequences: false)
            guard repository.count == 2, repository.allSatisfy({ Self.validComponent(String($0)) }),
                  Self.hex(entry.commit, length: 40), Self.hex(entry.digest, length: 64),
                  !entry.name.en.isEmpty, !entry.name.zhHans.isEmpty,
                  entry.name.en.count <= 128, entry.name.zhHans.count <= 128,
                  !entry.description.en.isEmpty, !entry.description.zhHans.isEmpty,
                  !entry.license.isEmpty, entry.license.count <= 256,
                  entry.files.count <= 2_048, !entry.files.isEmpty,
                  Set(entry.files.map(\.path)).count == entry.files.count,
                  Self.safePath(entry.licensePath), entry.subdirectory.isEmpty || Self.safePath(entry.subdirectory),
                  entry.files.contains(where: { $0.path == "SKILL.md" }),
                  entry.files.contains(where: { $0.path == entry.licensePath }),
                  entry.files.allSatisfy({ Self.safePath($0.path) && Self.safePath($0.sourcePath) && ($0.path == entry.licensePath || $0.sourcePath == (entry.subdirectory.isEmpty ? $0.path : entry.subdirectory + "/" + $0.path)) && Self.hex($0.sha256, length: 64) && $0.bytes >= 0 && $0.bytes <= Self.maximumPackageBytes && ["100644", "100755"].contains($0.mode) }),
                  entry.files.reduce(Int64(0), { $0 + $1.bytes }) <= Self.maximumPackageBytes else { throw SignedContentFailure.feed }
            let manifest = entry.files.sorted { $0.path < $1.path }.map { ["path": $0.path, "sourcePath": $0.sourcePath, "sha256": $0.sha256, "mode": $0.mode] }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard FloeDigest.sha256Hex(try encoder.encode(manifest)) == entry.digest else { throw SignedContentFailure.feed }
        }
    }
    public static func compatible(_ entry: Entry, appVersion: String) -> Bool {
        guard let app = try? SignedContentVersion(appVersion), let floor = try? SignedContentVersion(entry.minimumAppVersion) else { return false }
        return app >= floor
    }
    public static func sourcePath(_ entry: Entry, file: File) -> String {
        file.sourcePath
    }
    private static func hex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        } && value != "." && value != ".."
    }
    private static func safePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
