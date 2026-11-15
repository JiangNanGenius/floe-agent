// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

final class GameBuildCapabilityTests: XCTestCase {
    private func boundInspection(_ url: URL, engine: GameEngineID, version: String? = nil) throws -> GameProjectInspection {
        let projectID = UUID()
        let context = try GameProjectContext(projectID: projectID, owner: .space(recordID: projectID),
                                             rootURL: url, savedRevision: "rev-1")
        let marker = try GameRelativePath("marker")
        let evidence = [GameEngineEvidence(path: marker, kind: .projectMarker, versionHint: version)]
        return GameProjectInspection(rootURL: url, context: context,
                                     candidates: [GameEngineCandidate(engine: engine, evidence: evidence)],
                                     inspectedPaths: [])
    }

    func testPlansExistForTheFiveDocumentedRoutesAndPreserveVersions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        for engine in [GameEngineID.unity, .godot, .cocosCreator, .gdevelop, .phaser] {
            let inspection = try boundInspection(url, engine: engine, version: "1.2.3")
            let plan = try GameBuildCapabilityRegistry.plan(for: engine, inspection: inspection)
            XCTAssertEqual(plan.engine, engine)
            XCTAssertEqual(plan.engineVersion, "1.2.3")
            XCTAssertFalse(plan.stages.isEmpty)
            XCTAssertFalse(plan.outputs.isEmpty)
            let expectedTemplate: String = switch engine {
            case .phaser: "floe-game-build-script-web"
            case .cocosCreator: "floe-game-build-cocos"
            default: "floe-game-build-\(engine.rawValue.lowercased())"
            }
            XCTAssertEqual(plan.workflowTemplateID, expectedTemplate)
            // Every output names its producing stage; every stage is runnable-kind.
            let stageIDs = Set(plan.stages.map(\.id))
            for output in plan.outputs {
                XCTAssertTrue(stageIDs.contains(output.producedByStage), "\(engine.rawValue): \(output.artifactName)")
            }
            // Prerequisites can be reported as missing — configurable errors.
            let missing = plan.missingPrerequisites(configured: [])
            XCTAssertFalse(missing.isEmpty)
            XCTAssertTrue(plan.missingPrerequisites(configured: Set(missing.map(\.tool.id))).isEmpty)
        }
    }

    func testLegacySourceOnlyExpectationIsRetired() throws {
        // The original 30-test handoff threw `.sourceOnlyEngine` for these
        // engines. That assertion is intentionally retired: each now has a
        // concrete route. The old engine list is retained so the change is
        // reviewable instead of silently deleting coverage.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy: [GameEngineID] = [.rpgMakerMV, .rpgMakerXP, .renpy, .tic80, .love, .microStudio, .wasm4]
        for engine in legacy {
            let inspection = try boundInspection(url, engine: engine)
            let plan = try GameBuildCapabilityRegistry.plan(for: engine, inspection: inspection)
            XCTAssertEqual(plan.engine, engine)
            XCTAssertFalse(plan.routes.isEmpty)
            XCTAssertTrue(plan.routes.contains { $0.kind != .sourceArchive || $0.playable == false })
            XCTAssertFalse(plan.routes.allSatisfy { $0.kind == .sourceArchive && $0.proof == .sourceQualified })
        }
    }

    func testAllTwentyEnginesHaveConcreteAdapterRoutes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = try GameBuildCapabilityRegistry.catalog()
        XCTAssertEqual(catalog.engines.count, 20)
        for entry in catalog.engines {
            let inspection = try boundInspection(url, engine: entry.engine, version: "1.2.3")
            let plan = try GameBuildCapabilityRegistry.plan(for: entry.engine, inspection: inspection)
            XCTAssertFalse(plan.adapter.component.isEmpty, entry.engine.rawValue)
            XCTAssertFalse(plan.adapter.entryPoint.isEmpty, entry.engine.rawValue)
            XCTAssertFalse(plan.distributionProfileID.isEmpty, entry.engine.rawValue)
            XCTAssertFalse(plan.routes.isEmpty, entry.engine.rawValue)
            XCTAssertTrue(plan.routes.contains { $0.playable || $0.producer == .userEditor }, entry.engine.rawValue)
            XCTAssertEqual(plan.engineVersion, "1.2.3")
            let stageIDs = Set(plan.stages.map(\.id))
            for output in plan.outputs {
                XCTAssertTrue(stageIDs.contains(output.producedByStage), "\(entry.engine.rawValue): \(output.artifactName)")
            }
        }
    }

    func testCocosNativeProjectIsDistinctFromAnAPK() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = try GameBuildCapabilityRegistry.plan(for: .cocosCreator,
                                                      inspection: try boundInspection(url, engine: .cocosCreator))
        XCTAssertTrue(plan.routes.contains { $0.kind == .nativeProject && $0.platform == .android })
        XCTAssertTrue(plan.routes.contains { $0.artifactName.hasSuffix(".apk") && $0.stageID == "make-android" })
        XCTAssertTrue(plan.routes.contains { $0.artifactName == "cocos-web.zip" })
    }

    func testGDevelopHasAnActualExporterRouteNotManualOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = try GameBuildCapabilityRegistry.plan(for: .gdevelop,
                                                      inspection: try boundInspection(url, engine: .gdevelop))
        XCTAssertTrue(plan.routes.contains { $0.producer == .hostExporter && $0.proof == .actualExporterAndRuntime })
        XCTAssertTrue(plan.routes.contains { $0.producer == .ci && $0.templateID == "floe-game-build-gdevelop" })
    }

    func testPlanRequiresHostBoundInspection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let inspection = GameProjectInspection(rootURL: url, context: nil, candidates: [], inspectedPaths: [])
        XCTAssertThrowsError(try GameBuildCapabilityRegistry.plan(for: .godot, inspection: inspection)) { error in
            XCTAssertEqual(error as? GameBuildCapabilityError, .inspectionConflict("planning requires a host-bound inspection"))
        }
    }

    func testNativePackagingRecipesAreHonestAboutInstallability() throws {
        let unity = GameNativePackaging.recipes(for: .unity)
        XCTAssertEqual(unity.count, 4)
        XCTAssertTrue(unity.contains(where: { $0.platform == .ios && !$0.installableFromTemplate }))
        XCTAssertTrue(unity.contains(where: { $0.platform == .windows && $0.installableFromTemplate }))
        for engine in [GameEngineID.godot, .cocosCreator, .gdevelop, .phaser] {
            let recipes = GameNativePackaging.recipes(for: engine)
            XCTAssertFalse(recipes.isEmpty, engine.rawValue)
            XCTAssertTrue(recipes.allSatisfy { !$0.toolCommand.isEmpty })
        }
        let mv = GameNativePackaging.recipes(for: .rpgMakerMV)
        XCTAssertFalse(mv.isEmpty)
        XCTAssertTrue(mv.contains(where: { $0.platform == .web && $0.installableFromTemplate }))
        XCTAssertTrue(mv.contains(where: { $0.platform == .windows && !$0.installableFromTemplate }))
        for engine in GameEngineID.allCases {
            XCTAssertFalse(GameNativePackaging.recipes(for: engine).isEmpty, engine.rawValue)
        }
    }
}
