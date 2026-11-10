// FloeSync — RQ37 closure (job-d005ef9f9b2f4548, 2026-11-10).
//
// Change-boundary regression coverage for the two concrete completion/lifecycle
// gaps repaired against the live ConfigSyncEngine:
//
//   1. INBOUND APPLY FAN-OUT. A remote record that actually changes this
//      device's observable configuration (provider/model/preference/host/
//      credential write, durable deferred replay, or a resolved credential
//      wait) must notify live consumers so provider/model/default state
//      reloads immediately — previously only the settings manual-sync and
//      foreground-scene call sites reloaded, and scheduled/conflict/late-
//      secret applies emitted nothing at all.
//
//   2. BOUNDED TRANSIENT RETRY. A transient CloudKit failure (network
//      unavailable / rate limited / service unavailable / zone busy) used to
//      publish `.error` and own no further attempt: the durable pending
//      queue just waited for the next write, a manual sync or a foreground
//      transition (the reported "configuration sync failed" symptom). The
//      engine now retries the EXISTING serialized synchronize() path with a
//      15-second first wait; an EFFECTIVE finite server `retryAfter` hint is
//      honoured as the server's own wait (it may exceed the local cap,
//      because retrying before the server asked would re-offend the rate
//      limiter), while only the LOCAL doubling backoff caps at 300 seconds;
//      invalid hints (NaN/infinity/non-positive) fall back to the local
//      cadence. A bounded attempt budget stops after 6 waits while the honest
//      error state remains. Pause, disable, account change, cancellation and
//      any non-transient or successful transition fence/retire late ticks —
//      including a transition that lands WHILE the tick's transport is
//      suspended (the tick must not clobber the new lifecycle's chain, and a
//      failure published by the tick's own attempt legitimately advances the
//      cycle and arms exactly one next wait).
//
// These tests drive the REAL engine over real SQLite durable stores and
// directly constructed CKRecords (the established production-seam pattern of
// DeferredConfigSyncTests/ConfigSyncStatusArrivalTests). No iCloud account,
// no device Keychain, no network: the secret seam reports EXISTENCE only and
// the retry runner seam scripts transport outcomes. Synthetic fixtures only.

#if canImport(CloudKit)

import Foundation
import Testing
import CloudKit
import FloeCore
import FloeModels
import FloeSyncCore
@testable import FloeSync
@testable import FloePersistence

private func isoEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

private func remoteRecord(
    type: ConfigSyncRecordType,
    id: String,
    payload: Data,
    timestamps: [String: Date],
    zone: String = "RQ37ApplyRetryZone"
) throws -> CKRecord {
    let zoneID = CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
    let record = CKRecord(recordType: type.rawValue,
                          recordID: CKRecord.ID(recordName: id, zoneID: zoneID))
    record.encryptedValues["payload"] = payload as CKRecordValue
    record.encryptedValues["fieldTimestamps"] = try isoEncode(timestamps) as CKRecordValue
    return record
}

private func transientCloudKitError(retryAfter: TimeInterval? = nil) -> NSError {
    var userInfo: [String: Any] = [:]
    if let retryAfter { userInfo[CKErrorRetryAfterKey] = retryAfter }
    return NSError(domain: CKErrorDomain,
                   code: CKError.Code.serviceUnavailable.rawValue,
                   userInfo: userInfo)
}

/// Existence-only stand-in for the synchronizable Keychain namespace.
/// Accounts are UUID-derived strings; nothing here holds secret material.
private final class SecretPresence: @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: Set<String>
    init(_ accounts: Set<String> = []) { self.accounts = accounts }
    func insert(_ account: String) { lock.lock(); accounts.insert(account); lock.unlock() }
    func contains(_ account: String) -> Bool { lock.lock(); defer { lock.unlock() }; return accounts.contains(account) }
}

@Suite("Config sync apply fan-out", .serialized)
struct ConfigSyncApplyFanOutTests {
    private func makeStores() async throws -> (ConfigSyncEngine, ModelConfigurationStore, ConfigSyncMetadataStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(configurationStore: configuration, metadataStore: metadata)
        return (engine, configuration, metadata)
    }

    private func provider(_ name: String) -> ProviderProfile {
        ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://apply-fanout.test/v1")!,
            displayName: name
        )
    }

    @Test("An applied remote provider signals exactly one inbound-apply reload; rejection and deferral signal nothing")
    func appliedRejectedAndDeferredAreDistinguishable() async throws {
        let (engine, configuration, metadata) = try await makeStores()
        // Local original for the invalid-remote case.
        let local = provider("本地原配置")
        try await configuration.saveProvider(local)

        let baseline = await engine.remoteConfigurationAppliedCount

        // 1) Invalid remote payload: rejected, not persisted, NOT signaled.
        let invalid = ProviderProfile(
            id: local.id, kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://apply-fanout.test/v1")!, displayName: "bad\nname"
        )
        let invalidRecord = try remoteRecord(
            type: .providerProfile, id: local.id.uuidString,
            payload: try isoEncode(invalid), timestamps: ["displayName": Date()]
        )
        let appliedInvalid = try await engine.applyRemote(invalidRecord)
        #expect(!appliedInvalid)
        #expect(await engine.remoteConfigurationAppliedCount == baseline)
        #expect(try await configuration.provider(id: local.id)?.displayName == "本地原配置")

        // 2) Preference whose model dependency is absent: durably deferred,
        //    NOT signaled (it is not this device's configuration yet).
        let missingModel = UUID()
        let deferredPreferences = ModelSelectionPreferences(defaultAgentModelID: missingModel)
        let deferredRecord = try remoteRecord(
            type: .preference, id: "default",
            payload: try isoEncode(deferredPreferences),
            timestamps: ["defaultAgentModelID": Date()]
        )
        let appliedDeferred = try await engine.applyRemote(deferredRecord)
        #expect(!appliedDeferred)
        #expect(await engine.remoteConfigurationAppliedCount == baseline)
        #expect(try await metadata.metadata(
            recordType: ConfigSyncRecordType.preference.rawValue, recordID: "default"
        )?.deferredRemotePayload != nil)

        // 3) Valid remote provider record: applied → exactly one signal.
        let remote = provider("Remote In")
        let validRecord = try remoteRecord(
            type: .providerProfile, id: remote.id.uuidString,
            payload: try isoEncode(remote), timestamps: ["displayName": Date(), "baseURL": Date()]
        )
        let appliedValid = try await engine.applyRemote(validRecord)
        #expect(appliedValid)
        #expect(await engine.remoteConfigurationAppliedCount == baseline + 1)
        #expect(try await configuration.provider(id: remote.id)?.displayName == "Remote In")
    }

    @Test("Replaying a durable deferred payload through a later apply signals the reload once")
    func deferredReplaySignalsThroughApply() async throws {
        let (engine, configuration, metadata) = try await makeStores()
        let provider = provider("Dependency Provider")
        let model = ModelProfile(
            providerID: provider.id, remoteModelID: "fanout-model", displayName: "Fanout Model",
            limits: ModelLimits(contextTokens: 4096, maxOutputTokens: 512), capabilities: [.text]
        )
        // A durable deferred model payload is waiting for its provider.
        try await metadata.save(ConfigSyncMetadata(
            recordType: ConfigSyncRecordType.modelProfile.rawValue,
            recordID: model.id.uuidString,
            deferredRemotePayload: try isoEncode(model)
        ))
        let baseline = await engine.remoteConfigurationAppliedCount

        // Applying the provider record also replays the durable model payload.
        // The whole real-change is one device-side configuration moment, so
        // the fan-out must fire exactly once for this applyRemote call.
        let record = try remoteRecord(
            type: .providerProfile, id: provider.id.uuidString,
            payload: try isoEncode(provider), timestamps: ["displayName": Date(), "baseURL": Date()]
        )
        let applied = try await engine.applyRemote(record)
        #expect(applied)
        #expect(await engine.remoteConfigurationAppliedCount == baseline + 1)
        #expect(try await configuration.model(id: model.id) != nil)
        #expect(try await metadata.metadata(
            recordType: ConfigSyncRecordType.modelProfile.rawValue, recordID: model.id.uuidString
        )?.deferredRemotePayload == nil)
    }

    @Test("finishFetchBatch keeps dependency order, applies the whole batch once, and publishes the honest epilogue")
    func finishFetchBatchAppliesInOrderAndSignalsEachChange() async throws {
        let (engine, configuration, metadata) = try await makeStores()
        let provider = provider("Batch Provider")
        let model = ModelProfile(
            providerID: provider.id, remoteModelID: "batch-model", displayName: "Batch Model",
            limits: ModelLimits(contextTokens: 4096, maxOutputTokens: 512), capabilities: [.text]
        )
        let preferences = ModelSelectionPreferences(defaultAgentModelID: model.id)
        let now = Date()
        // Delivered in the WRONG dependency order on purpose: CloudKit makes
        // no ordering promise, and the production epilogue must still apply
        // provider → model → preference without deferring anything.
        let modifications: [(recordType: String, record: CKRecord)] = [
            (recordType: ConfigSyncRecordType.preference.rawValue, record: try remoteRecord(
                type: .preference, id: "default",
                payload: try isoEncode(preferences),
                timestamps: ["defaultAgentModelID": now])),
            (recordType: ConfigSyncRecordType.modelProfile.rawValue, record: try remoteRecord(
                type: .modelProfile, id: model.id.uuidString,
                payload: try isoEncode(model),
                timestamps: ["displayName": now, "remoteModelID": now])),
            (recordType: ConfigSyncRecordType.providerProfile.rawValue, record: try remoteRecord(
                type: .providerProfile, id: provider.id.uuidString,
                payload: try isoEncode(provider),
                timestamps: ["displayName": now, "baseURL": now])),
        ]
        let baseline = await engine.remoteConfigurationAppliedCount
        let applied = try await engine.finishFetchBatch(
            modifications: modifications, deletions: [], generation: 0
        )
        #expect(applied)
        // Every record applied its own real change: three fan-out signals.
        #expect(await engine.remoteConfigurationAppliedCount == baseline + 3)
        #expect(try await configuration.provider(id: provider.id) != nil)
        #expect(try await configuration.model(id: model.id) != nil)
        #expect(try await configuration.preferences().defaultAgentModelID == model.id)
        // Nothing was left durably deferred and the honest epilogue published
        // a completed state with lastSyncAt.
        let snapshot = await engine.configurationSnapshot()
        #expect(snapshot.status == .synced)
        #expect(snapshot.lastSyncAt != nil)
        #expect(try await metadata.metadata(
            recordType: ConfigSyncRecordType.preference.rawValue, recordID: "default"
        )?.deferredRemotePayload == nil)

        // A deletion in the same-shaped batch is an observable change too.
        let beforeDeletion = await engine.remoteConfigurationAppliedCount
        let zoneID = CKRecordZone.ID(zoneName: "RQ37ApplyRetryZone", ownerName: CKCurrentUserDefaultName)
        let appliedDeletion = try await engine.finishFetchBatch(
            modifications: [],
            deletions: [(recordType: ConfigSyncRecordType.providerProfile.rawValue,
                         recordID: CKRecord.ID(recordName: provider.id.uuidString, zoneID: zoneID))],
            generation: 0
        )
        #expect(appliedDeletion)
        #expect(await engine.remoteConfigurationAppliedCount == beforeDeletion + 1)
        #expect(try await configuration.provider(id: provider.id) == nil)
    }

    @Test("A live AsyncStream subscriber receives inbound-apply signals without any polling")
    func streamSubscriberSeesApplies() async throws {
        let (engine, _, _) = try await makeStores()
        let received = AppliedSignalRecorder()
        let stream = await engine.remoteConfigurationChanges
        let subscriber = Task {
            for await count in stream {
                await received.record(count)
            }
        }
        // Give the subscriber a chance to attach before the first apply.
        await Task.yield()
        let remote = provider("Stream Provider")
        let record = try remoteRecord(
            type: .providerProfile, id: remote.id.uuidString,
            payload: try isoEncode(remote), timestamps: ["displayName": Date()]
        )
        let applied = try await engine.applyRemote(record)
        #expect(applied)
        var sawSignal = false
        for _ in 0..<500 {
            let empty = await received.isEmpty
            if !empty { sawSignal = true; break }
            await Task.yield()
        }
        subscriber.cancel()
        #expect(sawSignal)
        let counts = await received.values
        #expect(counts.first ?? 0 >= 1)
    }

    @Test("A later Keychain secret arrival re-evaluates readiness through the real computation and signals the reload")
    func lateSecretArrivalResolvesAndSignals() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(configurationStore: configuration, metadataStore: metadata)
        let suite = "rq37-arrival." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        await engine.replacePreferencesDefaultsForTesting(suite: suite)
        SyncControlPreferences(
            overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: false
        ).save(to: defaults)

        // Two synchronizable provider secrets; only one has arrived. This is
        // the reported symptom shape ("some credentials temporarily
        // unavailable") with synthetic identities only.
        let first = ProviderProfile(
            kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://late-arrival.test/v1")!,
            displayName: "Late One",
            secretRef: SecretReference(keychainAccount: "provider.\(UUID().uuidString)", synchronizable: true)
        )
        let second = ProviderProfile(
            kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://late-arrival.test/v1")!,
            displayName: "Late Two",
            secretRef: SecretReference(keychainAccount: "provider.\(UUID().uuidString)", synchronizable: true)
        )
        try await configuration.saveProvider(first)
        try await configuration.saveProvider(second)
        let presence = SecretPresence([first.secretRef!.keychainAccount])
        await engine.replaceSecretExistenceReaderForTesting { service, account, synchronizable in
            #expect(service == KeychainSecretStore.defaultService && synchronizable)
            return presence.contains(account)
        }

        let waiting = await engine.batchCompletionStatus()
        #expect(waiting == .waitingForSecret)
        await engine.markWaitingForSecret()
        let baseline = await engine.remoteConfigurationAppliedCount

        // The LAST pending secret arrives. refreshStatusIfWaiting re-runs the
        // same honest per-account computation (no "first credential wins"
        // shortcut — with only `first` present the wait must persist).
        let stillWaiting = await engine.refreshStatusIfWaiting()
        #expect(stillWaiting == .waitingForSecret)
        #expect(await engine.remoteConfigurationAppliedCount == baseline)
        presence.insert(second.secretRef!.keychainAccount)
        let resolved = await engine.refreshStatusIfWaiting()
        #expect(resolved == .synced)
        // Consumers learn about the resolved readiness through the same seam.
        #expect(await engine.remoteConfigurationAppliedCount == baseline + 1)
        await engine.replaceSecretExistenceReaderForTesting(nil)
    }
}

private actor AppliedSignalRecorder {
    private(set) var values: [UInt64] = []
    var isEmpty: Bool { values.isEmpty }
    func record(_ value: UInt64) { values.append(value) }
}

@Suite("Config sync transient bounded retry", .serialized)
struct ConfigSyncTransientRetryTests {
    @Test("Cadence: 15s first local wait, doubling capped at 300 locally; a valid finite server hint wins as-is even above 300; invalid hints fall back")
    func pureCadence() {
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 0, serverRetryAfter: nil) == 15)
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 15, serverRetryAfter: nil) == 30)
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 240, serverRetryAfter: nil) == 300)
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 300, serverRetryAfter: nil) == 300)
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 900, serverRetryAfter: nil) == 300)
        // A valid finite server wait is respected as the SERVER's minimum,
        // including values LONGER than the local cap: retrying earlier than
        // the server asked would re-offend the rate limiter.
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 0, serverRetryAfter: 90) == 90)
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 60, serverRetryAfter: 900) == 900)
        // Small but valid hints are still the server's stated minimum.
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 240, serverRetryAfter: 5) == 5)
        // NaN/infinity/negative/zero are invalid: never an armed sleep,
        // always the local cadence.
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 100, serverRetryAfter: .nan) == 200)
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 0, serverRetryAfter: .nan) == 15)
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 100, serverRetryAfter: .infinity) == 200)
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 100, serverRetryAfter: -30) == 200)
        #expect(ConfigSyncEngine.transientRetryDelay(afterPrevious: 100, serverRetryAfter: 0) == 200)
    }

    @Test("CloudKit retryAfter becomes a safe typed hint on the failure value")
    func failureCarriesRetryHint() {
        let hinted = ConfigSyncFailure(error: transientCloudKitError(retryAfter: 77), phase: .synchronization)
        #expect(hinted.reason == .temporarilyUnavailable)
        #expect(hinted.retryAfter == 77)
        // Invalid hints (infinity/NaN/non-positive) are treated as ABSENT at
        // the typed boundary too — nothing garbage can be armed or stored.
        let invalidHints: [Double] = [Double.infinity, -Double.infinity, Double.nan, 0.0, -5.0]
        for nonsense in invalidHints {
            let bad = NSError(domain: CKErrorDomain,
                              code: CKError.Code.serviceUnavailable.rawValue,
                              userInfo: [CKErrorRetryAfterKey: nonsense])
            let failure = ConfigSyncFailure(error: bad, phase: .synchronization)
            #expect(failure.reason == .temporarilyUnavailable)
            #expect(failure.retryAfter == nil)
        }
        let plain = ConfigSyncFailure(error: transientCloudKitError(), phase: .configuration)
        #expect(plain.retryAfter == nil)
        let manual = ConfigSyncFailure(reason: .temporarilyUnavailable, phase: .configuration)
        #expect(manual.retryAfter == nil)
    }

    @Test("A transient failure arms the bounded chain: 15s first wait, doubling re-arms, budget stops honestly")
    func armDoubleAndExhaust() async throws {
        let engine = ConfigSyncEngine()
        await engine.replaceTransientRetryRunnerForTesting { throw transientCloudKitError() }

        // Publish a real transient failure through the production attempt path.
        await #expect(throws: Error.self) {
            try await engine.runConfigurationAttempt { _ in throw transientCloudKitError() }
        }
        let failed = await engine.configurationSnapshot()
        #expect(failed.failure?.reason == .temporarilyUnavailable)
        #expect(await engine.transientRetryAttemptsUsed == 1)
        #expect(await engine.transientRetryDelaySeconds == 15)
        var cycle = await engine.transientRetryCycle

        // Due ticks bypass the wall clock deterministically; production
        // armed the same real detached timer with these delays.
        for attempt in 1...ConfigSyncEngine.maximumTransientRetryAttempts {
            await engine.executeTransientRetryTick(attempt: cycle, generation: 0)
            #expect(await engine.transientRetryRuns == attempt)
            #expect(await engine.transientRetryAttemptsUsed == min(attempt + 1, ConfigSyncEngine.maximumTransientRetryAttempts))
            let expectedDelay = min(15 * pow(2, Double(attempt)), ConfigSyncEngine.maximumTransientRetryDelay)
            #expect(await engine.transientRetryDelaySeconds == expectedDelay)
            cycle = await engine.transientRetryCycle
        }
        // Budget exhausted: no further automatic wait is armed. The honest
        // transient error stays published (never faked as synced, pending
        // metadata never dropped); manual sync/next write/foreground own
        // recovery. Re-running the due tick with the current token must NOT
        // re-arm beyond the budget.
        let status = await engine.status
        if case .error = status {} else { Issue.record("exhausted chain must keep the honest error, got \(status)") }
        #expect(await engine.transientRetryAttemptsUsed == ConfigSyncEngine.maximumTransientRetryAttempts)
        await engine.replaceTransientRetryRunnerForTesting(nil)
        await engine.setSynchronizationEnabled(false)
    }

    @Test("A server retryAfter hint wins over the local doubling cadence")
    func serverHintArmsFirstWait() async throws {
        let engine = ConfigSyncEngine()
        await #expect(throws: Error.self) {
            try await engine.runConfigurationAttempt { _ in throw transientCloudKitError(retryAfter: 90) }
        }
        #expect(await engine.transientRetryAttemptsUsed == 1)
        #expect(await engine.transientRetryDelaySeconds == 90)
        await engine.setSynchronizationEnabled(false)
    }

    @Test("A server hint LONGER than the local cap is armed as the server's own wait (never clamped down)")
    func longServerHintIsHonouredNotClamped() async throws {
        let engine = ConfigSyncEngine()
        await #expect(throws: Error.self) {
            try await engine.runConfigurationAttempt { _ in throw transientCloudKitError(retryAfter: 900) }
        }
        #expect(await engine.transientRetryAttemptsUsed == 1)
        // The 300-second cap belongs to the LOCAL backoff only. Cutting a
        // valid 900-second server wait down to 300 would retry EARLIER than
        // the server asked and re-offend the rate limiter.
        #expect(await engine.transientRetryDelaySeconds == 900)
        await engine.setSynchronizationEnabled(false)
    }

    @Test("A tick suspended in its transport never stomps the chain a newer lifecycle owns, and its own published failure arms exactly one next wait")
    func midAwaitOwnershipIsRevalidatedOnBothSides() async throws {
        // --- Case 1: generation moves WHILE the transport await is in flight.
        let engine = ConfigSyncEngine()
        let gate = RetryHoldGate()
        await engine.replaceTransientRetryRunnerForTesting { await gate.hold() }
        await #expect(throws: Error.self) {
            try await engine.runConfigurationAttempt { _ in throw transientCloudKitError() }
        }
        let staleCycle = await engine.transientRetryCycle
        let stale = Task { await engine.executeTransientRetryTick(attempt: staleCycle, generation: 0) }
        await gate.waitUntilEntered()

        // The account changes mid-flight. The new lifecycle then suffers its
        // OWN genuine transient failure and legitimately arms a fresh wait.
        await engine.configurationAccountDidChange()
        await #expect(throws: Error.self) {
            try await engine.runConfigurationAttempt { _ in throw transientCloudKitError() }
        }
        let freshCycle = await engine.transientRetryCycle
        #expect(await engine.transientRetryAttemptsUsed == 1)
        #expect(await engine.transientRetryDelaySeconds == 15)

        // The suspended stale tick resumes now. Its post-await generation
        // revalidation must make it abandon WITHOUT clearing, resetting or
        // double-arming the new lifecycle's chain.
        await gate.release()
        await stale.value
        #expect(await engine.transientRetryAttemptsUsed == 1)
        #expect(await engine.transientRetryDelaySeconds == 15)
        #expect(await engine.transientRetryCycle == freshCycle)
        // Re-running the stale token is a pure pre-check no-op.
        await engine.executeTransientRetryTick(attempt: staleCycle, generation: 0)
        #expect(await engine.transientRetryCycle == freshCycle)
        #expect(await engine.transientRetryAttemptsUsed == 1)
        await engine.setSynchronizationEnabled(false)

        // --- Case 2: the suspended transport's OWN published transient
        // failure (same generation) legitimately advances the cycle and arms
        // the next wait; the resuming tick must leave it untouched instead of
        // arming a second one.
        let owned = ConfigSyncEngine()
        await #expect(throws: Error.self) {
            try await owned.runConfigurationAttempt { _ in throw transientCloudKitError() }
        }
        let cycleA = await owned.transientRetryCycle
        await owned.replaceTransientRetryRunnerForTesting { [weak owned] in
            guard let owned else { return }
            // Mirrors what the real `synchronize()` does on failure: publish
            // the transient outcome through the ordinary attempt path.
            do {
                try await owned.runConfigurationAttempt { _ in throw transientCloudKitError() }
            } catch {}
        }
        await owned.executeTransientRetryTick(attempt: cycleA, generation: 0)
        #expect(await owned.transientRetryRuns == 1)
        // arm #1 (first failure) + arm #2 (the attempt's own published
        // failure) — and NO third arm by the resuming tick.
        #expect(await owned.transientRetryAttemptsUsed == 2)
        #expect(await owned.transientRetryDelaySeconds == 30)
        await owned.setSynchronizationEnabled(false)
    }

    @Test("Pause, account change and a non-transient failure all retire the armed chain and fence stale ticks")
    func transitionsFenceTheChain() async throws {
        // Pause/disable fence.
        let disabled = ConfigSyncEngine()
        let counter = RunnerCounter()
        await disabled.replaceTransientRetryRunnerForTesting { await counter.record() }
        await #expect(throws: Error.self) {
            try await disabled.runConfigurationAttempt { _ in throw transientCloudKitError() }
        }
        let cycle = await disabled.transientRetryCycle
        await disabled.setSynchronizationEnabled(false)
        #expect(await disabled.transientRetryAttemptsUsed == 0)
        #expect(await disabled.transientRetryDelaySeconds == 0)
        await disabled.executeTransientRetryTick(attempt: cycle, generation: 0)
        #expect(await counter.value == 0)   // stale tick must not start a sync

        // Account-change fence keeps the same boundary through the epoch bump.
        let switched = ConfigSyncEngine()
        await #expect(throws: Error.self) {
            try await switched.runConfigurationAttempt { _ in throw transientCloudKitError() }
        }
        let switchedCycle = await switched.transientRetryCycle
        await switched.configurationAccountDidChange()
        let paused = await switched.configurationSnapshot()
        #expect(paused.status == .paused && paused.failure == nil)
        await switched.executeTransientRetryTick(attempt: switchedCycle, generation: 0)
        #expect(await switched.transientRetryRuns == 0)

        // A later NON-transient failure stops the chain immediately.
        let signedOut = ConfigSyncEngine()
        await #expect(throws: Error.self) {
            try await signedOut.runConfigurationAttempt { _ in throw transientCloudKitError() }
        }
        #expect(await signedOut.transientRetryAttemptsUsed == 1)
        await #expect(throws: Error.self) {
            try await signedOut.runConfigurationAttempt { _ in
                throw NSError(domain: CKErrorDomain, code: CKError.Code.notAuthenticated.rawValue)
            }
        }
        #expect(await signedOut.transientRetryAttemptsUsed == 0)
        #expect(await signedOut.transientRetryDelaySeconds == 0)
    }

    @Test("A successful synchronization clears the chain so the next transient failure restarts at 15s")
    func successResetsTheChain() async throws {
        let engine = ConfigSyncEngine()
        await #expect(throws: Error.self) {
            try await engine.runConfigurationAttempt { _ in throw transientCloudKitError() }
        }
        #expect(await engine.transientRetryAttemptsUsed == 1)
        // Any non-error published transition retires the retry ownership.
        await engine.markWaitingForSecret()
        _ = await engine.refreshStatusIfWaiting()   // resolves to .synced: no stores, no secrets
        let snapshot = await engine.configurationSnapshot()
        #expect(snapshot.status == .synced)
        #expect(await engine.transientRetryAttemptsUsed == 0)
        #expect(await engine.transientRetryDelaySeconds == 0)
        // A fresh transient failure re-arms from the initial cadence.
        await #expect(throws: Error.self) {
            try await engine.runConfigurationAttempt { _ in throw transientCloudKitError() }
        }
        #expect(await engine.transientRetryAttemptsUsed == 1)
        #expect(await engine.transientRetryDelaySeconds == 15)
        await engine.setSynchronizationEnabled(false)
    }

    private actor RunnerCounter {
        private(set) var value = 0
        func record() { value += 1 }
    }

    /// Deterministic rendezvous that suspends the injected transient-retry
    /// transport until the test has published a competing lifecycle
    /// transition, proving the post-await ownership revalidation with a real
    /// mid-await switch instead of a wall-clock race.
    private actor RetryHoldGate {
        private var entered = false
        private var enterWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            for waiter in enterWaiters { waiter.resume() }
            enterWaiters = []
            if released { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enterWaiters.append($0) }
        }
        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }
}
#endif
