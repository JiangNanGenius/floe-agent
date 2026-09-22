// FloeExecution — verified reconstruction of a sharded mirror archive.
//
// A mirror whose attachment cap is below the archive size (Gitee caps single
// attachments at 100 MB) publishes the exact same pinned bytes as a manifest
// plus fixed-size pieces. This file owns the reconstruction policy:
//
//  * The staging directory is *stable*: it is derived from the image id and
//    the pinned archive SHA-512, never from a random UUID. A later retry of
//    the same pinned image therefore sees the pieces a previous attempt
//    already verified.
//  * A piece is reused only when its size and SHA-512 both match the
//    (already trusted) manifest; anything else is refetched.
//  * After a successful concatenation the staging directory is removed.
//  * Content-shaped failures (a piece digest/size mismatch, a bad piece
//    path, a failed whole-archive digest) mean the mirror bytes cannot be
//    trusted: staging is purged and the error fails closed.
//  * Pure availability failures (network, temporary server errors) and
//    cancellation keep the verified pieces so a retry resumes where it
//    stopped.
//
// The per-piece transport stays behind `LinuxGuestImageDownloading.download`,
// so this policy is fully exercisable in package tests without a network.

import Foundation
import FloeCore

enum LinuxGuestImageShardFetch {
    /// Attempts for one piece before its availability failure is reported
    /// (digest-shaped failures never retry).
    static let maxPieceAttempts = 3
    /// Pause between availability retries of one piece.
    static let retryDelayNanoseconds: UInt64 = 500_000_000

    /// Stable staging directory for one pinned image. Derived from the image
    /// id and the pinned archive digest so:
    ///   * the same pinned image always maps to the same directory (resume);
    ///   * a different image or a new pinned digest maps elsewhere, so a
    ///     newer version never reuses pieces of an older one;
    ///   * the "v1" scheme prefix lets a future layout change move to a fresh
    ///     namespace instead of colliding with stale state.
    static func stagingDirectory(root: URL, imageID: String, archiveSHA512: String) -> URL {
        let key = FloeDigest.sha256Hex(
            Data("floe-image-shards/v1|\(imageID)|\(archiveSHA512.lowercased())".utf8)
        )
        return root.appendingPathComponent(".shards-\(key.prefix(24))", isDirectory: true)
    }

    /// Reconstructs `manifest`'s archive into `destination`, reusing verified
    /// pieces from the stable staging directory and fetching the rest.
    static func fetch(
        downloader: any LinuxGuestImageDownloading,
        baseURL: URL,
        manifest: LinuxGuestImageShardManifest,
        to destination: URL,
        onProgress: @escaping @Sendable (_ received: Int64, _ expected: Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        let fileManager = FileManager.default
        let staging = stagingDirectory(
            root: destination.deletingLastPathComponent(),
            imageID: manifest.imageID,
            archiveSHA512: manifest.archiveSHA512
        )
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw .localRejection(detail: "cannot create shard staging: \(error.localizedDescription)")
        }

        do {
            try await fetchReusingVerifiedPieces(
                downloader: downloader,
                baseURL: baseURL,
                manifest: manifest,
                staging: staging,
                to: destination,
                onProgress: onProgress
            )
            // Success: the archive is reconstructed and staging is removed.
            try? fileManager.removeItem(at: staging)
        } catch let error {
            switch error {
            case .responseRejected, .responseInvalid:
                // Untrusted content must not survive: purge the pieces *and*
                // the assembled archive, then fail closed.
                try? fileManager.removeItem(at: staging)
                try? fileManager.removeItem(at: destination)
            case .networkFailure, .serverUnavailable, .localRejection, .cancelled:
                // Availability, local or caller-shaped failure: the verified
                // pieces stay so the next attempt resumes after them.
                break
            }
            throw error
        }
    }

    // MARK: internals

    private static func fetchReusingVerifiedPieces(
        downloader: any LinuxGuestImageDownloading,
        baseURL: URL,
        manifest: LinuxGuestImageShardManifest,
        staging: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (_ received: Int64, _ expected: Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        let expected = Int64(manifest.archiveBytes)

        // Drop anything the staging directory holds that this manifest does
        // not describe (e.g. leftovers from an aborted run of the same pin).
        // Recognition is by normalized *relative* path, so nested piece names
        // such as "shards/part-00.bin" keep their parent directory instead of
        // being purged as unknown top-level entries.
        purgeStaleEntries(staging: staging, wantedNames: Set(manifest.shards.map { normalizedRelativePath($0.name) }))

        var received: Int64 = 0
        for shard in manifest.shards {
            do {
                try Task.checkCancellation()
            } catch {
                throw .cancelled
            }
            guard let pieceRemote = pieceURL(baseURL: baseURL, name: shard.name) else {
                throw .responseInvalid(detail: "shard #\(shard.index) has an unusable path '\(shard.name)'")
            }
            guard let pieceFile = pieceFileURL(staging: staging, name: shard.name) else {
                throw .responseInvalid(detail: "shard #\(shard.index) escapes the staging directory")
            }
            if pieceIsVerified(pieceFile, shard: shard) {
                received += Int64(shard.bytes)
                onProgress(received, expected)
                continue
            }
            try await downloadPieceWithRetries(
                downloader: downloader,
                url: pieceRemote,
                shard: shard,
                to: pieceFile,
                receivedSoFar: received,
                expectedTotal: expected,
                onProgress: onProgress
            )
            received += Int64(shard.bytes)
        }

        try await concatenateVerifiedPieces(
            manifest: manifest,
            staging: staging,
            to: destination,
            expectedBytes: expected
        )
    }

    /// Normalizes a manifest piece name or on-disk relative path to a
    /// canonical relative form ("shards//part-00.bin" -> "shards/part-00.bin").
    private static func normalizedRelativePath(_ name: String) -> String {
        name.split(separator: "/", omittingEmptySubsequences: true).map(String.init).joined(separator: "/")
    }

    /// Removes every file whose normalized relative path is not in
    /// `wantedNames`, then prunes directories that became empty. Files that a
    /// previous attempt verified (and directories still holding them) stay.
    private static func purgeStaleEntries(staging: URL, wantedNames: Set<String>) {
        let fileManager = FileManager.default
        let base = staging.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var directories: [URL] = []
        for case let entry as URL in enumerator {
            let standardized = entry.standardizedFileURL
            guard standardized.path.hasPrefix(base.path + "/") else { continue }
            let relative = normalizedRelativePath(String(standardized.path.dropFirst(base.path.count + 1)))
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                directories.append(entry)
                continue
            }
            if !wantedNames.contains(relative) {
                try? fileManager.removeItem(at: entry)
            }
        }
        // Deepest first so children empty out before their parents are tested.
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    /// True only when the file exists with the exact pinned size and SHA-512.
    private static func pieceIsVerified(_ file: URL, shard: LinuxGuestImageShard) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = (attributes?[.size] as? NSNumber)?.int64Value, size == Int64(shard.bytes) else {
            return false
        }
        guard let actual = try? FloeDigest.sha512Hex(ofFileAt: file) else { return false }
        return actual.lowercased() == shard.sha512.lowercased()
    }

    private static func downloadPieceWithRetries(
        downloader: any LinuxGuestImageDownloading,
        url: URL,
        shard: LinuxGuestImageShard,
        to pieceFile: URL,
        receivedSoFar: Int64,
        expectedTotal: Int64,
        onProgress: @escaping @Sendable (_ received: Int64, _ expected: Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        var lastAvailabilityFailure: LinuxGuestImageTransferError?
        for attempt in 0..<maxPieceAttempts {
            if attempt > 0 {
                try? FileManager.default.removeItem(at: pieceFile)
                do {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    try Task.checkCancellation()
                } catch {
                    throw LinuxGuestImageTransferError.cancelled
                }
            }
            do {
                try await downloader.download(
                    url,
                    to: pieceFile,
                    maxBytes: Int64(shard.bytes),
                    onProgress: { pieceReceived, _ in
                        onProgress(receivedSoFar + pieceReceived, expectedTotal)
                    }
                )
            } catch let error where error.allowsNextSource {
                // Bounded availability failure: retry the piece a few times,
                // then report it (verified pieces stay for the next attempt).
                lastAvailabilityFailure = error
                continue
            } catch let error {
                // Content-shaped, local or caller-shaped: fail closed.
                throw error
            }
            guard pieceIsVerified(pieceFile, shard: shard) else {
                // A completed answer with wrong bytes cannot be repaired by
                // retrying; purge happens at the catch in `fetch`.
                throw .responseInvalid(detail: "shard #\(shard.index) failed its SHA-512 check")
            }
            return
        }
        throw lastAvailabilityFailure ?? .networkFailure(detail: "shard #\(shard.index) could not be downloaded")
    }

    /// Concatenates the verified pieces in index order, then checks the
    /// whole-archive SHA-512 pinned by the (trusted) manifest before handing
    /// the bytes to the caller's own verification.
    private static func concatenateVerifiedPieces(
        manifest: LinuxGuestImageShardManifest,
        staging: URL,
        to destination: URL,
        expectedBytes: Int64
    ) async throws(LinuxGuestImageTransferError) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .localRejection(detail: "cannot create the archive directory: \(error.localizedDescription)")
        }
        fileManager.createFile(atPath: destination.path, contents: nil)
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destination)
        } catch {
            throw .localRejection(detail: "cannot open the archive file: \(error.localizedDescription)")
        }
        defer { try? output.close() }

        var written: Int64 = 0
        for shard in manifest.shards {
            do {
                try Task.checkCancellation()
            } catch {
                throw .cancelled
            }
            guard let pieceFile = pieceFileURL(staging: staging, name: shard.name) else {
                throw .responseInvalid(detail: "shard #\(shard.index) escapes the staging directory")
            }
            do {
                let bytes = try Data(contentsOf: pieceFile)
                try output.write(contentsOf: bytes)
                written += Int64(bytes.count)
            } catch is CancellationError {
                throw .cancelled
            } catch {
                throw .localRejection(detail: "cannot assemble the archive: \(error.localizedDescription)")
            }
        }
        guard written == expectedBytes else {
            throw .responseInvalid(detail: "assembled \(written) bytes, the manifest pins \(expectedBytes)")
        }
        let actual: String
        do {
            actual = try FloeDigest.sha512Hex(ofFileAt: destination)
        } catch {
            throw .localRejection(detail: "cannot hash the assembled archive: \(error.localizedDescription)")
        }
        guard actual.lowercased() == manifest.archiveSHA512.lowercased() else {
            throw .responseInvalid(detail: "the assembled archive does not match the pinned SHA-512")
        }
    }

    /// Resolves a manifest piece name against the manifest directory URL;
    /// absolute URLs are never honored.
    private static func pieceURL(baseURL: URL, name: String) -> URL? {
        if let parsed = URL(string: name), parsed.scheme != nil { return nil }
        let resolved = baseURL.appendingPathComponent(name)
        guard resolved.scheme?.lowercased() == "https" else { return nil }
        return resolved
    }

    /// Local staging path for a piece, rejecting names that would escape the
    /// staging directory.
    private static func pieceFileURL(staging: URL, name: String) -> URL? {
        let base = staging.resolvingSymlinksInPath().standardizedFileURL
        let candidate = base.appendingPathComponent(name).standardizedFileURL
        guard candidate.path == base.path || candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}
