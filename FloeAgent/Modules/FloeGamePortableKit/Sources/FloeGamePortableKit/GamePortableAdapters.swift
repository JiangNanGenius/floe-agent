// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public protocol GamePortableAdapter: Sendable {
    var engine: GameEngineID { get }
    var runtime: GamePortableRuntimeIdentity { get }
    func inspect(_ project: GamePortableProjectDescriptor) throws -> GamePortableProfile
    func plan(for project: GamePortableProjectDescriptor, outputURL: URL,
              resources: GamePortablePreparedResources?, sdkURL: URL?) throws -> GamePortableBuildPlan
    func verifyArtifact(at directory: URL, profile: GamePortableProfile?,
                        resources: GamePortablePreparedResources?) throws -> GamePortableArtifactVerification
}

public struct GamePortableRegistry: Sendable {
    private let adapters: [GameEngineID: any GamePortableAdapter]
    public init(_ adapters: [any GamePortableAdapter]) throws {
        var map: [GameEngineID: any GamePortableAdapter] = [:]
        for adapter in adapters {
            guard map[adapter.engine] == nil else { throw GamePortableError.unsupportedEngine(adapter.engine) }
            map[adapter.engine] = adapter
        }
        self.adapters = map
    }
    public var engines: [GameEngineID] { adapters.keys.sorted { $0.rawValue < $1.rawValue } }
    public func adapter(for engine: GameEngineID) -> (any GamePortableAdapter)? { adapters[engine] }
    public func inspect(_ project: GamePortableProjectDescriptor, engine: GameEngineID) throws -> GamePortableProfile {
        guard let adapter = adapters[engine] else { throw GamePortableError.unsupportedEngine(engine) }
        return try adapter.inspect(project)
    }
    public func plan(_ project: GamePortableProjectDescriptor, engine: GameEngineID,
                     outputURL: URL, resources: GamePortablePreparedResources?,
                     sdkURL: URL?) throws -> GamePortableBuildPlan {
        guard let adapter = adapters[engine] else { throw GamePortableError.unsupportedEngine(engine) }
        return try adapter.plan(for: project, outputURL: outputURL, resources: resources, sdkURL: sdkURL)
    }
    public func verifyArtifact(at directory: URL, engine: GameEngineID,
                               profile: GamePortableProfile?,
                               resources: GamePortablePreparedResources?) throws -> GamePortableArtifactVerification {
        guard let adapter = adapters[engine] else { throw GamePortableError.unsupportedEngine(engine) }
        return try adapter.verifyArtifact(at: directory, profile: profile, resources: resources)
    }
}

/// A bounded, read-only candidate root. It never selects a nested root, unpacks
/// an archive or rewrites the imported tree.
public struct GamePortableRootCandidate: Codable, Equatable, Sendable {
    /// Nil means the repository root itself.
    public let root: String?
    public let engines: [GameEngineID]
    public let evidence: [String]
    public init(root: String?, engines: [GameEngineID], evidence: [String]) {
        self.root = root; self.engines = engines; self.evidence = evidence
    }
}

public enum GamePortableRootScanner {
    public static func scan(rootURL: URL, maximumEntries: Int = 20_000,
                            maximumDepth: Int = 3) throws -> [GamePortableRootCandidate] {
        let entries = try GamePortableFileAccess.enumerate(root: rootURL,
            maximumEntries: maximumEntries, maximumDepth: maximumDepth)
        let paths = Set(entries.filter { !$0.directory }.map(\.path.value))
        var directories = Set<String>([""])
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            for count in 0..<parts.count {
                directories.insert(parts.prefix(count).joined(separator: "/"))
            }
        }
        var candidates: [GamePortableRootCandidate] = []
        for directory in directories.sorted() {
            let prefix = directory.isEmpty ? "" : directory + "/"
            func has(_ path: String) -> Bool { paths.contains(prefix + path) }
            var engines: [GameEngineID] = []
            var evidence: [String] = []
            func add(_ engine: GameEngineID, _ paths: [String]) {
                guard !engines.contains(engine) else { return }
                engines.append(engine)
                evidence.append(contentsOf: paths.filter(has).map { prefix + $0 })
            }
            if has("index.html") && (has("js/rpg_core.js") || has("rpgproject") || has("data/System.json")) {
                add(.rpgMakerMV, ["index.html", "js/rpg_core.js", "rpgproject", "data/System.json"])
            } else if has("rpgproject") || has("data/System.json") {
                add(.rpgMakerMV, ["rpgproject", "data/System.json"])
            }
            if has("main.lua") { add(.love, ["main.lua", "conf.lua"]) }
            if paths.contains(where: { $0.hasPrefix(prefix) && $0.lowercased().hasSuffix(".love") && !$0.dropFirst(prefix.count).contains("/") }) {
                add(.love, ["*.love"])
            }
            if has("game/script.rpy") || has("game/screens.rpy") {
                add(.renpy, ["game/script.rpy", "game/screens.rpy"])
            }
            if has("renpy.wasm") && (has("game.zip") || has("game.data")) {
                add(.renpy, ["renpy.wasm", "game.zip", "game.data"])
            }
            guard !engines.isEmpty else { continue }
            candidates.append(.init(root: directory.isEmpty ? nil : directory,
                engines: engines.sorted { $0.rawValue < $1.rawValue }, evidence: evidence.sorted()))
        }
        return candidates
    }
}

enum GamePortableAdapterSupport {
    static func path(_ value: String) -> GameRelativePath { try! GameRelativePath(value) }
    static func exists(_ project: GamePortableProjectDescriptor, _ name: String) -> Bool {
        project.contains(name)
    }
    static func hasPrefix(_ project: GamePortableProjectDescriptor, _ prefix: String) -> Bool {
        project.files.contains { $0.value.hasPrefix(prefix) }
    }
    static func entry(_ project: GamePortableProjectDescriptor, _ name: String) -> GameRelativePath? {
        project.contains(name) ? try? GameRelativePath(name) : nil
    }
    static func inputDeclaration(_ project: GamePortableProjectDescriptor,
                                 engine: GameEngineID) throws -> (GamePortableInputDeclaration?, [GamePortableWarning]) {
        guard project.contains("floe-inputs.json") else {
            return (nil, [.init(code: .unknownInputs,
                message: "No project keyboard declaration; the host must not assume standard bindings.",
                path: "floe-inputs.json")])
        }
        let data = try project.read("floe-inputs.json", maximumBytes: 65_536)
        let declaration = try GamePortableInputDeclaration.decode(data)
        guard declaration.engine == engine else {
            throw GamePortableError.invalidInputDeclaration("engine mismatch")
        }
        return (declaration, [])
    }
    static func keyPaths(_ project: GamePortableProjectDescriptor, candidates: [String]) -> [GameRelativePath] {
        candidates.filter { project.contains($0) }.compactMap { try? GameRelativePath($0) }
    }
}

public struct GamePortableMVAdapter: GamePortableAdapter {
    public let engine: GameEngineID = .rpgMakerMV
    public let runtime: GamePortableRuntimeIdentity
    public init() {
        runtime = try! .init(id: "rpg-maker-mv-corescript", version: "1.3b",
            upstreamURL: "https://github.com/rpgtkoolmv/corescript",
            revision: "182e31449707ba7e406db0485c44c2a9d11e2dcd", license: "MIT")
    }

    public func inspect(_ project: GamePortableProjectDescriptor) throws -> GamePortableProfile {
        let input = try GamePortableAdapterSupport.inputDeclaration(project, engine: engine)
        var warnings = input.1
        let index = GamePortableAdapterSupport.exists(project, "index.html")
        let data = GamePortableAdapterSupport.exists(project, "data/System.json")
        let builtCore = GamePortableAdapterSupport.exists(project, "js/rpg_core.js")
        let modules = GamePortableAdapterSupport.hasPrefix(project, "js/rpg_core/")
        let main = GamePortableAdapterSupport.exists(project, "js/main.js")
        let plugins = GamePortableAdapterSupport.exists(project, "js/plugins.js")
        let web = index && data && builtCore && main && plugins
        let sourceFormat: GamePortableSourceFormat = web ? .rpgMakerMVWeb
            : (data || modules || GamePortableAdapterSupport.exists(project, "rpgproject") ? .rpgMakerMVProject : .unknown)
        let readiness: GamePortableReadiness = web ? .webReady
            : (data || modules || GamePortableAdapterSupport.exists(project, "rpgproject") ? .buildRequired : .sourceOnly)
        if !web {
            warnings.append(.init(code: .buildRequired,
                message: builtCore ? "Web entry or runtime files are incomplete."
                    : "The official CoreScript/web runtime must be assembled before Web play.",
                path: "index.html"))
        }
        if !main || !plugins {
            warnings.append(.init(code: .missingRuntime,
                message: "js/main.js and js/plugins.js are required by the standard MV boot path."))
        }
        if project.files.contains(where: { $0.value.hasPrefix("data/") && $0.value.lowercased().hasSuffix(".rpgmvp") }) {
            warnings.append(.init(code: .encryptedAssets,
                message: "Encrypted MV assets require the project's original encryption key; Web play is not claimed.",
                path: "data"))
        }
        for file in project.files where file.value.hasPrefix("js/plugins/") && file.value.hasSuffix(".js") {
            guard let bytes = try? project.read(file.value, maximumBytes: 262_144),
                  let text = String(data: bytes, encoding: .utf8) else { continue }
            if text.contains("require(") || text.contains("child_process") || text.contains("nw.") {
                warnings.append(.init(code: .nativePlugin,
                    message: "A plugin uses Node/nw.js APIs that the restricted Web runtime does not provide.",
                    path: file.value))
            }
        }
        let bridge = GamePortableAdapterSupport.exists(project, "js/floe_bridge.js")
        let capabilities: GamePortableCapabilities
        if web {
            capabilities = .init(readiness: .webReady, input: .supported,
                stateSnapshot: bridge ? .supported : .unknown, restart: .supported,
                save: bridge ? .supported : .unknown, choose: bridge ? .supported : .unknown)
            if !bridge {
                warnings.append(.init(code: .hostSnapshotUnavailable,
                    message: "This imported project has no Floe bridge; keyboard play may work, but host snapshot/restore is not claimed."))
            }
        } else {
            capabilities = .init(readiness: readiness, input: .buildRequired,
                stateSnapshot: .buildRequired, restart: .buildRequired,
                save: .buildRequired, choose: .buildRequired)
        }
        return .init(engine: engine, sourceFormat: sourceFormat,
            entry: GamePortableAdapterSupport.entry(project, "index.html"), readiness: readiness,
            capabilities: capabilities, runtime: runtime, inputDeclaration: input.0,
            keyPaths: GamePortableAdapterSupport.keyPaths(project, candidates: [
                "index.html", "rpgproject", "data/System.json", "js/main.js", "js/plugins.js",
                "js/rpg_core.js", "js/rpg_core", "js/floe_bridge.js", "floe-inputs.json"
            ]), warnings: warnings)
    }

    public func plan(for project: GamePortableProjectDescriptor, outputURL: URL,
                     resources: GamePortablePreparedResources?, sdkURL: URL?) throws -> GamePortableBuildPlan {
        try GamePortableBuildChecks.output(outputURL, outside: [project.rootURL])
        let profile = try inspect(project)
        guard profile.entry != nil else {
            throw GamePortableError.invalidArtifact("RPG Maker MV project has no index.html entry")
        }
        if profile.readiness == .webReady {
            return .init(engine: engine, kind: .sourceCopy, entry: profile.entry!,
                steps: [], requiresExternalTool: false, resourceID: nil,
                outputs: [profile.entry!.value], notes: ["Existing index.html and runtime are served unchanged."])
        }
        let modules = GamePortableAdapterSupport.hasPrefix(project, "js/rpg_core/")
        if modules {
            return .init(engine: engine, kind: .mvCoreAssembly, entry: profile.entry!,
                steps: [.init(kind: .assembleFiles, executable: nil, arguments: [], outputs: ["js/rpg_core.js"],
                    note: "Concatenate the project's own js/rpg_core/*.js in rpg_core.json order; do not replace plugins or data.")],
                requiresExternalTool: false, resourceID: nil, outputs: [profile.entry!.value],
                notes: ["The imported source tree is preserved; only a separate built artifact is produced."])
        }
        guard let resources, resources.engine == engine else {
            throw GamePortableError.resourceMismatch("rpg-maker-mv prepared CoreScript resources are required")
        }
        try resources.verify()
        return .init(engine: engine, kind: .mvTemplateAssembly, entry: profile.entry!,
            steps: [.init(kind: .assembleFiles, executable: nil, arguments: [],
                outputs: ["js/rpg_core.js", "js/rpg_managers.js", "js/rpg_objects.js",
                          "js/rpg_scenes.js", "js/rpg_sprites.js", "js/rpg_windows.js"],
                note: "Copy the project tree, merge the pinned MIT CoreScript and reviewed libs, and preserve data/plugins/assets.")],
            requiresExternalTool: false, resourceID: resources.id, outputs: [profile.entry!.value],
            notes: ["No RTP or editor asset is added."])
    }

    public func verifyArtifact(at directory: URL, profile: GamePortableProfile?,
                               resources: GamePortablePreparedResources?) throws -> GamePortableArtifactVerification {
        try GamePortableArtifactVerifier.verify(directory: directory, engine: engine,
            profile: profile, resources: resources)
    }
}

public struct GamePortableLoveAdapter: GamePortableAdapter {
    public let engine: GameEngineID = .love
    public let runtime: GamePortableRuntimeIdentity
    public init() {
        runtime = try! .init(id: "lovejs", version: "11.4.1",
            upstreamURL: "https://github.com/Davidobot/love.js",
            revision: "8f9a7b85da9149b6d4d0af46442ead1e71f76477",
            license: "MIT; LÖVE 11.4 zlib; LGPL-2.1 mpg123")
    }

    public func inspect(_ project: GamePortableProjectDescriptor) throws -> GamePortableProfile {
        let input = try GamePortableAdapterSupport.inputDeclaration(project, engine: engine)
        var warnings = input.1
        let index = GamePortableAdapterSupport.exists(project, "index.html")
        let wasm = GamePortableAdapterSupport.exists(project, "love.wasm")
        let data = GamePortableAdapterSupport.exists(project, "game.data")
        let loader = GamePortableAdapterSupport.exists(project, "love.js")
        let web = index && wasm && data && loader
        let hasMain = GamePortableAdapterSupport.exists(project, "main.lua")
        let lovePackage = project.files.first { $0.value.lowercased().hasSuffix(".love") }
        let sourceFormat: GamePortableSourceFormat = web ? .loveJSWeb
            : (hasMain ? .loveSource : (lovePackage != nil ? .lovePackage : .unknown))
        let readiness: GamePortableReadiness = web ? .webReady
            : ((hasMain || lovePackage != nil) ? .buildRequired : .sourceOnly)
        if !web {
            warnings.append(.init(code: .buildRequired,
                message: "A pinned love.js package must compile this LÖVE source before Web play.",
                path: hasMain ? "main.lua" : lovePackage?.value))
        }
        if hasMain && !GamePortableAdapterSupport.exists(project, "conf.lua") {
            warnings.append(.init(code: .missingRuntime, message: "conf.lua is absent; default LÖVE configuration is used.", path: "conf.lua"))
        }
        let bridge = GamePortableAdapterSupport.exists(project, "floe_bridge.js")
        let capabilities: GamePortableCapabilities = web
            ? .init(readiness: .webReady, input: .supported, stateSnapshot: .unsupported,
                    restart: .supported, save: .engineInternal, choose: .unsupported)
            : .init(readiness: readiness, input: .buildRequired, stateSnapshot: .buildRequired,
                    restart: .buildRequired, save: .buildRequired, choose: .buildRequired)
        if web && !bridge {
            warnings.append(.init(code: .unknownInputs,
                message: "This imported love.js artifact has no Floe bridge; keyboard play may work but readiness/state are not claimed."))
        }
        if web {
            warnings.append(.init(code: .hostSnapshotUnavailable,
                message: "love.js has no host snapshot API; engine-internal saves require persistent browser storage and an acknowledged filesystem flush before close."))
        }
        return .init(engine: engine, sourceFormat: sourceFormat,
            entry: GamePortableAdapterSupport.entry(project, "index.html"), readiness: readiness,
            capabilities: capabilities, runtime: runtime, inputDeclaration: input.0,
            keyPaths: GamePortableAdapterSupport.keyPaths(project, candidates: [
                "main.lua", "conf.lua", "index.html", "love.wasm", "game.data", "love.js",
                "floe_bridge.js", "floe-inputs.json"
            ] + (lovePackage.map { [$0.value] } ?? [])), warnings: warnings)
    }

    public func plan(for project: GamePortableProjectDescriptor, outputURL: URL,
                     resources: GamePortablePreparedResources?, sdkURL: URL?) throws -> GamePortableBuildPlan {
        try GamePortableBuildChecks.output(outputURL, outside: [project.rootURL])
        let profile = try inspect(project)
        if profile.readiness == .webReady {
            return .init(engine: engine, kind: .sourceCopy, entry: profile.entry!,
                steps: [], requiresExternalTool: false, resourceID: nil,
                outputs: [profile.entry!.value], notes: ["Existing love.js artifact is served unchanged."])
        }
        guard let resources, resources.engine == engine else {
            throw GamePortableError.resourceMismatch("love.js 11.4.1 prepared resources are required")
        }
        try resources.verify()
        let package: String
        var steps: [GamePortableBuildStep] = []
        if profile.sourceFormat == .loveSource {
            package = "{{output}}/floe-game.love"
            steps.append(.init(kind: .archiveSource, executable: nil, arguments: [],
                outputs: ["floe-game.love"],
                note: "Archive the imported source folder as a standard .love ZIP through the host archive service; never feed the directory path to love.js."))
        } else if let file = project.files.first(where: { $0.value.lowercased().hasSuffix(".love") }) {
            package = "{{projectRoot}}/" + file.value
        } else {
            throw GamePortableError.invalidArtifact("LÖVE source or .love package")
        }
        steps.append(.init(kind: .runNode, executable: "node",
            arguments: ["{{resources}}/cli/index.js", package, "{{output}}", "-c", "-t", "{{title}}", "-m", "{{memory}}"],
            outputs: ["index.html", "game.data", "love.wasm", "love.js"],
            note: "Use the prepared love.js 11.4.1 compatibility build (single-threaded; no SharedArrayBuffer/COOP requirement)."))
        return .init(engine: engine, kind: .loveJSPackage, entry: GamePortableAdapterSupport.path("index.html"),
            steps: steps, requiresExternalTool: true, resourceID: resources.id,
            outputs: ["index.html", "game.data", "love.wasm", "love.js"],
            notes: ["The generated game.data contains the original .love bytes; source and licenses stay in the project/artifact."])
    }

    public func verifyArtifact(at directory: URL, profile: GamePortableProfile?,
                               resources: GamePortablePreparedResources?) throws -> GamePortableArtifactVerification {
        try GamePortableArtifactVerifier.verify(directory: directory, engine: engine,
            profile: profile, resources: resources)
    }
}

public struct GamePortableRenPyAdapter: GamePortableAdapter {
    public let engine: GameEngineID = .renpy
    public let runtime: GamePortableRuntimeIdentity
    public init() {
        runtime = try! .init(id: "renpy-web", version: "8.5.3",
            upstreamURL: "https://www.renpy.org/dl/8.5.3/renpy-8.5.3-web.zip",
            revision: "8.5.3.26051504+39895c1e017f0b36ffea2447d97eccd69d76ee1c",
            license: "MIT; LGPL-2.1 FFmpeg/FriBidi/chardet/SDL_gfx/pygame")
    }

    public func inspect(_ project: GamePortableProjectDescriptor) throws -> GamePortableProfile {
        let input = try GamePortableAdapterSupport.inputDeclaration(project, engine: engine)
        var warnings = input.1
        let index = GamePortableAdapterSupport.exists(project, "index.html")
        let wasm = GamePortableAdapterSupport.exists(project, "renpy.wasm")
        let game = GamePortableAdapterSupport.exists(project, "game.zip")
            || GamePortableAdapterSupport.exists(project, "game.data")
        let web = index && wasm && game
        let hasRPY = GamePortableAdapterSupport.hasPrefix(project, "game/") &&
            project.files.contains { $0.value.hasPrefix("game/") && $0.value.hasSuffix(".rpy") }
        let hasRPYC = project.files.contains { $0.value.hasPrefix("game/") && $0.value.hasSuffix(".rpyc") }
        var hasDesktopProject = hasRPY || hasRPYC
        if !web, !hasDesktopProject {
            let reader = try GameProjectReader(rootURL: project.rootURL, maximumFileBytes: 40)
            hasDesktopProject = try GameRenPyArchive.first(in: reader, paths: project.files) != nil
        }
        let sourceFormat: GamePortableSourceFormat = web ? .renpyWeb
            : (hasDesktopProject ? .renpyProject : .unknown)
        let readiness: GamePortableReadiness = web ? .webReady
            : (hasDesktopProject ? .buildRequired : .sourceOnly)
        if !web {
            warnings.append(.init(code: .webBeta,
                message: "The official Ren'Py Web route is Beta; the pinned 8.5.3 launcher web_build command is required.",
                path: hasRPY ? "game/script.rpy" : "game"))
        }
        warnings.append(.init(code: .hostSnapshotUnavailable,
            message: "The official Ren'Py Web runtime exposes no complete host snapshot; Ren'Py saves remain engine-internal."))
        if project.files.contains(where: { $0.value.hasPrefix("game/") && $0.value.lowercased().hasSuffix(".rpy") }) {
            for file in project.files where file.value.hasPrefix("game/tl/") == false && file.value.hasSuffix(".rpy") {
                guard let bytes = try? project.read(file.value, maximumBytes: 262_144),
                      let text = String(data: bytes, encoding: .utf8) else { continue }
                if text.contains("renpy.emscripten") || text.contains("threading") || text.contains("requests.") {
                    warnings.append(.init(code: .webBeta,
                        message: "Script uses an API limited by the Ren'Py Web runtime (threading/networking/emscripten).",
                        path: file.value))
                }
            }
        }
        let capabilities: GamePortableCapabilities = web
            ? .init(readiness: .webReady, input: .supported, stateSnapshot: .unsupported,
                    restart: .supported, save: .engineInternal, choose: .unsupported)
            : .init(readiness: readiness, input: .buildRequired, stateSnapshot: .buildRequired,
                    restart: .buildRequired, save: .buildRequired, choose: .buildRequired)
        return .init(engine: engine, sourceFormat: sourceFormat,
            entry: GamePortableAdapterSupport.entry(project, "index.html"), readiness: readiness,
            capabilities: capabilities, runtime: runtime, inputDeclaration: input.0,
            keyPaths: GamePortableAdapterSupport.keyPaths(project, candidates: [
                "game/script.rpy", "game/screens.rpy", "game.zip", "game.data", "renpy.wasm",
                "index.html", "floe_bridge.js", "floe-inputs.json"
            ]), warnings: warnings)
    }

    public func plan(for project: GamePortableProjectDescriptor, outputURL: URL,
                     resources: GamePortablePreparedResources?, sdkURL: URL?) throws -> GamePortableBuildPlan {
        try GamePortableBuildChecks.output(outputURL, outside: [project.rootURL])
        let profile = try inspect(project)
        if profile.readiness == .webReady {
            return .init(engine: engine, kind: .sourceCopy, entry: profile.entry!,
                steps: [], requiresExternalTool: false, resourceID: nil,
                outputs: [profile.entry!.value], notes: ["Existing Ren'Py Web build is served unchanged."])
        }
        guard profile.sourceFormat == .renpyProject else {
            throw GamePortableError.invalidArtifact("Ren'Py game folder with scripts or a standard RPA archive")
        }
        guard sdkURL != nil else {
            throw GamePortableError.invalidArtifact("pinned Ren'Py 8.5.3 SDK path is required")
        }
        return .init(engine: engine, kind: .renpyWebBuild,
            entry: GamePortableAdapterSupport.path("index.html"),
            steps: [.init(kind: .runRenPy, executable: "renpy.sh",
                arguments: ["launcher", "web_build", "{{projectRoot}}", "--destination", "{{output}}"],
                outputs: ["index.html", "renpy.wasm", "renpy.js", "game.zip"],
                note: "Official Ren'Py 8.5.3 launcher Web (Beta) build from the pinned SDK; no host Python interpreter is used as a game runtime.")],
            requiresExternalTool: true, resourceID: resources?.id,
            outputs: ["index.html", "renpy.wasm", "renpy.js", "game.zip"],
            notes: ["The SDK must contain the pinned web support hash. Build output is a Web artifact, never an iOS executable."])
    }

    public func verifyArtifact(at directory: URL, profile: GamePortableProfile?,
                               resources: GamePortablePreparedResources?) throws -> GamePortableArtifactVerification {
        try GamePortableArtifactVerifier.verify(directory: directory, engine: engine,
            profile: profile, resources: resources)
    }
}
