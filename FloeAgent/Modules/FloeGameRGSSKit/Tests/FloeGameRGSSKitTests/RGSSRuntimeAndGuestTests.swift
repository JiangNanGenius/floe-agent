// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameRGSS

final class RGSSRuntimePackTests: XCTestCase {
    func testPinnedHashesAreWellFormed() throws {
        let pin = RGSSRuntimePinCatalog.mkxpWebAsyncifyRGSS1
        XCTAssertEqual(pin.license, "GPL-2.0-or-later")
        XCTAssertEqual(pin.sourceCommit.count, 40)
        XCTAssertEqual(pin.sourceArchive.sha256.count, 64)
        for file in pin.files {
            XCTAssertEqual(file.sha256.count, 64)
            XCTAssertGreaterThan(file.bytes, 0)
            XCTAssertTrue(file.sha256.allSatisfy { $0.isHexDigit })
        }
    }

    func testRealPackVerificationAndAtomicInstall() throws {
        let pack = try runtimePackOrSkip()
        let files = try pack.verifiedFiles()
        XCTAssertNotNil(files["mkxp.js"])
        XCTAssertNotNil(files["mkxp.wasm"])
        XCTAssertNotNil(files["rgss.rb"])
        XCTAssertGreaterThan(try pack.sourceArchiveData().count, 0)
        let target = try temporaryDirectory().appendingPathComponent("installed-pack")
        let installed = try pack.install(to: target)
        XCTAssertEqual(installed.pin.id, pack.pin.id)
        XCTAssertEqual(try installed.verifiedFiles().keys.sorted(), files.keys.sorted())
        XCTAssertThrowsError(try pack.install(to: target))
    }
}

final class RGSSArtifactBuilderTests: XCTestCase {
    func testRealArtifactSealsSourceAndEngineAndOmitsNativeFiles() throws {
        let pack = try runtimePackOrSkip()
        let temp = try temporaryDirectory()
        let sourceRoot = Fixture.url("xp-preservation-project")
        let projectID = UUID()
        let owner = GameProjectOwner.space(recordID: projectID)
        let context = try makeContext(root: sourceRoot, projectID: projectID, owner: owner)
        let target = temp.appendingPathComponent("artifact")
        let artifact = try RGSSArtifactBuilder().build(
            source: context, engine: .rpgMakerXP, pack: pack,
            mode: .verifiedFixture, to: target)
        let paths = Set(artifact.package.files.map(\.path.value))
        XCTAssertTrue(paths.contains("game/Data/Scripts.rxdata"))
        XCTAssertTrue(paths.contains("game/rgss.rb"))
        XCTAssertTrue(paths.contains("game/floe-inputs.json"))
        XCTAssertTrue(paths.contains("engine/mkxp.js"))
        XCTAssertTrue(paths.contains("engine/mkxp.wasm"))
        XCTAssertTrue(paths.contains("index.html"))
        XCTAssertTrue(paths.contains("floe-runtime-manifest.json"))
        XCTAssertTrue(paths.contains("licenses/MKXP-COPYING.txt"))
        XCTAssertFalse(paths.contains("game/Game.exe"))
        XCTAssertFalse(paths.contains("game/RGSS104E.dll"))
        XCTAssertFalse(paths.contains("game/Game.rgssad"))
        let omitted = Set(artifact.omitted.map(\.path))
        XCTAssertTrue(omitted.contains("Game.exe"))
        XCTAssertTrue(omitted.contains("RGSS104E.dll"))
        XCTAssertTrue(omitted.contains("Game.rgssad"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("Game.exe").path))
        try artifact.package.verify()
        let index = try artifact.package.readResource(try GameRelativePath("index.html"))
        let indexText = String(data: index, encoding: .utf8) ?? ""
        XCTAssertTrue(indexText.contains("FLOE_RGSS_CONFIG"))
        XCTAssertTrue(indexText.contains("wasm-unsafe-eval") == false) // CSP is a host header, not a second meta policy
        let manifestData = try artifact.package.readResource(try GameRelativePath("floe-runtime-manifest.json"))
        let manifest = try JSONDecoder().decode(RGSSRuntimeManifest.self, from: manifestData)
        XCTAssertEqual(manifest.engine, .rpgMakerXP)
        XCTAssertEqual(manifest.entry, "index.html")
        XCTAssertEqual(manifest.runtimePinID, RGSSRuntimePinCatalog.mkxpWebAsyncifyRGSS1.id)
        XCTAssertEqual(manifest.requiredContentSecurityPolicy, RGSSWebRuntimeRequirements.requiredContentSecurityPolicy)
        XCTAssertEqual(manifest.input.engine, .rpgMakerXP)
        XCTAssertTrue(manifest.preload.contains("rgss.rb"))
        XCTAssertTrue(manifest.preload.contains("Data/Scripts.rxdata"))
        XCTAssertTrue(manifest.files.contains(where: { $0.path == "game/Data/Scripts.rxdata" && $0.role == "project" }))
        XCTAssertEqual(Set(manifest.files.map(\.path)).count, manifest.files.count)
    }

    func testSwiftBuiltArtifactForHeadlessQualification() throws {
        guard let output = ProcessInfo.processInfo.environment["FLOE_RGSS_ARTIFACT_OUT"], !output.isEmpty else {
            throw XCTSkip("set FLOE_RGSS_ARTIFACT_OUT for the headless Swift-artifact qualification")
        }
        let pack = try runtimePackOrSkip()
        let target = URL(fileURLWithPath: output)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        let sourceRoot = Fixture.url("xp-runtime-project")
        let projectID = UUID()
        let context = try makeContext(root: sourceRoot, projectID: projectID,
                                      owner: .space(recordID: projectID))
        let artifact = try RGSSArtifactBuilder().build(
            source: context, engine: .rpgMakerXP, pack: pack,
            mode: .verifiedFixture, to: target)
        let summary: [String: Any] = [
            "directory": target.path,
            "artifactDigest": artifact.package.prepared.sha256,
            "preparedID": artifact.package.prepared.id.uuidString.lowercased(),
            "entry": artifact.package.prepared.entry.value,
            "fileCount": artifact.package.files.count,
            "runtimePinID": artifact.manifest.runtimePinID,
            "sourceRevision": artifact.manifest.sourceRevision,
            "requiredCSP": artifact.manifest.requiredContentSecurityPolicy
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: target.deletingLastPathComponent().appendingPathComponent("swift-artifact-summary.json"),
                       options: [.atomic])
        try artifact.package.verify()
    }

    func testBuilderRefusesVXWithoutAReviewedWebPin() throws {
        let pack = try runtimePackOrSkip()
        let temp = try temporaryDirectory()
        let sourceRoot = Fixture.url("vx-template-project")
        let projectID = UUID()
        let context = try makeContext(root: sourceRoot, projectID: projectID,
                                      owner: .space(recordID: projectID))
        do {
            _ = try RGSSArtifactBuilder().build(
                source: context, engine: .rpgMakerVX, pack: pack,
                mode: .template, to: temp.appendingPathComponent("vx-artifact"))
            XCTFail("expected VX Web rejection")
        } catch {
            XCTAssertEqual(error as? RGSSRuntimeError, .unsupportedWebEngine(.rpgMakerVX))
        }
    }

    func testArtifactRefusesAnExistingTarget() throws {
        let pack = try runtimePackOrSkip()
        let temp = try temporaryDirectory()
        let sourceRoot = Fixture.url("xp-runtime-project")
        let projectID = UUID()
        let context = try makeContext(root: sourceRoot, projectID: projectID,
                                      owner: .space(recordID: projectID))
        let target = temp.appendingPathComponent("artifact")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RGSSArtifactBuilder().build(
            source: context, engine: .rpgMakerXP, pack: pack,
            mode: .template, to: target))
    }
}

final class RGSSPolicyAndHarnessTests: XCTestCase {
    func testJSPIRecipeIsSourceOnlyAndDoesNotClaimRuntime() {
        let recipe = RGSSWebRuntimeRecipes.mkxpWebJSPI
        XCTAssertEqual(recipe.sourceCommit, "65a31be926b1f6b01cee9b6ebde229f288c421af")
        XCTAssertEqual(recipe.sourceArchiveSHA256.count, 64)
        XCTAssertEqual(recipe.supportedVersions, [.rgss1, .rgss2])
        XCTAssertTrue(recipe.requiresJSPI)
        XCTAssertFalse(recipe.supportsAsyncify)
        XCTAssertFalse(recipe.hasBinaryPack)
        XCTAssertEqual(recipe.evidenceStatus, .sourceRecipeOnly)
        let support = try! RGSSRuntimeMatrix.support(for: .rpgMakerVX)
        guard case .sourceRecipeOnly(let id, _) = support.web else {
            XCTFail("VX must not be marked as executed Web")
            return
        }
        XCTAssertEqual(id, recipe.id)
    }

    func testCurrentHostPolicyDoesNotEnableRGSSWebAssembly() {
        let policy = GameWebRuntimePolicy(engine: .rpgMakerXP)
        XCTAssertFalse(policy.allowsWebAssembly)
        XCTAssertEqual(RGSSWebRuntimeRequirements.missingFeatures(in: policy), [.webAssembly])
        XCTAssertThrowsError(try RGSSWebRuntimeRequirements.validate(policy: policy))
        XCTAssertTrue(RGSSWebRuntimeRequirements.requiredContentSecurityPolicy.contains("'wasm-unsafe-eval'"))
        XCTAssertTrue(RGSSWebRuntimeRequirements.requiredContentSecurityPolicy.contains("connect-src 'self'"))
        XCTAssertTrue(RGSSWebRuntimeRequirements.requiredContentSecurityPolicy.contains("worker-src 'none'"))
        XCTAssertEqual(RGSSWebRuntimeRequirements.mimeTypeRequirements["wasm"], "application/wasm")
    }

    func testHarnessHasOnlyFixedPackageAndBridgeOperations() throws {
        let text = String(data: try RGSSHarnessResources.runtimeJavaScript(), encoding: .utf8) ?? ""
        for required in ["window.FloeGame", "key: function", "snapshot: snapshot",
                         "restore: restore", "loadFileAsync", "saveFile", "floeGameHost"] {
            XCTAssertTrue(text.contains(required), "missing harness contract \(required)")
        }
        for forbidden in ["NODEFS", "NODERAWFS", "indexedDB.", "localStorage.",
                          "new Function", "require(", "child_process", "XMLHttpRequest"] {
            XCTAssertFalse(text.contains(forbidden), "unexpected host capability \(forbidden)")
        }
        let template = String(data: try RGSSHarnessResources.indexTemplate(), encoding: .utf8) ?? ""
        XCTAssertTrue(template.contains("__FLOE_RGSS_CONFIG__"))
        XCTAssertTrue(template.contains("floe-runtime.js"))
    }
}

actor FakeGuestPort: RGSSGuestRuntimePort {
    private(set) var requests: [RGSSGuestLaunchRequest] = []
    private(set) var stops = 0
    private(set) var lastStatus: RGSSGuestJobState = .running(frameRevision: 3)

    func launch(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestJobHandle {
        requests.append(request)
        return .init(jobID: request.jobID, ownerToken: UUID())
    }
    func status(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus {
        .init(handle: handle, state: lastStatus, elapsedMilliseconds: 120)
    }
    func stop(_ handle: RGSSGuestJobHandle) async throws { stops += 1 }
    func setStatus(_ value: RGSSGuestJobState) { lastStatus = value }
}

actor FakeGuestContexts: RGSSGuestContextHost {
    var value: GameProjectContext
    init(_ value: GameProjectContext) { self.value = value }
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext { value }
    func set(_ value: GameProjectContext) { self.value = value }
}

final class RGSSGuestAdapterTests: XCTestCase {
    func testOwnedGuestLaunchAndStopUseExplicitContext() async throws {
        let root = try temporaryDirectory()
        let projectID = UUID()
        let context = try makeContext(root: root, projectID: projectID,
                                      owner: .space(recordID: projectID))
        let port = FakeGuestPort()
        let contexts = FakeGuestContexts(context)
        let adapter = RGSSGuestRuntimeAdapter(port: port, contexts: contexts)
        let digest = String(repeating: "a", count: 64)
        let session = try await adapter.run(context: context, engine: .rpgMakerXP,
                                            displayServiceID: "floe-display-start",
                                            sourceDigest: digest)
        XCTAssertEqual(session.sourceDigest, digest)
        XCTAssertEqual(session.environmentID, "env-rgss")
        let requests = await port.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].displayServiceID, "floe-display-start")
        XCTAssertEqual(requests[0].revision, context.savedRevision)
        XCTAssertEqual(requests[0].projectRoot, context.rootURL)
        let status = try await adapter.status(session)
        XCTAssertEqual(status.state, .running(frameRevision: 3))
        let stopped = try await adapter.stop(session)
        XCTAssertTrue(stopped)
        let stops = await port.stops
        XCTAssertEqual(stops, 1)
    }

    func testContextChangeAfterLaunchStopsTheOwnedJob() async throws {
        let root = try temporaryDirectory()
        let projectID = UUID()
        let context = try makeContext(root: root, projectID: projectID,
                                      owner: .space(recordID: projectID))
        let other = try makeContext(root: root, projectID: projectID,
                                    owner: .space(recordID: projectID), revision: "fixture-r2")
        let port = FakeGuestPort()
        let contexts = FakeGuestContexts(context)
        let adapter = RGSSGuestRuntimeAdapter(port: port, contexts: contexts)
        let session = try await adapter.run(context: context, engine: .rpgMakerXP,
                                            displayServiceID: "display",
                                            sourceDigest: String(repeating: "b", count: 64))
        await contexts.set(other)
        do {
            _ = try await adapter.status(session)
            XCTFail("expected context mismatch")
        } catch {
            XCTAssertEqual(error as? RGSSRuntimeError, .guestContextMismatch)
        }
    }

    func testMissingEnvironmentAndInvalidDigestAreRejected() async throws {
        let root = try temporaryDirectory()
        let projectID = UUID()
        let context = try makeContext(root: root, projectID: projectID,
                                      owner: .space(recordID: projectID), environment: nil)
        let adapter = RGSSGuestRuntimeAdapter(port: FakeGuestPort(),
                                              contexts: FakeGuestContexts(context))
        do {
            _ = try await adapter.run(context: context, engine: .rpgMakerXP,
                                      displayServiceID: "display",
                                      sourceDigest: String(repeating: "a", count: 64))
            XCTFail("expected missing environment")
        } catch {
            XCTAssertEqual(error as? RGSSRuntimeError, .guestEnvironmentMissing)
        }
    }
}
