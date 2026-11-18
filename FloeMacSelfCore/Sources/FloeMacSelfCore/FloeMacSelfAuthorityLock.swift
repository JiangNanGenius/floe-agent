// SPDX-License-Identifier: MPL-2.0
//
// Production authority gate for the host-selected private database.
//
// Two entry points, one safety posture:
//
//   * `init(databaseURL:owner:)` is the fail-closed gate. It refuses before
//     deriving, opening, creating, chmod-ing, truncating or reading any path.
//     `authorityOwnershipVerified` is intentionally false: it is a guard, not
//     a test switch. Enabling it without supplying provenance and without
//     resolving the start/stop/approval lifecycle races would reintroduce an
//     unsafe path-derived lock. The previous path-based implementation was
//     removed rather than retained behind the flag: an existing lock file
//     could be truncated, a replaced path could be accepted, and database
//     aliases could select independent locks.
//
//   * `init(provenance:owner:)` is the verified host-adapter path. It acquires
//     the `FloeAuthorityPrimitive` against host-supplied trusted provenance
//     (directory, lock directory and database identities captured by the host
//     before the runtime starts). Every identity is re-verified at
//     acquisition, before durable work, and on `verifyHeld()`; any mismatch
//     fails closed without modifying foreign bytes or modes.
//
// The runtime exposes both: the provenance initializer for genuine
// composition, and the gate initializer as the retained closed default.

import Foundation

final class FloeMacSelfAuthorityLock: @unchecked Sendable {
    private static let authorityOwnershipVerified = false

    private let primitive: FloeAuthorityPrimitive?

    /// Diagnostic path for the acquired lock. Empty while the gate is closed
    /// because the gate initializer throws before any stored property is
    /// initialized.
    let lockURL: URL

    /// Fail-closed gate. Refuses before touching any path.
    init(databaseURL: URL, owner: FloeMacSelfHostIdentity) throws {
        guard Self.authorityOwnershipVerified else {
            throw FloeMacSelfCoreError.authorityLockUnsafe("ownership_not_verified")
        }
        // Unreachable while the gate is closed. A future verified
        // auto-deriving implementation must not appear here: the only
        // permitted implementation binds host-supplied expected identities
        // through `init(provenance:owner:)`.
        _ = databaseURL
        _ = owner
        throw FloeMacSelfCoreError.authorityLockUnsafe("host_provenance_missing")
    }

    /// Acquires the verified authority lease for one exact database identity.
    init(provenance: FloeMacSelfHostProvenance, owner: FloeMacSelfHostIdentity) throws {
        _ = owner
        let acquired: FloeAuthorityPrimitive
        do {
            acquired = try FloeAuthorityPrimitive(
                trustedDirectoryPath: provenance.directoryPath,
                lockDirectoryPath: provenance.lockDirectoryPath,
                databaseName: provenance.databaseName,
                expectedDirectory: provenance.directoryIdentity.primitiveIdentity,
                expectedLockDirectory: provenance.lockDirectoryIdentity.primitiveIdentity,
                expectedDatabase: provenance.databaseIdentity.primitiveIdentity
            )
        } catch let error as FloeAuthorityPrimitiveError {
            throw Self.map(error)
        }
        self.primitive = acquired
        self.lockURL = acquired.lockURL
    }

    deinit {
        primitive?.release()
    }

    func verifyHeld() throws {
        guard let primitive else {
            throw FloeMacSelfCoreError.authorityLockUnsafe("ownership_not_verified")
        }
        do {
            try primitive.verifyHeld()
        } catch let error as FloeAuthorityPrimitiveError {
            throw Self.map(error)
        }
    }

    func release() {
        primitive?.release()
    }

    private static func map(_ error: FloeAuthorityPrimitiveError) -> FloeMacSelfCoreError {
        switch error {
        case .busy:
            return .authorityLocked
        case .invalidPath:
            return .authorityLockUnsafe("invalid_path")
        case .unsafeDirectory:
            return .authorityLockUnsafe("unsafe_directory")
        case .unsafeLockDirectory:
            return .authorityLockUnsafe("unsafe_lock_directory")
        case .unsafeDatabase:
            return .authorityLockUnsafe("unsafe_database")
        case .untrustedExistingLock:
            return .authorityLockUnsafe("untrusted_existing_lock")
        case .unsafeLock:
            return .authorityLockUnsafe("unsafe_lock")
        case .unavailable:
            return .authorityLockUnsafe("unavailable")
        case .released:
            return .authorityLockUnsafe("released")
        }
    }
}
