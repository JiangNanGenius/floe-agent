// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameWebKit

public struct GameRunProjectRoot: Identifiable, Sendable {
    public var id: String { root?.value ?? "." }
    public let root: GameRelativePath?
    public let engines: [GameEngineID]
    /// Probe failures are advisory. Imported bytes stay available in the IDE.
    public let diagnostic: String?

    public init(root: GameRelativePath?, engines: [GameEngineID], diagnostic: String? = nil) {
        self.root = root; self.engines = engines; self.diagnostic = diagnostic
    }
}

/// Discovers nested roots in the captured, owned project. Names and bounded
/// metadata are hints, never authorization or proof of a runnable engine.
/// A project with several roots/engines requires an explicit user selection.
public struct GameRunProjectDiscovery: Sendable {
    public let contexts: any GameRunContextHost
    public let maximumRoots: Int

    public init(contexts: any GameRunContextHost, maximumRoots: Int = 64) {
        self.contexts = contexts
        self.maximumRoots = maximumRoots
    }

    public func discover(context: GameProjectContext, files: [GameProjectFile]) async throws -> [GameRunProjectRoot] {
        // Read-only currency fences use the host's metadata probe; the run
        // preparation engine performs full-tree verification before planning.
        try context.validate(current: await contexts.currentContextMetadata(for: context))
        let roots = try Self.candidateRoots(paths: files.map(\.path),
                                           maximum: maximumRoots,
                                           recognitionRoot: context.rootURL)
        var result: [GameRunProjectRoot] = []
        for root in roots {
            try Task.checkCancellation()
            do {
                let resolved = try GameRunPathResolver.resolve(root: context.rootURL,
                    relativeRoot: root?.value ?? ".", limits: .default)
                let inspection = try GameProjectInspector().inspect(rootURL: resolved.url)
                result.append(.init(root: root, engines: inspection.candidates.map(\.engine), diagnostic: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.append(.init(root: root, engines: [], diagnostic: String(describing: error)))
            }
        }
        try context.validate(current: await contexts.currentContextMetadata(for: context))
        return result
    }

    /// Pure path selection keeps scanning bounded by the repository inventory.
    /// Dependency package manifests must not become game choices.
    static func candidateRoots(paths: [GameRelativePath], maximum: Int) throws -> [GameRelativePath?] {
        try pathCandidateRoots(paths: paths, maximum: maximum)
    }

    /// Captured-inventory discovery plus the additive Core seam for arbitrary
    /// native JSON names (for example MyGame.json or compiled ink story.json).
    /// The seam reads only the captured paths and never creates project,
    /// context, run or selection state. Context validation stays in `discover`.
    static func candidateRoots(paths: [GameRelativePath], maximum: Int,
                               recognitionRoot: URL) throws -> [GameRelativePath?] {
        var roots = try pathCandidateRoots(paths: paths, maximum: maximum)
        let extra = try GameProjectInspector.nativeJSONCandidateRoots(
            rootURL: recognitionRoot, paths: paths, maximumRoots: maximum)
        guard !extra.isEmpty else { return roots }
        var names = Set(roots.compactMap { $0?.value })
        for root in extra { names.insert(root.value) }
        guard names.count < maximum else {
            throw GameRunPreparationError.invalidProject("Too many potential game roots; select a smaller source folder in the IDE.")
        }
        roots = [nil] + (try names.sorted().map { try GameRelativePath($0) as GameRelativePath? })
        return roots
    }

    private static func pathCandidateRoots(paths: [GameRelativePath], maximum: Int) throws -> [GameRelativePath?] {
        guard (1...256).contains(maximum) else { throw GameProjectError.invalidContext }
        var names = Set<String>()
        let markers: Set<String> = ["package.json", "project.godot", "project.json", "game.json", "floe-game.json",
            "main.lua", "conf.lua", "cart.wasm", "story.twine.json", "startup.tjs", "data.xp3"]
        let extensions: Set<String> = ["rxproj", "rvproj", "rvproj2", "rpgproject", "rmmzproject",
            "html", "htm", "ink", "twee", "tic", "love", "ms", "wasm"]
        for path in paths {
            try Task.checkCancellation()
            let parts = path.value.split(separator: "/").map(String.init)
            guard !parts.contains(where: { GameProjectReader.versionControlNames.contains($0.lowercased()) || $0.lowercased() == "node_modules" }) else { continue }
            let name = parts.last ?? ""
            var parent = Array(parts.dropLast())
            let lower = name.lowercased()
            if parts.count >= 2, parts[parts.count - 2].lowercased() == "projectsettings", lower == "projectversion.txt" {
                parent = Array(parts.dropLast(2))
            } else if parts.count >= 2, parts[parts.count - 2] == "Data", lower.hasPrefix("system."),
                      ["rxdata", "rvdata", "rvdata2"].contains((lower as NSString).pathExtension) {
                parent = Array(parts.dropLast(2))
            } else if parts.count >= 2, parts[parts.count - 2].lowercased() == "game",
                      ["rpy", "rpyc", "rpa"].contains((lower as NSString).pathExtension) {
                parent = Array(parts.dropLast(2))
            } else if !markers.contains(lower) && !extensions.contains((lower as NSString).pathExtension) {
                continue
            }
            if !parent.isEmpty { names.insert(parent.joined(separator: "/")) }
            guard names.count < maximum else {
                throw GameRunPreparationError.invalidProject("Too many potential game roots; select a smaller source folder in the IDE.")
            }
        }
        return [nil] + (try names.sorted().map { try GameRelativePath($0) as GameRelativePath? })
    }
}
