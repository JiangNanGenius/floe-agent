// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import WebKit
import FloeNotes

struct NoteMindMapView: UIViewRepresentable {
    let document: NoteDocument
    let onEdit: @MainActor ([NoteEdit], Int) async throws -> NoteDocument
    let onHistory: @MainActor (Bool) -> Void
    let onError: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "floeNotes")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.scrollView.isScrollEnabled = false
        web.accessibilityIdentifier = "notes.mindmap"
        context.coordinator.web = web
        if let root = Bundle.main.url(forResource: "MindElixir", withExtension: nil),
           FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) {
            context.coordinator.root = root
            web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        } else { onError("导图编辑资源缺失。") }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render()
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "floeNotes")
        web.stopLoading(); web.navigationDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: NoteMindMapView
        weak var web: WKWebView?
        var root: URL?
        var ready = false
        var lastRender = ""
        var committedDocument: NoteDocument?
        init(parent: NoteMindMapView) { self.parent = parent }
        func render(force: Bool = false) {
            guard ready, let web else { return }
            let document = committedDocument.flatMap { $0.id == parent.document.id && $0.revision > parent.document.revision ? $0 : nil } ?? parent.document
            let signature = "\(document.id):\(document.revision):\(parent.colorScheme)"
            guard force || signature != lastRender else { return }
            do {
                let data = try JSONEncoder().encode(document)
                let object = try JSONSerialization.jsonObject(with: data)
                lastRender = signature
                let payload: [String: Any] = ["document": object, "dark": parent.colorScheme == .dark]
                Task { @MainActor [weak self, weak web] in
                    guard let web else { return }
                    do {
                        _ = try await web.callAsyncJavaScript("window.floeRender(payload)", arguments: ["payload": payload], in: nil, contentWorld: .page)
                    } catch { self?.parent.onError(error.localizedDescription) }
                }
            } catch { parent.onError(error.localizedDescription) }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" { ready = true; render(force: true); return }
            if type == "error" { parent.onError(body["message"] as? String ?? "导图运行错误。"); return }
            guard let id = body["documentID"] as? String, UUID(uuidString: id) == parent.document.id,
                  let revision = body["revision"] as? Int, revision == parent.document.revision else { render(force: true); return }
            if type == "undo" || type == "redo" { parent.onHistory(type == "redo"); return }
            guard type == "edit" else { return }
            do {
                let nodes = try JSONDecoder().decode([MindMapNode].self, from: JSONSerialization.data(withJSONObject: body["nodes"] ?? []))
                let edges = try JSONDecoder().decode([MindMapConnection].self, from: JSONSerialization.data(withJSONObject: body["connections"] ?? []))
                let summaries = try JSONDecoder().decode([MindMapSummary].self, from: JSONSerialization.data(withJSONObject: body["summaries"] ?? []))
                let direction = body["direction"] as? Int ?? 2
                var proposal = parent.document; proposal.nodes = nodes; proposal.connections = edges
                proposal.summaries = summaries; proposal.mindMapDirection = direction
                try proposal.validate()
                let edit = parent.onEdit
                Task { [weak self] in
                    do {
                        let committed = try await edit([.replaceMindMap(nodes: nodes, connections: edges), .mindMapLayout(direction: direction, summaries: summaries)], revision)
                        guard let self, self.parent.document.id == committed.id else { return }
                        self.committedDocument = committed
                        self.render(force: true)
                    } catch { self?.parent.onError(error.localizedDescription); self?.render(force: true) }
                }
            } catch { parent.onError(error.localizedDescription); render(force: true) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, let root,
                  url.isFileURL, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false; lastRender = ""
            parent.onError("导图编辑进程已结束，正在恢复已保存的内容。")
            webView.reload()
        }
    }
}
#endif
