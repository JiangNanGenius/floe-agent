// SPDX-License-Identifier: MPL-2.0
import Foundation

extension GameProjectInspector {
    /// Read-only ordinary-IDE preflight. It recognizes a game project at the
    /// supplied root and in bounded nested roots, but never creates a project
    /// context, project ID, repository, owner, run, permission or app record.
    ///
    /// `false` means every inspected root completed and no actual engine format
    /// was found. Budget, unreadable, unsafe, traversal and symlink failures are
    /// thrown explicitly. The scan is bounded by `maximumEntries` (tree entries)
    /// and `maximumRoots` (candidate roots), and honors task cancellation.
    public static func hasGameCandidate(rootURL: URL,
                                        maximumEntries: Int = 20_000,
                                        maximumRoots: Int = 64) throws -> Bool {
        guard (1...100_000).contains(maximumEntries), (1...256).contains(maximumRoots) else {
            throw GameProjectError.invalidContext
        }
        let limits = try GameProjectProbeLimits(maximumRootEntries: maximumEntries)
        let probe = try GameProjectRecognitionProbe(rootURL: rootURL, limits: limits,
                                                    maximumEntries: maximumEntries,
                                                    maximumRoots: maximumRoots)
        return try probe.hasGameCandidate()
    }

    /// Additive discovery seam for the frozen `FloeGameRunKit` selection
    /// inventory. It returns only nested roots (never the captured root) whose
    /// arbitrary-named JSON is a genuine native project document: GDevelop
    /// `gdVersion`/`layouts` or compiled ink `inkVersion`/`root`. Fixed-name
    /// roots (package.json/project.json/game.json/floe-game.json/story.twine.json)
    /// are already covered by the path inventory, so this seam skips them.
    ///
    /// Read-only and bounded by the captured path list, the same manifest and
    /// engine-project byte limits, cancellation, and explicit budget errors. It
    /// never creates a context, project ID, run, permission, repository or
    /// selection record and never auto-selects a root.
    public static func nativeJSONCandidateRoots(
        rootURL: URL,
        paths: [GameRelativePath],
        maximumRoots: Int = 64
    ) throws -> [GameRelativePath] {
        guard (1...256).contains(maximumRoots) else {
            throw GameProjectError.invalidContext
        }
        let limits = try GameProjectProbeLimits()
        let reader = try GameProjectReader(rootURL: rootURL,
                                           maximumFileBytes: limits.maximumManifestBytes)
        let skippedNames: Set<String> = [
            "package.json", "project.json", "game.json", "floe-game.json",
            "story.twine.json", "package-lock.json", "npm-shrinkwrap.json"
        ]
        let tokens = ["\"gdVersion\"", "\"firstLayout\"", "\"inkVersion\""]
        var roots = Set<GameRelativePath>()
        var probes = 0
        var bytes = 0
        func count(_ amount: Int) throws {
            guard amount >= 0, bytes <= limits.maximumProbeBytes - amount else {
                throw GameProjectError.limitExceeded("projectProbeBytes")
            }
            bytes += amount
        }
        for path in paths {
            try Task.checkCancellation()
            let components = path.value.split(separator: "/").map(String.init)
            guard !components.contains(where: {
                GameProjectReader.versionControlNames.contains($0.lowercased())
                    || $0.lowercased() == "node_modules"
            }) else { continue }
            let name = (components.last ?? "").lowercased()
            guard (name as NSString).pathExtension == "json",
                  !skippedNames.contains(name) else { continue }
            guard probes < limits.maximumProjectProbes else {
                throw GameProjectError.limitExceeded("projectProbes")
            }
            probes += 1
            guard let prefix = try reader.readPrefix(path, maximumBytes: 8_192) else { continue }
            try count(prefix.count)
            let text = String(decoding: prefix, as: UTF8.self)
            var candidate = text.contains("\"gdVersion\"")
                || text.contains("\"firstLayout\"") || text.contains("\"inkVersion\"")
            if !candidate, let size = try reader.fileSize(path), size > 0 {
                guard size <= limits.maximumEngineProjectBytes else {
                    throw GameProjectError.limitExceeded(path.value)
                }
                let scan = min(size, limits.maximumEngineProjectBytes)
                try count(scan)
                candidate = try reader.findAnyASCII(tokens, in: path, maximumBytes: scan) != nil
            }
            guard candidate else { continue }
            guard let data = try reader.read(path,
                                             maximumBytes: limits.maximumEngineProjectBytes) else {
                continue
            }
            try count(data.count)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.isNativeJSONDocument(object) else { continue }
            let parent = components.dropLast()
            guard !parent.isEmpty else { continue }
            let root = try GameRelativePath(parent.joined(separator: "/"))
            roots.insert(root)
            guard roots.count <= maximumRoots else {
                throw GameProjectError.limitExceeded("projectRoots")
            }
        }
        return roots.sorted { $0.value < $1.value }
    }
}

/// Mutable accounting for nested metadata probes. It throws an explicit budget
/// error instead of turning an unscanned candidate into a silent `false`.
final class GameProjectProbeBudget {
    let limits: GameProjectProbeLimits
    private(set) var files = 0
    private(set) var bytes = 0

    init(limits: GameProjectProbeLimits) {
        self.limits = limits
    }

    func nextFile() throws {
        guard files < limits.maximumProjectProbes else {
            throw GameProjectError.limitExceeded("projectProbes")
        }
        files += 1
    }

    func add(_ amount: Int) throws {
        guard amount >= 0, bytes <= limits.maximumProbeBytes - amount else {
            throw GameProjectError.limitExceeded("projectProbeBytes")
        }
        bytes += amount
    }
}

/// Descriptor-anchored nested-root discovery. The captured root is opened once;
/// every nested root is opened through `GameProjectReader(parent:...)`, so a
/// symlink swapped in after the directory walk cannot redirect the scan.
struct GameProjectRecognitionProbe {
    // Only genuine VCS, dependency and admin caches are skipped. Generic user
    // folder names such as build/, dist/, bin/, local/, library/ or temp/ can
    // contain a real downloaded/exported game, so they are never silent skips;
    // if their contents exceed the budget, the scan fails explicitly.
    private static let excludedNames: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "deriveddata", ".swiftpm",
        ".next", ".gradle", ".idea", "pods", "carthage"
    ]
    private static let webEngineFiles: Set<String> = [
        "phaser.js", "phaser.min.js", "phaser-arcade-physics.min.js",
        "kaplay.js", "babylon.js", "playcanvas.js"
    ]
    private static let engineDependencies: Set<String> = [
        "phaser", "kaplay", "playcanvas", "@babylonjs/core", "babylonjs"
    ]

    let root: GameProjectReader
    let inspector: GameProjectInspector
    let maximumEntries: Int
    let maximumRoots: Int

    init(rootURL: URL, limits: GameProjectProbeLimits,
         maximumEntries: Int, maximumRoots: Int) throws {
        guard rootURL.isFileURL else { throw GameProjectError.rootUnavailable }
        self.root = try GameProjectReader(rootURL: rootURL,
                                          maximumFileBytes: limits.maximumManifestBytes)
        self.inspector = GameProjectInspector(limits: limits)
        self.maximumEntries = maximumEntries
        self.maximumRoots = maximumRoots
    }

    func hasGameCandidate() throws -> Bool {
        try Task.checkCancellation()
        // A direct game root is the cheapest and most common case. Do not walk
        // a large tree when the selected root itself is already recognized.
        if try !inspector.inspectFirstCandidate(reader: root).candidates.isEmpty { return true }

        let entries = try root.tree(maximumEntries: maximumEntries,
                                    maximumDepth: 32,
                                    excludingNames: Self.excludedNames)
        let budget = GameProjectProbeBudget(limits: inspector.limits)
        var roots = Set<String>()
        for entry in entries where !entry.directory {
            try Task.checkCancellation()
            let path = entry.path.value
            let lower = path.lowercased()
            let name = lower.split(separator: "/").last.map(String.init) ?? lower
            let ext = (name as NSString).pathExtension.lowercased()
            let parent = Self.parent(of: path)
            switch (name, ext) {
            case ("package.json", _):
                if try hasRecognizedPackage(path: entry.path, budget: budget) {
                    roots.insert(parent)
                }
            case ("project.json", _):
                if try hasRecognizedProjectJSON(path: entry.path, budget: budget,
                                                allowFixedMetadata: true) {
                    roots.insert(parent)
                }
            case ("game.json", _), ("floe-game.json", _), ("project.godot", _),
                 ("main.lua", _), ("conf.lua", _), ("story.twine.json", _), ("cart.tic", _):
                roots.insert(parent)
            case (_, "rxproj"), (_, "rvproj"), (_, "rvproj2"), (_, "rpgproject"),
                 (_, "rmmzproject"), (_, "ink"), (_, "twee"), (_, "tic"),
                 (_, "love"), (_, "ms"):
                roots.insert(parent)
            case (_, "wasm"):
                if try isWasm4Cartridge(path: entry.path) { roots.insert(parent) }
            case (_, "html"), (_, "htm"):
                if try isTwineHTMLRoot(path: entry.path)
                    || isExportedWebRoot(htmlPath: entry.path) {
                    roots.insert(parent)
                }
            case (_, "json"):
                if name != "package-lock.json", name != "npm-shrinkwrap.json",
                   try hasRecognizedProjectJSON(path: entry.path, budget: budget,
                                                allowFixedMetadata: false) {
                    roots.insert(parent)
                }
            default:
                if Self.webEngineFiles.contains(name) {
                    roots.insert(parent)
                } else if lower.hasSuffix("projectsettings/projectversion.txt")
                            || lower.hasSuffix("data/system.rxdata")
                            || lower.hasSuffix("data/system.rvdata")
                            || lower.hasSuffix("data/system.rvdata2")
                            || ((lower.hasPrefix("game/") || lower.contains("/game/"))
                                && (ext == "rpy" || ext == "rpyc")) {
                    roots.insert(Self.grandparent(of: path) ?? "")
                }
            }
            guard roots.count <= maximumRoots else {
                throw GameProjectError.limitExceeded("projectRoots")
            }
        }
        // The captured root was already inspected above; nested discovery only
        // adds descendants and must never re-open an empty relative path.
        roots.remove("")

        for relative in roots.sorted() {
            try Task.checkCancellation()
            let path = try GameRelativePath(relative)
            let nested = try GameProjectReader(
                parent: root, relativePath: path,
                maximumFileBytes: max(inspector.limits.maximumManifestBytes,
                                      inspector.limits.maximumEngineProjectBytes))
            if try !inspector.inspectFirstCandidate(reader: nested).candidates.isEmpty { return true }
        }
        return false
    }

    private func hasRecognizedPackage(path: GameRelativePath,
                                      budget: GameProjectProbeBudget) throws -> Bool {
        try budget.nextFile()
        guard let data = try root.read(path,
                                       maximumBytes: inspector.limits.maximumManifestBytes) else {
            return false
        }
        try budget.add(data.count)
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GameProjectError.invalidManifest(path.value)
            }
            object = parsed
        } catch let error as GameProjectError {
            throw error
        } catch {
            throw GameProjectError.invalidManifest(path.value)
        }
        let packageParent = Self.parent(of: path.value)
        func sibling(_ relative: String) throws -> GameRelativePath {
            try GameRelativePath(packageParent.isEmpty ? relative : packageParent + "/" + relative)
        }
        let assets = try sibling("assets")
        if try root.exists(assets, directory: true) {
            if let creator = object["creator"] as? [String: Any],
               let version = creator["version"] as? String,
               GameProjectContext.validIdentifier(version) {
                return true
            }
            let settings = try sibling("settings/v2/packages/project.json")
            if object["uuid"] is String, try root.exists(settings) {
                return true
            }
        }
        for key in ["dependencies", "devDependencies", "optionalDependencies"] {
            guard let dependencies = object[key] as? [String: Any] else { continue }
            if dependencies.keys.contains(where: { Self.engineDependencies.contains($0) }) {
                return true
            }
        }
        return false
    }

    private func hasRecognizedProjectJSON(path: GameRelativePath,
                                          budget: GameProjectProbeBudget,
                                          allowFixedMetadata: Bool) throws -> Bool {
        try budget.nextFile()
        // Cheap prefix gate first. Only a project-like document is then parsed
        // with the same bounded manifest limit as the inspector.
        guard let prefix = try root.readPrefix(path, maximumBytes: 8_192) else { return false }
        try budget.add(prefix.count)
        let text = String(decoding: prefix, as: UTF8.self)
        var candidate = text.contains("\"engine\"") || text.contains("\"gdVersion\"")
            || text.contains("\"firstLayout\"") || text.contains("\"inkVersion\"")
            || text.contains("\"creator\"")
            || (text.contains("\"files\"") && text.contains("\"language\""))
        if !candidate, let size = try root.fileSize(path), size > 0 {
            guard size <= inspector.limits.maximumEngineProjectBytes else {
                throw GameProjectError.limitExceeded(path.value)
            }
            let scan = min(size, inspector.limits.maximumEngineProjectBytes)
            try budget.add(scan)
            candidate = try root.findAnyASCII(
                ["\"gdVersion\"", "\"firstLayout\"", "\"inkVersion\""],
                in: path, maximumBytes: scan) != nil
        }
        guard candidate else { return false }
        guard let data = try root.read(path,
                                       maximumBytes: inspector.limits.maximumEngineProjectBytes) else {
            return false
        }
        try budget.add(data.count)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return allowFixedMetadata
            ? GameProjectInspector.isFixedMetadataJSONDocument(object)
            : GameProjectInspector.isNativeJSONDocument(object)
    }

    private func isExportedWebRoot(htmlPath: GameRelativePath) throws -> Bool {
        let parent = Self.parent(of: htmlPath.value)
        guard !parent.isEmpty else { return false }
        func sibling(_ name: String) throws -> GameRelativePath {
            try GameRelativePath(parent + "/" + name)
        }
        func exists(_ name: String, directory: Bool = false) throws -> Bool {
            let path = try sibling(name)
            return try root.exists(path, directory: directory)
        }
        let hasDataJS = try exists("data.js")
        let hasGDJS = try exists("gd.js")
        let hasCode0JS = try exists("code0.js")
        if hasDataJS, hasGDJS || hasCode0JS { return true }
        let hasApplicationJS = try exists("application.js")
        let hasCocosSettings = try exists("src/settings.json")
        if hasApplicationJS, hasCocosSettings { return true }
        let hasGodotWasm = try exists("game.wasm")
        let hasGodotPack = try exists("game.pck")
        if hasGodotWasm, hasGodotPack { return true }
        let hasLoveWasm = try exists("love.wasm")
        let hasLoveData = try exists("game.data")
        let hasLoveLoader = try exists("love.js")
        if hasLoveWasm, hasLoveData, hasLoveLoader { return true }
        let hasRenpyWasm = try exists("renpy.wasm")
        let hasRenpyGame = try exists("game.zip")
        if hasRenpyWasm, hasRenpyGame { return true }
        for buildName in ["Build", "build"] {
            guard try exists(buildName, directory: true) else { continue }
            let build = try sibling(buildName)
            let names = try root.names(in: build, maximum: 512)
            let lowered = names.map { $0.lowercased() }
            let loader = lowered.contains {
                $0.hasSuffix(".loader.js") || $0.hasSuffix("unityloader.js")
            }
            if loader || (lowered.contains { $0.hasSuffix(".wasm") }
                          && lowered.contains { $0.hasSuffix(".data") }) {
                return true
            }
        }
        return false
    }

    private func isTwineHTMLRoot(path: GameRelativePath) throws -> Bool {
        guard let offset = try root.findASCII("<tw-storydata", in: path,
                                              maximumBytes: inspector.limits.maximumHTMLScanBytes),
              let snippet = try root.readSnippet(path, offset: offset, length: 16_384) else {
            return false
        }
        let text = String(decoding: snippet, as: UTF8.self)
        guard let tagEnd = text.firstIndex(of: ">") else { return false }
        let tag = String(text[..<tagEnd])
        return GameProjectInspector.htmlAttribute("name", in: tag) != nil
            && GameProjectInspector.htmlAttribute("startnode", in: tag) != nil
    }

    private func isWasm4Cartridge(path: GameRelativePath) throws -> Bool {
        guard let size = try root.fileSize(path), size > 0,
              size <= inspector.limits.maximumWasmCartBytes,
              let data = try root.readPrefix(path, maximumBytes: size) else { return false }
        return Wasm4CartridgeProbe.isCartridge(data)
    }

    private static func parent(of path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    private static func grandparent(of path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return parts.dropLast(2).joined(separator: "/")
    }
}

/// Structural read-only probe for the WASM-4 release cartridge ABI. It parses
/// only section headers, the import table and exported names; it never
/// instantiates or executes the module. The upstream web runtime enforces the
/// 64 KiB release-cart limit before this probe is called.
enum Wasm4CartridgeProbe {
    static func isCartridge(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 8,
              Array(bytes[0..<4]) == [0x00, 0x61, 0x73, 0x6D],
              Array(bytes[4..<8]) == [0x01, 0x00, 0x00, 0x00] else { return false }
        var index = 8
        var imports: [(module: String, field: String)] = []
        var exports = Set<String>()
        while index < bytes.count {
            let sectionID = bytes[index]
            index += 1
            guard let (sectionSize, contentStart) = readUnsigned(bytes, index),
                  contentStart <= bytes.count,
                  Int(sectionSize) <= bytes.count - contentStart else { return false }
            let end = contentStart + Int(sectionSize)
            switch sectionID {
            case 2:
                guard parseImports(bytes, start: contentStart, end: end, into: &imports) else {
                    return false
                }
            case 7:
                guard parseExports(bytes, start: contentStart, end: end, into: &exports) else {
                    return false
                }
            default:
                break
            }
            index = end
        }
        let importsMemory = imports.contains { $0.module == "env" && $0.field == "memory" }
        return importsMemory && (exports.contains("update") || exports.contains("start"))
    }

    private static func parseImports(_ bytes: [UInt8], start: Int, end: Int,
                                     into imports: inout [(module: String, field: String)]) -> Bool {
        guard let (count, countEnd) = readUnsigned(bytes, start) else { return false }
        var cursor = countEnd
        for _ in 0..<count {
            guard let (moduleLength, moduleStart) = readUnsigned(bytes, cursor),
                  moduleStart + Int(moduleLength) <= end else { return false }
            let module = String(decoding: bytes[moduleStart..<(moduleStart + Int(moduleLength))],
                                as: UTF8.self)
            cursor = moduleStart + Int(moduleLength)
            guard let (fieldLength, fieldStart) = readUnsigned(bytes, cursor),
                  fieldStart + Int(fieldLength) <= end else { return false }
            let field = String(decoding: bytes[fieldStart..<(fieldStart + Int(fieldLength))],
                               as: UTF8.self)
            cursor = fieldStart + Int(fieldLength)
            guard cursor < end else { return false }
            let kind = bytes[cursor]
            cursor += 1
            switch kind {
            case 0x00:
                guard let (_, next) = readUnsigned(bytes, cursor) else { return false }
                cursor = next
            case 0x01, 0x02:
                if kind == 0x01 {
                    guard cursor < end else { return false }
                    cursor += 1
                }
                guard let (flags, afterFlags) = readUnsigned(bytes, cursor),
                      flags & ~0x07 == 0 else { return false }
                cursor = afterFlags
                guard let (_, afterMinimum) = readUnsigned(bytes, cursor) else { return false }
                cursor = afterMinimum
                if flags & 0x01 != 0 {
                    guard let (_, afterMaximum) = readUnsigned(bytes, cursor) else { return false }
                    cursor = afterMaximum
                }
            case 0x03:
                guard cursor + 1 < end else { return false }
                cursor += 2
            default:
                return false
            }
            guard cursor <= end else { return false }
            if kind == 0x02 { imports.append((module, field)) }
        }
        return cursor == end
    }

    private static func parseExports(_ bytes: [UInt8], start: Int, end: Int,
                                     into exports: inout Set<String>) -> Bool {
        guard let (count, countEnd) = readUnsigned(bytes, start) else { return false }
        var cursor = countEnd
        for _ in 0..<count {
            guard let (nameLength, nameStart) = readUnsigned(bytes, cursor),
                  nameStart + Int(nameLength) <= end else { return false }
            let name = String(decoding: bytes[nameStart..<(nameStart + Int(nameLength))],
                              as: UTF8.self)
            cursor = nameStart + Int(nameLength)
            guard cursor < end else { return false }
            let kind = bytes[cursor]
            cursor += 1
            guard let (_, afterIndex) = readUnsigned(bytes, cursor) else { return false }
            cursor = afterIndex
            guard cursor <= end else { return false }
            if kind == 0x00 { exports.insert(name) }
        }
        return cursor == end
    }

    private static func readUnsigned(_ bytes: [UInt8], _ start: Int) -> (UInt32, Int)? {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if shift == 28, byte & 0xF0 != 0 { return nil }
            result |= UInt32(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, index) }
            shift += 7
            if shift > 28 { return nil }
        }
        return nil
    }
}
