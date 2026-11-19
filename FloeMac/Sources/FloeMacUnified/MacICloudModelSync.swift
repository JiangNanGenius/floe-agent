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
            && model.capabilities.contains(.text) && endpoint.scheme?.lowercased() == "https"
            && endpoint.host?.isEmpty == false && endpoint.user == nil && endpoint.password == nil
            && endpoint.query == nil && endpoint.fragment == nil
            && ProviderConfigurationValidation.issues(for: provider).isEmpty
            && ProviderConfigurationValidation.issues(for: model).isEmpty
    }
}

enum MacICloudModelError: Error {
    case setupRequired, signInRequired, temporarilyUnavailable, accountChanged, invalidProvider, uploadPending
}

@MainActor
final class MacICloudModelSync {
    static let containerIdentifier = "iCloud.org.floeagent.ios"
    private let applicationSupport: URL
    private let namespace: String
    private let zoneName: String

    init(applicationSupport: URL, namespace: String, zoneName: String = ConfigSyncEngine.zoneName) {
        self.applicationSupport = applicationSupport
        self.namespace = namespace
        self.zoneName = zoneName
    }

    static var hasCloudKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
              ) as? [String] else { return false }
        return containers.contains(containerIdentifier)
    }

    func synchronize(publishing entry: MacCloudModelEntry? = nil) async throws -> [MacCloudModelEntry] {
        guard Self.hasCloudKitEntitlement else { throw MacICloudModelError.setupRequired }
        let container = CKContainer(identifier: Self.containerIdentifier)
        switch try await container.accountStatus() {
        case .available: break
        case .noAccount: throw MacICloudModelError.signInRequired
        default: throw MacICloudModelError.temporarilyUnavailable
        }
        let accountID = try await container.userRecordID()
        let accountHash = FloeDigest.sha256Hex(Data("\(accountID.recordName)\n\(zoneName)".utf8))
        let database = try HostAgentDatabase.openConfigurationCache(
            applicationSupport: applicationSupport, namespace: namespace, accountHash: accountHash
        )
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(configurationStore: configuration, metadataStore: metadata,
                                      recordTypes: [.providerProfile, .modelProfile], automaticallySync: false,
                                      zoneName: zoneName, expectedAccountRecordName: accountID.recordName)
        do {
            try await engine.synchronize(container: container)
            try await verifyAccount(accountID, in: container)
            if let entry {
                try await publish(entry, configuration: configuration, engine: engine)
                try await engine.synchronize()
                try await verifyAccount(accountID, in: container)
                let provider = try await metadata.metadata(
                    recordType: ConfigSyncRecordType.providerProfile.rawValue,
                    recordID: entry.provider.id.uuidString
                )
                let model = try await metadata.metadata(
                    recordType: ConfigSyncRecordType.modelProfile.rawValue,
                    recordID: entry.model.id.uuidString
                )
                guard let provider, let model, provider.pendingAction == nil, model.pendingAction == nil else {
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
            try await verifyAccount(accountID, in: container)
            await engine.setSynchronizationEnabled(false)
            return entries
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
}
