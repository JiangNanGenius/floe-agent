#if canImport(CloudKit)
import CloudKit
#endif

import Foundation
import FloeCore
import FloePersistence
import FloeSecurity
import FloeSyncCore

public enum ConfigSyncRecordType: String, Sendable, CaseIterable {
    case providerProfile = "ProviderProfile"
    case modelProfile = "ModelProfile"
    case preference = "Preference"
    case remoteHostProfile = "RemoteHostProfile"
    /// Secret-free metadata for credentials the user explicitly promoted to
    /// the vault. Secret bytes remain exclusively in synchronizable Keychain.
    case credentialDescriptor = "CredentialDescriptor"
}

/// Private-database configuration sync. API-key bodies are never accepted by
/// this API and remain exclusively in `KeychainSecretStore`.
public actor ConfigSyncEngine {
    public static let zoneName = "FloeConfigZone"

    public private(set) var status: SyncStatus = .paused
    public private(set) var lastSyncAt: Date?
    public private(set) var synchronizationEnabled = true

    private let configurationStore: ModelConfigurationStore?
    private let metadataStore: ConfigSyncMetadataStore?
    private let remoteHostStore: RemoteHostStore?
    private var credentialStore: CredentialStore?

    public init(
        configurationStore: ModelConfigurationStore? = nil,
        metadataStore: ConfigSyncMetadataStore? = nil,
        remoteHostStore: RemoteHostStore? = nil,
        credentialStore: CredentialStore? = nil
    ) {
        self.configurationStore = configurationStore
        self.metadataStore = metadataStore
        self.remoteHostStore = remoteHostStore
        self.credentialStore = credentialStore
    }

    /// AppEnvironment creates the v11 credential store after the sync engine.
    /// Attaching it keeps construction acyclic while still making descriptors
    /// first-class CloudKit records.
    public func setCredentialStore(_ store: CredentialStore) {
        credentialStore = store
    }

    public func mergeRemoteChange(
        recordType: ConfigSyncRecordType,
        local: FieldTimestamps,
        remote: FieldTimestamps
    ) -> [String: FieldMergeDecision] {
        var decisions: [String: FieldMergeDecision] = [:]
        for field in Set(local.fields.keys).union(remote.fields.keys) {
            decisions[field] = ConfigMerge.decide(field: field, local: local, remote: remote)
        }
        return decisions
    }

    public func markPaused(reason: String) {
        _ = reason
        status = .paused
    }

    public func markWaitingForSecret() {
        status = .waitingForSecret
    }

    /// Pauses or resumes CloudKit traffic without discarding locally queued
    /// metadata. Changes made while paused are uploaded after re-enabling.
    public func setSynchronizationEnabled(_ enabled: Bool) {
        synchronizationEnabled = enabled
        if !enabled {
            status = .paused
            #if canImport(CloudKit)
            scheduledSync?.cancel()
            scheduledSync = nil
            #endif
        }
    }

    #if canImport(CloudKit)
    private var syncEngine: CKSyncEngine?
    private var delegate: EngineDelegate?
    private var zoneID: CKRecordZone.ID?
    private var scheduledSync: Task<Void, Never>?
    private var isSynchronizing = false

    public func configure(container: CKContainer) async throws {
        guard let metadataStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a metadata store")
        }

        let accountStatus = try await container.accountStatus()
        guard accountStatus == .available else {
            status = .paused
            return
        }

        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        let serialization: CKSyncEngine.State.Serialization?
        if let stateData = try await metadataStore.engineState() {
            serialization = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: stateData)
        } else {
            serialization = nil
        }

        let delegate = EngineDelegate(owner: self)
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: delegate
        )
        let engine = CKSyncEngine(configuration)
        self.delegate = delegate
        self.syncEngine = engine
        self.zoneID = zoneID
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        // Writes made while signed out/offline are durable in SQLite. Restore
        // them into CKSyncEngine whenever an account becomes available.
        for metadata in try await metadataStore.pending(limit: 10_000) {
            let recordID = CKRecord.ID(recordName: metadata.recordID, zoneID: zoneID)
            switch metadata.pendingAction {
            case .save:
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            case .delete:
                engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            case nil:
                break
            }
        }
        // Configuration is not a completed sync. Keep the UI honest until
        // CloudKit has accepted the zone and the first fetch/send cycle.
        status = synchronizationEnabled ? .syncing : .paused
    }

    public func saveProvider(_ provider: ProviderProfile, changedFields: Set<String>? = nil) async throws {
        guard let configurationStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a configuration store")
        }
        try await configurationStore.saveProvider(provider)
        guard provider.kind != .local else { return }
        try await enqueueSave(
            type: .providerProfile,
            id: provider.id.uuidString,
            value: provider,
            changedFields: changedFields
        )
    }

    public func saveModel(_ model: ModelProfile, changedFields: Set<String>? = nil) async throws {
        guard let configurationStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a configuration store")
        }
        try await configurationStore.saveModel(model)
        guard model.providerID != ProviderProfile.onDeviceProviderID else { return }
        try await enqueueSave(
            type: .modelProfile,
            id: model.id.uuidString,
            value: model,
            changedFields: changedFields
        )
    }

    public func savePreferences(
        _ preferences: ModelSelectionPreferences,
        changedFields: Set<String>? = nil
    ) async throws {
        guard let configurationStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a configuration store")
        }
        try await configurationStore.savePreferences(preferences)
        try await enqueueSave(
            type: .preference,
            id: "default",
            value: preferences,
            changedFields: changedFields
        )
    }

    public func deleteProvider(id: UUID) async throws {
        // CloudKit has no relational cascade. Capture child IDs before the
        // local SQLite foreign-key cascade and tombstone every model record,
        // otherwise a fresh device can later download orphaned models.
        let modelIDs: [UUID]
        if let configurationStore {
            modelIDs = try await configurationStore.models(providerID: id).map(\.id)
        } else {
            modelIDs = []
        }
        try await configurationStore?.deleteProvider(id: id)
        for modelID in modelIDs {
            try await enqueueDelete(type: .modelProfile, id: modelID.uuidString)
        }
        try await enqueueDelete(type: .providerProfile, id: id.uuidString)
    }

    public func deleteModel(id: UUID) async throws {
        try await configurationStore?.deleteModel(id: id)
        try await enqueueDelete(type: .modelProfile, id: id.uuidString)
    }

    public func saveRemoteHost(_ host: RemoteHostStore.StoredHost) async throws {
        guard let remoteHostStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a remote host store")
        }
        try await remoteHostStore.saveHost(host)
        try await enqueueSave(type: .remoteHostProfile, id: host.id.uuidString, value: host, changedFields: nil)
    }

    public func deleteRemoteHost(id: UUID) async throws {
        try await remoteHostStore?.deleteHost(id: id)
        try await enqueueDelete(type: .remoteHostProfile, id: id.uuidString)
    }

    public func saveCredentialDescriptor(_ record: CredentialRecord) async throws {
        guard record.owner == .vault, record.synchronizable else {
            throw FloeError.validationFailed(
                "Only explicitly saved, synchronizable vault credentials may publish descriptors"
            )
        }
        guard let credentialStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a credential store")
        }
        try await credentialStore.save(record)
        try await enqueueSave(
            type: .credentialDescriptor,
            id: record.id.uuidString,
            value: record,
            changedFields: nil
        )
    }

    public func deleteCredentialDescriptor(id: UUID) async throws {
        try await credentialStore?.delete(id: id)
        try await enqueueDelete(type: .credentialDescriptor, id: id.uuidString)
    }

    /// Stops publishing a descriptor without deleting the local vault item.
    /// Used when the device-local saved-credential sync switch is disabled.
    public func unpublishCredentialDescriptor(id: UUID) async throws {
        try await enqueueDelete(type: .credentialDescriptor, id: id.uuidString)
    }

    public func synchronize() async throws {
        guard synchronizationEnabled else {
            status = .paused
            return
        }
        guard let syncEngine else {
            throw FloeError.invalidConfiguration("CloudKit sync is not configured")
        }
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        scheduledSync = nil
        status = .syncing
        do {
            // A brand-new account has no custom zone yet. Sending database
            // changes first creates it; fetching first can fail with
            // CKError.zoneNotFound and previously prevented every later send.
            try await syncEngine.sendChanges()
            try await syncEngine.fetchChanges()
            // Upgrade installs may contain real local configuration created
            // before CloudKit was wired. Stage only records that were not
            // fetched from the cloud and preserve their original timestamps.
            try await stageUntrackedLocalConfiguration()
            // Remote merges may enqueue a conflict-resolving save.
            try await syncEngine.sendChanges()
            lastSyncAt = Date()
            status = await credentialSyncStatus()
        } catch {
            status = .error(String(describing: error))
            throw error
        }
    }

    private func enqueueSave<T: Encodable>(
        type: ConfigSyncRecordType,
        id: String,
        value: T,
        changedFields: Set<String>?
    ) async throws {
        guard let metadataStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a metadata store")
        }
        let payload = try Self.encode(value)
        let fields: Set<String>
        if let changedFields {
            fields = changedFields
        } else {
            fields = Set(try Self.jsonObject(payload).keys)
        }
        var metadata = try await metadataStore.metadata(recordType: type.rawValue, recordID: id)
            ?? ConfigSyncMetadata(recordType: type.rawValue, recordID: id)
        let now = Date()
        for field in fields { metadata.fieldTimestamps[field] = now }
        metadata.pendingAction = .save
        metadata.deletedAt = nil
        metadata.updatedAt = now
        try await metadataStore.save(metadata)

        guard synchronizationEnabled, let syncEngine, let zoneID else {
            status = .paused
            return
        }
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        status = .syncing
        scheduleSynchronization()
    }

    private func enqueueDelete(type: ConfigSyncRecordType, id: String) async throws {
        guard let metadataStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a metadata store")
        }
        var metadata = try await metadataStore.metadata(recordType: type.rawValue, recordID: id)
            ?? ConfigSyncMetadata(recordType: type.rawValue, recordID: id)
        let now = Date()
        metadata.pendingAction = .delete
        metadata.deletedAt = now
        metadata.updatedAt = now
        try await metadataStore.save(metadata)

        guard synchronizationEnabled, let syncEngine, let zoneID else {
            status = .paused
            return
        }
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        status = .syncing
        scheduleSynchronization()
    }

    /// Coalesces a provider bundle's provider/models/preferences writes into
    /// one real CloudKit round trip. The task is actor-owned so it survives
    /// the editor view disappearing after Save.
    private func scheduleSynchronization() {
        guard synchronizationEnabled else { return }
        scheduledSync?.cancel()
        // CKSyncEngine forbids sendChanges/fetchChanges from recursively
        // inheriting one of its delegate callback tasks. A normal Task keeps
        // task-local callback context and triggers CloudKit's
        // cannot-guarantee-serial-callbacks assertion. Detaching here preserves
        // actor isolation at synchronize() while breaking that recursion.
        scheduledSync = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            _ = try? await self?.synchronize()
        }
    }

    private func stageUntrackedLocalConfiguration() async throws {
        guard let configurationStore, let metadataStore, let syncEngine, let zoneID else { return }

        let providers = try await configurationStore.providers().filter { $0.kind != .local }
        let providerTimestamps = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.updatedAt) })
        for provider in providers {
            try await stageIfUntracked(
                type: .providerProfile,
                id: provider.id.uuidString,
                value: provider,
                timestamp: provider.updatedAt,
                metadataStore: metadataStore,
                syncEngine: syncEngine,
                zoneID: zoneID
            )
        }
        for model in try await configurationStore.models()
            where model.providerID != ProviderProfile.onDeviceProviderID {
            try await stageIfUntracked(
                type: .modelProfile,
                id: model.id.uuidString,
                value: model,
                // ModelProfile predates per-model timestamps. The owning
                // provider's update time is the closest durable legacy clock.
                timestamp: providerTimestamps[model.providerID] ?? Date(timeIntervalSince1970: 0),
                metadataStore: metadataStore,
                syncEngine: syncEngine,
                zoneID: zoneID
            )
        }
        if let remoteHostStore {
            for host in try await remoteHostStore.hosts() {
                try await stageIfUntracked(
                    type: .remoteHostProfile, id: host.id.uuidString,
                    value: host, timestamp: Date(timeIntervalSince1970: 0),
                    metadataStore: metadataStore, syncEngine: syncEngine, zoneID: zoneID
                )
            }
        }
        if SyncControlPreferences.load().savedCredentialsEnabled, let credentialStore {
            for credential in try await credentialStore.records(owner: .vault)
                where credential.synchronizable {
                try await stageIfUntracked(
                    type: .credentialDescriptor, id: credential.id.uuidString,
                    value: credential, timestamp: credential.updatedAt,
                    metadataStore: metadataStore, syncEngine: syncEngine, zoneID: zoneID
                )
            }
        }
        let preferences = try await configurationStore.preferences()
        if preferences.updatedAt > Date(timeIntervalSince1970: 1) {
            try await stageIfUntracked(
                type: .preference,
                id: "default",
                value: preferences,
                timestamp: preferences.updatedAt,
                metadataStore: metadataStore,
                syncEngine: syncEngine,
                zoneID: zoneID
            )
        }
    }

    private func stageIfUntracked<T: Encodable>(
        type: ConfigSyncRecordType,
        id: String,
        value: T,
        timestamp: Date,
        metadataStore: ConfigSyncMetadataStore,
        syncEngine: CKSyncEngine,
        zoneID: CKRecordZone.ID
    ) async throws {
        guard try await metadataStore.metadata(recordType: type.rawValue, recordID: id) == nil else {
            return
        }
        let payload = try Self.encode(value)
        let fields = Dictionary(
            uniqueKeysWithValues: try Self.jsonObject(payload).keys.map { ($0, timestamp) }
        )
        try await metadataStore.save(ConfigSyncMetadata(
            recordType: type.rawValue,
            recordID: id,
            fieldTimestamps: fields,
            pendingAction: .save,
            updatedAt: timestamp
        ))
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    fileprivate func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                guard let metadataStore else { return }
                let data = try JSONEncoder().encode(update.stateSerialization)
                try await metadataStore.saveEngineState(data)

            case .accountChange:
                status = .paused

            case .fetchedRecordZoneChanges(let changes):
                // CloudKit does not promise dependency order. Providers must
                // exist before their models, and models before preferences
                // whose foreign keys select them.
                let modifications = changes.modifications.sorted {
                    Self.applyPriority(for: $0.record.recordType)
                        < Self.applyPriority(for: $1.record.recordType)
                }
                for modification in modifications {
                    try await applyRemote(modification.record)
                }
                for deletion in changes.deletions {
                    try await applyRemoteDeletion(recordID: deletion.recordID, recordType: deletion.recordType)
                }
                lastSyncAt = Date()
                status = await credentialSyncStatus()

            case .sentRecordZoneChanges(let sent):
                for record in sent.savedRecords { try await acknowledge(record) }
                for recordID in sent.deletedRecordIDs { try await acknowledgeDeletion(recordID) }
                var recoveredConflict = false
                for failedSave in sent.failedRecordSaves {
                    if let serverRecord = Self.serverRecordChangedRecord(from: failedSave.error) {
                        // A fresh device may have local `default` preferences
                        // but no archived CloudKit system fields. CloudKit then
                        // rejects the attempted insert because another device
                        // already created that record. Merge the authoritative
                        // server record, retain newer per-field local values,
                        // and retry as an update instead of staying wedged.
                        try await applyRemote(serverRecord)
                        syncEngine.state.add(pendingRecordZoneChanges: [
                            .saveRecord(serverRecord.recordID)
                        ])
                        recoveredConflict = true
                    }
                }
                if recoveredConflict {
                    status = .syncing
                    scheduleSynchronization()
                } else if let firstFailure = sent.failedRecordSaves.first?.error {
                    status = .error(firstFailure.localizedDescription)
                } else if let firstFailure = sent.failedRecordDeletes.values.first {
                    status = .error(firstFailure.localizedDescription)
                } else {
                    lastSyncAt = Date()
                    status = await credentialSyncStatus()
                }

            case .didFetchRecordZoneChanges(let result):
                if let error = result.error { status = .error(error.localizedDescription) }

            default:
                break
            }
        } catch {
            status = .error(String(describing: error))
        }
    }

    fileprivate func nextBatch(
        context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains)
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            await self?.recordToSave(recordID)
        }
    }

    private func recordToSave(_ recordID: CKRecord.ID) async -> CKRecord? {
        guard let metadataStore,
              let metadata = try? await metadataStore.metadata(
                recordType: await recordType(for: recordID.recordName)?.rawValue ?? "",
                recordID: recordID.recordName
              ),
              metadata.pendingAction == .save,
              let type = await recordType(for: recordID.recordName),
              let payload = try? await payload(type: type, id: recordID.recordName)
        else { return nil }

        let record = Self.restoreRecord(from: metadata.cloudSystemFields)
            ?? CKRecord(recordType: type.rawValue, recordID: recordID)
        record.encryptedValues["payload"] = payload as CKRecordValue
        if let timestamps = try? Self.encode(metadata.fieldTimestamps) {
            record.encryptedValues["fieldTimestamps"] = timestamps as CKRecordValue
        }
        record["updatedAt"] = metadata.updatedAt as CKRecordValue
        return record
    }

    private func recordType(for id: String) async -> ConfigSyncRecordType? {
        if id == "default" { return .preference }
        if let configurationStore, let uuid = UUID(uuidString: id) {
            if (try? await configurationStore.provider(id: uuid)) != nil { return .providerProfile }
            if (try? await configurationStore.model(id: uuid)) != nil { return .modelProfile }
            if let remoteHostStore, (try? await remoteHostStore.host(id: uuid)) != nil { return .remoteHostProfile }
            if let credentialStore, (try? await credentialStore.record(id: uuid)) != nil {
                return .credentialDescriptor
            }
        }
        // A locally deleted object can no longer reveal its type through the
        // configuration store. Its tombstone metadata remains authoritative.
        if let metadataStore {
            for type in ConfigSyncRecordType.allCases {
                if (try? await metadataStore.metadata(recordType: type.rawValue, recordID: id)) != nil {
                    return type
                }
            }
        }
        return nil
    }

    private func payload(type: ConfigSyncRecordType, id: String) async throws -> Data {
        guard let configurationStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a configuration store")
        }
        switch type {
        case .preference:
            guard id == "default" else {
                throw FloeError.storageCorrupted("Invalid preference record identifier")
            }
            return try Self.encode(Self.withoutDeviceLocalModels(
                try await configurationStore.preferences()
            ))
        case .providerProfile:
            guard let uuid = UUID(uuidString: id) else {
                throw FloeError.storageCorrupted("Invalid provider record identifier")
            }
            guard let provider = try await configurationStore.provider(id: uuid) else {
                throw FloeError.storageCorrupted("Missing provider for pending CloudKit save")
            }
            return try Self.encode(provider)
        case .modelProfile:
            guard let uuid = UUID(uuidString: id) else {
                throw FloeError.storageCorrupted("Invalid model record identifier")
            }
            guard let model = try await configurationStore.model(id: uuid) else {
                throw FloeError.storageCorrupted("Missing model for pending CloudKit save")
            }
            return try Self.encode(model)
        case .remoteHostProfile:
            guard let uuid = UUID(uuidString: id), let remoteHostStore,
                  let host = try await remoteHostStore.host(id: uuid) else {
                throw FloeError.storageCorrupted("Missing host for pending CloudKit save")
            }
            return try Self.encode(host)
        case .credentialDescriptor:
            guard let uuid = UUID(uuidString: id), let credentialStore,
                  let credential = try await credentialStore.record(id: uuid),
                  credential.owner == .vault, credential.synchronizable else {
                throw FloeError.storageCorrupted("Missing synchronizable vault credential descriptor")
            }
            return try Self.encode(credential)
        }
    }

    private func applyRemote(_ record: CKRecord) async throws {
        guard let type = ConfigSyncRecordType(rawValue: record.recordType),
              let payload = record.encryptedValues["payload"] as? Data,
              let timestampsData = record.encryptedValues["fieldTimestamps"] as? Data,
              let metadataStore,
              let configurationStore
        else { return }

        let remoteTimestamps = try JSONDecoder.floe.decode([String: Date].self, from: timestampsData)
        let existing = try await metadataStore.metadata(recordType: type.rawValue, recordID: record.recordID.recordName)
        let localTimestamps = existing?.fieldTimestamps ?? [:]
        let localPayload = try? await self.payload(type: type, id: record.recordID.recordName)
        let mergedPayload = try Self.mergeJSON(
            local: localPayload,
            remote: payload,
            localTimestamps: localTimestamps,
            remoteTimestamps: remoteTimestamps
        )

        switch type {
        case .providerProfile:
            let provider = try JSONDecoder.floe.decode(ProviderProfile.self, from: mergedPayload)
            guard provider.kind != .local else { return }
            try await configurationStore.saveProvider(provider)
        case .modelProfile:
            let model = try JSONDecoder.floe.decode(ModelProfile.self, from: mergedPayload)
            guard model.providerID != ProviderProfile.onDeviceProviderID else { return }
            try await configurationStore.saveModel(model)
        case .preference:
            let remote = Self.withoutDeviceLocalModels(
                try JSONDecoder.floe.decode(ModelSelectionPreferences.self, from: mergedPayload)
            )
            let local = try await configurationStore.preferences()
            try await configurationStore.savePreferences(
                Self.restoringDeviceLocalModels(remote, from: local)
            )
        case .remoteHostProfile:
            guard let remoteHostStore else { return }
            try await remoteHostStore.saveHost(
                try JSONDecoder.floe.decode(RemoteHostStore.StoredHost.self, from: mergedPayload)
            )
        case .credentialDescriptor:
            guard let credentialStore else { return }
            let descriptor = try JSONDecoder.floe.decode(CredentialRecord.self, from: mergedPayload)
            guard descriptor.owner == .vault, descriptor.synchronizable else {
                throw FloeError.storageCorrupted("Cloud credential descriptor exceeded vault scope")
            }
            try await credentialStore.save(descriptor)
        }

        var mergedTimestamps = localTimestamps
        for (field, date) in remoteTimestamps where date > (mergedTimestamps[field] ?? .distantPast) {
            mergedTimestamps[field] = date
        }
        let retainsLocalChanges = existing?.pendingAction == .save && localTimestamps.contains { field, date in
            date >= (remoteTimestamps[field] ?? .distantPast)
        }
        let metadata = ConfigSyncMetadata(
            recordType: type.rawValue,
            recordID: record.recordID.recordName,
            fieldTimestamps: mergedTimestamps,
            cloudChangeTag: record.recordChangeTag,
            cloudSystemFields: Self.archiveSystemFields(record),
            pendingAction: retainsLocalChanges ? .save : nil,
            updatedAt: record.modificationDate ?? Date()
        )
        try await metadataStore.save(metadata)
        if retainsLocalChanges {
            syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
    }

    private static func withoutDeviceLocalModels(
        _ value: ModelSelectionPreferences
    ) -> ModelSelectionPreferences {
        var value = value
        if value.defaultAgentModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.defaultAgentModelID = nil
        }
        if value.visionModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.visionModelID = nil
        }
        if value.approvalModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.approvalModelID = nil
        }
        if value.packageReviewModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.packageReviewModelID = nil
        }
        if value.sharedImageModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.sharedImageModelID = nil
        }
        if value.imageGenerationModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.imageGenerationModelID = nil
        }
        if value.imageEditingModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.imageEditingModelID = nil
        }
        return value
    }

    /// Local weights and their picker selections belong to this device. A
    /// CloudKit update must not clear them merely because the sanitized cloud
    /// payload intentionally contains nil for those fixed model identifiers.
    private static func restoringDeviceLocalModels(
        _ remote: ModelSelectionPreferences,
        from local: ModelSelectionPreferences
    ) -> ModelSelectionPreferences {
        var value = remote
        func deviceValue(_ id: UUID?) -> UUID? {
            id.flatMap { ProviderProfile.onDeviceModelIDs.contains($0) ? $0 : nil }
        }
        value.defaultAgentModelID = deviceValue(local.defaultAgentModelID) ?? value.defaultAgentModelID
        value.visionModelID = deviceValue(local.visionModelID) ?? value.visionModelID
        value.approvalModelID = deviceValue(local.approvalModelID) ?? value.approvalModelID
        value.packageReviewModelID = deviceValue(local.packageReviewModelID) ?? value.packageReviewModelID
        value.sharedImageModelID = deviceValue(local.sharedImageModelID) ?? value.sharedImageModelID
        value.imageGenerationModelID = deviceValue(local.imageGenerationModelID) ?? value.imageGenerationModelID
        value.imageEditingModelID = deviceValue(local.imageEditingModelID) ?? value.imageEditingModelID
        return value
    }

    private func applyRemoteDeletion(recordID: CKRecord.ID, recordType: String) async throws {
        guard let type = ConfigSyncRecordType(rawValue: recordType),
              let configurationStore,
              let metadataStore
        else { return }
        switch type {
        case .providerProfile:
            if let uuid = UUID(uuidString: recordID.recordName) {
                try await configurationStore.deleteProvider(id: uuid)
            }
        case .modelProfile:
            if let uuid = UUID(uuidString: recordID.recordName) {
                try await configurationStore.deleteModel(id: uuid)
            }
        case .preference:
            let local = try await configurationStore.preferences()
            try await configurationStore.savePreferences(
                Self.restoringDeviceLocalModels(ModelSelectionPreferences(), from: local)
            )
        case .remoteHostProfile:
            if let uuid = UUID(uuidString: recordID.recordName) {
                try await remoteHostStore?.deleteHost(id: uuid)
            }
        case .credentialDescriptor:
            if let uuid = UUID(uuidString: recordID.recordName) {
                try await credentialStore?.delete(id: uuid)
            }
        }
        let now = Date()
        try await metadataStore.save(ConfigSyncMetadata(
            recordType: type.rawValue,
            recordID: recordID.recordName,
            pendingAction: nil,
            deletedAt: now,
            updatedAt: now
        ))
    }

    private func acknowledge(_ record: CKRecord) async throws {
        guard let metadataStore,
              var metadata = try await metadataStore.metadata(
                recordType: record.recordType,
                recordID: record.recordID.recordName
              )
        else { return }
        metadata.cloudChangeTag = record.recordChangeTag
        metadata.cloudSystemFields = Self.archiveSystemFields(record)
        metadata.pendingAction = nil
        metadata.updatedAt = record.modificationDate ?? Date()
        try await metadataStore.save(metadata)
    }

    private func acknowledgeDeletion(_ recordID: CKRecord.ID) async throws {
        guard let metadataStore else { return }
        for type in ConfigSyncRecordType.allCases {
            if var metadata = try await metadataStore.metadata(recordType: type.rawValue, recordID: recordID.recordName),
               metadata.pendingAction == .delete {
                metadata.pendingAction = nil
                metadata.cloudChangeTag = nil
                metadata.cloudSystemFields = nil
                try await metadataStore.save(metadata)
                return
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder.floe.encode(value)
    }

    private static func applyPriority(for recordType: String) -> Int {
        switch ConfigSyncRecordType(rawValue: recordType) {
        case .providerProfile: 0
        case .modelProfile: 1
        case .preference: 2
        case .remoteHostProfile: 3
        case .credentialDescriptor: 4
        case nil: 5
        }
    }

    /// CloudKit records and iCloud Keychain arrive independently. Keep the
    /// global sync status honest until every synchronized descriptor has a
    /// corresponding secret on this device.
    private func credentialSyncStatus() async -> SyncStatus {
        guard SyncControlPreferences.load().savedCredentialsEnabled,
              let credentialStore,
              let records = try? await credentialStore.records(owner: .vault)
        else { return .synced }
        let keychain = KeychainStore(
            service: CredentialVaultService.serviceName,
            synchronizable: true
        )
        for record in records where record.synchronizable {
            if record.deviceBound { return .waitingForSecret }
            do { _ = try keychain.read(account: record.keychainAccount) }
            catch { return .waitingForSecret }
        }
        return .synced
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FloeError.storageCorrupted("Configuration payload is not a JSON object")
        }
        return object
    }

    private static func mergeJSON(
        local: Data?,
        remote: Data,
        localTimestamps: [String: Date],
        remoteTimestamps: [String: Date]
    ) throws -> Data {
        guard let local else { return remote }
        var result = try jsonObject(local)
        let remoteObject = try jsonObject(remote)
        for key in Set(result.keys).union(remoteObject.keys) {
            let localDate = localTimestamps[key]
            let remoteDate = remoteTimestamps[key]
            if localDate == nil || (remoteDate ?? .distantPast) > (localDate ?? .distantPast) {
                result[key] = remoteObject[key]
            }
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    private static func archiveSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func restoreRecord(from data: Data?) -> CKRecord? {
        guard let data else { return nil }
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            return CKRecord(coder: unarchiver)
        } catch {
            return nil
        }
    }

    private static func serverRecordChangedRecord(from error: Error) -> CKRecord? {
        let nsError = error as NSError
        if let record = nsError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
            return record
        }
        if let partials = nsError.userInfo[CKPartialErrorsByItemIDKey]
            as? [AnyHashable: Error] {
            for nested in partials.values {
                if let record = serverRecordChangedRecord(from: nested) { return record }
            }
        }
        return nil
    }
    #endif
}

#if canImport(CloudKit)
private final class EngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    weak var owner: ConfigSyncEngine?

    init(owner: ConfigSyncEngine) {
        self.owner = owner
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await owner?.handleEvent(event, syncEngine: syncEngine)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await owner?.nextBatch(context: context, syncEngine: syncEngine)
    }
}

private extension JSONEncoder {
    static var floe: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var floe: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
