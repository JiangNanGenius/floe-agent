// FloeSync — iOS-only CloudKit configuration sync engine skeleton.
// M1 delivers the interface surface and merge wiring only; live CloudKit
// behavior requires a provisioned device and is verified in M7.

#if canImport(CloudKit)
import CloudKit
#endif

import Foundation
import FloeCore
import FloeSyncCore

/// Record types synced through the private custom zone.
public enum ConfigSyncRecordType: String, Sendable, CaseIterable {
    case providerProfile = "ProviderProfile"
    case modelProfile = "ModelProfile"
    case approvalModelSelection = "ApprovalModelSelection"
    case preference = "Preference"
}

/// Actor wrapping `CKSyncEngine` for the `FloeConfigZone` private zone.
/// Sensitive fields travel in encrypted record values; secrets themselves
/// never enter CloudKit (see `KeychainSecretStore`).
public actor ConfigSyncEngine {
    public static let zoneName = "FloeConfigZone"

    public private(set) var status: SyncStatus = .paused

    /// Merge strategy injected by the app layer; defaults to the pure
    /// cross-platform per-field last-writer-wins functions.
    public init() {}

    #if canImport(CloudKit)
    private var syncEngine: CKSyncEngine?

    /// Configures the engine for a container. Call once at app startup
    /// after the user's iCloud account state is known.
    public func configure(container: CKContainer) async {
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: nil,
            delegate: NoopSyncDelegate()
        )
        _ = zoneID // Zone creation happens lazily on first save (M2).
        syncEngine = CKSyncEngine(configuration)
        status = .synced
    }

    /// Receives a remote record change and merges it into local state.
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

    /// Marks the engine paused (iCloud unavailable → local-only mode).
    public func markPaused(reason: String) {
        _ = reason
        status = .paused
    }

    /// Marks the engine waiting for a Keychain secret to arrive.
    public func markWaitingForSecret() {
        status = .waitingForSecret
    }
    #else
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
    #endif
}

#if canImport(CloudKit)
/// M1 no-op delegate; real record handling lands in M2 with the settings UI.
private final class NoopSyncDelegate: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // M1 skeleton: events acknowledged without processing.
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }
}
#endif
