// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 enhancer credential mutation — focused fault-injection tests
// (job-e5e786c723244725, AUTHORED NOT RUN in this lane).
//
// These tests close the PRIMARY_REVIEW remaining failures against the
// ORIGINAL authorities — no mirror SQL, no seeded fake authority:
//   * REAL FloePersistence stack: DatabaseManager.inMemory() + migrate(),
//     the original SQLiteSettingsStore and the original CredentialStore;
//   * REAL admitted coordination: CredentialVaultRuntimeAdmission.admit +
//     AndroidCredentialVault.joinRuntimeOwnership (full synthetic
//     RuntimeOwnerIdentity per test root) with a synthetic
//     VaultOwnedWorkAttaching (same contract as the real registry port);
//   * synthetic GATED gateway (recording + deterministic barriers) — the
//     ONLY synthetic in the credential paths.
//
// The save under test is the ONE sealed secure ingress -> ONE native owned
// save exchange: the store consumes a typed `SaveIntentLease` (exact closed
// `enhancerSave` subject, frozen secret-free candidate, key bytes) and
// performs EXACTLY ONE original `AndroidCredentialVault.capture` inside the
// shared coordinator's runtime-owned mutation lifetime, persists the row
// LAST and retires the previous credential through the ORIGINAL vault
// delete. The removed two-call staging adapter (mint/commit/discard) is gone
// with its lease-released-at-mint gap and its host blind-delete path.
//
// Authored proofs (acceptance-mapped):
//   * two independent roots sharing ONE physical gateway cannot read/send/
//     clear each other — ZERO cross-root gateway effects;
//   * forged candidates (pending shapes, smuggled identities, mismatched
//     rows) and cross-subject leases are refused before any effect;
//   * a sealed save performs EXACTLY ONE original vault capture write;
//   * settings-commit failure (also with a failed rollback gateway delete)
//     leaves the previous configuration AND credential byte-identical;
//   * commit-fence failure retires the just-captured credential and keeps
//     the previous state byte-identical;
//   * a root switch during save/clear refuses the stale caller typed and
//     never touches the newer owner; the original admission fence refuses
//     rebind-while-owned;
//   * concurrent save/revoke resolve serially on the shared coordinator
//     (controlled-barrier proof, both orders) without false success;
//   * truthful revoke through the original vault delete — an IMMEDIATE
//     retry BEFORE the deletion-queue drain still reports pending;
//   * metadata-READ errors while resolving the previous credential are
//     propagated (never collapsed into "no previous", never silently
//     committed/abandoned).
// The real-ffprobe probe/parser/output-guard regressions from the
// coordinator correction are preserved verbatim below.
import XCTest
import Foundation
import FloeCore
import FloePersistence
@testable import FloeAndroidCore

final class G09R2EnhancerCredentialMutationTests: XCTestCase {
    private typealias Store = G09R2EnhancerBackendConfigurationStore
    private typealias ConfigError = G09R2EnhancerBackendConfigurationStore.ConfigurationError

    // MARK: - Fakes (only the gateway + owned-work port are synthetic)

    private enum GatewayEffect: Equatable {
        case read(String)
        case write(String, Data)
        case delete(String)
    }

    /// Synthetic gated gateway: the ONLY synthetic in the credential paths.
    /// Records every effect and exposes deterministic pre-effect barriers.
    private final class FakeGateway: AndroidSecretGateway, @unchecked Sendable {
        private let lock = NSLock()
        private var records: [String: Data] = [:]
        private(set) var effects: [GatewayEffect] = []
        var failReads: Set<String> = []
        var failWrites: Set<String> = []
        var failDeletes: Set<String> = []
        /// Controlled pre-effect scheduling seams (test-only; never set by
        /// production code). Called before the effect, outside the lock.
        var beforeRead: (@Sendable (String) async -> Void)?
        var beforeWrite: (@Sendable (String) async -> Void)?
        var beforeDelete: (@Sendable (String) async -> Void)?

        private func hook<T>(_ keyPath: KeyPath<FakeGateway, T?>) -> T? {
            lock.lock(); defer { lock.unlock() }
            return self[keyPath: keyPath]
        }

        func snapshotEffects() -> [GatewayEffect] {
            lock.lock(); defer { lock.unlock() }
            return effects
        }

        func snapshotRecords() -> [String: Data] {
            lock.lock(); defer { lock.unlock() }
            return records
        }

        func clearEffects() {
            lock.lock(); effects.removeAll(); lock.unlock()
        }

        func seed(_ reference: String, value: Data) {
            lock.lock(); records[reference] = value; lock.unlock()
        }

        func read(reference: String) async throws -> Data? {
            if let hook = hook(\.beforeRead) { await hook(reference) }
            lock.lock()
            effects.append(.read(reference))
            let fail = failReads.contains(reference)
            let value = records[reference]
            lock.unlock()
            if fail { throw NSError(domain: "fakeGateway", code: 10) }
            return value
        }

        func write(reference: String, value: Data) async throws {
            if let hook = hook(\.beforeWrite) { await hook(reference) }
            lock.lock()
            effects.append(.write(reference, value))
            let fail = failWrites.contains(reference)
            if !fail { records[reference] = value }
            lock.unlock()
            if fail { throw NSError(domain: "fakeGateway", code: 11) }
        }

        func delete(reference: String) async throws {
            if let hook = hook(\.beforeDelete) { await hook(reference) }
            lock.lock()
            effects.append(.delete(reference))
            let fail = failDeletes.contains(reference)
            if !fail { records.removeValue(forKey: reference) }
            lock.unlock()
            if fail { throw NSError(domain: "fakeGateway", code: 12) }
        }
    }

    /// Synthetic owned-work port with the SAME contract as
    /// `RuntimeOwnedWorkRegistryAttachment` (production forwards to the real
    /// shared registry unchanged; tests must not fake lifecycle counts).
    private final class FakeOwnedWork: VaultOwnedWorkAttaching, @unchecked Sendable {
        private let lock = NSLock()
        private var counter = 0
        private(set) var attachCount = 0
        private(set) var detachCount = 0

        func attachVaultMaintenance(epoch: UInt64, ownerID: String) -> VaultOwnedWorkAttach {
            lock.lock()
            counter += 1
            attachCount += 1
            let receipt = "receipt-\(counter)"
            lock.unlock()
            return .attached(receipt: receipt)
        }

        func detachVaultMaintenance(receipt: String, epoch: UInt64, ownerID: String) -> Bool {
            lock.lock(); detachCount += 1; lock.unlock()
            return true
        }

        func isVaultMaintenanceAttached(receipt: String, epoch: UInt64, ownerID: String) -> Bool {
            true
        }
    }

    /// Test ownership port over the REAL admitted coordinator. `expired`
    /// models a root that has moved on (production: the cluster lookup
    /// fails typed after retirement).
    private final class StaticOwnership: G09R2EnhancerRuntimeOwnership, @unchecked Sendable {
        let context: G09R2EnhancerRuntimeContext
        var expired = false
        init(context: G09R2EnhancerRuntimeContext) { self.context = context }
        func context(epoch: UInt64) async throws -> G09R2EnhancerRuntimeContext {
            if expired { throw G09R2EnhancerRuntimeRefusal.staleGeneration }
            guard epoch == context.epoch else {
                throw G09R2EnhancerRuntimeRefusal.staleGeneration
            }
            return context
        }
    }

    /// Settings decorator that can fail writes/removes (the production
    /// SQLiteSettingsStore cannot). Backed by the REAL store over the same
    /// database.
    private final class FailingSettingsStore: SettingsStore, @unchecked Sendable {
        let base: any SettingsStore
        var failSetValue = false
        var failRemoveValue = false
        init(base: any SettingsStore) { self.base = base }

        func value(forKey key: String) async throws -> String? {
            try await base.value(forKey: key)
        }

        func setValue(_ json: String, forKey key: String) async throws {
            if failSetValue { throw NSError(domain: "failingSettings", code: 1) }
            try await base.setValue(json, forKey: key)
        }

        func removeValue(forKey key: String) async throws {
            if failRemoveValue { throw NSError(domain: "failingSettings", code: 2) }
            try await base.removeValue(forKey: key)
        }

        func allValues() async throws -> [String: String] {
            try await base.allValues()
        }
    }

    /// Barrier handshake so the test controls exactly when a hooked gateway
    /// effect proceeds. `signal`/`wait` coordinate the "effect entered"
    /// observation; `register`/`release` hold the effect until released.
    private enum TestBarrier {
        private static let lock = NSLock()
        private static var waiters: [String: CheckedContinuation<Void, Never>] = [:]
        private static var signals: Set<String> = []

        static func signal(_ token: String) {
            lock.lock()
            if let resume = waiters.removeValue(forKey: token) {
                lock.unlock()
                resume.resume()
            } else {
                signals.insert(token)
                lock.unlock()
            }
        }

        static func wait(_ token: String) async {
            await withCheckedContinuation { resume in
                lock.lock()
                if signals.remove(token) != nil {
                    lock.unlock()
                    resume.resume()
                } else {
                    waiters[token] = resume
                    lock.unlock()
                }
            }
        }

        static func register(_ token: String,
                             _ resume: CheckedContinuation<Void, Never>) {
            lock.lock()
            waiters[token] = resume
            lock.unlock()
        }

        static func release(_ token: String) {
            lock.lock()
            let resume = waiters.removeValue(forKey: token)
            lock.unlock()
            resume?.resume()
        }
    }

    // MARK: - Real per-root harness

    private struct RootHarness {
        let database: DatabaseManager
        let identity: RuntimeOwnerIdentity
        let coordinator: CredentialVaultOperationCoordinator
        let ownedWork: FakeOwnedWork
        let vault: AndroidCredentialVault
        let records: CredentialStore
        let settings: FailingSettingsStore
        let ownership: StaticOwnership
        let store: Store
        let gateway: FakeGateway
        let epoch: UInt64
        var context: G09R2EnhancerRuntimeContext { ownership.context }
    }

    private func makeRoot(
        epoch: UInt64 = 7,
        gateway: FakeGateway? = nil,
        rootDirectory: URL? = nil
    ) async throws -> RootHarness {
        let directory = rootDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("g09r2-vault-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let storageRoot = try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: directory.path),
            "synthetic test root path must validate")
        let identity = try XCTUnwrap(
            RuntimeOwnerIdentity(
                root: storageRoot, token: "aabbccddeeff00112233", epoch: epoch),
            "synthetic test identity must validate")
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        // REAL admission: one shared coordinator per exact identity + manager.
        let admission = CredentialVaultRuntimeAdmission.admit(
            identity: identity, database: database)
        let coordinator = try XCTUnwrap(admission.coordinator)
        let ownedWork = FakeOwnedWork()
        let fakeGateway = gateway ?? FakeGateway()
        let vault = try AndroidCredentialVault.joinRuntimeOwnership(
            database: database,
            identity: identity,
            ownedWork: ownedWork,
            gateway: fakeGateway)
        let records = CredentialStore(database: database)
        let settings = FailingSettingsStore(
            base: SQLiteSettingsStore(database: database))
        let context = G09R2EnhancerRuntimeContext(
            epoch: epoch, coordinator: coordinator,
            ownedWork: ownedWork, vault: vault)
        let ownership = StaticOwnership(context: context)
        let store = Store(
            settings: settings,
            records: records,
            runtime: ownership,
            gatewayRead: { reference in
                try await fakeGateway.read(reference: reference)
            },
            gatewayWrite: { reference, value in
                try await fakeGateway.write(reference: reference, value: value)
            },
            gatewayDelete: { reference in
                try await fakeGateway.delete(reference: reference)
            })
        return RootHarness(
            database: database, identity: identity, coordinator: coordinator,
            ownedWork: ownedWork, vault: vault, records: records,
            settings: settings, ownership: ownership, store: store,
            gateway: fakeGateway, epoch: epoch)
    }

    private func account(_ id: UUID) -> String {
        "credential.\(id.uuidString)"
    }

    private func reference(_ account: String) -> String {
        Store.opaqueReference(for: account)
    }

    private func configuration(
        displayName: String? = "fal",
        account: String = G09R2EnhancerBackendConfiguration.defaultCredentialAccount
    ) -> G09R2EnhancerBackendConfiguration {
        G09R2EnhancerBackendConfiguration(
            displayName: displayName, credentialAccount: account)
    }

    /// The closed enhancer editor identity (route subject id + candidate id).
    private var enhancerEditorID: String { Store.enhancerEditorID }

    /// Builds the sealed-ingress lease exactly as the ONE-SHOT vault consume
    /// hands it to the native save: the frozen secret-free candidate and the
    /// key bytes captured together. Tests construct it directly because the
    /// host-side submit/consume seam is exercised by the Kotlin host tests;
    /// these tests prove the NATIVE owned save composition.
    private func makeIntentLease(
        displayName: String? = "fal",
        endpointID: String = G09R2EnhancerBackendConfiguration.defaultEndpointID,
        secret: Data = Data("new-key".utf8),
        subject: SubjectKind = .enhancerSave
    ) throws -> SaveIntentLease {
        var candidate: [String: Any] = [
            "id": enhancerEditorID,
            "endpointID": endpointID,
        ]
        if let displayName { candidate["displayName"] = displayName }
        let data = try JSONSerialization.data(
            withJSONObject: candidate, options: [.sortedKeys])
        return SaveIntentLease(
            leaseID: UUID().uuidString, subject: subject, baseRevision: nil,
            candidateJSON: data, secret: secret, vault: SecretSaveIntentVault.shared)
    }

    /// Configures `h` with one live enhancer credential through ONE sealed
    /// save and returns the freshly captured credential id.
    @discardableResult
    private func configure(
        _ h: RootHarness, displayName: String = "fal", secret: String = "fal-key"
    ) async throws -> UUID {
        let lease = try makeIntentLease(
            displayName: displayName, secret: Data(secret.utf8))
        try await h.store.save(
            configuration(displayName: displayName), intentLease: lease,
            epoch: h.epoch)
        let row = try await XCTUnwrap(
            h.store.load(), "the sealed save must persist the typed row")
        return try XCTUnwrap(
            Store.parseOwnedCredentialID(row.credentialAccount),
            "the sealed save must bind the row to a fresh owned account")
    }

    // MARK: - Cross-root ownership (the missed counterexample)

    func testTwoRootsSharingAccountStringProduceZeroCrossRootGatewayEffects() async throws {
        // ONE physical gateway (both roots hash into the same store), TWO
        // independent admitted roots/databases/coordinators.
        let shared = FakeGateway()
        let rootA = try await makeRoot(epoch: 101, gateway: shared)
        let rootB = try await makeRoot(epoch: 102, gateway: shared)

        // RootA is fully configured through the real sealed save.
        let idA = try await configure(rootA, secret: "rootA-key")
        let accountA = account(idA)
        let rootAConfigured = await rootA.store.credentialConfigured(
            configuration(account: accountA))
        XCTAssertTrue(rootAConfigured)

        // RootB's row is restored/malformed to carry THE SAME account string
        // — and even the legacy allowed global string with a live secret at
        // its reference (written by some earlier global-scheme build).
        let legacy = G09R2EnhancerBackendConfiguration.defaultCredentialAccount
        shared.seed(reference(legacy), value: Data("legacy-key".utf8))
        for rowAccount in [accountA, legacy] {
            let rowB = configuration(account: rowAccount)
            try await rootB.settings.base.setValue(
                rowB, forKey: Store.settingsKey)
            shared.clearEffects()

            // Reads: no ownership proof in rootB's metadata → unavailable.
            let configuredB = await rootB.store.credentialConfigured(rowB)
            XCTAssertFalse(configuredB,
                           "rootB must not prove rootA's/legacy account")
            let keyB = await rootB.store.credential(for: rowB)
            XCTAssertNil(keyB)
            // Revoke: the row is removed WITHOUT any gateway access (the
            // credential is foreign/retired in rootB's envelope).
            try await rootB.store.clear(epoch: rootB.epoch)
            XCTAssertNil(try await rootB.store.load())
            XCTAssertEqual(shared.snapshotEffects(), [],
                           "ZERO gateway effects for rootB on the shared store")
        }

        // RootB's OWN sealed save mints a FRESH rootB-owned credential: the
        // foreign row's account was never proven in rootB, so the rotation
        // never derives or touches its reference.
        let leaseB = try makeIntentLease(secret: Data("rootB-key".utf8))
        try await rootB.store.save(
            configuration(), intentLease: leaseB, epoch: rootB.epoch)
        let rowB = try await XCTUnwrap(rootB.store.load())
        let idB = try await XCTUnwrap(
            Store.parseOwnedCredentialID(rowB.credentialAccount))
        XCTAssertNotEqual(idB, idA)
        let recordB = try await rootB.records.record(id: idB)
        XCTAssertEqual(recordB?.origin, G09R2EnhancerCredentialPurpose.origin)
        for effect in shared.snapshotEffects() {
            switch effect {
            case .write(let ref, _):
                XCTAssertEqual(ref, reference(account(idB)))
            default:
                XCTFail("rootB's sealed save performs exactly one capture write: \(effect)")
            }
        }
        // RootA's credential stays fully usable and untouched.
        let rootAStillConfigured = await rootA.store.credentialConfigured(
            configuration(account: accountA))
        XCTAssertTrue(rootAStillConfigured)
        XCTAssertEqual(shared.snapshotRecords()[reference(accountA)], Data("rootA-key".utf8))
    }

    func testForgedCandidatesAndCrossSubjectLeasesAreRefusedBeforeAnyEffect() async throws {
        let h = try await makeRoot()
        // Forged candidate ids: the legacy global string, a `.pending.` shape
        // and a random credential shape are not the closed editor identity.
        let forgedIDs = [
            G09R2EnhancerBackendConfiguration.defaultCredentialAccount,
            G09R2EnhancerBackendConfiguration.defaultCredentialAccount
                + ".pending." + UUID().uuidString,
            "credential." + UUID().uuidString,
        ]
        for forgedID in forgedIDs {
            var candidate: [String: Any] = [
                "id": forgedID,
                "endpointID": G09R2EnhancerBackendConfiguration.defaultEndpointID,
            ]
            candidate["displayName"] = "fal"
            let data = try JSONSerialization.data(
                withJSONObject: candidate, options: [.sortedKeys])
            let lease = SaveIntentLease(
                leaseID: UUID().uuidString, subject: .enhancerSave,
                baseRevision: nil, candidateJSON: data,
                secret: Data("new-key".utf8), vault: SecretSaveIntentVault.shared)
            do {
                try await h.store.save(
                    configuration(), intentLease: lease, epoch: h.epoch)
                XCTFail("forged candidate id must be refused: \(forgedID)")
            } catch ConfigError.intentCandidateMismatch {}
        }
        // A smuggled provider identity inside the candidate (closed key set).
        do {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "id": enhancerEditorID,
                    "endpointID": G09R2EnhancerBackendConfiguration.defaultEndpointID,
                    "providerID": "provider.\(UUID().uuidString)",
                ], options: [.sortedKeys])
            let lease = SaveIntentLease(
                leaseID: UUID().uuidString, subject: .enhancerSave,
                baseRevision: nil, candidateJSON: data,
                secret: Data("new-key".utf8), vault: SecretSaveIntentVault.shared)
            try await h.store.save(
                configuration(), intentLease: lease, epoch: h.epoch)
            XCTFail("a smuggled provider identity must be refused")
        } catch ConfigError.intentCandidateMismatch {}
        // A frozen candidate whose row does not match the submitted row.
        do {
            let lease = try makeIntentLease(displayName: "other-name")
            try await h.store.save(
                configuration(displayName: "fal"), intentLease: lease,
                epoch: h.epoch)
            XCTFail("a mismatched frozen candidate must be refused")
        } catch ConfigError.intentCandidateMismatch {}
        // Cross-subject leases (a providerSave/webSearchSave token can never
        // drive an enhancer save; the vault consume enforces this and the
        // store re-checks at the effect boundary).
        for subject in [SubjectKind.providerSave, SubjectKind.webSearchSave] {
            let lease = try makeIntentLease(subject: subject)
            do {
                try await h.store.save(
                    configuration(), intentLease: lease, epoch: h.epoch)
                XCTFail("a cross-subject lease must be refused: \(subject)")
            } catch ConfigError.credentialAccountOwnership {}
        }
        XCTAssertEqual(h.gateway.snapshotEffects(), [])
        XCTAssertEqual(try await h.records.pendingDeletions(), [])
    }

    // MARK: - Sealed save uses ONE original vault capture

    func testSealedCommitBindsRowToFreshOwnedMetadataAndOneCaptureWrite() async throws {
        let h = try await makeRoot()
        let lease = try makeIntentLease(secret: Data("new-key".utf8))
        try await h.store.save(
            configuration(displayName: "fal"), intentLease: lease,
            epoch: h.epoch)

        // The row binds to the freshly captured owned account.
        let row = try await h.store.load()
        let stagedID = try await XCTUnwrap(
            Store.parseOwnedCredentialID(row?.credentialAccount ?? ""))
        XCTAssertEqual(row?.displayName, "fal")
        let staged = account(stagedID)
        let stagedRef = reference(staged)
        // The ORIGINAL metadata authority proves the issued record.
        let record = try await h.records.record(id: stagedID)
        XCTAssertEqual(record?.kind, .providerAPIKey)
        XCTAssertEqual(record?.owner, .vault)
        XCTAssertEqual(record?.origin, G09R2EnhancerCredentialPurpose.origin)
        XCTAssertEqual(record?.keychainAccount, staged)
        // Nothing pending: the capture claim was finalized.
        XCTAssertEqual(try await h.records.pendingDeletions(), [])
        // EXACTLY ONE original vault capture write — no host write, no second
        // secret path; every effect stayed on the issued reference. (The
        // credential resolution read below is asserted separately.)
        let effects = h.gateway.snapshotEffects()
        XCTAssertEqual(effects, [.write(stagedRef, Data("new-key".utf8))])
        // The credential resolves through the owned reference.
        let resolved = await h.store.credential(for: configuration(account: staged))
        XCTAssertEqual(resolved, "new-key")
    }

    // MARK: - Immutable rotation failure semantics

    func testSettingsCommitFailureLeavesOldConfigAndKeyByteIdentical() async throws {
        let h = try await makeRoot()
        let oldID = try await configure(h, displayName: "before", secret: "old-key")
        let oldAccount = account(oldID)
        let oldRef = reference(oldAccount)
        let oldKey = Data("old-key".utf8)
        h.gateway.clearEffects()

        let newLease = try makeIntentLease(
            displayName: "rotated", secret: Data("new-key".utf8))
        h.settings.failSetValue = true
        do {
            try await h.store.save(
                configuration(displayName: "rotated"), intentLease: newLease,
                epoch: h.epoch)
            XCTFail("a failed settings commit must propagate")
        } catch ConfigError.persistenceUnavailable {}
        h.settings.failSetValue = false

        // Previous configuration AND credential byte-identical.
        let row = try await h.store.load()
        XCTAssertEqual(row?.credentialAccount, oldAccount)
        XCTAssertEqual(row?.displayName, "before")
        XCTAssertEqual(h.gateway.snapshotRecords()[oldRef], oldKey)
        // The just-captured credential was durably retired through the
        // ORIGINAL delete: exactly the capture write + the rollback delete
        // on the SAME fresh reference; the previous reference was untouched.
        let effects = h.gateway.snapshotEffects()
        XCTAssertEqual(effects.count, 2)
        guard case .write(let capturedRef, let captured) = effects[0],
              case .delete(let retiredRef) = effects[1] else {
            return XCTFail("expected exactly one capture write + one rollback delete")
        }
        XCTAssertEqual(captured, Data("new-key".utf8))
        XCTAssertEqual(capturedRef, retiredRef)
        XCTAssertNotEqual(capturedRef, oldRef)
        XCTAssertNil(h.gateway.snapshotRecords()[capturedRef])
        XCTAssertEqual(try await h.records.pendingDeletions(), [])
        // Owned-work receipts were attached/detached for the mutations.
        XCTAssertGreaterThan(h.ownedWork.attachCount, 0)
        XCTAssertEqual(h.ownedWork.attachCount, h.ownedWork.detachCount)
    }

    func testSettingsFailureWithRollbackGatewayFailureKeepsOldByteIdentical() async throws {
        let h = try await makeRoot()
        let oldID = try await configure(h, secret: "old-key")
        let oldAccount = account(oldID)
        let oldRef = reference(oldAccount)
        let oldKey = Data("old-key".utf8)
        h.gateway.clearEffects()

        // The rollback delete of the just-captured reference fails: arm the
        // failure when the capture write is observed (the new account is
        // minted inside the store, so the test learns the reference from the
        // effect itself).
        h.gateway.beforeWrite = { ref in
            h.gateway.failDeletes.insert(ref)
        }
        let newLease = try makeIntentLease(secret: Data("new-key".utf8))
        h.settings.failSetValue = true
        do {
            try await h.store.save(
                configuration(), intentLease: newLease, epoch: h.epoch)
            XCTFail("a failed settings commit must propagate")
        } catch ConfigError.persistenceUnavailable {}
        h.settings.failSetValue = false
        h.gateway.beforeWrite = nil

        // Old state byte-identical even though BOTH the settings commit and
        // the rollback gateway delete failed.
        XCTAssertEqual(try await h.store.load()?.credentialAccount, oldAccount)
        XCTAssertEqual(h.gateway.snapshotRecords()[oldRef], oldKey)
        // The retirement cleanup intent is durable for the restart drain.
        let pending = try await h.records.pendingDeletions()
        XCTAssertEqual(pending.count, 1)
        let pendingRef = reference(pending[0].keychainAccount)
        XCTAssertEqual(h.gateway.snapshotRecords()[pendingRef], Data("new-key".utf8))
        // Late completion drains through the ORIGINAL claims + registry.
        h.gateway.failDeletes.remove(pendingRef)
        let report = await h.vault.drainDeletionQueue()
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(try await h.records.pendingDeletions(), [])
        XCTAssertEqual(h.gateway.snapshotRecords()[oldRef], oldKey,
                       "draining the retired claim must never touch the live key")
    }

    func testDisplayNameOnlyEditKeepsCredentialAndRowAccount() async throws {
        let h = try await makeRoot()
        let id = try await configure(h)
        let liveAccount = account(id)
        let liveRef = reference(liveAccount)
        let key = h.gateway.snapshotRecords()[liveRef]
        h.gateway.clearEffects()

        try await h.store.save(
            configuration(displayName: "renamed"), epoch: h.epoch)

        let row = try await h.store.load()
        XCTAssertEqual(row?.credentialAccount, liveAccount)
        XCTAssertEqual(row?.displayName, "renamed")
        XCTAssertEqual(h.gateway.snapshotRecords()[liveRef], key)
        for effect in h.gateway.snapshotEffects() {
            switch effect {
            case .read(let ref): XCTAssertEqual(ref, liveRef)
            default: XCTFail("display edit performs no mutation effect: \(effect)")
            }
        }
    }

    func testDisplayNameOnlyEditWithoutOwnedRowRefuses() async throws {
        let h = try await makeRoot()
        do {
            try await h.store.save(configuration(), epoch: h.epoch)
            XCTFail("a display edit without an owned row must refuse")
        } catch ConfigError.credentialMissing {}
        XCTAssertEqual(h.gateway.snapshotEffects(), [])
    }

    // MARK: - Truthful revoke through the original retirement

    func testClearRetiresCredentialThroughOriginalQueue() async throws {
        let h = try await makeRoot()
        let id = try await configure(h)
        let liveAccount = account(id)
        let liveRef = reference(liveAccount)

        try await h.store.clear(epoch: h.epoch)

        XCTAssertNil(try await h.store.load())
        XCTAssertNil(try await h.records.record(id: id))
        XCTAssertNil(h.gateway.snapshotRecords()[liveRef])
        XCTAssertEqual(try await h.records.pendingDeletions(), [])
    }

    func testClearReportsPendingCleanupTruthfullyAndRetrySettles() async throws {
        let h = try await makeRoot()
        let id = try await configure(h)
        let liveAccount = account(id)
        let liveRef = reference(liveAccount)
        h.gateway.failDeletes.insert(liveRef)

        do {
            try await h.store.clear(epoch: h.epoch)
            XCTFail("an incomplete cleanup must report the typed failure")
        } catch ConfigError.credentialRevokeFailed {}
        // Row preserved for retry; the cleanup intent is durable.
        XCTAssertNotNil(try await h.store.load())
        XCTAssertEqual(
            try await h.records.pendingDeletions().map(\.keychainAccount),
            [liveAccount])

        // The service-owned restart drain settles the original claim.
        h.gateway.failDeletes.remove(liveRef)
        let report = await h.vault.drainDeletionQueue()
        XCTAssertEqual(report.completed, 1)
        XCTAssertNil(h.gateway.snapshotRecords()[liveRef])
        XCTAssertEqual(try await h.records.pendingDeletions(), [])
        // The retry now removes the row WITHOUT any gateway access.
        h.gateway.clearEffects()
        try await h.store.clear(epoch: h.epoch)
        XCTAssertNil(try await h.store.load())
        XCTAssertEqual(h.gateway.snapshotEffects(), [])
    }

    func testImmediateRevokeRetryBeforeDrainStillReportsPending() async throws {
        let h = try await makeRoot()
        let id = try await configure(h)
        let liveAccount = account(id)
        let liveRef = reference(liveAccount)
        h.gateway.failDeletes.insert(liveRef)

        do {
            try await h.store.clear(epoch: h.epoch)
            XCTFail("an incomplete cleanup must report the typed failure")
        } catch ConfigError.credentialRevokeFailed {}
        // The durable claim is outstanding and the physical erase is still
        // pending: the row is preserved (never a credential-erased success
        // while this root still holds the claim).
        XCTAssertNotNil(try await h.store.load())
        XCTAssertEqual(
            try await h.records.pendingDeletions().map(\.keychainAccount),
            [liveAccount])

        // An IMMEDIATE retry BEFORE the deletion-queue drain: the metadata
        // may already be deleted while the physical erase is still pending —
        // the retry must report the SAME truthful pending failure, keep the
        // row, and never invent a success.
        do {
            try await h.store.clear(epoch: h.epoch)
            XCTFail("an immediate retry before the drain must stay pending")
        } catch ConfigError.credentialRevokeFailed {}
        XCTAssertNotNil(try await h.store.load())
        XCTAssertEqual(
            try await h.records.pendingDeletions().map(\.keychainAccount),
            [liveAccount])

        // After the original drain proves the deletion, the retry finishes.
        h.gateway.failDeletes.remove(liveRef)
        let report = await h.vault.drainDeletionQueue()
        XCTAssertEqual(report.completed, 1)
        try await h.store.clear(epoch: h.epoch)
        XCTAssertNil(try await h.store.load())
    }

    func testClearForeignShapedRowRemovesRowWithZeroEffects() async throws {
        let h = try await makeRoot()
        let foreign = G09R2EnhancerBackendConfiguration(
            credentialAccount: "provider.\(UUID().uuidString)")
        try await h.settings.base.setValue(foreign, forKey: Store.settingsKey)
        // A foreign-shaped row is removed as settings data only — no
        // reference is derived and NO gateway access happens.
        try await h.store.clear(epoch: h.epoch)
        XCTAssertNil(try await h.store.load())
        XCTAssertEqual(h.gateway.snapshotEffects(), [])
    }

    func testRotationOverwritesUnprovenRowWithoutTouchingIt() async throws {
        let h = try await makeRoot()
        // A stale restored row carrying a credential-shaped account that
        // this root never minted (no record, no claim).
        let foreignID = UUID()
        let stale = configuration(account: account(foreignID))
        try await h.settings.base.setValue(stale, forKey: Store.settingsKey)
        // RootB's OWN sealed save overwrites the stale row with a FRESH
        // root-owned credential; the stale account is never derived or
        // gateway-accessed.
        let lease = try makeIntentLease(
            displayName: "reconfigured", secret: Data("fresh-key".utf8))
        try await h.store.save(
            configuration(displayName: "reconfigured"), intentLease: lease,
            epoch: h.epoch)
        let row = try await XCTUnwrap(h.store.load())
        XCTAssertEqual(row.displayName, "reconfigured")
        let newID = try await XCTUnwrap(
            Store.parseOwnedCredentialID(row.credentialAccount))
        XCTAssertNotEqual(newID, foreignID)
        // EXACTLY ONE capture write at the fresh reference; the stale
        // reference was never read or written.
        let effects = h.gateway.snapshotEffects()
        XCTAssertEqual(effects, [.write(reference(account(newID)), Data("fresh-key".utf8))])
    }

    func testCommitFenceFailureRetiresCapturedAndPreservesPrevious() async throws {
        let h = try await makeRoot()
        let oldID = try await configure(h, displayName: "before", secret: "old-key")
        let oldAccount = account(oldID)
        let oldRef = reference(oldAccount)
        let oldKey = Data("old-key".utf8)
        h.gateway.clearEffects()

        let newLease = try makeIntentLease(
            displayName: "rotated", secret: Data("new-key".utf8))
        let fence: @Sendable () async throws -> Void = {
            throw G09R2EnhancerRuntimeRefusal.staleGeneration
        }
        do {
            try await h.store.save(
                configuration(displayName: "rotated"), intentLease: newLease,
                epoch: h.epoch, commitValidation: fence)
            XCTFail("a commit-fence failure must propagate")
        } catch G09R2EnhancerRuntimeRefusal.staleGeneration {}

        // The just-captured credential was durably retired; the previous
        // state is byte-identical (the previous reference was never
        // rewritten).
        XCTAssertEqual(try await h.store.load()?.credentialAccount, oldAccount)
        XCTAssertEqual(try await h.store.load()?.displayName, "before")
        XCTAssertEqual(h.gateway.snapshotRecords()[oldRef], oldKey)
        let effects = h.gateway.snapshotEffects()
        XCTAssertEqual(effects.count, 2)
        guard case .write(let capturedRef, _) = effects[0],
              case .delete(let retiredRef) = effects[1] else {
            return XCTFail("expected exactly one capture write + one rollback delete")
        }
        XCTAssertEqual(capturedRef, retiredRef)
        XCTAssertNotEqual(capturedRef, oldRef)
        XCTAssertNil(h.gateway.snapshotRecords()[capturedRef])
        XCTAssertEqual(try await h.records.pendingDeletions(), [])
    }

    // MARK: - Root switch / stale caller / admission fence

    func testStaleEpochSaveAndClearRefuseTypedBeforeAnyEffect() async throws {
        let h = try await makeRoot()
        let id = try await configure(h)
        h.gateway.clearEffects()
        do {
            try await h.store.save(
                configuration(), epoch: h.epoch + 50)
            XCTFail("a stale-epoch save must refuse")
        } catch G09R2EnhancerRuntimeRefusal.staleGeneration {}
        do {
            try await h.store.clear(epoch: h.epoch + 50)
            XCTFail("a stale-epoch clear must refuse")
        } catch G09R2EnhancerRuntimeRefusal.staleGeneration {}
        XCTAssertNotNil(try await h.store.load())
        _ = id
        XCTAssertEqual(h.gateway.snapshotEffects(), [])
    }

    func testRootSwitchRefusesStaleCallerAndNeverTouchesNewerOwner() async throws {
        let shared = FakeGateway()
        let epoch1: UInt64 = 201
        let root1 = try await makeRoot(epoch: epoch1, gateway: shared)
        let id1 = try await configure(root1, secret: "gen1-key")
        let account1 = account(id1)

        // Generation 2 admits over the SAME root path with a newer epoch
        // and its own (reopened) database — the real replacement path,
        // allowed because generation 1 has provably no live operations.
        let root2 = try await makeRoot(
            epoch: epoch1 + 1, gateway: shared,
            rootDirectory: URL(fileURLWithPath: root1.identity.root.path))
        let id2 = try await configure(root2, secret: "gen2-key")
        let account2 = account(id2)

        // The stale generation-1 caller is refused typed and produces ZERO
        // effects even on the shared physical gateway.
        shared.clearEffects()
        root1.ownership.expired = true
        let staleLease = try makeIntentLease()
        do {
            try await root1.store.save(
                configuration(), intentLease: staleLease, epoch: epoch1)
            XCTFail("the stale caller must refuse before any effect")
        } catch G09R2EnhancerRuntimeRefusal.staleGeneration {}
        do {
            try await root1.store.clear(epoch: epoch1)
            XCTFail("the stale caller must refuse before any effect")
        } catch G09R2EnhancerRuntimeRefusal.staleGeneration {}
        XCTAssertEqual(shared.snapshotEffects(), [])
        // The newer owner's configuration is untouched and still usable.
        XCTAssertEqual(try await root2.store.load()?.credentialAccount, account2)
        let gen2Configured = await root2.store.credentialConfigured(
            configuration(account: account2))
        XCTAssertTrue(gen2Configured)
        XCTAssertEqual(shared.snapshotRecords()[reference(account2)],
                       Data("gen2-key".utf8))
        XCTAssertEqual(shared.snapshotRecords()[reference(account1)],
                       Data("gen1-key".utf8))
    }

    func testRebindWhileMutationLiveIsRefusedByOriginalAdmissionFence() async throws {
        let h = try await makeRoot(epoch: 301)
        let id = try await configure(h)
        let liveAccount = account(id)
        let liveRef = reference(liveAccount)

        // Block the revoke inside the gateway delete of the live reference.
        h.gateway.beforeDelete = { ref in
            guard ref == liveRef else { return }
            TestBarrier.signal("clear-delete-entered")
            await withCheckedContinuation {
                TestBarrier.register("hold-clear", $0)
            }
        }
        let clearTask = Task { try await h.store.clear(epoch: h.epoch) }
        await TestBarrier.wait("clear-delete-entered")

        // A newer generation cannot take over while ANY owned operation is
        // live — the ORIGINAL admission fence, not a cloned gate.
        let newerIdentity = try XCTUnwrap(RuntimeOwnerIdentity(
            root: h.identity.root, token: h.identity.token, epoch: 302))
        let refused = CredentialVaultRuntimeAdmission.admit(
            identity: newerIdentity, database: h.database)
        guard case .rejected(let code) = refused.outcome else {
            return XCTFail("rebind while owned must be refused")
        }
        XCTAssertEqual(code, .rebindWhileOwned)

        TestBarrier.release("hold-clear")
        try await clearTask.value
        // Settled → retirement succeeds → the newer generation admits.
        try h.vault.retireRuntimeOwnership()
        let admitted = CredentialVaultRuntimeAdmission.admit(
            identity: newerIdentity, database: h.database)
        guard case .admittedNewContext = admitted.outcome else {
            XCTFail("generation 2 must admit after the mutation settled")
        }
    }

    // MARK: - Concurrent save/revoke serialization (controlled barriers)

    func testConcurrentClearThenSaveSerializeOnTheSharedCoordinator() async throws {
        let h = try await makeRoot()
        let oldID = try await configure(h)
        let oldAccount = account(oldID)
        let oldRef = reference(oldAccount)
        h.gateway.clearEffects()

        // The clear wins the coordination lease and stalls inside the live
        // gateway delete; the save must wait its turn (no interleaved
        // capture/delete effects — the mutations serialize on the SHARED
        // admitted coordinator, not a cloned gate).
        h.gateway.beforeDelete = { ref in
            guard ref == oldRef else { return }
            TestBarrier.signal("clear-delete-entered")
            await withCheckedContinuation {
                TestBarrier.register("hold-clear", $0)
            }
        }
        let clearTask = Task { try await h.store.clear(epoch: h.epoch) }
        await TestBarrier.wait("clear-delete-entered")
        let saveLease = try makeIntentLease(
            displayName: "after-clear", secret: Data("new-key".utf8))
        let saveTask = Task {
            try await h.store.save(
                configuration(displayName: "after-clear"),
                intentLease: saveLease, epoch: h.epoch)
        }
        // While the clear holds the lease, NEITHER party has produced a
        // recorded gateway effect (the clear is blocked inside its delete
        // before the effect lands; the save is still waiting on the
        // coordinator).
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.gateway.snapshotEffects(), [])

        TestBarrier.release("hold-clear")
        try await clearTask.value
        try await saveTask.value

        // Serial composition: clear fully retired the old credential and
        // removed the row; the save then captured the new credential as a
        // FIRST configuration for this root.
        let row = try await XCTUnwrap(h.store.load())
        let newID = try await XCTUnwrap(
            Store.parseOwnedCredentialID(row.credentialAccount))
        let newAccount = account(newID)
        let newRef = reference(newAccount)
        XCTAssertEqual(row.displayName, "after-clear")
        XCTAssertNil(try await h.records.record(id: oldID))
        XCTAssertNotNil(try await h.records.record(id: newID))
        XCTAssertNil(h.gateway.snapshotRecords()[oldRef])
        XCTAssertEqual(h.gateway.snapshotRecords()[newRef], Data("new-key".utf8))
        XCTAssertEqual(try await h.records.pendingDeletions(), [])
        XCTAssertEqual(h.ownedWork.attachCount, h.ownedWork.detachCount)
    }

    func testConcurrentSaveThenClearSerializeOnTheSharedCoordinator() async throws {
        let h = try await makeRoot()
        let oldID = try await configure(h)
        let oldAccount = account(oldID)
        let oldRef = reference(oldAccount)
        h.gateway.clearEffects()

        // The save wins the lease and stalls INSIDE the single original
        // capture write; the clear must wait its turn.
        var capturedRef: String?
        h.gateway.beforeWrite = { ref in
            capturedRef = ref
            TestBarrier.signal("save-write-entered")
            await withCheckedContinuation {
                TestBarrier.register("hold-save", $0)
            }
        }
        let saveLease = try makeIntentLease(
            displayName: "rotated", secret: Data("new-key".utf8))
        let saveTask = Task {
            try await h.store.save(
                configuration(displayName: "rotated"),
                intentLease: saveLease, epoch: h.epoch)
        }
        await TestBarrier.wait("save-write-entered")
        let newRef = try await XCTUnwrap(capturedRef)
        let clearTask = Task { try await h.store.clear(epoch: h.epoch) }
        // While the save holds the lease, NEITHER party has produced a
        // recorded gateway effect (the save is blocked inside its capture
        // write before the effect lands; the clear is still waiting on the
        // coordinator).
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.gateway.snapshotEffects(), [])

        TestBarrier.release("hold-save")
        try await saveTask.value
        try await clearTask.value
        h.gateway.beforeWrite = nil

        // Serial composition: the save committed + persisted + retired the
        // old credential; the clear then retired the NEW credential and
        // removed the row. No false success in either direction.
        XCTAssertNil(try await h.store.load())
        XCTAssertNil(try await h.records.record(id: oldID))
        XCTAssertNil(h.gateway.snapshotRecords()[oldRef])
        XCTAssertNil(h.gateway.snapshotRecords()[newRef])
        XCTAssertEqual(try await h.records.pendingDeletions(), [])
        XCTAssertEqual(h.ownedWork.attachCount, h.ownedWork.detachCount)
    }

    // MARK: - ffprobe probe/parser/output-guard regressions (preserved)

    private func realAllStreamsFixture() -> String {
        """
        {"programs":[],"stream_groups":[],"streams":[\
        {"codec_name":"h264","codec_type":"video","width":128,"height":96,\
        "avg_frame_rate":"24/1","duration":"2.000000","nb_frames":"48"},\
        {"codec_name":"aac","codec_type":"audio","avg_frame_rate":"0/0",\
        "duration":"2.000000","nb_frames":"95"}],\
        "format":{"duration":"2.000000"}}
        """
    }

    func testProbeParsesRealStringFrameCountAndMeasuredAudio() throws {
        let facts = try G09R2EnhancementProbeParser.parseVideoFacts(
            realAllStreamsFixture(), byteCount: 47_015,
            sha256: "b5f98d5c6300fec9afead2c0da76a83a62510505c7945854365d4e407425e1f5")
        XCTAssertEqual(facts.width, 128)
        XCTAssertEqual(facts.height, 96)
        XCTAssertEqual(facts.frameCount, 48)
        XCTAssertEqual(facts.frameRate, 24, accuracy: 0.001)
        XCTAssertTrue(facts.hasAudio,
                      "audio presence must be measured from the all-streams probe")
        XCTAssertEqual(facts.durationSeconds, 2, accuracy: 0.001)
    }

    func testProbeLegacyFixtureWithoutCodecTypeStillParses() throws {
        // Existing numeric fixtures (no codec_type) keep working; audio
        // stays unknown (historical contract) instead of failing the decode.
        let json = """
        {"streams":[{"codec_name":"hevc","width":3840,"height":2160,\
        "avg_frame_rate":"24000/1001","nb_frames":240,"duration":"10.01",\
        "color_transfer":"smpte2084"}],"format":{"duration":"10.01"}}
        """
        let facts = try G09R2EnhancementProbeParser.parseVideoFacts(
            json, byteCount: 100, sha256: "c")
        XCTAssertEqual(facts.frameCount, 240)
        XCTAssertTrue(facts.isHDR)
        XCTAssertFalse(facts.hasAudio)
    }

    func testProbeAudioFirstContainerSelectsVideoStream() throws {
        let json = """
        {"streams":[\
        {"codec_name":"aac","codec_type":"audio","avg_frame_rate":"0/0",\
        "duration":"2.000000","nb_frames":"95"},\
        {"codec_name":"h264","codec_type":"video","width":128,"height":96,\
        "avg_frame_rate":"24/1","duration":"2.000000","nb_frames":"48"}],\
        "format":{"duration":"2.000000"}}
        """
        let facts = try G09R2EnhancementProbeParser.parseVideoFacts(
            json, byteCount: 1, sha256: "s")
        XCTAssertEqual(facts.width, 128)
        XCTAssertEqual(facts.frameCount, 48)
        XCTAssertTrue(facts.hasAudio)
    }

    func testProbeUnboundedDurationRefusesInsteadOfTrapping() throws {
        // duration "1e300" with a valid rate and no explicit frame count:
        // the derived arithmetic refuses typed instead of trapping on the
        // Int conversion.
        let json = """
        {"streams":[{"codec_type":"video","codec_name":"h264","width":128,\
        "height":96,"avg_frame_rate":"24/1","duration":"1e300"}],\
        "format":{"duration":"1e300"}}
        """
        XCTAssertThrowsError(
            try G09R2EnhancementProbeParser.parseVideoFacts(
                json, byteCount: 1, sha256: "s")) { error in
            guard case G09R2EnhancementParsingError.malformedProbe(let reason) = error else {
                return XCTFail("expected malformedProbe, got \(error)")
            }
            XCTAssertEqual(reason, "unboundedDerivedFrames")
        }
        // An explicit frame count with the same hostile duration parses;
        // the downstream duration guard refuses the bound, not the parser.
        let explicit = """
        {"streams":[{"codec_type":"video","codec_name":"h264","width":128,\
        "height":96,"avg_frame_rate":"24/1","duration":"1e300","nb_frames":"48"}],\
        "format":{"duration":"1e300"}}
        """
        let facts = try G09R2EnhancementProbeParser.parseVideoFacts(
            explicit, byteCount: 1, sha256: "s")
        XCTAssertEqual(facts.frameCount, 48)
    }

    func testProbeNAFrameCountFallsBackToDerivation() throws {
        let derived = """
        {"streams":[{"codec_type":"video","codec_name":"h264","width":128,\
        "height":96,"avg_frame_rate":"24/1","duration":"2.000000",\
        "nb_frames":"N/A"}],"format":{"duration":"2.000000"}}
        """
        let facts = try G09R2EnhancementProbeParser.parseVideoFacts(
            derived, byteCount: 1, sha256: "s")
        XCTAssertEqual(facts.frameCount, 48)

        let unknown = """
        {"streams":[{"codec_type":"video","codec_name":"h264","width":128,\
        "height":96,"avg_frame_rate":"0/0","duration":"2.000000",\
        "nb_frames":"N/A"}],"format":{"duration":"2.000000"}}
        """
        let unknownFacts = try G09R2EnhancementProbeParser.parseVideoFacts(
            unknown, byteCount: 1, sha256: "s")
        XCTAssertEqual(unknownFacts.frameCount, 0,
                       "N/A without a rate stays unknown (0), never guessed")
        XCTAssertEqual(unknownFacts.frameRate, 0)
    }

    // MARK: - Output guards

    private func facts(width: Int, height: Int, fps: Double = 24,
                       duration: Double = 2, frames: Int = 48,
                       hasAudio: Bool, isHDR: Bool = false) -> G09R2MediaProbeFacts {
        G09R2MediaProbeFacts(
            isImage: false, width: width, height: height,
            durationSeconds: duration, frameRate: fps, frameCount: frames,
            hasAudio: hasAudio, codec: "h264", isHDR: isHDR,
            byteCount: 1, sha256: "s")
    }

    func testVerifyOutputRejectsLostSourceAudio() throws {
        let source = facts(width: 128, height: 96, hasAudio: true)
        let measured = facts(width: 128, height: 96, hasAudio: false)
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/clip.mp4",
            operation: .interpolation(targetFPS: 48),
            outputFileName: "out.mp4")
        XCTAssertThrowsError(
            try G09R2EnhancementGuards.verifyOutput(
                measured: measured, source: source, request: request)) { error in
            guard let refusal = error as? G09R2EnhancementRefusal else {
                return XCTFail("expected a typed refusal, got \(error)")
            }
            XCTAssertEqual(refusal.code,
                           G09R2EnhancementRefusal.unsupportedCombination("").code)
        }
    }

    func testVerifyOutputRejectsLostSourceHDR() throws {
        let source = facts(width: 3840, height: 2160, hasAudio: false, isHDR: true)
        let measured = facts(width: 3840, height: 2160, hasAudio: false, isHDR: false)
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/clip.mp4",
            operation: .superResolution(scaleFactor: 2),
            outputFileName: "out.mp4")
        XCTAssertThrowsError(
            try G09R2EnhancementGuards.verifyOutput(
                measured: measured, source: source, request: request))
    }

    func testVerifyOutputAcceptsPreservedAudioAndHDR() throws {
        let source = facts(width: 128, height: 96, hasAudio: true)
        let measured = facts(width: 128, height: 96, hasAudio: true)
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/clip.mp4",
            operation: .interpolation(targetFPS: 24),
            outputFileName: "out.mp4")
        XCTAssertNoThrow(
            try G09R2EnhancementGuards.verifyOutput(
                measured: measured, source: source, request: request))
    }

    func testProbeCommandsIncludeCodecTypeAndAllStreams() {
        let layout = G09R2EnhancementGuestLayout(
            jobID: "job-1", inputRelativePath: "Assets/clip.mp4",
            outputFileName: "out.mp4")
        let plan = G09R2EnhancementFFmpegPlan.interpolationScript(
            layout: layout, targetFPS: 48, sourceHasAudio: true)
        XCTAssertTrue(plan.script.contains("codec_type"))
        XCTAssertFalse(plan.script.contains("-select_streams v:0"),
                       "the probe must see every stream so audio presence is measured")
        let probeScript = G09R2EnhancementFFmpegPlan.probeScript(
            inputRelativePath: "Assets/clip.mp4")
        XCTAssertTrue(probeScript.contains("codec_type"))
        XCTAssertFalse(probeScript.contains("-select_streams v:0"))
    }
}
