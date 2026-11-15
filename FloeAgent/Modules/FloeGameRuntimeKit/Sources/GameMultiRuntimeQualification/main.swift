// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameRuntime
import FloeGameWebKit
#if os(macOS)
import AppKit

@MainActor final class Qualification: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var player: GameWebPlayer?
    var results: [[String: Any]] = []
    var output: URL!
    private var previousApplication: NSRunningApplication?
    func applicationDidFinishLaunching(_ notification: Notification) {
        previousApplication = NSWorkspace.shared.frontmostApplication
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Floe game component qualification"; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do { try await run(); finish(code: 0) }
            catch {
                var failure: [String: Any] = ["result": "failed", "error": String(describing: error), "logs": player?.logs ?? []]
                let args = CommandLine.arguments
                if (5...6).contains(args.count), args[1] == "--portable-runtime", let engine = GameEngineID(rawValue: args[2]),
                   let observation = try? await portableObservation(engine) { failure["observation"] = observation }
                if let player, let output, let png = try? await player.capturePNG() {
                    try? png.write(to: output.appendingPathComponent("failure-webkit.png"))
                }
                results.append(failure)
                if let player { _ = await player.stop() }
                finish(code: 1)
            }
        }
    }
    func finish(code: Int32) {
        if let output { try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("runtime-results.json")) }
        let ownsFocus = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        window?.orderOut(nil)
        if ownsFocus { previousApplication?.activate(options: []) }
        exit(code)
    }
    func require(_ condition: Bool, _ label: String) throws { if !condition { throw NSError(domain: "Qualification", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) } }
    func state() async throws -> [String: Any] {
        guard let player, let object = try JSONSerialization.jsonObject(with: await player.snapshotState()) as? [String: Any] else { throw GameWebPlayerError.invalidState }
        return object
    }
    func waitReady() async throws {
        for _ in 0..<200 {
            if player?.gameReady == true { return }
            if let failure = player?.failure { throw NSError(domain: "WebKit", code: 2, userInfo: [NSLocalizedDescriptionKey: failure]) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "WebKit", code: 3, userInfo: [NSLocalizedDescriptionKey: "Game not ready: \(player?.logs ?? [])"])
    }
    func run() async throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--save-flush" {
            try await runSaveFlush(evidence: URL(fileURLWithPath: args[2])); return
        }
        if args.count == 6, args[1] == "--narrative-import", let engine = GameEngineID(rawValue: args[2]),
           [.ink, .microStudio].contains(engine) {
            try await runImportedNarrative(engine: engine, resources: URL(fileURLWithPath: args[3]),
                                          source: URL(fileURLWithPath: args[4]), evidence: URL(fileURLWithPath: args[5])); return
        }
        if (4...5).contains(args.count), args[1] == "--narrative-runtime" {
            try await runNarrative(resources: URL(fileURLWithPath: args[2]), evidence: URL(fileURLWithPath: args[3]), filter: args.count == 5 ? args[4] : nil); return
        }
        if args.count == 5, args[1] == "--godot-runtime" {
            try await runGodot(source: URL(fileURLWithPath: args[2]), web: URL(fileURLWithPath: args[3]), evidence: URL(fileURLWithPath: args[4])); return
        }
        if args.count == 5, args[1] == "--gdevelop-runtime" {
            try await runGDevelop(source: URL(fileURLWithPath: args[2]), web: URL(fileURLWithPath: args[3]), evidence: URL(fileURLWithPath: args[4])); return
        }
        if (5...6).contains(args.count), args[1] == "--portable-runtime", let engine = GameEngineID(rawValue: args[2]), [.rpgMakerMV, .love, .renpy].contains(engine) {
            guard args.count == 5 || args[5] == "--persistent-saves" else { throw GameProjectError.invalidContext }
            try await runPortable(engine: engine, web: URL(fileURLWithPath: args[3]), evidence: URL(fileURLWithPath: args[4]),
                                  verifyBuiltInSaves: args.count == 6); return
        }
        guard (3...4).contains(args.count) else { throw GameProjectError.invalidContext }
        let resources = URL(fileURLWithPath: args[1]); output = URL(fileURLWithPath: args[2])
        try require(!FileManager.default.fileExists(atPath: output.path), "Use a fresh evidence directory")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for engine in [GameEngineID.kaplay, .babylon, .playcanvas] where args.count == 3 || args[3] == engine.rawValue {
            let spec = try GameEngineResourceCatalog.spec(engine)
            let pack = try GameEngineResourcePack(engine: engine, directory: resources.appendingPathComponent(engine.rawValue + "-" + spec.version))
            let root = output.appendingPathComponent(engine.rawValue)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let source = root.appendingPathComponent("source")
            try GameScriptTemplate.create(at: source, resources: pack, title: "Floe \(engine.rawValue)")
            let repository = try FileGameProjectRepository(directory: root.appendingPathComponent("repository")), id = UUID(), owner = GameProjectOwner.space(recordID: id)
            let empty = try await repository.createProject(projectID: id, owner: owner, title: "Game", engine: engine)
            let stored = try await repository.importContents(from: source, into: id, owner: owner, expectedRevision: empty.revision)
            let context = try await repository.export(id, owner: owner, expectedRevision: stored.revision, to: root.appendingPathComponent("play-source"))
            let artifact = try GameWebArtifactPackage.build(source: context, engine: engine, entry: GameRelativePath("index.html"), to: root.appendingPathComponent("artifact"))
            var registry = GameAdapterRegistry(); try registry.register(GameAdapterRegistration(engine: engine, route: .webKit, runtimeReady: true))
            let inspection = try GameProjectInspector().inspect(context: context)
            guard case .launch(let plan) = try GameLaunchPlanner.plan(inspection: inspection, context: context, registry: registry, artifact: artifact.prepared) else { throw GameProjectError.invalidArtifact }
            let player = try GameWebPlayer(package: artifact, plan: plan, current: context); self.player = player
            window.contentView = player.webView; player.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            try await player.start(current: context); try await waitReady()
            try await Task.sleep(for: .milliseconds(200))
            let initial = try await state()
            try require((initial["score"] as? Int) == 0, "Fresh game score")
            try await player.key(.right, pressed: true)
            try await Task.sleep(for: .milliseconds(500))
            try await player.key(.right, pressed: false)
            let moved = try await state(), checkpoint = try await player.snapshotState()
            try require((moved["frames"] as? Int ?? 0) > 0, "Actual engine frames")
            try require((moved["x"] as? Double ?? 0) > 130, "Actual engine movement")
            try require((moved["score"] as? Int ?? 0) == 1, "Actual collection")
            try await Task.sleep(for: .milliseconds(250))
            let released = try await state()
            try require(abs((released["x"] as? Double ?? 0) - (moved["x"] as? Double ?? 0)) < 2,
                        "Physical key up stops movement")
            try await player.capturePNG().write(to: root.appendingPathComponent("actual-webkit.png"))
            let saves = try FileGameSaveRepository(directory: root.appendingPathComponent("saves"), projectID: id, owner: owner, maximumStateBytes: GameWebRuntimePolicy(engine: engine).maximumStateBytes)
            _ = try await saves.save(checkpoint, expectedRevision: 0)
            try require(await player.stop(), "Confirm stop")
            try await player.start(current: context); try await waitReady()
            let restarted = try await state(); try require((restarted["score"] as? Int) == 0, "Restart creates fresh state")
            let saved = try await saves.load(); guard let saved else { throw GameWebPlayerError.invalidState }
            try await player.restoreState(saved.state)
            let restored = try await state(); try require((restored["score"] as? Int) == 1, "Restore actual state")
            try require(await player.stop(), "Confirm final stop")
            let result: [String: Any] = ["engine": engine.rawValue, "version": spec.version, "license": spec.license, "result": "passed", "nativeHost": true, "platform": "macOS AppKit WebKit", "input": "physical keyboard descriptors", "flow": "create before import", "initial": initial, "moved": moved, "released": released, "restarted": restarted, "restored": restored, "artifactSHA256": artifact.prepared.sha256, "logs": player.logs]
            results.append(result); print("Verified \(engine.rawValue): frames, input, screenshot, stop/restart/save/restore")
        }
    }
    func runGodot(source: URL, web: URL, evidence: URL) async throws {
        output = evidence
        try require(!FileManager.default.fileExists(atPath: evidence.path), "Use fresh evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let repo = try FileGameProjectRepository(directory: evidence.appendingPathComponent("repository"))
        let empty = try await repo.createProject(projectID: id, owner: owner, title: "Godot", engine: .godot)
        let project = try await repo.importContents(from: source, into: id, owner: owner, expectedRevision: empty.revision)
        let context = try await repo.export(id, owner: owner, expectedRevision: project.revision, to: evidence.appendingPathComponent("source-snapshot"))
        let artifact = try GameWebArtifactPackage.build(source: context, engine: .godot, entry: GameRelativePath("index.html"), to: evidence.appendingPathComponent("artifact"), contentRoot: web)
        var registry = GameAdapterRegistry(); try registry.register(GameAdapterRegistration(engine: .godot, route: .webKit, runtimeReady: true))
        guard case .launch(let plan) = try GameLaunchPlanner.plan(inspection: GameProjectInspector().inspect(context: context), context: context, registry: registry, artifact: artifact.prepared) else { throw GameProjectError.invalidArtifact }
        let player = try GameWebPlayer(package: artifact, plan: plan, current: context); self.player = player
        window.contentView = player.webView; player.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        try await player.start(current: context); try await waitReady()
        try await Task.sleep(for: .milliseconds(200))
        let initial = try await state(); try require((initial["score"] as? Int) == 0, "Fresh Godot game")
        try await player.key(.right, pressed: true); try await Task.sleep(for: .milliseconds(500)); try await player.key(.right, pressed: false)
        let moved = try await state(), checkpoint = try await player.snapshotState()
        try require((moved["frames"] as? Int ?? 0) > 0 && (moved["x"] as? Double ?? 0) > 130, "Godot GDScript frames and input")
        try require((moved["score"] as? Int) == 1, "Godot collection")
        try await Task.sleep(for: .milliseconds(250))
        let released = try await state()
        try require(abs((released["x"] as? Double ?? 0) - (moved["x"] as? Double ?? 0)) < 2,
                    "Godot physical key up stops movement")
        try await player.capturePNG().write(to: evidence.appendingPathComponent("actual-webkit.png"))
        let saves = try FileGameSaveRepository(directory: evidence.appendingPathComponent("saves"), projectID: id, owner: owner)
        _ = try await saves.save(checkpoint, expectedRevision: 0)
        try require(await player.stop(), "Godot stop")
        try await player.start(current: context); try await waitReady()
        let restarted = try await state(); try require((restarted["score"] as? Int) == 0, "Godot restart")
        let saved = try await saves.load(); guard let saved else { throw GameWebPlayerError.invalidState }
        try await player.restoreState(saved.state); try await Task.sleep(for: .milliseconds(100))
        let restored = try await state(); try require((restored["score"] as? Int) == 1, "Godot GDScript restore")
        try require(await player.stop(), "Godot final stop")
        results.append(["engine": "godot", "result": "passed", "nativeHost": true, "platform": "macOS AppKit WebKit", "input": "physical keyboard descriptors", "flow": "create before import", "initial": initial, "moved": moved, "released": released, "restarted": restarted, "restored": restored, "artifactSHA256": artifact.prepared.sha256, "logs": player.logs])
        print("Verified actual Godot export: frames, input, screenshot, stop/restart/save/restore")
    }
}

let app = NSApplication.shared
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--godot-template" {
    do { try GameGodotTemplate.create(at: URL(fileURLWithPath: CommandLine.arguments[2]), title: "Floe Godot"); exit(0) }
    catch { print(error); exit(1) }
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--finalize-godot" {
    do { try GameGodotTemplate.finalizeWebExport(sourceDirectory: URL(fileURLWithPath: CommandLine.arguments[2]), exportDirectory: URL(fileURLWithPath: CommandLine.arguments[3])); exit(0) }
    catch { print(error); exit(1) }
}
app.setActivationPolicy(.regular)
let delegate = Qualification(); app.delegate = delegate
app.run()
#else
print("Native runtime qualification is a macOS host, not an iOS executable")
#endif
