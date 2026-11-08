// SPDX-License-Identifier: MPL-2.0
//
// RB-6 skills CONNECTOR transport — the production adapter for the
// community/private GitHub skill-source path, built exclusively on the
// ALREADY-QUALIFIED minimal web tools closure (FloeAndroidWebTools;
// the SAME single HTTPRequestService the public hub transport composes).
// This file deliberately adds NO second HTTP engine: every network
// semantic (bounded incremental reads over the qualified FloeTransport
// streaming session, PublicNetworkTargetPolicy, the redirect revalidation
// delegate that strips cross-origin credentials, cookie/credential-store-
// free ephemeral configuration) rides the ORIGINAL service through its
// caller-header send/download seams.
//
// Contract (fixed iOS object 2ce48570a, SourceControlCenter.swift:399-454
// skillRepositoryData + SkillsCenter.swift:1371 usesConnectorCredential):
//   * Official/curated Hub sources (the exact validated identities in
//     SkillsRemoteTransportRouting) NEVER reach this transport — they stay
//     on the unchanged anonymous public mirror transport. This adapter
//     REFUSES those shapes (typed, fail-closed) as defense in depth.
//   * Community sources with NO configured token keep the EXISTING
//     anonymous path VERBATIM (frozen 729812f2 behaviour): commit
//     resolution and immutable raw.githubusercontent.com file bytes ride
//     the injected public transport — tokenless public installs are never
//     pushed through the rate-limited contents API. A missing token alone
//     is never a refusal.
//   * Community sources WITH a configured token (GitHubCredentialStore
//     lease, read PER REQUEST) resolve and fetch ONLY against
//     api.github.com: GET /repos/o/r/commits/<ref-escaped> (Accept
//     application/vnd.github.sha) then GET /repos/o/r/contents/<path>
//     ?ref=<immutable commit> (Accept application/vnd.github.raw+json) at
//     the SAME budgets GitHubSkillDownload.stage enforces downstream
//     (package entry 262144 B; other inventory files 2 MiB, both through DOWNLOAD
//     path — byte-exact, so arbitrary binary skill assets survive intact;
//     the 8 MiB staged total stays enforced unchanged downstream). The
//     mutable source.ref is resolved to one immutable commit BEFORE any
//     content request, exactly like the iOS connector path. The token rides
//     only the Authorization header of these requests: it never appears in
//     a URL, a log line, persisted state, a prompt, or any other origin
//     (raw.githubusercontent.com, transport mirrors, the public Finder and
//     arbitrary origins are unreachable from the credentialed path).
//   * A STALE lease (epoch/ownership drift), a vault failure or caller
//     cancellation fails closed and propagates typed — it never degrades
//     into a silent anonymous retry. A credentialed 401/403/404 maps to a
//     typed access denial ("check the repository, ref, path and GitHub
//     account access") — never a mirror retry, never an anonymous retry,
//     and never the claim that every 404 proves a private repository.
//   * fetchFinderEnvelope stays delegated to the injected PUBLIC transport:
//     Finder envelopes are public hub shapes and this adapter never sees
//     them.
import Foundation
import FloeCore
import FloeSkills
import FloeGit
import FloeTools
import FloeAndroidWebTools

// MARK: - Typed connector fetch failures

/// Honest, closed-vocabulary failures for the credentialed community
/// connector path. These carry NO repository content, NO credential
/// material and NO response bodies — status codes and machine labels only.
public enum SkillsConnectorFetchFailure: Error, Sendable, Equatable {
    /// The validated source is an official/curated Hub shape. The connector
    /// never serves Hub content (it stays on the anonymous public
    /// transport); reaching here means a routing invariant broke, so it
    /// fails closed before any request.
    case officialHubSourceRefused
    /// GitHub answered 401/403/404 on the credentialed community route.
    /// Actionable remediation: check the repository, ref, path and GitHub
    /// account access (connect a GitHub account in Connectors for private
    /// repos). Never interpreted as proof that a repository is private,
    /// and never retried anonymously.
    case accessDenied(Int)
    /// Any other non-2xx GitHub API status.
    case status(Int)
    /// The bounded body crossed its per-file cap (truncated) — fail closed;
    /// partial bytes are never returned.
    case oversized(String)
    /// The commit-resolution response was not exactly one canonical 40-hex
    /// commit (or was truncated).
    case commitUnresolvable
}

// MARK: - Credentialed community connector transport

/// The production `SkillsRemoteTransport` for community/private GitHub
/// skill sources, over the SAME qualified `HTTPRequestService`.
///
/// Credential-aware per request set: no configured token delegates the
/// whole community operation to the anonymous public transport (existing
/// immutable raw path preserved); a configured token switches resolve and
/// fetch to the authorized api.github.com contents route. The decision is
/// per call — the transport protocol is stateless — and every route is
/// immutable-commit-bound, so a token connecting or disconnecting between
/// the resolve and a content fetch can only change WHICH official route
/// serves the same pinned bytes, never the bytes' identity or their
/// downstream hash verification.
public struct WebToolsSkillsConnectorTransport: SkillsRemoteTransport {
    /// The pinned production GitHub API origin. `apiBase` is a
    /// COMPOSITION-TIME constant (bound once by G02DomainServices and never
    /// reachable from a model envelope or a source payload), which is what
    /// guarantees the leased token can only ever leave the process toward
    /// this origin.
    public static let productionAPIBase = URL(string: "https://api.github.com")!

    private let http: HTTPRequestService
    private let credentials: GitHubCredentialStore
    /// The anonymous public transport. It serves BOTH the tokenless
    /// community path (existing raw.githubusercontent.com immutable bytes)
    /// and every Finder envelope; the credentialed route below never
    /// touches it.
    private let anonymousTransport: any SkillsRemoteTransport
    /// The GitHub API origin. Defaults to the pinned production origin; the
    /// ONLY other accepted shape is an explicit loopback base for the host
    /// test fixture (http://127.0.0.1 / localhost). Anything else is
    /// rejected by clamping back to production — fail-closed by
    /// construction, since an unrecognized base can never widen the
    /// credential's reach.
    private let apiBase: URL

    public init(http: HTTPRequestService,
                credentials: GitHubCredentialStore,
                anonymousTransport: any SkillsRemoteTransport,
                apiBase: URL = WebToolsSkillsConnectorTransport.productionAPIBase) {
        self.http = http
        self.credentials = credentials
        self.anonymousTransport = anonymousTransport
        self.apiBase = Self.acceptedBase(apiBase)
    }

    /// Base validation: the pinned HTTPS API origin, or an explicit
    /// loopback HTTP test base. Anything else clamps to the pinned
    /// production origin so the credential can never be aimed at an
    /// unexpected origin.
    static func acceptedBase(_ base: URL) -> URL {
        guard let scheme = base.scheme?.lowercased(), let host = base.host?.lowercased(),
              !host.isEmpty, base.user == nil, base.password == nil else {
            return productionAPIBase
        }
        guard base.query == nil, base.fragment == nil, base.path.isEmpty || base.path == "/" else {
            return productionAPIBase
        }
        if scheme == "https", host == "api.github.com", base.port == nil || base.port == 443 {
            return productionAPIBase
        }
        if scheme == "http", ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) {
            return base
        }
        return productionAPIBase
    }

    /// Per-request credential read. The token is READ FRESH for every
    /// request set through the leased store: never cached on this adapter,
    /// never logged, never placed in a URL, and dropped by the store
    /// contract after the read. A lease failure (stale epoch, vault
    /// refusal, cancellation) propagates typed — it never degrades into an
    /// anonymous retry. A nil read (no account connected) means the
    /// caller keeps the EXISTING anonymous public path.
    private func leasedToken() async throws -> String? {
        do {
            return try await credentials.token()
        } catch FloeError.cancelled {
            throw CancellationError()
        }
    }

    /// Commit resolution ⇄ the SAME endpoint shape the public transport
    /// qualifies, plus the optional leased connector token. Tokenless
    /// community sources keep the existing anonymous resolution verbatim
    /// (immutable raw file bytes are part of that same public path).
    /// Mutable commit resolution exists ONLY on official GitHub routes —
    /// mirrors have no role here (no signed mirror identity exists for the
    /// mutable API), matching the public transport's official-only
    /// resolution and the iOS connector contract.
    public func resolveCommit(_ source: GitHubSkillSource) async throws -> String {
        try Task.checkCancellation()
        guard SkillsRemoteTransportRouting.usesConnectorTransport(for: source) else {
            throw SkillsConnectorFetchFailure.officialHubSourceRefused
        }
        guard let token = try await leasedToken() else {
            do {
                return try await anonymousTransport.resolveCommit(source)
            } catch {
                throw Self.anonymousFailure(error)
            }
        }
        let url = try Self.endpoint(
            base: apiBase, owner: source.owner, repository: source.repository,
            suffix: ["commits", source.ref], query: [])
        let response: HTTPResponse
        do {
            response = try await http.send(
                method: "GET", url: url, headers: Self.authorizedHeaders(accept: "application/vnd.github.sha", token: token),
                body: nil, timeout: 30, maxResponseBytes: 65_536)
        } catch FloeError.cancelled {
            throw CancellationError()
        }
        try Self.checkStatus(response.statusCode)
        guard !response.truncated else { throw SkillsConnectorFetchFailure.commitUnresolvable }
        // Accept: application/vnd.github.sha returns the raw 40-hex sha.
        let sha = response.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count == 40, sha.allSatisfy(\.isHexDigit) else {
            throw SkillsConnectorFetchFailure.commitUnresolvable
        }
        return sha.lowercased()
    }

    /// Immutable blob fetch. Tokenless community sources keep the existing
    /// anonymous raw.githubusercontent.com fetch verbatim. With a token, the
    /// contents API serves the bytes at the commit resolved BEFORE any
    /// content request (`GitHubSkillDownload.stage` resolves first, then
    /// fetches with that exact commit). The package entry (`source.path`,
    /// ≤262144 B of inventory JSON) and every other inventory file use the
    /// SAME bounded download path, preserving original bytes. Other files
    /// keep the 2 MiB bound; the staged total (8 MiB / ≤128 files) stays
    /// enforced unchanged downstream.
    public func fetch(_ source: GitHubSkillSource, commit: String,
                      path: String) async throws -> Data {
        try Task.checkCancellation()
        guard SkillsRemoteTransportRouting.usesConnectorTransport(for: source) else {
            throw SkillsConnectorFetchFailure.officialHubSourceRefused
        }
        guard let token = try await leasedToken() else {
            do {
                return try await anonymousTransport.fetch(source, commit: commit, path: path)
            } catch {
                throw Self.anonymousFailure(error)
            }
        }
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else {
            throw SkillUpgradeError.invalidCommit
        }
        // Path segments are encoded individually (the source validator
        // already rejected '%', '\\', control characters and empty/'.'/'..'
        // segments — revalidate defensively before touching the wire).
        try GitHubSkillSource.validatePath(path)
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        let url = try Self.endpoint(
            base: apiBase, owner: source.owner, repository: source.repository,
            suffix: ["contents"] + segments,
            query: [URLQueryItem(name: "ref", value: commit.lowercased())])
        let entry = path == source.path
        return try await downloadFile(url: url, token: token,
                                      maximumBytes: entry ? 262_144 : 2_097_152,
                                      kind: entry ? "entry" : "file")
    }

    /// One entry/inventory fetch: the qualified bounded DOWNLOAD
    /// path (byte-exact — arbitrary binary skill assets survive intact, no
    /// UTF-8 re-encoding), with the SAME caller-header validation and the
    /// SAME session/redirect policy as every other request on this service.
    /// The owned download is bridged to cooperative cancellation: a
    /// cancelled caller cancels the transfer and the scratch file is
    /// removed instead of being kept.
    private func downloadFile(url: URL, token: String, maximumBytes: Int,
                              kind: String) async throws -> Data {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-connector-\(UUID().uuidString)")
        let cancellation = CancellationToken()
        do {
            let result: HTTPRequestService.DownloadResult = try await withTaskCancellationHandler {
                try await http.download(
                    url: url, timeout: 60, maxBytes: maximumBytes, to: scratch,
                    cancellation: cancellation,
                    headers: Self.authorizedHeaders(accept: "application/vnd.github.raw+json", token: token))
            } onCancel: {
                cancellation.cancel()
            }
            defer { try? FileManager.default.removeItem(at: scratch) }
            try Task.checkCancellation()
            let data = try Data(floeContentsOf: scratch, options: [.mappedIfSafe])
            guard data.count <= maximumBytes, result.byteCount == data.count else {
                throw SkillsConnectorFetchFailure.oversized(kind)
            }
            try Task.checkCancellation()
            return data
        } catch let error as HTTPRequestError {
            try? FileManager.default.removeItem(at: scratch)
            if case .httpStatus(let code) = error {
                // 401/403/404 stay the honest actionable access denial;
                // other non-2xx stays a typed status. No anonymous retry.
                try Self.checkStatus(code)
            }
            if case .responseTooLarge = error {
                throw SkillsConnectorFetchFailure.oversized(kind)
            }
            throw error
        } catch let error as FloeError {
            try? FileManager.default.removeItem(at: scratch)
            // download() types cooperative cancellation as FloeError.cancelled.
            if case .cancelled = error { throw CancellationError() }
            throw error
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    /// Finder envelopes stay PUBLIC: delegate to the injected public
    /// transport, which keeps its signed-mirror policy and its host
    /// allow-list. This adapter never attaches a credential to an
    /// envelope request.
    public func fetchFinderEnvelope(url: URL) async throws -> Data {
        try await anonymousTransport.fetchFinderEnvelope(url: url)
    }

    // MARK: - Authorized request headers

    /// Builds the header set for one credentialed request. The token was
    /// already read once for THIS request by the caller. It is neither
    /// re-read during routing nor retained on the transport.
    private static func authorizedHeaders(accept: String, token: String) -> [String: String] {
        ["Accept": accept, "Authorization": "Bearer \(token)"]
    }

    /// The anonymous community path has the same actionable access failure.
    /// Preserve every other original error and never retry or infer privacy.
    private static func anonymousFailure(_ error: any Error) -> any Error {
        let status: Int?
        switch error {
        case WebToolsSkillsRemoteTransport.TransportError.status(let value): status = value
        case AndroidHubMirrorTransport.Failure.httpStatus(let value): status = value
        default: status = nil
        }
        if let status, [401, 403, 404].contains(status) {
            return SkillsConnectorFetchFailure.accessDenied(status)
        }
        return error
    }

    // MARK: - URL building (iOS connector-identical encoding)

    private static let encodedCharacters =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))

    /// Builds `<base>/repos/<owner>/<repository>/<suffix...>` with iOS
    /// connector-identical percent encoding: each segment encoded against
    /// alphanumerics + `-_.~` (ref slashes become %2F, version '+' bytes
    /// become %2B — exactly the iOS `encoded(_:)` character set), joined
    /// with literal '/', plus the caller's query items. Only validated
    /// source components (GitHubSkillSource.init charset/length rules) and
    /// validated path segments ever reach this builder.
    static func endpoint(base: URL, owner: String, repository: String,
                         suffix: [String], query: [URLQueryItem]) throws -> URL {
        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: Self.encodedCharacters) ?? value
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        guard components != nil else { throw SkillsConnectorFetchFailure.status(0) }
        let basePath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedSegments = ([owner, repository] + suffix).map(encoded)
        components?.percentEncodedPath = (basePath.isEmpty ? "" : "/" + encoded(basePath))
            + "/repos/" + encodedSegments.joined(separator: "/")
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw SkillsConnectorFetchFailure.status(0)
        }
        return url
    }

    /// Closed status mapping for the CREDENTIALED route: access failures
    /// (401/403/404) get the honest actionable denial; every other non-2xx
    /// stays a typed status. There is deliberately NO mirror or anonymous
    /// fallback on this route — access, size, integrity and cancellation
    /// failures fail closed where they occur.
    static func checkStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200...299:
            return
        case 401, 403, 404:
            throw SkillsConnectorFetchFailure.accessDenied(statusCode)
        default:
            throw SkillsConnectorFetchFailure.status(statusCode)
        }
    }
}
