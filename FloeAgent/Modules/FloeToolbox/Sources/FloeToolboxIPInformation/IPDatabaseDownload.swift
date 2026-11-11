// SPDX-License-Identifier: MPL-2.0
import Foundation

struct IPDownloadedFile: Sendable { let url: URL; let temporary: Bool }
typealias IPDatabaseDownload = @Sendable (URL, Int64, @escaping @Sendable (Int64) -> Void) async throws -> IPDownloadedFile

private final class IPDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximum: Int64
    let progress: @Sendable (Int64) -> Void
    init(maximum: Int64, progress: @escaping @Sendable (Int64) -> Void) { self.maximum = maximum; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum { downloadTask.cancel() }
        else { progress(totalBytesWritten) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // The reviewed dataset host must not redirect into a private endpoint
        // or expose a user's numeric lookup address to another service.
        completionHandler(request.url?.scheme == "https" && request.url?.host == "download.db-ip.com" ? request : nil)
    }
}

enum IPDatabaseNetwork {
    static let download: IPDatabaseDownload = { url, maximum, progress in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = IPDownloadDelegate(maximum: maximum, progress: progress)
        let (file, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == "download.db-ip.com" else {
            try? FileManager.default.removeItem(at: file); throw IPInformationError.invalidDownload
        }
        do { _ = try IPDatabaseStorage.regularFileSize(file, maximum: UInt64(maximum)) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        return IPDownloadedFile(url: file, temporary: true)
    }
}
