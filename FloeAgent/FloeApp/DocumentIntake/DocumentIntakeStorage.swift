// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — bounded filesystem primitives for system document intake (S5 P3).
//
// These helpers only touch app-owned directories. A provider URL is read
// through `DocumentIntakeStager`; nothing here writes, renames or deletes an
// original. Every digest read is streamed; no arbitrary document is assembled
// with `Data(contentsOf:)`.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

enum DocumentIntakeStorage {
    static let chunkBytes = 1_048_576

    // MARK: Paths

    static func isContained(_ child: URL, in root: URL) -> Bool {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalChild = child.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        return canonicalChild.hasPrefix(prefix)
    }

    static func isDirectoryNotSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    static func isRegularFileNotSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey]
        ) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && values.isAliasFile != true
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return nil
        }
        return Int64(size)
    }

    /// Removes only a path proven inside this task's owned root. Never a
    /// provider URL, never another owner's directory.
    static func removeOwned(_ url: URL, in root: URL) throws {
        guard isContained(url, in: root), url.standardizedFileURL != root.standardizedFileURL else {
            throw DocumentIntakeError.ioFailure
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Durable writes

    /// Writes `data` to a sibling temporary file, fsyncs it, renames it over
    /// `url`, then fsyncs the directory. A reader can never observe a
    /// partially written record.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw DocumentIntakeError.ioFailure }
        var descriptorOpen = true
        defer {
            if descriptorOpen { _ = Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw DocumentIntakeError.ioFailure
                }
                guard written > 0 else { throw DocumentIntakeError.ioFailure }
                offset += written
            }
        }
        if Darwin.fsync(descriptor) != 0, errno != EINVAL {
            throw DocumentIntakeError.ioFailure
        }
        _ = Darwin.close(descriptor)
        descriptorOpen = false
        guard temporary.path.withCString({ source in
            url.path.withCString { destination in
                Darwin.rename(source, destination) == 0
            }
        }) else {
            throw DocumentIntakeError.ioFailure
        }
        try syncDirectory(directory)
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw DocumentIntakeError.ioFailure }
        defer { _ = Darwin.close(descriptor) }
        if Darwin.fsync(descriptor) != 0, errno != EINVAL {
            throw DocumentIntakeError.ioFailure
        }
    }

    // MARK: Digests

    static func sha256(of url: URL, maximumBytes: Int64? = nil) throws -> (digest: String, byteCount: Int64) {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw DocumentIntakeError.ioFailure }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            total += Int64(chunk.count)
            if let maximumBytes, total > maximumBytes {
                throw DocumentIntakeError.tooLarge(maximumBytes)
            }
            hasher.update(data: chunk)
        }
        return (hex(hasher.finalize()), total)
    }

    /// Streams the staged copy and proves it still has the exact length and
    /// digest recorded while the provider scope was held. A changed or
    /// truncated copy is never handed to an importer.
    static func verifySHA256(
        at url: URL,
        expectedDigest: String,
        expectedByteCount: Int64
    ) throws -> Bool {
        let (digest, byteCount) = try sha256(of: url, maximumBytes: expectedByteCount)
        return byteCount == expectedByteCount && digest == expectedDigest
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Exclusive flood lock

/// One exclusive OS lock. `flock` is released by the kernel when the process
/// dies, so a crashed importer can never leave a permanently claimed entry.
final class DocumentIntakeFileLock: @unchecked Sendable {
    private let descriptor: Int32
    private let stateLock = NSLock()
    private var closed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { return }
        closed = true
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    deinit { close() }
}

/// A claimed intake entry. The queue actor owns the mutation; the intake
/// center reads the immutable snapshot and the payload URL.
final class DocumentIntakeClaim: @unchecked Sendable {
    let record: DocumentIntakeRecord
    let directory: URL
    let payloadURL: URL
    let token: String
    let lock: DocumentIntakeFileLock

    init(record: DocumentIntakeRecord, directory: URL, payloadURL: URL, token: String, lock: DocumentIntakeFileLock) {
        self.record = record
        self.directory = directory
        self.payloadURL = payloadURL
        self.token = token
        self.lock = lock
    }
}
#endif
