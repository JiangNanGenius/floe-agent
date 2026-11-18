// SPDX-License-Identifier: MPL-2.0

import Darwin
import FloeMacSelfCore
import Foundation

enum HostAgentDatabase {
    static func open(applicationSupport: URL, namespace: String) throws -> FloeMacSelfRuntime {
        let directoryName = namespace == "org.floeagent.macbridge" ? "Floe Mac Agent" : "Floe Mac Agent Development"
        let parent = applicationSupport
        let directory = parent.appendingPathComponent(directoryName, isDirectory: true)
        let databaseName = "floe.sqlite"
        let parentFD = try openDirectory(parent)
        defer { Darwin.close(parentFD) }
        guard mkdirat(parentFD, directoryName, 0o700) == 0 || errno == EEXIST else {
            throw StorageError.directoryCreate
        }
        let directoryFD = openat(parentFD, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw StorageError.directoryOpen }
        defer { Darwin.close(directoryFD) }
        let directoryIdentity = try checkedIdentity(directoryFD, type: S_IFDIR, permissions: 0o700)
        let fileFlags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var databaseFD = openat(directoryFD, databaseName, fileFlags | O_CREAT | O_EXCL, 0o600)
        if databaseFD < 0 && errno == EEXIST {
            databaseFD = openat(directoryFD, databaseName, fileFlags)
        }
        guard databaseFD >= 0 else { throw StorageError.databaseOpen }
        defer { Darwin.close(databaseFD) }
        let databaseIdentity = try checkedIdentity(databaseFD, type: S_IFREG, permissions: 0o600)
        // Foundation shortens /private/var on standardization. Capture the
        // identities through physical descriptors, then use the spelling
        // the runtime uses to validate the provenance.
        let database = directory.appendingPathComponent(databaseName).standardizedFileURL
        let runtimeDirectoryPath = database.deletingLastPathComponent().path
        let provenance = FloeMacSelfHostProvenance(
            directoryPath: runtimeDirectoryPath, lockDirectoryPath: runtimeDirectoryPath,
            databaseName: databaseName, directoryIdentity: directoryIdentity,
            lockDirectoryIdentity: directoryIdentity, databaseIdentity: databaseIdentity
        )
        return try FloeMacSelfRuntime(databaseURL: database,
                                     owner: .init(displayName: "Floe Mac"), provenance: provenance)
    }

    private static func openDirectory(_ directory: URL) throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/"), directory.path != "/" else {
            throw StorageError.supportDirectory
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = Darwin.open("/", flags)
        guard descriptor >= 0 else { throw StorageError.supportDirectory }
        for component in directory.path.split(separator: "/") {
            let child = openat(descriptor, String(component), flags)
            Darwin.close(descriptor)
            guard child >= 0 else { throw StorageError.supportDirectory }
            descriptor = child
        }
        return descriptor
    }

    private static func checkedIdentity(_ descriptor: Int32, type: mode_t,
                                        permissions: mode_t) throws -> FloeMacSelfFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & mode_t(S_IFMT)) == type,
              (info.st_mode & 0o7777) == permissions,
              type == S_IFDIR || info.st_nlink == 1 else {
            throw StorageError.ownershipOrPermissions
        }
        errno = 0
        if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0, errno == EINVAL else {
                throw StorageError.accessControl
            }
        } else if errno != ENOENT && errno != ENOATTR {
            throw StorageError.accessControl
        }
        return FloeMacSelfFileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }

    enum StorageError: String, Error {
        case supportDirectory, directoryCreate, directoryOpen, databaseOpen, ownershipOrPermissions, accessControl
    }
}
