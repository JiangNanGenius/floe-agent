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

    /// Engine lifecycle status. `.waitingForSecret` is DYNAMIC: CloudKit
    /// records and iCloud Keychain secrets arrive independently, so a cached
    /// wait must not freeze after the last batch epilogue. Every transition
    /// into the wait starts the engine-owned arrival monitor (which re-runs
    /// the same honest per-account computation when secrets land), and every
    /// other transition cancels it so paused/syncing/error states can never
    /// be silently promoted.
    public private(set) var status: SyncStatus = .paused {
        didSet {
            #if canImport(CloudKit)
            statusEpoch &+= 1
            if case .waitingForSecret = status {
                startSecretArrivalMonitor()
            } else {
                stopSecretArrivalMonitor()
            }
            #endif
        }
    }
    public private(set) var lastSyncAt: Date?
    public private(set) var lastFailure: ConfigSyncFailure?
    public func configurationSnapshot() -> ConfigSyncSnapshot {
        .init(status: status, failure: lastFailure, lastSyncAt: lastSyncAt)
    }
    public private(set) var synchronizationEnabled = true
    /// Record ids of remote records rejected by canonical validation during
    /// fetch batches. A non-empty set is a REAL partial failure: valid records
    /// in the same batch were applied, while each rejected record was neither
    /// persisted nor acknowledged (its local copy stays authoritative and the
    /// record is redelivered until a corrected payload passes). The set is
    /// never persisted and never causes a remote write; a later successful
    /// apply of the same record removes it.
    public private(set) var rejectedRemoteRecordIDs: Set<String> = []

    private let configurationStore: ModelConfigurationStore?
    private let metadataStore: ConfigSyncMetadataStore?
    private let remoteHostStore: RemoteHostStore?
    private var credentialStore: CredentialStore?

    // MARK: - Inbound-apply observation seam

    /// One increment per REAL inbound mutation of this device's observable
    /// configuration: an applied remote provider/model/preference/host/
    /// credential record, a durable deferred-replay write, or a resolved
    /// credential wait (a late Keychain secret makes configured credentials
    /// usable again). A pending-queue enqueue, an outbound acknowledgment or
    /// a rejected-but-unapplied remote record never signals through here —
    /// local writes already reload their own callers synchronously.
    ///
    /// This closes the concrete completion gap: scheduled/coalesced
    /// synchronization, conflict recovery, deferred replay and late-secret
    /// resolution previously left NO notification for live consumers, so the
    /// running provider/model/default state (ConversationCenter's published
    /// configuration) stayed stale until the next manual sync or foreground
    /// scene. The engine-owned stream is a projection fan-out only — never a
    /// second sync queue, never durable state, never a second engine. The
    /// App-side owner (Root's minimal hook) subscribes once and reloads the
    /// shared configuration/model/default state on each element.
    ///
    /// The stream carries the monotonic applied-change count with
    /// newest-only buffering, so a briefly suspended owner never replays an
    /// old backlog: it just learns that the newest applied-change number is
    /// N. Exactly ONE production owner subscribes — AppEnvironment's
    /// configuration reload — and this seam exists for that single owner;
    /// it is not a general multi-subscriber broadcast surface.
    public var remoteConfigurationChanges: AsyncStream<UInt64> { remoteConfigurationStream }
    private let remoteConfigurationStream: AsyncStream<UInt64>
    private let remoteConfigurationSignal: AsyncStream<UInt64>.Continuation
    private(set) var remoteConfigurationAppliedCount: UInt64 = 0

    /// The production inbound-apply fan-out owner is AppEnvironment. Tests
    /// assert the same counter/seam; nothing else may claim this signal.
    private func signalRemoteConfigurationApplied() {
        remoteConfigurationAppliedCount &+= 1
        remoteConfigurationSignal.yield(remoteConfigurationAppliedCount)
    }

    public init(
        configurationStore: ModelConfigurationStore? = nil,
        metadataStore: ConfigSyncMetadataStore? = nil,
        remoteHostStore: RemoteHostStore? = nil,
        credentialStore: CredentialStore? = nil
    ) {
        let (stream, signal) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.remoteConfigurationStream = stream
        self.remoteConfigurationSignal = signal
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
        #if canImport(CloudKit)
        invalidateConfigurationPreparation()
        #endif
        lastFailure = nil
        status = .paused
    }

    public func markWaitingForSecret() {
        status = .waitingForSecret
    }

    // MARK: - Untrusted remote payload validation

    /// Decodes and validates an untrusted remote provider payload. Applies
    /// the SAME invariants as local writes; an invalid payload is rejected
    /// without ever reaching SQLite. Throws `FloeError.invalidConfiguration`
    /// carrying machine-readable reason tokens only (no name/URL/headers).
    static func validatedRemoteProvider(_ payload: Data) throws -> ProviderProfile {
        let provider: ProviderProfile
        do {
            provider = try JSONDecoder.floe.decode(ProviderProfile.self, from: payload)
        } catch {
            throw FloeError.invalidConfiguration("remote provider malformed")
        }
        let issues = ProviderConfigurationValidation.issues(for: provider)
        guard issues.isEmpty else {
            throw FloeError.invalidConfiguration(
                "remote provider rejected: \(issues.map(\.problem.rawValue).joined(separator: ","))"
            )
        }
        return provider
    }

    /// Decodes and validates an untrusted remote model payload.
    static func validatedRemoteModel(_ payload: Data) throws -> ModelProfile {
        let model: ModelProfile
        do {
            model = try JSONDecoder.floe.decode(ModelProfile.self, from: payload)
        } catch {
            throw FloeError.invalidConfiguration("remote model malformed")
        }
        let issues = ProviderConfigurationValidation.issues(for: model)
        guard issues.isEmpty else {
            throw FloeError.invalidConfiguration(
                "remote model rejected: \(issues.map(\.problem.rawValue).joined(separator: ","))"
            )
        }
        return model
    }

    /// Explicit user decisions outrank capability metadata. When both devices
    /// explicitly decided the same bit, keep the existing per-field timestamp
    /// merge instead of making every device permanently win over the other.
    static func preservingCapabilityDecisions(
        merged: ModelProfile,
        local: ModelProfile?,
        remote: ModelProfile
    ) throws -> ModelProfile {
        guard merged.id == remote.id, local == nil || local?.id == merged.id else {
            throw FloeError.invalidConfiguration("Model capability merge identity mismatch")
        }
        let localOwned = local?.explicitCapabilities ?? []
        let remoteOwned = remote.explicitCapabilities ?? []
        let localOnly = localOwned.subtracting(remoteOwned)
        let remoteOnly = remoteOwned.subtracting(localOwned)
        var result = merged
        result.capabilities.subtract(localOnly.union(remoteOnly))
        result.capabilities.formUnion((local?.capabilities ?? []).intersection(localOnly))
        result.capabilities.formUnion(remote.capabilities.intersection(remoteOnly))
        if local?.explicitCapabilities != nil || remote.explicitCapabilities != nil {
            result.explicitCapabilities = localOwned.union(remoteOwned)
        }
        return result
    }

    // MARK: - Sync control

    /// Pauses or resumes CloudKit traffic without discarding locally queued
    /// metadata. Changes made while paused are uploaded after re-enabling.
    public func setSynchronizationEnabled(_ enabled: Bool) {
        #if canImport(CloudKit)
        if synchronizationEnabled != enabled { invalidateConfigurationPreparation() }
        #endif
        synchronizationEnabled = enabled
        if !enabled {
            lastFailure = nil
            status = .paused
            #if canImport(CloudKit)
            scheduledSync?.cancel()
            scheduledSync = nil
            // An explicitly disabled engine never keeps a pending automatic
            // retry alive; re-enabling starts fresh from real failures.
            clearTransientRetryChain()
            #endif
        }
    }

    #if canImport(CloudKit)
    private var syncEngine: CKSyncEngine?
    private var delegate: EngineDelegate?
    private var zoneID: CKRecordZone.ID?
    private var scheduledSync: Task<Void, Never>?
    private var isSynchronizing = false
    private var configurationLifecycle: UInt64 = 0
    private struct ConfigurationAttempt {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Error>
    }
    private var configurationAttempt: ConfigurationAttempt?
    /// Only bridges the SQLite snapshot suspension to the synchronous engine
    /// publication. SQLite remains the sole durable pending queue.
    private struct ConfigurationPendingHandoff {
        let generation: UInt64
        var changes: [String: ConfigSyncPendingAction] = [:]
        var overflowed = false
    }
    private var configurationPendingHandoff: ConfigurationPendingHandoff?
    private static let maximumConfigurationHandoffChanges = 10_000
    // Internal visibility gives deterministic tests an actual waiter rendezvous,
    // without CloudKit calls, timers or a substitute engine implementation.
    private(set) var configurationWaiterCount = 0
    /// Engine-owned observation of independent iCloud Keychain arrivals while
    /// the honest `.waitingForSecret` state is shown. Actor-owned (not view
    /// owned), cancelled by any other status transition. Bounded exponential
    /// backoff so a secret that takes hours to deliver still resolves without
    /// a busy loop, and every re-check goes through the SAME per-account
    /// computation the batch epilogues use — no "first credential wins"
    /// shortcut and no fallback that could claim arrival of a key that never
    /// entered the synced namespace.
    private var secretArrivalMonitor: Task<Void, Never>?
    /// Lifecycle epoch. Every `status` assignment — including a new batch
    /// epilogue re-asserting the wait — advances it. A credential computation
    /// captures the epoch BEFORE its awaits and may only write its conclusion
    /// while the epoch is unchanged, so a pause, disable, new error or new
    /// batch landing mid-compute can never be overwritten by a stale `.synced`
    /// derived from the previous cycle's inputs.
    private var statusEpoch = 0
    private var secretArrivalMonitorGeneration = 0

    // MARK: - Bounded transient-failure retry

    /// Concrete retry gap: a transient CloudKit failure (network unavailable,
    /// rate limit, service down, zone busy) previously published `.error`
    /// and owned NO further attempt. Durable pending metadata stayed queued
    /// until the next local write, a manual settings sync or a foreground
    /// scene — exactly the user-visible "configuration sync failed" with no
    /// automatic recovery. This engine-owned chain retries the EXISTING
    /// serialized `synchronize()` path: first wait 15 seconds (the retry the
    /// reported symptom expected), an effective finite CloudKit `retryAfter`
    /// hint is honoured as the server's own wait when supplied (it may
    /// exceed the local cap), otherwise the LOCAL backoff doubles up to
    /// 300 seconds, with a bounded attempt budget. After exhaustion the
    /// honest error remains and the ordinary manual/next-write/foreground
    /// routes still own recovery; a
    /// transient failure is never faked as success and pending metadata is
    /// never dropped. Pause, disable, account change, cancellation and any
    /// non-transient or successful transition fence/retire late due-ticks
    /// through the generation + cycle checks below.
    static let initialTransientRetryDelay: TimeInterval = 15
    static let maximumTransientRetryDelay: TimeInterval = 300
    static let maximumTransientRetryAttempts = 6
    private var transientRetryTask: Task<Void, Never>?
    /// Cycle token (arrival-monitor pattern): only the due-tick created by
    /// the CURRENTLY armed wait may run; direct test drives and stale
    /// detached timers both pass through the token check.
    private(set) var transientRetryCycle: UInt64 = 0
    private(set) var transientRetryAttemptsUsed = 0
    private(set) var transientRetryDelaySeconds: TimeInterval = 0
    private(set) var transientRetryRuns = 0
    /// Deterministic seam for the due attempt's work. Production leaves this
    /// nil and the retry executes the real serialized `synchronize()`. Tests
    /// inject scripted transient outcomes without a CloudKit account.
    var transientRetryRunner: (@Sendable () async throws -> Void)?

    func replaceTransientRetryRunnerForTesting(
        _ runner: (@Sendable () async throws -> Void)?
    ) {
        transientRetryRunner = runner
    }

    /// One bounded transient-retry wait. An EFFECTIVE CloudKit hint (finite
    /// and positive) is honoured as the server's own minimum wait — a longer
    /// hint may exceed the local cap, because retrying before the server
    /// asked would re-offend the rate limiter. Only the LOCAL exponential
    /// backoff is capped at 300 seconds. Missing or invalid hints (NaN,
    /// infinity, zero, negative) never become a wait: they fall back to the
    /// local cadence (15 seconds first, then doubling to the cap).
    static func transientRetryDelay(
        afterPrevious previous: TimeInterval,
        serverRetryAfter: TimeInterval?
    ) -> TimeInterval {
        if let hint = serverRetryAfter, hint.isFinite, hint > 0 {
            return hint
        }
        guard previous > 0 else { return initialTransientRetryDelay }
        return min(previous * 2, maximumTransientRetryDelay)
    }

    private func armTransientRetry(for failure: ConfigSyncFailure) {
        guard failure.reason == .temporarilyUnavailable else {
            clearTransientRetryChain()
            return
        }
        guard synchronizationEnabled, transientRetryTask == nil,
              transientRetryAttemptsUsed < Self.maximumTransientRetryAttempts else { return }
        transientRetryAttemptsUsed += 1
        let delay = Self.transientRetryDelay(
            afterPrevious: transientRetryDelaySeconds,
            serverRetryAfter: failure.retryAfter
        )
        transientRetryDelaySeconds = delay
        transientRetryCycle &+= 1
        let cycle = transientRetryCycle
        let generation = configurationLifecycle
        transientRetryTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.executeTransientRetryTick(attempt: cycle, generation: generation)
        }
    }

    /// Cancels the armed wait without touching durable pending metadata, the
    /// SQLite queue or the published lifecycle state — the fence the user
    /// decisions require for disabled/paused/account-changed transitions.
    private func clearTransientRetryChain() {
        transientRetryTask?.cancel()
        transientRetryTask = nil
        transientRetryCycle &+= 1
        transientRetryAttemptsUsed = 0
        transientRetryDelaySeconds = 0
    }

    /// One due transient-retry tick. The handle is retired BEFORE the await
    /// so a failure republished by this very attempt can arm the next bounded
    /// wait through the ordinary publish path. Ownership is revalidated on
    /// BOTH sides of the transport await: the pre-checks reject a tick whose
    /// cycle or lifecycle already moved, and after the awaits a
    /// generation change (pause, disable, account switch that happened while
    /// this attempt was suspended) makes the tick abandon WITHOUT touching
    /// the new lifecycle's chain — no cancel, no budget reset, no extra
    /// wait. A task handle that exists after the await is legitimately this
    /// attempt's own next wait (the failure published by the suspended
    /// `synchronize()`/runner armed it through the ordinary path, which
    /// advances the cycle); leaving it alone is required so the stale tick
    /// never swallows a newer owner of the same lifecycle either.
    func executeTransientRetryTick(attempt cycle: UInt64, generation: UInt64) async {
        guard cycle == transientRetryCycle else { return }
        transientRetryTask = nil
        guard synchronizationEnabled, configurationLifecycle == generation else { return }
        guard case .error = status, lastFailure?.reason == .temporarilyUnavailable else {
            clearTransientRetryChain()
            return
        }
        transientRetryRuns += 1
        if let transientRetryRunner {
            try? await transientRetryRunner()
        } else {
            try? await synchronize()
        }
        // Post-await ownership revalidation. The suspended transport ran
        // against the lifecycle that existed when this tick started; if any
        // transition moved the generation while it was suspended, the new
        // lifecycle owns the chain now and this callback must leave it
        // untouched.
        guard configurationLifecycle == generation else { return }
        if transientRetryTask != nil {
            // This same lifecycle already armed the next bounded wait —
            // normally this attempt's own published transient failure. The
            // tick is done; a second arm here would double-wait.
            return
        }
        if case .error = status, let failure = lastFailure,
           failure.reason == .temporarilyUnavailable {
            // Still the same transient failure with no armed successor (for
            // example an injected transport that failed without publishing
            // through the real path): arm the next bounded wait here.
            armTransientRetry(for: failure)
        } else {
            // Same lifecycle and the transient failure is genuinely gone;
            // retire the chain (idempotent — any real publish already did).
            clearTransientRetryChain()
        }
    }

    private func startSecretArrivalMonitor() {
        guard secretArrivalMonitor == nil else { return }
        secretArrivalMonitorGeneration &+= 1
        let generation = secretArrivalMonitorGeneration
        secretArrivalMonitor = Task { [weak self] in
            var delaySeconds = 1
            var keepWatching = true
            while keepWatching && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delaySeconds))
                if Task.isCancelled { break }
                guard let engine = self else { break }
                keepWatching = await engine.recheckWaitingStatusForArrival()
                delaySeconds = min(delaySeconds * 2, 120)
            }
            await self?.retireSecretArrivalMonitor(observing: generation)
        }
    }

    private func stopSecretArrivalMonitor() {
        secretArrivalMonitor?.cancel()
        secretArrivalMonitor = nil
    }

    /// Clears the stored handle only when it still belongs to the ending
    /// observation cycle; a monitor started for a newer wait is never
    /// orphaned or clobbered by the previous task's exit.
    private func retireSecretArrivalMonitor(observing generation: Int) {
        guard generation == secretArrivalMonitorGeneration else { return }
        secretArrivalMonitor?.cancel()
        secretArrivalMonitor = nil
    }

    /// One arrival-monitor tick (also used by `refreshStatusIfWaiting`).
    /// Returns TRUE only while the engine is STILL waiting with nothing
    /// changed — the monitor keeps watching with a longer backoff. Returns
    /// FALSE when this observation cycle is done: the wait was promoted to a
    /// freshly derived state, or another transition (pause, disable, sync
    /// start, error, cancellation) now owns the display. Every write is
    /// fenced on the epoch captured BEFORE the awaits, so a stale conclusion
    /// is never applied to a lifecycle state that moved mid-compute.
    private func recheckWaitingStatusForArrival() async -> Bool {
        var attempts = 0
        while !Task.isCancelled, attempts < 2 {
            attempts += 1
            guard case .waitingForSecret = status else { return false }
            let epoch = statusEpoch
            let fresh = await batchCompletionStatus()
            if Task.isCancelled { return false }
            if statusEpoch == epoch {
                guard case .waitingForSecret = status else { return false }
                if fresh == .waitingForSecret { return true }
                status = fresh
                // The wait resolved through the honest per-account
                // re-computation: secrets that arrived late make configured
                // credentials usable again, so consumers must re-read now.
                // An error conclusion is not a configuration change — only
                // the non-error promotion fans the reload out.
                clearTransientRetryChain()
                if case .error = fresh {} else { signalRemoteConfigurationApplied() }
                return false
            }
            // The lifecycle moved while credentials were being computed. If
            // the engine re-entered the wait (a new batch epilogue), recompute
            // against current inputs instead of exiting — this task IS the
            // monitor for the new cycle (a start was suppressed because the
            // handle was already set), and dropping it would freeze the
            // status again with no watching task. Any other transition
            // (pause, disable, sync start, error) owns the display now.
            guard case .waitingForSecret = status else { return false }
        }
        // Bounded attempts exhausted behind a reassignment storm: hand the
        // cadence back to the monitor's regular next tick while the engine
        // is still waiting, and finish otherwise.
        return !Task.isCancelled && status == .waitingForSecret
    }

    /// UI seam for an opened settings screen: re-evaluates the credential
    /// wait immediately instead of waiting for the next monitor tick or a
    /// CloudKit batch that may never come. Only ever acts on `.waitingForSecret`;
    /// paused/syncing/synced/error states are returned unchanged so a real
    /// error or pause can never be promoted by a screen visit, and the epoch
    /// fence prevents a mid-compute transition from being overwritten.
    @discardableResult
    public func refreshStatusIfWaiting() async -> SyncStatus {
        if case .waitingForSecret = status {
            _ = await recheckWaitingStatusForArrival()
        }
        return status
    }

    /// Device-local sync switches consulted by the credential status/staging
    /// path. Production is `.standard` (exactly the previous behavior); tests
    /// inject an isolated suite instead of mutating real App sync settings.
    private var preferencesDefaults: UserDefaults = .standard

    /// Suite name is Sendable (unlike `UserDefaults`), so tests inject an
    /// isolated store without touching real App sync settings.
    func replacePreferencesDefaultsForTesting(suite: String?) {
        preferencesDefaults = suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Deterministic seam for per-account secret existence. Production leaves
    /// this nil and the real synchronizable Keychain namespace is read (byte
    /// values are discarded immediately by callers; only existence is
    /// observed). Tests inject presence sets and deliberately delayed reads
    /// to exercise late arrival and mid-compute lifecycle changes without
    /// device Keychain access. Existence only — never a secret body.
    var secretExistenceReader: (@Sendable (String, String, Bool) async -> Bool)?

    func replaceSecretExistenceReaderForTesting(
        _ reader: (@Sendable (String, String, Bool) async -> Bool)?
    ) {
        secretExistenceReader = reader
    }

    /// Existence-only check in the declared Keychain namespace. Any read
    /// failure (item missing or unavailable) counts as not present, matching
    /// the previous `try keychain.read` / `catch → waiting` behavior exactly.
    private func secretPresent(service: String, account: String, synchronizable: Bool) async -> Bool {
        if let secretExistenceReader {
            return await secretExistenceReader(service, account, synchronizable)
        }
        do {
            _ = try KeychainStore(service: service, synchronizable: synchronizable)
                .read(account: account)
            return true
        } catch {
            return false
        }
    }

    public func configure(container: CKContainer) async throws {
        try Task.checkCancellation()
        guard synchronizationEnabled else { lastFailure = nil; status = .paused; return }
        if configurationAttempt == nil, syncEngine != nil { return }
        try await runConfigurationAttempt { [self] generation in
            try await prepareCloudKitConfiguration(container: container, generation: generation)
        }
    }

    /// One service-owned attempt. Concurrent callers await its actual outcome;
    /// a caller's cancellation never cancels another caller's configuration.
    /// Pause/account changes cancel and invalidate the owned attempt instead.
    func runConfigurationAttempt(_ operation: @escaping @Sendable (UInt64) async throws -> Void) async throws {
        try Task.checkCancellation()
        configurationWaiterCount += 1; defer { configurationWaiterCount -= 1 }
        let callerGeneration = configurationLifecycle
        while true {
            guard callerGeneration == configurationLifecycle else { throw CancellationError() }
            guard synchronizationEnabled else { lastFailure = nil; status = .paused; return }
            let attempt: ConfigurationAttempt
            if let current = configurationAttempt { attempt = current }
            else {
                let generation = configurationLifecycle, id = UUID()
                let task = Task { [self] in
                    do {
                        try requireCurrentConfiguration(generation)
                        lastFailure = nil; status = .syncing
                        try await operation(generation)
                        try requireCurrentConfiguration(generation)
                    } catch {
                        publishConfigurationFailure(error, phase: .configuration, generation: generation)
                        throw error
                    }
                }
                attempt = .init(id: id, generation: generation, task: task)
                configurationAttempt = attempt
            }
            do {
                try await attempt.task.value
                if configurationAttempt?.id == attempt.id { configurationAttempt = nil }
                try Task.checkCancellation()
                guard callerGeneration == configurationLifecycle else { throw CancellationError() }
                // A new attempt may start only after the obsolete task joined.
                if attempt.generation != configurationLifecycle { continue }
                return
            } catch {
                if configurationAttempt?.id == attempt.id { configurationAttempt = nil }
                try Task.checkCancellation()
                guard callerGeneration == configurationLifecycle else { throw CancellationError() }
                if attempt.generation != configurationLifecycle { continue }
                throw error
            }
        }
    }

    private func invalidateConfigurationPreparation() {
        configurationLifecycle &+= 1
        configurationAttempt?.task.cancel()
        configurationPendingHandoff = nil
        clearTransientRetryChain()
    }
    func configurationAccountDidChange() {
        invalidateConfigurationPreparation()
        lastFailure = nil; status = .paused
    }
    private func requireCurrentConfiguration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard synchronizationEnabled, configurationLifecycle == generation else { throw CancellationError() }
    }
    private func publishConfigurationFailure(_ error: Error, phase: ConfigSyncFailure.Phase, generation: UInt64) {
        guard synchronizationEnabled, configurationLifecycle == generation else { return }
        if ConfigSyncFailure.isCancellation(error) { lastFailure = nil; status = .paused; return }
        let failure = ConfigSyncFailure(error: error, phase: phase)
        lastFailure = failure; status = .error(failure.reason.rawValue)
        // Transient failures (offline, rate limit, service unavailable,
        // zone busy) own a bounded automatic retry of the existing
        // serialized sync path; every other reason stops the chain so a
        // sign-in/validation problem is never retried as if transient.
        armTransientRetry(for: failure)
    }
    private func publishConfigurationStatus(_ value: SyncStatus, generation: UInt64, completed: Bool = false) {
        guard synchronizationEnabled, configurationLifecycle == generation else { return }
        if completed { lastSyncAt = Date() }
        if case .error = value { lastFailure = .init(reason: .synchronizationFailed, phase: .synchronization) }
        else {
            lastFailure = nil
            // Any successful/queued transition retires the automatic retry
            // chain; the next transient failure re-arms from scratch.
            clearTransientRetryChain()
        }
        status = value
    }

    private func prepareCloudKitConfiguration(container: CKContainer, generation: UInt64) async throws {
        try requireCurrentConfiguration(generation)
        // A fully published engine may have completed just before a pause;
        // its waiter was invalidated, but resuming must not create a second one.
        if syncEngine != nil { return }
        guard let metadataStore else { throw FloeError.invalidConfiguration("ConfigSyncEngine requires a metadata store") }
        let accountStatus = try await container.accountStatus()
        try requireCurrentConfiguration(generation)
        guard accountStatus == .available else {
            lastFailure = .init(reason: accountStatus == .noAccount ? .signInRequired : .temporarilyUnavailable, phase: .configuration)
            status = .paused
            return
        }
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        let stateData = try await metadataStore.engineState()
        try requireCurrentConfiguration(generation)
        let serialization = stateData.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        // Finish every throwing/suspending preparation BEFORE publishing a
        // runner. A failed SQLite/deferred read cannot leave a half-configured
        // CKSyncEngine behind or consume/remove its durable pending queue.
        if try await retryDeferredRecords() {
            // A durable deferred payload just became this device's real
            // configuration: the same inbound-apply fan-out as a fetch batch.
            signalRemoteConfigurationApplied()
        }
        try requireCurrentConfiguration(generation)
        try await withConfigurationPendingHandoff(generation: generation,
            readPending: { try await metadataStore.pending(limit: 10_000) }
        ) { owner, changes in
            // No await between the merged handoff and publication. Writes
            // resumed later see this real engine and use the normal enqueue.
            let delegate = EngineDelegate(owner: owner)
            let configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                stateSerialization: serialization, delegate: delegate)
            let engine = CKSyncEngine(configuration)
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            for (id, action) in changes {
                let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
                switch action {
                case .save: engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                case .delete: engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                }
            }
            owner.delegate = delegate; owner.syncEngine = engine; owner.zoneID = zoneID
            owner.lastFailure = nil; owner.status = .syncing
        }
    }

    /// A synchronous publishing tail closes the actor reentrancy gap after
    /// reading pending metadata. The real preparation and deterministic
    /// SQLite tests use this same boundary; it never waits on its own task.
    func withConfigurationPendingHandoff<T: Sendable>(
        generation: UInt64,
        readPending: @Sendable () async throws -> [ConfigSyncMetadata],
        publish: @Sendable (isolated ConfigSyncEngine, [String: ConfigSyncPendingAction]) -> T
    ) async throws -> T {
        try requireCurrentConfiguration(generation)
        guard configurationPendingHandoff == nil else {
            throw FloeError.internalError("Configuration pending snapshot is already active")
        }
        configurationPendingHandoff = .init(generation: generation)
        defer {
            if configurationPendingHandoff?.generation == generation { configurationPendingHandoff = nil }
        }
        let pending = try await readPending()
        try requireCurrentConfiguration(generation)
        guard let handoff = configurationPendingHandoff, handoff.generation == generation else {
            throw CancellationError()
        }
        guard !handoff.overflowed else {
            // Local writes already succeeded and remain durable. Refuse only
            // this configuration attempt; never drop a buffered identity.
            throw FloeError.invalidConfiguration("Configuration pending snapshot changed too much; retry sync")
        }
        var changes: [String: ConfigSyncPendingAction] = [:]
        for metadata in pending {
            if let action = metadata.pendingAction { changes[metadata.recordID] = action }
        }
        // These commits occurred after/beside the snapshot: latest same-ID
        // save/delete always wins over its older snapshot action.
        changes.merge(handoff.changes) { _, later in later }
        return publish(self, changes)
    }

    private func capturePendingConfigurationChange(id: String, action: ConfigSyncPendingAction) {
        guard synchronizationEnabled,
              configurationPendingHandoff?.generation == configurationLifecycle,
              configurationPendingHandoff?.overflowed == false else { return }
        if configurationPendingHandoff?.changes[id] == nil,
           (configurationPendingHandoff?.changes.count ?? 0) >= Self.maximumConfigurationHandoffChanges {
            configurationPendingHandoff?.overflowed = true
            return
        }
        configurationPendingHandoff?.changes[id] = action
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

    /// Persists a model and queues the sync write. `expected` forwards a
    /// compare-and-swap expectation to the store: a reviewed editor writes
    /// only when the persisted row still equals the snapshot it validated, so
    /// an interleaved remote apply makes the save throw instead of being
    /// silently overwritten. The enqueue happens only after the store write
    /// actually committed.
    public func saveModel(
        _ model: ModelProfile,
        changedFields: Set<String>? = nil,
        expected: ModelProfile? = nil
    ) async throws {
        guard let configurationStore else {
            throw FloeError.invalidConfiguration("ConfigSyncEngine requires a configuration store")
        }
        try await configurationStore.saveModel(model, expected: expected)
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

    /// Completion status for one fetch/send batch. An honest rejected-record
    /// outcome is preserved here: the derived credential status only decides
    /// the result when the batch contained no rejected remote record.
    /// (Bug fixed by T6: the `.fetchedRecordZoneChanges` epilogue used to
    /// overwrite a rejection with `.synced`.)
    func batchCompletionStatus() async -> SyncStatus {
        if !rejectedRemoteRecordIDs.isEmpty {
            return .error(Self.rejectedRemoteMessage)
        }
        return await credentialSyncStatus()
    }

    /// User-initiated retry after a rejected partial batch. Re-runs the
    /// EXISTING synchronization path only (no new store, no remote write, no
    /// forced redelivery state rewrite). Returns true when no rejected record
    /// remains; a still-invalid remote payload keeps the honest error state.
    @discardableResult
    public func retryRejectedRemoteRecords() async -> Bool {
        guard !rejectedRemoteRecordIDs.isEmpty else { return true }
        try? await synchronize()
        return rejectedRemoteRecordIDs.isEmpty
    }

    public func synchronize(container: CKContainer? = nil) async throws {
        guard synchronizationEnabled else { lastFailure = nil; status = .paused; return }
        guard !isSynchronizing else { return }
        isSynchronizing = true; defer { isSynchronizing = false }
        let generation = configurationLifecycle
        scheduledSync = nil
        do {
            try requireCurrentConfiguration(generation)
            if syncEngine == nil, let container { try await configure(container: container) }
            try requireCurrentConfiguration(generation)
            guard let syncEngine else { throw FloeError.invalidConfiguration("CloudKit sync is not configured") }
            lastFailure = nil; status = .syncing
            // Establish the zone before fetching; preserve the same real
            // send/fetch/stage/send cycle and durable metadata/replay path.
            try await syncEngine.sendChanges()
            try requireCurrentConfiguration(generation)
            try await syncEngine.fetchChanges()
            try requireCurrentConfiguration(generation)
            try await stageUntrackedLocalConfiguration()
            try requireCurrentConfiguration(generation)
            try await syncEngine.sendChanges()
            try requireCurrentConfiguration(generation)
            let completion = await batchCompletionStatus()
            try requireCurrentConfiguration(generation)
            publishConfigurationStatus(completion, generation: generation, completed: true)
        } catch {
            if synchronizationEnabled, configurationLifecycle == generation,
               !ConfigSyncFailure.isCancellation(error), let preparation = lastFailure, syncEngine == nil {
                // Keep the actual preparation reason (including account not
                // ready), instead of replacing it with the later nil guard.
                status = .error(preparation.reason.rawValue)
            } else { publishConfigurationFailure(error, phase: syncEngine == nil ? .configuration : .synchronization, generation: generation) }
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
        capturePendingConfigurationChange(id: id, action: .save)

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
        capturePendingConfigurationChange(id: id, action: .delete)

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
        if SyncControlPreferences.load(from: preferencesDefaults).savedCredentialsEnabled, let credentialStore {
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

    /// Production inbound-apply epilogue for one fetched batch, extracted so
    /// the exact dependency order, honest partial-failure status and durable
    /// deferred replay are deterministically testable without a CloudKit
    /// account (same seam philosophy as `applyRemote`/`batchCompletionStatus`).
    /// `handleEvent(.fetchedRecordZoneChanges)` runs THIS code with the real
    /// batch contents. Returns TRUE when the batch applied at least one real
    /// configuration change (per-record fan-out signalling already happened
    /// inside `applyRemote`/`applyRemoteDeletion`; this return also reports
    /// durable replays so the batch epilogue can fan them out too).
    func finishFetchBatch(
        modifications: [(recordType: String, record: CKRecord)],
        deletions: [(recordType: String, recordID: CKRecord.ID)],
        generation: UInt64
    ) async throws -> Bool {
        // CloudKit does not promise dependency order. Providers must
        // exist before their models, and models before preferences
        // whose foreign keys select them.
        let sorted = modifications.sorted {
            Self.applyPriority(for: $0.recordType) < Self.applyPriority(for: $1.recordType)
        }
        var applied = false
        for modification in sorted {
            applied = (try await applyRemote(modification.record)) || applied
        }
        for deletion in deletions {
            applied = (try await applyRemoteDeletion(
                recordID: deletion.recordID, recordType: deletion.recordType
            )) || applied
        }
        if try await retryDeferredRecords() {
            // A durable deferred payload just became this device's
            // configuration outside any single record's apply path.
            signalRemoteConfigurationApplied()
            applied = true
        }
        // Preserve an honest partial-failure status for the batch:
        // a rejected record must never be masked by .synced.
        let completion = await batchCompletionStatus()
        publishConfigurationStatus(completion, generation: generation, completed: true)
        return applied
    }

    fileprivate func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let generation = configurationLifecycle
        do {
            switch event {
            case .stateUpdate(let update):
                guard let metadataStore else { return }
                let data = try JSONEncoder().encode(update.stateSerialization)
                try await metadataStore.saveEngineState(data)

            case .accountChange(let change):
                // A freshly constructed engine reports its initial sign-in.
                // That is the same account availability just prepared above,
                // not an obsolete runner returning after an account switch.
                if case .signIn = change.changeType,
                   let attempt = configurationAttempt, attempt.generation == configurationLifecycle,
                   let current = self.syncEngine, current === syncEngine { break }
                configurationAccountDidChange()

            case .fetchedRecordZoneChanges(let changes):
                _ = try await finishFetchBatch(
                    modifications: changes.modifications.map {
                        (recordType: $0.record.recordType, record: $0.record)
                    },
                    deletions: changes.deletions.map {
                        (recordType: $0.recordType, recordID: $0.recordID)
                    },
                    generation: generation
                )

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
                    publishConfigurationStatus(.syncing, generation: generation)
                    if generation == configurationLifecycle { scheduleSynchronization() }
                } else if let firstFailure = sent.failedRecordSaves.first?.error {
                    publishConfigurationFailure(firstFailure, phase: .synchronization, generation: generation)
                } else if let firstFailure = sent.failedRecordDeletes.values.first {
                    publishConfigurationFailure(firstFailure, phase: .synchronization, generation: generation)
                } else {
                    let completion = await batchCompletionStatus()
                    publishConfigurationStatus(completion, generation: generation, completed: true)
                }

            case .didFetchRecordZoneChanges(let result):
                if let error = result.error { publishConfigurationFailure(error, phase: .synchronization, generation: generation) }

            default:
                break
            }
        } catch {
            publishConfigurationFailure(error, phase: .synchronization, generation: generation)
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

    /// Applies one fetched remote record. Internal (not private) so the exact
    /// batch/status pipeline is directly testable without a CloudKit account;
    /// the production delegate calls it with the real CKRecord. Returns TRUE
    /// only when this device's observable configuration actually changed
    /// (a store write or a durable deferred replay); a deferred, rejected or
    /// guard-skipped record returns FALSE and must not fan a reload out.
    @discardableResult
    func applyRemote(_ record: CKRecord) async throws -> Bool {
        var didStore = false
        var replayed = false
        defer { if didStore || replayed { signalRemoteConfigurationApplied() } }
        guard let type = ConfigSyncRecordType(rawValue: record.recordType),
              let payload = record.encryptedValues["payload"] as? Data,
              let timestampsData = record.encryptedValues["fieldTimestamps"] as? Data,
              let metadataStore,
              let configurationStore
        else { return false }

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

        var repairedCapabilityDecisions = false
        switch type {
        case .providerProfile:
            let provider: ProviderProfile
            do {
                provider = try Self.validatedRemoteProvider(mergedPayload)
            } catch {
                // Untrusted/merged payload: skip this record (never persist,
                // never acknowledge metadata). Local configuration and this
                // device's pending saves are preserved; valid records in the
                // same batch still apply. Logs carry tokens only, no
                // name/endpoint/header content.
                Self.logRejectedRemoteProvider(
                    id: record.recordID.recordName,
                    reason: error.localizedDescription
                )
                rejectedRemoteRecordIDs.insert(record.recordID.recordName)
                status = .error(Self.rejectedRemoteMessage)
                return false
            }
            guard provider.kind != .local else { return false }
            try await configurationStore.saveProvider(provider)
            didStore = true
            replayed = (try await retryDeferredRecords()) || replayed
        case .modelProfile:
            let model: ModelProfile
            do {
                let merged = try Self.validatedRemoteModel(mergedPayload)
                let remote = try Self.validatedRemoteModel(payload)
                let local = try localPayload.map(Self.validatedRemoteModel)
                model = try Self.preservingCapabilityDecisions(
                    merged: merged, local: local, remote: remote
                )
                repairedCapabilityDecisions = model.capabilities != merged.capabilities
                    || model.explicitCapabilities != merged.explicitCapabilities
            } catch {
                FloeLogger(category: .sync).warning(
                    "rejected remote model profile \(record.recordID.recordName): \(error.localizedDescription)"
                )
                rejectedRemoteRecordIDs.insert(record.recordID.recordName)
                status = .error(Self.rejectedRemoteMessage)
                return false
            }
            guard model.providerID != ProviderProfile.onDeviceProviderID else { return false }
            guard try await configurationStore.provider(id: model.providerID) != nil else {
                try await saveDeferredRemoteRecord(
                    record: record, type: type, payload: try Self.encode(model),
                    localTimestamps: localTimestamps, remoteTimestamps: remoteTimestamps,
                    existing: existing
                )
                return false
            }
            try await configurationStore.saveModel(model)
            didStore = true
            replayed = (try await retryDeferredPreferences()) || replayed
        case .preference:
            let remote = Self.withoutDeviceLocalModels(
                try JSONDecoder.floe.decode(ModelSelectionPreferences.self, from: mergedPayload)
            )
            let local = try await configurationStore.preferences()
            let restored = Self.restoringDeviceLocalModels(remote, from: local)
            guard try await missingModelIDs(in: restored).isEmpty else {
                try await saveDeferredRemoteRecord(
                    record: record, type: type, payload: mergedPayload,
                    localTimestamps: localTimestamps, remoteTimestamps: remoteTimestamps,
                    existing: existing
                )
                return false
            }
            try await configurationStore.savePreferences(restored)
            didStore = true
        case .remoteHostProfile:
            guard let remoteHostStore else { return false }
            try await remoteHostStore.saveHost(
                try JSONDecoder.floe.decode(RemoteHostStore.StoredHost.self, from: mergedPayload)
            )
            didStore = true
        case .credentialDescriptor:
            guard let credentialStore else { return false }
            let descriptor = try JSONDecoder.floe.decode(CredentialRecord.self, from: mergedPayload)
            guard descriptor.owner == .vault, descriptor.synchronizable else {
                throw FloeError.storageCorrupted("Cloud credential descriptor exceeded vault scope")
            }
            try await credentialStore.save(descriptor)
            didStore = true
        }

        var mergedTimestamps = localTimestamps
        for (field, date) in remoteTimestamps where date > (mergedTimestamps[field] ?? .distantPast) {
            mergedTimestamps[field] = date
        }
        if repairedCapabilityDecisions {
            // Publish the protected value through the existing pending-save
            // path so a metadata-only remote write cannot erase provenance on
            // a fresh device. No second sync queue or unconditional echo.
            let now = Date()
            mergedTimestamps["capabilities"] = now
            mergedTimestamps["explicitCapabilities"] = now
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
            deferredRemotePayload: nil,
            pendingAction: retainsLocalChanges || repairedCapabilityDecisions ? .save : nil,
            updatedAt: record.modificationDate ?? Date()
        )
        try await metadataStore.save(metadata)
        // A previously rejected record that now applies cleanly is no longer
        // part of the honest partial-failure state.
        rejectedRemoteRecordIDs.remove(record.recordID.recordName)
        if retainsLocalChanges {
            syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
        return didStore || replayed
    }

    private func saveDeferredRemoteRecord(
        record: CKRecord,
        type: ConfigSyncRecordType,
        payload: Data,
        localTimestamps: [String: Date],
        remoteTimestamps: [String: Date],
        existing: ConfigSyncMetadata?
    ) async throws {
        guard let metadataStore else { return }
        var mergedTimestamps = localTimestamps
        for (field, date) in remoteTimestamps where date > (mergedTimestamps[field] ?? .distantPast) {
            mergedTimestamps[field] = date
        }
        let retainsLocalChanges = existing?.pendingAction == .save && localTimestamps.contains { field, date in
            date >= (remoteTimestamps[field] ?? .distantPast)
        }
        try await metadataStore.save(ConfigSyncMetadata(
            recordType: type.rawValue,
            recordID: record.recordID.recordName,
            fieldTimestamps: mergedTimestamps,
            cloudChangeTag: record.recordChangeTag,
            cloudSystemFields: Self.archiveSystemFields(record),
            deferredRemotePayload: payload,
            pendingAction: retainsLocalChanges ? .save : nil,
            updatedAt: record.modificationDate ?? Date()
        ))
        if retainsLocalChanges {
            syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
        status = .syncing
    }

    /// Replays dependency-sensitive CloudKit records from durable metadata.
    /// Internal visibility keeps the replay contract directly testable without
    /// exposing a product API or requiring a live iCloud account in CI.
    /// Returns TRUE when a durable deferred payload actually became this
    /// device's configuration; a payload still waiting on its dependency
    /// returns FALSE (it remains durable, never silently dropped).
    @discardableResult
    func retryDeferredRecords() async throws -> Bool {
        var applied = try await retryDeferredModels()
        applied = (try await retryDeferredPreferences()) || applied
        return applied
    }

    @discardableResult
    private func retryDeferredModels() async throws -> Bool {
        guard let metadataStore, let configurationStore else { return false }
        var applied = false
        for metadata in try await metadataStore.deferred(recordType: ConfigSyncRecordType.modelProfile.rawValue) {
            guard let payload = metadata.deferredRemotePayload else { continue }
            let remote = try Self.validatedRemoteModel(payload)
            let local = try await configurationStore.model(id: remote.id)
            var merged = remote
            if metadata.pendingAction == .save, let local {
                // A user may have edited the model while its provider was
                // being restored. Do not replay a deferred snapshot over
                // that newer, still-pending capability decision.
                merged.capabilities = local.capabilities
                merged.explicitCapabilities = local.explicitCapabilities
            }
            let model = try Self.preservingCapabilityDecisions(
                merged: merged, local: local, remote: remote
            )
            guard model.providerID != ProviderProfile.onDeviceProviderID,
                  try await configurationStore.provider(id: model.providerID) != nil else { continue }
            try await configurationStore.saveModel(model)
            applied = true
            var appliedMetadata = metadata
            appliedMetadata.deferredRemotePayload = nil
            try await metadataStore.save(appliedMetadata)
        }
        return applied
    }

    @discardableResult
    private func retryDeferredPreferences() async throws -> Bool {
        guard let metadataStore, let configurationStore,
              var metadata = try await metadataStore.metadata(
                recordType: ConfigSyncRecordType.preference.rawValue,
                recordID: "default"
              ),
              let payload = metadata.deferredRemotePayload else { return false }
        let remote = Self.withoutDeviceLocalModels(
            try JSONDecoder.floe.decode(ModelSelectionPreferences.self, from: payload)
        )
        let local = try await configurationStore.preferences()
        let restored = Self.restoringDeviceLocalModels(remote, from: local)
        guard try await missingModelIDs(in: restored).isEmpty else { return false }
        try await configurationStore.savePreferences(restored)
        metadata.deferredRemotePayload = nil
        try await metadataStore.save(metadata)
        return true
    }

    private func missingModelIDs(in preferences: ModelSelectionPreferences) async throws -> Set<UUID> {
        guard let configurationStore else { return [] }
        let selected = Set([
            preferences.defaultAgentModelID,
            preferences.generalAuxiliaryLLMModelID,
            preferences.canvasAgentModelID,
            preferences.visionModelID,
            preferences.canvasVisionModelID,
            preferences.approvalModelID,
            preferences.packageReviewModelID,
            preferences.sharedImageModelID,
            preferences.imageGenerationModelID,
            preferences.imageEditingModelID,
            preferences.defaultVideoModelID
        ].compactMap { $0 })
        var missing: Set<UUID> = []
        for id in selected where try await configurationStore.model(id: id) == nil {
            missing.insert(id)
        }
        return missing
    }

    private static func withoutDeviceLocalModels(
        _ value: ModelSelectionPreferences
    ) -> ModelSelectionPreferences {
        var value = value
        if value.defaultAgentModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.defaultAgentModelID = nil
        }
        if value.generalAuxiliaryLLMModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.generalAuxiliaryLLMModelID = nil
        }
        if value.canvasAgentModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.canvasAgentModelID = nil
        }
        if value.visionModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.visionModelID = nil
        }
        if value.canvasVisionModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.canvasVisionModelID = nil
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
        if value.defaultVideoModelID.map(ProviderProfile.onDeviceModelIDs.contains) == true {
            value.defaultVideoModelID = nil
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
        value.generalAuxiliaryLLMModelID = deviceValue(local.generalAuxiliaryLLMModelID) ?? value.generalAuxiliaryLLMModelID
        value.canvasAgentModelID = deviceValue(local.canvasAgentModelID) ?? value.canvasAgentModelID
        value.visionModelID = deviceValue(local.visionModelID) ?? value.visionModelID
        value.canvasVisionModelID = deviceValue(local.canvasVisionModelID) ?? value.canvasVisionModelID
        value.approvalModelID = deviceValue(local.approvalModelID) ?? value.approvalModelID
        value.packageReviewModelID = deviceValue(local.packageReviewModelID) ?? value.packageReviewModelID
        value.sharedImageModelID = deviceValue(local.sharedImageModelID) ?? value.sharedImageModelID
        value.imageGenerationModelID = deviceValue(local.imageGenerationModelID) ?? value.imageGenerationModelID
        value.imageEditingModelID = deviceValue(local.imageEditingModelID) ?? value.imageEditingModelID
        value.defaultVideoModelID = deviceValue(local.defaultVideoModelID) ?? value.defaultVideoModelID
        return value
    }

    /// Applies one fetched remote tombstone. Returns TRUE when this device's
    /// observable configuration actually changed; a deletion of an
    /// unknown-type record only tombstones metadata and returns FALSE.
    @discardableResult
    private func applyRemoteDeletion(recordID: CKRecord.ID, recordType: String) async throws -> Bool {
        guard let type = ConfigSyncRecordType(rawValue: recordType),
              let configurationStore,
              let metadataStore
        else { return false }
        var didStore = false
        defer { if didStore { signalRemoteConfigurationApplied() } }
        switch type {
        case .providerProfile:
            if let uuid = UUID(uuidString: recordID.recordName) {
                try await configurationStore.deleteProvider(id: uuid)
                didStore = true
            }
        case .modelProfile:
            if let uuid = UUID(uuidString: recordID.recordName) {
                try await configurationStore.deleteModel(id: uuid)
                didStore = true
            }
        case .preference:
            let local = try await configurationStore.preferences()
            try await configurationStore.savePreferences(
                Self.restoringDeviceLocalModels(ModelSelectionPreferences(), from: local)
            )
            didStore = true
        case .remoteHostProfile:
            if let uuid = UUID(uuidString: recordID.recordName), let remoteHostStore {
                try await remoteHostStore.deleteHost(id: uuid)
                didStore = true
            }
        case .credentialDescriptor:
            if let uuid = UUID(uuidString: recordID.recordName), let credentialStore {
                try await credentialStore.delete(id: uuid)
                didStore = true
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
        return didStore
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

    /// User-facing status when an untrusted remote record failed validation.
    /// States the actual outcome precisely: the LOCAL original was retained
    /// and the REMOTE update was skipped — it must never read as if the
    /// rejected remote configuration had been persisted. Bilingual at the
    /// sync boundary; the App catalog may override via
    /// `providers.sync.rejected_remote` (see T1 integration patch in REPORT).
    private static var rejectedRemoteMessage: String {
        FloeL10n.isChinese
            ? "部分云端配置未通过校验：已保留本机原有配置，并跳过该条云端更新；被拒绝的记录不会写入本机，也不会被确认"
            : "Some cloud configuration failed validation: the local copy on this device was kept and the remote update was skipped; the rejected record is neither saved here nor acknowledged"
    }

    /// Logs ONLY the stable record id and machine-readable reason tokens.
    /// Never logs the provider name, endpoint or headers.
    private static func logRejectedRemoteProvider(id: String, reason: String) {
        FloeLogger(category: .sync).warning(
            "rejected remote provider profile \(id): \(reason)"
        )
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
    /// corresponding secret on this device. Device-bound descriptors are
    /// excluded from the cloud delivery wait: their secret intentionally
    /// never leaves this device's local Keychain namespace, so the synced
    /// namespace will never receive it and awaiting it would freeze the
    /// status with no possible recovery.
    /// Shared by the batch epilogues AND the arrival monitor/`refreshStatusIfWaiting`
    /// seam: exactly one per-account truth, so a late arrival can resolve the
    /// wait without any new batch while one missing account still keeps every
    /// device waiting.
    private func credentialSyncStatus() async -> SyncStatus {
        let preferences = SyncControlPreferences.load(from: preferencesDefaults)
        if preferences.overallEnabled, let configurationStore,
           let providers = try? await configurationStore.providers() {
            for provider in providers {
                guard let reference = provider.secretRef, reference.synchronizable else { continue }
                if !(await secretPresent(
                    service: KeychainSecretStore.defaultService,
                    account: reference.keychainAccount,
                    synchronizable: true
                )) {
                    return .waitingForSecret
                }
            }
        }

        guard preferences.savedCredentialsEnabled,
              let credentialStore,
              let records = try? await credentialStore.records(owner: .vault)
        else { return .synced }
        // A device-bound record's secret (e.g. a Floe-generated SSH key
        // registered by RemoteSessionCenter) lives only in the local,
        // non-synchronizable namespace, and setSavedCredentialSyncEnabled
        // deliberately skips these records, so no iCloud Keychain delivery
        // can ever satisfy the synced-namespace read. Excluding them keeps
        // the honest waiting behavior for records that are genuinely
        // expected to arrive; their local presence is enforced at use time
        // by CredentialVaultService.resolveForApprovedUse instead.
        for record in records where record.synchronizable && !record.deviceBound {
            if !(await secretPresent(
                service: CredentialVaultService.serviceName,
                account: record.keychainAccount,
                synchronizable: true
            )) {
                return .waitingForSecret
            }
        }
        // A record the toggle had to leave behind is NOT synced: its
        // secret exists in no namespace on this device, so neither cloud
        // delivery nor a re-enable could complete it until the secret
        // returns HERE. Excluding such records would let the row claim
        // "synced" while an unsynchronizable credential sits unreported;
        // keeping the wait honest is the OBSERVABLE automatic route — the
        // engine-owned arrival monitor re-checks both namespaces through
        // this same computation and resolves the row the moment the user
        // re-adds the key (or deletes the record), after which the
        // settings retry publishes it (the manual route). Ordinary
        // local-only vault records (secret present in the local
        // namespace, e.g. a fresh capture) do not match and never wait.
        for record in records where !record.synchronizable && !record.deviceBound {
            if await secretPresent(
                service: CredentialVaultService.serviceName,
                account: record.keychainAccount,
                synchronizable: false
            ) { continue }
            if !(await secretPresent(
                service: CredentialVaultService.serviceName,
                account: record.keychainAccount,
                synchronizable: true
            )) {
                return .waitingForSecret
            }
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
