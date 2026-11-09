// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A base disk image this manifest may adopt as an existing environment disk.
///
/// An environment disk is a mutable clone of one base disk and its sidecar
/// records the exact image id, SHA-512 and byte count it was cloned from; a
/// later catalog image whose disk differs byte-for-byte would otherwise be a
/// conflict. A runner-only component release ships the same base image with
/// just `/usr/local/bin/floe-exec` replaced, so it declares the exact
/// predecessor here: only an origin that matches all three recorded fields is
/// adopted, the mutable disk and its original `origin.json` stay untouched,
/// and the runner is replaced in-guest from the verified standalone runner
/// artifact. Any other origin is still a conflict and is never overwritten.
public struct LinuxGuestCompatibleDiskOrigin: Sendable, Equatable, Codable {
    public var imageID: String
    public var artifactSHA512: String
    public var artifactBytes: Int64

    public init(imageID: String, artifactSHA512: String, artifactBytes: Int64) {
        self.imageID = imageID
        self.artifactSHA512 = artifactSHA512
        self.artifactBytes = artifactBytes
    }
}

/// Sidecar next to one environment disk. `artifactSHA512` is the digest the
/// verified manifest declared for the base disk when this environment disk was
/// first copied; later starts compare against that record — never against a
/// re-hash of the (intentionally mutated) environment copy.
///
/// Schema history:
///  - v1: image id + base digest/bytes (no logical-capacity record).
///  - v2: adds `logicalCapacityBytes` plus migration provenance; a v1
///    sidecar is decoded with absent capacity and the disk is grown once,
///    in place, then rewritten as v2.
struct LinuxGuestRuntimeDiskOrigin: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var imageID: String
    var artifactSHA512: String
    var artifactBytes: Int64
    var createdAt: Date
    /// Logical size of the raw container in bytes after host-side
    /// preparation. nil for a v1 sidecar; such a disk is migrated (grown)
    /// once and the sidecar is rewritten as v2.
    var logicalCapacityBytes: Int64?
    /// Logical capacity before the last grow-only migration, nil for a disk
    /// created already at its target capacity.
    var migratedFromCapacityBytes: Int64?
    var migratedAt: Date?

    init(
        imageID: String,
        artifactSHA512: String,
        artifactBytes: Int64,
        createdAt: Date = Date(),
        logicalCapacityBytes: Int64? = nil,
        migratedFromCapacityBytes: Int64? = nil,
        migratedAt: Date? = nil
    ) {
        self.version = Self.currentVersion
        self.imageID = imageID
        self.artifactSHA512 = artifactSHA512
        self.artifactBytes = artifactBytes
        self.createdAt = createdAt
        self.logicalCapacityBytes = logicalCapacityBytes
        self.migratedFromCapacityBytes = migratedFromCapacityBytes
        self.migratedAt = migratedAt
    }

    var summary: String {
        let capacity = logicalCapacityBytes.map { String($0) } ?? "v1"
        return "image \(imageID) (\(artifactSHA512.prefix(16))…, \(artifactBytes) bytes, capacity \(capacity))"
    }
}

/// The shared resident owner's existing storage layout. Changing catalog
/// preference never changes these paths or the on-disk origin schema.
public enum LinuxResidentDiskStorage {
    public static let environmentID = "resident-arm64"
    public static let containerDirectoryName = "LinuxGuest"
    public static let diskFileName = "disk.img"
    public static let originFileName = "origin.json"

    public static func directory(in residentRoot: URL) -> URL {
        residentRoot.standardizedFileURL
            .appendingPathComponent(containerDirectoryName, isDirectory: true)
            .appendingPathComponent("disks", isDirectory: true)
            .appendingPathComponent(environmentID, isDirectory: true)
    }
}
