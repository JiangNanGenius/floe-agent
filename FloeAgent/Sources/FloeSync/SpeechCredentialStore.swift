import Foundation
import FloeCore
import FloeSecurity

public struct SpeechCredentialMigrationOutcome: Sendable, Equatable {
    public var migrated = 0
    public var missing = 0
    public var failed = 0
    public init() {}
}

/// The existing speech namespaces, with the existing device-local iCloud
/// controls. Accounts must be deterministic origin-bound speech accounts.
/// Credentials never enter configuration payloads or this store's index.
public final class SpeechCredentialStore: KeychainProbeStore, @unchecked Sendable {
    public static let ttsLegacyOriginsKey = "voice.output.legacyCredentialOrigins.v1"
    public static let ttsLegacyOriginsInitializedKey = "voice.output.legacyCredentialOrigins.initialized.v1"
    public enum Failure: Error, LocalizedError {
        case migrationUnavailable, invalidAccount
        public var errorDescription: String? {
            FloeL10n.isChinese ? "部分语音密钥未能同步。密钥已保留，请重试或重新保存。"
                : "Some speech keys could not be synchronized. The keys were kept. Retry or save them again."
        }
    }
    private let service: String
    private let local: any KeychainProbeStore
    private let synchronized: any KeychainProbeStore
    private let defaults: UserDefaults
    private final class OperationLock: @unchecked Sendable { let value = NSRecursiveLock() }
    private static let operationLock = OperationLock()
    // All production wrapper instances share the check/copy/write boundary:
    // a late legacy migration must never overwrite an explicit newer save.
    private var lock: NSRecursiveLock { Self.operationLock.value }
    private var indexKey: String { "sync.speech.origin-accounts." + service }
    private static func deletionKey(account: String, service: String) -> String {
        "sync.speech.deleted-origin.v1." + service + "." + FloeDigest.sha256Hex(Data(account.utf8))
    }
    private func transferKey(_ account: String) -> String {
        "sync.speech.pending-transfer.v1." + service + "." + FloeDigest.sha256Hex(Data(account.utf8))
    }
    private struct PendingTransfer: Codable {
        var version = 1
        var enabled: Bool
        var sourceSHA256: String
        var targetBeforeSHA256: String?
    }
    private func pendingTransfer(_ account: String) throws -> PendingTransfer? {
        guard let object = defaults.object(forKey: transferKey(account)) else { return nil }
        guard let data = object as? Data, let value = try? JSONDecoder().decode(PendingTransfer.self, from: data),
              value.version == 1, Self.isDigest(value.sourceSHA256),
              value.targetBeforeSHA256.map(Self.isDigest) != false else { throw Failure.migrationUnavailable }
        return value
    }
    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func saveTransfer(_ value: PendingTransfer, account: String) throws {
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: transferKey(account))
        guard defaults.data(forKey: transferKey(account)) == data else { throw Failure.migrationUnavailable }
    }
    private func digest(_ store: any KeychainProbeStore, account: String) throws -> String? {
        do { return FloeDigest.sha256Hex(try store.read(account: account)) }
        catch KeychainStoreError.itemNotFound { return nil }
    }
    private func requireNotDeleted(_ account: String) throws {
        guard defaults.object(forKey: Self.deletionKey(account: account, service: service)) == nil else {
            throw KeychainStoreError.itemNotFound
        }
    }

    /// Shared with App-owned injected stores: a delete linearizes before both
    /// namespace removal and any retained-legacy read/copy. Only an explicit
    /// successful save may remove this device-local tombstone.
    public static func readUnlessDeleted(account: String, service: String, defaults: UserDefaults,
                                        read: @Sendable () throws -> Data) throws -> Data {
        operationLock.value.lock(); defer { operationLock.value.unlock() }
        try requireReadable(account: account, service: service, defaults: defaults)
        return try read()
    }
    private static func requireReadable(account: String, service: String, defaults: UserDefaults) throws {
        guard valid(account: account, service: service) else { throw Failure.invalidAccount }
        guard defaults.object(forKey: deletionKey(account: account, service: service)) == nil else {
            throw KeychainStoreError.itemNotFound
        }
    }
    public static func deleteExplicit(account: String, service: String, defaults: UserDefaults,
                                      destination: any KeychainProbeStore) throws {
        operationLock.value.lock(); defer { operationLock.value.unlock() }
        guard valid(account: account, service: service) else { throw Failure.invalidAccount }
        defaults.set(true, forKey: deletionKey(account: account, service: service))
        do { try destination.delete(account: account) } catch KeychainStoreError.itemNotFound {}
    }
    public static func storeExplicit(account: String, secret: Data, service: String, defaults: UserDefaults,
                                     destination: any KeychainProbeStore) throws {
        operationLock.value.lock(); defer { operationLock.value.unlock() }
        guard valid(account: account, service: service) else { throw Failure.invalidAccount }
        try destination.store(account: account, secret: secret)
        guard try destination.read(account: account) == secret else { throw Failure.migrationUnavailable }
        defaults.removeObject(forKey: deletionKey(account: account, service: service))
        let key = "sync.speech.pending-transfer.v1." + service + "." + FloeDigest.sha256Hex(Data(account.utf8))
        defaults.removeObject(forKey: key)
    }
    public static func copyRetainedLegacy(_ data: Data, account: String, service: String,
                                          defaults: UserDefaults, destination: any KeychainProbeStore) throws {
        operationLock.value.lock(); defer { operationLock.value.unlock() }
        try requireReadable(account: account, service: service, defaults: defaults)
        if let store = destination as? SpeechCredentialStore { try store.copyKnownLegacy(data, to: account); return }
        let key = "sync.speech.pending-transfer.v1." + service + "." + FloeDigest.sha256Hex(Data(account.utf8))
        guard defaults.object(forKey: key) == nil else { throw Failure.migrationUnavailable }
        do { guard try !destination.read(account: account).isEmpty else { throw Failure.migrationUnavailable }; return }
        catch KeychainStoreError.itemNotFound { try destination.store(account: account, secret: data) }
        guard try destination.read(account: account) == data else { throw Failure.migrationUnavailable }
    }

    public convenience init(service: String, defaults: UserDefaults = .standard) {
        self.init(service: service, local: KeychainStore(service: service, synchronizable: false),
            synchronized: KeychainStore(service: service, synchronizable: true), defaults: defaults)
    }
    public static func prepareAllSynchronization(enabled: Bool, defaults: UserDefaults = .standard) async -> SpeechCredentialMigrationOutcome {
        let stores = [SpeechCredentialBinding.asrService, SpeechCredentialBinding.ttsService]
            .map { SpeechCredentialStore(service: $0, defaults: defaults) }
        return await Task.detached(priority: .utility) {
            var total = SpeechCredentialMigrationOutcome()
            for store in stores {
                let value = store.prepareSynchronization(enabled: enabled)
                total.migrated += value.migrated; total.missing += value.missing; total.failed += value.failed
            }
            return total
        }.value
    }
    init(service: String, local: any KeychainProbeStore, synchronized: any KeychainProbeStore,
         defaults: UserDefaults) {
        self.service = service; self.local = local; self.synchronized = synchronized; self.defaults = defaults
    }
    private var syncEnabled: Bool {
        let value = SyncControlPreferences.load(from: defaults)
        return value.overallEnabled && value.savedCredentialsEnabled
    }
    private func checkAccount(_ account: String) throws {
        guard Self.valid(account: account, service: service) else { throw Failure.invalidAccount }
        let values = defaults.stringArray(forKey: indexKey) ?? []
        guard values.contains(account) || values.count < 512 else { throw Failure.invalidAccount }
    }
    private func remember(_ account: String) throws {
        try checkAccount(account)
        var values = Set(defaults.stringArray(forKey: indexKey) ?? [])
        if values.contains(account) { return }
        guard values.contains(account) || values.count < 512 else { throw Failure.invalidAccount }
        values.insert(account); defaults.set(values.sorted(), forKey: indexKey)
    }
    /// Metadata-only registration lets an explicit OFF request copy a key
    /// already delivered by Keychain even before the first recognition call.
    public func register(account: String) throws {
        lock.lock(); defer { lock.unlock() }; try remember(account)
    }
    public func store(account: String, secret: Data) throws {
        lock.lock(); defer { lock.unlock() }
        try checkAccount(account)
        let target = syncEnabled ? synchronized : local
        try target.store(account: account, secret: secret)
        guard try target.read(account: account) == secret else { throw Failure.migrationUnavailable }
        try remember(account)
        defaults.removeObject(forKey: Self.deletionKey(account: account, service: service))
        defaults.removeObject(forKey: transferKey(account))
    }
    public func read(account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try checkAccount(account)
        try requireNotDeleted(account)
        let bytes: Data
        if syncEnabled {
            do { bytes = try synchronized.read(account: account) }
            catch KeychainStoreError.itemNotFound { bytes = try local.read(account: account) }
        } else { bytes = try local.read(account: account) }
        try remember(account)
        return bytes
    }
    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.valid(account: account, service: service) else { throw Failure.invalidAccount }
        defaults.set(true, forKey: Self.deletionKey(account: account, service: service))
        var failure: Error?
        for store in [local, synchronized] {
            do { try store.delete(account: account) }
            catch KeychainStoreError.itemNotFound {} catch { failure = error }
        }
        if let failure { throw failure }
        var values = Set(defaults.stringArray(forKey: indexKey) ?? [])
        values.remove(account); defaults.set(values.sorted(), forKey: indexKey)
    }

    /// Caller invokes only when the EFFECTIVE overall+saved-key switch changes,
    /// before committing that preference. Missing keys may arrive later. A
    /// failed copy keeps the source; neither namespace is deleted here.
    public func prepareSynchronization(enabled: Bool) -> SpeechCredentialMigrationOutcome {
        lock.lock(); defer { lock.unlock() }
        var result = SpeechCredentialMigrationOutcome()
        let source = enabled ? local : synchronized, target = enabled ? synchronized : local
        for account in (defaults.stringArray(forKey: indexKey) ?? []).prefix(512) {
            guard Self.valid(account: account, service: service) else { result.failed += 1; continue }
            // Intentional removal is not a missing migration and can never
            // authorize a read of retained legacy or inactive namespace data.
            if defaults.object(forKey: Self.deletionKey(account: account, service: service)) != nil { continue }
            do {
                var transfer = try pendingTransfer(account)
                if transfer == nil {
                    if syncEnabled == enabled,
                       let existing = try digest(target, account: account) {
                        // No incomplete transfer exists; a successful explicit
                        // local save after OFF remains authoritative.
                        guard existing != FloeDigest.sha256Hex(Data()) else { throw Failure.migrationUnavailable }
                        result.migrated += 1; continue
                    }
                    let bytes: Data
                    do { bytes = try source.read(account: account) }
                    catch KeychainStoreError.itemNotFound {
                        if try digest(target, account: account) != nil { result.migrated += 1 }
                        else { result.missing += 1 }
                        continue
                    }
                    guard !bytes.isEmpty else { throw Failure.migrationUnavailable }
                    let created = PendingTransfer(enabled: enabled,
                        sourceSHA256: FloeDigest.sha256Hex(bytes),
                        targetBeforeSHA256: try digest(target, account: account))
                    try saveTransfer(created, account: account)
                    transfer = created
                }
                guard let transfer, transfer.enabled == enabled else { throw Failure.migrationUnavailable }
                let currentTarget = try digest(target, account: account)
                if currentTarget == transfer.sourceSHA256 {
                    // The verified target already contains the ORIGINAL
                    // transfer bytes (e.g. process death before final receipt).
                    defaults.removeObject(forKey: transferKey(account))
                    result.migrated += 1; continue
                }
                guard currentTarget == transfer.targetBeforeSHA256 else { throw Failure.migrationUnavailable }
                let bytes = try source.read(account: account)
                guard FloeDigest.sha256Hex(bytes) == transfer.sourceSHA256 else {
                    throw Failure.migrationUnavailable // do not adopt late cloud data
                }
                try target.store(account: account, secret: bytes)
                guard try digest(target, account: account) == transfer.sourceSHA256,
                      try digest(source, account: account) == transfer.sourceSHA256 else {
                    throw Failure.migrationUnavailable
                }
                defaults.removeObject(forKey: transferKey(account))
                result.migrated += 1
            } catch KeychainStoreError.itemNotFound { result.missing += 1 }
            catch { result.failed += 1 }
        }
        return result
    }

    /// Only an already-known LOCAL legacy profile may call this with its
    /// original origin. Remote settings never select a legacy source account.
    public func copyKnownLegacy(_ data: Data, to account: String) throws {
        lock.lock(); defer { lock.unlock() }
        try requireNotDeleted(account)
        guard try pendingTransfer(account) == nil else { throw Failure.migrationUnavailable }
        try remember(account)
        let target: any KeychainProbeStore = syncEnabled ? synchronized : local
        do {
            let existing = try target.read(account: account)
            // Already origin-bound: adopt its reference without overwriting a
            // possibly newer key with the retained legacy copy.
            guard !existing.isEmpty else { throw Failure.migrationUnavailable }
            return
        } catch KeychainStoreError.itemNotFound {
            try target.store(account: account, secret: data)
        }
        guard try target.read(account: account) == data else { throw Failure.migrationUnavailable }
    }
    public static func valid(account: String, service: String) -> Bool {
        guard service == SpeechCredentialBinding.asrService || service == SpeechCredentialBinding.ttsService,
              let range = account.range(of: ".origin.", options: .backwards) else { return false }
        let hash = account[range.upperBound...]
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        let prefix = String(account[..<range.lowerBound])
        if service == SpeechCredentialBinding.asrService {
            return prefix.hasPrefix("profile.") && UUID(uuidString: String(prefix.dropFirst(8))) != nil
        }
        return TTSSpeakerProvider.allCases.contains { provider in
            provider.requiresCloudCredential && provider.supportedBillingRoutes.contains {
                prefix == "tts." + provider.rawValue + "." + $0.rawValue
            }
        }
    }

    /// Reuses this Sendable wrapper's locked local policy inside utility
    /// workers; no UserDefaults object is transferred across actor isolation.
    public func copyRetainedLegacy(_ data: Data, account: String, destination: any KeychainProbeStore) throws {
        try Self.copyRetainedLegacy(data, account: account, service: service, defaults: defaults, destination: destination)
    }

    /// Freeze only origins evidenced by LOCAL metadata before the first cloud
    /// fetch. An empty or ambiguous local bucket authorizes no legacy-key copy.
    /// The marker/map are device-local and never appear in a sync record.
    @MainActor
    public static func captureLocalTTSOrigins(defaults: UserDefaults) {
        guard !defaults.bool(forKey: ttsLegacyOriginsInitializedKey) else { return }
        let decoder = JSONDecoder()
        var values = defaults.data(forKey: "voice.output.profiles.v1")
            .flatMap { try? decoder.decode([String: TTSSettingsSnapshot].self, from: $0) }.map { Array($0.values) } ?? []
        if let current = defaults.data(forKey: "voice.output.settings.v1")
            .flatMap({ try? decoder.decode(TTSSettingsSnapshot.self, from: $0) }) { values.append(current) }
        let groups = Dictionary(grouping: values.filter { $0.provider.requiresCloudCredential && $0.connectionProviderID == nil },
            by: { $0.provider.rawValue + "." + $0.billingRoute.rawValue })
        var origins: [String: String] = [:]
        for (bucket, snapshots) in groups {
            let accounts = Set(snapshots.map(SpeechCredentialBinding.ttsAccount))
            if accounts.count == 1 { origins[bucket] = accounts.first }
        }
        defaults.set(origins, forKey: ttsLegacyOriginsKey)
        defaults.set(true, forKey: ttsLegacyOriginsInitializedKey)
    }

    @MainActor
    public static func prepareTTSLegacyBindings(defaults: UserDefaults,
        local: any KeychainProbeStore = KeychainStore(service: SpeechCredentialBinding.ttsService, synchronizable: false),
        destination: (any KeychainProbeStore)? = nil) async -> Int {
        let target = destination ?? SpeechCredentialStore(service: SpeechCredentialBinding.ttsService, defaults: defaults)
        let policy = SpeechCredentialStore(service: SpeechCredentialBinding.ttsService, defaults: defaults)
        let decoder = JSONDecoder()
        var values = defaults.data(forKey: "voice.output.profiles.v1")
            .flatMap { try? decoder.decode([String: TTSSettingsSnapshot].self, from: $0) }.map { Array($0.values) } ?? []
        if let current = defaults.data(forKey: "voice.output.settings.v1")
            .flatMap({ try? decoder.decode(TTSSettingsSnapshot.self, from: $0) }) { values.append(current) }
        values = values.filter { $0.provider.requiresCloudCredential && $0.connectionProviderID == nil }
        captureLocalTTSOrigins(defaults: defaults)
        let origins = defaults.dictionary(forKey: ttsLegacyOriginsKey) as? [String: String] ?? [:]
        let known = values.filter { origins[$0.provider.rawValue + "." + $0.billingRoute.rawValue] == SpeechCredentialBinding.ttsAccount($0) }
        return await Task.detached(priority: .utility) {
            var failed = 0
            for value in known {
                let old = "tts." + value.provider.rawValue + "." + value.billingRoute.rawValue
                let account = SpeechCredentialBinding.ttsAccount(value)
                do {
                    let bytes = try local.read(account: old)
                    try policy.copyRetainedLegacy(bytes, account: account, destination: target)
                    guard try local.read(account: old) == bytes else { throw Failure.migrationUnavailable }
                } catch KeychainStoreError.itemNotFound {} catch { failed += 1 }
            }
            return failed
        }.value
    }
}
