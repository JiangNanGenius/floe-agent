// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameRGSS

final class RGSSProjectImportTests: XCTestCase {
    func testCreateThenImportPreservesEveryOriginalByte() async throws {
        let root = try temporaryDirectory()
        let repository = try FileGameProjectRepository(directory: root)
        let projectID = UUID()
        let owner = GameProjectOwner.space(recordID: projectID)
        let source = Fixture.url("xp-preservation-project")
        let imported = try await RGSSProjectImporter().createAndImport(
            from: source, projectID: projectID, owner: owner,
            title: "Preservation", repository: repository)
        let paths = Set(imported.project.files.map(\.path.value))
        XCTAssertTrue(paths.contains("Game.exe"))
        XCTAssertTrue(paths.contains("RGSS104E.dll"))
        XCTAssertTrue(paths.contains("Game.rgssad"))
        XCTAssertTrue(paths.contains(".floe/unknown.bin"))
        XCTAssertTrue(paths.contains("Plugins/custom_plugin.rb"))
        let unknown = try await repository.read(projectID, owner: owner,
            revision: imported.project.revision, path: try GameRelativePath(".floe/unknown.bin"))
        XCTAssertEqual(unknown, try Data(contentsOf: source.appendingPathComponent(".floe/unknown.bin")))
        XCTAssertEqual(imported.inspection?.engine, Optional(GameEngineID.rpgMakerXP))
        XCTAssertTrue(imported.inspection?.encryptedArchives.contains("Game.rgssad") == true)
        XCTAssertTrue(imported.inspection?.nativeExecutables.contains("Game.exe") == true)
        XCTAssertTrue(imported.inspection?.nativeLibraries.contains("RGSS104E.dll") == true)
        XCTAssertTrue(imported.inspection?.warnings.contains(where: { $0.contains("RTP") }) == true)
        let export = try await repository.export(projectID, owner: owner,
            expectedRevision: imported.project.revision,
            to: root.appendingPathComponent("exported"))
        XCTAssertEqual(export.savedRevision, imported.project.revision)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("exported/Game.exe")),
                       try Data(contentsOf: source.appendingPathComponent("Game.exe")))
    }

    func testTemplateCreateForAllEnginesWritesValidDeclaration() async throws {
        for engine in [GameEngineID.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce] {
            let root = try temporaryDirectory()
            let repository = try FileGameProjectRepository(directory: root)
            let projectID = UUID()
            let owner = GameProjectOwner.space(recordID: projectID)
            let stored = try await RGSSTemplateProvider.createProject(
                engine: engine, title: "Template", projectID: projectID,
                owner: owner, repository: repository)
            XCTAssertEqual(stored.engine, Optional(engine))
            let profile = try RGSSEngineProfiles.profile(for: engine)
            let marker = try await repository.read(projectID, owner: owner,
                revision: stored.revision, path: try GameRelativePath("Game." + profile.markerExtension))
            XCTAssertFalse(marker.isEmpty)
            let scripts = try await repository.read(projectID, owner: owner,
                revision: stored.revision, path: try GameRelativePath(profile.scriptsPath))
            XCTAssertGreaterThan(scripts.count, 32)
            let inputs = try await repository.read(projectID, owner: owner,
                revision: stored.revision, path: try GameRelativePath("floe-inputs.json"))
            let declaration = try RGSSInputDeclaration.decode(inputs, expectedEngine: engine)
            XCTAssertEqual(declaration.engine, engine)
        }
    }
}

final class RGSSCompatibilityTests: XCTestCase {
    func testInspectorReportsConcreteFindingsWithoutMutation() throws {
        let source = Fixture.url("xp-preservation-project")
        let before = try Data(contentsOf: source.appendingPathComponent("Game.rgssad"))
        let inspection = try RGSSCompatibilityInspector().inspect(rootURL: source)
        XCTAssertEqual(inspection.engine, .rpgMakerXP)
        XCTAssertEqual(inspection.version, .rgss1)
        XCTAssertTrue(inspection.scriptsPresent)
        XCTAssertTrue(inspection.encryptedArchives.contains("Game.rgssad"))
        XCTAssertTrue(inspection.nativeExecutables.contains("Game.exe"))
        XCTAssertTrue(inspection.nativeLibraries.contains("RGSS104E.dll"))
        XCTAssertTrue(inspection.audioUnsupported.contains("BGM/theme.wma"))
        XCTAssertTrue(inspection.pluginFiles.contains("custom_plugin.rb"))
        XCTAssertTrue(inspection.unknownRootEntries.contains(".floe") || inspection.unknownRootEntries.contains("Plugins") == false)
        XCTAssertTrue(inspection.warnings.contains(where: { $0.contains("never executed") }))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Game.rgssad")), before)
    }

    func testVXAndVXAceAreLinuxOnlyInThisLane() throws {
        for pair in [(GameEngineID.rpgMakerVX, "vx-template-project"), (.rpgMakerVXAce, "vxace-template-project")] {
            let inspection = try RGSSCompatibilityInspector().inspect(rootURL: Fixture.url(pair.1))
            XCTAssertEqual(inspection.engine, pair.0)
            if pair.0 == .rpgMakerVX {
                guard case .sourceRecipeOnly(let id, _) = inspection.webAvailability else {
                    XCTFail("expected a source-only VX JSPI recipe")
                    continue
                }
                XCTAssertEqual(id, RGSSWebRuntimeRecipes.mkxpWebJSPI.id)
            } else {
                guard case .unavailable = inspection.webAvailability else {
                    XCTFail("expected no reviewed RGSS3 Web engine")
                    continue
                }
            }
            guard case .typedAdapterAvailable = inspection.guestAvailability else {
                XCTFail("expected typed Linux adapter availability")
                continue
            }
        }
    }
}
