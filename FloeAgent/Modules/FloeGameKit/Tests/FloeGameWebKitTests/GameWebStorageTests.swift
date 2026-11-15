// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameWebKit

@MainActor final class GameWebStorageTests: XCTestCase {
    func testPlayerUsesOneStablePersistentStorePerProjectIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("<!doctype html><html><body>storage</body></html>".utf8)
            .write(to: source.appendingPathComponent("index.html"))
        try Data(#"{"engine":"phaser"}"#.utf8).write(to: source.appendingPathComponent("game.json"))
        let id = UUID()
        let context = try GameProjectContext(projectID: id, owner: .space(recordID: id),
            rootURL: source, savedRevision: "r1", environmentID: "env-1")
        let package = try GameWebArtifactPackage.build(source: context, engine: .phaser,
            entry: GameRelativePath("index.html"), to: root.appendingPathComponent("artifact"))
        var registry = GameAdapterRegistry()
        try registry.register(GameAdapterRegistration(engine: .phaser, route: .webKit, runtimeReady: true))
        guard case .launch(let plan) = try GameLaunchPlanner.plan(
            inspection: GameProjectInspector().inspect(context: context), context: context,
            selectedEngine: .phaser, registry: registry, artifact: package.prepared) else {
            return XCTFail("Expected a launch plan")
        }
        let player = try GameWebPlayer(package: package, plan: plan, current: context)
        let identity = try GameWebStorageIdentity(context: context, engine: .phaser)
        XCTAssertEqual(player.storageIdentity, identity)
        XCTAssertTrue(player.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(player.webView.configuration.websiteDataStore.identifier?.uuidString.lowercased(),
                       identity.originHost)
        XCTAssertEqual(identity.originHost, identity.uuid.uuidString.lowercased())
    }
}
