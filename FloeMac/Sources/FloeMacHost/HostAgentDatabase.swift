// SPDX-License-Identifier: MPL-2.0

import Darwin
import FloeMacSelfCore
import FloePersistence
import Foundation

enum HostAgentDatabase {
    static func open(applicationSupport: URL, namespace: String) throws -> FloeMacSelfRuntime {
        let directoryName = directoryName(for: namespace)
        let parent = applicationSupport
        let directory = parent.appendingPathComponent(directoryName, isDirectory: true)
        let databaseName = "floe.sqlite"
        let (directoryFD, directoryIdentity) = try openPrivateDirectory(parent: parent, name: directoryName)
        defer { Darwin.close(directoryFD) }
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
        // Personal conversations own a durable safe-files root each. The
        // lease resolves a private-task row as `<base>/<internalRelativePath>`
        // (i.e. `<base>/PrivateTasks/<task UUID>`), so the configured base is
        // the owner-only runtime directory itself — never the PrivateTasks
        // leaf (no duplicate PrivateTasks/PrivateTasks) and never a shared
        // parent. The unstandardized `directory` spelling is used here: the
        // standardized form shortens `/private/var` to `/var`, which the
        // no-follow directory walker rejects. The leaf directory is still
        // created here with the same 0o700 discipline; individual task
        // folders materialize only when a tool session binds that task's
        // workspace.
        let privateTaskRootBase = try preparePrivateTaskRootBase(runtimeDirectory: directory)
        return try FloeMacSelfRuntime(databaseURL: database,
                                      owner: .init(displayName: "Floe Mac"), provenance: provenance,
                                      options: .init(privateTaskRootBaseURL: privateTaskRootBase))
    }

    /// Canonical on-disk base of every per-task personal workspace:
    /// `<runtime directory>/PrivateTasks`. Returns the runtime directory,
    /// which is the lease/binding base; the managed leaf is created with the
    /// same descriptor-based 0o700 discipline as the runtime directory.
    /// Individual `<task UUID>` folders are materialized only when a tool
    /// session binds that task's workspace.
    static func preparePrivateTaskRootBase(runtimeDirectory: URL) throws -> URL {
        let (fd, _) = try openPrivateDirectory(parent: runtimeDirectory, name: "PrivateTasks")
        Darwin.close(fd)
        return runtimeDirectory.standardizedFileURL
    }

    /// Pure location of the managed per-task workspace aggregate
    /// (`<runtime directory>/PrivateTasks`). Performs no I/O; the host uses
    /// it for read-only UI exposure (Space browsing), while
    /// `preparePrivateTaskRootBase` remains the only creating entry point.
    static func privateTasksDirectoryURL(applicationSupport: URL, namespace: String) -> URL {
        runtimeDirectoryURL(applicationSupport: applicationSupport, namespace: namespace)
            .appendingPathComponent("PrivateTasks", isDirectory: true)
            .standardizedFileURL
    }

    /// Pure location of the owner-only runtime directory. Performs no I/O.
    static func runtimeDirectoryURL(applicationSupport: URL, namespace: String) -> URL {
        applicationSupport
            .appendingPathComponent(directoryName(for: namespace), isDirectory: true)
            .standardizedFileURL
    }

    /// Deterministic private location of the committed-task SyncStore that
    /// mirrors the host runtime database. Both files live in the same owner-
    /// only directory created by `open`; this seam performs no I/O and grants
    /// no access — the SyncStore itself enforces 0o600 permissions and schema
    /// ownership when the host opens it. The host derives the directory
    /// identity discipline from the same `namespace` mapping so the two files
    /// can never disagree about their private location.
    static func committedSyncStoreURL(applicationSupport: URL, namespace: String) throws -> URL {
        let parent = applicationSupport.standardizedFileURL
        guard parent.isFileURL, parent.path.hasPrefix("/"), parent.path != "/" else {
            throw StorageError.supportDirectory
        }
        return parent
            .appendingPathComponent(directoryName(for: namespace), isDirectory: true)
            .appendingPathComponent("floe-sync.sqlite")
    }

    /// CloudKit keeps account-specific change tokens and queued model updates.
    /// Open that cache beside the host store, using the same private directory
    /// and regular-file checks as the main database.
    static func openConfigurationCache(
        applicationSupport: URL, namespace: String, accountHash: String
    ) throws -> DatabaseManager {
        guard accountHash.utf8.count == 64,
              accountHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw StorageError.ownershipOrPermissions
        }
        let directory = applicationSupport.appendingPathComponent(directoryName(for: namespace), isDirectory: true)
        let directoryFD = try openDirectory(directory)
        defer { Darwin.close(directoryFD) }
        _ = try checkedIdentity(directoryFD, type: S_IFDIR, permissions: 0o700)
        let filename = "configuration-icloud-\(accountHash).sqlite"
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var descriptor = openat(directoryFD, filename, flags | O_CREAT | O_EXCL, 0o600)
        if descriptor < 0 && errno == EEXIST { descriptor = openat(directoryFD, filename, flags) }
        guard descriptor >= 0 else { throw StorageError.databaseOpen }
        defer { Darwin.close(descriptor) }
        _ = try checkedIdentity(descriptor, type: S_IFREG, permissions: 0o600)
        return try DatabaseManager(path: directory.appendingPathComponent(filename))
    }

    /// Media storage and the task database share this root. The first caller
    /// creates it under the exact same ownership and permission checks.
    static func prepareStorageDirectory(applicationSupport: URL, namespace: String) throws -> URL {
        let name = directoryName(for: namespace)
        let (fd, _) = try openPrivateDirectory(parent: applicationSupport, name: name)
        Darwin.close(fd)
        return applicationSupport.appendingPathComponent(name, isDirectory: true)
    }

    #if FLOE_UNIFIED_MAC
    /// File-picker bookmarks remain external. Images received as bytes are
    /// kept in a private directory belonging to exactly one conversation.
    private static let composerImagesDirectory = "Composer Images"

    @MainActor static func saveComposerImage(_ bytes: Data, fileExtension: String, id: UUID,
                                             owner: UUID, runtimeDirectory: URL) throws -> URL {
        guard ["png", "jpg", "gif", "webp"].contains(fileExtension), !bytes.isEmpty,
              bytes.count <= HostAgentWorkspace.maximumInlineImageBytes else { throw CocoaError(.fileReadTooLarge) }
        let base = physicalRuntimeDirectory(runtimeDirectory)
        let imports = base.appendingPathComponent(composerImagesDirectory, isDirectory: true)
        let (root, _) = try openPrivateDirectory(parent: base, name: composerImagesDirectory)
        defer { Darwin.close(root) }
        let (directory, _) = try openPrivateDirectory(parentFD: root, name: owner.uuidString)
        defer { Darwin.close(directory) }
        let name = "Photo-" + id.uuidString + "." + fileExtension
        let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(file) }
        do {
            _ = try checkedIdentity(file, type: S_IFREG, permissions: 0o600)
            try bytes.withUnsafeBytes { buffer in
                guard let start = buffer.baseAddress else { throw CocoaError(.fileWriteUnknown) }
                var done = 0
                while done < buffer.count {
                    let n = Darwin.write(file, start.advanced(by: done), buffer.count - done)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw CocoaError(.fileWriteUnknown) }
                    done += n
                }
            }
            guard fsync(file) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            unlinkat(directory, name, 0)
            unlinkat(root, owner.uuidString, AT_REMOVEDIR)
            throw error
        }
        return imports.appendingPathComponent(owner.uuidString, isDirectory: true).appendingPathComponent(name)
    }

    /// A recovered failed message gets a fresh draft ID. Only the original
    /// unsent import, identified by both its owner and its ID, may be discarded.
    static func discardComposerImage(_ url: URL, id: UUID, owner: UUID, runtimeDirectory: URL) {
        let imports = physicalRuntimeDirectory(runtimeDirectory).appendingPathComponent(composerImagesDirectory)
        let directory = imports.appendingPathComponent(owner.uuidString)
        let name = url.lastPathComponent
        guard directory.standardizedFileURL.path == url.deletingLastPathComponent().standardizedFileURL.path,
              composerImageID(name) == id, let parent = try? openDirectory(imports) else { return }
        defer { Darwin.close(parent) }
        guard (try? checkedIdentity(parent, type: S_IFDIR, permissions: 0o700)) != nil else { return }
        let fd = openat(parent, owner.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        guard (try? checkedIdentity(fd, type: S_IFDIR, permissions: 0o700)) != nil else { return }
        if unlinkat(fd, name, 0) == 0 {
            unlinkat(parent, owner.uuidString, AT_REMOVEDIR)
        }
    }

    static func removeComposerImages(for owner: UUID, runtimeDirectory: URL) {
        let imports = physicalRuntimeDirectory(runtimeDirectory).appendingPathComponent(composerImagesDirectory)
        guard let parent = try? openDirectory(imports) else { return }
        defer { Darwin.close(parent) }
        guard (try? checkedIdentity(parent, type: S_IFDIR, permissions: 0o700)) != nil else { return }
        let fd = openat(parent, owner.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        guard (try? checkedIdentity(fd, type: S_IFDIR, permissions: 0o700)) != nil else { return }
        let directoryURL = imports.appendingPathComponent(owner.uuidString)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? [] where composerImageID(name) != nil {
            unlinkat(fd, name, 0)
        }
        unlinkat(parent, owner.uuidString, AT_REMOVEDIR)
    }

    private static func composerImageID(_ name: String) -> UUID? {
        let file = name as NSString
        guard ["png", "jpg", "gif", "webp"].contains(file.pathExtension), file.deletingPathExtension.hasPrefix("Photo-") else { return nil }
        return UUID(uuidString: String(file.deletingPathExtension.dropFirst(6)))
    }

    private static func physicalRuntimeDirectory(_ directory: URL) -> URL {
        if directory.path.hasPrefix("/var/") || directory.path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + directory.path, isDirectory: true)
        }
        return directory
    }
    #endif

    private static func openPrivateDirectory(parent: URL, name: String) throws -> (Int32, FloeMacSelfFileIdentity) {
        let parentFD = try openDirectory(parent)
        defer { Darwin.close(parentFD) }
        return try openPrivateDirectory(parentFD: parentFD, name: name)
    }

    private static func openPrivateDirectory(parentFD: Int32, name: String) throws -> (Int32, FloeMacSelfFileIdentity) {
        guard mkdirat(parentFD, name, 0o700) == 0 || errno == EEXIST else { throw StorageError.directoryCreate }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageError.directoryOpen }
        do { return (fd, try checkedIdentity(fd, type: S_IFDIR, permissions: 0o700)) }
        catch { Darwin.close(fd); throw error }
    }

    private static func directoryName(for namespace: String) -> String {
        namespace == "org.floeagent.macbridge" ? "Floe Mac Agent" : "Floe Mac Agent Development"
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
