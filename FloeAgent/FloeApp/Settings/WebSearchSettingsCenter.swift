#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
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
        ) { [weak self] _ in Task { @MainActor in self?.reload() } }
        cloud.synchronize()
    }

    func reload() {
        let data = cloud.data(forKey: Self.defaultsKey) ?? defaults.data(forKey: Self.defaultsKey)
        if let data, let decoded = try? JSONDecoder().decode([WebSearchProviderConfiguration].self, from: data) {
            providers = decoded.sorted { $0.priority < $1.priority }
        } else {
            providers = Self.presets()
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

    nonisolated static func resolvedConfigurations() async -> [(WebSearchProviderConfiguration, WebSearchCredential)] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: defaultsKey),
              let providers = try? JSONDecoder().decode([WebSearchProviderConfiguration].self, from: data) else { return [] }
        let store = KeychainStore(service: keychainService, synchronizable: true)
        return providers.filter(\.enabled).compactMap { configuration in
            if let secret = try? store.read(account: configuration.credentialAccount),
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
    }

    private static func presets() -> [WebSearchProviderConfiguration] {
        let kinds: [(WebSearchProviderKind, String)] = [
            (.bochaWeb, "Bocha Web Search"), (.bochaAI, "Bocha AI Search"),
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
                    SecureField("SecretId", text: $secretID)
                    SecureField("SecretKey", text: $secretKey)
                } else {
                    SecureField("API Key", text: $apiKey)
                }
                if configuration.kind == .googleProgrammable { TextField("Search Engine ID", text: $engineID) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(configuration.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("action.save") { save() } }
            }
        }
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
