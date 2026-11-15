// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameAppIntegration

final class GameToolContractsTests: XCTestCase {
    func testInspectAcceptsExistingArgumentsAndBoundsDirectoryPages() throws {
        let legacy = try JSONDecoder().decode(GameInspectArguments.self, from: Data(#"{"includeFiles":true}"#.utf8))
        XCTAssertNoThrow(try legacy.validate())
        XCTAssertNil(legacy.offset)
        XCTAssertNoThrow(try GameInspectArguments(root: "data", includeFiles: true, offset: 200, limit: 200).validate())
        XCTAssertThrowsError(try GameInspectArguments(root: "../other", includeFiles: true).validate())
        XCTAssertThrowsError(try GameInspectArguments(offset: -1).validate())
        XCTAssertThrowsError(try GameInspectArguments(limit: 201).validate())
    }

    func testValidEditAcceptsWritesRemovalsAndMoves() throws {
        let projectID = UUID()
        let arguments = GameEditArguments(projectID: projectID, expectedRevision: "rev",
            operations: [
                GameEditOperation(write: "src/main.js", text: "console.log('hi')"),
                GameEditOperation(move: "src/old.js", to: "src/new.js"),
                GameEditOperation(remove: "src/dead.js")
            ])
        XCTAssertNoThrow(try arguments.validate())
    }

    func testTraversalAbsoluteAndDuplicatePathsAreRejected() throws {
        for value in ["../escape", "/etc/passwd", "a/../../b", "a\\b", "a:b", ".."] {
            let arguments = GameEditArguments(projectID: UUID(), expectedRevision: "rev",
                operations: [GameEditOperation(write: value, text: "x")])
            XCTAssertThrowsError(try arguments.validate(), "path \(value) must be rejected")
        }
        let duplicate = GameEditArguments(projectID: UUID(), expectedRevision: "rev",
            operations: [
                GameEditOperation(write: "same.txt", text: "a"),
                GameEditOperation(write: "same.txt", text: "b")
            ])
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testEditBoundsAndRequiredRevision() throws {
        let tooMany = (0..<65).map { GameEditOperation(write: "f\($0).txt", text: "x") }
        XCTAssertThrowsError(try GameEditArguments(projectID: UUID(), expectedRevision: "rev",
            operations: tooMany).validate())
        XCTAssertThrowsError(try GameEditArguments(projectID: UUID(), expectedRevision: " ",
            operations: [GameEditOperation(write: "a.txt", text: "x")]).validate())
        let big = String(repeating: "a", count: 2 * 1_024 * 1_024 + 1)
        XCTAssertThrowsError(try GameEditArguments(projectID: UUID(), expectedRevision: "rev",
            operations: [GameEditOperation(write: "a.txt", text: big)]).validate())
    }

    func testChordsAreExplicitAndNotAFlattenedAlternativeList() throws {
        let chord = GameInputArguments(projectID: UUID(), action: .chord,
            keys: ["shift", "z"], durationMilliseconds: 80)
        XCTAssertNoThrow(try chord.validate())
        let alternativesAsChord = GameInputArguments(projectID: UUID(), action: .chord,
            keys: ["z", "shift", "enter", "space", "c", "x", "q", "w", "e"], durationMilliseconds: 80)
        XCTAssertThrowsError(try alternativesAsChord.validate())
        let empty = GameInputArguments(projectID: UUID(), action: .chord, keys: [])
        XCTAssertThrowsError(try empty.validate())
        let action = GameInputArguments(projectID: UUID(), action: .action, actionName: "confirm")
        XCTAssertNoThrow(try action.validate())
        let unknown = GameInputArguments(projectID: UUID(), action: .action, actionName: "cheat")
        XCTAssertThrowsError(try unknown.validate())
    }

    func testReadAndHistoryBounds() throws {
        XCTAssertNoThrow(try GameReadArguments(projectID: UUID(), path: "src/main.js",
            offset: 0, limit: 128 * 1_024).validate())
        XCTAssertThrowsError(try GameReadArguments(projectID: UUID(), path: "src/main.js",
            offset: -1, limit: 10).validate())
        XCTAssertThrowsError(try GameReadArguments(projectID: UUID(), path: "src/main.js",
            offset: 0, limit: 0).validate())
        XCTAssertThrowsError(try GameHistoryArguments(projectID: UUID(), limit: 33).validate())
    }

    func testCreateAndBuildContractsDoNotAcceptHostAuthority() throws {
        let source = try GameToolOutput.encode(GameCreateArguments(title: "My game", engine: .godot))
        XCTAssertFalse(source.contains("owner"))
        XCTAssertFalse(source.contains("environment"))
        XCTAssertNoThrow(try GameCreateArguments(title: "My game", engine: .godot).validate())
        XCTAssertThrowsError(try GameCreateArguments(title: "", engine: .godot).validate())
        XCTAssertThrowsError(try GameCreateArguments(title: "x", engine: .godot,
            note: String(repeating: "n", count: 4_097)).validate())
        XCTAssertNoThrow(try GameBuildArguments(projectID: UUID(), engine: .godot, output: .web,
            routeIDs: ["godot-web"]).validate())
    }

    func testResultShapesRoundTripWithoutAbsolutePaths() throws {
        let page = GameFileListResult(revision: "rev", directory: ".",
            entries: [.init(path: try GameRelativePath("a.txt"), isDirectory: false, bytes: 1, sha256: "0")],
            offset: 0, nextOffset: nil, totalEntries: 1)
        let encoded = try GameToolOutput.encode(page)
        XCTAssertTrue(encoded.contains("a.txt"))
        XCTAssertFalse(encoded.contains("/Users/"))
        XCTAssertFalse(encoded.contains("file://"))
        let decoded = try JSONDecoder().decode(GameFileListResult.self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded, page)
    }
}

final class GameBuildArtifactPolicyTests: XCTestCase {
    func testSourceWebNativeProjectAndInstallerAreDistinct() {
        XCTAssertEqual(GameBuildArtifactPolicy.kind(routeID: "godot-source",
            artifactName: "godot-source.zip", kindHint: "sourceArchive", platform: nil), .sourceArchive)
        XCTAssertEqual(GameBuildArtifactPolicy.kind(routeID: "godot-web",
            artifactName: "godot-web.zip", kindHint: "webBundle", platform: "web"), .webBundle)
        XCTAssertEqual(GameBuildArtifactPolicy.kind(routeID: "cocos-android-project",
            artifactName: "cocos-android-project.zip", kindHint: "nativeProject", platform: "android"), .nativeProject)
        XCTAssertEqual(GameBuildArtifactPolicy.kind(routeID: "cocos-android-apk",
            artifactName: "cocos-android.apk", kindHint: "nativeInstaller", platform: "android"), .nativeInstaller)
        XCTAssertTrue(GameBuildArtifactKind.nativeInstaller.isInstallablePackage)
        XCTAssertFalse(GameBuildArtifactKind.sourceArchive.isInstallablePackage)
        XCTAssertFalse(GameBuildArtifactKind.nativeProject.isPlayableInApp)
        XCTAssertTrue(GameBuildArtifactKind.webBundle.isPlayableInApp)
    }

    func testDefaultSelectionPrefersPlayableWebOverSourceAndInstaller() {
        let source = GameBuildOption(id: "source", artifactName: "game-source.zip",
            kind: .sourceArchive, producer: "onDevice", platform: nil, playable: false, executed: false)
        let web = GameBuildOption(id: "web", artifactName: "game-web.zip",
            kind: .webBundle, producer: "githubCI", platform: "web", playable: true, executed: false)
        let apk = GameBuildOption(id: "apk", artifactName: "game.apk",
            kind: .nativeInstaller, producer: "githubCI", platform: "android", playable: false, executed: false)
        XCTAssertEqual(GameBuildArtifactPolicy.defaultSelection(from: [apk, source, web]), web)
        XCTAssertEqual(GameBuildArtifactPolicy.options(from: [apk, source, web]), [web, source, apk])
        XCTAssertFalse(GameBuildArtifactPolicy.isReady(requested: [web], verifiedArtifactNames: []))
        XCTAssertTrue(GameBuildArtifactPolicy.isReady(requested: [web], verifiedArtifactNames: ["game-web.zip"]))
    }

    func testInstrumentationDisclosureIsExplicit() {
        XCTAssertNil(GameBuildArtifactPolicy.exportDisclosure(developerInstrumentationInstalled: false,
                                                              sourceBundleAttached: false))
        let warning = GameBuildArtifactPolicy.exportDisclosure(developerInstrumentationInstalled: true,
                                                               sourceBundleAttached: false)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("source bundle"))
        let complete = GameBuildArtifactPolicy.exportDisclosure(developerInstrumentationInstalled: true,
                                                                sourceBundleAttached: true)
        XCTAssertNotNil(complete)
        XCTAssertTrue(complete!.contains("source bundle is attached"))
    }
}
