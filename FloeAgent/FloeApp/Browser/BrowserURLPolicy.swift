// FloeApp — conservative navigation policy for the visible browser.

#if canImport(WebKit)
import Foundation

enum BrowserURLPolicy {
    private static let previewLock = NSLock()
    nonisolated(unsafe) private static var previewPrefixes: Set<String> = []

    nonisolated(unsafe) private static var serviceOrigins: [UUID: (origin: String, conversationID: UUID)] = [:]

    static func authorizeService(_ url: URL, owner: UUID, conversationID: UUID) {
        guard url.scheme == "http", url.host == "127.0.0.1", let port = url.port, (1024...65535).contains(port) else { return }
        previewLock.withLock { serviceOrigins[owner] = ("http://127.0.0.1:\(port)", conversationID) }
    }

    static func revokeService(owner: UUID) {
        previewLock.withLock { _ = serviceOrigins.removeValue(forKey: owner) }
    }

    static func isLiveService(_ url: URL, owner: UUID, conversationID: UUID) -> Bool {
        previewLock.withLock {
            guard let service = serviceOrigins[owner] else { return false }
            return service.conversationID == conversationID && service.origin == url.originString
        }
    }

    static func authorizePreview(_ url: URL) {
        guard let prefix = previewPrefix(for: url) else { return }
        previewLock.withLock { _ = previewPrefixes.insert(prefix) }
    }

    static func revokePreview(_ url: URL) {
        guard let prefix = previewPrefix(for: url) else { return }
        previewLock.withLock { _ = previewPrefixes.remove(prefix) }
    }

    /// Read-only query for the native staged-export gate (`browser.exportFile`):
    /// true only when `url` is currently this conversation's OWN authorized
    /// loopback endpoint — a registered localService origin bound to the
    /// conversation, or a tokenized preview allocation in the registry. This
    /// is the same authority `validate` consults for navigation; querying it
    /// grants nothing, mutates nothing, and a plain 127.0.0.1/localhost URL
    /// that was never authorized here is refused.
    static func isOwnedLocalEndpoint(_ url: URL, conversationID: UUID) -> Bool {
        guard url.scheme?.lowercased() == "http", url.host == "127.0.0.1" else { return false }
        return isAuthorizedPreview(url, conversationID: conversationID)
    }

    /// Argument syntax only. This does not authorize a navigation or a
    /// registered service; execution must call validate with the real owner.
    static func parseNavigationURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw BrowserPolicyError.blocked("Only http and https URLs are allowed")
        }
        guard url.user == nil, url.password == nil else {
            throw BrowserPolicyError.blocked("Credentials in URLs are not allowed")
        }
        return url
    }

    static func validate(_ value: String, conversationID: UUID? = nil, allowLocalNetwork: Bool = false) throws -> URL {
        let url = try parseNavigationURL(value)
        if allowLocalNetwork, let conversationID {
            let foreignService = previewLock.withLock {
                serviceOrigins.values.contains {
                    $0.origin == url.originString && $0.conversationID != conversationID
                }
            }
            guard !foreignService else {
                throw BrowserPolicyError.blocked("This local service belongs to another conversation")
            }
            return url
        }
        guard let host = url.host?.lowercased(),
              !isPrivate(host) || isAuthorizedPreview(url, conversationID: conversationID) else {
            throw BrowserPolicyError.blocked("Loopback and private-network navigation is blocked")
        }
        return url
    }

    /// Durable-restore gate for one committed page URL. A page may only be
    /// replayed as a plain GET after an app relaunch when it is an ordinary
    /// http/https page on a public, multi-label DNS host without embedded
    /// credentials or authentication-callback parameters (including
    /// token-carrying fragments). Loopback/private-network pages, local
    /// previews, single-label intranet hosts, IPv6 literals, `about:blank`
    /// and bearer-grant callbacks never pass.
    static func isRestorablePageURL(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 4096,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.contains(":"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return false }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let topLevelLabel = labels.last,
              topLevelLabel.first?.isLetter == true,
              !["local", "localhost", "internal", "lan", "home", "arpa"].contains(topLevelLabel),
              !(components.queryItems ?? []).contains(where: { nonRestorableQueryParameters.contains($0.name.lowercased()) })
        else { return false }
        // Some authentication flows put their grants inside a fragment route.
        let fragment = components.fragment ?? ""
        return !fragment.split(whereSeparator: { $0 == "?" || $0 == "&" }).contains { pair in
            guard let key = pair.split(separator: "=", maxSplits: 1).first else { return false }
            return nonRestorableQueryParameters.contains(key.lowercased())
        }
    }

    /// Query parameter names that mark a URL as an authentication callback or
    /// one-time grant. Replaying such a URL after relaunch could re-submit a
    /// consumed code or expose a token, so the page is never persisted.
    private static let nonRestorableQueryParameters: Set<String> = [
        "code", "token", "access_token", "id_token", "refresh_token",
        "state", "session_state", "auth_code", "oauth_token", "oauth_verifier",
        "token_type", "key", "api_key", "apikey", "signature", "sig", "x-amz-signature", "x-goog-signature"
    ]

    private static func isAuthorizedPreview(_ url: URL, conversationID: UUID?) -> Bool {
        if let conversationID, url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
           previewLock.withLock({ serviceOrigins.values.contains(where: {
               $0.origin == "http://127.0.0.1:\(port)" && $0.conversationID == conversationID
           }) }) { return true }
        guard let prefix = previewPrefix(for: url) else { return false }
        return previewLock.withLock { previewPrefixes.contains(prefix) }
    }

    private static func previewPrefix(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "http",
              url.host == "127.0.0.1",
              let port = url.port,
              let token = url.pathComponents.dropFirst().first,
              token.count >= 32 else { return nil }
        return "http://127.0.0.1:\(port)/\(token)/"
    }

    private static func isPrivate(_ host: String) -> Bool {
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

private extension URL {
    var originString: String {
        guard let scheme = scheme?.lowercased(), let originalHost = host?.lowercased() else { return "" }
        let host = ["localhost", "::1", "[::1]"].contains(originalHost) ? "127.0.0.1" : originalHost
        return "\(scheme)://\(host):\(port ?? (scheme == "https" ? 443 : 80))"
    }
}

enum BrowserPolicyError: LocalizedError {
    case blocked(String)

    var errorDescription: String? {
        switch self { case .blocked(let message): message }
    }
}
#endif
