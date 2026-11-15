// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameDeveloperCore

/// Cocos Creator 3.8 project installer. It creates a typed component and its
/// exact `.meta` UUID, then attaches the component to one explicitly selected
/// scene with a byte-preserving insertion. A multi-scene project without an
/// explicit scene or real start-scene metadata is rejected instead of guessing.
enum CocosProjectInstrumentation {
    struct SceneRecord: Sendable {
        let choice: GameDeveloperInstrumentationSceneChoice
        let path: GameRelativePath
        let metaPath: GameRelativePath
        let data: Data
    }

    struct Result: Sendable {
        let engineVersion: String
        let files: [GameDeveloperProjectInstrumentationFile]
        let scene: GameDeveloperInstrumentationScene
        let diagnostics: [GameDeveloperInstrumentationDiagnostic]
    }

    static func scenes(project: GameStoredProject,
                       repository: FileGameProjectRepository,
                       revision: String,
                       root: GameRelativePath?,
                       limits: GameDeveloperInstrumentationLimits) async throws
        -> [GameDeveloperInstrumentationSceneChoice] {
        let records = try await sceneRecords(project: project, repository: repository,
                                             revision: revision, root: root, limits: limits)
        return records.map(\.choice)
    }

    static func inspect(project: GameStoredProject,
                        repository: FileGameProjectRepository,
                        revision: String,
                        root: GameRelativePath?,
                        requestedScene: String?,
                        templates: GameDeveloperProjectHookTemplates,
                        limits: GameDeveloperInstrumentationLimits) async throws -> Result {
        let records = try await sceneRecords(project: project, repository: repository,
                                             revision: revision, root: root, limits: limits)
        guard !records.isEmpty else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(
                .cocosCreator, "no assets/**/*.scene with a matching Creator scene .meta was found")
        }
        let selected = try select(records: records, requested: requestedScene)
        let choice = selected.choice
        // Paths in a SceneRecord are already full project-relative paths.
        let scenePath = selected.path
        let metaPath = selected.metaPath
        let folded = Dictionary(project.files.map {
            (GameDeveloperInstrumentationPath.folded($0.path.value), $0)
        }, uniquingKeysWith: { first, _ in first })
        let byPath = Dictionary(project.files.map { ($0.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        let template = try templates.template(id: "cocosBridge")
        let scriptPath = try GameDeveloperInstrumentationPath.resolve(
            root, GameDeveloperInstrumentationConstants.cocosBridgePath)
        let scriptMetaPath = try GameDeveloperInstrumentationPath.resolve(
            root, GameDeveloperInstrumentationConstants.cocosBridgeMetaPath)
        try ensureFileTarget(scriptPath, folded: folded, project: project)
        try ensureFileTarget(scriptMetaPath, folded: folded, project: project)
        let existingScript = byPath[scriptPath]
        let scriptInstalled = existingScript.map { $0.sha256 == template.sha256 && $0.bytes == template.bytes } ?? false
        if let existingScript, !scriptInstalled {
            throw GameDeveloperInstrumentationError.existingFileCollision(scriptPath, existingScript.sha256)
        }
        let existingMeta = byPath[scriptMetaPath]
        if existingMeta != nil && existingScript == nil {
            throw GameDeveloperInstrumentationError.existingFileCollision(
                scriptMetaPath, existingMeta?.sha256 ?? "")
        }
        let scriptUUID: String
        if let existingMeta {
            guard existingMeta.bytes <= limits.maximumMetadataBytes else {
                throw GameDeveloperInstrumentationError.limitExceeded(scriptMetaPath.value)
            }
            let data = try await repository.read(project.projectID, owner: project.owner,
                                                 revision: revision, path: scriptMetaPath)
            guard let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (meta["importer"] as? String) == "typescript",
                  let uuid = meta["uuid"] as? String,
                  canonicalUUID(uuid) != nil else {
                throw GameDeveloperInstrumentationError.existingFileCollision(
                    scriptMetaPath, existingMeta.sha256)
            }
            scriptUUID = uuid.lowercased()
        } else {
            scriptUUID = CocosSceneJSON.stableScriptUUID(
                projectID: project.projectID, path: scriptPath, templateSHA256: template.sha256)
        }
        let canonicalMeta = try metaData(uuid: scriptUUID)
        if let existingMeta, existingMeta.sha256 != GameDigest.sha256(canonicalMeta) {
            throw GameDeveloperInstrumentationError.existingFileCollision(
                scriptMetaPath, existingMeta.sha256)
        }
        let scenePatch: Data
        let sceneAction: GameDeveloperInstrumentationFileAction
        do {
            let result = try CocosSceneJSON.patch(data: selected.data, sceneUUID: choice.id,
                                                  scriptUUID: scriptUUID)
            scenePatch = result.data
            sceneAction = result.alreadyInstalled ? .unchanged : .patch
        } catch CocosSceneJSONError.invalid(let detail) {
            throw GameDeveloperInstrumentationError.invalidProjectFile(
                "\(choice.path.value): \(detail)")
        }
        let packageVersion = try await creatorVersion(project: project, repository: repository,
                                                      revision: revision, root: root,
                                                      byPath: byPath, limits: limits)
        let engineVersion = "Cocos Creator \(packageVersion)"

        var files: [GameDeveloperProjectInstrumentationFile] = [
            .init(path: scriptPath, kind: .helperSource,
                  action: scriptInstalled ? .unchanged : .create,
                  templateResource: GameDeveloperInstrumentationConstants.cocosBridgeResource,
                  templateSHA256: template.sha256, existingSHA256: existingScript?.sha256,
                  outputSHA256: template.sha256, outputBytes: template.bytes, outputData: template.data),
            .init(path: scriptMetaPath, kind: .generatedFile,
                  action: existingMeta == nil ? .create : .unchanged,
                  templateResource: "generated:cocos-typescript-meta",
                  templateSHA256: GameDigest.sha256(canonicalMeta),
                  existingSHA256: existingMeta?.sha256,
                  outputSHA256: GameDigest.sha256(canonicalMeta),
                  outputBytes: canonicalMeta.count, outputData: canonicalMeta),
            .init(path: scenePath, kind: .projectPatch, action: sceneAction,
                  templateResource: "inline:cocos-scene[FloeDeveloper]",
                  templateSHA256: GameDigest.sha256(scenePatch),
                  existingSHA256: byPath[scenePath]?.sha256,
                  outputSHA256: GameDigest.sha256(scenePatch),
                  outputBytes: scenePatch.count, outputData: scenePatch)
        ]
        var diagnostics = commonDiagnostics(project: project, engine: .cocosCreator, root: root,
                                            files: files, descriptor: try GameDeveloperEngineCatalog.descriptor(for: .cocosCreator))
        if choice.isStartScene {
            diagnostics.append(.init(
                severity: .information, code: "cocos-start-scene",
                message: "The scene \(choice.name) was selected from the project's actual startScene metadata.",
                messageZhHans: "已根据工程实际的 startScene 元数据选择场景 \(choice.name)。"))
        } else if requestedScene == nil && records.count == 1 {
            diagnostics.append(.init(
                severity: .information, code: "cocos-single-scene",
                message: "The project has exactly one scene; it is the explicit installer choice.",
                messageZhHans: "工程只有一个场景；安装器明确选择该场景。"))
        } else {
            diagnostics.append(.init(
                severity: .information, code: "cocos-explicit-scene",
                message: "The scene \(choice.name) was explicitly chosen for this installation.",
                messageZhHans: "已为本次安装明确选择场景 \(choice.name)。"))
        }
        diagnostics.append(.init(
            severity: .information, code: "cocos-scene-preserved",
            message: "Only one child id and one node/component pair are inserted into the selected scene. Unknown fields, prefabs and other components keep their bytes.",
            messageZhHans: "只向所选场景插入一个子节点引用和一组节点/组件。未知字段、预制体和其他组件保持原字节。"))
        if sceneAction == .unchanged {
            diagnostics.append(.init(
                severity: .information, code: "idempotent-scene",
                message: "The selected scene already references this exact component UUID; applying creates no scene change.",
                messageZhHans: "所选场景已引用此精确组件 UUID；应用不会修改场景。"))
        }
        diagnostics.append(.init(
            severity: .warning, code: "rebuild-required",
            message: "A new Cocos Web build is required after this revision so the component is compiled and loaded.",
            messageZhHans: "此修订后需要重新构建 Cocos 网页版，组件才会被编译并加载。"))
        let scene = GameDeveloperInstrumentationScene(choice: choice)
        return .init(engineVersion: engineVersion, files: files, scene: scene,
                     diagnostics: diagnostics)
    }

    static func validate(plan: GameDeveloperProjectInstrumentationPlan,
                         templates: GameDeveloperProjectHookTemplates,
                         limits: GameDeveloperInstrumentationLimits) throws {
        guard plan.engine == .cocosCreator, let scene = plan.scene, plan.autoload == nil,
              plan.exportHandling == .notApplicable else {
            throw GameDeveloperInstrumentationError.planMismatch("Cocos plan fields")
        }
        guard plan.files.count == 3 else {
            throw GameDeveloperInstrumentationError.planMismatch("Cocos file count")
        }
        let template = try templates.template(id: "cocosBridge")
        guard let script = plan.files.first(where: { $0.kind == .helperSource }),
              script.templateResource == GameDeveloperInstrumentationConstants.cocosBridgeResource,
              script.templateSHA256 == template.sha256,
              script.outputSHA256 == template.sha256,
              script.outputBytes == template.bytes,
              script.outputData == template.data,
              script.path.value.hasSuffix(GameDeveloperInstrumentationConstants.cocosBridgePath) else {
            throw GameDeveloperInstrumentationError.planMismatch("Cocos component")
        }
        guard let meta = plan.files.first(where: { $0.kind == .generatedFile }),
              meta.path.value == script.path.value + ".meta",
              meta.templateResource == "generated:cocos-typescript-meta",
              meta.outputBytes <= limits.maximumMetadataBytes else {
            throw GameDeveloperInstrumentationError.planMismatch("Cocos meta")
        }
        guard let metaObject = try? JSONSerialization.jsonObject(with: meta.outputData) as? [String: Any],
              (metaObject["importer"] as? String) == "typescript",
              let scriptUUID = metaObject["uuid"] as? String,
              canonicalUUID(scriptUUID) != nil,
              GameDigest.sha256(meta.outputData) == meta.outputSHA256 else {
            throw GameDeveloperInstrumentationError.planMismatch("Cocos meta bytes")
        }
        guard let sceneFile = plan.files.first(where: { $0.kind == .projectPatch }),
              sceneFile.path.value.hasSuffix(scene.path.value),
              sceneFile.outputSHA256 == GameDigest.sha256(sceneFile.outputData) else {
            throw GameDeveloperInstrumentationError.planMismatch("Cocos scene patch")
        }
        do {
            _ = try CocosSceneJSON.parse(sceneFile.outputData)
            let compressed = try CocosSceneJSON.compressedUUID(scriptUUID.lowercased())
            guard String(decoding: sceneFile.outputData, as: UTF8.self).contains(compressed) else {
                throw GameDeveloperInstrumentationError.planMismatch("Cocos scene component uuid")
            }
        } catch CocosSceneJSONError.invalid(let detail) {
            throw GameDeveloperInstrumentationError.planMismatch("Cocos scene: \(detail)")
        }
    }

    // MARK: - Discovery

    private static func sceneRecords(project: GameStoredProject,
                                     repository: FileGameProjectRepository,
                                     revision: String,
                                     root: GameRelativePath?,
                                     limits: GameDeveloperInstrumentationLimits) async throws -> [SceneRecord] {
        if let root, !project.directories.contains(root) {
            throw GameDeveloperInstrumentationError.rootNotSelected(root.value)
        }
        let assets = try GameDeveloperInstrumentationPath.resolve(root, "assets")
        guard project.directories.contains(assets) else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(.cocosCreator, "assets/ is missing")
        }
        let prefix = GameDeveloperInstrumentationPath.prefix(root)
        let candidates = project.files.filter {
            $0.path.value.hasPrefix(prefix) && $0.path.value.lowercased().hasSuffix(".scene")
        }.sorted { $0.path.value < $1.path.value }
        guard candidates.count <= GameDeveloperInstrumentationConstants.cocosMaximumScenes else {
            throw GameDeveloperInstrumentationError.limitExceeded("Cocos scene count")
        }
        var scenes: [SceneRecord] = []
        var startScene: String?
        let byPath = Dictionary(project.files.map { ($0.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        if let settingsPath = try? GameDeveloperInstrumentationPath.resolve(
            root, GameDeveloperInstrumentationConstants.cocosBuildSettingsPath),
           let record = byPath[settingsPath], record.bytes <= limits.maximumMetadataBytes {
            let data = try await repository.read(project.projectID, owner: project.owner,
                                                 revision: revision, path: settingsPath)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = object["startScene"] as? String, canonicalUUID(value) != nil {
                startScene = value.lowercased()
            }
        }
        var seenIDs = Set<String>()
        for file in candidates {
            guard file.bytes > 0,
                  file.bytes <= GameDeveloperInstrumentationConstants.cocosMaximumSceneBytes else {
                continue
            }
            let metaPath = try GameRelativePath(
                file.path.value + ".meta")
            guard let metaRecord = byPath[metaPath],
                  metaRecord.bytes > 0,
                  metaRecord.bytes <= GameDeveloperInstrumentationConstants.cocosMaximumMetaBytes else {
                continue
            }
            let metaData = try await repository.read(project.projectID, owner: project.owner,
                                                     revision: revision, path: metaPath)
            guard let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                  (meta["importer"] as? String) == "scene",
                  let uuid = meta["uuid"] as? String,
                  canonicalUUID(uuid) != nil else {
                continue
            }
            let data = try await repository.read(project.projectID, owner: project.owner,
                                                 revision: revision, path: file.path)
            guard let rootObject = try? CocosSceneJSON.parse(data),
                  let array = rootObject as? [Any], array.count >= 2,
                  let asset = array[0] as? [String: Any],
                  (asset["__type__"] as? String) == "cc.SceneAsset",
                  let scene = array[1] as? [String: Any],
                  (scene["__type__"] as? String) == "cc.Scene",
                  let sceneID = scene["_id"] as? String,
                  canonicalUUID(sceneID) != nil,
                  sceneID.caseInsensitiveCompare(uuid) == .orderedSame,
                  let name = scene["_name"] as? String, !name.isEmpty,
                  seenIDs.insert(uuid.lowercased()).inserted else {
                continue
            }
            scenes.append(.init(
                choice: .init(id: uuid.lowercased(), path: file.path, name: name,
                              isStartScene: startScene == uuid.lowercased()),
                path: file.path, metaPath: metaPath, data: data))
        }
        return scenes
    }

    private static func select(records: [SceneRecord], requested: String?) throws -> SceneRecord {
        if let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let value = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = records.first(where: { $0.choice.id.caseInsensitiveCompare(value) == .orderedSame }) {
                return match
            }
            let normalized = value.hasPrefix("./") ? String(value.dropFirst(2)) : value
            if !normalized.hasPrefix("/"), !normalized.contains(".."),
               let match = records.first(where: { $0.choice.path.value == normalized }) {
                return match
            }
            throw GameDeveloperInstrumentationError.sceneNotFound(
                "\(value); available: \(records.map { $0.choice.path.value }.joined(separator: ", "))")
        }
        if let start = records.first(where: { $0.choice.isStartScene }) { return start }
        if records.count == 1 { return records[0] }
        let choices = records.map { "\($0.choice.path.value) (\($0.choice.id))" }.joined(separator: ", ")
        throw GameDeveloperInstrumentationError.sceneSelectionRequired(
            "\(records.count) scenes: \(choices)")
    }

    private static func creatorVersion(project: GameStoredProject,
                                       repository: FileGameProjectRepository,
                                       revision: String,
                                       root: GameRelativePath?,
                                       byPath: [GameRelativePath: GameProjectFile],
                                       limits: GameDeveloperInstrumentationLimits) async throws -> String {
        let path = try GameDeveloperInstrumentationPath.resolve(root, "package.json")
        guard let record = byPath[path], record.bytes <= limits.maximumMetadataBytes else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(
                .cocosCreator, "package.json is missing")
        }
        let data = try await repository.read(project.projectID, owner: project.owner,
                                             revision: revision, path: path)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GameDeveloperInstrumentationError.invalidProjectFile("package.json is not JSON")
        }
        let creator = object["creator"] as? [String: Any]
        let version = (creator?["version"] as? String) ?? (object["version"] as? String) ?? ""
        let components = version.split(separator: ".")
        guard components.count >= 2,
              Int(components[0]) == GameDeveloperInstrumentationConstants.cocosSupportedMajor,
              Int(components[1]) == GameDeveloperInstrumentationConstants.cocosSupportedMinor else {
            throw GameDeveloperInstrumentationError.unsupportedEngineVersion(
                .cocosCreator, "expected 3.8.x, found \(version.isEmpty ? "<unknown>" : version)")
        }
        return version
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        UUID(uuidString: value)
    }

    private static func metaData(uuid: String) throws -> Data {
        let text = """
        {
          "ver": "\(GameDeveloperInstrumentationConstants.cocosMetaVersion)",
          "importer": "typescript",
          "imported": true,
          "uuid": "\(uuid.lowercased())",
          "files": [],
          "subMetas": {},
          "userData": {
            "moduleId": "project:///assets/scripts/FloeDeveloper.js",
            "simulateGlobals": []
          }
        }

        """
        return Data(text.utf8)
    }

    private static func ensureFileTarget(_ path: GameRelativePath,
                                         folded: [String: GameProjectFile],
                                         project: GameStoredProject) throws {
        if project.directories.contains(path) {
            throw GameDeveloperInstrumentationError.targetIsDirectory(path)
        }
        let key = GameDeveloperInstrumentationPath.folded(path.value)
        if let collision = folded[key], collision.path != path {
            throw GameDeveloperInstrumentationError.existingFileCollision(collision.path, collision.sha256)
        }
        if let directory = project.directories.first(where: {
            $0 != path && GameDeveloperInstrumentationPath.folded($0.value) == key
        }) {
            throw GameDeveloperInstrumentationError.targetIsDirectory(directory)
        }
    }

    private static func commonDiagnostics(project: GameStoredProject, engine: GameEngineID,
                                          root: GameRelativePath?,
                                          files: [GameDeveloperProjectInstrumentationFile],
                                          descriptor: GameDeveloperEngineDescriptor)
        -> [GameDeveloperInstrumentationDiagnostic] {
        var result: [GameDeveloperInstrumentationDiagnostic] = []
        if let recorded = project.engine, recorded != engine {
            result.append(.init(
                severity: .warning, code: "engine-override",
                message: "The project records \(recorded.rawValue); the explicit selection is \(engine.rawValue). Project metadata is not rewritten.",
                messageZhHans: "工程记录为 \(recorded.rawValue)，本次显式选择为 \(engine.rawValue)。不会改写工程元数据。"))
        } else if project.engine == nil {
            result.append(.init(
                severity: .information, code: "engine-unset",
                message: "The project has no recorded engine. This hook install uses the explicit selection and does not rewrite project metadata.",
                messageZhHans: "工程尚未记录引擎。本次钩子安装使用显式选择，不改写工程元数据。"))
        }
        if let root {
            result.append(.init(
                severity: .information, code: "nested-root", path: root,
                message: "The hook is installed under the selected nested root.",
                messageZhHans: "钩子安装在所选嵌套根目录下。"))
        }
        if !files.contains(where: { $0.changed }) {
            result.append(.init(
                severity: .information, code: "idempotent",
                message: "The exact component, metadata and scene attachment are already installed. Applying this plan creates no revision.",
                messageZhHans: "精确的组件、元数据和场景挂接已安装。应用此计划不会创建修订。"))
        }
        let targets = Set(files.map(\.path))
        let untouched = project.files.filter { !targets.contains($0.path) }.count
        result.append(.init(
            severity: .information, code: "preserved",
            message: "Only the listed component, metadata and scene change; \(untouched) existing files and \(project.directories.count) directories remain.",
            messageZhHans: "只修改列出的组件、元数据和场景；保留 \(untouched) 个现有文件和 \(project.directories.count) 个目录。"))
        if descriptor.instrumentation.requiresRebuild {
            result.append(.init(
                severity: .information, code: "cocos-bridge-component",
                message: "The component uses public cc Director/Game APIs and remains inert without window.FloeDeveloper.",
                messageZhHans: "组件使用公共 cc Director/Game API，在没有 window.FloeDeveloper 时保持惰性。"))
        }
        return result
    }
}
