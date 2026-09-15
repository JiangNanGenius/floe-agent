// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import WebKit
import FloeWorkspace

struct EngineeringFilePreview: View {
    let package: EngineeringPreviewPackage
    @Environment(\.colorScheme) private var colorScheme
    @State private var error: String?
    @State private var generation = UUID()

    var body: some View {
        Group {
            if package.kind == .unsupported {
                ContentUnavailableView {
                    Label("engineering.unsupported.title", systemImage: "doc.viewfinder")
                } description: {
                    Text("engineering.unsupported.description")
                }
            } else if let error {
                ContentUnavailableView {
                    Label("engineering.failed", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("engineering.retry") { self.error = nil; generation = UUID() }
                }
            } else {
                EngineeringWebView(package: package, error: $error).id("\(generation)-\(colorScheme)")
            }
        }
        .accessibilityIdentifier("file.preview.engineering")
    }
}

private struct EngineeringWebView: UIViewRepresentable {
    let package: EngineeringPreviewPackage
    @Binding var error: String?
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(package: package, error: $error) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "floeEngineering")
        let options: [String: Any] = ["dark": colorScheme == .dark, "language": Locale.preferredLanguages.first ?? "en"]
        if let bytes = try? JSONSerialization.data(withJSONObject: options), let json = String(data: bytes, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: "window.floeEngineeringConfiguration = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.accessibilityIdentifier = "file.preview.engineering.web"
        let coordinator = context.coordinator
        coordinator.startup = Task { @MainActor [weak web] in
            do {
                guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let (server, session) = try await LocalPreviewServer.start(root: root, entry: "index.html")
                guard !Task.isCancelled, let web else { server.stop(); return }
                coordinator.server = server
                coordinator.page = session.url
                web.load(URLRequest(url: session.url))
            } catch { if !Task.isCancelled { coordinator.error.wrappedValue = error.localizedDescription } }
        }
        // Native watchdog also works when a malformed model stalls JavaScript.
        coordinator.watchdog = Task { @MainActor [weak web] in
            do {
                try await Task.sleep(for: .seconds(65))
                guard !Task.isCancelled, let web else { return }
                // Do not wait on a potentially stuck web process to decide timeout.
                if !coordinator.completed {
                    web.stopLoading()
                    coordinator.error.wrappedValue = String(localized: "engineering.timeout")
                }
            } catch {}
        }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.startup?.cancel(); coordinator.watchdog?.cancel(); coordinator.server?.stop()
        web.stopLoading(); web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "floeEngineering", contentWorld: .page)
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        let package: EngineeringPreviewPackage
        let error: Binding<String?>
        var page: URL?
        var server: LocalPreviewServer?
        var startup: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var completed = false
        var delivered = false
        init(package: EngineeringPreviewPackage, error: Binding<String?>) { self.package = package; self.error = error }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url == page,
                  let body = message.body as? [String: Any], let operation = body["operation"] as? String else {
                replyHandler(nil, "Invalid preview origin"); return
            }
            if operation == "complete", delivered { completed = true; watchdog?.cancel(); replyHandler([:], nil); return }
            guard operation == "load", !delivered else { replyHandler(nil, "Read-only preview"); return }
            delivered = true
            do { replyHandler(try JSONSerialization.jsonObject(with: JSONEncoder().encode(package)), nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url == page ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error.wrappedValue = String(localized: "engineering.processStopped") }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error.wrappedValue = error.localizedDescription }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error.wrappedValue = error.localizedDescription }
    }
}
#endif
