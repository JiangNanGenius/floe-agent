// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameStarterKit
@testable import FloeGameProjectFlow

final class SelectionCatalogTests: XCTestCase {
    private static let runtimePackEngines: Set<GameEngineID> =
        [.phaser, .kaplay, .babylon, .playcanvas]

    func testCreationCatalogCoversExactlyAllTwentyEngines() async throws {
        try await withSelectionWorkspace { workspace in
            let capabilities = try workspace.coordinator.creationCapabilities()
            XCTAssertEqual(capabilities.count, 20)
            XCTAssertEqual(Set(capabilities.map(\.engine)), Set(GameEngineID.authoringEngines))
            for capability in capabilities {
                let descriptor = try workspace.catalog.descriptor(for: capability.engine)
                XCTAssertEqual(capability.displayName, descriptor.displayName)
                XCTAssertEqual(capability.starterReadiness, descriptor.readiness)
                XCTAssertEqual(capability.prerequisites.count,
                               descriptor.prerequisites.count)
                XCTAssertTrue(capability.prerequisites.allSatisfy { state in
                    if case .unverified = state.host { return true }
                    return false
                }, capability.engine.rawValue)
                if descriptor.runtimePack == nil {
                    XCTAssertNil(capability.preparedRuntimePackPresent)
                } else {
                    XCTAssertNotNil(capability.preparedRuntimePackPresent)
                }
                XCTAssertEqual(capability.engineLicense, descriptor.engineLicense)
            }
        }
    }

    func testEveryImportedEngineMarkerIsRecognizedWithoutSeeding() async throws {
        for engine in GameEngineID.authoringEngines {
            try await withSelectionWorkspace { workspace in
                let files: [String: Data] = [
                    "floe-game.json": Data(
                        "{\"engine\":\"\(engine.rawValue)\"}".utf8),
                    "data/asset.bin": Data([0, 1, 2, 255])
                ]
                let result = try await workspace.importFiles(files)
                XCTAssertEqual(result.snapshot.selectedEngine, engine,
                               engine.rawValue)
                XCTAssertEqual(result.snapshot.state, .automatic,
                               engine.rawValue)
                XCTAssertNil(result.snapshot.selectedRoot)
                XCTAssertTrue(result.snapshot.persisted)
                XCTAssertFalse(result.snapshot.choices.contains(where: { choice in
                    choice.engines.contains(where: { $0.engine != engine })
                }), engine.rawValue)
                XCTAssertEqual(Set(result.project.files.map(\.path.value)),
                               Set(files.keys), engine.rawValue)
                XCTAssertFalse(result.project.files.contains(where: {
                    $0.path.value == "floe-inputs.json"
                }), engine.rawValue)
                let record = try await workspace.storedRecord(
                    context: result.context)
                XCTAssertEqual(record?.selectedEngine, engine)
                XCTAssertNil(record?.selectedRoot)
            }
        }
    }

    func testEveryBundledStarterCreatesAndPersistsAnExplicitSelection() async throws {
        let catalog = try GameStarterCatalog.bundled()
        let engines = catalog.engines
            .filter { !Self.runtimePackEngines.contains($0.engine) }
            .map(\.engine)
        XCTAssertEqual(engines.count, 16)
        for engine in engines {
            try await withSelectionWorkspace { workspace in
                let result = try await workspace.seed(
                    engine: engine, title: "QA " + engine.rawValue)
                XCTAssertEqual(result.initialization.engine, engine,
                               engine.rawValue)
                XCTAssertNil(result.initialization.project.engine,
                             "the starter writes floe-game.json; the blank project had no creation hint")
                XCTAssertEqual(result.snapshot.selectedEngine, engine,
                               engine.rawValue)
                XCTAssertNil(result.snapshot.selectedRoot)
                XCTAssertEqual(result.snapshot.state, .confirmed,
                               engine.rawValue)
                XCTAssertEqual(result.snapshot.selectionSource, .explicit,
                               engine.rawValue)
                XCTAssertTrue(result.snapshot.persisted, engine.rawValue)
                XCTAssertEqual(result.snapshot.fileCount,
                               result.initialization.project.files.count)
                let paths = result.initialization.files.map(\.path.value)
                XCTAssertTrue(paths.contains("floe-game.json"), engine.rawValue)
                XCTAssertTrue(paths.contains(result.initialization.descriptor.entry.value),
                              engine.rawValue)
                let record = try await workspace.storedRecord(
                    context: result.initialization.context)
                XCTAssertEqual(record?.selectedEngine, engine)
            }
        }
    }

    func testHostPrecreatedEmptyProjectCanBeSeededInPlace() async throws {
        try await withSelectionWorkspace { workspace in
            let empty = try await workspace.repository.createProject(
                projectID: workspace.projectID, owner: workspace.owner,
                title: "Host Empty")
            let context = try await workspace.host.bind(
                projectID: workspace.projectID, owner: workspace.owner,
                environmentID: workspace.environmentID)
            let result = try await workspace.coordinator.createEngineProject(
                emptyProject: empty, context: context, engine: .godot)
            XCTAssertEqual(result.snapshot.selectedEngine, .godot)
            XCTAssertEqual(result.snapshot.state, .confirmed)
            let reopened = try await workspace.repository.open(
                workspace.projectID, owner: workspace.owner)
            XCTAssertEqual(reopened.revision, result.initialization.project.revision)
        }
    }

    func testRuntimePackStartersFailClosedAndKeepTheEmptyProject() async throws {
        for engine in Self.runtimePackEngines.sorted(by: { $0.rawValue < $1.rawValue }) {
            try await withSelectionWorkspace { workspace in
                let created = try await workspace.createEmpty()
                do {
                    _ = try await workspace.coordinator.createEngineProject(
                        emptyProject: created.0, context: created.1,
                        engine: engine, title: "Pack " + engine.rawValue)
                    XCTFail("\(engine.rawValue) created without a prepared pack")
                } catch let error as GameProjectFlowError {
                    guard case .starter(.missingRuntimePack(let failed, _, let expected)) = error else {
                        XCTFail("\(engine.rawValue) wrong error \(error)")
                        return
                    }
                    XCTAssertEqual(failed, engine)
                    XCTAssertFalse(expected.isEmpty)
                }
                let reopened = try await workspace.repository.open(
                    workspace.projectID, owner: workspace.owner)
                XCTAssertTrue(reopened.files.isEmpty, engine.rawValue)
                XCTAssertTrue(reopened.directories.isEmpty, engine.rawValue)
                let record = try await workspace.storedRecord(
                    context: created.1)
                XCTAssertNil(record, engine.rawValue)
                let history = try await workspace.repository.history(
                    workspace.projectID, owner: workspace.owner)
                XCTAssertEqual(history.count, 1, engine.rawValue)
            }
        }
    }
}
