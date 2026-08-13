#if canImport(CloudKit)
import CloudKit
#endif

import Foundation
import FloeCore
import FloePersistence
import FloeSyncCore

public enum ConfigSyncRecordType: String, Sendable, CaseIterable {
    case providerProfile = "ProviderProfile"
    case modelProfile = "ModelProfile"
    case approvalModelSelection = "ApprovalModelSelection"
    case preference = "Preference"
}

/// Private-database configuration sync. API-key bodies are never accepted by
/// this API and remain exclusively in `KeychainSecretStore`.
public actor ConfigSyncEngine {
    public static let zoneName = "FloeConfigZone"

    public private(set) var status: SyncStatus = .paused
    public private(set) var lastSyncAt: Date?

    private let configurationStore: ModelConfigurationStore?
    private let metadataStore: ConfigSyncMetadataStore?

    public init(
        configurationStore: ModelConfigurationStore? = nil,
        metadataStore: ConfigSyncMetadataStore? = nil
    ) {
        self.configurationStore = configurationStore
        self.metadataStore = metadataStore
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

    #if canImport(CloudKit)
    private var syncEngine: CKSyncEngine?
    private var delegate: EngineDelegate?
    private var zoneID: CKRecordZone.ID?

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
        status = .synced
    }

    public func saveProvider(_ provider: ProviderProfile, changedFields: Set<String>? = nil) async throws {
        guard let configurationStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a configuration store")
        }
        try await configurationStore.saveProvider(provider)
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
        try await enqueueSave(
            type: .modelProfile,
            id: model.id.uuidString,
            value: model,
            changedFields: changedFields
        )
    }

    public func deleteProvider(id: UUID) async throws {
        try await configurationStore?.deleteProvider(id: id)
        try await enqueueDelete(type: .providerProfile, id: id.uuidString)
    }

    public func deleteModel(id: UUID) async throws {
        try await configurationStore?.deleteModel(id: id)
        try await enqueueDelete(type: .modelProfile, id: id.uuidString)
    }

    public func synchronize() async throws {
        guard let syncEngine else {
            throw FloeError.invalidConfiguration("CloudKit sync is not configured")
        }
        do {
            try await syncEngine.fetchChanges()
            try await syncEngine.sendChanges()
            lastSyncAt = Date()
            status = .synced
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
        guard let metadataStore, let syncEngine, let zoneID else {
            throw FloeError.invalidConfiguration("CloudKit sync is not configured")
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

        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        status = .synced
    }

    private func enqueueDelete(type: ConfigSyncRecordType, id: String) async throws {
        guard let metadataStore, let syncEngine, let zoneID else {
            throw FloeError.invalidConfiguration("CloudKit sync is not configured")
        }
        var metadata = try await metadataStore.metadata(recordType: type.rawValue, recordID: id)
            ?? ConfigSyncMetadata(recordType: type.rawValue, recordID: id)
        let now = Date()
        metadata.pendingAction = .delete
        metadata.deletedAt = now
        metadata.updatedAt = now
        try await metadataStore.save(metadata)
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
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
                for modification in changes.modifications {
                    try await applyRemote(modification.record)
                }
                for deletion in changes.deletions {
                    try await applyRemoteDeletion(recordID: deletion.recordID, recordType: deletion.recordType)
                }
                lastSyncAt = Date()
                status = .synced

            case .sentRecordZoneChanges(let sent):
                for record in sent.savedRecords { try await acknowledge(record) }
                for recordID in sent.deletedRecordIDs { try await acknowledgeDeletion(recordID) }
                if let firstFailure = sent.failedRecordSaves.first?.error {
                    status = .error(firstFailure.localizedDescription)
                } else if let firstFailure = sent.failedRecordDeletes.values.first {
                    status = .error(firstFailure.localizedDescription)
                } else {
                    lastSyncAt = Date()
                    status = .synced
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
        guard let configurationStore, let uuid = UUID(uuidString: id) else { return nil }
        if (try? await configurationStore.provider(id: uuid)) != nil { return .providerProfile }
        if (try? await configurationStore.model(id: uuid)) != nil { return .modelProfile }
        return nil
    }

    private func payload(type: ConfigSyncRecordType, id: String) async throws -> Data {
        guard let configurationStore, let uuid = UUID(uuidString: id) else {
            throw FloeError.storageCorrupted("Invalid sync record identifier")
        }
        switch type {
        case .providerProfile:
            guard let provider = try await configurationStore.provider(id: uuid) else {
                throw FloeError.storageCorrupted("Missing provider for pending CloudKit save")
            }
            return try Self.encode(provider)
        case .modelProfile:
            guard let model = try await configurationStore.model(id: uuid) else {
                throw FloeError.storageCorrupted("Missing model for pending CloudKit save")
            }
            return try Self.encode(model)
        case .approvalModelSelection, .preference:
            throw FloeError.invalidConfiguration("Record type is not implemented yet")
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
            try await configurationStore.saveProvider(try JSONDecoder.floe.decode(ProviderProfile.self, from: mergedPayload))
        case .modelProfile:
            try await configurationStore.saveModel(try JSONDecoder.floe.decode(ModelProfile.self, from: mergedPayload))
        case .approvalModelSelection, .preference:
            return
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

    private func applyRemoteDeletion(recordID: CKRecord.ID, recordType: String) async throws {
        guard let type = ConfigSyncRecordType(rawValue: recordType),
              let uuid = UUID(uuidString: recordID.recordName),
              let configurationStore,
              let metadataStore
        else { return }
        switch type {
        case .providerProfile: try await configurationStore.deleteProvider(id: uuid)
        case .modelProfile: try await configurationStore.deleteModel(id: uuid)
        case .approvalModelSelection, .preference: break
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
