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
// (private source candidate; NOT compiled, NOT executed, NOT registered.)
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
import Foundation
import FloeCore
import FloeSkills
import FloeTools
import FloeAndroidWebTools

// MARK: - GitHub/Hub transport

public struct WebToolsSkillsRemoteTransport: SkillsRemoteTransport {
    private let http: HTTPRequestService

    /// One transport, one session (AGENTS invariant): bind the SAME
    /// qualified HTTPRequestService used by the D1 web tools; do not
    /// construct another URLSession here.
    public init(http: HTTPRequestService) {
        self.http = http
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
    // The fixed Android skill channel (`skill-hub/android/catalog.json`,
    // `skill-hub/android/catalog.sig` and the matching immutable package ZIPs)
    // is served by these SAME hosts: api.github.com for commit resolution,
    // raw.githubusercontent.com for immutable blobs, and github.com for the
    // reviewed blob URL shape (provenance/finder envelopes). Enabling the
    // Android channel therefore adds NO host, wildcard, redirect widening or
    // private-repo credential path; the per-request byte bounds below are
    // unchanged (catalog/signature 256 KiB, package ZIP ≤8 MiB).

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
    public func fetch(_ source: GitHubSkillSource, commit: String,
                      path: String) async throws -> Data {
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else {
            throw SkillUpgradeError.invalidCommit
        }
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = try Self.validated(url: URL(string:
            "https://raw.githubusercontent.com/\(source.owner)/\(source.repository)/\(commit.lowercased())/\(encodedPath)")!)
        if path.hasSuffix(".zip") {
            return try await downloadBounded(url: url, maxBytes: 8_388_608)
        }
        let response = try await http.send(method: "GET", url: url,
                                           headers: [:], body: nil,
                                           timeout: 30,
                                           maxResponseBytes: 262_144)
        guard (200...299).contains(response.statusCode) else {
            throw TransportError.status(response.statusCode)
        }
        guard !response.truncated else {
            throw TransportError.oversized("document")
        }
        return Data(response.body.utf8)
    }

    /// Finder envelope ingest (≤262 KiB exactly like the original cap at
    /// SkillsCenter:454-455). https-only + public-target policy is enforced
    /// by HTTPRequestService itself (PublicNetworkTargetPolicy: LAN/
    /// loopback/CGNAT refused).
    public func fetchFinderEnvelope(url: URL) async throws -> Data {
        let target = try Self.validated(url: url)
        let response = try await http.send(method: "GET", url: target,
                                           headers: [:], body: nil,
                                           timeout: 30,
                                           maxResponseBytes: FinderSkillEnvelope.maximumEnvelopeBytes)
        guard (200...299).contains(response.statusCode) else {
            throw TransportError.status(response.statusCode)
        }
        guard !response.truncated, response.body.utf8.count <= FinderSkillEnvelope.maximumEnvelopeBytes else {
            throw TransportError.oversized("envelope")
        }
        return Data(response.body.utf8)
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
        } catch {
            throw TransportError.status(-1)
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
}
