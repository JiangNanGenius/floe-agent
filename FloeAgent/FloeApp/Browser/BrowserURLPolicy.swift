// FloeApp — conservative navigation policy for the visible browser.

#if canImport(WebKit)
import Foundation

enum BrowserURLPolicy {
    private static let previewLock = NSLock()
    nonisolated(unsafe) private static var previewPrefixes: Set<String> = []

    static func authorizePreview(_ url: URL) {
        guard let prefix = previewPrefix(for: url) else { return }
        previewLock.withLock { _ = previewPrefixes.insert(prefix) }
    }

    static func revokePreview(_ url: URL) {
        guard let prefix = previewPrefix(for: url) else { return }
        previewLock.withLock { _ = previewPrefixes.remove(prefix) }
    }

    static func validate(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty
        else {
            throw BrowserPolicyError.blocked("Only http and https URLs are allowed")
        }
        guard !isPrivate(host) || isAuthorizedPreview(url) else {
            throw BrowserPolicyError.blocked("Loopback and private-network navigation is blocked")
        }
        guard url.user == nil, url.password == nil else {
            throw BrowserPolicyError.blocked("Credentials in URLs are not allowed")
        }
        return url
    }

    private static func isAuthorizedPreview(_ url: URL) -> Bool {
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
