// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeCore

enum APNsText {
    nonisolated static func t(_ chinese: String, _ english: String) -> String { FloeL10n.isChinese ? chinese : english }
    static func channel(_ channel: APNsInstallChannel) -> String {
        switch channel {
        case .testFlight: "TestFlight"
        case .appStore: "App Store"
        case .development: t("开发安装", "Development")
        case .unknown: t("暂未识别", "Not identified")
        }
    }
    static func authorization(_ authorization: APNsVisibleAuthorization) -> String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: t("已允许", "Allowed")
        case .denied: t("未允许", "Not allowed")
        case .notDetermined: t("尚未询问", "Not requested")
        case .unknown: t("暂未确认", "Unconfirmed")
        }
    }
}

/// Embedded in the EXISTING background/notification settings Form.
struct APNsSettingsSection: View {
    @ObservedObject var center: APNsCenter
    @Environment(\.openURL) private var openURL
    var body: some View {
        Section {
            Toggle(APNsText.t("推送", "Push"), isOn: .init(get: { center.preferences.enabled },
                set: { value in Task { await center.setEnabled(value) } }))
                .accessibilityIdentifier("push.enabled")
            Toggle(APNsText.t("版本更新提醒", "Version update reminders"), isOn: .init(get: { center.preferences.versionReminders },
                set: { value in Task { await center.setVersionReminders(value) } }))
                .disabled(!center.preferences.enabled)
                .accessibilityIdentifier("push.versionReminders")
            if center.preferences.enabled && center.preferences.versionReminders && center.visibleAuthorization == .denied {
                Button(APNsText.t("前往系统设置", "Open system settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            NavigationLink { APNsSettingsView(center: center) } label: {
                Label(APNsText.t("状态与详情", "Status and details"), systemImage: "info.circle")
            }.accessibilityIdentifier("push.details")
        } header: { Text(APNsText.t("推送", "Push")) } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(APNsText.t("帮助定时任务在后台运行。", "Helps scheduled tasks run in the background."))
                Text(statusText)
            }
        }
        .task { await center.reconcile() }
    }
    private var statusText: String {
        if !center.preferences.enabled { return APNsText.t("推送已关闭。", "Push is off.") }
        if let failure = center.failure { return failure }
        if center.syncState == "unconfigured" { return APNsText.t("服务尚未连接。", "The service is not connected yet.") }
        if center.preferences.versionReminders && center.visibleAuthorization == .denied {
            return APNsText.t("版本提醒未获允许，后台刷新仍可登记。", "Version reminders are not allowed; background refresh can still register.")
        }
        if !center.backgroundRefreshAvailable { return APNsText.t("后台刷新当前不可用。", "Background refresh is currently unavailable.") }
        return center.status().serverConnected
            ? APNsText.t("已连接，实际后台运行由系统安排。", "Connected. The system decides when background work runs.")
            : APNsText.t("正在确认连接状态。", "Checking the connection.")
    }
}

struct APNsSettingsView: View {
    @ObservedObject var center: APNsCenter
    @Environment(\.openURL) private var openURL
    @State private var diagnosticsExpanded = false

    var body: some View {
        Form {
            Section(APNsText.t("连接", "Connection")) {
                LabeledContent(APNsText.t("推送", "Push"), value: connectionText)
                if center.preferences.enabled, !center.status().serverConnected, let failure = center.failure {
                    Text(failure).foregroundStyle(.secondary)
                }
                if center.preferences.enabled {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let waiting = (center.status().nextRegistrationAttemptAt ?? .distantPast) > context.date
                        Button(waiting ? APNsText.t("稍后重试", "Try again later") : APNsText.t("重试连接", "Retry connection")) {
                            Task { await center.reload() }
                        }
                        .disabled(waiting || center.syncState == "connecting")
                        .accessibilityIdentifier("push.retry")
                    }
                }
            }
            if center.preferences.enabled && ((center.preferences.versionReminders && center.visibleAuthorization == .denied)
                || !center.backgroundRefreshAvailable) {
                Section {
                    if center.preferences.versionReminders && center.visibleAuthorization == .denied {
                        Text(APNsText.t("允许通知后才能收到版本更新提醒。", "Allow notifications to receive version update reminders."))
                    }
                    if !center.backgroundRefreshAvailable {
                        Text(APNsText.t("请在系统设置中允许后台刷新。", "Allow background refresh in system settings."))
                    }
                    Button(APNsText.t("前往系统设置", "Open system settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            Section {
                DisclosureGroup(APNsText.t("诊断详情", "Diagnostics"), isExpanded: $diagnosticsExpanded) {
                    diagnostics
                }
                .accessibilityIdentifier("push.diagnostics")
            }
        }
        .navigationTitle(APNsText.t("推送详情", "Push details"))
        .accessibilityIdentifier("push.settings")
        .task { await center.reconcile() }
    }

    private var connectionText: String {
        if !center.preferences.enabled { return APNsText.t("已关闭", "Off") }
        if center.status().serverConnected { return APNsText.t("已连接", "Connected") }
        if center.syncState == "connecting" || center.syncState == "retrying" {
            return APNsText.t("正在连接", "Connecting")
        }
        return APNsText.t("尚未连接", "Not connected")
    }

    @ViewBuilder private var diagnostics: some View {
        LabeledContent(APNsText.t("系统通知登记", "System notification registration"), value: center.status().deviceRegistered
            ? APNsText.t("已就绪", "Ready") : APNsText.t("尚未确认", "Unconfirmed"))
        LabeledContent(APNsText.t("服务登记", "Service registration"), value: center.status().serverConnected
            ? APNsText.t("已确认", "Confirmed") : APNsText.t("尚未连接", "Not connected"))
        if let date = center.status().nextRegistrationAttemptAt, date > Date() {
            LabeledContent(APNsText.t("下次可重试", "Retry available")) { Text(date, style: .relative) }
        }
        if let date = center.status().lastServerAcceptedAt {
            LabeledContent(APNsText.t("服务最近接受登记", "Last accepted registration")) { Text(date, style: .relative) }
        }
        if let date = center.state.receipt?.leaseExpiresAt {
            LabeledContent(APNsText.t("登记有效期", "Registration expiry")) { Text(date, style: .relative) }
        }
        LabeledContent(APNsText.t("可见通知", "Visible notifications"), value: APNsText.authorization(center.visibleAuthorization))
        LabeledContent(APNsText.t("后台刷新", "Background refresh"), value: center.backgroundRefreshAvailable
            ? APNsText.t("可用", "Available") : APNsText.t("当前不可用", "Unavailable"))
        LabeledContent(APNsText.t("安装通道", "Install channel"), value: APNsText.channel(center.channel))
        LabeledContent(APNsText.t("待运行的计划", "Scheduled work"), value: center.eligibilitySnapshot.map {
            $0.eligible ? APNsText.t("有", "Present") : APNsText.t("无", "None")
        } ?? APNsText.t("尚未确认", "Unconfirmed"))
        LabeledContent("APNs", value: center.signingEnvironment.rawValue)
        LabeledContent(APNsText.t("同步状态", "Sync state"), value: center.syncState)
        if case .some(.nativeVerification(let diagnostic)) = center.state.registrationFailure {
            LabeledContent(APNsText.t("验证阶段", "Verification stage"), value: diagnostic.stage.rawValue)
            LabeledContent(APNsText.t("验证结果", "Verification result"), value: diagnostic.code.rawValue)
        }
        if let date = center.status().lastReceivedAt {
            LabeledContent(APNsText.t("App 收到通知", "App received a notification")) { Text(date, style: .relative) }
        } else {
            Text(APNsText.t("尚无收到通知的记录。", "No notifications have been received yet.")).foregroundStyle(.secondary)
        }
        if let outcome = center.status().lastWakeOutcome {
            LabeledContent(APNsText.t("后台检查", "Background check"), value: outcomeText(outcome))
        }
        Text(APNsText.t("系统登记、服务连接和收到通知是不同阶段。后台运行由系统安排。",
            "System registration, service connection and notification receipt are separate stages. The system schedules background work."))
            .font(.footnote).foregroundStyle(.secondary)
    }

    private func outcomeText(_ value: APNsWakeOutcome) -> String {
        switch value {
        case .newData: APNsText.t("检查已完成", "Check completed")
        case .noData: APNsText.t("没有需要处理的工作", "No work needed")
        case .deferred: APNsText.t("留待下次继续", "Deferred until the next opportunity")
        case .rejected: APNsText.t("本次检查未继续", "This check did not continue")
        }
    }
}

struct APNsReleaseNotesView: View {
    let release: APNsReleaseRecord
    @ObservedObject var center: APNsCenter
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    private var installed: Bool { APNsInstalledVersion.current(channel: center.channel).alreadyInstalled(release) }
    private var targetURL: URL? { release.channel == .testFlight ? center.testFlightURL : center.appStoreURL }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(release.title).font(.title2.bold())
                    Label("\(release.version) (\(release.build)) · \(APNsText.channel(release.channel))", systemImage: "app.badge")
                        .foregroundStyle(.secondary)
                    Text(release.notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    if !release.isInstallable {
                        Label(APNsText.t("此版本当前不可安装", "This version is no longer available to install"), systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else if installed {
                        Label(APNsText.t("已是此版本或更新版本", "This version or a newer one is installed"), systemImage: "checkmark.circle")
                    } else {
                        Button(release.channel == .testFlight ? APNsText.t("打开 TestFlight", "Open TestFlight") : APNsText.t("打开 App Store", "Open App Store")) {
                            if let targetURL { openURL(targetURL) }
                        }.buttonStyle(.borderedProminent).disabled(targetURL == nil)
                        if targetURL == nil { Text(APNsText.t("更新入口暂不可用。", "The update page is not available yet.")).font(.footnote).foregroundStyle(.secondary) }
                    }
                }.padding(24)
            }
            .navigationTitle(APNsText.t("版本说明", "Release notes"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(APNsText.t("完成", "Done")) { dismiss() } } }
        }
    }
}

private struct APNsReleasePresentationModifier: ViewModifier {
    @ObservedObject var center: APNsCenter
    func body(content: Content) -> some View {
        content.sheet(item: $center.presentedRelease) { release in APNsReleaseNotesView(release: release, center: center) }
    }
}
extension View {
    /// Install ONCE on the stable outer App shell, not on a settings row.
    func apnsReleasePresentation(center: APNsCenter) -> some View { modifier(APNsReleasePresentationModifier(center: center)) }
}
#endif
