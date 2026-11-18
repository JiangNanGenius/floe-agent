// SPDX-License-Identifier: MPL-2.0

import Combine
import SwiftUI
import WebKit

enum MacBrowserAddress {
    static func url(from input: String) -> URL? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.utf8.count <= 8_192,
              !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let candidate = address.contains("://") ? address : "https://" + address
        guard let url = URL(string: candidate), allows(url) else { return nil }
        return url
    }

    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }
}

@MainActor
final class MacBrowserSession: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var address = ""
    @Published private(set) var failed = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    let page: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        page = WKWebView(frame: .zero, configuration: config)
        super.init()
        page.navigationDelegate = self
    }

    func open() {
        guard let url = MacBrowserAddress.url(from: address) else {
            failed = true
            return
        }
        address = url.absoluteString
        failed = false
        page.load(URLRequest(url: url))
    }

    func stop() {
        page.stopLoading()
        update(from: page)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let accepted = navigationAction.targetFrame != nil
            && navigationAction.request.url.map(MacBrowserAddress.allows) == true
            && !navigationAction.shouldPerformDownload
        decisionHandler(accepted ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        let accepted = navigationResponse.canShowMIMEType && disposition?.hasPrefix("attachment") != true
        decisionHandler(accepted ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failed = false
        update(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { address = url.absoluteString }
        update(from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failedNavigation(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failedNavigation(webView, error: error)
    }

    private func failedNavigation(_ webView: WKWebView, error: Error) {
        let underlying = error as NSError
        failed = underlying.domain != NSURLErrorDomain || underlying.code != NSURLErrorCancelled
        update(from: webView)
    }

    private func update(from webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }
}

struct MacBrowserToolView: View {
    @Environment(\.locale) private var locale
    @StateObject private var session = MacBrowserSession()

    var body: some View {
        VStack(spacing: 0) {
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
                .accessibilityLabel(session.isLoading ? MacToolboxText.t("停止", "Stop", locale)
                                                      : MacToolboxText.t("重新加载", "Reload", locale))
                TextField(MacToolboxText.t("输入网址", "Enter a website address", locale), text: $session.address)
                    .textContentType(.URL)
                    .onSubmit { session.open() }
            }
            .padding(12)
            if session.failed {
                Text(MacToolboxText.t("无法打开网页。请检查网址和连接。", "Could not open the page. Check the address and connection.", locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            BrowserPage(page: session.page)
        }
        .onDisappear { session.stop() }
    }
}

private struct BrowserPage: NSViewRepresentable {
    let page: WKWebView

    func makeNSView(context: Context) -> WKWebView { page }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
