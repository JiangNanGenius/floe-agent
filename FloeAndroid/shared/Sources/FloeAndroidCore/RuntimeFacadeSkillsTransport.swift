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
// 512 KiB-per-request internal clamp via send() and file-bounded download()).
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
// A configured connector credential for PRIVATE repos (the iOS
// usesConnectorCredential path, SkillsCenter:154) is NOT reimplemented:
// private-ref fetch is honestly refused (the capability stays declared;
// Main's G03/connector lane owns the real backend). No token is read, no
// auth header is fabricated.
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

    /// Immutable blob fetch at a resolved commit. Files ≤8 MiB route
    /// through the bounded download path (oversized ⇒ deleted + typed
    /// error — the ORIGINAL download semantics, never a partial keep);
    /// smaller documents use send() within its 256 KiB internal clamp.
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
        return try await loadWithMirrorPolicy(url: url,
                                              kind: path.hasSuffix(".zip") ? .boundedArchive : .document)
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

    private func downloadBounded(url: URL, maxBytes: Int) async throws -> Data {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-hub-\(UUID().uuidString)")
        do {
            _ = try await http.download(url: url, timeout: 60, maxBytes: maxBytes,
                                        to: scratch)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let data = try Data(floeContentsOf: scratch, options: [.mappedIfSafe])
            guard data.count <= maxBytes else {
                throw TransportError.oversized("zip")
            }
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

// MARK: - Honest-unavailable private/connector fetch (declared, not faked)

/// The iOS private-repo path (SkillUpgradeCandidate for community sources
/// with a connector credential, SkillsCenter:154 `usesCredential`) depends
/// on SourceControlCenter/GitHub credential stores NOT present in the G02
/// overlay. Until Main binds that backend, private fetch is EXACTLY this:
/// typed refusal, capability retained. The public-web hub path above is
/// unaffected. No token is read here, no header is faked.
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
/// fetch/Finder requests are therefore genuinely available once the host
/// binds the transport; a private/connector-credential source stays typed
/// unavailable (its iOS credential store is not part of G02).
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
}
