// SPDX-License-Identifier: MPL-2.0
// The newly authored embedded starter source is additionally MIT-licensed.
import Foundation
import FloeGameCore

/// Real microStudio authoring + runtime adapter.
///
/// Projects keep original microScript 2.0 source files under `src/` (imported
/// byte-exact) plus `project.json`. The Web artifact mirrors the official
/// microStudio HTML5 exporter: the pinned upstream language scripts
/// (compiler/parser/processor/...), the `microengine.js` bundle assembled in the
/// exact order of upstream `server/concatenator.js` (canvas2d player), the
/// upstream `Player` boot sequence and a `#code` element with the concatenated
/// sources. The typed bridge drives `Player.call()`/`Player.exec()`.
public enum GameMicroStudioAdapter {
    public static let version = "1.0.0"
    public static let commit = "80594cff51312b32db874a33d928876b23ab7718"
    public static let playerSHA256 = "e99d44eb73d63c99a6c441e5d065f87ef9d45e5fd6a0825682d08dbfb892120b"

    public static let profile = NarrativeEngineProfile(
        engine: .microStudio,
        runtimeVersion: version,
        upstream: "https://github.com/pmgl/microstudio/tree/\(commit)",
        license: "MIT",
        licenseBundle: nil,
        licenseBundleRequired: false,
        licenseURL: "https://github.com/pmgl/microstudio",
        entry: "index.html",
        supportsInput: true,
        supportsChoose: false,
        supportsPointer: true,
        supportsState: true,
        stateContract: "snapshot() = {values: <array returned by the game's floe_snapshot() microScript function>}; restore(state) invokes the game's floe_restore(...) with those values. Both calls go through the upstream Player.call() interpreter entry; games without these functions report state:false at readiness.",
        requiredCSPAdditions: [],
        requiredMIMETypes: [:]
    )

    // MARK: - Authoring

    public static func createProject(at target: URL, title: String) throws {
        guard target.isFileURL, NarrativeValidation.validIdentifier(title),
              !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".ms-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let files: [String: Data] = [
            "src/main.ms": Data(starterSource.utf8),
            "project.json": try projectJSON(title: title, starter: true),
            NarrativeInputs.fileName: try NarrativeInputs.encodedDefault(for: .microStudio),
            "licenses/LICENSE.microstudio.txt": Data(microStudioLicense.utf8),
            "licenses/FLOE-STARTER-MIT.txt": Data(NarrativeLicenses.starterMIT.utf8)
        ]
        for (path, data) in files {
            let output = stage.appendingPathComponent(path)
            try NarrativeWriter.directory(output.deletingLastPathComponent())
            try NarrativeWriter.atomicWrite(data, to: output)
        }
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    /// Full import of a microStudio project folder: every `.ms` source and every
    /// other file is preserved byte-exact; `project.json` is added when absent.
    public static func importProject(from source: URL, to target: URL, title: String) throws {
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let tree = try NarrativeProjectTree(root: source)
        let entries = try tree.walk()
        guard entries.contains(where: { !$0.directory && $0.path.hasSuffix(".ms") }) else {
            throw NarrativeAdapterError.invalidProject("no .ms microscript source")
        }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".ms-import-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        for entry in entries {
            // Imported trees often already have a src/ folder; flatten only when absent.
            let relative = entry.path
            let output = stage.appendingPathComponent(relative)
            if entry.directory {
                try NarrativeWriter.directory(output)
            } else {
                try NarrativeWriter.directory(output.deletingLastPathComponent())
                try NarrativeWriter.atomicWrite(try tree.read(relative), to: output)
            }
        }
        if !entries.contains(where: { $0.path == "project.json" }) {
            try NarrativeWriter.atomicWrite(try projectJSON(title: title, starter: false),
                                            to: stage.appendingPathComponent("project.json"))
        }
        if !entries.contains(where: { $0.path == NarrativeInputs.fileName }) {
            try NarrativeWriter.atomicWrite(try NarrativeInputs.encodedDefault(for: .microStudio),
                                            to: stage.appendingPathComponent(NarrativeInputs.fileName))
        }
        // Import adds only metadata/input declarations. The imported project's
        // own license/NOTICE/COPYING files are copied byte-exact above and are
        // never relabelled as Floe starter content or an engine license.
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    // MARK: - Artifact

    /// Builds the official canvas2d HTML5 export shape: pinned upstream
    /// `microengine`, microScript 2.0 language scripts, the concatenated source
    /// in upstream order (file-local function wrappers for multi-file projects),
    /// and `resources` metadata plus files for imported sprites/maps/sounds/
    /// music/assets. Unknown files stay in the project and are never executed.
    public static func buildArtifact(projectAt project: URL, to target: URL, resources: URL) throws {
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let engine = resources.appendingPathComponent("microstudio/microengine.js")
        let license = resources.appendingPathComponent("microstudio/LICENSE.microstudio.txt")
        guard FileManager.default.fileExists(atPath: engine.path), FileManager.default.fileExists(atPath: license.path) else {
            throw NarrativeAdapterError.missingResource("microstudio resource pack")
        }
        let engineBytes = try Data(contentsOf: engine)
        let licenseBytes = try Data(contentsOf: license)
        for rel in ["microstudio/play/player.js", "microstudio/runtime/screen.js", "microstudio/runtime/keyboard.js",
                    "microstudio/languages/microscript/v2/compiler.js"] {
            let url = resources.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { throw NarrativeAdapterError.missingResource(rel) }
        }
        guard GameDigest.sha256(try Data(contentsOf: resources.appendingPathComponent("microstudio/play/player.js"))) == playerSHA256 else {
            throw NarrativeAdapterError.resourceChanged("microstudio/play/player.js")
        }
        // The engine bundle is a deterministic concatenation of the pinned files;
        // verify it by rebuilding from the pack order and comparing bytes.
        let rebuilt = try rebuildEngineBundle(resources: resources)
        guard rebuilt == engineBytes else { throw NarrativeAdapterError.resourceChanged("microstudio/microengine.js") }

        let plan = try MicroStudioProjectPlan.prepare(projectAt: project)
        let sourceDocument = try sourceDocumentJSON(plan)
        let runtimeDocument = try runtimeDocumentJSON(plan)
        let languageBytes = try languageBundle(resources: resources)

        let stage = target.deletingLastPathComponent().appendingPathComponent(".ms-artifact-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }

        var artifact = NarrativeArtifactBuilder(engine: .microStudio)
        let shell = try NarrativeSupportAssets.shell("microstudio.html")
            .replacingOccurrences(of: "{{TITLE}}", with: htmlText(plan.title))
        try artifact.add(path: "index.html", data: Data(shell.utf8), role: .htmlShell, license: "MPL-2.0")
        for file in ["floe-host.js", "microstudio-bridge.js"] {
            try artifact.add(path: "support/" + file,
                             data: try NarrativeSupportAssets.support(file),
                             role: .floeSupport, license: "MPL-2.0")
        }
        try artifact.add(path: "support/microstudio.css",
                         data: try NarrativeSupportAssets.support("microstudio.css"),
                         role: .floeStyle, license: "MPL-2.0")
        try artifact.add(path: "language.js", data: languageBytes, role: .thirdPartyRuntime,
                         license: "MIT", upstream: profile.upstream)
        try artifact.add(path: "microengine.js", data: engineBytes, role: .thirdPartyRuntime,
                         license: "MIT", upstream: profile.upstream)
        try artifact.add(path: "licenses/LICENSE.microstudio.txt", data: licenseBytes,
                         role: .thirdPartyLicense, license: "MIT", upstream: profile.upstream)
        try artifact.add(path: "game/microstudio-sources.json", data: sourceDocument,
                         role: .gameSource, license: "original project content (not relicensed)")
        try artifact.add(path: "game/resources.json", data: runtimeDocument,
                         role: .gameData, license: "original project content (not relicensed)")
        // Preserve every compiled source path byte-exact in its own file.
        let tree = try NarrativeBuildTree(root: project)
        for source in plan.sources {
            let bytes: Data
            do { bytes = try tree.read(source.path, maximum: MicroStudioProjectPlan.maximumSourceBytes) }
            catch { throw MicroStudioArtifactError.unreadable(source.path) }
            try artifact.add(path: "game/source/" + source.path, data: bytes, role: .gameSource,
                             license: "original project content (not relicensed)")
        }
        // Copy exactly the referenced resources with their official flat runtime
        // names; maps are additionally embedded as JSON in `resources.maps`.
        for resource in plan.resources {
            let maximum = resource.kind == .map
                ? MicroStudioProjectPlan.maximumMapBytes
                : MicroStudioProjectPlan.maximumResourceBytes
            let bytes: Data
            do { bytes = try tree.read(resource.sourcePath, maximum: maximum) }
            catch let error as NarrativeAdapterError {
                if case .invalidProject(let reason) = error, reason.hasPrefix("symbolic link:") {
                    throw MicroStudioArtifactError.symbolicLink(resource.sourcePath)
                }
                throw MicroStudioArtifactError.unreadable(resource.sourcePath)
            }
            try artifact.add(path: resource.artifactPath, data: bytes, role: .gameAsset,
                             license: "original project content (not relicensed)")
        }
        try artifact.add(path: NarrativeInputs.fileName,
                         data: try NarrativeInputs.artifactFile(project: project, engine: .microStudio),
                         role: .inputDeclaration, license: "project input declaration (not relicensed)")
        let originalNotices = try NarrativeOriginalNotices.discover(projectAt: project)
        try NarrativeLicenses.addArtifactNotices(to: &artifact, engine: .microStudio, originals: originalNotices)
        try artifact.write(to: stage)
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    /// Upstream `server/app/exportfeatures` wraps every microscript_v2 source in
    /// `function() ... end()` to isolate locals between files; `// javascript`
    /// blocks become `system.javascript("""...""")`. A single ordinary file keeps
    /// its historical unwrapped form (identical behaviour). The exact source is
    /// stored in game/microstudio-sources.json, never in an MPL support file.
    static func sourceCode(for plan: MicroStudioBuildPlan) throws -> String {
        if plan.sources.count == 1, !isJavaScriptBlock(plan.sources[0].text) {
            return plan.sources[0].text
        }
        var code = ""
        for source in plan.sources {
            if isJavaScriptBlock(source.text) {
                code += "\nsystem.javascript(\"\"\"\n\n"
                    + source.text.replacingOccurrences(of: "\\", with: "\\\\")
                    + "\n\n\"\"\")\n"
            } else {
                code += "\n// file: \(source.path)\nfunction()\n\(source.text)\nend()\n"
            }
            code += "\n\n"
        }
        guard code.utf8.count <= MicroStudioProjectPlan.maximumTotalSourceBytes + 128 * 1_024 else {
            throw MicroStudioArtifactError.sourcesTooLarge(MicroStudioProjectPlan.maximumTotalSourceBytes)
        }
        return code
    }

    static func sourceDocumentJSON(_ plan: MicroStudioBuildPlan) throws -> Data {
        let document: [String: Any] = [
            "format": "floe-microstudio-sources",
            "version": 1,
            "files": plan.sources.map { ["file": $0.runtimeName, "path": $0.path] },
            "code": try sourceCode(for: plan)
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    static func isJavaScriptBlock(_ text: String) -> Bool {
        text.range(of: "^\\s*//\\s*javascript\\s*\\n", options: .regularExpression) != nil
    }

    static func runtimeDocumentJSON(_ plan: MicroStudioBuildPlan) throws -> Data {
        var images: [[String: Any]] = []
        var assets: [[String: Any]] = []
        var sounds: [[String: Any]] = []
        var music: [[String: Any]] = []
        for resource in plan.resources {
            var object: [String: Any] = ["file": resource.runtimeFile, "version": resource.version]
            switch resource.kind {
            case .sprite:
                if let properties = resource.imageProperties, !properties.isEmpty {
                    object["properties"] = properties
                }
                images.append(object)
            case .asset:
                assets.append(object)
            case .sound:
                sounds.append(object)
            case .music:
                music.append(object)
            case .map:
                continue
            }
        }
        var maps: [String: String] = [:]
        for map in plan.maps { maps[map.name] = map.text }
        let document: [String: Any] = [
            "resources": [
                "images": images,
                "assets": assets,
                "maps": maps,
                "sounds": sounds,
                "music": music
            ],
            "graphics": plan.graphics,
            "orientation": plan.orientation,
            "aspect": plan.aspect
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    static func rebuildEngineBundle(resources: URL) throws -> Data {
        var output = Data()
        for rel in engineOrder {
            let bytes = try Data(contentsOf: resources.appendingPathComponent(rel))
            output.append(bytes); output.append(Data("\n".utf8))
        }
        return output
    }

    static func languageBundle(resources: URL) throws -> Data {
        var output = Data()
        for rel in languageOrder {
            let bytes = try Data(contentsOf: resources.appendingPathComponent(rel))
            output.append(bytes); output.append(Data("\n".utf8))
        }
        return output
    }

    /// Upstream `server/concatenator.js` `player_js` order (canvas2d player).
    static let engineOrder = [
        "microstudio/util/canvas2d.js",
        "microstudio/languages/microscript/random.js",
        "microstudio/runtime/mpserverconnection.js",
        "microstudio/runtime/microvm.js",
        "microstudio/runtime/runtime.js",
        "microstudio/runtime/watcher.js",
        "microstudio/runtime/projectinterface.js",
        "microstudio/runtime/timemachine.js",
        "microstudio/runtime/screen.js",
        "microstudio/runtime/assetmanager.js",
        "microstudio/runtime/keyboard.js",
        "microstudio/runtime/gamepad.js",
        "microstudio/runtime/sprite.js",
        "microstudio/runtime/msimage.js",
        "microstudio/runtime/map.js",
        "microstudio/runtime/audio/audio.js",
        "microstudio/runtime/audio/beeper.js",
        "microstudio/runtime/audio/sound.js",
        "microstudio/runtime/audio/music.js",
        "microstudio/play/player.js",
        "microstudio/play/playerclient.js"
    ]

    /// microScript 2.0 language scripts (upstream `language_engines.microscript_v2`).
    static let languageOrder = [
        "microstudio/languages/microscript/v2/token.js",
        "microstudio/languages/microscript/v2/tokenizer.js",
        "microstudio/languages/microscript/v2/parser.js",
        "microstudio/languages/microscript/v2/program.js",
        "microstudio/languages/microscript/v2/routine.js",
        "microstudio/languages/microscript/v2/processor.js",
        "microstudio/languages/microscript/v2/transpiler.js",
        "microstudio/languages/microscript/v2/runner.js",
        "microstudio/languages/microscript/v2/compiler.js"
    ]

    struct Source: Sendable { let name: String; let text: String }

    static func collectSources(project: URL) throws -> [Source] {
        let manager = FileManager.default
        var roots: [URL] = []
        let src = project.appendingPathComponent("src")
        if manager.fileExists(atPath: src.path) { roots.append(src) }
        if roots.isEmpty { roots.append(project) }
        var sources: [Source] = []
        for root in roots {
            let tree = try NarrativeProjectTree(root: root)
            for entry in try tree.walk() where !entry.directory && entry.path.hasSuffix(".ms") {
                let text = String(decoding: try tree.read(entry.path), as: UTF8.self)
                sources.append(Source(name: entry.path, text: text))
            }
        }
        // Deterministic order matching upstream's source list.
        return sources.sorted { $0.name < $1.name }
    }

    private static func projectJSON(title: String, starter: Bool) throws -> Data {
        var object: [String: Any] = ["engine": "microStudio", "language": "microscript_v2",
                                     "graphics": "canvas2d", "runtime": "microstudio \(version) @ \(String(commit.prefix(12)))",
                                     "engineLicense": "MIT", "title": title,
                                     "unknownFieldsExample": ["preserved": true]]
        // Engine metadata only. Imported user sources/assets are never stamped
        // with a blanket license; `template` marks only Floe-generated starters.
        if starter {
            object["template"] = NarrativeStarter.templateMarker
            object["starterLicense"] = "MIT"
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static let microStudioLicense = """
    microStudio — MIT License

    Copyright (c) 2021 Gilles Pommereuil

    The full upstream license text is distributed with the prepared resource
    pack as microstudio/LICENSE.microstudio.txt. Source:
    https://github.com/pmgl/microstudio (commit \(commit)).
    Floe-generated starter projects additionally carry
    licenses/FLOE-STARTER-MIT.txt for the original starter source.
    """

    static let starterSource = """
    // FLOE microStudio starter (MIT) — dpad moves the marker.
    init = function()
      x = 74
      y = 60
      score = 0
      screen.clear()
    end

    update = function()
      if keyboard.LEFT then x = x - 2 end
      if keyboard.RIGHT then x = x + 2 end
      if keyboard.UP then y = y - 2 end
      if keyboard.DOWN then y = y + 2 end
      if x < 4 then x = 4 end
      if x > 144 then x = 144 end
      if y < 20 then y = 20 end
      if y > 144 then y = 144 end
      screen.clear()
      screen.drawRect(0, 0, 160, 160, "rgb(26,43,34)")
      screen.drawRect(x, y, 12, 12, "rgb(246,231,176)")
      screen.drawText("FLOE microStudio", 8, 8, 18, "rgb(255,255,255)")
    end

    floe_snapshot = function(seed)
      return [x, y, score]
    end

    floe_restore = function(sx, sy, sscore)
      x = sx
      y = sy
      score = sscore
      return 1
    end
    """

    static func htmlText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
