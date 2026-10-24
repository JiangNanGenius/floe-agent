// FloeAndroid shared/Sources/FloeBrowser — policy-gated browser downloads.
//
// Android-owned service (the iOS flow was WKDownload delegate plumbing inside
// the App target). Contract required by the G04 task: a page download can
// only SAVE through a precise native sink port into the owning task's
// workspace — staged, capped, hash-verified, cancellable — never as a direct
// arbitrary external write, and never widening the file namespace beyond the
// owner's admitted destinations. The Kotlin half (feature/browser) forwards
// WebView DownloadListener facts here and pipes bytes through the ticket;
// it holds no path authority.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import FloeCore
import FloeTransport

public struct BrowserDownloadQuery: Sendable, Codable, Hashable {
    public var tabID: UUID
    public var owner: BrowserOwnerID
    public var url: String
    public var userAgent: String
    public var contentDisposition: String
    public var mimeType: String
    public var suggestedContentLength: Int64?

    public init(
        tabID: UUID,
        owner: BrowserOwnerID,
        url: String,
        userAgent: String = "",
        contentDisposition: String = "",
        mimeType: String = "",
        suggestedContentLength: Int64? = nil
    ) {
        self.tabID = tabID
        self.owner = owner
        self.url = url
        self.userAgent = userAgent
        self.contentDisposition = contentDisposition
        self.mimeType = mimeType
        self.suggestedContentLength = suggestedContentLength
    }
}

public struct BrowserDownloadTicket: Sendable, Codable, Hashable {
    public let id: UUID
    public let taskID: UUID
    public let sessionID: UUID
    /// Workspace-relative directory minted by the sink configuration. Never a
    /// disk path; the native sink owns the real location.
    public let relativeDirectory: String
    public let fileName: String
    public let maximumBytes: Int

    public init(
        id: UUID,
        taskID: UUID,
        sessionID: UUID,
        relativeDirectory: String,
        fileName: String,
        maximumBytes: Int
    ) {
        self.id = id
        self.taskID = taskID
        self.sessionID = sessionID
        self.relativeDirectory = relativeDirectory
        self.fileName = fileName
        self.maximumBytes = maximumBytes
    }
}

public struct BrowserDownloadReceipt: Sendable, Codable, Hashable {
    public var relativePath: String
    public var byteCount: Int
    public var sha256: String

    public init(relativePath: String, byteCount: Int, sha256: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum BrowserDownloadError: Error, LocalizedError, Sendable, Equatable {
    case policy(String)
    case crossOrigin
    case overCap(Int64)
    case unknownTicket
    case cancelled
    case sinkFailed(String)

    public var errorDescription: String? {
        switch self {
        case .policy(let message): return message
        case .crossOrigin: return "The download target does not match the tab's committed origin or an authorized preview allocation for this task"
        case .overCap(let bytes): return "The suggested download size (\(bytes) bytes) exceeds the per-download cap"
        case .unknownTicket: return "The download ticket is unknown, expired, or owned by a released session"
        case .cancelled: return "The download was cancelled"
        case .sinkFailed(let message): return "The workspace download sink failed: \(message)"
        }
    }
}

/// The native fetch seam. Production streams GET bytes over URLSession's
/// incremental transport (FoundationNetworking on Android, same rule as
/// FloeAndroidWebTools); qualification/tests inject a deterministic source.
/// The closure must only call `send` with bytes for `url` and throw to
/// abort; the coordinator enforces cap/hash/cancellation around it.
public typealias BrowserDownloadFetcher =
    @Sendable (_ url: URL, _ send: @Sendable (Data) async throws -> Void) async throws -> Void

public enum BrowserDownloadFetchers {
    /// The production incremental transport seam (FloeTransport
    /// StreamingTransport) — the SAME Android-proven streaming path the
    /// provider/web tools use, inheriting its redirect/auth policy.
    /// `refuseAllRedirects` is deliberate: the admit-time policy check judged
    /// the ORIGINAL URL; a native 3xx to a private/loopback target must not
    /// silently widen that decision mid-fetch. Redirected downloads return a
    /// typed refusal and re-enter through the browser navigation path.
    public static let production: BrowserDownloadFetcher = { url, send in
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let urlSession = StreamingTransport.makeSession(
            configuration: configuration,
            refuseAllRedirects: true
        )
        defer { urlSession.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let stream = try StreamingTransport.stream(request, via: urlSession, maxBufferedBytes: 256 * 1024)
        defer { stream.cancelOwned() }
        let http = try await stream.httpResponse()
        guard (200...299).contains(http.statusCode) else {
            if (300...399).contains(http.statusCode) {
                throw BrowserDownloadError.sinkFailed("the target redirected; re-observe the link and use the browser navigation path for redirected downloads")
            }
            throw BrowserDownloadError.sinkFailed("the target returned a non-success status")
        }
        for try await chunk in stream {
            try await send(chunk)
            if Task.isCancelled { throw CancellationError() }
        }
    }
}

/// Main's staged/verified workspace save (pattern precedent: attachment
/// staging + transfer verification already in production). The coordinator
/// enforces the byte cap and the running SHA-256; the sink enforces the real
/// destination and atomic commit.
public protocol BrowserDownloadSinkPort: Sendable {
    func open(ticket: BrowserDownloadTicket) async throws -> String
    func append(handle: String, bytes: Data) async throws
    func commit(handle: String, sha256: String, expectedBytes: Int) async throws -> BrowserDownloadReceipt
    func discard(handle: String) async
}

public actor BrowserDownloadCoordinator {
    private struct InFlight {
        var ticket: BrowserDownloadTicket
        var sessionID: UUID
        var handle: String?
        var hasher: SHA256
        var received: Int
        var cancelled = false
        var committed = false
        var fetchTask: Task<Void, Never>?
    }

    /// Progress observer handed to Main's composition (UI/task cards only; it
    /// never authorizes anything).
    public struct DownloadSignals: Sendable {
        public var onStart: @Sendable (BrowserDownloadTicket) -> Void
        public var onProgress: @Sendable (UUID, Int) -> Void
        public var onCommitted: @Sendable (BrowserDownloadReceipt) -> Void
        public var onFailed: @Sendable (UUID, String) -> Void

        public init(
            onStart: @escaping @Sendable (BrowserDownloadTicket) -> Void = { _ in },
            onProgress: @escaping @Sendable (UUID, Int) -> Void = { _, _ in },
            onCommitted: @escaping @Sendable (BrowserDownloadReceipt) -> Void = { _ in },
            onFailed: @escaping @Sendable (UUID, String) -> Void = { _, _ in }
        ) {
            self.onStart = onStart
            self.onProgress = onProgress
            self.onCommitted = onCommitted
            self.onFailed = onFailed
        }
    }

    private let policy: BrowserURLPolicy
    private let sink: BrowserDownloadSinkPort
    public let maximumBytesPerDownload: Int
    private let sinkDirectory: @Sendable (BrowserOwnerID) -> String
    private let signals: DownloadSignals
    private let fetcher: BrowserDownloadFetcher
    private var inFlight: [UUID: InFlight] = [:]

    public init(
        policy: BrowserURLPolicy,
        sink: BrowserDownloadSinkPort,
        maximumBytesPerDownload: Int = 512 * 1024 * 1024,
        sinkDirectory: (@Sendable (BrowserOwnerID) -> String)? = nil,
        signals: DownloadSignals = DownloadSignals(),
        fetcher: BrowserDownloadFetcher? = nil
    ) {
        self.policy = policy
        self.sink = sink
        self.maximumBytesPerDownload = max(1024, maximumBytesPerDownload)
        self.sinkDirectory = sinkDirectory ?? { _ in "BrowserDownloads" }
        self.signals = signals
        self.fetcher = fetcher ?? BrowserDownloadFetchers.production
    }

    /// Admit one download observed by the renderer AND own the entire fetch.
    /// The URL must pass the SAME navigation policy as browser.navigate
    /// (preview/service grants apply), AND its origin must equal the tab's
    /// committed origin or be a granted preview allocation. Cross-origin or
    /// ungranted targets are refused; the page cannot widen the file
    /// namespace. Bytes stream through this actor into the sink — the Kotlin
    /// side does no networking and no file writes.
    public func admit(
        query: BrowserDownloadQuery,
        session: BrowserTaskSession,
        sessionID: UUID
    ) async -> BrowserDownloadTicket? {
        guard await session.sessionID == sessionID, !(await session.isReleased) else { return nil }
        guard let url = try? policy.validate(query.url, conversationID: query.owner.taskID) else {
            return nil
        }
        if let suggested = query.suggestedContentLength, suggested > Int64(maximumBytesPerDownload) {
            return nil
        }
        let targetOrigin = Self.origin(of: url)
        let tabOriginValue = await session.tabOrigin(tabID: query.tabID)
        let tabOrigin = tabOriginValue.flatMap { Self.origin(ofString: $0) }
        guard await session.hasTab(query.tabID) else { return nil }
        let isOwnPreview = policy.isGrantedPreviewAllocation(url)
        guard let targetOrigin, let tabOrigin, tabOrigin == targetOrigin || isOwnPreview else {
            return nil
        }
        // A preview allocation additionally belongs to THIS owner: the
        // grant-table check above is per-token, and tokens are per-server,
        // per-start; never rely on loopback alone.
        let fileName = Self.sanitizeFileName(
            contentDisposition: query.contentDisposition,
            url: url,
            mimeType: query.mimeType
        )
        let ticket = BrowserDownloadTicket(
            id: UUID(),
            taskID: query.owner.taskID,
            sessionID: sessionID,
            relativeDirectory: sinkDirectory(query.owner),
            fileName: fileName,
            maximumBytes: maximumBytesPerDownload
        )
        inFlight[ticket.id] = InFlight(
            ticket: ticket,
            sessionID: sessionID,
            handle: nil,
            hasher: SHA256(),
            received: 0
        )
        let task = Task { [weak self] in
            // Discard explicitly: the `self?` chain makes the inferred Task
            // Success `()?` unless discarded, while `fetchTask` owns a
            // Task<Void, Never>; the fetch result was never consumed.
            _ = await self?.runFetch(ticket: ticket, url: url)
        }
        inFlight[ticket.id]?.fetchTask = task
        signals.onStart(ticket)
        return ticket
    }

    /// The native fetch: bounded streaming download with cancellation, then
    /// staged verified commit through the sink port. A failed, cancelled or
    /// over-cap transfer discards staging and never leaves a partial
    /// "success" file behind.
    private func runFetch(ticket: BrowserDownloadTicket, url: URL) async {
        do {
            try Task.checkCancellation()
            try await openStaging(ticketID: ticket.id)
            try await stream(url: url, into: ticket)
            let receipt = try await commit(ticketID: ticket.id)
            signals.onCommitted(receipt)
        } catch {
            await cancel(ticketID: ticket.id)
            signals.onFailed(ticket.id, error.localizedDescription)
        }
    }

    /// Streams through the injected fetcher; the cap/hash/cancel enforcement
    /// stays in `appendChunk` regardless of the platform fetch strategy.
    private func stream(url: URL, into ticket: BrowserDownloadTicket) async throws {
        try await fetcher(url) { [weak self] data in
            guard let self else { throw BrowserDownloadError.cancelled }
            try await self.appendChunk(ticketID: ticket.id, bytes: data)
            let received = await self.receivedBytes(ticketID: ticket.id)
            self.signals.onProgress(ticket.id, received)
        }
    }

    private func receivedBytes(ticketID: UUID) -> Int {
        inFlight[ticketID]?.received ?? 0
    }

    public func openStaging(ticketID: UUID) async throws {
        guard var item = inFlight[ticketID], !item.cancelled, item.handle == nil else {
            throw BrowserDownloadError.unknownTicket
        }
        do {
            item.handle = try await sink.open(ticket: item.ticket)
        } catch {
            inFlight.removeValue(forKey: ticketID)
            throw BrowserDownloadError.sinkFailed(error.localizedDescription)
        }
        inFlight[ticketID] = item
    }

    /// Stream one bounded chunk into staging. Cumulative cap is enforced in
    /// Swift BEFORE the sink sees the bytes (the sink re-enforces its own).
    /// Exposed for Main's alternate producers; the WebView path uses the
    /// internal fetch above.
    public func appendChunk(ticketID: UUID, bytes: Data) async throws {
        guard var item = inFlight[ticketID], !item.cancelled, let handle = item.handle else {
            throw BrowserDownloadError.unknownTicket
        }
        guard item.received + bytes.count <= item.ticket.maximumBytes else {
            // Over the hard cap: discard staging and terminate the ticket.
            item.cancelled = true
            inFlight[ticketID] = item
            await sink.discard(handle: handle)
            inFlight.removeValue(forKey: ticketID)
            throw BrowserDownloadError.overCap(Int64(item.ticket.maximumBytes))
        }
        do {
            try await sink.append(handle: handle, bytes: bytes)
        } catch {
            throw BrowserDownloadError.sinkFailed(error.localizedDescription)
        }
        item.hasher.update(data: bytes)
        item.received += bytes.count
        inFlight[ticketID] = item
    }

    /// Finalize: hash + byte count are handed to the sink, which performs the
    /// verified staged commit at the owner's destination. Returns the receipt
    /// or throws; the ticket dies either way.
    public func commit(ticketID: UUID) async throws -> BrowserDownloadReceipt {
        guard var item = inFlight[ticketID], !item.cancelled, let handle = item.handle, !item.committed else {
            throw BrowserDownloadError.unknownTicket
        }
        item.committed = true
        inFlight[ticketID] = item
        let digest = item.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        do {
            let receipt = try await sink.commit(
                handle: handle,
                sha256: digest,
                expectedBytes: item.received
            )
            inFlight.removeValue(forKey: ticketID)
            return receipt
        } catch {
            inFlight.removeValue(forKey: ticketID)
            throw BrowserDownloadError.sinkFailed(error.localizedDescription)
        }
    }

    public func cancel(ticketID: UUID) async {
        guard let item = inFlight.removeValue(forKey: ticketID) else { return }
        item.fetchTask?.cancel()
        if let handle = item.handle, !item.committed {
            await sink.discard(handle: handle)
        }
    }

    /// Owner/session retirement fence: every unfinished ticket for this task
    /// (or this session) is cancelled and its staging discarded. A late
    /// callback against a removed ticket gets `unknownTicket`, never a commit.
    public func releaseOwner(taskID: UUID) async {
        let doomed = inFlight.filter { $0.value.ticket.taskID == taskID }
        for (id, _) in doomed {
            await cancel(ticketID: id)
        }
    }

    public func releaseSession(sessionID: UUID) async {
        let doomed = inFlight.filter { $0.value.sessionID == sessionID }
        for (id, _) in doomed {
            await cancel(ticketID: id)
        }
    }

    public var activeTicketCount: Int { inFlight.count }

    // MARK: Helpers

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port.map(String.init) ?? (scheme == "http" ? "80" : "443")
        return "\(scheme)://\(host):\(port)"
    }

    static func origin(ofString value: String?) -> String? {
        guard let value, let url = URL(string: value) else { return nil }
        return origin(of: url)
    }

    /// Derive a safe single filename. Only the basename survives: path
    /// separators, parent references, control characters and leading dots are
    /// stripped; a fallback name keeps the extension where known.
    public static func sanitizeFileName(contentDisposition: String, url: URL, mimeType: String) -> String {
        var candidate = ""
        // RFC 6266-ish extraction: filename*=UTF-8''... or filename="..."
        let lowered = contentDisposition.lowercased()
        if let range = lowered.range(of: "filename*=") {
            let tail = contentDisposition[range.upperBound...]
            let token = String(tail.split(separator: ";").first ?? "")
            if let tick = token.lastIndex(of: "'") {
                candidate = String(token[token.index(after: tick)...])
            } else {
                candidate = token
            }
        } else if let range = lowered.range(of: "filename=") {
            let tail = contentDisposition[range.upperBound...]
            let token = String(tail.split(separator: ";").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            candidate = token
        }
        if candidate.isEmpty {
            candidate = url.lastPathComponent
        }
        if let decoded = candidate.removingPercentEncoding {
            candidate = decoded
        }
        candidate = candidate
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        candidate = candidate
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" }
            .map(Character.init)
            .reduce(into: "") { result, ch in result.append(ch) }
        while candidate.hasPrefix(".") { candidate.removeFirst() }
        candidate = String(candidate.prefix(200))
        candidate = candidate
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespaces)
        if candidate.isEmpty {
            let ext = mimeType.isEmpty ? "bin" : Self.fileExtension(forMime: mimeType)
            candidate = "download.bin"
            if !ext.isEmpty { candidate = "download.\(ext)" }
        }
        return candidate
    }

    static func fileExtension(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "text/html": return "html"
        case "text/plain": return "txt"
        case "application/json": return "json"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "application/pdf": return "pdf"
        case "application/zip": return "zip"
        default: return ""
        }
    }
}
