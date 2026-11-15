// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct GameGDevelopArtifactManifest: Codable, Equatable, Sendable {
    public let engine: GameEngineID
    public let sdkVersion: String?
    public let directory: String
    public let entry: GameRelativePath
    public let files: [GameProjectFile]
    public let totalBytes: Int
    /// sha256 over sorted `path:sha256:bytes:executable` records.
    public let digest: String
    public let project: GameGDevelopProjectSummary
    public let inputDeclaration: GameGDevelopInputDeclaration?
    public let resources: [GameGDevelopResourceSummary]
    public let hasGDevelopLicense: Bool
    public let hasRuntimeCode: Bool
    public let hasDataFile: Bool

    public func seal(source: GameProjectContext, to target: URL) throws -> GameWebArtifactPackage {
        guard entry.value == "index.html" else { throw GameGDevelopError.artifactIncomplete("entry") }
        return try GameWebArtifactPackage.build(source: source, engine: engine, entry: entry,
                                               to: target, contentRoot: URL(fileURLWithPath: directory))
    }
}

public enum GameGDevelopArtifactVerifier {
    public static let maximumEntries = 20_000
    public static let maximumFileBytes = 64 * 1_024 * 1_024
    public static let maximumTotalBytes = 512 * 1_024 * 1_024

    /// Verifies a real exported GDevelop Web folder: the official runtime/data
    /// files, a standard project payload extracted from data.js, resource
    /// presence, license notice and (optionally) the truthful input declaration.
    /// It never executes the artifact; actual rendering/input acceptance belongs
    /// to the host/WebKit owner.
    public static func verify(directory: URL,
                              expectedProjectDataSHA256: String? = nil,
                              expectedInputs: GameGDevelopInputDeclaration? = nil,
                              sdkVersion: String? = nil) throws -> GameGDevelopArtifactManifest {
        guard directory.isFileURL else { throw GameGDevelopError.unsafePath("artifact") }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var entries: [(path: GameRelativePath, url: URL, size: Int, executable: Bool)] = []
        var total = 0
        var names: [String: GameRelativePath] = [:]

        func walk(_ url: URL, prefix: String, depth: Int) throws {
            guard depth <= 32 else { throw GameGDevelopError.limitExceeded("artifactDepth") }
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [])
            } catch { throw GameGDevelopError.unreadable(prefix) }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation()
                guard entries.count < maximumEntries else { throw GameGDevelopError.limitExceeded("artifactEntries") }
                let values: URLResourceValues
                do {
                    values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                } catch { throw GameGDevelopError.unreadable(prefix + child.lastPathComponent) }
                guard values.isSymbolicLink != true else {
                    throw GameGDevelopError.artifactMismatch("symlink in artifact: \(prefix + child.lastPathComponent)")
                }
                let name = child.lastPathComponent
                if values.isDirectory == true {
                    try walk(child, prefix: prefix + name + "/", depth: depth + 1)
                } else {
                    let path = try GameRelativePath(prefix + name)
                    let size = values.fileSize ?? 0
                    guard size >= 0, size <= maximumFileBytes else { throw GameGDevelopError.limitExceeded(path.value) }
                    guard total <= maximumTotalBytes - size else { throw GameGDevelopError.limitExceeded("artifactBytes") }
                    total += size
                    guard names[path.value] == nil else { throw GameGDevelopError.duplicate(path.value) }
                    names[path.value] = path
                    let executable = isExecutable(child)
                    entries.append((path: path, url: child, size: size, executable: executable))
                }
            }
        }
        try walk(root, prefix: "", depth: 0)
        guard let index = entries.first(where: { $0.path.value == "index.html" }),
              let dataEntry = entries.first(where: { $0.path.value == "data.js" }),
              let gd = entries.first(where: { $0.path.value == "gd.js" }),
              let license = entries.first(where: { $0.path.value == "LICENSE.GDevelop.txt" }) else {
            throw GameGDevelopError.artifactIncomplete("index.html/data.js/gd.js/LICENSE.GDevelop.txt")
        }
        let codeEntries = entries.filter { $0.path.value.hasPrefix("code") && $0.path.value.hasSuffix(".js") }
        guard !codeEntries.isEmpty else { throw GameGDevelopError.artifactIncomplete("compiled code*.js") }
        let hasCompiledLogic = try codeEntries.contains { entry in
            guard let text = String(data: try Data(contentsOf: entry.url), encoding: .utf8) else { return false }
            return text.contains("gdjs.") && text.contains("eventsList")
        }
        guard hasCompiledLogic else { throw GameGDevelopError.artifactIncomplete("compiled GDJS event code") }
        let hasPixi = entries.contains { $0.path.value.hasSuffix("pixi.js") }
        guard hasPixi else { throw GameGDevelopError.artifactIncomplete("pixi runtime") }
        guard dataEntry.size <= 32 * 1_024 * 1_024 else { throw GameGDevelopError.limitExceeded("data.js") }
        let dataBytes = try Data(contentsOf: dataEntry.url, options: [.mappedIfSafe])
        let projectBytes = try extractProjectData(from: dataBytes)
        let project = try GameGDevelopProjectDocument(data: projectBytes)
        if let expectedProjectDataSHA256,
           GameDigest.sha256(projectBytes) != expectedProjectDataSHA256 {
            throw GameGDevelopError.artifactMismatch("exported project data digest")
        }
        guard project.summary.isStandardGDJSProject else {
            throw GameGDevelopError.artifactIncomplete("standard project data")
        }
        // Resource names are logical; exported files use the resource `file`
        // basename at the artifact root (official exporter behavior).
        var missingResources: [String] = []
        var resources: [GameGDevelopResourceSummary] = []
        for resource in project.summary.resources {
            let file = resource.file.replacingOccurrences(of: "\\", with: "/")
            let base = (file as NSString).lastPathComponent
            let exists = !base.isEmpty && entries.contains(where: { $0.path.value == base })
            if !exists { missingResources.append(resource.name) }
            resources.append(.init(name: resource.name, file: resource.file, kind: resource.kind, fileExists: exists))
        }
        guard missingResources.isEmpty else {
            throw GameGDevelopError.artifactIncomplete("missing resources: \(missingResources.joined(separator: ", "))")
        }
        let inputsURL = root.appendingPathComponent(GameGDevelopTemplate.inputFileName)
        let inputs: GameGDevelopInputDeclaration?
        if let data = try? Data(contentsOf: inputsURL) {
            inputs = try GameGDevelopInputDeclaration.decode(data)
        } else {
            inputs = nil
        }
        if let expectedInputs {
            guard inputs == expectedInputs else {
                throw GameGDevelopError.artifactMismatch("floe-inputs.json")
            }
        }
        let indexBytes = try Data(contentsOf: index.url, options: [.mappedIfSafe])
        let indexText = String(data: indexBytes, encoding: .utf8) ?? ""
        guard indexText.contains("gdjs.projectData"), indexText.contains("gdjs.RuntimeGame"),
              indexText.contains("bindStandardEvents") else {
            throw GameGDevelopError.artifactIncomplete("index.html is not the official GDJS runtime entry")
        }
        let files = try entries.map { item -> GameProjectFile in
            let bytes = try Data(contentsOf: item.url, options: [.mappedIfSafe])
            return GameProjectFile(path: item.path, sha256: GameDigest.sha256(bytes),
                                   bytes: item.size, executable: item.executable)
        }
        let canonical = files.sorted { $0.path.value < $1.path.value }
            .map { "\($0.path.value):\($0.sha256):\($0.bytes):\($0.executable)" }
            .joined(separator: "\n")
        return .init(engine: .gdevelop, sdkVersion: sdkVersion, directory: root.path,
                     entry: index.path, files: files, totalBytes: total,
                     digest: GameDigest.sha256(Data(canonical.utf8)), project: project.summary,
                     inputDeclaration: inputs, resources: resources,
                     hasGDevelopLicense: license.size > 0, hasRuntimeCode: gd.size > 0,
                     hasDataFile: dataEntry.size > 0)
    }

    /// `data.js` is `gdjs.projectData = <JSON>; gdjs.runtimeGameOptions = ...;`
    static func extractProjectData(from data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "gdjs.projectData = ") else {
            throw GameGDevelopError.artifactIncomplete("data.js projectData")
        }
        let remainder = text[start.upperBound...]
        let marker = remainder.range(of: "gdjs.runtimeGameOptions", options: .backwards)
            ?? remainder.range(of: ";\n", options: .backwards)
        guard let end = marker else { throw GameGDevelopError.artifactIncomplete("data.js terminator") }
        var json = String(remainder[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasSuffix(";") { json.removeLast() }
        guard !json.isEmpty, json.hasPrefix("{") else {
            throw GameGDevelopError.artifactIncomplete("data.js projectData JSON")
        }
        return Data(json.utf8)
    }

    private static func isExecutable(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return (permissions.intValue & 0o111) != 0
    }
}
