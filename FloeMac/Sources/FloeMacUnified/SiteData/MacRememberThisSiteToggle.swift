// SPDX-License-Identifier: MPL-2.0

import FloeMacToolbox
import SwiftUI

// FloeMacUnified — user-facing "Remember This Site" affordance for the
// task-browser chrome. Primary mounts it next to the tab strip via
// `MacBrowserWorkbenchController.makeTaskWorkbenchView` (the app-owned
// accessory slot); it is a plain user gesture — model tools can never
// trigger it. Remembering takes effect on the next main-frame navigation to
// the site (WebKit binds a web view's data store at creation, so the
// current tab keeps its ephemeral jar until it next loads the site);
// forgetting immediately detaches every live tab from the jar and then
// wipes it, with an explicit confirmation because the wipe is destructive.

struct MacRememberThisSiteToggle: View {
    @ObservedObject var registry: MacSiteMemoryRegistry
    /// The active tab's current URL, re-read on every chrome snapshot.
    let currentURL: URL?

    @State private var confirmsForget = false
    @State private var notice: String?

    var body: some View {
        let origin = currentURL.flatMap { MacSiteMemoryRegistry.canonicalOrigin($0) }
        // No chrome entry for non-web documents, a non-persistent (or
        // unavailable) registry, or when the remember cap is reached and the
        // site is not already remembered.
        guard registry.isPersistent, origin != nil else { return AnyView(EmptyView()) }
        let remembered = currentURL.map { registry.isRemembered($0) } ?? false
        guard remembered || registry.canRememberMore else { return AnyView(EmptyView()) }

        return AnyView(
            HStack(spacing: 8) {
                if remembered {
                    Button {
                        confirmsForget = true
                    } label: {
                        Label(MacSiteDataText.t("忘记此网站", "Forget This Site"),
                              systemImage: "bookmark.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mac.browser.forgetSite")
                } else {
                    Button {
                        if let currentURL, let stored = registry.remember(url: currentURL) {
                            notice = MacSiteDataText.t(
                                "已记住 \(stored)。下次加载此网站时，登录状态将保留在新的网站存储中；您可能需要重新登录一次。",
                                "Remembered \(stored). Login state will persist in the site's new retained store the next time it loads; you may need to sign in once more."
                            )
                        }
                    } label: {
                        Label(MacSiteDataText.t("记住此网站", "Remember This Site"),
                              systemImage: "bookmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("mac.browser.rememberSite")
                }
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .onTapGesture { self.notice = nil }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .alert(MacSiteDataText.t("忘记此网站？", "Forget This Site?"), isPresented: $confirmsForget) {
                Button(MacSiteDataText.t("取消", "Cancel"), role: .cancel) {}
                Button(MacSiteDataText.t("忘记", "Forget"), role: .destructive) {
                    guard let origin else { return }
                    Task {
                        await registry.forget(origin: origin)
                        notice = MacSiteDataText.t(
                            "已忘记此网站并删除其保留的数据。",
                            "Forgot this site and deleted its retained data."
                        )
                    }
                }
            } message: {
                Text(MacSiteDataText.t(
                    "将停止记住此网站，并立即从所有打开的标签页中移除此网站的存储。",
                    "This stops remembering the site and immediately removes its stored data from every open tab."
                ))
            }
        )
    }
}
