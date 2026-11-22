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

    /// Set by the owning workbench; called on the main actor when a
    /// navigation commits or finishes so the owner can persist the safe,
    /// URL-only page restore record. Never carries cookies, forms or
    /// request bodies.
    public var onPageCommit: ((URL?) -> Void)?

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

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onPageCommit?(webView.url)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { address = url.absoluteString }
        update(from: webView)
        onPageCommit?(webView.url)
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

/// Download state the owning app supplies for the workbench banner. The
/// toolbox stays free of app-module types; the app maps its own download
/// snapshot onto this value type.
public struct MacBrowserDownloadSnapshot: Equatable {
    public let id: UUID
    public let displayName: String
    public let progress: Double
    public let isFinishing: Bool

    public init(id: UUID, displayName: String, progress: Double, isFinishing: Bool) {
        self.id = id
        self.displayName = displayName
        self.progress = progress
        self.isFinishing = isFinishing
    }
}

/// Visible result of a completed download the user explicitly started.
public struct MacBrowserSavedDownload: Equatable {
    public let displayName: String
    public let fileURL: URL

    public init(displayName: String, fileURL: URL) {
        self.displayName = displayName
        self.fileURL = fileURL
    }
}

/// Tab descriptor for the task-owned browser surface. The app maps its own
/// session's tabs onto this value type; the toolbox stays free of app-module
/// types.
public struct MacBrowserTabInfo: Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let isActive: Bool
    public let isLoading: Bool

    public init(id: UUID, title: String, isActive: Bool, isLoading: Bool) {
        self.id = id
        self.title = title
        self.isActive = isActive
        self.isLoading = isLoading
    }
}

/// Who controls the task browser right now. The visible chrome renders a
/// status strip for `.modelActive` and an explicit return-control banner for
/// `.userControlling`; model actions never pull the browser forward.
public enum MacBrowserControlStatus: Equatable {
    case idle
    case modelActive
    case userControlling(message: String)
}

/// Chrome snapshot for the task-owned browser surface. Supplied by the app
/// on every publish; the view stays a pure function of these values.
public struct MacTaskBrowserChrome: Equatable {
    public var address: String
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isLoading: Bool
    public var currentURL: URL?
    public var tabs: [MacBrowserTabInfo]
    public var controlStatus: MacBrowserControlStatus
    /// Public label of the last model action (for example a button's visible
    /// text); never carries page text, typed content or credentials.
    public var modelActivityDetail: String?

    public init(address: String, canGoBack: Bool, canGoForward: Bool, isLoading: Bool,
                currentURL: URL?, tabs: [MacBrowserTabInfo],
                controlStatus: MacBrowserControlStatus, modelActivityDetail: String?) {
        self.address = address
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.currentURL = currentURL
        self.tabs = tabs
        self.controlStatus = controlStatus
        self.modelActivityDetail = modelActivityDetail
    }
}

/// Actions the owning app supplies for the task-owned browser chrome. Every
/// user gesture funnels through the app's user-input gate, which transfers
/// control from a model run before the action changes the page.
public struct MacTaskBrowserActions {
    public var onSubmitAddress: (String) -> Void
    public var onGoBack: () -> Void
    public var onGoForward: () -> Void
    public var onReloadOrStop: () -> Void
    /// The user hands control back after a takeover; the page stays put and
    /// the next model acquisition starts a new epoch.
    public var onReturnControl: () -> Void
    public var expanded: Bool
    public var onToggleExpansion: (() -> Void)?

    public init(onSubmitAddress: @escaping (String) -> Void,
                onGoBack: @escaping () -> Void,
                onGoForward: @escaping () -> Void,
                onReloadOrStop: @escaping () -> Void,
                onReturnControl: @escaping () -> Void,
                expanded: Bool = false,
                onToggleExpansion: (() -> Void)? = nil) {
        self.onSubmitAddress = onSubmitAddress
        self.onGoBack = onGoBack
        self.onGoForward = onGoForward
        self.onReloadOrStop = onReloadOrStop
        self.onReturnControl = onReturnControl
        self.expanded = expanded
        self.onToggleExpansion = onToggleExpansion
    }
}

/// The workbench browser surface shown inside the Agent window. It reuses the
/// isolated session and adds the workbench affordances the toolbox window
/// does not need: an explicit return to the calling task, an escape hatch
/// to the system browser and an explicit user-invoked download of the
/// current page, mirroring the iPad browser chrome.
///
/// When the app supplies `taskChrome`/`taskPage`/`taskActions` (a task-owned
/// session bound to a conversation), the surface renders that session's
/// active tab — the exact same WKWebView and tab session the model tools
/// drive — with a tab strip, a control/status row and the takeover banner.
/// The plain `session` path stays the general (non-task) browser.
public struct MacBrowserWorkbenchView: View {
    @ObservedObject public var session: MacBrowserSession
    public var onReturn: (() -> Void)?
    public var onOpenExternal: ((URL) -> Void)?
    public var download: MacBrowserDownloadSnapshot?
    public var savedDownload: MacBrowserSavedDownload?
    public var downloadError: String?
    public var onDownload: (() -> Void)?
    public var onCancelDownload: ((UUID) -> Void)?
    public var onRevealDownload: ((URL) -> Void)?
    public var taskChrome: MacTaskBrowserChrome?
    public var taskPage: WKWebView?
    public var taskActions: MacTaskBrowserActions?
    public var taskTabStrip: AnyView?
    @Environment(\.locale) private var locale

    public init(session: MacBrowserSession, onReturn: (() -> Void)? = nil,
                onOpenExternal: ((URL) -> Void)? = nil,
                download: MacBrowserDownloadSnapshot? = nil,
                savedDownload: MacBrowserSavedDownload? = nil,
                downloadError: String? = nil,
                onDownload: (() -> Void)? = nil,
                onCancelDownload: ((UUID) -> Void)? = nil,
                onRevealDownload: ((URL) -> Void)? = nil,
                taskChrome: MacTaskBrowserChrome? = nil,
                taskPage: WKWebView? = nil,
                taskActions: MacTaskBrowserActions? = nil,
                taskTabStrip: AnyView? = nil) {
        self.session = session
        self.onReturn = onReturn
        self.onOpenExternal = onOpenExternal
        self.download = download
        self.savedDownload = savedDownload
        self.downloadError = downloadError
        self.onDownload = onDownload
        self.onCancelDownload = onCancelDownload
        self.onRevealDownload = onRevealDownload
        self.taskChrome = taskChrome
        self.taskPage = taskPage
        self.taskActions = taskActions
        self.taskTabStrip = taskTabStrip
    }

    public var body: some View {
        if let taskChrome, let taskActions {
            MacTaskBrowserSurface(
                chrome: taskChrome,
                page: taskPage,
                actions: taskActions,
                tabStrip: taskTabStrip,
                onReturn: onReturn,
                onOpenExternal: onOpenExternal,
                download: download,
                savedDownload: savedDownload,
                downloadError: downloadError,
                onDownload: onDownload,
                onCancelDownload: onCancelDownload,
                onRevealDownload: onRevealDownload
            )
        } else {
            generalBody
        }
    }

    private var generalBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let onReturn {
                    Button(action: onReturn) {
                        Label(MacToolboxText.backToTask(locale), systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("workspace.browser.backToTask")
                    #if DEBUG
                    .background(BrowserChromeDebugAnchor(identifier: "workspace.browser.returnAnchor"))
                    #endif
                }
                MacBrowserControlRow(session: session)
                if onDownload != nil {
                    Button {
                        onDownload?()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(download != nil || session.currentURL == nil)
                    .help(MacToolboxText.t("下载当前页面", "Download current page", locale))
                    .accessibilityIdentifier("workspace.browser.download")
                    #if DEBUG
                    .background(BrowserChromeDebugAnchor(identifier: "workspace.browser.downloadAnchor"))
                    #endif
                }
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
            if let download {
                MacBrowserDownloadBanner(
                    download: download,
                    cancel: onCancelDownload,
                    locale: locale
                )
            } else if let savedDownload, onRevealDownload != nil {
                MacBrowserSavedRow(
                    saved: savedDownload,
                    reveal: onRevealDownload,
                    locale: locale
                )
            } else if let downloadError {
                MacBrowserDownloadErrorRow(message: downloadError)
            }
            Divider()
            MacBrowserPageView(page: session.page)
        }
    }
}

/// Task-owned workbench surface: chrome + tab strip + status/takeover banner
/// around the session's active tab. Purely a function of the supplied
/// snapshot values; all state changes flow back through `actions`.
struct MacTaskBrowserSurface: View {
    let chrome: MacTaskBrowserChrome
    let page: WKWebView?
    let actions: MacTaskBrowserActions
    let tabStrip: AnyView?
    var onReturn: (() -> Void)?
    var onOpenExternal: ((URL) -> Void)?
    var download: MacBrowserDownloadSnapshot?
    var savedDownload: MacBrowserSavedDownload?
    var downloadError: String?
    var onDownload: (() -> Void)?
    var onCancelDownload: ((UUID) -> Void)?
    var onRevealDownload: ((URL) -> Void)?
    @Environment(\.locale) private var locale
    @State private var addressDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let onReturn {
                    Button(action: onReturn) {
                        Label(MacToolboxText.t("隐藏检查器", "Hide Inspector", locale), systemImage: "sidebar.trailing")
                            .labelStyle(.iconOnly)
                    }
                    .help(MacToolboxText.t("隐藏检查器", "Hide Inspector", locale))
                    .accessibilityIdentifier("workspace.browser.backToTask")
                    #if DEBUG
                    .background(BrowserChromeDebugAnchor(identifier: "workspace.browser.returnAnchor"))
                    #endif
                }
                Button { actions.onGoBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!chrome.canGoBack)
                    .accessibilityLabel(MacToolboxText.t("后退", "Back", locale))
                Button { actions.onGoForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!chrome.canGoForward)
                    .accessibilityLabel(MacToolboxText.t("前进", "Forward", locale))
                Button { actions.onReloadOrStop() } label: {
                    Image(systemName: chrome.isLoading ? "xmark" : "arrow.clockwise")
                }
                .disabled(!chrome.isLoading && chrome.currentURL == nil)
                .accessibilityLabel(chrome.isLoading
                    ? MacToolboxText.t("停止", "Stop", locale)
                    : MacToolboxText.t("重新加载", "Reload", locale))
                Spacer(minLength: 0)
                if onDownload != nil {
                    Button {
                        onDownload?()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(download != nil || chrome.currentURL == nil)
                    .help(MacToolboxText.t("下载当前页面", "Download current page", locale))
                    .accessibilityIdentifier("workspace.browser.download")
                    #if DEBUG
                    .background(BrowserChromeDebugAnchor(identifier: "workspace.browser.downloadAnchor"))
                    #endif
                }
                if onOpenExternal != nil {
                    Button {
                        if let url = chrome.currentURL { onOpenExternal?(url) }
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.bordered)
                    .disabled(chrome.currentURL == nil)
                    .help(MacToolboxText.openInSystemBrowser(locale))
                    .accessibilityIdentifier("workspace.browser.openExternal")
                }
                if let toggle = actions.onToggleExpansion {
                    Button(action: toggle) {
                        Image(systemName: actions.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .help(MacToolboxText.t("展开或收起浏览器", "Expand or Shrink Browser", locale))
                    .accessibilityLabel(MacToolboxText.t("展开或收起浏览器", "Expand or Shrink Browser", locale))
                    .accessibilityIdentifier("workspace.browser.expand")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            TextField(MacToolboxText.t("输入网址", "Enter a website address", locale), text: $addressDraft)
                .textContentType(.URL)
                .onSubmit { actions.onSubmitAddress(addressDraft) }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            if let tabStrip { tabStrip }
            MacTaskBrowserControlBanner(
                status: chrome.controlStatus,
                modelActivityDetail: chrome.modelActivityDetail,
                onReturnControl: actions.onReturnControl,
                locale: locale
            )
            if let download {
                MacBrowserDownloadBanner(
                    download: download,
                    cancel: onCancelDownload,
                    locale: locale
                )
            } else if let savedDownload, onRevealDownload != nil {
                MacBrowserSavedRow(
                    saved: savedDownload,
                    reveal: onRevealDownload,
                    locale: locale
                )
            } else if let downloadError {
                MacBrowserDownloadErrorRow(message: downloadError)
            }
            Divider()
            if let page { MacBrowserPageView(page: page) }
            else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .onAppear { addressDraft = chrome.address }
        .onChange(of: chrome.address) { _, newValue in
            // Keep the draft in sync with the committed page while the user
            // is not editing it (submit resets through the app callback).
            if !chrome.isLoading { addressDraft = newValue }
        }
        .id(chrome.tabs.map(\.id))
    }
}

/// Control-state banner: an unobtrusive strip while a model run holds the
/// page, and an explicit "You control this browser" banner with return
/// control after a takeover.
struct MacTaskBrowserControlBanner: View {
    let status: MacBrowserControlStatus
    let modelActivityDetail: String?
    let onReturnControl: () -> Void
    let locale: Locale

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .modelActive:
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                if let modelActivityDetail {
                    Text(MacToolboxText.t("代理正在使用此浏览器：\(modelActivityDetail)",
                                          "The agent is using this browser: \(modelActivityDetail)", locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(MacToolboxText.t("代理正在使用此浏览器", "The agent is using this browser", locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .accessibilityIdentifier("workspace.browser.modelActive")
        case .userControlling(let message):
            HStack(spacing: 10) {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.secondary)
                Text(MacToolboxText.t("你正在控制此浏览器。\(message)",
                                      "You control this browser. \(message)", locale))
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
                Button(MacToolboxText.t("交还控制", "Return control", locale)) {
                    onReturnControl()
                }
                .font(.callout)
                .accessibilityIdentifier("workspace.browser.returnControl")
                #if DEBUG
                .background(BrowserChromeDebugAnchor(identifier: "workspace.browser.returnControlAnchor"))
                #endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .accessibilityIdentifier("workspace.browser.userControlling")
        }
    }
}

/// Failure line for the last user-invoked download; cancel stays silent.
struct MacBrowserDownloadErrorRow: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("workspace.browser.downloadError")
    }
}

/// Progress/cancel line for an active user-invoked download; mirrors the
/// iPad browser download banner.
struct MacBrowserDownloadBanner: View {
    let download: MacBrowserDownloadSnapshot
    let cancel: ((UUID) -> Void)?
    let locale: Locale

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: download.progress)
                .frame(width: 120)
            VStack(alignment: .leading, spacing: 1) {
                Text(download.displayName).font(.callout).lineLimit(1)
                Text(download.isFinishing
                    ? MacToolboxText.t("正在保存", "Saving", locale)
                    : MacToolboxText.t("正在下载", "Downloading", locale))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let cancel {
                Button(MacToolboxText.t("取消", "Cancel", locale)) { cancel(download.id) }
                    .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(8)
        .accessibilityIdentifier("workspace.browser.downloadBanner")
    }
}

/// Visible result of a finished download; the file already sits at the
/// user-chosen path, so this only names it and offers a Finder reveal.
struct MacBrowserSavedRow: View {
    let saved: MacBrowserSavedDownload
    let reveal: ((URL) -> Void)?
    let locale: Locale

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(MacToolboxText.t("已下载", "Downloaded", locale))
                .font(.callout)
            Text(saved.displayName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            if let reveal {
                Button(MacToolboxText.t("在访达中显示", "Show in Finder", locale)) {
                    reveal(saved.fileURL)
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("workspace.browser.savedRow")
    }
}

struct MacBrowserPageView: NSViewRepresentable {
    let page: WKWebView

    func makeNSView(context: Context) -> WKWebView { page }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}


#if DEBUG
/// Hit-transparent debug anchor placed behind a chrome button so native
/// smoke can fall back to a real click at the button's on-screen location
/// when the accessibility press misses. One shared representable; the
/// identifier names the affordance (`workspace.browser.returnAnchor`,
/// `workspace.browser.downloadAnchor`).
private struct BrowserChromeDebugAnchor: NSViewRepresentable {
    let identifier: String

    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let anchor = Anchor()
        anchor.identifier = .init(identifier)
        anchor.setAccessibilityElement(false)
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
