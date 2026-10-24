// FloeAndroid shared/Sources/FloeBrowser — conservative navigation policy.
//
// Android mirror of the public iOS original
// FloeAgent/FloeApp/Browser/BrowserURLPolicy.swift @ 3fd597b…
// (sha256 2fd0bee1ddd3c76a9a759982ec48f12d227e3addce37e2b9f980a53ca744da0b).
// Mirror deltas (documented, minimal):
//  1. The original held its preview/service tables in static globals behind an
//     NSLock. Here they are instance state of `BrowserURLPolicy` (one instance
//     per runtime composition root, shared by the session center and the
//     preview coordinator), so no global state can outlive the service and no
//     second process can silently differ. All rule text is unchanged.
//  2. `validate` stays synchronous and string-level exactly like the original:
//     a navigation target is judged on the URL it names. DNS-time SSRF hardening
//     was never part of this surface on iOS and is not introduced here; the
//     Android DNS stack is owned by the WebView.
//  3. Grants are minted ONLY by trusted native code paths
//     (LocalPreviewCoordinator start, Main's service registration). Page
//     content — including an iframe src, a meta refresh or a redirect chain —
//     never reaches these registration functions, so a page cannot widen its
//     own access. Renderer callbacks route through the same `validate`.

import Foundation

public enum BrowserPolicyError: Error, LocalizedError, Equatable {
    case blocked(String)

    public var errorDescription: String? {
        switch self { case .blocked(let message): message }
    }
}

public final class BrowserURLPolicy: @unchecked Sendable {
    private struct ServiceOrigin {
        let origin: String
        let conversationID: UUID
    }

    private let lock = NSLock()
    private var previewPrefixes: Set<String> = []
    private var serviceOrigins: [UUID: ServiceOrigin] = [:]

    public init() {}

    /// Registers one owner's service origin (Main uses this for explicitly
    /// hosted local services). `owner` keys the registration; `conversationID`
    /// restricts which task may navigate to it unless the caller opts into
    /// registered services. Original semantics preserved.
    public func authorizeService(_ url: URL, owner: UUID, conversationID: UUID) {
        guard url.scheme == "http", url.host == "127.0.0.1", let port = url.port, (1024...65535).contains(port) else { return }
        lock.withLock { serviceOrigins[owner] = ServiceOrigin(origin: "http://127.0.0.1:\(port)", conversationID: conversationID) }
    }

    public func revokeService(owner: UUID) {
        lock.withLock { _ = serviceOrigins.removeValue(forKey: owner) }
    }

    /// Mints a preview grant for an already-started loopback preview URL whose
    /// first path segment is the unpredictable per-server token (>=32 chars).
    public func authorizePreview(_ url: URL) {
        guard let prefix = previewPrefix(for: url) else { return }
        lock.withLock { _ = previewPrefixes.insert(prefix) }
    }

    public func revokePreview(_ url: URL) {
        guard let prefix = previewPrefix(for: url) else { return }
        lock.withLock { _ = previewPrefixes.remove(prefix) }
    }

    public func revokePreviewAllocation(port: Int, token: String) {
        let prefix = "http://127.0.0.1:\(port)/\(token)/"
        lock.withLock { _ = previewPrefixes.remove(prefix) }
    }

    /// The original conservative gate: http/https, a named host, no embedded
    /// credentials, and private/loopback space only through an exact grant.
    public func validate(_ value: String, conversationID: UUID? = nil, allowRegisteredServices: Bool = false) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty
        else {
            throw BrowserPolicyError.blocked("Only http and https URLs are allowed")
        }
        guard !isPrivate(host) || isAuthorizedPreview(url, conversationID: conversationID, allowRegisteredServices: allowRegisteredServices) else {
            throw BrowserPolicyError.blocked("Loopback and private-network navigation is blocked")
        }
        guard url.user == nil, url.password == nil else {
            throw BrowserPolicyError.blocked("Credentials in URLs are not allowed")
        }
        return url
    }

    /// True when `url` matches an admitted preview allocation exactly
    /// (127.0.0.1 + port + >=32-char token first segment). Used by the
    /// download origin fence; never grants navigation on its own.
    public func isGrantedPreviewAllocation(_ url: URL) -> Bool {
        guard let prefix = previewPrefix(for: url) else { return false }
        return lock.withLock { previewPrefixes.contains(prefix) }
    }

    /// True when `candidate` belongs to the same loopback preview allocation
    /// (scheme/host/port and the per-server token path segment) as `previewURL`.
    /// Ported from LocalPreviewCoordinator.isPreviewURL (iOS original).
    public func isPreviewAllocation(_ candidate: URL, matching previewURL: URL) -> Bool {
        guard candidate.scheme == previewURL.scheme,
              candidate.host == previewURL.host,
              candidate.port == previewURL.port,
              let token = previewURL.pathComponents.dropFirst().first else { return false }
        return candidate.pathComponents.dropFirst().first == token
    }

    /// Same allocation test against an explicitly named allocation (used by
    /// the transport-side Host/token checks).
    public static func isLoopbackPreview(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return url.host == "127.0.0.1" || url.host?.lowercased() == "localhost"
    }

    private func isAuthorizedPreview(
        _ url: URL,
        conversationID: UUID?,
        allowRegisteredServices: Bool
    ) -> Bool {
        if url.scheme == "http", url.host == "127.0.0.1", let port = url.port {
            let origin = "http://127.0.0.1:\(port)"
            let allowed = lock.withLock {
                serviceOrigins.values.contains {
                    $0.origin == origin && (allowRegisteredServices || $0.conversationID == conversationID)
                }
            }
            if allowed { return true }
        }
        guard let prefix = previewPrefix(for: url) else { return false }
        return lock.withLock { previewPrefixes.contains(prefix) }
    }

    /// A preview grant is per allocation: `http://127.0.0.1:<port>/<token>/`.
    /// The token must be at least 32 characters (unpredictable per server).
    private func previewPrefix(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "http",
              url.host == "127.0.0.1",
              let port = url.port,
              let token = url.pathComponents.dropFirst().first,
              token.count >= 32 else { return nil }
        return "http://127.0.0.1:\(port)/\(token)/"
    }

    /// Original literal classification, preserved rule for rule.
    private func isPrivate(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        let pieces = host.split(separator: ".").compactMap { Int($0) }
        guard pieces.count == 4, pieces.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (pieces[0], pieces[1]) {
        case (10, _), (127, _), (0, _): return true
        case (169, 254): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }
}
