// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

enum UnityProjectInstrumentation {
    struct Result: Sendable {
        let engineVersion: String
        let files: [GameDeveloperProjectInstrumentationFile]
    }

    static func inspect(project: GameStoredProject,
                        repository: FileGameProjectRepository,
                        revision: String,
                        root: GameRelativePath?,
                        templates: GameDeveloperInstrumentationTemplates,
                        limits: GameDeveloperInstrumentationLimits) async throws -> Result {
        let prefix = GameDeveloperInstrumentationPath.prefix(root)
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
        let versionPath = try GameDeveloperInstrumentationPath.resolve(
            root, "ProjectSettings/ProjectVersion.txt")
        let assetsPath = try GameDeveloperInstrumentationPath.resolve(root, "Assets")
        guard byPath[versionPath] != nil else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(
                .unity, "ProjectSettings/ProjectVersion.txt is missing")
        }
        guard project.directories.contains(assetsPath) else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(.unity, "Assets/ is missing")
        }
        guard let versionRecord = byPath[versionPath],
              versionRecord.bytes <= limits.maximumMetadataBytes else {
            throw GameDeveloperInstrumentationError.limitExceeded(versionPath.value)
        }
        try Task.checkCancellation()
        let versionData = try await repository.read(project.projectID, owner: project.owner,
                                                    revision: revision, path: versionPath)
        guard let versionText = String(data: versionData, encoding: .utf8) else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(
                .unity, "ProjectSettings/ProjectVersion.txt is not UTF-8")
        }
        let engineVersion = try parseVersion(versionText)
        try await rejectDuplicateHelpers(project: project, repository: repository,
                                         revision: revision, prefix: prefix,
                                         root: root, limits: limits)

        let specifications: [(id: String, path: String, resource: String)] = [
            (id: "unityJSLibrary",
             path: GameDeveloperInstrumentationConstants.unityJSLibraryPath,
             resource: "Project/unity-floe-developer.jslib"),
            (id: "unityBridge",
             path: GameDeveloperInstrumentationConstants.unityBridgePath,
             resource: "Project/unity-floe-developer.cs"),
            (id: "unityBehaviour",
             path: GameDeveloperInstrumentationConstants.unityBehaviourPath,
             resource: "Project/unity-floe-developer-behaviour.cs")
        ]
        var files: [GameDeveloperProjectInstrumentationFile] = []
        for specification in specifications {
            let template = try templates.template(id: specification.id)
            let target = try GameDeveloperInstrumentationPath.resolve(root, specification.path)
            if project.directories.contains(target) {
                throw GameDeveloperInstrumentationError.targetIsDirectory(target)
            }
            let key = GameDeveloperInstrumentationPath.folded(target.value)
            if let folded = foldedFiles[key], folded.path != target {
                throw GameDeveloperInstrumentationError.existingFileCollision(
                    folded.path, folded.sha256)
            }
            if let directory = project.directories.first(where: {
                $0 != target && GameDeveloperInstrumentationPath.folded($0.value) == key
            }) {
                throw GameDeveloperInstrumentationError.targetIsDirectory(directory)
            }
            let existing = byPath[target]
            let same = existing.map {
                $0.sha256 == template.sha256 && $0.bytes == template.bytes
            } ?? false
            if let existing, !same {
                throw GameDeveloperInstrumentationError.existingFileCollision(
                    target, existing.sha256)
            }
            files.append(.init(
                path: target,
                kind: .helperSource,
                action: same ? .unchanged : .create,
                templateResource: specification.resource,
                templateSHA256: template.sha256,
                existingSHA256: existing?.sha256,
                outputSHA256: template.sha256,
                outputBytes: template.bytes,
                outputData: template.data))
        }
        return .init(engineVersion: engineVersion, files: files)
    }

    private static func rejectDuplicateHelpers(project: GameStoredProject,
                                               repository: FileGameProjectRepository,
                                               revision: String,
                                               prefix: String,
                                               root: GameRelativePath?,
                                               limits: GameDeveloperInstrumentationLimits) async throws {
        let jslibTarget = try GameDeveloperInstrumentationPath.resolve(
            root, GameDeveloperInstrumentationConstants.unityJSLibraryPath)
        let bridgeTarget = try GameDeveloperInstrumentationPath.resolve(
            root, GameDeveloperInstrumentationConstants.unityBridgePath)
        let behaviourTarget = try GameDeveloperInstrumentationPath.resolve(
            root, GameDeveloperInstrumentationConstants.unityBehaviourPath)
        let targets: Set<GameRelativePath> = [jslibTarget, bridgeTarget, behaviourTarget]
        var scannedFiles = 0
        var scannedBytes = 0
        for file in project.files.sorted(by: { $0.path.value < $1.path.value }) {
            try Task.checkCancellation()
            guard file.path.value.hasPrefix(prefix), !targets.contains(file.path) else { continue }
            let relative = GameDeveloperInstrumentationPath.relative(file.path, prefix: prefix)
            guard relative.hasSuffix(".cs") || relative.hasSuffix(".jslib") else { continue }
            guard scannedFiles < limits.maximumDependencyScanFiles,
                  file.bytes <= limits.maximumMetadataBytes,
                  scannedBytes <= limits.maximumDependencyScanBytes - file.bytes else {
                throw GameDeveloperInstrumentationError.limitExceeded("Unity source duplicate scan")
            }
            let data = try await repository.read(project.projectID, owner: project.owner,
                                                 revision: revision, path: file.path)
            scannedFiles += 1
            scannedBytes += data.count
            guard let text = String(data: data, encoding: .utf8) else { continue }
            if relative.hasSuffix(".cs") {
                for symbol in ["FloeDeveloperBridge", "FloeDeveloperBridgeBehaviour"] where
                    declaresClass(text, name: symbol) {
                    throw GameDeveloperInstrumentationError.duplicateHelperDefinition(file.path, symbol)
                }
            } else if text.contains("FloeDeveloperRegister") {
                throw GameDeveloperInstrumentationError.duplicateHelperDefinition(
                    file.path, "FloeDeveloperRegister")
            }
        }
    }

    private static func declaresClass(_ text: String, name: String) -> Bool {
        let pattern = "\\bclass\\s+" + NSRegularExpression.escapedPattern(for: name) + "\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func parseVersion(_ text: String) throws -> String {
        let normalized = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = normalized.split(whereSeparator: \.isNewline)
        let prefixes = ["m_EditorVersion:", "m_EditorVersionWithRevision:"]
        var found: Substring?
        for prefix in prefixes {
            if let line = lines.first(where: { $0.hasPrefix(prefix) }) {
                found = line
                break
            }
        }
        guard let line = found else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(
                .unity, "ProjectVersion.txt has no m_EditorVersion")
        }
        let remainder: Substring
        if line.hasPrefix("m_EditorVersion:") {
            remainder = line.dropFirst("m_EditorVersion:".count)
        } else {
            remainder = line.dropFirst("m_EditorVersionWithRevision:".count)
        }
        guard let token = remainder.split(whereSeparator: \.isWhitespace).first else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(
                .unity, "ProjectVersion.txt has an empty version")
        }
        let parts = token.split(separator: ".")
        let patchText = parts.count >= 3 ? String(parts[2]) : "0"
        let patchDigits = patchText.prefix(while: { $0.isNumber })
        guard parts.count >= 2,
              let major = Int(parts[0]), let minor = Int(parts[1]),
              !patchDigits.isEmpty, Int(patchDigits) != nil else {
            throw GameDeveloperInstrumentationError.rootUnrecognized(
                .unity, "ProjectVersion.txt has an invalid version \(token)")
        }
        if major < GameDeveloperInstrumentationConstants.unityMinimumMajor
            || (major == GameDeveloperInstrumentationConstants.unityMinimumMajor
                && minor < GameDeveloperInstrumentationConstants.unityMinimumMinor) {
            throw GameDeveloperInstrumentationError.unsupportedEngineVersion(
                .unity, "editor \(token) is older than 2019.4")
        }
        return String(token)
    }
}
