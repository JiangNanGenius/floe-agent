// SPDX-License-Identifier: MPL-2.0
// Real AppKit host; a command-line XCTest process does not run NSApp's event loop.
import Foundation
#if os(macOS)
import AppKit
import WebKit
import FloeGameCore
import FloeGameWebKit

enum QualificationFailure: Error { case assertion(String) }

@MainActor final class QualificationDelegate: NSObject, NSApplicationDelegate {
    var exitCode: Int32 = 1
    private var window: NSWindow?
    private var previousApplication: NSRunningApplication?
    private var player: GameWebPlayer?
    private var completed = false
    private var steps: [String] = []
    private var output: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        previousApplication = NSWorkspace.shared.frontmostApplication
        Task { await qualify() }
        Task {
            try? await Task.sleep(for: .seconds(60))
            if !completed { await finish(error: QualificationFailure.assertion("Qualification exceeded 60 seconds")) }
        }
    }
    private func require(_ value: Bool, _ message: String) throws {
        guard value else { throw QualificationFailure.assertion(message) }
    }
    private func step(_ message: String) { steps.append(message); print(message) }
    private func wait(_ stage: String, condition: @escaping @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        let state = try? await player?.snapshotState()
        throw QualificationFailure.assertion("Timeout \(stage), state=\(state.map { String(decoding: $0, as: UTF8.self) } ?? "none"), logs=\(player?.logs ?? [])")
    }
    private func raw(_ script: String) async throws -> Data {
        guard let player else { throw QualificationFailure.assertion("Missing player") }
        return try await withCheckedThrowingContinuation { continuation in
            player.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    do {
                        let mirror = Mirror(reflecting: value)
                        let object: Any = mirror.displayStyle == .optional ? (mirror.children.first?.value ?? NSNull()) : value
                        continuation.resume(returning: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]))
                    } catch { continuation.resume(throwing: error) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    private func state() async throws -> [String: Any] {
        guard let player, let value = try JSONSerialization.jsonObject(with: await player.snapshotState()) as? [String: Any] else {
            throw QualificationFailure.assertion("Invalid runtime state")
        }
        return value
    }

    private func qualify() async {
        do {
            let environment = ProcessInfo.processInfo.environment
            guard let resourcePath = environment["FLOE_GAME_TEST_RESOURCES"], let outputPath = environment["FLOE_GAME_TEST_EVIDENCE"] else {
                throw QualificationFailure.assertion("Explicit resource and evidence directories required")
            }
            let root = URL(fileURLWithPath: outputPath, isDirectory: true); output = root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("template-project")
            try GamePhaserTemplate.create(at: source, resources: URL(fileURLWithPath: resourcePath), title: "森林邮局")
            let repository = try FileGameProjectRepository(directory: root.appendingPathComponent("repository"))
            let id = UUID(), owner = GameProjectOwner.space(recordID: id)
            let initial = try await repository.importProject(from: source, projectID: id, owner: owner, title: "森林邮局", engine: .phaser)
            let config = try await repository.read(id, owner: owner, revision: initial.revision, path: GameRelativePath("game-config.json"))
            let edited = try GameJSONPatch.replacing(config, at: [.key("speed")], with: Data("240".utf8))
            let updated = try await repository.commit(id, owner: owner, expectedRevision: initial.revision,
                changes: [.write(GameRelativePath("game-config.json"), edited)])
            let reopened = try FileGameProjectRepository(directory: root.appendingPathComponent("repository"))
            let loaded = try await reopened.open(id, owner: owner)
            try require(loaded.revision == updated.revision, "Saved project did not reopen")
            step("created-imported-edited-saved-reopened")
            let context = try await reopened.export(id, owner: owner, expectedRevision: updated.revision, to: root.appendingPathComponent("playable-project"))
            let artifact = try GameWebArtifactPackage.build(source: context, engine: .phaser, entry: GameRelativePath("index.html"), to: root.appendingPathComponent("web-artifact"))
            var registry = GameAdapterRegistry()
            try registry.register(.init(engine: .phaser, route: .webKit, runtimeReady: true))
            let decision = try GameLaunchPlanner.plan(inspection: GameProjectInspector().inspect(context: context), context: context,
                registry: registry, artifact: artifact.prepared)
            guard case .launch(let plan) = decision else { throw QualificationFailure.assertion("Missing actual launch plan") }
            let player = try GameWebPlayer(package: artifact, plan: plan, current: context); self.player = player
            player.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 560)
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 560),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            self.window = window; window.isReleasedWhenClosed = false
            window.title = "Floe game component verification"
            window.contentView = player.webView; window.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
            try await player.start(current: context)
            try await wait("real engine readiness") { player.gameReady && player.loaded }
            try await wait("visible foreground document") {
                let bytes = try await self.raw("return document.visibilityState;")
                return (try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? String) == "visible"
            }
            let initialState = try await state()
            try require(initialState["engineVersion"] as? String == GamePhaserTemplate.version, "Real Phaser version did not match")
            step("phaser-3.90.0-visible-in-real-webkit")
            _ = try await raw("console.log('FLOE_CONSOLE_PROBE',42); console.warn('FLOE_BOUNDED_PROBE '+ 'x'.repeat(10000)); return true;")
            try await wait("bounded actual console delivery") {
                player.logs.contains(where: { $0.contains("FLOE_CONSOLE_PROBE 42") }) && player.logs.contains(where: { $0.contains("FLOE_BOUNDED_PROBE") })
            }
            try require(player.logs.allSatisfy { $0.utf8.count <= 8192 }, "Console entry exceeded its UTF-8 bound")
            step("real-browser-console-delivery-bounded-before-native-bridge")
            // Observe real DOM events in the rendered engine; this diagnostic
            // listener is confined to the qualification executable.
            _ = try await raw("""
            window.__floeKeyProbe=[];
            for(const kind of ['keydown','keyup'])document.addEventListener(kind,e=>window.__floeKeyProbe.push({type:e.type,
              key:e.key,code:e.code,keyCode:e.keyCode,which:e.which,location:e.location,shiftKey:e.shiftKey,
              ctrlKey:e.ctrlKey,altKey:e.altKey,metaKey:e.metaKey,repeat:e.repeat}));return true;
            """)
            for (key, pressed) in [(GameKeyboardKey.control, true), (.shift, true), (.z, true), (.z, false), (.shift, false), (.control, false), (.numpadEnter, true), (.numpadEnter, false)] {
                try await player.key(key, pressed: pressed)
            }
            let keyboardBytes = try await raw("return window.__floeKeyProbe;")
            let events = try JSONSerialization.jsonObject(with: keyboardBytes) as? [[String: Any]] ?? []
            try require(events.count == 8, "Keyboard events were lost or duplicated")
            try require(events[2]["code"] as? String == "KeyZ" && events[2]["keyCode"] as? Int == 90 && events[2]["key"] as? String == "Z", "Z keyboard descriptor was not delivered")
            try require(events[2]["ctrlKey"] as? Bool == true && events[2]["shiftKey"] as? Bool == true, "Chord modifiers missing")
            try require(events[4]["shiftKey"] as? Bool == false && events[4]["ctrlKey"] as? Bool == true && events[5]["ctrlKey"] as? Bool == false, "Modifier release flags were incorrect")
            try require(events[6]["code"] as? String == "NumpadEnter" && events[6]["location"] as? Int == 3, "Number-pad location was lost")
            try keyboardBytes.write(to: root.appendingPathComponent("actual-dom-keyboard-events.json"))
            step("real-dom-keyboard-chord-keycode-location-and-release-flags")
            try await player.key(.right, pressed: true)
            try await wait("input moves character and collects an item") {
                let state = try await self.state()
                return (state["score"] as? Int ?? 0) >= 1 && (state["frames"] as? Int ?? 0) > 1
            }
            try await player.key(.right, pressed: false)
            let captured = try await player.snapshotState()
            try captured.write(to: root.appendingPathComponent("phaser-state-after-input.json"))
            let saves = try FileGameSaveRepository(directory: root.appendingPathComponent("saves"), projectID: id, owner: owner)
            _ = try await saves.save(captured, expectedRevision: 0)
            let screenshot = try await player.capturePNG()
            try require(screenshot.count > 4_000, "Actual WebKit screenshot missing")
            try screenshot.write(to: root.appendingPathComponent("phaser-actual-webkit.png"))
            step("real-frames-input-score-screenshot-and-durable-progress")
            let isolation = try await raw("""
            let violation=false;document.addEventListener('securitypolicyviolation',e=>{if(e.effectiveDirective==='connect-src')violation=true});
            let blocked=false;try{await fetch('https://example.invalid/floe-game-forbidden')}catch(e){blocked=true}
            await new Promise(r=>setTimeout(r,50));return {blocked,violation};
            """)
            let blocked = try JSONSerialization.jsonObject(with: isolation) as? [String: Any]
            try require(blocked?["blocked"] as? Bool == true && blocked?["violation"] as? Bool == true, "External networking was not blocked by CSP")
            step("external-network-csp-violation-proved")
            let firstStop = await player.stop()
            try require(firstStop, "Stop was not confirmed by WebKit navigation")
            try await player.start(current: context)
            try await wait("clean restart") { player.gameReady && player.loaded }
            let restarted = try await state()
            try require(restarted["score"] as? Int == 0, "Restart did not create clean game state")
            let saved = try await saves.load()
            guard let saved else { throw QualificationFailure.assertion("Missing durable save") }
            try await player.restoreState(saved.state)
            let restored = try await state()
            try require((restored["score"] as? Int ?? 0) >= 1, "Progress did not restore")
            step("stopped-restarted-and-restored-durable-progress")
            let finalStop = await player.stop()
            try require(finalStop, "Final runtime stop was not confirmed")
            try await wait("runtime destroyed") {
                let bytes = try await self.raw("return !!window.FloeGame;")
                return (try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? Bool) == false
            }
            step("stopped-runtime-no-longer-exists")
            await finish(error: nil)
        } catch { await finish(error: error) }
    }

    private func finish(error: (any Error)?) async {
        guard !completed else { return }; completed = true
        if let player { await player.stop() }
        let ownsFocus = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        window?.orderOut(nil); window?.close(); window = nil
        if ownsFocus { previousApplication?.activate(options: []) }
        let record: [String: Any] = ["result": error == nil ? "passed" : "failed", "engine": "phaser", "version": GamePhaserTemplate.version,
            "platform": "macOS AppKit + real WebKit", "steps": steps, "error": error.map(String.init(describing:)) ?? "",
            "iosGameRuntimeVerified": false, "nativeHost": true]
        if let output, let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("runtime-result.json"))
        }
        print("RUNTIME RESULT: \(record)"); exitCode = error == nil ? 0 : 1
        NSApplication.shared.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApplication.shared.postEvent(event, atStart: true) }
    }
}

@main struct RuntimeQualification {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = QualificationDelegate(); app.delegate = delegate
        app.run(); exit(delegate.exitCode)
    }
}
#else
@main struct RuntimeQualification {
    static func main() { print("The development runtime qualification host requires macOS."); exit(1) }
}
#endif
