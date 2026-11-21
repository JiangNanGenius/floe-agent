// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameRunKit
import FloeGameCore
import FloeGameWebKit
import FloeGamePortableKit

final class TestWorkspace: @unchecked Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-run-kit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    func write(_ path: String, _ text: String) throws {
        try write(path, Data(text.utf8))
    }

    func write(_ path: String, _ data: Data) throws {
        try Self.write(data, to: root.appendingPathComponent(path))
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }
}

actor TestContextHost: GameRunContextHost {
    let repository: FileGameProjectRepository
    let directory: URL

    init(repository: FileGameProjectRepository, directory: URL) throws {
        self.repository = repository
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func context(id: UUID, owner: GameProjectOwner) async throws -> GameProjectContext {
        let project = try await repository.open(id, owner: owner)
        let target = directory.appendingPathComponent(project.revision, isDirectory: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            _ = try await repository.export(id, owner: owner,
                                            expectedRevision: project.revision, to: target)
        }
        return try GameProjectContext(projectID: id, owner: owner, rootURL: target,
                                      savedRevision: project.revision,
                                      environmentID: "run-kit-tests")
    }

    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext {
        try await context(id: captured.projectID, owner: captured.owner)
    }

    func commitChange(_ id: UUID, owner: GameProjectOwner, expectedRevision: String,
                      path: String, text: String) async throws {
        let relative = try GameRelativePath(path)
        _ = try await repository.commit(id, owner: owner, expectedRevision: expectedRevision,
                                        changes: [.write(relative, Data(text.utf8))])
    }
}

struct TestProject: Sendable {
    let repository: FileGameProjectRepository
    let host: TestContextHost
    let context: GameProjectContext
    let projectID: UUID
    let owner: GameProjectOwner
    let artifacts: URL

    static func make(workspace: TestWorkspace, files: [String: Data],
                     id: UUID = UUID()) async throws -> TestProject {
        let repository = try FileGameProjectRepository(
            directory: workspace.url("Repository-\(id.uuidString.lowercased())"))
        let owner = GameProjectOwner.space(recordID: id)
        let empty = try await repository.createProject(projectID: id, owner: owner,
                                                       title: "Run Kit Test")
        XCTAssertTrue(empty.files.isEmpty)
        let source = workspace.url("Source-\(id.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (path, data) in files {
            try TestWorkspace.write(data, to: source.appendingPathComponent(path))
        }
        _ = try await repository.importContents(from: source, into: id, owner: owner,
                                                expectedRevision: empty.revision)
        let host = try TestContextHost(repository: repository,
            directory: workspace.url("Materializations-\(id.uuidString.lowercased())"))
        let context = try await host.context(id: id, owner: owner)
        return .init(repository: repository, host: host, context: context,
                     projectID: id, owner: owner,
                     artifacts: workspace.url("Artifacts-\(id.uuidString.lowercased())"))
    }
}

func html(_ scripts: [String], inline: Bool = false) -> String {
    let tags = scripts.map { "<script src=\"\($0)\"></script>" }.joined()
    let inlineTag = inline ? "<script>window.fixtureReady=true;</script>" : ""
    return "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\(tags)\(inlineTag)</body></html>"
}

func makeRequest(_ context: GameProjectContext,
                 _ engine: GameEngineID) -> GameWebRunRequest {
    GameWebRunRequest(id: UUID(), context: context, engine: engine)
}

func emptyAvailability() -> GameRunAvailability {
    .init(narrativeResources: false, portableResources: [], runtimePacks: [],
          portableBuildPort: false, externalBuildProvider: false, renpySDK: false)
}

func scannedLayout(_ workspace: TestWorkspace, name: String,
                   files: [String: String]) throws -> (GameRunSourceIndex, GameRunWebEntry?) {
    let root = workspace.url("Layouts/\(name)")
    for (path, text) in files {
        try TestWorkspace.write(text, to: root.appendingPathComponent(path))
    }
    let index = try GameRunTreeScanner.scan(rootURL: root, relativeRoot: ".",
                                            limits: .default)
    let entry = GameRunRoutePlanner.defaultEntry(index)
    let web = try GameRunWebProbe.evaluate(index: index, entry: entry, limits: .default, inspectTwine: true)
    return (index, web)
}

final class GameRunPreparerTests: XCTestCase {
    func testNestedStaticWebKeepsOuterFilesAndOriginalProvenance() async throws {
        let workspace = try TestWorkspace()
        let files: [String: Data] = [
            "outer-unknown.bin": Data("keep me".utf8),
            "web/index.html": Data(html(["./assets/app.js"]).utf8),
            "web/assets/app.js": Data("window.fixture = true;".utf8),
            "web/licenses/ORIGINAL.txt": Data("original license".utf8),
            "web/data/level.json": Data("{\"n\":1}".utf8)
        ]
        let project = try await TestProject.make(workspace: workspace, files: files)
        let selection = try GameRunSelection(context: project.context, root: "web")
        let configuration = try GameRunPreparationConfiguration(
            artifactDirectory: project.artifacts, contexts: project.host)
        let preparer = try GameUnifiedRunPreparer(configuration: configuration)
        await preparer.select(selection)

        let plan = try await preparer.plan(context: project.context, engine: .phaser)
        XCTAssertEqual(plan.action, .staticWeb)
        XCTAssertEqual(plan.entry?.value, "index.html")

        let prepared = try await preparer.prepare(makeRequest(project.context, .phaser))
        XCTAssertEqual(prepared.package.prepared.source, project.context)
        XCTAssertEqual(prepared.package.prepared.entry.value, "index.html")
        let paths = Set(prepared.package.files.map(\.path.value))
        XCTAssertTrue(paths.contains("index.html"))
        XCTAssertTrue(paths.contains("assets/app.js"))
        XCTAssertTrue(paths.contains("licenses/ORIGINAL.txt"))
        XCTAssertTrue(paths.contains("data/level.json"))
        XCTAssertFalse(paths.contains("outer-unknown.bin"))
        let app = try prepared.package.readResource(try GameRelativePath("assets/app.js"))
        XCTAssertEqual(app, Data("window.fixture = true;".utf8))

        XCTAssertEqual(prepared.inspection.context, project.context)
        XCTAssertEqual(prepared.inspection.rootURL, project.context.rootURL)
        XCTAssertTrue(prepared.inspection.candidates.contains { $0.engine == .phaser })

        var registry = GameAdapterRegistry()
        try registry.register(GameAdapterRegistration(engine: .phaser, route: .webKit,
                                                      runtimeReady: true))
        let decision = try GameLaunchPlanner.plan(
            inspection: prepared.inspection, context: project.context,
            selectedEngine: .phaser, registry: registry, artifact: prepared.package.prepared)
        guard case .launch(let launch) = decision else {
            return XCTFail("expected a launch decision, got \(decision)")
        }
        XCTAssertEqual(launch.artifact, prepared.package.prepared)

        let original = project.context.rootURL
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: original.appendingPathComponent("outer-unknown.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: original.appendingPathComponent("web/assets/app.js").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: original.appendingPathComponent("web/floe-portable-artifact.json").path))
    }

    func testSelectedRootRejectsTraversalAndSymlinks() async throws {
        let workspace = try TestWorkspace()
        let files: [String: Data] = [
            "outer.txt": Data("outer".utf8),
            "web/index.html": Data(html(["./app.js"]).utf8),
            "web/app.js": Data("window.x=1;".utf8)
        ]
        let project = try await TestProject.make(workspace: workspace, files: files)
        XCTAssertThrowsError(try GameRunSelection(context: project.context, root: "../web")) { error in
            guard let gameError = error as? GameRunPreparationError,
                  case .invalidSelection = gameError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let configuration = try GameRunPreparationConfiguration(
            artifactDirectory: project.artifacts, contexts: project.host)
        let preparer = try GameUnifiedRunPreparer(configuration: configuration)

        let link = project.context.rootURL.appendingPathComponent("web-link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: project.context.rootURL.appendingPathComponent("web"))
        let linked = try GameRunSelection(context: project.context, root: "web-link")
        do {
            _ = try await preparer.plan(context: project.context, engine: .phaser,
                                        selection: linked)
            XCTFail("a symlinked root must be rejected")
        } catch let error as GameRunPreparationError {
            guard case .invalidSelection = error else {
                return XCTFail("unexpected error \(error)")
            }
        }

        let nestedLink = project.context.rootURL.appendingPathComponent("web/assets-link")
        try FileManager.default.createSymbolicLink(
            at: nestedLink, withDestinationURL: project.context.rootURL.appendingPathComponent("outer.txt"))
        let web = try GameRunSelection(context: project.context, root: "web")
        do {
            _ = try await preparer.plan(context: project.context, engine: .phaser,
                                        selection: web)
            XCTFail("a symlink inside the selected root must be rejected")
        } catch let error as GameRunPreparationError {
            guard case .invalidProject = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testRegisteredEnginesHaveExplicitStableRoutes() throws {
        let workspace = try TestWorkspace()
        let inline = html([], inline: true)
        let layouts: [GameEngineID: [String: String]] = [
            .rpgMakerXP: ["Game.rxproj": "x", "Data/System.rxdata": "x",
                          "Data/Scripts.rxdata": "x"],
            .rpgMakerVX: ["Game.rvproj": "x", "Data/System.rvdata": "x",
                          "Data/Scripts.rvdata": "x"],
            .rpgMakerVXAce: ["Game.rvproj2": "x", "Data/System.rvdata2": "x",
                             "Data/Scripts.rvdata2": "x"],
            .rpgMakerMV: ["index.html": inline, "js/rpg_core.js": "",
                          "js/main.js": "", "js/plugins.js": "", "data/System.json": "{}"],
            .rpgMakerMZ: ["Game.rmmzproject": "x", "data/System.json": "{}",
                          "js/rmmz_core.js": ""],
            .phaser: ["index.html": html(["vendor/phaser.js", "game.js"]),
                      "vendor/phaser.js": "", "game.js": ""],
            .kaplay: ["index.html": html(["runtime/engine.js", "game.js"]),
                      "runtime/engine.js": "", "game.js": ""],
            .godot: ["project.godot": ""],
            .babylon: ["index.html": html(["runtime/engine.js", "game.js"]),
                       "runtime/engine.js": "", "game.js": ""],
            .playcanvas: ["index.html": html(["runtime/engine.js", "game.js"]),
                          "runtime/engine.js": "", "game.js": ""],
            .love: ["main.lua": "function love.draw() end", "conf.lua": ""],
            .renpy: ["game/script.rpy": "label start:\n    return\n"],
            .tyranoScript: ["index.html": html(["tyrano/tyrano.js", "tyrano/plugins/kag/kag.js"]),
                            "tyrano/tyrano.js": "", "tyrano/plugins/kag/kag.js": "",
                            "data/scenario/first.ks": "Hello[p]"],
            .tic80: ["cart.tic": ""],
            .ink: ["story.ink": "Hello -> END\n"],
            .twine: ["story.twine.json": "{}"],
            .gdevelop: ["game.json": "{\"gdVersion\":\"5.6.287\",\"layouts\":[]}"],
            .cocosCreator: ["assets/Scenes/Main.scene": "", "project.json": "{}"],
            .microStudio: ["src/main.ms": "print(\"hi\")\n"],
            .wasm4: ["cart.wasm": ""],
            .unity: ["ProjectSettings/ProjectVersion.txt": "m_EditorVersion: 2022.3.0f1\n",
                     "Assets/Scenes/Main.unity": ""]
        ]
        XCTAssertEqual(Set(layouts.keys), Set(GameEngineID.allCases))
        var seen = Set<GameEngineID>()
        for engine in GameEngineID.allCases {
            let files = try XCTUnwrap(layouts[engine])
            let (index, web) = try scannedLayout(workspace, name: engine.rawValue, files: files)
            let evaluation = try GameRunRoutePlanner.evaluate(
                engine: engine, index: index, web: web, availability: emptyAvailability())
            XCTAssertEqual(evaluation.plan.engine, engine)
            XCTAssertNotEqual(evaluation.plan.action, .unavailable,
                              "\(engine.rawValue) must not fall through to unavailable")
            XCTAssertFalse(evaluation.plan.routeID.isEmpty)
            switch engine {
            case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
                XCTAssertEqual(evaluation.plan.action, .guestRuntime)
            case .rpgMakerMZ:
                XCTAssertEqual(evaluation.plan.action, .externalBuild)
            default:
                break
            }
            seen.insert(engine)
        }
        XCTAssertEqual(seen, Set(GameEngineID.allCases))
    }

    func testTyranoScriptRequiresAnOfflineExportWithItsOwnRuntime() throws {
        let workspace = try TestWorkspace()
        let (complete, web) = try scannedLayout(workspace, name: "tyrano", files: [
            "index.html": html(["tyrano/tyrano.js", "tyrano/plugins/kag/kag.js"]),
            "tyrano/tyrano.js": "", "tyrano/plugins/kag/kag.js": "",
            "data/scenario/first.ks": "Hello[p]"
        ])
        let ready = try GameRunRoutePlanner.evaluate(
            engine: .tyranoScript, index: complete, web: web, availability: emptyAvailability())
        XCTAssertEqual(ready.plan.action, .staticWeb)
        XCTAssertEqual(ready.plan.routeID, "static.tyranoscript")
        let (incomplete, missing) = try scannedLayout(workspace, name: "missing-runtime", files: [
            "index.html": html(["https://example.invalid/tyrano.js"]),
            "data/scenario/first.ks": "Hello[p]"
        ])
        let rejected = try GameRunRoutePlanner.evaluate(
            engine: .tyranoScript, index: incomplete, web: missing, availability: emptyAvailability())
        XCTAssertEqual(rejected.plan.action, .unavailable)
    }

    func testRenPyArchiveSelectsSDKBuildAndRenamedWebPackagePlaysUnchanged() throws {
        let workspace = try TestWorkspace()
        let archive = "RPA-3.0 0000000000000022 00000000\n" + String(repeating: "x", count: 16)
        let desktopLayouts = [(archive, GameRunRouteAction.portableAssembly),
                              ("these bytes are not an RPA archive", .unavailable)]
        for (number, layout) in desktopLayouts.enumerated() {
            let (index, web) = try scannedLayout(workspace, name: "rpa-\(number)",
                files: ["game/archive.rpa": layout.0])
            let evaluation = try GameRunRoutePlanner.evaluate(
                engine: .renpy, index: index, web: web, availability: emptyAvailability())
            XCTAssertEqual(evaluation.plan.action, layout.1)
        }
        let (index, web) = try scannedLayout(workspace, name: "web-data", files: [
            "index.html": html(["renpy.js"]), "renpy.js": "",
            "renpy.wasm": "wasm", "game.data": "archive"
        ])
        let evaluation = try GameRunRoutePlanner.evaluate(
            engine: .renpy, index: index, web: web, availability: emptyAvailability())
        XCTAssertEqual(evaluation.plan.routeID, "static.renpy-web")
        XCTAssertEqual(evaluation.plan.action, .staticWeb)
    }

    func testRealWebExportsPlanStaticWeb() throws {
        let workspace = try TestWorkspace()
        let layouts: [(GameEngineID, [String: String], String)] = [
            (.twine, ["index.html": #"<tw-storydata name="Story" startnode="1" format="Harlowe"><tw-passagedata pid="1">Start</tw-passagedata></tw-storydata><script>document.title='Story'</script>"#], "static.twine-web"),
            (.rpgMakerMZ, ["index.html": html([], inline: true),
                           "js/rmmz_core.js": "", "data/System.json": "{}"],
             "static.rpgmaker-mz-web"),
            (.unity, ["index.html": html(["Build/game.loader.js"]),
                      "Build/game.loader.js": "", "Build/game.wasm": "wasm",
                      "Build/game.data": "data"], "static.unity-webgl"),
            (.cocosCreator, ["index.html": html(["application.js"]),
                             "application.js": "", "src/settings.json": "{}"],
             "static.cocos-web"),
            (.godot, ["index.html": html([], inline: true),
                      "game.wasm": "wasm", "game.pck": "pck"], "static.godot-web"),
            (.gdevelop, ["index.html": html(["gd.js", "data.js", "code0.js"]),
                         "gd.js": "", "data.js": "", "code0.js": "",
                         "LICENSE.GDevelop.txt": "license"], "static.gdevelop-web")
        ]
        for (engine, files, routeID) in layouts {
            let (index, web) = try scannedLayout(workspace, name: "export-" + engine.rawValue,
                                                 files: files)
            let evaluation = try GameRunRoutePlanner.evaluate(
                engine: engine, index: index, web: web, availability: emptyAvailability())
            XCTAssertEqual(evaluation.plan.action, .staticWeb)
            XCTAssertEqual(evaluation.plan.routeID, routeID)
        }
    }

    func testMVWithOwnRuntimeReportsMissingScriptInsteadOfRequestingCorePack() throws {
        let workspace = try TestWorkspace()
        let (index, web) = try scannedLayout(workspace, name: "mv-missing-script", files: [
            "index.html": html(["js/rpg_core.js", "js/absent.js"]),
            "js/rpg_core.js": "", "js/main.js": "", "js/plugins.js": "",
            "data/System.json": "{}"
        ])
        let plan = try GameRunRoutePlanner.evaluate(engine: .rpgMakerMV, index: index,
            web: web, availability: emptyAvailability()).plan
        XCTAssertEqual(plan.action, .unavailable)
        XCTAssertTrue(plan.prerequisites.contains { String(describing: $0).contains("js/absent.js") })
        XCTAssertFalse(plan.prerequisites.contains { if case .preparedResourcePack = $0 { true } else { false } })
    }

    func testMissingPrerequisitesAreActionable() async throws {
        let workspace = try TestWorkspace()
        let inkProject = try await TestProject.make(workspace: workspace, files: [
            "story.ink": Data("Hello -> END\n".utf8)
        ])
        let inkPreparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: inkProject.artifacts,
                                            contexts: inkProject.host))
        let inkPlan = try await inkPreparer.plan(context: inkProject.context, engine: .ink)
        XCTAssertEqual(inkPlan.action, .narrativeAssembly)
        XCTAssertTrue(inkPlan.prerequisites.contains { prerequisite in
            if case .preparedResourcePack = prerequisite { return true }
            return false
        })
        do {
            _ = try await inkPreparer.prepare(makeRequest(inkProject.context, .ink))
            XCTFail("narrative resources are required")
        } catch let error as GameRunPreparationError {
            guard case .missingPrerequisite = error else {
                return XCTFail("unexpected error \(error)")
            }
        }

        let kaplayProject = try await TestProject.make(workspace: workspace, files: [
            "index.html": Data(html(["runtime/engine.js", "game.js"]).utf8),
            "game.js": Data("window.x=1;".utf8)
        ])
        let kaplayPreparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: kaplayProject.artifacts,
                                            contexts: kaplayProject.host))
        let kaplayPlan = try await kaplayPreparer.plan(context: kaplayProject.context,
                                                       engine: .kaplay)
        XCTAssertEqual(kaplayPlan.action, .runtimePackAssembly)
        do {
            _ = try await kaplayPreparer.prepare(makeRequest(kaplayProject.context, .kaplay))
            XCTFail("runtime pack is required")
        } catch let error as GameRunPreparationError {
            guard case .missingPrerequisite = error else {
                return XCTFail("unexpected error \(error)")
            }
        }

        let godotProject = try await TestProject.make(workspace: workspace, files: [
            "project.godot": Data("config_version=5\n".utf8)
        ])
        let godotPreparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: godotProject.artifacts,
                                            contexts: godotProject.host))
        let godotPlan = try await godotPreparer.plan(context: godotProject.context,
                                                     engine: .godot)
        XCTAssertEqual(godotPlan.action, .externalBuild)
        do {
            _ = try await godotPreparer.prepare(makeRequest(godotProject.context, .godot))
            XCTFail("host build provider is required")
        } catch let error as GameRunPreparationError {
            guard case .missingPrerequisite = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testRuntimePackAssemblyInstallsOnlyIntoOwnedArtifact() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "index.html": Data(html(["runtime/engine.js", "game.js"]).utf8),
            "game.js": Data("window.game=1;".utf8),
            "assets/unknown.bin": Data("unknown".utf8)
        ])
        try workspace.write("Packs/kaplay/runtime/engine.js", "window.fixtureRuntime=true;")
        try workspace.write("Packs/kaplay/licenses/ENGINE.txt", "fixture license")
        let pack = try GameRunRuntimePack(
            engine: .kaplay, id: "kaplay-fixture", version: "0.0.0", license: "MIT",
            directory: workspace.url("Packs/kaplay"),
            mappings: [("runtime/engine.js", "runtime/engine.js"),
                       ("licenses/ENGINE.txt", "licenses/ENGINE.txt")])
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(
                artifactDirectory: project.artifacts,
                runtimePacks: GameRunStaticRuntimePackProvider([.kaplay: pack]),
                contexts: project.host))
        let plan = try await preparer.plan(context: project.context, engine: .kaplay)
        XCTAssertEqual(plan.action, .runtimePackAssembly)
        XCTAssertTrue(plan.prerequisites.isEmpty)
        let prepared = try await preparer.prepare(makeRequest(project.context, .kaplay))
        let paths = Set(prepared.package.files.map(\.path.value))
        XCTAssertTrue(paths.contains("runtime/engine.js"))
        XCTAssertTrue(paths.contains("licenses/ENGINE.txt"))
        XCTAssertTrue(paths.contains("assets/unknown.bin"))
        let runtime = try prepared.package.readResource(try GameRelativePath("runtime/engine.js"))
        XCTAssertEqual(runtime, Data("window.fixtureRuntime=true;".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.context.rootURL.appendingPathComponent("runtime/engine.js").path))
    }

    func testExternalBuildProviderOutputIsVerifiedAndSealed() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "project.godot": Data("config_version=5\n".utf8),
            "scenes/main.tscn": Data("[gd_scene]\n".utf8)
        ])
        let provider = StaticExportBuildProvider(wasm: Data([0x00, 0x61, 0x73, 0x6d, 0, 0, 0, 0]),
                                                 pck: Data("PCK".utf8),
                                                 inlineHTML: html([], inline: true))
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: project.artifacts,
                                            externalBuildProvider: provider,
                                            contexts: project.host))
        let prepared = try await preparer.prepare(makeRequest(project.context, .godot))
        let paths = Set(prepared.package.files.map(\.path.value))
        XCTAssertTrue(paths.contains("index.html"))
        XCTAssertTrue(paths.contains("game.wasm"))
        XCTAssertTrue(paths.contains("game.pck"))
        XCTAssertEqual(prepared.package.prepared.source, project.context)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.context.rootURL.appendingPathComponent("project.godot").path))
    }

    func testRevisionSwitchDuringAsyncBuildRejectsWithoutArtifact() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "project.godot": Data("config_version=5\n".utf8)
        ])
        let provider = GatedBuildProvider()
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: project.artifacts,
                                            externalBuildProvider: provider,
                                            contexts: project.host))
        let request = makeRequest(project.context, .godot)
        let task = Task { try await preparer.prepare(request) }
        await provider.waitUntilStarted()
        try await project.host.commitChange(project.projectID, owner: project.owner,
                                            expectedRevision: project.context.savedRevision,
                                            path: "changed.txt", text: "changed")
        await provider.release()
        do {
            _ = try await task.value
            XCTFail("a changed saved revision must be rejected")
        } catch let error as GameRunPreparationError {
            guard case .contextChanged(.revision) = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.artifacts.appendingPathComponent(request.id.uuidString.lowercased()).path))
    }

    func testCancellationWaitsOwnedJobAndDoesNotTouchNextRun() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "project.godot": Data("config_version=5\n".utf8)
        ])
        let provider = SlowBuildProvider()
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: project.artifacts,
                                            externalBuildProvider: provider,
                                            contexts: project.host))
        let request = makeRequest(project.context, .godot)
        let task = Task { try await preparer.prepare(request) }
        await provider.waitUntilStarted()
        await preparer.cancel(request)
        let cancelled = await provider.wasCancelled()
        XCTAssertTrue(cancelled)
        do {
            _ = try await task.value
            XCTFail("cancelled preparation must throw")
        } catch let error as GameRunPreparationError {
            guard case .cancelled = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.artifacts.appendingPathComponent(request.id.uuidString.lowercased()).path))

        let second = try await TestProject.make(workspace: workspace, files: [
            "index.html": Data(html([], inline: true).utf8)
        ])
        let staticPreparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: second.artifacts,
                                            contexts: second.host))
        let prepared = try await staticPreparer.prepare(makeRequest(second.context, .phaser))
        XCTAssertEqual(prepared.package.prepared.source, second.context)
    }



    func testRenPySourceCopiesCompiledCompanionsToOfficialBuildPort() async throws {
        let workspace = try TestWorkspace()
        let scriptC = Data("compiled-script-companion".utf8)
        let screensC = Data("compiled-screens-companion".utf8)
        let project = try await TestProject.make(workspace: workspace, files: [
            "game/script.rpy": Data("label start:\n    return\n".utf8),
            "game/screens.rpy": Data("screen main_menu():\n    text \"menu\"\n".utf8),
            "game/script.rpyc": scriptC,
            "game/screens.rpyc": screensC
        ])
        let port = RecordingPortableBuildPort()
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(
                artifactDirectory: project.artifacts,
                portableBuildPort: port,
                contexts: project.host,
                renpySDK: workspace.url("RenPySDK")))
        let request = makeRequest(project.context, .renpy)
        do {
            _ = try await preparer.prepare(request)
            XCTFail("the recording port intentionally fails")
        } catch is TestPortFailure {
            // Expected: the typed host port was reached with the official build plan.
        }
        let recorded = await port.recordedFiles
        let recordedKind = await port.recordedKind
        let recordedSteps = await port.recordedSteps
        XCTAssertEqual(recordedKind, .renpyWebBuild)
        XCTAssertTrue(recordedSteps.contains(.runRenPy))
        XCTAssertTrue(recorded.contains(GameRunRoutePlanner.path("game/script.rpy")))
        XCTAssertTrue(recorded.contains(GameRunRoutePlanner.path("game/script.rpyc")))
        XCTAssertTrue(recorded.contains(GameRunRoutePlanner.path("game/screens.rpyc")))
        let sourceScript = try Data(contentsOf: project.context.rootURL
            .appendingPathComponent("game/script.rpyc"))
        let sourceScreens = try Data(contentsOf: project.context.rootURL
            .appendingPathComponent("game/screens.rpyc"))
        XCTAssertEqual(sourceScript, scriptC)
        XCTAssertEqual(sourceScreens, screensC)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.artifacts.appendingPathComponent(request.id.uuidString.lowercased()).path))
    }

    func testLoveSourceRequiresPreparedResourcesAndHostBuildPort() async throws {
        let workspace = try TestWorkspace()
        let project = try await TestProject.make(workspace: workspace, files: [
            "main.lua": Data("function love.draw() end\n".utf8),
            "conf.lua": Data("function love.conf(t) t.window.width = 320 end\n".utf8)
        ])
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: project.artifacts,
                                            contexts: project.host))
        let plan = try await preparer.plan(context: project.context, engine: .love)
        XCTAssertEqual(plan.action, .portableAssembly)
        XCTAssertEqual(plan.entry?.value, "index.html")
        do {
            _ = try await preparer.prepare(makeRequest(project.context, .love))
            XCTFail("LÖVE source must not be treated as a compiled Web build")
        } catch let error as GameRunPreparationError {
            guard case .missingPrerequisite = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testCreateThenImportThenPrepareKeepsWholeTree() async throws {
        let workspace = try TestWorkspace()
        let files: [String: Data] = [
            "games/inner/index.html": Data(html(["./game.js"]).utf8),
            "games/inner/game.js": Data("window.game=1;".utf8),
            "games/inner/licenses/ORIGINAL.txt": Data("license".utf8),
            "README.md": Data("outer readme".utf8),
            "Tools/Game.exe": Data("MZ-not-executed".utf8)
        ]
        let project = try await TestProject.make(workspace: workspace, files: files)
        let stored = try await project.repository.open(project.projectID, owner: project.owner)
        XCTAssertEqual(Set(stored.files.map(\.path.value)), Set(files.keys))
        let selection = try GameRunSelection(context: project.context, root: "games/inner")
        let preparer = try GameUnifiedRunPreparer(configuration:
            GameRunPreparationConfiguration(artifactDirectory: project.artifacts,
                                            contexts: project.host))
        await preparer.select(selection)
        let nested = try await preparer.prepare(makeRequest(project.context, .phaser))
        XCTAssertFalse(nested.package.files.contains { $0.path.value == "README.md" })
        XCTAssertTrue(nested.package.files.contains { $0.path.value == "index.html" })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.context.rootURL.appendingPathComponent("Tools/Game.exe").path))
    }
}

// MARK: - Deterministic build-provider doubles (component tests, not engine runs)

private struct StaticExportBuildProvider: GameRunExternalBuildProviding, Sendable {
    let wasm: Data
    let pck: Data
    let inlineHTML: String

    func build(_ request: GameRunExternalBuildRequest) async throws -> GameRunExternalBuildOutput {
        try FileManager.default.createDirectory(at: request.outputDirectory,
                                                withIntermediateDirectories: true)
        try TestWorkspace.write(inlineHTML,
            to: request.outputDirectory.appendingPathComponent("index.html"))
        try TestWorkspace.write(wasm,
            to: request.outputDirectory.appendingPathComponent("game.wasm"))
        try TestWorkspace.write(pck,
            to: request.outputDirectory.appendingPathComponent("game.pck"))
        return try GameRunExternalBuildOutput(
            directory: request.outputDirectory,
            entry: try GameRelativePath("index.html"),
            evidence: ["fixture export"])
    }
}

private actor GatedBuildProvider: GameRunExternalBuildProviding {
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func build(_ request: GameRunExternalBuildRequest) async throws -> GameRunExternalBuildOutput {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
        try FileManager.default.createDirectory(at: request.outputDirectory,
                                                withIntermediateDirectories: true)
        try TestWorkspace.write(html([], inline: true),
            to: request.outputDirectory.appendingPathComponent("index.html"))
        try TestWorkspace.write(Data([0x00, 0x61, 0x73, 0x6d, 0, 0, 0, 0]),
            to: request.outputDirectory.appendingPathComponent("game.wasm"))
        try TestWorkspace.write(Data("PCK".utf8),
            to: request.outputDirectory.appendingPathComponent("game.pck"))
        return try GameRunExternalBuildOutput(
            directory: request.outputDirectory,
            entry: try GameRelativePath("index.html"))
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SlowBuildProvider: GameRunExternalBuildProviding {
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var cancelled = false

    func build(_ request: GameRunExternalBuildRequest) async throws -> GameRunExternalBuildOutput {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            cancelled = true
            throw CancellationError()
        }
        throw GameRunPreparationError.externalBuildFailed("unexpected completion")
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func wasCancelled() -> Bool { cancelled }
}


private struct TestPortFailure: Error, Sendable {}

private actor RecordingPortableBuildPort: GamePortableBuildPort {
    private(set) var recordedFiles: [GameRelativePath] = []
    private(set) var recordedKind: GamePortableBuildKind?
    private(set) var recordedSteps: [GamePortableBuildStep.Kind] = []

    func execute(_ plan: GamePortableBuildPlan,
                 request: GamePortableBuildRequest) async throws -> GamePortableBuildOutput {
        recordedFiles = request.project.files
        recordedKind = plan.kind
        recordedSteps = plan.steps.map(\.kind)
        throw TestPortFailure()
    }
}
