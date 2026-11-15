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
        container(workspaceRoot: workspaceRoot)
            .appendingPathComponent(folderName(for: document, workspaceRoot: workspaceRoot), isDirectory: true)
    }

    static func folderName(for document: FloeCADDocument, workspaceRoot: URL) -> String {
        let documentPath = document.url.standardizedFileURL.path
        var root = workspaceRoot.standardizedFileURL.path
        if !root.hasSuffix("/") { root += "/" }
        let key = documentPath.hasPrefix(root)
            ? String(documentPath.dropFirst(root.count))
            : "external:\(documentPath)"
        let stem = document.url.deletingPathExtension().lastPathComponent
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
