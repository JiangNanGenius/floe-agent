// SPDX-License-Identifier: MPL-2.0

import CloudKit
import FloeCore
import FloeSync
import LocalAuthentication
import SwiftUI

struct MacICloudConfigurationView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    @ObservedObject var bridge: BridgeAppModel
    @State private var preferences = SyncControlPreferences()
    @State private var busy = false
    @State private var status: LocalizedStringKey?
    @State private var result: ResultSummary?

    private struct ResultSummary {
        let models: Int
        let providerKeys: Int
        let savedCredentials: Int
        let waiting: Int
    }

    var body: some View {
        Form {
            Section("mac.icloud.configurationTitle") {
                Toggle("mac.icloud.configurationEnabled", isOn: Binding(
                    get: { preferences.overallEnabled && preferences.configurationEnabled },
                    set: setConfigurationEnabled
                ))
                Text("mac.icloud.configurationHelp").foregroundStyle(.secondary)
                HStack {
                    Button("mac.icloud.downloadConfiguration") { synchronize(upload: false) }
                    Button("mac.icloud.uploadConfiguration") { synchronize(upload: true) }
                }
                .disabled(!preferences.overallEnabled || !preferences.configurationEnabled || busy
                          || !MacICloudModelSync.hasCloudKitEntitlement || !workspace.isReady)
            }
            Section("mac.icloud.credentialsTitle") {
                Toggle("mac.icloud.credentialsEnabled", isOn: Binding(
                    get: { preferences.savedCredentialsEnabled },
                    set: setCredentialsEnabled
                ))
                .disabled(!preferences.configurationEnabled || busy || !MacICloudModelSync.hasCredentialEntitlement)
                Text("mac.icloud.credentialsHelp").foregroundStyle(.secondary)
                if !MacICloudModelSync.hasCredentialEntitlement {
                    Text("mac.icloud.credentialsUnavailable").foregroundStyle(.secondary)
                }
            }
            if busy || status != nil || result != nil {
                Section("mac.icloud.statusTitle") {
                    if busy { ProgressView("mac.icloud.working") }
                    if let status { Text(status).foregroundStyle(.secondary) }
                    if let result {
                        Text(String(format: String(localized: "mac.icloud.modelsReceipt"), result.models))
                        if preferences.savedCredentialsEnabled {
                            Text(String(format: String(localized: "mac.icloud.credentialsReceipt"),
                                        result.providerKeys, result.savedCredentials, result.waiting))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { preferences = workspace.cloudSyncPreferences }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in clearCredentialAuthorization() }
        .accessibilityIdentifier("mac.settings.icloud")
        #if FLOE_MAC_HOST_SMOKE
        .onAppear { bridge.smokeCloudSettingsMounted = true }
        .onDisappear { bridge.smokeCloudSettingsMounted = false }
        #endif
    }

    private func setConfigurationEnabled(_ enabled: Bool) {
        guard !busy else { return }
        preferences.overallEnabled = enabled
        preferences.configurationEnabled = enabled
        if !enabled { preferences.savedCredentialsEnabled = false }
        workspace.setCloudSyncPreferences(preferences)
        result = nil
        status = nil
    }

    private func clearCredentialAuthorization() {
        preferences.savedCredentialsEnabled = false
        workspace.setCloudSyncPreferences(preferences)
        result = nil
    }

    private func setCredentialsEnabled(_ enabled: Bool) {
        guard !busy else { return }
        status = nil
        result = nil
        guard enabled else { clearCredentialAuthorization(); return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let context = LAContext()
            do {
                let reason = String(localized: "mac.icloud.credentialsAuthentication")
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return }
                let account = try await MacICloudModelSync.authorizeCredentialAccount()
                preferences.savedCredentialsEnabled = true
                workspace.setCloudSyncPreferences(preferences, credentialAccount: account)
            } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                return
            } catch {
                status = message(error)
            }
        }
    }

    private func synchronize(upload: Bool) {
        guard !busy else { return }
        busy = true
        status = nil
        result = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                var output: MacCloudConfiguration?
                if upload {
                    let settings = try MacSharedSettingsSnapshot(
                        appearance: bridge.appearance.rawValue, verifyAnswers: workspace.verifyAgentAnswers,
                        runningInput: workspace.runningInputMode
                    ).records()
                    output = workspace.configurationForCloud(settings: settings,
                        videoModelID: bridge.macWorkspace?.videos?.providerSelection?.modelID)
                }
                let received = try await workspace.synchronizeCloudConfiguration(publishing: output,
                    includeCredentials: preferences.savedCredentialsEnabled)
                if !upload {
                    guard workspace.applyCloudConfiguration(received) else { throw MacICloudModelError.invalidProvider }
                    let settings = MacSharedSettingsSnapshot(records: received.configuration.settings)
                    if let appearance = settings.appearance.flatMap(BridgeAppModel.Appearance.init(rawValue:)) {
                        bridge.appearance = appearance
                    }
                    if let verify = settings.verifyAnswers { workspace.verifyAgentAnswers = verify }
                    if let mode = settings.runningInput { workspace.runningInputMode = mode }
                    if let id = received.configuration.preferences?.defaultVideoModelID,
                       let route = workspace.providers.first(where: { $0.model.id == id && $0.model.supportsVideoGenerationSurface }) {
                        try bridge.macWorkspace?.videos?.bindProvider(accountID: route.profile.id, modelID: route.model.id)
                    }
                }
                result = .init(models: received.configuration.entries.count, providerKeys: received.providerKeys.count,
                    savedCredentials: received.savedCredentialCount, waiting: received.waitingForCredentialCount)
                status = upload ? "mac.icloud.configurationUploaded" : "mac.icloud.configurationDownloaded"
            } catch {
                status = message(error)
                if case .accountChanged? = error as? MacICloudModelError { clearCredentialAuthorization() }
            }
        }
    }

    private func message(_ error: Error) -> LocalizedStringKey {
        switch error as? MacICloudModelError {
        case .setupRequired: "mac.icloud.setupRequired"
        case .signInRequired: "mac.icloud.signIn"
        case .accountChanged: "mac.icloud.accountChanged"
        case .invalidProvider: "mac.icloud.providerConflict"
        case .uploadPending: "mac.icloud.uploadPending"
        case .credentialAccessUnavailable: "mac.icloud.credentialsUnavailable"
        default: "mac.icloud.unavailable"
        }
    }
}

/// Typed projection for the iPad settings that have the same meaning on Mac.
struct MacSharedSettingsSnapshot {
    static let appearanceKey = ApplicationSettingPolicy.defaultsPrefix + "floe.settings.appearance"
    static let verifyKey = ApplicationSettingPolicy.databasePrefix + AppSettingsKey.verifyFinalAnswer
    static let inputKey = ApplicationSettingPolicy.databasePrefix + AppSettingsKey.runningInputMode

    var appearance: String?
    var verifyAnswers: Bool?
    var runningInput: RunningInputMode?

    init(appearance: String?, verifyAnswers: Bool?, runningInput: RunningInputMode?) {
        self.appearance = appearance
        self.verifyAnswers = verifyAnswers
        self.runningInput = runningInput
    }

    init(records: [ApplicationSettingRecord]) {
        let decoder = JSONDecoder()
        for record in records {
            guard let canonical = try? record.validated(), let data = canonical.value else { continue }
            switch canonical.key {
            case Self.appearanceKey: appearance = try? decoder.decode(String.self, from: data)
            case Self.verifyKey: verifyAnswers = try? decoder.decode(Bool.self, from: data)
            case Self.inputKey: runningInput = try? decoder.decode(RunningInputMode.self, from: data)
            default: break
            }
        }
    }

    func records() throws -> [ApplicationSettingRecord] {
        var settings: [ApplicationSettingRecord] = []
        if let appearance { settings.append(try make(Self.appearanceKey, value: appearance)) }
        if let verifyAnswers { settings.append(try make(Self.verifyKey, value: verifyAnswers)) }
        if let runningInput { settings.append(try make(Self.inputKey, value: runningInput)) }
        return settings
    }

    private func make(_ key: String, value: some Encodable) throws -> ApplicationSettingRecord {
        try ApplicationSettingRecord(key: key, value: ApplicationSettingRecord.encodeValue(value)).validated()
    }
}
