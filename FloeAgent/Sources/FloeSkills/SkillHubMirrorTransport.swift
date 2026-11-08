import Foundation

/// Fixed anonymous byte routes for the official Hub. Authentication and
/// signed-content checks stay with their existing callers, outside failover.
public enum SkillHubMirrorTransport {
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case invalidTarget
        case httpStatus(Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .invalidTarget: "Skill Hub download target is invalid."
            case .httpStatus(let code): "Skill Hub download failed (HTTP \(code))."
            case .invalidResponse: "Skill Hub download response is invalid."
            }
        }
    }

    private static let atom = "https://github.com/JiangNanGenius/floe-skill-hub/commits/main.atom"
    private static let rawPrefix = "/JiangNanGenius/floe-skill-hub/"

    /// The mutable Atom resolver has only the mirror actually supporting it.
    /// File routes always preserve the exact immutable commit and path.
    public static func candidates(for canonical: URL, roles: GitHubTransportMirrorRoles = .bundled) -> [URL] {
        guard let parts = URLComponents(url: canonical, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return [] }
        let mirrors: [String]
        if canonical.absoluteString == atom {
            mirrors = roles.atom.map(\.prefix)
        } else {
            guard parts.host == "raw.githubusercontent.com",
                  parts.percentEncodedPath.hasPrefix(rawPrefix) else { return [] }
            let tail = parts.percentEncodedPath.dropFirst(rawPrefix.count)
                .split(separator: "/", omittingEmptySubsequences: false)
            guard tail.count >= 2, tail[0].utf8.count == 40,
                  tail[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { return [] }
            let plain = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
            let allowed = plain.union(CharacterSet(charactersIn: "+"))
            for segment in tail.dropFirst() {
                guard let decoded = String(segment).removingPercentEncoding,
                      !decoded.isEmpty, decoded != ".", decoded != "..",
                      decoded.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                      decoded.addingPercentEncoding(withAllowedCharacters: plain) == String(segment)
                else { return [] }
            }
            mirrors = roles.rawFiles.map(\.prefix)
        }
        return [canonical] + mirrors.compactMap { URL(string: $0 + canonical.absoluteString) }
    }

    /// Only definite transport availability errors are retried. Access,
    /// certificate, redirect, content/size and integrity failures stop here.
    public static func isAvailabilityFailure(_ error: Error) -> Bool {
        if case Failure.httpStatus(let status) = error {
            return [408, 429, 500, 502, 503, 504].contains(status)
        }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    public static func load(
        _ canonical: URL,
        roles: GitHubTransportMirrorRoles = .bundled,
        request: @Sendable (URL) async throws -> Data
    ) async throws -> Data {
        let routes = candidates(for: canonical, roles: roles)
        guard !routes.isEmpty else { throw Failure.invalidTarget }
        for (index, route) in routes.enumerated() {
            try Task.checkCancellation()
            do {
                let bytes = try await request(route)
                try Task.checkCancellation()
                return bytes
            } catch {
                try Task.checkCancellation()
                guard index + 1 < routes.count, isAvailabilityFailure(error) else { throw error }
            }
        }
        throw Failure.invalidResponse
    }
}
