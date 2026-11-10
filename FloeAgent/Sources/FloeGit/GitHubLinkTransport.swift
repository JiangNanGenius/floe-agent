// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GitHubLinkHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
    let evidence: GitHubLinkRequestEvidence
}

enum GitHubLinkTransport {
    static func apiURL(baseURL: URL, segments: [String], query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL.absoluteURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host != nil, components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { throw GitHubLinkError.invalidLink("API origin") }
        // An ASCII allowlist is essential: leaving Unicode unescaped makes
        // Foundation repair a partially encoded URL and encode existing '%' again.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + ([basePath].filter { !$0.isEmpty }
            + segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }).joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        components.fragment = nil
        guard let url = components.url else { throw GitHubLinkError.invalidLink("API path") }
        return url
    }

    static func read(_ request: URLRequest, session: URLSession, maximumBytes: Int) async throws -> GitHubLinkHTTPResponse {
        try Task.checkCancellation()
        let limit = max(1, min(maximumBytes, 8 * 1_048_576))
        // A transferred repository must be explicitly confirmed by the caller.
        // No redirect is allowed to forward credentials or silently change identity.
        let guarded = URLSession(configuration: session.configuration, delegate: GitHubLinkRedirectGuard(), delegateQueue: nil)
        defer { guarded.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            #if canImport(FoundationNetworking)
            (data, response) = try await guarded.data(for: request)
            #else
            let stream = try await guarded.bytes(for: request)
            response = stream.1
            defer { stream.0.task.cancel() }
            try validate(response, limit: limit)
            var buffer = Data()
            buffer.reserveCapacity(min(limit, 65_536))
            for try await byte in stream.0 {
                try Task.checkCancellation()
                guard buffer.count < limit else { throw GitHubLinkError.responseTooLarge(limit) }
                buffer.append(byte)
            }
            data = buffer
            #endif
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? GitHubLinkError { throw error }
            throw GitHubLinkError.transport
        }
        try Task.checkCancellation()
        try validate(response, limit: limit)
        guard data.count <= limit, let http = response as? HTTPURLResponse, let url = request.url else {
            throw GitHubLinkError.responseTooLarge(limit)
        }
        return GitHubLinkHTTPResponse(data: data, response: http, evidence: GitHubLinkRequestEvidence(
            apiURL: url, readAt: Date(), etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"), byteCount: data.count
        ))
    }

    private static func validate(_ response: URLResponse, limit: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw GitHubLinkError.transport }
        switch http.statusCode {
        case 200..<300: break
        case 301, 302, 303, 307, 308:
            var location = http.value(forHTTPHeaderField: "Location").flatMap { URLComponents(string: $0) }
            if location?.scheme != "https" || !["api.github.com", "github.com"].contains(location?.host ?? "")
                || location?.user != nil || location?.password != nil || (location?.port != nil && location?.port != 443) { location = nil }
            location?.query = nil; location?.fragment = nil
            throw GitHubLinkError.moved(location?.url)
        case 401: throw GitHubLinkError.authenticationRequired
        case 403:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.value(forHTTPHeaderField: "Retry-After") != nil {
                throw GitHubLinkError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After") ?? http.value(forHTTPHeaderField: "X-RateLimit-Reset"))
            }
            throw GitHubLinkError.forbidden
        case 404, 410: throw GitHubLinkError.notFoundOrNotAccessible
        case 429: throw GitHubLinkError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        default: throw GitHubLinkError.http(http.statusCode)
        }
        if response.expectedContentLength > Int64(limit) { throw GitHubLinkError.responseTooLarge(limit) }
    }
}

private final class GitHubLinkRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
