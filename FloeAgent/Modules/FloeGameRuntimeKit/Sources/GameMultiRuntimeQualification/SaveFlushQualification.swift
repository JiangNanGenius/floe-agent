// SPDX-License-Identifier: MPL-2.0
#if os(macOS)
import AppKit
import Foundation
import FloeGameCore
import FloeGameWebKit

extension Qualification {
    /// Small, original protocol fixtures for real WebKit lifecycle behavior.
    /// These cases are not counted as additional working game engines.
    func runSaveFlush(evidence: URL) async throws {
        output = evidence
        try require(!FileManager.default.fileExists(atPath: evidence.path), "Use fresh evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let cases = ["saved", "missing", "throws", "unresolved", "duplicate", "superseded"]
        for mode in cases {
            let source = evidence.appendingPathComponent(mode + "-source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let hook: String
            switch mode {
            case "missing": hook = ""
            case "throws": hook = "prepareToStop:async()=>{throw new Error('Original fixture failure')},"
            case "unresolved": hook = "prepareToStop:()=>new Promise(()=>{}),"
            default:
                hook = "prepareToStop:async()=>{await new Promise(resolve=>setTimeout(resolve,150));localStorage.setItem('closed','acknowledged');return true},"
            }
            let html = """
            <!doctype html><html><body>Original close fixture<script>
            window.FloeGame={\(hook)snapshot:()=>({stored:localStorage.getItem('closed')||''}),restore:()=>false};
            window.floeGameHost.ready({input:false,state:true});
            </script></body></html>
            """
            try Data(html.utf8).write(to: source.appendingPathComponent("index.html"))
            try Data(#"{"dependencies":{"phaser":"3.90.0"}}"#.utf8).write(to: source.appendingPathComponent("package.json"))
            let id = UUID()
            let context = try GameProjectContext(projectID: id, owner: .space(recordID: id), rootURL: source,
                                                 savedRevision: "original-close-fixture", environmentID: "qa-existing-environment")
            let package = try GameWebArtifactPackage.build(source: context, engine: .phaser,
                entry: GameRelativePath("index.html"), to: evidence.appendingPathComponent(mode + "-artifact"))
            var registry = GameAdapterRegistry()
            try registry.register(.init(engine: .phaser, route: .webKit, runtimeReady: true))
            guard case .launch(let plan) = try GameLaunchPlanner.plan(
                inspection: GameProjectInspector().inspect(context: context), context: context,
                registry: registry, artifact: package.prepared) else { throw GameProjectError.invalidArtifact }
            let current = try GameWebPlayer(package: package, plan: plan, current: context)
            player = current; window.contentView = current.webView
            current.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            try await current.start(current: context); try await waitReady()
            let began = Date()
            if mode == "duplicate" {
                let firstClose = Task { await current.stop() }
                try await Task.sleep(for: .milliseconds(30))
                let secondClose = await current.stop()
                let firstResult = await firstClose.value
                try require(secondClose && !firstResult, "Duplicate close coalesces flush and fences superseded navigation")
                try require(current.lastSaveFlushStatus == .saved, "Duplicate close retains acknowledged save")
            } else if mode == "superseded" {
                let oldClose = Task { await current.stop() }
                try await Task.sleep(for: .milliseconds(30))
                try await current.start(current: context); try await waitReady()
                let oldResult = await oldClose.value
                try require(!oldResult, "New run supersedes old close")
                try await Task.sleep(for: .milliseconds(250))
                try require(current.gameReady && current.loaded, "Late old flush cannot blank the new run")
                try require(await current.stop(), "Stop replacement run")
                try require(current.lastSaveFlushStatus == .saved, "Replacement run has independent flush result")
            } else {
                try require(await current.stop(), "Runtime stops even if its save hook fails")
                let expected: GameWebSaveFlushStatus = mode == "saved" ? .saved : (mode == "missing" ? .notRequired : .failed)
                try require(current.lastSaveFlushStatus == expected, "Truthful close result for " + mode)
                if mode == "unresolved" {
                    try require(Date().timeIntervalSince(began) < 5, "Untrusted save promise cannot hang close")
                }
            }
            let closeStatus = current.lastSaveFlushStatus
            if ["saved", "duplicate", "superseded"].contains(mode) {
                let reopened = try GameWebPlayer(package: package, plan: plan, current: context)
                player = reopened; window.contentView = reopened.webView
                try await reopened.start(current: context); try await waitReady()
                try require((try await state())["stored"] as? String == "acknowledged", "Close writes exist in a fresh player")
                try require(await reopened.stop(), "Stop fresh verification player")
            }
            results.append(["case": mode, "result": "passed", "platform": "macOS AppKit WebKit",
                            "scope": "original lifecycle protocol fixture, not an engine compatibility test",
                            "closeStatus": String(describing: closeStatus), "elapsed": Date().timeIntervalSince(began)])
            print("Verified real WebKit close hook: \(mode)")
        }
    }
}
#endif
