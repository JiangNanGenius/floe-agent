// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import CryptoKit
import FloeGameCore

/// Descriptor-relative, symlink-refusing file IO for exact source offers.
///
/// Every source read traverses from an opened root directory with `openat` and
/// `O_NOFOLLOW`; the final descriptor is `fstat`-checked as a regular file with
/// `O_NONBLOCK` so a FIFO cannot block the caller. Writes are created with
/// `openat(O_CREAT|O_EXCL|O_NOFOLLOW)` under an already-open staging directory,
/// and publication uses `renameatx_np(RENAME_EXCL)` between two names in that
/// same parent descriptor. A prior `URLResourceValues` check is never treated
/// as proof of a safe path.
enum GamePortableAnchoredIO {
    enum Kind: Equatable, Sendable {
        case regularFile
        case directory
        case symlink
        case other
        case missing
    }

    static func kind(_ url: URL) -> Kind {
        let value = url.standardizedFileURL
        var info = stat()
        let result = value.path.withCString { lstat($0, &info) }
        guard result == 0 else { return errno == ENOENT ? .missing : .other }
        let mode = info.st_mode & S_IFMT
        if mode == S_IFREG { return .regularFile }
        if mode == S_IFDIR { return .directory }
        if mode == S_IFLNK { return .symlink }
        return .other
    }

    /// Opens the caller-designated root directory. The URL's final symlink is
    /// resolved once (document-provider roots are often aliases); the opened
    /// descriptor is anchored and every descendant name is checked with
    /// `O_NOFOLLOW`.
    static func openDirectory(_ url: URL) throws -> Int32 {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = canonical.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw GamePortableSourceOfferError.io("open source root")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(descriptor)
            throw GamePortableSourceOfferError.io("source root is not a directory")
        }
        return descriptor
    }

    /// Opens the parent of `path` relative to `root`, refusing every symlinked
    /// intermediate component. The returned descriptor is owned by the caller.
    static func openParentDirectory(root: URL,
                                    path: GameRelativePath) throws -> (fd: Int32, name: String) {
        let components = path.value.split(separator: "/")
        guard let lastName = components.last else {
            throw GamePortableSourceOfferError.io("empty source path")
        }
        var current = try openDirectory(root)
        for component in components.dropLast() {
            let next = String(component).withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                Darwin.close(current)
                throw GamePortableSourceOfferError.invalidBundle("symlinked source directory")
            }
            Darwin.close(current)
            current = next
        }
        return (current, String(lastName))
    }

    /// Opens and validates the final regular file. The descriptor is positioned
    /// at zero and stays owned by the caller.
    static func openVerifiedRegularFile(root: URL, path: GameRelativePath,
                                        expectedBytes: Int?,
                                        maximumBytes: Int) throws -> (fd: Int32, bytes: Int) {
        let parent = try openParentDirectory(root: root, path: path)
        defer { Darwin.close(parent.fd) }
        return try openVerifiedRegularFile(directoryFD: parent.fd, name: parent.name,
                                           expectedBytes: expectedBytes,
                                           maximumBytes: maximumBytes)
    }

    static func openVerifiedRegularFile(directoryFD: Int32, name: String,
                                        expectedBytes: Int?,
                                        maximumBytes: Int) throws -> (fd: Int32, bytes: Int) {
        let descriptor = name.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw GamePortableSourceOfferError.missingFile(name)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes,
              (expectedBytes.map { info.st_size == Int64($0) } ?? true) else {
            Darwin.close(descriptor)
            throw GamePortableSourceOfferError.missingFile(name)
        }
        return (descriptor, Int(info.st_size))
    }

    /// Creates (or reuses verified) intermediate directories under `rootFD` and
    /// returns an owned descriptor for the final parent plus the leaf name.
    static func createParentDirectory(rootFD: Int32,
                                      path: GameRelativePath) throws -> (fd: Int32, name: String) {
        let components = path.value.split(separator: "/")
        guard let lastName = components.last else {
            throw GamePortableSourceOfferError.io("empty destination path")
        }
        var current = dup(rootFD)
        guard current >= 0 else { throw GamePortableSourceOfferError.io("duplicate directory") }
        for component in components.dropLast() {
            let name = String(component)
            var info = stat()
            let exists = name.withCString {
                fstatat(current, $0, &info, AT_SYMLINK_NOFOLLOW)
            } == 0
            if !exists {
                let created = name.withCString { mkdirat(current, $0, 0o700) }
                guard created == 0 || errno == EEXIST else {
                    Darwin.close(current)
                    throw GamePortableSourceOfferError.io("create destination directory")
                }
            }
            let next = name.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                Darwin.close(current)
                throw GamePortableSourceOfferError.io("destination directory is not a real directory")
            }
            Darwin.close(current)
            current = next
        }
        return (current, String(lastName))
    }

    static func createExclusiveFile(directoryFD: Int32, name: String) throws -> Int32 {
        let descriptor = name.withCString {
            openat(directoryFD, $0,
                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw GamePortableSourceOfferError.destinationExists
            }
            throw GamePortableSourceOfferError.io("create destination file")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            unlink(directoryFD: directoryFD, name: name)
            throw GamePortableSourceOfferError.io("destination is not a regular file")
        }
        return descriptor
    }

    static func createStagingDirectory(in parent: URL,
                                       name: String) throws -> (fd: Int32, url: URL) {
        let canonical = parent.standardizedFileURL.resolvingSymlinksInPath()
        let parentFD = try openDirectory(canonical)
        defer { Darwin.close(parentFD) }
        let created = name.withCString { mkdirat(parentFD, $0, 0o700) }
        guard created == 0 else {
            throw GamePortableSourceOfferError.io("create staging directory")
        }
        let descriptor = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            _ = name.withCString { unlinkat(parentFD, $0, AT_REMOVEDIR) }
            throw GamePortableSourceOfferError.io("open staging directory")
        }
        return (descriptor, canonical.appendingPathComponent(name, isDirectory: true))
    }

    /// Descriptor-relative existence check. Missing intermediate components
    /// return false; a symlinked/irregular intermediate is a hard failure.
    static func exists(root: URL, path: GameRelativePath) throws -> Bool {
        let components = path.value.split(separator: "/")
        guard let lastName = components.last else { return false }
        var current = try openDirectory(root)
        for component in components.dropLast() {
            let name = String(component)
            var info = stat()
            let found = name.withCString {
                fstatat(current, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            if found != 0 {
                let savedErrno = errno
                Darwin.close(current)
                if savedErrno == ENOENT { return false }
                throw GamePortableSourceOfferError.io("inspect source path")
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(current)
                throw GamePortableSourceOfferError.invalidBundle("symlinked source directory")
            }
            let next = name.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                Darwin.close(current)
                throw GamePortableSourceOfferError.invalidBundle("symlinked source directory")
            }
            Darwin.close(current)
            current = next
        }
        var info = stat()
        let result = lastName.withCString {
            fstatat(current, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        let savedErrno = errno
        Darwin.close(current)
        if result != 0 {
            if savedErrno == ENOENT { return false }
            throw GamePortableSourceOfferError.io("inspect source path")
        }
        return true
    }

    /// Streams exactly `expectedBytes` from the source descriptor into the
    /// destination while hashing. The caller owns both descriptors.
    static func copy(source: Int32, to destination: Int32,
                     expectedBytes: Int) throws -> String {
        var hasher = SHA256()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(source, bytes.baseAddress!, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw GamePortableSourceOfferError.io("read source file")
            }
            if count == 0 { break }
            guard total <= expectedBytes - count else {
                throw GamePortableSourceOfferError.digestMismatch("source size")
            }
            total += count
            hasher.update(data: Data(buffer[0..<count]))
            try writeAll(descriptor: destination, buffer: buffer, count: count)
        }
        guard total == expectedBytes else {
            throw GamePortableSourceOfferError.digestMismatch("source size")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func writeAll(descriptor: Int32, buffer: [UInt8], count: Int) throws {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset),
                             count - offset)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                throw GamePortableSourceOfferError.io("write destination file")
            }
            offset += written
        }
    }

    static func write(_ data: Data, directoryFD: Int32,
                      path: GameRelativePath) throws {
        let parent = try createParentDirectory(rootFD: directoryFD, path: path)
        defer { Darwin.close(parent.fd) }
        let descriptor = try createExclusiveFile(directoryFD: parent.fd, name: parent.name)
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor,
                        bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        throw GamePortableSourceOfferError.io("write generated file")
                    }
                    offset += written
                }
            }
            _ = Darwin.fsync(descriptor)
            Darwin.close(descriptor)
        } catch {
            Darwin.close(descriptor)
            unlink(directoryFD: parent.fd, name: parent.name)
            throw error
        }
    }

    static func hash(descriptor: Int32, maximumBytes: Int) throws -> (bytes: Int, sha256: String) {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw GamePortableSourceOfferError.io("read back")
        }
        var hasher = SHA256()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw GamePortableSourceOfferError.io("read back")
            }
            if count == 0 { break }
            total += count
            guard total <= maximumBytes else {
                throw GamePortableSourceOfferError.io("read-back limit")
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func hashStandaloneRegularFile(_ url: URL,
                                          maximumBytes: Int) throws -> (bytes: Int, sha256: String) {
        let value = url.standardizedFileURL
        guard kind(value) == .regularFile else {
            throw GamePortableSourceOfferError.invalidBundle("source bundle is not a regular file")
        }
        let descriptor = value.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw GamePortableSourceOfferError.missingFile(value.lastPathComponent)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw GamePortableSourceOfferError.invalidBundle("source bundle is not readable")
        }
        return try hash(descriptor: descriptor, maximumBytes: maximumBytes)
    }

    static func renameExclusive(directoryFD: Int32, from: String, to: String) throws {
        let result = from.withCString { source in
            to.withCString { destination in
                renameatx_np(directoryFD, source, directoryFD, destination,
                             UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw GamePortableSourceOfferError.destinationExists
            }
            throw GamePortableSourceOfferError.io("publish source offer")
        }
    }

    static func unlink(directoryFD: Int32, name: String) {
        _ = name.withCString { unlinkat(directoryFD, $0, 0) }
    }
}
