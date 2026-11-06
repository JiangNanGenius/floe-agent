// SPDX-License-Identifier: MPL-2.0
import Foundation
import UIKit
import WebKit
import FloeCAD
import FloeCore

nonisolated enum CADNativeRenderError: Error, LocalizedError {
    case unavailable, interrupted, invalidResult, busy
    case engine(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: CADOfflineRenderText.t("请保持 Floe 在前台，并重试本机渲染。", "Keep Floe in the foreground and try the local render again.")
        case .interrupted: CADOfflineRenderText.t("本次渲染已中断，输入已保留，可重新开始。", "Rendering was interrupted. Its input is preserved; start a new render.")
        case .invalidResult: CADOfflineRenderText.t("渲染器未返回完整图像，请重试或减小尺寸。", "The renderer did not return a complete image. Try again or choose a smaller size.")
        case .busy: CADOfflineRenderText.t("已有本机渲染正在进行，请先完成或取消。", "Finish or cancel the current local render first.")
        case .engine(let detail): detail
        }
    }
}

nonisolated enum CADNativeRenderResources {
    static func files(bundle: Bundle = .main) throws -> [String: Data] {
        guard let root = bundle.url(forResource: "CADNativeRender", withExtension: nil),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any],
              manifest["backend"] as? String == CADNativeSceneExporter.backendID,
              manifest["revision"] as? String == CADNativeSceneExporter.backendRevision,
              let hashes = manifest["files"] as? [String: String], Set(hashes.keys) == ["index.html", "engine.js"] else { throw CADNativeRenderError.unavailable }
        var result: [String: Data] = [:]
        for (name, expected) in hashes {
            let bytes = try Data(contentsOf: root.appendingPathComponent(name))
            guard !bytes.isEmpty, bytes.count <= 4 * 1024 * 1024, FloeDigest.sha256Hex(bytes) == expected else { throw CADNativeRenderError.unavailable }
            result[name] = bytes
        }
        return result
    }
}

private final class CADNativeRenderScheme: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    let files: [String: Data]
    init(files: [String: Data]) { self.files = files }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == "floe-cad-render", url.host == "render",
              let bytes = files[String(url.path.dropFirst())] else {
            task.didFailWithError(CADNativeRenderError.unavailable); return
        }
        let mime = url.path.hasSuffix(".html") ? "text/html" : "text/javascript"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: "utf-8"))
        task.didReceive(bytes); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Owns one local WebGL2 path tracer. No document text is evaluated as code;
/// frozen JSON and completed PNG cross WebKit in bounded, acknowledged chunks.
@MainActor
final class CADNativeRenderHost: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    nonisolated struct Output: Sendable { var png: Data; var samples: Int }
    private let input: Data
    private let settings: CADOfflineRenderSettings
    private let session = UUID().uuidString
    private let progress: @MainActor (Int) -> Void
    private var web: WKWebView?
    private var container: UIView?
    private var continuation: CheckedContinuation<Output, Error>?
    private var transfer: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private var active = false
    private var sentInput = false
    private var png = Data()
    private var expectedBytes: Int?
    private var nextChunk = 0
    private var samples = 0

    init(input: Data, settings: CADOfflineRenderSettings, progress: @escaping @MainActor (Int) -> Void) {
        self.input = input; self.settings = settings; self.progress = progress
    }
    func render() async throws -> Output {
        try settings.validate(); try Task.checkCancellation()
        guard !input.isEmpty, input.count <= CADNativeSceneExporter.maximumPackageBytes else { throw CADOfflineRenderError.tooLarge }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; active = true
                do { try begin() } catch { finish(.failure(error)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    private func begin() throws {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow }) else { throw CADNativeRenderError.unavailable }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(CADNativeRenderScheme(files: try CADNativeRenderResources.files()), forURLScheme: "floe-cad-render")
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "cadNativeRender")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        view.navigationDelegate = self; view.isUserInteractionEnabled = false; view.isOpaque = false
        // A real foreground-owned WebKit surface keeps the local GPU context
        // alive. Output is the accumulated WebGL canvas, never a UIKit snapshot.
        let holder = UIView(frame: view.frame); holder.isUserInteractionEnabled = false; holder.alpha = 0.01
        holder.addSubview(view); window.addSubview(holder); web = view; container = holder
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(.failure(CADNativeRenderError.interrupted)) }
        }
        view.load(URLRequest(url: URL(string: "floe-cad-render://render/index.html?session=\(session)")!))
    }
    func cancel() { finish(.failure(CancellationError())) }
    func release() {
        transfer?.cancel(); transfer = nil
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }; backgroundObserver = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "cadNativeRender", contentWorld: .page)
        web?.navigationDelegate = nil; web?.stopLoading(); web?.removeFromSuperview(); web = nil
        container?.removeFromSuperview(); container = nil
    }
    private func finish(_ result: Result<Output, Error>) {
        guard active else { return }; active = false
        let pending = continuation; continuation = nil; release(); pending?.resume(with: result)
    }
    private func sendInput() {
        guard !sentInput else { return }; sentInput = true
        transfer = Task { [weak self] in
            guard let self else { return }
            do {
                let size = 128 * 1024
                for offset in stride(from: 0, to: input.count, by: size) {
                    try Task.checkCancellation()
                    guard active, let web else { throw CancellationError() }
                    let end = min(offset + size, input.count)
                    _ = try await web.callAsyncJavaScript("return window.FloeCADNativeRender.appendInput(chunk, index, final);",
                        arguments: ["chunk": input.subdata(in: offset..<end).base64EncodedString(), "index": offset / size, "final": end == input.count],
                        in: nil, contentWorld: .page)
                }
            } catch { finish(.failure(error)) }
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard active, message.webView === web, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == "floe-cad-render", message.frameInfo.request.url?.host == "render",
              let object = message.body as? [String: Any], object["session"] as? String == session,
              let kind = object["kind"] as? String else { replyHandler(nil, "Invalid render session"); return }
        switch kind {
        case "ready":
            guard object["backend"] as? String == CADNativeSceneExporter.backendID,
                  object["revision"] as? String == CADNativeSceneExporter.backendRevision else { replyHandler(nil, "Invalid renderer"); finish(.failure(CADNativeRenderError.invalidResult)); return }
            replyHandler(true, nil); sendInput()
        case "progress":
            if let count = object["samples"] as? Int, count >= 0, count <= settings.quality.samples + 1 { progress(count) }
            replyHandler(true, nil)
        case "pngBegin":
            guard expectedBytes == nil, let count = object["byteCount"] as? Int, (1...(64*1024*1024)).contains(count),
                  let actualSamples = object["samples"] as? Int, actualSamples >= settings.quality.samples,
                  object["backend"] as? String == CADNativeSceneExporter.backendID,
                  object["revision"] as? String == CADNativeSceneExporter.backendRevision else { replyHandler(nil, "Incomplete render"); finish(.failure(CADNativeRenderError.invalidResult)); return }
            expectedBytes = count; samples = actualSamples; png.reserveCapacity(count); replyHandler(true, nil)
        case "pngChunk":
            guard let expectedBytes, object["index"] as? Int == nextChunk,
                  let text = object["data"] as? String, !text.isEmpty, text.utf8.count <= 196608,
                  let data = Data(base64Encoded: text), !data.isEmpty, png.count + data.count <= expectedBytes else { replyHandler(nil, "Invalid PNG chunk"); finish(.failure(CADNativeRenderError.invalidResult)); return }
            png.append(data); nextChunk += 1; replyHandler(true, nil)
        case "complete":
            guard let expectedBytes, png.count == expectedBytes, samples >= settings.quality.samples,
                  object["samples"] as? Int == samples, object["backend"] as? String == CADNativeSceneExporter.backendID,
                  object["revision"] as? String == CADNativeSceneExporter.backendRevision else { replyHandler(nil, "Incomplete PNG"); finish(.failure(CADNativeRenderError.invalidResult)); return }
            replyHandler(true, nil); finish(.success(Output(png: png, samples: samples)))
        case "error":
            replyHandler(true, nil); finish(.failure(CADNativeRenderError.engine(String((object["message"] as? String ?? "Local rendering failed.").prefix(1000)))))
        default: replyHandler(nil, "Unknown render event")
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        decisionHandler(url?.scheme == "floe-cad-render" && url?.host == "render" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(CADNativeRenderError.interrupted)) }
}
