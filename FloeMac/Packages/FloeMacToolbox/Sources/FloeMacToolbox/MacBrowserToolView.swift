// SPDX-License-Identifier: MPL-2.0

import Combine
import SwiftUI
import WebKit

/// Scheme guard shared by the toolbox browser and the workbench browser.
/// Only plain http(s) destinations without embedded credentials are
/// navigable; everything else stays in the system browser.
public enum MacBrowserAddress {
    public static func url(from input: String) -> URL? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.utf8.count <= 8_192,
              !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let candidate = address.contains("://") ? address : "https://" + address
        guard let url = URL(string: candidate), allows(url) else { return nil }
        return url
    }

    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }
}

/// One isolated browser session. The data store is non-persistent and the
/// web view is owned by the session, so the page, history and loading state
/// survive SwiftUI destination changes as long as the session is retained.
@MainActor
public final class MacBrowserSession: NSObject, ObservableObject, WKNavigationDelegate {
    /// Pure navigation rule shared by the delegate and the tests. A normal
    /// user-clicked http(s) link — including target=_blank links — navigates
    /// the current tab; automatic or scripted popup navigations are ignored.
    enum NavigationChoice: Equatable {
        case allow
        /// Cancel the original action and load the request in the current tab.
        case loadInCurrentTab
        case ignore
    }

    nonisolated static func choice(targetFrameExists: Bool, navigationType: WKNavigationType,
                                   url: URL?, shouldPerformDownload: Bool) -> NavigationChoice {
        guard !shouldPerformDownload, let url, MacBrowserAddress.allows(url) else { return .ignore }
        if targetFrameExists { return .allow }
        return navigationType == .linkActivated ? .loadInCurrentTab : .ignore
    }

    @Published public var address = ""
    @Published public private(set) var failed = false
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var currentURL: URL?
    public let page: WKWebView

    public override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        page = WKWebView(frame: .zero, configuration: config)
        super.init()
        page.navigationDelegate = self
    }

    /// Navigate to a caller-supplied link after the shared scheme guard.
    public func open(_ url: URL) {
        guard MacBrowserAddress.allows(url) else {
            failed = true
            return
        }
        address = url.absoluteString
        failed = false
        page.load(URLRequest(url: url))
    }

    public func open() {
        guard let url = MacBrowserAddress.url(from: address) else {
            failed = true
            return
        }
        open(url)
    }

    public func stop() {
        page.stopLoading()
        update(from: page)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        switch Self.choice(targetFrameExists: navigationAction.targetFrame != nil,
                           navigationType: navigationAction.navigationType,
                           url: navigationAction.request.url,
                           shouldPerformDownload: navigationAction.shouldPerformDownload) {
        case .allow:
            decisionHandler(.allow)
        case .loadInCurrentTab:
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
        case .ignore:
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        let accepted = navigationResponse.canShowMIMEType && disposition?.hasPrefix("attachment") != true
        decisionHandler(accepted ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failed = false
        update(from: webView)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { address = url.absoluteString }
        update(from: webView)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failedNavigation(webView, error: error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failedNavigation(webView, error: error)
    }

    private func failedNavigation(_ webView: WKWebView, error: Error) {
        let underlying = error as NSError
        failed = underlying.domain != NSURLErrorDomain || underlying.code != NSURLErrorCancelled
        update(from: webView)
    }

    private func update(from webView: WKWebView) {
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }
}

/// Shared navigation row for every Mac browser surface (toolbox window and
/// workbench destination): back, forward, reload/stop and the guarded
/// address field.
struct MacBrowserControlRow: View {
    @ObservedObject var session: MacBrowserSession
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 10) {
            Button { session.page.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!session.canGoBack)
                .accessibilityLabel(MacToolboxText.t("后退", "Back", locale))
            Button { session.page.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!session.canGoForward)
                .accessibilityLabel(MacToolboxText.t("前进", "Forward", locale))
            Button {
                if session.isLoading { session.stop() }
                else { session.page.reload() }
            } label: {
                Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
            }
            .disabled(!session.isLoading && session.currentURL == nil)
            .accessibilityLabel(session.isLoading ? MacToolboxText.t("停止", "Stop", locale)
                                                  : MacToolboxText.t("重新加载", "Reload", locale))
            TextField(MacToolboxText.t("输入网址", "Enter a website address", locale), text: $session.address)
                .textContentType(.URL)
                .onSubmit { session.open() }
        }
    }
}

/// Failure line shared by the toolbox and workbench browser surfaces.
struct MacBrowserLoadError: View {
    @Environment(\.locale) private var locale

    var body: some View {
        Text(MacToolboxText.t("无法打开网页。请检查网址和连接。",
                              "Could not open the page. Check the address and connection.", locale))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("browser.loadError")
    }
}

struct MacBrowserToolView: View {
    @Environment(\.locale) private var locale
    @StateObject private var session = MacBrowserSession()

    var body: some View {
        VStack(spacing: 0) {
            MacBrowserControlRow(session: session)
                .padding(12)
            if session.failed { MacBrowserLoadError() }
            Divider()
            MacBrowserPageView(page: session.page)
        }
        .onDisappear { session.stop() }
    }
}

/// The workbench browser surface shown inside the Agent window. It reuses the
/// isolated session and adds the workbench affordances the toolbox window
/// does not need: an explicit return to the calling task and an escape hatch
/// to the system browser, mirroring the iPad browser chrome.
public struct MacBrowserWorkbenchView: View {
    @ObservedObject public var session: MacBrowserSession
    public var onReturn: (() -> Void)?
    public var onOpenExternal: ((URL) -> Void)?
    @Environment(\.locale) private var locale

    public init(session: MacBrowserSession, onReturn: (() -> Void)? = nil,
                onOpenExternal: ((URL) -> Void)? = nil) {
        self.session = session
        self.onReturn = onReturn
        self.onOpenExternal = onOpenExternal
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let onReturn {
                    Button(action: onReturn) {
                        Label(MacToolboxText.backToTask(locale), systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("workspace.browser.backToTask")
                    #if DEBUG
                    .background(BrowserReturnButtonAnchor())
                    #endif
                }
                MacBrowserControlRow(session: session)
                if onOpenExternal != nil {
                    Button {
                        if let url = session.currentURL { onOpenExternal?(url) }
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.currentURL == nil)
                    .help(MacToolboxText.openInSystemBrowser(locale))
                    .accessibilityIdentifier("workspace.browser.openExternal")
                }
            }
            .padding(12)
            if session.failed { MacBrowserLoadError() }
            Divider()
            MacBrowserPageView(page: session.page)
        }
    }
}

struct MacBrowserPageView: NSViewRepresentable {
    let page: WKWebView

    func makeNSView(context: Context) -> WKWebView { page }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}


#if DEBUG
private struct BrowserReturnButtonAnchor: NSViewRepresentable {
    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> NSView {
        let anchor = Anchor()
        anchor.identifier = .init("workspace.browser.returnAnchor")
        anchor.setAccessibilityElement(false)
        return anchor
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
