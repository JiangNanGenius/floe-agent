// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeGameCore
@testable import FloeGamePortableKit

final class AdapterAndArtifactTests: XCTestCase {
    func testMVWebInspectionAndRootScan() throws {
        let root = try TestSupport.makeMVWebProject()
        let project = try GamePortableProjectDescriptor(rootURL: root)
        let profile = try GamePortableMVAdapter().inspect(project)
        XCTAssertEqual(profile.readiness, .webReady)
        XCTAssertEqual(profile.entry?.value, "index.html")
        XCTAssertEqual(profile.capabilities.input, .supported)
        XCTAssertEqual(profile.capabilities.stateSnapshot, .supported)
        XCTAssertEqual(profile.inputDeclaration?.engine, .rpgMakerMV)
        let candidates = try GamePortableRootScanner.scan(rootURL: root)
        XCTAssertTrue(candidates.contains { $0.engines.contains(.rpgMakerMV) })
    }

    func testMVSourcePlanRequiresResourcesAndPreservesSource() throws {
        let root = try TestSupport.temporaryDirectory("mv-source")
        for path in ["index.html", "js/main.js", "js/plugins.js", "data/System.json"] {
            try TestSupport.write("{}", to: root, path: path)
        }
        try TestSupport.write("[]", to: root, path: "rpg_core.json")
        try TestSupport.write("", to: root, path: "js/rpg_core/_header.js")
        try TestSupport.write("", to: root, path: "js/rpg_core/Input.js")
        let project = try GamePortableProjectDescriptor(rootURL: root)
        let adapter = GamePortableMVAdapter()
        let profile = try adapter.inspect(project)
        XCTAssertEqual(profile.readiness, .buildRequired)
        XCTAssertEqual(profile.capabilities.input, .buildRequired)
        let output = root.deletingLastPathComponent().appendingPathComponent("mv-source-out-" + UUID().uuidString)
        let plan = try adapter.plan(for: project, outputURL: output, resources: nil, sdkURL: nil)
        XCTAssertEqual(plan.kind, .mvCoreAssembly)
        XCTAssertFalse(plan.requiresExternalTool)
        XCTAssertThrowsError(try adapter.plan(for: project,
            outputURL: root.appendingPathComponent("inside"), resources: nil, sdkURL: nil))
    }

    func testLoveAndRenPyWebInspectionAndCapabilities() throws {
        let loveRoot = try TestSupport.makeLoveWebProject()
        let love = try GamePortableLoveAdapter().inspect(GamePortableProjectDescriptor(rootURL: loveRoot))
        XCTAssertEqual(love.readiness, .webReady)
        XCTAssertEqual(love.capabilities.stateSnapshot, .unsupported)
        XCTAssertEqual(love.capabilities.save, .engineInternal)
        XCTAssertEqual(love.capabilities.input, .supported)

        let renpyRoot = try TestSupport.makeRenPyWebProject()
        let renpy = try GamePortableRenPyAdapter().inspect(GamePortableProjectDescriptor(rootURL: renpyRoot))
        XCTAssertEqual(renpy.readiness, .webReady)
        XCTAssertEqual(renpy.capabilities.stateSnapshot, .unsupported)
        XCTAssertEqual(renpy.capabilities.save, .engineInternal)
        XCTAssertEqual(renpy.capabilities.input, .supported)
    }

    func testRenPySourcePlanNeedsSDK() throws {
        let root = try TestSupport.temporaryDirectory("renpy-source")
        try TestSupport.write("label start:\n    \"hi\"\n", to: root, path: "game/script.rpy")
        let project = try GamePortableProjectDescriptor(rootURL: root)
        let adapter = GamePortableRenPyAdapter()
        let output = root.deletingLastPathComponent().appendingPathComponent("renpy-out-" + UUID().uuidString)
        XCTAssertThrowsError(try adapter.plan(for: project, outputURL: output, resources: nil, sdkURL: nil))
        let plan = try adapter.plan(for: project, outputURL: output, resources: nil, sdkURL: root)
        XCTAssertEqual(plan.kind, .renpyWebBuild)
        XCTAssertTrue(plan.requiresExternalTool)
    }

    func testArtifactVerifierAcceptsFixturesAndRejectsTampering() throws {
        let loveRoot = try TestSupport.makeLoveWebProject()
        let result = try GamePortableArtifactVerifier.verify(directory: loveRoot, engine: .love,
            profile: nil, resources: nil)
        XCTAssertEqual(result.entry.value, "index.html")
        XCTAssertFalse(result.runtimeHashVerified)
        XCTAssertTrue(result.warnings.contains { $0.code == .runtimeUnverified })
        try TestSupport.write("not wasm", to: loveRoot, path: "love.wasm")
        XCTAssertThrowsError(try GamePortableArtifactVerifier.verify(directory: loveRoot, engine: .love,
            profile: nil, resources: nil))
    }

    func testArtifactVerifierRejectsNativeExecutableAndWrongInputEngine() throws {
        let renpyRoot = try TestSupport.makeRenPyWebProject()
        try TestSupport.write("MZ", to: renpyRoot, path: "tool.exe")
        XCTAssertThrowsError(try GamePortableArtifactVerifier.verify(directory: renpyRoot, engine: .renpy,
            profile: nil, resources: nil))
        try FileManager.default.removeItem(at: renpyRoot.appendingPathComponent("tool.exe"))
        try TestSupport.write("""
        {"schemaVersion":1,"engine":"love","movement":{"left":["left"],"right":["right"],"up":["up"],"down":["down"]},"buttons":[]}
        """, to: renpyRoot, path: "floe-inputs.json")
        XCTAssertThrowsError(try GamePortableArtifactVerifier.verify(directory: renpyRoot, engine: .renpy,
            profile: nil, resources: nil))
    }

    func testArtifactVerifierChecksPreparedRuntimeHashes() throws {
        let resources = try TestSupport.makePreparedResources()
        let root = try TestSupport.makeMVWebProject()
        // Replace fixture core bytes with the prepared runtime bytes so the hash mapping is real.
        for name in ["rpg_core", "rpg_managers", "rpg_objects", "rpg_scenes", "rpg_sprites", "rpg_windows"] {
            try TestSupport.write(try resources.resources.read("js/\(name).js"), to: root, path: "js/\(name).js")
        }
        let result = try GamePortableArtifactVerifier.verify(directory: root, engine: .rpgMakerMV,
            profile: nil, resources: resources.resources)
        XCTAssertTrue(result.runtimeHashVerified)
        try TestSupport.write("tampered", to: root, path: "js/rpg_core.js")
        XCTAssertThrowsError(try GamePortableArtifactVerifier.verify(directory: root, engine: .rpgMakerMV,
            profile: nil, resources: resources.resources))
    }

    func testSealerBindsContextAndRejectsStaleReceipt() throws {
        let root = try TestSupport.makeMVWebProject()
        let project = try GamePortableProjectDescriptor(rootURL: root)
        let profile = try GamePortableMVAdapter().inspect(project)
        let context = try TestSupport.makeContext(root: root, revision: "rev-1")
        let destination = try TestSupport.temporaryDirectory("sealed").appendingPathComponent("artifact")
        let sealed = try GamePortableArtifactSealer.seal(source: context, engine: .rpgMakerMV,
            entry: profile.entry!, contentRoot: root, to: destination, profile: profile,
            resources: nil, buildKind: .sourceCopy)
        XCTAssertEqual(sealed.receipt.artifactDigest, sealed.package.prepared.sha256)
        XCTAssertEqual(sealed.package.files.count, sealed.receipt.files.count)
        try sealed.validate(current: context)
        let stale = try TestSupport.makeContext(root: root, revision: "rev-2")
        XCTAssertThrowsError(try sealed.receipt.validate(current: stale))
        XCTAssertEqual(try sealed.package.readResource(try GameRelativePath("index.html")), Data("<html></html>".utf8))
    }
}
