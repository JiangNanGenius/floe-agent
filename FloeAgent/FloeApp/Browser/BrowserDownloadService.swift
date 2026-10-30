// FloeApp — authenticated native downloads through the task browser.
//
// WKDownload uses the exact WKWebView's website data store, so a PDF or image
// behind the page's existing login is fetched with that page's cookies without
// exposing cookie values to the model. The file is staged privately, checked
// for an allowed PDF/image signature and a byte cap, then committed through
// the existing atomic committer. Progress is visible/cancellable from the
// browser chrome, and the tool's own cancellation token cancels the transfer.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Combine
import Foundation
import SwiftUI
import WebKit
import FloeCore
import FloeTools

struct BrowserDownloadReceipt: Sendable {
    var id: UUID
    var destinationURL: URL
    var relativePath: String
    var mimeType: String
    var byteCount: Int
    var sha256: String
    var suggestedFilename: String
    var finalHost: String?
}

struct BrowserDownloadSnapshot: Identifiable, Sendable, Equatable {
    enum State: String, Sendable {
        case preparing
        case downloading
        case finishing
    }

    var id: UUID
    var displayName: String
    var state: State
    var progress: Double
    var receivedBytes: Int64
    var totalBytes: Int64
}

enum BrowserDownloadError: Error, LocalizedError {
    case anotherDownloadIsStarting
    case cancelled
    case badStatus(Int)
    case unsupportedType(String)
    case tooLarge(Int)
    case emptyFile
    case signatureMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .anotherDownloadIsStarting: "Another browser download is already starting"
        case .cancelled: "Browser download was cancelled"
        case .badStatus(let status): "Browser download returned HTTP \(status)"
        case .unsupportedType(let type): "This browser download type is not allowed: \(type)"
        case .tooLarge(let cap): "Browser download exceeds the \(cap)-byte limit"
        case .emptyFile: "Browser download produced an empty file"
        case .signatureMismatch(let expected, let actual):
            "Browser download content does not match \(expected) (detected \(actual))"
        }
    }
}

@MainActor
final class BrowserDownloadService: NSObject, ObservableObject, WKDownloadDelegate {
    @MainActor
    private final class Job {
        let id: UUID
        var displayName: String
        let destinationURL: URL
        let relativePath: String
        let stagingURL: URL
        let maxBytes: Int
        let overwrite: Bool
        var continuation: CheckedContinuation<BrowserDownloadReceipt, Error>?
        var download: WKDownload?
        var observation: NSKeyValueObservation?
        var cancelWatcher: Task<Void, Never>?
        var progress: Double = 0
        var receivedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var state: BrowserDownloadSnapshot.State = .preparing
        var responseMime: String = ""
        var finalURL: URL?
        var finished = false

        init(
            id: UUID,
            displayName: String,
            destinationURL: URL,
            relativePath: String,
            stagingURL: URL,
            maxBytes: Int,
            overwrite: Bool
        ) {
            self.id = id
            self.displayName = displayName
            self.destinationURL = destinationURL
            self.relativePath = relativePath
            self.stagingURL = stagingURL
            self.maxBytes = maxBytes
            self.overwrite = overwrite
        }
    }

    @Published private(set) var active: [BrowserDownloadSnapshot] = []

    private var jobs: [UUID: Job] = [:]
    private var byDownload: [ObjectIdentifier: UUID] = [:]
    private var startingJobID: UUID?

    func start(
        webView: WKWebView,
        request: URLRequest,
        destinationURL: URL,
        relativePath: String,
        suggestedFilename: String,
        maxBytes: Int,
        overwrite: Bool,
        cancellation: CancellationToken
    ) async throws -> BrowserDownloadReceipt {
        guard startingJobID == nil, !jobs.values.contains(where: { $0.download == nil && !$0.finished }) else {
            throw BrowserDownloadError.anotherDownloadIsStarting
        }
        try cancellation.throwIfCancelled()
        let id = UUID()
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeBrowserDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagingURL = stagingDirectory.appendingPathComponent(id.uuidString)
        let safeName = Self.safeDisplayName(suggestedFilename, fallback: destinationURL.lastPathComponent)
        let job = Job(
            id: id,
            displayName: safeName,
            destinationURL: destinationURL,
            relativePath: relativePath,
            stagingURL: stagingURL,
            maxBytes: max(1, min(maxBytes, 64 * 1_024 * 1_024)),
            overwrite: overwrite
        )
        jobs[id] = job
        startingJobID = id
        publish()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.continuation = continuation
                job.cancelWatcher = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        if cancellation.isCancelled {
                            self?.cancel(id)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                Task { @MainActor [weak self] in
                    await self?.begin(job, webView: webView, request: request)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    func cancel(_ id: UUID) {
        guard let job = jobs[id], !job.finished else { return }
        job.finished = true
        job.download?.cancel { _ in }
        complete(job, result: .failure(BrowserDownloadError.cancelled))
    }

    func cancelAll() {
        for id in Array(jobs.keys) { cancel(id) }
    }

    private func begin(_ job: Job, webView: WKWebView, request: URLRequest) async {
        guard !job.finished else { return }
        let download: WKDownload = await withCheckedContinuation { continuation in
            webView.startDownload(using: request) { download in
                continuation.resume(returning: download)
            }
        }
        guard !job.finished else {
            download.cancel { _ in }
            return
        }
        job.download = download
        download.delegate = self
        byDownload[ObjectIdentifier(download)] = job.id
        startingJobID = nil
        job.state = .downloading
        job.observation = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor [weak self] in
                self?.updateProgress(jobID: job.id, fraction: fraction, completed: completed, total: total)
            }
        }
        publish()
    }

    private func updateProgress(jobID: UUID, fraction: Double, completed: Int64, total: Int64) {
        guard let job = jobs[jobID], !job.finished else { return }
        job.progress = max(0, min(1, fraction.isFinite ? fraction : 0))
        job.receivedBytes = max(0, completed)
        job.totalBytes = max(-1, total)
        publish()
    }

    private func job(for download: WKDownload) -> Job? {
        if let id = byDownload[ObjectIdentifier(download)], let job = jobs[id] { return job }
        if let startingJobID, let job = jobs[startingJobID] { return job }
        return nil
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        guard let job = job(for: download), !job.finished else {
            completionHandler(nil)
            return
        }
        byDownload[ObjectIdentifier(download)] = job.id
        if startingJobID == job.id { startingJobID = nil }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            complete(job, result: .failure(BrowserDownloadError.badStatus(http.statusCode)))
            completionHandler(nil)
            return
        }
        let mime = (response.mimeType ?? "").lowercased()
        if mime.contains("text/html") || mime.contains("application/xhtml") {
            complete(job, result: .failure(BrowserDownloadError.unsupportedType(mime)))
            completionHandler(nil)
            return
        }
        let expected = response.expectedContentLength
        if expected > Int64(job.maxBytes) {
            complete(job, result: .failure(BrowserDownloadError.tooLarge(job.maxBytes)))
            completionHandler(nil)
            return
        }
        job.responseMime = mime
        job.finalURL = response.url
        job.displayName = Self.safeDisplayName(suggestedFilename, fallback: job.displayName)
        job.state = .downloading
        publish()
        completionHandler(job.stagingURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let job = job(for: download) else { return }
        job.state = .finishing
        publish()
        do {
            try Self.validate(
                stagedFile: job.stagingURL,
                declaredMime: job.responseMime,
                maxBytes: job.maxBytes
            )
            let receipt = try AtomicFileCommitter.commit(
                stagedFile: job.stagingURL,
                to: job.destinationURL,
                policy: FileCommitPolicy(
                    conflict: job.overwrite ? .replaceAtomically(consent: true) : .failIfExists,
                    maxBytes: job.maxBytes
                )
            )
            let mime = try Self.detectedMime(stagedFile: receipt.url) ?? "application/octet-stream"
            let host = job.finalURL?.host
            complete(job, result: .success(BrowserDownloadReceipt(
                id: job.id,
                destinationURL: receipt.url,
                relativePath: job.relativePath,
                mimeType: mime,
                byteCount: receipt.byteCount,
                sha256: receipt.sha256,
                suggestedFilename: job.displayName,
                finalHost: host
            )))
        } catch {
            complete(job, result: .failure(error))
        }
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        guard let job = job(for: download) else { return }
        complete(job, result: .failure(error))
    }

    private func complete(_ job: Job, result: Result<BrowserDownloadReceipt, Error>) {
        guard job.continuation != nil else { return }
        job.finished = true
        job.observation?.invalidate()
        job.observation = nil
        job.cancelWatcher?.cancel()
        job.cancelWatcher = nil
        if let download = job.download {
            byDownload.removeValue(forKey: ObjectIdentifier(download))
        }
        if startingJobID == job.id { startingJobID = nil }
        if case .failure = result {
            try? FileManager.default.removeItem(at: job.stagingURL)
        }
        jobs.removeValue(forKey: job.id)
        publish()
        let continuation = job.continuation
        job.continuation = nil
        continuation?.resume(with: result)
    }

    private func publish() {
        active = jobs.values.map {
            BrowserDownloadSnapshot(
                id: $0.id,
                displayName: $0.displayName,
                state: $0.state,
                progress: $0.progress,
                receivedBytes: $0.receivedBytes,
                totalBytes: $0.totalBytes
            )
        }.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Validation

    private static func safeDisplayName(_ raw: String, fallback: String) -> String {
        let name = (raw.split(separator: "/").last.map(String.init) ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = name.isEmpty ? fallback : name
        return String(cleaned.prefix(180))
    }

    private static func validate(stagedFile: URL, declaredMime: String, maxBytes: Int) throws {
        guard let values = try? stagedFile.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 0 else {
            throw BrowserDownloadError.emptyFile
        }
        guard size <= maxBytes else { throw BrowserDownloadError.tooLarge(maxBytes) }
        guard let detected = try detectedMime(stagedFile: stagedFile) else {
            throw BrowserDownloadError.unsupportedType(declaredMime.isEmpty ? "unknown" : declaredMime)
        }
        let declared = declaredMime.lowercased()
        if !declared.isEmpty, declared != "application/octet-stream", declared != detected {
            // Servers commonly send image/jpg while the file is JPEG. Treat
            // jpeg/jpg as one family and keep the plain-prefix rule.
            let family = { (value: String) -> String in
                if value.contains("jpeg") || value.contains("jpg") { return "image/jpeg" }
                if value.contains("pdf") { return "application/pdf" }
                return value
            }
            guard family(declared) == family(detected) else {
                throw BrowserDownloadError.signatureMismatch(expected: declared, actual: detected)
            }
        }
    }

    private static func detectedMime(stagedFile: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: stagedFile)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 32), header.count >= 4 else { return nil }
        let bytes = [UInt8](header)
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2d]) { return "application/pdf" }
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return "image/png" }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) { return "image/jpeg" }
        if bytes.count >= 6, String(decoding: bytes[0..<6], as: UTF8.self) == "GIF87a"
            || String(decoding: bytes[0..<6], as: UTF8.self) == "GIF89a" {
            return "image/gif"
        }
        if bytes.count >= 12,
           String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
           String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" {
            return "image/webp"
        }
        if bytes.count >= 12 {
            let brand = String(decoding: bytes[4..<12], as: UTF8.self).lowercased()
            if ["ftypheic", "ftypheix", "ftyphevc", "ftyphevx", "ftypmif1", "ftypmsf1"].contains(brand) {
                return "image/heic"
            }
        }
        return nil
    }
}
#endif
