// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import Testing
import FloeGameAuthoring
import FloeGameDeveloperCore
@testable import FloeGameInstrumentation

actor InstrumentationTestContextHost: GameAuthoringContextHost {
    private var contexts: [UUID: GameProjectContext] = [:]
    private var rejectHandoff = false

    func bind(_ context: GameProjectContext) {
        contexts[context.projectID] = context
    }

    func currentContext(for context: GameProjectContext) async throws -> GameProjectContext {
        guard let stored = contexts[context.projectID],
              stored.owner == context.owner else {
            throw GameProjectError.contextChanged(.project)
        }
        return stored
    }

    func contextAfterCommit(_ project: GameStoredProject,
                            previous: GameProjectContext) async throws -> GameProjectContext {
        guard !rejectHandoff else {
            throw GameProjectError.invalidContext
        }
        let next = try GameProjectContext(
            projectID: project.projectID, owner: project.owner,
            rootURL: previous.rootURL, savedRevision: project.revision,
            environmentID: previous.environmentID)
        contexts[project.projectID] = next
        return next
    }

    func setRejectHandoff(_ value: Bool) {
        rejectHandoff = value
    }
}

enum InstrumentationFixture {
    static let projectID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-444444444444")!
    static let owner: GameProjectOwner = .space(recordID: projectID)

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-instrumentation-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ files: [String: Data], to root: URL) throws {
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    static func makeDirectories(_ paths: [String], in root: URL) throws {
        for path in paths {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
    }

    static func unityProject(version: String = "2022.3.61f1",
                             extra: [String: Data] = [:]) -> [String: Data] {
        var files: [String: Data] = [
            "Assets/Scenes/Main.unity": Data("%YAML 1.1\n".utf8),
            "Assets/Scripts/FloeStarter.cs": Data("public sealed class FloeStarter {}\n".utf8),
            "ProjectSettings/ProjectVersion.txt": Data(
                "m_EditorVersion: \(version)\nm_EditorVersionWithRevision: \(version) (1234567890ab)\n".utf8),
            "ProjectSettings/ProjectSettings.asset": Data("%YAML 1.1\n".utf8)
        ]
        for (path, data) in extra { files[path] = data }
        return files
    }

    static func godotProject(configVersion: Int = 5,
                             autoloads: [String] = [],
                             lineEnding: String = "\n",
                             bom: Bool = false) -> Data {
        var lines = [
            "; SPDX-License-Identifier: MIT",
            "config_version=\(configVersion)",
            "",
            "[application]",
            "config/name=\"Fixture\"",
            ""
        ]
        if !autoloads.isEmpty {
            lines.append("[autoload]")
            lines.append("")
            lines.append(contentsOf: autoloads)
            lines.append("")
        }
        lines.append("[rendering]")
        lines.append("renderer/rendering_method=\"gl_compatibility\"")
        var text = lines.joined(separator: "\n") + "\n"
        if lineEnding == "\r\n" {
            text = text.replacingOccurrences(of: "\n", with: "\r\n")
        }
        var data = Data(text.utf8)
        if bom {
            var prefixed = Data([0xEF, 0xBB, 0xBF])
            prefixed.append(data)
            data = prefixed
        }
        return data
    }

    static func godotProjectData(configVersion: Int = 5,
                                autoloads: [String] = [],
                                lineEnding: String = "\n",
                                bom: Bool = false) -> [String: Data] {
        [
            "project.godot": godotProject(configVersion: configVersion,
                                          autoloads: autoloads,
                                          lineEnding: lineEnding, bom: bom),
            "main.gd": Data("extends Node2D\n".utf8),
            "main.tscn": Data("[gd_scene format=3]\n".utf8)
        ]
    }

    struct Imported: Sendable {
        let repositoryDirectory: URL
        let sourceDirectory: URL
        let repository: FileGameProjectRepository
        let contexts: InstrumentationTestContextHost
        let context: GameProjectContext
    }

    static func imported(files: [String: Data],
                         emptyDirectories: [String] = [],
                         engine: GameEngineID? = nil,
                         label: String = "fixture") async throws -> Imported {
        let repositoryDirectory = try temporaryDirectory(label + "-repository")
        let sourceDirectory = try temporaryDirectory(label + "-source")
        try write(files, to: sourceDirectory)
        try makeDirectories(emptyDirectories, in: sourceDirectory)
        let repository = try FileGameProjectRepository(directory: repositoryDirectory)
        let empty = try await repository.createProject(
            projectID: projectID, owner: owner, title: "Fixture", engine: engine)
        let imported = try await repository.importContents(
            from: sourceDirectory, into: projectID, owner: owner,
            expectedRevision: empty.revision)
        let context = try GameProjectContext(
            projectID: projectID, owner: owner, rootURL: sourceDirectory,
            savedRevision: imported.revision, environmentID: "instrumentation-test")
        let contexts = InstrumentationTestContextHost()
        await contexts.bind(context)
        return .init(repositoryDirectory: repositoryDirectory,
                     sourceDirectory: sourceDirectory,
                     repository: repository, contexts: contexts, context: context)
    }

    static func instrumenter(_ imported: Imported,
                             templates: GameDeveloperInstrumentationTemplates? = nil)
        throws -> GameDeveloperProjectInstrumenter {
        try GameDeveloperProjectInstrumenter(
            repository: imported.repository, contexts: imported.contexts,
            templates: templates)
    }

    static func templates(godot: Data? = nil,
                          unityBridge: Data? = nil,
                          unityBehaviour: Data? = nil) throws -> GameDeveloperInstrumentationTemplates {
        let base = try GameDeveloperInstrumentationTemplates()
        func replace(_ template: GameDeveloperInstrumentationTemplate,
                     data: Data?) -> GameDeveloperInstrumentationTemplate {
            guard let data else { return template }
            return .init(id: template.id, resource: template.resource,
                         sdkPath: template.sdkPath, sha256: GameDigest.sha256(data),
                         bytes: data.count, data: data)
        }
        return .init(
            catalogVersion: base.catalogVersion,
            frozenSourceRevision: base.frozenSourceRevision,
            sdkRelativeRoot: base.sdkRelativeRoot,
            pinsSHA256: base.pinsSHA256,
            unityBridge: replace(base.unityBridge, data: unityBridge),
            unityJSLibrary: base.unityJSLibrary,
            unityBehaviour: replace(base.unityBehaviour, data: unityBehaviour),
            godotAutoload: replace(base.godotAutoload, data: godot),
            license: base.license,
            notice: base.notice)
    }

    static func planError(_ instrumenter: GameDeveloperProjectInstrumenter,
                          context: GameProjectContext,
                          engine: GameEngineID,
                          root: GameRelativePath? = nil) async -> GameDeveloperInstrumentationError? {
        do {
            _ = try await instrumenter.plan(context: context, engine: engine, gameRoot: root)
            return nil
        } catch let error as GameDeveloperInstrumentationError {
            return error
        } catch {
            return nil
        }
    }
}

// MARK: - GDevelop / Cocos fixtures

extension InstrumentationFixture {
    static func gdevelopSourceProject(extra: [String: Data] = [:]) -> [String: Data] {
        let project = """
        {
          "firstLayout": "Main",
          "gdVersion": {"major": 5, "minor": 6, "revision": 0, "build": 287},
          "properties": {"name": "Fixture", "projectUuid": "11111111-2222-4333-8444-555555555555"},
          "variables": [{"name": "Score", "type": "number", "value": "0"}],
          "layouts": [{
            "name": "Main",
            "variables": [{"name": "Lives", "type": "number", "value": "3"}],
            "objects": [{"name": "Orb", "type": "Sprite"}],
            "instances": [{"name": "Orb", "x": 10, "y": 20}]
          }],
          "resources": {"resources": []}
        }
        """
        var files: [String: Data] = ["game.json": Data(project.utf8)]
        for (path, data) in extra { files[path] = data }
        return files
    }

    static func gdevelopExportedProject() -> [String: Data] {
        [
            "index.html": Data("""
            <!DOCTYPE html><html><head><script src="gd.js"></script><script src="code0.js"></script></head>
            <body><script>
            var game = new gdjs.RuntimeGame(gdjs.projectData, {});
            game.getRenderer().bindStandardEvents(game.getInputManager(), window, document);
            </script></body></html>
            """.utf8),
            "data.js": Data("gdjs.projectData = {\"firstLayout\":\"Main\",\"layouts\":[{\"name\":\"Main\"}]};\n".utf8),
            "gd.js": Data("var gdjs={};\n".utf8),
            "code0.js": Data("gdjs.MainCode = { eventsList0: function() {} };\n".utf8),
            "LICENSE.GDevelop.txt": Data("MIT\n".utf8)
        ]
    }

    static func cocosScene(name: String, uuid: String) -> Data {
        let text = """
        [
          {
            "__type__": "cc.SceneAsset",
            "_name": "",
            "_objFlags": 0,
            "_native": "",
            "scene": {"__id__": 1}
          },
          {
            "__type__": "cc.Scene",
            "_name": "\(name)",
            "_objFlags": 0,
            "_parent": null,
            "_children": [{"__id__": 2}],
            "_active": true,
            "_components": [],
            "_prefab": null,
            "autoReleaseAssets": false,
            "_globals": {"__id__": 4},
            "_id": "\(uuid)",
            "unknownSceneField": {"keep": "yes", "number": 7}
          },
          {
            "__type__": "cc.Node",
            "_name": "FloeStarter",
            "_objFlags": 0,
            "_parent": {"__id__": 1},
            "_children": [],
            "_active": true,
            "_components": [{"__id__": 3}],
            "_prefab": null,
            "_lpos": {"__type__": "cc.Vec3", "x": 0, "y": 0, "z": 0},
            "_lrot": {"__type__": "cc.Quat", "x": 0, "y": 0, "z": 0, "w": 1},
            "_lscale": {"__type__": "cc.Vec3", "x": 1, "y": 1, "z": 1},
            "_mobility": 0,
            "_layer": 1073741824,
            "_euler": {"__type__": "cc.Vec3", "x": 0, "y": 0, "z": 0},
            "_id": "d1a2B3c4D5e6F7g8H9i0Jk"
          },
          {
            "__type__": "0f10eWheitMPY5PWmt8jZ4P",
            "_name": "",
            "_objFlags": 0,
            "node": {"__id__": 2},
            "_enabled": true,
            "__prefab": null,
            "speed": 180,
            "unknownComponentField": 42,
            "_id": "a1B2c3D4e5F6g7H8i9J0kL"
          },
          {
            "__type__": "cc.SceneGlobals",
            "ambient": {"__id__": 5},
            "shadows": {"__id__": 6},
            "_skybox": {"__id__": 7},
            "fog": {"__id__": 8}
          },
          {"__type__": "cc.AmbientInfo", "_skyColor": {"__type__": "cc.Color", "r": 1, "g": 2, "b": 3, "a": 1}, "_skyIllum": 1, "_groundAlbedo": {"__type__": "cc.Color", "r": 1, "g": 1, "b": 1, "a": 255}},
          {"__type__": "cc.ShadowsInfo", "_type": 0, "_enabled": false},
          {"__type__": "cc.SkyboxInfo", "_envmap": null, "_isRGBE": false, "_enabled": false, "_useIBL": false},
          {"__type__": "cc.FogInfo", "_type": 0, "_fogColor": {"__type__": "cc.Color", "r": 1, "g": 1, "b": 1, "a": 1}, "_enabled": false, "_fogDensity": 0.3, "_fogStart": 0.5, "_fogEnd": 300, "_fogAtten": 5, "_fogTop": 1.5, "_fogRange": 1.2}
        ]
        """
        return Data(text.utf8)
    }

    static func cocosSceneMeta(uuid: String) -> Data {
        Data("""
        {
          "ver": "1.1.45",
          "importer": "scene",
          "imported": true,
          "uuid": "\(uuid)",
          "files": [".json"],
          "subMetas": {},
          "userData": {}
        }
        """.utf8)
    }

    static func cocosProject(scenes: [(name: String, uuid: String)],
                             startScene: String? = nil) -> [String: Data] {
        var files: [String: Data] = [
            "package.json": Data("""
            {"name": "fixture", "type": "2d", "uuid": "aaaaaaaa-1111-2222-3333-444444444444", "version": "3.8.6", "creator": {"version": "3.8.6"}}
            """.utf8),
            "tsconfig.json": Data("{}\n".utf8)
        ]
        for scene in scenes {
            files["assets/Scenes/\(scene.name).scene"] = cocosScene(name: scene.name, uuid: scene.uuid)
            files["assets/Scenes/\(scene.name).scene.meta"] = cocosSceneMeta(uuid: scene.uuid)
        }
        if let startScene {
            files["floe-cocos-build.json"] = Data("""
            {"name": "fixture", "startScene": "\(startScene)", "platform": "web-mobile", "buildPath": "project://build"}
            """.utf8)
        }
        return files
    }

    static func hookTemplates(gdevelop: Data? = nil,
                              cocos: Data? = nil) throws -> GameDeveloperProjectHookTemplates {
        let base = try GameDeveloperProjectHookTemplates()
        func replace(_ template: GameDeveloperProjectHookTemplate,
                     data: Data?) -> GameDeveloperProjectHookTemplate {
            guard let data else { return template }
            return .init(id: template.id, resource: template.resource,
                         sdkPath: template.sdkPath, sha256: GameDigest.sha256(data),
                         bytes: data.count, data: data)
        }
        return .init(
            catalogVersion: base.catalogVersion,
            frozenSourceRevision: base.frozenSourceRevision,
            sdkRelativeRoot: base.sdkRelativeRoot,
            pinsSHA256: base.pinsSHA256,
            gdevelopBridge: replace(base.gdevelopBridge, data: gdevelop),
            cocosBridge: replace(base.cocosBridge, data: cocos),
            license: base.license,
            notice: base.notice)
    }

    static func hookInstrumenter(_ imported: Imported,
                                 hookTemplates: GameDeveloperProjectHookTemplates) throws
        -> GameDeveloperProjectInstrumenter {
        try GameDeveloperProjectInstrumenter(
            repository: imported.repository, contexts: imported.contexts,
            hookTemplates: hookTemplates)
    }
}
