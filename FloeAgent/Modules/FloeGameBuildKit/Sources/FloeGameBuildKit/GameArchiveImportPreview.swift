// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GameArchiveContentClass: String, Sendable {
    /// Recognized engine editor-source project (markers/dependency manifests).
    case editorSource
    /// A shipped/downloaded game package (e.g. RPG_RT.exe RPG Maker runtime).
    case publishedGame
    /// No engine recognized; archive still imports whole with every file kept.
    case unknown
}

public enum GameProjectLimitationKind: String, Sendable {
    /// Windows executables are preserved as bytes and never executed.
    case windowsExecutable
    /// Native libraries are preserved; they are not loadable in-component.
    case dynamicLibrary
    /// Encrypted asset packages cannot be semantically edited without the engine toolchain.
    case encryptedAssets
    /// The package expects the engine's official RTP assets at play time (not bundled).
    case rtpRequired
    /// No in-component play route exists for this packaged runtime.
    case unsupportedPlayRoute
}

public struct GameProjectLimitation: Equatable, Sendable {
    public let kind: GameProjectLimitationKind
    public let path: String?
    public let note: String
}

/// Advisory diagnostics computed from archive names, bounded text peeks and/or
/// an already-extracted tree. Import NEVER gates on these: unknown engines,
/// multiple nested roots and mixed content all import whole. Engine/root
/// recognition and AI organization are later explicit actions on the imported
/// revision (and its durable revision history).
public struct GameArchiveImportPreview: Sendable {
    public let contentClass: GameArchiveContentClass
    public let recognizedEngines: [GameEngineID]
    public let rootCandidates: [GameArchiveRootCandidate]
    public let dependencyHints: [String]
    public let limitations: [GameProjectLimitation]
    public let executableCount: Int
    public let entryCount: Int
    public let totalBytes: Int
}

public struct GameArchiveProjectPreviewer: Sendable {
    public let exchange: GameArchiveExchange
    public init(exchange: GameArchiveExchange = .init()) {
        self.exchange = exchange
    }

    public func preview(archive: URL, filenameEncoding: String.Encoding? = nil) throws -> GameArchiveImportPreview {
        let listing = try exchange.inspect(archive: archive, filenameEncoding: filenameEncoding)
        let paths: [(path: String, kind: GameArchiveEntryKind, bytes: Int)] =
            listing.entries.map { ($0.path, $0.kind, $0.uncompressedBytes) }
        return try classify(paths: paths, rootCandidates: listing.rootCandidates) { path in
            try exchange.readEntry(archive: archive, path: GameRelativePath(path),
                                   maximumBytes: 256 * 1_024,
                                   filenameEncoding: filenameEncoding)
        }
    }

    /// Diagnostics for a tree already extracted by the host port. The walker
    /// is descriptor-safe and bounded; every file is preserved by the import.
    public func preview(tree root: URL) throws -> GameArchiveImportPreview {
        let walker = try GameDirectoryTreeWalker(rootURL: root)
        let entries = try walker.walk(maximumEntries: 100_000, maximumDepth: 64)
        let paths: [(path: String, kind: GameArchiveEntryKind, bytes: Int)] = entries.map {
            ($0.path.value, $0.directory ? .directory : .file, $0.bytes)
        }
        var topLevel: [String: Bool] = [:]
        var rootsWithMarkers = Set<String>()
        let markers = [".rxproj", ".rvproj", ".rvproj2", ".rpgproject", ".rmmzproject",
                       "project.godot", "projectsettings/projectversion.txt", "package.json"]
        for entry in entries {
            try Task.checkCancellation()
            let components = entry.path.value.split(separator: "/", maxSplits: 1)
            let name = String(components[0])
            topLevel[name] = topLevel[name] == true || entry.directory || components.count > 1
            if components.count > 1, !entry.directory {
                let relative = components[1].lowercased()
                if markers.contains(where: { relative.hasSuffix($0) }) {
                    rootsWithMarkers.insert(name.lowercased())
                }
            }
        }
        let candidates = topLevel.keys.sorted().map { name -> GameArchiveRootCandidate in
            GameArchiveRootCandidate(name: name,
                                     isDirectory: topLevel[name] == true,
                                     containsProjectMarkers: rootsWithMarkers.contains(name.lowercased()))
        }
        return try classify(paths: paths, rootCandidates: candidates) { path in
            self.readPeek(root.appendingPathComponent(path))
        }
    }

    private func readPeek(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1_024) else { return nil }
        return data
    }

    /// Shared filename/marker classification for archives and extracted trees.
    private func classify(paths: [(path: String, kind: GameArchiveEntryKind, bytes: Int)],
                          rootCandidates: [GameArchiveRootCandidate],
                          peek: (String) throws -> Data?) throws -> GameArchiveImportPreview {
        var engines = Set<GameEngineID>()
        var limitations: [GameProjectLimitation] = []
        var dependencyHints = Set<String>()
        var executableCount = 0
        var totalBytes = 0
        var entryCount = 0
        var sawPublishedRuntime = false
        var sawEditorMarker = false
        let lowercased = paths.map { $0.path.lowercased() }
        func has(_ suffix: String) -> Bool { lowercased.contains(where: { $0.hasSuffix(suffix) }) }

        let markerMap: [(String, GameEngineID)] = [
            (".rxproj", .rpgMakerXP), (".rvproj", .rpgMakerVX), (".rvproj2", .rpgMakerVXAce),
            (".rpgproject", .rpgMakerMV), (".rmmzproject", .rpgMakerMZ),
        ]
        for (suffix, engine) in markerMap where has(suffix) {
            engines.insert(engine)
            sawEditorMarker = true
        }
        let hasWebDeployment = lowercased.contains("www/index.html") ||
            (lowercased.contains(where: { $0.hasPrefix("www/") }) && has("package.json"))
        if has("rpg_rt.exe") || has("rpg_rt.ini") || (has("game.exe") && !hasWebDeployment) {
            sawPublishedRuntime = true
            if has(".rxdata") { engines.insert(.rpgMakerXP) }
            else if has(".rvdata") { engines.insert(.rpgMakerVX) }
            else if has(".rvdata2") { engines.insert(.rpgMakerVXAce) }
            else { engines.formUnion([.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce]) }
        }
        if hasWebDeployment {
            sawPublishedRuntime = true
            engines.formUnion([.rpgMakerMV, .rpgMakerMZ])
        }
        if has("project.godot") { engines.insert(.godot); sawEditorMarker = true }
        if lowercased.contains("projectsettings/projectversion.txt") { engines.insert(.unity); sawEditorMarker = true }
        if has(".ink") { engines.insert(.ink); sawEditorMarker = true }
        if has(".tw") || has(".twee") { engines.insert(.twine); sawEditorMarker = true }
        if has(".tic") { engines.insert(.tic80); sawEditorMarker = true }

        let archiveFiles = Set(paths.lazy.filter { $0.kind == .file }.map { $0.path.lowercased() })
        let tyranoMarker = "tyrano/tyrano.js"
        if archiveFiles.contains(where: { path in
            guard path.hasSuffix(tyranoMarker) else { return false }
            let prefix = path.dropLast(tyranoMarker.count)
            guard prefix.isEmpty || prefix.last == "/" else { return false }
            return (archiveFiles.contains(prefix + "index.html") || archiveFiles.contains(prefix + "index.htm"))
                && archiveFiles.contains(prefix + "tyrano/plugins/kag/kag.js")
        }) {
            engines.insert(.tyranoScript)
            sawPublishedRuntime = true
        }
        for path in archiveFiles {
            let parts = path.split(separator: "/")
            if parts.count >= 2, parts[parts.count - 2] == "game" {
                if path.hasSuffix(".rpa") || path.hasSuffix(".rpyc") {
                    engines.insert(.renpy)
                    sawPublishedRuntime = true
                } else if path.hasSuffix(".rpy") {
                    engines.insert(.renpy)
                    sawEditorMarker = true
                }
            } else if parts.last == "renpy.wasm" {
                let prefix = path.dropLast("renpy.wasm".count)
                if archiveFiles.contains(prefix + "game.zip") || archiveFiles.contains(prefix + "game.data") {
                    engines.insert(.renpy)
                    sawPublishedRuntime = true
                }
            }
        }

        for entry in paths {
            let path = entry.path
            entryCount += 1
            if entry.kind == .file { totalBytes += entry.bytes }
            let ext = (path as NSString).pathExtension.lowercased()
            if ["exe", "bat", "com"].contains(ext) {
                executableCount += 1
                if ext == "exe" {
                    limitations.append(.init(kind: .windowsExecutable, path: path,
                                             note: "Windows executable preserved as bytes; never executed by the component."))
                }
            }
            if ["dll", "so", "dylib"].contains(ext) {
                limitations.append(.init(kind: .dynamicLibrary, path: path,
                                         note: "Native library preserved as bytes; not loadable by the component runtime."))
            }
            if ["rgssad", "rgss2a", "rgss3a", "rpgmvp", "rpgmvo", "rpgmvm"].contains(ext) {
                limitations.append(.init(kind: .encryptedAssets, path: path,
                                         note: "Encrypted engine asset package; semantic editing/play requires the engine toolchain."))
            }
        }

        // Bounded peeks: shallowest package.json and RPG_RT.ini/Game.ini.
        if let packagePath = shallowestPath(in: paths, matching: { $0.lowercased().hasSuffix("package.json") }),
           let data = try peek(packagePath),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let engineDeps: [String: GameEngineID] = [
                "phaser": .phaser, "kaplay": .kaplay, "@babylonjs/core": .babylon,
                "babylonjs": .babylon, "playcanvas": .playcanvas, "inkjs": .ink,
            ]
            let keys = Array(engineDeps.keys) + ["nw", "rpg-maker", "rpgmaker"]
            var found = [String: String]()
            for key in keys { if let value = object[key] as? String { found[key] = value } }
            for section in ["dependencies", "devDependencies", "optionalDependencies"] {
                guard let dependencies = object[section] as? [String: Any] else { continue }
                for key in keys { if let value = dependencies[key] as? String { found[key] = value } }
            }
            for (name, value) in found {
                if let engine = engineDeps[name] {
                    engines.insert(engine)
                    dependencyHints.insert("\(name) \(value)")
                } else {
                    sawPublishedRuntime = true
                    engines.formUnion([.rpgMakerMV, .rpgMakerMZ])
                }
            }
            if !found.isEmpty { sawEditorMarker = true }
        }
        if let iniPath = shallowestPath(in: paths, matching: {
            let lower = $0.lowercased()
            return lower.hasSuffix("rpg_rt.ini") || lower.hasSuffix("game.ini")
        }), let data = try peek(iniPath) {
            if let text = String(data: data, encoding: .utf8),
               text.range(of: #"RTP\d*\s*=\s*Standard"#, options: [.regularExpression, .caseInsensitive]) != nil {
                limitations.append(.init(kind: .rtpRequired, path: nil,
                                         note: "This package expects the engine's official RTP assets at play time; RTP is not bundled (user-provided)."))
            }
        }

        if sawPublishedRuntime {
            limitations.append(.init(kind: .unsupportedPlayRoute, path: nil,
                                     note: "Packaged game runtime has no in-component play route; import preserves bytes and diagnostics only."))
        }

        return .init(contentClass: sawPublishedRuntime ? .publishedGame : (sawEditorMarker ? .editorSource : .unknown),
                     recognizedEngines: engines.sorted { $0.rawValue < $1.rawValue },
                     rootCandidates: rootCandidates,
                     dependencyHints: dependencyHints.sorted(),
                     limitations: limitations,
                     executableCount: executableCount,
                     entryCount: entryCount,
                     totalBytes: totalBytes)
    }

    private func shallowestPath(in paths: [(path: String, kind: GameArchiveEntryKind, bytes: Int)],
                                matching predicate: (String) -> Bool) -> String? {
        paths
            .filter { $0.kind == .file && predicate($0.path) }
            .map(\.path)
            .sorted { lhs, rhs in
                let ld = lhs.split(separator: "/").count, rd = rhs.split(separator: "/").count
                return ld == rd ? lhs < rhs : ld < rd
            }
            .first
    }
}
