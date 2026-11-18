// SPDX-License-Identifier: MPL-2.0
//
// Verified authority primitives for a host-selected private SQLite database.
//
// This is a candidate foundation, not an enabled production gate. The runtime
// gate in FloeMacSelfAuthorityLock.swift remains closed until the host supplies
// the trusted database-directory/lock-directory/database provenance this type
// requires and the start/stop/approval lifecycle races are resolved.
//
// What this file actually establishes when the caller supplies provenance:
//   * every intermediate path component is opened descriptor-relative with
//     O_NOFOLLOW; each final directory must be a real 0700 directory owned by
//     the effective user;
//   * the database must be the exact expected (device, inode), a 0600 regular
//     file with one link, owned by the effective user, reached with O_NOFOLLOW;
//   * the lock file lives in the host-stable lock directory and is named from
//     the *database identity*, not from a caller-provided basename. A database
//     alias in another parent directory, a case variant on a case-insensitive
//     volume, or a rename that keeps the inode still selects the same lock file
//     when the same lock directory is supplied. Symlinks and hard links are
//     rejected instead of silently selecting a second lock;
//   * an existing lock is never truncated and never chmod-ed. It is accepted
//     only when it is empty, already carries this exact database identity
//     header, or the host explicitly supplies its exact prior identity as
//     provenance. Foreign bytes and modes are left byte-for-byte untouched;
//   * the advisory flock is acquired non-blocking and every identity is
//     re-verified after acquisition and before durable work.
//
// Limits that remain true:
//   * a process that already has write access to the database or lock directory
//     is not stopped from replacing files between verifications;
//   * the host must use one stable lock directory per authority domain. Two
//     different lock directories are different provenance and are not
//     reconciled by this primitive;
//   * a noncooperating process that opens the SQLite file directly does not take
//     this flock. The durable admission table is the additional logical fence;
//   * POSIX mode/owner checks do not inspect extended ACLs. The host must
//     provide directories that are private under the actual ACL policy;
//   * the database content is deliberately not parsed here. SQLite/GRDB owns
//     content validation; this file binds the exact filesystem identity.

import Darwin
import Foundation

#if FLOE_AUTHORITY_TESTING
// Standalone synthetic tests only. These hooks are absent from production
// builds and must be used serially by the fixture runner.
enum FloeAuthorityPrimitiveTestHooks {
    nonisolated(unsafe) static var beforeLockOpen: (() -> Void)?
    nonisolated(unsafe) static var beforeFlock: (() -> Void)?
}
#endif

struct FloeAuthorityIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
    }

    init(device: dev_t, inode: ino_t) {
        self.device = device
        self.inode = inode
    }
}

enum FloeAuthorityPrimitiveError: Error, Equatable {
    case invalidPath
    case unsafeDirectory
    case unsafeLockDirectory
    case unsafeDatabase
    case untrustedExistingLock
    case unsafeLock
    case busy
    case unavailable
    case released
}

/// An authority lease over one exact database identity.
///
/// `trustedDirectoryPath`, `expectedDirectory` and `expectedDatabase` are
/// *trusted host provenance*, not model input and not an authorization API.
/// A caller that computes them from the same untrusted path immediately before
/// constructing this object has not established provenance.
final class FloeAuthorityPrimitive: @unchecked Sendable {
    private static let defaultDatabaseName = "floe.sqlite"
    private static let lockPrefix = ".floe-self-authority-v2-"
    private static let lockSuffix = ".lock"
    private static let headerMagic: [UInt8] = Array("FLOEAUTH".utf8)
    private static let headerIdentityLength = 32
    private static let headerLength = 64
    private static let headerVersion: UInt8 = 2

    private enum EntryKind {
        case database
        case lock
    }

    private enum LockHeaderState {
        /// A zero-length file, or a strict prefix of our identity header left by
        /// an interrupted first acquisition. It is safe to initialize after the
        /// flock proves no other cooperating owner is writing it.
        case uninitialized
        /// The first 32 bytes exactly match this database identity.
        case databaseBound
        /// The host supplied the exact prior identity of a foreign file. Its
        /// bytes are preserved and are never treated as our metadata.
        case adoptedForeign
    }

    private let trustedDirectoryPath: String
    private let canonicalDirectoryPath: String
    private let trustedLockDirectoryPath: String
    private let canonicalLockDirectoryPath: String
    private let databaseName: String
    private let directoryIdentity: FloeAuthorityIdentity
    private let lockDirectoryIdentity: FloeAuthorityIdentity
    private let databaseIdentity: FloeAuthorityIdentity
    let lockIdentity: FloeAuthorityIdentity
    let lockURL: URL

    private let mutex = NSLock()
    private var directoryFD: Int32
    private var lockDirectoryFD: Int32
    private var databaseFD: Int32
    private var lockFD: Int32
    private var released = false
    private let ownsMetadata: Bool

    /// Acquires the exclusive advisory lock. Throws `.busy` when another
    /// cooperating owner holds the same database identity, and an `unsafe*`
    /// error when any path, owner, mode, link count or identity is not exactly
    /// what the trusted provenance expects. No existing bytes or modes are
    /// changed on a rejection.
    ///
    /// `lockDirectoryPath` must be a host-stable private directory that does
    /// not move when the database file is renamed or moved. The lock file is
    /// keyed by the database's (device, inode) identity inside this directory,
    /// so a database alias in another directory still contends on the same
    /// lock. Passing the database's own parent as the lock directory is only
    /// safe while that parent itself is stable and not renamed.
    init(
        trustedDirectoryPath: String,
        lockDirectoryPath: String,
        databaseName: String = FloeAuthorityPrimitive.defaultDatabaseName,
        expectedDirectory: FloeAuthorityIdentity,
        expectedLockDirectory: FloeAuthorityIdentity,
        expectedDatabase: FloeAuthorityIdentity,
        expectedExistingLock: FloeAuthorityIdentity? = nil
    ) throws {
        try Self.validate(databaseName: databaseName)
        let canonicalPath = try Self.canonicalDirectoryPath(trustedDirectoryPath)
        let canonicalLockPath: String
        do {
            canonicalLockPath = try Self.canonicalDirectoryPath(lockDirectoryPath)
        } catch FloeAuthorityPrimitiveError.unsafeDirectory {
            throw FloeAuthorityPrimitiveError.unsafeLockDirectory
        }

        let directoryFD = try Self.openDirectoryWithoutSymlinks(canonicalPath)
        var ownsDirectory = true
        defer { if ownsDirectory { Darwin.close(directoryFD) } }

        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              Self.isPrivateDirectory(directoryInfo),
              FloeAuthorityIdentity(directoryInfo) == expectedDirectory else {
            throw FloeAuthorityPrimitiveError.unsafeDirectory
        }
        // The caller may pass a platform alias such as /tmp for an intermediate
        // component, but the named directory itself must be a real directory,
        // not a symlink to one.
        var namedDirectoryInfo = stat()
        guard lstat(trustedDirectoryPath, &namedDirectoryInfo) == 0,
              (namedDirectoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              FloeAuthorityIdentity(namedDirectoryInfo) == expectedDirectory else {
            throw FloeAuthorityPrimitiveError.unsafeDirectory
        }
        try Self.verifyCanonicalDirectory(canonicalPath, expected: expectedDirectory)

        let lockDirectoryFD: Int32
        do {
            lockDirectoryFD = try Self.openDirectoryWithoutSymlinks(canonicalLockPath)
        } catch FloeAuthorityPrimitiveError.unsafeDirectory {
            throw FloeAuthorityPrimitiveError.unsafeLockDirectory
        }
        var ownsLockDirectory = true
        defer { if ownsLockDirectory { Darwin.close(lockDirectoryFD) } }

        var lockDirectoryInfo = stat()
        guard fstat(lockDirectoryFD, &lockDirectoryInfo) == 0,
              Self.isPrivateDirectory(lockDirectoryInfo),
              FloeAuthorityIdentity(lockDirectoryInfo) == expectedLockDirectory else {
            throw FloeAuthorityPrimitiveError.unsafeLockDirectory
        }
        var namedLockDirectoryInfo = stat()
        guard lstat(lockDirectoryPath, &namedLockDirectoryInfo) == 0,
              (namedLockDirectoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              FloeAuthorityIdentity(namedLockDirectoryInfo) == expectedLockDirectory else {
            throw FloeAuthorityPrimitiveError.unsafeLockDirectory
        }
        try Self.verifyCanonicalDirectory(
            canonicalLockPath,
            expected: expectedLockDirectory,
            failure: .unsafeLockDirectory
        )

        let databaseFD = openat(
            directoryFD,
            databaseName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard databaseFD >= 0 else {
            throw FloeAuthorityPrimitiveError.unsafeDatabase
        }
        var ownsDatabase = true
        defer { if ownsDatabase { Darwin.close(databaseFD) } }

        var databaseInfo = stat()
        guard fstat(databaseFD, &databaseInfo) == 0,
              Self.isPrivateRegular(databaseInfo),
              FloeAuthorityIdentity(databaseInfo) == expectedDatabase else {
            throw FloeAuthorityPrimitiveError.unsafeDatabase
        }
        try Self.verifyEntry(
            directoryFD: directoryFD,
            name: databaseName,
            expected: expectedDatabase,
            kind: .database
        )

        let lockName = Self.lockFileName(for: expectedDatabase)
        // A database named exactly like its own lock would make the lock open
        // target the database inode. Refuse before any lock open can happen.
        guard lockName != databaseName else {
            throw FloeAuthorityPrimitiveError.unsafeLock
        }
        let createdLock: Bool
        let lockFD: Int32
#if FLOE_AUTHORITY_TESTING
        FloeAuthorityPrimitiveTestHooks.beforeLockOpen?()
#endif
        if expectedExistingLock != nil {
            // Provenance requires this exact prior inode. Never use O_CREAT in
            // this branch: an existence check followed by creation races a
            // concurrent unlink and can silently replace the expected lock.
            lockFD = openat(lockDirectoryFD, lockName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard lockFD >= 0 else {
                throw FloeAuthorityPrimitiveError.untrustedExistingLock
            }
            createdLock = false
        } else {
            let exclusiveFD = openat(
                lockDirectoryFD,
                lockName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                mode_t(S_IRUSR | S_IWUSR)
            )
            if exclusiveFD >= 0 {
                lockFD = exclusiveFD
                createdLock = true
            } else {
                let createError = errno
                if createError == EEXIST {
                    lockFD = openat(
                        lockDirectoryFD,
                        lockName,
                        O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                    )
                    guard lockFD >= 0 else {
                        let openError = errno
                        if openError == ELOOP || openError == EISDIR || openError == ENOTDIR {
                            throw FloeAuthorityPrimitiveError.unsafeLock
                        }
                        throw FloeAuthorityPrimitiveError.unavailable
                    }
                    createdLock = false
                } else if createError == ELOOP || createError == EISDIR || createError == ENOTDIR {
                    throw FloeAuthorityPrimitiveError.unsafeLock
                } else {
                    throw FloeAuthorityPrimitiveError.unavailable
                }
            }
        }
        var ownsLock = true
        defer { if ownsLock { Darwin.close(lockFD) } }

        if createdLock {
            // This inode was created by this call, so tightening its mode
            // cannot alter a pre-existing file.
            guard fchmod(lockFD, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw FloeAuthorityPrimitiveError.unsafeLock
            }
        }

        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0,
              Self.isPrivateRegular(lockInfo),
              FloeAuthorityIdentity(lockInfo) != expectedDatabase else {
            throw FloeAuthorityPrimitiveError.unsafeLock
        }
        let lockIdentity = FloeAuthorityIdentity(lockInfo)
        try Self.verifyEntry(
            directoryFD: lockDirectoryFD,
            name: lockName,
            expected: lockIdentity,
            kind: .lock
        )

#if FLOE_AUTHORITY_TESTING
        FloeAuthorityPrimitiveTestHooks.beforeFlock?()
#endif
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw FloeAuthorityPrimitiveError.busy
            }
            throw FloeAuthorityPrimitiveError.unavailable
        }

        let writesMetadata: Bool
        do {
            try Self.verifyHeldState(
                directoryFD: directoryFD,
                trustedDirectoryPath: trustedDirectoryPath,
                canonicalDirectoryPath: canonicalPath,
                directoryIdentity: expectedDirectory,
                lockDirectoryFD: lockDirectoryFD,
                trustedLockDirectoryPath: lockDirectoryPath,
                canonicalLockDirectoryPath: canonicalLockPath,
                lockDirectoryIdentity: expectedLockDirectory,
                databaseName: databaseName,
                databaseFD: databaseFD,
                databaseIdentity: expectedDatabase,
                lockName: lockName,
                lockFD: lockFD,
                lockIdentity: lockIdentity
            )
            // Classify the bytes only after acquiring the lock. Even a newly
            // created inode can have been modified before flock; foreign bytes
            // must not be overwritten based on an earlier observation.
            let headerState = try Self.classifyExistingLock(
                descriptor: lockFD,
                databaseIdentity: expectedDatabase,
                expectedExistingLock: expectedExistingLock,
                actualLockIdentity: lockIdentity
            )
            writesMetadata = headerState != .adoptedForeign
            if writesMetadata {
                try Self.writeHeader(
                    descriptor: lockFD,
                    databaseIdentity: expectedDatabase
                )
            }
            try Self.verifyLockHeader(
                descriptor: lockFD,
                databaseIdentity: expectedDatabase,
                required: writesMetadata
            )
            // Re-verify after the metadata write so a concurrent replacement
            // cannot be mistaken for a successful acquisition.
            try Self.verifyHeldState(
                directoryFD: directoryFD,
                trustedDirectoryPath: trustedDirectoryPath,
                canonicalDirectoryPath: canonicalPath,
                directoryIdentity: expectedDirectory,
                lockDirectoryFD: lockDirectoryFD,
                trustedLockDirectoryPath: lockDirectoryPath,
                canonicalLockDirectoryPath: canonicalLockPath,
                lockDirectoryIdentity: expectedLockDirectory,
                databaseName: databaseName,
                databaseFD: databaseFD,
                databaseIdentity: expectedDatabase,
                lockName: lockName,
                lockFD: lockFD,
                lockIdentity: lockIdentity
            )
        } catch {
            _ = flock(lockFD, LOCK_UN)
            throw error
        }

        self.trustedDirectoryPath = trustedDirectoryPath
        self.canonicalDirectoryPath = canonicalPath
        self.trustedLockDirectoryPath = lockDirectoryPath
        self.canonicalLockDirectoryPath = canonicalLockPath
        self.databaseName = databaseName
        self.directoryIdentity = expectedDirectory
        self.lockDirectoryIdentity = expectedLockDirectory
        self.databaseIdentity = expectedDatabase
        self.lockIdentity = lockIdentity
        self.lockURL = URL(fileURLWithPath: canonicalLockPath, isDirectory: true)
            .appendingPathComponent(lockName, isDirectory: false)
        self.directoryFD = directoryFD
        self.lockDirectoryFD = lockDirectoryFD
        self.databaseFD = databaseFD
        self.lockFD = lockFD
        self.ownsMetadata = writesMetadata
        ownsDirectory = false
        ownsLockDirectory = false
        ownsDatabase = false
        ownsLock = false
    }

    deinit {
        release()
    }

    /// Re-verifies that the pinned descriptors still name the exact directory,
    /// database and lock inode this lease acquired, that the paths still resolve
    /// to them, and that the lock metadata is still ours. Call before durable
    /// admission/settlement writes and before releasing the database.
    func verifyHeld() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard !released, directoryFD >= 0, lockDirectoryFD >= 0, databaseFD >= 0, lockFD >= 0 else {
            throw FloeAuthorityPrimitiveError.released
        }
        guard fcntl(directoryFD, F_GETFD) != -1,
              fcntl(lockDirectoryFD, F_GETFD) != -1,
              fcntl(databaseFD, F_GETFD) != -1,
              fcntl(lockFD, F_GETFD) != -1 else {
            throw FloeAuthorityPrimitiveError.released
        }
        let lockName = Self.lockFileName(for: databaseIdentity)
        try Self.verifyHeldState(
            directoryFD: directoryFD,
            trustedDirectoryPath: trustedDirectoryPath,
            canonicalDirectoryPath: canonicalDirectoryPath,
            directoryIdentity: directoryIdentity,
            lockDirectoryFD: lockDirectoryFD,
            trustedLockDirectoryPath: trustedLockDirectoryPath,
            canonicalLockDirectoryPath: canonicalLockDirectoryPath,
            lockDirectoryIdentity: lockDirectoryIdentity,
            databaseName: databaseName,
            databaseFD: databaseFD,
            databaseIdentity: databaseIdentity,
            lockName: lockName,
            lockFD: lockFD,
            lockIdentity: lockIdentity
        )
        try Self.verifyLockHeader(
            descriptor: lockFD,
            databaseIdentity: databaseIdentity,
            required: ownsMetadata
        )
    }

    /// Releases the advisory lock and closes the pinned descriptors. The lock
    /// file is deliberately left in place: deleting it would let a racing
    /// owner lock a withdrawn inode.
    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard !released else { return }
        released = true
        if lockFD >= 0 {
            _ = flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
            lockFD = -1
        }
        if lockDirectoryFD >= 0 {
            Darwin.close(lockDirectoryFD)
            lockDirectoryFD = -1
        }
        if databaseFD >= 0 {
            Darwin.close(databaseFD)
            databaseFD = -1
        }
        if directoryFD >= 0 {
            Darwin.close(directoryFD)
            directoryFD = -1
        }
    }

    static func lockFileName(for identity: FloeAuthorityIdentity) -> String {
        let device = UInt64(bitPattern: Int64(identity.device))
        let inode = UInt64(identity.inode)
        return String(
            format: "%@%016llx-%016llx%@",
            lockPrefix,
            device,
            inode,
            lockSuffix
        )
    }

    // MARK: - Path and identity verification

    private static func validate(databaseName: String) throws {
        guard !databaseName.isEmpty,
              databaseName != ".",
              databaseName != "..",
              !databaseName.contains("/"),
              !databaseName.contains("\0"),
              databaseName.utf8.count <= 200 else {
            throw FloeAuthorityPrimitiveError.invalidPath
        }
    }

    private static func canonicalDirectoryPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0") else {
            throw FloeAuthorityPrimitiveError.invalidPath
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "",
              parts.count > 1,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FloeAuthorityPrimitiveError.invalidPath
        }
        var named = stat()
        guard lstat(path, &named) == 0,
              (named.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw FloeAuthorityPrimitiveError.unsafeDirectory
        }
        guard let resolved = realpath(path, nil) else {
            throw FloeAuthorityPrimitiveError.unsafeDirectory
        }
        defer { Darwin.free(resolved) }
        let canonical = String(cString: resolved)
        guard canonical.hasPrefix("/"), canonical != "/" else {
            throw FloeAuthorityPrimitiveError.invalidPath
        }
        return canonical
    }

    private static func openDirectoryWithoutSymlinks(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0") else {
            throw FloeAuthorityPrimitiveError.invalidPath
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "",
              parts.count > 1,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FloeAuthorityPrimitiveError.invalidPath
        }
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw FloeAuthorityPrimitiveError.unavailable
        }
        for part in parts.dropFirst() {
            let next = openat(
                descriptor,
                String(part),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            let openError = errno
            Darwin.close(descriptor)
            guard next >= 0 else {
                if openError == ENOMEM || openError == EMFILE || openError == ENFILE {
                    throw FloeAuthorityPrimitiveError.unavailable
                }
                throw FloeAuthorityPrimitiveError.unsafeDirectory
            }
            descriptor = next
        }
        return descriptor
    }

    private static func verifyCanonicalDirectory(
        _ canonicalPath: String,
        expected: FloeAuthorityIdentity,
        failure: FloeAuthorityPrimitiveError = .unsafeDirectory
    ) throws {
        let descriptor = try openDirectoryWithoutSymlinks(canonicalPath)
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              isPrivateDirectory(value),
              FloeAuthorityIdentity(value) == expected else {
            throw failure
        }
    }

    private static func verifyHeldState(
        directoryFD: Int32,
        trustedDirectoryPath: String,
        canonicalDirectoryPath: String,
        directoryIdentity: FloeAuthorityIdentity,
        lockDirectoryFD: Int32,
        trustedLockDirectoryPath: String,
        canonicalLockDirectoryPath: String,
        lockDirectoryIdentity: FloeAuthorityIdentity,
        databaseName: String,
        databaseFD: Int32,
        databaseIdentity: FloeAuthorityIdentity,
        lockName: String,
        lockFD: Int32,
        lockIdentity: FloeAuthorityIdentity
    ) throws {
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              isPrivateDirectory(directoryInfo),
              FloeAuthorityIdentity(directoryInfo) == directoryIdentity else {
            throw FloeAuthorityPrimitiveError.unsafeDirectory
        }
        // Re-resolve the original path and require both the same canonical
        // string and the same inode. A retargeted intermediate symlink or a
        // renamed/recreated directory fails here.
        let resolved = try Self.canonicalDirectoryPath(trustedDirectoryPath)
        guard resolved == canonicalDirectoryPath else {
            throw FloeAuthorityPrimitiveError.unsafeDirectory
        }
        try verifyCanonicalDirectory(resolved, expected: directoryIdentity)
        var namedDirectoryInfo = stat()
        guard lstat(trustedDirectoryPath, &namedDirectoryInfo) == 0,
              (namedDirectoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              FloeAuthorityIdentity(namedDirectoryInfo) == directoryIdentity else {
            throw FloeAuthorityPrimitiveError.unsafeDirectory
        }

        var lockDirectoryInfo = stat()
        guard fstat(lockDirectoryFD, &lockDirectoryInfo) == 0,
              isPrivateDirectory(lockDirectoryInfo),
              FloeAuthorityIdentity(lockDirectoryInfo) == lockDirectoryIdentity else {
            throw FloeAuthorityPrimitiveError.unsafeLockDirectory
        }
        let resolvedLock = try Self.canonicalDirectoryPath(trustedLockDirectoryPath)
        guard resolvedLock == canonicalLockDirectoryPath else {
            throw FloeAuthorityPrimitiveError.unsafeLockDirectory
        }
        try verifyCanonicalDirectory(
            resolvedLock,
            expected: lockDirectoryIdentity,
            failure: .unsafeLockDirectory
        )
        var namedLockDirectoryInfo = stat()
        guard lstat(trustedLockDirectoryPath, &namedLockDirectoryInfo) == 0,
              (namedLockDirectoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              FloeAuthorityIdentity(namedLockDirectoryInfo) == lockDirectoryIdentity else {
            throw FloeAuthorityPrimitiveError.unsafeLockDirectory
        }

        try verifyEntry(
            directoryFD: directoryFD,
            name: databaseName,
            expected: databaseIdentity,
            kind: .database
        )
        var databaseInfo = stat()
        guard fstat(databaseFD, &databaseInfo) == 0,
              isPrivateRegular(databaseInfo),
              FloeAuthorityIdentity(databaseInfo) == databaseIdentity else {
            throw FloeAuthorityPrimitiveError.unsafeDatabase
        }

        try verifyEntry(
            directoryFD: lockDirectoryFD,
            name: lockName,
            expected: lockIdentity,
            kind: .lock
        )
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0,
              isPrivateRegular(lockInfo),
              FloeAuthorityIdentity(lockInfo) == lockIdentity else {
            throw FloeAuthorityPrimitiveError.unsafeLock
        }
    }

    private static func verifyEntry(
        directoryFD: Int32,
        name: String,
        expected: FloeAuthorityIdentity,
        kind: EntryKind
    ) throws {
        var value = stat()
        let result = name.withCString { pointer in
            fstatat(directoryFD, pointer, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              isPrivateRegular(value),
              FloeAuthorityIdentity(value) == expected else {
            throw kind == .database
                ? FloeAuthorityPrimitiveError.unsafeDatabase
                : FloeAuthorityPrimitiveError.unsafeLock
        }
    }

    private static func isPrivateDirectory(_ value: stat) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && value.st_uid == geteuid()
            && (value.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func isPrivateRegular(_ value: stat) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && value.st_uid == geteuid()
            && (value.st_mode & mode_t(0o7777)) == mode_t(0o600)
            && value.st_nlink == 1
    }

    // MARK: - Lock metadata

    private static func classifyExistingLock(
        descriptor: Int32,
        databaseIdentity: FloeAuthorityIdentity,
        expectedExistingLock: FloeAuthorityIdentity?,
        actualLockIdentity: FloeAuthorityIdentity
    ) throws -> LockHeaderState {
        // If the host supplied prior provenance, it must name this exact
        // inode. A copied or replaced lock file is never adopted just because
        // its contents happen to look like a valid header.
        if let expectedExistingLock, expectedExistingLock != actualLockIdentity {
            throw FloeAuthorityPrimitiveError.untrustedExistingLock
        }
        let prefix = try readPrefix(descriptor: descriptor, maximum: headerLength)
        if prefix.isEmpty {
            return .uninitialized
        }
        let identityHeader = headerIdentityBytes(for: databaseIdentity)
        if prefix.count < headerIdentityLength {
            // Only an empty file or a prefix that at least carries the full
            // magic is treated as our interrupted initialization. A short
            // foreign file (for example a one-byte "F") must be preserved.
            if prefix.count >= headerMagic.count,
               Data(prefix.prefix(headerMagic.count)) == Data(headerMagic),
               Data(prefix) == Data(identityHeader.prefix(prefix.count)) {
                return .uninitialized
            }
        } else {
            if Data(prefix.prefix(headerIdentityLength)) == Data(identityHeader) {
                return .databaseBound
            }
            if prefix.count >= headerMagic.count,
               Data(prefix.prefix(headerMagic.count)) == Data(headerMagic) {
                // A lock header for a different database identity. Never adopt
                // it as metadata: that would hide a copied or confused lock.
                throw FloeAuthorityPrimitiveError.unsafeLock
            }
        }
        if expectedExistingLock != nil {
            return .adoptedForeign
        }
        throw FloeAuthorityPrimitiveError.untrustedExistingLock
    }

    private static func verifyLockHeader(
        descriptor: Int32,
        databaseIdentity: FloeAuthorityIdentity,
        required: Bool
    ) throws {
        guard required else { return }
        let prefix = try readPrefix(descriptor: descriptor, maximum: headerIdentityLength)
        guard prefix.count == headerIdentityLength,
              Data(prefix) == Data(headerIdentityBytes(for: databaseIdentity)) else {
            throw FloeAuthorityPrimitiveError.unsafeLock
        }
    }

    private static func readPrefix(descriptor: Int32, maximum: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximum)
        var total = 0
        while total < maximum {
            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return pread(
                    descriptor,
                    UnsafeMutableRawPointer(base).advanced(by: total),
                    maximum - total,
                    off_t(total)
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw FloeAuthorityPrimitiveError.unavailable
            }
            if count == 0 { break }
            total += count
        }
        return Data(buffer.prefix(total))
    }

    private static func writeHeader(
        descriptor: Int32,
        databaseIdentity: FloeAuthorityIdentity
    ) throws {
        var identityBytes = headerIdentityBytes(for: databaseIdentity)
        var metadata = [UInt8]()
        appendUInt64(UInt64(getpid()), to: &metadata)
        let now = Date().timeIntervalSince1970
        let nanoseconds = now > 0 ? UInt64(now * 1_000_000_000) : 0
        appendUInt64(nanoseconds, to: &metadata)
        // Reserved diagnostic space. No display name, goal, path or credential
        // is written into the lock file.
        appendUInt64(0, to: &metadata)
        appendUInt64(0, to: &metadata)
        precondition(metadata.count == headerLength - headerIdentityLength)
        identityBytes.append(contentsOf: metadata)

        var written = 0
        while written < identityBytes.count {
            let count = identityBytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pwrite(
                    descriptor,
                    base.advanced(by: written),
                    identityBytes.count - written,
                    off_t(written)
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw FloeAuthorityPrimitiveError.unsafeLock
            }
            if count == 0 {
                throw FloeAuthorityPrimitiveError.unsafeLock
            }
            written += count
        }
    }

    private static func headerIdentityBytes(for identity: FloeAuthorityIdentity) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.append(contentsOf: headerMagic)
        bytes.append(headerVersion)
        bytes.append(0) // flags
        appendUInt16(UInt16(headerLength), to: &bytes) // total header length
        appendUInt16(0, to: &bytes) // reserved
        appendUInt16(0, to: &bytes) // reserved
        appendUInt64(UInt64(bitPattern: Int64(identity.device)), to: &bytes)
        appendUInt64(UInt64(identity.inode), to: &bytes)
        precondition(bytes.count == headerIdentityLength)
        return bytes
    }

    private static func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private static func appendUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
        var shift = 56
        while shift >= 0 {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xff))
            shift -= 8
        }
    }
}
