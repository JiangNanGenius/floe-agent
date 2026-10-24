import Foundation
import Testing
import FloeCore
import FloeSecurity
@testable import FloeSync
@testable import FloePersistence

/// Deterministic in-memory namespace store: exactly the `KeychainStore`
/// error surface (`itemNotFound` / `unexpectedStatus`) plus injection of
/// store failures and corrupted writes, with recorded call sequences so the
/// tests can prove idempotent retries and untouched secrets. No test in
/// this file touches the real Keychain or UserDefaults.standard; the vault
/// and engine receive isolated suites through their internal seams.
private final class FakeVaultSecretStore: VaultSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var storeErrors: [String: Error] = [:]
    private var corruptOnStore: Set<String> = []
    private var storeCalls_: [String] = []
    private var deleteCalls_: [String] = []

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func seed(_ account: String, _ secret: Data) {
        withLock { items[account] = secret }
    }
    func failStore(account: String, error: Error) {
        withLock { storeErrors[account] = error }
    }
    func clearStoreFailure(account: String) {
        withLock { storeErrors[account] = nil }
    }
    func corruptOnStore(account: String) {
        withLock { corruptOnStore.insert(account) }
    }
    func clearCorruption(account: String) {
        withLock { corruptOnStore.remove(account) }
    }
    var storeCalls: [String] { withLock { storeCalls_ } }
    var deleteCalls: [String] { withLock { deleteCalls_ } }
    func secret(for account: String) -> Data? { withLock { items[account] } }
    func hasSecret(for account: String) -> Bool { withLock { items[account] != nil } }

    func store(account: String, secret: Data) throws {
        try withLock {
            storeCalls_.append(account)
            if let error = storeErrors[account] { throw error }
            items[account] = corruptOnStore.contains(account)
                ? Data("unverified-\(account)".utf8)
                : secret
        }
    }

    func read(account: String) throws -> Data {
        try withLock {
            guard let data = items[account] else { throw KeychainStoreError.itemNotFound }
            return data
        }
    }

    func delete(account: String) throws {
        try withLock {
            deleteCalls_.append(account)
            items.removeValue(forKey: account)
        }
    }
}

@Suite("Saved credential sync toggle")
struct CredentialSyncMigrationTests {
    /// Each test gets fresh in-memory record storage, fresh fake Keychain
    /// namespaces and a fresh private preferences suite — never `.standard`.
    private func makeFixture(savedCredentialsEnabled: Bool) async throws
        -> (vault: CredentialVaultService, credentials: CredentialStore, local: FakeVaultSecretStore, synced: FakeVaultSecretStore, preferences: UserDefaults, suite: String)
    {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let credentials = CredentialStore(database: database)
        let local = FakeVaultSecretStore()
        let synced = FakeVaultSecretStore()
        let suite = "org.floeagent.tests.vault-sync.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        var seed = SyncControlPreferences()
        seed.savedCredentialsEnabled = savedCredentialsEnabled
        seed.save(to: preferences)
        let vault = CredentialVaultService(
            records: credentials,
            local: local,
            synchronized: synced,
            preferencesSuite: suite
        )
        return (vault, credentials, local, synced, preferences, suite)
    }

    /// Deterministic cleanup of the isolated suite: no trace is left in the
    /// real App preferences (`.standard` is never touched by these tests).
    private func tearDown(_ preferences: UserDefaults, suite: String) {
        preferences.removePersistentDomain(forName: suite)
    }

    // MARK: - Enable: missing secret must not abort or misrepresent

    /// The reported failure: enabling aborted on the FIRST vault record
    /// whose local secret was missing (a metadata record ahead of its
    /// secret), leaving every other credential unsynchronized, the switch
    /// off, and a raw "Not found" error — while records migrated earlier in
    /// the same loop were already orphaned behind the off switch. Now: the
    /// available records all migrate, the missing one stays untouched and
    /// honestly waiting, and the committed switch matches the moved secrets.
    @Test("Enable migrates available records around a missing-secret record")
    func enableSkipsMissingWithoutAbortingOrOverstating() async throws {
        let (vault, credentials, local, synced, preferences, suite) = try await makeFixture(savedCredentialsEnabled: false)
        defer { tearDown(preferences, suite: suite) }

        // The metadata-only record comes first in the store iteration —
        // the exact abort point of the old throw-on-first-missing behavior.
        let stranded = CredentialRecord(
            kind: .genericToken, owner: .vault, label: "Descriptor arrived first",
            synchronizable: false
        )
        try await credentials.save(stranded)
        let first = try await vault.capture(
            Data("secret-one".utf8), kind: .websitePassword, owner: .vault, label: "One"
        )
        let second = try await vault.capture(
            Data("secret-two".utf8), kind: .sshPrivateKey, owner: .vault, label: "Two"
        )
        let firstAccount = try #require(try await credentials.record(id: first.id)).keychainAccount
        let secondAccount = try #require(try await credentials.record(id: second.id)).keychainAccount

        let outcome = try await vault.setSavedCredentialSyncEnabled(true)
        #expect(outcome == SavedCredentialSyncOutcome(
            migrated: 2, missingOnDevice: 1, failed: 0, preferenceCommitted: true
        ))

        // Migrated records: destination verified, source removed, metadata
        // flipped — and nothing was claimed for the stranded record.
        #expect(synced.secret(for: firstAccount) == Data("secret-one".utf8))
        #expect(synced.secret(for: secondAccount) == Data("secret-two".utf8))
        #expect(local.secret(for: firstAccount) == nil)
        #expect(local.secret(for: secondAccount) == nil)
        let strandedRecord = try #require(try await credentials.record(id: stranded.id))
        #expect(!strandedRecord.synchronizable)
        #expect(!local.hasSecret(for: stranded.keychainAccount))
        #expect(!synced.hasSecret(for: stranded.keychainAccount))

        // The switch now agrees with the two moved secrets.
        #expect(SyncControlPreferences.load(from: preferences).savedCredentialsEnabled)

        // Honest per-record observation: migrated rows are synced, the
        // stranded row is waiting — not marked synced, not deleted.
        #expect(await vault.status(strandedRecord) == .waitingForSecret)
        #expect(await vault.status(try #require(try await credentials.record(id: first.id))) == .synced)

        // Retry is idempotent once the secret is re-added on this device:
        // already-migrated rows are skipped (no new writes), and exactly
        // the repaired record completes and publishes.
        local.seed(stranded.keychainAccount, Data("secret-readded".utf8))
        let storeWritesBefore = synced.storeCalls.count
        let retry = try await vault.setSavedCredentialSyncEnabled(true)
        #expect(retry == SavedCredentialSyncOutcome(
            migrated: 1, missingOnDevice: 0, failed: 0, preferenceCommitted: true
        ))
        #expect(synced.storeCalls.count == storeWritesBefore + 1)
        #expect(synced.secret(for: stranded.keychainAccount) == Data("secret-readded".utf8))
        let completed = try #require(try await credentials.record(id: stranded.id))
        #expect(completed.synchronizable)
        #expect(local.secret(for: stranded.keychainAccount) == nil)
    }

    // MARK: - Crash recovery / repeated migration

    /// A previous pass verified the destination copy but died before the
    /// metadata flip (and after the source delete): the retry completes the
    /// flip only, leaving the bytes untouched, and a second pass is a
    /// provable no-op.
    @Test("Destination already holding the secret completes idempotently")
    func destinationHoldsSecretCompletesPass() async throws {
        let (vault, credentials, local, synced, preferences, suite) = try await makeFixture(savedCredentialsEnabled: false)
        defer { tearDown(preferences, suite: suite) }

        let interrupted = CredentialRecord(
            kind: .genericToken, owner: .vault, label: "Crashed after destination store",
            synchronizable: false
        )
        try await credentials.save(interrupted)
        let bytes = Data("already-delivered".utf8)
        synced.seed(interrupted.keychainAccount, bytes)

        let alreadyMigrated = CredentialRecord(
            kind: .websitePassword, owner: .vault, label: "Already synced",
            synchronizable: true
        )
        try await credentials.save(alreadyMigrated)
        synced.seed(alreadyMigrated.keychainAccount, Data("synced-long-ago".utf8))

        let writesBefore = synced.storeCalls.count + local.storeCalls.count
        let deletesBefore = synced.deleteCalls.count + local.deleteCalls.count

        let outcome = try await vault.setSavedCredentialSyncEnabled(true)
        #expect(outcome == SavedCredentialSyncOutcome(
            migrated: 1, missingOnDevice: 0, failed: 0, preferenceCommitted: true
        ))
        #expect(try #require(try await credentials.record(id: interrupted.id)).synchronizable)
        #expect(try #require(try await credentials.record(id: alreadyMigrated.id)).synchronizable)
        // The delivered bytes are NOT rewritten or deleted during completion.
        #expect(synced.secret(for: interrupted.keychainAccount) == bytes)

        // Second enable: every record already matches — zero further store
        // or delete traffic (idempotent retry, no churn).
        let again = try await vault.setSavedCredentialSyncEnabled(true)
        #expect(again == SavedCredentialSyncOutcome(
            migrated: 0, missingOnDevice: 0, failed: 0, preferenceCommitted: true
        ))
        #expect(synced.storeCalls.count + local.storeCalls.count == writesBefore)
        #expect(synced.deleteCalls.count + local.deleteCalls.count == deletesBefore)
    }

    // MARK: - Real store errors: actionable, preserved, recoverable

    /// A genuine destination-store error on a MIDDLE record must not abort
    /// the rest, must preserve the source secret AND an independently valid
    /// pre-existing destination copy, and must not commit a fully failed
    /// enable. After the transient error clears, the retry completes.
    @Test("Store failure preserves source and pre-existing destination")
    func storeFailurePreservesBothCopies() async throws {
        let (vault, credentials, local, synced, preferences, suite) = try await makeFixture(savedCredentialsEnabled: false)
        defer { tearDown(preferences, suite: suite) }

        let before = try await vault.capture(
            Data("moves-first".utf8), kind: .genericToken, owner: .vault, label: "Before"
        )
        let beforeAccount = try #require(try await credentials.record(id: before.id)).keychainAccount

        let failing = CredentialRecord(
            kind: .genericToken, owner: .vault, label: "Store error",
            synchronizable: false
        )
        try await credentials.save(failing)
        // Independent valid synced copy under the SAME account: a failed
        // write must restore this, never delete it.
        let priorSyncedBytes = Data("independent-synced-credential".utf8)
        synced.seed(failing.keychainAccount, priorSyncedBytes)
        let sourceBytes = Data("local-authoritative".utf8)
        local.seed(failing.keychainAccount, sourceBytes)
        synced.failStore(
            account: failing.keychainAccount,
            error: KeychainStoreError.unexpectedStatus("simulated keychain unavailable")
        )

        let after = try await vault.capture(
            Data("moves-anyway".utf8), kind: .websitePassword, owner: .vault, label: "After"
        )
        let afterAccount = try #require(try await credentials.record(id: after.id)).keychainAccount

        let outcome = try await vault.setSavedCredentialSyncEnabled(true)
        // The middle failure neither aborts nor overstates: both neighbors
        // migrated, this record failed, the switch commits because secrets
        // really did move.
        #expect(outcome.migrated == 2)
        #expect(outcome.failed == 1)
        #expect(outcome.missingOnDevice == 0)
        #expect(outcome.preferenceCommitted)
        #expect(synced.secret(for: beforeAccount) == Data("moves-first".utf8))
        #expect(synced.secret(for: afterAccount) == Data("moves-anyway".utf8))

        // The failed record keeps EVERYTHING: source secret intact, prior
        // destination copy restored (the failed fake store threw before
        // writing; the restore path must not delete it either), metadata
        // unchanged.
        #expect(local.secret(for: failing.keychainAccount) == sourceBytes)
        #expect(synced.secret(for: failing.keychainAccount) == priorSyncedBytes)
        #expect(!(try #require(try await credentials.record(id: failing.id)).synchronizable))
        // The pre-existing copy was restored-or-untouched, never deleted.
        #expect(!synced.deleteCalls.contains(failing.keychainAccount))

        // Retry after the transient error clears completes exactly the
        // failed record (the migrated ones are skipped without rewrites).
        synced.clearStoreFailure(account: failing.keychainAccount)
        let writesBefore = synced.storeCalls.count
        let retry = try await vault.setSavedCredentialSyncEnabled(true)
        #expect(retry == SavedCredentialSyncOutcome(
            migrated: 1, missingOnDevice: 0, failed: 0, preferenceCommitted: true
        ))
        #expect(synced.storeCalls.count == writesBefore + 1)
        #expect(synced.secret(for: failing.keychainAccount) == sourceBytes)
        #expect(try #require(try await credentials.record(id: failing.id)).synchronizable)
    }

    /// A verification mismatch must leave NO unverified destination bytes
    /// behind when the destination did not exist before, must keep the
    /// source, and when it is the only record the enable must not commit —
    /// the switch cannot claim what did not happen.
    @Test("Verification failure removes only unverified copy and blocks empty commit")
    func verificationFailureLeavesCleanState() async throws {
        let (vault, credentials, local, synced, preferences, suite) = try await makeFixture(savedCredentialsEnabled: false)
        defer { tearDown(preferences, suite: suite) }

        let record = CredentialRecord(
            kind: .genericToken, owner: .vault, label: "Corrupt write",
            synchronizable: false
        )
        try await credentials.save(record)
        local.seed(record.keychainAccount, Data("good-bytes".utf8))
        synced.corruptOnStore(account: record.keychainAccount)

        let outcome = try await vault.setSavedCredentialSyncEnabled(true)
        #expect(outcome == SavedCredentialSyncOutcome(
            migrated: 0, missingOnDevice: 0, failed: 1, preferenceCommitted: false
        ))
        #expect(local.secret(for: record.keychainAccount) == Data("good-bytes".utf8))
        // Unverified bytes never persist: no presence a status read could
        // mistake for an arrived secret.
        #expect(!synced.hasSecret(for: record.keychainAccount))
        #expect(!(try #require(try await credentials.record(id: record.id)).synchronizable))
        #expect(!SyncControlPreferences.load(from: preferences).savedCredentialsEnabled)

        // Repaired retry completes the migration and commits then.
        synced.clearCorruption(account: record.keychainAccount)
        let retry = try await vault.setSavedCredentialSyncEnabled(true)
        #expect(retry == SavedCredentialSyncOutcome(
            migrated: 1, missingOnDevice: 0, failed: 0, preferenceCommitted: true
        ))
        #expect(SyncControlPreferences.load(from: preferences).savedCredentialsEnabled)
        #expect(local.secret(for: record.keychainAccount) == nil)
    }

    // MARK: - Disable direction

    /// Disabling always commits (stopping synchronization is unconditional)
    /// and moves delivered secrets back, while a descriptor whose synced
    /// secret never arrived is preserved untouched — no deletion, no
    /// overwrite, honest counts. Device-bound records are never touched.
    @Test("Disable moves delivered secrets and preserves never-arrived records")
    func disableMigratesBackAndKeepsHonest() async throws {
        let (vault, credentials, local, synced, preferences, suite) = try await makeFixture(savedCredentialsEnabled: true)
        defer { tearDown(preferences, suite: suite) }

        let delivered = CredentialRecord(
            kind: .websitePassword, owner: .vault, label: "Synced credential",
            synchronizable: true
        )
        try await credentials.save(delivered)
        let deliveredBytes = Data("move-me-back".utf8)
        synced.seed(delivered.keychainAccount, deliveredBytes)

        let neverArrived = CredentialRecord(
            kind: .genericToken, owner: .vault, label: "Descriptor without secret",
            synchronizable: true
        )
        try await credentials.save(neverArrived)

        let deviceBound = CredentialRecord(
            kind: .sshPrivateKey, owner: .vault, label: "Device-bound key",
            synchronizable: true, deviceBound: true
        )
        try await credentials.save(deviceBound)

        let outcome = try await vault.setSavedCredentialSyncEnabled(false)
        #expect(outcome == SavedCredentialSyncOutcome(
            migrated: 1, missingOnDevice: 1, failed: 0, preferenceCommitted: true
        ))
        #expect(local.secret(for: delivered.keychainAccount) == deliveredBytes)
        #expect(!synced.hasSecret(for: delivered.keychainAccount))
        #expect(!(try #require(try await credentials.record(id: delivered.id)).synchronizable))
        // Never-arrived and device-bound records are untouched.
        #expect(try #require(try await credentials.record(id: neverArrived.id)).synchronizable)
        #expect(try #require(try await credentials.record(id: deviceBound.id)).synchronizable)
        #expect(SyncControlPreferences.load(from: preferences).savedCredentialsEnabled == false)

        // A local-namespace copy the earlier interrupted pass left behind
        // makes the disable complete flip-only (recovery, no data change).
        let interruptedBack = CredentialRecord(
            kind: .genericToken, owner: .vault, label: "Crashed after local store",
            synchronizable: true
        )
        try await credentials.save(interruptedBack)
        local.seed(interruptedBack.keychainAccount, Data("already-local".utf8))
        // The never-arrived descriptor is reported again honestly — it is
        // still not synced and still not deleted — while the recovered
        // record completes without touching its bytes.
        let retry = try await vault.setSavedCredentialSyncEnabled(false)
        #expect(retry == SavedCredentialSyncOutcome(
            migrated: 1, missingOnDevice: 1, failed: 0, preferenceCommitted: true
        ))
        #expect(local.secret(for: interruptedBack.keychainAccount) == Data("already-local".utf8))
        #expect(!(try #require(try await credentials.record(id: interruptedBack.id)).synchronizable))
        #expect(try #require(try await credentials.record(id: neverArrived.id)).synchronizable)
        #expect(!local.hasSecret(for: neverArrived.keychainAccount))
        #expect(!synced.hasSecret(for: neverArrived.keychainAccount))
    }

    // MARK: - Engine observability for left-behind records

    #if canImport(CloudKit)
    /// The status path must not report "synced" while a non-device-bound
    /// vault record has no secret in either namespace (the permanently
    /// excluded case). Injecting the secret re-observes to synced through
    /// the same computation the arrival monitor uses; a record that only
    /// lacks cloud delivery keeps waiting exactly as before.
    @Test("Engine reports waiting for left-behind records and resolves on arrival")
    func engineObservesLeftBehindRecords() async throws {
        let (vault, credentials, local, synced, preferences, suite) = try await makeFixture(savedCredentialsEnabled: false)
        defer { tearDown(preferences, suite: suite) }

        let migrated = try await vault.capture(
            Data("fine".utf8), kind: .genericToken, owner: .vault, label: "Fine"
        )
        let stranded = CredentialRecord(
            kind: .genericToken, owner: .vault, label: "Stranded descriptor",
            synchronizable: false
        )
        try await credentials.save(stranded)
        let outcome = try await vault.setSavedCredentialSyncEnabled(true)
        #expect(outcome == SavedCredentialSyncOutcome(
            migrated: 1, missingOnDevice: 1, failed: 0, preferenceCommitted: true
        ))
        #expect(try #require(try await credentials.record(id: migrated.id)).synchronizable)

        let engine = ConfigSyncEngine(credentialStore: credentials)
        await engine.replacePreferencesDefaultsForTesting(suite: suite)
        await engine.replaceSecretExistenceReaderForTesting { _, account, synchronizable in
            synchronizable
                ? synced.hasSecret(for: account)
                : local.hasSecret(for: account)
        }

        // Before the fix this returned `.synced` while the stranded record
        // was silently excluded. The row now waits honestly.
        #expect(await engine.batchCompletionStatus() == .waitingForSecret)

        // Automatic route: the user re-adds the secret on this device, the
        // same per-account computation (arrival monitor / refresh seam)
        // resolves the wait without claiming the record is synchronized.
        local.seed(stranded.keychainAccount, Data("readded".utf8))
        #expect(await engine.batchCompletionStatus() == .synced)

        // Manual route: the retry toggle publishes the record into the
        // synchronizable namespace…
        let retry = try await vault.setSavedCredentialSyncEnabled(true)
        #expect(retry == SavedCredentialSyncOutcome(
            migrated: 1, missingOnDevice: 0, failed: 0, preferenceCommitted: true
        ))
        #expect(await engine.batchCompletionStatus() == .synced)

        // …and the pre-existing honest wait for a published record whose
        // iCloud Keychain copy has not arrived still holds through the
        // same computation (no local-namespace credit).
        try synced.delete(account: stranded.keychainAccount)
        #expect(await engine.batchCompletionStatus() == .waitingForSecret)
    }
    #endif
}
