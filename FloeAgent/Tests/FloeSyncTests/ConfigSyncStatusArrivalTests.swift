// FloeSync — regression coverage for the stale "Waiting for iCloud Keychain"
// status defect (job-502f9a8bf7f4479a, 2026-10-24).
//
// CloudKit configuration records and iCloud Keychain secrets arrive
// independently. Before the fix, `ConfigSyncEngine.status` was recomputed
// ONLY inside batch epilogues, so a `.waitingForSecret` cached after the last
// batch stayed frozen forever once the engine had no further CloudKit work —
// even after every pending secret had actually arrived and the providers
// worked. The settings screen (via SettingsCenter.load → engine.status) kept
// showing "waiting for iCloud Keychain".
//
// These tests drive the REAL engine status paths (`batchCompletionStatus`,
// `markWaitingForSecret`, `refreshStatusIfWaiting`, the engine-owned arrival
// monitor) through a delayed, controllable existence seam so no device
// Keychain, secrets or network access is involved. The seam reports
// EXISTENCE only; no secret material — not even synthetic bytes — exists
// anywhere in this file.
//
// They also pin the actor-reentrancy contract required by the primary's diff
// review: a credential computation that is suspended mid-flight must never
// overwrite a pause/disable/new-error/new-batch state published while it was
// awaiting.

#if canImport(CloudKit)

import Foundation
import Testing
import FloeCore
@testable import FloeSync
@testable import FloePersistence

/// Existence-only stand-in for the synchronizable Keychain namespace.
/// Accounts are UUID-derived strings; nothing here holds secret material.
private final class SecretPresence: @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: Set<String>
    private var recordedProbes: [(service: String, account: String, synchronizable: Bool)] = []

    init(_ accounts: Set<String> = []) {
        self.accounts = accounts
    }

    func insert(_ account: String) {
        lock.lock(); accounts.insert(account); lock.unlock()
    }

    func remove(_ account: String) {
        lock.lock(); accounts.remove(account); lock.unlock()
    }

    var probes: [(service: String, account: String, synchronizable: Bool)] {
        lock.lock(); defer { lock.unlock() }; return recordedProbes
    }

    func contains(service: String, account: String, synchronizable: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        recordedProbes.append((service, account, synchronizable))
        return accounts.contains(account)
    }
}

/// Deterministic rendezvous that suspends ONE gated existence read until the
/// test has published a competing lifecycle transition, proving the epoch
/// fence instead of relying on wall-clock races.
private actor ReadGate {
    private var gatedAccount: String?
    private var armed = false
    private var enterSignals = 0
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseSignals = 0
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arm(account: String) {
        gatedAccount = account
        armed = true
    }

    /// Called by the existence seam. The first read of the gated account
    /// signals entry and suspends until released; later reads pass through.
    func gatedRead(account: String) async {
        guard armed, account == gatedAccount else { return }
        armed = false
        if let waiter = enterWaiters.first {
            enterWaiters.removeFirst()
            waiter.resume()
        } else {
            enterSignals += 1
        }
        if releaseSignals > 0 {
            releaseSignals -= 1
            return
        }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if enterSignals > 0 {
            enterSignals -= 1
            return
        }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func release() {
        if let waiter = releaseWaiters.first {
            releaseWaiters.removeFirst()
            waiter.resume()
        } else {
            releaseSignals += 1
        }
    }
}

@Suite("Config sync status arrival", .serialized)
struct ConfigSyncStatusArrivalTests {
    /// Builds an engine over in-memory stores with the sync switches set by
    /// the caller, a controllable secret-presence seam (optionally gating one
    /// account behind a ReadGate), and restores the standard-defaults
    /// preferences afterwards — the same seam shape the pre-existing
    /// CredentialDescriptorSyncTests suite uses.
    private func makeEngine(
        savedCredentialsEnabled: Bool,
        presence: SecretPresence,
        gate: ReadGate? = nil
    ) async throws -> (ConfigSyncEngine, ModelConfigurationStore, SyncControlPreferences) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let credentials = CredentialStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let configuration = ModelConfigurationStore(database: database)
        let engine = ConfigSyncEngine(
            configurationStore: configuration,
            metadataStore: metadata,
            credentialStore: credentials
        )
        let previousPreferences = SyncControlPreferences.load()
        SyncControlPreferences(
            overallEnabled: true,
            configurationEnabled: true,
            savedCredentialsEnabled: savedCredentialsEnabled
        ).save()
        await engine.replaceSecretExistenceReaderForTesting { [presence, gate] service, account, synchronizable in
            if let gate {
                await gate.gatedRead(account: account)
            }
            return presence.contains(
                service: service,
                account: account,
                synchronizable: synchronizable
            )
        }
        return (engine, configuration, previousPreferences)
    }

    private func syncableProvider() -> ProviderProfile {
        ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://sync-status.test/v1")!,
            secretRef: SecretReference(
                keychainAccount: "provider.\(UUID().uuidString)",
                synchronizable: true
            )
        )
    }

    /// Core regression: a cached `.waitingForSecret` (exactly what the user
    /// saw after the last batch) resolves through the same honest
    /// per-account computation as soon as the LAST pending secret arrives,
    /// with no CloudKit batch in sight. One of two accounts arriving must
    /// NOT clear the status ("all ready on the first credential" is the
    /// anti-pattern this preserves the guard against).
    @Test("Stale waiting resolves only after every pending provider account arrives")
    func staleWaitingResolvesOnLateArrival() async throws {
        let presence = SecretPresence()
        let (engine, configuration, previousPreferences) = try await makeEngine(
            savedCredentialsEnabled: false,
            presence: presence
        )
        defer { previousPreferences.save() }

        let first = syncableProvider()
        let second = syncableProvider()
        try await configuration.saveProvider(first)
        try await configuration.saveProvider(second)
        let firstAccount = try #require(first.secretRef?.keychainAccount)
        let secondAccount = try #require(second.secretRef?.keychainAccount)

        // Batch-epilogue truth with two synced refs pending.
        #expect(await engine.batchCompletionStatus() == .waitingForSecret)
        // The cached state the stale UI displayed after the final batch.
        await engine.markWaitingForSecret()
        #expect(await engine.status == .waitingForSecret)

        // Late arrival #1 of two: still honestly waiting.
        presence.insert(firstAccount)
        #expect(await engine.refreshStatusIfWaiting() == .waitingForSecret)

        // Late arrival #2 of two: resolved without any CloudKit batch.
        presence.insert(secondAccount)
        #expect(await engine.refreshStatusIfWaiting() == .synced)
        #expect(await engine.status == .synced)

        // The refresh only ever acts on a wait: a healthy `.synced` is never
        // downgraded by a screen visit (removal detection stays owned by the
        // batch epilogues, exactly as before).
        presence.remove(secondAccount)
        #expect(await engine.refreshStatusIfWaiting() == .synced)
    }

    /// The engine-owned monitor — not the settings screen — eventually
    /// resolves the wait when a secret lands while no view and no CloudKit
    /// batch is active (steady state after the last configuration change).
    @Test("Arrival monitor resolves a cached wait without any batch or UI")
    func monitorResolvesLateArrivalWithoutManualRefresh() async throws {
        let presence = SecretPresence()
        let (engine, configuration, previousPreferences) = try await makeEngine(
            savedCredentialsEnabled: false,
            presence: presence
        )
        defer { previousPreferences.save() }

        let provider = syncableProvider()
        try await configuration.saveProvider(provider)
        let account = try #require(provider.secretRef?.keychainAccount)

        await engine.markWaitingForSecret()
        #expect(await engine.status == .waitingForSecret)

        // The secret arrives after the last batch. No refresh call, no view.
        presence.insert(account)

        var current = await engine.status
        let deadline = Date().addingTimeInterval(8)
        while current == .waitingForSecret, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            current = await engine.status
        }
        #expect(current == .synced)
    }

    /// Cancellation and isolation: any transition out of the wait cancels
    /// the monitor, and neither the monitor nor a screen visit may overwrite
    /// a paused (account unavailable / user-paused) state with a
    /// credentials-arrived conclusion.
    @Test("Any non-waiting transition cancels the arrival monitor")
    func pausedStateSurvivesLateArrival() async throws {
        let presence = SecretPresence()
        let (engine, configuration, previousPreferences) = try await makeEngine(
            savedCredentialsEnabled: false,
            presence: presence
        )
        defer { previousPreferences.save() }

        let provider = syncableProvider()
        try await configuration.saveProvider(provider)
        let account = try #require(provider.secretRef?.keychainAccount)

        await engine.markWaitingForSecret()
        // A user pause / account change transitions to .paused, which must
        // cancel the running monitor.
        await engine.setSynchronizationEnabled(false)
        #expect(await engine.status == .paused)

        presence.insert(account)
        // Past the monitor's first tick: the cancelled monitor must not
        // resurrect or promote the paused state.
        try? await Task.sleep(for: .seconds(3))
        #expect(await engine.status == .paused)
        #expect(await engine.refreshStatusIfWaiting() == .paused)
    }

    /// Actor-reentrancy regression (primary review): a credential
    /// computation suspended mid-flight must never overwrite a pause
    /// published while it awaited. The gated read holds the computation
    /// inside `batchCompletionStatus()`, the test pauses the engine, and the
    /// released computation must discard its now-stale `.synced` conclusion.
    @Test("Mid-compute pause is never overwritten by a stale synced conclusion")
    func pauseLandingMidComputeSurvivesEpochFence() async throws {
        let presence = SecretPresence()
        let gate = ReadGate()
        let (engine, configuration, previousPreferences) = try await makeEngine(
            savedCredentialsEnabled: false,
            presence: presence,
            gate: gate
        )
        defer { previousPreferences.save() }

        let provider = syncableProvider()
        try await configuration.saveProvider(provider)
        let account = try #require(provider.secretRef?.keychainAccount)
        await gate.arm(account: account)

        await engine.markWaitingForSecret()
        let refreshTask = Task { await engine.refreshStatusIfWaiting() }
        await gate.waitUntilEntered()

        // The lifecycle transition lands WHILE the existence read is suspended.
        await engine.setSynchronizationEnabled(false)
        // Even if the secret really arrives now, the in-flight computation may
        // not resurrect a promoted state; only a fresh wait may conclude it.
        presence.insert(account)
        await gate.release()

        let returned = await refreshTask.value
        #expect(returned == .paused)
        #expect(await engine.status == .paused)

        // Past the monitor tick budget: nothing re-enters a promoted state
        // behind the pause.
        try? await Task.sleep(for: .seconds(1.5))
        #expect(await engine.status == .paused)
    }

    /// Actor-reentrancy regression (primary review): a NEW batch epilogue
    /// re-asserting the wait mid-compute advances the epoch — the stale
    /// conclusion must be re-derived against current inputs, and the running
    /// task must keep serving as the monitor for the new cycle instead of
    /// exiting and freezing the status without a watching task.
    @Test("Mid-compute re-entry of the wait re-derives instead of freezing or stomping")
    func waitingReentryMidComputeKeepsWatching() async throws {
        let presence = SecretPresence()
        let gate = ReadGate()
        let (engine, configuration, previousPreferences) = try await makeEngine(
            savedCredentialsEnabled: false,
            presence: presence,
            gate: gate
        )
        defer { previousPreferences.save() }

        let provider = syncableProvider()
        try await configuration.saveProvider(provider)
        let account = try #require(provider.secretRef?.keychainAccount)
        await gate.arm(account: account)

        await engine.markWaitingForSecret()
        let refreshTask = Task { await engine.refreshStatusIfWaiting() }
        await gate.waitUntilEntered()

        // A new epilogue re-asserts the SAME wait while the first computation
        // is suspended, and the secret arrives afterwards.
        await engine.markWaitingForSecret()
        presence.insert(account)
        await gate.release()

        let returned = await refreshTask.value
        #expect(returned == .synced)
        #expect(await engine.status == .synced)
    }

    /// The full observed UI lifecycle at the engine level: a first wait
    /// resolves to synced, NEW configuration re-enters the wait, and the new
    /// secret's late arrival resolves it again. This is the exact sequence
    /// the settings row must keep following; the monitor must restart from
    /// an already-resolved cycle rather than freezing again.
    @Test("A resolved cycle re-waiting on new configuration resolves again on late arrival")
    func resolvedCycleRewaitsAndResolvesAgain() async throws {
        let presence = SecretPresence()
        let (engine, configuration, previousPreferences) = try await makeEngine(
            savedCredentialsEnabled: false,
            presence: presence
        )
        defer { previousPreferences.save() }

        let first = syncableProvider()
        try await configuration.saveProvider(first)
        presence.insert(try #require(first.secretRef?.keychainAccount))

        await engine.markWaitingForSecret()
        var current = await engine.status
        var deadline = Date().addingTimeInterval(8)
        while current == .waitingForSecret, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            current = await engine.status
        }
        #expect(current == .synced)

        // New configuration arrives later: its synced secret is pending.
        let second = syncableProvider()
        try await configuration.saveProvider(second)
        #expect(await engine.batchCompletionStatus() == .waitingForSecret)
        await engine.markWaitingForSecret()
        #expect(await engine.status == .waitingForSecret)

        // Late arrival of the SECOND secret alone resolves the new cycle —
        // the monitor restarted from a previously-resolved synced state.
        presence.insert(try #require(second.secretRef?.keychainAccount))
        current = await engine.status
        deadline = Date().addingTimeInterval(8)
        while current == .waitingForSecret, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            current = await engine.status
        }
        #expect(current == .synced)
    }

    /// The vault branch uses the same per-account truth through the same
    /// seam: a synchronized non-device-bound descriptor that has not arrived
    /// keeps the wait; only full arrival clears it; probes go to the
    /// synchronizable namespace of the vault service (channel isolation).
    @Test("Vault descriptors keep per-account honest waiting through the same re-check")
    func vaultDescriptorArrivalIsHonestPerAccount() async throws {
        let presence = SecretPresence()
        let (engine, _, previousPreferences) = try await makeEngine(
            savedCredentialsEnabled: true,
            presence: presence
        )
        defer { previousPreferences.save() }

        let pendingPassphrase = CredentialRecord(
            kind: .sshPassword, owner: .vault, label: "Imported passphrase",
            synchronizable: true
        )
        try await engine.saveCredentialDescriptor(pendingPassphrase)

        #expect(await engine.batchCompletionStatus() == .waitingForSecret)
        await engine.markWaitingForSecret()
        #expect(await engine.refreshStatusIfWaiting() == .waitingForSecret)

        presence.insert(pendingPassphrase.keychainAccount)
        #expect(await engine.refreshStatusIfWaiting() == .synced)

        // Every existence probe for the vault account targeted the
        // synchronizable namespace — no local-namespace credit is given to a
        // record that is expected to arrive via iCloud Keychain (the waived
        // local-fallback decision is preserved; only genuinely absent
        // synced-namespace items keep the wait).
        let vaultProbes = presence.probes.filter {
            $0.account == pendingPassphrase.keychainAccount
        }
        #expect(!vaultProbes.isEmpty)
        #expect(vaultProbes.allSatisfy { $0.synchronizable })
        #expect(Set(presence.probes.map { $0.account }) == Set([pendingPassphrase.keychainAccount]))
    }
}

#endif
