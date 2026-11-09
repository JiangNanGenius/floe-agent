// FloeApp — bounded HTTPS bytes for the existing pinned Linux image service.
// Content identity, archive/manifest verification and install ownership remain
// in FloeExecution. The website is only a last byte location for that asset.
import Foundation
import FloeExecution

nonisolated private final class LinuxImageDownloadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0
    private let lockedURL: URL?
    init(lockedURL: URL? = nil) { self.lockedURL = lockedURL }
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        // A website bearer token never follows a different URL or origin.
        guard request.url?.scheme == "https", lockedURL == nil || request.url == lockedURL else {
            completionHandler(nil); return
        }
        let allowed = lock.withLock { redirects += 1; return redirects <= 8 }
        completionHandler(allowed ? request : nil)
    }
}

/// Owned by ONE transfer/session. Completion fences its watchdog before the
/// session is disposed; no timer can touch another image or view afterwards.
nonisolated private final class LinuxImageTransferObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var ended: TimeInterval?
    private var received: Int64 = 0
    private var slow = false
    private var writing = false
    func record(_ bytes: Int64) { lock.withLock { received = bytes } }
    func localWrite(_ active: Bool) { lock.withLock { writing = active } }
    func shouldAbortSlow() -> Bool {
        lock.withLock {
            let seconds = Int(ProcessInfo.processInfo.systemUptime - started)
            // At most one 64KiB application buffer is not yet published. Use
            // its upper bound to avoid a false slow result at the threshold.
            guard ended == nil, !writing, seconds >= LinuxGuestImageWebsiteFallback.slowSeconds,
                  received + 65_536 < Int64(seconds) * LinuxGuestImageWebsiteFallback.slowBytesPerSecond else { return false }
            slow = true; return true
        }
    }
    func finish(_ actualReceived: Int64) {
        lock.withLock { received = actualReceived; ended = ProcessInfo.processInfo.systemUptime }
    }
    func snapshot() -> LinuxGuestImageWebsiteFallback.Observation {
        lock.withLock {
            .init(seconds: max(0, Int((ended ?? ProcessInfo.processInfo.systemUptime) - started)),
                  receivedBytes: received, slow: slow)
        }
    }
}

nonisolated struct LinuxGuestImageHTTPDownloader: LinuxGuestImageDownloading {
    typealias MirrorPolicy = @Sendable (_ waitForRefresh: Bool) async -> LinuxGuestImageMirrorPolicy
    private let mirrorPolicy: MirrorPolicy
    private let configuration: @Sendable () -> URLSessionConfiguration
    private let imageForURL: @Sendable (URL) -> LinuxGuestTrustedImage?
    init(mirrorPolicy: @escaping MirrorPolicy = { _ in .unavailable },
         configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral },
         imageForURL: @escaping @Sendable (URL) -> LinuxGuestTrustedImage? = { url in
             LinuxGuestImageDistributionCatalog.bundled.first { $0.archiveURL == url }
         }) {
        self.mirrorPolicy = mirrorPolicy; self.configuration = configuration; self.imageForURL = imageForURL
    }

    static func availableImportantBytes(for url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0 { return capacity }
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity { return Int64(capacity) }
        return -1
    }

    func download(_ url: URL, to destination: URL, maxBytes: Int64,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws(LinuxGuestImageTransferError) {
        try checkCancellation()
        guard let image = imageForURL(url), let pin = image.assetPin else {
            // Existing per-piece/custom-source requests retain their own
            // source coordinator and verified-piece resume contract.
            try await stream(URLRequest(url: url), to: destination, maxBytes: maxBytes, onProgress: onProgress)
            return
        }
        guard pin.bytes > 0, pin.bytes <= maxBytes else {
            throw .localRejection(detail: "The pinned image exceeds the download size limit")
        }
        // Starts only at a real download, not App launch/settings/HEAD. The
        // existing policy store owns and coalesces its nonblocking refresh.
        _ = await mirrorPolicy(false)
        try checkCancellation()
        let primary = LinuxImageTransferObservation()
        let primaryFailure: LinuxGuestImageTransferError
        do {
            try await stream(URLRequest(url: url), to: destination, maxBytes: maxBytes,
                             observation: primary, onProgress: onProgress)
            return
        } catch let error {
            guard error.allowsNextSource else { throw error }
            primaryFailure = error
        }
        try checkCancellation()
        // Re-read the authenticated store after the primary observation. A
        // missing/expired/rejected policy cannot invent enabled mirror roles.
        let policy = await mirrorPolicy(true)
        try checkCancellation()
        let mirrors = policy.enabledIDs
        guard !mirrors.isEmpty else {
            throw primaryFailure
        }
        var failures: [String] = []
        var lastFailure = primaryFailure
        for id in mirrors {
            try checkCancellation()
            guard let mirror = URL(string: "https://" + id + "/" + url.absoluteString) else {
                throw .responseInvalid(detail: "The image mirror address is invalid")
            }
            do {
                try await stream(URLRequest(url: mirror), to: destination, maxBytes: maxBytes,
                                 observation: LinuxImageTransferObservation(), onProgress: onProgress)
                return
            } catch let error {
                guard error.allowsNextSource else { throw error }
                failures.append(id)
                lastFailure = error
            }
        }
        try checkCancellation()
        guard Set(failures) == LinuxGuestImageWebsiteFallback.mirrorIDs, failures.count == 2,
              pin.bytes <= maxBytes else {
            throw lastFailure
        }
        let index = try await control(LinuxGuestImageWebsiteFallback.publicRequest(path: "/api/v1/distribution"),
                                      maximumBytes: LinuxGuestImageWebsiteFallback.indexMaximumBytes)
        let asset = try LinuxGuestImageWebsiteFallback.asset(in: index, image: image)
        let admission = try LinuxGuestImageWebsiteFallback.admission(asset: asset,
            observation: primary.snapshot(), failures: failures, policy: policy)
        try checkCancellation()
        let response = try await control(admission, maximumBytes: LinuxGuestImageWebsiteFallback.ticketMaximumBytes)
        let ticket = try LinuxGuestImageWebsiteFallback.ticket(in: response, asset: asset)
        try checkCancellation()
        let offset = try resumeOffset(destination, maximum: ticket.size)
        let request = LinuxGuestImageWebsiteFallback.downloadRequest(ticket: ticket, offset: offset)
        try await stream(request, to: destination, maxBytes: min(maxBytes, ticket.size),
                         ticket: ticket, requestedOffset: offset, onProgress: onProgress)
        // The existing install coordinator now verifies the whole archive's
        // immutable SHA512, qualified manifest and extracted artifact hashes.
        // Do not create another installation path or duplicate a large hash
        // loop on a caller's actor here.
    }

    private func session(lockedURL: URL? = nil) -> URLSession {
        let config = configuration()
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config,
            delegate: LinuxImageDownloadRedirectGuard(lockedURL: lockedURL), delegateQueue: nil)
    }

    private func control(_ request: URLRequest, maximumBytes: Int) async throws(LinuxGuestImageTransferError) -> Data {
        guard LinuxGuestImageWebsiteFallback.sameOrigin(request.url) else {
            throw .responseInvalid(detail: "The website address is invalid")
        }
        let session = session(lockedURL: request.url)
        defer { session.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw LinuxGuestImageTransferError.responseInvalid(detail: "The website response is invalid") }
                guard http.statusCode == 200 else { throw Self.classify(status: http.statusCode) }
                guard http.expectedContentLength <= Int64(maximumBytes) else { throw LinuxGuestImageTransferError.responseInvalid(detail: "The website response is too large") }
                var body = Data()
                for try await byte in bytes {
                    if body.count >= maximumBytes { throw LinuxGuestImageTransferError.responseInvalid(detail: "The website response is too large") }
                    body.append(byte)
                    if body.count % 4096 == 0 { try Task.checkCancellation() }
                }
                try Task.checkCancellation()
                return body
            } onCancel: { session.invalidateAndCancel() }
        } catch is CancellationError { throw .cancelled }
        catch let error as LinuxGuestImageTransferError { throw error }
        catch let error as URLError { throw Self.classify(error, taskIsCancelled: Task.isCancelled) }
        catch { throw .responseInvalid(detail: "The website response is invalid") }
    }

    private func stream(_ request: URLRequest, to destination: URL, maxBytes: Int64,
                        observation: LinuxImageTransferObservation? = nil,
                        ticket: LinuxGuestImageWebsiteFallback.Ticket? = nil, requestedOffset: Int64 = 0,
                        onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws(LinuxGuestImageTransferError) {
        guard request.url?.scheme == "https", maxBytes > 0,
              ticket == nil || LinuxGuestImageWebsiteFallback.sameOrigin(request.url) else {
            throw .responseInvalid(detail: "Image downloads require HTTPS")
        }
        let session = session(lockedURL: ticket == nil ? nil : request.url)
        var received: Int64 = 0
        let watchdog: Task<Void, Never>? = observation.map { observation in
            Task {
                do { try await Task.sleep(for: .seconds(LinuxGuestImageWebsiteFallback.slowSeconds)) }
                catch { return }
                if !Task.isCancelled, observation.shouldAbortSlow() { session.invalidateAndCancel() }
            }
        }
        defer {
            observation?.finish(received)
            watchdog?.cancel()
            session.invalidateAndCancel()
        }
        do {
            try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw LinuxGuestImageTransferError.responseInvalid(detail: "The image response is invalid") }
                guard (200..<300).contains(http.statusCode) else { throw Self.classify(status: http.statusCode) }
                let offset: Int64
                if let ticket { offset = try LinuxGuestImageWebsiteFallback.responseOffset(http, ticket: ticket, requestedOffset: requestedOffset) }
                else { offset = 0 }
                let expected = ticket?.size ?? http.expectedContentLength
                let fm = FileManager.default
                do { try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) }
                catch { throw LinuxGuestImageTransferError.localRejection(detail: "Cannot create the download directory") }
                if expected > 0 {
                    guard expected <= maxBytes, expected <= Int64.max - 64 * 1024 * 1024 else {
                        throw LinuxGuestImageTransferError.localRejection(detail: "The image exceeds the download size limit")
                    }
                    let available = Self.availableImportantBytes(for: destination.deletingLastPathComponent())
                    let required = max(0, expected - offset) + 64 * 1024 * 1024
                    if available >= 0 && available < required { throw LinuxGuestImageTransferError.localRejection(detail: "There is not enough space to download the image") }
                }
                if offset == 0 { guard fm.createFile(atPath: destination.path, contents: nil) else { throw LinuxGuestImageTransferError.localRejection(detail: "Cannot create the download file") } }
                let handle: FileHandle
                do {
                    handle = try FileHandle(forWritingTo: destination)
                } catch { throw LinuxGuestImageTransferError.localRejection(detail: "Cannot open the download file") }
                defer { try? handle.close() }
                do { try handle.truncate(atOffset: UInt64(offset)); try handle.seek(toOffset: UInt64(offset)) }
                catch { throw LinuxGuestImageTransferError.localRejection(detail: "Cannot prepare the download file") }
                var buffer = Data(); buffer.reserveCapacity(65_536)
                for try await byte in bytes {
                    received += 1
                    guard offset + received <= maxBytes else { throw LinuxGuestImageTransferError.localRejection(detail: "The image exceeds the download size limit") }
                    buffer.append(byte)
                    if buffer.count >= 65_536 {
                        observation?.record(received); observation?.localWrite(true)
                        do { try handle.write(contentsOf: buffer) }
                        catch { throw LinuxGuestImageTransferError.localRejection(detail: "Cannot write the download file") }
                        observation?.localWrite(false)
                        buffer.removeAll(keepingCapacity: true)
                        onProgress(offset + received, expected)
                        try Task.checkCancellation()
                    }
                }
                if !buffer.isEmpty {
                    do { try handle.write(contentsOf: buffer) }
                    catch { throw LinuxGuestImageTransferError.localRejection(detail: "Cannot write the download file") }
                    onProgress(offset + received, expected)
                }
                try Task.checkCancellation()
                guard received > 0 else { throw LinuxGuestImageTransferError.responseInvalid(detail: "The image response was empty") }
                if let ticket, offset + received != ticket.size { throw LinuxGuestImageTransferError.responseInvalid(detail: "The website download was incomplete") }
            } onCancel: { session.invalidateAndCancel() }
        } catch is CancellationError {
            if Task.isCancelled { throw .cancelled }
            if let observation, observation.snapshot().qualifiesAsSlow {
                throw .networkFailure(detail: "The image source stayed below the download speed threshold")
            }
            throw .responseInvalid(detail: "The image request was interrupted")
        }
        catch let error as LinuxGuestImageTransferError { throw error }
        catch let error as URLError {
            if Task.isCancelled { throw .cancelled }
            if let observation, observation.snapshot().qualifiesAsSlow {
                throw .networkFailure(detail: "The image source stayed below the download speed threshold")
            }
            throw Self.classify(error, taskIsCancelled: false)
        } catch { throw .responseInvalid(detail: "The image response is invalid") }
    }

    private func resumeOffset(_ file: URL, maximum: Int64) throws(LinuxGuestImageTransferError) -> Int64 {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LinuxGuestImageTransferError.localRejection(detail: "The download file is not a regular file") }
            let size = Int64(values.fileSize ?? 0)
            return size > 0 && size < maximum ? size : 0
        } catch let error as LinuxGuestImageTransferError { throw error }
        catch { throw .localRejection(detail: "The download file could not be read") }
    }
    private func checkCancellation() throws(LinuxGuestImageTransferError) {
        if Task.isCancelled { throw .cancelled }
    }
    private static func classify(_ error: URLError, taskIsCancelled: Bool) -> LinuxGuestImageTransferError {
        if error.code == .cancelled { return taskIsCancelled ? .cancelled : .responseInvalid(detail: "The image request was interrupted") }
        switch error.code {
        case .dataNotAllowed, .internationalRoamingOff:
            // Local network-use restrictions cannot authorize another route.
            return .localRejection(detail: "Network use is restricted by the device settings")
        case .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .dnsLookupFailed, .callIsActive:
            return .networkFailure(detail: error.localizedDescription)
        default: return .responseInvalid(detail: error.localizedDescription)
        }
    }
    private static func classify(status: Int) -> LinuxGuestImageTransferError {
        if status == 408 || status == 429 || (500..<600).contains(status) { return .serverUnavailable(status: status, detail: "HTTP \(status)") }
        return .responseRejected(status: status, detail: "HTTP \(status)")
    }

    static func probePinnedArchiveBytes(imageID: String) async -> Int64? {
        guard let image = LinuxGuestImageDistributionCatalog.entry(id: imageID) else { return nil }
        if let bytes = image.assetPin?.bytes { return bytes }
        let url = image.archiveURL
        let session = URLSession(configuration: .ephemeral, delegate: LinuxImageDownloadRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "HEAD"; request.timeoutInterval = 30
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.expectedContentLength > 0 else { return nil }
            return http.expectedContentLength
        } catch { return nil }
    }
}
