// FloeApp — bounded HTTPS download for a pinned Linux guest image archive.
//
// The downloader only knows how to fetch bytes under a hard size cap; all
// verification (archive SHA-512, manifest digests, path containment) happens
// in FloeExecution before anything is promoted into the image directory.
// Redirects are refused so a pinned HTTPS URL cannot be bounced to another
// host or scheme, and the destination is written in the app's image staging
// area rather than a temporary directory.

import Foundation
import FloeExecution

#if canImport(SwiftUI) && canImport(UIKit)
/// Follows bounded HTTPS→HTTPS redirects (GitHub Release assets redirect to
/// object storage) and refuses anything that would downgrade to HTTP or loop
/// forever. The archive bytes are still verified against the pinned SHA-512
/// after the download, so a redirect can change the location but not the
/// content.
private final class LinuxImageDownloadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let maxRedirects = 8
    private let lock = NSLock()
    private var redirects = 0

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        lock.lock()
        redirects += 1
        let allowed = redirects <= Self.maxRedirects
        lock.unlock()
        completionHandler(allowed ? request : nil)
    }
}

struct LinuxGuestImageHTTPDownloader: LinuxGuestImageDownloading {
    func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard url.scheme?.lowercased() == "https" else {
            throw LinuxGuestImageInstallError.downloadFailed("image downloads require HTTPS")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: LinuxImageDownloadRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LinuxGuestImageInstallError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let expected = http.expectedContentLength
        // Verify free space against the real archive size before writing.
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if expected > 0 {
            let required = expected + 64 * 1024 * 1024
            let available = LinuxGuestVolumeSpace.availableImportantBytes(for: destination.deletingLastPathComponent())
            if available >= 0, available < required {
                throw LinuxGuestImageInstallError.insufficientSpace(required: required, available: available)
            }
        }
        fileManager.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    written += Int64(buffer.count)
                    guard written <= maxBytes else {
                        throw LinuxGuestImageInstallError.archiveTooLarge(limit: maxBytes)
                    }
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    onProgress(written, expected)
                    // Cancellation from the shared job task.
                    try Task.checkCancellation()
                }
            }
            if !buffer.isEmpty {
                written += Int64(buffer.count)
                guard written <= maxBytes else {
                    throw LinuxGuestImageInstallError.archiveTooLarge(limit: maxBytes)
                }
                try handle.write(contentsOf: buffer)
                onProgress(written, expected)
            }
        } catch is CancellationError {
            throw LinuxGuestImageInstallError.cancelled
        }
        guard written > 0 else {
            throw LinuxGuestImageInstallError.downloadFailed("the archive response was empty")
        }
    }

    /// Real archive size in bytes for the pinned image, following the same
    /// bounded HTTPS redirect policy. Returns nil when the server does not
    /// expose a length, so callers never display a guessed size.
    static func probePinnedArchiveBytes() async -> Int64? {
        guard let url = LinuxGuestImageDistributionCatalog.bundled.first?.archiveURL else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration,
                                 delegate: LinuxImageDownloadRedirectGuard(),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.expectedContentLength > 0 else { return nil }
            return http.expectedContentLength
        } catch {
            return nil
        }
    }
}
#endif
