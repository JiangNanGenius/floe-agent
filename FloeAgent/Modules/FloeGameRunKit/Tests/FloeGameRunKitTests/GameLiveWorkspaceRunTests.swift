// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameWebKit
@testable import FloeGameRunKit

final class GameLiveWorkspaceRunTests: XCTestCase {
    func testWebPreparationPreservesOriginalGitAndUnknownHiddenGameData() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "index.html": Data(html(["app.js"]).utf8), "app.js": Data("window.value=1;".utf8),
            ".git/config": Data("existing IDE administrative data".utf8),
            "nested/.hg/store": Data("nested administrative data".utf8),
            ".game-data": Data([0, 255, 1])])
        let preparer = try GameUnifiedRunPreparer(configuration: .init(artifactDirectory: project.artifacts, contexts: project.host))
        let prepared = try await preparer.prepare(makeRequest(project.context, .phaser))
        let paths = Set(prepared.package.files.map(\.path.value))
        XCTAssertFalse(paths.contains { $0.split(separator: "/").contains(".git") || $0.contains(".hg/") })
        XCTAssertEqual(try prepared.package.readResource(GameRelativePath(".game-data")), Data([0, 255, 1]))
        XCTAssertThrowsError(try prepared.package.readResource(GameRelativePath(".git/config")))
        XCTAssertEqual(try Data(contentsOf: project.context.rootURL.appendingPathComponent(".git/config")), Data("existing IDE administrative data".utf8))
    }

    func testAnAdministrativeDirectoryCannotBeSelectedAsTheGameRoot() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            ".git/index.html": Data(html(["app.js"]).utf8), ".git/app.js": Data("window.value=1;".utf8)])
        let preparer = try GameUnifiedRunPreparer(configuration: .init(artifactDirectory: project.artifacts, contexts: project.host))
        let selection = try GameRunSelection(context: project.context, root: ".git")
        do {
            _ = try await preparer.prepare(makeRequest(project.context, .phaser), selection: selection)
            XCTFail("administrative directory is not a playable root")
        } catch let error as GameRunPreparationError {
            guard case .invalidSelection = error else { throw error }
        }
        XCTAssertEqual(try Data(contentsOf: project.context.rootURL.appendingPathComponent(".git/app.js")), Data("window.value=1;".utf8))
    }

    func testConcurrentExplicitRootsCannotBorrowAnotherRunsDefaultSelection() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "alpha/index.html": Data(html(["app.js"]).utf8), "alpha/app.js": Data("window.level='alpha';".utf8),
            "beta/index.html": Data(html(["app.js"]).utf8), "beta/app.js": Data("window.level='beta';".utf8)])
        let preparer = try GameUnifiedRunPreparer(configuration: .init(artifactDirectory: project.artifacts, contexts: project.host))
        let alpha = try GameRunSelection(context: project.context, root: "alpha")
        let beta = try GameRunSelection(context: project.context, root: "beta")
        await preparer.select(beta)
        async let a = preparer.prepare(makeRequest(project.context, .phaser), selection: alpha)
        async let b = preparer.prepare(makeRequest(project.context, .phaser), selection: beta)
        let (left, right) = try await (a, b)
        XCTAssertEqual(try left.package.readResource(GameRelativePath("app.js")), Data("window.level='alpha';".utf8))
        XCTAssertEqual(try right.package.readResource(GameRelativePath("app.js")), Data("window.level='beta';".utf8))
        XCTAssertNotEqual(left.package.directory, right.package.directory)
        XCTAssertNotEqual(try left.package.prepared.storageIdentity(), try right.package.prepared.storageIdentity())
        XCTAssertEqual(left.package.prepared.gameRoot, "alpha")
        XCTAssertEqual(right.package.prepared.gameRoot, "beta")
    }
}
