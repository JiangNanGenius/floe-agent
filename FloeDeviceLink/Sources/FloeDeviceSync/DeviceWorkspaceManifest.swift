// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import FloeDesktopSync
import Foundation

public struct DeviceWorkspaceEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case file, directory }

    public let path: String
    public let kind: Kind
    public let size: Int64?
    public let digest: String?

    init(directory path: String) {
        self.path = path
        kind = .directory
        size = nil
        digest = nil
    }

    init(file path: String, size: Int64, digest: String) {
        self.path = path
        kind = .file
        self.size = size
        self.digest = digest
    }
}

struct DeviceWorkspaceManifest: Codable, Sendable {
    static let maximumEntries = 10_000
    static let maximumManifestBytes = 16 * 1_024 * 1_024
    static let maximumFileBytes: Int64 = 1 << 30
    static let maximumTotalBytes: Int64 = 8 << 30
    static let chunkSize = 384 * 1_024
    static let confirmationLimit = 128

    let entries: [DeviceWorkspaceEntry]

    func validated() throws -> Self {
        guard entries.count <= Self.maximumEntries else { throw DeviceHistorySyncError.tooLarge }
        var total: Int64 = 0
        var paths: [String: DeviceWorkspaceEntry.Kind] = [:]
        var ancestorSpellings: [String: String] = [:]
        for entry in entries {
            guard DeviceWorkspacePath.isSyncable(entry.path) else { throw DeviceHistorySyncError.invalidResponse }
            let key = DeviceWorkspacePath.comparisonKey(entry.path)
            guard paths.updateValue(entry.kind, forKey: key) == nil else {
                throw DeviceHistorySyncError.invalidResponse
            }
            var prefix = ""
            for component in entry.path.split(separator: "/") {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                let normalized = DeviceWorkspacePath.comparisonKey(prefix)
                if let spelling = ancestorSpellings[normalized] {
                    guard spelling.utf8.elementsEqual(prefix.utf8) else {
                        throw DeviceHistorySyncError.invalidResponse
                    }
                } else {
                    ancestorSpellings[normalized] = prefix
                }
            }
            switch entry.kind {
            case .directory:
                guard entry.size == nil, entry.digest == nil else { throw DeviceHistorySyncError.invalidResponse }
            case .file:
                guard let size = entry.size, size >= 0, let digest = entry.digest,
                      DeviceWorkspaceDigest.isValid(digest) else { throw DeviceHistorySyncError.invalidResponse }
                guard size <= Self.maximumFileBytes, size <= Self.maximumTotalBytes - total else {
                    throw DeviceHistorySyncError.tooLarge
                }
                total += size
            }
        }
        for path in paths.keys {
            let components = path.split(separator: "/")
            var ancestor = ""
            for component in components.dropLast() {
                ancestor = ancestor.isEmpty ? String(component) : ancestor + "/" + component
                guard paths[ancestor] != .file else { throw DeviceHistorySyncError.invalidResponse }
            }
        }
        return self
    }
}

enum DeviceWorkspaceDigest {
    static func hex(_ digest: SHA256.Digest) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        return String(decoding: digest.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }, as: UTF8.self)
    }

    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum DeviceWorkspacePath {
    static let conflicts = "Floe Sync Conflicts"
    static let temporaryPrefix = ".floe-workspace-sync-"
    private static let reserved: Set<String> = [
        ".", "..", ".git", ".svn", ".hg", ".ds_store", "node_modules", ".venv", "__pycache__",
        ".build", ".gradle", ".swiftpm", ".ssh", ".aws", ".gnupg", ".netrc", ".npmrc", ".pypirc",
        ".git-credentials", ".htpasswd", "floe sync conflicts"
    ]
    private static let secretPrefixes = [".env", ".pgpass", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    private static let secretExtensions: Set<String> = ["pem", "key", "keystore", "p12", "pfx", "jks"]

    static func comparisonKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func isSyncable(_ path: String) -> Bool {
        guard path.utf8.count <= 1_024, !path.contains(":"),
              (try? PortabilityPolicy.validatePortableRelativePath(path)) != nil else { return false }
        let keys = comparisonKey(path).split(separator: "/")
        guard keys.count <= 64, let first = keys.first, first != "mounts", first != "network" else { return false }
        return zip(path.split(separator: "/"), keys).allSatisfy { original, key in
            let name = String(key)
            return original.utf8.count <= 255 && !original.utf8.contains(127)
                && !reserved.contains(name) && name != ".floe" && !name.hasPrefix(".floe-")
                && !secretPrefixes.contains(where: { name.hasPrefix($0) })
                && !secretExtensions.contains((name as NSString).pathExtension)
        }
    }
}
