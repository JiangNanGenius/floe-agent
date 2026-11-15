// SPDX-License-Identifier: MPL-2.0
#if os(macOS)
import AppKit
import Foundation
import FloeGameCore
import FloeGameWebKit
import FloeGameNarrativeKit

extension Qualification {
    private func importedInkVariable(_ name: String, state: [String: Any]) -> Int? {
        guard let encoded = state["story"] as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any],
              let variables = object["variablesState"] as? [String: Any] else { return nil }
        return variables[name] as? Int
    }

    private func importedValues(_ state: [String: Any]) -> [Double] {
        (state["values"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
    }

    private func waitImported(_ condition: ([String: Any]) -> Bool) async throws -> [String: Any] {
        for _ in 0..<160 {
            let object = try await state()
            if condition(object) { return object }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "ImportedNarrativeQualification", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Original imported fixture did not reach expected real engine state: \(player?.logs ?? [])"])
    }

    /// Original multi-file/asset fixtures. Import the whole raw tree into a
    /// pre-created repository project; no starter normalization or host script
    /// interpreter participates in this actual WebKit run.
    func runImportedNarrative(engine: GameEngineID, resources: URL, source: URL, evidence: URL) async throws {
        output = evidence
        try require(!FileManager.default.fileExists(atPath: evidence.path), "Use fresh evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let repository = try FileGameProjectRepository(directory: evidence.appendingPathComponent("repository"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let empty = try await repository.createProject(projectID: id, owner: owner, title: "Imported \(engine.rawValue)", engine: engine)
        let imported = try await repository.importContents(from: source, into: id, owner: owner, expectedRevision: empty.revision)
        let context = try await repository.export(id, owner: owner, expectedRevision: imported.revision,
                                                  to: evidence.appendingPathComponent("intact-source-snapshot"))
        let compiled = evidence.appendingPathComponent("compiled-web")
        if engine == .ink {
            try GameInkAdapter.buildArtifact(projectAt: context.rootURL, to: compiled, resources: resources)
        } else {
            try GameMicroStudioAdapter.buildArtifact(projectAt: context.rootURL, to: compiled, resources: resources)
        }
        let package = try GameWebArtifactPackage.build(source: context, engine: engine,
            entry: GameRelativePath("index.html"), to: evidence.appendingPathComponent("sealed-artifact"), contentRoot: compiled)
        let marker = try GameRelativePath(engine == .ink ? "main.ink" : "ms/main.ms")
        let host = PreparedQualificationHost(current: context, package: package, evidencePath: marker)
        let controller = GameProjectRunController(contexts: host, preparation: host)
        try await controller.run(context: context, engine: engine)
        guard let first = controller.player else { throw GameProjectError.invalidArtifact }
        player = first; window.contentView = first.webView
        first.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        window.setContentSize(NSSize(width: 800, height: 480))
        try await waitReady()
        let initial = try await waitImported { object in
            if engine == .ink { return (object["text"] as? String)?.contains("雾从河谷") == true }
            let values = self.importedValues(object)
            return values.count >= 4 && values[2] == 1 && values[3] == 1
        }
        try await first.capturePNG().write(to: evidence.appendingPathComponent("initial-webkit.png"))
        if engine == .ink {
            try await first.key(.down, pressed: true); try await first.key(.down, pressed: false)
            try await first.key(.enter, pressed: true); try await first.key(.enter, pressed: false)
        } else {
            try await first.key(.right, pressed: true)
            try await Task.sleep(for: .milliseconds(250))
            try await first.key(.right, pressed: false)
        }
        let moved = try await waitImported { object in
            if engine == .ink { return self.importedInkVariable("lantern", state: object) == 1 }
            let values = self.importedValues(object), original = self.importedValues(initial)
            return values.count >= 4 && values[0] > original[0] + 10 && values[2] == 1 && values[3] == 1
        }
        if engine == .microStudio {
            try await Task.sleep(for: .milliseconds(200))
            let released = try await state()
            try require(abs(importedValues(released)[0] - importedValues(moved)[0]) < 0.01,
                        "Imported microStudio physical key release stops movement")
        }
        let checkpoint = try await first.snapshotState()
        let saves = try FileGameSaveRepository(directory: evidence.appendingPathComponent("saves"), projectID: id, owner: owner,
                                               maximumStateBytes: GameWebRuntimePolicy(engine: engine).maximumStateBytes)
        _ = try await saves.save(checkpoint, expectedRevision: 0)
        try await first.capturePNG().write(to: evidence.appendingPathComponent("actual-webkit.png"))
        let oldRun = controller.activeRunID!
        try require(await controller.stop(runID: oldRun), "Imported game stop")
        try await controller.run(context: context, engine: engine)
        guard let reopened = controller.player else { throw GameProjectError.invalidArtifact }
        player = reopened; window.contentView = reopened.webView
        reopened.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        try await waitReady()
        _ = try await waitImported { object in
            if engine == .ink { return (object["text"] as? String)?.contains("雾从河谷") == true }
            let values = self.importedValues(object)
            return values.count >= 4 && values[2] == 1 && values[3] == 1
        }
        try require(!(await controller.stop(runID: oldRun)), "Late old close cannot stop reopened imported game")
        guard let saved = try await saves.load() else { throw GameWebPlayerError.invalidState }
        try await reopened.restoreState(saved.state)
        let restored = try await state()
        if engine == .ink {
            try require(importedInkVariable("lantern", state: restored) == 1, "Nested INCLUDE variable save restores")
        } else {
            try require(importedValues(restored) == importedValues(moved), "Imported asset game restores its real variables")
        }
        try require(await controller.stop(), "Final imported game stop")
        results.append(["engine": engine.rawValue, "result": "passed", "nativeHost": true,
                        "platform": "macOS AppKit WebKit", "flow": "create -> intact raw import -> build -> project run",
                        "importedFiles": imported.files.count, "initial": initial, "moved": moved, "restored": restored,
                        "input": "physical keyboard descriptors", "artifactSHA256": package.prepared.sha256,
                        "logs": first.logs + reopened.logs])
        print("Verified imported \(engine.rawValue): original multi-file/assets, physical keys/release, snapshot save/reopen/restore")
    }
}
#endif
