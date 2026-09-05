// FloeExecution — Bounded outbound HTTP request.
//
// Gives the agent a narrow, budgeted way to call public APIs and fetch
// resources. Public targets require HTTPS; explicitly enabled LAN diagnostics
// also accept local HTTP. Redirects are revalidated and bodies are size-capped.

import Foundation
import Darwin

/// Bounded result of one HTTP exchange.
public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var contentType: String
    public var body: String
    public var truncated: Bool

    public init(statusCode: Int, contentType: String, body: String, truncated: Bool) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
        self.truncated = truncated
    }
}

public enum HTTPRequestError: Error, Sendable, LocalizedError {
    case invalidURL(String)
    case invalidMethod(String)
    case invalidHeaders(String)
    case privateNetworkTarget(String)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
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
    private let session: URLSession
    /// Whether private/local network targets are allowed. When true, the
    /// agent can reach LAN devices (smart home, HA, local servers). Requests
    /// to private IPs trigger iOS's local-network permission prompt on first
    /// use. When false (default), only public Internet targets are allowed.
    public let allowsPrivateNetwork: Bool

    public init(configuration: URLSessionConfiguration = .ephemeral, allowsPrivateNetwork: Bool = false) {
        let delegate: URLSessionTaskDelegate = allowsPrivateNetwork
            ? PrivateRedirectDelegate()
            : PublicRedirectDelegate()
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        self.allowsPrivateNetwork = allowsPrivateNetwork
    }

    public func send(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval,
        maxResponseBytes: Int
    ) async throws -> HTTPResponse {
        guard ["GET", "POST", "PUT", "DELETE", "HEAD"].contains(method.uppercased()) else {
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
            truncated: accepted.count < data.count
        )
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
    public func download(
        url: URL,
        timeout: TimeInterval,
        maxBytes: Int,
        to destination: URL
    ) async throws -> DownloadResult {
        if allowsPrivateNetwork {
            try DiagnosticNetworkTargetPolicy.validate(url)
        } else {
            try PublicNetworkTargetPolicy.validate(url)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(1, min(timeout, 120))

        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await session.download(for: request)
        } catch {
            throw HTTPRequestError.requestFailed(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
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

/// Deterministic public-network boundary shared by the initial request and
/// redirect delegate. DNS failure is fail-closed.
public enum PublicNetworkTargetPolicy {
    public static func validate(_ url: URL) throws {
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

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
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
            if !isPublic(address) {
                throw HTTPRequestError.privateNetworkTarget(host)
            }
            cursor = current.pointee.ai_next
        }
        guard foundAddress else { throw HTTPRequestError.invalidURL(url.absoluteString) }
    }

    public static func isAllowedHeader(_ name: String) -> Bool {
        let blocked = [
            "host", "connection", "content-length", "transfer-encoding",
            "proxy-authorization", "proxy-connection", "upgrade", "te", "trailer"
        ]
        return !blocked.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func isPublic(_ address: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let first = UInt8((ipv4 >> 24) & 0xff)
            let second = UInt8((ipv4 >> 16) & 0xff)
            if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
            if first == 100 && (64...127).contains(second) { return false }
            if first == 169 && second == 254 { return false }
            if first == 172 && (16...31).contains(second) { return false }
            if first == 192 && (second == 0 || second == 168) { return false }
            if first == 198 && (second == 18 || second == 19 || second == 51) { return false }
            if first == 203 && second == 0 { return false }
            return true
        case AF_INET6:
            let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
            guard bytes.count == 16 else { return false }
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }
            if bytes[0] & 0xfe == 0xfc { return false } // unique local fc00::/7
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return false } // link local
            if bytes[0] == 0xff { return false } // multicast
            if Array(bytes.prefix(4)) == [0x20, 0x01, 0x0d, 0xb8] { return false } // documentation
            if Array(bytes.prefix(12)) == Array(repeating: 0, count: 10) + [0xff, 0xff] {
                var mapped = sockaddr_in()
                mapped.sin_family = sa_family_t(AF_INET)
                let value = bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                mapped.sin_addr.s_addr = value.bigEndian
                return withUnsafePointer(to: &mapped) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1, isPublic)
                }
            }
            return true
        default:
            return false
        }
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
            ai_protocol: IPPROTO_TCP,
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
