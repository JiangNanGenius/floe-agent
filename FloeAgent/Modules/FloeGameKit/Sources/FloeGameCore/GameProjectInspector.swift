// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct GameProjectProbeLimits: Sendable {
    public let maximumRootEntries: Int
    public let maximumManifestBytes: Int
    /// A single native engine project file (for example a large GDevelop JSON)
    /// may be larger than a package manifest. This is still a bounded,
    /// engine-specific read and does not raise the manifest limit.
    public let maximumEngineProjectBytes: Int
    public let maximumProjectProbes: Int
    public let maximumProbeBytes: Int
    public let maximumHTMLScanBytes: Int
    public let maximumWasmCartBytes: Int

    public init(maximumRootEntries: Int = 2_048, maximumManifestBytes: Int = 262_144,
                maximumEngineProjectBytes: Int = 16 * 1_024 * 1_024,
                maximumProjectProbes: Int = 512,
                maximumProbeBytes: Int = 64 * 1_024 * 1_024,
                maximumHTMLScanBytes: Int = 16 * 1_024 * 1_024,
                maximumWasmCartBytes: Int = 65_536) throws {
        guard (1...100_000).contains(maximumRootEntries),
              (1...4_194_304).contains(maximumManifestBytes),
              (1_024...GameProjectReader.maximumScannableBytes).contains(maximumEngineProjectBytes),
              (1...4_096).contains(maximumProjectProbes),
              (1_024...GameProjectReader.maximumScannableBytes).contains(maximumProbeBytes),
              (1_024...GameProjectReader.maximumScannableBytes).contains(maximumHTMLScanBytes),
              (8...GameProjectReader.maximumScannableBytes).contains(maximumWasmCartBytes) else {
            throw GameProjectError.invalidContext
        }
        self.maximumRootEntries = maximumRootEntries
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumEngineProjectBytes = maximumEngineProjectBytes
        self.maximumProjectProbes = maximumProjectProbes
        self.maximumProbeBytes = maximumProbeBytes
        self.maximumHTMLScanBytes = maximumHTMLScanBytes
        self.maximumWasmCartBytes = maximumWasmCartBytes
    }
}

/// Identifies candidates at exactly the supplied root. It never recurses into
/// nested projects, expands archives, reads executable scripts or executes npm.
/// A candidate is not a claim that a project is complete, licensed or playable.
public struct GameProjectInspector: Sendable {
    public let limits: GameProjectProbeLimits

    public init(limits: GameProjectProbeLimits? = nil) {
        self.limits = limits ?? (try! GameProjectProbeLimits())
    }

    public func inspect(rootURL: URL) throws -> GameProjectInspection {
        try inspect(rootURL: rootURL, context: nil)
    }

    /// The host holds its original-file lease, resolves a saved revision before
    /// probing, then rechecks that revision after probing and before dispatch.
    public func inspect(context: GameProjectContext) throws -> GameProjectInspection {
        try inspect(rootURL: context.rootURL, context: context)
    }

    private func inspect(rootURL: URL, context: GameProjectContext?) throws -> GameProjectInspection {
        let reader = try GameProjectReader(rootURL: rootURL,
                                           maximumFileBytes: limits.maximumManifestBytes)
        return try inspect(reader: reader, context: context, stopAfterFirstCandidate: false)
    }

    /// Internal anchored-reader entry used by bounded nested-root discovery.
    /// It never creates a context, project identity, run or permission.
    func inspect(reader: GameProjectReader) throws -> GameProjectInspection {
        try inspect(reader: reader, context: nil, stopAfterFirstCandidate: false)
    }

    /// Boolean preflight helper: once any actual engine format is observed it
    /// returns without scanning unrelated later files. The full selection path
    /// still uses `inspect(reader:)`, which retains every conflicting candidate.
    func inspectFirstCandidate(reader: GameProjectReader) throws -> GameProjectInspection {
        try inspect(reader: reader, context: nil, stopAfterFirstCandidate: true)
    }

    private func inspect(reader: GameProjectReader, context: GameProjectContext?,
                         stopAfterFirstCandidate: Bool) throws -> GameProjectInspection {
        let names = try reader.rootNames(maximum: limits.maximumRootEntries)
        var evidence: [GameEngineID: [GameEngineEvidence]] = [:]
        var inspected = Set<GameRelativePath>()
        var probeFiles = 0
        var probeBytes = 0

        func add(_ engine: GameEngineID, path: GameRelativePath,
                 kind: GameEngineEvidence.Kind, version: String? = nil) {
            if evidence[engine]?.contains(where: { $0.path == path && $0.kind == kind }) == true {
                inspected.insert(path)
                return
            }
            evidence[engine, default: []].append(.init(path: path, kind: kind, versionHint: version))
            inspected.insert(path)
        }
        func addOnce(_ engine: GameEngineID, path: GameRelativePath,
                     kind: GameEngineEvidence.Kind, version: String? = nil) {
            guard evidence[engine] == nil else {
                inspected.insert(path)
                return
            }
            add(engine, path: path, kind: kind, version: version)
        }
        func nextProbe() throws {
            guard probeFiles < limits.maximumProjectProbes else {
                throw GameProjectError.limitExceeded("projectProbes")
            }
            probeFiles += 1
        }
        func countProbe(_ bytes: Int) throws {
            guard bytes >= 0, probeBytes <= limits.maximumProbeBytes - bytes else {
                throw GameProjectError.limitExceeded("projectProbeBytes")
            }
            probeBytes += bytes
        }
        func read(_ path: GameRelativePath, maximumBytes: Int? = nil) throws -> Data? {
            let data: Data?
            if let maximumBytes {
                data = try reader.read(path, maximumBytes: maximumBytes)
            } else {
                data = try reader.read(path)
            }
            if data != nil { inspected.insert(path) }
            return data
        }
        func read(_ name: String, maximumBytes: Int? = nil) throws -> (GameRelativePath, Data)? {
            let path = try GameRelativePath(name)
            guard let data = try read(path, maximumBytes: maximumBytes) else { return nil }
            return (path, data)
        }
        func makeResult() -> GameProjectInspection {
            let candidates = evidence.keys.sorted { $0.rawValue < $1.rawValue }.map { engine in
                GameEngineCandidate(engine: engine, evidence: evidence[engine]!)
            }
            return .init(rootURL: reader.rootURL, context: context, candidates: candidates,
                         inspectedPaths: inspected.sorted { $0.value < $1.value })
        }
        func firstCandidateIfRequested() -> GameProjectInspection? {
            guard stopAfterFirstCandidate, !evidence.isEmpty else { return nil }
            return makeResult()
        }

        var lowerNames: [String: String] = [:]
        for name in names where lowerNames[name.lowercased()] == nil {
            lowerNames[name.lowercased()] = name
        }

        let rpgMarkers: [String: GameEngineID] = [
            "rxproj": .rpgMakerXP, "rvproj": .rpgMakerVX, "rvproj2": .rpgMakerVXAce,
            "rpgproject": .rpgMakerMV, "rmmzproject": .rpgMakerMZ
        ]
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            guard let engine = rpgMarkers[ext], let (path, _) = try read(name) else { continue }
            add(engine, path: path, kind: .projectMarker)
        }
        if let result = firstCandidateIfRequested() { return result }

        // Deployed unencrypted RGSS projects can omit the editor marker.
        // Probe names/types only: never deserialize Ruby objects or read a large script archive.
        let legacyLayouts: [(GameEngineID, String)] = [
            (.rpgMakerXP, "rxdata"), (.rpgMakerVX, "rvdata"), (.rpgMakerVXAce, "rvdata2")
        ]
        if names.contains("Data") {
            for (engine, ext) in legacyLayouts where evidence[engine] == nil {
                let system = try GameRelativePath("Data/System." + ext)
                let scripts = try GameRelativePath("Data/Scripts." + ext)
                if try reader.exists(system), try reader.exists(scripts) {
                    add(engine, path: system, kind: .dataLayout)
                    add(engine, path: scripts, kind: .dataLayout)
                }
            }
        }
        if let result = firstCandidateIfRequested() { return result }

        // Godot explicitly permits an empty project.godot.
        if names.contains("project.godot"), let (path, _) = try read("project.godot") {
            add(.godot, path: path, kind: .projectMarker)
        }
        if let result = firstCandidateIfRequested() { return result }

        if names.contains("ProjectSettings"), let (path, bytes) = try read("ProjectSettings/ProjectVersion.txt") {
            guard let text = String(data: bytes, encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("m_EditorVersion:") }),
                  let version = line.dropFirst("m_EditorVersion:".count).split(whereSeparator: \.isWhitespace).first,
                  GameProjectContext.validIdentifier(String(version)),
                  try reader.exists(GameRelativePath("Assets"), directory: true) else {
                throw GameProjectError.invalidManifest(path.value)
            }
            add(.unity, path: path, kind: .projectMarker, version: String(version))
            inspected.insert(try GameRelativePath("Assets"))
        }
        if let result = firstCandidateIfRequested() { return result }

        if names.contains("package.json"), let (path, data) = try read("package.json") {
            let package: PackageManifest
            do { package = try JSONDecoder().decode(PackageManifest.self, from: data) }
            catch { throw GameProjectError.invalidManifest(path.value) }
            let packages: [(String, GameEngineID)] = [
                ("phaser", .phaser), ("kaplay", .kaplay), ("playcanvas", .playcanvas),
                ("@babylonjs/core", .babylon), ("babylonjs", .babylon)
            ]
            for dependencies in [package.dependencies, package.devDependencies, package.optionalDependencies] {
                for (name, engine) in packages {
                    guard let requirement = dependencies?[name] else { continue }
                    guard GameProjectContext.validIdentifier(requirement) else {
                        throw GameProjectError.invalidManifest(path.value)
                    }
                    add(engine, path: path, kind: .packageDependency, version: requirement)
                }
            }
            // Cocos Creator 3.x validates a project by package.json + assets/.
            // Require the official creator.version, or the 3.x project UUID
            // plus settings/v2/packages/project.json. A plain npm package with
            // an assets folder does not match either combination.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               try reader.exists(GameRelativePath("assets"), directory: true) {
                let creatorVersion = (object["creator"] as? [String: Any])?["version"] as? String
                let hasCreatorVersion = creatorVersion.map { GameProjectContext.validIdentifier($0) } ?? false
                let hasProjectUUID = object["uuid"] is String
                let hasV2Settings = try reader.exists(
                    GameRelativePath("settings/v2/packages/project.json"))
                if hasCreatorVersion || (hasProjectUUID && hasV2Settings) {
                    add(.cocosCreator, path: path, kind: .projectMarker,
                        version: hasCreatorVersion ? creatorVersion : nil)
                    inspected.insert(try GameRelativePath("assets"))
                }
            }
        }
        if let result = firstCandidateIfRequested() { return result }

        // Native project documents: GDevelop gdVersion/layouts, compiled ink
        // `story.json`, explicit engine metadata, and microStudio project.json.
        // Arbitrary names and a >8 KiB prelude are supported by a bounded
        // streaming key search before the bounded full document read.
        let metadataNames: Set<String> = ["game.json", "project.json", "floe-game.json"]
        let skippedJSONNames: Set<String> = ["package-lock.json", "npm-shrinkwrap.json"]
        let nativeJSONTokens = ["\"gdVersion\"", "\"firstLayout\"", "\"inkVersion\""]
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            let lowerName = name.lowercased()
            guard ext == "json", lowerName != "package.json",
                  lowerName != "story.twine.json",
                  !skippedJSONNames.contains(lowerName) else { continue }
            let path = try GameRelativePath(name)
            try nextProbe()
            if !metadataNames.contains(lowerName) {
                guard let prefix = try reader.readPrefix(path, maximumBytes: 8_192) else { continue }
                try countProbe(prefix.count)
                let text = String(decoding: prefix, as: UTF8.self)
                var looksLikeNativeProject = text.contains("\"gdVersion\"")
                    || text.contains("\"firstLayout\"") || text.contains("\"inkVersion\"")
                if !looksLikeNativeProject, let size = try reader.fileSize(path), size > 0 {
                    guard size <= limits.maximumEngineProjectBytes else {
                        throw GameProjectError.limitExceeded(path.value)
                    }
                    let scanLimit = min(size, limits.maximumEngineProjectBytes)
                    try countProbe(scanLimit)
                    looksLikeNativeProject = try reader.findAnyASCII(
                        nativeJSONTokens, in: path, maximumBytes: scanLimit) != nil
                }
                guard looksLikeNativeProject else { continue }
            }
            guard let data = try read(path, maximumBytes: limits.maximumEngineProjectBytes) else { continue }
            try countProbe(data.count)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let hint = Self.gdevelopVersionHint(in: object) {
                addOnce(.gdevelop, path: path, kind: .projectMarker, version: hint)
            }
            if let inkVersion = Self.compiledInkVersion(in: object) {
                addOnce(.ink, path: path, kind: .projectMarker,
                        version: "ink \(inkVersion)")
            }
            if let value = object["engine"] as? String, let engine = GameEngineID(rawValue: value) {
                addOnce(engine, path: path, kind: .projectMarker)
            }
            if try Self.isMicroStudioProject(object, reader: reader, names: names) {
                addOnce(.microStudio, path: path, kind: .projectMarker)
            }
        }
        if let result = firstCandidateIfRequested() { return result }

        let layouts: [(GameEngineID, [String])] = [
            (.rpgMakerMV, ["js/rpg_core.js", "data/System.json"]),
            (.rpgMakerMZ, ["js/rmmz_core.js", "data/System.json"]),
            (.love, ["main.lua", "conf.lua"]),
            (.renpy, ["game/script.rpy"])
        ]
        for (engine, paths) in layouts where evidence[engine] == nil {
            var found = true
            for name in paths { if try !reader.exists(GameRelativePath(name)) { found = false; break } }
            if found { for name in paths { add(engine, path: try GameRelativePath(name), kind: .dataLayout) } }
        }
        if let result = firstCandidateIfRequested() { return result }

        // Exported Web builds are native roots too. The same source-level
        // inspector is used by the selection inventory, so recognize the
        // documented self-contained shapes without executing any script.
        if let entryName = lowerNames["index.html"] ?? lowerNames["index.htm"] {
            let entry = try GameRelativePath(entryName)
            func has(_ name: String) -> Bool { lowerNames[name] != nil }
            func file(_ name: String) throws -> GameRelativePath? {
                guard let actual = lowerNames[name] else { return nil }
                return try GameRelativePath(actual)
            }
            if evidence[.gdevelop] == nil, has("data.js"), has("gd.js") || has("code0.js") {
                add(.gdevelop, path: entry, kind: .dataLayout)
                if let data = try file("data.js") {
                    add(.gdevelop, path: data, kind: .dataLayout)
                }
            }
            if evidence[.cocosCreator] == nil, has("application.js") {
                let settings = try GameRelativePath("src/settings.json")
                if try reader.exists(settings) {
                    add(.cocosCreator, path: entry, kind: .dataLayout)
                    if let application = try file("application.js") {
                        add(.cocosCreator, path: application, kind: .dataLayout)
                    }
                    add(.cocosCreator, path: settings, kind: .dataLayout)
                }
            }
            // Godot names both export files after the chosen output basename.
            if evidence[.godot] == nil,
               let pack = lowerNames.keys.sorted().first(where: { name in
                   name.hasSuffix(".pck") && name.count > 4 && has(String(name.dropLast(4)) + ".wasm")
               }),
               let packPath = try file(pack),
               let wasmPath = try file(String(pack.dropLast(4)) + ".wasm") {
                add(.godot, path: entry, kind: .dataLayout)
                add(.godot, path: packPath, kind: .dataLayout)
                add(.godot, path: wasmPath, kind: .dataLayout)
            }
            if evidence[.love] == nil, has("love.wasm"), has("game.data"), has("love.js") {
                add(.love, path: entry, kind: .dataLayout)
                for name in ["love.wasm", "game.data", "love.js"] {
                    if let path = try file(name) { add(.love, path: path, kind: .dataLayout) }
                }
            }
            if evidence[.renpy] == nil, has("renpy.wasm"), has("game.zip") {
                add(.renpy, path: entry, kind: .dataLayout)
                for name in ["renpy.wasm", "game.zip"] {
                    if let path = try file(name) { add(.renpy, path: path, kind: .dataLayout) }
                }
            }
            if evidence[.unity] == nil, let buildName = lowerNames["build"] {
                let build = try GameRelativePath(buildName)
                if try reader.exists(build, directory: true) {
                    let entries = try reader.names(in: build, maximum: 512)
                    let lowered = entries.map { $0.lowercased() }
                    let loader = lowered.firstIndex {
                        $0.hasSuffix(".loader.js") || $0.hasSuffix("unityloader.js")
                    }
                    let wasm = lowered.firstIndex { $0.hasSuffix(".wasm") }
                    let data = lowered.firstIndex { $0.hasSuffix(".data") }
                    if loader != nil || (wasm != nil && data != nil) {
                        add(.unity, path: entry, kind: .dataLayout)
                        if let index = loader ?? wasm ?? data {
                            add(.unity, path: try GameRelativePath(buildName + "/" + entries[index]),
                                kind: .dataLayout)
                        }
                    }
                }
            }
        }
        if let result = firstCandidateIfRequested() { return result }

        // Ren'Py projects commonly carry several game/*.rpy files and are not
        // required to retain the starter name script.rpy.
        if evidence[.renpy] == nil, let gameName = lowerNames["game"] {
            let gamePath = try GameRelativePath(gameName)
            if try reader.exists(gamePath, directory: true) {
                let gameNames = try reader.names(in: gamePath, maximum: 256)
                if let script = gameNames.first(where: {
                    ["rpy", "rpyc"].contains(($0 as NSString).pathExtension.lowercased())
                }) {
                    add(.renpy, path: try GameRelativePath(gameName + "/" + script),
                        kind: .dataLayout)
                }
            }
        }
        if let result = firstCandidateIfRequested() { return result }

        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            let engine: GameEngineID?
            switch ext {
            case "ink": engine = .ink
            case "tic": engine = .tic80
            case "twee": engine = .twine
            case "love": engine = .love
            default: engine = nil
            }
            if let engine, try reader.exists(GameRelativePath(name)) {
                add(engine, path: try GameRelativePath(name), kind: .projectMarker)
            }
        }
        if let result = firstCandidateIfRequested() { return result }

        // A Twine 2 HTML export is a standalone native format even when the
        // project has no Floe project.json. Only bounded streaming scans are
        // used, and a failed/short scan is a non-match rather than a false game.
        if let twineName = lowerNames["story.twine.json"] {
            addOnce(.twine, path: try GameRelativePath(twineName), kind: .projectMarker)
        }
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext == "html" || ext == "htm" else { continue }
            let path = try GameRelativePath(name)
            try nextProbe()
            guard let size = try reader.fileSize(path) else { continue }
            try countProbe(min(size, limits.maximumHTMLScanBytes))
            if try Self.isTwineHTML(reader: reader, path: path,
                                    maximumScanBytes: limits.maximumHTMLScanBytes) {
                let version = try Self.twineHTMLVersionHint(reader: reader, path: path,
                                                             maximumScanBytes: limits.maximumHTMLScanBytes)
                addOnce(.twine, path: path, kind: .projectMarker, version: version)
            }
        }
        if let result = firstCandidateIfRequested() { return result }

        // Web-engine projects may vendor the engine script instead of using npm.
        if let entryName = lowerNames["index.html"] ?? lowerNames["index.htm"] {
            let entry = try GameRelativePath(entryName)
            let engineFiles: [(GameEngineID, [String])] = [
                (.phaser, ["phaser.js", "phaser.min.js", "phaser-arcade-physics.min.js"]),
                (.kaplay, ["kaplay.js"]),
                (.babylon, ["babylon.js"]),
                (.playcanvas, ["playcanvas.js"])
            ]
            for (engine, candidates) in engineFiles where evidence[engine] == nil {
                guard let marker = candidates.compactMap({ lowerNames[$0] }).first else { continue }
                add(engine, path: try GameRelativePath(marker), kind: .projectMarker)
                add(engine, path: entry, kind: .dataLayout)
            }
        }
        if let result = firstCandidateIfRequested() { return result }

        // WASM-4 release cartridges are small WebAssembly modules that import
        // env.memory and export update (and often start). Size is checked before
        // reading and the structural probe never executes the module.
        for name in names {
            guard (name as NSString).pathExtension.lowercased() == "wasm" else { continue }
            let path = try GameRelativePath(name)
            try nextProbe()
            guard let size = try reader.fileSize(path), size > 0,
                  size <= limits.maximumWasmCartBytes else { continue }
            try countProbe(size)
            guard let data = try reader.readPrefix(path, maximumBytes: size),
                  Wasm4CartridgeProbe.isCartridge(data) else { continue }
            addOnce(.wasm4, path: path, kind: .projectMarker)
        }

        return makeResult()
    }

    // MARK: - Native document helpers

    private static func gdevelopVersion(
        in object: [String: Any]
    ) -> (major: Int, minor: Int, revision: Int, build: Int)? {
        guard let version = object["gdVersion"] as? [String: Any],
              let major = version["major"] as? Int, let minor = version["minor"] as? Int,
              let revision = version["revision"] as? Int, let build = version["build"] as? Int,
              (3...9).contains(major), (0...99).contains(minor),
              revision >= 0, build >= 0,
              let properties = object["properties"] as? [String: Any],
              let name = properties["name"] as? String,
              GameProjectContext.validIdentifier(name),
              object["layouts"] is [Any] else {
            return nil
        }
        return (major: major, minor: minor, revision: revision, build: build)
    }

    private static func gdevelopVersionHint(in object: [String: Any]) -> String? {
        guard let version = gdevelopVersion(in: object) else { return nil }
        return "\(version.major).\(version.minor).\(version.revision) build \(version.build)"
    }

    /// Compiled ink JSON emitted by inklecate (for example story.json).
    static func compiledInkVersion(in object: [String: Any]) -> Int? {
        guard let version = object["inkVersion"] as? Int, version > 0,
              object["root"] is [Any] else { return nil }
        return version
    }

    /// Native documents that may use an arbitrary filename and are therefore
    /// part of the additive RunKit discovery seam. Fixed-name project.json /
    /// game.json metadata is covered by the path inventory instead.
    static func isNativeJSONDocument(_ object: [String: Any]) -> Bool {
        gdevelopVersion(in: object) != nil || compiledInkVersion(in: object) != nil
    }

    /// Fixed-name project metadata remains a valid root marker even when it is
    /// not a GDevelop/compiled-ink document.
    static func isFixedMetadataJSONDocument(_ object: [String: Any]) -> Bool {
        if isNativeJSONDocument(object) { return true }
        if let engine = object["engine"] as? String,
           GameEngineID(rawValue: engine) != nil { return true }
        if object["language"] as? String == "microscript_v2" { return true }
        if let files = object["files"] as? [String: Any],
           files.keys.contains(where: { $0.lowercased().hasSuffix(".ms") }) { return true }
        let graphics = (object["graphics"] as? String)?.lowercased()
        return ["canvas2d", "m1", "m2d", "m3d", "pixi", "babylon", "micro3d"]
            .contains(graphics ?? "")
    }

    /// The official microStudio export keeps project.json plus real `.ms`
    /// sources (usually ms/ or src/). Floe's explicit engine metadata is handled
    /// by the generic engine field above; this recognizes ordinary exports.
    private static func isMicroStudioProject(_ object: [String: Any],
                                             reader: GameProjectReader,
                                             names: [String]) throws -> Bool {
        let declared = object["language"] as? String
        let graphics = (object["graphics"] as? String)?.lowercased()
        let fileMap = object["files"] as? [String: Any]
        let recognizedGraphics = ["canvas2d", "m1", "m2d", "m3d", "pixi", "babylon", "micro3d"]
            .contains(graphics ?? "")
        guard declared == "microscript_v2" || fileMap != nil || recognizedGraphics else {
            return false
        }

        if let fileMap {
            for key in fileMap.keys where key.lowercased().hasSuffix(".ms") {
                guard let path = try? GameRelativePath(key) else { continue }
                if try reader.exists(path) { return true }
            }
        }
        for directoryName in ["ms", "src"] where names.contains(directoryName) {
            guard let directory = try? GameRelativePath(directoryName) else { continue }
            guard try reader.exists(directory, directory: true) else { continue }
            let entries = try reader.names(in: directory, maximum: 256)
            for entry in entries where entry.lowercased().hasSuffix(".ms") {
                guard let path = try? GameRelativePath(directoryName + "/" + entry) else { continue }
                if try reader.exists(path) { return true }
            }
        }
        for name in names where name.lowercased().hasSuffix(".ms") {
            let path = try GameRelativePath(name)
            if try reader.exists(path) { return true }
        }
        return false
    }

    public static func isTwineHTML(reader: GameProjectReader, path: GameRelativePath,
                                    maximumScanBytes: Int) throws -> Bool {
        guard let offset = try reader.findASCII("<tw-storydata", in: path,
                                                maximumBytes: maximumScanBytes),
              let snippet = try reader.readSnippet(path, offset: offset, length: 16_384) else {
            return false
        }
        let text = String(decoding: snippet, as: UTF8.self)
        guard let tagEnd = text.firstIndex(of: ">") else { return false }
        let tag = String(text[..<tagEnd])
        guard let name = htmlAttribute("name", in: tag), !name.isEmpty,
              let start = htmlAttribute("startnode", in: tag), !start.isEmpty,
              htmlAttribute("format", in: tag) != nil || htmlAttribute("ifid", in: tag) != nil else {
            return false
        }
        return try reader.findASCII("<tw-passagedata", in: path,
                                    maximumBytes: maximumScanBytes) != nil
    }

    private static func twineHTMLVersionHint(reader: GameProjectReader,
                                             path: GameRelativePath,
                                             maximumScanBytes: Int) throws -> String? {
        guard let offset = try reader.findASCII("<tw-storydata", in: path,
                                                maximumBytes: maximumScanBytes),
              let snippet = try reader.readSnippet(path, offset: offset, length: 16_384) else {
            return nil
        }
        let text = String(decoding: snippet, as: UTF8.self)
        guard let tagEnd = text.firstIndex(of: ">") else { return nil }
        let tag = String(text[..<tagEnd])
        guard let format = htmlAttribute("format", in: tag),
              GameProjectContext.validIdentifier(format) else { return nil }
        if let version = htmlAttribute("format-version", in: tag),
           GameProjectContext.validIdentifier(version) {
            return format + " " + version
        }
        return format
    }

    /// Parses a quoted HTML attribute and accepts optional whitespace around
    /// `=` (for example `name = "Story"`). It also avoids matching a suffix such
    /// as `data-name` because the preceding character must not be a name char.
    static func htmlAttribute(_ name: String, in tag: String) -> String? {
        var searchStart = tag.startIndex
        while let range = tag.range(of: name, range: searchStart..<tag.endIndex) {
            let beforeOK = range.lowerBound == tag.startIndex
                || !isAttributeNameCharacter(tag[tag.index(before: range.lowerBound)])
            if beforeOK {
                var cursor = range.upperBound
                func skipWhitespace() {
                    while cursor < tag.endIndex, tag[cursor].isWhitespace {
                        cursor = tag.index(after: cursor)
                    }
                }
                skipWhitespace()
                if cursor < tag.endIndex, tag[cursor] == "=" {
                    cursor = tag.index(after: cursor)
                    skipWhitespace()
                    if cursor < tag.endIndex,
                       tag[cursor] == "\"" || tag[cursor] == "'" {
                        let quote = tag[cursor]
                        cursor = tag.index(after: cursor)
                        let start = cursor
                        while cursor < tag.endIndex, tag[cursor] != quote {
                            cursor = tag.index(after: cursor)
                        }
                        guard cursor < tag.endIndex else { return nil }
                        let value = String(tag[start..<cursor])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        return value.isEmpty ? nil : value
                    }
                }
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func isAttributeNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character == "-" || character == "_" || character == ":"
    }
}

/// Unknown fields, including scripts and imported owner/permission hints, are ignored.
private struct PackageManifest: Decodable {
    let dependencies: [String: String]?
    let devDependencies: [String: String]?
    let optionalDependencies: [String: String]?
}
