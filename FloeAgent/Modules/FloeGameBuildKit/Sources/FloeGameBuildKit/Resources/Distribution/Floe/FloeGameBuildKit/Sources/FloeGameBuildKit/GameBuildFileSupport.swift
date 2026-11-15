// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Internal file primitives mirroring the reviewed FloeGameCore storage
/// patterns (flock + staged fsync/rename, descriptor-relative traversal that
/// refuses symlinks). FloeGameCore's own helpers are not public, so this
/// module keeps an equivalent minimal implementation instead of weakening
/// the core package's API surface.
enum GameBuildFileSupport {
    enum FileKind: Equatable {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    /// `lstat`-based kind. It never follows a symbolic link, so a nested root
    /// replaced by a link is observable instead of silently resolved.
    static func kind(at url: URL) -> FileKind? {
        guard url.isFileURL else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regularFile
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    /// Device/inode identity of the exact path (no symlink resolution). Used to
    /// reject a root replaced after the user's selection was captured.
    static func identity(at url: URL) -> (device: UInt64, file: UInt64)? {
        guard url.isFileURL else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw GameArchiveError.io("unsafe directory: \(url.lastPathComponent)")
        }
    }

    static func locked<T>(root: URL, name: String, _ body: () throws -> T) throws -> T {
        let descriptor = systemOpen(root.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GameArchiveError.io("open lock") }
        defer { systemClose(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw GameArchiveError.io("lock is not a regular file")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw GameArchiveError.io("lock") }
            try Task.checkCancellation()
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try body()
    }

    /// Staged write + fsync + exclusive rename. Never follows symlinks and
    /// never overwrites an existing destination.
    static func publish(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".floe-build-" + UUID().uuidString)
        let descriptor = systemOpen(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GameArchiveError.io("stage output") }
        var isOpen = true
        defer { if isOpen { systemClose(descriptor) }; unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = systemWrite(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw GameArchiveError.io("write output") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw GameArchiveError.io("flush output") }
        systemClose(descriptor); isOpen = false
        try Task.checkCancellation()
        #if canImport(Darwin)
        guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, url.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw GameArchiveError.destinationExists(url.lastPathComponent) }
            throw GameArchiveError.io("publish output")
        }
        #else
        guard link(temporary.path, url.path) == 0 else {
            if errno == EEXIST { throw GameArchiveError.destinationExists(url.lastPathComponent) }
            throw GameArchiveError.io("publish output")
        }
        unlink(temporary.path)
        #endif
        let parent = systemOpen(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0)
        if parent >= 0 { _ = fsync(parent); systemClose(parent) }
    }

    /// Atomic overwrite for mutable internal records. User deliverables use the
    /// exclusive `publish` path above; records must update in place.
    static func replace(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".floe-build-" + UUID().uuidString)
        let descriptor = systemOpen(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GameArchiveError.io("stage record") }
        var isOpen = true
        defer { if isOpen { systemClose(descriptor) }; unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = systemWrite(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw GameArchiveError.io("write record") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw GameArchiveError.io("flush record") }
        systemClose(descriptor); isOpen = false
        guard rename(temporary.path, url.path) == 0 else { throw GameArchiveError.io("replace record") }
        let parent = systemOpen(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0)
        if parent >= 0 { _ = fsync(parent); systemClose(parent) }
    }

    /// Exclusive publication of a staged regular file (ZIP deliverables).
    static func publishFile(from staged: URL, to target: URL) throws {
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else {
            throw GameArchiveError.destinationExists(target.lastPathComponent)
        }
        try Task.checkCancellation()
        #if canImport(Darwin)
        guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw GameArchiveError.destinationExists(target.lastPathComponent) }
            throw GameArchiveError.io("publish archive")
        }
        #else
        guard link(staged.path, target.path) == 0 else {
            if errno == EEXIST { throw GameArchiveError.destinationExists(target.lastPathComponent) }
            throw GameArchiveError.io("publish archive")
        }
        unlink(staged.path)
        #endif
        let parent = systemOpen(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0)
        if parent >= 0 { _ = fsync(parent); systemClose(parent) }
    }

    static func stagedDirectory(near target: URL, prefix: String) throws -> (stage: URL, publish: () throws -> Void) {
        guard target.isFileURL else { throw GameArchiveError.invalidTarget }
        let parent = target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        try makeDirectory(parent)
        let stage = parent.appendingPathComponent("." + prefix + "-" + UUID().uuidString)
        try makeDirectory(stage)
        let publishClosure: () throws -> Void = {
            try Task.checkCancellation()
            #if canImport(Darwin)
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw GameArchiveError.destinationExists(target.lastPathComponent) }
                throw GameArchiveError.io("publish output")
            }
            #else
            guard link(stage.path, target.path) == 0 else {
                if errno == EEXIST { throw GameArchiveError.destinationExists(target.lastPathComponent) }
                throw GameArchiveError.io("publish output")
            }
            unlink(stage.path)
            #endif
        }
        return (stage, publishClosure)
    }
}

/// Bounded, symlink-refusing directory traversal used before ZIP export.
/// Mirrors GameProjectReader's posture; the source tree is untrusted input.
struct GameDirectoryTreeWalker {
    struct Entry: Equatable {
        let path: GameRelativePath
        let directory: Bool
        let executable: Bool
        let bytes: Int
    }

    let rootURL: URL

    init(rootURL: URL) throws {
        guard rootURL.isFileURL else { throw GameArchiveError.invalidTarget }
        let canonical = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(canonical.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw GameArchiveError.invalidTarget
        }
        self.rootURL = canonical
    }

    func walk(maximumEntries: Int, maximumDepth: Int = 32) throws -> [Entry] {
        var result: [Entry] = []
        func visit(_ prefix: String, depth: Int) throws {
            guard depth <= maximumDepth else { throw GameArchiveError.limitExceeded("treeDepth") }
            let parent = prefix.isEmpty ? rootURL : rootURL.appendingPathComponent(prefix)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
                throw GameArchiveError.io("read directory \(prefix)")
            }
            for name in names.sorted() {
                try Task.checkCancellation()
                guard result.count < maximumEntries else { throw GameArchiveError.limitExceeded("treeEntries") }
                let path = try GameRelativePath(prefix + name)
                let full = parent.appendingPathComponent(name)
                var info = stat()
                guard lstat(full.path, &info) == 0 else { throw GameArchiveError.io("stat \(path.value)") }
                let type = info.st_mode & S_IFMT
                guard type == S_IFREG || type == S_IFDIR else {
                    // No symlink, device, socket or FIFO is ever packed.
                    throw GameArchiveError.unsafeSourceEntry(path.value)
                }
                let executable = type == S_IFREG && info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
                result.append(.init(path: path, directory: type == S_IFDIR,
                                    executable: executable, bytes: type == S_IFREG ? Int(info.st_size) : 0))
                if type == S_IFDIR { try visit(path.value + "/", depth: depth + 1) }
            }
        }
        try visit("", depth: 0)
        return result.sorted { $0.path.value < $1.path.value }
    }
}

#if canImport(Darwin)
private func systemOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
    Darwin.open(path, flags, mode)
}
private func systemClose(_ descriptor: Int32) { Darwin.close(descriptor) }
private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Darwin.write(descriptor, buffer, count)
}
#else
private func systemOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
    Glibc.open(path, flags, mode)
}
private func systemClose(_ descriptor: Int32) { Glibc.close(descriptor) }
private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Glibc.write(descriptor, buffer, count)
}
#endif

