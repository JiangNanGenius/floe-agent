// FloeSync — iOS Keychain secret store with iCloud Keychain sync.
// Wraps FloeSecurity.KeychainStore with the sync-aware policy surface:
// `kSecAttrSynchronizable=true` + `kSecAttrAccessibleWhenUnlocked`,
// per-provider sync opt-out, and degraded local-only mode.

import Foundation
import FloeCore
import FloeSyncCore
import FloeSecurity

/// Sync-aware secret storage. Config sync and secret sync are deliberately
/// decoupled: configuration may arrive before its secret does, surfacing
/// `.waitingForSecret` until iCloud Keychain catches up.
public struct KeychainSecretStore: Sendable {

    public enum Scope: Sendable, Hashable {
        case provider(UUID)
        case hostSSH(UUID)
        case hostVNC(UUID)
        case hostVNCConnection(hostID: UUID, connectionID: UUID)
        case approvalModel
    }

    private let store: KeychainStore
    /// Providers whose secrets stay local (user opt-out per provider).
    private let syncOptOut: SyncOptOutStorage

    public init(service: String = "org.floeagent.ios.secrets") {
        self.store = KeychainStore(service: service, synchronizable: true)
        self.syncOptOut = SyncOptOutStorage(namespace: service)
    }

    /// Moves an existing secret between synchronized and device-local
    /// Keychain items before committing the preference. A failed copy leaves
    /// the source item and preference untouched, so the operation is retryable.
    public func setSyncEnabled(_ enabled: Bool, for providerID: UUID) async throws {
        let currentlyEnabled = await syncOptOut.isOptedOut(providerID: providerID) == false
        guard currentlyEnabled != enabled else { return }

        // Preserve the provider's preference while the device-wide switch is
        // off. The value remains local until the master switch is enabled.
        guard SyncControlPreferences.load().overallEnabled else {
            await syncOptOut.set(providerID: providerID, optedOut: !enabled)
            return
        }

        let account = accountName(for: .provider(providerID))
        let synchronizedStore = store
        let localStore = KeychainStore(service: store.service, synchronizable: false)
        let source = enabled ? localStore : synchronizedStore
        let destination = enabled ? synchronizedStore : localStore

        do {
            let secret = try source.read(account: account)
            try destination.store(account: account, secret: secret)
            guard try destination.read(account: account) == secret else {
                throw KeychainStoreError.unexpectedStatus("migration verification failed")
            }
            try source.delete(account: account)
        } catch KeychainStoreError.itemNotFound {
            // No value to migrate; the next write will use the selected scope.
        }

        await syncOptOut.set(providerID: providerID, optedOut: !enabled)
    }

    public func isSyncEnabled(for providerID: UUID) async -> Bool {
        guard SyncControlPreferences.load().overallEnabled else { return false }
        let optedOut = await syncOptOut.isOptedOut(providerID: providerID)
        return !optedOut
    }

    /// Migrates configured provider secrets between synchronized and local
    /// Keychain namespaces, then commits the device-wide preference. Host
    /// credentials remain device-local regardless of this setting.
    public func setGlobalSyncEnabled(_ enabled: Bool, providerIDs: [UUID]) async throws {
        var preferences = SyncControlPreferences.load()

        let synchronizedStore = store
        let localStore = KeychainStore(service: store.service, synchronizable: false)
        for providerID in providerIDs {
            let optedOut = await syncOptOut.isOptedOut(providerID: providerID)
            guard !optedOut else { continue }
            let account = accountName(for: .provider(providerID))
            let source = enabled ? localStore : synchronizedStore
            let destination = enabled ? synchronizedStore : localStore
            do {
                let secret = try source.read(account: account)
                try destination.store(account: account, secret: secret)
                guard try destination.read(account: account) == secret else {
                    throw KeychainStoreError.unexpectedStatus("migration verification failed")
                }
                try source.delete(account: account)
            } catch KeychainStoreError.itemNotFound {
                // A provider without a configured secret needs no migration.
            }
        }
        preferences.overallEnabled = enabled
        preferences.save()
    }

    /// Stores a secret. When sync is disabled for the provider the item is
    /// written with a non-synchronizable store instance.
    public func storeSecret(_ secret: Data, scope: Scope) async throws {
        let account = accountName(for: scope)
        if case .provider(let id) = scope, await !isSyncEnabled(for: id) {
            let localStore = KeychainStore(service: store.service, synchronizable: false)
            try localStore.store(account: account, secret: secret)
            // Remove any previously synced copy.
            try? store.delete(account: account)
            return
        }
        switch scope {
        case .hostSSH, .hostVNC, .hostVNCConnection:
            if SyncControlPreferences.load().savedCredentialsEnabled {
                try store.store(account: account, secret: secret)
                try? KeychainStore(service: store.service, synchronizable: false)
                    .delete(account: account)
                return
            }
            let localStore = KeychainStore(service: store.service, synchronizable: false)
            try localStore.store(account: account, secret: secret)
            try? store.delete(account: account)
            return
        case .provider:
            break
        case .approvalModel where !SyncControlPreferences.load().overallEnabled:
            let localStore = KeychainStore(service: store.service, synchronizable: false)
            try localStore.store(account: account, secret: secret)
            try? store.delete(account: account)
            return
        case .approvalModel:
            break
        }
        try store.store(account: account, secret: secret)
        let localStore = KeychainStore(service: store.service, synchronizable: false)
        try? localStore.delete(account: account)
    }

    public func readSecret(scope: Scope) async throws -> Data {
        let account = accountName(for: scope)
        if case .provider(let id) = scope, await !isSyncEnabled(for: id) {
            let localStore = KeychainStore(service: store.service, synchronizable: false)
            return try localStore.read(account: account)
        }
        if case .approvalModel = scope, !SyncControlPreferences.load().overallEnabled {
            let localStore = KeychainStore(service: store.service, synchronizable: false)
            return try localStore.read(account: account)
        }
        do {
            return try store.read(account: account)
        } catch KeychainStoreError.itemNotFound {
            // Fall back to the local (non-synchronizable) namespace.
            let localStore = KeychainStore(service: store.service, synchronizable: false)
            return try localStore.read(account: account)
        }
    }

    public func deleteSecret(scope: Scope) async throws {
        let account = accountName(for: scope)
        let localStore = KeychainStore(service: store.service, synchronizable: false)
        var firstFailure: Error?
        do {
            try store.delete(account: account)
        } catch KeychainStoreError.itemNotFound {
            // The provider may be opted out and therefore local-only.
        } catch {
            firstFailure = error
        }
        do {
            try localStore.delete(account: account)
        } catch KeychainStoreError.itemNotFound {
            // Idempotent deletion is intentional.
        } catch {
            if firstFailure == nil { firstFailure = error }
        }
        if let firstFailure { throw firstFailure }
    }

    /// Sync status for one provider: `.waitingForSecret` when configuration
    /// exists but its secret has not synced.
    public func status(for providerID: UUID, hasConfiguration: Bool) async -> SyncStatus {
        guard hasConfiguration else { return .synced }
        do {
            _ = try await readSecret(scope: .provider(providerID))
            return .synced
        } catch {
            return .waitingForSecret
        }
    }

    private func accountName(for scope: Scope) -> String {
        switch scope {
        case .provider(let id): return "provider.\(id.uuidString)"
        case .hostSSH(let id): return "host.ssh.\(id.uuidString)"
        case .hostVNC(let id): return "host.vnc.\(id.uuidString)"
        case .hostVNCConnection(let hostID, let connectionID):
            return "host.vnc.\(hostID.uuidString).\(connectionID.uuidString)"
        case .approvalModel: return "approval-model"
        }
    }
}

/// Durable set of provider sync opt-outs. This is preference metadata only;
/// secret material remains exclusively in Keychain.
actor SyncOptOutStorage {
    private let defaults: UserDefaults
    private let defaultsKey: String
    private var optedOut: Set<UUID>

    init(namespace: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultsKey = "org.floeagent.sync-opt-out.\(namespace)"
        self.optedOut = Set(
            defaults.stringArray(forKey: self.defaultsKey)?
                .compactMap(UUID.init(uuidString:)) ?? []
        )
    }

    func set(providerID: UUID, optedOut: Bool) {
        if optedOut {
            self.optedOut.insert(providerID)
        } else {
            self.optedOut.remove(providerID)
        }
        defaults.set(
            self.optedOut.map(\.uuidString).sorted(),
            forKey: defaultsKey
        )
    }

    func isOptedOut(providerID: UUID) -> Bool {
        optedOut.contains(providerID)
    }
}
