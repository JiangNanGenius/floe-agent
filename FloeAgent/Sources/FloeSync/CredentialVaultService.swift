import Foundation
import FloeCore
import FloePersistence
import FloeSecurity
import FloeSyncCore

public struct CredentialHandle: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

/// Owns the only path between secret-free metadata and raw Keychain bytes.
/// Callers receive opaque handles unless they are an approved executor.
public actor CredentialVaultService {
    public static let serviceName = "org.floeagent.ios.secrets"

    private let records: CredentialStore
    private let local: KeychainStore
    private let synchronized: KeychainStore

    public init(records: CredentialStore) {
        self.records = records
        self.local = KeychainStore(service: Self.serviceName, synchronizable: false)
        self.synchronized = KeychainStore(service: Self.serviceName, synchronizable: true)
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
        let record = CredentialRecord(
            id: id,
            kind: kind, owner: owner, hostID: hostID, origin: origin,
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
            guard SyncControlPreferences.load().savedCredentialsEnabled else {
                throw FloeError.unauthorized
            }
            do { return try synchronized.read(account: record.keychainAccount) }
            catch KeychainStoreError.itemNotFound { return try local.read(account: record.keychainAccount) }
        }
        return try local.read(account: record.keychainAccount)
    }

    public func setSavedCredentialSyncEnabled(_ enabled: Bool) async throws {
        let vault = try await records.records(owner: .vault)
        for var record in vault where !record.deviceBound && record.synchronizable != enabled {
            let source = enabled ? local : synchronized
            let destination = enabled ? synchronized : local
            do {
                let secret = try source.read(account: record.keychainAccount)
                try destination.store(account: record.keychainAccount, secret: secret)
                guard try destination.read(account: record.keychainAccount) == secret else {
                    throw KeychainStoreError.unexpectedStatus("credential migration verification failed")
                }
                try source.delete(account: record.keychainAccount)
            } catch KeychainStoreError.itemNotFound {
                // Metadata can arrive before iCloud Keychain. Keep the record
                // honest and allow a later retry instead of claiming success.
                if enabled { throw FloeError.notFound("saved credential is not available on this device") }
            }
            record.synchronizable = enabled
            record.updatedAt = Date()
            try await records.save(record)
        }
        var preferences = SyncControlPreferences.load()
        preferences.savedCredentialsEnabled = enabled
        preferences.save()
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
