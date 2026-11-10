// SPDX-License-Identifier: MPL-2.0
//
// Large-source-v1 package profile consumer contracts (Android shared
// mirror). Authored source-only tests; NOT executed by the preparing lane.
// Every fixture is synthetic and public-safe: the deterministic hubcore
// fixture key signs fixture bytes only, no network/device/App cloud/real
// signing key is touched, and no Taste upstream bytes appear here.
//
// Wire contract (authoritative: APP-CONSUMER-CONTRACT.json):
//   entry.package.profile missing            -> standard (128 files/8 MiB)
//   entry.package.profile "large-source-v1"  -> 2048 files/64 MiB, 2 MiB/file
//   entry.package.profile anything else      -> fail closed, no fallback
//   large entries only in the signed catalog-large-source-v1.json capability
//   projection (a SAME-Y full superset of the standard full feed); a failed
//   capability projection never supplies entries or budgets.
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
@testable import FloeSkills
import FloeCore

final class C02LargeSourceProfileTests: XCTestCase {

    // MARK: 1. Standard bounds preserved; explicit opt-in; unknown refused

    func testStandardProfileBoundsPreservedAndExplicitLargeAccepted() throws {
        // Old feeds carry no profile key at all: the binding must default to
        // the unchanged standard envelope.
        let standard = try Self.verifiedFixtureFeed(mutatePackage: { _ in })
        XCTAssertEqual(standard.feed.entry(id: "fixture-large")?.package?.profile, .standard)

        // 8 MiB + 1 is refused without a profile (the old assertion shape).
        XCTAssertThrowsError(try Self.verifiedFixtureFeed(mutatePackage: { package in
            package["size"] = 8_388_609
        })) { error in
            guard case CuratedSkillHubFailure.feed(let reason) = error else {
                return XCTFail("expected feed failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("signed profile"))
        }

        // The explicit opt-in accepts a 30 MiB signed archive.
        let opted = try Self.verifiedFixtureFeed(profile: "large-source-v1", archiveBlob: 30 * 1_024 * 1_024)
        let binding = try XCTUnwrap(opted.feed.entry(id: "fixture-large")?.package)
        XCTAssertEqual(binding.profile, .largeSourceV1)
        XCTAssertEqual(binding.size, 30 * 1_024 * 1_024)
        XCTAssertEqual(SkillPackageResourceProfile.largeSourceV1.maximumFiles, 2048)
        XCTAssertEqual(SkillPackageResourceProfile.largeSourceV1.maximumBytes, 67_108_864)
        XCTAssertEqual(SkillPackageResourceProfile.largeSourceV1.maximumFileBytes, 2_097_152)
        XCTAssertEqual(SkillPackageResourceProfile.standard.maximumFiles, 128)
        XCTAssertEqual(SkillPackageResourceProfile.standard.maximumBytes, 8_388_608)
    }

    func testUnknownProfileFailsClosedWithoutFallback() throws {
        // "standard-v1" is NOT the wire spelling; neither is any future name.
        for unknown in ["standard-v1", "unbounded-v1", "large-source-v2"] {
            XCTAssertThrowsError(
                try Self.verifiedFixtureFeed(profile: unknown, archiveBlob: 30 * 1_024 * 1_024),
                "profile \(unknown) must be rejected") { error in
                guard case CuratedSkillHubFailure.feed(let reason) = error else {
                    return XCTFail("expected feed failure for \(unknown), got \(error)")
                }
                XCTAssertTrue(reason.contains("profile is unsupported"))
            }
        }
        // Even with the large profile, the declared profile total is a hard
        // ceiling (64 MiB archive+uncompressed).
        XCTAssertThrowsError(try Self.verifiedFixtureFeed(
            profile: "large-source-v1", archiveBlob: 67_108_865))
    }

    // MARK: 2. Capability projection guards at loadPublication

    func testCapabilityProjectionGuards() async throws {
        // A large entry inside the standard full projection is refused even
        // when every signature verifies.
        let files = try Self.largeSourceFixtureFiles()
        var wrong = files
        wrong["android/catalog-full.json"] = files["android/catalog-large-source-v1.json"]
        wrong["android/catalog-full.sig"] = files["android/catalog-large-source-v1.sig"]
        let badTransport = SyntheticHubTransport(files: wrong)
        await XCTAssertThrowsCuratedFailure(.feed) {
            _ = try await CuratedSkillHub.loadPublication(
                channel: .android, mode: Self.fixtureMode(), layout: .full,
                resolve: { try await badTransport.resolve($0) }, fetch: { try badTransport.fetch($0, commit: $1, path: $2) })
        }

        // The capability projection must be a full superset of the standard
        // entry ids at the SAME immutable publication Y.
        let transport = SyntheticHubTransport(files: files)
        await XCTAssertThrowsCuratedFailure(.feed) {
            _ = try await CuratedSkillHub.loadPublication(
                channel: .android, mode: Self.fixtureMode(),
                layout: .largeSourceV1,
                requiredProjectionIDs: ["fixture-large", "missing-standard-entry"],
                resolve: { try await transport.resolve($0) }, fetch: { try transport.fetch($0, commit: $1, path: $2) })
        }

        // Same-Y pinning: the capability projection reuses the standard
        // publication commit instead of re-resolving the branch.
        let pinned = SyntheticHubTransport(files: files)
        let standard = try await CuratedSkillHub.loadPublication(
            channel: .android, mode: Self.fixtureMode(), layout: .full,
            resolve: { try await pinned.resolve($0) }, fetch: { try pinned.fetch($0, commit: $1, path: $2) })
        let commit = standard.publicationCommit
        let capability = try await CuratedSkillHub.loadPublication(
            channel: .android, mode: Self.fixtureMode(),
            layout: .largeSourceV1,
            requiredProjectionIDs: Set(standard.feed.entries.map(\.id)),
            resolve: { _ in commit }, fetch: { try pinned.fetch($0, commit: $1, path: $2) })
        XCTAssertEqual(capability.layout, .largeSourceV1)
        XCTAssertEqual(capability.publicationCommit, standard.publicationCommit)
        XCTAssertEqual(capability.feed.entry(id: "fixture-large")?.package?.profile, .largeSourceV1)
    }

    // MARK: 3. Stage requires the authenticated route; receipt persists profile

    func testLargeStageRequiresVerifiedRouteAndPersistsProfile() async throws {
        let files = try Self.largeSourceFixtureFiles()
        let transport = SyntheticHubTransport(files: files)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .android, mode: Self.fixtureMode(), layout: .largeSourceV1,
            resolve: { try await transport.resolve($0) }, fetch: { try transport.fetch($0, commit: $1, path: $2) })
        let root = Self.stagingRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A large-source entry refuses the generic fetch-only stage path.
        await XCTAssertThrowsCuratedFailure(.compatibility) {
            _ = try await CuratedSkillHub.stage(
                publication, entryID: "fixture-large", appVersion: "999.0.0",
                at: root, fetch: { try transport.fetch($0, commit: $1, path: $2) })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        // The authenticated route stages the exact bytes; the download token
        // binds owner/repository/immutable commit/path/declared size.
        let staged = try await CuratedSkillHub.stage(
            publication, entryID: "fixture-large", appVersion: "999.0.0",
            at: root, fetch: { try transport.fetch($0, commit: $1, path: $2) },
            fetchPackage: { source, commit, path, authorization in
                let bound = try authorization.maximumBytes(
                    owner: source.owner, repository: source.repository,
                    ref: commit, path: path)
                XCTAssertGreaterThan(bound, 8_388_608)
                XCTAssertLessThanOrEqual(bound, 67_108_864)
                XCTAssertThrowsError(try authorization.maximumBytes(
                    owner: "other", repository: source.repository, ref: commit, path: path))
                XCTAssertThrowsError(try authorization.maximumBytes(
                    owner: source.owner, repository: source.repository, ref: "main", path: path))
                XCTAssertThrowsError(try authorization.maximumBytes(
                    owner: source.owner, repository: source.repository, ref: commit,
                    path: "android/packages/other/1.0.0/other.zip"))
                return try await transport.fetch(source, commit: commit, path: path)
            })
        XCTAssertGreaterThan(staged.content.files.count, 300)
        XCTAssertGreaterThan(
            staged.content.files.values.reduce(0, { $0 + $1.count }), 8_388_608)
        XCTAssertEqual(staged.receipt.packageProfile, .largeSourceV1)
        XCTAssertEqual(staged.receipt.catalogLayout, .largeSourceV1)

        // Receipt coding keeps the profile for lifecycle restore; fixture
        // metadata never becomes production trust.
        let decoded = try JSONDecoder().decode(
            CuratedSkillHub.Receipt.self, from: JSONEncoder().encode(staged.receipt))
        XCTAssertEqual(decoded.packageProfile, .largeSourceV1)
        XCTAssertThrowsError(try decoded.resourceAuthorization()) { error in
            guard case CuratedSkillHubFailure.trust = error else {
                return XCTFail("expected production trust refusal, got \(error)")
            }
        }
        let authority = try XCTUnwrap(try decoded.resourceAuthorization(mode: Self.fixtureMode()))
        XCTAssertEqual(authority.profile, .largeSourceV1)

        // Old receipts without the profile key still decode as standard.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(staged.receipt)) as? [String: Any])
        object.removeValue(forKey: "packageProfile")
        object.removeValue(forKey: "catalogLayout")
        let legacy = try JSONDecoder().decode(
            CuratedSkillHub.Receipt.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.packageProfile)
        XCTAssertNil(legacy.catalogLayout)
        XCTAssertNil(try legacy.resourceAuthorization(mode: Self.fixtureMode()))
    }

    // MARK: 4. Install/reopen under the signed profile; profile never relaxes gates

    func testLargeProfileInstallReopenAndSafetyCaps() async throws {
        let files = try Self.largeSourceFixtureFiles()
        let transport = SyntheticHubTransport(files: files)
        let publication = try await CuratedSkillHub.loadPublication(
            channel: .android, mode: Self.fixtureMode(), layout: .largeSourceV1,
            resolve: { try await transport.resolve($0) }, fetch: { try transport.fetch($0, commit: $1, path: $2) })
        let base = Self.stagingRoot()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let staged = try await CuratedSkillHub.stage(
            publication, entryID: "fixture-large", appVersion: "999.0.0",
            at: base.appendingPathComponent("stage"), fetch: { try transport.fetch($0, commit: $1, path: $2) },
            fetchPackage: { source, commit, path, authorization in
                _ = try authorization.maximumBytes(
                    owner: source.owner, repository: source.repository, ref: commit, path: path)
                return try await transport.fetch(source, commit: commit, path: path)
            })
        let authority = try XCTUnwrap(
            try staged.receipt.resourceAuthorization(mode: Self.fixtureMode()))

        let installRoot = base.appendingPathComponent("installed")
        let provenance = SkillInstallProvenance(
            sourceURL: URL(string: "https://example.invalid/source.zip")!,
            originalSHA256: staged.content.package.canonicalSHA256,
            expectedRewrittenSHA256: staged.content.package.canonicalSHA256,
            rewriteModelID: "profile-fixture",
            compatibilitySummary: "synthetic large profile transaction")
        let record = try await SkillInstallStagingService(installationRoot: installRoot)
            .installRewrittenPackage(
                at: staged.content.package.rootURL,
                provenance: provenance,
                resourceAuthorization: authority)
        XCTAssertEqual(record.resourceProfile, .largeSourceV1)

        // The default standard validator still refuses the installed bytes;
        // only the signed profile authority revalidates them.
        XCTAssertThrowsError(try SkillContentSnapshot(
            root: record.canonicalPackageURL,
            expectedDigest: record.canonicalSHA256))
        let reopened = try SkillContentSnapshot(
            root: record.canonicalPackageURL,
            expectedDigest: record.canonicalSHA256,
            resourceAuthorization: authority)
        XCTAssertEqual(reopened.files, staged.content.files)

        // The profile widens only count/total bounds: per-file, traversal,
        // file-count and native-payload gates are unchanged.
        let limits = SkillPackageResourceProfile.largeSourceV1.archiveLimits
        XCTAssertEqual(limits.maximumEntries, 2048)
        XCTAssertEqual(limits.maximumTotalBytes, 67_108_864)
        XCTAssertEqual(limits.maximumFileBytes, 2_097_152)
        XCTAssertThrowsError(try SignedContentArchive.extract(
            try Self.zip(["assets/too-big.bin": Data(repeating: 65, count: 2_097_153)]),
            at: Self.stagingRoot(), limits: limits,
            allowedTopLevel: ["SKILL.md", "floe.json", "assets"]))
        XCTAssertThrowsError(try SignedContentArchive.extract(
            try Self.zip(["../escape": Data("x".utf8)]),
            at: Self.stagingRoot(), limits: limits,
            allowedTopLevel: ["SKILL.md", "floe.json", "assets"]))
        var many: [String: Data] = [:]
        for index in 0..<2049 { many["assets/\(index).txt"] = Data([65]) }
        XCTAssertThrowsError(try SignedContentArchive.extract(
            try Self.zip(many), at: Self.stagingRoot(), limits: limits,
            allowedTopLevel: ["SKILL.md", "floe.json", "assets"]))
    }

    // MARK: 5. Transport budget token facts + fail-closed default transport

    func testTransportBudgetTokenBindsEveryRetrievalFact() async throws {
        let publication = try Self.makePublication(
            commit: "c0123456789abcdef0123456789abcdef0123456")
        let binding = try XCTUnwrap(
            publication.feed.entry(id: "fixture-large")?.package)
        let token = CuratedSkillHub.PackageDownloadAuthorization(
            binding: binding, publicationCommit: publication.publicationCommit)
        XCTAssertEqual(try token.maximumBytes(
            owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository,
            ref: publication.publicationCommit, path: binding.path), binding.size)
        XCTAssertThrowsError(try token.maximumBytes(
            owner: "Other", repository: CuratedSkillHub.repository,
            ref: publication.publicationCommit, path: binding.path))
        XCTAssertThrowsError(try token.maximumBytes(
            owner: CuratedSkillHub.owner, repository: "other-repo",
            ref: publication.publicationCommit, path: binding.path))
        XCTAssertThrowsError(try token.maximumBytes(
            owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository,
            ref: "main", path: binding.path))
        XCTAssertThrowsError(try token.maximumBytes(
            owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository,
            ref: publication.publicationCommit, path: "android/packages/other/1.0.0/o.zip"))

        // The default protocol transport has no authenticated budget: an
        // authorized request fails closed instead of silently downgrading.
        let unavailable = SkillsRemoteTransportUnavailable()
        do {
            _ = try await unavailable.fetch(
                publication.source, commit: publication.publicationCommit,
                path: binding.path, verifiedPackage: token)
            XCTFail("The unimplemented transport must refuse the authorized fetch")
        } catch { }
        // nil authorization keeps the ordinary bounded fetch (which throws
        // unavailable here only because this adapter is the honest stub).
        do {
            _ = try await unavailable.fetch(
                publication.source, commit: publication.publicationCommit,
                path: binding.path, verifiedPackage: nil)
            XCTFail("The unimplemented transport must refuse the ordinary fetch")
        } catch { }
    }

    // MARK: 6. Taste floor: the 0.1.1 client compatibility constant

    func testTasteFloorUsesProjectedFeedMinimumWith011Client() throws {
        // The coordinator-owned author override projects the Android Taste
        // floor into the ordinary feed minimumAppVersion; the consumer uses
        // the existing offer gate, not a new mechanism. The gate's
        // `.installable` answer exists only for a qualified offer in a
        // production-status feed, so this decodes the production spelling of
        // the same synthetic catalog (the floor itself is the offer gate over
        // the decoded entry).
        let feed = try CuratedSkillFeed.decode(
            bytes: Self.productionCatalogBytes(mutateEntry: { entry in
                entry["minimumAppVersion"] = "0.1.1"
            }),
            expectedChannel: .android)
        let entry = try XCTUnwrap(feed.entry(id: "fixture-large"))
        XCTAssertEqual(C02AndroidSkillCompatibility.version, "0.1.1")
        XCTAssertEqual(CuratedSkillHub.offerState(
            for: entry, mode: .production,
            appVersion: C02AndroidSkillCompatibility.version), .installable)
        let oldClient = CuratedSkillHub.offerState(
            for: entry, mode: .production, appVersion: "0.1.0")
        guard case .incompatibleApp(let minimum) = oldClient else {
            return XCTFail("0.1.0 client must refuse the 0.1.1 floor, got \(oldClient)")
        }
        XCTAssertEqual(minimum, "0.1.1")
    }

    func testLargeRunPinReopensWithItsExactHistoricalAuthority() throws {
        let graph = try Self.largeSourceFixtureFiles(archiveBlob: 9_216_000)
        let zip = try XCTUnwrap(graph["android/packages/fixture-large/2.0.0/fixture-large.zip"])
        let base = Self.stagingRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let current = base.appendingPathComponent("current")
        let members = try SignedContentArchive.extract(zip, at: current,
            limits: SkillPackageResourceProfile.largeSourceV1.archiveLimits,
            allowedTopLevel: ["SKILL.md", "floe.json", "assets"])
        let digest = SignedContentArchive.canonicalDigest(members)
        let authority = SkillPackageResourceAuthorization(profile: .largeSourceV1,
            skillID: "fixture-large", version: "2.0.0", contentDigest: digest)
        let lookup: SkillRunSnapshotStore.ResourceAuthorizationLookup = { requested in
            requested == digest ? authority : nil
        }
        let root = base.appendingPathComponent("installed")
        // The store publishes under <installationRoot>/.run-snapshots without
        // creating intermediate directories, so the installation root itself
        // must already exist (it is the live install root in the iOS layout).
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pins = SkillRunSnapshotStore(installationRoot: root)
        let run = UUID()
        let first = try pins.pinnedSnapshot(currentInstallRoot: current,
            expectedDigest: digest, manifestOverride: nil, runID: run,
            skillID: "fixture-large", authorizationLookup: lookup)
        XCTAssertGreaterThan(first.files.count, 256)
        XCTAssertEqual(first.resourceAuthorization?.contentDigest, digest)

        // Recovery must use the old pin's recorded digest even when the
        // current installation has been upgraded or is unavailable.
        let changed = String(repeating: "b", count: 64)
        let absent = base.appendingPathComponent("new-install-not-readable")
        let reopened = try SkillRunSnapshotStore(installationRoot: root).pinnedSnapshot(
            currentInstallRoot: absent, expectedDigest: changed, manifestOverride: nil,
            runID: run, skillID: "fixture-large", authorizationLookup: lookup)
        XCTAssertEqual(reopened.package.canonicalSHA256, digest)
        XCTAssertEqual(reopened.files, first.files)

        // Neither a pin marker nor the new installation's authorization
        // mints capacity for this older digest. Failures retain the old pin.
        XCTAssertThrowsError(try pins.pinnedSnapshot(currentInstallRoot: current,
            expectedDigest: digest, manifestOverride: nil, runID: run, skillID: "fixture-large"))
        let other = SkillPackageResourceAuthorization(profile: .largeSourceV1,
            skillID: "fixture-large", version: "2.1.0", contentDigest: changed)
        XCTAssertThrowsError(try pins.pinnedSnapshot(currentInstallRoot: current,
            expectedDigest: digest, manifestOverride: nil, runID: run,
            skillID: "fixture-large", authorizationLookup: { _ in other }))
        XCTAssertThrowsError(try pins.pinnedSnapshot(currentInstallRoot: current,
            expectedDigest: digest, manifestOverride: nil, runID: UUID(), skillID: "fixture-large"))
        let retained = try pins.pinnedSnapshot(currentInstallRoot: absent,
            expectedDigest: changed, manifestOverride: nil, runID: run,
            skillID: "fixture-large", authorizationLookup: lookup)
        XCTAssertEqual(retained.package.canonicalSHA256, digest)
    }

    func testAppendedExternalSourceAndPlanRemainBounded() throws {
        let source: [String: Any] = [
            "repository": "https://github.com/example/fixture", "commit": String(repeating: "c", count: 40),
            "path": "skills/fixture-large", "skillManifestPath": "skills/fixture-large/SKILL.md",
            "retrievedAt": "2026-11-10", "repositoryLicense": "MIT", "licenseStatus": "verified",
            "licenseEvidencePath": "LICENSE", "licenseNote": ["en": "Fixture only", "zh-Hans": "仅为夹具"],
        ]
        let feed = try Self.verifiedFixtureFeed(profile: "large-source-v1", mutateEntry: { entry in
            entry["planNumber"] = 86; entry["source"] = "O"; entry["upstream"] = source
        })
        XCTAssertEqual(feed.feed.entry(id: "fixture-large")?.planNumber, 86)
        XCTAssertThrowsError(try Self.verifiedFixtureFeed(profile: "large-source-v1", mutateEntry: { entry in
            entry["source"] = "O"; entry["upstream"] = NSNull()
        }))
        XCTAssertThrowsError(try Self.verifiedFixtureFeed(profile: "large-source-v1", mutateEntry: { entry in
            entry["planNumber"] = CuratedSkillHub.maximumEntries + 1
        }))
    }

    // MARK: - Synthetic fixture graph (fixture trust only)

    /// Deterministic hubcore fixture identity — the same public-knowledge
    /// ephemeral seed the iOS consumer contracts use; never production.
    private static let fixtureSeed = Data(
        ("floe-skill-hub fixture-only ephemeral Ed25519 key 2026-10 "
         + "-- NOT a trust root -- NOT production material").utf8)

    static func fixtureMode() -> CuratedSkillTrustMode {
        let seed = SHA256.hash(data: fixtureSeed)
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))
        return .fixtureTestOnly(fixturePublicKey: key.publicKey.rawRepresentation)
    }

    private static func fixtureKey() throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(SHA256.hash(data: fixtureSeed)))
    }

    static func signedEnvelope(over payload: Data) throws -> Data {
        let signature = try fixtureKey().signature(for: payload)
        return Data(("{\"keyID\":\"\(CuratedSkillHub.fixtureKeyID)\","
                     + "\"signature\":\"\(Data(signature).base64EncodedString())\"}").utf8)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds the complete synthetic hub graph: a >300-file, >8 MiB package
    /// with no native payload, its signed review record, and the capability
    /// projection carrying the large-source-v1 profile binding.
    static func largeSourceFixtureFiles(
        archiveBlob: Int = 30 * 1_024 * 1_024
    ) throws -> [String: Data] {
        var payload: [String: Data] = [
            "SKILL.md": Data((
                "---\nname: fixture-large\ndescription: Synthetic large profile fixture\n"
                    + "---\nBody\n").utf8),
            "floe.json": try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "id": "fixture-large",
                "version": "2.0.0",
                "platforms": ["ios", "linux"],
                "capabilities": ["workspace.read"],
                "tools": [],
                "scriptRuntime": "none",
                "pythonPackages": [],
            ] as [String: Any], options: [.sortedKeys]),
        ]
        let blob = Data(repeating: 65, count: 30_720)
        for index in 0..<300 { payload["assets/large-\(index).txt"] = blob }
        // Pad the archive past the standard 8 MiB total with inert text when
        // the caller needs an oversized archive; small fixtures stay small.
        if archiveBlob > 9_216_000 {
            // Positive fixtures must still obey the unchanged 2 MiB/file cap.
            var remaining = archiveBlob - 9_216_000
            var index = 0
            while remaining > 0 {
                let count = min(1_048_576, remaining)
                payload["assets/pad-\(index).txt"] = Data(repeating: 66, count: count)
                remaining -= count; index += 1
            }
        }
        let zip = try Self.zip(payload)
        let digest = SignedContentArchive.canonicalDigest(payload)

        let review: [String: Any] = [
            "schemaVersion": 1,
            "id": "fixture-large",
            "version": "2.0.0",
            "contentDigest": digest,
            "packageSha256": sha256Hex(zip),
            "reviewedCapabilities": ["workspace.read"],
            "reviewedTools": [] as [String],
            "reviewedPythonPackages": [] as [String],
            "execution": ["os": NSNull(), "arch": "n/a", "evidence": "unproven"],
            "reviewStage": "static-content-reviewed",
            "reviewedAt": "2026-11-10",
            "reviewer": "fixture-synthetic-reviewer",
            "decision": "approve",
            "notes": ["en": "Synthetic large profile review.", "zh-Hans": "合成审核。"],
        ]
        let reviewBytes = try JSONSerialization.data(
            withJSONObject: review, options: [.sortedKeys])

        let status: [String: Any] = [
            "sourcePinned": true, "licenseChecked": true,
            "adaptation": "frozen", "packaged": true,
            "reviewed": true, "qualified": true,
            "published": true, "executionVerified": false,
        ]
        let entry: [String: Any] = [
            "id": "fixture-large",
            "planNumber": 1,
            "kind": "optional",
            "source": "F",
            "name": ["en": "Fixture Large", "zh-Hans": "大夹具"],
            "description": ["en": "Synthetic.", "zh-Hans": "合成。"],
            "category": "writing-communication",
            "tags": ["fixture", "testing"],
            "deepAdaptation": false,
            "upstream": NSNull(),
            "firstParty": NSNull(),
            "runtime": [
                "scriptRuntime": "none",
                "capabilities": ["workspace.read"],
                "tools": [] as [String],
                "installPlatforms": ["android"],
                "pythonPackagesPlan": [] as [String],
                "execution": ["os": NSNull(), "arch": "n/a", "evidence": "unproven"],
            ],
            "version": "2.0.0",
            "minimumAppVersion": "0.1.1",
            "status": status,
            "notes": ["en": "", "zh-Hans": ""],
            "package": [
                "path": "android/packages/fixture-large/2.0.0/fixture-large.zip",
                "size": zip.count,
                "sha256": sha256Hex(zip),
                "contentDigest": digest,
                "containsScripts": false,
                "profile": "large-source-v1",
            ],
            "review": [
                "path": "reviews/fixture-large/2.0.0.review.json",
                "sha256": sha256Hex(reviewBytes),
                "keyID": CuratedSkillHub.fixtureKeyID,
            ],
            // Fixture feeds refuse qualified offers at decode (they are
            // production-only); fixture-simulated is the fixture-feed offer
            // kind for an installable entry, still backed by the signed
            // package + review bindings above.
            "installOffer": "fixture-simulated",
        ]
        var standardEntry = entry
        standardEntry["id"] = "fixture-standard"
        standardEntry["planNumber"] = 1
        standardEntry["package"] = NSNull(); standardEntry["review"] = NSNull()
        standardEntry["installOffer"] = "none"
        standardEntry["status"] = [
            "sourcePinned": true, "licenseChecked": true, "adaptation": "planned",
            "packaged": false, "reviewed": false, "qualified": false,
            "published": false, "executionVerified": false,
        ] as [String: Any]
        var largeEntry = entry
        largeEntry["planNumber"] = 2
        func catalog(_ entries: [[String: Any]]) -> [String: Any] {
            let packaged = entries.filter { $0["package"] is [String: Any] }.count
            let qualifiedOffers = entries.filter { $0["installOffer"] as? String == "qualified" }.count
            return [
                "schemaVersion": 3, "publisher": CuratedSkillHub.publisher,
                "channel": "android", "feedStatus": "fixture",
                "hubRepository": CuratedSkillHub.hubRepository, "sourceCommit": NSNull(),
                "permissionPolicy": [
                    "automaticInstallWhenReviewedAndGranted": true, "deltaOnlyApproval": true,
                    "selfApprovalProhibited": true, "userDisabledAndRemovedPriority": "user",
                    "temporaryTaskCeiling": "client-enforced",
                ],
                "entries": entries,
                "counts": ["total": entries.count, "builtin": 0, "optional": entries.count,
                    "deepAdaptation": 0, "packaged": packaged, "reviewed": packaged,
                    "qualified": packaged, "offerQualified": qualifiedOffers],
            ]
        }
        let standardBytes = try JSONSerialization.data(
            withJSONObject: catalog([standardEntry]), options: [.sortedKeys])
        let capabilityBytes = try JSONSerialization.data(
            withJSONObject: catalog([standardEntry, largeEntry]), options: [.sortedKeys])
        return [
            "android/catalog-full.json": standardBytes,
            "android/catalog-full.sig": try signedEnvelope(over: standardBytes),
            "android/catalog-large-source-v1.json": capabilityBytes,
            "android/catalog-large-source-v1.sig": try signedEnvelope(over: capabilityBytes),
            "android/packages/fixture-large/2.0.0/fixture-large.zip": zip,
            "reviews/fixture-large/2.0.0.review.json": reviewBytes,
            "reviews/fixture-large/2.0.0.review.json.sig": try signedEnvelope(over: reviewBytes),
        ]
    }

    /// A feed whose single entry package is mutated before fixture signing.
    /// `profile: nil` removes the profile key entirely (the old-feed shape).
    static func verifiedFixtureFeed(
        profile: String? = nil,
        archiveBlob: Int = 1_024,
        mutatePackage: (inout [String: Any]) throws -> Void = { _ in },
        mutateEntry: (inout [String: Any]) throws -> Void = { _ in }
    ) throws -> CuratedSkillHub.VerifiedFeed {
        var files = try Self.largeSourceFixtureFiles(archiveBlob: archiveBlob)
        let key = "android/catalog-large-source-v1.json"
        var root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(files[key])) as? [String: Any])
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        let index = try XCTUnwrap(entries.firstIndex { $0["id"] as? String == "fixture-large" })
        var entry = entries[index]
        var package = try XCTUnwrap(entry["package"] as? [String: Any])
        if let profile { package["profile"] = profile } else { package.removeValue(forKey: "profile") }
        package["size"] = archiveBlob
        try mutatePackage(&package)
        entry["package"] = package
        try mutateEntry(&entry)
        entries[index] = entry
        root["entries"] = entries
        let bytes = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        files[key] = bytes
        return try CuratedSkillHub.verifiedFeed(
            bytes: bytes, signature: try signedEnvelope(over: bytes),
            channel: .android, mode: fixtureMode())
    }

    /// The production-feed spelling of the same synthetic graph. A qualified
    /// offer may only exist in a production-status feed (fixture feeds refuse
    /// it at decode), so the offer-gate tests that need `.installable` under
    /// `.production` trust decode THIS shape — the same schema-3 decode path
    /// the production consumer uses; signature verification is the separate
    /// `verifiedFeed` gate and is not what the offer gate tests exercise.
    static func productionCatalogBytes(
        mutateEntry: (inout [String: Any]) throws -> Void = { _ in }
    ) throws -> Data {
        let files = try Self.largeSourceFixtureFiles()
        let key = "android/catalog-large-source-v1.json"
        var root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(files[key])) as? [String: Any])
        root["feedStatus"] = "production"
        root["sourceCommit"] = "d0123456789abcdef0123456789abcdef0123456"
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        let index = try XCTUnwrap(entries.firstIndex { $0["id"] as? String == "fixture-large" })
        var entry = entries[index]
        entry["installOffer"] = "qualified"
        // This helper tests schema/offer gating only; no review signature or
        // install authority is minted. Production-status decode requires a
        // non-fixture review-key label, as in the existing Android Hub tests.
        var review = try XCTUnwrap(entry["review"] as? [String: Any])
        review["keyID"] = "synthetic-production-review-decode-only"
        entry["review"] = review
        try mutateEntry(&entry)
        entries[index] = entry
        root["entries"] = entries
        var counts = try XCTUnwrap(root["counts"] as? [String: Any])
        counts["offerQualified"] = entries
            .filter { $0["installOffer"] as? String == "qualified" }.count
        root["counts"] = counts
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Builds a Publication directly from the synthetic fixture graph for
    /// token-binding tests that do not need a transport. Throws instead of
    /// trapping so a malformed fixture reports an ordinary test failure and
    /// never aborts the whole host.
    static func makePublication(commit: String) throws -> CuratedSkillHub.Publication {
        let files = try Self.largeSourceFixtureFiles()
        let catalogBytes = try XCTUnwrap(files["android/catalog-large-source-v1.json"])
        let verified = try CuratedSkillHub.verifiedFeed(
            bytes: catalogBytes,
            signature: try signedEnvelope(over: catalogBytes),
            channel: .android, mode: fixtureMode())
        let source = try GitHubSkillSource(
            owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository,
            ref: "main", path: "android/catalog-large-source-v1.json")
        return CuratedSkillHub.Publication(
            source: source, publicationCommit: commit,
            verifiedFeed: verified, mode: Self.fixtureMode(), layout: .largeSourceV1)
    }

    static func stagingRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - Minimal stored ZIP writer (no dependency change)

    static func zip(_ files: [String: Data]) throws -> Data {
        var out = Data()
        var central = Data()
        var offsets: [String: UInt32] = [:]
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            offsets[name] = UInt32(out.count)
            let nameBytes = Array(name.utf8)
            let crc = crc32(data)
            func le16(_ v: UInt16) { out.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
            func le32(_ v: UInt32) { out.append(contentsOf: [
                UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]) }
            le32(0x04034b50); le16(20); le16(0); le16(0); le16(0); le16(0)
            le32(crc); le32(UInt32(data.count)); le32(UInt32(data.count))
            le16(UInt16(nameBytes.count)); le16(0)
            out.append(contentsOf: nameBytes)
            out.append(data)
        }
        let centralStart = UInt32(out.count)
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            let nameBytes = Array(name.utf8)
            let crc = crc32(data)
            func le16(_ v: UInt16) { central.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
            func le32(_ v: UInt32) { central.append(contentsOf: [
                UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]) }
            le32(0x02014b50); le16(20); le16(20); le16(0); le16(0); le16(0); le16(0)
            le32(crc); le32(UInt32(data.count)); le32(UInt32(data.count))
            le16(UInt16(nameBytes.count)); le16(0); le16(0); le16(0); le16(0); le32(0)
            le32(try XCTUnwrap(offsets[name]))
            central.append(contentsOf: nameBytes)
        }
        out.append(central)
        func cle16(_ v: UInt16) { out.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
        func cle32(_ v: UInt32) { out.append(contentsOf: [
            UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]) }
        cle32(0x06054b50); cle16(0); cle16(0)
        cle16(UInt16(files.count)); cle16(UInt16(files.count))
        cle32(UInt32(central.count)); cle32(centralStart); cle16(0)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table: [UInt32] = []
        for byte in 0..<256 {
            var crc = UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
            table.append(crc)
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[(Int(crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - Assertions

    private func XCTAssertThrowsCuratedFailure(
        _ expected: CuratedSkillHubFailure.Cases,
        _ block: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await block()
            XCTFail("expected \(expected), got success", file: file, line: line)
        } catch let failure as CuratedSkillHubFailure {
            switch (expected, failure) {
            case (.feed, .feed), (.compatibility, .compatibility):
                break
            default:
                XCTFail("expected \(expected), got \(failure)", file: file, line: line)
            }
        } catch {
            XCTFail("expected CuratedSkillHubFailure.\(expected), got \(error)",
                    file: file, line: line)
        }
    }
}

private extension CuratedSkillHubFailure {
    enum Cases { case feed, compatibility }
}

/// In-memory resolve/fetch transport over the synthetic fixture graph.
private actor SyntheticHubTransport {
    private let files: [String: Data]
    private var resolved = false

    init(files: [String: Data]) { self.files = files }

    func resolve(_ source: GitHubSkillSource) throws -> String {
        guard !resolved else { return "b0123456789abcdef0123456789abcdef0123456" }
        resolved = true
        return "b0123456789abcdef0123456789abcdef0123456"
    }

    nonisolated func fetch(_ source: GitHubSkillSource, commit: String, path: String) throws -> Data {
        guard let data = files[path] else {
            throw SyntheticHubTransportError(path: path)
        }
        return data
    }
}

private struct SyntheticHubTransportError: Error {
    let path: String
}
