// Fixed image-transfer namespace only. No symlink traversal or broad cache sweep.
import Foundation
import Darwin

struct LinuxImageStageIdentity: Codable, Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let uid: UInt32
    let links: UInt32
    let size: Int64
    let blocks: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    var allocatedBytes: Int64 {
        let (bytes, overflow) = max(0, blocks).multipliedReportingOverflow(by: 512)
        return overflow ? Int64.max : bytes
    }
    func sameInode(as other: Self) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode && uid == other.uid
    }
}

enum LinuxImageStageError: Error, Sendable {
    case unsafe, busy, limit, io(Int32)
}

struct LinuxImageStageNode {
    let components: [String]
    let identity: LinuxImageStageIdentity
}

enum LinuxImageStageIO {
    static let namespace = ".floe-image-transfers-v1"
    static let journalName = "owner.json"
    static let lockName = "owner.lock"
    static let journalLimit = 16_384

    static func identity(_ info: stat) -> LinuxImageStageIdentity {
        .init(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
              mode: UInt16(info.st_mode), uid: UInt32(info.st_uid), links: UInt32(info.st_nlink),
              size: Int64(info.st_size), blocks: Int64(info.st_blocks),
              modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
              changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    static func identity(fd: Int32) throws -> LinuxImageStageIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw LinuxImageStageError.io(errno) }
        return identity(info)
    }

    static func observe(_ name: String, in parent: Int32) throws -> LinuxImageStageIdentity? {
        try validate(name)
        var info = stat()
        let result = name.withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw LinuxImageStageError.io(errno)
        }
        return identity(info)
    }

    /// Read a small installer manifest through the held directory. Never
    /// follow a symlink or infer its identity from the name of the directory.
    static func manifestID(in directory: Int32) throws -> String? {
        guard let entry = try observe("manifest.json", in: directory) else { return nil }
        guard entry.isRegular, entry.uid == UInt32(geteuid()), entry.links == 1,
              entry.size > 0, entry.size <= 256 * 1024 else { throw LinuxImageStageError.unsafe }
        let fd = openat(directory, "manifest.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw LinuxImageStageError.io(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard try identity(fd: fd) == entry,
              let bytes = try handle.read(upToCount: Int(entry.size) + 1), bytes.count == Int(entry.size),
              try identity(fd: fd) == entry, try observe("manifest.json", in: directory) == entry else {
            throw LinuxImageStageError.unsafe
        }
        struct Identifier: Decodable { let id: String }
        let id = try JSONDecoder().decode(Identifier.self, from: bytes).id
        try validate(id)
        guard !id.hasPrefix(".") else { throw LinuxImageStageError.unsafe }
        return id
    }

    static func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0), name.utf8.count <= 240 else { throw LinuxImageStageError.unsafe }
    }

    static func directory(_ name: String, in parent: Int32, create: Bool) throws -> Int32? {
        try validate(name)
        if create {
            let result = name.withCString { mkdirat(parent, $0, mode_t(0o700)) }
            if result != 0 && errno != EEXIST { throw LinuxImageStageError.io(errno) }
        }
        let fd = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 {
            if !create && errno == ENOENT { return nil }
            throw LinuxImageStageError.io(errno)
        }
        do {
            let current = try identity(fd: fd)
            guard current.isDirectory, current.uid == UInt32(geteuid()) else { throw LinuxImageStageError.unsafe }
            return fd
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    static func images(root: URL, create: Bool) throws -> Int32? {
        // The installation service's existing App-owned artifact root is the
        // sole authority. Every child from that root is opened without following links.
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let rootFD = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        if rootFD < 0 {
            if !create && errno == ENOENT { return nil }
            throw LinuxImageStageError.io(errno)
        }
        defer { _ = Darwin.close(rootFD) }
        guard let linux = try directory("LinuxGuest", in: rootFD, create: create) else { return nil }
        defer { _ = Darwin.close(linux) }
        return try directory("images", in: linux, create: create)
    }

    static func names(in fd: Int32, limit: Int, allowPartial: Bool = false) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw LinuxImageStageError.io(errno) }
        guard let stream = fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            throw LinuxImageStageError.io(errno)
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            try validate(name)
            if result.count >= limit {
                if allowPartial { return result.sorted() }
                throw LinuxImageStageError.limit
            }
            result.append(name)
            errno = 0
        }
        guard errno == 0 else { throw LinuxImageStageError.io(errno) }
        return result.sorted()
    }

    static func lock(in directory: Int32, create: Bool) throws -> Int32 {
        let flags = O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT | O_EXCL : 0)
        let fd = lockName.withCString { openat(directory, $0, flags, mode_t(0o600)) }
        guard fd >= 0 else { throw LinuxImageStageError.io(errno) }
        do {
            let entry = try identity(fd: fd)
            guard entry.isRegular, entry.links == 1, entry.uid == UInt32(geteuid()), entry.size == 0 else {
                throw LinuxImageStageError.unsafe
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw LinuxImageStageError.busy }
                throw LinuxImageStageError.io(errno)
            }
            return fd
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    static func readRecord(in directory: Int32) throws -> LinuxImageStageRecord {
        let fd = journalName.withCString { openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw LinuxImageStageError.io(errno) }
        defer { _ = Darwin.close(fd) }
        let entry = try identity(fd: fd)
        guard entry.isRegular, entry.links == 1, entry.uid == UInt32(geteuid()),
              entry.size > 0, entry.size <= journalLimit else { throw LinuxImageStageError.unsafe }
        var bytes = [UInt8](repeating: 0, count: Int(entry.size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LinuxImageStageError.io(errno) }
            offset += count
        }
        return try JSONDecoder().decode(LinuxImageStageRecord.self, from: Data(bytes))
    }

    static func writeRecord(_ record: LinuxImageStageRecord, in directory: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(record)
        guard bytes.count <= journalLimit else { throw LinuxImageStageError.limit }
        let temporary = ".owner-\(UUID().uuidString).tmp"
        let fd = temporary.withCString {
            openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw LinuxImageStageError.io(errno) }
        defer { _ = Darwin.close(fd) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LinuxImageStageError.io(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw LinuxImageStageError.io(errno) }
        let renamed = temporary.withCString { old in
            journalName.withCString { renameat(directory, old, directory, $0) }
        }
        guard renamed == 0, fsync(directory) == 0 else { throw LinuxImageStageError.io(errno) }
    }

    static func snapshot(in directory: Int32, limit: Int, cancelled: () -> Bool) throws -> [LinuxImageStageNode] {
        var nodes: [LinuxImageStageNode] = []
        func walk(_ fd: Int32, _ prefix: [String]) throws {
            if cancelled() { throw CancellationError() }
            guard prefix.count < 24 else { throw LinuxImageStageError.limit }
            for name in try names(in: fd, limit: limit) {
                if cancelled() { throw CancellationError() }
                guard nodes.count < limit, let entry = try observe(name, in: fd),
                      entry.uid == UInt32(geteuid()), entry.isDirectory || (entry.isRegular && entry.links == 1) else {
                    throw LinuxImageStageError.unsafe
                }
                let parts = prefix + [name]
                nodes.append(.init(components: parts, identity: entry))
                if entry.isDirectory {
                    guard let child = try Self.directory(name, in: fd, create: false) else { throw LinuxImageStageError.unsafe }
                    defer { _ = Darwin.close(child) }
                    try walk(child, parts)
                }
            }
        }
        try walk(directory, [])
        return nodes
    }

    static func remove(
        nodes: [LinuxImageStageNode], from directory: Int32,
        cancelled: () -> Bool, report: inout LinuxGuestUpgradeResidueReport
    ) throws {
        // Delete payload first. owner.json is retained until every payload entry
        // is gone, so a cancelled/failed pass leaves durable deletion authority.
        let sorted = nodes.sorted {
            let lhsMeta = $0.components.first != "payload"
            let rhsMeta = $1.components.first != "payload"
            if lhsMeta != rhsMeta { return !lhsMeta }
            if $0.components.count != $1.components.count { return $0.components.count > $1.components.count }
            if $0.components == [journalName] { return false }
            if $1.components == [journalName] { return true }
            return $0.components.joined(separator: "/") < $1.components.joined(separator: "/")
        }
        for node in sorted {
            if cancelled() { throw CancellationError() }
            var parent = dup(directory)
            guard parent >= 0 else { throw LinuxImageStageError.io(errno) }
            defer { _ = Darwin.close(parent) }
            for component in node.components.dropLast() {
                guard let child = try Self.directory(component, in: parent, create: false) else { throw LinuxImageStageError.unsafe }
                _ = Darwin.close(parent)
                parent = child
            }
            guard let leaf = node.components.last, let observed = try observe(leaf, in: parent),
                  observed.sameInode(as: node.identity),
                  observed.isDirectory || observed == node.identity else { throw LinuxImageStageError.unsafe }
            let removed = leaf.withCString { unlinkat(parent, $0, observed.isDirectory ? AT_REMOVEDIR : 0) }
            guard removed == 0 else {
                if errno == EBUSY || errno == EAGAIN { throw LinuxImageStageError.busy }
                throw LinuxImageStageError.io(errno)
            }
            report.summedDeletedAllocatedBytes += observed.allocatedBytes
            report.deletedEntries += 1
            guard fsync(parent) == 0 else { throw LinuxImageStageError.io(errno) }
        }
    }

    static func availableBytes(fd: Int32) -> Int64? {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return nil }
        let block = max(1, Int64(info.f_bsize))
        return Int64(min(info.f_bavail, UInt64(Int64.max / block))) * block
    }
}
