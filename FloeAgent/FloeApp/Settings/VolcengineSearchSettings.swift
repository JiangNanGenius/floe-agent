// FloeAgent — Volcengine web-search account selection and DataPro lifecycle.
//
// The provider uses the existing `WebSearchProviderConfiguration.options`
// dictionary and one stable Keychain account per account/interface. The
// legacy custom-endpoint configuration is represented by the ABSENCE of an
// interface option, so an older record never silently changes product or
// credential. DataPro is an independent, locally-off MCP connection: this
// file only maps the feature onto the existing MCPSettingsCenter lifecycle
// and never claims that a configured server is connected.

import Combine
import Foundation
import FloeCore
import FloeExecution
import FloeSecurity
import FloeTools

// MARK: - Settings persistence seams

/// Minimal view of the ubiquitous key-value store used for provider sync.
/// Tests inject an in-memory store instead of touching the developer's iCloud
/// defaults; production uses `NSUbiquitousKeyValueStore.default`.
@MainActor
protocol WebSearchCloudStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    func synchronize()
    var notificationObject: AnyObject? { get }
    var externalChangeNotification: Notification.Name { get }
}

@MainActor
final class UbiquitousWebSearchCloudStore: WebSearchCloudStoring {
    private let store: NSUbiquitousKeyValueStore

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) { store.set(data, forKey: key) }
    func synchronize() { store.synchronize() }
    var notificationObject: AnyObject? { store }
    var externalChangeNotification: Notification.Name {
        NSUbiquitousKeyValueStore.didChangeExternallyNotification
    }
}

/// Secret storage seam for web-search credentials. The production value is
/// the existing synchronizable Keychain namespace; tests use a synthetic
/// in-memory store and never activate the real Keychain.
struct WebSearchCredentialStore: Sendable {
    var read: @Sendable (String) throws -> Data?
    var write: @Sendable (String, Data) throws -> Void
    var delete: @Sendable (String) throws -> Void

    static func keychain(
        service: String,
        synchronizable: Bool = true
    ) -> WebSearchCredentialStore {
        let keychain = KeychainStore(service: service, synchronizable: synchronizable)
        return WebSearchCredentialStore(
            read: { account in
                do {
                    return try keychain.read(account: account)
                } catch KeychainStoreError.itemNotFound {
                    return nil
                }
            },
            write: { account, data in
                try keychain.store(account: account, secret: data)
            },
            delete: { account in
                try? keychain.delete(account: account)
            }
        )
    }
}

// MARK: - Account / interface selection

/// UI and persistence representation of a Volcengine provider. The legacy
/// case is a real, explicit state: it preserves the original custom-endpoint
/// request and credential until the user deliberately selects another mode.
enum VolcengineConfigurationMode: String, CaseIterable, Identifiable, Sendable {
    case agentPlan
    case arkResponses
    case doubaoSearch
    case legacyCustom

    var id: String { rawValue }

    var interface: VolcengineSearchInterface? {
        switch self {
        case .agentPlan: .agentPlan
        case .arkResponses: .arkResponses
        case .doubaoSearch: .doubaoSearch
        case .legacyCustom: nil
        }
    }
}

enum VolcengineSearchSettingsError: Error, Equatable, Sendable {
    case providerKindMismatch
    case malformedInterfaceSelection
    case missingCredential
    case invalidEndpoint
    case invalidArkModel
    case requiresAgentPlan
    case dataProUnavailable
    case serverIdentityConflict
}

/// Form state for the dedicated Volcengine editor. This is the single
/// production mapping between the UI, the stored options dictionary and the
/// per-interface credential accounts; tests exercise the same type.
struct VolcengineSettingsDraft: Equatable {
    /// Original generic-endpoint account. Kept as the default for old
    /// records, but no draft rewrites a different captured account to it.
    static let legacyCredentialAccount = "web-search.volcengine"
    /// Legacy per-interface names used by the first unreleased draft. New
    /// configurations use the per-provider namespaces below; existing
    /// credentials under these names are reused for their exact interface.
    static let agentPlanCredentialAccount = "web-search.volcengine.agentPlan"
    static let arkCredentialAccount = "web-search.volcengine.arkResponses"
    static let doubaoSearchCredentialAccount = "web-search.volcengine.doubaoSearch"

    static func perProviderCredentialAccount(
        for providerID: UUID,
        interface: VolcengineSearchInterface
    ) -> String {
        "web-search.volcengine.\(providerID.uuidString.lowercased()).\(interface.rawValue)"
    }

    static func perProviderLegacyCredentialAccount(for providerID: UUID) -> String {
        "web-search.volcengine.\(providerID.uuidString.lowercased()).legacyCustom"
    }

    var mode: VolcengineConfigurationMode
    var arkEngine: VolcengineArkSearchEngine
    var arkModel: String
    var endpoint: String
    var queryRewrite: Bool
    var authoritativeOnly: Bool
    var dataProEnabled: Bool
    var dataProServerID: UUID
    var displayName: String
    /// The catalog-owned official title of this preset, captured while the
    /// editor is open, or nil when the preset has no catalog entry. An
    /// emptied display-name field falls back to this title and then to the
    /// name the editor opened with — never to a hardcoded literal, which
    /// would freeze a stale official name in and let a passive save mark it
    /// as a user alias after the catalog title refreshed on its own.
    var officialName: String?

    let providerID: UUID
    /// The display name this draft was opened with. A saved name still equal
    /// to it is a carried-over official title, not a user edit.
    let openingDisplayName: String
    let enabled: Bool
    let priority: Int
    let region: String?
    let preservedOptions: [String: String]
    /// The exact account and interface captured when the editor opened. A
    /// legacy save must return these bytes unchanged; an explicit-interface
    /// save reuses the account only when the captured product matches.
    let originalCredentialAccount: String
    let originalInterface: VolcengineSearchInterface?

    static let knownOptionKeys: Set<String> = [
        VolcengineSearchOptions.Key.interface,
        VolcengineSearchOptions.Key.arkEngine,
        VolcengineSearchOptions.Key.arkModel,
        VolcengineSearchOptions.Key.queryRewrite,
        VolcengineSearchOptions.Key.authoritativeOnly,
        VolcengineSearchOptions.Key.dataProEnabled,
        VolcengineSearchOptions.Key.dataProServerID
    ]

    init(
        mode: VolcengineConfigurationMode,
        arkEngine: VolcengineArkSearchEngine,
        arkModel: String,
        endpoint: String,
        queryRewrite: Bool,
        authoritativeOnly: Bool,
        dataProEnabled: Bool,
        dataProServerID: UUID,
        displayName: String,
        officialName: String? = nil,
        openingDisplayName: String? = nil,
        providerID: UUID,
        enabled: Bool,
        priority: Int,
        region: String?,
        preservedOptions: [String: String],
        originalCredentialAccount: String,
        originalInterface: VolcengineSearchInterface?
    ) {
        self.mode = mode
        self.arkEngine = arkEngine
        self.arkModel = arkModel
        self.endpoint = endpoint
        self.queryRewrite = queryRewrite
        self.authoritativeOnly = authoritativeOnly
        self.dataProEnabled = dataProEnabled
        self.dataProServerID = dataProServerID
        self.displayName = displayName
        self.officialName = officialName
        self.openingDisplayName = openingDisplayName ?? displayName
        self.providerID = providerID
        self.enabled = enabled
        self.priority = priority
        self.region = region
        self.preservedOptions = preservedOptions
        self.originalCredentialAccount = originalCredentialAccount
        self.originalInterface = originalInterface
    }

    init(configuration: WebSearchProviderConfiguration) throws {
        guard configuration.kind == .volcengine else {
            throw VolcengineSearchSettingsError.providerKindMismatch
        }
        let options: VolcengineSearchOptions
        do {
            options = try VolcengineSearchOptions(options: configuration.options)
        } catch {
            throw VolcengineSearchSettingsError.malformedInterfaceSelection
        }
        mode = options.interface.map { interface in
            switch interface {
            case .agentPlan: .agentPlan
            case .arkResponses: .arkResponses
            case .doubaoSearch: .doubaoSearch
            }
        } ?? .legacyCustom
        arkEngine = options.arkEngine
        arkModel = options.arkModel
        endpoint = configuration.endpoint?.absoluteString ?? ""
        queryRewrite = options.queryRewrite
        authoritativeOnly = options.authoritativeOnly
        dataProEnabled = options.dataProEnabled
        dataProServerID = options.dataProServerID
            ?? Self.defaultDataProServerID(for: configuration.id)
        displayName = configuration.displayName
        officialName = nil
        openingDisplayName = configuration.displayName
        providerID = configuration.id
        enabled = configuration.enabled
        priority = configuration.priority
        region = configuration.region
        preservedOptions = configuration.options.filter {
            !Self.knownOptionKeys.contains($0.key)
        }
        originalCredentialAccount = configuration.credentialAccount
        originalInterface = options.interface
    }

    /// Non-throwing recovery state for a malformed stored record. Saving is
    /// blocked until the user explicitly selects a valid mode.
    static func fallback(configuration: WebSearchProviderConfiguration) -> Self {
        Self(
            mode: .legacyCustom,
            arkEngine: .doubaoCustom,
            arkModel: VolcengineSearchOptions.defaultArkModel,
            endpoint: configuration.endpoint?.absoluteString ?? "",
            queryRewrite: false,
            authoritativeOnly: false,
            dataProEnabled: false,
            dataProServerID: defaultDataProServerID(for: configuration.id),
            displayName: configuration.displayName,
            providerID: configuration.id,
            enabled: configuration.enabled,
            priority: configuration.priority,
            region: configuration.region,
            preservedOptions: configuration.options.filter {
                !knownOptionKeys.contains($0.key)
            },
            originalCredentialAccount: configuration.credentialAccount,
            originalInterface: nil
        )
    }

    var credentialAccount: String {
        credentialAccount(for: mode)
    }

    /// Select the account for a mode without rewriting a captured legacy
    /// account or silently moving a key between products.
    func credentialAccount(for mode: VolcengineConfigurationMode) -> String {
        if mode == .legacyCustom {
            // A record that was already legacy keeps its exact account; a
            // switch TO legacy from a product interface gets its own stable
            // per-provider account instead of borrowing the product key.
            if originalInterface == nil {
                return originalCredentialAccount
            }
            return Self.perProviderLegacyCredentialAccount(for: providerID)
        }
        guard let interface = mode.interface else {
            return Self.perProviderLegacyCredentialAccount(for: providerID)
        }
        // Reuse the stored account only when it was already selected for the
        // same product. The generic legacy account is never promoted into an
        // explicit interface.
        if originalInterface == interface,
           !originalCredentialAccount.isEmpty,
           originalCredentialAccount != Self.legacyCredentialAccount {
            return originalCredentialAccount
        }
        return Self.perProviderCredentialAccount(for: providerID, interface: interface)
    }

    /// Stable fallback identity for the feature-owned DataPro MCP server.
    /// A random UUID would duplicate the server on migration; this XOR is a
    /// one-to-one transform of the provider UUID and needs no crypto.
    static func defaultDataProServerID(for providerID: UUID) -> UUID {
        var providerUUID = providerID.uuid
        var bytes = withUnsafeBytes(of: &providerUUID) { Array($0) }
        let namespace = Array("FloeDataPro2026!".utf8)
        for index in 0..<min(bytes.count, namespace.count) {
            bytes[index] ^= namespace[index]
        }
        return bytes.withUnsafeBufferPointer { buffer in
            NSUUID(uuidBytes: buffer.baseAddress) as UUID
        }
    }

    func configuration() throws -> WebSearchProviderConfiguration {
        var options = preservedOptions
        for key in Self.knownOptionKeys {
            options.removeValue(forKey: key)
        }
        let resolvedEndpoint: URL?
        switch mode {
        case .legacyCustom:
            resolvedEndpoint = try Self.validatedEndpoint(endpoint)
        case .agentPlan:
            options[VolcengineSearchOptions.Key.interface] =
                VolcengineSearchInterface.agentPlan.rawValue
            options[VolcengineSearchOptions.Key.queryRewrite] =
                queryRewrite ? "true" : "false"
            options[VolcengineSearchOptions.Key.authoritativeOnly] =
                authoritativeOnly ? "true" : "false"
            options[VolcengineSearchOptions.Key.dataProEnabled] =
                dataProEnabled ? "true" : "false"
            options[VolcengineSearchOptions.Key.dataProServerID] =
                dataProServerID.uuidString
            resolvedEndpoint = nil
        case .arkResponses:
            options[VolcengineSearchOptions.Key.interface] =
                VolcengineSearchInterface.arkResponses.rawValue
            options[VolcengineSearchOptions.Key.arkEngine] = arkEngine.rawValue
            options[VolcengineSearchOptions.Key.arkModel] = try Self.validatedArkModel(arkModel)
            resolvedEndpoint = nil
        case .doubaoSearch:
            options[VolcengineSearchOptions.Key.interface] =
                VolcengineSearchInterface.doubaoSearch.rawValue
            options[VolcengineSearchOptions.Key.queryRewrite] =
                queryRewrite ? "true" : "false"
            options[VolcengineSearchOptions.Key.authoritativeOnly] =
                authoritativeOnly ? "true" : "false"
            resolvedEndpoint = nil
        }
        // The feature-owned DataPro identity survives interface transitions:
        // losing it on a temporary Ark/legacy save would strand the existing
        // MCP server and create a duplicate on return to Agent Plan.
        options[VolcengineSearchOptions.Key.dataProServerID] = dataProServerID.uuidString
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field means the user wants no personal alias: keep the
        // catalog-owned official title, falling back to the name this draft
        // opened with when no catalog entry is known.
        let resolvedName = trimmedName.isEmpty
            ? (officialName ?? openingDisplayName)
            : trimmedName
        return WebSearchProviderConfiguration(
            id: providerID,
            kind: .volcengine,
            displayName: resolvedName,
            endpoint: resolvedEndpoint,
            credentialAccount: credentialAccount,
            enabled: enabled,
            priority: priority,
            region: region,
            options: options
        )
    }

    static func validatedEndpoint(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            throw VolcengineSearchSettingsError.invalidEndpoint
        }
        return url
    }

    static func validatedArkModel(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= VolcengineSearchOptions.maximumArkModelCharacters,
              trimmed.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics
                      .union(CharacterSet(charactersIn: "-._/:"))
                      .contains($0)
              }) else {
            throw VolcengineSearchSettingsError.invalidArkModel
        }
        return trimmed
    }
}

// MARK: - DataPro

/// The feature-owned MCP server. Creating this value never writes anything;
/// `WebSearchSettingsCenter.setDataProEnabled` performs the existing
/// MCPSettingsCenter upsert/setEnabled lifecycle.
struct VolcengineDataProPlan {
    static let endpoint = VolcengineProfessionalSearch.endpoint
    static let credentialHeaderName = VolcengineProfessionalSearch.credentialHeaderName
    static let displayName = VolcengineProfessionalSearch.displayName

    static func serverID(for configuration: WebSearchProviderConfiguration) -> UUID {
        if let raw = configuration.options[VolcengineSearchOptions.Key.dataProServerID],
           let stored = UUID(uuidString: raw) {
            return stored
        }
        return VolcengineSettingsDraft.defaultDataProServerID(for: configuration.id)
    }

    static func server(for configuration: WebSearchProviderConfiguration) throws -> MCPServerConfiguration {
        guard configuration.kind == .volcengine else {
            throw VolcengineSearchSettingsError.providerKindMismatch
        }
        return MCPServerConfiguration(
            id: serverID(for: configuration),
            displayName: displayName,
            endpoint: endpoint,
            enabled: true,
            allowInCanvas: false,
            allowInsecureHTTP: false,
            authentication: .customHeader,
            credentialHeaderName: credentialHeaderName,
            timeoutSeconds: 60
        )
    }

    /// A server may only be modified when it is this feature's exact
    /// endpoint/auth/header/display identity. A different user MCP that
    /// happens to occupy a persisted UUID is a collision, never an update.
    static func matchesOwnedServer(_ server: MCPServerConfiguration) -> Bool {
        VolcengineProfessionalSearch.matchesOwnedServer(server)
    }
}

enum VolcengineDataProState: Equatable, Sendable {
    case inactive
    case connecting
    case ready(Int)
    case failed(String)
}

/// Narrow feature seam over `MCPSettingsCenter`. The production adapter is
/// below; tests supply an in-memory manager so no shared MCP store, cloud
/// defaults or Keychain is touched merely to simulate a toggle.
/// Cancellation token for a feature-local MCP state observation. The
/// production adapter wraps the existing MCPSettingsCenter @Published state;
/// tests use an in-memory observer. No polling is involved.
final class VolcengineDataProObservation {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}

@MainActor
protocol VolcengineDataProManaging: AnyObject {
    func upsert(_ server: MCPServerConfiguration, credential: String?) async throws
    func setEnabled(_ enabled: Bool, serverID: UUID)
    func currentServer(serverID: UUID) -> MCPServerConfiguration?
    func state(serverID: UUID) -> VolcengineDataProState
    func refresh(serverID: UUID) async
    func observeState(
        serverID: UUID,
        onChange: @escaping @MainActor (VolcengineDataProState) -> Void
    ) -> VolcengineDataProObservation
}

#if canImport(UIKit)
import SwiftUI

// MARK: - Production MCP adapter

@MainActor
final class MCPSettingsCenterDataProManager: VolcengineDataProManaging {
    static let shared = MCPSettingsCenterDataProManager(center: .shared)

    private let center: MCPSettingsCenter

    init(center: MCPSettingsCenter) {
        self.center = center
    }

    func upsert(_ server: MCPServerConfiguration, credential: String?) async throws {
        try await center.upsert(server, credential: credential)
    }

    func setEnabled(_ enabled: Bool, serverID: UUID) {
        center.setEnabled(enabled, serverID: serverID)
    }

    func currentServer(serverID: UUID) -> MCPServerConfiguration? {
        center.servers.first { $0.id == serverID }
    }

    func state(serverID: UUID) -> VolcengineDataProState {
        Self.map(center.stateByServerID[serverID])
    }

    func refresh(serverID: UUID) async {
        await center.refresh(serverID: serverID)
    }

    func observeState(
        serverID: UUID,
        onChange: @escaping @MainActor (VolcengineDataProState) -> Void
    ) -> VolcengineDataProObservation {
        let cancellable = center.$stateByServerID
            .map { $0[serverID] }
            .removeDuplicates()
            .sink { state in
                Task { @MainActor in
                    onChange(Self.map(state))
                }
            }
        return VolcengineDataProObservation { cancellable.cancel() }
    }

    @MainActor
    private static func map(
        _ state: MCPSettingsCenter.ConnectionState?
    ) -> VolcengineDataProState {
        switch state {
        case .none, .inactive: .inactive
        case .connecting: .connecting
        case .ready(let count): .ready(count)
        case .failed(let message): .failed(message)
        }
    }
}

// MARK: - Editor

struct VolcengineSearchEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var center: WebSearchSettingsCenter
    let configuration: WebSearchProviderConfiguration
    /// Catalog provenance for an instance created from the signed catalog.
    /// Nil for an edit that predates catalogs; the dedicated interface and
    /// account guards below are identical in both cases.
    var provenance: SearchProviderCatalogProvenance?
    /// The effective signed catalog, read only for this preset's official
    /// titles so a save can tell a carried-over official name from a real
    /// user alias. Nil (or a missing entry) keeps the legacy name behavior.
    var catalog: SearchProviderCatalogIndex?
    /// Called after a successful save when this editor is pushed inside the
    /// Add Provider sheet (the sheet closes; the editor's own dismiss would
    /// only pop the navigation stack).
    var onFinished: (() -> Void)?

    @State private var draft: VolcengineSettingsDraft
    @State private var credential: String
    @State private var credentialsByMode: [VolcengineConfigurationMode: String]
    @State private var revealsCredential = false
    @State private var authenticationError: String?
    @State private var errorMessage: String?
    @State private var configurationError: String?
    @State private var saving = false
    @State private var advancedExpanded: Bool
    @State private var dataProState: VolcengineDataProState
    @State private var saveGeneration: UInt64 = 0
    @State private var refreshGeneration: UInt64 = 0
    @State private var observationGeneration: UInt64 = 0
    @State private var dataProObservation: VolcengineDataProObservation?

    @MainActor
    init(
        center: WebSearchSettingsCenter,
        configuration: WebSearchProviderConfiguration,
        provenance: SearchProviderCatalogProvenance? = nil,
        catalog: SearchProviderCatalogIndex? = nil,
        onFinished: (() -> Void)? = nil
    ) {
        self.center = center
        self.configuration = configuration
        self.provenance = provenance
        self.catalog = catalog
        self.onFinished = onFinished
        let officialName = Self.catalogEntry(
            in: catalog,
            presetID: provenance?.presetID
                ?? SearchProviderPresets.presetID(for: .volcengine)
        )?.displayName(localePrimary: WebSearchSettingsCenter.localePrimary)
        do {
            var loaded = try VolcengineSettingsDraft(configuration: configuration)
            loaded.officialName = officialName
            let stored = center.credential(forAccount: loaded.credentialAccount)?
                .values["apiKey"] ?? ""
            _draft = State(initialValue: loaded)
            _credential = State(initialValue: stored)
            _credentialsByMode = State(initialValue: [loaded.mode: stored])
            _configurationError = State(initialValue: nil)
            _advancedExpanded = State(initialValue:
                loaded.mode == .legacyCustom || loaded.mode == .arkResponses
            )
        } catch {
            var fallback = VolcengineSettingsDraft.fallback(configuration: configuration)
            fallback.officialName = officialName
            _draft = State(initialValue: fallback)
            _credential = State(initialValue: "")
            _credentialsByMode = State(initialValue: [:])
            _configurationError = State(initialValue:
                FloeL10n.l("websearch.volcengine.error.configuration")
            )
            _advancedExpanded = State(initialValue: true)
        }
        _dataProState = State(initialValue: center.dataProState(for: configuration))
    }

    /// The catalog entry owning this provider's official title, when the
    /// effective catalog still carries the preset.
    private static func catalogEntry(
        in catalog: SearchProviderCatalogIndex?,
        presetID: String?
    ) -> SearchProviderCatalogEntry? {
        guard let catalog, let presetID else { return nil }
        return catalog.entry(presetID: presetID)
    }

    private var entry: SearchProviderCatalogEntry? {
        Self.catalogEntry(
            in: catalog,
            presetID: provenance?.presetID
                ?? SearchProviderPresets.presetID(for: .volcengine)
        )
    }

    /// The catalog's current official title for the active locale.
    private var officialName: String? {
        entry?.displayName(localePrimary: WebSearchSettingsCenter.localePrimary)
    }

    /// Every official title the current entry carries, mirroring the generic
    /// editor's official-name set so both editors treat the same titles as
    /// catalog-owned.
    private var officialNames: Set<String> {
        guard let entry else { return [] }
        let locale = WebSearchSettingsCenter.localePrimary
        return Set([entry.name[locale], entry.name["en"], entry.name["zh-Hans"]].compactMap { $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("websearch.display_name", text: $draft.displayName)
                    Picker("websearch.volcengine.interface", selection: $draft.mode) {
                        ForEach(VolcengineConfigurationMode.allCases) { mode in
                            Text(modeLabel(mode)).tag(mode)
                        }
                    }
                }

                if draft.mode == .arkResponses {
                    Section {
                        Picker("websearch.volcengine.engine", selection: $draft.arkEngine) {
                            Text("websearch.volcengine.engine.doubao")
                                .tag(VolcengineArkSearchEngine.doubaoCustom)
                            Text("websearch.volcengine.engine.online")
                                .tag(VolcengineArkSearchEngine.onlineContent)
                        }
                    }
                }

                Section {
                    credentialField
                }

                if draft.mode == .agentPlan || draft.mode == .doubaoSearch {
                    Section {
                        Toggle("websearch.volcengine.queryRewrite", isOn: $draft.queryRewrite)
                        Toggle("websearch.volcengine.authoritativeOnly", isOn: $draft.authoritativeOnly)
                    }
                }

                SearchTestSection(
                    center: center,
                    configuration: { try? draft.configuration() },
                    credential: {
                        let supplied = credential.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !supplied.isEmpty {
                            return WebSearchCredential(values: ["apiKey": supplied])
                        }
                        return center.credential(forAccount: draft.credentialAccount)
                    }
                )

                Section {
                    Toggle("websearch.volcengine.dataPro", isOn: $draft.dataProEnabled)
                        .disabled(draft.mode != .agentPlan)
                    if draft.mode == .agentPlan, draft.dataProEnabled {
                        HStack {
                            Text(dataProStateText)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("websearch.volcengine.dataPro.retry") {
                                refreshDataPro()
                            }
                            .buttonStyle(.borderless)
                            .disabled(dataProState == .connecting)
                        }
                    }
                } footer: {
                    if draft.mode != .agentPlan {
                        Text("websearch.volcengine.dataPro.requiresAgentPlan")
                    } else if draft.dataProEnabled {
                        Text("websearch.volcengine.dataPro.footer")
                    }
                }

                if draft.mode == .legacyCustom || draft.mode == .arkResponses {
                    Section {
                        DisclosureGroup("websearch.volcengine.advanced", isExpanded: $advancedExpanded) {
                            if draft.mode == .legacyCustom {
                                TextField("websearch.endpoint", text: $draft.endpoint)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                                    .autocorrectionDisabled()
                            }
                            if draft.mode == .arkResponses {
                                TextField("websearch.volcengine.model", text: $draft.arkModel)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                    }
                }

                if let message = errorMessage
                    ?? configurationError
                    ?? authenticationError {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(configuration.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { save() }
                        .disabled(saving || configurationError != nil)
                }
            }
            .onChange(of: draft.mode) { oldMode, newMode in
                modeChanged(from: oldMode, to: newMode)
            }
            .onAppear {
                startDataProObservation()
            }
            .onDisappear {
                saveGeneration &+= 1
                refreshGeneration &+= 1
                stopDataProObservation()
            }
        }
    }

    private var credentialField: some View {
        HStack {
            if revealsCredential {
                TextField(credentialLabel, text: $credential)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                SecureField(credentialLabel, text: $credential)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button {
                if revealsCredential {
                    revealsCredential = false
                } else {
                    Task { await revealCredential() }
                }
            } label: {
                Image(systemName: revealsCredential ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealsCredential
                ? "settings.web_search_settings_center.hide_credentials"
                : "settings.web_search_settings_center.show_credentials")
        }
    }

    @MainActor
    private func revealCredential() async {
        do {
            guard try await DeviceOwnerAuthenticator.authenticate(
                reason: FloeL10n.l("settings.web_search_settings_center.view_saved_web_search_credentials")
            ) else { return }
            authenticationError = nil
            revealsCredential = true
        } catch {
            authenticationError = error.localizedDescription
        }
    }

    private func modeChanged(
        from oldMode: VolcengineConfigurationMode,
        to newMode: VolcengineConfigurationMode
    ) {
        credentialsByMode[oldMode] = credential
        let stored = center.credential(
            forAccount: draft.credentialAccount(for: newMode)
        )?.values["apiKey"] ?? ""
        credential = credentialsByMode[newMode] ?? stored
        revealsCredential = false
        authenticationError = nil
        configurationError = nil
        if newMode != .agentPlan {
            draft.dataProEnabled = false
            dataProState = .inactive
            stopDataProObservation()
        } else {
            startDataProObservation()
        }
        if newMode == .legacyCustom || newMode == .arkResponses {
            advancedExpanded = true
        }
    }

    private func save() {
        guard !saving, configurationError == nil else { return }
        saving = true
        errorMessage = nil
        let generation = saveGeneration &+ 1
        saveGeneration = generation
        var snapshot = draft
        // Re-read the official title at save time: a catalog rename that
        // landed while this sheet stayed open is then adopted by the save
        // instead of being frozen in or marked as a user alias.
        snapshot.officialName = officialName
        let openingTitle = snapshot.openingDisplayName
        let officialTitle = officialName
        let officialTitles = officialNames
        let supplied = credential.trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor in
            do {
                var updated = try snapshot.configuration()
                // Saving is always allowed: a configuration without a usable
                // key is persisted disabled instead of rejected.
                if updated.enabled,
                   supplied.isEmpty,
                   !center.hasCredential(account: snapshot.credentialAccount) {
                    updated.enabled = false
                }
                let credentialValue: WebSearchCredential? = supplied.isEmpty
                    ? nil
                    : WebSearchCredential(values: ["apiKey": supplied])
                try center.upsert(
                    updated,
                    credential: credentialValue,
                    provenance: provenance,
                    nameOwnership: SearchProviderNameOwnership(
                        openingTitle: openingTitle,
                        officialTitle: officialTitle,
                        officialTitles: officialTitles
                    )
                )

                let dataProCredential: String? = supplied.isEmpty
                    ? center.credential(forAccount: snapshot.credentialAccount)?
                        .values["apiKey"]
                    : supplied
                try await center.setDataProEnabled(
                    snapshot.mode == .agentPlan && snapshot.dataProEnabled,
                    for: updated,
                    credential: dataProCredential
                )
                guard saveGeneration == generation else { return }
                saving = false
                if let onFinished {
                    onFinished()
                } else {
                    dismiss()
                }
            } catch {
                guard saveGeneration == generation else { return }
                saving = false
                errorMessage = localizedMessage(for: error)
            }
        }
    }

    private func refreshDataPro() {
        guard let current = try? draft.configuration() else { return }
        let generation = refreshGeneration &+ 1
        refreshGeneration = generation
        Task { @MainActor in
            let next = await center.refreshDataPro(for: current)
            guard refreshGeneration == generation else { return }
            dataProState = next
        }
    }

    private func startDataProObservation() {
        dataProObservation?.cancel()
        dataProObservation = nil
        observationGeneration &+= 1
        refreshGeneration &+= 1
        let generation = observationGeneration
        guard draft.mode == .agentPlan,
              let current = try? draft.configuration() else {
            dataProState = .inactive
            return
        }
        dataProObservation = center.observeDataPro(for: current) { state in
            guard observationGeneration == generation else { return }
            dataProState = state
        }
        if dataProObservation == nil {
            dataProState = .inactive
        }
    }

    private func stopDataProObservation() {
        observationGeneration &+= 1
        refreshGeneration &+= 1
        dataProObservation?.cancel()
        dataProObservation = nil
        dataProState = .inactive
    }

    private func cancel() {
        saveGeneration &+= 1
        refreshGeneration &+= 1
        stopDataProObservation()
        dismiss()
    }

    private var credentialLabel: String {
        switch draft.mode {
        case .agentPlan: FloeL10n.l("websearch.volcengine.credential.agentPlan")
        case .arkResponses: FloeL10n.l("websearch.volcengine.credential.ark")
        case .doubaoSearch: FloeL10n.l("websearch.volcengine.credential.doubao")
        case .legacyCustom: FloeL10n.l("websearch.volcengine.credential.legacy")
        }
    }

    private var dataProStateText: String {
        switch dataProState {
        case .inactive: FloeL10n.l("skills.skills_view.not_connected")
        case .connecting: FloeL10n.l("skills.skills_view.reading_tools")
        case .ready(let count):
            FloeL10n.plural("skills.skills_view.tools_available", count: count)
        case .failed(let message):
            FloeL10n.l("skills.skills_view.connection_failed", message)
        }
    }

    private func modeLabel(_ mode: VolcengineConfigurationMode) -> String {
        switch mode {
        case .agentPlan: FloeL10n.l("websearch.volcengine.agentPlan")
        case .arkResponses: FloeL10n.l("websearch.volcengine.arkResponses")
        case .doubaoSearch: FloeL10n.l("websearch.volcengine.doubaoSearch")
        case .legacyCustom: FloeL10n.l("websearch.volcengine.legacy")
        }
    }

    private func localizedMessage(for error: Error) -> String {
        guard let settingsError = error as? VolcengineSearchSettingsError else {
            return error.localizedDescription
        }
        switch settingsError {
        case .missingCredential:
            return FloeL10n.l("websearch.volcengine.error.credential")
        case .invalidEndpoint:
            return FloeL10n.l("websearch.volcengine.error.endpoint")
        case .invalidArkModel:
            return FloeL10n.l("websearch.volcengine.error.model")
        case .requiresAgentPlan:
            return FloeL10n.l("websearch.volcengine.error.requiresAgentPlan")
        case .dataProUnavailable:
            return FloeL10n.l("websearch.volcengine.error.dataProUnavailable")
        case .serverIdentityConflict:
            return FloeL10n.l("websearch.volcengine.error.dataProConflict")
        case .providerKindMismatch, .malformedInterfaceSelection:
            return FloeL10n.l("websearch.volcengine.error.configuration")
        }
    }
}
#endif
