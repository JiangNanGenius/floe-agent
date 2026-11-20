// SPDX-License-Identifier: MPL-2.0
import AppKit
import Darwin
import Foundation
import SwiftUI
import WebKit

/// The URL origin exists only for this presentation. Its root is the selected
/// document's enclosing folder, never the whole workspace or a file URL.
struct MacWorkspaceHTMLSite: Identifiable, Sendable {
    static let scheme = "floe-preview"
    private let origin = UUID().uuidString.lowercased()
    private let directory: MacAgentWorkspaceRoot
    let name: String
    var id: String { origin }
    var entryURL: URL { URL(string: Self.scheme + "://" + origin)!.appendingPathComponent(name) }

    static func isPage(_ url: URL) -> Bool { ["htm", "html"].contains(url.pathExtension.lowercased()) }

    init(page: URL, workspace: URL) throws {
        let parent = page.deletingLastPathComponent()
        // Foundation can shorten /private/var and /private/tmp when producing
        // file URLs. Recognize those system aliases only; user symlinks remain excluded.
        func matchesPhysicalPath(_ path: String, _ physical: String) -> Bool {
            if path == physical { return true }
            let systemAlias = ["/tmp", "/var"].contains { path == $0 || path.hasPrefix($0 + "/") }
            return systemAlias && physical == "/private" + path
        }
        let root = MacAgentWorkspaceRoot(parent)
        guard page.isFileURL, workspace.isFileURL, Self.isPage(page),
              let physical = root.physicalPath, matchesPhysicalPath(parent.path, physical),
              let scope = MacAgentWorkspacePinSupport.physicalPath(workspace.path), matchesPhysicalPath(workspace.path, scope),
              MacAgentWorkspacePinSupport.isContained(physical, in: scope)
        else { throw CocoaError(.fileReadNoPermission) }
        self.directory = root
        self.name = page.lastPathComponent
    }

    func owns(_ url: URL) -> Bool {
        url.scheme == Self.scheme && url.host == origin && url.port == nil && url.user == nil && url.password == nil
    }

    private static let types = [
        "htm": "text/html", "html": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
        "json": "application/json", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "svg": "image/svg+xml", "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "mp3": "audio/mpeg", "wav": "audio/wav", "mp4": "video/mp4", "webm": "video/webm"
    ]

    func resource(_ url: URL) throws -> (data: Data, type: String) {
        guard owns(url), let physical = directory.physicalPath,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              encoded.hasPrefix("/") else { throw CocoaError(.fileReadNoPermission) }
        var components = try encoded.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { raw -> String in
            guard let s = raw.removingPercentEncoding, !s.hasPrefix("."), !s.contains("/"), !s.contains("\\") else {
                throw CocoaError(.fileReadNoPermission)
            }
            return s
        }
        if components.isEmpty || components.last == "" {
            if !components.isEmpty { components.removeLast() }
            components.append("index.html")
        }
        let path = components.joined(separator: "/")
        guard !components.contains(""), try MacAgentWorkspacePinSupport.standardizedRelativePath(path) == path,
              let type = Self.types[(path as NSString).pathExtension.lowercased()] else { throw CocoaError(.fileReadNoPermission) }
        return try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: path, root: directory) { pin in
            let fd = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(pin, physicalRoot: physical, displayPath: path)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            let limit = 16 * 1024 * 1024
            guard fstat(fd, &info) == 0, info.st_size <= limit else { throw CocoaError(.fileReadTooLarge) }
            let bytes = try handle.read(upToCount: limit + 1) ?? Data()
            guard bytes.count <= limit else { throw CocoaError(.fileReadTooLarge) }
            return (bytes, type)
        }
    }
}

@MainActor private final class SiteHandler: NSObject, WKURLSchemeHandler {
    private let site: MacWorkspaceHTMLSite
    private var reads: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(site: MacWorkspaceHTMLSite) { self.site = site }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard let url = task.request.url, site.owns(url), task.request.httpMethod == "GET", reads.count < 16 else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let site = site
        reads[id] = Task {
            do {
                let resource = try await Task.detached(priority: .userInitiated) { try site.resource(url) }.value
                guard !Task.isCancelled else { return }
                let scheme = MacWorkspaceHTMLSite.scheme + ":"
                let policy = "sandbox allow-scripts; default-src 'none'; script-src \(scheme) 'unsafe-inline'; style-src \(scheme) 'unsafe-inline'; img-src \(scheme) data:; media-src \(scheme); font-src \(scheme) data:; connect-src \(scheme); frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; worker-src 'none'"
                let headers = ["Content-Type": resource.type,
                               "Content-Security-Policy": policy, "X-Content-Type-Options": "nosniff",
                               "Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
                               "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
                               "X-DNS-Prefetch-Control": "off", "Access-Control-Allow-Origin": "*"]
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
                    throw URLError(.cannotParseResponse)
                }
                task.didReceive(response)
                task.didReceive(resource.data)
                task.didFinish()
            } catch {
                if !Task.isCancelled { task.didFailWithError(error) }
            }
            reads.removeValue(forKey: id)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        reads.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }
}

@MainActor private final class SiteSession: NSObject, ObservableObject, WKNavigationDelegate {
    let site: MacWorkspaceHTMLSite
    @Published private(set) var page: WKWebView?
    @Published private(set) var failed = false
    @Published private(set) var canGoBack = false
    @Published private(set) var title: String

    init(site: MacWorkspaceHTMLSite) { self.site = site; title = site.name }

    func start() async {
        guard page == nil else { return }
        do {
            guard let store = WKContentRuleListStore.default() else { throw URLError(.cannotLoadFromNetwork) }
            // Block network subresources as well as document navigation. Wait
            // until WebKit installs the rule before issuing the first load.
            let rule = try await store.compileContentRuleList(forIdentifier: "FloeLocalPreviewNoNetwork1",
                encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^floe-preview://"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]"#)
            try Task.checkCancellation()
            guard let rule else { throw URLError(.cannotParseResponse) }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            // A local page has no use for peer or QUIC transports, which do
            // not load URL subresources through the content-rule filter.
            config.defaultWebpagePreferences.isLockdownModeEnabled = true
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.userContentController.add(rule)
            config.setURLSchemeHandler(SiteHandler(site: site), forURLScheme: MacWorkspaceHTMLSite.scheme)
            let page = WKWebView(frame: .zero, configuration: config)
            page.navigationDelegate = self
            self.page = page
            page.load(URLRequest(url: site.entryURL))
        } catch { failed = true }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let allowed = action.targetFrame?.isMainFrame == true && action.request.url.map(site.owns) == true
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? webView.url?.lastPathComponent ?? site.name
        canGoBack = webView.canGoBack
        failed = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = true }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = true }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true }

    func reload() async {
        failed = false
        if let page { page.load(URLRequest(url: page.url ?? site.entryURL)) }
        else { await start() }
    }
}

struct MacWorkspaceHTMLPreview: View {
    @StateObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    init(site: MacWorkspaceHTMLSite) { _session = StateObject(wrappedValue: SiteSession(site: site)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { session.page?.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!session.canGoBack)
                    .accessibilityLabel(MacPermissionsText.t("后退", "Back"))
                Button { Task { await session.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(MacPermissionsText.t("重新加载", "Reload"))
                Text(verbatim: session.title).font(.headline).lineLimit(1)
                Spacer()
                Button(MacPermissionsText.t("完成", "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }.padding(10)
            Divider()
            if session.failed {
                ContentUnavailableView(MacPermissionsText.t("无法打开网页", "Couldn’t Open Page"), systemImage: "doc")
            } else if let page = session.page {
                WebView(page: page)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(width: min(780, (NSScreen.main?.visibleFrame.width ?? 860) - 64),
               height: min(550, (NSScreen.main?.visibleFrame.height ?? 660) - 100))
        .task { await session.start() }
        .onDisappear { session.page?.stopLoading() }
    }

    private struct WebView: NSViewRepresentable {
        let page: WKWebView
        func makeNSView(context: Context) -> WKWebView { page }
        func updateNSView(_ view: WKWebView, context: Context) {}
    }
}

#if FLOE_MAC_HOST_SMOKE
enum MacWorkspaceHTMLPreviewSmoke {
    /// Exercises the same custom origin and WebKit session used by the file Open action.
    @MainActor static func verify(in root: URL) async -> Bool {
        let directory = root.resolvingSymlinksInPath().appendingPathComponent("SitePreview-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: directory) }
            let siteDirectory = directory.appendingPathComponent("site", isDirectory: true)
            try fm.createDirectory(at: siteDirectory, withIntermediateDirectories: false)
            let html = siteDirectory.appendingPathComponent("index.html")
            let marker = directory.appendingPathComponent("outside.js")
            try Data("window.outside = true".utf8).write(to: marker)
            try fm.createSymbolicLink(at: siteDirectory.appendingPathComponent("link.js"), withDestinationURL: marker)
            try Data("body { color: rgb(9, 42, 78) }".utf8).write(to: siteDirectory.appendingPathComponent("style.css"))
            try Data("function mark(){ document.title='Clicked' }".utf8).write(to: siteDirectory.appendingPathComponent("main.js"))
            let document = """
                <!doctype html><title>Local fixture</title><link rel="stylesheet" href="style.css">
                <script src="main.js"></script><button id="go" onclick="mark()">Go</button>
                <script>document.addEventListener('securitypolicyviolation', e => { if (e.effectiveDirective === 'connect-src') window.networkDenied=true });
                fetch('https://127.0.0.1:1/denied').catch(() => {});</script>
                """
            try Data(document.utf8).write(to: html)
            let site = try MacWorkspaceHTMLSite(page: html, workspace: directory)
            guard let link = URL(string: "link.js", relativeTo: site.entryURL)?.absoluteURL,
                  let traversal = URL(string: "../outside.js", relativeTo: site.entryURL)?.absoluteURL,
                  (try? site.resource(link)) == nil, (try? site.resource(traversal)) == nil else { return false }
            let session = SiteSession(site: site)
            await session.start()
            guard let page = session.page else { return false }
            defer { page.stopLoading() }
            let deadline = ContinuousClock.now + .seconds(8)
            while !session.failed && ContinuousClock.now < deadline {
                if (try? await page.evaluateJavaScript("document.getElementById('go').click(); document.title==='Clicked' && getComputedStyle(document.body).color==='rgb(9, 42, 78)' && window.networkDenied === true && typeof RTCPeerConnection === 'undefined' && typeof WebTransport === 'undefined' ")) as? Bool == true {
                    return true
                }
                try await Task.sleep(for: .milliseconds(80))
            }
            return false
        } catch { return false }
    }
}
#endif
