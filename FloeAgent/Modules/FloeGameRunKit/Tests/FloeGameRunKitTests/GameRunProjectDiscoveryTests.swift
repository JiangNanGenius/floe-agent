// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameWebKit
@testable import FloeGameRunKit

private actor DiscoveryRevisionChange: GameRunContextHost {
    var reads = 0
    func currentContext(for context: GameProjectContext) async throws -> GameProjectContext {
        reads += 1
        if reads == 1 { return context }
        return try GameProjectContext(projectID: context.projectID, owner: context.owner,
            rootURL: context.rootURL, savedRevision: "changed", environmentID: context.environmentID)
    }
}

final class GameRunProjectDiscoveryTests: XCTestCase {
    func testDefaultPreparationHasNoFixedTotalByteCeiling() {
        XCTAssertEqual(GameRunPreparationLimits.default.maximumProjectBytes, Int.max)
        XCTAssertEqual(GameRunPreparationLimits.default.maximumFileBytes, 64 * 1_024 * 1_024)
    }

    func testNestedDistinctGamesAndUnknownHTMLAreSeparateChoices() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "Bundle/Web/package.json": Data(#"{"dependencies":{"phaser":"3.90.0"}}"#.utf8),
            "Bundle/Web/index.html": Data("<!doctype html>".utf8),
            "Bundle/Legacy/Game.rvproj2": Data("VXAce".utf8),
            "Unknown/index.html": Data("<!doctype html>plain page".utf8),
            "node_modules/vendor/package.json": Data(#"{"dependencies":{"phaser":"3.90.0"}}"#.utf8)
        ])
        let stored = try await project.repository.open(project.projectID, owner: project.owner)
        let roots = try await GameRunProjectDiscovery(contexts: project.host)
            .discover(context: project.context, files: stored.files)
        XCTAssertEqual(roots.map(\.id), [".", "Bundle/Legacy", "Bundle/Web", "Unknown"])
        XCTAssertEqual(roots.first { $0.id == "Bundle/Web" }?.engines, [.phaser])
        XCTAssertEqual(roots.first { $0.id == "Bundle/Legacy" }?.engines, [.rpgMakerVXAce])
        XCTAssertEqual(roots.first { $0.id == "Unknown" }?.engines, [])
        XCTAssertTrue(roots[0].engines.isEmpty, "Outer directory must not impersonate a nested game")
    }

    func testMalformedMetadataDoesNotHideAnotherImportedGame() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "Bad/package.json": Data("{broken".utf8),
            "Good/Game.rxproj": Data("XP".utf8)
        ])
        let stored = try await project.repository.open(project.projectID, owner: project.owner)
        let roots = try await GameRunProjectDiscovery(contexts: project.host)
            .discover(context: project.context, files: stored.files)
        XCTAssertNotNil(roots.first { $0.id == "Bad" }?.diagnostic)
        XCTAssertEqual(roots.first { $0.id == "Good" }?.engines, [.rpgMakerXP])
        let reopened = try await project.repository.open(project.projectID, owner: project.owner)
        XCTAssertEqual(reopened.revision, stored.revision)
        XCTAssertEqual(reopened.files.count, 2)
    }

    func testRevisionChangeWhileDiscoveringCannotPublishStaleChoices() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace,
            files: ["Game.rxproj": Data("XP".utf8)])
        let stored = try await project.repository.open(project.projectID, owner: project.owner)
        do {
            _ = try await GameRunProjectDiscovery(contexts: DiscoveryRevisionChange())
                .discover(context: project.context, files: stored.files)
            XCTFail("Stale selection must be rejected")
        } catch GameProjectError.contextChanged(let change) { XCTAssertEqual(change, .revision) }
    }

    func testRootLimitRejectsInsteadOfSilentlyChoosingFirst() throws {
        let paths = try ["A/main.lua", "B/Game.rxproj"].map(GameRelativePath.init)
        XCTAssertThrowsError(try GameRunProjectDiscovery.candidateRoots(paths: paths, maximum: 2))
    }

    func testEngineSpecificParentMarkersResolveGameRoots() throws {
        let paths = try ["Unity/ProjectSettings/ProjectVersion.txt", "RenPy/game/script.rpy",
                         "XP/Data/System.rxdata", ".git/hidden/Game.rxproj"].map(GameRelativePath.init)
        let roots = try GameRunProjectDiscovery.candidateRoots(paths: paths, maximum: 10)
        XCTAssertEqual(roots.map { $0?.value ?? "." }, [".", "RenPy", "Unity", "XP"])
    }
}
