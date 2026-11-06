import Foundation
import WebKit

/// Offscreen, offline Indigo chemistry operations for a native editor. This object
/// exposes data operations only; the WKWebView is never placed in the user interface.
@MainActor public final class ChemistryStructureProcessor: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let handler: ProcessorMessageHandler
    private var ready = false
    private var failure: String?
    private var tail: Task<Void,Never>?
    public override init() {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(SketchAssets(),forURLScheme:"floechem")
        handler = ProcessorMessageHandler()
        config.userContentController.add(handler,name:"processor")
        config.userContentController.addUserScript(WKUserScript(source:"""
        (() => { const began=Date.now(); const timer=setInterval(() => {
          if(window.ketcher && window.ketcher.indigo) {clearInterval(timer);window.webkit.messageHandlers.processor.postMessage('ready');}
          else if(Date.now()-began>60000) {clearInterval(timer);window.webkit.messageHandlers.processor.postMessage('timeout');}
        },100); })();
        """,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        web = WKWebView(frame:CGRect(x:0,y:0,width:1024,height:768),configuration:config)
        super.init(); handler.target = self; web.navigationDelegate = self
        web.load(URLRequest(url:URL(string:"floechem://editor/index.html?hiddenControls=open,save")!))
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == "floechem", message.frameInfo.request.url?.host == "editor", let state = message.body as? String else { return }
        if state == "ready" { ready = true } else { failure = "The offline chemistry processor did not finish loading." }
    }
    public func evaluate(_ source: String, layout: Bool = false) async throws -> ChemistrySketchSnapshot {
        guard source.utf8.count <= 16 * 1024 * 1024 else { throw ProcessorError.failed("Structure exceeds the input limit.") }
        let prior = tail
        let work = Task { @MainActor [self] in
            if let prior { await prior.value }
            for _ in 0..<1200 {
                try Task.checkCancellation()
                if ready || failure != nil { break }
                try await Task.sleep(for:.milliseconds(50))
            }
            if let failure { throw ProcessorError.failed(failure) }
            guard ready else { throw ProcessorError.failed("The offline chemistry processor is unavailable.") }
            let script = """
            const k = window.ketcher;
            let input = source;
            if (layout) {
              const result = await k.structService.layout({struct:source,output_format:'chemical/x-indigo-ket'});
              input = result.struct;
            }
            await k.setMolecule(input,{preserveCanvasPosition:true});
            const ket = await k.getKet();
            let format=null, data=null, smiles=null, properties=null;
            try { if(k.containsReaction()){format='rxn';data=await k.getRxn('v3000');}
                  else{format='mol';data=await k.getMolfile('v3000');} } catch(_){}
            try { smiles=await k.getSmiles(); } catch(_){}
            try { properties=await k.indigo.calculate(ket,{properties:['gross','molecular-weight']}); } catch(_){}
            return JSON.stringify({ket,format,source:data,smiles,properties});
            """
            let raw = try await web.callAsyncJavaScript(script,arguments:["source":source,"layout":layout],in:nil,contentWorld:.page)
            try Task.checkCancellation()
            guard let text = raw as? String, text.utf8.count <= 40 * 1024 * 1024 else { throw ProcessorError.failed("Invalid chemistry processor output.") }
            return try JSONDecoder().decode(ProcessorResult.self,from:Data(text.utf8)).snapshot()
        }
        tail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.request.url?.scheme == "floechem", navigationAction.request.url?.host == "editor", navigationAction.targetFrame?.isMainFrame == true else { return .cancel }; return .allow
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; failure = "The offline chemistry processor stopped. Reopen the project to restart it." }
    public func webView(_ webView: WKWebView,didFail navigation:WKNavigation!,withError error:any Error) { failure = error.localizedDescription }
}
private enum ProcessorError: LocalizedError { case failed(String); var errorDescription: String? { switch self { case .failed(let text): text } } }
private struct ProcessorResult: Decodable {
    var ket:String; var format:String?; var source:String?; var smiles:String?; var properties:[String:String]?
    func snapshot() throws -> ChemistrySketchSnapshot {
        guard ket.utf8.count <= 16 * 1024 * 1024, (source?.utf8.count ?? 0) <= 16 * 1024 * 1024,
              (smiles?.utf8.count ?? 0) <= 1024 * 1024, (properties?.count ?? 0) <= 16,
              properties?.values.allSatisfy({$0.utf8.count <= 4096}) ?? true else { throw ProcessorError.failed("Chemistry output exceeds its limit.") }
        return ChemistrySketchSnapshot(ket:ket,format:format,source:source,smiles:smiles,properties:properties)
    }
}
@MainActor private final class ProcessorMessageHandler: NSObject,WKScriptMessageHandler {
    weak var target:ChemistryStructureProcessor?
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) { target?.receive(message) }
}
