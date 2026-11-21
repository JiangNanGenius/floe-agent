// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

struct GameRunAvailability: Sendable, Equatable {
    let narrativeResources: Bool
    let portableResources: Set<GameEngineID>
    let runtimePacks: Set<GameEngineID>
    let portableBuildPort: Bool
    let externalBuildProvider: Bool
    let renpySDK: Bool
}

struct GameRunRouteEvaluation: Sendable {
    let plan: GameRunRoutePlan
    /// Real evidence paths relative to the selected root. A route never adds a
    /// candidate for an engine whose layout was not observed here.
    let evidence: [GameEngineEvidence]
}

enum GameRunRoutePlanner {
    static func path(_ value: String) -> GameRelativePath { try! GameRelativePath(value) }

    static func evaluate(engine: GameEngineID, index: GameRunSourceIndex,
                         web: GameRunWebEntry?,
                         availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        let entry = web?.entry ?? defaultEntry(index)
        switch engine {
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            return try legacyRPG(engine: engine, index: index)
        case .rpgMakerMV:
            return try rpgMakerMV(index: index, entry: entry, web: web, availability: availability)
        case .rpgMakerMZ:
            return try rpgMakerMZ(index: index, entry: entry, web: web,
                                  availability: availability)
        case .phaser, .kaplay, .babylon, .playcanvas:
            return try scriptEngines(engine: engine, index: index, entry: entry, web: web,
                                     availability: availability)
        case .love:
            return try love(index: index, entry: entry, web: web, availability: availability)
        case .renpy:
            return try renpy(index: index, entry: entry, web: web, availability: availability)
        case .tyranoScript:
            return tyranoScript(index: index, web: web)
        case .tic80:
            return try narrative(engine: .tic80, marker: "cart.tic", index: index,
                                 availability: availability)
        case .wasm4:
            return try narrative(engine: .wasm4, marker: "cart.wasm", index: index,
                                 availability: availability)
        case .ink:
            return try narrative(engine: .ink, index: index, hasMarker: index.anyFile(suffix: ".ink"),
                                 availability: availability)
        case .twine:
            if let web, web.isPublishedTwine, web.isSelfContained, web.hasScriptTag {
                return staticRoute(engine: engine, entry: web.entry, routeID: "static.twine-web",
                    notes: [], evidence: [web.entry])
            }
            if index.contains("story.twine.json") {
                return try narrative(engine: .twine, index: index, hasMarker: true,
                                     availability: availability)
            }
            if index.anyFile(suffix: ".twee") {
                return unavailable(engine: .twine, routeID: "narrative.twine",
                    detail: "This root contains only raw .twee files. Import it through the Twine adapter so the standard story.twine.json model is present; the original files are preserved.")
            }
            return try narrative(engine: .twine, index: index, hasMarker: false,
                                 availability: availability)
        case .microStudio:
            return try narrative(engine: .microStudio, index: index,
                                 hasMarker: index.anyFile(suffix: ".ms"), availability: availability)
        case .gdevelop:
            return try gdevelop(index: index, entry: entry, web: web, availability: availability)
        case .godot:
            return try godot(index: index, entry: entry, web: web, availability: availability)
        case .unity:
            return try unity(index: index, entry: entry, web: web, availability: availability)
        case .cocosCreator:
            return try cocos(index: index, entry: entry, web: web, availability: availability)
        }
    }

    // MARK: - Legacy RPG Maker (guest runtime only)

    private static func legacyRPG(engine: GameEngineID,
                                  index: GameRunSourceIndex) throws -> GameRunRouteEvaluation {
        let marker: String
        let data: String
        let system: String
        switch engine {
        case .rpgMakerXP: marker = "Game.rxproj"; data = "Data"; system = "Data/System.rxdata"
        case .rpgMakerVX: marker = "Game.rvproj"; data = "Data"; system = "Data/System.rvdata"
        default: marker = "Game.rvproj2"; data = "Data"; system = "Data/System.rvdata2"
        }
        let markerPath = first(index, marker)
        let systemPath = first(index, system)
        let hasData = index.hasPrefix(data + "/")
        guard markerPath != nil || (systemPath != nil && hasData) else {
            return unavailable(engine: engine, routeID: "guest.rgss",
                detail: "No \(engine.rawValue) project marker was found in this root.")
        }
        let requirement = GameRunPrerequisite.guestRuntime(id: "rgss-\(engine.rawValue)",
            detail: "This \(engine.rawValue) project requires an RGSS-compatible guest/native runtime. Floe does not claim a Web engine for it, and the original project files are preserved unchanged.")
        var evidence: [GameEngineEvidence] = []
        if let markerPath { evidence.append(.init(path: markerPath, kind: .projectMarker)) }
        if let systemPath { evidence.append(.init(path: systemPath, kind: .dataLayout)) }
        return .init(plan: .init(engine: engine, action: .guestRuntime,
                                 routeID: "guest.rgss-\(engine.rawValue)",
                                 entry: nil, prerequisites: [requirement],
                                 notes: ["No Web build is performed. Source, data and assets are kept as imported."]),
                     evidence: evidence)
    }

    // MARK: - RPG Maker MV/MZ

    private static func rpgMakerMV(index: GameRunSourceIndex, entry: GameRelativePath?,
                                   web: GameRunWebEntry?,
                                   availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        let data = first(index, "data/System.json")
        let core = first(index, "js/rpg_core.js")
        let main = first(index, "js/main.js")
        let plugins = first(index, "js/plugins.js")
        let modules = index.anyFile(prefix: "js/rpg_core/")
        let marker = first(index, "rpgproject")
        let webReady = data != nil && core != nil && main != nil && plugins != nil
        if webReady, entry != nil, web?.isSelfContained == true {
            return staticRoute(engine: .rpgMakerMV, entry: entry!, routeID: "static.rpgmaker-mv-web",
                notes: ["The imported MV Web runtime is served unchanged; all script references resolve inside the artifact."],
                evidence: [core!, data!, entry!])
        }
        if webReady, let web, !web.isSelfContained {
            let missing = web.missingReferences.joined(separator: ", ")
            let external = web.externalReferences.joined(separator: ", ")
            let detail = [missing.isEmpty ? nil : "Missing scripts: \(missing)",
                          external.isEmpty ? nil : "External scripts: \(external)"]
                .compactMap { $0 }.joined(separator: "; ")
            return unavailable(engine: .rpgMakerMV, routeID: "static.rpgmaker-mv-web",
                detail: "The game's own runtime is present, but its Web entry cannot be loaded locally. \(detail)")
        }
        let hasSource = data != nil || marker != nil || modules || core != nil
        guard hasSource else {
            return unavailable(engine: .rpgMakerMV, routeID: "portable.mv",
                detail: "No RPG Maker MV project or Web runtime was found in this root.")
        }
        guard let entry else {
            return unavailable(engine: .rpgMakerMV, routeID: "portable.mv",
                detail: "The MV source has no index.html Web entry. Add the standard Web entry or use the official MV deployment; the source is preserved.")
        }
        guard main != nil, plugins != nil else {
            return unavailable(engine: .rpgMakerMV, routeID: "portable.mv",
                detail: "The MV source lacks js/main.js or js/plugins.js. Provide the standard Web entry and runtime files, or use the official MV deployment; the source is preserved.")
        }
        var prerequisites: [GameRunPrerequisite] = []
        if !modules && !availability.portableResources.contains(.rpgMakerMV) {
            prerequisites.append(.preparedResourcePack(id: "rpg-maker-mv-corescript",
                detail: "The prepared official MIT RPG Maker MV CoreScript resources are required to assemble this project."))
        }
        let routeID = modules ? "portable.mv-core-assembly" : "portable.mv-template-assembly"
        var evidence: [GameEngineEvidence] = [.init(path: entry, kind: .projectMarker)]
        if let data { evidence.append(.init(path: data, kind: .dataLayout)) }
        if let core { evidence.append(.init(path: core, kind: .dataLayout)) }
        return .init(plan: .init(engine: .rpgMakerMV, action: .portableAssembly,
                                 routeID: routeID, entry: entry, prerequisites: prerequisites,
                                 notes: [modules
                                    ? "The project's own js/rpg_core modules are concatenated in project order into a separate artifact."
                                    : "A separate artifact merges the pinned CoreScript; data, plugins and assets are preserved."]),
                     evidence: evidence)
    }

    private static func rpgMakerMZ(index: GameRunSourceIndex, entry: GameRelativePath?,
                                   web: GameRunWebEntry?,
                                   availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        let data = first(index, "data/System.json")
        let rmmz = index.files.first {
            $0.path.value.lowercased().hasPrefix("js/rmmz_") && $0.path.value.lowercased().hasSuffix(".js")
        }?.path
        let legacyMarker: GameRelativePath? = index.files.first {
            $0.path.value.lowercased().hasSuffix(".rmmzproject")
        }?.path
        let marker = first(index, "Game.rmmzproject") ?? legacyMarker
        let webReady = data != nil && rmmz != nil && entry != nil
        if webReady, web?.isSelfContained == true {
            return staticRoute(engine: .rpgMakerMZ, entry: entry!, routeID: "static.rpgmaker-mz-web",
                notes: ["The imported MZ Web export is served unchanged with its own licensed runtime files."],
                evidence: [entry!, data!, rmmz!])
        }
        guard marker != nil || (data != nil && rmmz != nil) else {
            return unavailable(engine: .rpgMakerMZ, routeID: "external.rpgmaker-mz",
                detail: "No RPG Maker MZ project or Web export was found in this root.")
        }
        let requirement = GameRunPrerequisite.licensedRuntime(id: "rpg-maker-mz-web",
            detail: "A user-supplied licensed RPG Maker MZ Web runtime/editor deployment is required. Floe does not bundle MZ engine files or gate this on a developer account.")
        var prerequisites: [GameRunPrerequisite] = [requirement]
        if !availability.externalBuildProvider {
            prerequisites.append(.hostBuildProvider(id: "external-build",
                detail: "The host's existing jobs/CI build provider is required to run the licensed MZ deployment."))
        }
        var evidence: [GameEngineEvidence] = []
        if let marker { evidence.append(.init(path: marker, kind: .projectMarker)) }
        if let data { evidence.append(.init(path: data, kind: .dataLayout)) }
        return .init(plan: .init(engine: .rpgMakerMZ, action: .externalBuild,
                                 routeID: "external.rpgmaker-mz-web",
                                 entry: path("index.html"),
                                 prerequisites: prerequisites,
                                 notes: ["Source and assets are preserved. The host may use a licensed MZ runtime/deployment service; no fake Web engine is used."]),
                     evidence: evidence)
    }

    // MARK: - Phaser / KAPLAY / Babylon / PlayCanvas

    private static func scriptEngines(engine: GameEngineID, index: GameRunSourceIndex,
                                      entry: GameRelativePath?, web: GameRunWebEntry?,
                                      availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        let engineNames: [String]
        switch engine {
        case .phaser: engineNames = ["phaser.js", "phaser.min.js", "phaser-arcade-physics.min.js"]
        case .kaplay: engineNames = ["kaplay.js", "runtime/engine.js", "engine.js"]
        case .babylon: engineNames = ["babylon.js", "runtime/engine.js", "engine.js"]
        default: engineNames = ["playcanvas.js", "runtime/engine.js", "engine.js"]
        }
        let engineFile = index.files.first { file in
            let name = file.path.value.lowercased()
            return engineNames.contains { name == $0 || name.hasSuffix("/" + $0) }
        }?.path
        if let entry, web?.isSelfContained == true, engineFile != nil {
            return staticRoute(engine: engine, entry: entry, routeID: "static.\(engine.rawValue)",
                notes: ["The ready Web project and its local engine script are copied unchanged."],
                evidence: [entry, engineFile!])
        }
        guard let entry else {
            if index.contains("package.json") {
                return externalRoute(engine: engine, kind: .webBundle, routeID: "external.web-bundle",
                    entry: path("index.html"), availability: availability,
                    requirement: .externalTool(id: "web-bundle",
                        detail: "The host's existing Node/bundler build service is required to produce a Web entry from this npm source project."),
                    evidence: [.init(path: first(index, "package.json")!, kind: .projectMarker)],
                    notes: ["No Web entry exists yet; the source project is preserved."])
            }
            return unavailable(engine: engine, routeID: "static.\(engine.rawValue)",
                detail: "No index.html Web entry was found in this root.")
        }
        if let web, !web.externalReferences.isEmpty {
            if index.contains("package.json") {
                return externalRoute(engine: engine, kind: .webBundle, routeID: "external.web-bundle",
                    entry: entry, availability: availability,
                    requirement: .externalTool(id: "web-bundle",
                        detail: "The source loads remote scripts; the host's existing Node/bundler build service must produce a self-contained local Web bundle."),
                    evidence: [.init(path: entry, kind: .projectMarker),
                               .init(path: first(index, "package.json")!, kind: .projectMarker)],
                    notes: ["No remote script is executed by the offline player; the source project is preserved."])
            }
            return unavailable(engine: engine, routeID: "static.\(engine.rawValue)",
                detail: "index.html loads remote scripts, which the offline game CSP blocks. Supply a local Web bundle.")
        }
        let missingEngineReferences = web?.missingReferences.filter {
            isEngineReference($0, engine: engine)
        } ?? []
        if engineFile == nil, !missingEngineReferences.isEmpty,
           missingEngineReferences.allSatisfy(packableEngineReference),
           web?.missingReferences.count == missingEngineReferences.count {
            var prerequisites: [GameRunPrerequisite] = []
            if availability.runtimePacks.contains(engine) == false {
                prerequisites.append(.preparedResourcePack(id: "\(engine.rawValue)-runtime",
                    detail: "A prepared \(engine.rawValue) runtime pack is required to assemble the referenced local engine script."))
            }
            return .init(plan: .init(engine: engine, action: .runtimePackAssembly,
                                     routeID: "runtime.\(engine.rawValue)", entry: entry,
                                     prerequisites: prerequisites,
                                     notes: ["The project tree is copied and the verified runtime pack is installed without rewriting the imported source."]),
                         evidence: [.init(path: entry, kind: .projectMarker)])
        }
        if index.contains("package.json") {
            return externalRoute(engine: engine, kind: .webBundle, routeID: "external.web-bundle",
                entry: entry, availability: availability,
                requirement: .externalTool(id: "web-bundle",
                    detail: "The host's existing Node/bundler build service is required to produce the final Web bundle."),
                evidence: [.init(path: entry, kind: .projectMarker),
                           .init(path: first(index, "package.json")!, kind: .projectMarker)],
                notes: ["The source project is preserved; no engine is downloaded or executed by this package."])
        }
        if web?.isSelfContained == true {
            // Plain offline static HTML under a Web engine identity. Inline or
            // local scripts only; no engine-specific state is claimed.
            return staticRoute(engine: engine, entry: entry, routeID: "static.plain-web",
                notes: ["A self-contained local Web entry is served unchanged. Engine-specific helpers may be absent."],
                evidence: [entry])
        }
        return unavailable(engine: engine, routeID: "static.\(engine.rawValue)",
            detail: "index.html references local scripts that are missing from this root.")
    }

    /// A runtime pack can only satisfy a simple local script path such as
    /// runtime/engine.js or vendor/phaser.js. Deep node_modules/dist paths need
    /// the host's real bundler instead of a single-file pack copy.
    static func packableEngineReference(_ reference: String) -> Bool {
        let count = reference.split(separator: "/", omittingEmptySubsequences: false).count
        return count <= 2
    }

    static func isEngineReference(_ reference: String, engine: GameEngineID) -> Bool {
        let lower = reference.lowercased()
        switch engine {
        case .phaser: return lower.contains("phaser") && lower.hasSuffix(".js")
        case .kaplay: return lower.hasSuffix("engine.js") || lower.contains("kaplay")
        case .babylon: return lower.hasSuffix("engine.js") || lower.contains("babylon")
        case .playcanvas: return lower.hasSuffix("engine.js") || lower.contains("playcanvas")
        default: return false
        }
    }

    // MARK: - LÖVE and Ren'Py

    private static func love(index: GameRunSourceIndex, entry: GameRelativePath?,
                             web: GameRunWebEntry?,
                             availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        let wasm = first(index, "love.wasm")
        let data = first(index, "game.data")
        let loader = first(index, "love.js")
        let webReady = entry != nil && wasm != nil && data != nil && loader != nil
        if webReady, web?.isSelfContained == true {
            return staticRoute(engine: .love, entry: entry!, routeID: "static.love-js-web",
                notes: ["The imported love.js Web artifact is served unchanged; engine-internal saves stay in browser storage."],
                evidence: [entry!, wasm!, data!, loader!])
        }
        let main = first(index, "main.lua")
        let package = index.files.first { $0.path.value.lowercased().hasSuffix(".love") }?.path
        guard main != nil || package != nil else {
            return unavailable(engine: .love, routeID: "portable.love-js",
                detail: "No LÖVE main.lua or .love package was found in this root.")
        }
        var prerequisites: [GameRunPrerequisite] = []
        if !availability.portableResources.contains(.love) {
            prerequisites.append(.preparedResourcePack(id: "lovejs-11.4.1",
                detail: "The prepared love.js 11.4.1 compatibility resources are required to build this source."))
        }
        if !availability.portableBuildPort {
            prerequisites.append(.hostBuildProvider(id: "portable-build",
                detail: "The host's existing Node/job build provider is required to run the prepared love.js CLI."))
        }
        var evidence: [GameEngineEvidence] = []
        if let main { evidence.append(.init(path: main, kind: .projectMarker)) }
        if let package { evidence.append(.init(path: package, kind: .projectMarker)) }
        return .init(plan: .init(engine: .love, action: .portableAssembly,
                                 routeID: "portable.love-js", entry: path("index.html"),
                                 prerequisites: prerequisites,
                                 notes: ["The source is preserved. The build produces index.html, game.data, love.wasm and love.js in a separate artifact."]),
                     evidence: evidence)
    }

    private static func renpy(index: GameRunSourceIndex, entry: GameRelativePath?,
                              web: GameRunWebEntry?,
                              availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        let wasm = first(index, "renpy.wasm")
        let game = first(index, "game.zip") ?? first(index, "game.data")
        let webReady = entry != nil && wasm != nil && game != nil
        if webReady, web?.isSelfContained == true {
            return staticRoute(engine: .renpy, entry: entry!, routeID: "static.renpy-web",
                notes: ["The imported Ren'Py Web build is served unchanged; saves remain engine-internal."],
                evidence: [entry!, wasm!, game!])
        }
        let script = index.files.first {
            $0.path.value.lowercased().hasPrefix("game/")
                && ($0.path.value.lowercased().hasSuffix(".rpy") || $0.path.value.lowercased().hasSuffix(".rpyc"))
        }?.path
        let marker: GameRelativePath?
        if let script {
            marker = script
        } else {
            let reader = try GameProjectReader(rootURL: index.rootURL, maximumFileBytes: 40)
            marker = try GameRenPyArchive.first(in: reader, paths: index.paths)
        }
        guard let marker else {
            return unavailable(engine: .renpy, routeID: "portable.renpy-web",
                detail: "Provide a Ren'Py Web export or a game folder with scripts or a standard RPA archive.")
        }
        var prerequisites: [GameRunPrerequisite] = []
        if !availability.renpySDK {
            prerequisites.append(.externalTool(id: "renpy-8.5.3-web",
                detail: "The pinned Ren'Py 8.5.3 Web SDK path is required for the official web_build command."))
        }
        if !availability.portableBuildPort {
            prerequisites.append(.hostBuildProvider(id: "portable-build",
                detail: "The host's existing Ren'Py/job build provider is required to run the pinned SDK."))
        }
        return .init(plan: .init(engine: .renpy, action: .portableAssembly,
                                 routeID: "portable.renpy-web", entry: path("index.html"),
                                 prerequisites: prerequisites,
                                 notes: ["The official Ren'Py 8.5.3 SDK builds a Web export from a separate copy of the game tree, including compiled scripts and archives. Desktop games must be compatible with this SDK and Web runtime."]),
                     evidence: [.init(path: marker, kind: .projectMarker)])
    }

    private static func tyranoScript(index: GameRunSourceIndex,
                                     web: GameRunWebEntry?) -> GameRunRouteEvaluation {
        let route = "static.tyranoscript"
        guard let web, web.isSelfContained,
              let engine = first(index, "tyrano/tyrano.js"),
              web.references.contains(engine.value),
              let kag = first(index, "tyrano/plugins/kag/kag.js"),
              web.references.contains(kag.value),
              let scenario = index.files.first(where: {
                  $0.path.value.hasPrefix("data/scenario/") && $0.path.value.hasSuffix(".ks")
              }) else {
            return unavailable(engine: .tyranoScript, routeID: route,
                detail: "Import the complete TyranoScript browser export, including index.html, tyrano/ and data/.")
        }
        return staticRoute(engine: .tyranoScript, entry: web.entry, routeID: route,
            notes: ["Plays the imported browser export with its own runtime and per-project browser saves."],
            evidence: [web.entry, engine, kag, scenario.path])
    }

    // MARK: - Narrative and fantasy consoles

    private static func narrative(engine: GameEngineID, marker: String,
                                  index: GameRunSourceIndex,
                                  availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        guard let path = first(index, marker) else {
            return unavailable(engine: engine, routeID: "narrative.\(engine.rawValue)",
                detail: "No \(marker) source was found in this root.")
        }
        return try narrative(engine: engine, index: index, hasMarker: true,
                         availability: availability, evidencePath: path)
    }

    private static func narrative(engine: GameEngineID, index: GameRunSourceIndex,
                                  hasMarker: Bool, availability: GameRunAvailability,
                                  evidencePath: GameRelativePath? = nil) throws -> GameRunRouteEvaluation {
        guard hasMarker else {
            return unavailable(engine: engine, routeID: "narrative.\(engine.rawValue)",
                detail: "No \(engine.rawValue) source was found in this root.")
        }
        var prerequisites: [GameRunPrerequisite] = []
        if !availability.narrativeResources {
            prerequisites.append(.preparedResourcePack(id: "narrative-runtime-resources",
                detail: "The prepared narrative runtime resources (inkjs, SugarCube, TIC-80, WASM-4 and microStudio) are required to build this artifact."))
        }
        let markerPath = evidencePath ?? index.files.first?.path
        let evidence: [GameEngineEvidence]
        if let markerPath {
            evidence = [GameEngineEvidence(path: markerPath, kind: .projectMarker)]
        } else {
            evidence = []
        }
        return .init(plan: .init(engine: engine, action: .narrativeAssembly,
                                 routeID: "narrative.\(engine.rawValue)", entry: path("index.html"),
                                 prerequisites: prerequisites,
                                 notes: ["The adapter builds a self-contained offline Web artifact; original source and unknown files stay in the project."]),
                     evidence: evidence)
    }

    // MARK: - GDevelop

    private static func gdevelop(index: GameRunSourceIndex, entry: GameRelativePath?,
                                 web: GameRunWebEntry?,
                                 availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        let data = first(index, "data.js")
        let gd = first(index, "gd.js")
        let license = first(index, "LICENSE.GDevelop.txt")
        let code = index.files.first {
            $0.path.value.lowercased().hasPrefix("code") && $0.path.value.lowercased().hasSuffix(".js")
        }?.path
        let exportReady = entry != nil && data != nil && gd != nil && license != nil && code != nil
        if exportReady, web?.isSelfContained == true {
            return staticRoute(engine: .gdevelop, entry: entry!, routeID: "static.gdevelop-web",
                notes: ["A real official GDJS export is verified; the private run copy receives the reviewed dormant Floe bridge and is then sealed. Imported source bytes and third-party notices are retained."],
                evidence: [entry!, data!, gd!, code!])
        }
        let project = try gdevelopProjectJSON(index: index)
        guard let project else {
            return unavailable(engine: .gdevelop, routeID: "external.gdevelop-web",
                detail: "No standard GDevelop project (game.json with gdVersion/layouts) or complete GDJS Web export was found.")
        }
        var prerequisites: [GameRunPrerequisite] = [
            .externalTool(id: "gdevelop-5.6.287",
                detail: "The pinned official GDevelop 5.6.287 SDK and reviewed export script are required to produce the Web export.")
        ]
        if !availability.externalBuildProvider {
            prerequisites.append(.hostBuildProvider(id: "external-build",
                detail: "The host's existing jobs/CI build provider is required to run the GDevelop export."))
        }
        return .init(plan: .init(engine: .gdevelop, action: .externalBuild,
                                 routeID: "external.gdevelop-web", entry: path("index.html"),
                                 prerequisites: prerequisites,
                                 notes: ["The project is exported by the official SDK in the host build service; the source is preserved."]),
                     evidence: [.init(path: project, kind: .projectMarker)])
    }

    private static func gdevelopProjectJSON(index: GameRunSourceIndex) throws -> GameRelativePath? {
        // Standard GDevelop projects use game.json. Boundedly probe other JSON
        // candidates too so an imported project with a custom file name still
        // gets an explicit external-export route; the host still verifies the
        // real GDJS export through the artifact verifier.
        let standard = first(index, "game.json")
        let candidates = ([standard].compactMap { $0 }
            + index.files.map(\.path).filter { $0.value.lowercased().hasSuffix(".json") })
        var seen = Set<String>()
        var examined = 0
        for path in candidates {
            guard seen.insert(path.value).inserted else { continue }
            guard examined < 16 else { break }
            guard let file = index.byPath(path.value), file.bytes <= 262_144 else { continue }
            examined += 1
            let data = try GameRunFileIO.read(root: index.rootURL, path: path,
                                              maximumBytes: 262_144)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["gdVersion"] != nil, object["layouts"] != nil else { continue }
            return path
        }
        return nil
    }

    // MARK: - Godot / Unity / Cocos

    private static func godot(index: GameRunSourceIndex, entry: GameRelativePath?,
                              web: GameRunWebEntry?,
                              availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        let wasm = index.wasmFile()?.path
        let pck = index.files.first { $0.path.value.lowercased().hasSuffix(".pck") }?.path
        if entry != nil, wasm != nil, pck != nil, web?.isSelfContained == true {
            return staticRoute(engine: .godot, entry: entry!, routeID: "static.godot-web",
                notes: ["A real Godot Web export is served unchanged; WASM and PCK stay in the artifact."],
                evidence: [entry!, wasm!, pck!])
        }
        guard let marker = first(index, "project.godot") else {
            return unavailable(engine: .godot, routeID: "external.godot-web",
                detail: "No project.godot source or Godot Web export was found in this root.")
        }
        return externalRoute(engine: .godot, kind: .godotWeb, routeID: "external.godot-web",
            entry: path("index.html"), availability: availability,
            requirement: .externalTool(id: "godot-4.7.2-web-export",
                detail: "The pinned Godot 4.7.2 Web export toolchain is required; no local Godot source path is proven on this host."),
            evidence: [.init(path: marker, kind: .projectMarker)],
            notes: ["Raw Godot source is never treated as a Web export. The host Linux/CI service builds it."])
    }

    private static func unity(index: GameRunSourceIndex, entry: GameRelativePath?,
                              web: GameRunWebEntry?,
                              availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        let wasm = index.wasmFile()?.path
        let payload = index.files.first {
            let lower = $0.path.value.lowercased()
            return lower.hasSuffix(".data") || lower.hasSuffix(".data.br")
                || lower.hasSuffix(".data.gz") || lower.hasSuffix(".data.unityweb")
                || lower.hasSuffix(".loader.js") || lower.hasSuffix(".framework.js")
        }?.path
        if entry != nil, wasm != nil, payload != nil, web?.isSelfContained == true {
            return staticRoute(engine: .unity, entry: entry!, routeID: "static.unity-webgl",
                notes: ["A real Unity WebGL export is served unchanged; the WASM/payload files stay in the artifact."],
                evidence: [entry!, wasm!, payload!])
        }
        guard let version = first(index, "ProjectSettings/ProjectVersion.txt"),
              index.hasPrefix("Assets/") else {
            return unavailable(engine: .unity, routeID: "external.unity-webgl",
                detail: "No Unity project or complete WebGL export was found in this root.")
        }
        return externalRoute(engine: .unity, kind: .unityWebGL, routeID: "external.unity-webgl",
            entry: path("index.html"), availability: availability,
            requirement: .externalTool(id: "unity-webgl-export",
                detail: "A Unity Editor/CI WebGL export is required; no local Unity source build is proven."),
            evidence: [.init(path: version, kind: .projectMarker)],
            notes: ["The source project is preserved. Unity-as-a-library is not selected for this route."])
    }

    private static func cocos(index: GameRunSourceIndex, entry: GameRelativePath?,
                              web: GameRunWebEntry?,
                              availability: GameRunAvailability) throws -> GameRunRouteEvaluation {
        let application = first(index, "application.js")
        let settings = first(index, "src/settings.json")
        let exportReady = entry != nil && (application != nil || settings != nil || index.anyFile(prefix: "cocos-js/"))
        if exportReady, web?.isSelfContained == true {
            return staticRoute(engine: .cocosCreator, entry: entry!, routeID: "static.cocos-web",
                notes: ["A real Cocos Creator Web build is served unchanged."],
                evidence: [entry!] + [application, settings].compactMap { $0 })
        }
        let marker = first(index, "project.json")
            ?? first(index, "settings/v2/packages/project.json")
            ?? first(index, "package.json")
        guard index.hasPrefix("assets/"), marker != nil else {
            return unavailable(engine: .cocosCreator, routeID: "external.cocos-web",
                detail: "No Cocos Creator project or Web build was found in this root.")
        }
        return externalRoute(engine: .cocosCreator, kind: .cocosWeb, routeID: "external.cocos-web",
            entry: path("index.html"), availability: availability,
            requirement: .externalTool(id: "cocos-creator-web-export",
                detail: "A Cocos Creator Web export is required; no local Cocos source build is proven."),
            evidence: [.init(path: marker!, kind: .projectMarker)],
            notes: ["The source project is preserved; the host CI/editor path owns the export."])
    }

    // MARK: - Shared route constructors

    private static func staticRoute(engine: GameEngineID, entry: GameRelativePath,
                                    routeID: String, notes: [String],
                                    evidence: [GameRelativePath]) -> GameRunRouteEvaluation {
        .init(plan: .init(engine: engine, action: .staticWeb, routeID: routeID,
                          entry: entry, prerequisites: [], notes: notes),
              evidence: evidence.map { GameEngineEvidence(path: $0, kind: .projectMarker) })
    }

    private static func externalRoute(engine: GameEngineID, kind: GameRunExternalBuildKind,
                                      routeID: String, entry: GameRelativePath,
                                      availability: GameRunAvailability,
                                      requirement: GameRunPrerequisite,
                                      evidence: [GameEngineEvidence],
                                      notes: [String]) -> GameRunRouteEvaluation {
        var prerequisites = [requirement]
        if !availability.externalBuildProvider {
            prerequisites.append(.hostBuildProvider(id: "external-build",
                detail: "The host's existing jobs/CI build provider is required for this route."))
        }
        return .init(plan: .init(engine: engine, action: .externalBuild, routeID: routeID,
                                 entry: entry, prerequisites: prerequisites, notes: notes),
                     evidence: evidence)
    }

    private static func unavailable(engine: GameEngineID, routeID: String,
                                    detail: String) -> GameRunRouteEvaluation {
        .init(plan: .init(engine: engine, action: .unavailable, routeID: routeID,
                          entry: nil,
                          prerequisites: [.unsupportedRoute(id: routeID, detail: detail)],
                          notes: [detail]),
              evidence: [])
    }

    // MARK: - File helpers

    static func defaultEntry(_ index: GameRunSourceIndex) -> GameRelativePath? {
        first(index, "index.html") ?? first(index, "index.htm")
    }

    static func first(_ index: GameRunSourceIndex, _ path: String) -> GameRelativePath? {
        index.files.first { $0.path.value.caseInsensitiveCompare(path) == .orderedSame }?.path
    }
}
