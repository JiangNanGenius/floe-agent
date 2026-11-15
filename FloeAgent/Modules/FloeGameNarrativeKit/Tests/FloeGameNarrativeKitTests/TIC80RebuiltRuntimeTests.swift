// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameNarrativeKit

final class TIC80RebuiltRuntimeTests: XCTestCase {
    func testRebuildIdentityRequiresExactSourceBytesAndBoundedRevision() throws {
        let source = Data("Original synthetic source companion fixture".utf8)
        let sha = GameDigest.sha256(source)
        XCTAssertThrowsError(try GameTIC80RebuiltRuntime(revision: "../other", jsSHA256: sha,
            wasmSHA256: sha, sourceCompanion: source, sourceSHA256: sha))
        XCTAssertThrowsError(try GameTIC80RebuiltRuntime(revision: "test", jsSHA256: "unknown",
            wasmSHA256: sha, sourceCompanion: source, sourceSHA256: sha))
        XCTAssertThrowsError(try GameTIC80RebuiltRuntime(revision: "test", jsSHA256: sha,
            wasmSHA256: sha, sourceCompanion: source + Data([0]), sourceSHA256: sha))
        XCTAssertThrowsError(try GameTIC80RebuiltRuntime(revision: "test", jsSHA256: sha,
            wasmSHA256: sha, sourceCompanion: Data(), sourceSHA256: GameDigest.sha256(Data())))
    }

    func testExplicitReplacementRetainsCompanionAndOriginalCartridge() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("tic-rebuild")
        defer { try? FileManager.default.removeItem(at: work) }
        let resources = work.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: NarrativeTestSupport.resources.appendingPathComponent("tic80"),
                                        to: resources.appendingPathComponent("tic80"))
        let jsURL = resources.appendingPathComponent("tic80/tic80.js")
        let modifiedJS = try Data(contentsOf: jsURL) + Data("\n/* original test-only rebuild identity */\n".utf8)
        try modifiedJS.write(to: jsURL)
        let wasm = try Data(contentsOf: resources.appendingPathComponent("tic80/tic80js.wasm"))
        let source = Data("Original test source companion; this unit fixture is not a distribution clearance".utf8)
        let replacement = try GameTIC80RebuiltRuntime(revision: "1.4.1-test",
            jsSHA256: GameDigest.sha256(modifiedJS), wasmSHA256: GameDigest.sha256(wasm),
            sourceCompanion: source, sourceSHA256: GameDigest.sha256(source))
        let project = work.appendingPathComponent("project")
        try GameTIC80Adapter.createProject(at: project, title: "Rebuild test")
        let originalCart = try Data(contentsOf: project.appendingPathComponent("cart.tic"))
        XCTAssertThrowsError(try GameTIC80Adapter.buildArtifact(projectAt: project,
            to: work.appendingPathComponent("default-rejected"), resources: resources))
        let artifact = work.appendingPathComponent("replacement")
        try GameTIC80Adapter.buildArtifact(projectAt: project, to: artifact, resources: resources,
                                           rebuiltRuntime: replacement)
        XCTAssertEqual(try Data(contentsOf: artifact.appendingPathComponent("tic80.js")), modifiedJS)
        XCTAssertEqual(try Data(contentsOf: artifact.appendingPathComponent("cart.tic")), originalCart)
        XCTAssertEqual(try Data(contentsOf: artifact.appendingPathComponent("third-party-source/tic80/REBUILT-SOURCE.zip")), source)
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            artifact.appendingPathComponent("licenses/TIC80-REBUILT-IDENTITY.json"))) as? [String: String])
        XCTAssertEqual(identity["sourceSHA256"], GameDigest.sha256(source))
        try Data("tampered".utf8).write(to: jsURL)
        XCTAssertThrowsError(try GameTIC80Adapter.buildArtifact(projectAt: project,
            to: work.appendingPathComponent("tampered-rejected"), resources: resources, rebuiltRuntime: replacement))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("tampered-rejected").path))
    }
}
