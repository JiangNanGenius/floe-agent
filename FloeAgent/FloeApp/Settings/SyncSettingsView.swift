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
    /// Live engine truth while this screen is open. The cached
    /// `SettingsCenter` value is refreshed on load; iCloud Keychain secrets
    /// can still land afterwards, so the status row follows the engine's
    /// arrival re-checks instead of freezing on a stale "waiting" state.
    @State private var liveConfigSyncStatus: SyncStatus?
    /// Bumped on every SettingsCenter publication so a suspended poll can
    /// detect that a newer pause/error/toggle value landed while it was
    /// awaiting the engine and must not be applied afterwards.
    @State private var configStatusPublicationGeneration = 0
    /// One-shot flag: the center just published a fresh `.waitingForSecret`
    /// (manual sync, toggle, load) while this screen is open. The mirror loop
    /// spends it on exactly one immediate honest re-check; the engine-owned
    /// arrival monitor remains the only durable re-computation owner.
    @State private var newlyPublishedWaiting = false

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
                Toggle("settings.sync_settings_view.sync_saved_credentials", isOn: Binding(
                    get: { center.savedCredentialsSyncEnabled },
                    set: { value in Task { await changeCredentialSync(to: value) } }
                ))
                .disabled(!center.overallSyncEnabled || center.syncControlBusy)
                .accessibilityIdentifier("settings.sync.saved_credentials")
                Label("settings.sync_settings_view.api_keys_saved_ssh_vnc_keys", systemImage: "key.icloud")
                    .frame(minHeight: FloeTheme.minimumTarget)
            } footer: {
                Text("settings.sync_settings_view.off_by_default_enabling_requires_device")
            }

            if let credentialAuthenticationError {
                Section {
                    Label(credentialAuthenticationError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(FloeTheme.destructive)
                }
            } else if let error = center.syncControlError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(FloeTheme.pending)
                        .textSelection(.enabled)
                    // Exactly one actionable message per failed operation;
                    // retry re-runs the matching saved-credentials request
                    // idempotently and a clean run clears this error.
                    if center.credentialSyncRetryDirection != nil {
                        Button {
                            Task { await center.retrySavedCredentialsSync() }
                        } label: {
                            HStack {
                                Text("settings.sync.saved_credentials.retry")
                                Spacer()
                                if center.syncControlBusy { ProgressView() }
                            }
                        }
                        .disabled(center.syncControlBusy)
                        .accessibilityIdentifier("settings.sync.saved_credentials.retry")
                    }
                }
            }
        }
        .navigationTitle(FloeL10n.l("settings.section.sync"))
        .task {
            await center.load()
            await trackConfigurationStatus()
        }
        .onChange(of: center.configSyncStatus) { _, newValue in
            // A freshly published engine value (sync cycle, toggle, pause)
            // takes precedence; the mirror loop re-reads on its next pass.
            // A newly published wait also arms exactly one immediate
            // re-check, so a resolved-then-re-waiting cycle can never freeze
            // the row even though the .task chain already started once.
            configStatusPublicationGeneration += 1
            liveConfigSyncStatus = nil
            newlyPublishedWaiting = newValue == .waitingForSecret
        }
    }

    /// Single screen-bounded mirror of the engine's live status. Secrets and
    /// CloudKit records arrive independently: the engine-owned arrival
    /// monitor re-derives the credential wait in the background, while this
    /// loop cheaply mirrors it so the row follows late arrivals for as long
    /// as the screen is visible — including a `synced → new waiting → late
    /// arrival` cycle that starts after the first observation exited.
    /// Cancelling this `.task` (navigation away) stops UI polling entirely;
    /// no duplicate durable poll owner is created.
    ///
    /// Every application revalidates the SettingsCenter publication
    /// generation, so a value read BEFORE a pause/error/toggle was published
    /// can never be applied AFTER it.
    @MainActor
    private func trackConfigurationStatus() async {
        let engine = center.environment.configurationSync
        // Entry: one immediate honest per-account re-check. It only ever
        // promotes a cached `.waitingForSecret`; other lifecycle states are
        // returned unchanged.
        let entryGeneration = configStatusPublicationGeneration
        let entryStatus = await engine.refreshStatusIfWaiting()
        if entryGeneration == configStatusPublicationGeneration {
            liveConfigSyncStatus = entryStatus
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { break }
            let recheck = newlyPublishedWaiting
            newlyPublishedWaiting = false
            let cycleGeneration = configStatusPublicationGeneration
            let latest: SyncStatus
            if recheck {
                latest = await engine.refreshStatusIfWaiting()
            } else {
                latest = await engine.status
            }
            if cycleGeneration == configStatusPublicationGeneration {
                liveConfigSyncStatus = latest
            }
        }
    }

    private var effectiveConfigSyncStatus: SyncStatus {
        liveConfigSyncStatus ?? center.configSyncStatus
    }

    private var syncStatusText: String {
        guard center.overallSyncEnabled, center.configurationSyncEnabled else {
            return String(localized: "settings.sync.status.paused")
        }
        switch effectiveConfigSyncStatus {
        case .syncing: return String(localized: "settings.sync.status.syncing")
        case .synced: return String(localized: "settings.sync.status.synced")
        case .paused: return String(localized: "settings.sync.status.paused")
        case .waitingForSecret: return String(localized: "settings.sync.status.waiting_secret")
        case .error: return String(localized: "settings.sync.status.error")
        }
    }

    private func changeCredentialSync(to enabled: Bool) async {
        // Each new attempt owns the error area outright: a stale auth or
        // sync message must never linger beside the result of this one.
        credentialAuthenticationError = nil
        if enabled {
            do {
                guard try await DeviceOwnerAuthenticator.authenticate(
                    reason: FloeL10n.l("settings.sync_settings_view.sync_explicitly_saved_keys_and_website")
                ) else { return }
            } catch {
                // The raw LocalAuthentication error stays in the log; the
                // row shows concise user copy only.
                FloeLogger(category: .sync).error("Saved credentials device owner authentication failed")
                credentialAuthenticationError = FloeL10n.l("settings.sync.saved_credentials.auth_failed")
                return
            }
        }
        // The sync operation's own error is rendered by the single
        // `center.syncControlError` section below; mirroring it into the
        // authentication state here previously showed the same message
        // twice (red and yellow) for one failure.
        await center.setSavedCredentialsSyncEnabled(enabled)
    }

    private var canSynchronizeManually: Bool {
        center.overallSyncEnabled
            && center.configurationSyncEnabled
            && !center.syncControlBusy
            && !isSynchronizing
    }

    private var syncStatusColor: Color {
        switch effectiveConfigSyncStatus {
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
