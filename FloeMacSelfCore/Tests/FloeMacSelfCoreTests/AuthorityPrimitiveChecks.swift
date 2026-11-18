// SPDX-License-Identifier: MPL-2.0
//
// Synthetic-only authority checks. They exercise the verified
// FloeAuthorityPrimitive against unique 0700 temporary roots. No user database,
// Keychain item, workspace or simulator is touched.
//
// The same file is used in two ways:
//   * from the Swift Testing suite, which calls `run(selfExecutable: nil)`;
//   * as the body of a standalone Swift 6 executable compiled with the
//     primitive source, which passes its own executable so the child-process
//     checks exercise this implementation in a second process.
//
// A failing check retains its unique container and prints the path. A passing
// check removes only the container this file created.

import Darwin
import Foundation

#if canImport(FloeMacSelfCore)
@testable import FloeMacSelfCore
#endif

enum AuthorityPrimitiveCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

struct AuthorityFileSnapshot: Equatable {
    let mode: mode_t
    let device: dev_t
    let inode: ino_t
    let linkCount: UInt64
    let size: Int64
    let bytes: Data?
    let linkTarget: String?
}

enum AuthorityPrimitiveChecks {
    private static let databaseName = "floe.sqlite"
    private static let sqliteHeader: [UInt8] = Array("SQLite format 3\0".utf8)

    // MARK: - Child modes for the standalone executable

    /// Returns true when a hidden child mode handled the arguments. The caller
    /// (the standalone main) exits after this returns true.
    static func runChildMode(arguments: [String]) throws -> Bool {
        guard arguments.count >= 4 else { return false }
        let operation = arguments[1]
        let rootPath = arguments[2]
        let name = arguments[3]
        switch operation {
        case "--authority-hold":
            try hold(rootPath: rootPath, databaseName: name)
            return true
        case "--authority-probe-busy":
            try probeBusy(rootPath: rootPath, databaseName: name)
            return true
        default:
            return false
        }
    }

    private static func hold(rootPath: String, databaseName: String) throws {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let databaseURL = root.appendingPathComponent(databaseName, isDirectory: false)
        let primitive = try FloeAuthorityPrimitive(
            trustedDirectoryPath: root.path,
            lockDirectoryPath: root.path,
            databaseName: databaseName,
            expectedDirectory: identity(of: root),
            expectedLockDirectory: identity(of: root),
            expectedDatabase: identity(of: databaseURL)
        )
        FileHandle.standardOutput.write(Data("HELD\n".utf8))
        sleep(60)
        primitive.release()
        exit(0)
    }

    private static func probeBusy(rootPath: String, databaseName: String) throws {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let databaseURL = root.appendingPathComponent(databaseName, isDirectory: false)
        do {
            let primitive = try FloeAuthorityPrimitive(
                trustedDirectoryPath: root.path,
                lockDirectoryPath: root.path,
                databaseName: databaseName,
                expectedDirectory: identity(of: root),
                expectedLockDirectory: identity(of: root),
                expectedDatabase: identity(of: databaseURL)
            )
            primitive.release()
            FileHandle.standardOutput.write(Data("ACQUIRED\n".utf8))
            exit(9)
        } catch FloeAuthorityPrimitiveError.busy {
            FileHandle.standardOutput.write(Data("CHILD_BUSY\n".utf8))
            exit(0)
        }
    }

    // MARK: - Entry point

    static func run(selfExecutable: URL?) throws {
        var failures: [String] = []

        func check(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                print("PASS \(name)")
            } catch {
                let message = "\(name): \(error)"
                failures.append(message)
                print("FAIL \(message)")
            }
        }

        check("acquire, verify, release and reacquire") { try checkAcquireRelease() }
        check("same database identity is exclusive in one process") { try checkSameDatabaseBusy() }
        check("different database identities in one directory are independent") { try checkDifferentDatabases() }
        check("intermediate directory symlink alias selects the same lock") { try checkIntermediateSymlinkAlias() }
        check("case-variant database name selects the same lock") { try checkCaseAlias() }
        check("rename that keeps the inode selects the same lock") { try checkRenameAlias() }
        check("cross-directory rename selects the same fixed lock root") { try checkCrossDirectoryRenameAlias() }
        check("database symlink, hard link, mode, directory and FIFO are rejected") { try checkUnsafeDatabaseInputs() }
        check("lock symlink, hard link and widened mode are rejected untouched") { try checkUnsafeLockInputs() }
        check("unsafe lock directory paths and modes are rejected") { try checkUnsafeLockDirectoryInputs() }
        check("foreign lock bytes are rejected and never rewritten") { try checkForeignLockPreserved() }
        check("short foreign lock bytes are preserved") { try checkShortForeignLockPreserved() }
        check("explicit prior lock identity adopts without changing bytes") { try checkForeignLockAdoption() }
#if FLOE_AUTHORITY_TESTING
        check("expected prior lock removed before open is not recreated") { try checkPriorLockRemovedBeforeOpen() }
        check("expected prior lock replaced before open is not adopted") { try checkPriorLockReplacedBeforeOpen() }
        check("foreign bytes written before flock are not overwritten") { try checkForeignBytesBeforeFlock() }
#endif
        check("lock header for another database is rejected") { try checkConfusedHeader() }
        check("interrupted lock header is recovered") { try checkInterruptedHeader() }
        check("lock truncation after acquisition fails closed") { try checkLockTruncationDetected() }
        check("database path replacement fails closed") { try checkDatabaseReplacement() }
        check("lock path replacement fails closed") { try checkLockReplacement() }
        check("directory path replacement fails closed") { try checkDirectoryReplacement() }
        check("intermediate symlink retarget fails closed") { try checkSymlinkRetarget() }
        check("widened modes and new hard links fail closed") { try checkWidenedModes() }
        check("invalid names and paths are rejected before any open") { try checkInvalidInputs() }
        check("another process cannot take a held lock") { try checkExternalProcessSeesBusy() }
        check("abnormal external exit releases the lock") { try checkExternalProcessKillRecovery() }
        if let selfExecutable {
            check("our own second process cannot take a held lock") {
                try checkSelfProcessExclusion(executable: selfExecutable)
            }
            check("abnormal self-process exit releases the lock") {
                try checkSelfProcessKillRecovery(executable: selfExecutable)
            }
        } else {
            print("SKIP self-process checks (no standalone executable supplied)")
        }

        guard failures.isEmpty else {
            throw AuthorityPrimitiveCheckFailure.failed(
                "\(failures.count) authority check(s) failed: " + failures.joined(separator: " | ")
            )
        }
        print("ALL AUTHORITY PRIMITIVE CHECKS PASSED")
    }

    // MARK: - Core checks

    private static func checkAcquireRelease() throws {
        try withContainer("acquire") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let databaseIdentity = try identity(of: databaseURL)

            let primitive = try acquire(root: root)
            try primitive.verifyHeld()
            try expect(
                primitive.lockURL.lastPathComponent
                    == FloeAuthorityPrimitive.lockFileName(for: databaseIdentity),
                "lock name is not derived from the database identity"
            )
            try expect(try fileMode(primitive.lockURL) == 0o600, "lock mode is not 0600")
            try expect(try linkCount(primitive.lockURL) == 1, "lock has more than one link")
            try expect(
                primitive.lockIdentity == (try identity(of: primitive.lockURL)),
                "reported lock identity differs from the path"
            )
            let header = try Data(contentsOf: primitive.lockURL)
            try expect(header.count >= 32, "lock header is too short")
            try expect(
                Data(header.prefix(8)) == Data("FLOEAUTH".utf8),
                "lock header magic is missing"
            )
            try expect(
                try fileMode(databaseURL) == 0o600,
                "database mode changed"
            )

            primitive.release()
            primitive.release()
            try expectError(.released) { try primitive.verifyHeld() }
            try expect(
                FileManager.default.fileExists(atPath: primitive.lockURL.path),
                "release deleted the lock file"
            )

            let reopened = try acquire(root: root)
            try reopened.verifyHeld()
            reopened.release()
        }
    }

    private static func checkSameDatabaseBusy() throws {
        try withContainer("same-db") { container in
            let root = try makeRoot(in: container)
            _ = try makeDatabase(at: root.appendingPathComponent(databaseName))
            let first = try acquire(root: root)
            try expectError(.busy) { _ = try acquire(root: root) }
            try first.verifyHeld()
            first.release()
            let second = try acquire(root: root)
            second.release()
        }
    }

    private static func checkDifferentDatabases() throws {
        try withContainer("different-db") { container in
            let root = try makeRoot(in: container)
            _ = try makeDatabase(at: root.appendingPathComponent("a.sqlite"))
            _ = try makeDatabase(at: root.appendingPathComponent("b.sqlite"))
            let first = try acquire(root: root, databaseName: "a.sqlite")
            let second = try acquire(root: root, databaseName: "b.sqlite")
            try first.verifyHeld()
            try second.verifyHeld()
            first.release()
            second.release()
        }
    }

    private static func checkIntermediateSymlinkAlias() throws {
        try withContainer("alias") { container in
            let real = container.appendingPathComponent("real", isDirectory: true)
            try makePrivateDirectory(real)
            let root = try makeRoot(in: real)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let alias = container.appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                atPath: alias.path,
                withDestinationPath: "real"
            )
            let aliasedRoot = alias.appendingPathComponent("root", isDirectory: true)

            let first = try acquire(root: root)
            try expectError(.busy) {
                _ = try FloeAuthorityPrimitive(
                    trustedDirectoryPath: aliasedRoot.path,
                    lockDirectoryPath: root.path,
                    databaseName: databaseName,
                    expectedDirectory: try identity(of: root),
                    expectedLockDirectory: try identity(of: root),
                    expectedDatabase: try identity(of: databaseURL)
                )
            }
            try first.verifyHeld()
            first.release()
        }
    }

    private static func checkCaseAlias() throws {
        try withContainer("case-alias") { container in
            let root = try makeRoot(in: container)
            let lower = root.appendingPathComponent("floe.sqlite")
            _ = try makeDatabase(at: lower)
            let upper = root.appendingPathComponent("FLOE.SQLITE")
            var upperInfo = stat()
            guard lstat(upper.path, &upperInfo) == 0,
                  FloeAuthorityIdentity(upperInfo) == (try identity(of: lower)) else {
                print("SKIP case-variant check: this volume is case-sensitive")
                return
            }
            let first = try acquire(root: root)
            try expectError(.busy) {
                _ = try acquire(root: root, databaseName: "FLOE.SQLITE")
            }
            try first.verifyHeld()
            first.release()
        }
    }

    private static func checkRenameAlias() throws {
        try withContainer("rename-alias") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let renamedURL = root.appendingPathComponent("renamed.sqlite")
            let first = try acquire(root: root)
            try FileManager.default.moveItem(at: databaseURL, to: renamedURL)
            try expectError(.busy) {
                _ = try acquire(root: root, databaseName: "renamed.sqlite")
            }
            try expectError(.unsafeDatabase) { try first.verifyHeld() }
            first.release()
        }
    }

    private static func checkCrossDirectoryRenameAlias() throws {
        try withContainer("cross-dir-alias") { container in
            let rootA = try makeRoot(in: container, name: "a")
            let rootB = try makeRoot(in: container, name: "b")
            let lockRoot = try makeRoot(in: container, name: "locks")
            let databaseURL = rootA.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let databaseIdentity = try identity(of: databaseURL)
            let movedURL = rootB.appendingPathComponent(databaseName)

            let first = try acquire(root: rootA, lockRoot: lockRoot)
            try FileManager.default.moveItem(at: databaseURL, to: movedURL)
            // The same inode now has a different parent directory. A lock
            // beside the old path would be a different file; the fixed lock
            // root keyed by the database identity must remain exclusive.
            try expectError(.busy) {
                _ = try acquire(root: rootB, lockRoot: lockRoot)
            }
            try expectError(.unsafeDatabase) { try first.verifyHeld() }
            first.release()

            try expect(
                try identity(of: movedURL) == databaseIdentity,
                "cross-directory move changed the database identity"
            )
            let second = try acquire(root: rootB, lockRoot: lockRoot)
            try second.verifyHeld()
            second.release()
        }
    }

    private static func checkUnsafeDatabaseInputs() throws {
        try withContainer("unsafe-db") { container in
            let root = try makeRoot(in: container)
            let target = root.appendingPathComponent("target.sqlite")
            _ = try makeDatabase(at: target)
            let databaseURL = root.appendingPathComponent(databaseName)
            try FileManager.default.createSymbolicLink(
                atPath: databaseURL.path,
                withDestinationPath: target.path
            )
            try expectError(.unsafeDatabase) { _ = try acquire(root: root) }
            try FileManager.default.removeItem(at: databaseURL)

            _ = try makeDatabase(at: databaseURL)
            let hardLink = root.appendingPathComponent("hard.sqlite")
            try expect(Darwin.link(databaseURL.path, hardLink.path) == 0, "create hard link")
            try expectError(.unsafeDatabase) { _ = try acquire(root: root) }
            try FileManager.default.removeItem(at: hardLink)

            try expect(Darwin.chmod(databaseURL.path, 0o644) == 0, "widen database mode")
            try expectError(.unsafeDatabase) { _ = try acquire(root: root) }
            try expect(Darwin.chmod(databaseURL.path, 0o600) == 0, "restore database mode")

            let fifoURL = root.appendingPathComponent("fifo.sqlite")
            try expect(Darwin.mkfifo(fifoURL.path, 0o600) == 0, "create fifo")
            try expectError(.unsafeDatabase) {
                _ = try acquire(root: root, databaseName: "fifo.sqlite")
            }
            try FileManager.default.removeItem(at: fifoURL)

            let directoryURL = root.appendingPathComponent("dir.sqlite", isDirectory: true)
            try makePrivateDirectory(directoryURL)
            try expectError(.unsafeDatabase) {
                _ = try acquire(root: root, databaseName: "dir.sqlite")
            }

            let recovered = try acquire(root: root)
            try recovered.verifyHeld()
            recovered.release()
        }
    }

    private static func checkUnsafeLockInputs() throws {
        try withContainer("unsafe-lock") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let databaseIdentity = try identity(of: databaseURL)
            let lockURL = root.appendingPathComponent(
                FloeAuthorityPrimitive.lockFileName(for: databaseIdentity)
            )

            let elsewhere = container.appendingPathComponent("elsewhere")
            try FileManager.default.createSymbolicLink(
                atPath: lockURL.path,
                withDestinationPath: elsewhere.path
            )
            try expectError(.unsafeLock) { _ = try acquire(root: root) }
            try expect(
                FileManager.default.destinationOfSymbolicLink(atPath: lockURL.path) == elsewhere.path,
                "lock symlink was changed"
            )
            try FileManager.default.removeItem(at: lockURL)

            try writeFile(at: lockURL, bytes: Data("foreign-lock".utf8), mode: 0o600)
            let hardLink = container.appendingPathComponent("lock-hardlink")
            try expect(Darwin.link(lockURL.path, hardLink.path) == 0, "create lock hard link")
            let beforeHardLink = try snapshot(root)
            try expectError(.unsafeLock) { _ = try acquire(root: root) }
            try expect(try snapshot(root) == beforeHardLink, "lock hard link was modified")
            try FileManager.default.removeItem(at: hardLink)
            try FileManager.default.removeItem(at: lockURL)

            try writeFile(at: lockURL, bytes: Data("widened-lock".utf8), mode: 0o644)
            let beforeMode = try snapshot(root)
            try expectError(.unsafeLock) { _ = try acquire(root: root) }
            try expect(try snapshot(root) == beforeMode, "widened lock was modified")
            try FileManager.default.removeItem(at: lockURL)
        }
    }

    private static func checkUnsafeLockDirectoryInputs() throws {
        try withContainer("unsafe-lock-dir") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let locks = try makeRoot(in: container, name: "locks")
            let directoryIdentity = try identity(of: root)
            let lockDirectoryIdentity = try identity(of: locks)
            let databaseIdentity = try identity(of: databaseURL)

            let link = container.appendingPathComponent("lock-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: locks.path
            )
            try expectError(.unsafeLockDirectory) {
                _ = try FloeAuthorityPrimitive(
                    trustedDirectoryPath: root.path,
                    lockDirectoryPath: link.path,
                    databaseName: databaseName,
                    expectedDirectory: directoryIdentity,
                    expectedLockDirectory: lockDirectoryIdentity,
                    expectedDatabase: databaseIdentity
                )
            }

            try expect(Darwin.chmod(locks.path, 0o755) == 0, "widen lock directory mode")
            try expectError(.unsafeLockDirectory) {
                _ = try FloeAuthorityPrimitive(
                    trustedDirectoryPath: root.path,
                    lockDirectoryPath: locks.path,
                    databaseName: databaseName,
                    expectedDirectory: directoryIdentity,
                    expectedLockDirectory: lockDirectoryIdentity,
                    expectedDatabase: databaseIdentity
                )
            }
            try expect(Darwin.chmod(locks.path, 0o700) == 0, "restore lock directory mode")

            let recovered = try acquire(root: root, lockRoot: locks)
            try recovered.verifyHeld()
            recovered.release()
        }
    }

    private static func checkForeignLockPreserved() throws {
        try withContainer("foreign-lock") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let lockURL = root.appendingPathComponent(
                FloeAuthorityPrimitive.lockFileName(for: try identity(of: databaseURL))
            )
            try writeFile(at: lockURL, bytes: Data("user-lock-sentinel".utf8), mode: 0o600)
            let before = try snapshot(root)
            try expectError(.untrustedExistingLock) { _ = try acquire(root: root) }
            try expect(try snapshot(root) == before, "foreign lock bytes or modes changed")
        }
    }

    private static func checkShortForeignLockPreserved() throws {
        try withContainer("short-foreign-lock") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let lockURL = root.appendingPathComponent(
                FloeAuthorityPrimitive.lockFileName(for: try identity(of: databaseURL))
            )
            try writeFile(at: lockURL, bytes: Data("F".utf8), mode: 0o600)
            let before = try snapshot(root)
            try expectError(.untrustedExistingLock) { _ = try acquire(root: root) }
            try expect(try snapshot(root) == before, "short foreign lock was modified")
        }
    }

    private static func checkForeignLockAdoption() throws {
        try withContainer("foreign-adopt") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let lockURL = root.appendingPathComponent(
                FloeAuthorityPrimitive.lockFileName(for: try identity(of: databaseURL))
            )
            try writeFile(at: lockURL, bytes: Data("legacy-lock-bytes".utf8), mode: 0o600)
            let lockIdentity = try identity(of: lockURL)
            let before = try snapshot(root)
            let other = container.appendingPathComponent("other-identity")
            try writeFile(at: other, bytes: Data("x".utf8), mode: 0o600)
            let wrongIdentity = try identity(of: other)
            try expectError(.untrustedExistingLock) {
                _ = try acquire(root: root, expectedExistingLock: wrongIdentity)
            }
            try expect(try snapshot(root) == before, "wrong prior identity modified the lock")

            let missingRoot = try makeRoot(in: container, name: "missing-lock")
            _ = try makeDatabase(at: missingRoot.appendingPathComponent(databaseName))
            let missingBefore = try snapshot(missingRoot)
            try expectError(.untrustedExistingLock) {
                _ = try acquire(root: missingRoot, expectedExistingLock: wrongIdentity)
            }
            try expect(
                try snapshot(missingRoot) == missingBefore,
                "missing lock with a prior identity was created"
            )

            let adopted = try acquire(root: root, expectedExistingLock: lockIdentity)
            try adopted.verifyHeld()
            adopted.release()
            try expect(try snapshot(root) == before, "adopted foreign lock was modified")
            try expectError(.untrustedExistingLock) { _ = try acquire(root: root) }
        }
    }

#if FLOE_AUTHORITY_TESTING
    private static func checkPriorLockRemovedBeforeOpen() throws {
        try withContainer("prior-removed-before-open") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let lockURL = root.appendingPathComponent(FloeAuthorityPrimitive.lockFileName(for: try identity(of: databaseURL)))
            try writeFile(at: lockURL, bytes: Data("prior".utf8), mode: 0o600)
            let prior = try identity(of: lockURL)
            FloeAuthorityPrimitiveTestHooks.beforeLockOpen = { _ = Darwin.unlink(lockURL.path) }
            defer { FloeAuthorityPrimitiveTestHooks.beforeLockOpen = nil }
            try expectError(.untrustedExistingLock) { _ = try acquire(root: root, expectedExistingLock: prior) }
            try expect(!FileManager.default.fileExists(atPath: lockURL.path), "missing prior lock was recreated")
        }
    }

    private static func checkPriorLockReplacedBeforeOpen() throws {
        try withContainer("prior-replaced-before-open") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let lockURL = root.appendingPathComponent(FloeAuthorityPrimitive.lockFileName(for: try identity(of: databaseURL)))
            let saved = container.appendingPathComponent("saved-prior")
            try writeFile(at: lockURL, bytes: Data("prior".utf8), mode: 0o600)
            let prior = try identity(of: lockURL)
            let replacement = Data("foreign replacement".utf8)
            FloeAuthorityPrimitiveTestHooks.beforeLockOpen = {
                try? FileManager.default.moveItem(at: lockURL, to: saved)
                try? writeFile(at: lockURL, bytes: replacement, mode: 0o600)
            }
            defer { FloeAuthorityPrimitiveTestHooks.beforeLockOpen = nil }
            try expectError(.untrustedExistingLock) { _ = try acquire(root: root, expectedExistingLock: prior) }
            try expect(try Data(contentsOf: lockURL) == replacement, "replacement lock bytes changed")
            try expect(try identity(of: saved) == prior, "prior lock identity changed")
        }
    }

    private static func checkForeignBytesBeforeFlock() throws {
        try withContainer("foreign-before-flock") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let lockURL = root.appendingPathComponent(FloeAuthorityPrimitive.lockFileName(for: try identity(of: databaseURL)))
            try writeFile(at: lockURL, bytes: Data(), mode: 0o600)
            let prior = try identity(of: lockURL)
            let foreign = Data("foreign bytes before lock".utf8)
            FloeAuthorityPrimitiveTestHooks.beforeFlock = { try? foreign.write(to: lockURL) }
            defer { FloeAuthorityPrimitiveTestHooks.beforeFlock = nil }
            try expectError(.untrustedExistingLock) { _ = try acquire(root: root) }
            try expect(try identity(of: lockURL) == prior, "fixture unexpectedly replaced the lock inode")
            try expect(try Data(contentsOf: lockURL) == foreign, "foreign lock bytes were overwritten")
        }
    }
#endif

    private static func checkConfusedHeader() throws {
        try withContainer("confused-header") { container in
            let root = try makeRoot(in: container)
            let firstURL = root.appendingPathComponent("first.sqlite")
            let secondURL = root.appendingPathComponent("second.sqlite")
            _ = try makeDatabase(at: firstURL)
            _ = try makeDatabase(at: secondURL)
            let first = try acquire(root: root, databaseName: "first.sqlite")
            let firstHeader = try Data(contentsOf: first.lockURL)
            first.release()

            let secondLockURL = root.appendingPathComponent(
                FloeAuthorityPrimitive.lockFileName(for: try identity(of: secondURL))
            )
            try writeFile(at: secondLockURL, bytes: firstHeader, mode: 0o600)
            let before = try snapshot(root)
            try expectError(.unsafeLock) {
                _ = try acquire(root: root, databaseName: "second.sqlite")
            }
            try expect(try snapshot(root) == before, "confused lock header was modified")
        }
    }

    private static func checkInterruptedHeader() throws {
        try withContainer("interrupted-header") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let lockURL = root.appendingPathComponent(
                FloeAuthorityPrimitive.lockFileName(for: try identity(of: databaseURL))
            )

            try writeFile(at: lockURL, bytes: Data(), mode: 0o600)
            let empty = try acquire(root: root)
            try empty.verifyHeld()
            let completed = try Data(contentsOf: empty.lockURL)
            try expect(completed.count >= 64, "empty lock header was not completed")
            empty.release()

            try expect(Darwin.truncate(lockURL.path, 16) == 0, "truncate lock to partial header")
            let partial = try acquire(root: root)
            try partial.verifyHeld()
            let restored = try Data(contentsOf: partial.lockURL)
            try expect(restored.count >= 64, "partial lock header was not completed")
            partial.release()
        }
    }

    private static func checkLockTruncationDetected() throws {
        try withContainer("lock-truncate") { container in
            let root = try makeRoot(in: container)
            _ = try makeDatabase(at: root.appendingPathComponent(databaseName))
            let primitive = try acquire(root: root)
            try expect(Darwin.truncate(primitive.lockURL.path, 0) == 0, "truncate lock")
            try expectError(.unsafeLock) { try primitive.verifyHeld() }
            primitive.release()
            let recovered = try acquire(root: root)
            try recovered.verifyHeld()
            recovered.release()
        }
    }

    private static func checkDatabaseReplacement() throws {
        try withContainer("db-replace") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let primitive = try acquire(root: root)
            let retained = container.appendingPathComponent("retained.sqlite")
            try FileManager.default.moveItem(at: databaseURL, to: retained)
            _ = try makeDatabase(at: databaseURL)
            let replacement = try snapshot(root)[databaseName]
            try expectError(.unsafeDatabase) { try primitive.verifyHeld() }
            try expect(try snapshot(root)[databaseName] == replacement, "replacement database changed")
            primitive.release()
        }
    }

    private static func checkLockReplacement() throws {
        try withContainer("lock-replace") { container in
            let root = try makeRoot(in: container)
            _ = try makeDatabase(at: root.appendingPathComponent(databaseName))
            let primitive = try acquire(root: root)
            let lockURL = primitive.lockURL
            let retained = container.appendingPathComponent("retained.lock")
            try FileManager.default.moveItem(at: lockURL, to: retained)
            try writeFile(at: lockURL, bytes: Data("replacement-lock".utf8), mode: 0o600)
            let replacement = try snapshot(root)[lockURL.lastPathComponent]
            try expectError(.unsafeLock) { try primitive.verifyHeld() }
            try expect(
                try snapshot(root)[lockURL.lastPathComponent] == replacement,
                "replacement lock changed"
            )
            primitive.release()
        }
    }

    private static func checkDirectoryReplacement() throws {
        try withContainer("dir-replace") { container in
            let root = try makeRoot(in: container)
            _ = try makeDatabase(at: root.appendingPathComponent(databaseName))
            let primitive = try acquire(root: root)
            let retained = container.appendingPathComponent("retained-root", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: retained)
            try makePrivateDirectory(root)
            try expectError(.unsafeDirectory) { try primitive.verifyHeld() }
            primitive.release()
        }
    }

    private static func checkSymlinkRetarget() throws {
        try withContainer("symlink-retarget") { container in
            let real = container.appendingPathComponent("real", isDirectory: true)
            let other = container.appendingPathComponent("other", isDirectory: true)
            try makePrivateDirectory(real)
            try makePrivateDirectory(other)
            let root = try makeRoot(in: real)
            _ = try makeDatabase(at: root.appendingPathComponent(databaseName))
            let otherRoot = try makeRoot(in: other)
            _ = try makeDatabase(at: otherRoot.appendingPathComponent(databaseName))

            let alias = container.appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                atPath: alias.path,
                withDestinationPath: "real"
            )
            let aliasedRoot = alias.appendingPathComponent("root", isDirectory: true)
            let primitive = try FloeAuthorityPrimitive(
                trustedDirectoryPath: aliasedRoot.path,
                lockDirectoryPath: root.path,
                databaseName: databaseName,
                expectedDirectory: try identity(of: root),
                expectedLockDirectory: try identity(of: root),
                expectedDatabase: try identity(of: root.appendingPathComponent(databaseName))
            )
            try primitive.verifyHeld()

            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(
                atPath: alias.path,
                withDestinationPath: "other"
            )
            try expectError(.unsafeDirectory) { try primitive.verifyHeld() }
            primitive.release()
        }
    }

    private static func checkWidenedModes() throws {
        try withContainer("widened") { container in
            let root = try makeRoot(in: container)
            let databaseURL = root.appendingPathComponent(databaseName)
            _ = try makeDatabase(at: databaseURL)
            let primitive = try acquire(root: root)

            try expect(Darwin.chmod(primitive.lockURL.path, 0o644) == 0, "widen lock mode")
            try expectError(.unsafeLock) { try primitive.verifyHeld() }
            try expect(Darwin.chmod(primitive.lockURL.path, 0o600) == 0, "restore lock mode")
            try primitive.verifyHeld()

            try expect(Darwin.chmod(databaseURL.path, 0o644) == 0, "widen database mode")
            try expectError(.unsafeDatabase) { try primitive.verifyHeld() }
            try expect(Darwin.chmod(databaseURL.path, 0o600) == 0, "restore database mode")
            try primitive.verifyHeld()

            try expect(Darwin.chmod(root.path, 0o755) == 0, "widen directory mode")
            try expectError(.unsafeDirectory) { try primitive.verifyHeld() }
            try expect(Darwin.chmod(root.path, 0o700) == 0, "restore directory mode")
            try primitive.verifyHeld()

            let hardLink = root.appendingPathComponent("new-hardlink.sqlite")
            try expect(Darwin.link(databaseURL.path, hardLink.path) == 0, "add database hard link")
            try expectError(.unsafeDatabase) { try primitive.verifyHeld() }
            try FileManager.default.removeItem(at: hardLink)
            try primitive.verifyHeld()

            primitive.release()
        }
    }

    private static func checkInvalidInputs() throws {
        try withContainer("invalid") { container in
            let root = try makeRoot(in: container)
            _ = try makeDatabase(at: root.appendingPathComponent(databaseName))
            let directoryIdentity = try identity(of: root)
            let databaseIdentity = try identity(of: root.appendingPathComponent(databaseName))

            try expectError(.invalidPath) {
                _ = try FloeAuthorityPrimitive(
                    trustedDirectoryPath: "relative/path",
                    lockDirectoryPath: root.path,
                    expectedDirectory: directoryIdentity,
                    expectedLockDirectory: directoryIdentity,
                    expectedDatabase: databaseIdentity
                )
            }
            try expectError(.invalidPath) {
                _ = try FloeAuthorityPrimitive(
                    trustedDirectoryPath: "/",
                    lockDirectoryPath: root.path,
                    expectedDirectory: directoryIdentity,
                    expectedLockDirectory: directoryIdentity,
                    expectedDatabase: databaseIdentity
                )
            }
            try expectError(.invalidPath) {
                _ = try FloeAuthorityPrimitive(
                    trustedDirectoryPath: root.path,
                    lockDirectoryPath: root.path,
                    databaseName: "../escape.sqlite",
                    expectedDirectory: directoryIdentity,
                    expectedLockDirectory: directoryIdentity,
                    expectedDatabase: databaseIdentity
                )
            }
            try expectError(.invalidPath) {
                _ = try FloeAuthorityPrimitive(
                    trustedDirectoryPath: root.path,
                    lockDirectoryPath: root.path,
                    databaseName: "nested/database.sqlite",
                    expectedDirectory: directoryIdentity,
                    expectedLockDirectory: directoryIdentity,
                    expectedDatabase: databaseIdentity
                )
            }
            try expectError(.invalidPath) {
                _ = try FloeAuthorityPrimitive(
                    trustedDirectoryPath: root.path,
                    lockDirectoryPath: root.path,
                    databaseName: "",
                    expectedDirectory: directoryIdentity,
                    expectedLockDirectory: directoryIdentity,
                    expectedDatabase: databaseIdentity
                )
            }
        }
    }

    // MARK: - Process checks

    private static func checkExternalProcessSeesBusy() throws {
        try withContainer("perl-busy") { container in
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
                print("SKIP external process check: /usr/bin/perl is unavailable")
                return
            }
            let root = try makeRoot(in: container)
            _ = try makeDatabase(at: root.appendingPathComponent(databaseName))
            let primitive = try acquire(root: root)
            let outputURL = container.appendingPathComponent("perl-busy-\(UUID().uuidString).log")
            let (status, output) = try runPerlTryLock(
                lockPath: primitive.lockURL.path,
                outputURL: outputURL
            )
            try expect(status == 3 && output.contains("BUSY"),
                       "external process did not observe the held lock: status=\(status) output=\(output)")
            try primitive.verifyHeld()
            primitive.release()
        }
    }

    private static func checkExternalProcessKillRecovery() throws {
        try withContainer("perl-kill") { container in
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
                print("SKIP external kill check: /usr/bin/perl is unavailable")
                return
            }
            let root = try makeRoot(in: container)
            _ = try makeDatabase(at: root.appendingPathComponent(databaseName))
            let initial = try acquire(root: root)
            let lockPath = initial.lockURL.path
            initial.release()

            let outputURL = container.appendingPathComponent("perl-hold-\(UUID().uuidString).log")
            let process = try startPerlHold(lockPath: lockPath, outputURL: outputURL)
            defer { killAndReap(process) }
            try expect(
                waitForOutput(outputURL, containing: "HELD", timeout: 4),
                "external holder did not start: \(readText(outputURL))"
            )
            try expectError(.busy) { _ = try acquire(root: root) }
            try expect(Darwin.kill(process.processIdentifier, SIGKILL) == 0, "kill external holder")
            process.waitUntilExit()
            let recovered = try acquire(root: root)
            try recovered.verifyHeld()
            recovered.release()
        }
    }

    private static func checkSelfProcessExclusion(executable: URL) throws {
        try withContainer("self-busy") { container in
            let root = try makeRoot(in: container)
            _ = try makeDatabase(at: root.appendingPathComponent(databaseName))
            let primitive = try acquire(root: root)
            let outputURL = container.appendingPathComponent("self-busy-\(UUID().uuidString).log")
            let process = try startSelf(
                executable: executable,
                arguments: ["--authority-probe-busy", root.path, databaseName],
                outputURL: outputURL
            )
            defer { killAndReap(process) }
            try expect(
                waitForExit(process, timeout: 5),
                "self probe did not exit: \(readText(outputURL))"
            )
            let output = readText(outputURL)
            try expect(
                process.terminationStatus == 0 && output.contains("CHILD_BUSY"),
                "self process did not observe the held lock: status=\(process.terminationStatus) output=\(output)"
            )
            try primitive.verifyHeld()
            primitive.release()
        }
    }

    private static func checkSelfProcessKillRecovery(executable: URL) throws {
        try withContainer("self-kill") { container in
            let root = try makeRoot(in: container)
            _ = try makeDatabase(at: root.appendingPathComponent(databaseName))
            let initial = try acquire(root: root)
            initial.release()

            let outputURL = container.appendingPathComponent("self-hold-\(UUID().uuidString).log")
            let process = try startSelf(
                executable: executable,
                arguments: ["--authority-hold", root.path, databaseName],
                outputURL: outputURL
            )
            defer { killAndReap(process) }
            try expect(
                waitForOutput(outputURL, containing: "HELD", timeout: 5),
                "self holder did not start: \(readText(outputURL))"
            )
            try expectError(.busy) { _ = try acquire(root: root) }
            try expect(Darwin.kill(process.processIdentifier, SIGKILL) == 0, "kill self holder")
            process.waitUntilExit()
            let recovered = try acquire(root: root)
            try recovered.verifyHeld()
            recovered.release()
        }
    }

    // MARK: - Fixture helpers

    private static func withContainer(
        _ name: String,
        _ body: (URL) throws -> Void
    ) throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "floe-authority-check-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        print("ROOT \(container.path)")
        do {
            try body(container)
            try? FileManager.default.removeItem(at: container)
        } catch {
            print("RETAINED \(container.path)")
            throw error
        }
    }

    private static func makeRoot(in parent: URL, name: String = "root") throws -> URL {
        let root = parent.appendingPathComponent(name, isDirectory: true)
        try makePrivateDirectory(root)
        return root
    }

    private static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try expect(Darwin.chmod(url.path, 0o700) == 0, "set fixture directory mode")
    }

    @discardableResult
    private static func makeDatabase(at url: URL) throws -> FloeAuthorityIdentity {
        let header = Data(sqliteHeader)
        let padding = Data(repeating: 0, count: max(0, 4096 - header.count))
        try writeFile(at: url, bytes: header + padding, mode: 0o600)
        return try identity(of: url)
    }

    private static func writeFile(at url: URL, bytes: Data, mode: mode_t) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode
        )
        guard descriptor >= 0 else {
            throw AuthorityPrimitiveCheckFailure.failed("create fixture file \(url.path) errno=\(errno)")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode) == 0 else {
            throw AuthorityPrimitiveCheckFailure.failed("chmod fixture file \(url.path)")
        }
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw AuthorityPrimitiveCheckFailure.failed("write fixture file \(url.path)")
            }
            if count == 0 {
                throw AuthorityPrimitiveCheckFailure.failed("short write \(url.path)")
            }
            written += count
        }
    }

    private static func acquire(
        root: URL,
        lockRoot: URL? = nil,
        databaseName: String = AuthorityPrimitiveChecks.databaseName,
        expectedExistingLock: FloeAuthorityIdentity? = nil
    ) throws -> FloeAuthorityPrimitive {
        let lockDirectory = lockRoot ?? root
        return try FloeAuthorityPrimitive(
            trustedDirectoryPath: root.path,
            lockDirectoryPath: lockDirectory.path,
            databaseName: databaseName,
            expectedDirectory: try identity(of: root),
            expectedLockDirectory: try identity(of: lockDirectory),
            expectedDatabase: try identity(of: root.appendingPathComponent(databaseName)),
            expectedExistingLock: expectedExistingLock
        )
    }

    static func snapshot(_ root: URL) throws -> [String: AuthorityFileSnapshot] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        var result: [String: AuthorityFileSnapshot] = [:]
        for name in names {
            let url = root.appendingPathComponent(name)
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                throw AuthorityPrimitiveCheckFailure.failed("lstat snapshot \(url.path)")
            }
            let type = value.st_mode & mode_t(S_IFMT)
            var bytes: Data?
            var target: String?
            if type == mode_t(S_IFREG), value.st_size <= 1_048_576 {
                bytes = try Data(contentsOf: url)
            }
            if type == mode_t(S_IFLNK) {
                target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            }
            result[name] = AuthorityFileSnapshot(
                mode: value.st_mode,
                device: value.st_dev,
                inode: value.st_ino,
                linkCount: UInt64(value.st_nlink),
                size: type == mode_t(S_IFREG) ? Int64(value.st_size) : 0,
                bytes: bytes,
                linkTarget: target
            )
        }
        return result
    }

    private static func identity(of url: URL) throws -> FloeAuthorityIdentity {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw AuthorityPrimitiveCheckFailure.failed("lstat \(url.path) errno=\(errno)")
        }
        return FloeAuthorityIdentity(value)
    }

    private static func fileMode(_ url: URL) throws -> mode_t {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw AuthorityPrimitiveCheckFailure.failed("lstat mode \(url.path)")
        }
        return value.st_mode & mode_t(0o7777)
    }

    private static func linkCount(_ url: URL) throws -> UInt64 {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw AuthorityPrimitiveCheckFailure.failed("lstat links \(url.path)")
        }
        return UInt64(value.st_nlink)
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw AuthorityPrimitiveCheckFailure.failed(message)
        }
    }

    private static func expectError(
        _ expected: FloeAuthorityPrimitiveError,
        _ body: () throws -> Void
    ) throws {
        do {
            try body()
        } catch let actual as FloeAuthorityPrimitiveError {
            guard actual == expected else {
                throw AuthorityPrimitiveCheckFailure.failed(
                    "expected \(expected), got \(actual)"
                )
            }
            return
        } catch {
            throw AuthorityPrimitiveCheckFailure.failed(
                "expected \(expected), got unrelated error \(error)"
            )
        }
        throw AuthorityPrimitiveCheckFailure.failed("expected \(expected), but no error")
    }

    // MARK: - External process helpers

    private static let perlTryLockScript = """
    use Fcntl qw(:flock);
    my $path = $ARGV[0];
    open(my $fh, '<', $path) or do { print "OPEN_FAILED\\n"; exit 4; };
    if (flock($fh, LOCK_EX | LOCK_NB)) { print "ACQUIRED\\n"; exit 0; }
    print "BUSY\\n";
    exit 3;
    """

    private static let perlHoldScript = """
    use Fcntl qw(:flock);
    my $path = $ARGV[0];
    open(my $fh, '<', $path) or do { print "OPEN_FAILED\\n"; exit 4; };
    flock($fh, LOCK_EX) or do { print "LOCK_FAILED\\n"; exit 5; };
    $| = 1;
    print "HELD\\n";
    sleep 60;
    """

    private static func runPerlTryLock(
        lockPath: String,
        outputURL: URL
    ) throws -> (status: Int32, output: String) {
        let process = try startProcess(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", perlTryLockScript, lockPath],
            outputURL: outputURL
        )
        try expect(waitForExit(process, timeout: 5), "perl try-lock timed out")
        return (process.terminationStatus, readText(outputURL))
    }

    private static func startPerlHold(lockPath: String, outputURL: URL) throws -> Process {
        try startProcess(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", perlHoldScript, lockPath],
            outputURL: outputURL
        )
    }

    private static func startSelf(
        executable: URL,
        arguments: [String],
        outputURL: URL
    ) throws -> Process {
        try startProcess(
            executable: executable.standardizedFileURL,
            arguments: arguments,
            outputURL: outputURL
        )
    }

    private static func startProcess(
        executable: URL,
        arguments: [String],
        outputURL: URL
    ) throws -> Process {
        try writeFile(at: outputURL, bytes: Data(), mode: 0o600)
        let outputDescriptor = Darwin.open(
            outputURL.path,
            O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        )
        guard outputDescriptor >= 0 else {
            throw AuthorityPrimitiveCheckFailure.failed("open child output \(outputURL.path)")
        }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return process
    }

    private static func waitForOutput(
        _ url: URL,
        containing text: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readText(url).contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return readText(url).contains(text)
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
    }

    private static func killAndReap(_ process: Process) {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func readText(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
