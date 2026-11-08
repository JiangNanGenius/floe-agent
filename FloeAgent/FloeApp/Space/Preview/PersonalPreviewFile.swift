// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeCore
import Darwin

/// A read-only file under a caller's already authorized root. Every component
/// is opened relative to an anchored directory FD, with no symlink following.
/// No mkdir, recovery, migration or write is performed for a preview.
nonisolated struct PersonalPreviewFile: Sendable {
    struct Identity: Hashable, Sendable {
        let device: UInt64, inode: UInt64, size: Int64
        let modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
        init(_ value: stat) {
            device = UInt64(UInt32(bitPattern: value.st_dev)); inode = UInt64(value.st_ino); size = value.st_size
            modified = Int64(value.st_mtimespec.tv_sec); modifiedNS = Int64(value.st_mtimespec.tv_nsec)
            changed = Int64(value.st_ctimespec.tv_sec); changedNS = Int64(value.st_ctimespec.tv_nsec)
        }
        var token: String { "\(device):\(inode):\(size):\(modified):\(modifiedNS):\(changed):\(changedNS)" }
    }
    let root: URL
    let url: URL
    let relativePath: String
    let identity: Identity
    let maximumBytes: Int

    init(root: URL, url: URL, maximumBytes: Int) throws {
        guard root.isFileURL, url.isFileURL, maximumBytes > 0 else { throw PersonalContentPreviewError.unavailable }
        let base = root.standardizedFileURL
        guard base.resolvingSymlinksInPath() == base else { throw PersonalContentPreviewError.unavailable }
        let target = url.standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { throw PersonalContentPreviewError.unavailable }
        let relative = String(target.path.dropFirst(base.path.count + 1))
        self.root = base; self.url = target; self.relativePath = relative; self.maximumBytes = maximumBytes
        self.identity = try Self.withFile(root: base, relative: relative) { fd in
            var info = stat(); guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw PersonalContentPreviewError.unavailable }
            guard info.st_size > 0 else { throw PersonalContentPreviewError.notPrepared }
            guard info.st_size <= maximumBytes else { throw PersonalContentPreviewError.tooLarge }
            return Identity(info)
        }
    }
    func validate() throws {
        try Self.withFile(root: root, relative: relativePath) { fd in
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Identity(info) == identity else {
                throw PersonalContentPreviewError.sourceChanged
            }
        }
    }
    func data(expectedSHA256: String? = nil,
              checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Data {
        let value = try consume(keepBytes: true, checkCancellation: checkCancellation)
        if let expectedSHA256, value.digest != expectedSHA256 { throw PersonalContentPreviewError.sourceChanged }
        return value.bytes
    }
    func verifyHash(_ expected: String?) throws {
        guard let expected else { try validate(); return }
        guard expected.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              try consume(keepBytes: false).digest == expected else { throw PersonalContentPreviewError.sourceChanged }
    }
    func sha256(checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> String {
        try consume(keepBytes: false, checkCancellation: checkCancellation).digest
    }
    private func consume(keepBytes: Bool,
                         checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> (bytes: Data, digest: String) {
        try Task.checkCancellation(); try checkCancellation()
        let result = try Self.withFile(root: root, relative: relativePath) { fd in
            var before = stat(); guard fstat(fd, &before) == 0, Identity(before) == identity else { throw PersonalContentPreviewError.sourceChanged }
            var output = Data(), hasher = SHA256(), count = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                try Task.checkCancellation(); try checkCancellation()
                let readCount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if readCount < 0, errno == EINTR { continue }
                guard readCount >= 0 else { throw PersonalContentPreviewError.unavailable }
                if readCount == 0 { break }
                count += readCount; guard count <= maximumBytes else { throw PersonalContentPreviewError.tooLarge }
                let chunk = Data(buffer.prefix(readCount)); hasher.update(data: chunk)
                if keepBytes { output.append(chunk) }
            }
            var after = stat()
            guard fstat(fd, &after) == 0, Identity(after) == identity, Int64(count) == identity.size else { throw PersonalContentPreviewError.sourceChanged }
            return (output, hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
        try validate(); try Task.checkCancellation(); try checkCancellation()
        return result
    }
    private static func withFile<T>(root: URL, relative: String, body: (Int32) throws -> T) throws -> T {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard root.resolvingSymlinksInPath() == root, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw PersonalContentPreviewError.unavailable
        }
        var directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw PersonalContentPreviewError.unavailable }
        defer { Darwin.close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw PersonalContentPreviewError.unavailable }
            Darwin.close(directory); directory = next
        }
        let fd = openat(directory, parts[parts.count - 1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PersonalContentPreviewError.unavailable }
        defer { Darwin.close(fd) }
        return try body(fd)
    }
}

/// Cancellation propagates into bounded blocking reads/hash/decoders, rather
/// than leaving an unowned detached worker after its row disappears.
nonisolated func personalPreviewOffMain<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try await NativeValuePreparation.run(operation)
}
#endif
