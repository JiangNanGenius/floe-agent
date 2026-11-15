// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeGameCore
import FloeRPGCore
@testable import FloeGameStarterKit

final class StarterDataFormatTests: XCTestCase {
    func testLegacyRPGMapDatabaseAndScriptsRoundTripThroughRPGCore() async throws {
        let cases: [(GameEngineID, RPGEngine, String)] = [
            (.rpgMakerXP, .rpgMakerXP, "rxdata"),
            (.rpgMakerVX, .rpgMakerVX, "rvdata"),
            (.rpgMakerVXAce, .rpgMakerVXAce, "rvdata2"),
        ]
        for (engine, rpgEngine, ext) in cases {
            try await withWorkspace { workspace in
                let result = try await workspace.seed(engine: engine, title: "RPG " + engine.rawValue)
                let mapData = try await workspace.read(result, "Data/Map001." + ext)
                let map = try RPGMapDocument.decode(mapData, engine: rpgEngine,
                                                     pathName: "Map001." + ext)
                XCTAssertEqual(map.width, 12, engine.rawValue)
                XCTAssertEqual(map.height, 10, engine.rawValue)
                XCTAssertEqual(map.events.count, 2, engine.rawValue)
                XCTAssertEqual(map.events.map(\.name).sorted(), ["Ferry Keeper", "Notice Stone"])
                XCTAssertNotNil(map.table)
                XCTAssertGreaterThanOrEqual(map.tile(x: 2, y: 2, z: 0), 0)
                let mapEncoded = try map.encode()
                let mapAgain = try RPGMapDocument.decode(mapEncoded, engine: rpgEngine,
                                                         pathName: "Map001." + ext)
                XCTAssertEqual(mapAgain.width, map.width)
                XCTAssertEqual(mapAgain.height, map.height)
                XCTAssertEqual(mapAgain.events.map(\.id), map.events.map(\.id))
                XCTAssertEqual(mapAgain.tile(x: 2, y: 2, z: 0), map.tile(x: 2, y: 2, z: 0))

                let actorData = try await workspace.read(result, "Data/Actors." + ext)
                let actors = try RPGDataDocument.decode(actorData, kind: .actors,
                                                        engine: rpgEngine)
                let records = actors.binaryRecords()
                XCTAssertGreaterThan(records.count, 1, engine.rawValue)
                XCTAssertEqual(records[1]?.stringMember("@name"), "Kestrel")
                let actorsEncoded = try actors.encode()
                let actorsAgain = try RPGDataDocument.decode(actorsEncoded, kind: .actors,
                                                             engine: rpgEngine)
                XCTAssertEqual(actorsAgain.binaryRecords()[1]?.stringMember("@name"), "Kestrel")

                let scriptData = try await workspace.read(result, "Data/Scripts." + ext)
                let scripts = try RPGScriptArchive.decode(scriptData)
                XCTAssertEqual(scripts.count, 1)
                XCTAssertEqual(scripts[0].title.utf8String, "FloeStarter")
                let source = String(decoding: scripts[0].source, as: UTF8.self)
                XCTAssertTrue(source.contains("FloeStarterScene"))
                XCTAssertTrue(source.contains("Marshal.dump"))
                XCTAssertFalse(source.contains("Enterbrain"))
                let scriptEncoded = try RPGScriptArchive.encode(scripts)
                let scriptsAgain = try RPGScriptArchive.decode(scriptEncoded)
                XCTAssertEqual(scriptsAgain.count, 1)
                XCTAssertEqual(scriptsAgain[0].title.utf8String, "FloeStarter")
                XCTAssertEqual(scriptsAgain[0].source, scripts[0].source)
            }
        }
    }

    func testMZContainsStandardJSONDataAndNoProprietaryCoreScripts() async throws {
        try await withWorkspace { workspace in
            let result = try await workspace.seed(engine: .rpgMakerMZ, title: "MZ QA")
            let paths = Set(workspace.paths(result))
            XCTAssertTrue(paths.contains("Game.rmmzproject"))
            XCTAssertTrue(paths.contains("data/Map001.json"))
            XCTAssertTrue(paths.contains("data/System.json"))
            XCTAssertTrue(paths.contains("js/plugins/FloeStarter.js"))
            XCTAssertFalse(paths.contains(where: { $0.hasPrefix("js/rmmz_") }))
            let system = try jsonObject(try await workspace.read(result, "data/System.json"))
            let gameTitle = try XCTUnwrap(system["gameTitle"] as? String)
            let startMapId = try XCTUnwrap(system["startMapId"] as? Int)
            XCTAssertEqual(gameTitle, "MZ QA")
            XCTAssertEqual(startMapId, 1)
            let map = try jsonObject(try await workspace.read(result, "data/Map001.json"))
            let width = try XCTUnwrap(map["width"] as? Int)
            let height = try XCTUnwrap(map["height"] as? Int)
            XCTAssertEqual(width, 12)
            XCTAssertEqual(height, 10)
            let events = try XCTUnwrap(map["events"] as? [Any])
            XCTAssertEqual(events.count, 3)
            let actors = try jsonArray(try await workspace.read(result, "data/Actors.json"))
            XCTAssertEqual(actors.count, 2)
            let plugin = String(decoding: try await workspace.read(
                result, "js/plugins/FloeStarter.js"), as: UTF8.self)
            XCTAssertTrue(plugin.contains("@target MZ"))
            XCTAssertTrue(plugin.contains("DataManager.saveGame"))
        }
    }

    func testUnityProjectMetadataSourceAndEditorWebBuildBootstrap() async throws {
        try await withWorkspace { workspace in
            let result = try await workspace.seed(engine: .unity, title: "Unity QA")
            let version = String(decoding: try await workspace.read(
                result, "ProjectSettings/ProjectVersion.txt"), as: UTF8.self)
            XCTAssertTrue(version.contains("m_EditorVersion: 2022.3.0f1"))
            let script = String(decoding: try await workspace.read(
                result, "Assets/Scripts/FloeStarter.cs"), as: UTF8.self)
            XCTAssertTrue(script.contains("RuntimeInitializeOnLoadMethod"))
            XCTAssertTrue(script.contains("Input.GetKey"))
            XCTAssertTrue(script.contains("PlayerPrefs"))
            let editor = String(decoding: try await workspace.read(
                result, "Assets/Editor/FloeWebBuild.cs"), as: UTF8.self)
            XCTAssertTrue(editor.contains("BuildTarget.WebGL"))
            XCTAssertTrue(editor.contains("BuildPipeline.BuildPlayer"))
            let scene = String(decoding: try await workspace.read(
                result, "Assets/Scenes/Main.unity"), as: UTF8.self)
            XCTAssertTrue(scene.hasPrefix("%YAML 1.1"))
            let buildSettings = String(decoding: try await workspace.read(
                result, "ProjectSettings/EditorBuildSettings.asset"), as: UTF8.self)
            XCTAssertTrue(buildSettings.contains("Assets/Scenes/Main.unity"))
            let manifest = try jsonObject(try await workspace.read(result, "Packages/manifest.json"))
            XCTAssertNotNil(manifest["dependencies"])
        }
    }

    func testCocosCreatorProjectLayoutSceneAndTypeScriptSource() async throws {
        try await withWorkspace { workspace in
            let result = try await workspace.seed(engine: .cocosCreator, title: "Cocos QA")
            let package = try jsonObject(try await workspace.read(result, "package.json"))
            let creator = try XCTUnwrap(package["creator"] as? [String: Any])
            let creatorVersion = try XCTUnwrap(creator["version"] as? String)
            XCTAssertEqual(creatorVersion, "3.8.6")
            let scene = try jsonArray(try await workspace.read(
                result, "assets/Scenes/Main.scene"))
            XCTAssertTrue(scene.contains { item in
                guard let object = item as? [String: Any],
                      let type = object["__type__"] as? String else { return false }
                return !type.hasPrefix("cc.") && object["node"] != nil
            })
            let script = String(decoding: try await workspace.read(
                result, "assets/scripts/FloeStarter.ts"), as: UTF8.self)
            XCTAssertTrue(script.contains("@ccclass('FloeStarter')"))
            XCTAssertTrue(script.contains("view.setDesignResolutionSize"))
            let meta = try jsonObject(try await workspace.read(
                result, "assets/scripts/FloeStarter.ts.meta"))
            XCTAssertNotNil(meta["uuid"])
            let project = try jsonObject(try await workspace.read(
                result, "settings/v2/packages/project.json"))
            XCTAssertNotNil(project["general"])
            let sceneMeta = try jsonObject(try await workspace.read(result, "assets/Scenes/Main.scene.meta"))
            let sceneID = try XCTUnwrap(sceneMeta["uuid"] as? String)
            for (file, platform, output) in [("floe-cocos-build.json", "web-mobile", "web-mobile"),
                                              ("floe-cocos-android.json", "android", "android")] {
                let config = try jsonObject(try await workspace.read(result, file))
                XCTAssertEqual(config["startScene"] as? String, sceneID)
                XCTAssertEqual(config["platform"] as? String, platform)
                XCTAssertEqual(config["buildPath"] as? String, "project://build")
                XCTAssertEqual(config["outputName"] as? String, output)
            }
        }
    }

    func testRenPyCurrentPortableTemplateKeepsChoiceFocusFix() async throws {
        try await withWorkspace { workspace in
            let result = try await workspace.seed(engine: .renpy, title: "RenPy Focus")
            let screens = String(decoding: try await workspace.read(
                result, "game/screens.rpy"), as: UTF8.self)
            XCTAssertTrue(screens.contains("QuickSave() keyboard_focus False"))
            XCTAssertTrue(screens.contains("QuickLoad(confirm=False) keyboard_focus False"))
            XCTAssertTrue(screens.contains("MainMenu(confirm=False) keyboard_focus False"))
            XCTAssertTrue(screens.contains("default_focus (i == items[0])"))
            XCTAssertTrue(screens.contains("key \"K_F5\" action QuickSave()"))
            XCTAssertTrue(screens.contains("key \"K_F9\" action QuickLoad(confirm=False)"))
        }
    }

    func testGodotStandardProjectAndWebExportPreset() async throws {
        try await withWorkspace { workspace in
            let result = try await workspace.seed(engine: .godot, title: "Godot QA")
            let project = String(decoding: try await workspace.read(
                result, "project.godot"), as: UTF8.self)
            XCTAssertTrue(project.contains("config_version=5"))
            XCTAssertTrue(project.contains("run/main_scene=\"res://main.tscn\""))
            let script = String(decoding: try await workspace.read(
                result, "main.gd"), as: UTF8.self)
            XCTAssertTrue(script.contains("JavaScriptBridge"))
            XCTAssertTrue(script.contains("_on_host_input"))
            let preset = String(decoding: try await workspace.read(
                result, "export_presets.cfg"), as: UTF8.self)
            XCTAssertTrue(preset.contains("platform=\"Web\""))
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonArray(_ data: Data) throws -> [Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any])
    }
}
