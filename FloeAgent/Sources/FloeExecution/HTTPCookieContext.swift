// FloeExecution — explicit HTTP cookie context and stateful cookie jar.
//
// The default HTTP transport is stateless and sends no cookies. This file
// adds two opt-in modes used by the browser-aware fetch/http tools:
//
//  * a bounded snapshot of cookies supplied by the task browser (the app owns
//    that provider; this module never reaches into WebKit), and
//  * an in-memory per-task jar used only when a caller explicitly asks for a
//    stateful HTTP exchange. It never falls back to URLSession/global cookies.
//
// Every cookie is checked against the request URL on every redirect: domain,
// path, Secure, expiry and SameSite. Cross-origin redirects keep the existing
// Authorization stripping and recompute the Cookie header from the snapshot,
// so a redirect can never widen cookie credentials.

import Foundation

/// Immutable, transport-neutral representation of one HTTP cookie.
///
/// `value` is a secret. Tools may return it only for an explicit raw-value
/// read; ordinary logs, durable captures and diagnostics must print counts and
/// metadata instead.
public struct HTTPCookieSnapshot: Sendable, Codable, Equatable, Hashable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expiresAt: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var isSessionOnly: Bool
    public var sameSite: String?

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expiresAt: Date? = nil,
        isSecure: Bool = false,
        isHTTPOnly: Bool = false,
        isSessionOnly: Bool = true,
        sameSite: String? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.isSessionOnly = isSessionOnly
        self.sameSite = sameSite
    }
}

public enum HTTPCookiePolicyError: Error, Sendable, LocalizedError, Equatable {
    case invalidName
    case invalidValue
    case invalidDomain
    case invalidPath
    case domainMismatch
    case secureRequiresHTTPS
    case invalidExpiry
    case invalidSameSite
    case tooManyCookies

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Cookie name is empty or contains an invalid character"
        case .invalidValue: "Cookie value is empty of controls or exceeds the bounded size"
        case .invalidDomain: "Cookie domain is invalid"
        case .invalidPath: "Cookie path is invalid"
        case .domainMismatch: "Cookie domain does not match the current page"
        case .secureRequiresHTTPS: "A Secure cookie requires HTTPS"
        case .invalidExpiry: "Cookie expiry is in the past or invalid"
        case .invalidSameSite: "SameSite must be lax, strict or none (none requires Secure)"
        case .tooManyCookies: "Too many cookies for one request"
        }
    }
}

public enum HTTPCookiePolicy {
    public static let maximumCookieBytes = 4 * 1_024
    public static let maximumHeaderBytes = 32 * 1_024
    public static let maximumCookiesPerRequest = 128

    // MARK: - Snapshot conversion

    public static func snapshot(from cookie: HTTPCookie) -> HTTPCookieSnapshot {
        HTTPCookieSnapshot(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expiresAt: cookie.expiresDate,
            isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly,
            isSessionOnly: cookie.isSessionOnly,
            sameSite: cookie.sameSitePolicy?.rawValue
        )
    }

    public static func httpCookie(from snapshot: HTTPCookieSnapshot) -> HTTPCookie? {
        guard let normalized = try? normalize(snapshot, setting: true, url: nil) else {
            return nil
        }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: normalized.name,
            .value: normalized.value,
            .domain: normalized.domain,
            .path: normalized.path
        ]
        if let expiresAt = normalized.expiresAt {
            properties[.expires] = expiresAt
        }
        if normalized.isSecure {
            properties[.secure] = "TRUE"
        }
        if normalized.isHTTPOnly {
            // Foundation parses Set-Cookie HttpOnly but exposes no public
            // property-key constant; the extensible key round-trips through
            // HTTPCookie and WKHTTPCookieStore on public API only.
            properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE"
        }
        if let sameSite = normalized.sameSite {
            properties[.sameSitePolicy] = sameSite
        }
        return HTTPCookie(properties: properties)
    }

    // MARK: - Validation

    /// Validates and normalizes a cookie for a concrete URL. `setting` adds
    /// the public-suffix-like and domain-suffix checks that are required when
    /// a tool or response wants to store a new cookie. Sending only needs the
    /// cookie to match the request.
    public static func validatedForSetting(
        _ cookie: HTTPCookieSnapshot,
        for url: URL
    ) throws -> HTTPCookieSnapshot {
        try normalize(cookie, setting: true, url: url)
    }

    public static func validatedForSending(
        _ cookie: HTTPCookieSnapshot,
        for url: URL
    ) -> HTTPCookieSnapshot? {
        try? normalize(cookie, setting: false, url: url)
    }

    private static func normalize(
        _ cookie: HTTPCookieSnapshot,
        setting: Bool,
        url: URL?
    ) throws -> HTTPCookieSnapshot {
        let name = cookie.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.contains(where: { $0 == "=" || $0 == ";" || $0 == "," || $0.isWhitespace || $0.isNewline }),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw HTTPCookiePolicyError.invalidName
        }
        guard cookie.value.utf8.count <= maximumCookieBytes,
              !cookie.value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw HTTPCookiePolicyError.invalidValue
        }

        let rawDomain = cookie.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !rawDomain.isEmpty, rawDomain.utf8.count <= 253,
              !rawDomain.contains(where: { $0 == "/" || $0 == ":" || $0 == "?" || $0 == "#" || $0.isWhitespace || $0.isNewline }),
              !rawDomain.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw HTTPCookiePolicyError.invalidDomain
        }
        let domain = rawDomain
        let cookieHost = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard !cookieHost.isEmpty, !cookieHost.hasPrefix("."), !cookieHost.hasSuffix(".") else {
            throw HTTPCookiePolicyError.invalidDomain
        }

        var normalizedPath = cookie.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedPath.isEmpty { normalizedPath = "/" }
        guard normalizedPath.hasPrefix("/"), normalizedPath.utf8.count <= 1_024,
              !normalizedPath.contains(";"),
              !normalizedPath.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw HTTPCookiePolicyError.invalidPath
        }

        let sameSite = cookie.sameSite?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let sameSite, !["lax", "strict", "none"].contains(sameSite) {
            throw HTTPCookiePolicyError.invalidSameSite
        }
        let secure = cookie.isSecure
        if sameSite == "none", !secure {
            throw HTTPCookiePolicyError.invalidSameSite
        }

        if let expiresAt = cookie.expiresAt, expiresAt <= Date() {
            if setting { throw HTTPCookiePolicyError.invalidExpiry }
        }

        if let url {
            guard let host = url.host?.lowercased(), !host.isEmpty else {
                throw HTTPCookiePolicyError.invalidDomain
            }
            let hostMatches = host == cookieHost
                || (domain.hasPrefix(".") && host.hasSuffix("." + cookieHost))
            guard hostMatches else { throw HTTPCookiePolicyError.domainMismatch }
            if setting, !isLoopback(host) {
                // A single-label Domain (for example "com") could be shared
                // beyond the current site. Host-only single-label targets
                // such as localhost are still allowed.
                guard cookieHost.contains(".") else { throw HTTPCookiePolicyError.invalidDomain }
            }
            if secure, url.scheme?.lowercased() != "https", !isLoopback(host) {
                throw HTTPCookiePolicyError.secureRequiresHTTPS
            }
        } else if secure {
            // Constructing a cookie without a URL is only used by callers that
            // already validated the browser origin.
        }

        return HTTPCookieSnapshot(
            name: name,
            value: cookie.value,
            domain: domain,
            path: normalizedPath,
            expiresAt: cookie.expiresAt,
            isSecure: secure,
            isHTTPOnly: cookie.isHTTPOnly,
            isSessionOnly: cookie.expiresAt == nil,
            sameSite: sameSite
        )
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    // MARK: - Response Set-Cookie

    /// Parses every Set-Cookie header on a response. Expired cookies are kept
    /// so a stateful jar can apply a server deletion (`Max-Age=0`); the send
    /// path filters them out.
    public static func parsedSetCookies(
        from response: HTTPURLResponse,
        requestURL: URL
    ) -> [HTTPCookieSnapshot] {
        let url = response.url ?? requestURL
        var headers: [String] = []
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie" else { continue }
            if let string = value as? String {
                headers.append(contentsOf: splitSetCookieHeader(string))
            }
        }
        var cookies: [HTTPCookieSnapshot] = []
        for header in headers.prefix(64) {
            let parsed = HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": header],
                for: url
            )
            for cookie in parsed {
                let snapshot = snapshot(from: cookie)
                if let normalized = try? normalize(snapshot, setting: true, url: url) {
                    cookies.append(normalized)
                } else if let normalized = try? normalize(snapshot, setting: false, url: url) {
                    // Expired/deletion cookies fail the setting check (past
                    // expiry) but still need to reach the stateful jar.
                    cookies.append(normalized)
                }
            }
        }
        return Array(cookies.prefix(maximumCookiesPerRequest))
    }

    public static func parsedSetCookies(
        from headers: [String],
        for url: URL
    ) -> [HTTPCookieSnapshot] {
        var result: [HTTPCookieSnapshot] = []
        for header in headers.prefix(64) {
            for piece in splitSetCookieHeader(header) {
                let parsed = HTTPCookie.cookies(
                    withResponseHeaderFields: ["Set-Cookie": piece],
                    for: url
                )
                for cookie in parsed {
                    let snapshot = snapshot(from: cookie)
                    if let normalized = try? normalize(snapshot, setting: true, url: url) {
                        result.append(normalized)
                    } else if let normalized = try? normalize(snapshot, setting: false, url: url) {
                        result.append(normalized)
                    }
                }
            }
        }
        return Array(result.prefix(maximumCookiesPerRequest))
    }

    /// Splits a possibly folded Set-Cookie header without splitting the comma
    /// inside an Expires date. Cookie values cannot contain an unquoted comma
    /// under RFC 6265; quoted commas are preserved.
    public static func splitSetCookieHeader(_ header: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        let characters = Array(header)
        for (index, character) in characters.enumerated() {
            current.append(character)
            if escaped { escaped = false; continue }
            if character == "\\", quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            guard character == ",", !quoted else { continue }
            var lookahead = index + 1
            while lookahead < characters.count, characters[lookahead] == " " { lookahead += 1 }
            var tokenEnd = lookahead
            while tokenEnd < characters.count, characters[tokenEnd] != "=", characters[tokenEnd] != ";", characters[tokenEnd] != "," { tokenEnd += 1 }
            guard tokenEnd < characters.count, characters[tokenEnd] == "=", tokenEnd > lookahead else { continue }
            // The comma is a separator: remove it from the current piece.
            if current.hasSuffix(",") { current.removeLast() }
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pieces.append(trimmed) }
        return pieces
    }

    // MARK: - Request Cookie header

    /// Domain-only match for management views. It deliberately ignores path,
    /// Secure and expiry so a site can list and delete all of its own cookies;
    /// the sending path uses `matchingCookies` instead.
    public static func domainMatches(
        _ cookie: HTTPCookieSnapshot,
        for url: URL
    ) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let cookieHost = cookie.domain.hasPrefix(".")
            ? String(cookie.domain.dropFirst()).lowercased()
            : cookie.domain.lowercased()
        return host == cookieHost
            || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + cookieHost))
    }

    public static func matchingCookies(
        for url: URL,
        cookies: [HTTPCookieSnapshot]
    ) -> [HTTPCookieSnapshot] {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https" || isLoopback(host)
        let now = Date()
        return cookies.compactMap { cookie in
            guard let normalized = try? normalize(cookie, setting: false, url: url) else { return nil }
            let cookieHost = normalized.domain.hasPrefix(".")
                ? String(normalized.domain.dropFirst())
                : normalized.domain
            let domainMatches = host == cookieHost
                || (normalized.domain.hasPrefix(".") && host.hasSuffix("." + cookieHost))
            guard domainMatches else { return nil }
            guard path == normalized.path
                || path.hasPrefix(normalized.path.hasSuffix("/") ? normalized.path : normalized.path + "/") else { return nil }
            guard !normalized.isSecure || secure else { return nil }
            guard normalized.expiresAt.map({ $0 > now }) ?? true else { return nil }
            if normalized.sameSite == "none", !normalized.isSecure { return nil }
            return normalized
        }
        .sorted { $0.path.count > $1.path.count }
    }

    public static func cookieHeader(
        for url: URL,
        cookies: [HTTPCookieSnapshot]
    ) -> String? {
        let matched = matchingCookies(for: url, cookies: cookies)
        guard !matched.isEmpty else { return nil }
        var header = ""
        for cookie in matched.prefix(maximumCookiesPerRequest) {
            let pair = "\(cookie.name)=\(cookie.value)"
            if !header.isEmpty {
                if header.utf8.count + 2 + pair.utf8.count > maximumHeaderBytes { break }
                header += "; "
            }
            header += pair
        }
        return header.isEmpty ? nil : header
    }

    // MARK: - Origin

    public static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        if let port = url.port ?? defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = origin(lhs), let right = origin(rhs) else { return false }
        return left == right
    }
}

/// Explicit transient cookie input accepted by web.fetch/network.http.
public struct HTTPCookieInput: Decodable, Sendable {
    public var name: String
    public var value: String
    public var domain: String?
    public var path: String?
    public var secure: Bool?
    public var httpOnly: Bool?
    public var expiresAt: String?
    public var sameSite: String?

    public init(
        name: String,
        value: String,
        domain: String? = nil,
        path: String? = nil,
        secure: Bool? = nil,
        httpOnly: Bool? = nil,
        expiresAt: String? = nil,
        sameSite: String? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.httpOnly = httpOnly
        self.expiresAt = expiresAt
        self.sameSite = sameSite
    }
}

public enum HTTPCookieInputParser {
    public static func parse(_ raw: String?, for url: URL) throws -> [HTTPCookieSnapshot] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        guard raw.utf8.count <= 64 * 1_024,
              let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([HTTPCookieInput].self, from: data) else {
            throw HTTPCookiePolicyError.invalidValue
        }
        guard arguments.count <= HTTPCookiePolicy.maximumCookiesPerRequest else {
            throw HTTPCookiePolicyError.tooManyCookies
        }
        let host = url.host ?? ""
        let formatter = ISO8601DateFormatter()
        var result: [HTTPCookieSnapshot] = []
        for argument in arguments {
            let expires = argument.expiresAt.flatMap { formatter.date(from: $0) }
            let snapshot = HTTPCookieSnapshot(
                name: argument.name,
                value: argument.value,
                domain: argument.domain ?? host,
                path: argument.path ?? "/",
                expiresAt: expires,
                isSecure: argument.secure ?? (url.scheme?.lowercased() == "https"),
                isHTTPOnly: argument.httpOnly ?? true,
                isSessionOnly: expires == nil,
                sameSite: argument.sameSite
            )
            result.append(try HTTPCookiePolicy.validatedForSetting(snapshot, for: url))
        }
        return result
    }
}

/// Optional in-memory jar for an explicitly stateful HTTP exchange. It is
/// owned by the task identity the runtime issued, never by a URL or model
/// argument, and it is deliberately not durable across app launches.
public actor HTTPStatefulCookieStore {
    public static let shared = HTTPStatefulCookieStore()

    private struct Jar {
        var cookies: [String: HTTPCookieSnapshot]
        var lastUsed: Date
    }

    private var jars: [UUID: Jar] = [:]
    private let maximumTasks = 64
    private let maximumCookies = 128
    private let idleTTL: TimeInterval = 30 * 60

    public init() {}

    public func cookies(for taskID: UUID, now: Date = Date()) -> [HTTPCookieSnapshot] {
        prune(now: now)
        guard let jar = jars[taskID] else { return [] }
        return Array(jar.cookies.values).filter { $0.expiresAt.map({ $0 > now }) ?? true }
    }

    /// Applies a response's Set-Cookie directives. Returns the number of live
    /// cookies after the merge, not the values.
    @discardableResult
    public func merge(
        _ cookies: [HTTPCookieSnapshot],
        for taskID: UUID,
        now: Date = Date()
    ) -> Int {
        prune(now: now)
        var jar = jars[taskID] ?? Jar(cookies: [:], lastUsed: now)
        for cookie in cookies.prefix(HTTPCookiePolicy.maximumCookiesPerRequest) {
            let key = "\(cookie.name)\u{1f}\(cookie.domain)\u{1f}\(cookie.path)"
            if let expiresAt = cookie.expiresAt, expiresAt <= now {
                jar.cookies.removeValue(forKey: key)
            } else {
                jar.cookies[key] = cookie
            }
        }
        if jar.cookies.count > maximumCookies {
            let overflow = jar.cookies.count - maximumCookies
            for key in jar.cookies.keys.sorted().prefix(overflow) {
                jar.cookies.removeValue(forKey: key)
            }
        }
        jar.lastUsed = now
        jars[taskID] = jar
        return jar.cookies.count
    }

    public func clear(taskID: UUID) {
        jars.removeValue(forKey: taskID)
    }

    private func prune(now: Date) {
        jars = jars.filter { now.timeIntervalSince($0.value.lastUsed) <= idleTTL }
        if jars.count > maximumTasks {
            let overflow = jars.count - maximumTasks
            for key in jars.keys.sorted(by: { jars[$0]!.lastUsed < jars[$1]!.lastUsed }).prefix(overflow) {
                jars.removeValue(forKey: key)
            }
        }
    }
}

/// What the task browser contributes to one outbound HTTP/web.fetch call.
public struct BrowserWebContext: Sendable, Equatable {
    public var cookies: [HTTPCookieSnapshot]
    /// `nil` means the WebKit default user agent. A non-nil value is the
    /// browser tab's custom UA (settings-managed) and is never inferred from
    /// page content.
    public var userAgent: String?
    public var origin: String?
    /// Non-secret authorization snapshot for revalidation after the network
    /// await. The provider confirms these still match before the result is
    /// returned to the model.
    public var authorizationProviderID: String?
    public var authorizationGeneration: UInt64

    public init(
        cookies: [HTTPCookieSnapshot] = [],
        userAgent: String? = nil,
        origin: String? = nil,
        authorizationProviderID: String? = nil,
        authorizationGeneration: UInt64 = 0
    ) {
        self.cookies = cookies
        self.userAgent = userAgent
        self.origin = origin
        self.authorizationProviderID = authorizationProviderID
        self.authorizationGeneration = authorizationGeneration
    }
}

public enum BrowserCookieProviderError: Error, Sendable, LocalizedError {
    case unavailable
    case noTask
    case noActivePage
    case originMismatch
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The task browser is not available for cookie context"
        case .noTask: "A task-owned browser is required for cookie context"
        case .noActivePage: "Open the page in the task browser before using its cookies"
        case .originMismatch: "Browser cookies are limited to the active page origin"
        case .notAuthorized: "The active model provider is not authorized for browser session data"
        }
    }
}

/// The app supplies this weak provider at startup. FloeExecution never keeps
/// a strong reference and never reads WebKit directly.
@MainActor
public protocol BrowserCookieProviding: AnyObject, Sendable {
    /// `runID` is the trusted runtime identity that must already be bound to
    /// the provider recipient by the host. The provider never trusts a model
    /// string or the visible Settings selection for this decision.
    func browserWebContext(
        for url: URL,
        conversationID: UUID?,
        runID: UUID?
    ) async throws -> BrowserWebContext

    /// Called after an outbound request or page read finishes awaiting. The
    /// provider rechecks the same run/provider binding and advanced generation;
    /// a changed recipient or OFF switch discards the result.
    func revalidateBrowserWebContext(
        _ context: BrowserWebContext,
        conversationID: UUID?,
        runID: UUID?
    ) async throws
}

public final class BrowserCookieProviderRegistry: @unchecked Sendable {
    public static let shared = BrowserCookieProviderRegistry()

    private let lock = NSLock()
    private weak var provider: (any BrowserCookieProviding)?

    private init() {}

    @MainActor
    public func install(_ provider: (any BrowserCookieProviding)?) {
        lock.withLock { self.provider = provider }
    }

    public func revalidate(
        _ context: BrowserWebContext,
        conversationID: UUID?,
        runID: UUID?
    ) async throws {
        let current = lock.withLock { provider }
        guard let current else { throw BrowserCookieProviderError.unavailable }
        guard runID != nil else { throw BrowserCookieProviderError.notAuthorized }
        try await current.revalidateBrowserWebContext(
            context,
            conversationID: conversationID,
            runID: runID
        )
    }

    public func context(
        for url: URL,
        conversationID: UUID?,
        runID: UUID?
    ) async throws -> BrowserWebContext {
        let current = lock.withLock { provider }
        guard let current else { throw BrowserCookieProviderError.unavailable }
        guard runID != nil else { throw BrowserCookieProviderError.notAuthorized }
        return try await current.browserWebContext(
            for: url,
            conversationID: conversationID,
            runID: runID
        )
    }
}
