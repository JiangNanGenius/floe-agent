// SPDX-License-Identifier: MPL-2.0
//
// Device-workspace sync — wire policy helpers for the trusted native host.
//
// Ported from the reviewed iOS donor `FloeDeviceLink` package
// (`DeviceWorkspaceManifest.swift`), MPL-2.0:
//   * CryptoKit -> swift-crypto `Crypto` (the Android product graph already
//     links swift-crypto; SHA256 is platform-neutral there);
//   * the donor's `PortabilityPolicy.validatePortableRelativePath` gate is
//     inlined as `isPortableRelativePath` so this module needs no iOS-only
//     dependency (same rules: `/` separators, no empty/`.`/`..` segments, no
//     `\\`, `:`, control characters, no leading `~`);
//   * NFC + en_US_POSIX lowercase comparison keys (file-spelling collision
//     discipline) are unchanged from the donor.
//
// These helpers are the SINGLE authority for manifest limits, digest
// spelling and syncable-path admission on the native side; the Kotlin
// transport re-validates every manifest before it is sent (defense in
// depth, same as the donor).
import Foundation
import Crypto

// MARK: - Lane error (internal vocabulary mapped onto the fixed ABI status)

enum DeviceWorkspaceLaneError: Error, Sendable, Equatable {
    case invalidArguments
    case bufferTooSmall
    case unavailable
    case fenced
    case sessionUnknown
    case notShared
    case conflict
    case oversized
    case busy
    case ioFailure
}

// MARK: - Manifest constants (frozen wire contract)

enum DeviceWorkspaceManifest {
    /// Maximum manifest records (files + directories).
    static let maximumEntries = 10_000
    /// UTF-8 JSON manifest byte ceiling.
    static let maximumManifestBytes = 16 * 1_024 * 1_024
    /// Single-file ceiling.
    static let maximumFileBytes: Int64 = 1 << 30
    /// Whole-workspace regular-byte ceiling.
    static let maximumTotalBytes: Int64 = 8 << 30
    /// Wire chunk used by the transport (Kotlin); native never buffers more
    /// than one 64 KiB JNI page at a time.
    static let chunkSize = 384 * 1_024
    /// Maximum indexes per confirmation batch.
    static let confirmationLimit = 128
}

// MARK: - Wire entry

struct DeviceWorkspaceEntry: Sendable, Equatable {
    enum Kind: String, Sendable {
        case file, directory
    }

    let path: String
    let kind: Kind
    let size: Int64?
    let digest: String?

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

// MARK: - Digest spelling

enum DeviceWorkspaceDigest {
    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Directory-conflict scoping (frozen donor parity, `DeviceWorkspaceSyncHost`):
    /// a directory entry has no content digest, so its deterministic conflict
    /// location is scoped by the SHA-256 of the raw UTF-8 original path.
    static func pathDigest(_ path: String) -> String {
        hex(SHA256.hash(data: Data(path.utf8)))
    }
}

// MARK: - Path policy

enum DeviceWorkspacePath {
    static let conflicts = "Floe Sync Conflicts"
    static let temporaryPrefix = ".floe-workspace-sync-"

    private static let reserved: Set<String> = [
        ".", "..", ".git", ".svn", ".hg", ".ds_store", "node_modules", ".venv", "__pycache__",
        ".build", ".gradle", ".swiftpm", ".ssh", ".aws", ".gnupg", ".netrc", ".npmrc", ".pypirc",
        ".git-credentials", ".htpasswd", "floe sync conflicts",
    ]
    private static let secretPrefixes = [".env", ".pgpass", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    private static let secretExtensions: Set<String> = ["pem", "key", "keystore", "p12", "pfx", "jks"]

    /// NFC + locale-insensitive lowercase collation key (donor rule).
    static func comparisonKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// The donor's portable relative-path gate, inlined: `/` separators,
    /// at most 64 components, each 1...255 UTF-8 bytes and not `.`/`..`;
    /// no empty segments, backslash, colon, control characters or a `~`
    /// prefix; whole path <= 1024 UTF-8 bytes; NFC-comparable.
    static func isPortableRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("~"), !path.hasPrefix("/"),
              path.utf8.count <= 1_024 else { return false }
        var components = 0
        var componentBytes = 0
        for byte in path.utf8 {
            if byte == 47 {  // '/'
                guard componentBytes > 0 else { return false }
                componentBytes = 0
                components += 1
                guard components < 64 else { return false }
                continue
            }
            guard byte != 92, byte != 58, byte > 31, byte != 127 else { return false }
            componentBytes += 1
            guard componentBytes <= 255 else { return false }
        }
        guard componentBytes > 0 else { return false }
        return true
    }

    /// Admission rule for one canonical wire relative path (scan AND receive).
    /// Root-level `Mounts`/`Network` subtrees stay local, as do VCS/build
    /// internals, dot/credential material and the conflicts directory itself.
    static func isSyncable(_ path: String) -> Bool {
        guard isPortableRelativePath(path), !path.contains(":") else { return false }
        let keys = comparisonKey(path).split(separator: "/")
        guard keys.count <= 64, let first = keys.first, first != "mounts", first != "network" else { return false }
        return zip(path.split(separator: "/"), keys).allSatisfy { original, key in
            let name = String(key)
            return !name.isEmpty
                && !reserved.contains(name) && name != ".floe" && !name.hasPrefix(".floe-")
                && !secretPrefixes.contains(where: { name.hasPrefix($0) })
                && !secretExtensions.contains((name as NSString).pathExtension.lowercased(with: Locale(identifier: "en_US_POSIX")))
        }
    }
}
