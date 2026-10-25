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

    static func authorizePreview(_ url: URL) {
        guard let prefix = previewPrefix(for: url) else { return }
        previewLock.withLock { _ = previewPrefixes.insert(prefix) }
    }

    static func revokePreview(_ url: URL) {
        guard let prefix = previewPrefix(for: url) else { return }
        previewLock.withLock { _ = previewPrefixes.remove(prefix) }
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

    static func validate(_ value: String, conversationID: UUID? = nil) throws -> URL {
        let url = try parseNavigationURL(value)
        guard let host = url.host?.lowercased(),
              !isPrivate(host) || isAuthorizedPreview(url, conversationID: conversationID) else {
            throw BrowserPolicyError.blocked("Loopback and private-network navigation is blocked")
        }
        return url
    }

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

enum BrowserPolicyError: LocalizedError {
    case blocked(String)

    var errorDescription: String? {
        switch self { case .blocked(let message): message }
    }
}
#endif
