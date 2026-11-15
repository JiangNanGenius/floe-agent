// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameDeveloperCore
@testable import FloeGameInstrumentation

private func clean(_ imported: InstrumentationFixture.Imported) {
    try? FileManager.default.removeItem(at: imported.repositoryDirectory)
    try? FileManager.default.removeItem(at: imported.sourceDirectory)
}

private func read(_ imported: InstrumentationFixture.Imported,
                  revision: String, path: String) async throws -> Data {
    try await imported.repository.read(
        InstrumentationFixture.projectID, owner: InstrumentationFixture.owner,
        revision: revision, path: try GameRelativePath(path))
}

private func hookPlanError(_ instrumenter: GameDeveloperProjectInstrumenter,
                           context: GameProjectContext, engine: GameEngineID,
                           root: GameRelativePath? = nil, scene: String? = nil)
    async -> GameDeveloperInstrumentationError? {
    do {
        _ = try await instrumenter.plan(context: context, engine: engine,
                                        gameRoot: root, scene: scene)
        return nil
    } catch let error as GameDeveloperInstrumentationError {
        return error
    } catch {
        return nil
    }
}

@Suite("GDevelop project hook")
struct GDevelopProjectHookTests {
    @Test("source JSON is never rewritten; the reviewed bridge is provenance")
    func sourceProject() async throws {
        let imported = try await InstrumentationFixture.imported(
            files: InstrumentationFixture.gdevelopSourceProject(), engine: .gdevelop)
        defer { clean(imported) }
        let instrumenter = try InstrumentationFixture.instrumenter(imported)
        let originalProject = try await read(imported,
            revision: imported.context.savedRevision, path: "game.json")
        let plan = try await instrumenter.plan(context: imported.context, engine: .gdevelop)
        #expect(plan.exportHandling == .sourceRequiresExport)
        #expect(plan.requiresRebuild)
        #expect(plan.scene == nil)
        #expect(plan.files.count == 1)
        #expect(plan.files[0].path.value == "floe-developer.js")
        #expect(plan.files[0].action == .create)
        #expect(plan.diagnostics.contains { $0.code == "gdevelop-source-export" })
        #expect(plan.dormancy.gated)
        let receipt = try await instrumenter.apply(plan)
        let projectAfter = try await read(imported, revision: receipt.revision, path: "game.json")
        #expect(projectAfter == originalProject)
        let bridge = try await read(imported, revision: receipt.revision, path: "floe-developer.js")
        #expect(bridge == plan.files[0].outputData)
        let bundle = try await instrumenter.bundleSourceFiles(plan)
        #expect(bundle.files.contains { $0.role == .license })
        #expect(bundle.files.contains { $0.role == .notice })
        #expect(bundle.files.contains { $0.role == .provenance })
        #expect(bundle.files.contains {
            $0.role == .helperSource && $0.path.hasSuffix("floe-developer.js")
                && $0.sha256 == plan.files[0].outputSHA256
        })
        let replanned = try await instrumenter.plan(context: receipt.context, engine: .gdevelop)
        #expect(replanned.files[0].action == .unchanged)
        let second = try await instrumenter.apply(replanned)
        #expect(second.revision == receipt.revision)
    }

    @Test("an already exported playable game needs no re-export")
    func exportedPlayable() async throws {
        let imported = try await InstrumentationFixture.imported(
            files: InstrumentationFixture.gdevelopExportedProject(), engine: .gdevelop)
        defer { clean(imported) }
        let instrumenter = try InstrumentationFixture.instrumenter(imported)
        let originalIndex = try await read(imported,
            revision: imported.context.savedRevision, path: "index.html")
        let plan = try await instrumenter.plan(context: imported.context, engine: .gdevelop)
        #expect(plan.exportHandling == .alreadyExportedPlayable)
        #expect(!plan.requiresRebuild)
        #expect(plan.diagnostics.contains { $0.code == "gdevelop-already-exported" })
        let receipt = try await instrumenter.apply(plan)
        let indexAfter = try await read(imported, revision: receipt.revision, path: "index.html")
        #expect(indexAfter == originalIndex)
    }

    @Test("a same-name user file is a collision, not an overwrite")
    func collision() async throws {
        var files = InstrumentationFixture.gdevelopSourceProject()
        files["floe-developer.js"] = Data("// user file\n".utf8)
        let imported = try await InstrumentationFixture.imported(
            files: files, engine: .gdevelop)
        defer { clean(imported) }
        let instrumenter = try InstrumentationFixture.instrumenter(imported)
        let error = await hookPlanError(instrumenter, context: imported.context,
                                        engine: .gdevelop)
        guard let error else { Issue.record("expected collision"); return }
        guard case .existingFileCollision(let path, _) = error else {
            Issue.record("expected existingFileCollision, got \(error)")
            return
        }
        #expect(path.value == "floe-developer.js")
    }

    @Test("a bridge without the host gate fails closed")
    func dormancyTamper() async throws {
        let imported = try await InstrumentationFixture.imported(
            files: InstrumentationFixture.gdevelopSourceProject(), engine: .gdevelop)
        defer { clean(imported) }
        let base = try GameDeveloperProjectHookTemplates()
        let original = try #require(String(data: base.gdevelopBridge.data, encoding: .utf8))
        let modified = original.replacingOccurrences(of: "window.FloeDeveloper", with: "window.NotFloe")
        let templates = try InstrumentationFixture.hookTemplates(gdevelop: Data(modified.utf8))
        let instrumenter = try InstrumentationFixture.hookInstrumenter(imported,
                                                                       hookTemplates: templates)
        let error = await hookPlanError(instrumenter, context: imported.context,
                                        engine: .gdevelop)
        guard let error else { Issue.record("expected dormancy failure"); return }
        guard case .dormancyUnverified(let detail) = error else {
            Issue.record("expected dormancyUnverified, got \(error)")
            return
        }
        #expect(detail.contains("window.FloeDeveloper"))
    }
}

@Test func cocosCompressedUUIDMatchesOfficialSerialization() throws {
    #expect(try CocosSceneJSON.compressedUUID("0f10e5a1-7a2b-4c3d-8e4f-5a6b7c8d9e0f")
            == "0f10eWheitMPY5PWmt8jZ4P")
    #expect(try CocosSceneJSON.compressedUUID("0f10e5a1-7a2b-4c3d-8e4f-5a6b7c8d9e0f",
                                              minimumHead: true)
            == "0fEOWheitMPY5PWmt8jZ4P")
}

@Suite("Cocos Creator project hook")
struct CocosProjectHookTests {
    private static let sceneA = "e2f7c9a4-2b7d-4f7e-8a1c-3d5b6e9f0a21"
    private static let sceneB = "f3a8d0b5-3c8e-4a5f-9b2d-4e6c7d8f1b32"

    @Test("a single scene is attached with exact meta UUID and preserved fields")
    func singleScene() async throws {
        let imported = try await InstrumentationFixture.imported(
            files: InstrumentationFixture.cocosProject(
                scenes: [("Main", Self.sceneA)], startScene: Self.sceneA),
            engine: .cocosCreator)
        defer { clean(imported) }
        let instrumenter = try InstrumentationFixture.instrumenter(imported)
        let choices = try await instrumenter.scenes(context: imported.context,
                                                    engine: .cocosCreator)
        #expect(choices.count == 1)
        #expect(choices[0].id == Self.sceneA)
        #expect(choices[0].isStartScene)
        let plan = try await instrumenter.plan(context: imported.context,
                                               engine: .cocosCreator)
        #expect(plan.engineVersion.contains("3.8.6"))
        #expect(plan.scene?.id == Self.sceneA)
        #expect(plan.files.count == 3)
        let script = try #require(plan.files.first { $0.kind == .helperSource })
        let meta = try #require(plan.files.first { $0.kind == .generatedFile })
        let scene = try #require(plan.files.first { $0.kind == .projectPatch })
        #expect(script.path.value == "assets/scripts/FloeDeveloper.ts")
        #expect(meta.path.value == "assets/scripts/FloeDeveloper.ts.meta")
        #expect(scene.action == .patch)
        let metaObject = try JSONSerialization.jsonObject(with: meta.outputData) as? [String: Any]
        let uuid = try #require(metaObject?["uuid"] as? String)
        let compressed = try CocosSceneJSON.compressedUUID(uuid)
        #expect(String(decoding: scene.outputData, as: UTF8.self).contains(compressed))
        let sceneObject = try JSONSerialization.jsonObject(with: scene.outputData) as? [Any]
        let sceneDictionary = try #require(sceneObject?[1] as? [String: Any])
        let unknown = try #require(sceneDictionary["unknownSceneField"] as? [String: Any])
        #expect(unknown["keep"] as? String == "yes")
        let oldComponent = try #require(sceneObject?[3] as? [String: Any])
        #expect(oldComponent["unknownComponentField"] as? Int == 42)
        let originalScene = try await read(imported,
            revision: imported.context.savedRevision, path: "assets/Scenes/Main.scene")
        let receipt = try await instrumenter.apply(plan)
        #expect(receipt.changedFiles.count == 3)
        let committedScene = try await read(imported, revision: receipt.revision,
                                            path: "assets/Scenes/Main.scene")
        let committedArray = try JSONSerialization.jsonObject(with: committedScene) as? [Any]
        #expect((committedArray?.count ?? -1) == (sceneObject?.count ?? -1))
        let committedMeta = try await read(imported, revision: receipt.revision,
                                           path: "assets/scripts/FloeDeveloper.ts.meta")
        #expect(committedMeta == meta.outputData)
        let bundle = try await instrumenter.bundleSourceFiles(plan)
        #expect(bundle.files.contains { $0.role == .generatedFile && $0.path.hasSuffix(".ts.meta") })
        let replanned = try await instrumenter.plan(context: receipt.context, engine: .cocosCreator)
        #expect(replanned.files.allSatisfy { $0.action == .unchanged })
        let second = try await instrumenter.apply(replanned)
        #expect(second.revision == receipt.revision)
        let restored = try await imported.repository.restore(
            InstrumentationFixture.projectID, owner: InstrumentationFixture.owner,
            expectedRevision: receipt.revision,
            historicalRevision: imported.context.savedRevision)
        #expect(restored.revision != receipt.revision)
        let restoredScene = try await read(imported, revision: restored.revision,
                                           path: "assets/Scenes/Main.scene")
        #expect(restoredScene == originalScene)
    }

    @Test("multiple scenes without start metadata require an explicit choice")
    func multipleScenes() async throws {
        let imported = try await InstrumentationFixture.imported(
            files: InstrumentationFixture.cocosProject(
                scenes: [("Main", Self.sceneA), ("Level2", Self.sceneB)]),
            engine: .cocosCreator)
        defer { clean(imported) }
        let instrumenter = try InstrumentationFixture.instrumenter(imported)
        let choices = try await instrumenter.scenes(context: imported.context,
                                                    engine: .cocosCreator)
        #expect(choices.count == 2)
        #expect(choices.allSatisfy { !$0.isStartScene })
        let error = await hookPlanError(instrumenter, context: imported.context,
                                        engine: .cocosCreator)
        guard let error else { Issue.record("expected explicit scene error"); return }
        guard case .sceneSelectionRequired = error else {
            Issue.record("expected sceneSelectionRequired, got \(error)")
            return
        }
        let byUUID = try await instrumenter.plan(context: imported.context,
            engine: .cocosCreator, scene: Self.sceneB)
        #expect(byUUID.scene?.id == Self.sceneB)
        let byPath = try await instrumenter.plan(context: imported.context,
            engine: .cocosCreator, scene: "assets/Scenes/Main.scene")
        #expect(byPath.scene?.id == Self.sceneA)
        let missing = await hookPlanError(instrumenter, context: imported.context,
            engine: .cocosCreator, scene: "assets/Scenes/Missing.scene")
        guard let missing else { Issue.record("expected sceneNotFound"); return }
        guard case .sceneNotFound = missing else {
            Issue.record("expected sceneNotFound, got \(missing)")
            return
        }
    }

    @Test("actual startScene metadata selects the starter scene, not the first file")
    func startSceneSelection() async throws {
        let imported = try await InstrumentationFixture.imported(
            files: InstrumentationFixture.cocosProject(
                scenes: [("Main", Self.sceneA), ("Level2", Self.sceneB)],
                startScene: Self.sceneB),
            engine: .cocosCreator)
        defer { clean(imported) }
        let instrumenter = try InstrumentationFixture.instrumenter(imported)
        let plan = try await instrumenter.plan(context: imported.context,
                                               engine: .cocosCreator)
        #expect(plan.scene?.id == Self.sceneB)
        #expect(plan.scene?.isStartScene == true)
        #expect(plan.diagnostics.contains { $0.code == "cocos-start-scene" })
    }

    @Test("a same-name user component is a collision")
    func collision() async throws {
        var files = InstrumentationFixture.cocosProject(
            scenes: [("Main", Self.sceneA)], startScene: Self.sceneA)
        files["assets/scripts/FloeDeveloper.ts"] = Data("// user component\n".utf8)
        let imported = try await InstrumentationFixture.imported(
            files: files, engine: .cocosCreator)
        defer { clean(imported) }
        let instrumenter = try InstrumentationFixture.instrumenter(imported)
        let error = await hookPlanError(instrumenter, context: imported.context,
                                        engine: .cocosCreator)
        guard let error else { Issue.record("expected collision"); return }
        guard case .existingFileCollision(let path, _) = error else {
            Issue.record("expected existingFileCollision, got \(error)")
            return
        }
        #expect(path.value == "assets/scripts/FloeDeveloper.ts")
    }

    @Test("a scene with corrupt JSON is rejected without a write")
    func corruptScene() async throws {
        var files = InstrumentationFixture.cocosProject(
            scenes: [("Main", Self.sceneA)], startScene: Self.sceneA)
        files["assets/Scenes/Main.scene"] = Data("[{\"__type__\":\"cc.SceneAsset\"".utf8)
        let imported = try await InstrumentationFixture.imported(
            files: files, engine: .cocosCreator)
        defer { clean(imported) }
        let instrumenter = try InstrumentationFixture.instrumenter(imported)
        let historyBefore = try await imported.repository.history(
            InstrumentationFixture.projectID, owner: InstrumentationFixture.owner)
        let error = await hookPlanError(instrumenter, context: imported.context,
                                        engine: .cocosCreator)
        guard let error else { Issue.record("expected an error"); return }
        guard case .rootUnrecognized = error else {
            Issue.record("expected rootUnrecognized, got \(error)")
            return
        }
        let history = try await imported.repository.history(
            InstrumentationFixture.projectID, owner: InstrumentationFixture.owner)
        #expect(history == historyBefore)
    }
}
