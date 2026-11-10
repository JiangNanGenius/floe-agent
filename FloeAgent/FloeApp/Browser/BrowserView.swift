// FloeApp — the user-visible in-app browser and takeover surface.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var center: BrowserSessionCenter
    @State private var expanded = false

    var body: some View {
        Group {
            if expanded { Color.clear }
            else {
                BrowserSurfaceRoot(center: center, expanded: $expanded)
            }
        }
        .fullScreenCover(isPresented: $expanded) {
            BrowserSurfaceRoot(center: center, expanded: $expanded)
        }
        .task(id: center.conversationID) { await center.recoverHandoff() }
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

    var body: some View {
        if let session = center.visibleSession {
            BrowserSurface(center: center, session: session, expanded: $expanded)
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var activeSheet: BrowserSheet?

    private enum BrowserSheet: String, Identifiable {
        case tabs, settings, ports
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { geometry in
            content(wide: geometry.size.width >= 620 && !dynamicTypeSize.isAccessibilitySize)
        }
        .background(.background)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .tabs:
                BrowserTabOverview(session: session)
            case .settings:
                BrowserSettingsSheet(center: center)
            case .ports:
                BrowserPortsSheet()
            }
        }
        .alert(
            IDELanguageRunText.t("标签页上限", "Tab limit"),
            isPresented: Binding(
                get: { session.tabLimitNotice != nil },
                set: { if !$0 { session.clearTabLimitNotice() } }
            )
        ) {
            Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { session.clearTabLimitNotice() }
        } message: {
            Text(session.tabLimitNotice ?? "")
        }
    }

    private func content(wide: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                BrowserAddressBar(
                    center: center,
                    session: session,
                    compact: !wide,
                    fullscreen: expanded,
                    showTabs: { activeSheet = .tabs },
                    showSettings: { activeSheet = .settings },
                    showPorts: { activeSheet = .ports }
                ) { expanded.toggle() }
                if wide { BrowserTabStrip(session: session) }
            }
            .background(.bar)
            BrowserProgressBar(session: session)
            if center.taskHandoffsEnabled && (session.isUserControlling || center.handoffNeedsContinue || center.handoffError != nil) {
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
                    .accessibilityIdentifier("browser.taskHandoff")
            }
            if center.taskHandoffsEnabled && center.handoffNotified {
                Label(IDELanguageRunText.t("已通知原任务", "Original task notified"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("browser.taskHandoffNotified")
            }
            Divider()
            BrowserWebContainer(webView: session.activeWebView)
                .overlay(alignment: .top) {
                    if case .failed(let message) = session.surfaceState {
                        VStack(spacing: 12) {
                            Text(message).font(.callout).multilineTextAlignment(.center)
                            Button(IDELanguageRunText.t("重试", "Retry")) { session.activeWebView?.reload() }
                                .buttonStyle(.bordered)
                        }
                        .padding().frame(maxWidth: 480)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding()
                    }
                }
                .overlay(alignment: .bottom) { BrowserDownloadBanner(service: session.downloads) }
                .clipped()
        }
    }
}

private struct BrowserSettingsSheet: View {
    @ObservedObject var center: BrowserSessionCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BrowserSettingsView(settings: center.settingsService, browserCenter: center)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                    }
                }
        }
    }
}

private struct BrowserPortsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LinuxPortManagementView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                    }
                }
        }
    }
}

private struct BrowserProgressBar: View {
    @ObservedObject var session: BrowserTaskSession

    var body: some View {
        Group {
            if session.isLoading {
                ProgressView(value: session.estimatedProgress)
                    .progressViewStyle(.linear)
                    .frame(height: 3)
                    .accessibilityLabel(IDELanguageRunText.t("页面载入进度", "Page loading progress"))
            } else {
                Color.clear.frame(height: 3)
            }
        }
    }
}

private struct BrowserTabStrip: View {
    @ObservedObject var session: BrowserTaskSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(session.tabs) { tab in
                    BrowserTabChip(session: session, tab: tab)
                }
                Button {
                    _ = session.createTab()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(IDELanguageRunText.t("新建标签页", "New tab"))
                .accessibilityIdentifier("browser.newTab")
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
    }
}

private struct BrowserTabChip: View {
    @ObservedObject var session: BrowserTaskSession
    let tab: BrowserTaskSession.Tab

    private var active: Bool { tab.id == session.activeTabID }
    private var title: String {
        let value = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty { return value }
        if let host = tab.webView.url?.host, !host.isEmpty { return host }
        return IDELanguageRunText.t("新标签页", "New tab")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                session.close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(IDELanguageRunText.t("关闭标签页", "Close tab"))
            Button {
                session.activate(tab.id)
            } label: {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(active ? .primary : .secondary)
                    .padding(.trailing, 16)
                    .frame(minWidth: 80, maxWidth: 180, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(active ? .isSelected : [])
        }
        .background(active ? Color(uiColor: .systemBackground) : .clear,
                    in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

private struct BrowserTabOverview: View {
    @ObservedObject var session: BrowserTaskSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.tabs) { tab in
                        Button {
                            session.activate(tab.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tab.id == session.activeTabID ? "safari.fill" : "safari")
                                    .foregroundStyle(tab.id == session.activeTabID ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tabTitle(tab)).lineLimit(1)
                                    if let host = tab.webView.url?.host {
                                        Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if tab.id == session.activeTabID {
                                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                session.close(tab.id)
                            } label: { Label(IDELanguageRunText.t("关闭", "Close"), systemImage: "xmark") }
                        }
                    }
                }
                Section {
                    Button {
                        _ = session.createTab()
                        dismiss()
                    } label: {
                        Label(IDELanguageRunText.t("新建标签页", "New tab"), systemImage: "plus")
                    }
                } footer: {
                    Text(IDELanguageRunText.t(
                        "最多 6 个标签页。关闭最后一个标签页会留下空白页。",
                        "Up to 6 tabs. Closing the last tab leaves a blank tab."
                    ))
                }
            }
            .navigationTitle(IDELanguageRunText.t("标签页", "Tabs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                }
            }
        }
    }

    private func tabTitle(_ tab: BrowserTaskSession.Tab) -> String {
        let value = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? IDELanguageRunText.t("新标签页", "New tab") : value
    }
}

private struct BrowserAddressBar: View {
    @ObservedObject var center: BrowserSessionCenter
    @ObservedObject var session: BrowserTaskSession
    let compact: Bool
    let fullscreen: Bool
    let showTabs: () -> Void
    let showSettings: () -> Void
    let showPorts: () -> Void
    let toggleFullscreen: () -> Void
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if !compact { historyButtons }
                if !compact { Spacer(minLength: 0) }
                addressField
                    .frame(maxWidth: compact ? .infinity : 720)
                if !compact {
                    Spacer(minLength: 0)
                    shareButton
                    fullscreenButton
                }
                browserMenu
            }
            if compact {
                HStack(spacing: 0) {
                    historyButtons
                    Spacer(minLength: 0)
                    shareButton
                    Button(action: showTabs) {
                        Image(systemName: "square.on.square")
                            .overlay { Text("\(session.tabs.count)").font(.system(size: 9, weight: .semibold, design: .rounded)).offset(x: 2, y: -2) }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(IDELanguageRunText.t("标签页概览", "Tab overview"))
                    .accessibilityValue("\(session.tabs.count)")
                    .accessibilityIdentifier("browser.tabs.overview")
                    fullscreenButton
                }
            }
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary).accessibilityHidden(true)
                .padding(.leading, 12)
            TextField("browser.address", text: Binding(
                get: { editing ? session.addressText : displayedAddress },
                set: { session.addressText = $0 }
            ))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL).submitLabel(.go).textFieldStyle(.plain)
                .font(.subheadline)
                .multilineTextAlignment(editing ? .leading : .center)
                .focused($editing)
                .onChange(of: editing) { _, value in session.isEditingAddress = value }
                .onChange(of: session.activeTabID) { _, _ in editing = false; session.isEditingAddress = false }
                .onSubmit { editing = false; session.isEditingAddress = false; session.navigateFromAddressBar() }
                .accessibilityIdentifier("browser.address")
                .accessibilityValue(session.addressText)
            button(session.isLoading ? "xmark" : "arrow.clockwise",
                   session.isLoading ? IDELanguageRunText.t("停止载入", "Stop loading") : IDELanguageRunText.t("刷新", "Reload")) {
                if session.isLoading { session.activeWebView?.stopLoading() }
                else { session.activeWebView?.reload() }
            }
            .accessibilityIdentifier("browser.reload")
        }
        .frame(minHeight: 44)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        .layoutPriority(1)
    }

    private var displayedAddress: String {
        // Shorten presentation only. Editing, copying and accessibility retain
        // the full address, including the path and a local service's port.
        guard let url = session.activeWebView?.url,
              url.absoluteString == session.addressText,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return session.addressText }
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return url.port.map { "\(name):\($0)" } ?? name
    }

    @ViewBuilder
    private var shareButton: some View {
        if let url = session.activeWebView?.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(IDELanguageRunText.t("分享页面", "Share page"))
            .accessibilityIdentifier("browser.share")
        }
    }

    private var historyButtons: some View {
        Group {
            button("chevron.backward", IDELanguageRunText.t("后退", "Back")) { session.activeWebView?.goBack() }
                .disabled(!session.canGoBack)
                .accessibilityIdentifier("browser.back")
            button("chevron.forward", IDELanguageRunText.t("前进", "Forward")) { session.activeWebView?.goForward() }
                .disabled(!session.canGoForward)
                .accessibilityIdentifier("browser.forward")
        }
    }

    private var fullscreenButton: some View {
        button(fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
               fullscreen ? IDELanguageRunText.t("退出全屏", "Exit full screen") : IDELanguageRunText.t("全屏", "Full screen"),
               action: toggleFullscreen)
            .accessibilityIdentifier("browser.fullscreen")
    }

    private var browserMenu: some View {
        Menu {
            Section {
                Button(IDELanguageRunText.t("后退", "Back"), systemImage: "chevron.backward") { session.activeWebView?.goBack() }
                    .disabled(!session.canGoBack)
                Button(IDELanguageRunText.t("前进", "Forward"), systemImage: "chevron.forward") { session.activeWebView?.goForward() }
                    .disabled(!session.canGoForward)
                Button(IDELanguageRunText.t("刷新", "Reload"), systemImage: "arrow.clockwise") { session.activeWebView?.reload() }
                Button(IDELanguageRunText.t("复制地址", "Copy address"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = session.technicalAddress
                }
                if let url = session.activeWebView?.url {
                    Button(IDELanguageRunText.t("在系统浏览器中打开", "Open in system browser"), systemImage: "safari") {
                        UIApplication.shared.open(url)
                    }
                }
                if center.taskHandoffsEnabled, !session.isUserControlling, center.deliverHandoff != nil {
                    Button(IDELanguageRunText.t("接管浏览器", "Take control"), systemImage: "hand.tap") { center.takeControl() }
                        .accessibilityIdentifier("browser.takeControl")
                }
            }
            Section {
                Button(IDELanguageRunText.t("浏览器设置", "Browser settings"), systemImage: "gearshape") { showSettings() }
                Button("portforward.title", systemImage: "network", action: showPorts)
            }
            Section {
                Button(IDELanguageRunText.t("标签页概览", "Tab overview"), systemImage: "square.on.square", action: showTabs)
                ForEach(session.tabs) { tab in
                    Button(tabTitle(tab)) { session.activate(tab.id) }
                }
                Button("browser.new_tab", systemImage: "plus") { _ = session.createTab() }
                    .accessibilityIdentifier("browser.menu.newTab")
                if let active = session.activeTabID, !session.tabs.isEmpty {
                    Button("browser.close_tab", systemImage: "xmark", role: .destructive) { session.close(active) }
                        .accessibilityIdentifier("browser.menu.closeTab")
                }
            }
        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
        .accessibilityLabel(IDELanguageRunText.t("浏览器菜单", "Browser menu"))
        .accessibilityIdentifier("browser.menu")
    }

    private func tabTitle(_ tab: BrowserTaskSession.Tab) -> String {
        let value = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? IDELanguageRunText.t("新标签页", "New tab") : value
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel(Text(label))
    }
}

private struct BrowserDownloadBanner: View {
    @ObservedObject var service: BrowserDownloadService

    var body: some View {
        if let record = service.active.first {
            HStack(spacing: 10) {
                ProgressView(value: record.progress)
                    .frame(width: 120)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.displayName).font(.caption).lineLimit(1)
                    Text(record.state == .finishing
                        ? IDELanguageRunText.t("正在保存", "Saving")
                        : IDELanguageRunText.t("正在下载", "Downloading"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(IDELanguageRunText.t("取消", "Cancel")) { service.cancel(record.id) }
                    .font(.caption)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(8)
        }
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
