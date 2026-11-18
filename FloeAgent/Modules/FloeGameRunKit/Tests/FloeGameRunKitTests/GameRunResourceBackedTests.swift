// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameRunKit
import FloeGameCore
import FloeGameWebKit
import FloeGamePortableKit

/// Opt-in tests for the real prepared runtime packs. They are kept in a
/// separate class from the default suite and produce an explicit XCTSkip (never
/// a hidden pass) when an env fixture is absent. Set:
///   FLOE_GAME_RUN_NARRATIVE_RESOURCES
///   FLOE_GAME_RUN_PORTABLE_RESOURCES
///   FLOE_GAME_RUN_STARTER_PACKS
final class GameRunResourceBackedTests: XCTestCase {
    private func environmentDirectory(_ name: String) throws -> URL {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("Set \(name) to the prepared resource directory to run this opt-in test.")
        }
        let url = URL(fileURLWithPath: value, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) does not exist: \(value)")
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func testInkArtifactWithRealPreparedResources() async throws {
        let resources = try environmentDirectory("FLOE_GAME_RUN_NARRATIVE_RESOURCES")
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "story.ink": Data("""
            Hello from the saved story.
            * [Continue] -> END
            """.utf8)
        ])
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: project.artifacts,
                                            narrativeResources: resources,
                                            contexts: project.host))
        let prepared = try await preparer.prepare(makeRequest(project.context, .ink))
        let paths = Set(prepared.package.files.map(\.path.value))
        XCTAssertTrue(paths.contains("index.html"))
        XCTAssertTrue(paths.contains("vendor/inkjs.js"))
        XCTAssertTrue(paths.contains("story.ink"))
        XCTAssertTrue(paths.contains("game/ink-sources.json"))
        XCTAssertTrue(paths.contains("floe-artifact.json"))
        let manifest = try prepared.package.readResource(try GameRelativePath("floe-artifact.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        XCTAssertEqual(object["engine"] as? String, "ink")
        let original = try XCTUnwrap(object["originalGameFiles"] as? [String])
        XCTAssertTrue(original.contains("story.ink"))
        XCTAssertEqual(prepared.package.prepared.source, project.context)
    }

    func testTwineArtifactWithRealPreparedResources() async throws {
        let resources = try environmentDirectory("FLOE_GAME_RUN_NARRATIVE_RESOURCES")
        let workspace = try TestWorkspace()
        let story = """
        {"format":"SugarCube","formatVersion":"2.37.3","start":"1","ifid":"11111111-1111-4111-8111-111111111111","title":"Run Kit Twine","storyAttributes":{},"passages":[{"pid":"1","name":"Start","tags":"","position":"100,100","size":"100,100","text":"Hello from Twine.","attributes":{}}]}
        """
        let project = try await TestProject.make(workspace: workspace, files: [
            "story.twine.json": Data(story.utf8)
        ])
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: project.artifacts,
                                            narrativeResources: resources,
                                            contexts: project.host))
        let prepared = try await preparer.prepare(makeRequest(project.context, .twine))
        let paths = Set(prepared.package.files.map(\.path.value))
        XCTAssertTrue(paths.contains("index.html"))
        XCTAssertTrue(paths.contains("vendor/sugarcube-engine.js"))
        XCTAssertTrue(paths.contains("vendor/sugarcube-libraries.js"))
        XCTAssertTrue(paths.contains("game/story.twine.json"))
        XCTAssertEqual(prepared.package.prepared.source, project.context)
    }

    func testMicroStudioArtifactWithRealPreparedResources() async throws {
        let resources = try environmentDirectory("FLOE_GAME_RUN_NARRATIVE_RESOURCES")
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "src/main.ms": Data("print(\"hello from microStudio\")\n".utf8),
            "project.json": Data("{\"title\":\"Run Kit microStudio\"}".utf8)
        ])
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: project.artifacts,
                                            narrativeResources: resources,
                                            contexts: project.host))
        let prepared = try await preparer.prepare(makeRequest(project.context, .microStudio))
        let paths = Set(prepared.package.files.map(\.path.value))
        XCTAssertTrue(paths.contains("index.html"))
        XCTAssertTrue(paths.contains("microengine.js") || paths.contains("vendor/microengine.js"))
        XCTAssertTrue(paths.contains("game/microstudio-sources.json"))
        XCTAssertEqual(prepared.package.prepared.source, project.context)
    }

    func testMVTemplateAssemblyWithRealPreparedCoreScript() async throws {
        let resourcesRoot = try environmentDirectory("FLOE_GAME_RUN_PORTABLE_RESOURCES")
        let manifestURL = resourcesRoot.appendingPathComponent(
            "rpg-maker-mv-corescript-1.3b.manifest.json")
        let packRoot = resourcesRoot.appendingPathComponent(
            "rpg-maker-mv-corescript-1.3b", isDirectory: true)
        let resources = try GamePortablePreparedResources(rootURL: packRoot, manifestURL: manifestURL)
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "index.html": Data("""
            <!doctype html><html><body>
            <script src="js/rpg_core.js"></script>
            <script src="js/main.js"></script>
            <script src="js/plugins.js"></script>
            </body></html>
            """.utf8),
            "js/main.js": Data("// original project main\n".utf8),
            "js/plugins.js": Data("// original project plugins\n".utf8),
            "data/System.json": Data("{\"gameTitle\":\"Run Kit MV\"}".utf8),
            "img/pictures/unknown.png": Data([0x89, 0x50, 0x4E, 0x47])
        ])
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(
                artifactDirectory: project.artifacts,
                preparePortableResource: { engine in
                    XCTAssertEqual(engine, .rpgMakerMV)
                    return resources
                },
                contexts: project.host))
        let plan = try await preparer.plan(context: project.context, engine: .rpgMakerMV)
        XCTAssertEqual(plan.action, .portableAssembly)
        let prepared = try await preparer.prepare(makeRequest(project.context, .rpgMakerMV))
        let paths = Set(prepared.package.files.map(\.path.value))
        XCTAssertTrue(paths.contains("index.html"))
        XCTAssertTrue(paths.contains("js/rpg_core.js"))
        XCTAssertTrue(paths.contains("js/main.js"))
        XCTAssertTrue(paths.contains("data/System.json"))
        XCTAssertTrue(paths.contains("img/pictures/unknown.png"))
        let core = try prepared.package.readResource(try GameRelativePath("js/rpg_core.js"))
        let expectedCore = try resources.read("js/rpg_core.js")
        XCTAssertEqual(core, expectedCore)
        XCTAssertEqual(prepared.package.prepared.source, project.context)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.context.rootURL.appendingPathComponent("js/rpg_core.js").path))
    }

    func testRealKAPLAYPackAssemblyFromStarterPacks() async throws {
        let starterPacks = try environmentDirectory("FLOE_GAME_RUN_STARTER_PACKS")
        let packRoot = starterPacks.appendingPathComponent("kaplay-3001.0.0", isDirectory: true)
        let pack = try GameRunRuntimePack(
            engine: .kaplay, id: "kaplay-3001.0.0", version: "3001.0.0", license: "MIT",
            directory: packRoot,
            mappings: [("runtime/engine.js", "runtime/engine.js"),
                       ("licenses/ENGINE.txt", "licenses/ENGINE.txt")])
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "index.html": Data("""
            <!doctype html><html><body>
            <script src="runtime/engine.js"></script>
            <script src="game.js"></script>
            </body></html>
            """.utf8),
            "game.js": Data("window.game = true;\n".utf8)
        ])
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(
                artifactDirectory: project.artifacts,
                runtimePacks: GameRunStaticRuntimePackProvider([.kaplay: pack]),
                contexts: project.host))
        let prepared = try await preparer.prepare(makeRequest(project.context, .kaplay))
        let engine = try prepared.package.readResource(try GameRelativePath("runtime/engine.js"))
        let expected = try Data(contentsOf: packRoot.appendingPathComponent("runtime/engine.js"))
        XCTAssertEqual(engine, expected)
        XCTAssertTrue(prepared.package.files.contains {
            $0.path.value == "licenses/ENGINE.txt"
        })
        XCTAssertEqual(prepared.package.prepared.source, project.context)
    }
}
