// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

enum GodotProjectInstrumentation {
    struct Result: Sendable {
        let engineVersion: String
        let files: [GameDeveloperProjectInstrumentationFile]
        let autoload: GameDeveloperGodotAutoloadPlan
    }

    static func inspect(project: GameStoredProject,
                        repository: FileGameProjectRepository,
                        revision: String,
                        root: GameRelativePath?,
                        templates: GameDeveloperInstrumentationTemplates,
                        limits: GameDeveloperInstrumentationLimits) async throws -> Result {
        if let root {
            guard project.directories.contains(root) else {
                throw GameDeveloperInstrumentationError.rootNotSelected(root.value)
            }
        }
        let byPath = Dictionary(project.files.map { ($0.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        let foldedFiles = Dictionary(project.files.map {
            (GameDeveloperInstrumentationPath.folded($0.path.value), $0)
        }, uniquingKeysWith: { first, _ in first })
        let projectPath = try GameDeveloperInstrumentationPath.resolve(
            root, GameDeveloperInstrumentationConstants.godotProjectPath)
        let helperPath = try GameDeveloperInstrumentationPath.resolve(
            root, GameDeveloperInstrumentationConstants.godotAutoloadPath)
        guard let projectRecord = byPath[projectPath] else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(
                .godot, "project.godot is missing")
        }
        guard projectRecord.bytes <= limits.maximumMetadataBytes else {
            throw GameDeveloperInstrumentationError.limitExceeded(projectPath.value)
        }
        try Task.checkCancellation()
        let original = try await repository.read(project.projectID, owner: project.owner,
                                                 revision: revision, path: projectPath)
        let parsed = try GodotProjectFile.parse(original, maximumBytes: limits.maximumMetadataBytes)
        if project.directories.contains(helperPath) {
            throw GameDeveloperInstrumentationError.targetIsDirectory(helperPath)
        }
        let helperKey = GameDeveloperInstrumentationPath.folded(helperPath.value)
        if let folded = foldedFiles[helperKey], folded.path != helperPath {
            throw GameDeveloperInstrumentationError.existingFileCollision(
                folded.path, folded.sha256)
        }
        if let directory = project.directories.first(where: {
            $0 != helperPath && GameDeveloperInstrumentationPath.folded($0.value) == helperKey
        }) {
            throw GameDeveloperInstrumentationError.targetIsDirectory(directory)
        }
        let helper = try templates.template(id: "godotAutoload")
        let existingHelper = byPath[helperPath]
        let helperInstalled = existingHelper.map {
            $0.sha256 == helper.sha256 && $0.bytes == helper.bytes
        } ?? false
        if let existingHelper, !helperInstalled {
            throw GameDeveloperInstrumentationError.existingFileCollision(
                helperPath, existingHelper.sha256)
        }

        let patched = parsed.patchedData ?? original
        let projectAction: GameDeveloperInstrumentationFileAction = parsed.changed ? .patch : .unchanged
        let helperAction: GameDeveloperInstrumentationFileAction = helperInstalled ? .unchanged : .create
        let inlineLine = parsed.insertLine
        let files: [GameDeveloperProjectInstrumentationFile] = [
            .init(path: projectPath,
                  kind: .projectPatch,
                  action: projectAction,
                  templateResource: "inline:project.godot[autoload]",
                  templateSHA256: GameDigest.sha256(Data(inlineLine.utf8)),
                  existingSHA256: projectRecord.sha256,
                  outputSHA256: GameDigest.sha256(patched),
                  outputBytes: patched.count,
                  outputData: patched),
            .init(path: helperPath,
                  kind: .helperSource,
                  action: helperAction,
                  templateResource: "Project/godot-floe-developer.gd",
                  templateSHA256: helper.sha256,
                  existingSHA256: existingHelper?.sha256,
                  outputSHA256: helper.sha256,
                  outputBytes: helper.bytes,
                  outputData: helper.data)
        ]
        let autoload = GameDeveloperGodotAutoloadPlan(
            section: "autoload",
            key: GameDeveloperInstrumentationConstants.godotAutoloadKey,
            value: GameDeveloperInstrumentationConstants.godotAutoloadValue,
            line: parsed.insertLine,
            previousValue: parsed.previousValue,
            changed: parsed.changed,
            lineEnding: parsed.lineEnding.rawValue,
            hadBOM: parsed.hadBOM)
        return .init(engineVersion: "Godot 4 (config_version=\(parsed.configVersion))",
                     files: files, autoload: autoload)
    }
}
