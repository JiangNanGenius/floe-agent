// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Fixed, anonymous byte routes for the official Floe electronics data
/// release and its approved pinned source-model origins. Only the signed
/// `GitHubTransportMirrorRoles` policy can reorder or disable compiled
/// mirrors; a mirror never becomes a different repository, revision or path.
///
/// The one GitLab source (KiCad packages3D) has a compiled official GitHub
/// alias at the exact revision/path. GitLab remains the canonical identity;
/// the alias is tried only after a definite availability failure and its bytes
/// are still verified against the publisher's gitBlobSHA1.
public enum ElectronicsLibraryMirrorTransport {
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case invalidTarget
        case httpStatus(Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .invalidTarget: "Electronics library download target is invalid."
            case .httpStatus(let code): "Electronics library download failed (HTTP \(code))."
            case .invalidResponse: "Electronics library download response is invalid."
            }
        }
    }

    public static let dataOwner = "JiangNanGenius"
    public static let dataRepository = "floe-electronics-library"
    private static let rawHost = "raw.githubusercontent.com"
    private static let assetTagPrefix = "data-v1-"
    private static let allowedSegments = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Builds the exact canonical route plus signed-role mirrors for one
    /// already-verified target URL. Unknown repositories, mutable refs,
    /// credentials, query/fragment, traversal and non-canonical encodings are
    /// rejected with an empty candidate list.
    public static func candidates(for canonical: URL,
                                  roles: GitHubTransportMirrorRoles = .bundled) -> [URL] {
        guard let parts = URLComponents(url: canonical, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let host = parts.host else { return [] }
        if canonical.absoluteString == latestReceiptURLString {
            return [canonical]
        }
        if host == "github.com" {
            guard let release = releaseAsset(parts.percentEncodedPath) else { return [] }
            return [canonical] + roles.releaseAssets.map { mirror in
                URL(string: mirror.prefix + canonical.absoluteString)!
            }
        }
        if host == "gitlab.com" {
            // The GitLab authority has no verified GitHub-proxy route. The
            // compiled KiCad alias is a separate raw.githubusercontent route.
            guard isApprovedGitLabPath(parts.percentEncodedPath) else { return [] }
            return [canonical]
        }
        guard host == rawHost, let path = rawRepositoryPath(parts.percentEncodedPath),
              isApprovedRawRepository(owner: path.owner, repository: path.repository) else { return [] }
        return [canonical] + roles.rawFiles.map { mirror in
            URL(string: mirror.prefix + canonical.absoluteString)!
        }
    }

    public static var latestReceiptURLString: String {
        "https://github.com/\(dataOwner)/\(dataRepository)/releases/latest/download/release.json"
    }

    /// Only definite transport availability errors are retried. Access,
    /// certificate, redirect, content/size, Git-object and integrity failures
    /// stop the whole transfer; they never trigger retry-to-green elsewhere.
    public static func isAvailabilityFailure(_ error: Error) -> Bool {
        if case Failure.httpStatus(let status) = error {
            return SkillHubMirrorTransport.isAvailabilityFailure(
                SkillHubMirrorTransport.Failure.httpStatus(status))
        }
        return SkillHubMirrorTransport.isAvailabilityFailure(error)
    }

    public static func load(_ canonical: URL, roles: GitHubTransportMirrorRoles = .bundled,
                            request: @Sendable (URL) async throws -> Data) async throws -> Data {
        let routes = candidates(for: canonical, roles: roles)
        guard !routes.isEmpty else { throw Failure.invalidTarget }
        for (index, route) in routes.enumerated() {
            try Task.checkCancellation()
            do {
                let data = try await request(route)
                try Task.checkCancellation()
                return data
            } catch {
                try Task.checkCancellation()
                guard index + 1 < routes.count, isAvailabilityFailure(error) else { throw error }
            }
        }
        throw Failure.invalidResponse
    }

    private static func releaseAsset(_ path: String) -> String? {
        let prefix = "/\(dataOwner)/\(dataRepository)/releases/download/"
        guard path.hasPrefix(prefix) else { return nil }
        let tail = path.dropFirst(prefix.count)
        let components = tail.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let tag = String(components[0]), name = String(components[1])
        guard tag.hasPrefix(assetTagPrefix), tag.utf8.count == assetTagPrefix.utf8.count + 20,
              tag.dropFirst(assetTagPrefix.count).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              safeAssetName(name), decode(name) == name else { return nil }
        return name
    }

    private struct RawPath {
        let owner: String
        let repository: String
        let revision: String
    }

    private static func rawRepositoryPath(_ path: String) -> RawPath? {
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 4 else { return nil }
        let owner = String(components[0]), repository = String(components[1])
        let revision = String(components[2])
        guard safeComponent(owner), safeComponent(repository),
              revision.utf8.count == 40,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        for segment in components.dropFirst(3) {
            guard let decoded = String(segment).removingPercentEncoding,
                  !decoded.isEmpty, decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\"),
                  !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  // A literal percent is never needed by the published corpus
                  // and its presence would permit double-encoded segments.
                  !String(segment).contains("%25"),
                  decoded.addingPercentEncoding(withAllowedCharacters: allowedSegments) == String(segment) else {
                return nil
            }
        }
        return .init(owner: owner, repository: repository, revision: revision)
    }

    private static func isApprovedGitLabPath(_ path: String) -> Bool {
        let prefix = "/kicad/libraries/kicad-packages3D/-/raw/"
        guard path.hasPrefix(prefix) else { return false }
        let tail = path.dropFirst(prefix.count)
        let components = tail.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        let revision = String(components[0])
        guard revision.utf8.count == 40,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        for segment in components.dropFirst() {
            guard let decoded = String(segment).removingPercentEncoding,
                  !decoded.isEmpty, decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\"),
                  !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  !String(segment).contains("%25"),
                  decoded.addingPercentEncoding(withAllowedCharacters: allowedSegments) == String(segment) else {
                return false
            }
        }
        return true
    }

    private static func isApprovedRawRepository(owner: String, repository: String) -> Bool {
        if owner == dataOwner, repository == dataRepository { return true }
        if owner == "sparkfun", repository == "SparkFun-KiCad-Libraries" { return true }
        if owner == "espressif", repository == "kicad-libraries" { return true }
        if owner == "KiCad", repository == "kicad-packages3D" { return true }
        if owner == "LibrePCB-Libraries", repository.hasSuffix(".lplib") {
            return safeComponent(repository) && repository.utf8.count > ".lplib".utf8.count
        }
        return false
    }

    private static func safeAssetName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        return true
    }

    private static func safeComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              value != ".", value != "..", !value.contains("/"), !value.contains("\\") else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func decode(_ value: String) -> String? {
        value.removingPercentEncoding
    }
}
