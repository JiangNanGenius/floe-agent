// SPDX-License-Identifier: MPL-2.0
// A bounded macOS WKWebView engine qualification; not the full App or an iPad test.
#if os(macOS)
import AppKit
import Foundation
import WebKit
import FloeScoreKit

@MainActor final class PageNavigation: NSObject, WKNavigationDelegate {
    var finish: CheckedContinuation<Void, any Error>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish?.resume(); finish = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish?.resume(throwing: error); finish = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish?.resume(throwing: error); finish = nil }
}
@main struct ScoreWebQualification {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count >= 3 else { fatalError("Usage: ScoreWebQualification fixture.musicxml output-directory") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = ScoreWorkbench.descriptor.resourceRoot
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: "globalThis.scoreErrors=[];addEventListener('error',e=>scoreErrors.push(e.message));addEventListener('unhandledrejection',e=>scoreErrors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1240, height: 980), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        FileHandle.standardOutput.write(Data("Starting WKWebView navigation\n".utf8))
        let navigation = PageNavigation()
        web.navigationDelegate = navigation
        try await withCheckedThrowingContinuation { continuation in
            navigation.finish = continuation
            web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        }
        FileHandle.standardOutput.write(Data("WKWebView navigation finished\n".utf8))
        let initial = try await web.callAsyncJavaScript("return JSON.stringify({editor:!!window.FloeEditor,errors:window.scoreErrors,body:document.body.innerText.slice(0,1400)});", arguments: [:], in: nil, contentWorld: .page)
        FileHandle.standardOutput.write(Data("Initial: \(initial ?? "nil")\n".utf8))
        let readiness = try await web.callAsyncJavaScript("for(let i=0;i<100;i++){if(window.FloeEditor?.renderKey)return 'ready';if(window.scoreErrors?.length)throw new Error(scoreErrors.join(';'));await new Promise(r=>setTimeout(r,50));}throw new Error(document.body.innerText);", arguments: [:], in: nil, contentWorld: .page)
        FileHandle.standardOutput.write(Data("Readiness finished\n".utf8))
        print("Ready: \(readiness ?? "nil")")
        let base64 = try Data(contentsOf: fixture).base64EncodedString()
        let importResult = try await web.callAsyncJavaScript("const e=window.FloeEditor;await e.execute({command:'file.import',arguments:{name:'ensemble.musicxml',base64:value},revision:e.revision});return JSON.stringify({title:document.title,commands:e.catalog().length,parts:e.state.xml.match(/<part id=/g).length,svgs:e.scoreSurface.querySelectorAll('svg').length,paths:e.scoreSurface.querySelectorAll('path').length,mappedNotes:e.noteVisuals.size,body:document.body.innerText.slice(0,400)});", arguments: ["value": base64], in: nil, contentWorld: .page)
        print("Fixture: \(importResult ?? "nil")")
        if let text = importResult as? String { try text.write(to: output.appendingPathComponent("render-fixture.json"), atomically: true, encoding: .utf8) }
        for format in ["musicxml", "mxl", "midi", "svg", "png", "pdf"] {
            let result = try await web.callAsyncJavaScript("const e=window.FloeEditor;const r=await e.execute({command:'score.export',arguments:{format:value,scale:1},revision:e.revision});return JSON.stringify(r.artifacts);", arguments: ["value": format], in: nil, contentWorld: .page)
            guard let text = result as? String, let encoded = text.data(using: .utf8),
                  let artifacts = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] else { fatalError("No artifacts for \(format)") }
            for artifact in artifacts {
                guard let name = artifact["name"] as? String, let base64 = artifact["base64"] as? String,
                      let bytes = Data(base64Encoded: base64), !name.contains("/"), !bytes.isEmpty else { fatalError("Invalid \(format) artifact") }
                try bytes.write(to: output.appendingPathComponent(name))
                print("Artifact \(name): \(bytes.count) bytes")
            }
        }
        try await snapshot(web, destination: output.appendingPathComponent("score-ipad-layout.png"))
        let interaction = try await web.callAsyncJavaScript("const e=window.FloeEditor;const g=e.scoreSurface.querySelector('[data-score-notes]');if(!g)throw new Error('No clickable notes');g.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,clientY:100,pointerId:1}));g.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,clientY:100,pointerId:1}));if(!e.selection?.note)throw new Error('Click did not select a note');const before=e.selection.note;await e.perform('score.edit.transpose',{semitones:1});return JSON.stringify({selected:before,after:e.selection.note,highlighted:e.scoreSurface.querySelectorAll('.score-selected').length});", arguments: [:], in: nil, contentWorld: .page)
        print("Interaction: \(interaction ?? "nil")")
        web.setFrameSize(NSSize(width: 390, height: 844))
        window.setContentSize(NSSize(width: 390, height: 844))
        _ = try await web.callAsyncJavaScript("await new Promise(r=>setTimeout(r,350));await window.FloeEditor.render();return document.body.innerText.includes('Score');", arguments: [:], in: nil, contentWorld: .page)
        try await snapshot(web, destination: output.appendingPathComponent("score-phone-layout.png"))
        web.setFrameSize(NSSize(width: 1240, height: 980))
        window.setContentSize(NSSize(width: 1240, height: 980))
        _ = try await web.callAsyncJavaScript("await new Promise(r=>setTimeout(r,250));const e=window.FloeEditor;await e.execute({command:'score.project.template',arguments:{template:'quartet',bars:32},revision:e.revision});await e.execute({command:'score.layout.settings',arguments:{paper:'A4_P',zoom:1,margin:15,measuresPerSystem:4,staffSpacing:7},revision:e.revision});return e.scoreSurface.querySelectorAll('svg').length;", arguments: [:], in: nil, contentWorld: .page)
        let paged = try await web.callAsyncJavaScript("const e=window.FloeEditor;return JSON.stringify({pages:e.scoreSurface.querySelectorAll('svg').length,paths:e.scoreSurface.querySelectorAll('path').length,mappedNotes:e.noteVisuals.size,xmlMeasures:(e.state.xml.match(/<measure /g)||[]).length,sourceMeasures:e.osmd.Sheet.SourceMeasures.length,measureList:e.osmd.GraphicSheet.MeasureList.length,firstRow:e.osmd.GraphicSheet.MeasureList[0].length,sample:e.osmd.GraphicSheet.MeasureList.slice(0,3).flat().flatMap(m=>(m?.staffEntries??[]).flatMap(s=>(s.graphicalVoiceEntries??[]).flatMap(v=>(v.notes??[]).map(g=>({staff:g.sourceNote.ParentStaff.Id,voice:g.sourceNote.ParentVoiceEntry.ParentVoice.VoiceId,onset:g.sourceNote.ParentVoiceEntry.Timestamp.RealValue,part:g.sourceNote.ParentStaff.ParentInstrument.IdString}))))).slice(0,8)});", arguments: [:], in: nil, contentWorld: .page)
        print("Paged: \(paged ?? "nil")")
        if let text = paged as? String { try text.write(to: output.appendingPathComponent("render-paged.json"), atomically: true, encoding: .utf8) }
        let pagedExport = try await web.callAsyncJavaScript("const e=window.FloeEditor;const r=await e.execute({command:'score.export',arguments:{format:'pdf'},revision:e.revision});return JSON.stringify(r.artifacts);", arguments: [:], in: nil, contentWorld: .page)
        if let text = pagedExport as? String, let data = text.data(using: .utf8), let artifacts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let base64 = artifacts.first?["base64"] as? String, let bytes = Data(base64Encoded: base64) { try bytes.write(to: output.appendingPathComponent("score-multipage.pdf")) }
        _ = try await web.callAsyncJavaScript("const e=window.FloeEditor;await e.execute({command:'file.import',arguments:{name:'ensemble.musicxml',base64:value},revision:e.revision});await e.execute({command:'score.project.metadata',arguments:{title:'晨光练习',composer:'Floe 原创练习'},revision:e.revision});return e.scoreSurface.querySelectorAll('svg').length;", arguments: ["value": base64], in: nil, contentWorld: .page)
        let unicodePDF = try await web.callAsyncJavaScript("const e=window.FloeEditor;const r=await e.execute({command:'score.export',arguments:{format:'pdf'},revision:e.revision});return JSON.stringify(r.artifacts);", arguments: [:], in: nil, contentWorld: .page)
        if let text = unicodePDF as? String, let data = text.data(using: .utf8), let artifacts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let base64 = artifacts.first?["base64"] as? String, let bytes = Data(base64Encoded: base64) { try bytes.write(to: output.appendingPathComponent("score-unicode.pdf")) }
        try await snapshot(web, destination: output.appendingPathComponent("score-unicode-layout.png"))
        window.close()
        print("Score WKWebView qualification complete")
    }
    @MainActor static func snapshot(_ web: WKWebView, destination: URL) async throws {
        let image = try await web.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Snapshot encoding failed") }
        try png.write(to: destination)
    }
}

#else
@main struct ScoreWebQualification { static func main() {} }
#endif
