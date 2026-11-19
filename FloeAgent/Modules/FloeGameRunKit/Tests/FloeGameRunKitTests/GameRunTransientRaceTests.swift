// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameRunKit
import FloeGameCore
import FloeGameWebKit

final class GameRunTransientRaceTests: XCTestCase {
    func testExternalBuildRaceNeverRerunsHostBuild() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "index.html": Data(html(["game.js"]).utf8),
            "game.js": Data("window.x=1;".utf8),
            "package.json": Data(#"{"dependencies":{"phaser":"^3.60.0"}}"#.utf8),
        ])
        let provider = DriftingExternalProvider(liveRoot: project.context.rootURL)
        let preparer = try GameUnifiedRunPreparer(configuration: .init(
            artifactDirectory: project.artifacts,
            externalBuildProvider: provider,
            contexts: project.host))
        let plan = try await preparer.plan(context: project.context, engine: .phaser)
        XCTAssertEqual(plan.action, .externalBuild)

        do {
            _ = try await preparer.prepare(makeRequest(project.context, .phaser))
            XCTFail("a source race during an external build must fail closed")
        } catch let error as GameRunPreparationError {
            guard case .sourceChanged = error else {
                return XCTFail("expected .sourceChanged, got \(error)")
            }
        }
        let calls = await provider.callCount
        XCTAssertEqual(calls, 1)
    }
}

private actor DriftingExternalProvider: GameRunExternalBuildProviding {
    let liveRoot: URL
    private(set) var callCount = 0

    init(liveRoot: URL) { self.liveRoot = liveRoot }

    func build(_ request: GameRunExternalBuildRequest) async throws -> GameRunExternalBuildOutput {
        callCount += 1
        try Data("window.changed = true;".utf8).write(to: liveRoot.appendingPathComponent("game.js"), options: .atomic)
        let output = request.outputDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("<!doctype html><script src=\"game.js\"></script>".utf8)
            .write(to: output.appendingPathComponent("index.html"), options: .atomic)
        try Data("window.x=1;".utf8).write(to: output.appendingPathComponent("game.js"),
                                           options: .atomic)
        return try GameRunExternalBuildOutput(directory: output,
                                              entry: GameRelativePath("index.html"))
    }
}
