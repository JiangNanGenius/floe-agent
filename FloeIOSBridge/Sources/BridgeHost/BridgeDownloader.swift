import Foundation

/// One bounded, cancellable DDI file download. It stages into the caller's
/// directory, cancels as soon as the declared or written size exceeds the cap,
/// and never leaves a partial file at the final destination.
final class BridgeDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Result: Sendable {
        let stagedURL: URL
        let statusCode: Int
        let bytes: Int64
    }

    enum DownloadError: LocalizedError {
        case tooLarge
        case http(Int)
        case noFile
        case cancelled
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "The file exceeded the prototype's size limit."
            case .http(let status): return "The download returned HTTP \(status)."
            case .noFile: return "The download produced no file."
            case .cancelled: return "The download was cancelled."
            case .transport(let message): return message
            }
        }
    }

    private let maximumBytes: Int64
    private let destinationDirectory: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false
    private var stagedURL: URL?

    init(maximumBytes: Int64,
         destinationDirectory: URL,
         progress: @escaping @Sendable (Double) -> Void) {
        self.maximumBytes = maximumBytes
        self.destinationDirectory = destinationDirectory
        self.progress = progress
        super.init()
    }

    func download(url: URL) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.waitsForConnectivity = true
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            lock.lock()
            self.session = session
            let task = session.downloadTask(with: url)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(DownloadError.cancelled))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > maximumBytes || totalBytesWritten > maximumBytes {
            downloadTask.cancel()
            finish(.failure(DownloadError.tooLarge))
            return
        }
        if totalBytesExpectedToWrite > 0 {
            progress(min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            finish(.failure(DownloadError.http(status)))
            return
        }
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let target = destinationDirectory.appendingPathComponent(".download-\(UUID().uuidString).tmp")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= maximumBytes else {
                try? FileManager.default.removeItem(at: target)
                finish(.failure(size > maximumBytes ? DownloadError.tooLarge : DownloadError.noFile))
                return
            }
            stagedURL = target
            progress(1.0)
            finish(.success(Result(stagedURL: target, statusCode: status, bytes: size)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(DownloadError.transport(error.localizedDescription)))
        } else {
            finish(.failure(DownloadError.noFile))
        }
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        let staged = self.stagedURL
        self.stagedURL = nil
        lock.unlock()

        session?.invalidateAndCancel()
        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            if let staged { try? FileManager.default.removeItem(at: staged) }
            continuation?.resume(throwing: error)
        }
    }
}
