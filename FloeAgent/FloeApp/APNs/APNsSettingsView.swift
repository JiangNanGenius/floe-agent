// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeCore

enum APNsText {
    nonisolated static func t(_ chinese: String, _ english: String) -> String { FloeL10n.bilingual(chinese: chinese, english: english) }
    static func channel(_ channel: APNsInstallChannel) -> String {
        switch channel {
        case .testFlight: "TestFlight"
        case .appStore: "App Store"
        case .development: FloeL10n.l("app.apns_settings_view.development")
        case .unknown: FloeL10n.l("app.apns_settings_view.not_identified")
        }
    }
    static func authorization(_ authorization: APNsVisibleAuthorization) -> String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: FloeL10n.l("app.apns_settings_view.allowed")
        case .denied: FloeL10n.l("app.apns_settings_view.not_allowed")
        case .notDetermined: FloeL10n.l("app.apns_settings_view.not_requested")
        case .unknown: FloeL10n.l("app.apns_settings_view.unconfirmed")
        }
    }
}

/// Embedded in the EXISTING background/notification settings Form.
struct APNsSettingsSection: View {
    @ObservedObject var center: APNsCenter
    @Environment(\.openURL) private var openURL
    var body: some View {
        Section {
            Toggle(FloeL10n.l("app.apns_settings_view.push"), isOn: .init(get: { center.preferences.enabled },
                set: { value in Task { await center.setEnabled(value) } }))
                .accessibilityIdentifier("push.enabled")
            Toggle(FloeL10n.l("app.apns_settings_view.version_update_reminders"), isOn: .init(get: { center.preferences.versionReminders },
                set: { value in Task { await center.setVersionReminders(value) } }))
                .disabled(!center.preferences.enabled)
                .accessibilityIdentifier("push.versionReminders")
            if center.preferences.enabled && center.preferences.versionReminders && center.visibleAuthorization == .denied {
                Button(FloeL10n.l("app.apns_settings_view.open_system_settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            NavigationLink { APNsSettingsView(center: center) } label: {
                Label(FloeL10n.l("app.apns_settings_view.status_and_details"), systemImage: "info.circle")
            }.accessibilityIdentifier("push.details")
        } header: { Text(FloeL10n.l("app.apns_settings_view.push")) } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(FloeL10n.l("app.apns_settings_view.helps_scheduled_tasks_run_in"))
                Text(statusText)
            }
        }
        .task { await center.reconcile() }
    }
    private var statusText: String {
        if !center.preferences.enabled { return FloeL10n.l("app.apns_settings_view.push_is_off") }
        if let failure = center.failure { return failure }
        if center.syncState == "unconfigured" { return FloeL10n.l("app.apns_settings_view.the_service_is_not_connected") }
        if center.preferences.versionReminders && center.visibleAuthorization == .denied {
            return FloeL10n.l("app.apns_settings_view.version_reminders_are_not_allowed")
        }
        if !center.backgroundRefreshAvailable { return FloeL10n.l("app.apns_settings_view.background_refresh_is_currently_unavailable") }
        return center.status().serverConnected
            ? FloeL10n.l("app.apns_settings_view.connected_the_system_decides_when")
            : FloeL10n.l("app.apns_settings_view.checking_the_connection")
    }
}

struct APNsSettingsView: View {
    @ObservedObject var center: APNsCenter
    @Environment(\.openURL) private var openURL
    @State private var diagnosticsExpanded = false

    var body: some View {
        Form {
            Section(FloeL10n.l("home.connection")) {
                LabeledContent(FloeL10n.l("app.apns_settings_view.push"), value: connectionText)
                if center.preferences.enabled, !center.status().serverConnected, let failure = center.failure {
                    Text(failure).foregroundStyle(.secondary)
                }
                if center.preferences.enabled {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let waiting = (center.status().nextRegistrationAttemptAt ?? .distantPast) > context.date
                        Button(waiting ? FloeL10n.l("app.apns_settings_view.try_again_later") : FloeL10n.l("app.apns_settings_view.retry_connection")) {
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
                        Text(FloeL10n.l("app.apns_settings_view.allow_notifications_to_receive_version"))
                    }
                    if !center.backgroundRefreshAvailable {
                        Text(FloeL10n.l("app.apns_settings_view.allow_background_refresh_in_system"))
                    }
                    Button(FloeL10n.l("app.apns_settings_view.open_system_settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            Section {
                DisclosureGroup(FloeL10n.l("app.apns_settings_view.diagnostics"), isExpanded: $diagnosticsExpanded) {
                    diagnostics
                }
                .accessibilityIdentifier("push.diagnostics")
            }
        }
        .navigationTitle(FloeL10n.l("app.apns_settings_view.push_details"))
        .accessibilityIdentifier("push.settings")
        .task { await center.reconcile() }
    }

    private var connectionText: String {
        if !center.preferences.enabled { return FloeL10n.l("app.apns_settings_view.off") }
        if center.status().serverConnected { return FloeL10n.l("connectors.connected") }
        if center.syncState == "connecting" || center.syncState == "retrying" {
            return FloeL10n.l("app.apns_settings_view.connecting")
        }
        return FloeL10n.l("app.apns_settings_view.not_connected")
    }

    @ViewBuilder private var diagnostics: some View {
        LabeledContent(FloeL10n.l("app.apns_settings_view.system_notification_registration"), value: center.status().deviceRegistered
            ? FloeL10n.l("background.location.state.ready") : FloeL10n.l("app.apns_settings_view.unconfirmed_2"))
        LabeledContent(FloeL10n.l("app.apns_settings_view.service_registration"), value: center.status().serverConnected
            ? FloeL10n.l("app.apns_settings_view.confirmed") : FloeL10n.l("app.apns_settings_view.not_connected"))
        if let date = center.status().nextRegistrationAttemptAt, date > Date() {
            LabeledContent(FloeL10n.l("app.apns_settings_view.retry_available")) { Text(date, style: .relative) }
        }
        if let date = center.status().lastServerAcceptedAt {
            LabeledContent(FloeL10n.l("app.apns_settings_view.last_accepted_registration")) { Text(date, style: .relative) }
        }
        if let date = center.state.receipt?.leaseExpiresAt {
            LabeledContent(FloeL10n.l("app.apns_settings_view.registration_expiry")) { Text(date, style: .relative) }
        }
        LabeledContent(FloeL10n.l("app.apns_settings_view.visible_notifications"), value: APNsText.authorization(center.visibleAuthorization))
        LabeledContent(FloeL10n.l("app.apns_settings_view.background_refresh"), value: center.backgroundRefreshAvailable
            ? FloeL10n.l("design.panel.capability_available") : FloeL10n.l("app.apns_settings_view.unavailable"))
        LabeledContent(FloeL10n.l("app.apns_settings_view.install_channel"), value: APNsText.channel(center.channel))
        LabeledContent(FloeL10n.l("app.apns_settings_view.scheduled_work"), value: center.eligibilitySnapshot.map {
            $0.eligible ? FloeL10n.l("app.apns_settings_view.present") : FloeL10n.l("cad.paint.noTexture")
        } ?? FloeL10n.l("app.apns_settings_view.unconfirmed_2"))
        LabeledContent("APNs", value: center.signingEnvironment.rawValue)
        LabeledContent(FloeL10n.l("app.apns_settings_view.sync_state"), value: center.syncState)
        if case .some(.nativeVerification(let diagnostic)) = center.state.registrationFailure {
            LabeledContent(FloeL10n.l("app.apns_settings_view.verification_stage"), value: diagnostic.stage.rawValue)
            LabeledContent(FloeL10n.l("app.apns_settings_view.verification_result"), value: diagnostic.code.rawValue)
        }
        if let date = center.status().lastReceivedAt {
            LabeledContent(FloeL10n.l("app.apns_settings_view.app_received_a_notification")) { Text(date, style: .relative) }
        } else {
            Text(FloeL10n.l("app.apns_settings_view.no_notifications_have_been_received")).foregroundStyle(.secondary)
        }
        if let outcome = center.status().lastWakeOutcome {
            LabeledContent(FloeL10n.l("app.apns_settings_view.background_check"), value: outcomeText(outcome))
        }
        Text(FloeL10n.l("app.apns_settings_view.system_registration_service_connection_and"))
            .font(.footnote).foregroundStyle(.secondary)
    }

    private func outcomeText(_ value: APNsWakeOutcome) -> String {
        switch value {
        case .newData: FloeL10n.l("app.apns_settings_view.check_completed")
        case .noData: FloeL10n.l("app.apns_settings_view.no_work_needed")
        case .deferred: FloeL10n.l("app.apns_settings_view.deferred_until_the_next_opportunity")
        case .rejected: FloeL10n.l("app.apns_settings_view.this_check_did_not_continue")
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
                        Label(FloeL10n.l("app.apns_settings_view.this_version_is_no_longer"), systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else if installed {
                        Label(FloeL10n.l("app.apns_settings_view.this_version_or_a_newer"), systemImage: "checkmark.circle")
                    } else {
                        Button(release.channel == .testFlight ? FloeL10n.l("app.apns_settings_view.open_testflight") : FloeL10n.l("app.apns_settings_view.open_app_store")) {
                            if let targetURL { openURL(targetURL) }
                        }.buttonStyle(.borderedProminent).disabled(targetURL == nil)
                        if targetURL == nil { Text(FloeL10n.l("app.apns_settings_view.the_update_page_is_not")).font(.footnote).foregroundStyle(.secondary) }
                    }
                }.padding(24)
            }
            .navigationTitle(FloeL10n.l("app.apns_settings_view.release_notes"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(FloeL10n.l("help.done")) { dismiss() } } }
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
