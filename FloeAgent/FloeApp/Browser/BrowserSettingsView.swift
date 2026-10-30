// FloeApp — reusable Browser settings child view.
//
// Primary can push this view from the existing Settings root or present it
// from BrowserView. It owns no application navigation or localization state;
// all mutations go through BrowserSettingsService and the shared provider
// trust coordinator.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import SwiftUI
import WebKit

struct BrowserSettingsView: View {
    @ObservedObject private var settings: BrowserSettingsService
    @ObservedObject private var trust: BrowserProviderTrustCoordinator
    private let configuredProviders: [BrowserProviderIdentity]
    private let onProviderSelected: ((BrowserProviderIdentity) -> Void)?
    @State private var selectedProviderID: String?

    @State private var customUserAgent: String
    @State private var activeAlert: PresentedAlert?
    @State private var statusMessage: String?

    private enum PresentedAlert: String, Identifiable {
        case advanced
        case provider
        case clearData
        var id: String { rawValue }
    }

    /// Primary integration point. Pass the configured provider profiles so a
    /// new user can authorize before the first advanced tool call; the
    /// selected provider is display/authorization only, never run authority.
    init(
        settings: BrowserSettingsService? = nil,
        trust: BrowserProviderTrustCoordinator? = nil,
        browserCenter: BrowserSessionCenter? = nil,
        providers: [BrowserProviderIdentity] = [],
        defaultProviderID: String? = nil,
        onProviderSelected: ((BrowserProviderIdentity) -> Void)? = nil
    ) {
        let settings = settings ?? BrowserSettingsService.shared
        let trust = trust ?? BrowserProviderTrustCoordinator.shared
        self.settings = settings
        self.trust = trust
        _ = browserCenter
        self.configuredProviders = providers
        self.onProviderSelected = onProviderSelected
        _customUserAgent = State(initialValue: settings.userAgent.customValue)
        _selectedProviderID = State(
            initialValue: defaultProviderID
                ?? trust.currentProvider?.id
                ?? providers.first?.id
        )
    }

    private var selectedProvider: BrowserProviderIdentity? {
        if let selectedProviderID,
           let configured = configuredProviders.first(where: { $0.id == selectedProviderID }) {
            return configured
        }
        if !configuredProviders.isEmpty {
            return configuredProviders.first
        }
        return trust.currentProvider
    }

    var body: some View {
        Form {
            Section {
                Picker(
                    IDELanguageRunText.t("打开链接", "Open links"),
                    selection: Binding(
                        get: { settings.linkOpenBehavior },
                        set: { settings.setLinkOpenBehavior($0) }
                    )
                ) {
                    ForEach(BrowserLinkOpenBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
            } header: {
                Text(IDELanguageRunText.t("链接与页面", "Links and pages"))
            } footer: {
                Text(IDELanguageRunText.t(
                    "系统浏览器只影响你亲自点击的链接。",
                    "The system-browser option affects links you tap yourself."
                ))
            }

            Section {
                Picker(
                    IDELanguageRunText.t("网站版本", "Site version"),
                    selection: Binding(
                        get: { settings.userAgent.mode },
                        set: { settings.setUserAgent(mode: $0, customValue: customUserAgent) }
                    )
                ) {
                    ForEach(BrowserUserAgentMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if settings.userAgent.mode == .custom {
                    HStack {
                        TextField(IDELanguageRunText.t("自定义 User-Agent", "Custom User-Agent"), text: $customUserAgent)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(IDELanguageRunText.t("保存", "Save")) {
                            settings.setUserAgent(mode: .custom, customValue: customUserAgent)
                            statusMessage = IDELanguageRunText.t("自定义 User-Agent 已保存", "Custom User-Agent saved")
                        }
                        .disabled(customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } header: {
                Text(IDELanguageRunText.t("网站标识", "Site identity"))
            } footer: {
                Text(IDELanguageRunText.t(
                    "网站版本只改变请求中的 User-Agent，不会改变登录状态或页面权限。",
                    "Site version changes only the request User-Agent; it does not change login state or page permissions."
                ))
            }

            Section {
                Toggle(
                    IDELanguageRunText.t("高级浏览器功能", "Advanced browser features"),
                    isOn: Binding(
                        get: { settings.advancedBrowserFeaturesEnabled },
                        set: { enable in
                            if enable {
                                activeAlert = .advanced
                            } else {
                                settings.disableAdvancedBrowserFeatures()
                                statusMessage = IDELanguageRunText.t(
                                    "高级浏览器功能已关闭；进行中的敏感结果已失效",
                                    "Advanced browser features are off; in-flight sensitive results are now invalid"
                                )
                            }
                        }
                    )
                )
                Label(
                    settings.advancedBrowserFeaturesEnabled
                        ? IDELanguageRunText.t("高级功能已开启", "Advanced features are on")
                        : IDELanguageRunText.t("默认关闭", "Off by default"),
                    systemImage: settings.advancedBrowserFeaturesEnabled
                        ? "checkmark.shield"
                        : "shield.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text(IDELanguageRunText.t("高级浏览器功能", "Advanced browser features"))
            } footer: {
                Text(settings.advancedWarning)
            }

            Section {
                NavigationLink {
                    BrowserSiteDataView()
                } label: {
                    Label(IDELanguageRunText.t("网站数据", "Website data"), systemImage: "list.bullet.rectangle")
                }
                Button(role: .destructive) {
                    activeAlert = .clearData
                } label: {
                    Label(IDELanguageRunText.t("删除所有网站数据", "Delete all website data"),
                          systemImage: "trash")
                }
            } header: {
                Text(IDELanguageRunText.t("网站数据", "Website data"))
            } footer: {
                Text(IDELanguageRunText.t(
                    "普通浏览继续使用设备上现有的网站数据。只有你明确点击删除时才会清除 Cookie 和登录状态。",
                    "Ordinary browsing keeps the website data already on this device. Cookies and login state are cleared only when you explicitly delete them."
                ))
            }

            Section {
                if let provider = selectedProvider {
                    if configuredProviders.count > 1 {
                        Picker(
                            IDELanguageRunText.t("模型提供商", "Model provider"),
                            selection: Binding(
                                get: { selectedProviderID ?? provider.id },
                                set: { newID in
                                    selectedProviderID = newID
                                    if let selected = configuredProviders.first(where: { $0.id == newID }) {
                                        onProviderSelected?(selected)
                                    }
                                }
                            )
                        ) {
                            ForEach(configuredProviders) { item in
                                Text(item.displayName).tag(item.id)
                            }
                        }
                    } else {
                        HStack {
                            Text(provider.displayName)
                            Spacer()
                        }
                    }
                    HStack {
                        Text(settings.isProviderAuthorized(provider.id)
                            ? IDELanguageRunText.t("已授权", "Authorized")
                            : IDELanguageRunText.t("未授权", "Not authorized"))
                            .font(.caption)
                            .foregroundStyle(settings.isProviderAuthorized(provider.id) ? .green : .orange)
                        Spacer()
                    }
                    Button {
                        activeAlert = .provider
                    } label: {
                        Label(IDELanguageRunText.t("授权此提供商读取浏览器数据", "Authorize this provider for browser data"),
                              systemImage: "person.badge.key")
                    }
                } else {
                    Text(IDELanguageRunText.t(
                        "当前模型提供商尚未标识，浏览器会话数据读取保持关闭。",
                        "The active model provider is not identified; browser session data reads stay off."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text(IDELanguageRunText.t("模型接收方", "Model recipient"))
            } footer: {
                Text(IDELanguageRunText.t(
                    "提供商授权会保留。工具操作仍遵循当前任务的审批设置。",
                    "Provider consent is saved. Tool actions still follow this task’s approval settings."
                ))
            }
        }
        .navigationTitle(IDELanguageRunText.t("浏览器设置", "Browser settings"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if trust.currentProvider == nil, let selected = selectedProvider {
                onProviderSelected?(selected)
            }
        }
        .alert(item: $activeAlert) { item in
            switch item {
            case .advanced:
                return Alert(
                    title: Text(IDELanguageRunText.t("开启高级浏览器功能？", "Enable advanced browser features?")),
                    message: Text(settings.advancedWarning),
                    primaryButton: .destructive(Text(IDELanguageRunText.t("继续并确认", "Continue and confirm"))) {
                        _ = settings.enableAdvancedBrowserFeatures(confirmedWarning: true)
                        statusMessage = IDELanguageRunText.t(
                            "高级浏览器功能已开启",
                            "Advanced browser features are enabled"
                        )
                    },
                    secondaryButton: .cancel()
                )
            case .provider:
                return Alert(
                    title: Text(IDELanguageRunText.t("为此提供商授权浏览器数据？", "Authorize this provider for browser data?")),
                    message: Text(settings.providerWarning),
                    primaryButton: .destructive(Text(IDELanguageRunText.t("授权", "Authorize"))) {
                        guard let provider = selectedProvider else { return }
                        settings.authorizeProvider(provider.id)
                        statusMessage = IDELanguageRunText.t(
                            "提供商已获得一次性浏览器数据授权",
                            "The provider now has a one-time browser-data grant"
                        )
                    },
                    secondaryButton: .cancel()
                )
            case .clearData:
                return Alert(
                    title: Text(IDELanguageRunText.t("删除所有网站数据？", "Delete all website data?")),
                    message: Text(IDELanguageRunText.t(
                        "这会删除所有网站的 Cookie、缓存和本地存储，不会影响 Safari、钥匙串或你的文件。",
                        "This deletes cookies, cache and local storage for all sites. It does not touch Safari, Keychain or your files."
                    )),
                    primaryButton: .destructive(Text(IDELanguageRunText.t("删除", "Delete"))) {
                        Task {
                            await settings.deleteAllWebsiteData()
                            statusMessage = IDELanguageRunText.t("已删除已保存的网站数据", "Stored website data was deleted")
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .padding()
                    .onTapGesture { self.statusMessage = nil }
            }
        }
    }

}

struct BrowserSiteDataView: View {
    @State private var groups: [BrowserSiteDataGroup] = []
    @State private var isLoading = false
    @State private var showClearAllWarning = false

    init() {}

    var body: some View {
        List {
            if isLoading {
                ProgressView()
            }
            Section {
                if groups.isEmpty {
                    Text(IDELanguageRunText.t("没有已保存的网站数据", "No stored website data"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.displayName).font(.body)
                            Text(group.dataTypes.joined(separator: ", "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await delete(group) }
                            } label: { Label(IDELanguageRunText.t("删除", "Delete"), systemImage: "trash") }
                        }
                    }
                }
            } header: {
                Text(IDELanguageRunText.t("网站数据", "Website data"))
            } footer: {
                Text(IDELanguageRunText.t(
                    "仅显示网站域名和数据类型；缓存正文、Cookie 值和页面内容不会在这里显示。",
                    "Only site domains and data types are shown; cache bodies, cookie values and page content are not displayed here."
                ))
            }
        }
        .navigationTitle(IDELanguageRunText.t("网站数据", "Website data"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showClearAllWarning = true
                } label: { Image(systemName: "trash") }
                .accessibilityLabel(IDELanguageRunText.t("删除全部网站数据", "Delete all website data"))
            }
        }
        .task { await reload() }
        .alert(
            IDELanguageRunText.t("删除所有网站数据？", "Delete all website data?"),
            isPresented: $showClearAllWarning
        ) {
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
            Button(IDELanguageRunText.t("删除", "Delete"), role: .destructive) {
                Task { await clearAll() }
            }
        }
    }

    private func reload() async {
        isLoading = true
        groups = await BrowserWebDataBridge.records(store: .default())
        isLoading = false
    }

    private func delete(_ group: BrowserSiteDataGroup) async {
        _ = await BrowserWebDataBridge.deleteRecords(
            store: .default(),
            displayNames: [group.displayName]
        )
        await reload()
    }

    private func clearAll() async {
        _ = await BrowserWebDataBridge.clearAll(store: .default())
        await reload()
    }
}
#endif
