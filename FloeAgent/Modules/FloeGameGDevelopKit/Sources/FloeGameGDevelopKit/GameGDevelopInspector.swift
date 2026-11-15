// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GameGDevelopDiagnosticKind: String, Codable, Equatable, Sendable {
    case invalidProjectJSON
    case nestedProject
    case missingResource
    case resourceOutsideProject
    case duplicateResource
    case inputDeclaration
    case noProjectFound
    case skippedSymlink
}

public struct GameGDevelopDiagnostic: Codable, Equatable, Sendable {
    public let kind: GameGDevelopDiagnosticKind
    public let path: String?
    public let message: String
}

public struct GameGDevelopProjectCandidate: Codable, Equatable, Sendable {
    public let path: GameRelativePath
    /// Directory containing the project JSON. Resource files are resolved here.
    public let directory: GameRelativePath?
    public let summary: GameGDevelopProjectSummary
    public let depth: Int
}

public struct GameGDevelopInspection: Codable, Equatable, Sendable {
    public let projectCandidates: [GameGDevelopProjectCandidate]
    public let primaryProject: GameGDevelopProjectCandidate?
    public let inputDeclaration: GameGDevelopInputDeclaration?
    public let diagnostics: [GameGDevelopDiagnostic]
    public let scannedFiles: Int
    public let skippedDirectories: [String]

    public var hasProject: Bool { primaryProject != nil }
    public var nestedProjects: [GameGDevelopProjectCandidate] {
        guard let primary = primaryProject else { return projectCandidates }
        return projectCandidates.filter { $0.path != primary.path }
    }
}

/// Read-only, bounded identification. It inspects a source tree but never
/// imports, moves, edits, executes or deletes anything. A malformed candidate
/// is reported and another candidate can still be chosen.
public struct GameGDevelopInspector: Sendable {
    public let maximumEntries: Int
    public let maximumDepth: Int
    public let maximumProjectBytes: Int

    public init(maximumEntries: Int = 5_000, maximumDepth: Int = 6,
                maximumProjectBytes: Int = 64 * 1_024 * 1_024) throws {
        guard (1...100_000).contains(maximumEntries), (1...32).contains(maximumDepth),
              (1_024...64 * 1_024 * 1_024).contains(maximumProjectBytes) else {
            throw GameGDevelopError.invalidInput("inspector limits")
        }
        self.maximumEntries = maximumEntries
        self.maximumDepth = maximumDepth
        self.maximumProjectBytes = maximumProjectBytes
    }

    private static let skippedNames: Set<String> = [
        ".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm", "Objects"
    ]

    public func inspect(rootURL: URL) throws -> GameGDevelopInspection {
        guard rootURL.isFileURL else { throw GameGDevelopError.unsafePath("root") }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var entries: [(path: GameRelativePath, url: URL, size: Int)] = []
        var diagnostics: [GameGDevelopDiagnostic] = []
        var skipped: Set<String> = []
        var count = 0

        func walk(_ url: URL, prefix: String, depth: Int) throws {
            guard depth <= maximumDepth else { return }
            let names: [URL]
            do {
                names = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [.skipsHiddenFiles])
            } catch {
                diagnostics.append(.init(kind: .invalidProjectJSON, path: prefix,
                                         message: "directory unreadable"))
                return
            }
            for child in names.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                count += 1
                guard count <= maximumEntries else { throw GameGDevelopError.limitExceeded("inspectionEntries") }
                let values: URLResourceValues
                do {
                    values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                } catch {
                    diagnostics.append(.init(kind: .invalidProjectJSON, path: prefix + child.lastPathComponent,
                                             message: "unreadable entry"))
                    continue
                }
                if values.isSymbolicLink == true {
                    diagnostics.append(.init(kind: .skippedSymlink, path: prefix + child.lastPathComponent,
                                             message: "symlink not followed"))
                    continue
                }
                let name = child.lastPathComponent
                if values.isDirectory == true {
                    if Self.skippedNames.contains(name) { skipped.insert(name); continue }
                    try walk(child, prefix: prefix + name + "/", depth: depth + 1)
                } else {
                    let path = try GameRelativePath(prefix + name)
                    entries.append((path, child, values.fileSize ?? 0))
                }
            }
        }
        try walk(root, prefix: "", depth: 0)

        var candidates: [GameGDevelopProjectCandidate] = []
        for entry in entries where entry.path.value.lowercased().hasSuffix(".json") {
            guard entry.size > 0, entry.size <= maximumProjectBytes else { continue }
            let data: Data
            do { data = try Data(contentsOf: entry.url, options: [.mappedIfSafe]) }
            catch {
                diagnostics.append(.init(kind: .invalidProjectJSON, path: entry.path.value,
                                         message: "file unreadable"))
                continue
            }
            do {
                let document = try GameGDevelopProjectDocument(data: data)
                let directory = Self.directory(of: entry.path.value)
                candidates.append(.init(path: entry.path, directory: directory,
                                        summary: document.summary, depth: entry.path.value.split(separator: "/").count - 1))
            } catch {
                if let text = String(data: data.prefix(4_096), encoding: .utf8), text.contains("gdVersion") {
                    diagnostics.append(.init(kind: .invalidProjectJSON, path: entry.path.value,
                                             message: "GDevelop-looking JSON could not be parsed"))
                }
            }
        }
        candidates.sort {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            return $0.path.value < $1.path.value
        }
        let primary = Self.choosePrimary(candidates)
        if let primary {
            for other in candidates where other.path != primary.path {
                diagnostics.append(.init(kind: .nestedProject, path: other.path.value,
                                         message: "additional GDevelop project retained in the tree"))
            }
            let base = primary.directory.map { root.appendingPathComponent($0.value) } ?? root
            var seenNames: Set<String> = []
            for resource in primary.summary.resources {
                if !seenNames.insert(resource.name).inserted {
                    diagnostics.append(.init(kind: .duplicateResource, path: primary.path.value,
                                             message: "duplicate resource name \(resource.name)"))
                }
                let normalized = resource.file.replacingOccurrences(of: "\\", with: "/")
                guard !normalized.isEmpty, !normalized.hasPrefix("/"),
                      !normalized.split(separator: "/").contains("..") else {
                    diagnostics.append(.init(kind: .resourceOutsideProject, path: primary.path.value,
                                             message: "resource \(resource.name) has an unsafe path"))
                    continue
                }
                let fileURL = base.appendingPathComponent(normalized)
                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) || isDirectory.boolValue {
                    diagnostics.append(.init(kind: .missingResource, path: primary.path.value,
                                             message: "resource \(resource.name) is missing"))
                }
            }
        } else {
            diagnostics.append(.init(kind: .noProjectFound, path: nil,
                                     message: "no standard GDevelop project JSON found"))
        }
        var inputs: GameGDevelopInputDeclaration?
        if let primary {
            let base = primary.directory.map { root.appendingPathComponent($0.value) } ?? root
            let inputURL = base.appendingPathComponent(GameGDevelopTemplate.inputFileName)
            if let data = try? Data(contentsOf: inputURL, options: [.mappedIfSafe]) {
                do { inputs = try GameGDevelopInputDeclaration.decode(data) }
                catch {
                    diagnostics.append(.init(kind: .inputDeclaration, path: primary.path.value,
                                             message: "floe-inputs.json is not a valid declaration"))
                }
            }
        }
        let primaryWithResources = primary.map { candidate -> GameGDevelopProjectCandidate in
            let base = candidate.directory.map { root.appendingPathComponent($0.value) } ?? root
            let resources = candidate.summary.resources.map { resource -> GameGDevelopResourceSummary in
                let normalized = resource.file.replacingOccurrences(of: "\\", with: "/")
                let exists = !normalized.isEmpty && !normalized.hasPrefix("/")
                    && !normalized.split(separator: "/").contains("..")
                    && FileManager.default.fileExists(atPath: base.appendingPathComponent(normalized).path)
                return .init(name: resource.name, file: resource.file, kind: resource.kind, fileExists: exists)
            }
            let summary = GameGDevelopProjectSummary(
                name: candidate.summary.name, description: candidate.summary.description,
                projectUUID: candidate.summary.projectUUID, version: candidate.summary.version,
                firstLayout: candidate.summary.firstLayout, scenes: candidate.summary.scenes,
                resources: resources, extensionTypes: candidate.summary.extensionTypes,
                propertyKeys: candidate.summary.propertyKeys, sourceBytes: candidate.summary.sourceBytes,
                sourceSHA256: candidate.summary.sourceSHA256)
            return .init(path: candidate.path, directory: candidate.directory, summary: summary, depth: candidate.depth)
        }
        let candidatesWithResources = candidates.map { candidate -> GameGDevelopProjectCandidate in
            if let primaryWithResources, candidate.path == primaryWithResources.path { return primaryWithResources }
            return candidate
        }
        return .init(projectCandidates: candidatesWithResources,
                     primaryProject: primaryWithResources,
                     inputDeclaration: inputs,
                     diagnostics: diagnostics,
                     scannedFiles: entries.count,
                     skippedDirectories: skipped.sorted())
    }

    private static func choosePrimary(_ candidates: [GameGDevelopProjectCandidate]) -> GameGDevelopProjectCandidate? {
        guard !candidates.isEmpty else { return nil }
        let preferred = ["game.json", "project.json", "floe-game.json"]
        for name in preferred {
            if let exact = candidates.first(where: { $0.path.value == name }) { return exact }
        }
        if let rootLevel = candidates.first(where: { $0.depth == 0 }) { return rootLevel }
        for name in preferred {
            if let nested = candidates.first(where: { $0.path.value.hasSuffix("/" + name) }) { return nested }
        }
        return candidates[0]
    }

    private static func directory(of path: String) -> GameRelativePath? {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return nil }
        return try? GameRelativePath(components.dropLast().joined(separator: "/"))
    }
}
