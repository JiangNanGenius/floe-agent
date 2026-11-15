// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameWebKit
@testable import FloeGameRunKit

private struct ReboundRootHost: GameRunContextHost {
    let context: GameProjectContext
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext { context }
}

final class GameRunRootFenceTests: XCTestCase {
    func testSameRevisionWithReboundRootStillRejectsBeforeCreatingArtifact() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace,
            files: ["index.html": Data("<!doctype html><title>source</title>".utf8)])
        let rebound = workspace.url("other-root")
        try FileManager.default.createDirectory(at: rebound, withIntermediateDirectories: true)
        let current = try GameProjectContext(projectID: project.projectID, owner: project.owner,
            rootURL: rebound, savedRevision: project.context.savedRevision,
            environmentID: project.context.environmentID)
        let preparer = try GameUnifiedRunPreparer(configuration: GameRunPreparationConfiguration(
            artifactDirectory: project.artifacts, contexts: ReboundRootHost(context: current)))
        let request = GameWebRunRequest(id: UUID(), context: project.context, engine: .phaser)
        do {
            _ = try await preparer.prepare(request)
            XCTFail("A root rebind with the same revision must remain fenced")
        } catch let error as GameRunPreparationError {
            guard case .contextChanged(.root) = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            project.artifacts.appendingPathComponent(request.id.uuidString.lowercased()).path))
    }
}
