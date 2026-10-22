// FloeApp — the user-visible in-app browser and takeover surface.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var center: BrowserSessionCenter
    @State private var expanded = false
    @State private var showingPorts = false

    var body: some View {
        Group {
            if expanded { Color.clear }
            else {
                BrowserSurfaceRoot(center: center, expanded: $expanded, showingPorts: $showingPorts)
            }
        }
        .fullScreenCover(isPresented: $expanded) {
            BrowserSurfaceRoot(center: center, expanded: $expanded, showingPorts: $showingPorts)
        }
        .task(id: center.conversationID) { await center.recoverHandoff() }
        .sheet(isPresented: $showingPorts) { NavigationStack { LinuxPortManagementView() } }
        .navigationTitle("browser.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Projects the currently bound task's session. Binding is a presentation
/// choice; the session keeps running (and keeps its own ownership) even when
/// another task's surface is shown.
private struct BrowserSurfaceRoot: View {
    @ObservedObject var center: BrowserSessionCenter
    @Binding var expanded: Bool
    @Binding var showingPorts: Bool

    var body: some View {
        if let session = center.visibleSession {
            BrowserSurface(center: center, session: session, expanded: $expanded, showingPorts: $showingPorts)
                .id(session.conversationID)
        } else {
            ContentUnavailableView {
                Label(IDELanguageRunText.t("浏览器", "Browser"), systemImage: "safari")
            } description: {
                Text(IDELanguageRunText.t("打开一个任务即可使用它自己的浏览器", "Open a task to use its own browser"))
            }
        }
    }
}

private struct BrowserSurface: View {
    @ObservedObject var center: BrowserSessionCenter
    @ObservedObject var session: BrowserTaskSession
    @Binding var expanded: Bool
    @Binding var showingPorts: Bool

    var body: some View {
        VStack(spacing: 0) {
            BrowserAddressBar(
                center: center,
                session: session,
                fullscreen: expanded,
                showPorts: { showingPorts = true }
            ) { expanded.toggle() }
            if session.isUserControlling || center.handoffNeedsContinue || center.handoffError != nil {
                HStack {
                    Text(center.handoffError ?? (center.handoffNeedsContinue
                        ? IDELanguageRunText.t("通知已保存，原任务未运行", "Notification saved; the original task is not running")
                        : IDELanguageRunText.t("浏览器由你操作，模型可继续其他工作", "You control the browser; the agent can continue other work")))
                        .font(.caption).lineLimit(2)
                    Spacer()
                    Button {
                        Task { await center.returnToAgent(continueTask: center.handoffNeedsContinue) }
                    } label: {
                        if center.returningControl {
                            HStack { ProgressView(); Text(IDELanguageRunText.t("正在交还", "Returning control")) }
                        }
                        else { Text(center.handoffNeedsContinue
                            ? IDELanguageRunText.t("继续任务", "Continue task")
                            : IDELanguageRunText.t("完成并交还模型", "Return to agent")) }
                    }
                    .disabled(center.returningControl)
                    .frame(minHeight: 44)
                }.padding(.horizontal, 12)
            }
            if center.handoffNotified {
                Label(IDELanguageRunText.t("已通知原任务", "Original task notified"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            BrowserWebContainer(webView: session.activeWebView)
                .overlay(alignment: .top) {
                    if case .loading = session.surfaceState { ProgressView().padding(8).allowsHitTesting(false) }
                    if case .failed(let message) = session.surfaceState {
                        VStack { Text(message); Button(IDELanguageRunText.t("重试", "Retry")) { session.activeWebView?.reload() } }
                            .padding().background(.regularMaterial)
                    }
                }.clipped()
        }
        .background(.background)
    }
}

private struct BrowserAddressBar: View {
    @ObservedObject var center: BrowserSessionCenter
    @ObservedObject var session: BrowserTaskSession
    let fullscreen: Bool
    let showPorts: () -> Void
    let toggleFullscreen: () -> Void
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let title = session.activeWebView?.title, !title.isEmpty {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 0) {
                button("chevron.backward", IDELanguageRunText.t("后退", "Back")) { session.activeWebView?.goBack() }
                    .disabled(session.activeWebView?.canGoBack != true)
                TextField("browser.address", text: $session.addressText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL).textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onChange(of: editing) { _, value in session.isEditingAddress = value }
                    .onSubmit { editing = false; session.isEditingAddress = false; session.navigateFromAddressBar() }
                    .accessibilityIdentifier("browser.address")
                button("arrow.clockwise", IDELanguageRunText.t("刷新", "Reload")) { session.activeWebView?.reload() }
                button(fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", fullscreen ? IDELanguageRunText.t("退出全屏", "Exit full screen") : IDELanguageRunText.t("全屏", "Full screen"), action: toggleFullscreen)
                Menu {
                    Button(IDELanguageRunText.t("前进", "Forward"), systemImage: "chevron.forward") { session.activeWebView?.goForward() }
                        .disabled(session.activeWebView?.canGoForward != true)
                    Button(IDELanguageRunText.t("复制地址", "Copy address"), systemImage: "doc.on.doc") { UIPasteboard.general.string = session.technicalAddress }
                    if !session.isUserControlling, center.deliverHandoff != nil {
                        Button("browser.take_control", systemImage: "hand.tap") { center.takeControl() }
                    }
                    Button("portforward.title", systemImage: "network", action: showPorts)
                    Divider()
                    ForEach(session.tabs) { tab in
                        Button(tab.webView.title?.isEmpty == false ? tab.webView.title! : String(localized: "browser.new_tab")) { editing = false; session.isEditingAddress = false; session.activate(tab.id) }
                    }
                    Button("browser.new_tab", systemImage: "plus") { _ = session.createTab() }
                        .disabled(session.tabs.count >= 6)
                    if let active = session.activeTabID, session.tabs.count > 1 {
                        Button("browser.close_tab", systemImage: "xmark", role: .destructive) { session.close(active) }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .accessibilityLabel(IDELanguageRunText.t("浏览器菜单", "Browser menu"))
            }
        }.padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel(Text(label))
    }
}

private struct BrowserWebContainer: UIViewRepresentable {
    let webView: WKWebView?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        container.subviews.forEach { if $0 !== webView { $0.removeFromSuperview() } }
        guard let webView else { return }
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        // Only detach a web view that is still owned by this representable.
        // A newer browser column may already have reparented the shared tab.
        container.subviews.compactMap { $0 as? WKWebView }.forEach {
            if $0.superview === container { $0.removeFromSuperview() }
        }
    }
}
#endif
