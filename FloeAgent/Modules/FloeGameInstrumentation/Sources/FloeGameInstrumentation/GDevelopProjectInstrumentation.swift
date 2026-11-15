// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameDeveloperCore

/// GDevelop source projects are not rewritten. The installer records the exact
/// reviewed bridge in the project revision; the exporter and Web run preparer
/// stamp the same bytes into a private playable copy. This type also
/// distinguishes an imported playable export (decorated at run time) from
/// source JSON that still needs the official SDK export.
enum GDevelopProjectInstrumentation {
    struct Result: Sendable {
        let engineVersion: String
        let files: [GameDeveloperProjectInstrumentationFile]
        let exportHandling: GameDeveloperInstrumentationExportHandling
        let diagnostics: [GameDeveloperInstrumentationDiagnostic]
    }

    static func inspect(project: GameStoredProject,
                        repository: FileGameProjectRepository,
                        revision: String,
                        root: GameRelativePath?,
                        templates: GameDeveloperProjectHookTemplates,
                        limits: GameDeveloperInstrumentationLimits) async throws -> Result {
        if let root, !project.directories.contains(root) {
            throw GameDeveloperInstrumentationError.rootNotSelected(root.value)
        }
        let prefix = GameDeveloperInstrumentationPath.prefix(root)
        let byPath = Dictionary(project.files.map { ($0.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        let foldedFiles = Dictionary(project.files.map {
            (GameDeveloperInstrumentationPath.folded($0.path.value), $0)
        }, uniquingKeysWith: { first, _ in first })
        let relativeFiles = project.files
            .filter { $0.path.value.hasPrefix(prefix) }
            .map { GameDeveloperInstrumentationPath.relative($0.path, prefix: prefix) }
            .filter { $0 != "" }

        let projectPath = try await standardProject(in: relativeFiles, prefix: prefix,
                                                    byPath: byPath, repository: repository,
                                                    project: project, revision: revision,
                                                    limits: limits)
        let export = try await playableExport(in: relativeFiles, prefix: prefix,
                                              byPath: byPath, repository: repository,
                                              project: project, revision: revision,
                                              limits: limits)
        let handling: GameDeveloperInstrumentationExportHandling
        if projectPath != nil && export != nil {
            handling = .sourceWithExistingExport
        } else if projectPath != nil {
            handling = .sourceRequiresExport
        } else if export != nil {
            handling = .alreadyExportedPlayable
        } else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(
                .gdevelop,
                "no game.json/layouts source project and no complete GDJS Web export (index.html, data.js, gd.js, code*.js)")
        }

        let helper = try templates.template(id: "gdevelopBridge")
        let target = try GameDeveloperInstrumentationPath.resolve(
            root, GameDeveloperInstrumentationConstants.gdevelopBridgePath)
        if project.directories.contains(target) {
            throw GameDeveloperInstrumentationError.targetIsDirectory(target)
        }
        let key = GameDeveloperInstrumentationPath.folded(target.value)
        if let folded = foldedFiles[key], folded.path != target {
            throw GameDeveloperInstrumentationError.existingFileCollision(folded.path, folded.sha256)
        }
        if let directory = project.directories.first(where: {
            $0 != target && GameDeveloperInstrumentationPath.folded($0.value) == key
        }) {
            throw GameDeveloperInstrumentationError.targetIsDirectory(directory)
        }
        let existing = byPath[target]
        let installed = existing.map { $0.sha256 == helper.sha256 && $0.bytes == helper.bytes } ?? false
        if let existing, !installed {
            throw GameDeveloperInstrumentationError.existingFileCollision(target, existing.sha256)
        }
        let file = GameDeveloperProjectInstrumentationFile(
            path: target, kind: .helperSource,
            action: installed ? .unchanged : .create,
            templateResource: GameDeveloperInstrumentationConstants.gdevelopBridgeResource,
            templateSHA256: helper.sha256, existingSHA256: existing?.sha256,
            outputSHA256: helper.sha256, outputBytes: helper.bytes, outputData: helper.data)

        let engineVersion = try await version(for: handling, sourcePath: projectPath,
                                              byPath: byPath, repository: repository,
                                              project: project, revision: revision,
                                              limits: limits, prefix: prefix)
        var diagnostics = commonDiagnostics(project: project, engine: .gdevelop,
                                            root: root, file: file,
                                            descriptor: try GameDeveloperEngineCatalog.descriptor(for: .gdevelop))
        switch handling {
        case .sourceRequiresExport:
            diagnostics.append(.init(
                severity: .information, code: "gdevelop-source-export",
                message: "The original project JSON is not modified. Export the project with the official GDevelop 5.6.287 SDK; the host exporter then stamps the reviewed dormant bridge into the private playable copy.",
                messageZhHans: "不会修改原始工程 JSON。请使用官方 GDevelop 5.6.287 SDK 导出；宿主导出器随后把审核过的惰性桥写入私有试玩副本。"))
            diagnostics.append(.init(
                severity: .warning, code: "rebuild-required",
                message: "A new GDevelop Web export is required before the bridge can run.",
                messageZhHans: "桥运行前需要重新导出 GDevelop 网页版。"))
        case .alreadyExportedPlayable:
            diagnostics.append(.init(
                severity: .information, code: "gdevelop-already-exported",
                message: "This root is already a complete playable GDJS export. No engine export is needed: the Web run preparer stamps the bridge into a private copy and the original export bytes stay unchanged.",
                messageZhHans: "此根目录已是完整可玩的 GDJS 导出。无需再次导出：网页运行准备器会把桥写入私有副本，原始导出字节保持不变。"))
            diagnostics.append(.init(
                severity: .information, code: "gdevelop-no-rebuild",
                message: "No rebuild is required for this already-exported playable game.",
                messageZhHans: "此已导出可玩游戏不需要重新构建。"))
        case .sourceWithExistingExport:
            diagnostics.append(.init(
                severity: .information, code: "gdevelop-existing-export",
                message: "A source project and an existing export are both present. The source export route remains authoritative; Floe never edits the existing export folder in place.",
                messageZhHans: "同时存在源工程与现有导出。以源工程导出路由为准；Floe 不会原地修改现有导出目录。"))
            diagnostics.append(.init(
                severity: .warning, code: "rebuild-required",
                message: "Re-exporting the source project produces the private decorated playable copy.",
                messageZhHans: "重新导出源工程会生成私有装饰后的试玩副本。"))
        case .notApplicable:
            break
        }
        return .init(engineVersion: engineVersion, files: [file],
                     exportHandling: handling, diagnostics: diagnostics)
    }

    static func validate(plan: GameDeveloperProjectInstrumentationPlan,
                         templates: GameDeveloperProjectHookTemplates,
                         limits: GameDeveloperInstrumentationLimits) throws {
        guard plan.engine == .gdevelop, plan.scene == nil, plan.autoload == nil else {
            throw GameDeveloperInstrumentationError.planMismatch("GDevelop plan fields")
        }
        guard plan.exportHandling == .sourceRequiresExport
                || plan.exportHandling == .alreadyExportedPlayable
                || plan.exportHandling == .sourceWithExistingExport else {
            throw GameDeveloperInstrumentationError.planMismatch("GDevelop export handling")
        }
        let helper = try templates.template(id: "gdevelopBridge")
        guard plan.files.count == 1,
              let file = plan.files.first,
              file.kind == .helperSource,
              file.path.value.hasSuffix(GameDeveloperInstrumentationConstants.gdevelopBridgePath),
              file.templateResource == GameDeveloperInstrumentationConstants.gdevelopBridgeResource,
              file.templateSHA256 == helper.sha256,
              file.outputSHA256 == helper.sha256,
              file.outputBytes == helper.bytes,
              file.outputData == helper.data else {
            throw GameDeveloperInstrumentationError.planMismatch("GDevelop bridge file")
        }
        guard file.outputBytes <= limits.maximumMetadataBytes else {
            throw GameDeveloperInstrumentationError.limitExceeded("GDevelop bridge")
        }
    }

    // MARK: - Detection

    private static func standardProject(in relativeFiles: [String], prefix: String,
                                        byPath: [GameRelativePath: GameProjectFile],
                                        repository: FileGameProjectRepository,
                                        project: GameStoredProject, revision: String,
                                        limits: GameDeveloperInstrumentationLimits) async throws -> GameRelativePath? {
        let candidates = relativeFiles.filter {
            $0.lowercased().hasSuffix(".json") && $0.split(separator: "/").count <= 2
        }.sorted {
            let left = ($0 as NSString).lastPathComponent.lowercased() == "game.json" ? 0 : 1
            let right = ($1 as NSString).lastPathComponent.lowercased() == "game.json" ? 0 : 1
            if left != right { return left < right }
            return $0 < $1
        }
        var examined = 0
        for relative in candidates {
            guard examined < GameDeveloperInstrumentationConstants.gdevelopMaximumProjectCandidates else { break }
            let path = try GameDeveloperInstrumentationPath.resolve(nil, prefix + relative)
            guard let record = byPath[path],
                  record.bytes > 0,
                  record.bytes <= GameDeveloperInstrumentationConstants.gdevelopMaximumProjectJSONBytes else {
                continue
            }
            examined += 1
            let data = try await repository.read(project.projectID, owner: project.owner,
                                                 revision: revision, path: path)
            guard data.count <= GameDeveloperInstrumentationConstants.gdevelopMaximumProjectJSONBytes,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["gdVersion"] is [String: Any],
                  object["layouts"] is [[String: Any]],
                  let properties = object["properties"] as? [String: Any],
                  (properties["name"] as? String)?.isEmpty == false else {
                continue
            }
            return path
        }
        return nil
    }

    private static func playableExport(in relativeFiles: [String], prefix: String,
                                       byPath: [GameRelativePath: GameProjectFile],
                                       repository: FileGameProjectRepository,
                                       project: GameStoredProject, revision: String,
                                       limits: GameDeveloperInstrumentationLimits) async throws -> GameRelativePath? {
        let names = Set(relativeFiles.map { ($0 as NSString).lastPathComponent.lowercased() })
        guard names.contains("index.html"), names.contains("data.js"), names.contains("gd.js"),
              names.contains("license.gdevelop.txt"),
              relativeFiles.contains(where: {
                  let name = ($0 as NSString).lastPathComponent.lowercased()
                  return name.hasPrefix("code") && name.hasSuffix(".js")
              }) else {
            return nil
        }
        let indexPath = try GameDeveloperInstrumentationPath.resolve(nil, prefix + "index.html")
        guard let indexRecord = byPath[indexPath],
              indexRecord.bytes > 0,
              indexRecord.bytes <= 8 * 1_024 * 1_024 else {
            return nil
        }
        let data = try await repository.read(project.projectID, owner: project.owner,
                                             revision: revision, path: indexPath)
        guard let text = String(data: data, encoding: .utf8),
              text.contains("gdjs.projectData"), text.contains("gdjs.RuntimeGame") else {
            return nil
        }
        return indexPath
    }

    private static func version(for handling: GameDeveloperInstrumentationExportHandling,
                                sourcePath: GameRelativePath?,
                                byPath: [GameRelativePath: GameProjectFile],
                                repository: FileGameProjectRepository,
                                project: GameStoredProject, revision: String,
                                limits: GameDeveloperInstrumentationLimits,
                                prefix: String) async throws -> String {
        if let sourcePath {
            let data = try await repository.read(project.projectID, owner: project.owner,
                                                 revision: revision, path: sourcePath)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["gdVersion"] as? [String: Any] {
                let major = version["major"] as? Int ?? 0
                let minor = version["minor"] as? Int ?? 0
                let revisionNumber = version["revision"] as? Int ?? 0
                let build = version["build"] as? Int ?? 0
                return "GDevelop \(major).\(minor).\(revisionNumber) build \(build)"
            }
            return "GDevelop project"
        }
        _ = handling
        return "GDevelop Web export"
    }

    private static func commonDiagnostics(project: GameStoredProject, engine: GameEngineID,
                                          root: GameRelativePath?,
                                          file: GameDeveloperProjectInstrumentationFile,
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
        if !file.changed {
            result.append(.init(
                severity: .information, code: "idempotent",
                message: "The exact helper bytes are already installed. Applying this plan creates no revision.",
                messageZhHans: "精确的辅助文件字节已安装。应用此计划不会创建修订。"))
        }
        let targets = Set([file.path])
        let untouched = project.files.filter { !targets.contains($0.path) }.count
        result.append(.init(
            severity: .information, code: "preserved",
            message: "Only the listed helper file changes; \(untouched) existing files and \(project.directories.count) directories remain in the revision.",
            messageZhHans: "只修改列出的辅助文件；修订中保留 \(untouched) 个现有文件和 \(project.directories.count) 个目录。"))
        if descriptor.instrumentation.requiresRebuild {
            result.append(.init(
                severity: .information, code: "gdevelop-bridge-source",
                message: "The exporter embeds these exact reviewed bytes; the project copy is provenance and is not executed by the game.",
                messageZhHans: "导出器嵌入这些精确的审核字节；工程副本用于来源记录，不会被游戏执行。"))
        }
        return result
    }
}
