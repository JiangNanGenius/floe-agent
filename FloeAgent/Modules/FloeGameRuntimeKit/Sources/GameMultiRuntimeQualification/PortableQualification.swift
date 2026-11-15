// SPDX-License-Identifier: MPL-2.0
#if os(macOS)
import AppKit
import Foundation
import WebKit
import FloeGameCore
import FloeGameWebKit

extension Qualification {
    private func portableObject(_ script: String) async throws -> [String: Any] {
        guard let player else { throw GameProjectError.invalidContext }
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            player.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    do {
                        guard let object = value as? [String: Any] else { throw GameWebPlayerError.invalidState }
                        continuation.resume(returning: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                    } catch { continuation.resume(throwing: error) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw GameWebPlayerError.invalidState }
        return object
    }

    func portableObservation(_ engine: GameEngineID) async throws -> [String: Any] {
        switch engine {
        case .rpgMakerMV:
            return try await portableObject("""
            const scene=window.SceneManager?._scene,commands=scene?._commandWindow;
            return {scene:scene?.constructor?.name||'',
              titleReady:!!(scene?.constructor?.name==='Scene_Title'&&scene.isActive()&&!scene.isBusy()&&commands?.active&&commands.openness===255),
              mapReady:!!(scene?.constructor?.name==='Scene_Map'&&scene.isActive()&&!scene.isBusy()),
              sceneActive:!!scene?.isActive?.(),busy:!!scene?.isBusy?.(),commandActive:!!commands?.active,
              map:window.$gameMap?.mapId?.()||0,x:window.$gamePlayer?.x??-1,y:window.$gamePlayer?.y??-1};
            """)
        case .renpy:
            return try await portableObject("""
            if(typeof renpy_get!=='function')return {ready:false};
            return {ready:true,stage:await renpy_get('floe_stage'),clicks:await renpy_get('floe_clicks')};
            """)
        case .love:
            guard let line = player?.logs.last(where: { $0.contains("FLOE_STATE tick") }),
                  let range = line.range(of: #"x=(-?[0-9]+(?:\.[0-9]+)?)"#, options: .regularExpression),
                  let x = Double(line[range].dropFirst(2)) else { return [:] }
            return ["x": x, "actualLuaLog": line]
        default: throw GameProjectError.invalidContext
        }
    }

    private func waitPortable(_ engine: GameEngineID, label: String,
                              condition: ([String: Any]) -> Bool) async throws -> [String: Any] {
        for _ in 0..<200 {
            if player?.loaded == true {
                let observation = try await portableObservation(engine)
                if condition(observation) { return observation }
            }
            if let failure = player?.failure { throw NSError(domain: "GameWebKit", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "PortableQualification", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "\(label): \(player?.logs ?? [])"])
    }

    private func portableTap(_ key: GameKeyboardKey) async throws {
        guard let player else { throw GameProjectError.invalidContext }
        try await player.key(key, pressed: true)
        try await Task.sleep(for: .milliseconds(100))
        try await player.key(key, pressed: false)
    }

    func runPortable(engine: GameEngineID, web: URL, evidence: URL, verifyBuiltInSaves: Bool = false) async throws {
        output = evidence
        try require(!FileManager.default.fileExists(atPath: evidence.path), "Use fresh evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let repo = try FileGameProjectRepository(directory: evidence.appendingPathComponent("repository"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let empty = try await repo.createProject(projectID: id, owner: owner, title: engine.rawValue, engine: engine)
        let imported = try await repo.importContents(from: web, into: id, owner: owner, expectedRevision: empty.revision)
        let context = try await repo.export(id, owner: owner, expectedRevision: imported.revision,
            to: evidence.appendingPathComponent("intact-import"))
        let package = try GameWebArtifactPackage.build(source: context, engine: engine,
            entry: GameRelativePath("index.html"), to: evidence.appendingPathComponent("sealed-artifact"))
        let marker = try GameRelativePath("floe-portable-artifact.json")
        let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
            candidates: [.init(engine: engine, evidence: [.init(path: marker, kind: .dataLayout)])], inspectedPaths: [marker])
        var registry = GameAdapterRegistry(); try registry.register(.init(engine: engine, route: .webKit, runtimeReady: true))
        guard case .launch(let plan) = try GameLaunchPlanner.plan(inspection: inspection, context: context, registry: registry, artifact: package.prepared)
        else { throw GameProjectError.invalidArtifact }
        let player = try GameWebPlayer(package: package, plan: plan, current: context)
        self.player = player; window.contentView = player.webView
        player.webView.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        window.setContentSize(NSSize(width: 960, height: 640))
        try await player.start(current: context)
        var initial: [String: Any] = [:], moved: [String: Any] = [:], restored: [String: Any] = [:]
        var expectedBuiltInSaveX: Double?
        switch engine {
        case .rpgMakerMV:
            _ = try await waitPortable(engine, label: "Actual MV title menu accepts keys") { $0["titleReady"] as? Bool == true }
            try await portableTap(.z)
            try await waitReady()
            initial = try await waitPortable(engine, label: "Actual MV map accepts movement") { $0["mapReady"] as? Bool == true }
            try require(initial["map"] as? Int == 1, "Actual original MV map data")
            try await player.key(.right, pressed: true)
            try await Task.sleep(for: .milliseconds(600))
            try await player.key(.right, pressed: false)
            moved = try await portableObservation(engine)
            try require((moved["x"] as? Int ?? 0) > (initial["x"] as? Int ?? 0), "Physical right key moves actual MV player")
            let saved = try await player.snapshotState()
            try await player.key(.left, pressed: true)
            try await Task.sleep(for: .milliseconds(300))
            try await player.key(.left, pressed: false)
            try await player.restoreState(saved)
            _ = try await waitPortable(engine, label: "MV save restore") { $0["scene"] as? String == "Scene_Map" }
            restored = try await portableObservation(engine)
            try require(restored["x"] as? Int == moved["x"] as? Int, "Actual MV JsonEx save restores player")
        case .love:
            try await waitReady()
            initial = try await waitPortable(engine, label: "Original Lua game loop") { $0["x"] is Double }
            try await player.key(.right, pressed: true)
            try await Task.sleep(for: .milliseconds(650))
            try await player.key(.right, pressed: false)
            moved = try await waitPortable(engine, label: "Real Lua keyboard movement") {
                ($0["x"] as? Double ?? 0) > (initial["x"] as? Double ?? 0) + 30
            }
            try require(!player.supportsState, "LOVE host snapshots are unsupported")
            try await portableTap(.s)
            for _ in 0..<50 {
                if player.logs.contains(where: { $0.contains("FLOE_SAVE_WRITTEN") }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(player.logs.contains(where: { $0.contains("FLOE_SAVE_WRITTEN") }), "Actual Lua filesystem save")
            try await portableTap(.l)
            for _ in 0..<50 {
                if player.logs.contains(where: { $0.contains("FLOE_SAVE_LOADED") }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(player.logs.contains(where: { $0.contains("FLOE_SAVE_LOADED") }), "Actual Lua filesystem read in the same run")
            if let line = player.logs.last(where: { $0.contains("FLOE_SAVE_LOADED ") }),
               let payload = line.components(separatedBy: "FLOE_SAVE_LOADED ").last,
               let first = payload.split(separator: ",").first {
                expectedBuiltInSaveX = Double(first.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case .renpy:
            try await waitReady()
            initial = try await portableObservation(engine)
            if initial["stage"] as? String == "menu" {
                try await portableTap(.enter)
                initial = try await waitPortable(engine, label: "RenPy keyboard starts the story") { $0["stage"] as? String == "opening" }
            }
            try require(initial["stage"] as? String == "opening", "Real RenPy script opening")
            try await portableTap(.enter)
            _ = try await waitPortable(engine, label: "RenPy script choice") { $0["stage"] as? String == "choice" }
            try await portableTap(.down); try await portableTap(.enter)
            moved = try await waitPortable(engine, label: "RenPy actual branch") { ["answered", "waited"].contains($0["stage"] as? String ?? "") }
            try require((moved["clicks"] as? Int ?? 0) >= 2, "Real RenPy variables changed")
            try require(!player.supportsState, "RenPy host snapshots are unsupported")
        default: throw GameProjectError.invalidContext
        }
        try await player.capturePNG().write(to: evidence.appendingPathComponent("actual-webkit.png"))
        try require(await player.stop(), "Actual engine stop")
        var builtInSaveObservation: [String: Any] = [:]
        if verifyBuiltInSaves {
            try require(engine == .love, "This fixed built-in-save probe currently covers the original Lua fixture")
            try require(player.lastSaveFlushStatus == .saved, "Engine filesystem flush acknowledged before teardown")
            guard let expectedBuiltInSaveX else { throw GameWebPlayerError.invalidState }
            // A new GameWebPlayer, not the original in-memory filesystem or a
            // host snapshot. The original Lua S/L handlers remain unchanged.
            let reopened = try GameWebPlayer(package: package, plan: plan, current: context)
            self.player = reopened; window.contentView = reopened.webView
            reopened.webView.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
            try await reopened.start(current: context); try await waitReady()
            let fresh = try await waitPortable(engine, label: "Reopened original Lua game") { $0["x"] is Double }
            try require(abs((fresh["x"] as? Double ?? 0) - expectedBuiltInSaveX) > 20,
                        "New player starts with fresh Lua state")
            try await portableTap(.l)
            let loaded = try await waitPortable(engine, label: "Actual filesystem save survives a new player") {
                guard let x = $0["x"] as? Double else { return false }
                return abs(x - expectedBuiltInSaveX) < 0.05
            }
            try require(reopened.logs.contains(where: { $0.contains("FLOE_SAVE_LOADED") }),
                        "Original Lua code read the persisted save file")
            builtInSaveObservation = ["fresh": fresh, "expectedSavedX": expectedBuiltInSaveX,
                                      "loaded": loaded, "logs": reopened.logs]
            try await reopened.capturePNG().write(to: evidence.appendingPathComponent("restored-built-in-save.png"))
            try require(await reopened.stop(), "Reopened engine stop")
        }
        results.append(["engine": engine.rawValue, "result": "passed", "nativeHost": true,
            "platform": "macOS AppKit WebKit", "initial": initial, "moved": moved, "restored": restored,
            "source": "whole imported unchanged worker Web export", "input": "physical keyboard descriptors",
            "artifactSHA256": package.prepared.sha256, "logs": player.logs,
            "crossPlayerBuiltInSavePersistenceVerified": verifyBuiltInSaves,
            "builtInSaveObservation": builtInSaveObservation])
        print("Verified actual \(engine.rawValue) WebKit: intact external import, keyboard, real engine state and screenshot")
    }
}
#endif
