// SPDX-License-Identifier: MPL-2.0

import SwiftUI

// FloeMacUnified — settings surface for task-browser site memory.
//
// Primary mounts this view from the Mac settings content. It lists the sites
// the user chose to remember, shows an honest per-site inventory (counts and
// data-type names only) and offers two confirmed destructive actions:
// per-site removal (stops remembering and wipes that site's jar) and clearing
// all retained website data (wipes every remembered jar but keeps the
// remember choices). The default for everything else stays ephemeral.

enum MacSiteDataText {
    static func t(_ chinese: String, _ english: String) -> String {
        if let language = Locale.current.language.languageCode?.identifier,
           language == "zh" { return chinese }
        return english
    }
}

struct MacSiteDataSettingsView: View {
    @ObservedObject var registry: MacSiteMemoryRegistry

    @State private var summaries: [MacRememberedSiteSummary] = []
    @State private var isLoading = false
    @State private var pendingRemoval: MacRememberedSiteSummary?
    @State private var confirmsClearAll = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                if !registry.isPersistent {
                    Text(MacSiteDataText.t(
                        "网站记忆当前不可用：没有可用的存储位置。",
                        "Site memory is unavailable right now: there is no storage location to keep the remembered-site list in."
                    ))
                    .foregroundStyle(.secondary)
                } else if isLoading && summaries.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else if summaries.isEmpty {
                    Text(MacSiteDataText.t(
                        "没有已记住的网站。任务浏览器默认不保留任何网站数据。",
                        "No remembered sites. The task browser keeps no website data by default."
                    ))
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(summaries) { site in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(site.displayName)
                                Spacer()
                                Button(MacSiteDataText.t("移除", "Remove")) {
                                    pendingRemoval = site
                                }
                                .accessibilityIdentifier("mac.siteData.remove." + site.origin)
                            }
                            Text(Self.detailLine(for: site))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text(MacSiteDataText.t("已记住的网站", "Remembered sites"))
            } footer: {
                Text(MacSiteDataText.t(
                    "只在您明确选择记住后，网站登录状态才会在下次打开时保留。每个已记住的网站使用独立的存储，任务浏览器和其他网站不会共享 Cookie。",
                    "A site's login state survives only after you explicitly choose to remember it. Every remembered site uses its own isolated store; the task browser and other sites never share its cookies."
                ))
            }

            Section {
                Button(MacSiteDataText.t("清除所有已保留的网站数据…", "Clear all retained website data…")) {
                    confirmsClearAll = true
                }
                .disabled(summaries.isEmpty)
                .accessibilityIdentifier("mac.siteData.clearAll")
            } footer: {
                Text(MacSiteDataText.t(
                    "清除所有已记住网站保存的 Cookie、缓存和本地存储，但保留记住选择。不会影响 Safari、系统浏览器或其他应用的数据。",
                    "Clears the cookies, cache and local storage kept by every remembered site, but keeps the remember choices. Safari, the system browser and other apps are not affected."
                ))
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .onChange(of: registry.sites.map(\.origin)) { _, _ in
            Task { await reload() }
        }
        .alert(item: $pendingRemoval) { site in
            Alert(
                title: Text(MacSiteDataText.t("移除已记住的网站？", "Remove remembered site?")),
                message: Text(MacSiteDataText.t(
                    "将停止记住 \(site.displayName) 并删除其保留的 Cookie、缓存和本地存储。",
                    "This stops remembering \(site.displayName) and deletes its retained cookies, cache and local storage."
                )),
                primaryButton: .destructive(Text(MacSiteDataText.t("移除", "Remove"))) {
                    Task {
                        await registry.forget(origin: site.origin)
                        statusMessage = MacSiteDataText.t("已移除 \(site.displayName)", "Removed \(site.displayName)")
                        await reload()
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(MacSiteDataText.t("清除所有已保留的网站数据？", "Clear all retained website data?"), isPresented: $confirmsClearAll) {
            Button(MacSiteDataText.t("取消", "Cancel"), role: .cancel) {}
            Button(MacSiteDataText.t("清除", "Clear"), role: .destructive) {
                Task {
                    await registry.clearAllRetainedData()
                    statusMessage = MacSiteDataText.t("已清除所有已保留的网站数据", "Cleared all retained website data")
                    await reload()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .padding()
                    .onTapGesture { self.statusMessage = nil }
                    .accessibilityIdentifier("mac.siteData.status")
            }
        }
    }

    private func reload() async {
        isLoading = true
        summaries = await registry.siteSummaries()
        isLoading = false
    }

    nonisolated private static func detailLine(for site: MacRememberedSiteSummary) -> String {
        var parts: [String] = [site.origin]
        let size = MacSiteDataText.t(
            "\(site.cookieCount) 个 Cookie · \(site.recordCount) 条数据记录",
            "\(site.cookieCount) cookies · \(site.recordCount) data records"
        )
        parts.append(size)
        if !site.dataTypes.isEmpty {
            parts.append(site.dataTypes.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}
