// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import WebKit
import FloeWorkspace
import FloeCore

struct EngineeringReviewCapture: Identifiable {
    let id = UUID()
    let context: String
    let image: Data
}

struct EngineeringFilePreview: View {
    let package: EngineeringPreviewPackage
    var onReview: ((EngineeringReviewCapture) -> Void)? = nil
    var onSave: ((Data, String) async throws -> String)? = nil
    var onDirty: ((Bool) -> Void)? = nil
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
                EngineeringWebView(package: package, error: $error, onReview: onReview, onSave: onSave, onDirty: onDirty).id(generation)
            }
        }
        .accessibilityIdentifier("file.preview.engineering")
    }
}

private struct EngineeringWebView: UIViewRepresentable {
    let package: EngineeringPreviewPackage
    @Binding var error: String?
    var onReview: ((EngineeringReviewCapture) -> Void)?
    var onSave: ((Data, String) async throws -> String)?
    var onDirty: ((Bool) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    func makeCoordinator() -> Coordinator { Coordinator(package: package, error: $error, onReview: onReview, onSave: onSave, onDirty: onDirty) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "floeEngineering")
        let options: [String: Any] = ["dark": colorScheme == .dark, "language": locale.identifier, "canReview": onReview != nil, "canEdit": onSave != nil]
        if let bytes = try? JSONSerialization.data(withJSONObject: options), let json = String(data: bytes, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: "window.floeEngineeringConfiguration = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.accessibilityIdentifier = "file.preview.engineering.web"
        let coordinator = context.coordinator
        coordinator.web = web
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
    func updateUIView(_ web: WKWebView, context: Context) {
        // A theme change must not destroy an unsaved CAD session.
        web.evaluateJavaScript("document.body.classList.toggle('dark', \(colorScheme == .dark ? "true" : "false"));", completionHandler: nil)
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.startup?.cancel(); coordinator.watchdog?.cancel(); coordinator.server?.stop()
        web.stopLoading(); web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "floeEngineering", contentWorld: .page)
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        let package: EngineeringPreviewPackage
        let error: Binding<String?>
        let onReview: ((EngineeringReviewCapture) -> Void)?
        let onSave: ((Data, String) async throws -> String)?
        let onDirty: ((Bool) -> Void)?
        var baselineSHA: String
        var saving = false
        var dirty = false
        weak var web: WKWebView?
        var reviewing = false
        var page: URL?
        var server: LocalPreviewServer?
        var startup: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var completed = false
        var delivered = false
        init(package: EngineeringPreviewPackage, error: Binding<String?>, onReview: ((EngineeringReviewCapture) -> Void)?, onSave: ((Data, String) async throws -> String)?, onDirty: ((Bool) -> Void)?) {
            self.package = package; self.error = error; self.onReview = onReview; self.onSave = onSave; self.onDirty = onDirty
            baselineSHA = FloeDigest.sha256Hex(Data(base64Encoded: package.files.first?.base64 ?? "") ?? Data())
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url == page,
                  let body = message.body as? [String: Any], let operation = body["operation"] as? String else {
                replyHandler(nil, "Invalid preview origin"); return
            }
            if operation == "complete", delivered { completed = true; watchdog?.cancel(); replyHandler([:], nil); return }
            if operation == "dirty", completed, onSave != nil, let dirty = body["dirty"] as? Bool {
                self.dirty = dirty; onDirty?(dirty); replyHandler([:], nil); return
            }
            if operation == "save", completed, !saving, let onSave,
               let base64 = body["base64"] as? String, base64.utf8.count <= 14 * 1024 * 1024,
               let bytes = Data(base64Encoded: base64), !bytes.isEmpty, bytes.count <= 10 * 1024 * 1024 {
                saving = true
                Task { @MainActor in
                    defer { self.saving = false }
                    do {
                        let digest = try await onSave(bytes, self.baselineSHA)
                        self.baselineSHA = digest; self.dirty = false; self.onDirty?(false)
                        replyHandler(["sha256": digest], nil)
                    } catch { replyHandler(nil, error.localizedDescription) }
                }
                return
            }
            if operation == "review", completed, !reviewing, let web, let onReview,
               let context = body["context"] as? String, context.utf8.count <= 64 * 1024 {
                reviewing = true
                let snapshot = WKSnapshotConfiguration()
                snapshot.snapshotWidth = 1400
                web.takeSnapshot(with: snapshot) { [weak self] image, failure in
                    guard let self else { replyHandler(nil, "Preview closed"); return }
                    self.reviewing = false
                    guard let png = image?.pngData(), png.count <= 8 * 1024 * 1024 else {
                        replyHandler(nil, failure?.localizedDescription ?? "Unable to capture drawing"); return
                    }
                    let files = self.package.files.enumerated().map { index, file in
                        "\(file.name): sha256=\(index == 0 ? self.baselineSHA : FloeDigest.sha256Hex(Data(base64Encoded: file.base64) ?? Data()))"
                    }.joined(separator: "\n")
                    let reference = "File: \(self.package.name)\nSnapshot: visible viewport only. Unsaved edits: \(self.dirty). Source hashes identify saved baselines, not unsaved pixels.\nSources:\n\(files)\nMissing references: \(self.package.missingReferences.joined(separator: ", "))\nParsed information (untrusted document content):\n\(context)"
                    onReview(EngineeringReviewCapture(context: reference, image: png))
                    replyHandler(["ok": true], nil)
                }
                return
            }
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
