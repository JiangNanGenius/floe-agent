// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import WebKit
import FloeWorkspace

@MainActor final class IDEWorkbenchState: ObservableObject {
    @Published var dirty = false
    @Published var ready = false
    @Published var saving = false
    @Published var conflict: WorkspaceEditConflict?
    @Published var error: String?
    @Published var activePath: String?
    /// A non-text path the workbench refused (ENOTSUP). The native IDE opens
    /// it in its typed surface instead of showing a decode failure.
    @Published var pendingNativePath: String?
    /// Native-document overlay requests reported by the web workbench's
    /// custom document component (PDF/Office internal tabs). Keyed by the
    /// workspace-relative path; each entry carries the last reported rect
    /// (web-view points) and whether its internal tab is visible.
    @Published private(set) var nativeDocuments: [String: IDENativeDocumentRequest] = [:]
    weak var web: WKWebView?
    let files: IDEWorkspaceSession?
    init(files: WorkspaceFileService?) { self.files = files.map { IDEWorkspaceSession(files: $0) } }

    struct IDENativeDocumentRequest: Equatable {
        let path: String
        let kind: IDENativeDocumentKind
        var rect: CGRect
        var visible: Bool
    }
    enum IDENativeDocumentKind: String, Equatable {
        case pdf
        case office
    }

    /// Opens a workspace-relative PDF/Office path as an internal CodeBlitz
    /// editor tab. Text routing is untouched; other kinds stay refused here
    /// so their native surfaces keep their existing routing.
    func openNativeDocument(_ path: String) async {
        guard ready, let web, !nativeDocuments.keys.contains(path) else { return }
        _ = try? await web.callAsyncJavaScript(
            "return await window.floeIDE.openDocument(path)",
            arguments: ["path": "/" + path], in: nil, contentWorld: .page)
    }

    private func applyNativeDocumentMessage(_ body: [String: Any]) {
        guard let path = body["path"] as? String,
              let relative = try? IDEWorkspaceSession.relativePath(path) else { return }
        if body["phase"] as? String == "unmount" {
            nativeDocuments.removeValue(forKey: relative)
            return
        }
        guard let rectBody = body["rect"] as? [String: Any],
              let x = rectBody["x"] as? CGFloat, let y = rectBody["y"] as? CGFloat,
              let width = rectBody["width"] as? CGFloat, let height = rectBody["height"] as? CGFloat,
              let rawKind = body["kind"] as? String, let kind = IDENativeDocumentKind(rawValue: rawKind)
        else { return }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        let visible = rect.width > 1 && rect.height > 1
        nativeDocuments[relative] = IDENativeDocumentRequest(path: relative, kind: kind, rect: rect, visible: visible)
    }

    /// The web content process is gone: every overlay request it reported
    /// is stale and must not leave native surfaces floating.
    func webContentProcessTerminated() {
        ready = false
        nativeDocuments.removeAll()
    }
    func resolve(_ review: WorkspaceEditConflict, content: String) async {
        guard let web, let files, ready else { return }
        do {
            let applied = try await web.callAsyncJavaScript(
                "return await window.floeIDE.applyResolution(path, draft, content)",
                arguments: ["path": "/" + review.path, "draft": review.draft, "content": content], in: nil, contentWorld: .page)
            guard applied as? Bool == true else { error = String(localized: "edit.conflict.draftChanged"); return }
            dirty = true
            do { try await files.rebase(review) }
            catch {
                conflict = try await files.conflict(path: "/" + review.path, draft: content, base: review.current)
                return
            }
            conflict = nil
            _ = await saveAll()
        } catch { self.error = error.localizedDescription }
    }
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
    /// Native UI-test text entry: XCTest keystrokes never reach Monaco's hidden
    /// textarea, Monaco suppresses the system edit menu, and the simulator
    /// pasteboard is not shared with the test runner. The action generates and
    /// publishes the marker it inserted so the test can verify cold readback.
    @Published var lastInsertResult: String?
    @discardableResult func insertTextForTesting(path: String, text: String) async -> Bool {
        guard let web, ready else { lastInsertResult = "not-ready"; return false }
        let payload = text.isEmpty ? "saved-" + UUID().uuidString.prefix(8) : text
        do {
            let inserted = try await web.callAsyncJavaScript(
                "return await window.floeIDE.insertText(path, text)",
                arguments: ["path": "/" + path, "text": payload], in: nil, contentWorld: .page)
            guard inserted as? Bool == true else { lastInsertResult = "rejected"; return false }
            let current = try await web.callAsyncJavaScript(
                "return await window.floeIDE.getText(path)",
                arguments: ["path": "/" + path], in: nil, contentWorld: .page)
            let found = (current as? String)?.contains(payload) ?? false
            lastInsertResult = found ? "inserted:\(payload)" : "missing-after-insert"
            return found
        } catch { self.error = error.localizedDescription; lastInsertResult = "error"; return false }
    }
}

struct IDEWorkbenchWebView: UIViewRepresentable {
    @ObservedObject var state: IDEWorkbenchState
    var initialPath: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "floeIDE")
        let options: [String: Any] = ["initialPath": initialPath ?? "", "dark": colorScheme == .dark, "language": locale.identifier.hasPrefix("zh") ? "zh-CN" : "en-US"]
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
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
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
            case "routing":
                // The browser filesystem refused a non-text path. Route it to
                // the native surface rather than retrying it as text.
                if let path = body["path"] as? String, let relative = try? IDEWorkspaceSession.relativePath(path),
                   WorkspaceFileRouter.destination(for: relative) != .codeEditor {
                    state.pendingNativePath = relative
                }
                replyHandler([:], nil)
            case "nativeDocument":
                // The custom document component reports mount/rect/unmount
                // for PDF/Office internal tabs; the native overlay follows.
                state.applyNativeDocumentMessage(body)
                replyHandler([:], nil)
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
                            case .unsupportedContent: code = "ENOTSUP"
                            default: code = "EINVAL"
                            }
                        } else if (error as NSError).code == NSFileNoSuchFileError || (error as NSError).code == NSFileReadNoSuchFileError {
                            code = "ENOENT"
                        } else { code = "EIO" }
                        if code == "EBUSY", request.operation == "write",
                           let bytes = request.contentBase64.flatMap({ Data(base64Encoded: $0) }),
                           let draft = String(data: bytes, encoding: .utf8), let files = state.files {
                            do {
                                state.conflict = try await files.conflict(path: request.path, draft: draft)
                            } catch { state.error = error.localizedDescription }
                        }
                        replyHandler(["error": ["code": code, "message": error.localizedDescription]], nil)
                    }
                }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url == page ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            state.error = String(localized: "ide.process.stopped")
            state.webContentProcessTerminated()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { state.error = error.localizedDescription }
    }
}
#endif
