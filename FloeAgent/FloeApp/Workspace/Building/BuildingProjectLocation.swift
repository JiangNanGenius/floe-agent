// SPDX-License-Identifier: MPL-2.0
// FloeApp — on-disk location of a building/interior project.
//
// Every App entry that opens a building project resolves the SAME folder here:
// one project per CAD document under the workspace root, and one furniture
// library per workspace. No live session is cached in this type, so another
// chat/workspace always mounts the project through the project service's own
// file lock, generation check and recovery journal instead of sharing UI state.

#if canImport(UIKit)
import Foundation
import FloeCore
import FloeCAD

@MainActor
enum BuildingProjectLocation {
    static let containerName = "Building Projects"
    static let assetLibraryName = "Asset Library"

    static func container(workspaceRoot: URL) -> URL {
        workspaceRoot.standardizedFileURL
            .appendingPathComponent(containerName, isDirectory: true)
    }

    static func assetLibrary(workspaceRoot: URL) -> URL {
        container(workspaceRoot: workspaceRoot)
            .appendingPathComponent(assetLibraryName, isDirectory: true)
    }

    /// Stable for the document's workspace-relative path, so the same project
    /// survives an app container move or reinstall. Editing, saving or renaming
    /// the drawing's display name never moves an existing project.
    static func projectDirectory(for document: FloeCADDocument, workspaceRoot: URL) -> URL {
        let source = document.url.standardizedFileURL
        let root = workspaceRoot.standardizedFileURL
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let projects = container(workspaceRoot: root)
        let key = sourceKey(for: resolvedSource, relativeTo: resolvedRoot)
        let directory = projects.appendingPathComponent(folderName(for: resolvedSource, key: key), isDirectory: true)
        let originalName = folderName(for: source, key: sourceKey(for: source, relativeTo: root))
        if originalName != directory.lastPathComponent {
            let original = projects.appendingPathComponent(originalName, isDirectory: true)
            if FileManager.default.fileExists(atPath: original.path) { return original }
        }
        if FileManager.default.fileExists(atPath: directory.path) { return directory }

        // Older entries hashed the incoming URL spelling. A workspace alias
        // could therefore classify its own drawing as an external file.
        let previous = [
            folderName(for: source, key: "external:" + source.path),
            folderName(for: resolvedSource, key: "external:" + resolvedSource.path)
        ]
        for name in previous where name != directory.lastPathComponent {
            let existing = projects.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: existing.path) { return existing }
        }
        return directory
    }

    private static func sourceKey(for source: URL, relativeTo root: URL) -> String {
        let path = source.pathComponents
        let parent = root.pathComponents
        guard path.count > parent.count, path.starts(with: parent) else { return "external:" + source.path }
        return path.dropFirst(parent.count).joined(separator: "/")
    }

    private static func folderName(for source: URL, key: String) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        let digest = String(FloeDigest.sha256Hex(Data(key.utf8)).prefix(8))
        return "\(sanitized(stem))-\(digest)"
    }

    static func projectName(for document: FloeCADDocument) -> String {
        let name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? sanitized(document.url.deletingPathExtension().lastPathComponent) : name
    }

    /// Keep letters (including CJK), digits and single separators. A user
    /// drawing name can contain slashes, colons or control characters that
    /// must never become directories or traversal.
    static func sanitized(_ value: String) -> String {
        var output = ""
        var separator = false
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.append(String(scalar))
                separator = false
            } else if !separator {
                output.append("-")
                separator = true
            }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        let limited = String(trimmed.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return limited.isEmpty ? "Building" : limited
    }
}
#endif
