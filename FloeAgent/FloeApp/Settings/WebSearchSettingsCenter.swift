#if canImport(SwiftUI)
import Foundation
import SwiftUI
import FloeCore
import FloeExecution
import FloeSecurity

// MARK: - Catalog provenance

/// Catalog context captured for an instance when it is created from the
/// Add Provider catalog or reviewed against a newer catalog revision. Values
/// are metadata only; no secret ever enters this struct.
struct SearchProviderCatalogProvenance: Sendable {
    var presetID: String?
    var catalogVersion: String?
    var credentialKeys: [String]?

    init(
        presetID: String? = nil,
        catalogVersion: String? = nil,
        credentialKeys: [String]? = nil
    ) {
        self.presetID = presetID
        self.catalogVersion = catalogVersion
        self.credentialKeys = credentialKeys
    }
}

enum WebSearchSettingsError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case invalidDisplayName
    case missingRequiredCredential
    case confirmationRequired
    case instanceNotFound
    case catalogUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid http(s) address without credentials."
        case .invalidDisplayName: "Enter a name for this provider."
        case .missingRequiredCredential: "Enter the required credentials before saving."
        case .confirmationRequired: "Review and confirm this catalog change first."
        case .instanceNotFound: "This provider is no longer available."
        case .catalogUnavailable: "The search provider catalog is unavailable."
        }
    }
}

// MARK: - Settings center

/// Owns the user's search-provider instances (`floe.webSearch.instances.v2`),
/// their per-instance Keychain credentials, the v1 → v2 migration and the
/// catalog review/apply operations. The signed catalog itself is owned by
/// `ContentUpdateCenter`; views pass the effective catalog value in, so this
/// center has no second updater or unsigned fetch path.
///
/// Settled behavior:
/// * the main list shows only user-added instances; nothing is auto-created,
///   auto-added or default-enabled by a catalog revision;
/// * every instance owns an independent Keychain account derived from its
///   UUID, so two accounts of the same brand never share one secret;
/// * the v1 key and its legacy Keychain entries are preserved as a backup;
/// * the runtime resolves a frozen configuration + credential snapshot per
///   query; applying a catalog update never touches a running query.
@MainActor
final class WebSearchSettingsCenter: ObservableObject {
    nonisolated static let defaultsKey = WebSearchInstanceStore.legacyProvidersKey
    nonisolated static let keychainService = WebSearchInstanceStore.keychainService
    nonisolated static let instancesKey = WebSearchInstanceStore.instancesKey
    nonisolated static let migrationBackupKey = WebSearchInstanceStore.migrationBackupKey

    @Published private(set) var instances: [WebSearchProviderInstance] = []

    /// Compatibility projection for existing readers (runtime note, tests).
    var providers: [WebSearchProviderConfiguration] { instances.map(\.configuration) }

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

    nonisolated static var localePrimary: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return code.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    // MARK: - Loading, migration, persistence

    func reload() {
        let cloudV2 = cloud.data(forKey: Self.instancesKey)
        let localV2 = defaults.data(forKey: Self.instancesKey)
        if let data = cloudV2 ?? localV2,
           let decoded = try? JSONDecoder().decode([WebSearchProviderInstance].self, from: data) {
            instances = Self.sorted(decoded)
            if cloudV2 != nil, let encoded = try? JSONEncoder().encode(instances),
               encoded != localV2 {
                // Runtime resolution reads local defaults; mirror cloud
                // hydration immediately instead of waiting for a Save tap.
                defaults.set(encoded, forKey: Self.instancesKey)
            }
            FloeLogger(category: .sync).info(
                "webSearchSettingsLoaded source=\(cloudV2 == nil ? "local" : "cloud") format=v2 count=\(instances.count) enabled=\(instances.filter { $0.configuration.enabled }.count)"
            )
            return
        }

        let cloudV1 = cloud.data(forKey: Self.defaultsKey)
        let localV1 = defaults.data(forKey: Self.defaultsKey)
        if let data = cloudV1 ?? localV1,
           let decoded = try? JSONDecoder().decode([WebSearchProviderConfiguration].self, from: data) {
            migrateLegacy(decoded)
            return
        }

        if let data = cloudV1 ?? localV1 {
            // Unreadable legacy payload: retain the exact bytes as a backup
            // before pinning the empty user-instance state.
            defaults.set(data, forKey: Self.migrationBackupKey)
            cloud.set(data, forKey: Self.migrationBackupKey)
        }
        // Fresh state: no auto-created presets and no auto-add later when a
        // catalog revision arrives. The user adds providers explicitly.
        instances = []
        persist()
        FloeLogger(category: .sync).info("webSearchSettingsLoaded source=empty count=0")
    }

    private func migrateLegacy(_ records: [WebSearchProviderConfiguration]) {
        let result = WebSearchInstanceMigration.migrate(
            records: records,
            hasCredential: { [credentialStore] account in
                guard let data = try? credentialStore.read(account) else { return false }
                return !data.isEmpty
            }
        )
        var copied = 0
        for outcome in result.outcomes {
            for copy in outcome.credentialCopies where copy.from != copy.to {
                // Copy, never move: legacy shared entries stay readable as a
                // backup and each instance owns its own account from now on.
                guard (try? credentialStore.read(copy.to)) == nil,
                      let data = try? credentialStore.read(copy.from) else { continue }
                do {
                    try credentialStore.write(copy.to, data)
                    copied += 1
                } catch {
                    FloeLogger(category: .sync).warning(
                        "webSearchMigrationCredentialCopyFailed"
                    )
                }
            }
        }
        instances = Self.sorted(result.instances)
        let backup = result.backupDocument(originalRecords: records)
        defaults.set(backup, forKey: Self.migrationBackupKey)
        cloud.set(backup, forKey: Self.migrationBackupKey)
        // Keep the original v1 bytes untouched; v2 is the live store.
        persist()
        FloeLogger(category: .sync).info(
            "webSearchMigration legacy=\(records.count) kept=\(result.instances.count) droppedPlaceholders=\(result.droppedPlaceholderCount) credentialCopies=\(copied)"
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(instances) else { return }
        defaults.set(data, forKey: Self.instancesKey)
        cloud.set(data, forKey: Self.instancesKey)
        cloud.synchronize()
        FloeLogger(category: .sync).debug(
            "webSearchInstancesPersisted bytes=\(data.count) count=\(instances.count) enabled=\(instances.filter { $0.configuration.enabled }.count)"
        )
    }

    nonisolated static func sorted(
        _ instances: [WebSearchProviderInstance]
    ) -> [WebSearchProviderInstance] {
        instances.enumerated().sorted { lhs, rhs in
            if lhs.element.configuration.priority != rhs.element.configuration.priority {
                return lhs.element.configuration.priority < rhs.element.configuration.priority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - Instance mutations

    /// Saves a configuration the user edited (Volcengine's dedicated editor
    /// and the provider editor both go through this). Existing instances keep
    /// their catalog provenance; new identities get their preset identity and
    /// an independent, UUID-owned Keychain account.
    func upsert(
        _ configuration: WebSearchProviderConfiguration,
        credential: WebSearchCredential?,
        provenance: SearchProviderCatalogProvenance? = nil
    ) throws {
        try validateCredentialRequirement(for: configuration, supplied: credential)
        if let credential {
            let data = try JSONEncoder().encode(credential)
            try credentialStore.write(configuration.credentialAccount, data)
        }
        if let index = instances.firstIndex(where: { $0.configuration.id == configuration.id }) {
            var instance = instances[index]
            Self.recordOverrideChanges(
                previous: instance.configuration,
                updated: configuration,
                into: &instance
            )
            instance.configuration = configuration
            if let provenance {
                instance.presetID = provenance.presetID ?? instance.presetID
                if let version = provenance.catalogVersion {
                    instance.appliedCatalogVersion = version
                }
                if let keys = provenance.credentialKeys {
                    instance.catalogCredentialKeys = keys
                }
            }
            instances[index] = instance
        } else {
            var configuration = configuration
            configuration.priority = nextPriority()
            let instance = WebSearchProviderInstance(
                configuration: configuration,
                presetID: provenance?.presetID
                    ?? SearchProviderPresets.presetID(for: configuration.kind),
                appliedCatalogVersion: provenance?.catalogVersion,
                overrides: [],
                catalogCredentialKeys: provenance?.credentialKeys
            )
            instances.append(instance)
        }
        instances = Self.sorted(instances)
        FloeLogger(category: .sync).info(
            "webSearchProviderSaved provider=\(configuration.kind.rawValue) enabled=\(configuration.enabled) endpointHost=\(configuration.endpoint?.host ?? "default") credentialUpdated=\(credential != nil)"
        )
        persist()
    }

    /// Saves a full instance (catalog-managed fields + user overrides already
    /// computed by the editor). New identities are appended disabled; nothing
    /// is auto-enabled.
    func saveInstance(
        _ instance: WebSearchProviderInstance,
        credential: WebSearchCredential?
    ) throws {
        try validateCredentialRequirement(for: instance.configuration, supplied: credential)
        if let credential {
            let data = try JSONEncoder().encode(credential)
            try credentialStore.write(instance.configuration.credentialAccount, data)
        }
        var instance = instance
        // An unready configuration (a required credential is missing and none
        // is stored) or an untested new instance is saved DISABLED: saving is
        // always allowed, enablement only ever follows an explicit user
        // switch backed by a usable credential.
        let suppliedValue = credential?.values.values.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        if instance.configuration.kind.requiresCredential,
           !suppliedValue,
           !hasCredential(account: instance.configuration.credentialAccount) {
            instance.configuration.enabled = false
        }
        if let index = instances.firstIndex(where: { $0.configuration.id == instance.configuration.id }) {
            instance.configuration.priority = instances[index].configuration.priority
            instances[index] = instance
        } else {
            instance.configuration.enabled = false
            instance.configuration.priority = nextPriority()
            instances.append(instance)
        }
        instances = Self.sorted(instances)
        persist()
    }

    private func validateCredentialRequirement(
        for configuration: WebSearchProviderConfiguration,
        supplied: WebSearchCredential?
    ) throws {
        // A Keychain write failure must not publish an enabled configuration
        // whose selected account still holds another interface's secret. The
        // secret is stored BEFORE any in-memory/persisted provider mutation.
        let hasSuppliedCredential = supplied?.values.values.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        if configuration.kind == .volcengine,
           configuration.enabled,
           !hasSuppliedCredential,
           !hasCredential(account: configuration.credentialAccount) {
            throw VolcengineSearchSettingsError.missingCredential
        }
    }

    private func nextPriority() -> Int {
        (instances.map(\.configuration.priority).max() ?? -1) + 1
    }

    /// Records the fields the user personally changed. Catalog updates merge
    /// only values the user has not overridden. Option keys are tracked
    /// individually so changing one option never freezes an unrelated one.
    nonisolated static func recordOverrideChanges(
        previous: WebSearchProviderConfiguration,
        updated: WebSearchProviderConfiguration,
        into instance: inout WebSearchProviderInstance
    ) {
        if previous.displayName != updated.displayName {
            instance.overrides.insert("displayName")
        }
        if previous.endpoint != updated.endpoint {
            instance.overrides.insert("endpoint")
        }
        for (key, value) in updated.options where previous.options[key] != value {
            instance.overrides.insert("option:\(key)")
        }
        for key in previous.options.keys where updated.options[key] == nil {
            instance.overrides.insert("option:\(key)")
        }
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = instances.firstIndex(where: { $0.configuration.id == id }) else { return }
        instances[index].configuration.enabled = enabled
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        instances.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for index in instances.indices {
            instances[index].configuration.priority = index
        }
        persist()
    }

    func remove(id: UUID) {
        guard let instance = instances.first(where: { $0.configuration.id == id }) else { return }
        instances.removeAll { $0.configuration.id == id }
        for index in instances.indices {
            instances[index].configuration.priority = index
        }
        // Delete only credentials that belong to this provider identity. A
        // shared legacy account (web-search.<kind>) stays untouched as the
        // migration backup.
        let account = instance.configuration.credentialAccount.lowercased()
        if account.contains(id.uuidString.lowercased()) {
            try? credentialStore.delete(instance.configuration.credentialAccount)
        }
        persist()
    }

    // MARK: - Credentials

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

    // MARK: - Catalog review / apply

    /// The pending catalog plan for one instance, if any. Pure and read-only:
    /// nothing is applied or persisted until `applyCatalogUpdate`.
    func updatePlan(
        for instance: WebSearchProviderInstance,
        catalog: SearchProviderCatalogIndex
    ) -> SearchProviderUpdatePlan? {
        SearchProviderUpdatePlanner.plan(for: instance, in: catalog, localePrimary: Self.localePrimary)
    }

    /// Applies a reviewed plan. Host or credential-schema changes require an
    /// explicit confirmation and rotate the credential account, so a key that
    /// was stored for the old destination can never be sent to a new one.
    /// The old Keychain entry is retained as a backup.
    @discardableResult
    func applyCatalogUpdate(
        _ plan: SearchProviderUpdatePlan,
        to instanceID: UUID,
        catalog: SearchProviderCatalogIndex,
        confirmed: Bool
    ) throws -> WebSearchProviderInstance {
        guard let index = instances.firstIndex(where: { $0.configuration.id == instanceID }) else {
            throw WebSearchSettingsError.instanceNotFound
        }
        guard let entry = catalog.entry(presetID: plan.presetID) else {
            throw WebSearchSettingsError.catalogUnavailable
        }
        if plan.requiresConfirmation, !confirmed {
            throw WebSearchSettingsError.confirmationRequired
        }
        var rotatedAccount: String?
        if plan.rotatesCredentialAccount {
            let base = "web-search.instance.\(instanceID.uuidString.lowercased()).catalog.\(Self.accountVersionSlug(catalog.version))"
            rotatedAccount = hasCredential(account: base) ? "\(base).\(UUID().uuidString.lowercased())" : base
        }
        let outcome = SearchProviderUpdatePlanner.apply(
            plan,
            to: instances[index],
            entry: entry,
            rotatedCredentialAccount: rotatedAccount
        )
        instances[index] = outcome.instance
        persist()
        FloeLogger(category: .sync).info(
            "webSearchCatalogApplied preset=\(plan.presetID) from=\(plan.fromCatalogVersion ?? "none") to=\(plan.toCatalogVersion) changes=\(plan.changes.count) rotatedCredential=\(outcome.didRotateCredential)"
        )
        return outcome.instance
    }

    private static func accountVersionSlug(_ version: String) -> String {
        version.replacingOccurrences(of: ".", with: "_")
    }

    // MARK: - Test Search

    /// One-shot Test Search over the real `WebSearchService` with a frozen
    /// draft configuration and an in-memory credential. Exactly one provider
    /// is attempted: no cross-provider fallback and nothing persisted.
    func testSearch(
        configuration: WebSearchProviderConfiguration,
        credential: WebSearchCredential,
        query: String
    ) async -> WebSearchTestOutcome {
        await WebSearchService.searchTest(
            configuration: configuration,
            credential: credential,
            text: query,
            maxResults: 5
        )
    }

    // MARK: - DataPro (unchanged lifecycle)

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

    // MARK: - Runtime resolution

    nonisolated static func resolvedConfigurations() async -> [(WebSearchProviderConfiguration, WebSearchCredential)] {
        readyConfigurations()
    }

    nonisolated static func toolIsAvailable(
        _ name: String,
        defaults: UserDefaults = .standard,
        cloudData: (String) -> Data? = { NSUbiquitousKeyValueStore.default.data(forKey: $0) }
    ) -> Bool {
        let ready = readyConfigurations(defaults: defaults, cloudData: cloudData)
        if name == WebSearchTool.name { return !ready.isEmpty }
        if name == BochaAISearchTool.name { return ready.contains { $0.0.kind == .bochaWeb || $0.0.kind == .bochaAI } }
        return false
    }

    /// v2 user instances first, then the legacy v1 array with its historical
    /// semantics (including the Bocha shared-account fallback) for the window
    /// before the settings page has migrated a device.
    nonisolated private static func readyConfigurations(
        defaults: UserDefaults = .standard,
        cloudData: (String) -> Data? = { NSUbiquitousKeyValueStore.default.data(forKey: $0) }
    ) -> [(WebSearchProviderConfiguration, WebSearchCredential)] {
        let keychain = KeychainStore(service: keychainService, synchronizable: true)

        let v2Snapshots = [
            cloudData(instancesKey),
            defaults.data(forKey: instancesKey)
        ]
        if let data = v2Snapshots.compactMap({ $0 }).first,
           let decoded = try? JSONDecoder().decode([WebSearchProviderInstance].self, from: data) {
            let candidates: [(WebSearchProviderConfiguration, WebSearchCredential)] =
                sorted(decoded).map(\.configuration).filter(\.enabled).compactMap { configuration in
                    if let secret = try? keychain.read(account: configuration.credentialAccount),
                       let credential = try? JSONDecoder().decode(WebSearchCredential.self, from: secret) {
                        return (configuration, credential)
                    }
                    return configuration.kind.requiresCredential
                        ? nil
                        : (configuration, WebSearchCredential(values: [:]))
                }
            return candidates.map { configuration, credential in
                (configuration, WebSearchCredential(values: credential.values.mapValues {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }))
            }.filter { WebSearchService.isConfigured($0.0, credential: $0.1) }
        }

        let snapshots = [cloudData(defaultsKey), defaults.data(forKey: defaultsKey)]
        guard let providers = snapshots.compactMap({ data -> [WebSearchProviderConfiguration]? in
            guard let data else { return nil }
            return try? JSONDecoder().decode([WebSearchProviderConfiguration].self, from: data)
        }).first else { return [] }
        let candidates: [(WebSearchProviderConfiguration, WebSearchCredential)] = legacyNormalizedProviders(providers).filter(\.enabled).compactMap { configuration in
            if let secret = try? keychain.read(account: configuration.credentialAccount),
               let credential = try? JSONDecoder().decode(WebSearchCredential.self, from: secret) {
                return (configuration, credential)
            }
            if configuration.kind == .bochaWeb,
               let secret = try? keychain.read(account: "web-search.bochaAI"),
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

    /// v1.4.19 presents Bocha as one provider. Older installs stored Web and
    /// AI search separately even though they share one account and key. This
    /// legacy-only projection keeps the pre-migration runtime contract; new
    /// instances never pass through it, which is what fixes the old global
    /// credential-account rewrite.
    nonisolated static func legacyNormalizedProviders(
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

    nonisolated static func runtimeProviderNote() -> String? {
        let ready = readyConfigurations().map(\.0)
        guard !ready.isEmpty else { return nil }
        return "Available web search providers: "
            + ready.map { "\($0.displayName) [\($0.kind.rawValue)]" }.joined(separator: ", ")
            + ". The optional web.search provider argument must use one of these names or kinds."
    }
}

// MARK: - Main settings list

/// Web Search settings. The list contains only instances the user added:
/// each row has an independent enabled switch, tapping the row edits it,
/// swipe deletes with confirmation and edit mode reorders. `+` opens the
/// searchable official catalog (with a signed refresh) and selecting an entry
/// opens its configuration; cancelling creates nothing.
///
/// The catalog owner is injected by the settings shell so this page delegates
/// refresh/install to the same `ContentUpdateCenter` as the Content Updates
/// page — there is no second updater here.
#if canImport(UIKit)
struct WebSearchSettingsView: View {
    @ObservedObject var center: WebSearchSettingsCenter
    var catalogOwner: ContentUpdateCenter

    @State private var showingCatalog = false
    @State private var editing: WebSearchProviderInstance?
    @State private var pendingDeletion: WebSearchProviderInstance?

    private var catalog: SearchProviderCatalogIndex? {
        catalogOwner.searchProviderCatalog()
    }

    var body: some View {
        List {
            Section {
                if center.instances.isEmpty {
                    Button {
                        showingCatalog = true
                    } label: {
                        Label("websearch.add_provider", systemImage: "plus.circle")
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("websearch.add")
                } else {
                    ForEach(center.instances) { instance in
                        row(for: instance)
                    }
                    .onMove { source, destination in
                        center.move(fromOffsets: source, toOffset: destination)
                    }
                }
            } header: {
                Text("websearch.providers")
            }
        }
        .navigationTitle(FloeL10n.l("websearch.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCatalog = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("websearch.add_provider")
                .accessibilityIdentifier("websearch.add.toolbar")
            }
            if center.instances.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .sheet(isPresented: $showingCatalog) {
            SearchProviderCatalogPicker(
                center: center,
                catalogOwner: catalogOwner,
                isPresented: $showingCatalog
            )
        }
        .sheet(item: $editing) { instance in
            if instance.configuration.kind == .volcengine {
                VolcengineSearchEditor(
                    center: center,
                    configuration: instance.configuration,
                    provenance: SearchProviderCatalogProvenance(
                        presetID: instance.presetID,
                        catalogVersion: instance.appliedCatalogVersion,
                        credentialKeys: instance.catalogCredentialKeys
                    )
                )
            } else {
                WebSearchProviderEditor(
                    center: center,
                    instance: instance,
                    catalog: catalog,
                    onFinished: { editing = nil }
                )
            }
        }
        .confirmationDialog(
            FloeL10n.l("websearch.delete.confirm"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("action.delete", role: .destructive) {
                if let id = pendingDeletion?.configuration.id {
                    center.remove(id: id)
                }
                pendingDeletion = nil
            }
            Button("action.cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let name = pendingDeletion?.configuration.displayName {
                Text(name)
            }
        }
    }

    @ViewBuilder
    private func row(for instance: WebSearchProviderInstance) -> some View {
        let entry = catalog?.entry(presetID: instance.presetID ?? "")
        let brandName = entry.map { $0.displayName(localePrimary: WebSearchSettingsCenter.localePrimary) }
        let hasUpdate = catalog.flatMap {
            center.updatePlan(for: instance, catalog: $0)
        } != nil
        HStack(spacing: 12) {
            Button {
                editing = instance
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(instance.configuration.displayName)
                        .foregroundStyle(.primary)
                    if let brandName, brandName != instance.configuration.displayName {
                        Text(brandName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if hasUpdate {
                        Text("websearch.update_available")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FloeTheme.pending)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("websearch.instance.\(instance.configuration.id.uuidString)")
            Toggle("", isOn: Binding(
                get: { instance.configuration.enabled },
                set: { center.setEnabled($0, id: instance.configuration.id) }
            ))
            .labelsHidden()
            .accessibilityLabel(instance.configuration.displayName)
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("action.delete", role: .destructive) {
                pendingDeletion = instance
            }
        }
    }
}

// MARK: - Catalog picker (add flow)

private struct SearchProviderCatalogPicker: View {
    /// One pick: the catalog entry plus the draft instance created when the
    /// row was tapped. Holding the instance in state keeps its UUID stable
    /// across view updates, so cancelling really creates nothing.
    struct Selection: Hashable {
        let entry: SearchProviderCatalogEntry
        let instance: WebSearchProviderInstance
    }

    @ObservedObject var center: WebSearchSettingsCenter
    var catalogOwner: ContentUpdateCenter
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var refreshing = false
    @State private var selection: Selection?

    private var catalog: SearchProviderCatalogIndex? {
        catalogOwner.searchProviderCatalog()
    }

    private var brandedEntries: [SearchProviderCatalogEntry] {
        guard let catalog else { return [] }
        let branded = catalog.search(query: query, localePrimary: WebSearchSettingsCenter.localePrimary)
            .filter { $0.presetID != SearchProviderPresets.custom }
        return branded
    }

    private var customEntry: SearchProviderCatalogEntry? {
        guard let catalog,
              catalog.search(query: query, localePrimary: WebSearchSettingsCenter.localePrimary)
                .contains(where: { $0.presetID == SearchProviderPresets.custom }) else {
            return nil
        }
        return catalog.entry(presetID: SearchProviderPresets.custom)
    }

    var body: some View {
        NavigationStack {
            List {
                if catalog == nil {
                    Text("websearch.catalog.unavailable")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        if brandedEntries.isEmpty {
                            Text("websearch.catalog.no_match")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(brandedEntries) { entry in
                                Button {
                                    selection = Selection(entry: entry, instance: addDraft(for: entry))
                                } label: {
                                    row(entry)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("websearch.catalog.entry.\(entry.presetID)")
                            }
                        }
                    }
                    if let customEntry {
                        Section {
                            Button {
                                selection = Selection(entry: customEntry, instance: addDraft(for: customEntry))
                            } label: {
                                row(customEntry)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("websearch.catalog.entry.\(customEntry.presetID)")
                        }
                    }
                    if let error = catalogOwner.errorMessage {
                        Section {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("websearch.catalog.search_placeholder")
            )
            .navigationTitle(FloeL10n.l("websearch.catalog.title"))
            .navigationDestination(item: $selection) { selection in
                if selection.entry.supportedAdapter == .volcengine {
                    VolcengineSearchEditor(
                        center: center,
                        configuration: selection.instance.configuration,
                        provenance: SearchProviderCatalogProvenance(
                            presetID: selection.entry.presetID,
                            catalogVersion: catalog?.version,
                            credentialKeys: selection.entry.credentialKeys
                        ),
                        onFinished: { isPresented = false }
                    )
                } else {
                    WebSearchProviderEditor(
                        center: center,
                        instance: selection.instance,
                        catalog: catalog,
                        onFinished: { isPresented = false }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refresh()
                    } label: {
                        if refreshing || catalogOwner.isChecking {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel("settings.content_updates.catalog.refresh")
                    .accessibilityIdentifier("websearch.catalog.refresh")
                    .disabled(refreshing || catalogOwner.isChecking)
                }
            }
        }
    }

    private func row(_ entry: SearchProviderCatalogEntry) -> some View {
        Text(entry.displayName(localePrimary: WebSearchSettingsCenter.localePrimary))
            .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget, alignment: .leading)
    }

    private func addDraft(for entry: SearchProviderCatalogEntry) -> WebSearchProviderInstance {
        SearchProviderDraftFactory.draftInstance(
            for: entry,
            localePrimary: WebSearchSettingsCenter.localePrimary,
            volcengineCredentialAccount: { id in
                VolcengineSettingsDraft.perProviderCredentialAccount(
                    for: id,
                    interface: .agentPlan
                )
            }
        ) ?? WebSearchProviderInstance(
            configuration: WebSearchProviderConfiguration(
                kind: .custom,
                displayName: entry.displayName(localePrimary: WebSearchSettingsCenter.localePrimary),
                credentialAccount: WebSearchProviderInstance.credentialAccount(for: UUID()),
                enabled: false
            ),
            presetID: entry.presetID,
            appliedCatalogVersion: nil
        )
    }

    private func refresh() {
        refreshing = true
        Task { @MainActor in
            await catalogOwner.refreshSearchProviderCatalog()
            refreshing = false
        }
    }
}

// MARK: - Provider editor (non-Volcengine)

/// Configuration editor for one instance. Used for both a catalog pick (new,
/// never persisted until Save) and editing a saved instance. Requirements:
/// only validated fields are saved, a new/untested instance is saved
/// disabled, the credential values are written to the instance-owned account
/// only, and Test Search runs the real service with the frozen draft.
struct WebSearchProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    let center: WebSearchSettingsCenter
    let instance: WebSearchProviderInstance
    let catalog: SearchProviderCatalogIndex?
    let onFinished: () -> Void

    @State private var configuration: WebSearchProviderConfiguration
    @State private var displayName: String
    @State private var endpointText: String
    @State private var credentialValues: [String: String] = [:]
    @State private var optionValues: [String: String] = [:]
    @State private var revealsSecrets = false
    @State private var authenticationError: String?
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var updateConfirmationPresented = false
    @State private var appliedNotice = false

    init(
        center: WebSearchSettingsCenter,
        instance: WebSearchProviderInstance,
        catalog: SearchProviderCatalogIndex?,
        onFinished: @escaping () -> Void
    ) {
        self.center = center
        self.instance = instance
        self.catalog = catalog
        self.onFinished = onFinished
        let configuration = instance.configuration
        _configuration = State(initialValue: configuration)
        _displayName = State(initialValue: configuration.displayName)
        _endpointText = State(initialValue: configuration.endpoint?.absoluteString ?? "")
        var options: [String: String] = [:]
        for field in Self.optionFields(for: instance, catalog: catalog) {
            options[field.key] = configuration.options[field.key] ?? field.defaultValue ?? ""
        }
        _optionValues = State(initialValue: options)
    }

    private var isNew: Bool {
        !center.instances.contains { $0.configuration.id == instance.configuration.id }
    }

    private var entry: SearchProviderCatalogEntry? {
        guard let presetID = instance.presetID else { return nil }
        return catalog?.entry(presetID: presetID)
    }

    private var credentialFields: [SearchProviderCatalogEntry.CredentialField] {
        if let entry { return entry.credentialFields }
        return Self.fallbackCredentialFields(for: configuration.kind)
    }

    private var optionFields: [SearchProviderCatalogEntry.OptionField] {
        entry?.optionFields ?? []
    }

    private var endpointRequired: Bool {
        if let entry { return entry.endpointRequired }
        return configuration.kind == .searxng || configuration.kind == .custom
    }

    private var pendingUpdate: (
        instance: WebSearchProviderInstance,
        plan: SearchProviderUpdatePlan,
        entry: SearchProviderCatalogEntry,
        catalog: SearchProviderCatalogIndex
    )? {
        guard !isNew, let catalog, let entry,
              let stored = center.instances.first(where: { $0.configuration.id == instance.configuration.id }),
              let plan = center.updatePlan(for: stored, catalog: catalog) else { return nil }
        return (stored, plan, entry, catalog)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let pendingUpdate {
                    updateReviewSection(pendingUpdate)
                }

                Section {
                    TextField("websearch.display_name", text: $displayName)
                    TextField(
                        endpointRequired ? "websearch.endpoint_required" : "websearch.endpoint",
                        text: $endpointText
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    if let authNote = entry?.localizedAuthNote(localePrimary: WebSearchSettingsCenter.localePrimary) {
                        Text(authNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !credentialFields.isEmpty {
                    Section {
                        ForEach(credentialFields) { field in
                            credentialField(for: field)
                        }
                    }
                }

                if !optionFields.isEmpty {
                    Section {
                        ForEach(optionFields) { field in
                            optionField(field)
                        }
                    }
                }

                SearchTestSection(
                    center: center,
                    configuration: currentDraft,
                    credential: currentDraftCredential
                )

                if let message = errorMessage ?? authenticationError {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(configuration.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { save() }
                        .disabled(saving)
                }
            }
            .task { loadCredential() }
        }
    }

    // MARK: Update review

    @ViewBuilder
    private func updateReviewSection(
        _ pending: (
            instance: WebSearchProviderInstance,
            plan: SearchProviderUpdatePlan,
            entry: SearchProviderCatalogEntry,
            catalog: SearchProviderCatalogIndex
        )
    ) -> some View {
        Section {
            ForEach(Array(pending.plan.changes.enumerated()), id: \.offset) { _, change in
                updateRow(change, entry: pending.entry)
            }
            Button("websearch.update.apply") {
                if pending.plan.requiresConfirmation {
                    updateConfirmationPresented = true
                } else {
                    applyUpdate(pending.plan, in: pending.catalog, confirmed: false)
                }
            }
            .frame(minHeight: FloeTheme.minimumTarget)
            .accessibilityIdentifier("websearch.update.apply")
            if appliedNotice {
                Text("websearch.update.applied")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("websearch.update_available")
        } footer: {
            if pending.plan.requiresConfirmation {
                Text("websearch.update.confirm_note")
            }
        }
        .confirmationDialog(
            FloeL10n.l("websearch.update.confirm_title"),
            isPresented: $updateConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("websearch.update.apply", role: .destructive) {
                applyUpdate(pending.plan, in: pending.catalog, confirmed: true)
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("websearch.update.confirm_note")
        }
    }

    @ViewBuilder
    private func updateRow(
        _ change: SearchProviderUpdatePlan.FieldChange,
        entry: SearchProviderCatalogEntry
    ) -> some View {
        let label: String = {
            switch change.field {
            case .displayName: return FloeL10n.l("websearch.display_name")
            case .endpoint: return FloeL10n.l("websearch.endpoint")
            case .option(let key):
                return entry.optionFields.first { $0.key == key }
                    .map { $0.label[WebSearchSettingsCenter.localePrimary] ?? $0.label["en"] ?? key }
                    ?? key
            case .credentialKeys: return FloeL10n.l("websearch.update.field.credentials")
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
            switch change.field {
            case .credentialKeys:
                Text("websearch.update.field.credentials_changed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                Text("\(change.from ?? "—") → \(change.to ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func applyUpdate(
        _ plan: SearchProviderUpdatePlan,
        in catalog: SearchProviderCatalogIndex,
        confirmed: Bool
    ) {
        do {
            let previousAccount = configuration.credentialAccount
            let updated = try center.applyCatalogUpdate(
                plan,
                to: configuration.id,
                catalog: catalog,
                confirmed: confirmed
            )
            configuration = updated.configuration
            displayName = updated.configuration.displayName
            endpointText = updated.configuration.endpoint?.absoluteString ?? ""
            if updated.configuration.credentialAccount != previousAccount {
                // Host/auth change rotated the account: the previous key is
                // never carried over, the user re-enters it for the new
                // destination.
                credentialValues = [:]
            }
            appliedNotice = true
            errorMessage = nil
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    // MARK: Fields

    private func credentialField(
        for field: SearchProviderCatalogEntry.CredentialField
    ) -> some View {
        let label = field.label[WebSearchSettingsCenter.localePrimary]
            ?? field.label["en"] ?? field.key
        return HStack {
            Group {
                if revealsSecrets {
                    TextField(label, text: Binding(
                        get: { credentialValues[field.key] ?? "" },
                        set: { credentialValues[field.key] = $0 }
                    ))
                } else {
                    SecureField(label, text: Binding(
                        get: { credentialValues[field.key] ?? "" },
                        set: { credentialValues[field.key] = $0 }
                    ))
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button {
                if revealsSecrets {
                    revealsSecrets = false
                } else {
                    Task { await revealCredentials() }
                }
            } label: {
                Image(systemName: revealsSecrets ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealsSecrets
                ? "settings.web_search_settings_center.hide_credentials"
                : "settings.web_search_settings_center.show_credentials")
        }
    }

    @ViewBuilder
    private func optionField(_ field: SearchProviderCatalogEntry.OptionField) -> some View {
        let label = field.label[WebSearchSettingsCenter.localePrimary]
            ?? field.label["en"] ?? field.key
        switch field.kind {
        case .bool:
            Toggle(label, isOn: Binding(
                get: { optionValues[field.key] != "false" },
                set: { optionValues[field.key] = $0 ? "true" : "false" }
            ))
        case .option:
            Picker(label, selection: Binding(
                get: { optionValues[field.key] ?? field.defaultValue ?? field.allowedValues?.first ?? "" },
                set: { optionValues[field.key] = $0 }
            )) {
                ForEach(field.allowedValues ?? [], id: \.self) { value in
                    Text(value).tag(value)
                }
            }
        case .text:
            TextField(label, text: Binding(
                get: { optionValues[field.key] ?? "" },
                set: { optionValues[field.key] = $0 }
            ))
        }
    }

    @MainActor
    private func revealCredentials() async {
        do {
            guard try await DeviceOwnerAuthenticator.authenticate(
                reason: FloeL10n.l("settings.web_search_settings_center.view_saved_web_search_credentials")
            ) else { return }
            authenticationError = nil
            revealsSecrets = true
        } catch {
            authenticationError = error.localizedDescription
        }
    }

    private func loadCredential() {
        guard let values = center.credential(forAccount: configuration.credentialAccount)?.values else { return }
        var state: [String: String] = [:]
        for field in credentialFields {
            state[field.key] = values[field.key] ?? ""
        }
        credentialValues = state
    }

    // MARK: Draft + save

    /// Frozen snapshot of the editor fields for Test Search. It never mutates
    /// storage and never enables the provider.
    private func currentDraft() -> WebSearchProviderConfiguration? {
        var draft = configuration
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.displayName = name.isEmpty ? configuration.displayName : name
        let endpoint = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.isEmpty {
            if endpointRequired { return nil }
            draft.endpoint = nil
        } else if let url = try? Self.validatedEndpoint(endpoint) {
            draft.endpoint = url
        } else {
            return nil
        }
        var options = draft.options
        for field in optionFields {
            let raw = optionValues[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (raw?.isEmpty ?? true) ? field.defaultValue : raw
            if let value {
                options[field.key] = value
            } else {
                options.removeValue(forKey: field.key)
            }
        }
        draft.options = options
        return draft
    }

    private func currentDraftCredential() -> WebSearchCredential? {
        var merged = center.credential(forAccount: configuration.credentialAccount)?.values ?? [:]
        for field in credentialFields {
            let value = credentialValues[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { merged[field.key] = value }
        }
        return merged.isEmpty ? nil : WebSearchCredential(values: merged)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        do {
            guard let draft = currentDraft() else {
                throw WebSearchSettingsError.invalidEndpoint
            }
            var credential = center.credential(forAccount: configuration.credentialAccount)?.values ?? [:]
            for field in credentialFields {
                let value = credentialValues[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !value.isEmpty { credential[field.key] = value }
            }
            var updated = instance
            updated.configuration = draft
            if isNew {
                // New instances are saved disabled and untested; enablement is
                // exclusively the user's independent row switch afterwards.
                updated.configuration.enabled = false
            }
            if let entry {
                updated.overrides = Self.mergedOverrides(
                    existing: isNew ? [] : instance.overrides,
                    configuration: draft,
                    entry: entry
                )
                updated.presetID = instance.presetID ?? entry.presetID
                if updated.appliedCatalogVersion == nil {
                    updated.appliedCatalogVersion = catalog?.version
                }
                updated.catalogCredentialKeys = entry.credentialKeys
            }
            try center.saveInstance(
                updated,
                credential: credential.isEmpty ? nil : WebSearchCredential(values: credential)
            )
            saving = false
            onFinished()
            dismiss()
        } catch {
            saving = false
            errorMessage = localizedMessage(for: error)
        }
    }

    /// User overrides = fields whose saved value differs from the catalog
    /// default (or that were already overridden). Reverting a value to the
    /// catalog default clears its override so future catalog updates manage
    /// it again. Credentials, the enabled switch, priority, identity and
    /// non-catalog options are never part of this set.
    nonisolated static func mergedOverrides(
        existing: Set<String>,
        configuration: WebSearchProviderConfiguration,
        entry: SearchProviderCatalogEntry
    ) -> Set<String> {
        var overrides = existing.filter { $0 == "displayName" || $0 == "endpoint" || $0.hasPrefix("option:") || $0 == "options" }
        let locale = WebSearchSettingsCenter.localePrimary
        let defaultNames = Set([entry.name[locale], entry.name["en"], entry.name["zh-Hans"]].compactMap { $0 })
        if defaultNames.contains(configuration.displayName) {
            overrides.remove("displayName")
        } else {
            overrides.insert("displayName")
        }
        let endpoint = configuration.endpoint?.absoluteString
        if (entry.managesEndpoint ?? false), let endpoint, endpoint != entry.defaultEndpoint {
            overrides.insert("endpoint")
        } else if !(entry.managesEndpoint ?? false) || endpoint == nil {
            overrides.remove("endpoint")
        }
        for field in entry.optionFields {
            if configuration.options[field.key] == field.defaultValue {
                overrides.remove("option:\(field.key)")
            } else if configuration.options[field.key] != nil {
                overrides.insert("option:\(field.key)")
            }
        }
        return overrides
    }

    static func validatedEndpoint(_ raw: String) throws -> URL {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw WebSearchSettingsError.invalidEndpoint
        }
        return url
    }

    private static func fallbackCredentialFields(
        for kind: WebSearchProviderKind
    ) -> [SearchProviderCatalogEntry.CredentialField] {
        switch kind {
        case .tencentWSA:
            return [
                .init(key: "secretId", required: true, label: ["en": "SecretId", "zh-Hans": "SecretId"]),
                .init(key: "secretKey", required: true, label: ["en": "SecretKey", "zh-Hans": "SecretKey"])
            ]
        case .googleProgrammable:
            return [
                .init(key: "apiKey", required: true, label: ["en": "API Key", "zh-Hans": "API 密钥"]),
                .init(key: "engineId", required: true, label: ["en": "Search Engine ID", "zh-Hans": "搜索引擎 ID"])
            ]
        case .custom:
            return [
                .init(key: "apiKey", required: true, label: ["en": "API Key", "zh-Hans": "API 密钥"])
            ]
        case .searxng:
            return []
        default:
            return [
                .init(key: "apiKey", required: true, label: ["en": "API Key", "zh-Hans": "API 密钥"])
            ]
        }
    }

    private static func optionFields(
        for instance: WebSearchProviderInstance,
        catalog: SearchProviderCatalogIndex?
    ) -> [SearchProviderCatalogEntry.OptionField] {
        guard let presetID = instance.presetID else { return [] }
        return catalog?.entry(presetID: presetID)?.optionFields ?? []
    }

    private func localizedMessage(for error: Error) -> String {
        guard let settingsError = error as? WebSearchSettingsError else {
            return error.localizedDescription
        }
        switch settingsError {
        case .invalidEndpoint:
            return FloeL10n.l("websearch.error.endpoint")
        case .missingRequiredCredential:
            return FloeL10n.l("websearch.error.credential")
        case .confirmationRequired:
            return FloeL10n.l("websearch.update.confirm_note")
        case .instanceNotFound:
            return FloeL10n.l("websearch.error.instance_missing")
        case .catalogUnavailable:
            return FloeL10n.l("websearch.catalog.unavailable")
        case .invalidDisplayName:
            return FloeL10n.l("websearch.error.display_name")
        }
    }
}

// MARK: - Test Search (shared by both editors)

/// Test Search panel. The parent freezes its current draft configuration and
/// the in-memory supplied credential; the request runs through the real
/// service for exactly that one provider. Results open the normalized URL;
/// failures are actionable. Nothing is saved by running a test.
struct SearchTestSection: View {
    let center: WebSearchSettingsCenter
    let configuration: () -> WebSearchProviderConfiguration?
    let credential: () -> WebSearchCredential?

    @State private var query = ""
    @State private var outcome: WebSearchTestOutcome?
    @State private var running = false

    var body: some View {
        Section {
            TextField("websearch.test.query_placeholder", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                run()
            } label: {
                HStack(spacing: 8) {
                    if running { ProgressView() }
                    Text("websearch.test.run")
                }
            }
            .frame(minHeight: FloeTheme.minimumTarget)
            .disabled(running || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("websearch.test.run")

            if let outcome {
                if let error = outcome.error {
                    Text(error == WebSearchTestOutcome.notConfiguredReason
                         ? FloeL10n.l("websearch.test.not_configured")
                         : error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if outcome.results.isEmpty {
                    Text("websearch.test.no_results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(outcome.results.prefix(5).enumerated()), id: \.offset) { _, result in
                        Link(destination: result.url) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                Text(result.url.host ?? result.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                        .accessibilityIdentifier("websearch.test.result")
                    }
                }
            }
        } header: {
            Text("websearch.test.title")
        }
    }

    private func run() {
        guard !running,
              let configuration = configuration(),
              let credential = credential() else {
            outcome = WebSearchTestOutcome(
                results: [],
                error: WebSearchTestOutcome.notConfiguredReason
            )
            return
        }
        let text = query
        running = true
        outcome = nil
        Task { @MainActor in
            let result = await center.testSearch(
                configuration: configuration,
                credential: credential,
                query: text
            )
            guard !Task.isCancelled else { return }
            outcome = result
            running = false
        }
    }
}
#endif
#endif
