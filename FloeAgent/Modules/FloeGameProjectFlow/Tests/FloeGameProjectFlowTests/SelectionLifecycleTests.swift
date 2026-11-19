// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameIDEBridge
import FloeGameStarterKit
@testable import FloeGameProjectFlow

final class SelectionLifecycleTests: XCTestCase {
    private func nestedAmbiguousFiles() -> [String: Data] {
        [
            "Web/package.json": Data(
                "{\"dependencies\":{\"phaser\":\"3.90.0\"}}".utf8),
            "Web/index.html": Data("<!doctype html>".utf8),
            "Legacy/Game.rvproj2": Data("VXAce".utf8),
            "Unknown/readme.txt": Data("unknown nested content".utf8)
        ]
    }

    func testLauncherHTMLDoesNotHideTheOnlyRecognizedGame() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles([
                "index.html": Data("<title>Launcher</title>".utf8),
                "www/Game.rpgproject": Data("RPGMV 1.6.2".utf8),
                "www/js/rpg_core.js": Data("var RPGMAKER_NAME = 'MV';".utf8),
                "www/data/System.json": Data("{}".utf8)
            ])
            XCTAssertEqual(result.snapshot.state, .automatic)
            XCTAssertEqual(result.snapshot.runSelection?.engine, .rpgMakerMV)
            XCTAssertEqual(result.snapshot.runSelection?.gameRoot?.value, "www")
        }
    }

    func testEmptyProjectAndRecordedEngineNeverClaimSelection() async throws {
        try await withSelectionWorkspace { workspace in
            let created = try await workspace.createEmpty()
            let snapshot = try await workspace.coordinator.refresh(
                project: created.0, context: created.1)
            XCTAssertEqual(snapshot.state, .empty)
            XCTAssertTrue(snapshot.isEmptyProject)
            XCTAssertNil(snapshot.selectedEngine)
            XCTAssertNil(snapshot.recordedEngine)
            XCTAssertNil(snapshot.runSelection)
            XCTAssertFalse(snapshot.persisted)
        }
        try await withSelectionWorkspace { workspace in
            let created = try await workspace.createEmpty(engine: .godot)
            let snapshot = try await workspace.coordinator.refresh(
                project: created.0, context: created.1)
            XCTAssertEqual(snapshot.state, .empty)
            XCTAssertEqual(snapshot.recordedEngine, .godot)
            XCTAssertNil(snapshot.selectedEngine,
                         "a recorded creation hint is not a recognized selection")
            XCTAssertNil(snapshot.runSelection)
        }
    }

    func testCreateThenImportIsExplicitAndNeverSeedsStarterFiles() async throws {
        try await withSelectionWorkspace { workspace in
            let files: [String: Data] = [
                "Game.rxproj": Data("XP".utf8),
                "assets/unknown.bin": Data([0, 255, 1, 127]),
                "docs/readme.txt": Data("keep me".utf8)
            ]
            let result = try await workspace.importFiles(files)
            let paths = Set(result.project.files.map(\.path.value))
            XCTAssertEqual(paths, Set(files.keys))
            XCTAssertFalse(paths.contains("floe-game.json"))
            XCTAssertFalse(paths.contains("floe-inputs.json"))
            XCTAssertEqual(result.snapshot.state, .automatic)
            XCTAssertEqual(result.snapshot.selectedEngine, .rpgMakerXP)
            XCTAssertTrue(result.snapshot.persisted)
            let history = try await workspace.repository.history(
                workspace.projectID, owner: workspace.owner)
            XCTAssertEqual(history.count, 2)
            XCTAssertEqual(history[1].files.count, 0)
            XCTAssertEqual(result.project.parent, history[1].revision)
            let bytes = try await workspace.repository.read(
                workspace.projectID, owner: workspace.owner,
                revision: result.project.revision,
                path: try GameRelativePath("assets/unknown.bin"))
            XCTAssertEqual(bytes, Data([0, 255, 1, 127]))
        }
    }

    func testImportRecognitionWinsOverTheCreationHint() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(
                ["Game.rxproj": Data("XP".utf8)], engine: .unity)
            XCTAssertEqual(result.project.engine, .unity)
            XCTAssertEqual(result.snapshot.recordedEngine, .unity)
            XCTAssertEqual(result.snapshot.selectedEngine, .rpgMakerXP)
            XCTAssertEqual(result.snapshot.state, .automatic)
        }
    }

    func testAmbiguousNestedRootsRequireExplicitSelectionAndPersistIt() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(nestedAmbiguousFiles())
            XCTAssertEqual(result.snapshot.state, .ambiguous)
            XCTAssertNil(result.snapshot.selectedEngine)
            XCTAssertTrue(result.snapshot.requiresExplicitChoice)
            XCTAssertTrue(result.snapshot.ambiguities.contains {
                if case .multipleRoots = $0 { return true }
                return false
            })
            XCTAssertNil(result.snapshot.runSelection)
            XCTAssertThrowsError(try result.snapshot.requireRunSelection())
            let noRecord = try await workspace.storedRecord(context: result.context)
            XCTAssertNil(noRecord)

            let web = try GameRelativePath("Web")
            do {
                _ = try await workspace.coordinator.select(
                    root: web, engine: .unity, context: result.context)
                XCTFail("unrecognized engine override was accepted")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .engineNotRecognized(root: web,
                                                           engine: .unity))
            }
            let missing = try GameRelativePath("Missing")
            do {
                _ = try await workspace.coordinator.select(
                    root: missing, engine: .phaser, context: result.context)
                XCTFail("missing root was accepted")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .rootNotAvailable(missing))
            }
            let selected = try await workspace.coordinator.select(
                root: web, engine: .phaser, context: result.context)
            XCTAssertEqual(selected.state, .confirmed)
            XCTAssertEqual(selected.selectionSource, .explicit)
            XCTAssertEqual(selected.selectedRoot?.value, web.value)
            XCTAssertEqual(selected.selectedEngine, .phaser)
            XCTAssertTrue(selected.persisted)
            XCTAssertEqual(selected.runSelection?.engine, .phaser)
            XCTAssertEqual(selected.runSelection?.gameRoot, web)
            let record = try await workspace.storedRecord(context: result.context)
            XCTAssertEqual(record?.selectedRoot?.value, web.value)
            XCTAssertEqual(record?.selectedEngine, .phaser)
        }
    }

    func testAmbiguousEnginesAndAISuggestionRemainAdvisory() async throws {
        let recommender: GameProjectSelectionRecommendationHandler = { _ in
            GameProjectAIEngineRecommendation(
                engine: .godot, root: nil,
                rationale: "fixture model choice", generatedBy: "fixture-model")
        }
        try await withSelectionWorkspace(recommender: recommender) { workspace in
            let files: [String: Data] = [
                "project.godot": Data("config_version=5\n".utf8),
                "package.json": Data(
                    "{\"dependencies\":{\"phaser\":\"3.90.0\"}}".utf8)
            ]
            let result = try await workspace.importFiles(files)
            XCTAssertEqual(result.snapshot.state, .ambiguous)
            XCTAssertNil(result.snapshot.selectedEngine)
            XCTAssertEqual(result.snapshot.aiRecommendation?.engine, .godot)
            XCTAssertEqual(result.snapshot.aiRecommendation?.generatedBy,
                           "fixture-model")
            XCTAssertNotNil(result.snapshot.heuristicRecommendation)
            let record = try await workspace.storedRecord(context: result.context)
            XCTAssertNil(record, "AI advice must not become a persisted selection")

            let overridden = try await workspace.coordinator.select(
                root: nil, engine: .phaser, context: result.context)
            XCTAssertEqual(overridden.state, .confirmed)
            XCTAssertEqual(overridden.selectedEngine, .phaser)
            XCTAssertEqual(overridden.selectionSource, .explicit)
            XCTAssertEqual(overridden.aiRecommendation?.engine, .godot)
            let stored = try await workspace.storedRecord(context: result.context)
            XCTAssertEqual(stored?.selectedEngine, .phaser)
        }
    }

    func testHeuristicIsNeverExposedAsAI() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(nestedAmbiguousFiles())
            XCTAssertEqual(result.snapshot.state, .ambiguous)
            XCTAssertNil(result.snapshot.aiRecommendation)
            XCTAssertNotNil(result.snapshot.heuristicRecommendation)
        }
    }

    func testPersistedChoiceSurvivesRevalidationWhenItStillMatches() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(
                ["Game.rxproj": Data("XP".utf8)])
            let committed = try await workspace.repository.commit(
                workspace.projectID, owner: workspace.owner,
                expectedRevision: result.project.revision,
                changes: [.write(try GameRelativePath("notes.txt"),
                                 Data("unrelated save".utf8))])
            let newContext = try await workspace.context()
            XCTAssertEqual(newContext.savedRevision, committed.revision)
            let refreshed = try await workspace.coordinator.refresh(
                project: committed, context: newContext)
            XCTAssertEqual(refreshed.state, .confirmed)
            XCTAssertEqual(refreshed.selectionSource, .restored)
            XCTAssertEqual(refreshed.selectedEngine, .rpgMakerXP)
            XCTAssertTrue(refreshed.persisted)
            let record = try await workspace.storedRecord(context: newContext)
            XCTAssertEqual(record?.selectedEngine, .rpgMakerXP)
            XCTAssertEqual(record?.baseRevision, committed.revision)
        }
    }

    func testPersistedChoiceInvalidatedWhenItsEngineDisappears() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(
                ["Game.rxproj": Data("XP".utf8)])
            let recordBefore = try await workspace.storedRecord(
                context: result.context)
            XCTAssertEqual(recordBefore?.selectedEngine, .rpgMakerXP)

            let committed = try await workspace.repository.commit(
                workspace.projectID, owner: workspace.owner,
                expectedRevision: result.project.revision,
                changes: [
                    .remove(try GameRelativePath("Game.rxproj")),
                    .write(try GameRelativePath("project.godot"),
                           Data("config_version=5\n".utf8))
                ])
            let newContext = try await workspace.context()
            XCTAssertEqual(newContext.savedRevision, committed.revision)
            let refreshed = try await workspace.coordinator.refresh(
                project: committed, context: newContext)
            XCTAssertEqual(refreshed.selectedEngine, .godot)
            XCTAssertEqual(refreshed.state, .automatic)
            XCTAssertTrue(refreshed.ambiguities.contains {
                if case .persistedSelectionInvalidated = $0 { return true }
                return false
            })
            let recordAfter = try await workspace.storedRecord(
                context: newContext)
            XCTAssertEqual(recordAfter?.selectedEngine, .godot)
        }
    }

    func testPersistedChoiceIsRestoredByANewCoordinator() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(nestedAmbiguousFiles())
            let web = try GameRelativePath("Web")
            _ = try await workspace.coordinator.select(
                root: web, engine: .phaser, context: result.context)
            let second = try GameProjectSelectionCoordinator(
                scaffolder: workspace.scaffolder, contexts: workspace.host,
                store: workspace.store)
            let restored = try await second.refresh(
                project: result.project, context: result.context)
            XCTAssertEqual(restored.state, .confirmed)
            XCTAssertEqual(restored.selectionSource, .restored)
            XCTAssertEqual(restored.selectedRoot?.value, web.value)
            XCTAssertEqual(restored.selectedEngine, .phaser)
            XCTAssertTrue(restored.persisted)
        }
    }

    func testStaleProjectAndStaleContextAreRejected() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(
                ["Game.rxproj": Data("XP".utf8)])
            let committed = try await workspace.repository.commit(
                workspace.projectID, owner: workspace.owner,
                expectedRevision: result.context.savedRevision,
                changes: [.write(try GameRelativePath("later.txt"),
                                 Data("later".utf8))])
            do {
                _ = try await workspace.coordinator.refresh(
                    project: result.project, context: result.context)
                XCTFail("stale project was accepted")
            } catch let error as GameProjectFlowError {
                guard case .staleProject = error else {
                    XCTFail("wrong error \(error)"); return
                }
            }

            let newContext = try await workspace.context()
            XCTAssertEqual(newContext.savedRevision, committed.revision)
            do {
                _ = try await workspace.coordinator.refresh(
                    project: result.project, context: result.context)
                XCTFail("stale revision context was accepted")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .staleContext(.revision))
            }

            let environment = try await workspace.host.contextChangingEnvironment(
                newContext, to: "another-environment")
            do {
                _ = try await workspace.coordinator.refresh(
                    project: committed, context: environment)
                XCTFail("changed environment was accepted")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .staleContext(.environment))
            }

            let owner = try await workspace.host.contextChangingOwner(
                newContext, to: .conversation(conversationID: UUID(),
                                              workspaceID: UUID()))
            do {
                _ = try await workspace.coordinator.refresh(
                    project: committed, context: owner)
                XCTFail("changed owner was accepted")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .wrongOwner)
            }

            let root = try await workspace.host.contextChangingRoot(
                newContext,
                to: workspace.root.appendingPathComponent("Elsewhere"))
            do {
                _ = try await workspace.coordinator.refresh(
                    project: committed, context: root)
                XCTFail("changed root was accepted")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .staleContext(.root))
            }
        }
    }

    func testIndependentOwnersDoNotShareSelections() async throws {
        try await withSelectionWorkspace { workspace in
            let files = nestedAmbiguousFiles()
            let idA = UUID()
            let idB = UUID()
            let idC = UUID()
            let ownerA = GameProjectOwner.space(recordID: idA)
            let ownerB = GameProjectOwner.space(recordID: idB)
            let ownerC = GameProjectOwner.conversation(
                conversationID: UUID(), workspaceID: UUID())
            let a = try await workspace.importFor(
                projectID: idA, owner: ownerA, files: files)
            let b = try await workspace.importFor(
                projectID: idB, owner: ownerB, files: files)
            let c = try await workspace.importFor(
                projectID: idC, owner: ownerC, files: files)
            let web = try GameRelativePath("Web")
            let legacy = try GameRelativePath("Legacy")
            _ = try await workspace.coordinator.select(
                root: web, engine: .phaser, context: a.context)
            _ = try await workspace.coordinator.select(
                root: legacy, engine: .rpgMakerVXAce, context: b.context)

            let refreshedA = try await workspace.coordinator.refresh(
                project: a.project, context: a.context)
            let refreshedB = try await workspace.coordinator.refresh(
                project: b.project, context: b.context)
            let refreshedC = try await workspace.coordinator.refresh(
                project: c.project, context: c.context)
            XCTAssertEqual(refreshedA.selectedEngine, .phaser)
            XCTAssertEqual(refreshedA.selectedRoot?.value, web.value)
            XCTAssertEqual(refreshedB.selectedEngine, .rpgMakerVXAce)
            XCTAssertEqual(refreshedB.selectedRoot?.value, legacy.value)
            XCTAssertEqual(refreshedC.state, .ambiguous)
            XCTAssertNil(refreshedC.selectedEngine)
            let recordC = try await workspace.storedRecord(context: c.context)
            XCTAssertNil(recordC, "another owner's selection must not leak")
        }
    }

    func testCancellationBeforeImportKeepsTheEmptyProjectAndNoSelection() async throws {
        try await withSelectionWorkspace(beforeImport: {
            throw GameStarterError.cancelled
        }) { workspace in
            let created = try await workspace.createEmpty()
            do {
                _ = try await workspace.coordinator.createEngineProject(
                    emptyProject: created.0, context: created.1, engine: .godot)
                XCTFail("cancelled starter creation succeeded")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .starter(.cancelled))
            }
            let reopened = try await workspace.repository.open(
                workspace.projectID, owner: workspace.owner)
            XCTAssertTrue(reopened.files.isEmpty)
            XCTAssertTrue(reopened.directories.isEmpty)
            let record = try await workspace.storedRecord(context: created.1)
            XCTAssertNil(record)
        }
    }

    func testPreCancelledSelectDoesNotPersist() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(nestedAmbiguousFiles())
            let web = try GameRelativePath("Web")
            let task = Task {
                try await workspace.coordinator.select(
                    root: web, engine: .phaser, context: result.context)
            }
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("cancelled select returned a selection")
            } catch is CancellationError {
            }
            let record = try await workspace.storedRecord(context: result.context)
            XCTAssertNil(record)
        }
    }

    func testEngineChangeForkIsNonDestructiveAndKeepsAdministrativeFiles() async throws {
        try await withSelectionWorkspace { workspace in
            let files: [String: Data] = [
                "Game.rxproj": Data("XP".utf8),
                ".git/config": Data("[core]\n\trepositoryformatversion = 0\n".utf8),
                "Data/unknown.bin": Data([9, 8, 7, 0, 255])
            ]
            let result = try await workspace.importFiles(files)
            let historyBefore = try await workspace.repository.history(
                workspace.projectID, owner: workspace.owner)
            let newID = UUID()
            let target = try GameProjectForkTarget(
                projectID: newID,
                owner: .space(recordID: newID),
                title: "Fork to Godot",
                engine: .godot)
            let preparation = try await workspace.coordinator
                .prepareEngineChangeFork(from: result.project,
                                         context: result.context, to: target)
            XCTAssertEqual(preparation.targetEngine, .godot)
            XCTAssertEqual(preparation.conversion,
                           .explicitManualConversionRequired)
            XCTAssertTrue(preparation.steps.contains(
                .convertOrRecreateWithTargetEngine))
            XCTAssertEqual(preparation.newProject.projectID, newID)
            XCTAssertEqual(preparation.newProject.owner, target.owner)
            XCTAssertEqual(preparation.newProject.files, result.project.files)
            XCTAssertEqual(preparation.copiedFileCount,
                           result.project.files.count)

            let sourceAfter = try await workspace.repository.open(
                workspace.projectID, owner: workspace.owner)
            XCTAssertEqual(sourceAfter.revision, result.project.revision)
            XCTAssertEqual(sourceAfter.files, result.project.files)
            let historyAfter = try await workspace.repository.history(
                workspace.projectID, owner: workspace.owner)
            XCTAssertEqual(historyAfter, historyBefore)

            let copiedGit = try await workspace.repository.read(
                newID, owner: target.owner,
                revision: preparation.newProject.revision,
                path: try GameRelativePath(".git/config"))
            let expectedGit = try XCTUnwrap(files[".git/config"])
            XCTAssertEqual(copiedGit, expectedGit)
            let copiedBinary = try await workspace.repository.read(
                newID, owner: target.owner,
                revision: preparation.newProject.revision,
                path: try GameRelativePath("Data/unknown.bin"))
            let expectedBinary = try XCTUnwrap(files["Data/unknown.bin"])
            XCTAssertEqual(copiedBinary, expectedBinary)
            let newHistory = try await workspace.repository.history(
                newID, owner: target.owner)
            XCTAssertEqual(newHistory.count, 1)
        }
    }

    func testRunSelectionValidatesWorkspaceAndRevision() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(
                ["Game.rxproj": Data("XP".utf8)])
            let run = try await workspace.coordinator.currentRunSelection(
                project: result.project, context: result.context)
            XCTAssertEqual(run.engine, .rpgMakerXP)
            XCTAssertNil(run.gameRoot)
            XCTAssertEqual(run.baseRevision, result.project.revision)
            let pin = try GameIDEWorkspacePin(workspaceID: UUID(),
                                              context: result.context)
            XCTAssertNoThrow(try run.validate(workspace: pin,
                                              context: result.context))

            let changedEnvironment = try await workspace.host
                .contextChangingEnvironment(result.context, to: "other")
            XCTAssertThrowsError(try run.validate(context: changedEnvironment)) {
                XCTAssertEqual($0 as? GameProjectFlowError, .invalidContext)
            }
            let changedRevision = try GameProjectContext(
                projectID: result.context.projectID,
                owner: result.context.owner,
                rootURL: result.context.rootURL,
                savedRevision: UUID().uuidString.lowercased(),
                environmentID: result.context.environmentID)
            XCTAssertThrowsError(try run.validate(context: changedRevision)) {
                XCTAssertEqual($0 as? GameProjectFlowError,
                               .staleContext(.revision))
            }
        }
    }
}
