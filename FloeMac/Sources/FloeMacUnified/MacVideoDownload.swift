// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import FloeProviders
import Foundation

/// URLSession streams to a temporary file; a video never needs to fit in RAM.
enum MacVideoDownload {
    private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let limit: Int64
        init(limit: Int64) { self.limit = limit }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let prior = response.url, let originalHost = prior.host, let target = request.url,
                  VideoDownloadRedirectPolicy.allowsRedirect(from: originalHost, to: target) else {
                completionHandler(nil)
                return
            }
            var next = request
            if target.host?.lowercased() != originalHost.lowercased() || (target.port ?? 443) != (prior.port ?? 443) {
                next.setValue(nil, forHTTPHeaderField: "Authorization")
                next.setValue(nil, forHTTPHeaderField: "x-goog-api-key")
            }
            completionHandler(next)
        }
    }

    static func fetch(request: URLRequest, directory: URL, jobID: UUID, byteLimit: Int) async throws -> URL {
        let manager = FileManager.default
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 900
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await session.download(for: request, delegate: Transfer(limit: Int64(byteLimit)))
        } catch let error as URLError where error.code == .cancelled && !Task.isCancelled {
            throw MacVideoGeneration.MacVideoGenerationError.unsupportedResult
        }
        defer { try? manager.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MacVideoGeneration.MacVideoGenerationError.downloadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= byteLimit else {
            throw MacVideoGeneration.MacVideoGenerationError.unsupportedResult
        }
        let handle = try FileHandle(forReadingFrom: file)
        let header: Data
        do { header = try handle.read(upToCount: 12) ?? Data(); try handle.close() }
        catch { try? handle.close(); throw error }
        let ext: String
        if header.count >= 12, header.subdata(in: 4..<8) == Data("ftyp".utf8) { ext = "mp4" }
        else if header.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { ext = "webm" }
        else { throw MacVideoGeneration.MacVideoGenerationError.unsupportedResult }

        let staging = directory.appendingPathComponent(".download-" + UUID().uuidString + "." + ext)
        try manager.moveItem(at: file, to: staging)
        defer { try? manager.removeItem(at: staging) }
        let asset = AVURLAsset(url: staging)
        guard try await asset.load(.isPlayable), try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw MacVideoGeneration.MacVideoGenerationError.unsupportedResult
        }
        try Task.checkCancellation()
        let result = directory.appendingPathComponent(jobID.uuidString + "." + ext)
        if manager.fileExists(atPath: result.path) { _ = try manager.replaceItemAt(result, withItemAt: staging) }
        else { try manager.moveItem(at: staging, to: result) }
        return result
    }
}
