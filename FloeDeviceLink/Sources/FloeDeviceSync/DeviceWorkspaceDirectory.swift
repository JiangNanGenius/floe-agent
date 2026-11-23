// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Darwin
import Foundation

/// The host is the authority for the binding and application write policy.
/// The directory handle pins that root for the lifetime of a transfer.
public struct DeviceWorkspaceRoot: Sendable {
    public let scope: String
    public let url: URL
    let guardCurrent: @Sendable () async throws -> Void
    let mutate: @Sendable (URL, @Sendable () throws -> Void) throws -> Void
    let release: @Sendable () -> Void

    public init(scope: String, url: URL, guardCurrent: @escaping @Sendable () async throws -> Void,
                mutate: @escaping @Sendable (URL, @Sendable () throws -> Void) throws -> Void = { _, operation in
                    try operation()
                },
                release: @escaping @Sendable () -> Void = {}) {
        self.scope = scope
        self.url = url
        self.guardCurrent = guardCurrent
        self.mutate = mutate
        self.release = release
    }
}

private final class WorkspaceDescriptor: Sendable {
    let number: Int32

    init(_ number: Int32) throws {
        guard number >= 0 else { throw Self.failure() }
        self.number = number
    }

    deinit { close(number) }

    func info() throws -> stat {
        var value = stat()
        guard fstat(number, &value) == 0 else { throw Self.failure() }
        return value
    }

    func hasName(_ name: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard let pointer = bytes.baseAddress, fcntl(number, F_GETPATH, pointer) == 0,
                  let path = String(validatingCString: pointer) else { return false }
            return path.split(separator: "/").last.map(String.init) == name
        }
    }

    static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

struct DeviceWorkspaceFileStamp: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    fileprivate init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

final class DeviceWorkspaceDirectory: Sendable {
    struct FileVersion: Sendable, Equatable {
        let stamp: DeviceWorkspaceFileStamp
        let digest: String
    }

    struct Scanned: Sendable {
        let entry: DeviceWorkspaceEntry
        let stamp: DeviceWorkspaceFileStamp?
    }

    final class StagedFile {
        fileprivate let name: String
        fileprivate let root: WorkspaceDescriptor
        private let output: FileHandle
        fileprivate var fileDescriptor: Int32 { output.fileDescriptor }
        private var hasher = SHA256()
        private var size: Int64 = 0

        fileprivate init(root: WorkspaceDescriptor) throws {
            self.root = root
            name = DeviceWorkspacePath.temporaryPrefix + UUID().uuidString
            let number = openat(root.number, name, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o600)
            guard number >= 0 else { throw WorkspaceDescriptor.failure() }
            output = FileHandle(fileDescriptor: number, closeOnDealloc: true)
        }

        deinit { _ = unlinkat(root.number, name, 0) }

        func append(_ bytes: Data) throws {
            try output.write(contentsOf: bytes)
            hasher.update(data: bytes)
            size += Int64(bytes.count)
        }

        func seal(size expectedSize: Int64, digest: String) throws {
            guard size == expectedSize, DeviceWorkspaceDigest.hex(hasher.finalize()) == digest else {
                throw DeviceHistorySyncError.invalidResponse
            }
            try output.synchronize()
        }
    }

    let lease: DeviceWorkspaceRoot
    private let descriptor: WorkspaceDescriptor
    private let identity: DeviceWorkspaceFileStamp

    init(_ lease: DeviceWorkspaceRoot) throws {
        do {
            let descriptor = try WorkspaceDescriptor(open(lease.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            identity = try DeviceWorkspaceFileStamp(descriptor.info())
            self.descriptor = descriptor
            self.lease = lease
        } catch {
            lease.release()
            throw error
        }
    }

    deinit { lease.release() }

    func validate() async throws {
        try Task.checkCancellation()
        try await lease.guardCurrent()
        try validateVisibleRoot()
    }

    private func validateVisibleRoot() throws {
        var value = stat()
        guard lstat(lease.url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              value.st_dev == identity.device, value.st_ino == identity.inode else {
            throw DeviceHistorySyncError.conflict
        }
    }

    func scan() throws -> [Scanned] {
        var files: [Scanned] = []
        var regularBytes: Int64 = 0
        try scan(descriptor, prefix: "", results: &files, regularBytes: &regularBytes)
        return files.sorted { $0.entry.path.utf8.lexicographicallyPrecedes($1.entry.path.utf8) }
    }

    private func scan(_ directory: WorkspaceDescriptor, prefix: String, results: inout [Scanned],
                      regularBytes: inout Int64) throws {
        let duplicate = dup(directory.number)
        guard duplicate >= 0 else { throw WorkspaceDescriptor.failure() }
        guard let entries = fdopendir(duplicate) else {
            let failure = WorkspaceDescriptor.failure()
            close(duplicate)
            throw failure
        }
        defer { closedir(entries) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(entries) else {
                if errno != 0 { throw WorkspaceDescriptor.failure() }
                return
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(validatingCString: $0) }
            }
            guard let name else { continue }
            let path = prefix + name
            guard DeviceWorkspacePath.isSyncable(path), let metadata = try info(in: directory, name: name),
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
                    throw DeviceHistorySyncError.tooLarge
                }
                let file = try openFile(name, in: directory)
                guard let file else { throw DeviceHistorySyncError.conflict }
                let version = try fileVersion(file)
                guard version.stamp == DeviceWorkspaceFileStamp(metadata) else { throw DeviceHistorySyncError.conflict }
                regularBytes += size
                results.append(.init(entry: .init(file: path, size: size, digest: version.digest), stamp: version.stamp))
            }
        }
    }

    private static func checkCount(_ count: Int) throws {
        guard count < DeviceWorkspaceManifest.maximumEntries else { throw DeviceHistorySyncError.tooLarge }
    }

    func read(_ item: Scanned, offset: Int64, count: Int) throws -> Data {
        let file = try file(at: item.entry.path)
        guard let file, let stamp = item.stamp, try file.info().matches(stamp) else {
            throw DeviceHistorySyncError.conflict
        }
        let bytes = try read(file, offset: offset, count: count)
        guard bytes.count == count, try file.info().matches(stamp) else { throw DeviceHistorySyncError.conflict }
        return bytes
    }

    func version(at path: String) throws -> FileVersion? {
        guard let file = try file(at: path) else { return nil }
        return try fileVersion(file)
    }

    func matches(_ item: Scanned) throws -> Bool {
        guard let expected = item.stamp, let file = try file(at: item.entry.path) else { return false }
        return try file.info().matches(expected)
    }

    func stage() throws -> StagedFile {
        try validateVisibleRoot()
        return try StagedFile(root: descriptor)
    }

    func createDirectory(at path: String) throws {
        try lease.mutate(lease.url.appending(path: path)) {
            try self.validateVisibleRoot()
            try Task.checkCancellation()
            _ = try self.parent(of: path + "/.", create: true)
        }
    }

    func commit(_ staged: StagedFile, path: String, replacing expected: FileVersion?) throws {
        let source = staged.root
        let temporaryName = staged.name
        let temporaryDescriptor = staged.fileDescriptor
        try lease.mutate(lease.url.appending(path: path)) {
            try self.validateVisibleRoot()
            try Task.checkCancellation()
            guard let (parent, name) = try self.parent(of: path, create: true) else {
                throw DeviceHistorySyncError.conflict
            }
            let existing = try self.info(in: parent, name: name)
            if let expected {
                guard let existing, let file = try self.openFile(name, in: parent),
                      try file.info().matches(expected.stamp) else { throw DeviceHistorySyncError.conflict }
                guard fchmod(temporaryDescriptor, existing.st_mode & 0o777) == 0 else {
                    throw WorkspaceDescriptor.failure()
                }
                guard renameat(source.number, temporaryName, parent.number, name) == 0 else {
                    throw WorkspaceDescriptor.failure()
                }
            } else {
                guard existing == nil else { throw DeviceHistorySyncError.conflict }
                guard renameatx_np(source.number, temporaryName, parent.number, name, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { throw DeviceHistorySyncError.conflict }
                    throw WorkspaceDescriptor.failure()
                }
            }
        }
    }

    func conflictPath(for entry: DeviceWorkspaceEntry) -> String {
        let digest = entry.digest ?? DeviceWorkspaceDigest.hex(SHA256.hash(data: Data(entry.path.utf8)))
        return DeviceWorkspacePath.conflicts + "/" + digest + "/" + entry.path
    }

    private func file(at path: String) throws -> WorkspaceDescriptor? {
        guard let (parent, name) = try parent(of: path, create: false) else { return nil }
        return try openFile(name, in: parent)
    }

    private func parent(of path: String, create: Bool) throws -> (WorkspaceDescriptor, String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw DeviceHistorySyncError.invalidResponse }
        var current = descriptor
        for component in parts.dropLast() {
            if try info(in: current, name: component) == nil {
                guard create else { return nil }
                guard mkdirat(current.number, component, 0o755) == 0 || errno == EEXIST else {
                    throw WorkspaceDescriptor.failure()
                }
            }
            current = try openDirectory(component, in: current)
        }
        return (current, name)
    }

    private func openDirectory(_ name: String, in parent: WorkspaceDescriptor) throws -> WorkspaceDescriptor {
        guard let metadata = try info(in: parent, name: name),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_dev == identity.device else {
            throw DeviceHistorySyncError.conflict
        }
        let child = try WorkspaceDescriptor(openat(parent.number, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        let opened = try child.info()
        guard opened.st_dev == identity.device, opened.st_ino == metadata.st_ino, child.hasName(name) else {
            throw DeviceHistorySyncError.conflict
        }
        return child
    }

    private func openFile(_ name: String, in parent: WorkspaceDescriptor) throws -> WorkspaceDescriptor? {
        guard let metadata = try info(in: parent, name: name) else { return nil }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_dev == identity.device else { throw DeviceHistorySyncError.conflict }
        let file = try WorkspaceDescriptor(openat(parent.number, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        let opened = try file.info()
        guard opened.matches(DeviceWorkspaceFileStamp(metadata)), opened.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1, file.hasName(name) else { throw DeviceHistorySyncError.conflict }
        return file
    }

    private func info(in directory: WorkspaceDescriptor, name: String) throws -> stat? {
        var value = stat()
        if fstatat(directory.number, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        if errno == ENOENT { return nil }
        throw WorkspaceDescriptor.failure()
    }

    private func fileVersion(_ file: WorkspaceDescriptor) throws -> FileVersion {
        let stamp = try DeviceWorkspaceFileStamp(file.info())
        guard stamp.size <= DeviceWorkspaceManifest.maximumFileBytes else { throw DeviceHistorySyncError.conflict }
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < stamp.size {
            try Task.checkCancellation()
            let count = Int(min(1 << 20, stamp.size - offset))
            let bytes = try read(file, offset: offset, count: count)
            guard !bytes.isEmpty else { throw DeviceHistorySyncError.conflict }
            hasher.update(data: bytes)
            offset += Int64(bytes.count)
        }
        guard try file.info().matches(stamp) else { throw DeviceHistorySyncError.conflict }
        return FileVersion(stamp: stamp, digest: DeviceWorkspaceDigest.hex(hasher.finalize()))
    }

    private func read(_ file: WorkspaceDescriptor, offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let length = try data.withUnsafeMutableBytes { buffer in
            let length = pread(file.number, buffer.baseAddress, count, offset)
            guard length >= 0 else { throw WorkspaceDescriptor.failure() }
            return length
        }
        data.count = length
        return data
    }
}

private extension stat {
    func matches(_ stamp: DeviceWorkspaceFileStamp) -> Bool {
        DeviceWorkspaceFileStamp(self) == stamp
    }
}
