// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameWebKit
@testable import FloeGameRunKit

final class GameLiveWorkspaceRunTests: XCTestCase {
    private func readFixture(_ root: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let rootPrefix = root.resolvingSymlinksInPath().path + "/"
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(rootPrefix) else { throw CocoaError(.fileReadInvalidFileName) }
                let relative = String(path.dropFirst(rootPrefix.count))
                files[relative] = try Data(contentsOf: url)
            }
        }
        return files
    }

    /// Opt-in: supply a real, locally obtained MV Web export; third-party game
    /// files are never bundled with the source or copied into a test fixture.
    func testRealMVExportImportsAndPreparesItsOwnRuntime() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLOE_REAL_MV_GAME_ROOT"], !path.isEmpty else {
            throw XCTSkip("Set FLOE_REAL_MV_GAME_ROOT to a local MV Web export")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let files = try readFixture(root)
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: files)
        let preparer = try GameUnifiedRunPreparer(configuration: .init(
            artifactDirectory: project.artifacts,
            preparePortableResource: { _ in
                XCTFail("An MV Web export must use its own runtime")
                return nil
            },
            contexts: project.host))
        let plan = try await preparer.plan(context: project.context, engine: .rpgMakerMV)
        XCTAssertEqual(plan.action, .staticWeb)
        XCTAssertEqual(plan.routeID, "static.rpgmaker-mv-web")
        let prepared = try await preparer.prepare(makeRequest(project.context, .rpgMakerMV))
        XCTAssertFalse(try prepared.package.readResource(GameRelativePath("js/rpg_core.js")).isEmpty)
        XCTAssertFalse(try prepared.package.readResource(GameRelativePath("data/System.json")).isEmpty)
    }

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
