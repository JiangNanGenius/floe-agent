// SPDX-License-Identifier: MPL-2.0
// FloeApp — Canvas-owned native CAD package storage.
//
// A native CAD node created from the Canvas toolbar must not depend on an
// open chat task or on a selected local file workspace: a Canvas is its own
// workspace. Those packages therefore live in an app-owned, on-device
// container under Application Support, in a per-canvas folder — never in a
// temporary directory and never guessed from "the first project". This is the
// canvas analogue of the workspace-root creation in `FileTreeViewModel`, with
// explicit ownership by the canvas id.
//
// Identity on the canvas node is recorded through
// `CADCanvasNodePlanner.MetadataKeys.sourcePath` as
// `canvas-cad:<canvasUUID>/<packageFileName>`; `packageURL(forKey:)` resolves
// that key back to the exact on-disk package. The key is file-name based (not
// absolute) so it survives the app container moving between installs.
//
// The CAD packages here are separate from the canvas project JSON (which
// lives under `FloeAgent/Canvases`) and from the exported PNG renders in the
// material library. Deleting a canvas prunes its folder through
// `removePackages(canvasID:)`; a failed creation is recovered by
// `recoverablePackageURLs(canvasID:)` so an orphaned package can rebound to a
// node instead of being lost silently.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore

@MainActor
enum CanvasCADStorage {
    /// Marker + key prefix for canvas-owned package bindings.
    static let keyPrefix = "canvas-cad:"
    /// Folder name under `Application Support/FloeAgent`.
    nonisolated static let containerDirectoryName = "CanvasCAD"

    enum StorageError: Error, LocalizedError {
        case containerUnavailable
        case packageMissing
        var errorDescription: String? {
            switch self {
            case .containerUnavailable:
                return NSLocalizedString(
                    "workspace.canvas_cad.storage_unavailable",
                    value: "The on-device CAD storage folder is unavailable.",
                    comment: "Canvas CAD package storage could not be located")
            case .packageMissing:
                return NSLocalizedString(
                    "workspace.canvas_cad.package_missing",
                    value: "The CAD document to duplicate is no longer on this device.",
                    comment: "Canvas CAD package copy source missing")
            }
        }
    }

    /// Root container: `Application Support/FloeAgent/CanvasCAD`.
    static func containerRoot(createIfNeeded: Bool = true) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createIfNeeded)
        let root = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(containerDirectoryName, isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    /// The per-canvas package folder.
    static func directory(canvasID: UUID, createIfNeeded: Bool = true) throws -> URL {
        let dir = try containerRoot(createIfNeeded: createIfNeeded)
            .appendingPathComponent(canvasID.uuidString, isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Binding key recorded on a canvas node for a package file name.
    static func key(canvasID: UUID, packageFileName: String) -> String {
        CanvasCADBindingKey.key(canvasID: canvasID, packageFileName: packageFileName)
    }

    /// Parse a `canvas-cad:` key into its canvas id + package file name.
    static func parse(key: String) -> (canvasID: UUID, packageFileName: String)? {
        CanvasCADBindingKey.parse(key)
    }

    /// True when a node's recorded source path is a canvas-owned package.
    static func isCanvasOwnedKey(_ sourcePath: String?) -> Bool {
        CanvasCADBindingKey.isCanvasOwned(sourcePath)
    }

    /// Resolve a recorded binding key to its absolute package URL. Returns nil
    /// for keys that do not parse; the package itself may or may not exist.
    static func packageURL(forKey key: String) -> URL? {
        guard let parsed = parse(key: key) else { return nil }
        guard let dir = try? directory(canvasID: parsed.canvasID, createIfNeeded: false) else {
            return nil
        }
        let candidate = dir.appendingPathComponent(parsed.packageFileName).standardizedFileURL
        // Containment: the resolved package must stay inside the canvas
        // folder (no traversal, no symlink escape).
        let root = dir.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    /// A unique, non-existing package URL inside the canvas folder.
    static func uniquePackageURL(canvasID: UUID, baseName: String = "CAD Model") throws -> URL {
        let dir = try directory(canvasID: canvasID)
        let stem = sanitize(baseName)
        var candidate = "\(stem).floecad"
        var serial = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(stem) \(serial).floecad"
            serial += 1
        }
        return dir.appendingPathComponent(candidate)
    }

    /// Packages on disk for one canvas (recoverable orphans included).
    static func packageURLs(canvasID: UUID) -> [URL] {
        guard let dir = try? directory(canvasID: canvasID, createIfNeeded: false),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "floecad" }
    }

    /// Remove every canvas-owned package for a canvas being deleted.
    static func removePackages(canvasID: UUID) {
        guard let dir = try? directory(canvasID: canvasID, createIfNeeded: false) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Pending creation (retry rebinds the SAME package)

    private struct PendingRecord: Codable {
        var fileName: String
        var createdAt: Date
    }

    private static func pendingFileURL(createIfNeeded: Bool) -> URL? {
        guard let root = try? containerRoot(createIfNeeded: createIfNeeded) else { return nil }
        return root.appendingPathComponent("pending.json")
    }

    private static func pendingKey(canvasID: UUID, documentID: UUID) -> String {
        "\(canvasID.uuidString)|\(documentID.uuidString)"
    }

    private static func loadPending() -> [String: PendingRecord] {
        guard let url = pendingFileURL(createIfNeeded: false),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([String: PendingRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    private static func storePending(_ records: [String: PendingRecord]) {
        guard let url = pendingFileURL(createIfNeeded: true) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// The package a previous failed creation already saved for this exact
    /// canvas + canvas document, if it still exists on disk. A retry REUSES it
    /// instead of creating another orphan.
    static func pendingPackage(canvasID: UUID, documentID: UUID) -> URL? {
        let records = loadPending()
        guard let record = records[pendingKey(canvasID: canvasID, documentID: documentID)],
              let dir = try? directory(canvasID: canvasID, createIfNeeded: false) else {
            return nil
        }
        let candidate = dir.appendingPathComponent(record.fileName).standardizedFileURL
        guard candidate.path.hasPrefix(dir.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    /// Record (or refresh) the pending creation identity BEFORE the package is
    /// created, so a crash or a failed canvas write leaves a rebindable record.
    static func setPending(canvasID: UUID, documentID: UUID, packageFileName: String) {
        var records = loadPending()
        records[pendingKey(canvasID: canvasID, documentID: documentID)] =
            PendingRecord(fileName: packageFileName, createdAt: Date())
        storePending(records)
    }

    /// Clear the pending record once a canvas node binds the package.
    static func clearPending(canvasID: UUID, documentID: UUID) {
        var records = loadPending()
        records.removeValue(forKey: pendingKey(canvasID: canvasID, documentID: documentID))
        storePending(records)
    }

    // MARK: - Fork (canvas duplicate keeps a mutable, independent package)

    /// Copy one package into another canvas's folder for duplication, returning
    /// the new file name. The copy is a full byte-for-byte package the fork can
    /// edit without touching the original.
    static func copyPackage(fromCanvas: UUID, fileName: String, toCanvas: UUID) throws -> String {
        let source = try directory(canvasID: fromCanvas, createIfNeeded: false)
            .appendingPathComponent((fileName as NSString).lastPathComponent)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw StorageError.packageMissing
        }
        let destination = try uniquePackageURL(
            canvasID: toCanvas,
            baseName: (source.deletingPathExtension().lastPathComponent))
        try FileManager.default.copyItem(at: source, to: destination)
        return destination.lastPathComponent
    }

    private static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        return trimmed.isEmpty ? "CAD Model" : trimmed
    }
}
#endif
