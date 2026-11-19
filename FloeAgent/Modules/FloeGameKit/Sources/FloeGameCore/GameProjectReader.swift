// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An in-process optimization hint, never an authorization or persisted
/// project revision. A cached digest is reusable only while the same regular
/// file is reopened beneath the captured root with unchanged metadata.
public struct GameFileFingerprint: Equatable, Sendable {
    public let bytes: Int
    public let sha256: String
    let device: UInt64
    fileprivate let inode: UInt64
    fileprivate let mode: UInt32
    public var executable: Bool { mode & UInt32(S_IXUSR | S_IXGRP | S_IXOTH) != 0 }
    fileprivate let modifiedSeconds: Int64
    fileprivate let modifiedNanoseconds: Int64
    fileprivate let changedSeconds: Int64
    fileprivate let changedNanoseconds: Int64

    fileprivate init(bytes: Int, sha256: String, info: stat) {
        self.bytes = bytes; self.sha256 = sha256
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(truncatingIfNeeded: info.st_ino)
        mode = UInt32(truncatingIfNeeded: info.st_mode)
        #if canImport(Darwin)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(info.st_mtim.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        changedSeconds = Int64(info.st_ctim.tv_sec)
        changedNanoseconds = Int64(info.st_ctim.tv_nsec)
        #endif
    }

    fileprivate func matches(_ info: stat) -> Bool {
        info.st_size >= 0 && info.st_size == bytes && self == .init(bytes: bytes, sha256: sha256, info: info)
    }
}

/// Bounded read-only probe. Descriptor-relative opens refuse symlinks at every
/// component, including a manifest replaced after the initial directory listing.
/// The host still owns sandbox grants and its original-file lifecycle lease.
public final class GameProjectReader {
    /// Administrative files remain in original imports/history, but are not
    /// game runtime resources. Callers opt in; ordinary archive reads stay whole.
    public static let versionControlNames: Set<String> = [".git", ".hg", ".svn"]
    /// Hard ceiling for every bounded scanner/prefix helper. Engine projects
    /// still use their own, smaller limits; this is never a manifest-size grant.
    public static let maximumScannableBytes = 64 * 1_024 * 1_024
    public let rootURL: URL
    private let rootFD: Int32
    private let maximumFileBytes: Int

    public init(rootURL: URL, maximumFileBytes: Int) throws {
        guard rootURL.isFileURL, maximumFileBytes > 0 else { throw GameProjectError.rootUnavailable }
        let canonical = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GameProjectError.rootUnavailable }
        self.rootURL = canonical
        self.rootFD = descriptor
        self.maximumFileBytes = maximumFileBytes
    }

    /// Opens a nested project root relative to an already validated parent
    /// descriptor. Each component is opened with O_NOFOLLOW|O_DIRECTORY, so a
    /// symlink or traversal swapped in after a directory walk cannot escape the
    /// captured root. `rootURL` is descriptive only; access always uses this FD.
    init(parent: GameProjectReader, relativePath: GameRelativePath,
         maximumFileBytes: Int) throws {
        guard maximumFileBytes > 0 else { throw GameProjectError.invalidContext }
        var descriptor = dup(parent.rootFD)
        guard descriptor >= 0 else { throw GameProjectError.rootUnavailable }
        for component in relativePath.value.split(separator: "/") {
            let next = openat(descriptor, String(component),
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let code = errno
                close(descriptor)
                if code == ENOENT { throw GameProjectError.rootUnavailable }
                if code == ELOOP || code == ENOTDIR {
                    throw GameProjectError.unsafePath(relativePath.value)
                }
                throw GameProjectError.unreadableFile(relativePath.value)
            }
            close(descriptor)
            descriptor = next
        }
        self.rootURL = parent.rootURL.appendingPathComponent(relativePath.value,
                                                             isDirectory: true)
        self.rootFD = descriptor
        self.maximumFileBytes = maximumFileBytes
    }

    deinit { close(rootFD) }

    /// Only regular files on this same local APFS device qualify for import
    /// revalidation by identity and nanosecond change time.
    var localAPFSDevice: UInt64? {
        #if canImport(Darwin)
        var volume = statfs()
        var root = stat()
        guard fstatfs(rootFD, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              fstat(rootFD, &root) == 0 else { return nil }
        let isAPFS = withUnsafeBytes(of: &volume.f_fstypename) {
            $0.prefix(while: { $0 != 0 }).elementsEqual("apfs".utf8)
        }
        return isAPFS ? UInt64(truncatingIfNeeded: root.st_dev) : nil
        #else
        return nil
        #endif
    }

    /// Includes empty directories. No symlink, device, socket or FIFO is imported.
    public func tree(maximumEntries: Int, maximumDepth: Int = 32, excludingNames: Set<String> = []) throws -> [(path: GameRelativePath, directory: Bool)] {
        var result: [(path: GameRelativePath, directory: Bool)] = []
        func walk(_ parent: Int32, prefix: String, depth: Int) throws {
            guard depth <= maximumDepth else { throw GameProjectError.limitExceeded("treeDepth") }
            let descriptor = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw GameProjectError.rootUnavailable }
            guard let stream = fdopendir(descriptor) else { close(descriptor); throw GameProjectError.rootUnavailable }
            defer { closedir(stream) }
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw GameProjectError.rootUnavailable }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." || excludingNames.contains(name.lowercased()) { continue }
                let path = try GameRelativePath(prefix + name)
                guard result.count < maximumEntries else { throw GameProjectError.limitExceeded("treeEntries") }
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw GameProjectError.unreadableFile(path.value)
                }
                let type = info.st_mode & S_IFMT
                guard type == S_IFREG || type == S_IFDIR else { throw GameProjectError.unsafePath(path.value) }
                result.append((path, type == S_IFDIR))
                if type == S_IFDIR {
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw GameProjectError.unsafePath(path.value) }
                    defer { close(child) }
                    try walk(child, prefix: path.value + "/", depth: depth + 1)
                }
            }
        }
        try walk(rootFD, prefix: "", depth: 0)
        return result.sorted { $0.path.value < $1.path.value }
    }

    func rootNames(maximum: Int) throws -> [String] {
        let descriptor = dup(rootFD)
        guard descriptor >= 0 else { throw GameProjectError.rootUnavailable }
        guard let directory = fdopendir(descriptor) else {
            close(descriptor)
            throw GameProjectError.rootUnavailable
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw GameProjectError.rootUnavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximum else { throw GameProjectError.limitExceeded("rootEntries") }
            names.append(name)
        }
        return names.sorted()
    }

    public func read(_ path: GameRelativePath, honorCancellation: Bool = true) throws -> Data? {
        try read(path, limit: maximumFileBytes, honorCancellation: honorCancellation)
    }

    /// Fingerprint and optionally copy a regular file in bounded chunks. The
    /// descriptor walk retains the same no-symlink rules as ordinary reads.
    public func fingerprint(_ path: GameRelativePath, honorCancellation: Bool = true,
                            writeChunk: ((Data) throws -> Void)? = nil) throws -> (bytes: Int, sha256: String)? {
        guard let result = try fingerprintWithIdentity(path, honorCancellation: honorCancellation,
                                                       writeChunk: writeChunk) else { return nil }
        return (result.bytes, result.sha256)
    }

    /// Reuses a digest only after opening the same file under the same root and
    /// confirming its file identity and nanosecond change metadata. Copying a
    /// file always reads its actual bytes, even when a cache hint is supplied.
    public func fingerprintWithIdentity(_ path: GameRelativePath,
                                        cached: GameFileFingerprint? = nil,
                                        honorCancellation: Bool = true,
                                        writeChunk: ((Data) throws -> Void)? = nil) throws -> GameFileFingerprint? {
        guard let descriptor = try openRelative(path, directory: false) else { return nil }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw GameProjectError.unsafePath(path.value)
        }
        guard before.st_size >= 0, before.st_size <= off_t(maximumFileBytes) else {
            throw GameProjectError.limitExceeded(path.value)
        }
        if honorCancellation { try Task.checkCancellation() }
        if writeChunk == nil, let cached, cached.matches(before) {
            try verifyFingerprintPath(path, expected: cached)
            return cached
        }
        var result = try hashFile(descriptor, info: before, path: path,
                                  honorCancellation: honorCancellation, writeChunk: writeChunk)
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw GameProjectError.corruptStorage }
        if !result.matches(after) {
            // A provider can finish setting timestamps while the bytes are in
            // transit. Re-read the same descriptor once, without writing a
            // second copy, and require a stable byte-for-byte matching digest.
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_mode == after.st_mode, before.st_size == after.st_size,
                  lseek(descriptor, 0, SEEK_SET) == 0 else { throw GameProjectError.corruptStorage }
            let checked = try hashFile(descriptor, info: after, path: path,
                                       honorCancellation: honorCancellation, writeChunk: nil)
            guard result.sha256 == checked.sha256, fstat(descriptor, &after) == 0,
                  checked.matches(after) else { throw GameProjectError.corruptStorage }
            result = checked
        }
        try verifyFingerprintPath(path, expected: result)
        return result
    }

    private func hashFile(_ descriptor: Int32, info: stat, path: GameRelativePath,
                          honorCancellation: Bool, writeChunk: ((Data) throws -> Void)?) throws -> GameFileFingerprint {
        var hash = SHA256(), total = 0
        var buffer = [UInt8](repeating: 0, count: max(1, min(1_048_576, Int(info.st_size))))
        while true {
            if honorCancellation { try Task.checkCancellation() }
            let count = buffer.withUnsafeMutableBytes { systemRead(descriptor, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw GameProjectError.unreadableFile(path.value) }
            if count == 0 { break }
            guard total <= maximumFileBytes - count else { throw GameProjectError.limitExceeded(path.value) }
            let chunk = Data(buffer.prefix(count))
            hash.update(data: chunk)
            try writeChunk?(chunk)
            total += count
        }
        guard total == info.st_size else { throw GameProjectError.corruptStorage }
        return GameFileFingerprint(bytes: total, sha256: GameDigest.hex(hash.finalize()), info: info)
    }

    private func verifyFingerprintPath(_ path: GameRelativePath, expected: GameFileFingerprint) throws {
        guard let current = try openRelative(path, directory: false) else { throw GameProjectError.unreadableFile(path.value) }
        defer { close(current) }
        var info = stat()
        guard fstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              expected.matches(info) else { throw GameProjectError.corruptStorage }
    }

    /// Engine-project readers pass their own bounded allowance without raising
    /// the general manifest limit. The hard ceiling still applies.
    public func read(_ path: GameRelativePath, maximumBytes: Int,
                     honorCancellation: Bool = true) throws -> Data? {
        guard maximumBytes > 0, maximumBytes <= Self.maximumScannableBytes else {
            throw GameProjectError.invalidContext
        }
        return try read(path, limit: maximumBytes, honorCancellation: honorCancellation)
    }

    private func read(_ path: GameRelativePath, limit: Int,
                      honorCancellation: Bool) throws -> Data? {
        guard let descriptor = try openRelative(path, directory: false) else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GameProjectError.unsafePath(path.value)
        }
        guard info.st_size >= 0, info.st_size <= off_t(limit) else {
            throw GameProjectError.limitExceeded(path.value)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(32_768, limit))
        while true {
            if honorCancellation { try Task.checkCancellation() }
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(descriptor, bytes.baseAddress!, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw GameProjectError.unreadableFile(path.value) }
            if count == 0 { return result }
            guard result.count <= limit - count else {
                throw GameProjectError.limitExceeded(path.value)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    /// Bounded, descriptor-relative directory listing used for standard layout
    /// checks such as Ren'Py `game/*.rpy` and microStudio `ms/*.ms`.
    func names(in directory: GameRelativePath, maximum: Int) throws -> [String] {
        guard (1...100_000).contains(maximum) else { throw GameProjectError.invalidContext }
        guard let descriptor = try openRelative(directory, directory: true) else { return [] }
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            throw GameProjectError.unreadableFile(directory.value)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw GameProjectError.unreadableFile(directory.value) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximum else {
                throw GameProjectError.limitExceeded("directoryEntries")
            }
            names.append(name)
        }
        return names.sorted()
    }

    /// Size of a regular file without reading it. Nil means the path is absent.
    func fileSize(_ path: GameRelativePath) throws -> Int? {
        guard let descriptor = try openRelative(path, directory: false) else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GameProjectError.unsafePath(path.value)
        }
        guard info.st_size >= 0 else { throw GameProjectError.unreadableFile(path.value) }
        guard info.st_size <= off_t(Int.max) else { return Int.max }
        return Int(info.st_size)
    }

    /// Reads only the requested prefix. A larger file is truncated at the
    /// caller's bound; the file is never loaded whole into memory.
    func readPrefix(_ path: GameRelativePath, maximumBytes: Int,
                    honorCancellation: Bool = true) throws -> Data? {
        guard maximumBytes > 0, maximumBytes <= Self.maximumScannableBytes else {
            throw GameProjectError.invalidContext
        }
        guard let descriptor = try openRelative(path, directory: false) else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GameProjectError.unsafePath(path.value)
        }
        guard info.st_size >= 0 else { throw GameProjectError.unreadableFile(path.value) }
        let limit = min(maximumBytes, info.st_size <= off_t(Int.max) ? Int(info.st_size) : maximumBytes)
        var result = Data()
        result.reserveCapacity(min(limit, 1_024 * 1_024))
        var remaining = limit
        var buffer = [UInt8](repeating: 0, count: min(32_768, max(1, limit)))
        while remaining > 0 {
            if honorCancellation { try Task.checkCancellation() }
            let want = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(descriptor, bytes.baseAddress!, want)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
            remaining -= count
        }
        return result
    }

    /// Streaming ASCII token search. It keeps only one chunk plus token overlap
    /// in memory, checks cancellation per chunk and never follows a symlink.
    func findASCII(_ needle: String, in path: GameRelativePath,
                   maximumBytes: Int, chunkSize: Int = 65_536,
                   honorCancellation: Bool = true) throws -> Int? {
        let token = Array(needle.utf8)
        guard !token.isEmpty, chunkSize >= token.count, chunkSize <= 1_024 * 1_024,
              maximumBytes > 0, maximumBytes <= Self.maximumScannableBytes else {
            throw GameProjectError.invalidContext
        }
        guard let descriptor = try openRelative(path, directory: false) else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GameProjectError.unsafePath(path.value)
        }
        guard info.st_size >= 0 else { throw GameProjectError.unreadableFile(path.value) }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var overlap: [UInt8] = []
        var scanned = 0
        while scanned < maximumBytes {
            if honorCancellation { try Task.checkCancellation() }
            let want = min(chunkSize, maximumBytes - scanned)
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(descriptor, bytes.baseAddress!, want)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw GameProjectError.unreadableFile(path.value) }
            if count == 0 { return nil }
            var window = overlap
            window.append(contentsOf: buffer.prefix(count))
            if let index = Self.indexOf(token, in: window) {
                return scanned - overlap.count + index
            }
            let keep = min(token.count - 1, window.count)
            overlap = Array(window.suffix(keep))
            scanned += count
        }
        return nil
    }

    /// Streaming search for any of several ASCII tokens in one pass. Used by
    /// bounded native-JSON detection when a supported key appears after a large
    /// prelude; only one chunk plus overlap is retained in memory.
    func findAnyASCII(_ needles: [String], in path: GameRelativePath,
                      maximumBytes: Int, chunkSize: Int = 65_536,
                      honorCancellation: Bool = true) throws -> String? {
        let tokens = needles.map { (Array($0.utf8), $0) }.filter { !$0.0.isEmpty }
        let maximumToken = tokens.map { $0.0.count }.max() ?? 0
        guard !tokens.isEmpty, chunkSize >= maximumToken, chunkSize <= 1_024 * 1_024,
              maximumBytes > 0, maximumBytes <= Self.maximumScannableBytes else {
            throw GameProjectError.invalidContext
        }
        guard let descriptor = try openRelative(path, directory: false) else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GameProjectError.unsafePath(path.value)
        }
        guard info.st_size >= 0 else { throw GameProjectError.unreadableFile(path.value) }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var overlap: [UInt8] = []
        var scanned = 0
        while scanned < maximumBytes {
            if honorCancellation { try Task.checkCancellation() }
            let want = min(chunkSize, maximumBytes - scanned)
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(descriptor, bytes.baseAddress!, want)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw GameProjectError.unreadableFile(path.value) }
            if count == 0 { return nil }
            var window = overlap
            window.append(contentsOf: buffer.prefix(count))
            for (token, original) in tokens where Self.indexOf(token, in: window) != nil {
                return original
            }
            let keep = min(maximumToken - 1, window.count)
            overlap = Array(window.suffix(keep))
            scanned += count
        }
        return nil
    }

    /// Reads a small descriptor-relative window at a known byte offset. This is
    /// used to inspect tag attributes after a streaming token search.
    func readSnippet(_ path: GameRelativePath, offset: Int, length: Int,
                     honorCancellation: Bool = true) throws -> Data? {
        guard offset >= 0, length > 0, length <= 1_024 * 1_024,
              offset <= Int.max - length else {
            throw GameProjectError.invalidContext
        }
        guard let descriptor = try openRelative(path, directory: false) else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GameProjectError.unsafePath(path.value)
        }
        guard info.st_size >= 0, info.st_size > off_t(offset) else { return Data() }
        let delta = info.st_size - off_t(offset)
        guard delta <= off_t(Int.max) else { return Data() }
        let available = min(length, Int(delta))
        var result = Data()
        result.reserveCapacity(available)
        var buffer = [UInt8](repeating: 0, count: min(32_768, max(1, available)))
        var position = offset
        var remaining = available
        while remaining > 0 {
            if honorCancellation { try Task.checkCancellation() }
            let want = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemPread(descriptor, bytes.baseAddress!, want, off_t(position))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
            position += count
            remaining -= count
        }
        return result
    }

    private static func indexOf(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        for start in 0...last {
            var matches = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matches = false
                break
            }
            if matches { return start }
        }
        return nil
    }

    func exists(_ path: GameRelativePath, directory: Bool = false) throws -> Bool {
        guard let descriptor = try openRelative(path, directory: directory) else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else {
            throw GameProjectError.unsafePath(path.value)
        }
        return true
    }

    public func isExecutable(_ path: GameRelativePath) throws -> Bool {
        guard let descriptor = try openRelative(path, directory: false) else { throw GameProjectError.unreadableFile(path.value) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw GameProjectError.unsafePath(path.value) }
        return info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
    }

    private func openRelative(_ path: GameRelativePath, directory: Bool) throws -> Int32? {
        var parent = dup(rootFD)
        guard parent >= 0 else { throw GameProjectError.rootUnavailable }
        defer { if parent >= 0 { close(parent) } }
        let components = path.value.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let needsDirectory = directory || index < components.count - 1
            // O_NONBLOCK prevents an imported FIFO from hanging a metadata probe.
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (needsDirectory ? O_DIRECTORY : 0)
            let next = openat(parent, component, flags)
            guard next >= 0 else {
                if errno == ENOENT { return nil }
                if errno == ELOOP || errno == ENOTDIR { throw GameProjectError.unsafePath(path.value) }
                throw GameProjectError.unreadableFile(path.value)
            }
            close(parent)
            parent = next
        }
        let result = parent
        parent = -1
        return result
    }
}

private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
#else
    Glibc.read(descriptor, buffer, count)
#endif
}

private func systemPread(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer,
                         _ count: Int, _ offset: off_t) -> Int {
#if canImport(Darwin)
    Darwin.pread(descriptor, buffer, count, offset)
#else
    Glibc.pread(descriptor, buffer, count, offset)
#endif
}
