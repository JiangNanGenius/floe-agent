// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI
import UIKit
@preconcurrency import WebKit
import FloeCore

@MainActor
final class HelpWebReaderController: ObservableObject {
    fileprivate weak var webView: WKWebView?
    fileprivate var pendingSectionID: String?
    fileprivate var didLoad = false

    func scroll(to sectionID: String) {
        pendingSectionID = sectionID
        applyPendingSection()
    }

    func showFind() {
        webView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    fileprivate func applyPendingSection() {
        guard didLoad, let webView, let sectionID = pendingSectionID,
              let data = try? JSONEncoder().encode(sectionID),
              let literal = String(data: data, encoding: .utf8) else { return }
        pendingSectionID = nil
        // The only source of code is this native constant. The chapter id is JSON data.
        webView.evaluateJavaScript("document.getElementById(\(literal))?.scrollIntoView({block:'start'});",
                                  in: nil, in: .defaultClient, completionHandler: nil)
    }
}

@MainActor
private final class HelpBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    let snapshot: HelpLibrarySnapshot
    init(snapshot: HelpLibrarySnapshot) { self.snapshot = snapshot }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard task.request.httpMethod == nil || task.request.httpMethod == "GET",
                  let url = task.request.url, let path = HelpResourceURL.path(url: url) else {
                throw URLError(.unsupportedURL)
            }
            let resource = try snapshot.resource(at: path)
            var data = resource.data
            if resource.mimeType.lowercased().hasPrefix("text/html")
                || snapshot.index.articles.contains(where: { $0.htmlPath == path }) {
                guard let html = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                data = Data(Self.protectedHTML(html).utf8)
            }
            // URLResponse takes the media type separately from its encoding.
            // Passing the manifest's "text/html; charset=utf-8" as mimeType
            // makes WebKit display the HTML source instead of the article.
            let mediaType = resource.mimeType.split(separator: ";", maxSplits: 1)
                .first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            task.didReceive(URLResponse(url: url, mimeType: mediaType,
                                       expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func protectedHTML(_ html: String) -> String {
        let policy = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src floe-help:; style-src floe-help: 'unsafe-inline'; font-src 'none'; frame-src 'none'; object-src 'none'; media-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        """
        if let range = html.range(of: "<head>", options: .caseInsensitive) {
            var result = html
            result.insert(contentsOf: policy, at: range.upperBound)
            return result
        }
        return policy + html
    }
}

struct HelpArticleWebView: UIViewRepresentable {
    let document: HelpArticleDocument
    let controller: HelpWebReaderController
    let pointSize: Double
    let dark: Bool
    let imageLabel: String
    let onReference: (HelpReference) -> Void
    let onImage: (HelpReaderImage) -> Void
    let onFailure: () -> Void
    var onExternalURL: (URL) -> Void = { UIApplication.shared.open($0) }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, controller: controller, onReference: onReference,
                    onImage: onImage, onFailure: onFailure, onExternalURL: onExternalURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.ignoresViewportScaleLimits = true
        configuration.setURLSchemeHandler(HelpBundleSchemeHandler(snapshot: document.snapshot), forURLScheme: "floe-help")
        let userContent = configuration.userContentController
        userContent.add(context.coordinator, contentWorld: .defaultClient, name: "floeHelpImage")
        userContent.addUserScript(WKUserScript(source: Self.imageInteraction(label: imageLabel),
                                             injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                                             in: .defaultClient))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.allowsLinkPreview = false
        web.isFindInteractionEnabled = true
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        controller.webView = web
        controller.didLoad = false
        controller.pendingSectionID = document.reference.sectionID
        context.coordinator.applyAppearance(pointSize: pointSize, dark: dark, web: web)
        guard let url = HelpResourceURL.url(path: document.article.htmlPath) else {
            onFailure(); return web
        }
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onReference = onReference
        context.coordinator.onImage = onImage
        context.coordinator.onExternalURL = onExternalURL
        context.coordinator.applyAppearance(pointSize: pointSize, dark: dark, web: web)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "floeHelpImage", contentWorld: .defaultClient)
        coordinator.controller.webView = nil
        coordinator.controller.didLoad = false
    }

    private static func imageInteraction(label: String) -> String {
        let literal = String(data: (try? JSONEncoder().encode(label)) ?? Data("\"Image\"".utf8), encoding: .utf8) ?? "\"Image\""
        return """
        document.querySelectorAll('img').forEach(image => {
          image.tabIndex = 0;
          image.setAttribute('role', 'button');
          image.setAttribute('aria-label', \(literal) + (image.alt ? ': ' + image.alt : ''));
          const open = event => {
            if (!event.isTrusted) return;
            event.preventDefault(); event.stopPropagation();
            window.webkit.messageHandlers.floeHelpImage.postMessage({src:image.currentSrc || image.src,alt:image.alt || ''});
          };
          image.addEventListener('click', open);
          image.addEventListener('keydown', event => { if(event.key === 'Enter' || event.key === ' ') open(event); });
        });
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let document: HelpArticleDocument
        let controller: HelpWebReaderController
        var onReference: (HelpReference) -> Void
        var onImage: (HelpReaderImage) -> Void
        let onFailure: () -> Void
        var onExternalURL: (URL) -> Void
        private var appearance: (size: Double, dark: Bool)?

        init(document: HelpArticleDocument, controller: HelpWebReaderController,
             onReference: @escaping (HelpReference) -> Void, onImage: @escaping (HelpReaderImage) -> Void,
             onFailure: @escaping () -> Void, onExternalURL: @escaping (URL) -> Void) {
            self.document = document; self.controller = controller
            self.onReference = onReference; self.onImage = onImage
            self.onFailure = onFailure; self.onExternalURL = onExternalURL
        }

        func applyAppearance(pointSize: Double, dark: Bool, web: WKWebView) {
            let size = min(max(pointSize, 12), 80)
            guard appearance?.size != size || appearance?.dark != dark else { return }
            appearance = (size, dark)
            guard controller.didLoad else { return }
            updateStyle(web)
        }

        private func updateStyle(_ web: WKWebView) {
            guard let appearance else { return }
            let background = appearance.dark ? "#1c1c1e" : "#ffffff"
            let foreground = appearance.dark ? "#f2f2f7" : "#1c1c1e"
            let secondary = appearance.dark ? "#aeaeb2" : "#636366"
            let css = """
            :root{color-scheme:\(appearance.dark ? "dark" : "light");--floe-help-size:\(appearance.size)px}
            html,body{background:\(background)!important;color:\(foreground)!important;font-family:-apple-system,BlinkMacSystemFont,sans-serif!important;font-size:var(--floe-help-size)!important;line-height:1.65!important;-webkit-text-size-adjust:100%}
            body{box-sizing:border-box;max-width:52rem!important;margin:0 auto!important;padding:20px clamp(16px,4vw,36px) 48px!important;overflow-wrap:anywhere}
            p,li,td,th,blockquote{font-size:inherit!important}p,li{line-height:1.65}img{max-width:100%;height:auto;cursor:zoom-in;border-radius:8px}h1,h2,h3,h4{scroll-margin-top:20px;line-height:1.3}a{color:\(appearance.dark ? "#64a9ff" : "#0066cc")!important}pre{overflow:auto;padding:12px;border-radius:8px;background:\(appearance.dark ? "#2c2c2e" : "#f2f2f7");font-size:.85em}table{display:block;max-width:100%;overflow-x:auto;border-collapse:collapse}td,th{padding:8px;min-width:5em}figcaption,small{color:\(secondary)}
            """
            guard let data = try? JSONEncoder().encode(css), let literal = String(data: data, encoding: .utf8) else { return }
            web.evaluateJavaScript("var s=document.getElementById('floe-native-reading-style');if(!s){s=document.createElement('style');s.id='floe-native-reading-style';document.head.appendChild(s)}s.textContent=\(literal);",
                                   in: nil, in: .defaultClient, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller.didLoad = true
            updateStyle(webView)
            controller.applyPendingSection()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { reportFailure(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { reportFailure(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure() }

        private func reportFailure(_ error: Error) {
            let error = error as NSError
            guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
            onFailure()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if action.navigationType == .linkActivated {
                if let reference = try? HelpReferenceLink.reference(from: url) {
                    // Citations may select another frozen version only through the typed center.
                    onReference(reference)
                } else if let path = HelpResourceURL.path(url: url),
                          let article = document.snapshot.index.articles.first(where: { $0.htmlPath == path }),
                          let reference = try? document.snapshot.reference(articleID: article.id,
                                                                           sectionID: url.fragment?.removingPercentEncoding) {
                    if article.id == document.article.id, let section = reference.sectionID {
                        controller.scroll(to: section)
                    } else { onReference(reference) }
                } else if (url.scheme == "https" || url.scheme == "http"), url.user == nil, url.password == nil {
                    // Remote destinations are opened only by this explicit native click path.
                    onExternalURL(url)
                }
                return .cancel
            }
            let isInitialDocument = action.targetFrame?.isMainFrame != false
                && HelpResourceURL.path(url: url) == document.article.htmlPath
                && url.fragment == nil
            return isInitialDocument ? .allow : .cancel
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: String],
                  let source = body["src"], source.utf8.count <= 2048, let url = URL(string: source),
                  let path = HelpResourceURL.path(url: url),
                  let resource = try? document.snapshot.resource(at: path),
                  resource.mimeType.hasPrefix("image/") else { return }
            onImage(HelpReaderImage(path: path, data: resource.data, title: String((body["alt"] ?? "").prefix(300))))
        }
    }
}
#endif
