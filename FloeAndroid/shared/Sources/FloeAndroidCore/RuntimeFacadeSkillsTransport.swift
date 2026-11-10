// SPDX-License-Identifier: MPL-2.0
//
// RB-6 skills remote transport — the PRODUCTION adapters for the
// SkillsRemoteTransport ports, built exclusively on the ALREADY-QUALIFIED
// minimal web tools closure (FloeAndroidWebTools; pinned/qualified earlier
// per the Main webtools-portability lane). This file is deliberately NOT a
// second simple-HTTP tool: no URLSession is constructed here, no parallel
// redirect/limit policy exists here — every network semantic rides the
// ORIGINAL HTTPRequestService (bounded incremental reads over the qualified
// FloeTransport streaming session, PublicNetworkTargetPolicy, redirect
// revalidation delegate, cookie/credential-store-free ephemeral config,
// 256 KiB-per-request internal clamp via send() and file-bounded download()).
// This file is the production public-hub transport composed in
// G02DomainServices.swift (SkillsRemoteTransportComposition.makePublicHubTransport).
//
// GitHub host allow-list (the narrowest honest adapter over the ORIGINAL
// service): the iOS app reached the hub through SourceControlCenter (an
// App-target class excluded from the overlay). The ORIGINAL rules being
// preserved here are: https-only, no URL credentials, no redirect widening
// (redirects revalidated by the session delegate against the same public-
// network policy), bounded bodies. We therefore pin the exact hosts the
// original code path uses:
//   * api.github.com            — commit resolution (≤64 KiB JSON)
//   * raw.githubusercontent.com — immutable blob bytes (catalog 256 KiB,
//                                 zip ≤8 MiB via bounded download)
//   * github.com                — the source URL shape OfficialSkillHub
//                                 itself validates (:21-26)
// A configured connector credential for PRIVATE/community sources is bound
// separately: RuntimeFacadeSkillsConnectorTransport.swift adapts the iOS
// usesConnectorCredential path (2ce48570a SourceControlCenter:399-454) over
// the SAME qualified HTTPRequestService, reading the existing
// GitHubCredentialStore lease per request. With a token it reaches ONLY
// api.github.com (contents route); with NO token the whole community
// operation keeps the existing anonymous path of THIS transport verbatim.
// Per-source selection between the two transports lives in
// SkillsRemoteTransportRouting below; the token never reaches this public
// transport, a mirror origin, or raw.githubusercontent.com.
//
// Signed transport-mirror policy (CONTRACT_V1): official GitHub is always
// the first route. The service-owned AndroidHubMirrorPolicyStore keeps the
// last verified, unexpired signed mirror list (detached Ed25519 under the
// SAME pinned curated-hub trust) plus the monotonic generation floor; it
// refreshes in the background at most once per six hours through the
// compiled bootstrap routes only (atom → immutable commit → payload+sig,
// never through the store itself — no recursive trust). Only bounded
// network/server availability failures (HTTP 408/429/500/502/503/504, or a
// typed URLError availability code) may advance to an approved mirror for
// the SAME immutable repo/commit/path; cancellation, local, cache-only,
// certificate/permission, 401/403/404, size and parse/signature/hash
// failures fail closed on the route that produced them. No
// Authorization/cookie/secret header is ever forwarded to a mirror origin.
import Foundation
import FloeCore
import FloeSkills
import FloeGit
import FloeTools
import FloeAndroidWebTools

// MARK: - GitHub/Hub transport

public struct WebToolsSkillsRemoteTransport: SkillsRemoteTransport {
    private let http: HTTPRequestService
    /// Service-owned signed mirror policy (last-good + generation floor).
    private let mirrorPolicy: AndroidHubMirrorPolicyStore

    /// One transport, one session (AGENTS invariant): bind the SAME
    /// qualified HTTPRequestService used by the D1 web tools; do not
    /// construct another URLSession here. The policy store is injected by
    /// the composition with service-owned persistence; a nil-persistence
    /// store still honours the same verify/floor semantics in memory.
    public init(http: HTTPRequestService,
                mirrorPolicy: AndroidHubMirrorPolicyStore = AndroidHubMirrorPolicyStore(persistenceURL: nil)) {
        self.http = http
        self.mirrorPolicy = mirrorPolicy
    }

    enum TransportError: Error, Equatable {
        case hostNotAllowed
        case status(Int)
        case oversized(String)
        case commitUnresolvable
    }

    static let allowedHosts: Set<String> = [
        "api.github.com", "raw.githubusercontent.com", "github.com",
    ]

    static func validated(url: URL) throws -> URL {
        guard let host = url.host?.lowercased(),
              url.scheme == "https",
              url.user == nil, url.password == nil,
              allowedHosts.contains(host) else {
            throw TransportError.hostNotAllowed
        }
        return url
    }

    /// Commit resolution ⇄ the original connector path's refs endpoint:
    /// GET api.github.com/repos/<owner>/<repo>/commits/<ref> reading the
    /// top-level "sha". Bounded ≤64 KiB via send().
    ///
    /// The signed mirror list has no role for the mutable GitHub API, so
    /// resolution stays official-only; a failure here never initiates a
    /// mirror route (the immutable commit is fixed before any mirrored
    /// content fetch).
    public func resolveCommit(_ source: GitHubSkillSource) async throws -> String {
        let refPath = source.ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.ref
        let url = try Self.validated(url: URL(string:
            "https://api.github.com/repos/\(source.owner)/\(source.repository)/commits/\(refPath)")!)
        let response = try await http.send(method: "GET", url: url,
                                           headers: ["Accept": "application/vnd.github.sha"],
                                           body: nil,
                                           timeout: 30,
                                           maxResponseBytes: 65_536)
        guard (200...299).contains(response.statusCode) else {
            throw TransportError.status(response.statusCode)
        }
        // Accept: application/vnd.github.sha returns the raw 40-hex sha.
        let sha = response.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count == 40, sha.allSatisfy(\.isHexDigit), !response.truncated else {
            throw TransportError.commitUnresolvable
        }
        return sha.lowercased()
    }

    /// Immutable blob fetch at a resolved commit. Hub archives retain their
    /// 8 MiB download limit; Hub documents retain the 256 KiB text limit.
    /// Community JSON inventories and resources use byte-exact downloads
    /// at the stage's 256 KiB / 2 MiB limits, including binary assets.
    ///
    /// Official GitHub is always the first route. When the canonical URL
    /// is an approved hub raw shape, the verified same-content mirror
    /// policy MAY order already-compiled mirrors after it; only bounded
    /// availability failures advance, and every route serves the SAME
    /// immutable commit/path bytes for the existing signature/digest/size
    /// checks downstream.
    public func fetch(_ source: GitHubSkillSource, commit: String,
                      path: String) async throws -> Data {
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else {
            throw SkillUpgradeError.invalidCommit
        }
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        // Keep version '+' bytes canonically encoded for the exact Hub;
        // unrelated repositories retain their original official-only path.
        let canonical = AndroidHubMirrorTransport.rawFileURL(owner: source.owner,
            repository: source.repository, commit: commit.lowercased(), path: path)
        let url = try Self.validated(url: canonical ?? URL(string:
            "https://raw.githubusercontent.com/\(source.owner)/\(source.repository)/\(commit.lowercased())/\(encodedPath)")!)
        if SkillsRemoteTransportRouting.usesConnectorTransport(for: source) {
            try GitHubSkillSource.validatePath(path)
            // Community inventories/resources are bytes, including images
            // and scripts above send()'s text clamp. They have no signed Hub
            // mirror identity and never trigger mirror discovery.
            return try await downloadBounded(url: url,
                maxBytes: Self.communityMaximumBytes(source: source, path: path))
        }
        return try await loadWithMirrorPolicy(url: url,
                                              kind: path.hasSuffix(".zip") ? .boundedArchive : .document)
    }

    /// Authenticated package fetch: `verifiedPackage` is the non-Codable
    /// token minted by `CuratedSkillHub.stage` from the signature-verified
    /// publication entry. The larger budget applies ONLY when every
    /// retrieval fact (owner, repository, immutable commit Y, exact package
    /// path, declared size within the signed profile) matches; any mismatch
    /// fails closed. The ordinary `fetch` budget is never widened for
    /// unauthenticated callers, and no community/connector route can ever
    /// carry a curated package authorization.
    public func fetch(_ source: GitHubSkillSource, commit: String,
                      path: String,
                      verifiedPackage: CuratedSkillHub.PackageDownloadAuthorization?) async throws -> Data {
        guard let verifiedPackage else {
            return try await fetch(source, commit: commit, path: path)
        }
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else {
            throw SkillUpgradeError.invalidCommit
        }
        let byteBudget = try verifiedPackage.maximumBytes(
            owner: source.owner, repository: source.repository, ref: commit, path: path)
        guard !SkillsRemoteTransportRouting.usesConnectorTransport(for: source) else {
            throw SkillsDomainRefusal.transportUnavailable
        }
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let canonical = AndroidHubMirrorTransport.rawFileURL(owner: source.owner,
            repository: source.repository, commit: commit.lowercased(), path: path)
        let url = try Self.validated(url: canonical ?? URL(string:
            "https://raw.githubusercontent.com/\(source.owner)/\(source.repository)/\(commit.lowercased())/\(encodedPath)")!)
        return try await downloadBounded(url: url, maxBytes: byteBudget)
    }

    static func communityMaximumBytes(source: GitHubSkillSource, path: String) -> Int {
        path == source.path && source.path.lowercased().hasSuffix(".json") ? 262_144 : 2_097_152
    }

    /// Finder envelope ingest (≤262 KiB exactly like the original cap at
    /// SkillsCenter:454-455). https-only + public-target policy is enforced
    /// by HTTPRequestService itself (PublicNetworkTargetPolicy: LAN/
    /// loopback/CGNAT refused). Mirrors apply only when the validated URL
    /// is an approved hub raw shape; otherwise the envelope stays
    /// official-only.
    public func fetchFinderEnvelope(url: URL) async throws -> Data {
        let target = try Self.validated(url: url)
        return try await loadWithMirrorPolicy(url: target, kind: .envelope)
    }

    // MARK: - Signed mirror policy routing

    private enum BodyKind {
        /// Small document through send() (256 KiB internal clamp).
        case document
        /// Finder envelope through send() with the original 262 KiB cap.
        case envelope
        /// Zip package through the bounded file download (≤8 MiB).
        case boundedArchive
    }

    /// Official route first; the verified policy may append already-compiled
    /// mirrors for approved hub shapes. Non-approved shapes keep the exact
    /// original official-only behaviour.
    private func loadWithMirrorPolicy(url: URL, kind: BodyKind) async throws -> Data {
        let policy = await mirrorPolicy.policyRefreshingIfNeeded { [self] in
            try await self.downloadMirrorManifest()
        }
        let routes = AndroidHubMirrorTransport.candidates(for: url, roles: policy.roles)
        guard !routes.isEmpty else {
            return try await fetchBytes(url, kind: kind)
        }
        return try await AndroidHubMirrorTransport.load(url, roles: policy.roles) { [self] route in
            try await self.fetchBytes(route, kind: kind)
        }
    }

    /// One request over the ORIGINAL qualified service. HTTP-level failures
    /// normalize onto the mirror classifier's typed surface; cancellation,
    /// oversize and local file failures keep their original typed
    /// semantics and therefore NEVER qualify for a mirror route.
    private func fetchBytes(_ url: URL, kind: BodyKind, maximumBytes: Int = 262_144) async throws -> Data {
        switch kind {
        case .document:
            let response = try await http.send(method: "GET", url: url,
                                               headers: [:], body: nil,
                                               timeout: 30,
                                               maxResponseBytes: maximumBytes)
            guard (200...299).contains(response.statusCode) else {
                throw AndroidHubMirrorTransport.Failure.httpStatus(response.statusCode)
            }
            guard !response.truncated, response.body.utf8.count <= maximumBytes else {
                throw TransportError.oversized("document")
            }
            return Data(response.body.utf8)
        case .envelope:
            let response = try await http.send(method: "GET", url: url,
                                               headers: [:], body: nil,
                                               timeout: 30,
                                               maxResponseBytes: FinderSkillEnvelope.maximumEnvelopeBytes)
            guard (200...299).contains(response.statusCode) else {
                throw AndroidHubMirrorTransport.Failure.httpStatus(response.statusCode)
            }
            guard !response.truncated, response.body.utf8.count <= FinderSkillEnvelope.maximumEnvelopeBytes else {
                throw TransportError.oversized("envelope")
            }
            return Data(response.body.utf8)
        case .boundedArchive:
            return try await downloadBounded(url: url, maxBytes: 8_388_608)
        }
    }

    /// One immutable discovery snapshot, using compiled routes only. It
    /// never calls the policy store and cannot recursively trust a mirror.
    private func downloadMirrorManifest() async throws -> AndroidHubMirrorPolicyStore.Downloaded {
        guard let atomURL = AndroidHubMirrorTransport.atomURL(
            owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository) else {
            throw AndroidHubMirrorManifestFailure.unavailable
        }
        let atom = try await AndroidHubMirrorTransport.load(atomURL, roles: .bundled) { [self] target in
            try await self.fetchBytes(target, kind: .document)
        }
        try Task.checkCancellation()
        let commit = try AndroidHubAtomCommit.extract(atom, owner: CuratedSkillHub.owner,
                                                      repository: CuratedSkillHub.repository)
        func fetch(_ path: String, maximumBytes: Int) async throws -> Data {
            guard let url = AndroidHubMirrorTransport.rawFileURL(
                owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository,
                commit: commit, path: path) else {
                throw AndroidHubMirrorManifestFailure.unavailable
            }
            return try await AndroidHubMirrorTransport.load(url, roles: .bundled) { [self] target in
                try await self.fetchBytes(target, kind: .document, maximumBytes: maximumBytes)
            }
        }
        async let payload = fetch(AndroidHubTransportMirrorManifest.payloadPath,
                                  maximumBytes: AndroidHubTransportMirrorManifest.maximumPayloadBytes)
        async let signature = fetch(AndroidHubTransportMirrorManifest.signaturePath,
                                    maximumBytes: AndroidHubTransportMirrorManifest.maximumSignatureBytes)
        return try await .init(payload: payload, signature: signature)
    }

    func downloadBounded(url: URL, maxBytes: Int) async throws -> Data {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-hub-\(UUID().uuidString)")
        let cancellation = CancellationToken()
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let result = try await withTaskCancellationHandler {
                try await http.download(url: url, timeout: 60, maxBytes: maxBytes,
                                        to: scratch, cancellation: cancellation)
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
            let data = try Data(floeContentsOf: scratch, options: [.mappedIfSafe])
            guard data.count <= maxBytes, result.byteCount == data.count else {
                throw TransportError.oversized("file")
            }
            try Task.checkCancellation()
            return data
        } catch let error as TransportError {
            throw error
        } catch let error as HTTPRequestError {
            // HTTP-level failures normalize onto the mirror classifier's
            // typed surface so ONLY 408/429/5xx can advance a route; the
            // original typed cancellation/oversize requests keep failing
            // closed here.
            if case .httpStatus(let code) = error {
                throw AndroidHubMirrorTransport.Failure.httpStatus(code)
            }
            throw error
        } catch let error as FloeError {
            // download() types cooperative cancellation as FloeError.cancelled;
            // surface it as cancellation (never a mirror-availability signal).
            if case .cancelled = error {
                throw CancellationError()
            }
            throw error
        }
    }
}

// MARK: - Per-source transport routing (validated source identity only)

/// The ONE routing rule for the two production transports, decided from the
/// VALIDATED source identity — never from a model-supplied skill id or an
/// untrusted URL. `GitHubSkillSource.init` has already enforced the
/// owner/repository charset+length rules, the ref rules and the path
/// traversal rules before any value reaches this discriminator.
///
/// Public/official shapes (⇄ the iOS `SkillHubPublicTransport` short-circuit
/// and `usesConnectorCredential = !OfficialSkillHub.skillIDs.contains(id)`,
/// 2ce48570a): the official catalog path in JiangNanGenius/floe-agent and
/// either channel catalog path in JiangNanGenius/floe-skill-hub keep the
/// UNCHANGED anonymous public mirror transport. Every other validated
/// source is a community source and uses the connector transport (token
/// when configured, anonymous official API otherwise — a missing token is
/// never a blanket refusal, and the source UI cannot prove private/public
/// from a URL).
public enum SkillsRemoteTransportRouting {
    public static func isOfficialHubSource(_ source: GitHubSkillSource) -> Bool {
        if source.owner == OfficialSkillHub.owner,
           source.repository == OfficialSkillHub.repository {
            return source.path == OfficialSkillHub.catalogPath
        }
        if source.owner == CuratedSkillHub.owner,
           source.repository == CuratedSkillHub.repository {
            // Every fixed catalog layout of both channels is an official
            // hub source: the legacy projection, the expanded full feed and
            // the signed large-source capability projection all resolve to
            // the SAME repository identity and keep the public transport.
            return CuratedSkillCatalogLayout.allCases.contains {
                source.path == CuratedSkillHub.catalogPath(for: .ios, layout: $0)
                    || source.path == CuratedSkillHub.catalogPath(for: .android, layout: $0)
            }
        }
        return false
    }

    public static func usesConnectorTransport(for source: GitHubSkillSource) -> Bool {
        !isOfficialHubSource(source)
    }

    /// The domain-facing per-source router. `publicHub` keeps the signed
    /// mirror policy, redirect stripping and hub budgets untouched;
    /// `connector` carries the leased connector credential for community
    /// sources only. Finder envelopes are public shapes and always stay on
    /// the public transport.
    public static func transport(for source: GitHubSkillSource,
                                 connector: any SkillsRemoteTransport,
                                 publicHub: any SkillsRemoteTransport) -> any SkillsRemoteTransport {
        usesConnectorTransport(for: source) ? connector : publicHub
    }
}

/// The SkillsDomain-bound router: every resolve/fetch closure in the domain
/// rides this single value, so install AND upgrade-check selection is the
/// same validated-identity decision at every call site. Both transports
/// share the SAME qualified HTTPRequestService (single-session doctrine) —
/// this router adds no session, engine or policy of its own.
public struct SkillsRemoteTransportRouter: SkillsRemoteTransport {
    private let connector: any SkillsRemoteTransport
    private let publicHub: any SkillsRemoteTransport

    public init(connector: any SkillsRemoteTransport, publicHub: any SkillsRemoteTransport) {
        self.connector = connector
        self.publicHub = publicHub
    }

    public func resolveCommit(_ source: GitHubSkillSource) async throws -> String {
        try await SkillsRemoteTransportRouting
            .transport(for: source, connector: connector, publicHub: publicHub)
            .resolveCommit(source)
    }

    public func fetch(_ source: GitHubSkillSource, commit: String,
                      path: String) async throws -> Data {
        try await SkillsRemoteTransportRouting
            .transport(for: source, connector: connector, publicHub: publicHub)
            .fetch(source, commit: commit, path: path)
    }

    public func fetch(_ source: GitHubSkillSource, commit: String,
                      path: String,
                      verifiedPackage: CuratedSkillHub.PackageDownloadAuthorization?) async throws -> Data {
        // Route by the SAME validated source identity. Curated package
        // authorizations only exist for official-hub sources, so this lands
        // on the public transport's authenticated budget path; the connector
        // transport's default implementation fails closed for them.
        try await SkillsRemoteTransportRouting
            .transport(for: source, connector: connector, publicHub: publicHub)
            .fetch(source, commit: commit, path: path, verifiedPackage: verifiedPackage)
    }

    public func fetchFinderEnvelope(url: URL) async throws -> Data {
        try await publicHub.fetchFinderEnvelope(url: url)
    }
}

// MARK: - Honest-unavailable fallback (no connector transport bound)

/// Explicit unavailable adapter retained for existing consumers. It is
/// neither the production binding nor the no-token fallback: existing
/// callers retain their configured public transport, while production
/// binds the credential-aware adapter at G02DomainServices.
public struct SkillsConnectorFetchUnavailable: SkillsRemoteTransport {
    public init() {}
    public func resolveCommit(_ source: GitHubSkillSource) async throws -> String {
        throw SkillsDomainRefusal.transportUnavailable
    }
    public func fetch(_ source: GitHubSkillSource, commit: String,
                      path: String) async throws -> Data {
        throw SkillsDomainRefusal.transportUnavailable
    }
    public func fetchFinderEnvelope(url: URL) async throws -> Data {
        throw SkillsDomainRefusal.transportUnavailable
    }
}

// MARK: - Production binding (available public-HTTPS transport)

/// The composition binds THIS for the configured public GitHub/hub path
/// instead of `SkillsRemoteTransportUnavailable`: the ORIGINAL qualified
/// `HTTPRequestService` (bounded incremental session over `FloeTransport`,
/// public-target/redirect policy, cookie/credential-store-free configuration)
/// behind the allow-listed adapter above. Ordinary public HTTPS resolveCommit/
/// fetch/Finder requests use the public adapter; production separately
/// binds the existing credential lease for community/private sources.
public enum SkillsRemoteTransportComposition {
    /// One transport, one session: create the qualified HTTP service here.
    public static func makePublicHubTransport() -> any SkillsRemoteTransport {
        WebToolsSkillsRemoteTransport(http: HTTPRequestService())
    }

    /// Reuse ONE already-qualified HTTP service (single-session doctrine).
    public static func makePublicHubTransport(
        http: HTTPRequestService) -> any SkillsRemoteTransport {
        WebToolsSkillsRemoteTransport(http: http)
    }

    /// Production binding with a service-owned mirror-policy store: the
    /// store (not any view or task) owns the atomic last-good record and
    /// the monotonic generation floor; `persistenceURL` lives in
    /// service-owned storage.
    public static func makePublicHubTransport(
        http: HTTPRequestService,
        mirrorPolicy: AndroidHubMirrorPolicyStore) -> any SkillsRemoteTransport {
        WebToolsSkillsRemoteTransport(http: http, mirrorPolicy: mirrorPolicy)
    }

    /// Production community/private connector binding: the SAME qualified
    /// HTTP service (single-session doctrine — callers pass the SAME
    /// instance they gave `makePublicHubTransport`), the existing leased
    /// GitHub credential store (read per request; never cached here), and
    /// the public transport as the anonymous delegate: tokenless community
    /// sources keep the existing immutable raw path through it, and it
    /// keeps every Finder envelope. `apiBase` stays pinned to api.github.com
    /// in production; the loopback override exists solely for the host test
    /// fixture.
    public static func makeConnectorTransport(
        http: HTTPRequestService,
        credentials: GitHubCredentialStore,
        anonymous publicHub: any SkillsRemoteTransport,
        apiBase: URL = WebToolsSkillsConnectorTransport.productionAPIBase) -> any SkillsRemoteTransport {
        WebToolsSkillsConnectorTransport(http: http, credentials: credentials,
                                         anonymousTransport: publicHub, apiBase: apiBase)
    }
}
