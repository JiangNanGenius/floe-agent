// Contract tests for the curated schemaVersion-3 Skill Hub client (lane A1).
//
// Everything here verifies against the EXACT H1 fixture bytes copied under
// `Fixtures/CuratedSkillHub` (see PROVENANCE.md): both channels, the strict
// structural gates, the pinned resolve-once Y fetch flow, the X/Y receipt
// separation, the exact-bytes signature and three-way review joins, the
// unqualified-offer wall, archive bounds and the permission-delta math.
// Fixture mutations are re-signed with the documented public-knowledge
// ephemeral fixture seed — the fixture key is never production trust and is
// only ever loaded through the explicit `fixtureTestOnly` policy.
//
// The legacy four-item decoder is exercised unchanged as a boundary witness:
// the new client rejects legacy bytes and the legacy client rejects fixture
// bytes. These tests intentionally avoid asserting anything about production
// publication: production is honestly NOT published; no test fabricates a
// selectable-43 or live-feed claim.

import Foundation
import Testing
import Crypto
import ZIPFoundation
@testable import FloeSkills

private struct UnexpectedSuccess: Error {}

private struct HubTransportError: Error { let path: String }

private struct CuratedFixtureError: Error { let relativePath: String }

/// Anchor class so `Bundle(for:)` resolves the actual test bundle image when
/// these tests are hosted inside the app's test target. The curated fixture
/// folder is registered as a folder resource in the TEST bundle only (Main
/// owns project.yml membership); the fixture key must never enter production
/// App resources.
private final class CuratedSkillHubFixtureAnchor: NSObject {}

/// Locates the `CuratedSkillHub` fixture folder. Preference order, no silent
/// fallback and no skips: (1) the registered folder resource in the bundle
/// containing this test target's anchor class; (2) the source-tree path via
/// `#filePath` (host SwiftPM runs, and local simulator runs which share the
/// host filesystem). If neither exists, every fixture read throws.
private func curatedFixtureRootCandidates() -> [URL] {
    let bundle = Bundle(for: CuratedSkillHubFixtureAnchor.self)
    var candidates: [URL] = []
    if let resourceURL = bundle.resourceURL?
        .appendingPathComponent("CuratedSkillHub", isDirectory: true),
       FileManager.default.fileExists(atPath: resourceURL
           .appendingPathComponent("catalog.json").path) {
        candidates.append(resourceURL)
    }
    if let nested = bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "CuratedSkillHub")?
        .deletingLastPathComponent() {
        if !candidates.contains(nested) { candidates.append(nested) }
    }
    candidates.append(URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("CuratedSkillHub", isDirectory: true))
    return candidates
}

private func curatedFixture(_ relativePath: String) throws -> Data {
    let components = relativePath.split(separator: "/").map(String.init)
    var attempted: [String] = []
    for root in curatedFixtureRootCandidates() {
        let file = components.reduce(root) { partial, name in
            partial.appendingPathComponent(name, isDirectory: false)
        }
        if FileManager.default.fileExists(atPath: file.path) {
            return try Data(contentsOf: file)
        }
        attempted.append(file.path)
    }
    throw CuratedFixtureError(relativePath: relativePath + " (attempted: " + attempted.joined(separator: ", ") + ")")
}

/// Records resolve/fetch traffic so pinning is provable, not aspirational.
private actor HubTransport {
    private let files: [String: Data]
    private let commits: [String]
    private var resolveCount = 0
    private var fetchLog: [(commit: String, path: String)] = []

    init(files: [String: Data], commits: [String]) {
        self.files = files
        self.commits = commits
    }

    func resolve() throws -> String {
        resolveCount += 1
        guard !commits.isEmpty else { throw HubTransportError(path: "#resolve") }
        return commits[min(resolveCount - 1, commits.count - 1)]
    }

    func fetch(commit: String, path: String) throws -> Data {
        fetchLog.append((commit: commit, path: path))
        guard let data = files[path] else { throw HubTransportError(path: path) }
        return data
    }

    func snapshot() -> (resolveCount: Int, fetches: [(commit: String, path: String)]) {
        (resolveCount: resolveCount, fetches: fetchLog)
    }
}

private func makeClosures(_ transport: HubTransport)
    -> (GitHubSkillDownload.ResolveCommit, GitHubSkillDownload.FetchFile)
{
    let resolve: GitHubSkillDownload.ResolveCommit = { _ in try await transport.resolve() }
    let fetch: GitHubSkillDownload.FetchFile = { _, commit, path in try await transport.fetch(commit: commit, path: path) }
    return (resolve, fetch)
}

// MARK: - Fixture key material (public-knowledge ephemeral seed, hubcore)

private let fixtureSeedLabel = Data(
    ("floe-skill-hub fixture-only ephemeral Ed25519 key 2026-10 "
     + "-- NOT a trust root -- NOT production material").utf8)

private func fixturePrivateKey() throws -> Curve25519.Signing.PrivateKey {
    try Curve25519.Signing.PrivateKey(rawRepresentation: Data(SHA256.hash(data: fixtureSeedLabel)))
}

private func fixturePublicKeyRaw() throws -> Data {
    try fixturePrivateKey().publicKey.rawRepresentation
}

private func fixtureMode() throws -> CuratedSkillTrustMode {
    .fixtureTestOnly(fixturePublicKey: try fixturePublicKeyRaw())
}

private func signedEnvelope(over payload: Data) throws -> Data {
    let signature = try fixturePrivateKey().signature(for: payload)
    return Data("{\"keyID\":\"\(CuratedSkillHub.fixtureKeyID)\",\"signature\":\"\(Data(signature).base64EncodedString())\"}".utf8)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Replace one occurrence (or all) of an exact canonical substring, keeping
/// the JSON canonical apart from the value swap (signatures are then
/// recomputed over the exact mutated bytes).
private func mutate(_ data: Data, _ pattern: String, to replacement: String, replaceAll: Bool = false) throws -> Data {
    guard var text = String(data: data, encoding: .utf8) else { throw UnexpectedSuccess() }
    var searchRange = text.startIndex..<text.endIndex
    var replaced = 0
    while let found = text.range(of: pattern, range: searchRange) {
        text.replaceSubrange(found, with: replacement)
        replaced += 1
        if !replaceAll { break }
        searchRange = text.index(found.lowerBound, offsetBy: replacement.count)..<text.endIndex
    }
    guard replaced > 0 else { throw UnexpectedSuccess() }
    return Data(text.utf8)
}

private func iosFixtureFiles() throws -> [String: Data] {
    try [
        "catalog.json": curatedFixture("catalog.json"),
        "catalog.sig": curatedFixture("catalog.sig"),
        "packages/fixture-guide/1.0.0/fixture-guide.zip": curatedFixture("packages/fixture-guide/1.0.0/fixture-guide.zip"),
        "packages/fixture-script/1.0.0/fixture-script.zip": curatedFixture("packages/fixture-script/1.0.0/fixture-script.zip"),
        "packages/fixture-reviewed/1.0.0/fixture-reviewed.zip": curatedFixture("packages/fixture-reviewed/1.0.0/fixture-reviewed.zip"),
        "reviews/fixture-reviewed/1.0.0.review.json": curatedFixture("reviews/fixture-reviewed/1.0.0.review.json"),
        "reviews/fixture-reviewed/1.0.0.review.json.sig": curatedFixture("reviews/fixture-reviewed/1.0.0.review.json.sig"),
    ]
}

private func androidFixtureFiles() throws -> [String: Data] {
    try [
        "android/catalog.json": curatedFixture("android/catalog.json"),
        "android/catalog.sig": curatedFixture("android/catalog.sig"),
        "android/packages/fixture-guide/1.0.0/fixture-guide.zip": curatedFixture("android/packages/fixture-guide/1.0.0/fixture-guide.zip"),
        "android/packages/fixture-script/1.0.0/fixture-script.zip": curatedFixture("android/packages/fixture-script/1.0.0/fixture-script.zip"),
        "android/packages/fixture-reviewed/1.0.0/fixture-reviewed.zip": curatedFixture("android/packages/fixture-reviewed/1.0.0/fixture-reviewed.zip"),
        "reviews/fixture-reviewed/1.0.0.review.json": curatedFixture("reviews/fixture-reviewed/1.0.0.review.json"),
        "reviews/fixture-reviewed/1.0.0.review.json.sig": curatedFixture("reviews/fixture-reviewed/1.0.0.review.json.sig"),
    ]
}

private func stagingRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func caseName(_ failure: CuratedSkillHubFailure) -> String {
    String(String(describing: failure).prefix { $0 != "(" })
}

private func expectCuratedFailure(
    _ run: () throws -> Void,
    case expected: String,
    containing fragment: String? = nil
) throws {
    do {
        try run()
    } catch let failure as CuratedSkillHubFailure {
        #expect(caseName(failure) == expected, "expected case '\(expected)', got \(failure)")
        if let fragment {
            #expect(String(describing: failure).contains(fragment), "failure \(failure) lacks '\(fragment)'")
        }
        return
    }
    throw UnexpectedSuccess()
}

private func expectCuratedFailureAsync(
    _ run: () async throws -> Void,
    case expected: String,
    containing fragment: String? = nil
) async throws {
    do {
        try await run()
    } catch let failure as CuratedSkillHubFailure {
        #expect(caseName(failure) == expected, "expected case '\(expected)', got \(failure)")
        if let fragment {
            #expect(String(describing: failure).contains(fragment), "failure \(failure) lacks '\(fragment)'")
        }
        return
    }
    throw UnexpectedSuccess()
}

@Suite("Curated signed Skill Hub client (schemaVersion 3)")
struct CuratedSkillHubTests {
    private static let iosCatalogDigest = "df0fe20bd55977b160dc8144c0b04bd7ac982547998b0174f4c29c30924cd30b"
    private static let androidCatalogDigest = "40cca611ef3361a4295c64e5b6563c5c1243fe42b8e10d6338f896713198a6cc"

    // MARK: Fixture key + both channels

    @Test("Fixture test key derives from the documented public seed and matches the shipped public key")
    func fixtureKeyDerivation() throws {
        let shipped = try JSONDecoder().decode(
            [String: JSONValue].self, from: curatedFixture("fixture-public-key.json"))
        let publicB64 = try #require((shipped["publicKey"]?.value as? String))
        let decoded = try #require(Data(base64Encoded: publicB64))
        #expect(try fixturePublicKeyRaw() == decoded)
        #expect((shipped["fixtureOnly"]?.value as? Bool) == true)
        #expect((shipped["notATrustRoot"]?.value as? Bool) == true)
        #expect((shipped["keyID"]?.value as? String) == CuratedSkillHub.fixtureKeyID)
    }

    @Test("Both fixture channels verify under the explicit test-only trust, exact bytes and counts intact")
    func bothChannelsVerify() throws {
        let mode = try fixtureMode()
        for (channel, digest) in [
            (CuratedSkillChannel.ios, Self.iosCatalogDigest),
            (CuratedSkillChannel.android, Self.androidCatalogDigest),
        ] {
            let verified = try CuratedSkillHub.verifiedFeed(
                bytes: curatedFixture(CuratedSkillHub.catalogPath(for: channel)),
                signature: curatedFixture(CuratedSkillHub.signaturePath(for: channel)),
                channel: channel, mode: mode)
            #expect(verified.feed.channel == channel)
            #expect(verified.feed.feedStatus == .fixture)
            #expect(verified.feed.sourceCommit == nil)
            #expect(verified.keyID == CuratedSkillHub.fixtureKeyID)
            #expect(verified.catalogSHA256 == digest)
            #expect(verified.feed.permissionPolicy == CuratedSkillPermissionPolicy.contract)
            #expect(verified.feed.counts.total == 3)
            #expect(verified.feed.counts.offerQualified == 0)
            #expect(verified.feed.entries.count == 3)
        }
    }

    @Test("optional authoringPath is preserved as signed provenance without changing authority or execution")
    func authoringPathIsOptionalProvenance() throws {
        enum AuthoringPath {
            case absent
            case null
            case value(String)
        }
        let base = try curatedFixture("catalog.json")
        let canonical = try CuratedSkillFeed.decode(bytes: base, expectedChannel: .ios)
        let before = try #require(canonical.entry(id: "fixture-guide"))

        func upstreamJSON(_ authoring: AuthoringPath) -> String {
            var fields = [
                "\"repository\":\"https://github.com/example/upstream\"",
                "\"commit\":\"4fc2f83e1c8710dba772bfd4523d0efab57737b6\"",
                "\"path\":\"plugin/skills/example\"",
                "\"skillManifestPath\":\"plugin/skills/example/SKILL.md\"",
                "\"retrievedAt\":\"2026-10-26\"",
                "\"licenseStatus\":\"verified\"",
                "\"licenseEvidencePath\":\"LICENSE\"",
                "\"repositoryLicense\":\"Apache-2.0\"",
                "\"licenseNote\":{\"en\":\"Fixture note.\",\"zh-Hans\":\"夹具说明。\"}",
            ]
            switch authoring {
            case .absent: break
            case .null: fields.append("\"authoringPath\":null")
            case .value(let path): fields.append("\"authoringPath\":\"\(path)\"")
            }
            return "{" + fields.joined(separator: ",") + "}"
        }

        func catalog(_ authoring: AuthoringPath) throws -> Data {
            try mutate(base, "\"upstream\":null", to: "\"upstream\":\(upstreamJSON(authoring))")
        }

        func feed(_ authoring: AuthoringPath) throws -> CuratedSkillFeed {
            try CuratedSkillFeed.decode(bytes: catalog(authoring), expectedChannel: .ios)
        }

        // Legacy bytes without the field still decode, and the field absent
        // from a present upstream pin is nil rather than invented.
        let absentFeed = try feed(.absent)
        let absentUpstream = try #require(absentFeed.entry(id: "fixture-guide")?.upstream)
        #expect(absentUpstream.authoringPath == nil)
        #expect(absentUpstream.commit == "4fc2f83e1c8710dba772bfd4523d0efab57737b6")
        #expect(absentUpstream.path == "plugin/skills/example")
        #expect(absentUpstream.licenseStatus == .verified)
        #expect(absentUpstream.licenseNote == CuratedSkillLocalizedText(
            en: "Fixture note.", zhHans: "夹具说明。"))

        // An explicit JSON null is a present-but-null optional, not a string.
        let nullFeed = try feed(.null)
        let nullUpstream = try #require(nullFeed.entry(id: "fixture-guide")?.upstream)
        #expect(nullUpstream.authoringPath == nil)

        // The signed value is preserved exactly and every authority-bearing
        // field stays identical to the same pin without the field.
        let authored = try feed(.value("skill"))
        let after = try #require(authored.entry(id: "fixture-guide"))
        let afterUpstream = try #require(after.upstream)
        #expect(afterUpstream.authoringPath == "skill")
        #expect(afterUpstream.repository == absentUpstream.repository)
        #expect(afterUpstream.commit == absentUpstream.commit)
        #expect(afterUpstream.path == absentUpstream.path)
        #expect(afterUpstream.skillManifestPath == absentUpstream.skillManifestPath)
        #expect(afterUpstream.retrievedAt == absentUpstream.retrievedAt)
        #expect(afterUpstream.licenseStatus == absentUpstream.licenseStatus)
        #expect(afterUpstream.licenseEvidencePath == absentUpstream.licenseEvidencePath)
        #expect(afterUpstream.repositoryLicense == absentUpstream.repositoryLicense)
        #expect(afterUpstream.licenseNote == absentUpstream.licenseNote)

        // Presentation/provenance only: no status, package, review, runtime,
        // offer, source or feed-level policy/authority fact changes.
        #expect(after.status == before.status)
        #expect(after.package == before.package)
        #expect(after.review == before.review)
        #expect(after.runtime == before.runtime)
        #expect(after.installOffer == before.installOffer)
        #expect(after.source == before.source)
        #expect(after.tags == before.tags)
        #expect(after.planNumber == before.planNumber)
        #expect(after.minimumAppVersion == before.minimumAppVersion)
        #expect(authored.feedStatus == canonical.feedStatus)
        #expect(authored.permissionPolicy == canonical.permissionPolicy)
        #expect(authored.counts == canonical.counts)

        // Unknown fields are still refused; this is not a permissive decoder.
        let authoredCatalog = try catalog(.value("skill"))
        let unknown = try mutate(authoredCatalog, "\"authoringPath\":\"skill\"",
                                 to: "\"authoringPath\":\"skill\",\"unexpected\":true")
        do {
            _ = try CuratedSkillFeed.decode(bytes: unknown, expectedChannel: .ios)
            Issue.record("an unknown upstream field must still fail closed")
        } catch let failure as CuratedSkillHubFailure {
            #expect(String(describing: failure).contains("unexpected"),
                    "the failure should name the unknown field, got \(failure)")
        }
    }

    @Test("Compiled production trust is the official identity only; fixture bytes fail under it")
    func productionTrustBoundary() throws {
        #expect(CuratedSkillHub.productionTrustedKeys == OfficialSkillHub.trustedKeys)
        #expect(Set(CuratedSkillHub.productionTrustedKeys.keys) == Set([CuratedSkillHub.productionKeyID]))
        #expect(CuratedSkillHub.productionTrustedKeys[CuratedSkillHub.productionKeyID]?.count == 32)
        // A fixture envelope presented to production trust is a trust-shape
        // violation before crypto: the fixture identity can never verify a
        // production feed, and no fetched data can add it to the map.
        try expectCuratedFailure(
            { try CuratedSkillHub.verifiedFeed(
                bytes: curatedFixture("catalog.json"),
                signature: curatedFixture("catalog.sig"),
                channel: .ios, mode: .production) },
            case: "trust", containing: "production feed")
    }

    @Test("Signature envelope tampering, missing, wrong-key and fixture-in-production all fail closed")
    func signatureRejections() throws {
        let catalog = try curatedFixture("catalog.json")
        let signature = try curatedFixture("catalog.sig")
        let mode = try fixtureMode()
        // Payload tampering (one flipped byte) with the ORIGINAL envelope.
        var tamperedCatalog = catalog
        tamperedCatalog[8] ^= 0x01
        try expectCuratedFailure(
            { try CuratedSkillHub.verifiedFeed(bytes: tamperedCatalog, signature: signature, channel: .ios, mode: mode) },
            case: "signature", containing: "exact")
        // Envelope signature character change (still valid base64, wrong proof).
        let tamperedSignature = try mutate(signature, "\"signature\":\"yXIPdoQ5DZMj", to: "\"signature\":\"yXIPdoQ5DZMh")
        try expectCuratedFailure(
            { try CuratedSkillHub.verifiedFeed(bytes: catalog, signature: tamperedSignature, channel: .ios, mode: mode) },
            case: "signature")
        // Missing signature material.
        try expectCuratedFailure(
            { try CuratedSkillHub.verifiedFeed(bytes: catalog, signature: Data(), channel: .ios, mode: mode) },
            case: "signature")
        // Envelope with an extra key violates the exact {keyID,signature} shape.
        let bloated = try mutate(signature, "{\"keyID\":", to: "{\"surprise\":1,\"keyID\":")
        try expectCuratedFailure(
            { try CuratedSkillHub.verifiedFeed(bytes: catalog, signature: bloated, channel: .ios, mode: mode) },
            case: "signature")
        // Fixture payload presented with the PRODUCTION keyID: passes the
        // trust-shape gate and must fail crypto under the compiled official key.
        let officialKeyed = try mutate(signature, "\"keyID\":\"fixture-only-2026-10\"", to: "\"keyID\":\"official-2026-09\"")
        try expectCuratedFailure(
            { try CuratedSkillHub.verifiedFeed(bytes: catalog, signature: officialKeyed, channel: .ios, mode: .production) },
            case: "signature")
        // Official keyID under the fixture test policy is a trust-shape violation.
        try expectCuratedFailure(
            { try CuratedSkillHub.verifiedFeed(bytes: catalog, signature: officialKeyed, channel: .ios, mode: mode) },
            case: "trust")
        // The fixture policy's trust map is hard-wired to the fixture keyID;
        // the official identity can never be injected through it.
        #expect(try CuratedSkillHub.trustedKeys(for: .fixtureTestOnly(fixturePublicKey: fixturePublicKeyRaw()))
                == [CuratedSkillHub.fixtureKeyID: fixturePublicKeyRaw()])
    }

    @Test("Malformed test-only trust material fails closed")
    func trustConfiguration() throws {
        try expectCuratedFailure(
            { _ = try CuratedSkillHub.trustedKeys(for: .fixtureTestOnly(fixturePublicKey: Data(repeating: 0, count: 31))) },
            case: "trust")
        // Correct keyID in the envelope but WRONG key material: crypto fails.
        let wrongKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        try expectCuratedFailure(
            { try CuratedSkillHub.verifiedFeed(
                bytes: curatedFixture("catalog.json"),
                signature: curatedFixture("catalog.sig"),
                channel: .ios, mode: .fixtureTestOnly(fixturePublicKey: wrongKey)) },
            case: "signature")
    }

    // MARK: Strict structural decode (direct, no trust)

    @Test("Feed structure fails closed on every contract drift")
    func structuralFailClosed() throws {
        let catalog = try curatedFixture("catalog.json")
        func expectFeedDecodeFailure(_ mutated: Data, _ fragment: String, channel: CuratedSkillChannel = .ios) throws {
            do {
                _ = try CuratedSkillFeed.decode(bytes: mutated, expectedChannel: channel)
            } catch let failure as CuratedSkillHubFailure {
                #expect(String(describing: failure).contains(fragment), "wanted '\(fragment)', got \(failure)")
                return
            }
            throw UnexpectedSuccess()
        }
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"schemaVersion\":3", to: "\"schemaVersion\":2"), "schemaVersion must be 3")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"publisher\":\"JiangNanGenius\"", to: "\"publisher\":\"attacker\""), "publisher")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"hubRepository\":\"JiangNanGenius/floe-skill-hub\"",
                       to: "\"hubRepository\":\"attacker/floe-skill-hub\""), "hubRepository")
        // Cross-channel bytes are rejected: android-stamped feed at the iOS path.
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"channel\":\"ios\"", to: "\"channel\":\"android\""),
            "does not match the fetched ios channel", channel: .ios)
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"feedStatus\":\"fixture\"", to: "\"feedStatus\":\"unknown\""), "feedStatus unknown")
        try expectFeedDecodeFailure(
            try mutate(catalog, "{\"channel\"", to: "{\"surprise\":true,\"channel\""), "outside the contract")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"total\":3", to: "\"total\":4"), "drifted")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"deltaOnlyApproval\":true", to: "\"deltaOnlyApproval\":false"), "permissionPolicy")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"feedStatus\":\"fixture\"", to: "\"feedStatus\":\"production\""),
            "audited source commit")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"licenseChecked\":true,\"packaged\":true,\"published\":false,\"qualified\":false,\"reviewed\":true",
                       to: "\"licenseChecked\":false,\"packaged\":true,\"published\":false,\"qualified\":false,\"reviewed\":true"),
            "license check")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"path\":\"reviews/fixture-reviewed/1.0.0.review.json\"",
                       to: "\"path\":\"reviews/other/1.0.0.review.json\""), "reviews/fixture-reviewed")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"packages/fixture-script/1.0.0/fixture-script.zip\"",
                       to: "\"packages/fixture-script/9.9.9/fixture-script.zip\""), "must be")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"installPlatforms\":[\"ios\",\"android\"]",
                       to: "\"installPlatforms\":[\"linux\",\"android\"]", replaceAll: true),
            "outside the store channels")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"capabilities\":[\"execution.remote\",\"workspace.read\",\"workspace.write\"]",
                       to: "\"capabilities\":[\"execution.remote\",\"browser.vision\",\"workspace.read\",\"workspace.write\"]"),
            "outside the native enum")
        try expectFeedDecodeFailure(
            try mutate(catalog, "\"installOffer\":\"fixture-simulated\"", to: "\"installOffer\":\"qualified\""),
            "qualified offers never appear in fixture feeds")
        // Duplicate ids (id AND package path shifted together so the entry
        // itself stays structurally legal until the cross-entry check).
        var duplicated = try mutate(catalog, "\"id\":\"fixture-script\"", to: "\"id\":\"fixture-guide\"")
        duplicated = try mutate(duplicated, "\"packages/fixture-script/1.0.0/fixture-script.zip\"",
                                to: "\"packages/fixture-guide/1.0.0/fixture-guide.zip\"")
        try expectFeedDecodeFailure(duplicated, "duplicate entry id")
    }

    @Test("Real production-signed legacy bytes verify under the legacy decoder and fail closed in the curated client")
    func legacyFeedRejected() throws {
        let legacy = try curatedFixture("legacy/catalog.json")
        let legacySignature = try curatedFixture("legacy/catalog.sig")
        // Integrity of the copied test input: these are the exact tracked
        // public legacy feed bytes (see LEGACY-MANIFEST.sha256). The legacy
        // four-item decoder must accept them under the compiled production
        // trust — this proves the regression exercises a REAL production
        // signature, never a synthesized legacy bypass.
        let package = try OfficialSkillHub.verifiedPackage(
            catalog: legacy, signature: legacySignature,
            id: "floe-pdf", appVersion: "99.0.0", trustedKeys: OfficialSkillHub.trustedKeys)
        #expect(package.id == "floe-pdf")
        // The same genuine bytes fail closed in the curated client purely on
        // the schemaVersion-3 contract gate.
        try expectCuratedFailure(
            { try CuratedSkillHub.verifiedFeed(bytes: legacy, signature: legacySignature, channel: .ios, mode: .production) },
            case: "feed", containing: "schemaVersion must be 3")
    }

    @Test("The legacy decoder still refuses curated fixture bytes (old protocol unchanged)")
    func legacyDecoderUnchanged() throws {
        let officialKeys = OfficialSkillHub.trustedKeys
        #expect(throws: OfficialSkillHub.Failure.signature) {
            _ = try OfficialSkillHub.verifiedPackage(
                catalog: curatedFixture("catalog.json"),
                signature: curatedFixture("catalog.sig"),
                id: "floe-pdf", appVersion: "99.0.0", trustedKeys: officialKeys)
        }
        #expect(OfficialSkillHub.catalogPath == "skill-hub/catalog.json")
        #expect(CuratedSkillHub.catalogPath(for: .ios) == "catalog.json")
        #expect(CuratedSkillHub.repository == "floe-skill-hub" && OfficialSkillHub.repository == "floe-agent")
        // A curated source is never a legacy source and vice versa.
        let curatedSource = try CuratedSkillHub.source(channel: .ios)
        #expect(throws: OfficialSkillHub.Failure.self) {
            try OfficialSkillHub.validateSource(curatedSource)
        }
        #expect(throws: (any Error).self) {
            try CuratedSkillHub.validateSource(OfficialSkillHub.source(), for: .ios)
        }
    }

    // MARK: Pinned load + stage (X/Y)

    @Test("Publication resolves once, fetches every artifact at the same Y, and stages the full chain")
    func pinnedPublicationAndStaging() async throws {
        let transport = HubTransport(
            files: try iosFixtureFiles(),
            commits: [String(repeating: "a", count: 40), String(repeating: "b", count: 40)])
        let (resolve, fetch) = makeClosures(transport)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
        let y = String(repeating: "a", count: 40)
        #expect(publication.publicationCommit == y)
        #expect(publication.auditedSourceCommit == nil)  // fixture X: honest nil, never fabricated
        let root = stagingRoot()
        let staged = try await CuratedSkillHub.stage(
            publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: root, fetch: fetch)
        #expect(staged.content.package.canonicalSHA256
                == "e600ad152d76490da4f9c7c9cc5ad884dd484e139c3dd318b13d3b6363bea62e")
        #expect(staged.archiveSHA256 == "111e5492a0a14895431bd869fc29ed1195625d7a73fbf7f01a38cfe8c73bab26")
        #expect(staged.reviewRecordSHA256 == "d5cedd23ef0a8ecd9eaba754197793ce4e69b692ddd8cb9237bf28518524f14b")
        let receipt = staged.receipt
        #expect(receipt.publicationCommit == y)
        #expect(receipt.auditedSourceCommit == nil)
        #expect(receipt.catalogSHA256 == Self.iosCatalogDigest)
        #expect(receipt.packageSHA256 == staged.archiveSHA256)
        #expect(receipt.contentDigest == staged.content.package.canonicalSHA256)
        #expect(receipt.reviewKeyID == CuratedSkillHub.fixtureKeyID)
        #expect(receipt.reviewStage == .staticContentReviewed)
        #expect(receipt.reviewDecision == .approve)
        #expect(receipt.feedStatus == .fixture)
        #expect(receipt.hubRepository == "JiangNanGenius/floe-skill-hub")
        #expect(receipt.curatedRetrievalEvidence.contentDigest == receipt.contentDigest)
        let snapshot = await transport.snapshot()
        #expect(snapshot.resolveCount == 1)
        #expect(Set(snapshot.fetches.map { $0.commit }) == Set([y]))
        let paths = snapshot.fetches.map { $0.path }
        #expect(paths.contains("catalog.json"))
        #expect(paths.contains("packages/fixture-reviewed/1.0.0/fixture-reviewed.zip"))
        #expect(paths.contains("reviews/fixture-reviewed/1.0.0.review.json"))
        // Receipt persistence: Codable round trip (Main stores through the
        // current SkillStore path; the lane performs no persistence itself).
        let decoded = try JSONDecoder().decode(CuratedSkillHub.Receipt.self, from: try JSONEncoder().encode(receipt))
        #expect(decoded == receipt)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Android channel stages its own package prefix at its own pinned Y")
    func androidChannel() async throws {
        let y = String(repeating: "c", count: 40)
        let transport = HubTransport(files: try androidFixtureFiles(), commits: [y, String(repeating: "d", count: 40)])
        let (resolve, fetch) = makeClosures(transport)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .android, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
        #expect(publication.feed.channel == .android)
        #expect(publication.verifiedFeed.catalogSHA256 == Self.androidCatalogDigest)
        let root = stagingRoot()
        let staged = try await CuratedSkillHub.stage(
            publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: root, fetch: fetch)
        #expect(staged.receipt.packagePath == "android/packages/fixture-reviewed/1.0.0/fixture-reviewed.zip")
        #expect(staged.receipt.reviewPath == "reviews/fixture-reviewed/1.0.0.review.json")
        let snapshot = await transport.snapshot()
        #expect(Set(snapshot.fetches.map { $0.commit }) == Set([y]))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Missing catalog, missing signature and unknown entries fail closed (never a fake empty feed)")
    func unavailablePublications() async throws {
        let y = String(repeating: "e", count: 40)
        let empty = HubTransport(files: [:], commits: [y])
        let (emptyResolve, emptyFetch) = makeClosures(empty)
        try await expectCuratedFailureAsync(
            { _ = try await CuratedSkillHub.loadPublication(
                channel: .ios, mode: fixtureMode(), ref: "main", resolve: emptyResolve, fetch: emptyFetch) },
            case: "unavailable")
        // Catalog present, signature absent at Y.
        var partial = try iosFixtureFiles()
        partial.removeValue(forKey: "catalog.sig")
        let partialTransport = HubTransport(files: partial, commits: [y])
        let (partialResolve, partialFetch) = makeClosures(partialTransport)
        try await expectCuratedFailureAsync(
            { _ = try await CuratedSkillHub.loadPublication(
                channel: .ios, mode: fixtureMode(), ref: "main", resolve: partialResolve, fetch: partialFetch) },
            case: "unavailable")
        // Loading works, but staging an id that the pinned publication does
        // not carry fails closed without touching the filesystem.
        let transport = HubTransport(files: try iosFixtureFiles(), commits: [y])
        let (resolve, fetch) = makeClosures(transport)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
        let root = stagingRoot()
        try await expectCuratedFailureAsync(
            { _ = try await CuratedSkillHub.stage(publication, entryID: "not-in-feed", appVersion: "1.7.58", at: root, fetch: fetch) },
            case: "offer")
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: Offer wall and counts

    @Test("Unqualified candidates show Unavailable and never stage; counts stay honest")
    func unqualifiedWall() async throws {
        let transport = HubTransport(
            files: try iosFixtureFiles(),
            commits: [String(repeating: "f", count: 40)])
        let (resolve, fetch) = makeClosures(transport)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
        let feed = publication.feed
        let cards = CuratedSkillHub.cards(feed: feed, mode: publication.mode, appVersion: "1.7.58")
        #expect(cards.count == 3)
        #expect(CuratedSkillHub.installableOfferCount(feed: feed, mode: publication.mode, appVersion: "1.7.58") == 1)
        #expect(cards.first { $0.entry.id == "fixture-guide" }?.offer
                == .unavailable(reason: "no install offer for this candidate"))
        #expect(cards.first { $0.entry.id == "fixture-script" }?.showsInstallAction == false)
        let root = stagingRoot()
        try await expectCuratedFailureAsync(
            { _ = try await CuratedSkillHub.stage(publication, entryID: "fixture-script", appVersion: "1.7.58", at: root, fetch: fetch) },
            case: "offer")
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // Simulated offers are contract-test-only: under production trust the
        // same entry is Unavailable, proving the offer gate, not just decode.
        let reviewed = try #require(feed.entry(id: "fixture-reviewed"))
        #expect(CuratedSkillHub.offerState(for: reviewed, mode: .production, appVersion: "1.7.58")
                == .unavailable(reason: "fixture-simulated offers are contract-test only"))
        // App compatibility applies to live offers.
        #expect(CuratedSkillHub.offerState(for: reviewed, mode: publication.mode, appVersion: "1.0.0")
                == .incompatibleApp(minimumAppVersion: "1.7.0"))
        let oldRoot = stagingRoot()
        try await expectCuratedFailureAsync(
            { _ = try await CuratedSkillHub.stage(publication, entryID: "fixture-reviewed", appVersion: "1.0.0", at: oldRoot, fetch: fetch) },
            case: "compatibility")
        // Localized search model.
        let english = CuratedSkillHub.searchCards(
            feed: feed, mode: publication.mode, appVersion: "1.7.58", query: "guide", preferredLanguages: ["en"])
        #expect(english.map { $0.entry.id } == ["fixture-guide"])
        let zh = CuratedSkillHub.searchCards(
            feed: feed, mode: publication.mode, appVersion: "1.7.58", query: "契约夹具", preferredLanguages: ["zh-Hans-CN"])
        #expect(Set(zh.map { $0.entry.id }) == Set(feed.entries.map { $0.id }))
        #expect(reviewed.name.value(preferredLanguages: ["zh-Hans"]) == "契约夹具 fixture-reviewed")
    }

    // MARK: Exact-bytes join failures (re-signed fixture mutations)

    @Test("Tampered archive bytes are refused and the staging root never persists")
    func tamperedArchive() async throws {
        let y = String(repeating: "1", count: 40)
        var files = try iosFixtureFiles()
        var zip = try #require(files["packages/fixture-reviewed/1.0.0/fixture-reviewed.zip"])
        zip[zip.count - 1] ^= 0x02
        files["packages/fixture-reviewed/1.0.0/fixture-reviewed.zip"] = zip
        let transport = HubTransport(files: files, commits: [y])
        let (resolve, fetch) = makeClosures(transport)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
        let root = stagingRoot()
        try await expectCuratedFailureAsync(
            { _ = try await CuratedSkillHub.stage(publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: root, fetch: fetch) },
            case: "archive")
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Signed contentDigest drift over a correctly-hashed archive fails the digest join")
    func contentDigestDrift() async throws {
        let catalog = try mutate(
            curatedFixture("catalog.json"),
            "\"contentDigest\":\"e600ad152d76490da4f9c7c9cc5ad884dd484e139c3dd318b13d3b6363bea62e\"",
            to: "\"contentDigest\":\"\(String(repeating: "0", count: 63))1\"")
        let transport = HubTransport(
            files: [
                "catalog.json": catalog,
                "catalog.sig": try signedEnvelope(over: catalog),
                "packages/fixture-reviewed/1.0.0/fixture-reviewed.zip": try curatedFixture("packages/fixture-reviewed/1.0.0/fixture-reviewed.zip"),
                "reviews/fixture-reviewed/1.0.0.review.json": try curatedFixture("reviews/fixture-reviewed/1.0.0.review.json"),
                "reviews/fixture-reviewed/1.0.0.review.json.sig": try curatedFixture("reviews/fixture-reviewed/1.0.0.review.json.sig"),
            ],
            commits: [String(repeating: "2", count: 40)])
        let (resolve, fetch) = makeClosures(transport)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
        let root = stagingRoot()
        try await expectCuratedFailureAsync(
            { _ = try await CuratedSkillHub.stage(publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: root, fetch: fetch) },
            case: "digest")
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Signed package sha256 drift fails before extraction; review-stage evidence drift fails decode")
    func archiveShaDriftAndStageEvidenceDrift() async throws {
        let catalog = try mutate(
            curatedFixture("catalog.json"),
            "\"sha256\":\"111e5492a0a14895431bd869fc29ed1195625d7a73fbf7f01a38cfe8c73bab26\"",
            to: "\"sha256\":\"\(String(repeating: "9", count: 63))0\"")
        let transport = HubTransport(
            files: [
                "catalog.json": catalog,
                "catalog.sig": try signedEnvelope(over: catalog),
                "packages/fixture-reviewed/1.0.0/fixture-reviewed.zip": try curatedFixture("packages/fixture-reviewed/1.0.0/fixture-reviewed.zip"),
            ],
            commits: [String(repeating: "3", count: 40)])
        let (resolve, fetch) = makeClosures(transport)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
        let root = stagingRoot()
        try await expectCuratedFailureAsync(
            { _ = try await CuratedSkillHub.stage(publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: root, fetch: fetch) },
            case: "archive")

        // A guest-execution-qualified stage over unproven evidence cannot
        // even decode the record honestly.
        let review = try mutate(
            curatedFixture("reviews/fixture-reviewed/1.0.0.review.json"),
            "\"reviewStage\":\"static-content-reviewed\"",
            to: "\"reviewStage\":\"guest-execution-qualified\"")
        #expect(throws: (any Error).self) { _ = try CuratedSkillReviewRecord.decode(bytes: review) }
    }

    @Test("Re-signed review records that do not cover the actual manifest fail the join")
    func reviewJoinMutations() async throws {
        let originalRecord = try curatedFixture("reviews/fixture-reviewed/1.0.0.review.json")
        let mutations: [(String, String, String)] = [
            ("\"reviewedTools\":[\"exec.shell\"]",
             "\"reviewedTools\":[\"exec.localPython\",\"exec.shell\"]",
             "tools"),
            ("\"reviewedCapabilities\":[\"execution.remote\",\"workspace.read\",\"workspace.write\"]",
             "\"reviewedCapabilities\":[\"workspace.read\"]",
             "capabilities"),
            ("\"reviewedPythonPackages\":[]",
             "\"reviewedPythonPackages\":[{\"capabilities\":[\"network.download\"],\"purpose\":\"fixture drift\",\"spec\":\"requests==2.31.0\"}]",
             "dependencies"),
            ("\"decision\":\"approve\"", "\"decision\":\"reject\"", "approve"),
        ]
        for (pattern, replacement, fragment) in mutations {
            let record = try mutate(originalRecord, pattern, to: replacement)
            let catalog = try mutate(
                curatedFixture("catalog.json"),
                "\"sha256\":\"d5cedd23ef0a8ecd9eaba754197793ce4e69b692ddd8cb9237bf28518524f14b\"",
                to: "\"sha256\":\"\(sha256Hex(record))\"")
            let transport = HubTransport(
                files: [
                    "catalog.json": catalog,
                    "catalog.sig": try signedEnvelope(over: catalog),
                    "packages/fixture-reviewed/1.0.0/fixture-reviewed.zip": try curatedFixture("packages/fixture-reviewed/1.0.0/fixture-reviewed.zip"),
                    "reviews/fixture-reviewed/1.0.0.review.json": record,
                    "reviews/fixture-reviewed/1.0.0.review.json.sig": try signedEnvelope(over: record),
                ],
                commits: [String(repeating: "4", count: 40)])
            let (resolve, fetch) = makeClosures(transport)
            let publication = try await CuratedSkillHub.loadPublication(
                channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
            let root = stagingRoot()
            try await expectCuratedFailureAsync(
                { _ = try await CuratedSkillHub.stage(publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: root, fetch: fetch) },
                case: "review", containing: fragment)
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
        // A stale-but-valid signature over OLD record bytes after a content
        // change: the mutated record without an updated catalog binding digest
        // fails the exact-bytes sha join before any trust in the record.
        let record = try mutate(originalRecord, "\"decision\":\"approve\"", to: "\"decision\":\"reject\"")
        let transport = HubTransport(
            files: [
                "catalog.json": try curatedFixture("catalog.json"),
                "catalog.sig": try curatedFixture("catalog.sig"),
                "packages/fixture-reviewed/1.0.0/fixture-reviewed.zip": try curatedFixture("packages/fixture-reviewed/1.0.0/fixture-reviewed.zip"),
                "reviews/fixture-reviewed/1.0.0.review.json": record,
                "reviews/fixture-reviewed/1.0.0.review.json.sig": try signedEnvelope(over: record),
            ],
            commits: [String(repeating: "5", count: 40)])
        let (resolve, fetch) = makeClosures(transport)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
        let root = stagingRoot()
        try await expectCuratedFailureAsync(
            { _ = try await CuratedSkillHub.stage(publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: root, fetch: fetch) },
            case: "digest")
    }

    @Test("Registry-plan drift in the entry runtime block is refused against the actual manifest")
    func entryRuntimePlanDrift() async throws {
        // Entry adds a capability the real manifest does not declare.
        let capabilitiesCatalog = try mutate(
            curatedFixture("catalog.json"),
            "\"capabilities\":[\"execution.remote\",\"workspace.read\",\"workspace.write\"]",
            to: "\"capabilities\":[\"execution.remote\",\"network\",\"workspace.read\",\"workspace.write\"]")
        let dependencyCatalog = try mutate(
            curatedFixture("catalog.json"),
            "\"pythonPackagesPlan\":[]",
            to: "\"pythonPackagesPlan\":[\"numpy==1.26.4\"]", replaceAll: true)
        for (mutated, fragment) in [
            (capabilitiesCatalog, "capabilities drift"),
            (dependencyCatalog, "pythonPackagesPlan drift"),
        ] {
            let transport = HubTransport(
                files: [
                    "catalog.json": mutated,
                    "catalog.sig": try signedEnvelope(over: mutated),
                    "packages/fixture-reviewed/1.0.0/fixture-reviewed.zip": try curatedFixture("packages/fixture-reviewed/1.0.0/fixture-reviewed.zip"),
                    "reviews/fixture-reviewed/1.0.0.review.json": try curatedFixture("reviews/fixture-reviewed/1.0.0.review.json"),
                    "reviews/fixture-reviewed/1.0.0.review.json.sig": try curatedFixture("reviews/fixture-reviewed/1.0.0.review.json.sig"),
                ],
                commits: [String(repeating: "6", count: 40)])
            let (resolve, fetch) = makeClosures(transport)
            let publication = try await CuratedSkillHub.loadPublication(
                channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
            let root = stagingRoot()
            try await expectCuratedFailureAsync(
                { _ = try await CuratedSkillHub.stage(publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: root, fetch: fetch) },
                case: "review", containing: fragment)
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Archive safety bounds through the shared gates

    @Test("Path-unsafe and native-payload archives never materialize files")
    func unsafeArchives() async throws {
        func archive(_ files: [(name: String, bytes: Data)]) throws -> Data {
            let built = try Archive(data: Data(), accessMode: .create)
            for file in files {
                try built.addEntry(with: file.name, type: .file, uncompressedSize: Int64(file.bytes.count)) { position, size in
                    file.bytes.subdata(in: Int(position)..<min(Int(position) + size, file.bytes.count))
                }
            }
            return try #require(built.data)
        }
        let skillBytes = Data("---\nname: fixture-reviewed\ndescription: fixture\n---\n\nBody.\n".utf8)
        let manifestBytes = Data(#"{"capabilities":[],"id":"fixture-reviewed","platforms":["ios"],"pythonPackages":[],"schemaVersion":1,"scriptRuntime":"none","tools":[],"version":"1.0.0"}"#.utf8)
        let cases: [[(String, Data)]] = [
            [("../escape", Data("x".utf8)), ("SKILL.md", skillBytes), ("floe.json", manifestBytes)],
            [("SKILL.md", skillBytes), ("skill.md", skillBytes), ("floe.json", manifestBytes)],
            [("SKILL.md", skillBytes), ("floe.json", Data([0x7F, 0x45, 0x4C, 0x46] + Array("ELF".utf8))), ],
            [("SKILL.md", Data([0xCF, 0xFA, 0xED, 0xFE])), ("floe.json", manifestBytes)],
        ]
        for entries in cases {
            let bytes = try archive(entries)
            var catalog = try mutate(
                curatedFixture("catalog.json"),
                "\"size\":999", to: "\"size\":\(bytes.count)")
            catalog = try mutate(
                catalog,
                "\"sha256\":\"111e5492a0a14895431bd869fc29ed1195625d7a73fbf7f01a38cfe8c73bab26\"",
                to: "\"sha256\":\"\(sha256Hex(bytes))\"")
            let transport = HubTransport(
                files: [
                    "catalog.json": catalog,
                    "catalog.sig": try signedEnvelope(over: catalog),
                    "packages/fixture-reviewed/1.0.0/fixture-reviewed.zip": bytes,
                ],
                commits: [String(repeating: "7", count: 40)])
            let (resolve, fetch) = makeClosures(transport)
            let publication = try await CuratedSkillHub.loadPublication(
                channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
            let root = stagingRoot()
            try await expectCuratedFailureAsync(
                { _ = try await CuratedSkillHub.stage(publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: root, fetch: fetch) },
                case: "archive")
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }

    // MARK: Permission delta (module-actual facts only)

    @Test("Delta comes from the actual manifest and only covered rights proceed without repetition")
    func permissionDeltaFlow() async throws {
        let transport = HubTransport(
            files: try iosFixtureFiles(),
            commits: [String(repeating: "8", count: 40)])
        let (resolve, fetch) = makeClosures(transport)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .ios, mode: fixtureMode(), ref: "main", resolve: resolve, fetch: fetch)
        let root = stagingRoot()
        let staged = try await CuratedSkillHub.stage(
            publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: root, fetch: fetch)
        let delta = staged.permissionDelta
        #expect(delta.requiredCapabilities == ["execution.remote", "workspace.read", "workspace.write"])
        #expect(delta.requiredTools == ["exec.shell"])
        #expect(delta.requiredPythonPackageSpecs.isEmpty)
        #expect(delta.missingCapabilities == delta.requiredCapabilities)
        #expect(delta.isCoveredByEffectiveGrants == false)
        #expect(delta.requiresCombinedApproval == true)
        #expect(delta.mayProceedWithoutRedundantConfirmation(under: .contract) == false)
        try? FileManager.default.removeItem(at: root)

        let coveredRoot = stagingRoot()
        let covered = try await CuratedSkillHub.stage(
            publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: coveredRoot,
            effectiveCapabilities: ["execution.remote", "workspace.read", "workspace.write", "network"],
            effectiveTools: ["exec.shell", "workspace.readFile"],
            effectivePythonPackageSpecs: ["unused==0.1"],
            fetch: fetch)
        #expect(covered.permissionDelta.isCoveredByEffectiveGrants)
        #expect(covered.permissionDelta.mayProceedWithoutRedundantConfirmation(under: .contract))
        try? FileManager.default.removeItem(at: coveredRoot)

        let partialRoot = stagingRoot()
        let partial = try await CuratedSkillHub.stage(
            publication, entryID: "fixture-reviewed", appVersion: "1.7.58", at: partialRoot,
            effectiveCapabilities: ["workspace.read"], effectiveTools: [],
            effectivePythonPackageSpecs: [], fetch: fetch)
        #expect(partial.permissionDelta.missingCapabilities == ["execution.remote", "workspace.write"])
        #expect(partial.permissionDelta.missingTools == ["exec.shell"])
        #expect(partial.permissionDelta.mayProceedWithoutRedundantConfirmation(under: .contract) == false)
        // Drifted policy (anything other than the byte-exact §4 constants)
        // can never enable the auto-proceed path.
        let strict = CuratedSkillPermissionPolicy(
            automaticInstallWhenReviewedAndGranted: true, deltaOnlyApproval: false,
            selfApprovalProhibited: true, userDisabledAndRemovedPriority: "user",
            temporaryTaskCeiling: "client-enforced")
        #expect(partial.permissionDelta.mayProceedWithoutRedundantConfirmation(under: strict) == false)
        try? FileManager.default.removeItem(at: partialRoot)
    }

    // MARK: Identity guards

    @Test("Model-declared sources and refs cannot repoint a curated operation")
    func sourceIdentity() async throws {
        let curated = try CuratedSkillHub.source(channel: .android)
        try CuratedSkillHub.validateSource(curated, for: .android)
        #expect(curated.owner == "JiangNanGenius" && curated.repository == "floe-skill-hub")
        #expect(curated.path == "android/catalog.json")
        let legacy = try GitHubSkillSource(owner: "JiangNanGenius", repository: "floe-agent", ref: "main", path: "skill-hub/catalog.json")
        #expect(throws: CuratedSkillHubFailure.self) {
            try CuratedSkillHub.validateSource(legacy, for: .ios)
        }
        let attacker = try GitHubSkillSource(owner: "attacker", repository: "floe-skill-hub", ref: "main", path: "catalog.json")
        #expect(throws: CuratedSkillHubFailure.self) {
            try CuratedSkillHub.validateSource(attacker, for: .ios)
        }
        // A package-style path is not a channel catalog path.
        let wrongPath = try GitHubSkillSource(owner: "JiangNanGenius", repository: "floe-skill-hub", ref: "main", path: "packages/x/1.0.0/x.zip")
        #expect(throws: CuratedSkillHubFailure.self) {
            try CuratedSkillHub.validateSource(wrongPath, for: .ios)
        }
        // Non-40-hex pins from a hostile resolver fail closed.
        let transport = HubTransport(files: try iosFixtureFiles(), commits: ["main-branch-head"])
        let (badResolve, badFetch) = makeClosures(transport)
        await #expect(throws: CuratedSkillHubFailure.self) {
            _ = try await CuratedSkillHub.loadPublication(
                channel: .ios, mode: fixtureMode(), ref: "main", resolve: badResolve, fetch: badFetch)
        }
    }
}

/// Minimal JSON value wrapper used only to inspect the fixture public key file.
private enum JSONValue: Decodable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case other

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self = .string(text) }
        else if let flag = try? container.decode(Bool.self) { self = .bool(flag) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else { self = .other }
    }

    var value: Any? {
        switch self {
        case .string(let text): return text
        case .bool(let flag): return flag
        case .number(let number): return number
        case .other: return nil
        }
    }
}
