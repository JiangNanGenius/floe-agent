// SPDX-License-Identifier: MPL-2.0
//
// C02 Android Hub client qualification tests (authored, NOT executed by this
// source-only lane). Fixtures are synthetic and public-safe; no network,
// device, App cloud or real signing key is touched.
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeSkills

final class C02AndroidHubClientTests: XCTestCase {

    // MARK: - Android host / Linux runtime split

    func testAndroidHostPlatformDoesNotWidenIOSOnlyPackages() {
        let iosOnly = makePackage(platforms: [.iOS], runtime: .none)
        let report = SkillCompatibility.evaluate(
            iosOnly,
            in: SkillRuntimeEnvironment(
                platform: .android,
                supportedCapabilities: [.workspaceRead],
                registeredTools: [],
                supportsJavaScriptCore: false,
                hasRemoteExecutionHost: false,
                hasQualifiedTaskLinuxRuntime: true))
        XCTAssertFalse(report.isRunnable)
        XCTAssertTrue(report.problems.contains(.unsupportedPlatform(.android)))

        let portable = makePackage(platforms: [.iOS, .linux], runtime: .none)
        let portableReport = SkillCompatibility.evaluate(
            portable,
            in: SkillRuntimeEnvironment(
                platform: .android,
                supportedCapabilities: [.workspaceRead],
                registeredTools: [],
                supportsJavaScriptCore: false,
                hasRemoteExecutionHost: false,
                hasQualifiedTaskLinuxRuntime: false))
        XCTAssertTrue(portableReport.isRunnable)
        XCTAssertTrue(portableReport.runtimeProblems.isEmpty)
    }

    func testScriptPackageRequiresActualSelectedTaskLinuxRuntime() {
        let scripted = makePackage(platforms: [.linux], runtime: .remote, tools: ["exec.shell"])
        let notSelected = SkillCompatibility.evaluate(
            scripted,
            in: SkillRuntimeEnvironment(
                platform: .android,
                supportedCapabilities: [.workspaceRead, .remoteExecution],
                registeredTools: ["exec.shell"],
                supportsJavaScriptCore: false,
                hasRemoteExecutionHost: false,
                hasQualifiedTaskLinuxRuntime: false))
        XCTAssertTrue(notSelected.isRunnable)
        XCTAssertFalse(notSelected.isRuntimeReady)
        XCTAssertTrue(notSelected.runtimeProblems.contains(.linuxRuntimeUnavailable))

        let selected = SkillCompatibility.evaluate(
            scripted,
            in: SkillRuntimeEnvironment(
                platform: .android,
                supportedCapabilities: [.workspaceRead, .remoteExecution],
                registeredTools: ["exec.shell"],
                supportsJavaScriptCore: false,
                hasRemoteExecutionHost: false,
                hasQualifiedTaskLinuxRuntime: true))
        XCTAssertTrue(selected.isRunnable)
        XCTAssertTrue(selected.isRuntimeReady)
    }

    func testAndroidCompatibilityVersionIsIndependentOfPrerelease() {
        XCTAssertEqual(C02AndroidSkillCompatibility.version, "0.1.0")
        XCTAssertNotEqual(C02AndroidSkillCompatibility.version, "0.1.0-alpha.22")
        XCTAssertEqual(C02AndroidSkillCompatibility.platform, .android)
    }

    // MARK: - schemaVersion-3 consumer and production offer compatibility

    func testProductionFeedDecodeAndMinimumAppVersionGate() throws {
        let bytes = try makeFeedBytes(production: true, minimumAppVersion: "1.7.59")
        let feed = try CuratedSkillFeed.decode(bytes: bytes, expectedChannel: .android)
        XCTAssertEqual(feed.schemaVersion, 3)
        XCTAssertEqual(feed.channel, .android)
        XCTAssertEqual(feed.entries.count, 1)
        let entry = try XCTUnwrap(feed.entries.first)
        XCTAssertEqual(entry.id, "demo")

        let tooOld = CuratedSkillHub.offerState(
            for: entry, mode: .production, appVersion: "0.1.0")
        XCTAssertEqual(tooOld, .incompatibleApp(minimumAppVersion: "1.7.59"))

        let capable = CuratedSkillHub.offerState(
            for: entry, mode: .production, appVersion: "1.7.60")
        XCTAssertEqual(capable, .installable)
    }

    func testLegacyDecoderStaysSeparateFromSchema3() throws {
        let bytes = try makeFeedBytes(production: true, minimumAppVersion: "0.0.0")
        // The legacy four-item decoder is a different shape and must not
        // silently accept the full channel.
        XCTAssertThrowsError(try JSONDecoder().decode(OfficialSkillHub.Catalog.self,
                                                      from: bytes))
        // The curated client is the only schemaVersion-3 consumer.
        let feed = try CuratedSkillFeed.decode(bytes: bytes, expectedChannel: .android)
        XCTAssertEqual(feed.schemaVersion, 3)
    }

    func testFixtureSignedFeedVerifiesOnlyUnderFixtureTrust() throws {
        let key = Curve25519.Signing.PrivateKey()
        let bytes = try makeFeedBytes(production: false, minimumAppVersion: nil)
        let signature = try key.signature(for: bytes)
        let envelope = try JSONSerialization.data(withJSONObject: [
            "keyID": CuratedSkillHub.fixtureKeyID,
            "signature": signature.base64EncodedString(),
        ], options: [.sortedKeys])
        let verified = try CuratedSkillHub.verifiedFeed(
            bytes: bytes, signature: envelope, channel: .android,
            mode: .fixtureTestOnly(fixturePublicKey: key.publicKey.rawRepresentation))
        XCTAssertEqual(verified.feed.feedStatus, .fixture)
        XCTAssertEqual(verified.keyID, CuratedSkillHub.fixtureKeyID)

        let productionBytes = try makeFeedBytes(production: true, minimumAppVersion: "0.0.0")
        XCTAssertThrowsError(try CuratedSkillHub.verifiedFeed(
            bytes: productionBytes,
            signature: envelope,
            channel: .android,
            mode: .fixtureTestOnly(fixturePublicKey: key.publicKey.rawRepresentation)))
    }

    // MARK: - Receipt sidecar (no DB migration)

    func testCuratedSidecarStoresEnvelopesAndDoesNotTrustMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c02-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = C02CuratedReceiptStore(installationRoot: root)

        // A real, digest-verifiable package so the negative verification test
        // fails on the missing/invalid signature rather than a missing tree.
        let packageRoot = root.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: synthetic\n---\n\nBody\n".utf8)
            .write(to: packageRoot.appendingPathComponent("SKILL.md"))
        try Data(#"{"capabilities":[],"id":"demo","platforms":["android","linux"],"pythonPackages":[],"schemaVersion":1,"scriptRuntime":"none","tools":[],"version":"1.0.0"}"#.utf8)
            .write(to: packageRoot.appendingPathComponent("floe.json"))
        let package = try SkillPackageValidator().validate(packageAt: packageRoot)
        let oldDigest = package.canonicalSHA256
        let newDigest = String(repeating: "b", count: 64)

        let oldEnvelope = makeEnvelope(publicationCommit: String(repeating: "5", count: 40))
        let newEnvelope = makeEnvelope(publicationCommit: String(repeating: "6", count: 40))

        XCTAssertTrue(try store.persist(oldEnvelope, skillID: "demo",
                                        contentDigest: oldDigest))
        XCTAssertTrue(store.hasCurrent(skillID: "demo"))
        XCTAssertEqual(store.currentEnvelope(skillID: "demo")?.publicationCommit,
                       String(repeating: "5", count: 40))
        XCTAssertEqual(store.envelope(skillID: "demo",
                                      contentDigest: oldDigest)?.publicationCommit,
                       String(repeating: "5", count: 40))

        // Signed-envelope bytes are required authority. A sidecar with a
        // well-formed package but an invalid signature must not authorize
        // automatic provisioning or official trust.
        XCTAssertNil(store.verifiedCurrent(
            skillID: "demo", contentDigest: oldDigest,
            packageRoot: packageRoot, manifestOverride: nil))

        XCTAssertTrue(try store.persist(newEnvelope, skillID: "demo",
                                        contentDigest: newDigest))
        XCTAssertEqual(store.currentEnvelope(skillID: "demo")?.publicationCommit,
                       String(repeating: "6", count: 40))

        store.restoreCurrent(skillID: "demo", contentDigest: oldDigest)
        XCTAssertEqual(store.currentEnvelope(skillID: "demo")?.publicationCommit,
                       String(repeating: "5", count: 40))
        XCTAssertNotNil(store.envelope(skillID: "demo", contentDigest: newDigest))

        store.remove(skillID: "demo")
        XCTAssertFalse(store.hasCurrent(skillID: "demo"))
    }

    // MARK: - Job no-replay / unknown exit / cancellation

    func testJobCompletionWithoutExitEvidenceIsUnknown() {
        XCTAssertEqual(C02JobCompletionProof.parse(nil), .unknown)
        XCTAssertEqual(C02JobCompletionProof.parse(""), .unknown)
        XCTAssertEqual(C02JobCompletionProof.parse("job completed, no exit line"), .unknown)
        XCTAssertEqual(C02JobCompletionProof.parse("exit=0 durationMs=1\n--- output ---\nok"),
                       .exit(0))
        XCTAssertEqual(C02JobCompletionProof.parse("exit=1\n--- output ---\nfail"),
                       .exit(1))
    }

    func testFallbackOnlyForProvenPreSubmission() {
        let pre = C02SkillDependencyPreparation.JobRunResult.notSubmitted("payloadEncode")
        XCTAssertTrue(pre.mayFallbackToForeground)

        let finished = C02SkillDependencyPreparation.JobRunResult.finished(
            C02SkillDependencyPreparation.ShellResult(
                exit: 0, text: "exit=0", timedOut: false, failure: nil))
        XCTAssertFalse(finished.mayFallbackToForeground)

        let pending = C02SkillDependencyPreparation.JobRunResult.pending(
            jobID: UUID(), reason: "still live")
        XCTAssertFalse(pending.mayFallbackToForeground)
        XCTAssertFalse(C02SkillDependencyPreparation.JobRunResult.cancelled
            .mayFallbackToForeground)
    }

    func testForegroundDispatchRefusesCancellation() {
        XCTAssertTrue(C02ForegroundDispatchPolicy.shouldDispatch(cancelled: false))
        XCTAssertFalse(C02ForegroundDispatchPolicy.shouldDispatch(cancelled: true))
    }

    // MARK: - Dependency lock parser

    func testPipLockRequiresFullHashClosureAndDeclaredPin() {
        let hash = String(repeating: "c", count: 64)
        let valid = Data("pypdf==5.4.0 --hash=sha256:\(hash)\n".utf8)
        XCTAssertNotNil(C02SkillDependencyPreparation.parsePipLock(
            valid, declaredName: "pypdf", declaredVersion: "5.4.0"))

        let missingHash = Data("pypdf==5.4.0\n".utf8)
        XCTAssertNil(C02SkillDependencyPreparation.parsePipLock(
            missingHash, declaredName: "pypdf", declaredVersion: "5.4.0"))

        let range = Data("pypdf>=5.4 --hash=sha256:\(hash)\n".utf8)
        XCTAssertNil(C02SkillDependencyPreparation.parsePipLock(
            range, declaredName: "pypdf", declaredVersion: "5.4.0"))

        let wrongPin = Data("pypdf==5.3.0 --hash=sha256:\(hash)\n".utf8)
        XCTAssertNil(C02SkillDependencyPreparation.parsePipLock(
            wrongPin, declaredName: "pypdf", declaredVersion: "5.4.0"))
    }

    // MARK: - Fixtures

    private func makePackage(platforms: [SkillPlatform],
                             runtime: SkillScriptRuntime,
                             tools: [String] = []) -> ValidatedSkillPackage {
        let manifest = SkillManifest(
            id: "demo", version: "1.0.0", capabilities: [], tools: tools,
            platforms: platforms.map(\.rawValue), scriptRuntime: runtime)
        return ValidatedSkillPackage(
            rootURL: URL(fileURLWithPath: "/tmp/c02-does-not-exist"),
            metadata: SkillMetadata(name: "demo", description: "", instructions: ""),
            manifest: manifest,
            declaredCapabilities: [],
            supportedPlatforms: Set(platforms),
            files: [],
            canonicalSHA256: String(repeating: "0", count: 64))
    }

    private func makeFeedBytes(production: Bool,
                               minimumAppVersion: String?) throws -> Data {
        let package: Any
        let review: Any
        let status: [String: Any]
        let counts: [String: Any]
        let installOffer: String
        let feedStatus: String
        let sourceCommit: Any
        if production {
            package = [
                "path": "android/packages/demo/1.0.0/demo.zip",
                "size": 1,
                "sha256": String(repeating: "1", count: 64),
                "contentDigest": String(repeating: "2", count: 64),
                "containsScripts": false,
            ]
            review = [
                "path": "reviews/demo/1.0.0.review.json",
                "sha256": String(repeating: "3", count: 64),
                "keyID": CuratedSkillHub.productionKeyID,
            ]
            status = [
                "sourcePinned": true, "licenseChecked": true,
                "adaptation": "frozen", "packaged": true,
                "reviewed": true, "qualified": true,
                "published": true, "executionVerified": false,
            ]
            counts = [
                "total": 1, "builtin": 0, "optional": 1,
                "deepAdaptation": 0, "packaged": 1, "reviewed": 1,
                "qualified": 1, "offerQualified": 1,
            ]
            installOffer = "qualified"
            feedStatus = "production"
            sourceCommit = String(repeating: "4", count: 40)
        } else {
            package = NSNull()
            review = NSNull()
            status = [
                "sourcePinned": true, "licenseChecked": true,
                "adaptation": "planned", "packaged": false,
                "reviewed": false, "qualified": false,
                "published": false, "executionVerified": false,
            ]
            counts = [
                "total": 1, "builtin": 0, "optional": 1,
                "deepAdaptation": 0, "packaged": 0, "reviewed": 0,
                "qualified": 0, "offerQualified": 0,
            ]
            installOffer = "none"
            feedStatus = "fixture"
            sourceCommit = NSNull()
        }
        let entry: [String: Any] = [
            "id": "demo",
            "planNumber": 1,
            "kind": "optional",
            "source": "F",
            "name": ["en": "Demo", "zh-Hans": "演示"],
            "description": ["en": "Synthetic feed entry.", "zh-Hans": "合成目录项。"],
            "category": "writing-communication",
            "tags": ["demo", "synthetic"],
            "deepAdaptation": false,
            "upstream": NSNull(),
            "firstParty": NSNull(),
            "runtime": [
                "scriptRuntime": "none",
                "capabilities": [],
                "tools": [],
                "installPlatforms": ["android"],
                "pythonPackagesPlan": [],
                "execution": ["os": NSNull(), "arch": "n/a", "evidence": "unproven"],
            ],
            "version": "1.0.0",
            "minimumAppVersion": minimumAppVersion ?? NSNull(),
            "status": status,
            "notes": ["en": "", "zh-Hans": ""],
            "package": package,
            "review": review,
            "installOffer": installOffer,
        ]
        let root: [String: Any] = [
            "schemaVersion": 3,
            "publisher": CuratedSkillHub.publisher,
            "channel": "android",
            "feedStatus": feedStatus,
            "hubRepository": CuratedSkillHub.hubRepository,
            "sourceCommit": sourceCommit,
            "permissionPolicy": [
                "automaticInstallWhenReviewedAndGranted": true,
                "deltaOnlyApproval": true,
                "selfApprovalProhibited": true,
                "userDisabledAndRemovedPriority": "user",
                "temporaryTaskCeiling": "client-enforced",
            ],
            "entries": [entry],
            "counts": counts,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func makeEnvelope(publicationCommit: String) -> C02CuratedReceiptEnvelope {
        C02CuratedReceiptEnvelope(
            catalogBytes: Data("{}".utf8),
            catalogSignature: Data("not-a-signature".utf8),
            reviewBytes: Data("{}".utf8),
            reviewSignature: Data("not-a-signature".utf8),
            publicationCommit: publicationCommit)
    }

    // MARK: - Runtime-component target/supply classification

    func testRuntimeComponentReportsExactTargetMismatchBeforeAnySupplyClaim() throws {
        let descriptor = try makeEngineDescriptor()
        let availability = C02RuntimeComponentPlanBuilder.availability(
            descriptor: descriptor, actualOS: "linux", actualArch: "arm64",
            appVersion: "1.7.60", publicationCommit: String(repeating: "a", count: 40))
        guard case .targetMismatch(let declared, let actual) = availability else {
            return XCTFail("expected a precise target mismatch")
        }
        XCTAssertEqual(declared, "linux/riscv64")
        XCTAssertEqual(actual, "linux/arm64")
    }

    func testRuntimeComponentTargetMatchStillHonorsTheAppVersionFloor() throws {
        let descriptor = try makeEngineDescriptor()
        let availability = C02RuntimeComponentPlanBuilder.availability(
            descriptor: descriptor, actualOS: "linux", actualArch: "riscv64",
            appVersion: "0.1.0", publicationCommit: String(repeating: "a", count: 40))
        guard case .clientVersionFloor(let minimum, let actual) = availability else {
            return XCTFail("expected the app-version floor")
        }
        XCTAssertEqual(minimum, "1.7.60")
        XCTAssertEqual(actual, "0.1.0")
    }

    func testRuntimeComponentPlanPinsTheExactArtifactAndGuestCache() throws {
        let descriptor = try makeEngineDescriptor()
        let commit = String(repeating: "b", count: 40)
        let availability = C02RuntimeComponentPlanBuilder.availability(
            descriptor: descriptor, actualOS: "linux", actualArch: "riscv64",
            appVersion: "1.7.60", publicationCommit: commit)
        guard case .portable(let plan) = availability else {
            return XCTFail("expected a portable exact-target plan")
        }
        XCTAssertEqual(plan.componentID, "impeccable-engine")
        XCTAssertEqual(plan.componentVersion, "0.1.17+floe.1.1.1")
        XCTAssertEqual(plan.artifactSize, descriptor.artifact.size)
        XCTAssertEqual(plan.artifactSHA256, descriptor.artifact.sha256)
        XCTAssertTrue(plan.artifactURL.contains(commit))
        XCTAssertTrue(plan.artifactURL.contains("engines/impeccable/dist/"))
        XCTAssertTrue(plan.guestPath.hasPrefix("~/.floe/runtime-components/"))
        XCTAssertTrue(plan.guestPath.contains(descriptor.artifact.sha256))
        let provision = try XCTUnwrap(C02RuntimeComponentCommands.provision(plan))
        XCTAssertTrue(provision.contains("component=provisioned"))
        XCTAssertTrue(provision.contains("os.link"))
        let verify = try XCTUnwrap(C02RuntimeComponentCommands.verify(plan))
        XCTAssertTrue(verify.contains("component=verified"))
        XCTAssertTrue(verify.contains("engine-probe"))
        XCTAssertTrue(verify.contains("contract"))
    }

    func testRuntimeComponentWithoutImmutableCommitIsSupplyRejected() throws {
        let descriptor = try makeEngineDescriptor()
        let availability = C02RuntimeComponentPlanBuilder.availability(
            descriptor: descriptor, actualOS: "linux", actualArch: "riscv64",
            appVersion: "1.7.60", publicationCommit: "not-a-commit")
        guard case .supplyRejected = availability else {
            return XCTFail("expected a supply rejection")
        }
    }

    private func makeEngineDescriptor() throws -> SkillRuntimeDependencyDescriptor {
        let path = SkillRuntimeDependency.expectedArtifactPath(
            componentVersion: "0.1.17+floe.1.1.1",
            triple: SkillRuntimeDependency.frozenTargetTriple)
        let object: [String: Any] = [
            "schemaVersion": 1,
            "componentID": SkillRuntimeDependency.knownComponentID,
            "componentVersion": "0.1.17+floe.1.1.1",
            "minimumAppVersion": "1.7.60",
            "target": [
                "os": "linux",
                "arch": "riscv64",
                "triple": SkillRuntimeDependency.frozenTargetTriple,
                "format": SkillRuntimeDependency.frozenTargetFormat,
            ],
            "artifact": [
                "path": path,
                "size": 1_234,
                "sha256": String(repeating: "c", count: 64),
            ],
            "captureContract": [
                "version": 1,
                "sha256": String(repeating: "d", count: 64),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try SkillRuntimeDependency.decode(data)
    }
}
