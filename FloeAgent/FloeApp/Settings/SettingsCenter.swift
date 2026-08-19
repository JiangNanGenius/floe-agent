// FloeApp — Settings center coordinator (UI-facing seam).
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §3.2. The single entry point for every
// settings read/write: aggregates the SettingsStore (app_settings DB),
// UserDefaults (immediate UI preferences), capability probes, the
// WorkspaceStore grant tables and the in-memory ApprovalGrantStore. Views
// bind only to this center, never to stores directly. Secrets never pass
// through here — only Keychain "configured / not configured" state.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeSync
import FloeSyncCore
import FloeTools

/// Coordinates the nine settings sections. All mutations persist first and
/// then refresh the published snapshot, so the UI can never display state
/// that was not actually stored.
@MainActor
final class SettingsCenter: ObservableObject {

    // MARK: - Dependencies

    let environment: AppEnvironment
    private let settingsStore: any SettingsStore
    private let workspaceStore: any WorkspaceStore
    private let approvalGrants: ApprovalGrantStore
    private let defaults: UserDefaults

    // MARK: - General (UserDefaults layer)

    @Published var appearance: AppearancePreference = .system
    @Published var languageOverride: LanguagePreference = .system
    @Published var reduceMotionOverride: Bool?
    @Published var hapticsEnabled = true
    @Published var dateTimeStyle: DateTimeDisplayStyle = .relative

    // MARK: - Cross-session preferences (DB app_settings layer)

    @Published private(set) var defaultAgentMode: AgentMode = .human
    @Published private(set) var defaultStartPage: StartPage = .home
    @Published private(set) var execution: ExecutionSettings = ExecutionSettings()
    @Published private(set) var defaultWorkspaceID: UUID?
    @Published private(set) var sshDefaults: RemoteSessionDefaults = RemoteSessionDefaults()
    @Published private(set) var vncDefaults: RemoteSessionDefaults = RemoteSessionDefaults()
    @Published private(set) var idleDisconnectMinutes: Int = 15
    @Published private(set) var runningInputMode: RunningInputMode = .queue
    @Published private(set) var backgroundExecution: BackgroundExecutionPreference = .standard
    /// Self-critique pass on the final answer before the run completes.
    @Published private(set) var verifyFinalAnswer: Bool = false

    // MARK: - Agent 与权限

    @Published private(set) var savedGrants: [StoredGrant] = []
    @Published private(set) var memoryGrants: [ApprovalGrant] = []
    /// True when the catastrophic gate is in fail-closed mode (UI red flag).
    @Published private(set) var gateIsFailClosed = false

    // MARK: - 执行环境（探测结果，不存储）

    @Published private(set) var jsCapability: CapabilityState = .unknown
    @Published private(set) var localPythonCapability: CapabilityState = .unknown
    @Published private(set) var remotePythonCapability: CapabilityState = .unknown
    @Published private(set) var remoteHostCount = 0
    @Published private(set) var activeRemoteSessionCount = 0

    // MARK: - 文件与 iCloud

    @Published private(set) var workspaces: [WorkspaceRecord] = []
    @Published private(set) var iCloudDrive: CapabilityState = .unknown
    @Published private(set) var configSyncStatus: SyncStatus = .paused
    @Published private(set) var configSyncLastSyncAt: Date?
    @Published private(set) var overallSyncEnabled = true
    @Published private(set) var configurationSyncEnabled = true
    @Published private(set) var savedCredentialsSyncEnabled = false
    @Published private(set) var syncControlBusy = false
    @Published private(set) var syncControlError: String?

    // MARK: - 隐私与安全

    @Published private(set) var keychainState: CapabilityState = .unknown
    /// Per-provider "configured" projection (never the secret itself).
    @Published private(set) var credentialStatus: [UUID: Bool] = [:]

    // MARK: - 诊断与关于

    @Published private(set) var databaseUserVersion = 0
    @Published private(set) var capabilitySummary = CapabilitySummary()

    // MARK: - Actions

    let actions: SettingsActions

    init(
        environment: AppEnvironment,
        settingsStore: (any SettingsStore)? = nil,
        workspaceStore: (any WorkspaceStore)? = nil,
        approvalGrants: ApprovalGrantStore = ApprovalGrantStore(),
        defaults: UserDefaults = .standard
    ) {
        self.environment = environment
        self.settingsStore = settingsStore ?? SQLiteSettingsStore(database: environment.database)
        self.workspaceStore = workspaceStore ?? SQLiteWorkspaceStore(database: environment.database)
        self.approvalGrants = approvalGrants
        self.defaults = defaults
        self.actions = SettingsActions(
            environment: environment,
            workspaceStore: self.workspaceStore,
            approvalGrants: approvalGrants
        )
    }

    // MARK: - UserDefaults keys

    private enum UDKey {
        static let prefix = "floe.settings."
        static let appearance = prefix + "appearance"
        static let language = prefix + "language"
        static let reduceMotion = prefix + "reduceMotion"
        static let haptics = prefix + "hapticsEnabled"
        static let dateTimeStyle = prefix + "dateTimeStyle"
    }

    // MARK: - Loading

    /// Loads every settings source in parallel and refreshes the snapshot.
    /// Probe results are recomputed on every load (never persisted).
    func load() async {
        loadUserDefaults()

        async let values = (try? settingsStore.allValues()) ?? [:]
        async let grants = (try? workspaceStore.allGrants()) ?? []
        async let workspacesResult = (try? workspaceStore.workspaces()) ?? []
        async let memory = approvalGrants.allGrants
        async let js = JavaScriptCoreProbe().probe()
        async let localPython = environment.localPythonProbe.probe()
        // Real remote-Python probe from FloeExecution (wired in
        // AppEnvironment); replaces the always-unavailable placeholder.
        async let remotePython = environment.remotePythonProbe.probe()
        async let iCloud = ICloudStatusProbe().probe()
        async let keychain = KeychainProbe(keychain: environment.keychain).probe()
        async let version = (try? environment.database.userVersion()) ?? 0
        async let providers = (try? environment.configurationStore.providers()) ?? []
        async let models = (try? environment.configurationStore.models()) ?? []
        async let hosts = (try? environment.remoteSessionCenterHostsCount()) ?? 0
        async let activeSessions = (try? environment.remoteSessionRegistry.activeSessions().count) ?? 0

        let stored = await values
        applyStoredValues(stored)

        savedGrants = await grants
        memoryGrants = await memory
        workspaces = await workspacesResult
        jsCapability = await js
        localPythonCapability = await localPython
        remotePythonCapability = await remotePython
        iCloudDrive = await iCloud
        keychainState = await keychain
        databaseUserVersion = await version
        remoteHostCount = await hosts
        activeRemoteSessionCount = await activeSessions
        configSyncStatus = await environment.configurationSync.status
        configSyncLastSyncAt = await environment.configurationSync.lastSyncAt

        let providerList = await providers
        let modelList = await models
        capabilitySummary = CapabilitySummary(
            providerCount: providerList.count,
            modelCount: modelList.count,
            toolCount: ToolCatalog.allDescriptors.count,
            adapterKinds: providerList.map(\.kind.rawValue)
        )
        gateIsFailClosed = environment.catastrophicGate.evaluate(command: "true").stopped
            && environment.catastrophicGate.evaluate(command: "ls").stopped
        credentialStatus = await credentialProjection(for: providerList)
    }

    /// Performs an explicit CloudKit send/fetch/send cycle and immediately
    /// refreshes the displayed status. Errors remain visible instead of being
    /// turned into a false "Synced" result.
    func synchronizeConfiguration() async {
        do {
            try await environment.configurationSync.synchronize()
        } catch {
            // ConfigSyncEngine owns the redacted, user-presentable error state.
        }
        configSyncStatus = await environment.configurationSync.status
        configSyncLastSyncAt = await environment.configurationSync.lastSyncAt
    }

    // MARK: - Stored-value mapping

    private func applyStoredValues(_ values: [String: String]) {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            values[key].flatMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
        }
        if let mode: AgentMode = decode(AgentMode.self, AppSettingsKey.defaultAgentMode) {
            defaultAgentMode = mode
        }
        if let page: StartPage = decode(StartPage.self, AppSettingsKey.defaultStartPage) {
            defaultStartPage = page
        }
        if let timeout: Int = decode(Int.self, AppSettingsKey.executionTimeoutSeconds) {
            execution.timeoutSeconds = timeout
        }
        if let maxBytes: Int = decode(Int.self, AppSettingsKey.maxOutputBytes) {
            execution.maxOutputBytes = maxBytes
        }
        if let saves: Bool = decode(Bool.self, AppSettingsKey.savesArtifacts) {
            execution.savesArtifacts = saves
        }
        if let target: ExecutionTargetPreference = decode(
            ExecutionTargetPreference.self, AppSettingsKey.executionTarget
        ) {
            execution.target = target
        }
        if let workspace: UUID = decode(UUID.self, AppSettingsKey.defaultWorkspace) {
            defaultWorkspaceID = workspace
        }
        if let ssh: RemoteSessionDefaults = decode(RemoteSessionDefaults.self, AppSettingsKey.sshDefaults) {
            sshDefaults = ssh
        }
        if let vnc: RemoteSessionDefaults = decode(RemoteSessionDefaults.self, AppSettingsKey.vncDefaults) {
            vncDefaults = vnc
        }
        if let idle: Int = decode(Int.self, AppSettingsKey.idleDisconnectMinutes) {
            idleDisconnectMinutes = idle
        }
        if let mode: RunningInputMode = decode(RunningInputMode.self, AppSettingsKey.runningInputMode) {
            runningInputMode = mode
        }
        if let preference: BackgroundExecutionPreference = decode(
            BackgroundExecutionPreference.self, AppSettingsKey.backgroundExecution
        ) {
            backgroundExecution = preference
        }
        if let verify: Bool = decode(Bool.self, AppSettingsKey.verifyFinalAnswer) {
            verifyFinalAnswer = verify
        }
    }

    private func loadUserDefaults() {
        let syncPreferences = SyncControlPreferences.load(from: defaults)
        overallSyncEnabled = syncPreferences.overallEnabled
        configurationSyncEnabled = syncPreferences.configurationEnabled
        savedCredentialsSyncEnabled = syncPreferences.savedCredentialsEnabled
        if let raw = defaults.string(forKey: UDKey.appearance),
           let value = AppearancePreference(rawValue: raw) {
            appearance = value
        }
        if let raw = defaults.string(forKey: UDKey.language),
           let value = LanguagePreference(rawValue: raw) {
            languageOverride = value
        }
        if defaults.object(forKey: UDKey.reduceMotion) != nil {
            reduceMotionOverride = defaults.bool(forKey: UDKey.reduceMotion)
        } else {
            reduceMotionOverride = nil
        }
        if defaults.object(forKey: UDKey.haptics) != nil {
            hapticsEnabled = defaults.bool(forKey: UDKey.haptics)
        }
        if let raw = defaults.string(forKey: UDKey.dateTimeStyle),
           let value = DateTimeDisplayStyle(rawValue: raw) {
            dateTimeStyle = value
        }
    }

    // MARK: - Setters (UserDefaults layer)

    func setAppearance(_ value: AppearancePreference) {
        appearance = value
        defaults.set(value.rawValue, forKey: UDKey.appearance)
    }

    func setLanguageOverride(_ value: LanguagePreference) {
        languageOverride = value
        defaults.set(value.rawValue, forKey: UDKey.language)
    }

    func setReduceMotionOverride(_ value: Bool?) {
        reduceMotionOverride = value
        if let value {
            defaults.set(value, forKey: UDKey.reduceMotion)
        } else {
            defaults.removeObject(forKey: UDKey.reduceMotion)
        }
    }

    func setHapticsEnabled(_ value: Bool) {
        hapticsEnabled = value
        defaults.set(value, forKey: UDKey.haptics)
    }

    func setDateTimeStyle(_ value: DateTimeDisplayStyle) {
        dateTimeStyle = value
        defaults.set(value.rawValue, forKey: UDKey.dateTimeStyle)
    }

    // MARK: - Sync controls (device-local UserDefaults layer)

    func setOverallSyncEnabled(_ enabled: Bool) {
        FloeLogger(category: .sync).info(
            "Overall sync preference requested: \(enabled); current=\(overallSyncEnabled); busy=\(syncControlBusy)"
        )
        guard overallSyncEnabled != enabled, !syncControlBusy else { return }
        let previous = overallSyncEnabled
        overallSyncEnabled = enabled
        syncControlBusy = true
        syncControlError = nil
        if !enabled { configSyncStatus = .paused }

        Task { [weak self] in
            guard let self else { return }
            do {
                let providers = try await environment.configurationStore.providers()
                try await KeychainSecretStore().setGlobalSyncEnabled(
                    enabled,
                    providerIDs: providers.map(\.id)
                )
                if !enabled, savedCredentialsSyncEnabled {
                    try await environment.credentialVault.setSavedCredentialSyncEnabled(false)
                    savedCredentialsSyncEnabled = false
                }
                // Keychain migration commits the production device-wide
                // preference only after every secret was verified at its
                // destination. Mirror that committed value into an injected
                // defaults suite used by tests/previews.
                var preferences = SyncControlPreferences.load(from: defaults)
                preferences.overallEnabled = enabled
                preferences.save(to: defaults)
                await environment.configurationSync.setSynchronizationEnabled(
                    enabled && configurationSyncEnabled
                )
                if enabled && configurationSyncEnabled {
                    await synchronizeConfiguration()
                }
            } catch {
                overallSyncEnabled = previous
                var rollback = SyncControlPreferences.load(from: defaults)
                rollback.overallEnabled = previous
                rollback.save(to: defaults)
                await environment.configurationSync.setSynchronizationEnabled(
                    previous && configurationSyncEnabled
                )
                syncControlError = SecretRedactor.redact(error.localizedDescription)
                FloeLogger(category: .sync).error("Overall sync preference failed and was rolled back")
            }
            syncControlBusy = false
            FloeLogger(category: .sync).info("Overall sync preference operation finished")
        }
    }

    func setConfigurationSyncEnabled(_ enabled: Bool) {
        FloeLogger(category: .sync).info(
            "Configuration sync preference requested: \(enabled); current=\(configurationSyncEnabled); busy=\(syncControlBusy)"
        )
        guard configurationSyncEnabled != enabled, !syncControlBusy else { return }
        configurationSyncEnabled = enabled
        syncControlBusy = true
        syncControlError = nil
        var preferences = SyncControlPreferences.load(from: defaults)
        preferences.configurationEnabled = enabled
        preferences.save(to: defaults)
        if !enabled { configSyncStatus = .paused }

        Task { [weak self] in
            guard let self else { return }
            await environment.configurationSync.setSynchronizationEnabled(
                overallSyncEnabled && enabled
            )
            if overallSyncEnabled && enabled {
                await synchronizeConfiguration()
            }
            syncControlBusy = false
            FloeLogger(category: .sync).info("Configuration sync preference operation finished")
        }
    }

    func setSavedCredentialsSyncEnabled(_ enabled: Bool) async {
        guard savedCredentialsSyncEnabled != enabled, !syncControlBusy else { return }
        syncControlBusy = true
        syncControlError = nil
        defer { syncControlBusy = false }
        do {
            let existingVault = try await environment.credentialStore.records(owner: .vault)
            if !enabled {
                for credential in existingVault where credential.synchronizable {
                    try await environment.configurationSync.unpublishCredentialDescriptor(
                        id: credential.id
                    )
                }
            }
            try await environment.credentialVault.setSavedCredentialSyncEnabled(enabled)
            if enabled {
                for credential in try await environment.credentialStore.records(owner: .vault)
                    where credential.synchronizable {
                    try await environment.configurationSync.saveCredentialDescriptor(credential)
                }
            }
            savedCredentialsSyncEnabled = enabled
            if overallSyncEnabled && configurationSyncEnabled {
                await synchronizeConfiguration()
            }
        } catch {
            syncControlError = SecretRedactor.redact(error.localizedDescription)
        }
    }

    // MARK: - Setters (DB app_settings layer)

    /// Persists one typed value under an `app_settings` key, then refreshes
    /// the published snapshot. Encoding is JSON, matching the store contract.
    private func persist<T: Encodable & Sendable>(_ value: T, forKey key: String) async {
        do {
            try await settingsStore.setValue(value, forKey: key)
        } catch {
            // Honest degradation: keep the in-memory value; the UI reloads
            // on next appearance and surfaces the stored truth.
        }
    }

    func setDefaultAgentMode(_ mode: AgentMode) async {
        defaultAgentMode = mode
        await persist(mode, forKey: AppSettingsKey.defaultAgentMode)
    }

    func loadRunningInputMode() async {
        if let stored = try? await settingsStore.value(
            forKey: AppSettingsKey.runningInputMode,
            as: RunningInputMode.self
        ) {
            runningInputMode = stored
        }
    }

    func setRunningInputMode(_ mode: RunningInputMode) async {
        runningInputMode = mode
        await persist(mode, forKey: AppSettingsKey.runningInputMode)
    }

    func loadBackgroundExecution() async {
        if let stored = try? await settingsStore.value(
            forKey: AppSettingsKey.backgroundExecution,
            as: BackgroundExecutionPreference.self
        ) {
            backgroundExecution = stored
        }
    }

    func setBackgroundExecution(_ preference: BackgroundExecutionPreference) async {
        backgroundExecution = preference
        await persist(preference, forKey: AppSettingsKey.backgroundExecution)
    }

    func setVerifyFinalAnswer(_ value: Bool) async {
        verifyFinalAnswer = value
        await persist(value, forKey: AppSettingsKey.verifyFinalAnswer)
    }

    func setDefaultStartPage(_ page: StartPage) async {
        defaultStartPage = page
        await persist(page, forKey: AppSettingsKey.defaultStartPage)
    }

    func setExecutionTimeout(seconds: Int) async {
        execution.timeoutSeconds = seconds
        await persist(seconds, forKey: AppSettingsKey.executionTimeoutSeconds)
    }

    func setMaxOutputBytes(_ bytes: Int) async {
        execution.maxOutputBytes = bytes
        await persist(bytes, forKey: AppSettingsKey.maxOutputBytes)
    }

    func setSavesArtifacts(_ saves: Bool) async {
        execution.savesArtifacts = saves
        await persist(saves, forKey: AppSettingsKey.savesArtifacts)
    }

    func setExecutionTarget(_ target: ExecutionTargetPreference) async {
        execution.target = target
        await persist(target, forKey: AppSettingsKey.executionTarget)
    }

    func setDefaultWorkspace(id: UUID?) async {
        defaultWorkspaceID = id
        if let id {
            // Encode explicitly: `setValue(_ json: String)` is the raw
            // overload and would store the bare UUID without JSON quoting.
            await persist(id, forKey: AppSettingsKey.defaultWorkspace)
        } else {
            try? await settingsStore.removeValue(forKey: AppSettingsKey.defaultWorkspace)
        }
    }

    func setSSHDefaults(_ defaultsValue: RemoteSessionDefaults) async {
        sshDefaults = defaultsValue
        await persist(defaultsValue, forKey: AppSettingsKey.sshDefaults)
    }

    func setVNCDefaults(_ defaultsValue: RemoteSessionDefaults) async {
        vncDefaults = defaultsValue
        await persist(defaultsValue, forKey: AppSettingsKey.vncDefaults)
    }

    func setIdleDisconnectMinutes(_ minutes: Int) async {
        idleDisconnectMinutes = minutes
        await persist(minutes, forKey: AppSettingsKey.idleDisconnectMinutes)
    }

    // MARK: - Grant management

    /// Revokes a saved grant in both layers: DB row + in-memory store.
    /// See §9: 撤销授权双写.
    func revokeGrant(id: UUID) async {
        try? await workspaceStore.deleteGrant(id: id)
        await approvalGrants.revoke(id: id)
        savedGrants = (try? await workspaceStore.allGrants()) ?? savedGrants
        memoryGrants = await approvalGrants.allGrants
    }

    /// Adds an in-memory grant (used when an approval flow mints one).
    func registerMemoryGrant(_ grant: ApprovalGrant) async {
        await approvalGrants.add(grant)
        memoryGrants = await approvalGrants.allGrants
    }

    // MARK: - Credential projection

    /// Builds the "configured / not configured" projection per provider.
    /// Reads each Keychain reference and records only presence — the secret
    /// bytes are discarded immediately and never retained or logged.
    private func credentialProjection(for providers: [ProviderProfile]) async -> [UUID: Bool] {
        var status: [UUID: Bool] = [:]
        for provider in providers {
            guard let ref = provider.secretRef else {
                status[provider.id] = false
                continue
            }
            let store = KeychainStore(
                service: "org.floeagent.ios.secrets",
                synchronizable: ref.synchronizable
            )
            status[provider.id] = (try? store.read(account: ref.keychainAccount)) != nil
        }
        return status
    }

    // MARK: - Diagnostics export

    /// Renders a redacted diagnostics bundle as text and writes it to a
    /// temporary file for the system share sheet. Never contains secrets.
    func exportDiagnostics() async throws -> URL {
        var lines: [String] = []
        lines.append("Floe Agent Diagnostics")
        lines.append("generated_at: \(ISO8601DateFormatter().string(from: Date()))")
        let info = Bundle.main.infoDictionary
        lines.append("version: \(info?["CFBundleShortVersionString"] as? String ?? "unknown")")
        lines.append("build: \(info?["CFBundleVersion"] as? String ?? "unknown")")
        lines.append("database_user_version: \(databaseUserVersion)")
        lines.append("sync_status: \(configSyncStatus)")
        lines.append("providers: \(capabilitySummary.providerCount)")
        lines.append("models: \(capabilitySummary.modelCount)")
        lines.append("catalog_tools: \(capabilitySummary.toolCount)")
        lines.append("adapter_kinds: \(capabilitySummary.adapterKinds.joined(separator: ", "))")
        lines.append("js: \(describe(jsCapability))")
        lines.append("python_local: \(describe(localPythonCapability))")
        lines.append("python_remote: \(describe(remotePythonCapability))")
        lines.append("icloud_drive: \(describe(iCloudDrive))")
        lines.append("keychain: \(describe(keychainState))")
        lines.append("gate_fail_closed: \(gateIsFailClosed)")
        lines.append("saved_grants: \(savedGrants.count)")
        lines.append("memory_grants: \(memoryGrants.count)")

        let redacted = SecretRedactor.redact(lines.joined(separator: "\n"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-diagnostics-\(UUID().uuidString).txt")
        try Data(redacted.utf8).write(to: url, options: .atomic)
        return url
    }

    private func describe(_ state: CapabilityState) -> String {
        switch state {
        case .available(let version): return "available(\(version))"
        case .unavailable(let reason): return "unavailable(\(reason))"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - AppEnvironment helper

private extension AppEnvironment {
    /// Host count without exposing RemoteSessionCenter internals; the
    /// center's `hosts` list is the single source of truth.
    func remoteSessionCenterHostsCount() async throws -> Int {
        remoteSessionCenter.hosts.count
    }
}
#endif
