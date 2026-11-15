// SPDX-License-Identifier: MPL-2.0
// Standard decoding algorithms adapted from RPGMakerDecrypter, MIT:
// Copyright (c) 2016 Mikko Uuksulainen. Full original MIT in Resources/.
// Hardened streaming, staging, validation and cancellation are Floe source.
import Foundation
import Darwin
import CryptoKit
import FloeGameCore

private func nextKey(_ key: UInt32) -> UInt32 { key &* 7 &+ 3 }

private final class ArchiveReader {
    let handle: FileHandle
    let original: stat
    let size: UInt64
    var position: UInt64 = 0
    init(_ url: URL, limits: RPGDeploymentLimits) throws {
        guard url.isFileURL else { throw RPGDeploymentError.invalidArchive("non-file URL") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RPGDeploymentError.io("open archive") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 8 else {
            close(fd); throw RPGDeploymentError.invalidArchive("file/header")
        }
        guard UInt64(info.st_size) <= limits.maximumArchiveBytes else { close(fd); throw RPGDeploymentError.limitExceeded("archive bytes") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        original = info; size = UInt64(info.st_size)
    }
    func unchanged() throws {
        var current = stat()
        guard fstat(handle.fileDescriptor, &current) == 0, current.st_size == original.st_size,
              current.st_ino == original.st_ino, current.st_dev == original.st_dev,
              current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else { throw RPGDeploymentError.sourceChanged }
    }
    func seek(_ offset: UInt64) throws {
        guard offset <= size else { throw RPGDeploymentError.invalidArchive("seek beyond archive") }
        try handle.seek(toOffset: offset); position = offset
    }
    func read(_ count: Int) throws -> Data {
        guard count >= 0, UInt64(count) <= size - position else { throw RPGDeploymentError.invalidArchive("truncated archive") }
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            guard let bytes = try handle.read(upToCount: count - result.count), !bytes.isEmpty else { throw RPGDeploymentError.invalidArchive("truncated archive") }
            result.append(bytes)
        }
        position += UInt64(count)
        return result
    }
    func word() throws -> UInt32 {
        let bytes = try read(4)
        return bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
    }
}

public enum RGSSArchive {
    /// Indexes standard XP/VX v1 and Ace v3. No archive or game code executes.
    public static func inspect(at source: URL, limits: RPGDeploymentLimits = .standard) throws -> (version: Int, entries: [RPGDeploymentEntry]) {
        let reader = try ArchiveReader(source, limits: limits)
        let result = try index(reader, limits: limits)
        try reader.unchanged()
        return result
    }

    /// Writes a fresh, atomically published decoded folder. Original source
    /// stays intact. Partial decoded data remains at the diagnostic staging
    /// path on failure, and is never reported as a successful output.
    public static func extract(at source: URL, to destination: URL, limits: RPGDeploymentLimits = .standard) throws -> RPGDeploymentExtraction {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty, destination.path != "/" else {
            throw RPGDeploymentError.unsafePath("destination")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RPGDeploymentError.destinationExists }
        let reader = try ArchiveReader(source, limits: limits)
        let parsed = try index(reader, limits: limits)
        let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".rpg-deployment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var files: [RPGDeploymentFile] = []
        do {
            for entry in parsed.entries {
                try Task.checkCancellation()
                let output = stage.appendingPathComponent(entry.path.value)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw RPGDeploymentError.io("create decoded file") }
                let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try reader.seek(entry.offset)
                var remaining = entry.byteCount, key = entry.fileKey, byteIndex: UInt64 = 0
                var hash = SHA256()
                while remaining > 0 {
                    try Task.checkCancellation()
                    var data = try reader.read(Int(min(remaining, 64 * 1_024)))
                    data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                        for i in 0..<buffer.count {
                            if byteIndex > 0 && (byteIndex & 3) == 0 { key = nextKey(key) }
                            buffer[i] ^= UInt8(truncatingIfNeeded: key >> UInt32((byteIndex & 3) * 8))
                            byteIndex += 1
                        }
                    }
                    hash.update(data: data); try writer.write(contentsOf: data)
                    remaining -= UInt64(data.count)
                }
                try writer.synchronize(); try writer.close()
                files.append(.init(path: entry.path.value, byteCount: entry.byteCount,
                                   sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()))
            }
            try Task.checkCancellation(); try reader.unchanged()
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw RPGDeploymentError.destinationExists }
                throw RPGDeploymentError.io("publish decoded directory")
            }
            return .init(archiveVersion: parsed.version, output: destination, files: files, originalArchivePreserved: true)
        } catch {
            // A separate receipt makes the retained partial folder explicit.
            let failure = ["result": "failed", "staging": stage.lastPathComponent,
                           "error": String(describing: error), "sourceModified": "false"]
            if let bytes = try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]) {
                try? bytes.write(to: parent.appendingPathComponent(stage.lastPathComponent + "-failure.json"), options: .atomic)
            }
            throw error
        }
    }

    private static func index(_ reader: ArchiveReader, limits: RPGDeploymentLimits) throws -> (version: Int, entries: [RPGDeploymentEntry]) {
        let header = try reader.read(8)
        guard Array(header.prefix(7)) == [82, 71, 83, 83, 65, 68, 0] else { throw RPGDeploymentError.invalidArchive("RGSSAD header") }
        let version = Int(header[7])
        guard version == 1 || version == 3 else { throw RPGDeploymentError.unsupportedVersion(version) }
        var entries: [RPGDeploymentEntry] = [], total: UInt64 = 0
        func append(name: Data, offset: UInt64, count: UInt64, key: UInt32) throws {
            guard entries.count < limits.maximumFiles else { throw RPGDeploymentError.limitExceeded("file count") }
            guard count <= limits.maximumEntryBytes else { throw RPGDeploymentError.limitExceeded("entry bytes") }
            guard offset <= reader.size, count <= reader.size - offset else {
                throw RPGDeploymentError.invalidArchive("entry size/offset")
            }
            guard count <= limits.maximumTotalBytes - total else { throw RPGDeploymentError.limitExceeded("decoded bytes") }
            total += count
            entries.append(.init(path: try DeploymentPath.decode(name), originalNameBytes: name, byteCount: count, offset: offset, fileKey: key))
        }
        if version == 1 {
            var key: UInt32 = 0xDEADCAFE
            while reader.position < reader.size {
                try Task.checkCancellation()
                let length = try reader.word() ^ key; key = nextKey(key)
                guard length > 0, UInt64(length) <= UInt64(limits.maximumNameBytes) else { throw RPGDeploymentError.limitExceeded("file name") }
                var name = try reader.read(Int(length))
                for i in name.indices { name[i] ^= UInt8(truncatingIfNeeded: key); key = nextKey(key) }
                let count = UInt64(try reader.word() ^ key); key = nextKey(key)
                try append(name: name, offset: reader.position, count: count, key: key)
                try reader.seek(reader.position + count)
            }
        } else {
            let key = (try reader.word()) &* 9 &+ 3
            while true {
                try Task.checkCancellation()
                let offset = UInt64(try reader.word() ^ key), count = UInt64(try reader.word() ^ key)
                let fileKey = try reader.word() ^ key, length = try reader.word() ^ key
                if offset == 0 { break }
                guard length > 0, UInt64(length) <= UInt64(limits.maximumNameBytes) else { throw RPGDeploymentError.limitExceeded("file name") }
                var name = try reader.read(Int(length))
                for i in name.indices { name[i] ^= UInt8(truncatingIfNeeded: key >> UInt32((i & 3) * 8)) }
                try append(name: name, offset: offset, count: count, key: fileKey)
            }
            let tableEnd = reader.position
            var end = tableEnd
            for entry in entries.sorted(by: { $0.offset == $1.offset ? $0.byteCount < $1.byteCount : $0.offset < $1.offset }) {
                guard entry.offset >= end else { throw RPGDeploymentError.invalidArchive("overlapping entry/index") }
                end = entry.offset + entry.byteCount
            }
        }
        try DeploymentPath.validateSet(entries)
        return (version, entries)
    }
}
