// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin

public enum GameDigest {
    public static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static let digits = Array("0123456789abcdef".utf8)

    static func hex(_ digest: SHA256.Digest) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Same flock + staged fsync/rename pattern as the existing Diagram repository.
/// This small independent file implementation is for component hosts. Production
/// adapters still own File Provider coordination, grants and lifecycle leases.
enum GameFileStorage {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw GameProjectError.unsafePath(url.lastPathComponent) }
    }

    static func locked<T>(root: URL, name: String, _ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(root.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GameProjectError.io("open lock") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw GameProjectError.corruptStorage }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw GameProjectError.io("lock") }
            try Task.checkCancellation()
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try body()
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".game-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GameProjectError.io("stage output") }
        var isOpen = true
        defer { if isOpen { Darwin.close(descriptor) }; unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw GameProjectError.io("write output") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw GameProjectError.io("flush output") }
        Darwin.close(descriptor); isOpen = false
        try Task.checkCancellation()
        guard rename(temporary.path, url.path) == 0 else { throw GameProjectError.io("replace output") }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if parent >= 0 { _ = fsync(parent); Darwin.close(parent) }
    }

    static func read(_ url: URL, maximum: Int, honorCancellation: Bool = true) throws -> Data {
        let reader = try GameProjectReader(rootURL: url.deletingLastPathComponent(), maximumFileBytes: maximum)
        guard let result = try reader.read(GameRelativePath(url.lastPathComponent), honorCancellation: honorCancellation) else { throw GameProjectError.corruptStorage }
        return result
    }
}
