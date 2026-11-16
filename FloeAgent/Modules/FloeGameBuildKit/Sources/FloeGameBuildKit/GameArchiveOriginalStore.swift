// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct GameArchiveOriginal: Equatable, Sendable {
    public let sha256: String
    public let bytes: Int
    public let url: URL
}

/// Immutable, content-addressed preservation of the exact original archive
/// bytes handed to the exchange. Deduplicates by digest, stages + exclusively
/// renames, and reads back with digest verification before reporting success.
public actor GameArchiveOriginalStore {
    public let directory: URL
    /// Bounded acceptance for preserved originals (applies to every caller).
    public let maximumOriginalBytes: Int

    public init(directory: URL, maximumOriginalBytes: Int = Int.max) throws {
        guard directory.isFileURL, maximumOriginalBytes > 0 else {
            throw GameArchiveError.invalidTarget
        }
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumOriginalBytes = maximumOriginalBytes
        try GameBuildFileSupport.makeDirectory(self.directory)
    }

    public func contains(sha256: String) -> Bool {
        guard let url = try? objectURL(sha256) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func preserve(_ bytes: Data) throws -> GameArchiveOriginal {
        guard bytes.count <= maximumOriginalBytes else {
            throw GameArchiveError.limitExceeded("originalArchiveBytes")
        }
        let digest = GameDigest.sha256(bytes)
        let target = try objectURL(digest)
        return try GameBuildFileSupport.locked(root: directory, name: ".original-store.lock") {
            if FileManager.default.fileExists(atPath: target.path) {
                let existing = try GameBuildFileSupport.readVerified(target, expected: digest)
                return .init(sha256: digest, bytes: existing.count, url: target)
            }
            try GameBuildFileSupport.publish(bytes, to: target)
            let saved = try GameBuildFileSupport.readVerified(target, expected: digest)
            return .init(sha256: digest, bytes: saved.count, url: target)
        }
    }

    /// Preserve a selected archive with bounded memory and exclusive publication.
    public func preserve(file source: URL) throws -> GameArchiveOriginal {
        let stage = directory.appendingPathComponent(".original-" + UUID().uuidString)
        let descriptor = open(stage.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor < 0 && errno == ENOSPC { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        guard descriptor >= 0 else { throw GameArchiveError.io("stage original") }
        defer { close(descriptor); unlink(stage.path) }
        let result = try GameBuildFileSupport.fingerprint(source, maximum: maximumOriginalBytes) { chunk in
            try chunk.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let n = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 && errno == ENOSPC { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
                    guard n > 0 else { throw GameArchiveError.io("write original") }
                    offset += n
                }
            }
        }
        let flushed = fsync(descriptor)
        if flushed != 0 && errno == ENOSPC { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        guard flushed == 0 else { throw GameArchiveError.io("flush original") }
        let target = try objectURL(result.digest)
        return try GameBuildFileSupport.locked(root: directory, name: ".original-store.lock") {
            if !FileManager.default.fileExists(atPath: target.path) {
                try GameBuildFileSupport.publishFile(from: stage, to: target)
            }
            let saved = try GameBuildFileSupport.fingerprint(target, maximum: maximumOriginalBytes)
            guard saved.digest == result.digest, saved.bytes == result.bytes else {
                throw GameArchiveError.checksumMismatch(target.lastPathComponent)
            }
            return .init(sha256: result.digest, bytes: result.bytes, url: target)
        }
    }

    public func read(sha256: String) throws -> Data {
        try GameBuildFileSupport.readVerified(try objectURL(sha256), expected: sha256,
                                              maximum: min(maximumOriginalBytes, 64 * 1_024 * 1_024))
    }

    private func objectURL(_ digest: String) throws -> URL {
        // Public callers may pass arbitrary strings; only a canonical
        // 64-character lowercase hex digest may become a path component.
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GameArchiveError.unsafeEntryPath(digest)
        }
        return directory.appendingPathComponent(digest + ".zip")
    }
}

extension GameBuildFileSupport {
    static func readVerified(_ url: URL, expected digest: String, maximum: Int = 512 * 1_024 * 1_024) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else {
            throw GameArchiveError.io("read original")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard GameDigest.sha256(data) == digest else { throw GameArchiveError.checksumMismatch(url.lastPathComponent) }
        return data
    }
}
