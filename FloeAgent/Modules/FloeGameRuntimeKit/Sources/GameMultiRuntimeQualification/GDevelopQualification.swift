// SPDX-License-Identifier: MPL-2.0
#if os(macOS)
import AppKit
import Foundation
import WebKit
import FloeGameCore
import FloeGameWebKit

extension Qualification {
    /// Consumes the unchanged official SDK export. The diagnostic observer
    /// records the scene passed to the real input query; it delegates that query
    /// unchanged and is confined to this development qualification executable.
    private func gdevelopState() async throws -> [String: Any] {
        guard let player else { throw GameProjectError.invalidContext }
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            player.webView.callAsyncJavaScript("""
            if(typeof gdjs==='undefined'||!gdjs.evtTools?.input?.isKeyPressed)return {ready:false};
            if(!window.__floeObservedInput){
              window.__floeObservedInput=gdjs.evtTools.input.isKeyPressed;
              gdjs.evtTools.input.isKeyPressed=function(scene,key){
                window.__floeObservedScene=scene;
                return window.__floeObservedInput.apply(this,arguments);
              };
            }
            const scene=window.__floeObservedScene,orb=scene?.getObjects('Orb')?.[0],canvas=document.querySelector('canvas');
            if(!orb||!canvas)return {ready:false};
            return {ready:true,x:orb.getX(),y:orb.getY(),scene:scene.getName(),
                    canvasWidth:canvas.width,canvasHeight:canvas.height};
            """, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    if let object = value as? [String: Any] {
                        do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) }
                        catch { continuation.resume(throwing: error) }
                    } else { continuation.resume(throwing: GameWebPlayerError.invalidState) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw GameWebPlayerError.invalidState }
        return object
    }

    private func waitForGDevelop() async throws -> [String: Any] {
        for _ in 0..<200 {
            if let failure = player?.failure { throw NSError(domain: "GameWebKit", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
            if player?.loaded == true {
                let value = try await gdevelopState()
                if value["ready"] as? Bool == true { return value }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "GDevelopQualification", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Official engine did not start: \(player?.logs ?? [])"])
    }

    func runGDevelop(source: URL, web: URL, evidence: URL) async throws {
        output = evidence
        try require(!FileManager.default.fileExists(atPath: evidence.path), "Use fresh evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let repository = try FileGameProjectRepository(directory: evidence.appendingPathComponent("repository"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let empty = try await repository.createProject(projectID: id, owner: owner, title: "Official GDevelop", engine: .gdevelop)
        let imported = try await repository.importContents(from: source, into: id, owner: owner, expectedRevision: empty.revision)
        let context = try await repository.export(id, owner: owner, expectedRevision: imported.revision,
                                                  to: evidence.appendingPathComponent("source-snapshot"))
        let package = try GameWebArtifactPackage.build(source: context, engine: .gdevelop,
            entry: GameRelativePath("index.html"), to: evidence.appendingPathComponent("sealed-official-export"), contentRoot: web)
        let marker = try GameRelativePath("game.json")
        let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
            candidates: [.init(engine: .gdevelop, evidence: [.init(path: marker, kind: .projectMarker)])], inspectedPaths: [marker])
        var registry = GameAdapterRegistry()
        try registry.register(.init(engine: .gdevelop, route: .webKit, runtimeReady: true))
        guard case .launch(let plan) = try GameLaunchPlanner.plan(inspection: inspection, context: context, registry: registry, artifact: package.prepared)
        else { throw GameProjectError.invalidArtifact }
        let player = try GameWebPlayer(package: package, plan: plan, current: context)
        self.player = player; window.contentView = player.webView
        player.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        try await player.start(current: context)
        let initial = try await waitForGDevelop()
        try await player.capturePNG().write(to: evidence.appendingPathComponent("initial-webkit.png"))
        try await player.key(.right, pressed: true)
        try await Task.sleep(for: .milliseconds(600))
        try await player.key(.right, pressed: false)
        let right = try await gdevelopState()
        try require((right["x"] as? Double ?? 0) > (initial["x"] as? Double ?? 0) + 40, "Official GDevelop right key must move Orb")
        try await player.key(.down, pressed: true)
        try await Task.sleep(for: .milliseconds(350))
        try await player.key(.down, pressed: false)
        let down = try await gdevelopState()
        try require((down["y"] as? Double ?? 0) > (right["y"] as? Double ?? 0) + 20, "Official GDevelop down key must move Orb")
        try await player.capturePNG().write(to: evidence.appendingPathComponent("actual-webkit.png"))
        try await player.key(.z, pressed: true)
        try await Task.sleep(for: .milliseconds(120))
        try await player.key(.z, pressed: false)
        let reset = try await gdevelopState()
        try require(abs((reset["x"] as? Double ?? 0)-280) < 0.01 && abs((reset["y"] as? Double ?? 0)-140) < 0.01, "Official GDevelop Z reset")
        try require(!player.supportsState, "Unmodified GDevelop export has no fabricated native state protocol")
        try require(await player.stop(), "Stop destroys actual GDevelop runtime")
        try await player.start(current: context)
        let reopened = try await waitForGDevelop()
        try require(abs((reopened["x"] as? Double ?? 0)-280) < 0.01, "Restart creates fresh real engine state")
        try require(await player.stop(), "Final stop")
        results.append(["engine": "gdevelop", "version": "5.6.287", "result": "passed", "nativeHost": true,
            "platform": "macOS AppKit WebKit", "sourceAndExportUnmodified": true,
            "diagnostic": "observe real engine input-query scene and delegate unchanged", "stateProtocolSupported": false,
            "initial": initial, "right": right, "down": down, "reset": reset, "reopened": reopened,
            "artifactSHA256": package.prepared.sha256, "logs": player.logs])
        print("Verified official GDevelop WebKit: source-bound export, keyboard movement/Z reset, screenshot, stop/restart")
    }
}
#endif
