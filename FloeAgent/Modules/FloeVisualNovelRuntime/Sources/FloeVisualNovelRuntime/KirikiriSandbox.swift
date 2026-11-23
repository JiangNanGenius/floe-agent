// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A staged, per-run Kirikiri game sandbox.
///
/// The engine only reads and writes inside `gameRoot` (its own temporary area
/// is separate), so the staging directory is the trust boundary: game content
/// is copied from the imported project, and `gameRoot/savedata` is a
/// symlink to the App's persistent per-game save directory. Reopening a game
/// reuses the same save directory, which is what makes save/restore survive
/// across runs.
public struct KirikiriSandbox: Sendable {
    /// Engine `game_root`: contains the staged game content and `savedata`.
    public let gameRoot: URL
    /// App-owned persistent save directory (outside the sandbox).
    public let savesDirectory: URL
    /// Disposable per-run directory that owns `gameRoot`.
    public let workDirectory: URL

    /// Removes the per-run staging. The persistent save directory is never
    /// touched here.
    public func dispose(fileManager: FileManager = FileManager()) throws {
        try fileManager.removeItem(at: workDirectory)
    }
}

public enum KirikiriSandboxBuilder {
    private static let excludedNames: Set<String> = [".git", ".floe", "savedata"]

    /// Stages one run of one game.
    /// - Parameters:
    ///   - source: the recognized project root (holds startup.tjs / XP3).
    ///   - savesDirectory: persistent per-game save storage; created if absent.
    ///   - workDirectory: a fresh, caller-owned run directory.
    ///   - fallbackFont: a bundled font for games that rely on the host default.
    public static func stage(gameRoot source: URL,
                             savesDirectory: URL,
                             workDirectory: URL,
                             fallbackFont: URL? = nil,
                             fileManager: FileManager = FileManager()) throws -> KirikiriSandbox {
        var isDirectory: ObjCBool = false
        guard source.isFileURL,
              fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VisualNovelRuntimeError.sandboxUnavailable("game root is missing: \(source.path)")
        }
        let gameRoot = workDirectory.appendingPathComponent("game", isDirectory: true)
        guard !fileManager.fileExists(atPath: workDirectory.path) else {
            throw VisualNovelRuntimeError.sandboxUnavailable("run directory already exists")
        }
        do {
            try fileManager.createDirectory(at: gameRoot, withIntermediateDirectories: true)
            // The source is never a writable link in the engine's namespace.
            // Validate the private copy before adding the host-owned save link.
            try copyContents(of: source, to: gameRoot, excluding: excludedNames, fileManager: fileManager)
            if let fallbackFont {
                try installFallbackFont(fallbackFont, in: gameRoot, fileManager: fileManager)
            }
            if !fileManager.fileExists(atPath: savesDirectory.path) {
                let importedSaves = source.appendingPathComponent("savedata", isDirectory: true)
                let stagedSaves = workDirectory.appendingPathComponent("save-import", isDirectory: true)
                try fileManager.createDirectory(at: stagedSaves, withIntermediateDirectories: false)
                if (try? importedSaves.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                    .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true {
                    try copyContents(of: importedSaves, to: stagedSaves, excluding: [], fileManager: fileManager)
                }
                try fileManager.createDirectory(at: savesDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: stagedSaves, to: savesDirectory)
            }
            let saveType = try savesDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard saveType.isDirectory == true, saveType.isSymbolicLink != true else {
                throw VisualNovelRuntimeError.sandboxUnavailable("save directory is unavailable")
            }
            try fileManager.createSymbolicLink(at: gameRoot.appendingPathComponent("savedata"),
                                               withDestinationURL: savesDirectory)
            return KirikiriSandbox(gameRoot: gameRoot, savesDirectory: savesDirectory, workDirectory: workDirectory)
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            throw error
        }
    }

    private static func installFallbackFont(_ font: URL, in gameRoot: URL, fileManager: FileManager) throws {
        let entries = try fileManager.contentsOfDirectory(at: gameRoot, includingPropertiesForKeys: nil)
        let extensions: Set<String> = ["ttf", "ttc", "otf", "otc"]
        if entries.contains(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == "default"
                && extensions.contains($0.pathExtension.lowercased())
        }) { return }
        if let gameFonts = entries.first(where: { $0.lastPathComponent.lowercased() == "fonts" }),
           let files = try? fileManager.contentsOfDirectory(at: gameFonts, includingPropertiesForKeys: nil),
           files.contains(where: { extensions.contains($0.pathExtension.lowercased()) }) {
            return
        }
        try fileManager.copyItem(at: font, to: gameRoot.appendingPathComponent("default.ttf"))
    }

    private static func copyContents(of source: URL, to destination: URL, excluding: Set<String>,
                                     fileManager: FileManager, depth: Int = 0) throws {
        guard depth <= 32 else { throw VisualNovelRuntimeError.sandboxUnavailable("game folders are nested too deeply") }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        for entry in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys)) {
            try Task.checkCancellation()
            if excluding.contains(entry.lastPathComponent.lowercased()) { continue }
            let values = try entry.resourceValues(forKeys: keys)
            let target = destination.appendingPathComponent(entry.lastPathComponent, isDirectory: values.isDirectory == true)
            guard values.isSymbolicLink != true else {
                throw VisualNovelRuntimeError.sandboxUnavailable("a game file is a symbolic link")
            }
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
                try copyContents(of: entry, to: target, excluding: excluding, fileManager: fileManager, depth: depth + 1)
            } else {
                guard values.isRegularFile == true else {
                    throw VisualNovelRuntimeError.sandboxUnavailable("a game file is not a regular file")
                }
                try fileManager.copyItem(at: entry, to: target)
                let copied = try target.resourceValues(forKeys: keys)
                guard copied.isRegularFile == true, copied.isSymbolicLink != true else {
                    throw VisualNovelRuntimeError.sandboxUnavailable("a game file changed during preparation")
                }
            }
        }
    }
}
