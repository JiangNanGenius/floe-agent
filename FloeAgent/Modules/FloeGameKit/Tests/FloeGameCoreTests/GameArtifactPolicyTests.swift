// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameCore

@MainActor final class GameArtifactPolicyTests: XCTestCase {
    func testWebArtifactsOmitIDEGitWhileKeepingUnknownHiddenGameData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested/.svn"), withIntermediateDirectories: true)
        try Data("IDE Git data".utf8).write(to: source.appendingPathComponent(".git/config"))
        try Data("nested administrative data".utf8).write(to: source.appendingPathComponent("nested/.svn/entries"))
        try Data([0, 255, 1]).write(to: source.appendingPathComponent(".game-data"))
        try Data("<html>original game fixture</html>".utf8).write(to: source.appendingPathComponent("index.html"))
        let id = UUID(), context = try GameProjectContext(projectID: id, owner: .space(recordID: id), rootURL: source, savedRevision: "r1")
        let artifact = try GameWebArtifactPackage.build(source: context, engine: .phaser,
            entry: GameRelativePath("index.html"), to: root.appendingPathComponent("artifact"))
        XCTAssertEqual(Set(artifact.files.map(\.path.value)), ["index.html", ".game-data"])
        XCTAssertThrowsError(try artifact.readResource(GameRelativePath(".git/config")))
        XCTAssertEqual(try artifact.readResource(GameRelativePath(".game-data")), Data([0, 255, 1]))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(".git/config")), Data("IDE Git data".utf8))
    }

    func testCompiledOutputKeepsOriginalSourceIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), output = root.appendingPathComponent("output")
        for url in [source, output] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("source-code".utf8).write(to: source.appendingPathComponent("Main.cs"))
        try Data("<html>compiled</html>".utf8).write(to: output.appendingPathComponent("index.html"))
        let id = UUID(), context = try GameProjectContext(projectID: id, owner: .space(recordID: id), rootURL: source, savedRevision: "r1")
        let artifact = try GameWebArtifactPackage.build(source: context, engine: .unity, entry: GameRelativePath("index.html"), to: root.appendingPathComponent("artifact"), contentRoot: output)
        XCTAssertEqual(artifact.prepared.source, context)
        XCTAssertEqual(artifact.files.map(\.path.value), ["index.html"])
        try artifact.verify()
        XCTAssertThrowsError(try GameWebArtifactPackage.build(source: context, engine: .unity, entry: GameRelativePath("index.html"), to: output.appendingPathComponent("nested"), contentRoot: output))
    }

    func testEnginePoliciesStayOfflineAndOnlyEnableNeededBrowserFeatures() throws {
        for engine in GameEngineID.allCases {
            let policy = GameWebRuntimePolicy(engine: engine)
            XCTAssertTrue(policy.contentSecurityPolicy.contains("connect-src 'self'"))
            XCTAssertTrue(policy.contentSecurityPolicy.contains("frame-src 'none'"))
            XCTAssertFalse(policy.contentSecurityPolicy.contains("https:"))
            XCTAssertLessThanOrEqual(policy.maximumStateBytes, 4_194_304)
        }
        XCTAssertFalse(GameWebRuntimePolicy(engine: .phaser).allowsWebAssembly)
        XCTAssertFalse(GameWebRuntimePolicy(engine: .phaser).allowsJavaScriptEvaluation)
        XCTAssertTrue(GameWebRuntimePolicy(engine: .wasm4).contentSecurityPolicy.contains("'wasm-unsafe-eval'"))
        // The actual pinned WASM-4 audio fallback uses new Function; browser
        // JavaScript evaluation is needed independently of WASM compilation.
        XCTAssertTrue(GameWebRuntimePolicy(engine: .wasm4).allowsJavaScriptEvaluation)
        XCTAssertFalse(GameWebRuntimePolicy(engine: .wasm4).allowsWorkers)
        XCTAssertTrue(GameWebRuntimePolicy(engine: .gdevelop).allowsJavaScriptEvaluation)
        XCTAssertFalse(GameWebRuntimePolicy(engine: .gdevelop).allowsWebAssembly)
        XCTAssertTrue(GameWebRuntimePolicy(engine: .rpgMakerMV).allowsJavaScriptEvaluation)
        XCTAssertTrue(GameWebRuntimePolicy(engine: .rpgMakerMZ).allowsJavaScriptEvaluation)
        XCTAssertTrue(GameWebRuntimePolicy(engine: .love).allowsJavaScriptEvaluation)
        XCTAssertTrue(GameWebRuntimePolicy(engine: .twine).allowsJavaScriptEvaluation)
        XCTAssertEqual(GameWebArtifactPackage.mimeType(for: try GameRelativePath("Build/game.wasm.br")), "application/wasm")
    }

    func testLargerConsoleSaveRemainsBoundedAndCASProtected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), id = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileGameSaveRepository(directory: root, projectID: id, owner: .space(recordID: id), maximumStateBytes: 1_048_576)
        let state = try JSONSerialization.data(withJSONObject: ["memory": String(repeating: "x", count: 200_000)])
        let saved = try await store.save(state, expectedRevision: 0)
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.state, state); XCTAssertEqual(saved.revision, 1)
        do { _ = try await store.save(Data(repeating: 32, count: 1_048_577), expectedRevision: 1); XCTFail("Expected bound") }
        catch { XCTAssertEqual(error as? GameProjectError, .limitExceeded("gameSave")) }
        XCTAssertThrowsError(try FileGameSaveRepository(directory: root, projectID: id, owner: .space(recordID: id), maximumStateBytes: Int.max))
    }
}
