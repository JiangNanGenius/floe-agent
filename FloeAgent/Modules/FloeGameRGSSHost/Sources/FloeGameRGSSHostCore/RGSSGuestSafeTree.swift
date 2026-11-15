// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bounded, descriptor-relative source inspection/copy. Symlinks and special
/// files are rejected instead of followed. Administrative VCS directories are
/// never copied into a run layer; the edit repository keeps their original
/// bytes untouched.
enum RGSSGuestSafeTree {
    struct Entry: Sendable, Equatable {
        let relative: String
        let directory: Bool
        let bytes: Int
        let executable: Bool
    }

    static let administrativeNames: Set<String> = [".git", ".hg", ".svn"]

    static func isAdministrative(_ name: String) -> Bool {
        administrativeNames.contains(name.lowercased())
    }

    static func scan(rootURL: URL, limits: RGSSGuestTreeLimits) throws -> [Entry] {
        let root = try openDirectory(rootURL)
        defer { close(root) }
        var result: [Entry] = []
        var total = 0
        try walk(directoryFD: root, prefix: "", depth: 0, limits: limits,
                 result: &result, total: &total)
        return result.sorted { $0.relative < $1.relative }
    }

    static func digest(rootURL: URL, limits: RGSSGuestTreeLimits) throws -> String {
        let root = try openDirectory(rootURL)
        defer { close(root) }
        var entries: [Entry] = []
        var total = 0
        try walk(directoryFD: root, prefix: "", depth: 0, limits: limits,
                 result: &entries, total: &total)
        entries.sort { $0.relative < $1.relative }
        var hasher = SHA256()
        let marker = Data("floe-rgss-tree-v1\n".utf8)
        hasher.update(data: marker)
        for entry in entries {
            let pathBytes = Data(entry.relative.utf8)
            hasher.update(data: pathBytes)
            hasher.update(data: Data([entry.directory ? UInt8(0x44) : UInt8(0x46)]))
            if entry.directory {
                hasher.update(data: Data([0]))
                continue
            }
            let fileHash = try hashFile(rootFD: root, relative: entry.relative,
                                        maximumBytes: limits.maximumFileBytes)
            hasher.update(data: fileHash)
            hasher.update(data: Data([entry.executable ? UInt8(1) : UInt8(0)]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies a source tree into a destination that must not exist yet. The
    /// destination root is created 0700. File bytes and executable bits are
    /// preserved; xattrs, ACLs and symlinks are not copied.
    @discardableResult
    static func copy(from sourceURL: URL, to destinationURL: URL,
                     limits: RGSSGuestTreeLimits) throws -> [Entry] {
        let source = try openDirectory(sourceURL)
        defer { close(source) }
        let destinationPath = destinationURL.standardizedFileURL.path
        guard destinationURL.isFileURL, destinationPath != "/" else {
            throw RGSSGuestRunError.runLayerViolation("invalid destination")
        }
        if FileManager.default.fileExists(atPath: destinationPath) {
            throw RGSSGuestRunError.runLayerViolation("destination already exists")
        }
        guard mkdir(destinationPath, mode_t(0o700)) == 0 else {
            throw RGSSGuestRunError.runLayerViolation("cannot create run root")
        }
        var result: [Entry] = []
        var total = 0
        try copyDirectory(sourceFD: source, destinationPath: destinationPath,
                          prefix: "", depth: 0, limits: limits,
                          result: &result, total: &total)
        return result.sorted { $0.relative < $1.relative }
    }

    static func readFile(rootURL: URL, relative: String, maximumBytes: Int) throws -> Data {
        let root = try openDirectory(rootURL)
        defer { close(root) }
        guard isSafeRelative(relative) else {
            throw RGSSGuestRunError.unsafeSourceEntry(relative)
        }
        let fd = try openFile(rootFD: root, relative: relative)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(maximumBytes) else {
            throw RGSSGuestRunError.sourceLimitExceeded(relative)
        }
        return try readAll(fd: fd, maximumBytes: maximumBytes)
    }

    static func isSafeRelative(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || isAdministrative(String($0)) })
    }

    // MARK: - Walk

    private static func walk(directoryFD: Int32, prefix: String, depth: Int,
                             limits: RGSSGuestTreeLimits,
                             result: inout [Entry], total: inout Int) throws {
        guard depth <= limits.maximumDepth else {
            throw RGSSGuestRunError.sourceLimitExceeded("tree depth")
        }
        let entries = try directoryNames(fd: directoryFD)
        for name in entries where !isAdministrative(name) {
            try Task.checkCancellation()
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            guard result.count < limits.maximumEntries else {
                throw RGSSGuestRunError.sourceLimitExceeded("tree entries")
            }
            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw RGSSGuestRunError.sourceRootUnavailable(relative)
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                result.append(.init(relative: relative, directory: true, bytes: 0, executable: false))
                let child = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    throw RGSSGuestRunError.unsafeSourceEntry(relative)
                }
                defer { close(child) }
                try walk(directoryFD: child, prefix: relative, depth: depth + 1,
                         limits: limits, result: &result, total: &total)
            case S_IFREG:
                let size = info.st_size
                guard size >= 0, size <= Int64(limits.maximumFileBytes),
                      total <= limits.maximumTotalBytes - Int(size) else {
                    throw RGSSGuestRunError.sourceLimitExceeded(relative)
                }
                total += Int(size)
                result.append(.init(relative: relative, directory: false,
                                    bytes: Int(size),
                                    executable: (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0))
            default:
                throw RGSSGuestRunError.unsafeSourceEntry(relative)
            }
        }
    }

    // MARK: - Copy

    private static func copyDirectory(sourceFD: Int32, destinationPath: String,
                                      prefix: String, depth: Int,
                                      limits: RGSSGuestTreeLimits,
                                      result: inout [Entry], total: inout Int) throws {
        guard depth <= limits.maximumDepth else {
            throw RGSSGuestRunError.sourceLimitExceeded("tree depth")
        }
        let names = try directoryNames(fd: sourceFD)
        for name in names where !isAdministrative(name) {
            try Task.checkCancellation()
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            guard result.count < limits.maximumEntries else {
                throw RGSSGuestRunError.sourceLimitExceeded("tree entries")
            }
            var info = stat()
            guard fstatat(sourceFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw RGSSGuestRunError.sourceRootUnavailable(relative)
            }
            let childDestination = (destinationPath as NSString).appendingPathComponent(name)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard mkdir(childDestination, mode_t(0o700)) == 0 else {
                    throw RGSSGuestRunError.runLayerViolation("cannot create \(relative)")
                }
                result.append(.init(relative: relative, directory: true, bytes: 0, executable: false))
                let child = openat(sourceFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    throw RGSSGuestRunError.unsafeSourceEntry(relative)
                }
                defer { close(child) }
                try copyDirectory(sourceFD: child, destinationPath: childDestination,
                                  prefix: relative, depth: depth + 1,
                                  limits: limits, result: &result, total: &total)
            case S_IFREG:
                let size = info.st_size
                guard size >= 0, size <= Int64(limits.maximumFileBytes),
                      total <= limits.maximumTotalBytes - Int(size) else {
                    throw RGSSGuestRunError.sourceLimitExceeded(relative)
                }
                total += Int(size)
                let sourceFile = openat(sourceFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard sourceFile >= 0 else {
                    throw RGSSGuestRunError.unsafeSourceEntry(relative)
                }
                defer { close(sourceFile) }
                let executable = (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0
                try copyFile(sourceFD: sourceFile, destinationPath: childDestination,
                             mode: executable ? 0o700 : 0o600,
                             expectedBytes: Int(size), relative: relative)
                result.append(.init(relative: relative, directory: false,
                                    bytes: Int(size), executable: executable))
            default:
                throw RGSSGuestRunError.unsafeSourceEntry(relative)
            }
        }
    }

    private static func copyFile(sourceFD: Int32, destinationPath: String, mode: mode_t,
                                 expectedBytes: Int, relative: String) throws {
        let destination = open(destinationPath,
                               O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode)
        guard destination >= 0 else {
            throw RGSSGuestRunError.runLayerViolation("cannot create \(relative)")
        }
        var openFlag = true
        defer {
            if openFlag { close(destination) }
            if openFlag { unlink(destinationPath) }
        }
        var copied = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(sourceFD, bytes.baseAddress!, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw RGSSGuestRunError.sourceRootUnavailable(relative)
            }
            if count == 0 { break }
            guard copied <= expectedBytes - count else {
                throw RGSSGuestRunError.saveBytesMismatch(relative)
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    systemWrite(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw RGSSGuestRunError.runLayerViolation("cannot write \(relative)")
                }
                offset += written
            }
            copied += count
        }
        guard copied == expectedBytes else {
            throw RGSSGuestRunError.saveBytesMismatch(relative)
        }
        guard fsync(destination) == 0 else {
            throw RGSSGuestRunError.runLayerViolation("cannot flush \(relative)")
        }
        close(destination)
        openFlag = false
    }

    // MARK: - Hashing

    private static func hashFile(rootFD: Int32, relative: String, maximumBytes: Int) throws -> Data {
        let fd = try openFile(rootFD: rootFD, relative: relative)
        defer { close(fd) }
        var hasher = SHA256()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(fd, bytes.baseAddress!, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw RGSSGuestRunError.sourceRootUnavailable(relative)
            }
            if count == 0 { break }
            guard total <= maximumBytes - count else {
                throw RGSSGuestRunError.sourceLimitExceeded(relative)
            }
            hasher.update(data: Data(buffer.prefix(count)))
            total += count
        }
        return Data(hasher.finalize())
    }

    // MARK: - Descriptor helpers

    private static func openDirectory(_ url: URL) throws -> Int32 {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw RGSSGuestRunError.sourceRootUnavailable(url.lastPathComponent)
        }
        return fd
    }

    private static func openFile(rootFD: Int32, relative: String) throws -> Int32 {
        guard isSafeRelative(relative) else {
            throw RGSSGuestRunError.unsafeSourceEntry(relative)
        }
        var current = dup(rootFD)
        guard current >= 0 else { throw RGSSGuestRunError.sourceRootUnavailable(relative) }
        defer { if current >= 0 { close(current) } }
        let components = relative.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
                | (isLast ? 0 : O_DIRECTORY)
            let next = openat(current, component, flags)
            close(current)
            current = -1
            guard next >= 0 else {
                throw RGSSGuestRunError.unsafeSourceEntry(relative)
            }
            current = next
        }
        let result = current
        current = -1
        return result
    }

    private static func directoryNames(fd: Int32) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else {
            throw RGSSGuestRunError.sourceRootUnavailable("directory")
        }
        guard let stream = fdopendir(duplicate) else {
            close(duplicate)
            throw RGSSGuestRunError.sourceRootUnavailable("directory")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw RGSSGuestRunError.sourceRootUnavailable("directory")
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            guard names.count < 100_001 else {
                throw RGSSGuestRunError.sourceLimitExceeded("directory entries")
            }
            names.append(name)
        }
        return names.sorted()
    }

    private static func readAll(fd: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(fd, bytes.baseAddress!, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw RGSSGuestRunError.sourceRootUnavailable("file")
            }
            if count == 0 { return result }
            guard result.count <= maximumBytes - count else {
                throw RGSSGuestRunError.sourceLimitExceeded("file")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
#else
    Glibc.read(descriptor, buffer, count)
#endif
}

private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
#else
    Glibc.write(descriptor, buffer, count)
#endif
}

/// Small bounded atomic file helper for owned save/developer layers. It never
/// follows a symlink and it fsyncs both the file and its parent directory.
enum RGSSGuestAtomicFile {
    static func write(_ data: Data, to url: URL, insideRoot root: URL) throws {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path == rootPath || parent.path.hasPrefix(rootPath + "/") else {
            throw RGSSGuestRunError.saveLayerViolation("destination escapes the owned layer")
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RGSSGuestRunError.saveLayerViolation("destination parent")
        }
        let resolvedParent = parent.resolvingSymlinksInPath()
        guard resolvedParent.path == rootPath || resolvedParent.path.hasPrefix(rootPath + "/") else {
            throw RGSSGuestRunError.saveLayerViolation("destination parent escapes through a symlink")
        }
        let temporary = parent.appendingPathComponent(".floe-rgss-" + UUID().uuidString)
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw RGSSGuestRunError.saveLayerViolation("cannot stage save")
        }
        var closed = false
        defer {
            if !closed { close(fd) }
            unlink(temporary.path)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = systemWrite(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw RGSSGuestRunError.saveLayerViolation("cannot write save")
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else {
            throw RGSSGuestRunError.saveLayerViolation("cannot flush save")
        }
        close(fd)
        closed = true
        guard rename(temporary.path, url.path) == 0 else {
            throw RGSSGuestRunError.saveLayerViolation("cannot replace save")
        }
        let parentFD = open(resolvedParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if parentFD >= 0 {
            _ = fsync(parentFD)
            close(parentFD)
        }
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw RGSSGuestRunError.invalidSaveName(url.lastPathComponent)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(maximumBytes) else {
            throw RGSSGuestRunError.saveLimitExceeded(url.lastPathComponent)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(fd, bytes.baseAddress!, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw RGSSGuestRunError.saveLayerViolation("cannot read save")
            }
            if count == 0 { return result }
            guard result.count <= maximumBytes - count else {
                throw RGSSGuestRunError.saveLimitExceeded(url.lastPathComponent)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
