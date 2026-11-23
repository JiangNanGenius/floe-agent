// SPDX-License-Identifier: MPL-2.0
//
// Device-workspace sync — descriptor-pinned managed-root directory.
//
// Ported from the reviewed iOS donor `FloeDeviceLink` package
// (`DeviceWorkspaceDirectory.swift`), MPL-2.0, with the platform exchanges
// the Android product requires:
//   * CryptoKit -> swift-crypto `Crypto`;
//   * Darwin -> Darwin/Glibc/Android conditional imports, and the timespec
//     fields read `st_mtim`/`st_ctim` off Darwin (Glibc and Android both
//     expose the timespec member directly; the C `st_mtime` macro is not
//     visible to Swift — same idiom as `WorkspacePathSafety.swift`);
//   * exclusive-create commit uses a no-replace rename on Darwin and
//     Android, and linkat on the Linux host. Android's app sandbox rejects
//     hard links, including within the App's own workspace;
//   * the host lease closures of the donor are replaced by the synchronous
//     root-identity validation the bridge re-checks on every operation, and
//     the application write serialization is the ORIGINAL
//     `ManagedFileMutationLock.shared` recursive lock (same lock the managed
//     text/Office writers hold for versioned replacement).
//
// Authority notes carried over unchanged: the descriptor pins the root for
// the transfer lifetime; every descendant is opened relative to it with
// O_NOFOLLOW; only real directories and single-link regular files inside the
// pinned device are admitted; staged bytes are sealed by length + SHA-256
// before they can replace anything, so a failed commit never modifies old
// bytes.
import Foundation
import Crypto
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
import CFloeAndroidWorkspaceCommit
#endif

/// One pinned managed workspace root. The descriptor (not the path) is the
/// authority for every descendant operation; `rootPath` is kept ONLY for the
/// visible-root revalidation (a same-inode lstat proof against swaps).
final class DeviceWorkspaceDirectory {
    struct FileVersion: Sendable, Equatable {
        let stamp: DeviceWorkspaceFileStamp
        let digest: String
    }

    struct Scanned: Sendable {
        let entry: DeviceWorkspaceEntry
        let stamp: DeviceWorkspaceFileStamp?
    }

    enum TargetKind: Sendable, Equatable {
        case missing
        case directory
        case file(digest: String)
        /// Symlink/special/multi-link leaf or a non-directory ancestor in the
        /// path chain — the receiver preserves the local entry and reports a
        /// conflict, never writing through or around it.
        case blocked
    }

    private final class WorkspaceDescriptor {
        let number: Int32

        init(_ number: Int32) throws {
            guard number >= 0 else { throw DeviceWorkspaceLaneError.ioFailure }
            self.number = number
        }

        deinit { close(number) }

        func info() throws -> stat {
            var value = stat()
            guard fstat(number, &value) == 0 else { throw DeviceWorkspaceLaneError.ioFailure }
            return value
        }
    }

    final class StagedFile {
        let name: String
        private let rootNumber: Int32
        private let output: FileHandle
        private var hasher = SHA256()
        private(set) var size: Int64 = 0
        private(set) var sealed = false
        private var consumed = false

        init(rootNumber: Int32) throws {
            self.rootNumber = rootNumber
            name = DeviceWorkspacePath.temporaryPrefix + UUID().uuidString
            let number = name.withCString {
                openat(rootNumber, $0, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o600)
            }
            guard number >= 0 else {
                throw DeviceWorkspaceLaneError.ioFailure
            }
            output = FileHandle(fileDescriptor: number, closeOnDealloc: true)
        }

        deinit { _ = name.withCString { unlinkat(rootNumber, $0, 0) } }

        var isConsumed: Bool { consumed }

        func markConsumed() { consumed = true }

        func append(_ bytes: Data) throws {
            guard !sealed, !consumed else { throw DeviceWorkspaceLaneError.conflict }
            try output.write(contentsOf: bytes)
            hasher.update(data: bytes)
            size += Int64(bytes.count)
            guard size <= DeviceWorkspaceManifest.maximumFileBytes else {
                throw DeviceWorkspaceLaneError.oversized
            }
        }

        func seal(size expectedSize: Int64, digest: String) throws {
            guard !sealed, !consumed, size == expectedSize, DeviceWorkspaceDigest.hex(hasher.finalize()) == digest else {
                throw DeviceWorkspaceLaneError.conflict
            }
            try output.synchronize()
            try output.close()
            sealed = true
        }
    }

    private let descriptor: WorkspaceDescriptor
    private let identity: DeviceWorkspaceFileStamp
    let rootPath: String

    init(rootPath: String) throws {
        self.rootPath = rootPath
        let number = rootPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        do {
            let descriptor = try WorkspaceDescriptor(number)
            identity = try DeviceWorkspaceFileStamp(descriptor.info())
            self.descriptor = descriptor
        } catch {
            if number >= 0 { close(number) }
            throw error
        }
    }

    deinit {}

    // MARK: - Root currency

    /// Synchronous visible-root proof: the path still names the pinned
    /// device+inode as a real directory. A swap/rebind underneath the
    /// descriptor is a conflict, never a silent redirect.
    func validateVisibleRoot() throws {
        var value = stat()
        guard rootPath.withCString({ lstat($0, &value) }) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_dev == identity.device, value.st_ino == identity.inode else {
            throw DeviceWorkspaceLaneError.conflict
        }
    }

    /// The pinned root identity (scope proof input).
    var pinnedIdentity: DeviceWorkspaceFileStamp { identity }

    // MARK: - Source scan

    func scan() throws -> [Scanned] {
        var files: [Scanned] = []
        var regularBytes: Int64 = 0
        try scan(descriptor, prefix: "", results: &files, regularBytes: &regularBytes)
        return files.sorted { $0.entry.path.utf8.lexicographicallyPrecedes($1.entry.path.utf8) }
    }

    private func scan(_ directory: WorkspaceDescriptor, prefix: String, results: inout [Scanned],
                      regularBytes: inout Int64) throws {
        let duplicate = dup(directory.number)
        guard duplicate >= 0 else { throw DeviceWorkspaceLaneError.ioFailure }
        guard let entries = fdopendir(duplicate) else {
            close(duplicate)
            throw DeviceWorkspaceLaneError.ioFailure
        }
        defer { closedir(entries) }
        while true {
            errno = 0
            guard let item = readdir(entries) else {
                if errno != 0 { throw DeviceWorkspaceLaneError.ioFailure }
                return
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(validatingCString: $0) }
            }
            guard let name else { continue }
            let path = prefix + name
            guard DeviceWorkspacePath.isSyncable(path),
                  let metadata = try info(in: directory, name: name),
                  metadata.st_dev == identity.device else { continue }
            let type = metadata.st_mode & S_IFMT
            if type == S_IFDIR {
                try Self.checkCount(results.count)
                results.append(.init(entry: .init(directory: path), stamp: nil))
                let child = try openDirectory(name, in: directory)
                try scan(child, prefix: path + "/", results: &results, regularBytes: &regularBytes)
            } else if type == S_IFREG, metadata.st_nlink == 1 {
                try Self.checkCount(results.count)
                let size = metadata.st_size
                guard size <= DeviceWorkspaceManifest.maximumFileBytes,
                      size <= DeviceWorkspaceManifest.maximumTotalBytes - regularBytes else {
                    throw DeviceWorkspaceLaneError.oversized
                }
                let file = try openFile(name, in: directory)
                guard let file else { throw DeviceWorkspaceLaneError.conflict }
                let version = try fileVersion(file)
                guard version.stamp == DeviceWorkspaceFileStamp(metadata) else {
                    throw DeviceWorkspaceLaneError.conflict
                }
                regularBytes += size
                results.append(.init(entry: .init(file: path, size: size, digest: version.digest),
                                     stamp: version.stamp))
            }
        }
    }

    private static func checkCount(_ count: Int) throws {
        guard count < DeviceWorkspaceManifest.maximumEntries else { throw DeviceWorkspaceLaneError.oversized }
    }

    // MARK: - Source reads

    /// Donor read contract: open by path relative to the pinned descriptors,
    /// prove the snapshot stamp before AND after the read, and serve exactly
    /// `count` bytes — anything else is a conflict.
    func read(_ item: Scanned, offset: Int64, count: Int) throws -> Data {
        let file = try file(at: item.entry.path)
        guard let file, let stamp = item.stamp, try DeviceWorkspaceFileStamp(file.info()).matches(stamp) else {
            throw DeviceWorkspaceLaneError.conflict
        }
        let bytes = try read(file, offset: offset, count: count)
        guard bytes.count == count, try DeviceWorkspaceFileStamp(file.info()).matches(stamp) else {
            throw DeviceWorkspaceLaneError.conflict
        }
        return bytes
    }

    /// Snapshot identity re-check used by source confirmations (donor
    /// `confirm` validates the prepared index before recording the ledger).
    /// Zero-byte files compare by stamp alone — untouched means confirmed.
    func verify(_ item: Scanned) throws {
        guard item.entry.kind == .file else { throw DeviceWorkspaceLaneError.invalidArguments }
        let file = try file(at: item.entry.path)
        guard let file, let stamp = item.stamp, try DeviceWorkspaceFileStamp(file.info()).matches(stamp) else {
            throw DeviceWorkspaceLaneError.conflict
        }
    }

    func version(at path: String) throws -> FileVersion? {
        guard let file = try file(at: path) else { return nil }
        return try fileVersion(file)
    }

    // MARK: - Target staging + commit

    func stage() throws -> StagedFile {
        try validateVisibleRoot()
        return try StagedFile(rootNumber: descriptor.number)
    }

    /// Donor receive contract: create the directory chain (final component
    /// included) with mkdirat relative to opened parents; an existing real
    /// directory is idempotent success; anything else is a conflict.
    func createDirectory(at path: String, conflictDigest: String? = nil) throws {
        let path = try targetPath(path, conflictDigest: conflictDigest)
        ManagedFileMutationLock.shared.lock()
        defer { ManagedFileMutationLock.shared.unlock() }
        try validateVisibleRoot()
        _ = try parent(of: path + "/.", create: true)
    }

    /// Classify one target path (original or deterministic conflict path)
    /// without mutating anything. A symlink/special/multi-link leaf or a
    /// non-directory ancestor is `.blocked` — reported to the receiver as a
    /// conflict so the local entry is preserved.
    func targetKind(at path: String, conflictDigest: String? = nil) throws -> TargetKind {
        let path = try targetPath(path, conflictDigest: conflictDigest)
        let resolved: (WorkspaceDescriptor, String)?
        do {
            resolved = try parent(of: path, create: false)
        } catch DeviceWorkspaceLaneError.conflict {
            return .blocked
        }
        guard let (parent, name) = resolved else { return .missing }
        guard let metadata = try info(in: parent, name: name) else { return .missing }
        let type = metadata.st_mode & S_IFMT
        if type == S_IFDIR { return .directory }
        guard type == S_IFREG, metadata.st_nlink == 1, metadata.st_dev == identity.device else {
            return .blocked
        }
        let file = try openFile(name, in: parent)
        guard let file else { return .blocked }
        return .file(digest: try fileVersion(file).digest)
    }

    /// Deterministic conflict location: the peer file digest scopes one
    /// `Floe Sync Conflicts/<digest>/<original path>` tree. Built HERE from
    /// the original wire path plus the digest — a remote conflict
    /// directory/path is never trusted.
    private func targetPath(_ path: String, conflictDigest: String?) throws -> String {
        guard DeviceWorkspacePath.isSyncable(path) else { throw DeviceWorkspaceLaneError.invalidArguments }
        guard let digest = conflictDigest else { return path }
        guard DeviceWorkspaceDigest.isValid(digest) else { throw DeviceWorkspaceLaneError.invalidArguments }
        return DeviceWorkspacePath.conflicts + "/" + digest + "/" + path
    }

    /// Commit sealed staged bytes at `path` (donor `commit`, with the wire
    /// version identity the receiver actually holds):
    ///   * `replacingDigest == nil` — exclusive creation; an existing entry
    ///     of any kind is a conflict and nothing is modified;
    ///   * `replacingDigest != nil` — the current leaf must be a single-link
    ///     regular file on the pinned device whose content SHA-256 equals the
    ///     explicit previous digest, then a same-filesystem rename replaces
    ///     it; a concurrent change after staging is preserved as a conflict
    ///     instead and the old bytes are never modified on failure.
    /// Holds the ORIGINAL path-mutation serialization for the whole
    /// validation + rename so version comparison and replacement cannot
    /// interleave across service instances.
    func commit(_ staged: StagedFile, path: String, replacingDigest expectedDigest: String?,
                conflictDigest: String? = nil) throws {
        guard staged.sealed, !staged.isConsumed, conflictDigest == nil || expectedDigest == nil else {
            throw DeviceWorkspaceLaneError.invalidArguments
        }
        let path = try targetPath(path, conflictDigest: conflictDigest)
        ManagedFileMutationLock.shared.lock()
        defer { ManagedFileMutationLock.shared.unlock() }
        try validateVisibleRoot()
        guard let (parent, name) = try parent(of: path, create: true) else {
            throw DeviceWorkspaceLaneError.conflict
        }
        let existing = try info(in: parent, name: name)
        if let expectedDigest {
            guard DeviceWorkspaceDigest.isValid(expectedDigest) else {
                throw DeviceWorkspaceLaneError.invalidArguments
            }
            guard let existing, existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1,
                  existing.st_dev == identity.device else {
                throw DeviceWorkspaceLaneError.conflict
            }
            let current = try openFile(name, in: parent)
            guard let current, try fileVersion(current).digest == expectedDigest else {
                throw DeviceWorkspaceLaneError.conflict
            }
            try renameStaged(staged, into: parent, name: name)
        } else {
            guard existing == nil else { throw DeviceWorkspaceLaneError.conflict }
            #if canImport(Darwin) || canImport(Android)
            let renamed = staged.name.withCString { temporary in
                name.withCString { leaf in
                    #if canImport(Darwin)
                    renameatx_np(descriptor.number, temporary, parent.number, leaf, UInt32(RENAME_EXCL))
                    #else
                    floe_workspace_rename_no_replace(descriptor.number, temporary, parent.number, leaf)
                    #endif
                }
            }
            guard renamed == 0 else {
                if errno == EEXIST { throw DeviceWorkspaceLaneError.conflict }
                throw DeviceWorkspaceLaneError.ioFailure
            }
            staged.markConsumed()
            #else
            // Linux-host qualification uses linkat's atomic no-replace point.
            let linked = staged.name.withCString { temporary in
                name.withCString { leaf in
                    linkat(descriptor.number, temporary, parent.number, leaf, 0)
                }
            }
            guard linked == 0 else {
                if errno == EEXIST { throw DeviceWorkspaceLaneError.conflict }
                throw DeviceWorkspaceLaneError.ioFailure
            }
            _ = staged.name.withCString { unlinkat(descriptor.number, $0, 0) }
            staged.markConsumed()
            #endif
        }
    }

    private func renameStaged(_ staged: StagedFile, into parent: WorkspaceDescriptor, name: String) throws {
        guard staged.name.withCString({ temporary in
            name.withCString { leaf in
                renameat(descriptor.number, temporary, parent.number, leaf)
            }
        }) == 0 else {
            switch errno {
            case EEXIST, EISDIR, ENOTDIR, ENOTEMPTY:
                throw DeviceWorkspaceLaneError.conflict
            default:
                throw DeviceWorkspaceLaneError.ioFailure
            }
        }
        staged.markConsumed()
    }

    /// Applies a v2 rename or recoverable removal using the confirmed
    /// digest, and never replaces a path that already exists.
    func relocateConfirmedFile(
        key: String, digest: String, pathHint: String?, destination: String?,
        guardCurrent: () throws -> Void
    ) throws -> Bool {
        guard DeviceWorkspacePath.isSyncable(key), DeviceWorkspacePath.comparisonKey(key) == key,
              DeviceWorkspaceDigest.isValid(digest),
              pathHint.map({ DeviceWorkspacePath.isSyncable($0) && DeviceWorkspacePath.comparisonKey($0) == key }) ?? true,
              destination.map({ DeviceWorkspacePath.isSyncable($0) && DeviceWorkspacePath.comparisonKey($0) != key }) ?? true
        else { throw DeviceWorkspaceLaneError.invalidArguments }
        try validateVisibleRoot()
        do {
            // The old ledger may lack the original spelling. Walk only the
            // matching path components and hash only the confirmed file.
            guard let source = try matchingPath(key: key),
                  let verified = try version(at: source), verified.digest == digest else { return false }
            let target = destination ?? "\(DeviceWorkspacePath.conflicts)/Removed/\(UUID().uuidString)/\(source)"
            try guardCurrent()
            ManagedFileMutationLock.shared.lock()
            defer { ManagedFileMutationLock.shared.unlock() }
            try validateVisibleRoot()
            guard let (oldParent, oldName) = try parent(of: source, create: false),
                  let opened = try openFile(oldName, in: oldParent),
                  DeviceWorkspaceFileStamp(try opened.info()).matches(verified.stamp),
                  let onDisk = try info(in: oldParent, name: oldName),
                  DeviceWorkspaceFileStamp(onDisk).matches(verified.stamp) else { return false }
            if let destination, try hasAlternateSpelling(destination) { return false }
            guard let (newParent, newName) = try parent(of: target, create: true),
                  try info(in: newParent, name: newName) == nil else { return false }
            try validateVisibleRoot()
            guard let latest = try info(in: oldParent, name: oldName),
                  DeviceWorkspaceFileStamp(latest).matches(verified.stamp) else { return false }
            return try renameExclusively(from: oldParent, name: oldName, to: newParent, name: newName)
        } catch DeviceWorkspaceLaneError.conflict {
            return false
        }
    }

    private func matchingPath(key: String) throws -> String? {
        let parts = key.split(separator: "/").map(String.init)
        var current = descriptor
        var resolved: [String] = []
        for (index, component) in parts.enumerated() {
            guard let name = try matchingName(component, in: current) else { return nil }
            resolved.append(name)
            if index < parts.count - 1 { current = try openDirectory(name, in: current) }
        }
        let path = resolved.joined(separator: "/")
        return DeviceWorkspacePath.isSyncable(path) ? path : nil
    }

    private func hasAlternateSpelling(_ path: String) throws -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        var current = descriptor
        for (index, component) in parts.enumerated() {
            let key = DeviceWorkspacePath.comparisonKey(component)
            guard let name = try matchingName(key, in: current) else { return false }
            if !name.utf8.elementsEqual(component.utf8) { return true }
            if index < parts.count - 1 { current = try openDirectory(name, in: current) }
        }
        return false
    }

    private func matchingName(_ key: String, in directory: WorkspaceDescriptor) throws -> String? {
        let number = openat(directory.number, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard number >= 0 else { throw DeviceWorkspaceLaneError.ioFailure }
        guard let stream = fdopendir(number) else {
            close(number)
            throw DeviceWorkspaceLaneError.ioFailure
        }
        defer { closedir(stream) }
        var match: String?
        var scanned = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw DeviceWorkspaceLaneError.ioFailure }
                return match
            }
            scanned += 1
            guard scanned <= DeviceWorkspaceManifest.maximumEntries + 2 else { throw DeviceWorkspaceLaneError.oversized }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(validatingCString: $0) }
            }
            guard let name, DeviceWorkspacePath.comparisonKey(name) == key else { continue }
            guard match == nil else { throw DeviceWorkspaceLaneError.conflict }
            match = name
        }
    }

    private func renameExclusively(from source: WorkspaceDescriptor, name oldName: String,
                                   to target: WorkspaceDescriptor, name newName: String) throws -> Bool {
        let status = oldName.withCString { old in
            newName.withCString { new in
                #if canImport(Darwin)
                renameatx_np(source.number, old, target.number, new, UInt32(RENAME_EXCL))
                #elseif canImport(Android)
                floe_workspace_rename_no_replace(source.number, old, target.number, new)
                #else
                linkat(source.number, old, target.number, new, 0)
                #endif
            }
        }
        guard status == 0 else {
            if errno == EEXIST { return false }
            throw DeviceWorkspaceLaneError.ioFailure
        }
        #if !canImport(Darwin) && !canImport(Android)
        if oldName.withCString({ unlinkat(source.number, $0, 0) }) != 0 {
            _ = newName.withCString { unlinkat(target.number, $0, 0) }
            throw DeviceWorkspaceLaneError.ioFailure
        }
        #endif
        _ = fsync(source.number)
        _ = fsync(target.number)
        return true
    }

    // MARK: - Descriptor-relative plumbing

    private func file(at path: String) throws -> WorkspaceDescriptor? {
        guard let (parent, name) = try parent(of: path, create: false) else { return nil }
        return try openFile(name, in: parent)
    }

    private func parent(of path: String, create: Bool) throws -> (WorkspaceDescriptor, String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw DeviceWorkspaceLaneError.invalidArguments }
        var current = descriptor
        for component in parts.dropLast() {
            if try info(in: current, name: component) == nil {
                guard create else { return nil }
                guard component.withCString({ mkdirat(current.number, $0, 0o755) }) == 0 || errno == EEXIST else {
                    throw DeviceWorkspaceLaneError.ioFailure
                }
            }
            current = try openDirectory(component, in: current)
        }
        return (current, name)
    }

    private func openDirectory(_ name: String, in parent: WorkspaceDescriptor) throws -> WorkspaceDescriptor {
        guard let metadata = try info(in: parent, name: name),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_dev == identity.device else {
            throw DeviceWorkspaceLaneError.conflict
        }
        let child = try name.withCString {
            try WorkspaceDescriptor(openat(parent.number, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        }
        let opened = try child.info()
        guard opened.st_dev == identity.device, opened.st_ino == metadata.st_ino else {
            throw DeviceWorkspaceLaneError.conflict
        }
        return child
    }

    private func openFile(_ name: String, in parent: WorkspaceDescriptor) throws -> WorkspaceDescriptor? {
        guard let metadata = try info(in: parent, name: name) else { return nil }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_dev == identity.device else { throw DeviceWorkspaceLaneError.conflict }
        let file = try name.withCString {
            try WorkspaceDescriptor(openat(parent.number, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        }
        let opened = try file.info()
        guard DeviceWorkspaceFileStamp(opened).matches(DeviceWorkspaceFileStamp(metadata)),
              opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1 else {
            throw DeviceWorkspaceLaneError.conflict
        }
        return file
    }

    private func info(in directory: WorkspaceDescriptor, name: String) throws -> stat? {
        var value = stat()
        let status = name.withCString { fstatat(directory.number, $0, &value, AT_SYMLINK_NOFOLLOW) }
        if status == 0 { return value }
        if errno == ENOENT { return nil }
        throw DeviceWorkspaceLaneError.ioFailure
    }

    private func fileVersion(_ file: WorkspaceDescriptor) throws -> FileVersion {
        let stamp = try DeviceWorkspaceFileStamp(file.info())
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < stamp.size {
            let count = Int(min(1 << 20, stamp.size - offset))
            let bytes = try read(file, offset: offset, count: count)
            guard !bytes.isEmpty else { throw DeviceWorkspaceLaneError.conflict }
            hasher.update(data: bytes)
            offset += Int64(bytes.count)
        }
        guard try DeviceWorkspaceFileStamp(file.info()).matches(stamp) else { throw DeviceWorkspaceLaneError.conflict }
        return FileVersion(stamp: stamp, digest: DeviceWorkspaceDigest.hex(hasher.finalize()))
    }

    private func read(_ file: WorkspaceDescriptor, offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let length = try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { throw DeviceWorkspaceLaneError.ioFailure }
            let length = pread(file.number, base, count, offset)
            guard length >= 0 else { throw DeviceWorkspaceLaneError.ioFailure }
            return length
        }
        data.count = length
        return data
    }
}

/// Immutable file identity: device+inode pin, size and the full
/// modification/change stamps (nanoseconds). A content read is valid only
/// when the identity is identical on both sides of it.
struct DeviceWorkspaceFileStamp: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        #if canImport(Darwin)
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
        #else
        modifiedSeconds = value.st_mtim.tv_sec
        modifiedNanoseconds = value.st_mtim.tv_nsec
        changedSeconds = value.st_ctim.tv_sec
        changedNanoseconds = value.st_ctim.tv_nsec
        #endif
    }

    func matches(_ other: DeviceWorkspaceFileStamp) -> Bool { self == other }
}
