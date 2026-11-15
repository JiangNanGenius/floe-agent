// SPDX-License-Identifier: MPL-2.0
#if os(macOS)
import AppKit
import Foundation
import FloeGameCore
import FloeGameWebKit
import FloeGameNarrativeKit

/// A fixed authoritative context for this isolated native qualification host.
/// The actual App supplies its existing project/environment/jobs services.
actor PreparedQualificationHost: GameRunContextHost, GameWebRunPreparationHost {
    let current: GameProjectContext
    let package: GameWebArtifactPackage
    let evidencePath: GameRelativePath
    init(current: GameProjectContext, package: GameWebArtifactPackage, evidencePath: GameRelativePath? = nil) {
        self.current = current; self.package = package
        self.evidencePath = evidencePath ?? (try! GameRelativePath("project.json"))
    }
    func currentContext(for captured: GameProjectContext) throws -> GameProjectContext {
        try captured.validate(current: current); return current
    }
    func prepare(_ request: GameWebRunRequest) throws -> GamePreparedWebRun {
        try request.context.validate(current: current)
        guard request.engine == package.prepared.engine else { throw GameProjectError.invalidArtifact }
        // Each adapter created/validated this real project.json before building.
        let evidence = GameEngineEvidence(path: evidencePath, kind: .projectMarker)
        let inspection = GameProjectInspection(rootURL: current.rootURL, context: current,
            candidates: [GameEngineCandidate(engine: request.engine, evidence: [evidence])], inspectedPaths: [evidence.path])
        return .init(inspection: inspection, package: package)
    }
    func cancel(_ request: GameWebRunRequest) {}
}

extension Qualification {
    func runNarrative(resources: URL, evidence: URL, filter: String?) async throws {
        output = evidence
        try require(!FileManager.default.fileExists(atPath: evidence.path), "Use fresh evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let engines: [GameEngineID] = [.ink, .twine, .wasm4, .tic80, .microStudio]
        for engine in engines where filter == nil || engine.rawValue == filter {
            let root = evidence.appendingPathComponent(engine.rawValue)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let repo = try FileGameProjectRepository(directory: root.appendingPathComponent("repository"))
            let id = UUID(), owner = GameProjectOwner.space(recordID: id)
            let empty = try await repo.createProject(projectID: id, owner: owner, title: engine.rawValue, engine: engine)
            let source = root.appendingPathComponent("generated-source")
            switch engine {
            case .ink: try GameInkAdapter.createProject(at: source, title: "Forest Postie")
            case .twine: try GameTwineAdapter.createProject(at: source, title: "Forest Postie")
            case .wasm4: try GameWasm4Adapter.createProject(at: source, title: "Postie dot")
            case .tic80: try GameTIC80Adapter.createProject(at: source, title: "Postie dot")
            case .microStudio: try GameMicroStudioAdapter.createProject(at: source, title: "Postie dot")
            default: throw GameProjectError.invalidContext
            }
            if engine == .tic80 {
                // Instrument only this original QA fixture, before import and
                // source-revision binding. A changing boot animation is not
                // evidence that its cartridge loop or keyboard input works.
                let cartURL = source.appendingPathComponent("cart.tic")
                var cart = try TICCart.parse(Data(contentsOf: cartURL))
                for index in cart.chunks.indices where cart.chunks[index].type == TICCart.ChunkType.code.rawValue {
                    let original = String(decoding: cart.chunks[index].data, as: UTF8.self)
                    let instrumented = original.replacingOccurrences(of: "function TIC() {", with: "function TIC() { trace('FLOE_TIC_X=' + x);")
                    cart.chunks[index].data = Data(instrumented.utf8)
                }
                try cart.serialized().write(to: cartURL)
            }
            let stored = try await repo.importContents(from: source, into: id, owner: owner, expectedRevision: empty.revision)
            let context = try await repo.export(id, owner: owner, expectedRevision: stored.revision, to: root.appendingPathComponent("source-snapshot"))
            let web = root.appendingPathComponent("compiled-web")
            switch engine {
            case .ink: try GameInkAdapter.buildArtifact(projectAt: context.rootURL, to: web, resources: resources)
            case .twine: try GameTwineAdapter.buildArtifact(projectAt: context.rootURL, to: web, resources: resources)
            case .wasm4: try GameWasm4Adapter.buildArtifact(projectAt: context.rootURL, to: web, resources: resources)
            case .tic80: try GameTIC80Adapter.buildArtifact(projectAt: context.rootURL, to: web, resources: resources)
            case .microStudio: try GameMicroStudioAdapter.buildArtifact(projectAt: context.rootURL, to: web, resources: resources)
            default: throw GameProjectError.invalidContext
            }
            let package = try GameWebArtifactPackage.build(source: context, engine: engine, entry: GameRelativePath("index.html"), to: root.appendingPathComponent("sealed-artifact"), contentRoot: web)
            let host = PreparedQualificationHost(current: context, package: package)
            let controller = GameProjectRunController(contexts: host, preparation: host)
            try await controller.run(context: context, engine: engine)
            guard let started = controller.player else { throw GameProjectError.invalidArtifact }
            player = started; window.contentView = started.webView
            started.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            try await waitReady(); try await Task.sleep(for: .milliseconds(250))
            let initialTICX = engine == .tic80 ? try await waitForTICFrame(started) : nil
            let initial = started.supportsState ? try await state() : [:]
            let initialPNG = try await started.capturePNG(); try initialPNG.write(to: root.appendingPathComponent("initial-webkit.png"))
            if engine == .ink || engine == .twine {
                for _ in 0..<2 {
                    try await started.key(.down, pressed: true)
                    try await started.key(.down, pressed: false)
                }
                try await started.key(.enter, pressed: true)
                try await started.key(.enter, pressed: false)
            }
            else {
                try await started.key(.right, pressed: true)
                try await Task.sleep(for: .milliseconds(500))
                try await started.key(.right, pressed: false)
            }
            try await Task.sleep(for: .milliseconds(150))
            let moved = started.supportsState ? try await state() : [:]
            let png = try await started.capturePNG(); try png.write(to: root.appendingPathComponent("actual-webkit.png"))
            try require(png != initialPNG, "Input must change the actual engine screen")
            var ticObservation: [String: Any] = [:]
            if let initialTICX {
                let movedX = try await waitForTICFrame(started)
                try require(movedX > initialTICX + 10, "Right key must move the running cartridge horizontally")
                ticObservation = ["initialX": initialTICX, "movedX": movedX, "source": "original QA cartridge trace from real TIC loop"]
            }
            var checkpoint: Data?
            if started.supportsState {
                try require(observable(initial, engine: engine) != observable(moved, engine: engine), "Input must change real engine state")
                checkpoint = try await started.snapshotState()
                let saves = try FileGameSaveRepository(directory: root.appendingPathComponent("saves"), projectID: id, owner: owner, maximumStateBytes: GameWebRuntimePolicy(engine: engine).maximumStateBytes)
                _ = try await saves.save(checkpoint!, expectedRevision: 0)
                checkpoint = try await saves.load()?.state
            }
            let oldRunID = controller.activeRunID!
            try require(await controller.stop(runID: oldRunID), "Project-level stop")
            try await controller.run(context: context, engine: engine)
            guard let restartedPlayer = controller.player else { throw GameProjectError.invalidArtifact }
            player = restartedPlayer; window.contentView = restartedPlayer.webView
            restartedPlayer.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            try await waitReady(); try await Task.sleep(for: .milliseconds(150))
            try require(!(await controller.stop(runID: oldRunID)), "A late old close cannot stop a newer run")
            let restarted = restartedPlayer.supportsState ? try await state() : [:]
            var restored: [String: Any] = [:]
            if let checkpoint {
                try require(observable(initial, engine: engine) == observable(restarted, engine: engine), "Restart creates fresh state")
                try await restartedPlayer.restoreState(checkpoint)
                restored = try await state()
                try require(observable(moved, engine: engine) == observable(restored, engine: engine), "Restore must recover engine progress")
            }
            try require(await controller.stop(), "Final stop")
            results.append(["engine": engine.rawValue, "result": "passed", "nativeHost": true,
                "platform": "macOS AppKit WebKit", "flow": "create then import then project-level run", "input": "physical keyboard key descriptors",
                "stateSupported": checkpoint != nil, "initial": initial, "moved": moved,
                "cartridgeObservation": ticObservation,
                "restarted": restarted, "restored": restored, "logs": restartedPlayer.logs,
                "artifactSHA256": package.prepared.sha256])
            print("Verified actual \(engine.rawValue) WebKit: input, screen, restart\(checkpoint != nil ? ", save/restore" : "; state unsupported")", terminator: "\n")
        }
    }
    private func waitForTICFrame(_ player: GameWebPlayer) async throws -> Double {
        for _ in 0..<160 {
            if let line = player.logs.last(where: { $0.contains("FLOE_TIC_X=") }),
               let value = line.components(separatedBy: "FLOE_TIC_X=").last?.trimmingCharacters(in: .whitespacesAndNewlines),
               let x = Double(value) { return x }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "TIC80Qualification", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "No actual cartridge frame: \(player.logs)"])
    }
    private func observable(_ object: [String: Any], engine: GameEngineID) -> String {
        let value: Any
        switch engine {
        case .ink: value = ["text": object["text"] ?? "", "choices": object["choices"] ?? []]
        case .twine: value = ["passage": object["passage"] ?? "", "variables": object["variables"] ?? [:]]
        case .wasm4: value = (object["globals"] as? [String: Any] ?? [:]).filter { !$0.key.lowercased().contains("frame") }
        case .microStudio: value = Array((object["values"] as? [Any] ?? []).prefix(3))
        default: value = object
        }
        return (try? String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)) ?? "invalid"
    }
}
#endif
