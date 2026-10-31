// FloeProviders — Cloud ASR transport implementations and security policy.
//
// SPDX-License-Identifier: MPL-2.0
//
// Concrete URLSession/URLSessionWebSocketTask transports for the shared
// `ASRHTTPTransport` / `ASRWebSocketTransport` seams in FloeCore. Provider
// adapters (the OpenAI adapters here and the vendor adapters in their lane)
// receive these through injection, so focused tests can drive exact payloads
// without a network and a reader can verify the security policy directly.
//
// Security rules:
//   * default sessions are ephemeral: no URLCache, cookies, credential store
//     or shared connection state;
//   * a credential-bearing request is only sent to the validated endpoint; an
//     origin-changing redirect is not followed (nil completion), so a Bearer
//     key cannot be replayed to another host/port;
//   * provider bodies/headers never become an error: only status codes,
//     categories and bounded data leave this layer.

import Foundation
import FloeCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Redirect policy

/// Same-origin-only redirect handling for credential-bearing ASR calls.
/// `willPerformHTTPRedirection` returns nil for a cross-origin target, which
/// cancels the redirect instead of forwarding the Authorization header.
public final class ASRRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }

    public static func isAllowed(from original: URL, to redirect: URL) -> Bool {
        guard let old = ASRTransportSecurity.originKey(original),
              let new = ASRTransportSecurity.originKey(redirect) else {
            return false
        }
        return old == new
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url ?? task.currentRequest?.url,
              let target = request.url,
              Self.isAllowed(from: original, to: target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - Session factories / origin checks

public enum ASRTransportSecurity {
    /// Ephemeral JSON/multipart session used by default.
    public static func makeHTTPSession() -> URLSession {
        makeSession()
    }

    /// Ephemeral WebSocket session used by default.
    public static func makeWebSocketSession() -> URLSession {
        makeSession()
    }

    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        originKey(lhs) != nil && originKey(lhs) == originKey(rhs)
    }

    public static func originKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        let secure: String
        switch scheme {
        case "https", "wss": secure = "secure"
        case "http", "ws": secure = "insecure"
        default: return nil
        }
        let port = url.port ?? (secure == "secure" ? 443 : 80)
        return "\(secure)://\(host):\(port)"
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldUsePipelining = false
        return URLSession(
            configuration: configuration,
            delegate: ASRRedirectGuard(),
            delegateQueue: nil)
    }
}

// MARK: - Error mapping

public enum ASRTransportErrorMapping {
    /// Collapse any transport error into a redacted lane-safe category.
    public static func failure(_ error: Error) -> ASRTranscriptionError {
        if let error = error as? ASRTranscriptionError { return error }
        if error is CancellationError { return .transport(.cancelled) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                 NSURLErrorResourceUnavailable:
                return .transport(.cannotResolveHost)
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
                return .transport(.cannotConnect)
            case NSURLErrorTimedOut:
                return .transport(.timedOut)
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return .transport(.tlsFailure)
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return .transport(.notReachable)
            case NSURLErrorCancelled:
                return .transport(.cancelled)
            case NSURLErrorDataLengthExceedsMaximum:
                // A native WebSocket message above `maximumMessageSize`.
                return .responseTooLarge
            default:
                return .transport(.unknown)
            }
        }
        return .transport(.unknown)
    }
}

// MARK: - Native receive ceilings

/// Fixed ceilings enforced by the built-in native transports while provider
/// data is still arriving. Deliberately not part of the `ASRHTTPTransport` /
/// `ASRWebSocketTransport` protocols: a caller can still inject its own bounded
/// transport, while the URLSession transport never buffers a whole untrusted
/// response past these limits. They are ceilings, not provider configuration.
public enum ASRTransportLimits {
    /// Matches `OpenAITranscriptionAdapter.maximumResponseBytes` (8 MiB).
    public static let maximumResponseBodyBytes = 8 * 1024 * 1024
    /// One inbound WebSocket message. Adapter event caps may be smaller.
    public static let maximumWebSocketMessageBytes = 8 * 1024 * 1024
}

// MARK: - HTTP transport

public struct URLSessionASRHTTPTransport: ASRHTTPTransport {
    public let session: URLSession
    /// Per-response ceiling applied while chunks arrive. Internal so focused
    /// tests can drive the bound with a small body; every public initializer
    /// uses `ASRTransportLimits.maximumResponseBodyBytes`.
    let maximumResponseBodyBytes: Int

    public init(session: URLSession) {
        self.init(
            session: session,
            maximumResponseBodyBytes: ASRTransportLimits.maximumResponseBodyBytes)
    }

    init(session: URLSession, maximumResponseBodyBytes: Int) {
        self.session = session
        self.maximumResponseBodyBytes = Swift.max(1, maximumResponseBodyBytes)
    }

    public func perform(
        _ request: URLRequest,
        body: Data
    ) async throws -> ASRHTTPResponse {
        try Task.checkCancellation()
        #if canImport(Darwin)
        return try await performBounded(request, body: body)
        #else
        // swift-corelibs-foundation does not expose the per-task streaming
        // delegate seam. Keep this transport source-compatible there; callers
        // that need a hard receive bound on that platform inject a bounded
        // `ASRHTTPTransport`. The adapter independently rejects an oversized
        // completed body.
        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw ASRTranscriptionError.providerRejected
        }
        guard data.count <= maximumResponseBodyBytes else {
            throw ASRTranscriptionError.responseTooLarge
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        return ASRHTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            url: http.url)
        #endif
    }

    #if canImport(Darwin)
    private func performBounded(
        _ request: URLRequest,
        body: Data
    ) async throws -> ASRHTTPResponse {
        let delegate = ASRBoundedHTTPTaskDelegate(
            maximumBytes: maximumResponseBodyBytes)
        let task = session.uploadTask(with: request, from: body)
        // A task-specific delegate is required: the injected session may have
        // no delegate, or the default session delegate belongs to another
        // feature. It also carries the redirect guard for this one request.
        task.delegate = delegate
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.start(continuation: continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ASRTranscriptionError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
    #endif
}

#if canImport(Darwin)
/// One-request `URLSessionDataDelegate`. It accumulates only up to the ceiling
/// and cancels the task as soon as a chunk (or declared Content-Length) would
/// exceed it, so an untrusted response is never materialized in full. The
/// continuation is resumed exactly once from the serial delegate queue.
final class ASRBoundedHTTPTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var response: HTTPURLResponse?
    private var body = Data()
    private var continuation: CheckedContinuation<ASRHTTPResponse, Error>?
    private var isFinished = false

    init(maximumBytes: Int) {
        self.maximumBytes = Swift.max(1, maximumBytes)
        super.init()
        body.reserveCapacity(Swift.min(maximumBytes, 64 * 1024))
    }

    func start(continuation: CheckedContinuation<ASRHTTPResponse, Error>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url ?? task.currentRequest?.url,
              let target = request.url,
              ASRRedirectGuard.isAllowed(from: original, to: target) else {
            // Do not forward a credential-bearing request to another origin.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(throwing: ASRTranscriptionError.providerRejected)
            completionHandler(.cancel)
            return
        }
        // Reject a declared oversize before a single body byte is downloaded.
        if http.expectedContentLength > Int64(maximumBytes) {
            finish(throwing: ASRTranscriptionError.responseTooLarge)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var overflow: CheckedContinuation<ASRHTTPResponse, Error>?
        lock.lock()
        if !isFinished {
            if data.count > maximumBytes || body.count > maximumBytes - data.count {
                isFinished = true
                overflow = continuation
                continuation = nil
                body = Data()
            } else {
                body.append(data)
            }
        }
        lock.unlock()
        guard let overflow else { return }
        dataTask.cancel()
        overflow.resume(throwing: ASRTranscriptionError.responseTooLarge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let http = response
        let body = self.body
        self.body = Data()
        lock.unlock()
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let http else {
            continuation.resume(throwing: ASRTranscriptionError.providerRejected)
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        continuation.resume(returning: ASRHTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: body,
            url: http.url))
    }

    private func finish(throwing error: Error) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        body = Data()
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
#endif

// MARK: - WebSocket transport

#if !canImport(FoundationNetworking)
// URLSessionWebSocketTask is Apple-platform API. Linux keeps the protocol
// seams (fake transports and vendor transports compile there); the native
// WebSocket implementation exists only where the SDK provides the task.
public struct URLSessionWebSocketTransport: ASRWebSocketTransport {
    public let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? ASRTransportSecurity.makeWebSocketSession()
    }

    public func connect(_ request: URLRequest) async throws -> any ASRWebSocketConnection {
        let task = session.webSocketTask(with: request)
        // Must be applied before resume so the ceiling is active from the
        // first inbound frame.
        task.maximumMessageSize = ASRTransportLimits.maximumWebSocketMessageBytes
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

/// Thin, idempotently-closable wrapper so the session code can be tested with
/// a fake connection implementing the same FloeCore protocol.
public final class URLSessionWebSocketConnection: ASRWebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var closed = false

    public init(task: URLSessionWebSocketTask) {
        self.task = task
        // Bound one inbound message before the handshake. Without this the
        // task's implicit buffering, not the adapter's event caps, decides how
        // much provider data can arrive. Chunked frames still fail in the
        // adapter when their assembled event exceeds its own smaller cap.
        task.maximumMessageSize = ASRTransportLimits.maximumWebSocketMessageBytes
    }

    public func send(_ message: ASRWebSocketMessage) async throws {
        let payload: URLSessionWebSocketTask.Message
        switch message {
        case .text(let text): payload = .string(text)
        case .data(let data): payload = .data(data)
        }
        try await task.send(payload)
    }

    public func receive() async throws -> ASRWebSocketMessage {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            // Defense in depth: `maximumMessageSize` is the native bound, but
            // never hand an oversized message to an adapter even if a platform
            // edge case delivers one.
            guard text.utf8.count <= ASRTransportLimits.maximumWebSocketMessageBytes else {
                throw ASRTranscriptionError.responseTooLarge
            }
            return .text(text)
        case .data(let data):
            guard data.count <= ASRTransportLimits.maximumWebSocketMessageBytes else {
                throw ASRTranscriptionError.responseTooLarge
            }
            return .data(data)
        @unknown default:
            throw ASRTranscriptionError.providerRejected
        }
    }

    public func close() {
        finish(code: .normalClosure)
    }

    public func cancel() {
        finish(code: .goingAway)
    }

    private func finish(code: URLSessionWebSocketTask.CloseCode) {
        let shouldCancel: Bool = {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return false }
            closed = true
            return true
        }()
        guard shouldCancel else { return }
        task.cancel(with: code, reason: nil)
    }
}
#endif
