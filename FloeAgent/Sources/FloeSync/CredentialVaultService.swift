import Foundation
import FloeCore
import FloePersistence
import FloeSecurity
import FloeSyncCore

public struct CredentialHandle: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

/// Outcome of one saved-credential sync request. The counts are per-record
/// truth: `migrated` moved namespaces (or completed a previously interrupted
/// move), `missingOnDevice` stays honestly untouched because no namespace on
/// this device holds its secret, and `failed` hit a real Keychain/metadata
/// error while its source copy was preserved. `preferenceCommitted` reports
/// whether the device-local switch now reflects the request, so the UI can
/// never display a state that contradicts the already-moved secrets.
public struct SavedCredentialSyncOutcome: Sendable, Equatable {
    public let migrated: Int
    public let missingOnDevice: Int
    public let failed: Int
    public let preferenceCommitted: Bool

    public init(migrated: Int, missingOnDevice: Int, failed: Int, preferenceCommitted: Bool) {
        self.migrated = migrated
        self.missingOnDevice = missingOnDevice
        self.failed = failed
        self.preferenceCommitted = preferenceCommitted
    }
}

/// Synchronous secret-storage seam — exactly the `KeychainStore` API shape.
/// Internal so unit tests inject deterministic in-memory stores and exercise
/// migration/retry semantics without touching device Keychain items.
protocol VaultSecretStore: Sendable {
    func store(account: String, secret: Data) throws
    func read(account: String) throws -> Data
    func delete(account: String) throws
}

extension KeychainStore: VaultSecretStore {}

/// Owns the only path between secret-free metadata and raw Keychain bytes.
/// Callers receive opaque handles unless they are an approved executor.
public actor CredentialVaultService {
    public static let serviceName = "org.floeagent.ios.secrets"

    private let records: CredentialStore
    private let local: any VaultSecretStore
    private let synchronized: any VaultSecretStore
    /// Device-local sync switches. Production is `.standard` (exactly the
    /// previous behavior); the internal test seam injects an isolated suite
    /// so synthetic migration tests never mutate real App sync settings.
    private let preferencesDefaults: UserDefaults

    public init(records: CredentialStore) {
        self.records = records
        self.local = KeychainStore(service: Self.serviceName, synchronizable: false)
        self.synchronized = KeychainStore(service: Self.serviceName, synchronizable: true)
        self.preferencesDefaults = .standard
    }

    /// Test seam: deterministic in-memory namespace stores and an isolated
    /// preferences suite name (Sendable, unlike `UserDefaults`). Production
    /// keeps the real-Keychain `init(records:)`; no other construction path
    /// exists, and the suite is never `.standard` for tests.
    init(
        records: CredentialStore,
        local: any VaultSecretStore,
        synchronized: any VaultSecretStore,
        preferencesSuite: String
    ) {
        self.records = records
        self.local = local
        self.synchronized = synchronized
        self.preferencesDefaults = UserDefaults(suiteName: preferencesSuite) ?? .standard
    }

    @discardableResult
    public func capture(
        _ secret: Data,
        kind: CredentialKind,
        owner: CredentialOwner,
        label: String,
        id: UUID = UUID(),
        hostID: UUID? = nil,
        origin: String? = nil,
        deviceBound: Bool = false
    ) async throws -> CredentialHandle {
        let durableHostID: UUID?
        if let hostID, try await records.hostExists(id: hostID) {
            durableHostID = hostID
        } else {
            durableHostID = nil
        }
        let record = CredentialRecord(
            id: id,
            kind: kind, owner: owner, hostID: durableHostID, origin: origin,
            label: label, synchronizable: false, deviceBound: deviceBound
        )
        try local.store(account: record.keychainAccount, secret: secret)
        do {
            try await records.save(record)
        } catch {
            try? local.delete(account: record.keychainAccount)
            throw error
        }
        return CredentialHandle(id: record.id)
    }

    public func promoteToVault(_ handle: CredentialHandle) async throws {
        guard var record = try await records.record(id: handle.id) else {
            throw FloeError.notFound("credential \(handle.id.uuidString)")
        }
        record.owner = .vault
        record.updatedAt = Date()
        try await records.save(record)
    }

    /// Replaces the secret bytes of an existing credential in place, keeping
    /// its stable ID (and therefore every ⟨credential:id⟩ reference) intact.
    public func replaceSecret(_ handle: CredentialHandle, secret: Data) async throws {
        guard var record = try await records.record(id: handle.id) else {
            throw FloeError.notFound("credential \(handle.id.uuidString)")
        }
        try local.store(account: record.keychainAccount, secret: secret)
        if record.synchronizable {
            do {
                try synchronized.store(account: record.keychainAccount, secret: secret)
            } catch {
                // The local copy is authoritative; a synchronizable copy that
                // cannot be written is reconciled by the next sync pass.
                record.synchronizable = false
            }
        }
        record.updatedAt = Date()
        try await records.save(record)
    }

    /// Updates secret-free metadata (label) without touching the secret.
    public func updateLabel(_ handle: CredentialHandle, label: String) async throws {
        guard var record = try await records.record(id: handle.id) else {
            throw FloeError.notFound("credential \(handle.id.uuidString)")
        }
        record.label = label
        record.updatedAt = Date()
        try await records.save(record)
    }

    /// Registers an already-existing Keychain item (for v10 host migration)
    /// without ever reading or copying its secret body.
    public func registerExisting(
        account: String,
        kind: CredentialKind,
        label: String,
        hostID: UUID? = nil,
        synchronizable: Bool,
        deviceBound: Bool = false
    ) async throws {
        let existing = try await records.records(owner: nil).first { $0.keychainAccount == account }
        guard existing == nil else { return }
        try await records.save(CredentialRecord(
            kind: kind, owner: .vault, hostID: hostID, label: label,
            keychainAccount: account, synchronizable: synchronizable,
            deviceBound: deviceBound
        ))
    }

    /// Executor-only resolution. UI/model layers must not expose the result.
    public func resolveForApprovedUse(_ handle: CredentialHandle) async throws -> Data {
        guard let record = try await records.record(id: handle.id) else {
            throw FloeError.notFound("credential \(handle.id.uuidString)")
        }
        if record.synchronizable {
            guard SyncControlPreferences.load(from: preferencesDefaults).savedCredentialsEnabled else {
                throw FloeError.unauthorized
            }
            do { return try synchronized.read(account: record.keychainAccount) }
            catch KeychainStoreError.itemNotFound { return try local.read(account: record.keychainAccount) }
        }
        return try local.read(account: record.keychainAccount)
    }

    /// Turns saved-credential synchronization on or off for every vault
    /// record that is available on this device.
    ///
    /// A record whose secret is not present (metadata arriving before its
    /// secret, a Keychain wipe, or a previous interrupted pass) never
    /// aborts the other records: it is left exactly as it is — neither
    /// published as synced nor deleted — and stays honestly waiting: while
    /// the switch is committed on, `ConfigSyncEngine.credentialSyncStatus`
    /// reports `.waitingForSecret` for such a record until its secret
    /// returns to this device (automatic observation via the existing
    /// arrival monitor), and the settings retry re-runs this idempotent
    /// migration to publish it (manual completion). A retry never
    /// rewrites already-migrated records, and a pass that verified the
    /// destination copy but crashed before the metadata flip or the source
    /// cleanup completes safely on the next run. Real Keychain or metadata
    /// errors affect only that record: its source secret is preserved, its
    /// pre-existing destination copy is restored rather than deleted, and
    /// its previous metadata state stands until a successful retry. The
    /// device-local preference is committed whenever the request succeeded
    /// or at least one record migrated, so an already-moved secret can
    /// never be orphaned behind a switch that stayed off; a fully failed
    /// enable does not pretend the switch turned on.
    @discardableResult
    public func setSavedCredentialSyncEnabled(_ enabled: Bool) async throws -> SavedCredentialSyncOutcome {
        let vault = try await records.records(owner: .vault)
        let source = enabled ? local : synchronized
        let destination = enabled ? synchronized : local
        var migrated = 0
        var missingOnDevice = 0
        var failed = 0
        for record in vault where !record.deviceBound && record.synchronizable != enabled {
            do {
                switch try await migrateRecord(record, enabled: enabled, source: source, destination: destination) {
                case .migrated:
                    migrated += 1
                case .missingOnDevice:
                    missingOnDevice += 1
                }
            } catch {
                // Genuine store/verification/metadata failure: this record
                // keeps its previous state, its source secret and its prior
                // destination copy. Not swallowed silently — counted and
                // surfaced as actionable, with the whole set retryable.
                failed += 1
            }
        }
        let preferenceCommitted: Bool
        if !enabled {
            // Stopping synchronization is always honored immediately.
            preferenceCommitted = true
        } else {
            // Enable commits unless nothing moved and something really
            // failed; leaving records that did move contradicted by the
            // gate in `resolveForApprovedUse` is the failure mode this
            // repair removes.
            preferenceCommitted = failed == 0 || migrated > 0
        }
        if preferenceCommitted {
            var preferences = SyncControlPreferences.load(from: preferencesDefaults)
            preferences.savedCredentialsEnabled = enabled
            preferences.save(to: preferencesDefaults)
        }
        return SavedCredentialSyncOutcome(
            migrated: migrated,
            missingOnDevice: missingOnDevice,
            failed: failed,
            preferenceCommitted: preferenceCommitted
        )
    }

    private enum RecordMigrationResult {
        case migrated
        case missingOnDevice
    }

    /// Moves one record's secret with a destination-preserving,
    /// metadata-before-cleanup ordering:
    ///
    /// 1. observe any pre-existing destination copy (so a later failure
    ///    can restore it instead of deleting an independently valid
    ///    secret);
    /// 2. copy the source secret to the destination and verify the stored
    ///    bytes, restoring or removing only what THIS attempt changed on
    ///    failure, then reporting the error with the source intact;
    /// 3. commit the metadata flip while both copies still exist, so a
    ///    metadata failure leaves the old state resolvable against a
    ///    namespace that still holds the secret;
    /// 4. best-effort remove the redundant source copy. A source-delete
    ///    failure is not a data fault: the destination is verified and the
    ///    metadata committed; the duplicate is byte-identical, is dropped
    ///    by the durable deletion queue with the record, and a later pass
    ///    re-attempts nothing (the record already matches the request).
    ///
    /// Returns `.missingOnDevice` (nothing touched) only when NEITHER
    /// namespace holds a secret for this record on this device. If the
    /// source is absent but the destination already holds the secret, the
    /// metadata flip alone is the honest idempotent recovery of an
    /// interrupted pass. Throws only for genuine store/verification/
    /// metadata errors.
    private func migrateRecord(
        _ record: CredentialRecord,
        enabled: Bool,
        source: any VaultSecretStore,
        destination: any VaultSecretStore
    ) async throws -> RecordMigrationResult {
        // Step 1: remember what the destination held BEFORE this attempt.
        // Any later failure must restore exactly that state.
        let priorDestination: Data?
        do {
            priorDestination = try destination.read(account: record.keychainAccount)
        } catch KeychainStoreError.itemNotFound {
            priorDestination = nil
        }

        let secret: Data
        do {
            secret = try source.read(account: record.keychainAccount)
        } catch KeychainStoreError.itemNotFound {
            // Step 2 alternative: no source copy on this device. If the
            // destination already holds the secret (verified by a pass
            // that crashed after its store but before the flip or the
            // source delete), completing the metadata flip recovers it.
            // Only an absent destination too means there is nothing to
            // move: the record stays untouched and honestly waiting.
            guard priorDestination != nil else { return .missingOnDevice }
            try await flipSynchronizable(record, to: enabled)
            return .migrated
        }

        do {
            try destination.store(account: record.keychainAccount, secret: secret)
            guard try destination.read(account: record.keychainAccount) == secret else {
                throw KeychainStoreError.unexpectedStatus("credential migration verification failed")
            }
        } catch {
            // Step 2 failure: undo only what THIS attempt changed. A
            // pre-existing destination copy is restored (it may be an
            // independently valid synced credential); a destination that
            // did not exist before is removed so unverified bytes can
            // never pose as an arrived secret. The source is untouched.
            if let priorDestination {
                try? destination.store(account: record.keychainAccount, secret: priorDestination)
            } else if (try? destination.read(account: record.keychainAccount)) != nil {
                try? destination.delete(account: record.keychainAccount)
            }
            throw error
        }

        // Step 3: commit metadata while the source copy is still present.
        // If this save fails, the old metadata state remains authoritative
        // and resolvable from the untouched source namespace.
        try await flipSynchronizable(record, to: enabled)

        // Step 4: source cleanup is best-effort AFTER the destination was
        // verified and the metadata committed. A delete failure leaves a
        // byte-identical duplicate (recovered by `drainDeletionQueue`
        // scope); the credential itself is fully migrated.
        try? source.delete(account: record.keychainAccount)
        return .migrated
    }

    private func flipSynchronizable(_ record: CredentialRecord, to enabled: Bool) async throws {
        var flipped = record
        flipped.synchronizable = enabled
        flipped.updatedAt = Date()
        try await records.save(flipped)
    }

    public func status(_ record: CredentialRecord) async -> SyncStatus {
        let store = record.synchronizable ? synchronized : local
        do {
            _ = try store.read(account: record.keychainAccount)
            return .synced
        } catch {
            return .waitingForSecret
        }
    }

    /// Deletes secret metadata and lets the durable deletion queue remove
    /// every local/synchronizable Keychain copy. Callers never receive the
    /// Keychain account or secret body.
    public func delete(_ handle: CredentialHandle) async throws {
        try await records.delete(id: handle.id)
        await drainDeletionQueue()
    }

    /// Crash-recoverable cleanup for rows enqueued by SQLite cascade triggers.
    public func drainDeletionQueue() async {
        guard let pending = try? await records.pendingDeletions() else { return }
        for item in pending {
            do {
                try local.delete(account: item.keychainAccount)
                try synchronized.delete(account: item.keychainAccount)
                try await records.completeDeletion(account: item.keychainAccount)
            } catch {
                try? await records.recordDeletionFailure(
                    account: item.keychainAccount,
                    message: error.localizedDescription
                )
            }
        }
    }
}
