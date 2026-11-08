// SPDX-License-Identifier: MPL-2.0
//
// Android skills connector DOMAIN routing — qualification TEST SOURCE
// (authored, NOT executed by this source-only lane; Main runs the composed
// Swift/Native batch). Pins the real consumer wiring: the SkillsDomain
// router selects the connector transport for validated community sources
// and keeps official/curated Hub identities on the UNCHANGED anonymous
// public transport; tokenless community checks keep the existing anonymous
// path (never the rate-limited contents API); staged bytes still pass the
// UNCHANGED hash/staging verifiers; access failures surface the typed
// credentialUnavailable/githubConnectorAccess remediation. The credentialed
// end-to-end case runs the REAL WebToolsSkillsConnectorTransport against
// the synthetic 127.0.0.1 loopback fixture with a SYNTHETIC token. No real
// account, device, mirror or external network is touched.
#if canImport(Darwin)
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeSkills
import FloeTools
import FloePersistence
import FloeGit
import FloeAndroidWebTools

final class AndroidSkillsConnectorDomainTests: XCTestCase, @unchecked Sendable {

    private let pin = "0123456789abcdef0123456789abcdef01234567"
    private let token = "synthetic-gh-token-cafef00d-0123456789abcdef"

    // MARK: - Test doubles

    private struct SyntheticLease: GitHubCredentialLeasing {
        let value: String?
        func leasedToken() async throws -> String? { value }
    }

    /// Records transport calls and serves a scripted community upgrade:
    /// one immutable commit, one package-entry inventory, hash-matched
    /// file bytes (or scripted failures) — the unchanged staging chain
    /// decides what commits.
    private final class RecordingTransport: SkillsRemoteTransport, @unchecked Sendable {
        struct Call: Sendable { let kind: String; let owner: String; let repository: String; let path: String }
        private let lock = NSLock()
        private var calls: [Call] = []
        var resolveResult: Result<String, Error> = .success("")
        var entryBody: Result<Data, Error> = .success(Data())
        var fileBodies: [String: Result<Data, Error>] = [:]
        var envelope: Result<Data, Error> = .success(Data("envelope".utf8))

        func snapshot() -> [Call] { lock.withLock { calls } }
        private func record(_ kind: String, _ source: GitHubSkillSource, _ path: String = "") {
            lock.withLock {
                calls.append(Call(kind: kind, owner: source.owner,
                                  repository: source.repository, path: path))
            }
        }
        func resolveCommit(_ source: GitHubSkillSource) async throws -> String {
            record("resolve", source)
            return try resolveResult.get()
        }
        func fetch(_ source: GitHubSkillSource, commit: String, path: String) async throws -> Data {
            record("fetch", source, path)
            if path == source.path { return try entryBody.get() }
            return try fileBodies[path, default: .failure(SkillsDomainRefusal.transportUnavailable)].get()
        }
        func fetchFinderEnvelope(url: URL) async throws -> Data {
            lock.withLock { calls.append(Call(kind: "envelope", owner: url.host ?? "",
                                              repository: "", path: url.path)) }
            return try envelope.get()
        }
    }

    private func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    private func communitySource(path: String = "pkg/inventory.json") throws -> GitHubSkillSource {
        try GitHubSkillSource(owner: "octo-org", repository: "community-skill",
                              ref: "main", path: path)
    }

    private func sha256Hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The staged community upgrade script: entry inventory JSON naming
    /// SKILL.md + floe.json with the INSTALLED bytes' real hashes, so the
    /// unchanged downstream digest verifier passes.
    private func scriptCommunityUpgrade(_ stub: RecordingTransport,
                                        fixture: RB6TestFixture,
                                        skillID: String,
                                        tamperSkillMarkdown: Bool = false) throws {
        let root = fixture.installationRoot.appendingPathComponent(skillID, isDirectory: true)
        var skill = try Data(floeContentsOf: root.appendingPathComponent("SKILL.md"))
        let manifest = try Data(floeContentsOf: root.appendingPathComponent("floe.json"))
        stub.resolveResult = .success(pin)
        let inventory = try JSONSerialization.data(
            withJSONObject: ["files": ["SKILL.md": sha256Hex(skill),
                                       "floe.json": sha256Hex(manifest)]],
            options: [.sortedKeys])
        stub.entryBody = .success(inventory)
        if tamperSkillMarkdown { skill.append(Data("tampered".utf8)) }
        stub.fileBodies = ["pkg/SKILL.md": .success(skill), "pkg/floe.json": .success(manifest)]
    }

    private func makeDomain(_ id: String,
                            public publicTransport: RecordingTransport,
                            connector connectorTransport: any SkillsRemoteTransport)
        async throws -> (RB6TestFixture, SkillsDomain) {
        let fixture = try await RB6TestFixture.make(id: id)
        let domain = try SkillsDomain(services: .init(
            database: fixture.database,
            installationRoot: fixture.installationRoot,
            stagingRoot: fixture.stagingRoot,
            hostContext: fixture.hostContext,
            transport: publicTransport,
            connectorTransport: connectorTransport,
            rewriter: SkillModelRewritingUnavailable(),
            ownedWork: fixture.ownedWorkLifecycle(),
            toolWork: FacadeToolWorkCoordinator(),
            registry: ToolRunnerRegistry()))
        return (fixture, domain)
    }

    private func installCommunitySkill(_ domain: SkillsDomain,
                                       _ name: String = "Connector Routing Skill") async throws -> String {
        let projection = try await domain.createSkill(
            draft: SkillCreationRequest(name: name, description: "routing test",
                                        instructions: "Verify per-source transport selection."))
        XCTAssertTrue(projection.committed,
                      "a workspace.read-only creator skill installs under the original automatic policy")
        return projection.skillID
    }

    override func tearDown() async throws {
        await RB6TestFixture.shutdownCurrent()
    }

    // MARK: - Router unit selection (validated source identity)

    func testRouterSelectsPublicForHubIdentitiesAndConnectorForCommunity() async throws {
        let publicStub = RecordingTransport()
        let connectorStub = RecordingTransport()
        publicStub.resolveResult = .success(pin)
        connectorStub.resolveResult = .success(pin)
        let router = SkillsRemoteTransportRouter(connector: connectorStub, publicHub: publicStub)

        _ = try await router.resolveCommit(OfficialSkillHub.source())
        _ = try await router.fetch(try CuratedSkillHub.source(channel: .ios),
                                   commit: pin, path: "catalog.json")
        _ = try await router.fetch(try CuratedSkillHub.source(channel: .android),
                                   commit: pin, path: "android/catalog.json")
        let community = try communitySource()
        _ = try await router.fetch(community, commit: pin, path: community.path)
        _ = try await router.fetchFinderEnvelope(url: URL(string: "https://example.com/e.json")!)

        // Official + curated identities AND every envelope stay public.
        XCTAssertEqual(publicStub.snapshot().map(\.path),
                       ["", "catalog.json", "android/catalog.json", "/e.json"])
        // Only the validated community source touches the connector.
        XCTAssertEqual(connectorStub.snapshot().map(\.path), ["pkg/inventory.json"])
    }

    // MARK: - Real consumer: community upgrade checks ride the connector

    func testCommunityCheckUpgradeSelectsConnectorWhilePublicStaysIdle() async throws {
        let publicStub = RecordingTransport()
        let connectorStub = RecordingTransport()
        let (fixture, domain) = try await makeDomain(
            "conn-community", public: publicStub, connector: connectorStub)
        let skillID = try await installCommunitySkill(domain)
        try scriptCommunityUpgrade(connectorStub, fixture: fixture, skillID: skillID)

        let projection = try await domain.checkUpgrade(
            skillID: skillID, source: communitySource())
        XCTAssertFalse(projection.token.isEmpty)
        XCTAssertEqual(projection.skillID, skillID)
        // resolve + entry + two inventory files — all on the connector.
        XCTAssertEqual(connectorStub.snapshot().map(\.kind),
                       ["resolve", "fetch", "fetch", "fetch"])
        XCTAssertEqual(connectorStub.snapshot()[1...].map(\.path),
                       ["pkg/inventory.json", "pkg/SKILL.md", "pkg/floe.json"])
        // The public transport (Hub + mirror policy) saw nothing.
        XCTAssertTrue(publicStub.snapshot().isEmpty)
    }

    func testHubShapedCommunitySourceKeepsThePublicTransport() async throws {
        let publicStub = RecordingTransport()
        let connectorStub = RecordingTransport()
        let (fixture, domain) = try await makeDomain(
            "conn-hubshape", public: publicStub, connector: connectorStub)
        let skillID = try await installCommunitySkill(domain)
        // A community check whose source IDENTITY is the official catalog
        // shape stays on the anonymous public transport by routing rule.
        let hubShaped = try GitHubSkillSource(
            owner: OfficialSkillHub.owner, repository: OfficialSkillHub.repository,
            ref: "main", path: OfficialSkillHub.catalogPath)
        try scriptCommunityUpgrade(publicStub, fixture: fixture, skillID: skillID)

        let projection = try await domain.checkUpgrade(skillID: skillID, source: hubShaped)
        XCTAssertFalse(projection.token.isEmpty)
        XCTAssertEqual(publicStub.snapshot().map(\.kind),
                       ["resolve", "fetch", "fetch", "fetch"])
        XCTAssertTrue(connectorStub.snapshot().isEmpty)
    }

    func testTokenlessCommunityCheckUpgradeKeepsTheAnonymousPublicPath() async throws {
        // REAL connector adapter with NO configured token: every community
        // call must delegate to the anonymous public transport — tokenless
        // public installs never touch the rate-limited contents API.
        let server = try ScriptedLoopbackFixture()
        server.start()
        defer { server.stop() }
        let publicStub = RecordingTransport()
        let connector = WebToolsSkillsConnectorTransport(
            http: HTTPRequestService(configuration: ephemeralConfiguration(),
                                     allowsPrivateNetwork: true),
            credentials: GitHubCredentialStore(lease: SyntheticLease(value: nil)),
            anonymousTransport: publicStub,
            apiBase: URL(string: "http://127.0.0.1:\(server.port)")!)
        let (fixture, domain) = try await makeDomain(
            "conn-tokenless", public: publicStub, connector: connector)
        let skillID = try await installCommunitySkill(domain)
        try scriptCommunityUpgrade(publicStub, fixture: fixture, skillID: skillID)

        let projection = try await domain.checkUpgrade(
            skillID: skillID, source: communitySource())
        XCTAssertFalse(projection.token.isEmpty)
        XCTAssertEqual(publicStub.snapshot().map(\.kind),
                       ["resolve", "fetch", "fetch", "fetch"])
        XCTAssertTrue(server.requests.isEmpty,
                      "no-token community fetch must keep the existing anonymous path, not the contents API")
    }

    // MARK: - Unchanged integrity and staging gates

    func testTamperedInventoryBytesStillFailTheUnchangedHashGate() async throws {
        let publicStub = RecordingTransport()
        let connectorStub = RecordingTransport()
        let (fixture, domain) = try await makeDomain(
            "conn-integrity", public: publicStub, connector: connectorStub)
        let skillID = try await installCommunitySkill(domain)
        try scriptCommunityUpgrade(connectorStub, fixture: fixture, skillID: skillID,
                                   tamperSkillMarkdown: true)

        do {
            _ = try await domain.checkUpgrade(skillID: skillID, source: communitySource())
            XCTFail("tampered bytes must fail the unchanged digest verifier")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .invalidEnvelope)
            XCTAssertTrue(error.reason.hasPrefix("upgrade.hashMismatch"),
                          "unexpected reason \(error.reason)")
        }
        XCTAssertEqual(connectorStub.snapshot().map(\.kind),
                       ["resolve", "fetch", "fetch"])
        XCTAssertTrue(publicStub.snapshot().isEmpty)
    }

    // MARK: - Honest access remediation end-to-end (real connector, fixture API)

    func testCredentialedAccessFailureMapsToTypedRemediation() async throws {
        let server = try ScriptedLoopbackFixture()
        let path = "/repos/octo-org/community-skill/commits/main"
        server.register(path: path) { connection in
            connection.sendHead(status: 403, headers: ["content-length": "0"])
        }
        server.start()
        defer { server.stop() }
        let publicStub = RecordingTransport()
        let connector = WebToolsSkillsConnectorTransport(
            http: HTTPRequestService(configuration: ephemeralConfiguration(),
                                     allowsPrivateNetwork: true),
            credentials: GitHubCredentialStore(lease: SyntheticLease(value: token)),
            anonymousTransport: publicStub,
            apiBase: URL(string: "http://127.0.0.1:\(server.port)")!)
        let (_, domain) = try await makeDomain(
            "conn-access", public: publicStub, connector: connector)
        let skillID = try await installCommunitySkill(domain)

        do {
            _ = try await domain.checkUpgrade(skillID: skillID, source: communitySource())
            XCTFail("a credentialed 403 must not produce a candidate")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .credentialUnavailable)
            XCTAssertEqual(error.reason, "githubConnectorAccess")
        }
        // Fail closed: exactly one API request, no anonymous retry, no mirror.
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(publicStub.snapshot().isEmpty)
    }
}
#endif
