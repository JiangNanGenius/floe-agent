// FloeApp — the user-visible in-app browser and takeover surface.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var center: BrowserSessionCenter

    var body: some View {
        VStack(spacing: 0) {
            BrowserAddressBar(center: center)
            Divider()
            BrowserWebContainer(webView: center.activeWebView)
                .overlay {
                    BrowserSurfaceStatus(center: center)
                }
                .overlay(alignment: .topTrailing) {
                    if center.isUserControlling {
                        Button("browser.return_to_agent") { center.returnToAgent() }
                            .buttonStyle(.borderedProminent)
                            .padding()
                    } else {
                        Button("browser.take_control") { center.takeControl() }
                            .buttonStyle(.bordered)
                            .padding()
                    }
                }
        }
        .navigationTitle("browser.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BrowserSurfaceStatus: View {
    @ObservedObject var center: BrowserSessionCenter

    var body: some View {
        switch center.surfaceState {
        case .unbound:
            ContentUnavailableView(
                "No task browser",
                systemImage: "rectangle.slash",
                description: Text("Open a task before starting a browser session.")
            )
            .background(.background)
        case .loading:
            ProgressView("Loading page…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .failed(let message):
            ContentUnavailableView(
                "Page failed to load",
                systemImage: "wifi.exclamationmark",
                description: Text(message)
            )
            .background(.background)
        case .needsUser(let message):
            VStack(spacing: 10) {
                Label("User action required", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.headline)
                Text(message).font(.caption).multilineTextAlignment(.center)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .ready:
            EmptyView()
        }
    }
}

private struct BrowserAddressBar: View {
    @ObservedObject var center: BrowserSessionCenter

    var body: some View {
        HStack(spacing: 8) {
            Button { center.activeWebView?.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(center.activeWebView?.canGoBack != true)
            Button { center.activeWebView?.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(center.activeWebView?.canGoForward != true)
            TextField("browser.address", text: $center.addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .onSubmit { center.navigateFromAddressBar() }
                .accessibilityHint(center.isDisplayingLocalPreview
                    ? "显示网页名称；真实回环地址仅在技术信息中提供。"
                    : "输入网页地址")
            Button { center.navigateFromAddressBar() } label: { Image(systemName: "arrow.right.circle.fill") }
            if center.isDisplayingLocalPreview, let technicalAddress = center.technicalAddress {
                Menu {
                    Button {
                        UIPasteboard.general.string = technicalAddress
                    } label: {
                        Label("复制技术地址", systemImage: "doc.on.doc")
                    }
                    Text(technicalAddress)
                } label: {
                    Image(systemName: "lock.shield")
                }
                .accessibilityLabel("本地网页预览")
            }
            Menu {
                ForEach(center.tabs) { tab in
                    Button(tab.webView.title?.isEmpty == false ? tab.webView.title! : "browser.new_tab") {
                        center.activate(tab.id)
                    }
                }
                Divider()
                Button("browser.new_tab", systemImage: "plus") { _ = center.createTab() }
                    .disabled(center.tabs.count >= 6)
                if let active = center.activeTabID, center.tabs.count > 1 {
                    Button("browser.close_tab", systemImage: "xmark", role: .destructive) { center.close(active) }
                }
            } label: {
                Label("\(center.tabs.count)", systemImage: "square.on.square")
            }
        }
        .padding(10)
        .frame(minHeight: FloeTheme.minimumTarget)
    }
}

private struct BrowserWebContainer: UIViewRepresentable {
    let webView: WKWebView?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
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
}
#endif
