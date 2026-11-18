// SPDX-License-Identifier: MPL-2.0
// A host-owned, fixed lock-directory binding for future runtime integration.
// This validates a supplied provenance record but does not acquire a lock,
// authenticate the host, or prove the descriptor opened by SQLite. It is not
// an authorization token and does not enable production execution.

import Darwin
import Foundation

public struct FloeMacSelfAuthorityDomain: Sendable {
    public let lockDirectoryPath: String
    public let lockDirectoryIdentity: FloeMacSelfFileIdentity

    /// The host must persist the same private authority directory and identity
    /// independently of any database path, and supply them to every process.
    /// Deriving a new domain from each request does not establish exclusivity.
    public init(lockDirectoryPath: String, lockDirectoryIdentity: FloeMacSelfFileIdentity) {
        self.lockDirectoryPath = lockDirectoryPath
        self.lockDirectoryIdentity = lockDirectoryIdentity
    }

    public func validate(_ provenance: FloeMacSelfHostProvenance) throws {
        guard lockDirectoryPath.hasPrefix("/"),
              lockDirectoryPath != "/",
              !lockDirectoryPath.contains("\0"),
              URL(fileURLWithPath: lockDirectoryPath).standardizedFileURL.path == lockDirectoryPath,
              provenance.lockDirectoryPath == lockDirectoryPath,
              provenance.lockDirectoryIdentity == lockDirectoryIdentity else {
            throw FloeMacSelfCoreError.hostProvenanceUnavailable("authority_domain_mismatch")
        }
        var lockDirectory = stat()
        guard lstat(lockDirectoryPath, &lockDirectory) == 0,
              (lockDirectory.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              FloeMacSelfFileIdentity(lockDirectory) == lockDirectoryIdentity else {
            throw FloeMacSelfCoreError.hostProvenanceUnavailable("authority_domain_replaced")
        }
        guard !provenance.databaseName.isEmpty,
              provenance.databaseName != ".", provenance.databaseName != "..",
              !provenance.databaseName.contains("/"), !provenance.databaseName.contains("\0") else {
            throw FloeMacSelfCoreError.hostProvenanceUnavailable("invalid_database_name")
        }
        var database = stat()
        guard lstat(provenance.directoryPath + "/" + provenance.databaseName, &database) == 0,
              (database.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              FloeMacSelfFileIdentity(database) == provenance.databaseIdentity else {
            throw FloeMacSelfCoreError.hostProvenanceUnavailable("database_replaced")
        }
    }
}
