// SPDX-License-Identifier: MPL-2.0

import CloudKit
import FloeCore
import FloePersistence
import FloeSecurity
import FloeSync
import FloeSyncCore
import Foundation
import Security

struct MacCloudModelEntry: Identifiable, Sendable {
    let provider: ProviderProfile
    let model: ModelProfile

    var id: UUID { model.id }
    var providerName: String { provider.displayName ?? provider.baseURL.host ?? provider.kind.rawValue }

    static func accepts(_ provider: ProviderProfile, model: ModelProfile) -> Bool {
        let endpoint = provider.baseURL
        return provider.id != ProviderProfile.onDeviceProviderID && provider.kind != .local
            && provider.kind != .googleGemini && provider.isEnabled && model.providerID == provider.id
            && (model.capabilities.contains(.text) || model.supportsImageGenerationSurface || model.supportsVideoGenerationSurface)
            && endpoint.scheme?.lowercased() == "https"
            && endpoint.host?.isEmpty == false && endpoint.user == nil && endpoint.password == nil
            && endpoint.query == nil && endpoint.fragment == nil
            && ProviderConfigurationValidation.issues(for: provider).isEmpty
            && ProviderConfigurationValidation.issues(for: model).isEmpty
    }
}

enum MacICloudModelError: Error {
    case setupRequired, signInRequired, temporarilyUnavailable, accountChanged, invalidProvider, uploadPending
    case credentialAccessUnavailable
}

struct MacCloudConfiguration {
    var entries: [MacCloudModelEntry] = []
    var preferences: ModelSelectionPreferences?
    var settings: [ApplicationSettingRecord] = []
}

struct MacCloudConfigurationExchange {
    var configuration: MacCloudConfiguration
    var providerKeys: [UUID: String] = [:]
    var savedCredentialCount: Int = 0
    var waitingForCredentialCount: Int = 0
}

@MainActor
final class MacICloudModelSync {
    static let containerIdentifier = "iCloud.org.floeagent.ios"
    static let credentialAccessGroup = "QYL72C43K6.org.floeagent.ios"
    private let applicationSupport: URL
    private let namespace: String
    private let zoneName: String

    init(applicationSupport: URL, namespace: String, zoneName: String = ConfigSyncEngine.zoneName) {
        self.applicationSupport = applicationSupport
        self.namespace = namespace
        self.zoneName = zoneName
    }

    static var hasCloudKitEntitlement: Bool {
        hasEntitlement("com.apple.developer.icloud-container-identifiers", containing: containerIdentifier)
    }

    static var hasCredentialEntitlement: Bool {
        hasEntitlement("keychain-access-groups", containing: credentialAccessGroup)
    }

    private static func hasEntitlement(_ key: String, containing value: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let values = SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? [String] else { return false }
        return values.contains(value)
    }

    func synchronize(publishing entry: MacCloudModelEntry? = nil) async throws -> [MacCloudModelEntry] {
        let requested = entry.map { MacCloudConfiguration(entries: [$0]) }
        return try await exchange(publishing: requested, fullConfiguration: false).configuration.entries
    }

    func synchronizeConfiguration(publishing configuration: MacCloudConfiguration? = nil,
                                  credentialAccount: String?, localProviderKeys: [UUID: String] = [:]) async throws -> MacCloudConfigurationExchange {
        try await exchange(publishing: configuration, fullConfiguration: true,
                           credentialAccount: credentialAccount, localProviderKeys: localProviderKeys)
    }

    static func authorizeCredentialAccount() async throws -> String {
        guard hasCloudKitEntitlement, hasCredentialEntitlement else { throw MacICloudModelError.credentialAccessUnavailable }
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else { throw MacICloudModelError.signInRequired }
        return fingerprint(try await container.userRecordID())
    }

    private static func fingerprint(_ id: CKRecord.ID) -> String {
        FloeDigest.sha256Hex(Data(id.recordName.utf8))
    }

    private func exchange(publishing requested: MacCloudConfiguration?, fullConfiguration: Bool,
                          credentialAccount: String? = nil, localProviderKeys: [UUID: String] = [:]) async throws -> MacCloudConfigurationExchange {
        let includeCredentials = credentialAccount != nil
        guard Self.hasCloudKitEntitlement else { throw MacICloudModelError.setupRequired }
        guard !includeCredentials || Self.hasCredentialEntitlement else { throw MacICloudModelError.credentialAccessUnavailable }
        let container = CKContainer(identifier: Self.containerIdentifier)
        switch try await container.accountStatus() {
        case .available: break
        case .noAccount: throw MacICloudModelError.signInRequired
        default: throw MacICloudModelError.temporarilyUnavailable
        }
        let accountID = try await container.userRecordID()
        guard credentialAccount == nil || credentialAccount == Self.fingerprint(accountID) else { throw MacICloudModelError.accountChanged }
        // Sync cursors are scoped to the set of record types they fetch.
        let scope = fullConfiguration ? (includeCredentials ? "\nconfiguration-and-credentials" : "\nconfiguration") : ""
        let accountHash = FloeDigest.sha256Hex(Data("\(accountID.recordName)\n\(zoneName)\(scope)".utf8))
        let database = try HostAgentDatabase.openConfigurationCache(
            applicationSupport: applicationSupport, namespace: namespace, accountHash: accountHash
        )
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let credentials = includeCredentials ? CredentialStore(database: database) : nil
        var recordTypes: Set<ConfigSyncRecordType> = [.providerProfile, .modelProfile]
        if fullConfiguration { recordTypes.formUnion([.preference, .applicationSetting]) }
        if includeCredentials { recordTypes.insert(.credentialDescriptor) }
        let engine = ConfigSyncEngine(configurationStore: configuration, metadataStore: metadata, credentialStore: credentials,
                                      recordTypes: recordTypes, automaticallySync: false,
                                      zoneName: zoneName, expectedAccountRecordName: accountID.recordName,
                                      synchronizedKeychainAccessGroup: includeCredentials ? Self.credentialAccessGroup : nil,
                                      checksSynchronizedSecrets: includeCredentials)
        do {
            try await engine.synchronize(container: container)
            try await verifyAccount(accountID, in: container)
            let synchronizedKeychain = includeCredentials ? KeychainStore(service: KeychainSecretStore.defaultService,
                synchronizable: true, accessGroup: Self.credentialAccessGroup) : nil
            if let requested {
                var published = Set<UUID>()
                for entry in requested.entries {
                    try await verifyAccount(accountID, in: container)
                    try await publish(entry, configuration: configuration, engine: engine)
                    if published.insert(entry.provider.id).inserted, let synchronizedKeychain,
                       let key = localProviderKeys[entry.provider.id], !key.isEmpty {
                        try await publishProviderKey(key, providerID: entry.provider.id, keychain: synchronizedKeychain,
                                                     configuration: configuration, engine: engine)
                    }
                }
                if let preferences = requested.preferences {
                    try await publishPreferences(preferences, configuration: configuration, engine: engine)
                }
                for setting in requested.settings { try await engine.saveApplicationSetting(setting) }
                try await engine.synchronize()
                try await verifyAccount(accountID, in: container)
                let pending = try await metadata.pending(limit: 10_000)
                guard pending.allSatisfy({ row in !recordTypes.contains { $0.rawValue == row.recordType } }) else {
                    throw MacICloudModelError.uploadPending
                }
            }
            let snapshot = await engine.configurationSnapshot()
            guard snapshot.lastSyncAt != nil, snapshot.status == .synced || snapshot.status == .waitingForSecret else {
                throw MacICloudModelError.temporarilyUnavailable
            }
            let providers = Dictionary(uniqueKeysWithValues: try await configuration.providers().map { ($0.id, $0) })
            let entries = try await configuration.models().compactMap { model -> MacCloudModelEntry? in
                guard let provider = providers[model.providerID],
                      MacCloudModelEntry.accepts(provider, model: model) else { return nil }
                return .init(provider: provider, model: model)
            }
            let selected: ModelSelectionPreferences? = fullConfiguration ? try await configuration.preferences() : nil
            let settings = fullConfiguration ? try await configuration.applicationSettings() : []
            var receipt = MacCloudConfigurationExchange(configuration: .init(entries: entries, preferences: selected, settings: settings))
            if let synchronizedKeychain, let credentials {
                let vault = CredentialVaultService(records: credentials, synchronizedAccessGroup: Self.credentialAccessGroup)
                let descriptors = try await credentials.records(owner: .vault).filter { $0.synchronizable && !$0.deviceBound }
                receipt.savedCredentialCount = descriptors.count
                for descriptor in descriptors {
                    if await vault.availability(CredentialHandle(id: descriptor.id)) != .available {
                        receipt.waitingForCredentialCount += 1
                    }
                }
                for id in Set(entries.map { $0.provider.id }) {
                    guard let ref = providers[id]?.secretRef, ref.synchronizable,
                          ref.keychainAccount == Self.providerKeyAccount(id) else { continue }
                    do {
                        let value = try synchronizedKeychain.read(account: ref.keychainAccount)
                        if let key = String(data: value, encoding: .utf8), !key.isEmpty { receipt.providerKeys[id] = key }
                        else { receipt.waitingForCredentialCount += 1 }
                    } catch KeychainStoreError.itemNotFound {
                        receipt.waitingForCredentialCount += 1
                    } catch KeychainStoreError.interactionNotAllowed {
                        receipt.waitingForCredentialCount += 1
                    }
                }
            }
            try await verifyAccount(accountID, in: container)
            await engine.setSynchronizationEnabled(false)
            return receipt
        } catch {
            await engine.setSynchronizationEnabled(false)
            throw error
        }
    }

    private func verifyAccount(_ account: CKRecord.ID, in container: CKContainer) async throws {
        try Task.checkCancellation()
        guard try await container.userRecordID() == account else { throw MacICloudModelError.accountChanged }
    }

    private func publish(_ entry: MacCloudModelEntry, configuration: ModelConfigurationStore,
                         engine: ConfigSyncEngine) async throws {
        guard MacCloudModelEntry.accepts(entry.provider, model: entry.model) else {
            throw MacICloudModelError.invalidProvider
        }
        if let remoteModel = try await configuration.model(id: entry.model.id),
           remoteModel.remoteModelID != entry.model.remoteModelID || remoteModel.providerID != entry.model.providerID {
            throw MacICloudModelError.invalidProvider
        }
        var provider = entry.provider
        provider.secretRef = nil
        provider.nonSecretHeaders = [:]
        if let remote = try await configuration.provider(id: provider.id) {
            let identity = ProviderConfigurationValidation.ProviderConnectionIdentity.self
            guard identity.key(kind: remote.kind, baseURL: remote.baseURL)
                    == identity.key(kind: provider.kind, baseURL: provider.baseURL),
                  remote.wireProtocol == provider.wireProtocol,
                  remote.baseURL == provider.baseURL else { throw MacICloudModelError.invalidProvider }
            // Keep shared authentication metadata and routing fields owned by
            // the remote record. A local publish only changes its display name.
            provider = remote
            provider.displayName = entry.provider.displayName
            try await engine.saveProvider(provider, changedFields: ["displayName"])
        } else {
            try await engine.saveProvider(provider)
        }
        try await engine.saveModel(entry.model)
    }

    static func providerKeyAccount(_ id: UUID) -> String { "provider.\(id.uuidString)" }

    private func publishProviderKey(_ key: String, providerID: UUID, keychain: KeychainStore,
                                    configuration: ModelConfigurationStore, engine: ConfigSyncEngine) async throws {
        guard var provider = try await configuration.provider(id: providerID) else {
            throw MacICloudModelError.invalidProvider
        }
        let account = Self.providerKeyAccount(providerID)
        let value = Data(key.utf8)
        try keychain.store(account: account, secret: value)
        guard try keychain.read(account: account) == value else { throw MacICloudModelError.credentialAccessUnavailable }
        provider.secretRef = SecretReference(keychainAccount: account, synchronizable: true)
        try await engine.saveProvider(provider, changedFields: ["secretRef"])
    }

    private func publishPreferences(_ input: ModelSelectionPreferences, configuration: ModelConfigurationStore,
                                    engine: ConfigSyncEngine) async throws {
        let ids = Set(try await configuration.models().map(\.id))
        var preferences = try await configuration.preferences()
        var changes = Set<String>()
        func replace(_ path: WritableKeyPath<ModelSelectionPreferences, UUID?>, _ field: String) {
            guard let id = input[keyPath: path], ids.contains(id), preferences[keyPath: path] != id else { return }
            preferences[keyPath: path] = id
            changes.insert(field)
        }
        replace(\.defaultAgentModelID, "defaultAgentModelID")
        replace(\.generalAuxiliaryLLMModelID, "generalAuxiliaryLLMModelID")
        replace(\.visionModelID, "visionModelID")
        replace(\.approvalModelID, "approvalModelID")
        replace(\.defaultVideoModelID, "defaultVideoModelID")
        guard !changes.isEmpty else { return }
        preferences.updatedAt = Date()
        preferences.syncRevision += 1
        try await engine.savePreferences(preferences, changedFields: changes)
    }
}
