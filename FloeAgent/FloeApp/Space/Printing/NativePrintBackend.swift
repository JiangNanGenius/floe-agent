// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
@preconcurrency import WebKit
import FloePrintCore

enum NativePrintError: Error, LocalizedError {
    case unavailable, invalidTransfer, engine(String), timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: IDELanguageRunText.t("切片组件暂时无法启动。", "The slicer could not start.")
        case .invalidTransfer: IDELanguageRunText.t("切片结果不完整，未保存。", "The slicing result is incomplete and was not saved.")
        case .engine(let detail): detail
        case .timedOut: IDELanguageRunText.t("切片时间过长，请减少模型复杂度后重试。", "Slicing took too long. Simplify the model and try again.")
        }
    }
}

/// Only the typed, pinned print adapter is callable. Each job owns a fresh
/// offline WebKit realm; no user-authored script or network URL enters it.
@MainActor final class NativePrintBackend: PrintSlicingBackend {
    private var active: PrintJobRealm?
    private var currentJob: UUID?
    private var cancelled = false

    func slice(_ request: PrintRequest,
               progress: @escaping @Sendable (PrintProgress) async -> Void) async throws -> Data {
        guard currentJob == nil else { throw PrintError.busy }
        try Task.checkCancellation()
        currentJob = request.identity.jobID
        cancelled = false
        defer { currentJob = nil; cancelled = false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floe-print-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mesh = directory.appendingPathComponent("mesh.bin")
        try await Task.detached(priority: .userInitiated) {
            let bytes = request.input.mesh.positions.withUnsafeBytes { Data($0) }
            try bytes.write(to: mesh, options: .atomic)
        }.value
        try Task.checkCancellation()
        guard !cancelled else { throw PrintError.cancelled }
        let realm = try PrintJobRealm(request: request, meshFile: mesh, progress: progress)
        active = realm
        defer { if active === realm { active = nil }; realm.retire() }
        return try await realm.run()
    }

    func cancel(jobID: UUID) async {
        guard currentJob == jobID else { return }
        cancelled = true
        active?.finish(.failure(PrintError.cancelled))
    }
}

@MainActor private final class PrintJobRealm: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate {
    let request: PrintRequest
    private let meshFile: URL
    private let runtime: URL
    private let engine: URL
    private let progress: @Sendable (PrintProgress) async -> Void
    private let token = UUID().uuidString
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeout: Task<Void, Never>?
    private var bytes = Data()
    private var declaredSize: Int?
    private var sequence = 0
    private var ended = false
    private static let byteLimit = 128 * 1_024 * 1_024

    init(request: PrintRequest, meshFile: URL, progress: @escaping @Sendable (PrintProgress) async -> Void) throws {
        guard let runtime = Bundle.main.url(forResource: "Printing", withExtension: nil),
              let engine = Bundle.main.url(forResource: "KiriMoto", withExtension: nil) else { throw NativePrintError.unavailable }
        self.request = request; self.meshFile = meshFile; self.runtime = runtime; self.engine = engine
        self.progress = progress
        super.init()
    }

    func run() async throws -> Data {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.processPool = WKProcessPool()
        config.setURLSchemeHandler(self, forURLScheme: "floe-print")
        config.userContentController.add(self, name: "floePrint")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        webView = view
        let settings: [String: Any] = [
            "token": token, "requestID": request.identity.jobID.uuidString,
            "kind": request.input.preset == .genericMarlinPLA ? "fdm" : "sla",
            "overrides": request.input.overrides, "limit": Self.byteLimit
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), as: UTF8.self)
        let html = """
        <!doctype html><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src floe-print: 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'; connect-src floe-print:">
        <script type="module">
        import {createPrintHost,createSettings,sliceFDM,sliceSLA} from 'floe-print://host/floe-print-host.js';
        const config=\(json);
        const read=globalThis.fetch.bind(globalThis);
        const post=(kind,values={})=>webkit.messageHandlers.floePrint.postMessage({token:config.token,kind,...values});
        try {
          const mesh=new Float32Array(await (await read('floe-print://job/mesh.bin')).arrayBuffer());
          const host=await createPrintHost({engineRoot:'floe-print://engine/src/',
            wasmResolver:async name=>await (await read('floe-print://engine/src/wasm/'+name)).arrayBuffer()});
          const slice=config.kind==='fdm'?sliceFDM:sliceSLA;
          const result=await slice(host,{requestId:config.requestID,mesh:{positions:mesh},
            settings:createSettings(config.kind,config.overrides),
            onProgress:p=>post('progress',{stage:String(p.stage||''),fraction:Number(p.value)||0})});
          const output=config.kind==='fdm'?new TextEncoder().encode(result.text):new Uint8Array(result.file);
          if(!output.length||output.length>config.limit)throw new Error('Slicing output exceeds the supported size.');
          post('begin',{size:output.length});
          let sequence=0;
          for(let offset=0;offset<output.length;offset+=49152){
            const chunk=output.subarray(offset,Math.min(output.length,offset+49152));
            post('chunk',{sequence:sequence++,data:btoa(String.fromCharCode(...chunk))});
          }
          post('complete');
        } catch(error){post('error',{message:String(error?.message||error)});}
        </script>
        """
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(900))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(NativePrintError.timedOut))
            }
            view.loadHTMLString(html, baseURL: URL(string: "floe-print://host/index.html"))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !ended, let body = message.body as? [String: Any], body["token"] as? String == token,
              let kind = body["kind"] as? String else { return }
        switch kind {
        case "progress":
            let update = PrintProgress(identity: request.identity, stage: body["stage"] as? String ?? "",
                                       fraction: body["fraction"] as? Double ?? 0)
            let progress = self.progress
            Task { await progress(update) }
        case "begin":
            guard declaredSize == nil, let size = body["size"] as? Int, size > 0, size <= Self.byteLimit else {
                finish(.failure(NativePrintError.invalidTransfer)); return
            }
            declaredSize = size; bytes.reserveCapacity(size)
        case "chunk":
            guard let declaredSize, body["sequence"] as? Int == sequence,
                  let encoded = body["data"] as? String, encoded.utf8.count <= 65_536,
                  let chunk = Data(base64Encoded: encoded), !chunk.isEmpty,
                  bytes.count + chunk.count <= declaredSize else { finish(.failure(NativePrintError.invalidTransfer)); return }
            bytes.append(chunk); sequence += 1
        case "complete":
            guard let declaredSize, bytes.count == declaredSize else { finish(.failure(NativePrintError.invalidTransfer)); return }
            finish(.success(bytes))
        case "error":
            finish(.failure(NativePrintError.engine(String((body["message"] as? String ?? "Slicing failed.").prefix(2_048)))))
        default:
            finish(.failure(NativePrintError.invalidTransfer))
        }
    }

    func finish(_ result: Result<Data, Error>) {
        guard !ended else { return }
        ended = true; timeout?.cancel(); timeout = nil
        let continuation = self.continuation; self.continuation = nil
        retire()
        continuation?.resume(with: result)
    }

    func retire() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "floePrint")
        webView?.navigationDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(NativePrintError.unavailable)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(scheme == "floe-print" || scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            guard !ended, let url = urlSchemeTask.request.url, url.query == nil, url.fragment == nil else { throw NativePrintError.unavailable }
            let file: URL
            if url.host == "job", url.path == "/mesh.bin" {
                file = meshFile
            } else {
                let base: URL
                switch url.host {
                case "host": base = runtime
                case "engine": base = engine
                default: throw NativePrintError.unavailable
                }
                file = base.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL.resolvingSymlinksInPath()
                guard file.path.hasPrefix(base.resolvingSymlinksInPath().path + "/") else { throw NativePrintError.unavailable }
            }
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize, size <= 40 * 1_024 * 1_024 else { throw NativePrintError.unavailable }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let mime: String
            switch file.pathExtension { case "js": mime = "text/javascript"; case "wasm": mime = "application/wasm"; default: mime = "application/octet-stream" }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"])!
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
#endif
