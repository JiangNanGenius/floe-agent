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

    public init(directory: URL, maximumOriginalBytes: Int = 512 * 1_024 * 1_024) throws {
        guard directory.isFileURL, maximumOriginalBytes > 0,
              maximumOriginalBytes <= 1_024 * 1_024 * 1_024 else {
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

    public func read(sha256: String) throws -> Data {
        try GameBuildFileSupport.readVerified(try objectURL(sha256), expected: sha256,
                                              maximum: maximumOriginalBytes)
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
