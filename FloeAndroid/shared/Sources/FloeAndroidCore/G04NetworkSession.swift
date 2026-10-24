// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore

/// Owner-retained WebDAV session. FoundationNetworking keeps its qualified
/// system-CA + hostname verifier; this delegate never handles trust challenges.
/// The mount owner must retain this object until its IO settles, then retire it.
final class G04NetworkSession: @unchecked Sendable {
    let session: URLSession
    private let delegate: RedirectDelegate

    init(endpoint: URL) throws {
        let origin = try G04NetworkOrigin(endpoint)
        let delegate = RedirectDelegate(origin: origin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate,
                                  delegateQueue: nil)
    }

    /// Invalidates admission and cancels requests; this is not an IO-drain proof.
    /// Existing native operation ownership stays attached until awaited IO ends.
    func cancel() { session.invalidateAndCancel() }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let origin: G04NetworkOrigin
        private let lock = NSLock()
        private var redirects: [Int: Int] = [:]
        init(origin: G04NetworkOrigin) { self.origin = origin }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard origin.allows(response.url), origin.allows(request.url),
                  let original = task.originalRequest,
                  origin.allows(original.url),
                  // Rewriting PUT/MOVE/etc to GET changes WebDAV semantics;
                  // refuse rather than silently replay another operation.
                  (request.httpMethod ?? "GET") == (original.httpMethod ?? "GET")
            else { completionHandler(nil); return }
            let accepted = lock.withLock {
                let count = redirects[task.taskIdentifier, default: 0]
                guard count < 8 else { return false }
                redirects[task.taskIdentifier] = count + 1
                return true
            }
            guard accepted else { completionHandler(nil); return }
            var admitted = request
            // The vault credential is scoped to this exact configured origin.
            // Only restore it after both the current and next URL passed that
            // test; a server-provided Location never widens the credential.
            if let authorization = original.value(forHTTPHeaderField: "Authorization") {
                admitted.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            completionHandler(admitted)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            _ = lock.withLock { redirects.removeValue(forKey: task.taskIdentifier) }
        }
    }
}

/// Exact scheme/host/effective-port boundary, supplied by the trusted native
/// mount record. HTTP LAN mounts remain an explicit existing configuration;
/// HTTPS cannot downgrade or follow a cross-origin/userinfo Location.
struct G04NetworkOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              url.port == nil || (1...65535).contains(url.port!) else {
            throw FloeError.validationFailed("Invalid network workspace endpoint")
        }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    func allows(_ url: URL?) -> Bool {
        guard let url, let candidate = try? Self(url) else { return false }
        return candidate == self
    }
}
