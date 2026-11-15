// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeGameCore
@testable import FloeGameStarterKit

final class StarterLicenseTests: XCTestCase {
    func testEveryEmbeddedStarterCarriesStarterLicenseAndMetadata() async throws {
        let embedded: [GameEngineID] = [
            .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce, .rpgMakerMV, .rpgMakerMZ,
            .godot, .love, .renpy, .tic80, .ink, .twine, .gdevelop,
            .cocosCreator, .microStudio, .wasm4, .unity,
        ]
        for engine in embedded {
            try await withWorkspace { workspace in
                let result = try await workspace.seed(engine: engine, title: "License " + engine.rawValue)
                let paths = Set(workspace.paths(result))
                XCTAssertTrue(paths.contains("floe-game.json"), engine.rawValue)
                XCTAssertTrue(paths.contains("floe-inputs.json"), engine.rawValue)
                XCTAssertTrue(paths.contains("licenses/FLOE-STARTER-MIT.txt")
                              || paths.contains("LICENSE-FLOE-STARTER-MIT.txt"),
                              engine.rawValue)
                let metadata = try JSONSerialization.jsonObject(
                    with: try await workspace.read(result, "floe-game.json")) as? [String: Any]
                let metadataEngine = try XCTUnwrap(metadata?["engine"] as? String)
                let metadataLicense = try XCTUnwrap(metadata?["sourceLicense"] as? String)
                XCTAssertEqual(metadataEngine, engine.rawValue)
                XCTAssertEqual(metadataLicense, result.descriptor.sourceLicense)
                XCTAssertNotNil(metadata?["engineLicense"] as? String)
                XCTAssertFalse((metadata?["prerequisites"] as? [Any])?.isEmpty ?? true)
            }
        }
    }

    func testLegacyStarterHasNoProprietaryExecutableOrArchiveFiles() async throws {
        for (engine, ext) in [(GameEngineID.rpgMakerXP, "rxdata"),
                              (.rpgMakerVX, "rvdata"),
                              (.rpgMakerVXAce, "rvdata2")] {
            try await withWorkspace { workspace in
                let result = try await workspace.seed(engine: engine, title: "Legacy " + engine.rawValue)
                let paths = workspace.paths(result)
                XCTAssertTrue(paths.contains("Game.ini"))
                XCTAssertTrue(paths.contains("Data/Scripts." + ext))
                XCTAssertTrue(paths.contains("Data/Map001." + ext))
                for path in paths {
                    let lower = path.lowercased()
                    XCTAssertFalse(lower.hasSuffix(".dll"), path)
                    XCTAssertFalse(lower.hasSuffix(".exe"), path)
                    XCTAssertFalse(lower.hasSuffix(".rgssad"), path)
                    XCTAssertFalse(lower.hasSuffix(".rgss2a"), path)
                    XCTAssertFalse(lower.hasSuffix(".rgss3a"), path)
                    XCTAssertFalse(lower.hasSuffix(".so"), path)
                    XCTAssertFalse(lower.hasSuffix(".dylib"), path)
                }
            }
        }
    }

    func testMZHasNoLicensedCoreScriptsOrRTPData() async throws {
        try await withWorkspace { workspace in
            let result = try await workspace.seed(engine: .rpgMakerMZ, title: "MZ License")
            let paths = workspace.paths(result)
            XCTAssertFalse(paths.contains { $0.lowercased().hasPrefix("js/rmmz_") })
            XCTAssertFalse(paths.contains { $0.lowercased().hasSuffix("rmmz_core.js") })
            XCTAssertFalse(paths.contains { $0.lowercased().hasSuffix("rmmz_managers.js") })
            XCTAssertTrue(paths.contains("js/plugins/FloeStarter.js"))
            let plugin = String(decoding: try await workspace.read(
                result, "js/plugins/FloeStarter.js"), as: UTF8.self)
            XCTAssertTrue(plugin.contains("SPDX-License-Identifier: MIT"))
            XCTAssertTrue(plugin.contains("licensed rmmz_* core scripts"))
        }
    }

    func testUnityAndCocosHaveNoEngineBinariesOrGeneratedBuildTrees() async throws {
        for engine in [GameEngineID.unity, .cocosCreator] {
            try await withWorkspace { workspace in
                let result = try await workspace.seed(engine: engine, title: "Native " + engine.rawValue)
                for path in workspace.paths(result) {
                    let lower = path.lowercased()
                    XCTAssertFalse(lower.hasSuffix(".dll"), path)
                    XCTAssertFalse(lower.hasSuffix(".pdb"), path)
                    XCTAssertFalse(lower.hasSuffix(".so"), path)
                    XCTAssertFalse(lower.hasSuffix(".dylib"), path)
                    XCTAssertFalse(lower.hasPrefix("library/"), path)
                    XCTAssertFalse(lower.hasPrefix("temp/"), path)
                    XCTAssertFalse(lower.hasPrefix("obj/"), path)
                    XCTAssertFalse(lower.hasPrefix("build/webgl/"), path)
                    XCTAssertFalse(lower.hasPrefix("build/web-mobile/"), path)
                }
            }
        }
    }

    func testRuntimePacksCarryTheirEngineLicenseFiles() async throws {
        guard let root = runtimePackRootFromEnvironment() else {
            throw XCTSkip("prepared runtime packs unavailable")
        }
        let resources = GameStarterResources.from(root: root)
        let expected: [(GameEngineID, [String])] = [
            (.phaser, ["vendor/phaser.js", "licenses/PHASER-MIT.txt",
                       "licenses/THIRD-PARTY-NOTICES.txt", "licenses/FLOE-STARTER-MIT.txt"]),
            (.kaplay, ["runtime/engine.js", "licenses/ENGINE.txt", "licenses/FLOE-STARTER-MIT.txt"]),
            (.babylon, ["runtime/engine.js", "licenses/ENGINE.txt",
                        "licenses/NOTICE.md", "licenses/FLOE-STARTER-MIT.txt"]),
            (.playcanvas, ["runtime/engine.js", "licenses/ENGINE.txt", "licenses/FLOE-STARTER-MIT.txt"]),
        ]
        for (engine, files) in expected {
            try await withWorkspace(resources: resources) { workspace in
                let result = try await workspace.seed(engine: engine, title: "Pack License " + engine.rawValue)
                let paths = Set(workspace.paths(result))
                for file in files {
                    XCTAssertTrue(paths.contains(file), "\(engine.rawValue) missing \(file)")
                }
            }
        }
    }
}
