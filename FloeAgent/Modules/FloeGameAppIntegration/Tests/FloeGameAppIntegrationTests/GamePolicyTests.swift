// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameAppIntegration

final class GameSaveDestinationPolicyTests: XCTestCase {
    private let destinationID = UUID()

    private func destination(revision: String, engine: GameEngineID? = .phaser,
                             owner: GameProjectOwner? = nil) -> GameStoredProject {
        GameStoredProject(version: 1, projectID: destinationID,
            owner: owner ?? .space(recordID: destinationID),
            revision: revision, parent: nil, title: "Space", engine: engine,
            directories: [], files: [])
    }

    func testFirstExplicitSaveCreatesNewProject() {
        XCTAssertEqual(GameSaveDestinationPolicy.decide(sourceRevision: "s1", sourceEngine: .phaser,
                                                        destination: nil, link: nil), .createNewCopy)
    }

    func testUnchangedSourceAndDestinationAreIdempotent() {
        let link = GameSaveDestinationLink(destinationProjectID: destinationID,
            lastSourceRevision: "s1", lastDestinationRevision: "d1",
            sourceEngine: .phaser, destinationEngine: .phaser)
        XCTAssertEqual(GameSaveDestinationPolicy.decide(sourceRevision: "s1", sourceEngine: .phaser,
                                                        destination: destination(revision: "d1"), link: link),
                       .upToDate)
    }

    func testOnlySourceChangedUpdatesExistingCopy() {
        let link = GameSaveDestinationLink(destinationProjectID: destinationID,
            lastSourceRevision: "s1", lastDestinationRevision: "d1",
            sourceEngine: .phaser, destinationEngine: .phaser)
        XCTAssertEqual(GameSaveDestinationPolicy.decide(sourceRevision: "s2", sourceEngine: .phaser,
                                                        destination: destination(revision: "d1"), link: link),
                       .updateExistingCopy)
    }

    func testDestinationChangedRequiresExplicitChoice() {
        let link = GameSaveDestinationLink(destinationProjectID: destinationID,
            lastSourceRevision: "s1", lastDestinationRevision: "d1",
            sourceEngine: .phaser, destinationEngine: .phaser)
        let decision = GameSaveDestinationPolicy.decide(sourceRevision: "s1", sourceEngine: .phaser,
            destination: destination(revision: "d2"), link: link)
        XCTAssertEqual(decision, .requiresChoice([.updateExistingCopy, .saveAsNewProject]))
    }

    func testBothSidesChangedRequiresExplicitChoiceNotMerge() {
        let link = GameSaveDestinationLink(destinationProjectID: destinationID,
            lastSourceRevision: "s1", lastDestinationRevision: "d1",
            sourceEngine: .phaser, destinationEngine: .phaser)
        let decision = GameSaveDestinationPolicy.decide(sourceRevision: "s2", sourceEngine: .phaser,
            destination: destination(revision: "d2"), link: link)
        XCTAssertEqual(decision, .requiresChoice([.updateExistingCopy, .saveAsNewProject]))
    }

    func testEngineChangeNeverOverwritesAnExistingCopy() {
        let link = GameSaveDestinationLink(destinationProjectID: destinationID,
            lastSourceRevision: "s1", lastDestinationRevision: "d1",
            sourceEngine: .phaser, destinationEngine: .unity)
        guard case .requiresNewCopy = GameSaveDestinationPolicy.decide(sourceRevision: "s2",
            sourceEngine: .unity, destination: destination(revision: "d1", engine: .phaser), link: link) else {
            return XCTFail("Engine conversion must create a new conversion project")
        }
    }

    func testWrongOwnerCannotBeOverwritten() {
        let link = GameSaveDestinationLink(destinationProjectID: destinationID,
            lastSourceRevision: "s1", lastDestinationRevision: "d1",
            sourceEngine: .phaser, destinationEngine: .phaser)
        let value = destination(revision: "d1", owner: .conversation(conversationID: UUID(), workspaceID: UUID()))
        guard case .requiresNewCopy = GameSaveDestinationPolicy.decide(sourceRevision: "s2",
            sourceEngine: .phaser, destination: value, link: link) else {
            return XCTFail("A chat-owned destination is not a Space copy")
        }
    }

    func testLatePreferenceCannotReplaceNewerChoiceButCompletedCopyStands() {
        let older = GameSaveDestinationLink(destinationProjectID: UUID(), lastSourceRevision: "s1",
                                            lastDestinationRevision: "d1", sourceEngine: .phaser,
                                            destinationEngine: .phaser)
        let newer = GameSaveDestinationLink(destinationProjectID: UUID(), lastSourceRevision: "s1",
                                            lastDestinationRevision: "d1", sourceEngine: .phaser,
                                            destinationEngine: .phaser)
        XCTAssertFalse(GameSaveDestinationPolicy.mayReplaceLink(current: newer, expected: older))
        XCTAssertTrue(GameSaveDestinationPolicy.mayReplaceLink(current: older, expected: older))
    }
}

final class GameEngineLibraryTests: XCTestCase {
    func testBundledCatalogCoversExactlyTwentyEnginesAndPreservesChords() throws {
        let library = try GameEngineLibrary.bundled()
        XCTAssertEqual(library.entries.count, 20)
        XCTAssertEqual(Set(library.entries.map(\.engine)), Set(GameEngineID.allCases))
        XCTAssertEqual(library.catalogVersion, "1.0.0")
        for entry in library.entries {
            XCTAssertFalse(entry.displayName.isEmpty)
            XCTAssertFalse(entry.sourceLicense.isEmpty)
            XCTAssertFalse(entry.engineLicense.isEmpty)
            XCTAssertTrue(entry.expectedFileCount > 0)
        }
        let rpg = try library.entry(for: .rpgMakerXP)
        XCTAssertEqual(rpg.entry.value, "Game.rxproj")
        XCTAssertEqual(rpg.readiness, .sourceWithEditor)
        let renpy = try library.entry(for: .renpy)
        XCTAssertTrue(renpy.defaultButtons.contains { $0.id == "quicksave" && $0.keys == ["f5"] })
        XCTAssertFalse(renpy.chordButtons.contains { $0.id == "quicksave" })
    }

    func testRuntimePackEnginesAreListedAsMissingPreparedPackNotInstalled() throws {
        let library = try GameEngineLibrary.bundled()
        let required = Set(library.entries.filter(\.requiresPreparedRuntimePack).map(\.engine))
        XCTAssertEqual(required, [.phaser, .kaplay, .babylon, .playcanvas])
        for engine in required {
            let entry = try library.entry(for: engine)
            XCTAssertNotNil(entry.runtimePackID)
            XCTAssertGreaterThan(entry.runtimePackFileCount, 0)
            XCTAssertFalse(entry.prerequisiteSummary.isEmpty)
        }
    }

    func testRecognitionNeverAcceptsARecordedEngineMissingFromTheTree() throws {
        let library = try GameEngineLibrary.bundled()
        let root = FileManager.default.temporaryDirectory
        let candidate = GameEngineCandidate(engine: .godot, evidence: [
            .init(path: try GameRelativePath("project.godot"), kind: .projectMarker)
        ])
        let inspection = GameProjectInspection(rootURL: root, context: nil,
            candidates: [candidate], inspectedPaths: [try GameRelativePath("project.godot")])
        XCTAssertEqual(library.recognizedEngine(in: inspection, preferred: .godot), .godot)
        XCTAssertNil(library.recognizedEngine(in: inspection, preferred: .unity))
        XCTAssertEqual(library.recognizedEngine(in: inspection), .godot)
    }

    func testOverviewOnlyShowsPrimaryActionsForARealSelectedEngine() {
        let empty = GameProjectOverviewState(state: .emptyProject, engine: nil, selectedRoot: nil,
            identifiedEngines: [], roots: [], hasFiles: false, status: nil)
        XCTAssertFalse(empty.showsPrimaryActions)
        let ambiguous = GameProjectOverviewState(state: .needsExplicitChoice, engine: nil,
            selectedRoot: nil, identifiedEngines: [.godot, .unity], roots: [".", "nested"],
            hasFiles: true, status: nil)
        XCTAssertTrue(ambiguous.requiresExplicitSelection)
        XCTAssertFalse(ambiguous.canPlay)
        let ready = GameProjectOverviewState(state: .ready, engine: .godot, selectedRoot: ".",
            identifiedEngines: [.godot], roots: ["."], hasFiles: true, status: nil)
        XCTAssertTrue(ready.showsPrimaryActions)
        XCTAssertTrue(ready.canQuickEdit && ready.canOpenIDE && ready.canPlay && ready.canUseAI)
    }
}

final class GameEditorPresentationTests: XCTestCase {
    func testRPGMapSpriteNarrativeAndBinaryClassification() throws {
        let files = ["Data/Map001.rxdata", "img/pictures/hero.png", "Audio/BGM/theme.ogg",
                     "Scripts/Game.rb", "game/script.rpy", "story.ink", "data/System.json", "cart.wasm",
                     "floe-inputs.json"]
        let paths = try files.map(GameRelativePath.init)
        let project = GameStoredProject(version: 1, projectID: UUID(),
            owner: .space(recordID: UUID()), revision: UUID().uuidString.lowercased(),
            parent: nil, title: "p", engine: .rpgMakerXP, directories: [],
            files: paths.map { .init(path: $0, sha256: String(repeating: "0", count: 64), bytes: 1) })
        XCTAssertEqual(GameEditorPresentation.classify(path: paths[0], engine: .rpgMakerXP, project: project), .tileMap)
        XCTAssertEqual(GameEditorPresentation.classify(path: paths[1], engine: .rpgMakerXP, project: project), .sprite)
        XCTAssertEqual(GameEditorPresentation.classify(path: paths[2], engine: .rpgMakerXP, project: project), .audio)
        XCTAssertEqual(GameEditorPresentation.classify(path: paths[3], engine: .rpgMakerXP, project: project), .code)
        XCTAssertEqual(GameEditorPresentation.classify(path: paths[4], engine: .renpy, project: project), .code)
        XCTAssertEqual(GameEditorPresentation.classify(path: paths[5], engine: .ink, project: project), .narrative)
        XCTAssertEqual(GameEditorPresentation.classify(path: paths[6], engine: .rpgMakerMZ, project: project), .parameterForm)
        XCTAssertEqual(GameEditorPresentation.classify(path: paths[7], engine: .wasm4, project: project), .binary)
        XCTAssertEqual(GameEditorPresentation.classify(path: paths[8], engine: .godot, project: project), .parameterForm)
        XCTAssertEqual(GameEditorPresentation.preferredEntry(project: project, engine: .rpgMakerXP)?.path, paths[0])
    }

    func testUnknownFilesRemainVisibleForIDEHandoff() throws {
        let path = try GameRelativePath("custom/asset.xyz")
        let project = GameStoredProject(version: 1, projectID: UUID(),
            owner: .space(recordID: UUID()), revision: UUID().uuidString.lowercased(),
            parent: nil, title: "p", engine: .godot, directories: [],
            files: [.init(path: path, sha256: String(repeating: "0", count: 64), bytes: 3)])
        let entries = GameEditorPresentation.entries(project: project, engine: .godot)
        XCTAssertEqual(entries.map(\.path), [path])
        XCTAssertEqual(entries.first?.kind, .unsupported)
        XCTAssertFalse(GameEditorPresentation.offersNativeSurface(.unsupported))
    }
}
