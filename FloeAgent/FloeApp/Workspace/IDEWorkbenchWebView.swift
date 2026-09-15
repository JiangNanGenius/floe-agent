// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import WebKit
import FloeWorkspace

@MainActor final class IDEWorkbenchState: ObservableObject {
    @Published var dirty = false
    @Published var ready = false
    @Published var saving = false
    @Published var error: String?
    @Published var activePath: String?
    weak var web: WKWebView?
    let files: IDEWorkspaceSession?
    init(files: WorkspaceFileService?) { self.files = files.map { IDEWorkspaceSession(files: $0) } }
    func refreshDirty() async {
        guard let web, ready else { return }
        do {
            let result = try await web.callAsyncJavaScript("return window.floeIDE.hasDirty()", arguments: [:], in: nil, contentWorld: .page)
            dirty = result as? Bool ?? true
        } catch { dirty = true; self.error = error.localizedDescription }
    }
    @discardableResult func saveAll() async -> Bool {
        guard let web, ready, !saving else { return false }
        saving = true
        defer { saving = false }
        do {
            let saved = try await web.callAsyncJavaScript("return await window.floeIDE.saveAll()", arguments: [:], in: nil, contentWorld: .page)
            guard saved as? Bool == true else { error = String(localized: "ide.save.failed"); return false }
            dirty = false
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct IDEWorkbenchWebView: UIViewRepresentable {
    @ObservedObject var state: IDEWorkbenchState
    var initialPath: String?
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "floeIDE")
        let options: [String: Any] = ["initialPath": initialPath ?? "", "dark": colorScheme == .dark, "language": Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-CN" : "en-US"]
        if let json = try? JSONSerialization.data(withJSONObject: options), let source = String(data: json, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: "window.floeIDEConfiguration = \(source);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        state.web = web
        web.navigationDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false
        web.accessibilityIdentifier = "workspace.ide.workbench"
        if let root = Bundle.main.url(forResource: "IDE", withExtension: nil) {
            context.coordinator.startup = Task { @MainActor [weak web] in
                do {
                    let (server, session) = try await LocalPreviewServer.start(root: root, entry: "index.html")
                    guard !Task.isCancelled, let web else { server.stop(); return }
                    context.coordinator.server = server
                    context.coordinator.page = session.url
                    web.load(URLRequest(url: session.url))
                } catch { if !Task.isCancelled { state.error = error.localizedDescription } }
            }
        } else { state.error = String(localized: "ide.resources.missing") }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.startup?.cancel(); coordinator.server?.stop()
        web.stopLoading(); web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "floeIDE", contentWorld: .page)
        let files = coordinator.state.files
        Task { await files?.close() }
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        let state: IDEWorkbenchState
        var page: URL?
        var server: LocalPreviewServer?
        var startup: Task<Void, Never>?
        init(state: IDEWorkbenchState) { self.state = state }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.request.url == page,
                  let body = message.body as? [String: Any], let operation = body["operation"] as? String else {
                replyHandler(nil, "Invalid IDE request origin"); return
            }
            switch operation {
            case "ready": state.ready = true; replyHandler([:], nil)
            case "dirty": state.dirty = body["dirty"] as? Bool == true; replyHandler([:], nil)
            case "active":
                if let path = body["path"] as? String, let relative = try? IDEWorkspaceSession.relativePath(path) {
                    state.activePath = relative
                } else { state.activePath = nil }
                replyHandler([:], nil)
            case "saved": replyHandler([:], nil)
            case "failed": state.error = body["message"] as? String; replyHandler([:], nil)
            default:
                guard let data = try? JSONSerialization.data(withJSONObject: body),
                      let request = try? JSONDecoder().decode(IDEWorkspaceSession.Request.self, from: data) else {
                    replyHandler(nil, "Invalid IDE request"); return
                }
                Task {
                    do {
                        guard let files = state.files else { throw WorkspaceToolError.invalidArguments("Workspace unavailable") }
                        let result = try await files.handle(request)
                        let encoded = try JSONEncoder().encode(result)
                        replyHandler(try JSONSerialization.jsonObject(with: encoded), nil)
                    } catch {
                        let code: String
                        if let workspaceError = error as? WorkspaceToolError {
                            switch workspaceError {
                            case .notFound: code = "ENOENT"
                            case .alreadyExists, .alreadyExistsOverwritable: code = "EEXIST"
                            case .conflict: code = "EBUSY"
                            case .escapesRoot, .secretFile: code = "EACCES"
                            case .tooLarge: code = "EFBIG"
                            case .isDirectory: code = "EISDIR"
                            default: code = "EINVAL"
                            }
                        } else if (error as NSError).code == NSFileNoSuchFileError || (error as NSError).code == NSFileReadNoSuchFileError {
                            code = "ENOENT"
                        } else { code = "EIO" }
                        replyHandler(["error": ["code": code, "message": error.localizedDescription]], nil)
                    }
                }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url == page ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            state.ready = false
            state.error = String(localized: "ide.process.stopped")
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { state.error = error.localizedDescription }
    }
}
#endif
