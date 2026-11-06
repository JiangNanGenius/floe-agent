// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import WebKit
import FloeInteractiveContentCore

@MainActor
public final class InteractiveWebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    public let webView: WKWebView
    public let document: InteractiveDocument
    public let session: InteractiveSession
    @Published public private(set) var isReady = false
    @Published public private(set) var failed = false
    @Published public private(set) var hasUnsavedChanges = false
    @Published public private(set) var contentHeight: CGFloat = 360
    @Published public private(set) var blockedNavigations = 0
    public var onStateChange: (@MainActor (InteractiveState) -> Void)?
    private var generation: UInt64 = 0
    private var loadedLease: UUID?
    var bridgeDiagnostic = "no message"
    var navigationDiagnostic = "no navigation"

    public init(document: InteractiveDocument, session: InteractiveSession) {
        self.document = document
        self.session = session
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        configuration.userContentController.addScriptMessageHandler(
            WeakBridge(owner: self), contentWorld: .page, name: "floeInteractive"
        )
    }

    /// Navigation and deletion fence the current DOM immediately. Cleanup may
    /// finish later, but callbacks from this renderer can no longer publish.
    public func invalidate() {
        generation &+= 1; loadedLease = nil; isReady = false
        onStateChange = nil
        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        Task { try? await session.close() }
    }

    public func resume() async {
        if hasUnsavedChanges, loadedLease != nil, isReady, !failed {
            // A failed commit must not destroy the still-recoverable DOM draft.
            webView.callAsyncJavaScript("window.__floeHost.setActive(true)",
                arguments: [:], in: nil, in: .page, completionHandler: { _ in })
            return
        }
        generation &+= 1
        let current = generation
        isReady = false
        failed = false
        do {
            let seed = try await session.activateRenderer()
            try Task.checkCancellation()
            guard current == generation else { return }
            let html = try InteractiveHTML.render(document: document, seed: seed)
            loadedLease = seed.leaseID
            webView.loadHTMLString(html, baseURL: nil)
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            failed = true
        }
    }

    /// Flush accepted UI updates, then destroy the document so its timers cannot keep running.
    public func suspend() async {
        let current = generation
        do { try await flush(pause: true) }
        catch {
            if current == generation { hasUnsavedChanges = true }
            return
        }
        guard current == generation else { return }
        generation &+= 1
        isReady = false
        loadedLease = nil
        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
    }

    /// Actual navigation/deletion: unlike offscreen suspension this fences and discards the renderer.
    /// Temporary-state ownership and cleanup stay in the same session.
    public func close() async throws {
        generation &+= 1
        isReady = false
        loadedLease = nil
        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        try await session.close()
    }

    /// Host calls only after an explicit decision to discard an uncommitted UI draft.
    public func discardUncommittedStateAndReload() async {
        hasUnsavedChanges = false
        await resume()
    }

    public func exportHTML() async throws -> Data {
        if isReady { try await flush() }
        return try InteractiveHTML.export(document: document, state: await session.snapshot())
    }

    public func exportData() async throws -> Data {
        if isReady { try await flush() }
        return try InteractiveHTML.exportData(document: document, state: await session.snapshot())
    }

    /// Exposed for the host's explicit native actions, never as a script tool.
    public func currentState() async throws -> InteractiveState {
        if isReady { try await flush() }
        return try await session.snapshot()
    }

    private func flush(pause: Bool = false) async throws {
        guard isReady else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let latch = FlushLatch(continuation)
            webView.callAsyncJavaScript(
                "if (window.__floeHost) { if (pause) window.__floeHost.setActive(false); await window.__floeHost.flush(); }",
                arguments: ["pause": pause], in: nil, in: .page
            ) { result in
                switch result {
                case .success: latch.finish(nil)
                case .failure: latch.finish(InteractiveError.storageFailure)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                latch.finish(InteractiveError.storageFailure)
            }
        }
    }

    fileprivate func receive(_ message: WKScriptMessage, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.webView === webView,
              let body = message.body as? String,
              body.utf8.count <= InteractiveLimits.bridgeBytes,
              let data = body.data(using: .utf8),
              let envelope = try? RuntimeMessage.decode(data),
              envelope.leaseID == loadedLease else {
            bridgeDiagnostic = "rejected frame/body/lease"
            reply(nil, "Invalid interaction")
            return
        }
        let current = generation
        Task { @MainActor [weak self] in
            guard let self else { reply(nil, "Content unavailable"); return }
            do {
                let receipt = try await self.session.receive(envelope)
                guard current == self.generation, envelope.leaseID == self.loadedLease else {
                    reply(nil, "Content changed")
                    return
                }
                if envelope.event == .ready { self.isReady = true }
                self.bridgeDiagnostic = "accepted " + envelope.event.rawValue
                if let height = receipt.height { self.contentHeight = CGFloat(height) }
                if envelope.event == .state {
                    self.hasUnsavedChanges = false
                    self.onStateChange?(receipt.state)
                }
                let visible = VisibleReceipt(receipt)
                reply(String(decoding: try JSONEncoder().encode(visible), as: UTF8.self), nil)
            } catch {
                if envelope.event == .state, current == self.generation { self.hasUnsavedChanges = true }
                self.bridgeDiagnostic = "session rejected " + String(describing: error)
                reply(nil, "Could not save this change")
            }
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.absoluteString ?? ""
        let main = navigationAction.targetFrame?.isMainFrame == true
        // loadHTMLString uses about:blank. Suspend/resume can enqueue two such loads;
        // a shared one-shot flag would cancel the new document when the old blank load wins.
        let mainLoad = main && navigationAction.navigationType == .other
            && (url == "about:blank" || url.isEmpty)
        let childLoad = !main && (url == "about:srcdoc" || url.hasPrefix("about:srcdoc#"))
        if !navigationAction.shouldPerformDownload && (mainLoad || childLoad) {
            navigationDiagnostic = "allowed " + (main ? "main" : "child") + " " + (navigationAction.request.url?.scheme ?? "nil")
            decisionHandler(.allow)
        } else {
            blockedNavigations += 1
            navigationDiagnostic = "blocked " + (main ? "main" : "child") + " " + (navigationAction.request.url?.scheme ?? "nil")
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        failed = true
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: any Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        isReady = false
        failed = true
    }

    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

@MainActor
private final class WeakBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: InteractiveWebController?
    init(owner: InteractiveWebController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "Content unavailable"); return }
        owner.receive(message, reply: replyHandler)
    }
}

private struct VisibleReceipt: Encodable {
    struct State: Encodable {
        let revision: UInt64
        let modelContent: JSONValue
        let privateContent: JSONValue
    }
    let version = 1
    let state: State
    let height: Double?
    init(_ receipt: RuntimeReceipt) {
        state = State(revision: receipt.state.revision, modelContent: receipt.state.modelContent,
                      privateContent: receipt.state.privateContent)
        height = receipt.height
    }
}

@MainActor
private final class FlushLatch {
    private var continuation: CheckedContinuation<Void, any Error>?
    init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }
    func finish(_ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
