// FloeAndroidWebTools — Android platform mirror of the ORIGINAL
// FloeAgent/Sources/FloeExecution/HTTPRequestService.swift. Every statement is
// byte-equal to the original except the deltas numbered below, each documented
// in shared/PROVENANCE.md. Darwin/macOS behaviour stays identical to the
// shipped original (the `bytes(for:)` path is preserved verbatim on Apple);
// the Android/Linux branch uses the qualified `FloeTransport` incremental
// seam (job-ca18980891c043b5) so a session that cannot host streaming fails
// closed instead of silently buffering.
//
// D1 (Main decision 2026-10-18, BRIDGE_V3_MAIN_DECISIONS.json +
// runtime-facade-contract D1/RB-6): minimal 5-file web.search/web.fetch
// closure. Deltas in this file:
//   1. Import block: `import Darwin` becomes the documented
//      Android/Glibc/Darwin + FoundationNetworking split; `FloeTransport`
//      is imported for the seam.
//   2. `PrivateNetworkTargetPolicy.validate`: `IPPROTO_TCP` is passed as
//      `Int32(IPPROTO_TCP)` (bionic defines the macro as `Int`; the value
//      and every other argument are unchanged; the cast is an identity
//      conversion on Darwin).
//   3. `init`: on os(Linux)/os(Android) the session is built through
//      `StreamingTransport.makeSession` with the SAME original redirect
//      delegate object as `policyDelegate` (redirect/auth decisions are
//      forwarded by the qualified router; no policy object is invented).
//      Apple keeps the exact original `URLSession(configuration:delegate:
//      delegateQueue:)` construction.
//   4. `send`: Apple keeps the original byte-by-byte `bytes(for:)` loop.
//      os(Linux)/os(Android) runs `WebBoundedStream.execute` below — the
//      REAL incremental chunk stream, bounded to the SAME cap+1 read amount
//      with the SAME truncated-within-cap original return semantics (no
//      `responseTooLarge` behavior change), cancelling the owned task after
//      the cap is crossed (strictly safer than abandoning the iterator).
//      The shared post-processing (prefix(cap), truncated flag, headers,
//      finalURL) is unchanged.
//   5. `download`/`commitDownload`/policies/IPAddress/resultHeaders:
//      UNCHANGED original code; they compile on Android unchanged
//      (`download(for:)` exists in FoundationNetworking). Device behaviour
//      of the async download cancellation seam remains Main's gate.
// FloeExecution — Bounded outbound HTTP request.
//
// Gives the agent a narrow, budgeted way to call public APIs and fetch
// resources. Public targets require HTTPS; explicitly enabled LAN diagnostics
// also accept local HTTP. Redirects are revalidated and bodies are size-capped.

import Foundation
#if canImport(Android)
import Android
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore
import FloeTools
import FloeTransport

/// Bounded result of one HTTP exchange.
public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var contentType: String
    public var body: String
    public var truncated: Bool
    public var finalURL: String?
    public var headers: [String: String]

    public init(statusCode: Int, contentType: String, body: String, truncated: Bool, finalURL: String? = nil, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
        self.truncated = truncated
        self.finalURL = finalURL
        self.headers = headers
    }
}

public enum HTTPRequestError: Error, Sendable, LocalizedError {
    case httpStatus(Int)
    case invalidURL(String)
    case invalidMethod(String)
    case invalidHeaders(String)
    case privateNetworkTarget(String)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "HTTP request failed: download returned HTTP \(code); no destination file was created"
        case .invalidURL(let url): "Invalid URL: \(url)"
        case .invalidMethod(let method): "Unsupported HTTP method: \(method)"
        case .invalidHeaders(let detail): "Invalid headers: \(detail)"
        case .privateNetworkTarget(let host): "Private or non-public network target is not allowed: \(host)"
        case .requestFailed(let detail): "HTTP request failed: \(detail)"
        }
    }
}

/// Performs bounded HTTPS and opt-in local HTTP requests. Every redirect is
/// revalidated and cross-origin credentials are stripped. The policy is immutable
/// so initial-request validation cannot diverge from its redirect delegate.
public struct HTTPRequestService: Sendable {
    /// Internal for privacy-audit tests: the transport configuration must
    /// stay ephemeral (no shared on-disk cache/cookie/credential state).
    let session: URLSession
    /// Whether private/local network targets are allowed. When true, the
    /// agent can reach LAN devices (smart home, HA, local servers). Requests
    /// to private IPs trigger iOS's local-network permission prompt on first
    /// use. When false (default), only public Internet targets are allowed.
    public let allowsPrivateNetwork: Bool

    public init(configuration: URLSessionConfiguration = .ephemeral, allowsPrivateNetwork: Bool = false) {
        // This shared service is stateless: one task must not inherit another
        // task's website login. Explicit headers remain supported. Stateful
        // scripted workflows keep their cookie jar in their own workspace.
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        #if os(Linux) || os(Android)
        // Delta 3: FoundationNetworking has no `bytes(for:)`, so the product
        // session must host the incremental transport. `makeStreamingSession`
        // installs the ORIGINAL redirect delegate as the router's policy
        // object; nothing else about the configuration changes.
        self.session = Self.makeStreamingSession(configuration: configuration,
                                                 allowsPrivateNetwork: allowsPrivateNetwork)
        #else
        let delegate: URLSessionTaskDelegate = allowsPrivateNetwork
            ? PrivateRedirectDelegate()
            : PublicRedirectDelegate()
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        #endif
        self.allowsPrivateNetwork = allowsPrivateNetwork
    }

    /// Compiled on EVERY platform and used verbatim by the Android/Linux
    /// `init` branch; host tests run this exact construction so the delegate
    /// wiring (original `PublicRedirectDelegate` / `PrivateRedirectDelegate`
    /// objects forwarded through the qualified `FloeTransport` router) has
    /// real behavioural coverage before the device gate. A plain session is
    /// never substituted: reads against a non-streaming session fail closed
    /// (`IncrementalTransportError.sessionNotStreamable`).
    static func makeStreamingSession(configuration: URLSessionConfiguration,
                                     allowsPrivateNetwork: Bool) -> URLSession {
        let delegate: URLSessionTaskDelegate = allowsPrivateNetwork
            ? PrivateRedirectDelegate()
            : PublicRedirectDelegate()
        return StreamingTransport.makeSession(configuration: configuration,
                                              policyDelegate: delegate)
    }

    public func send(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval,
        maxResponseBytes: Int
    ) async throws -> HTTPResponse {
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method.uppercased()) else {
            throw HTTPRequestError.invalidMethod(method)
        }
        if allowsPrivateNetwork {
            try DiagnosticNetworkTargetPolicy.validate(url)
        } else {
            try PublicNetworkTargetPolicy.validate(url)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.timeoutInterval = max(1, min(timeout, 120))
        for (key, value) in headers {
            guard PublicNetworkTargetPolicy.isAllowedHeader(key) else {
                throw HTTPRequestError.invalidHeaders("header is not allowed: \(key)")
            }
            request.setValue(value, forHTTPHeaderField: key)
        }
        if method.uppercased() != "GET", method.uppercased() != "HEAD" {
            request.httpBody = body
        }

        let (data, response): (Data, URLResponse)
        #if os(Linux) || os(Android)
        // Delta 4: the bounded incremental read of the original below is
        // replaced by the real streaming seam. The ORIGINAL outcome is kept:
        // the first `cap` bytes with `truncated == true` when the body is
        // larger — NOT a `responseTooLarge` error, which would silently
        // change tool behaviour. Transport failures keep the original
        // `requestFailed(error.localizedDescription)` mapping.
        do {
            (data, response) = try await WebBoundedStream.execute(
                request,
                via: session,
                cap: max(1, min(maxResponseBytes, 256 * 1024)))
        } catch {
            throw HTTPRequestError.requestFailed(error.localizedDescription)
        }
        #else
        do {
            let (bytes, receivedResponse) = try await session.bytes(for: request)
            var bounded = Data()
            let cap = max(1, min(maxResponseBytes, 256 * 1024))
            for try await byte in bytes {
                bounded.append(byte)
                if bounded.count > cap { break }
            }
            data = bounded
            response = receivedResponse
        } catch {
            throw HTTPRequestError.requestFailed(error.localizedDescription)
        }
        #endif
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let cap = max(1, min(maxResponseBytes, 256 * 1024))
        let accepted = data.prefix(cap)
        let body = String(decoding: accepted, as: UTF8.self)
        return HTTPResponse(
            statusCode: statusCode,
            contentType: contentType,
            body: body,
            truncated: accepted.count < data.count,
            finalURL: response.url?.absoluteString,
            headers: Self.resultHeaders(http)
        )
    }

    /// Only navigation/cache/rate-limit metadata is returned automatically.
    /// Cookies and authentication challenges are not copied into model context.
    static func resultHeaders(_ response: HTTPURLResponse?) -> [String: String] {
        var result: [String: String] = [:]
        for name in ["Content-Type", "Location", "Link", "ETag", "Last-Modified",
                     "Retry-After", "Allow", "Content-Disposition", "Content-Length"] {
            if let value = response?.value(forHTTPHeaderField: name) {
                result[name.lowercased()] = String(value.prefix(4096))
            }
        }
        return result
    }

    /// Bounded result of one GET download saved to disk.
    public struct DownloadResult: Sendable, Equatable {
        public var statusCode: Int
        public var contentType: String
        public var byteCount: Int64

        public init(statusCode: Int, contentType: String, byteCount: Int64) {
            self.statusCode = statusCode
            self.contentType = contentType
            self.byteCount = byteCount
        }
    }

    /// Downloads a GET response to `destination` through the same redirect-
    /// revalidating session used by `send`. The payload is bounded by
    /// `maxBytes`: an oversized download is deleted and reported as an error
    /// instead of being partially kept.
    ///
    /// `cancellation` is observed while the transfer is in flight: the
    /// underlying URLSession task is cancelled and `FloeError.cancelled` is
    /// thrown, so a shell command that owns this download can stop promptly
    /// instead of holding the engine's run gate until the network timeout.
    public func download(
        url: URL,
        timeout: TimeInterval,
        maxBytes: Int,
        to destination: URL,
        cancellation: CancellationToken? = nil
    ) async throws -> DownloadResult {
        try cancellation?.throwIfCancelled()
        if allowsPrivateNetwork {
            try DiagnosticNetworkTargetPolicy.validate(url)
        } else {
            try PublicNetworkTargetPolicy.validate(url)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(1, min(timeout, 120))

        let (temporary, response): (URL, URLResponse)
        let downloadTask = Task { try await self.session.download(for: request) }
        // Cooperative cancellation: a shell command that owns this download
        // must be able to stop the transfer and release the engine run gate
        // instead of waiting for the URLSession timeout.
        let watcher = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true {
                    downloadTask.cancel()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { watcher.cancel() }
        do {
            (temporary, response) = try await downloadTask.value
        } catch is CancellationError {
            throw FloeError.cancelled
        } catch {
            if cancellation?.isCancelled == true { throw FloeError.cancelled }
            throw HTTPRequestError.requestFailed(error.localizedDescription)
        }
        try cancellation?.throwIfCancelled()
        return try Self.commitDownload(temporary: temporary, response: response, maxBytes: maxBytes, destination: destination)
    }

    static func commitDownload(temporary: URL, response: URLResponse, maxBytes: Int, destination: URL) throws -> DownloadResult {
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw HTTPRequestError.httpStatus(statusCode)
        }
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        let cap = Int64(max(1, min(maxBytes, 64 * 1_024 * 1_024)))
        guard size <= cap else {
            try? FileManager.default.removeItem(at: temporary)
            throw HTTPRequestError.requestFailed("download exceeds the \(cap)-byte limit")
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw HTTPRequestError.requestFailed("downloaded file could not be saved: \(error.localizedDescription)")
        }
        return DownloadResult(statusCode: statusCode, contentType: contentType, byteCount: size)
    }
}

/// The Android/Linux bounded read body for `send`. Compiled on EVERY
/// platform; the Darwin branch above keeps the original `bytes(for:)` loop
/// byte-identical, and host tests run THIS exact function against the
/// delegate transport (same pattern as `BoundedHTTP.androidBounded` and
/// `MCPIncrementalCollect.execute` in the qualified transport lane).
///
/// Original semantics preserved:
/// - The response is read at most `cap + 1` bytes worth of stream (the
///   original breaks after exceeding `cap`); the caller keeps applying the
///   original `prefix(cap)` + `truncated` math, so an oversized body is a
///   SUCCESS with `truncated == true`, never a thrown `responseTooLarge`.
/// - Stream mode never cancels on a declared `Content-Length` alone (the
///   original `bytes(for:)` reads anyway); the bounded IN-FLIGHT queue is
///   the only transport backpressure, mirroring the provider seam.
/// - Status/body/header handling stays in the original code path; this
///   helper returns exactly `(body, finalResponse)` like the original tuple.
/// - On Android the abandoned iterator additionally cancels the owned
///   `URLSessionTask` explicitly (the original Apple path abandons
///   `bytes(for:)` and lets the platform tear the task down). Early owned
///   cancellation is strictly safer and is the qualified transport
///   behaviour; the returned bytes and flags are identical.
/// - A plain (non-streaming) session throws `sessionNotStreamable` here and
///   is mapped to the original `requestFailed` at the call site — never a
///   silent session recreation or full-buffer fallback.
/// - One documented degradation: a transport failure BEFORE any response
///   head surfaces here as `IncrementalTransportError.noHTTPResponse` (the
///   router does not replay the platform error through the response
///   waiter). The call-site mapping is unchanged (`requestFailed` with a
///   platform description); only the diagnostic text of the detail can
///   differ on Android. Device confirmation stays with Main.
enum WebBoundedStream {
    /// In-flight ceiling between the delegate callback and this consumer.
    /// The body read stops at `cap + 1` (cap ≤ 256 KiB), so 1 MiB of queued
    /// chunks can never be needed by a successful read; saturating it means
    /// the consumer task was starved, and the original would have kept
    /// buffering unboundedly — we cancel with an explicit recoverable error
    /// instead, matching the qualified provider/MCP seams.
    static let maxInFlightBytes = 1_024 * 1024

    static func execute(_ request: URLRequest,
                        via session: URLSession,
                        cap: Int) async throws -> (Data, URLResponse) {
        let stream = try StreamingTransport.stream(request, via: session,
                                                   maxBufferedBytes: maxInFlightBytes)
        let response: URLResponse
        do {
            response = try await stream.response()
        } catch {
            stream.cancelOwned()
            throw error
        }
        var bounded = Data()
        do {
            for try await chunk in stream {
                bounded.append(chunk)
                if bounded.count > cap { break }
            }
        } catch let error as IncrementalTransportError {
            if case .pendingBufferSaturated = error, bounded.count > cap {
                // The cap was already crossed with real body bytes: the
                // original returned the truncated body here. Saturation
                // after the crossing cannot change that outcome.
            } else {
                stream.cancelOwned()
                throw error
            }
        } catch {
            stream.cancelOwned()
            throw error
        }
        // The original `break` abandoned the iterator at cap+1 bytes; here
        // the owned task is explicitly cancelled (idempotent, fenced) so a
        // stalled server can never keep the request alive after the cap.
        stream.cancelOwned()
        return (bounded, response)
    }
}

/// Deterministic public-network boundary shared by the initial request and
/// redirect delegate. DNS failure is fail-closed.
public enum PublicNetworkTargetPolicy {
    public static func validate(_ url: URL) throws {
        try validate(url, allowTransientTunnelAddresses: false)
    }

    /// When `allowTransientTunnelAddresses` is true, DNS answers in the
    /// 198.18.0.0/15 fake-IP range are accepted for this request. Callers
    /// grant this only for a fixed built-in provider endpoint bound to a
    /// specific provider kind (see WebSearchService.allowsTransientTunnel);
    /// every other non-public range is still rejected and resolution stays
    /// fail-closed.
    public static func validate(_ url: URL, allowTransientTunnelAddresses: Bool) throws {
        try validate(
            url,
            allowTransientTunnelAddresses: allowTransientTunnelAddresses,
            resolve: NetworkDestinationPolicy.systemResolve
        )
    }

    /// Package-internal resolver seam for deterministic integration tests.
    /// Production callers always use the system resolver above.
    static func validate(
        _ url: URL,
        allowTransientTunnelAddresses: Bool,
        resolve: @Sendable (String) throws -> [String]
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw HTTPRequestError.invalidURL(url.absoluteString)
        }
        let deniedSuffixes = ["localhost", ".localhost", ".local", ".internal", ".lan", ".home"]
        guard !deniedSuffixes.contains(where: { host == $0 || host.hasSuffix($0) }) else {
            throw HTTPRequestError.privateNetworkTarget(host)
        }
        do {
            try NetworkDestinationPolicy.validate(
                host: host,
                allowTransientTunnel: allowTransientTunnelAddresses,
                resolve: resolve
            )
        } catch NetworkDestinationError.privateTarget {
            throw HTTPRequestError.privateNetworkTarget(host)
        } catch {
            throw HTTPRequestError.invalidURL(url.absoluteString)
        }
    }

    public static func isAllowedHeader(_ name: String) -> Bool {
        let blocked = [
            "host", "connection", "content-length", "transfer-encoding",
            "proxy-authorization", "proxy-connection", "upgrade", "te", "trailer"
        ]
        return !blocked.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

private final class PublicRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, (try? PublicNetworkTargetPolicy.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        var next = request
        if Self.origin(task.currentRequest?.url) != Self.origin(url) {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        }
        completionHandler(next)
    }

    private static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        return "\(scheme)://\(host):\(url.port ?? 443)"
    }
}

/// Allows private/local network targets (LAN devices, smart home, local
/// servers). Requests to private IPs trigger iOS's local-network permission
/// prompt on first use. Redirects are revalidated and cross-origin
/// credentials are stripped.
enum PrivateNetworkTargetPolicy {
    static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw HTTPRequestError.invalidURL(url.absoluteString)
        }
        // Resolve names as well as literals: a local-looking suffix must not
        // bypass address validation or reach a metadata/link-local service.
        // Validate IP ranges directly for numeric hosts.
        if let ip = IPAddress(host) {
            if ip.isPrivate || ip.isLoopback {
                return
            }
        }
        // For DNS names, resolve and check all addresses.
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: Int32(IPPROTO_TCP),
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw HTTPRequestError.invalidURL(url.absoluteString)
        }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var foundAddress = false
        while let current = cursor {
            guard let address = current.pointee.ai_addr else {
                cursor = current.pointee.ai_next
                continue
            }
            foundAddress = true
            if !isPrivateOrLocal(address) {
                throw HTTPRequestError.privateNetworkTarget(host)
            }
            cursor = current.pointee.ai_next
        }
        guard foundAddress else { throw HTTPRequestError.invalidURL(url.absoluteString) }
    }

    static func isAllowedHeader(_ name: String) -> Bool {
        PublicNetworkTargetPolicy.isAllowedHeader(name)
    }

    private static func isPrivateOrLocal(_ address: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let first = UInt8((ipv4 >> 24) & 0xff)
            let second = UInt8((ipv4 >> 16) & 0xff)
            if first == 10 { return true }
            if first == 172 && (16...31).contains(second) { return true }
            if first == 192 && second == 168 { return true }
            if first == 127 { return true } // loopback
            return false
        case AF_INET6:
            let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
            guard bytes.count == 16 else { return false }
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true } // loopback
            if bytes[0] & 0xfe == 0xfc { return true } // unique local fc00::/7
            return false
        default:
            return false
        }
    }
}

private struct IPAddress {
    let bytes: [UInt8]
    let isIPv6: Bool

    init?(_ string: String) {
        if string.contains(":") {
            isIPv6 = true
            var addr = in6_addr()
            guard string.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
            bytes = withUnsafeBytes(of: &addr) { Array($0) }
        } else {
            isIPv6 = false
            var addr = in_addr()
            guard string.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
            bytes = withUnsafeBytes(of: &addr) { Array($0) }
        }
    }

    var isPrivate: Bool {
        if isIPv6 {
            guard bytes.count == 16 else { return false }
            if bytes[0] & 0xfe == 0xfc { return true } // fc00::/7
            return false
        } else {
            guard bytes.count == 4 else { return false }
            let first = bytes[0]
            let second = bytes[1]
            if first == 10 { return true }
            if first == 172 && (16...31).contains(second) { return true }
            if first == 192 && second == 168 { return true }
            return false
        }
    }

    var isLoopback: Bool {
        if isIPv6 {
            guard bytes.count == 16 else { return false }
            return bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1
        } else {
            guard bytes.count == 4 else { return false }
            return bytes[0] == 127
        }
    }

    var isLinkLocal: Bool {
        if isIPv6 {
            guard bytes.count == 16 else { return false }
            return bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        } else {
            guard bytes.count == 4 else { return false }
            return bytes[0] == 169 && bytes[1] == 254
        }
    }
}

public enum DiagnosticNetworkTargetPolicy {
    public static func validate(_ url: URL) throws {
        if (try? PrivateNetworkTargetPolicy.validate(url)) != nil { return }
        try PublicNetworkTargetPolicy.validate(url)
    }
}

private final class PrivateRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, (try? DiagnosticNetworkTargetPolicy.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        var next = request
        if Self.origin(task.currentRequest?.url) != Self.origin(url) {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        }
        completionHandler(next)
    }

    private static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        return "\(scheme)://\(host):\(url.port ?? 443)"
    }
}
