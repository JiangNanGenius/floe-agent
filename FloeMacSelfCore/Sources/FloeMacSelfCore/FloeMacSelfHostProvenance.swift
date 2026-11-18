// SPDX-License-Identifier: MPL-2.0
//
// Host-supplied provenance for the verified authority primitive.
//
// `FloeAuthorityPrimitive` binds one exact database identity: every path,
// owner, mode and (device, inode) it checks must be *trusted host provenance*
// captured by the host before the runtime starts. The composition layer never
// derives trust from `databaseURL` on its own. This type is that host
// contract: the host records the private directory, the host-stable lock
// directory, the database name, and the exact identities it observed, then
// hands the record to `FloeMacSelfRuntime`.
//
// This is a consistency and binding contract, not authentication. The
// composition layer cannot prove the host truly owns the workspace or that its
// capture happened before an attacker touched the path; the primitive
// re-verifies every identity at acquisition and fails closed on any mismatch.
// A host that fabricates provenance for a path it does not control gains
// nothing: acquisition still binds the real filesystem identity.

import Darwin
import Foundation

/// Exact filesystem identity (device, inode) observed by the host.
public struct FloeMacSelfFileIdentity: Sendable, Hashable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    init(_ value: stat) {
        self.init(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    init(_ identity: FloeAuthorityIdentity) {
        self.init(device: UInt64(identity.device), inode: UInt64(identity.inode))
    }

    var primitiveIdentity: FloeAuthorityIdentity {
        FloeAuthorityIdentity(
            device: dev_t(truncatingIfNeeded: device),
            inode: ino_t(truncatingIfNeeded: inode)
        )
    }
}

/// Trusted provenance record for one host-selected private database.
public struct FloeMacSelfHostProvenance: Sendable, Hashable {
    /// Trusted path to the directory that directly contains the database.
    /// Every intermediate component may be a platform alias (for example
    /// `/var` on macOS); the named directory itself must be a real directory.
    public let directoryPath: String
    /// Host-stable private directory that holds the identity-bound lock file.
    /// It must not move when the database is renamed or moved.
    public let lockDirectoryPath: String
    /// Database file name inside `directoryPath` (no path separators).
    public let databaseName: String
    /// Identity the host observed for `directoryPath`.
    public let directoryIdentity: FloeMacSelfFileIdentity
    /// Identity the host observed for `lockDirectoryPath`.
    public let lockDirectoryIdentity: FloeMacSelfFileIdentity
    /// Identity the host observed for the database file.
    public let databaseIdentity: FloeMacSelfFileIdentity

    public init(
        directoryPath: String,
        lockDirectoryPath: String,
        databaseName: String,
        directoryIdentity: FloeMacSelfFileIdentity,
        lockDirectoryIdentity: FloeMacSelfFileIdentity,
        databaseIdentity: FloeMacSelfFileIdentity
    ) {
        self.directoryPath = directoryPath
        self.lockDirectoryPath = lockDirectoryPath
        self.databaseName = databaseName
        self.directoryIdentity = directoryIdentity
        self.lockDirectoryIdentity = lockDirectoryIdentity
        self.databaseIdentity = databaseIdentity
    }

    /// Records whatever identity the filesystem currently reports for the
    /// named paths. This only captures bytes; it does not establish trust. The
    /// caller must have created or validated these paths through its own
    /// trusted path first. The primitive re-verifies every identity at
    /// acquisition and rejects any path, owner, mode or identity that does not
    /// match exactly. Missing paths, symlinked directories and non-regular
    /// database files are rejected here so a bad capture fails before the
    /// runtime is constructed.
    public static func capture(
        directoryPath: String,
        lockDirectoryPath: String,
        databaseName: String
    ) throws -> FloeMacSelfHostProvenance {
        guard !databaseName.isEmpty,
              databaseName != ".",
              databaseName != "..",
              !databaseName.contains("/"),
              !databaseName.contains("\0"),
              databaseName.utf8.count <= 200 else {
            throw FloeMacSelfCoreError.hostProvenanceUnavailable("invalid_database_name")
        }
        let directoryIdentity = try Self.captureDirectoryIdentity(
            directoryPath,
            failure: "unsafe_directory"
        )
        let lockDirectoryIdentity: FloeMacSelfFileIdentity
        if lockDirectoryPath == directoryPath {
            lockDirectoryIdentity = directoryIdentity
        } else {
            lockDirectoryIdentity = try Self.captureDirectoryIdentity(
                lockDirectoryPath,
                failure: "unsafe_lock_directory"
            )
        }
        let databasePath = directoryPath + "/" + databaseName
        var databaseInfo = stat()
        guard lstat(databasePath, &databaseInfo) == 0,
              (databaseInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw FloeMacSelfCoreError.hostProvenanceUnavailable("unsafe_database")
        }
        return FloeMacSelfHostProvenance(
            directoryPath: directoryPath,
            lockDirectoryPath: lockDirectoryPath,
            databaseName: databaseName,
            directoryIdentity: directoryIdentity,
            lockDirectoryIdentity: lockDirectoryIdentity,
            databaseIdentity: FloeMacSelfFileIdentity(databaseInfo)
        )
    }

    private static func captureDirectoryIdentity(
        _ path: String,
        failure: String
    ) throws -> FloeMacSelfFileIdentity {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0") else {
            throw FloeMacSelfCoreError.hostProvenanceUnavailable("invalid_path")
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw FloeMacSelfCoreError.hostProvenanceUnavailable(failure)
        }
        return FloeMacSelfFileIdentity(info)
    }
}
