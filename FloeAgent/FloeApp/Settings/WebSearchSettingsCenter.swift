#if canImport(SwiftUI) && canImport(UIKit)
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
    private let cloud: NSUbiquitousKeyValueStore
    private let keychain = KeychainStore(service: keychainService, synchronizable: true)

    init(defaults: UserDefaults = .standard, cloud: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.cloud = cloud
        reload()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
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
        cloud.synchronize()
    }

    func reload() {
        let data = cloud.data(forKey: Self.defaultsKey) ?? defaults.data(forKey: Self.defaultsKey)
        if let data, let decoded = try? JSONDecoder().decode([WebSearchProviderConfiguration].self, from: data) {
            providers = Self.normalizedProviders(decoded)
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
        if let index = providers.firstIndex(where: { $0.id == configuration.id }) {
            providers[index] = configuration
        } else {
            providers.append(configuration)
        }
        providers.sort { $0.priority < $1.priority }
        if let credential {
            let data = try JSONEncoder().encode(credential)
            try keychain.store(account: configuration.credentialAccount, secret: data)
        }
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
        try? keychain.delete(account: item.credentialAccount)
        persist()
    }

    func credential(for configuration: WebSearchProviderConfiguration) -> WebSearchCredential? {
        if let data = try? keychain.read(account: configuration.credentialAccount) {
            return try? JSONDecoder().decode(WebSearchCredential.self, from: data)
        }
        if configuration.kind == .bochaWeb,
           let legacy = try? keychain.read(account: "web-search.bochaAI") {
            return try? JSONDecoder().decode(WebSearchCredential.self, from: legacy)
        }
        return nil
    }

    nonisolated static func resolvedConfigurations() async -> [(WebSearchProviderConfiguration, WebSearchCredential)] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: defaultsKey),
              let providers = try? JSONDecoder().decode([WebSearchProviderConfiguration].self, from: data) else { return [] }
        let store = KeychainStore(service: keychainService, synchronizable: true)
        return normalizedProviders(providers).filter(\.enabled).compactMap { configuration in
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
            WebSearchProviderConfiguration(
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
        guard (try? keychain.read(account: "web-search.bochaWeb")) == nil,
              let legacy = try? keychain.read(account: "web-search.bochaAI") else { return }
        try? keychain.store(account: "web-search.bochaWeb", secret: legacy)
    }

    nonisolated static func runtimeProviderNote() -> String? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(
                [WebSearchProviderConfiguration].self,
                from: data
              ) else { return nil }
        let enabled = normalizedProviders(decoded).filter(\.enabled)
        guard !enabled.isEmpty else { return "Web search providers enabled: none." }
        return "Web search providers enabled: "
            + enabled.map { "\($0.displayName) [\($0.kind.rawValue)]" }.joined(separator: ", ")
            + ". The optional web.search provider argument must use one of these names or kinds."
    }
}

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
        .navigationTitle("websearch.title")
        .sheet(item: $editing) { configuration in
            WebSearchProviderEditor(center: center, configuration: configuration)
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
                    Text("保存后会同时向模型提供 web.search（普通网页结果）和 web.searchAI（Bocha AI 摘要）两个工具，不需要在设置中切换。两者共用此 API Key 和 Base URL。")
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
            .accessibilityLabel(revealed.wrappedValue ? "隐藏凭据" : "显示凭据")
        }
    }

    @MainActor
    private func revealCredential(_ revealed: Binding<Bool>) async {
        do {
            guard try await DeviceOwnerAuthenticator.authenticate(
                reason: "查看已保存的联网搜索凭据"
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
