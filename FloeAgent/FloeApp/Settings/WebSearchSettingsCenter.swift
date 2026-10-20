#if canImport(SwiftUI)
import Foundation
import SwiftUI
import FloeCore
import FloeExecution
import FloeSecurity

@MainActor
final class WebSearchSettingsCenter: ObservableObject {
    nonisolated static let defaultsKey = "floe.webSearch.providers.v1"
    nonisolated static let keychainService = "org.floeagent.ios.web-search"

    @Published private(set) var providers: [WebSearchProviderConfiguration] = []
    private let defaults: UserDefaults
    private let cloud: WebSearchCloudStoring
    private let credentialStore: WebSearchCredentialStore
    private let dataProManager: VolcengineDataProManaging?

    init(
        defaults: UserDefaults = .standard,
        cloud: WebSearchCloudStoring? = nil,
        credentialStore: WebSearchCredentialStore? = nil,
        dataProManager: VolcengineDataProManaging? = nil
    ) {
        self.defaults = defaults
        self.cloud = cloud ?? UbiquitousWebSearchCloudStore(store: .default)
        self.credentialStore = credentialStore ?? .keychain(service: Self.keychainService)
        #if canImport(UIKit)
        self.dataProManager = dataProManager ?? MCPSettingsCenterDataProManager.shared
        #else
        self.dataProManager = dataProManager
        #endif
        reload()
        if let object = self.cloud.notificationObject {
            NotificationCenter.default.addObserver(
                forName: self.cloud.externalChangeNotification,
                object: object,
                queue: .main
            ) { [weak self] notification in
                let reason = (notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? NSNumber)?.intValue ?? -1
                Task { @MainActor [weak self, reason] in
                    FloeLogger(category: .sync).info(
                        "webSearchSettingsExternalChange reason=\(reason)"
                    )
                    self?.reload()
                }
            }
        }
        self.cloud.synchronize()
    }

    func reload() {
        let data = cloud.data(forKey: Self.defaultsKey) ?? defaults.data(forKey: Self.defaultsKey)
        if let data, let decoded = try? JSONDecoder().decode([WebSearchProviderConfiguration].self, from: data) {
            providers = Self.normalizedProviders(decoded)
            // Runtime resolution reads local defaults. Mirror cloud hydration
            // immediately, rather than waiting for an unrelated Save tap.
            if let normalized = try? JSONEncoder().encode(providers) { defaults.set(normalized, forKey: Self.defaultsKey) }
            migrateBochaCredentialIfNeeded()
            FloeLogger(category: .sync).info(
                "webSearchSettingsLoaded source=\(cloud.data(forKey: Self.defaultsKey) == nil ? "local" : "cloud") count=\(providers.count) enabled=\(providers.filter(\.enabled).count)"
            )
        } else {
            providers = Self.presets()
            FloeLogger(category: .sync).info("webSearchSettingsLoaded source=presets count=\(providers.count)")
            persist()
        }
    }

    func upsert(_ configuration: WebSearchProviderConfiguration, credential: WebSearchCredential?) throws {
        // A Keychain write failure must not publish an enabled configuration
        // whose selected account still holds another interface's secret. The
        // secret is stored BEFORE any in-memory/persisted provider mutation.
        let hasSuppliedCredential = credential?.values["apiKey"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if configuration.kind == .volcengine,
           configuration.enabled,
           !hasSuppliedCredential,
           !hasCredential(account: configuration.credentialAccount) {
            throw VolcengineSearchSettingsError.missingCredential
        }
        if let credential {
            let data = try JSONEncoder().encode(credential)
            try credentialStore.write(configuration.credentialAccount, data)
        }
        if let index = providers.firstIndex(where: { $0.id == configuration.id }) {
            providers[index] = configuration
        } else {
            providers.append(configuration)
        }
        providers.sort { $0.priority < $1.priority }
        FloeLogger(category: .sync).info(
            "webSearchProviderSaved provider=\(configuration.kind.rawValue) enabled=\(configuration.enabled) endpointHost=\(configuration.endpoint?.host ?? "default") credentialUpdated=\(credential != nil)"
        )
        persist()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[index].enabled = enabled
        persist()
    }

    func remove(id: UUID) {
        guard let item = providers.first(where: { $0.id == id }) else { return }
        providers.removeAll { $0.id == id }
        try? credentialStore.delete(item.credentialAccount)
        persist()
    }

    func credential(for configuration: WebSearchProviderConfiguration) -> WebSearchCredential? {
        credential(forAccount: configuration.credentialAccount)
            ?? (configuration.kind == .bochaWeb
                ? credential(forAccount: "web-search.bochaAI")
                : nil)
    }

    func credential(forAccount account: String) -> WebSearchCredential? {
        guard let data = try? credentialStore.read(account) else { return nil }
        return try? JSONDecoder().decode(WebSearchCredential.self, from: data)
    }

    func hasCredential(account: String) -> Bool {
        guard let data = try? credentialStore.read(account) else { return false }
        return !data.isEmpty
    }

    /// DataPro is a separate feature-owned MCP server. It is available only
    /// for the Agent Plan account and never reads an Ark model key.
    func dataProState(for configuration: WebSearchProviderConfiguration) -> VolcengineDataProState {
        guard configuration.kind == .volcengine, let dataProManager else {
            return .inactive
        }
        let serverID = VolcengineDataProPlan.serverID(for: configuration)
        if let existing = dataProManager.currentServer(serverID: serverID),
           !VolcengineDataProPlan.matchesOwnedServer(existing) {
            // Never surface an unrelated user MCP as this feature's state.
            return .inactive
        }
        return dataProManager.state(serverID: serverID)
    }

    /// Observe the existing MCP center's published state for this feature's
    /// owned server. The callback is fenced to the Agent Plan interface, the
    /// provider-derived server ID and the feature's exact server identity.
    func observeDataPro(
        for configuration: WebSearchProviderConfiguration,
        onChange: @escaping @MainActor (VolcengineDataProState) -> Void
    ) -> VolcengineDataProObservation? {
        guard configuration.kind == .volcengine, let dataProManager else {
            return nil
        }
        let options: VolcengineSearchOptions
        do {
            options = try VolcengineSearchOptions(options: configuration.options)
        } catch {
            return nil
        }
        guard options.interface == .agentPlan else { return nil }
        let serverID = VolcengineDataProPlan.serverID(for: configuration)
        return dataProManager.observeState(serverID: serverID) { state in
            if let existing = dataProManager.currentServer(serverID: serverID),
               !VolcengineDataProPlan.matchesOwnedServer(existing) {
                onChange(.inactive)
            } else {
                onChange(state)
            }
        }
    }

    func refreshDataPro(for configuration: WebSearchProviderConfiguration) async -> VolcengineDataProState {
        guard configuration.kind == .volcengine, let dataProManager else {
            return .inactive
        }
        let serverID = VolcengineDataProPlan.serverID(for: configuration)
        if let existing = dataProManager.currentServer(serverID: serverID),
           !VolcengineDataProPlan.matchesOwnedServer(existing) {
            return .inactive
        }
        await dataProManager.refresh(serverID: serverID)
        return dataProManager.state(serverID: serverID)
    }

    func setDataProEnabled(
        _ enabled: Bool,
        for configuration: WebSearchProviderConfiguration,
        credential: String?
    ) async throws {
        guard configuration.kind == .volcengine else {
            throw VolcengineSearchSettingsError.providerKindMismatch
        }
        guard let dataProManager else {
            if enabled { throw VolcengineSearchSettingsError.dataProUnavailable }
            return
        }
        let server = try VolcengineDataProPlan.server(for: configuration)
        let existing = dataProManager.currentServer(serverID: server.id)
        if let existing, !VolcengineDataProPlan.matchesOwnedServer(existing) {
            // Do not overwrite an unrelated MCP that occupies the persisted
            // UUID. Disabling is a safe no-op; enabling must be explicit.
            if enabled { throw VolcengineSearchSettingsError.serverIdentityConflict }
            return
        }
        if enabled {
            // DataPro requires the Agent Plan account. This check happens
            // before any MCP mutation, so an ordinary Ark key is never sent.
            let options: VolcengineSearchOptions
            do {
                options = try VolcengineSearchOptions(options: configuration.options)
            } catch {
                throw VolcengineSearchSettingsError.malformedInterfaceSelection
            }
            guard options.interface == .agentPlan else {
                throw VolcengineSearchSettingsError.requiresAgentPlan
            }
            try await dataProManager.upsert(server, credential: credential)
            dataProManager.setEnabled(true, serverID: server.id)
        } else if existing != nil {
            dataProManager.setEnabled(false, serverID: server.id)
        }
    }

    nonisolated static func resolvedConfigurations() async -> [(WebSearchProviderConfiguration, WebSearchCredential)] {
        readyConfigurations()
    }

    nonisolated static func toolIsAvailable(_ name: String) -> Bool {
        let ready = readyConfigurations()
        if name == WebSearchTool.name { return !ready.isEmpty }
        if name == BochaAISearchTool.name { return ready.contains { $0.0.kind == .bochaWeb || $0.0.kind == .bochaAI } }
        return false
    }

    nonisolated private static func readyConfigurations() -> [(WebSearchProviderConfiguration, WebSearchCredential)] {
        let defaults = UserDefaults.standard
        // Resolve hydration here as well: opening Settings is not a prerequisite
        // for using cloud-synced configuration after launch or upgrade.
        let snapshots = [NSUbiquitousKeyValueStore.default.data(forKey: defaultsKey), defaults.data(forKey: defaultsKey)]
        guard let providers = snapshots.compactMap({ data -> [WebSearchProviderConfiguration]? in
            guard let data else { return nil }
            return try? JSONDecoder().decode([WebSearchProviderConfiguration].self, from: data)
        }).first else { return [] }
        let store = KeychainStore(service: keychainService, synchronizable: true)
        let candidates: [(WebSearchProviderConfiguration, WebSearchCredential)] = normalizedProviders(providers).filter(\.enabled).compactMap { configuration in
            if let secret = try? store.read(account: configuration.credentialAccount),
               let credential = try? JSONDecoder().decode(WebSearchCredential.self, from: secret) {
                return (configuration, credential)
            }
            if configuration.kind == .bochaWeb,
               let secret = try? store.read(account: "web-search.bochaAI"),
               let credential = try? JSONDecoder().decode(WebSearchCredential.self, from: secret) {
                return (configuration, credential)
            }
            return configuration.kind.requiresCredential
                ? nil
                : (configuration, WebSearchCredential(values: [:]))
        }
        return candidates.map { configuration, credential in
            (configuration, WebSearchCredential(values: credential.values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
        }.filter { WebSearchService.isConfigured($0.0, credential: $0.1) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        cloud.set(data, forKey: Self.defaultsKey)
        cloud.synchronize()
        FloeLogger(category: .sync).debug(
            "webSearchSettingsPersisted bytes=\(data.count) count=\(providers.count) enabled=\(providers.filter(\.enabled).count)"
        )
    }

    private static func presets() -> [WebSearchProviderConfiguration] {
        let kinds: [(WebSearchProviderKind, String)] = [
            (.bochaWeb, "Bocha Search"),
            (.tencentWSA, "Tencent Cloud WSA"), (.volcengine, "Volcengine Web Search"),
            (.brave, "Brave Search"), (.tavily, "Tavily"), (.exa, "Exa"),
            (.googleProgrammable, "Google Programmable Search"), (.searxng, "SearXNG")
        ]
        return kinds.enumerated().map { index, value in
            if value.0 == .volcengine {
                // New installs default to the Agent Plan account/interface but
                // stay disabled. The account is namespaced by provider ID so
                // two Volcengine configurations cannot share one credential.
                // Existing stored legacy records are untouched by this preset.
                let id = UUID()
                return WebSearchProviderConfiguration(
                    id: id,
                    kind: value.0,
                    displayName: value.1,
                    credentialAccount: VolcengineSettingsDraft.perProviderCredentialAccount(
                        for: id,
                        interface: .agentPlan
                    ),
                    enabled: false,
                    priority: index,
                    options: [
                        VolcengineSearchOptions.Key.interface:
                            VolcengineSearchInterface.agentPlan.rawValue
                    ]
                )
            }
            return WebSearchProviderConfiguration(
                kind: value.0,
                displayName: value.1,
                credentialAccount: "web-search.\(value.0.rawValue)",
                enabled: false,
                priority: index
            )
        }
    }

    /// v1.4.19 presents Bocha as one provider. Older installs stored Web and
    /// AI search separately even though they share one account and key. Keep
    /// the legacy enum for decoding, but collapse it at the settings/runtime
    /// boundary and use the supported Web Search endpoint for both modes.
    nonisolated private static func normalizedProviders(
        _ source: [WebSearchProviderConfiguration]
    ) -> [WebSearchProviderConfiguration] {
        let legacyAI = source.first { $0.kind == .bochaAI }
        var result = source.filter { $0.kind != .bochaAI }
        if let index = result.firstIndex(where: { $0.kind == .bochaWeb }) {
            if let legacyAI {
                result[index].enabled = result[index].enabled || legacyAI.enabled
                result[index].options["summaryEnabled"] =
                    result[index].options["summaryEnabled"] ?? "true"
            }
            result[index].displayName = "Bocha Search"
            result[index].credentialAccount = "web-search.bochaWeb"
        } else if var legacyAI {
            legacyAI.kind = .bochaWeb
            legacyAI.displayName = "Bocha Search"
            legacyAI.credentialAccount = "web-search.bochaWeb"
            legacyAI.options["summaryEnabled"] = "true"
            result.append(legacyAI)
        }
        return result.sorted { $0.priority < $1.priority }
    }

    private func migrateBochaCredentialIfNeeded() {
        guard (try? credentialStore.read("web-search.bochaWeb")) == nil,
              let legacy = try? credentialStore.read("web-search.bochaAI") else { return }
        try? credentialStore.write("web-search.bochaWeb", legacy)
    }

    nonisolated static func runtimeProviderNote() -> String? {
        let ready = readyConfigurations().map(\.0)
        guard !ready.isEmpty else { return nil }
        return "Available web search providers: "
            + ready.map { "\($0.displayName) [\($0.kind.rawValue)]" }.joined(separator: ", ")
            + ". The optional web.search provider argument must use one of these names or kinds."
    }
}

#if canImport(UIKit)
struct WebSearchSettingsView: View {
    @ObservedObject var center: WebSearchSettingsCenter
    @State private var editing: WebSearchProviderConfiguration?

    var body: some View {
        List {
            Section {
                ForEach(center.providers) { provider in
                    Button { editing = provider } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.displayName).foregroundStyle(.primary)
                                Text(provider.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { provider.enabled },
                                set: { center.setEnabled($0, id: provider.id) }
                            )).labelsHidden()
                        }
                    }
                }
            } header: { Text("websearch.providers") }
              footer: { Text("websearch.providers.footer") }
        }
        .navigationTitle(FloeL10n.l("websearch.title"))
        .sheet(item: $editing) { configuration in
            if configuration.kind == .volcengine {
                VolcengineSearchEditor(center: center, configuration: configuration)
            } else {
                WebSearchProviderEditor(center: center, configuration: configuration)
            }
        }
    }
}

private struct WebSearchProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    let center: WebSearchSettingsCenter
    @State private var configuration: WebSearchProviderConfiguration
    @State private var endpoint: String
    @State private var apiKey = ""
    @State private var secretID = ""
    @State private var secretKey = ""
    @State private var engineID = ""
    @State private var errorMessage: String?
    @State private var revealsAPIKey = false
    @State private var revealsSecretID = false
    @State private var revealsSecretKey = false
    @State private var authenticationError: String?

    init(center: WebSearchSettingsCenter, configuration: WebSearchProviderConfiguration) {
        self.center = center
        _configuration = State(initialValue: configuration)
        _endpoint = State(initialValue: configuration.endpoint?.absoluteString ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("websearch.display_name", text: $configuration.displayName)
                TextField("websearch.endpoint", text: $endpoint).textInputAutocapitalization(.never).keyboardType(.URL)
                if configuration.kind == .tencentWSA {
                    credentialField("SecretId", value: $secretID, revealed: $revealsSecretID)
                    credentialField("SecretKey", value: $secretKey, revealed: $revealsSecretKey)
                } else {
                    credentialField("API Key", value: $apiKey, revealed: $revealsAPIKey)
                }
                if configuration.kind == .googleProgrammable { TextField("Search Engine ID", text: $engineID) }
                if configuration.kind == .bochaWeb {
                    Text("settings.web_search_settings_center.when_saved_the_model_gets_both")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = errorMessage ?? authenticationError {
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle(configuration.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("action.save") { save() } }
            }
            .task { loadCredential() }
        }
    }

    private func credentialField(
        _ title: String,
        value: Binding<String>,
        revealed: Binding<Bool>
    ) -> some View {
        HStack {
            if revealed.wrappedValue {
                TextField(title, text: value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                SecureField(title, text: value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button {
                if revealed.wrappedValue {
                    revealed.wrappedValue = false
                } else {
                    Task { await revealCredential(revealed) }
                }
            } label: {
                Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed.wrappedValue ? "settings.web_search_settings_center.hide_credentials" : "settings.web_search_settings_center.show_credentials")
        }
    }

    @MainActor
    private func revealCredential(_ revealed: Binding<Bool>) async {
        do {
            guard try await DeviceOwnerAuthenticator.authenticate(
                reason: FloeL10n.l("settings.web_search_settings_center.view_saved_web_search_credentials")
            ) else { return }
            authenticationError = nil
            revealed.wrappedValue = true
        } catch {
            authenticationError = error.localizedDescription
        }
    }

    private func loadCredential() {
        guard let values = center.credential(for: configuration)?.values else { return }
        apiKey = values["apiKey"] ?? ""
        secretID = values["secretId"] ?? ""
        secretKey = values["secretKey"] ?? ""
        engineID = values["engineId"] ?? ""
    }

    private func save() {
        configuration.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        var values: [String: String] = [:]
        if !apiKey.isEmpty { values["apiKey"] = apiKey }
        if !secretID.isEmpty { values["secretId"] = secretID }
        if !secretKey.isEmpty { values["secretKey"] = secretKey }
        if !engineID.isEmpty { values["engineId"] = engineID }
        do {
            try center.upsert(configuration, credential: values.isEmpty ? nil : WebSearchCredential(values: values))
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
#endif
