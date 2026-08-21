// FloeApp — Dedicated iCloud synchronization settings.

// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeSyncCore
import LocalAuthentication

struct SyncSettingsView: View {
    @ObservedObject var center: SettingsCenter
    @State private var isSynchronizing = false
    @State private var credentialAuthenticationError: String?

    var body: some View {
        Form {
            Section {
                Toggle("settings.sync.enabled", isOn: Binding(
                    get: { center.overallSyncEnabled },
                    set: { value in
                        center.setOverallSyncEnabled(value)
                    }
                ))
                .accessibilityIdentifier("settings.sync.master")
                .disabled(center.syncControlBusy)
                .frame(minHeight: FloeTheme.minimumTarget)

                LabeledContent("settings.sync.icloud_status") {
                    capabilityText(center.iCloudDrive)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            } header: {
                Text("settings.sync.master.header")
            } footer: {
                Text("settings.sync.master.footer")
            }

            Section {
                Toggle("settings.sync.configuration.enabled", isOn: Binding(
                    get: { center.configurationSyncEnabled },
                    set: { value in
                        center.setConfigurationSyncEnabled(value)
                    }
                ))
                .accessibilityIdentifier("settings.sync.configuration")
                .disabled(!center.overallSyncEnabled || center.syncControlBusy)
                .frame(minHeight: FloeTheme.minimumTarget)

                LabeledContent("settings.sync.configuration.status") {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(syncStatusText)
                            .foregroundStyle(syncStatusColor)
                        if let lastSync = center.configSyncLastSyncAt {
                            Text(lastSync, style: .relative)
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)

                Button {
                    Task {
                        isSynchronizing = true
                        await center.synchronizeConfiguration()
                        isSynchronizing = false
                    }
                } label: {
                    HStack {
                        Text("settings.sync.now")
                        Spacer()
                        if isSynchronizing { ProgressView() }
                    }
                }
                .accessibilityIdentifier("settings.sync.now")
                .accessibilityValue(canSynchronizeManually ? "available" : "disabled")
                .disabled(
                    !canSynchronizeManually
                )
                .frame(minHeight: FloeTheme.minimumTarget)
            } header: {
                Text("settings.sync.configuration.header")
            } footer: {
                Text("settings.sync.configuration.footer")
            }

            Section {
                Toggle("同步已保存凭据", isOn: Binding(
                    get: { center.savedCredentialsSyncEnabled },
                    set: { value in Task { await changeCredentialSync(to: value) } }
                ))
                .disabled(!center.overallSyncEnabled || center.syncControlBusy)
                .accessibilityIdentifier("settings.sync.saved_credentials")
                Label("API Key、已保存 SSH/VNC 密钥和网页密码仅通过 iCloud Keychain 同步。任务和项目临时凭据永不上传。", systemImage: "key.icloud")
                    .frame(minHeight: FloeTheme.minimumTarget)
            } footer: {
                Text("默认关闭。启用需要验证设备身份；不可导出的设备密钥仍只存在于当前设备。")
            }

            if let credentialAuthenticationError {
                Section { Text(credentialAuthenticationError).foregroundStyle(FloeTheme.destructive) }
            }

            if let error = center.syncControlError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(FloeTheme.pending)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("settings.section.sync")
        .task { await center.load() }
    }

    private var syncStatusText: String {
        guard center.overallSyncEnabled, center.configurationSyncEnabled else {
            return String(localized: "settings.sync.status.paused")
        }
        switch center.configSyncStatus {
        case .syncing: return String(localized: "settings.sync.status.syncing")
        case .synced: return String(localized: "settings.sync.status.synced")
        case .paused: return String(localized: "settings.sync.status.paused")
        case .waitingForSecret: return String(localized: "settings.sync.status.waiting_secret")
        case .error: return String(localized: "settings.sync.status.error")
        }
    }

    private func changeCredentialSync(to enabled: Bool) async {
        if enabled {
            do {
                guard try await DeviceOwnerAuthenticator.authenticate(
                    reason: "同步已明确保存的密钥和网页密码"
                ) else { return }
            } catch {
                credentialAuthenticationError = error.localizedDescription
                return
            }
        }
        await center.setSavedCredentialsSyncEnabled(enabled)
        credentialAuthenticationError = center.syncControlError
    }

    private var canSynchronizeManually: Bool {
        center.overallSyncEnabled
            && center.configurationSyncEnabled
            && !center.syncControlBusy
            && !isSynchronizing
    }

    private var syncStatusColor: Color {
        switch center.configSyncStatus {
        case .synced: FloeTheme.success
        case .error: FloeTheme.destructive
        case .syncing: FloeTheme.primary
        case .paused, .waitingForSecret: .secondary
        }
    }

    @ViewBuilder
    private func capabilityText(_ state: CapabilityState) -> some View {
        switch state {
        case .available:
            Label("settings.sync.icloud.available", systemImage: "checkmark.circle.fill")
                .foregroundStyle(FloeTheme.success)
        case .unavailable:
            Text("settings.sync.icloud.unavailable").foregroundStyle(.secondary)
        case .unknown:
            Text("settings.capability.unknown").foregroundStyle(FloeTheme.unknown)
        }
    }
}
#endif
