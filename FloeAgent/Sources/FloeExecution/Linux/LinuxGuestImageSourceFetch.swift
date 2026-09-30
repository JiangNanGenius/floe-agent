// FloeExecution — ordered primary→mirror fetch of one pinned image archive.
//
// The contract is deliberately narrow and fail-closed:
//
//  1. The trust-bearing primary (GitHub Releases) is always contacted first.
//  2. A mirror is contacted *only* when the primary (or every earlier mirror)
//     fails with a bounded availability error (`LinuxGuestImageTransferError
//     .allowsNextSource`): a connectivity loss or a 5xx/408/429 answer.
//  3. A definite answer (4xx), an invalid response, a local rejection, a
//     cancellation, an unclassified error, or anything content-shaped never
//     switches sources.
//  4. A mirror serves the archive DIRECTLY at its `archiveURL` by default.
//     When a shard manifest URL is additionally pinned, a bounded
//     availability failure of the direct request reconstructs the same bytes
//     from the manifest's verified piece set instead. The shard manifest is
//     re-validated against the pinned image id and archive digest before any
//     piece is fetched.
//  5. However the bytes arrive, they go through the same immutable
//     whole-archive SHA-512 verification (`importArchive`) as the primary.
//
// This file performs no downloads itself; the app supplies the downloader.

import Foundation
import FloeCore

enum LinuxGuestImageSourceFetch {
    /// Bounded size of a shard manifest: a manifest for this catalog is a few
    /// kilobytes, so anything above 1 MiB is not the pinned asset.
    static let maxManifestBytes: Int64 = 1 * 1024 * 1024

    static func fetch(
        image trusted: LinuxGuestTrustedImage,
        to stagingArchive: URL,
        maxBytes: Int64,
        downloader: any LinuxGuestImageDownloading,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws {
        try checkCancelled(isCancelled)
        // 1 — primary first, always.
        do {
            try await downloader.download(
                trusted.archiveURL,
                to: stagingArchive,
                maxBytes: maxBytes,
                onProgress: onProgress
            )
            return
        } catch let error {
            guard error.allowsNextSource, !trusted.mirrors.isEmpty else {
                throw installError(for: error)
            }
            FloeLogger(category: .tools).info(
                "primary image source unavailable, trying \(trusted.mirrors.count) mirror(s): \(error.errorDescription ?? "?")"
            )
        }

        // 2 — mirrors in declared order.
        for mirror in trusted.mirrors {
            try checkCancelled(isCancelled)
            do {
                try await fetchMirror(
                    mirror,
                    image: trusted,
                    to: stagingArchive,
                    maxBytes: maxBytes,
                    downloader: downloader,
                    onProgress: onProgress,
                    isCancelled: isCancelled
                )
                return
            } catch let error where error.allowsNextSource {
                FloeLogger(category: .tools).info(
                    "image mirror unavailable, \(error.errorDescription ?? "?")"
                )
                continue
            } catch let error {
                throw installError(for: error)
            }
        }
        throw LinuxGuestImageInstallError.downloadFailed(
            "the primary source and every mirror were unavailable"
        )
    }

    private static func checkCancelled(
        _ isCancelled: (@Sendable () -> Bool)?
    ) throws(LinuxGuestImageTransferError) {
        if Task.isCancelled || isCancelled?() == true {
            throw .cancelled
        }
    }

    private static func fetchMirror(
        _ mirror: LinuxGuestImageMirror,
        image trusted: LinuxGuestTrustedImage,
        to stagingArchive: URL,
        maxBytes: Int64,
        downloader: any LinuxGuestImageDownloading,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        isCancelled: (@Sendable () -> Bool)?
    ) async throws(LinuxGuestImageTransferError) {
        // 1 — direct whole-archive request first.
        try checkCancelled(isCancelled)
        do {
            try await downloader.download(
                mirror.archiveURL,
                to: stagingArchive,
                maxBytes: maxBytes,
                onProgress: onProgress
            )
            return
        } catch let error where error.allowsNextSource {
            guard let shardManifestURL = mirror.shardManifestURL else {
                // No piece set pinned for this mirror: let the outer loop
                // decide whether another mirror may be contacted.
                throw error
            }
            FloeLogger(category: .tools).info(
                "mirror direct archive unavailable, reconstructing from pinned pieces: \(error.errorDescription ?? "?")"
            )
            // 2 — verified reconstruction from the pinned piece set.
            try await fetchShardedMirror(
                shardManifestURL: shardManifestURL,
                image: trusted,
                to: stagingArchive,
                maxBytes: maxBytes,
                downloader: downloader,
                onProgress: onProgress,
                isCancelled: isCancelled
            )
        }
    }

    private static func fetchShardedMirror(
        shardManifestURL: URL,
        image trusted: LinuxGuestTrustedImage,
        to stagingArchive: URL,
        maxBytes: Int64,
        downloader: any LinuxGuestImageDownloading,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        isCancelled: (@Sendable () -> Bool)?
    ) async throws(LinuxGuestImageTransferError) {
        // Download the manifest beside the release assets.
        try checkCancelled(isCancelled)
        let manifestFile = stagingArchive.deletingLastPathComponent()
            .appendingPathComponent(".shards-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestFile) }
        try await downloader.download(
            shardManifestURL,
            to: manifestFile,
            maxBytes: maxManifestBytes,
            onProgress: { _, _ in }
        )
        try checkCancelled(isCancelled)

        let data: Data
        do {
            data = try Data(contentsOf: manifestFile)
        } catch {
            throw .responseInvalid(detail: "cannot read the shard manifest: \(error.localizedDescription)")
        }
        let manifest: LinuxGuestImageShardManifest
        do {
            manifest = try JSONDecoder().decode(LinuxGuestImageShardManifest.self, from: data)
        } catch {
            throw .responseInvalid(detail: "shard manifest is not valid JSON: \(error.localizedDescription)")
        }
        // Fail closed unless the manifest describes exactly the pinned image.
        if let failure = manifest.validationFailure(imageID: trusted.id, archiveSHA512: trusted.archiveSHA512) {
            throw .responseInvalid(detail: failure)
        }
        // The archive the manifest claims must also fit this build's import cap.
        guard Int64(manifest.archiveBytes) <= maxBytes else {
            throw .localRejection(detail: "the mirrored archive (\(manifest.archiveBytes) bytes) exceeds the \(maxBytes) byte import limit")
        }

        let baseURL = shardManifestURL.deletingLastPathComponent()
        // Package-owned reconstruction: pieces are fetched through the plain
        // download seam, individually verified, and the assembled archive is
        // re-checked against the pinned SHA-512; verified pieces survive an
        // availability failure so a retry resumes.
        try checkCancelled(isCancelled)
        try await LinuxGuestImageShardFetch.fetch(
            downloader: downloader,
            baseURL: baseURL,
            manifest: manifest,
            to: stagingArchive,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
    }

    /// Maps a non-fallback transfer failure to the install error the rest of
    /// the service already classifies. Cancellation stays cancellation;
    /// everything else is a bounded download failure.
    private static func installError(
        for error: LinuxGuestImageTransferError
    ) -> LinuxGuestImageInstallError {
        switch error {
        case .cancelled:
            return .cancelled
        default:
            return .downloadFailed(error.errorDescription ?? "image transfer failed")
        }
    }
}
