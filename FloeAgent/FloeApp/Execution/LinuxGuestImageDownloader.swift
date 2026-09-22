// FloeApp — bounded HTTPS transport for the pinned Linux guest image.
//
// The downloader is intentionally the narrowest seam: it fetches bytes under
// a hard size cap and pre-classifies failures. Everything that carries trust
// lives in FloeExecution: ordered primary→mirror selection, per-piece retries,
// piece SHA-512 verification, stable resume/assembly, the immutable whole-
// archive SHA-512 and manifest/path checks.
//
// Redirects are HTTPS-only so a pinned URL cannot be bounced to another
// scheme; only a bounded availability error lets the package coordinator
// switch from GitHub to the Gitee mirror.

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
    /// Important-usage capacity of the download volume, falling back to the
    /// coarse free-space value and then to `-1` when the volume cannot report
    /// capacity, so an unknown value never blocks a download. This mirrors the
    /// installer's own pre-write check (`LinuxGuestVolumeSpace` is internal to
    /// FloeExecution) and keeps the download stage honest about space.
    static func availableImportantBytes(for url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return capacity
        }
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
            let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return -1
    }

    func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        try await Self.stream(url: url, to: destination, maxBytes: maxBytes, onProgress: onProgress)
    }

    // MARK: internals

    /// Bounded HTTPS streaming fetch; the only place that talks to the
    /// network. Every failure is classified for the mirror decision.
    private static func stream(
        url: URL,
        to destination: URL,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        guard url.scheme?.lowercased() == "https" else {
            throw .responseInvalid(detail: "image downloads require HTTPS")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration,
            delegate: LinuxImageDownloadRedirectGuard(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        } catch is CancellationError {
            throw .cancelled
        } catch let urlError as URLError {
            throw classify(urlError, taskIsCancelled: Task.isCancelled)
        } catch {
            // Under typed throws this catch keeps the function exhaustive.
            // `session.bytes` is an untyped-throws seam: a non-URLError
            // failure cannot be proven to be availability-related, so it
            // fails closed as an invalid response rather than guessing that
            // switching to a mirror could repair it.
            throw .responseInvalid(detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw .responseInvalid(detail: "the source did not answer with HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw classify(status: http.statusCode)
        }
        let expected = http.expectedContentLength
        // Verify free space against the real asset size before writing.
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .localRejection(detail: "cannot create the download directory")
        }
        if expected > 0 {
            let required = expected + 64 * 1024 * 1024
            let available = availableImportantBytes(for: destination.deletingLastPathComponent())
            if available >= 0, available < required {
                throw .localRejection(
                    detail: LinuxGuestImageInstallError.insufficientSpace(required: required, available: available).localizedDescription
                )
            }
        }
        fileManager.createFile(atPath: destination.path, contents: nil)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            throw .localRejection(detail: "cannot open the download file")
        }
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
            throw .cancelled
        } catch let error as LinuxGuestImageTransferError {
            throw error
        } catch let urlError as URLError {
            throw classify(urlError, taskIsCancelled: Task.isCancelled)
        } catch let installError as LinuxGuestImageInstallError {
            switch installError {
            case .archiveTooLarge:
                throw .localRejection(detail: installError.localizedDescription)
            default:
                throw .responseInvalid(detail: installError.localizedDescription)
            }
        } catch {
            throw .responseInvalid(detail: error.localizedDescription)
        }
        guard written > 0 else {
            throw .responseInvalid(detail: "the archive response was empty")
        }
    }

    /// Classifies a transport-level URLError for the fallback decision.
    /// `URLError.cancelled` only becomes the caller-cancelled transfer class
    /// while the surrounding task is actually cancelled (or the shared
    /// session is being torn down because of that); an unexpected
    /// cancellation stays fail-closed and never switches mirrors.
    private static func classify(
        _ error: URLError,
        taskIsCancelled: Bool
    ) -> LinuxGuestImageTransferError {
        if error.code == .cancelled {
            return taskIsCancelled ? .cancelled : .responseInvalid(detail: error.localizedDescription)
        }
        switch error.code {
        case .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive:
            return .networkFailure(detail: error.localizedDescription)
        default:
            // A definite, non-connectivity error cannot be repaired by a mirror.
            return .responseInvalid(detail: error.localizedDescription)
        }
    }

    /// Classifies a non-2xx HTTP status for the fallback decision.
    private static func classify(status: Int) -> LinuxGuestImageTransferError {
        if status == 408 || status == 429 || (500..<600).contains(status) {
            return .serverUnavailable(status: status, detail: "HTTP \(status)")
        }
        return .responseRejected(status: status, detail: "HTTP \(status)")
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
