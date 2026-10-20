import XCTest
import Foundation
import GRDB
import FloeCore
import FloePersistence
@testable import FloeAndroidCore

/// Authored-only tests for the Android credential vault OWNED-OPERATIONS
/// candidate (job-07f0d672e3854e17). This file is NOT executed by the
/// source-authoring job; it is host-runnable later against the original
/// file-backed `DatabaseManager`/schema-46 migrations, the admitted RB1
/// reviewed types (`RuntimeOwnerIdentity`, `RuntimeFacadeCode`) and test-only
/// gateway/registry doubles. No production fallback, real key, device or live
/// registry registration is used here.
///
/// All 36 vault methods from the parent suite are preserved with meaningful
/// assertions. Expectations changed ONLY for the corrected constructor /
/// operation-lifetime semantics Main proved (CV-R1): construction now runs
/// through `AndroidCredentialVault.joinRuntimeOwnership` under a trusted full
/// root+token+epoch identity; restart patterns retire the prior context first
/// (the retirement fence); the default-gateway test supplies a synthetic
/// owned-work port (the production default forwards to the REAL shared
/// `RuntimeOwnedWorkRegistry`, whose lifecycle admission unit tests by
/// design do not bootstrap); and same-account contention is FIFO lease-wait
/// serialization rather than refusal by one wrapper's private RAM gate. New
/// methods exercise the owned side-effect lifetime (controlled gateway
/// suspension + shared coordinator), the same-second queue truth (CV-R2), the
/// keyset fairness (CV-R3), the typed dispatcherUnresponsive semantics
/// (CV-R4), and the duplicate-owner / retirement admission boundaries.
final class AndroidCredentialVaultTests: XCTestCase {
    // MARK: - Trusted runtime identity helpers (synthetic, never real creds)

    /// RB1-legal synthetic owner token: 32 lowercase hex. Fixed synthetic
    /// string, NOT a credential. The synthetic root path is syntactically
    /// valid; admission is RAM-only bookkeeping and never touches the
    /// filesystem (RB1's owned-store actor creates real directories).
    private func syntheticToken() -> String {
        "0123456789abcdef0123456789abcdef"
    }

    private func makeIdentity(
        rootPath: String? = nil,
        token: String? = nil,
        epoch: UInt64 = 1
    ) throws -> RuntimeOwnerIdentity {
        let path = rootPath ?? "/private/tmp/floe-vault-tests/\(UUID().uuidString)"
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: path))
        return try XCTUnwrap(RuntimeOwnerIdentity(
            root: root, token: token ?? syntheticToken(), epoch: epoch))
    }

    override func setUp() {
        super.setUp()
        CredentialVaultRuntimeAdmission.removeAllForTesting()
        let registry = SecretGatewayRegistry.shared
        if registry.isRegistered { registry.unregister() }
    }

    override func tearDown() {
        CredentialVaultRuntimeAdmission.removeAllForTesting()
        let registry = SecretGatewayRegistry.shared
        if registry.isRegistered { registry.unregister() }
        super.tearDown()
    }

    /// Join (or share) a vault context the way the admitted RB1 owner does.
    /// `ownedWork` is ALWAYS the synthetic port double in unit tests — the
    /// production default (`RuntimeOwnedWorkRegistryAttachment.shared`) is
    /// exercised by RB1's own suite and later host integration; without a
    /// bootstrapped lifecycle it refuses every attach with `.notInstalled`
    /// BY DESIGN (fail-closed), which two tests below pin explicitly.
    private func makeVault(
        manager: DatabaseManager,
        identity: RuntimeOwnerIdentity,
        ownedWork: TestOwnedWork = TestOwnedWork(),
        gateway: TestGateway = TestGateway(),
        now: (@Sendable () -> Date)? = nil
    ) throws -> AndroidCredentialVault {
        if let now {
            return try AndroidCredentialVault.joinRuntimeOwnership(
                database: manager,
                identity: identity,
                ownedWork: ownedWork,
                gateway: gateway,
                now: now)
        }
        return try AndroidCredentialVault.joinRuntimeOwnership(
            database: manager,
            identity: identity,
            ownedWork: ownedWork,
            gateway: gateway)
    }

    // MARK: - Test gateway

    private enum GatewayFault: Sendable {
        case unavailable
        case rejected
        case effectUnknown
        case cancellation
        /// CV-R4: mirrors the ACTUAL mailbox watchdog settling an ALREADY
        /// CLAIMED ticket (SecretGatewayMailbox.swift lines 923..934: state
        /// `callerSettledExecutionOutstanding`, permit/effect-unknown
        /// retained): the store effect may have landed and the caller
        /// receives `dispatcherUnresponsive`. The vault must NOT treat this
        /// as proof of no effect.
        case claimedWatchdog

        var error: any Error {
            switch self {
            case .unavailable: return SecretGatewayError.needsConfiguration
            case .rejected: return SecretBackendError.mailboxSaturated
            case .effectUnknown: return SecretBackendError.internal
            case .cancellation: return CancellationError()
            case .claimedWatchdog: return SecretBackendError.dispatcherUnresponsive
            }
        }
    }

    /// Test-only synthetic gateway. It is never registered in
    /// SecretGatewayRegistry as a production path; the ONE test that
    /// exercises the default forwarder registers a distinct in-memory spy
    /// and unregisters it in the same test. Controlled suspension gates
    /// (writes + one-shot/standing delete gates) provide the deterministic
    /// interleavings Main asked for; the vault itself uses no timers.
    private actor TestGateway: AndroidSecretGateway {
        private var storage: [String: Data] = [:]
        private(set) var writes: [String] = []
        private(set) var reads: [String] = []
        private(set) var deletes: [String] = []
        /// Attempts that actually crossed the store boundary (after any
        /// fault throw). Distinguishes an authoritative cleanup from a
        /// failed attempt in the race tests.
        private(set) var successfulDeletes: [String] = []
        private var writeFault: GatewayFault?
        private var deleteFaultAll: GatewayFault?
        private var deleteFaults: [String: GatewayFault] = [:]
        private let onWrite: (@Sendable (String) async -> Void)?
        private var suspendWrites = false
        private var writeStarts = 0
        private var writeStartWaiters: [CheckedContinuation<Void, Never>] = []
        private var writeGates: [CheckedContinuation<Void, Never>] = []
        private var suspendDeletes = false
        private var suspendNextDelete = false
        private var deleteStarts = 0
        private var deleteStartWaiters: [CheckedContinuation<Void, Never>] = []
        private var deleteGates: [CheckedContinuation<Void, Never>] = []

        init(onWrite: (@Sendable (String) async -> Void)? = nil) {
            self.onWrite = onWrite
        }

        func read(reference: String) async throws -> Data? {
            reads.append(reference)
            return storage[reference]
        }

        func write(reference: String, value: Data) async throws {
            writes.append(reference)
            writeStarts += 1
            let waiters = writeStartWaiters
            writeStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if let onWrite { await onWrite(reference) }
            if let writeFault {
                switch writeFault {
                case .effectUnknown, .claimedWatchdog:
                    // The store effect may have landed even though the
                    // caller cannot know (the traced mailbox/claim paths).
                    storage[reference] = value
                default:
                    break
                }
                throw writeFault.error
            }
            if suspendWrites {
                await withCheckedContinuation { continuation in
                    writeGates.append(continuation)
                }
            }
            if Task.isCancelled { throw CancellationError() }
            storage[reference] = value
        }

        func delete(reference: String) async throws {
            deletes.append(reference)
            deleteStarts += 1
            let waiters = deleteStartWaiters
            deleteStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if suspendNextDelete {
                suspendNextDelete = false
                await withCheckedContinuation { continuation in
                    deleteGates.append(continuation)
                }
            } else if suspendDeletes {
                await withCheckedContinuation { continuation in
                    deleteGates.append(continuation)
                }
            }
            if let fault = deleteFaults[reference] ?? deleteFaultAll {
                throw fault.error
            }
            successfulDeletes.append(reference)
            storage[reference] = nil
        }

        func setWriteFault(_ fault: GatewayFault?) { writeFault = fault }
        func setDeleteFaultAll(_ fault: GatewayFault?) { deleteFaultAll = fault }
        func setDeleteFault(_ fault: GatewayFault?, for reference: String) {
            deleteFaults[reference] = fault
        }
        func seed(reference: String, value: Data) { storage[reference] = value }
        func value(for reference: String) -> Data? { storage[reference] }
        func setSuspendWrites(_ suspended: Bool) { suspendWrites = suspended }
        func resetWriteSignal() { writeStarts = 0 }

        func waitForWriteStart() async {
            if writeStarts > 0 { return }
            await withCheckedContinuation { continuation in
                writeStartWaiters.append(continuation)
            }
        }

        func resumeWrites() {
            let gates = writeGates
            writeGates.removeAll()
            for gate in gates { gate.resume() }
        }

        func setSuspendDeletes(_ suspended: Bool) { suspendDeletes = suspended }
        func setSuspendNextDelete(_ armed: Bool) { suspendNextDelete = armed }
        func resetDeleteSignal() { deleteStarts = 0 }

        func waitForDeleteStart() async {
            if deleteStarts > 0 { return }
            await withCheckedContinuation { continuation in
                deleteStartWaiters.append(continuation)
            }
        }

        func resumeDeletes() {
            let gates = deleteGates
            deleteGates.removeAll()
            for gate in gates { gate.resume() }
        }
    }

    // MARK: - Test owned-work port (synthetic mirror of the REAL registry)

    /// Synthetic double with the SAME closed contract as the real
    /// `RuntimeOwnedWorkRegistry` port (`VaultOwnedWorkAttaching`). It proves
    /// receipt lifetime (attach/detach counts), admission refusal and
    /// fail-closed behaviour; it is fault injection only and never a product
    /// fallback.
    private final class TestOwnedWork: VaultOwnedWorkAttaching, @unchecked Sendable {
        private let lock = NSLock()
        private var live: [String: (epoch: UInt64, ownerID: String)] = [:]
        private var counter: UInt64 = 0
        private var forcedRejection: RuntimeFacadeCode?

        func setForcedRejection(_ code: RuntimeFacadeCode?) {
            lock.lock(); forcedRejection = code; lock.unlock()
        }

        func attachVaultMaintenance(
            epoch: UInt64, ownerID: String
        ) -> VaultOwnedWorkAttach {
            lock.lock()
            defer { lock.unlock() }
            if let code = forcedRejection {
                forcedRejection = nil
                return .rejected(code)
            }
            counter += 1
            let hex = String(format: "%032llx", counter)
            let receipt = "work:v1:" + hex
            live[receipt] = (epoch, ownerID)
            return .attached(receipt: receipt)
        }

        func detachVaultMaintenance(
            receipt: String, epoch: UInt64, ownerID: String
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = live[receipt],
                  entry.epoch == epoch, entry.ownerID == ownerID else {
                return false
            }
            live.removeValue(forKey: receipt)
            return true
        }

        func isVaultMaintenanceAttached(
            receipt: String, epoch: UInt64, ownerID: String
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = live[receipt] else { return false }
            return entry.epoch == epoch && entry.ownerID == ownerID
        }

        var liveCount: Int {
            lock.lock(); defer { lock.unlock() }
            return live.count
        }
    }

    private actor EventRecorder {
        private(set) var events: [String] = []
        func append(_ event: String) { events.append(event) }
    }

    // MARK: - Helpers

    private func migratedManager() async throws -> DatabaseManager {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        return manager
    }

    private func makeFileDatabase() throws -> (directory: URL, manager: DatabaseManager) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-credential-vault-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let manager = try DatabaseManager(path: directory.appendingPathComponent("db.sqlite"))
        return (directory, manager)
    }

    private func reference(account: String) -> String {
        SecretGatewayNaming.opaqueReference(
            namespace: "keychainAccount", account: account)
    }

    private func account(for id: UUID) -> String {
        "credential.\(id.uuidString)"
    }

    private func unwrapRecord(
        _ record: CredentialRecord?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CredentialRecord {
        try XCTUnwrap(record, file: file, line: line)
    }

    /// Direct narrow read of the ORIGINAL queue table (test observability of
    /// the durable row — never a production path). The value is a
    /// second-resolution wall clock: an observation, not a generation
    /// (CV-R2).
    private func readQueueGeneration(
        manager: DatabaseManager, account: String
    ) async throws -> String? {
        try await manager.reader { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT enqueued_at FROM credential_deletion_queue
                    WHERE keychain_account = ?
                    """,
                arguments: [account])
        }
    }

    /// Inserts a synthetic durable intent row into the ORIGINAL queue with a
    /// fixed literal second-resolution value, simulating a process death that
    /// left the row behind (crash cut-point staging; the same columns the
    /// original trigger writes).
    private func insertIntentRow(
        manager: DatabaseManager, account: String, enqueuedAt: String
    ) async throws {
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO credential_deletion_queue (
                        keychain_account, synchronizable, enqueued_at, last_error
                    ) VALUES (?, 0, ?, NULL)
                    """,
                arguments: [account, enqueuedAt])
        }
    }

    /// Raw queue-row removal used ONLY to stage uncoordinated/late-arriving
    /// observations in the deterministic race tests (test staging; the
    /// supported vault writers are lease-serialized, which the CV-R1 tests
    /// pin instead).
    private func rawDeleteQueueRow(
        manager: DatabaseManager, account: String
    ) async throws {
        try await manager.writer { db in
            try db.execute(
                sql: """
                    DELETE FROM credential_deletion_queue WHERE keychain_account = ?
                    """,
                arguments: [account])
        }
    }

    // MARK: - Capture ordering and identity

    func testCaptureWritesGatewayBeforeMetadataAndPersistsCanonicalReference() async throws {
        let manager = try await migratedManager()
        // Two actor wrappers over the ONE DatabaseManager are fine: the vault
        // creates (and exports) its own store; this test store observes the
        // same database through the same manager. (Constructor correction:
        // joined under one trusted identity instead of a bare init.)
        let store = CredentialStore(database: manager)
        let recorder = EventRecorder()
        let targetID = UUID()
        let gateway = TestGateway(onWrite: { _ in
            let record: CredentialRecord?
            do { record = try await store.record(id: targetID) }
            catch { record = nil }
            await recorder.append("write:recordExists=\(record != nil)")
        })
        let ownedWork = TestOwnedWork()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(),
            ownedWork: ownedWork, gateway: gateway)
        let secret = Data("synthetic-vault-secret".utf8)

        let handle = try await vault.capture(
            secret, kind: .websitePassword, owner: .vault,
            label: "Synthetic website", id: targetID)

        XCTAssertEqual(handle.id, targetID)
        let record = try unwrapRecord(try await store.record(id: targetID))
        XCTAssertEqual(record.id, targetID)
        XCTAssertEqual(record.keychainAccount, account(for: targetID))
        XCTAssertFalse(record.synchronizable)
        XCTAssertFalse(record.deviceBound)
        XCTAssertNil(record.hostID)

        let expectedReference = reference(account: record.keychainAccount)
        let writes = await gateway.writes
        XCTAssertEqual(writes, [expectedReference])
        XCTAssertTrue(SecretGatewayIdentity.isCanonicalReference(expectedReference))
        XCTAssertEqual(expectedReference.count, 71)
        XCTAssertEqual(expectedReference, SecretGatewayNaming.opaqueReference(
            namespace: "keychainAccount", account: record.keychainAccount))

        let events = await recorder.events
        XCTAssertEqual(events, ["write:recordExists=false"])

        // The durable claim is finalized on the success path, so a committed
        // capture leaves NO queue row; and the owned operation has FULLY
        // settled (lease released + receipt detached) by the time the handle
        // comes back — ownership never outlives actual completion, and never
        // ends before it.
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let generation = try await readQueueGeneration(
            manager: manager, account: record.keychainAccount)
        XCTAssertNil(generation)
        let summary = await vault.ownedOperationSummary
        XCTAssertEqual(summary.accounts, 0)
        XCTAssertEqual(summary.handles, 0)
        XCTAssertEqual(ownedWork.liveCount, 0)

        let resolved = try await vault.resolveForApprovedUse(handle)
        XCTAssertEqual(resolved, secret)
    }

    func testCaptureUsesOnlyDurableHostsAndDropsUnknownHost() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let hostID = UUID()
        try await RemoteHostStore(database: manager).saveHost(
            id: hostID, displayName: "Lab host", address: "192.0.2.10",
            port: 22, user: "tester", authJSON: #"{"none":{}}"#,
            jumpChainJSON: "[]", hostKeyPolicy: "trustOnFirstUse",
            allowsLegacyAlgorithms: false, vncEndpointJSON: nil)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: TestGateway())

        let withHostID = UUID()
        _ = try await vault.capture(
            Data("synthetic-secret-a".utf8), kind: .sshPassword, owner: .vault,
            label: "Host password", id: withHostID, hostID: hostID)
        let durable = try unwrapRecord(try await store.record(id: withHostID))
        XCTAssertEqual(durable.hostID, hostID)

        let withoutHostID = UUID()
        _ = try await vault.capture(
            Data("synthetic-secret-b".utf8), kind: .sshPassword, owner: .vault,
            label: "New host password", id: withoutHostID, hostID: UUID())
        let transient = try unwrapRecord(try await store.record(id: withoutHostID))
        XCTAssertNil(transient.hostID)
    }

    func testCaptureRefusesExistingIDBeforeAnySecretWrite() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let targetID = UUID()
        try await store.save(CredentialRecord(
            id: targetID, kind: .genericToken, owner: .vault, label: "Existing"))
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)

        do {
            _ = try await vault.capture(
                Data("synthetic-secret".utf8), kind: .genericToken, owner: .vault,
                label: "Duplicate", id: targetID)
            XCTFail("capture must not overwrite an existing id")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .credentialConflict(targetID))
        }
        let writes = await gateway.writes
        XCTAssertTrue(writes.isEmpty)
        // The refused capture may not leave a claim either.
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testEmptyAndOversizedSecretsAreRejectedBeforeGateway() async throws {
        let manager = try await migratedManager()
        let gateway = TestGateway()
        let ownedWork = TestOwnedWork()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(),
            ownedWork: ownedWork, gateway: gateway)
        let store = await vault.records

        do {
            _ = try await vault.capture(
                Data(), kind: .genericToken, owner: .vault,
                label: "Empty", id: UUID())
            XCTFail("empty secret must be rejected")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .invalidSecret)
        }

        let oversized = Data(count: SecretGatewayLimits.maximumSecretBytes + 1)
        do {
            _ = try await vault.capture(
                oversized, kind: .genericToken, owner: .vault,
                label: "Too large", id: UUID())
            XCTFail("oversized secret must be rejected")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .invalidSecret)
        }

        let writes = await gateway.writes
        XCTAssertTrue(writes.isEmpty, "validation precedes any gateway use")
        // Lifetime correction: validation precedes even the owned-operation
        // attach — no receipt and no lease are minted for a rejected
        // argument.
        XCTAssertEqual(ownedWork.liveCount, 0)
        let summary = await vault.ownedOperationSummary
        XCTAssertEqual(summary.accounts, 0)
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCaptureRefusesAccountOwnedByAnotherRecordWithoutWriting() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let targetID = UUID()
        try await store.save(CredentialRecord(
            id: UUID(), kind: .genericToken, owner: .vault, label: "Account owner",
            keychainAccount: account(for: targetID)))
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)

        do {
            _ = try await vault.capture(
                Data("synthetic-shared-account".utf8), kind: .genericToken,
                owner: .vault, label: "Must refuse", id: targetID)
            XCTFail("capture must not reuse another record's account")
        } catch let error as AndroidCredentialVaultError {
            // The account conflict is decided by the atomic claim
            // transaction (targeted UNIQUE lookup), not by materializing
            // every record.
            XCTAssertEqual(error, .credentialConflict(targetID))
        }
        let writes = await gateway.writes
        XCTAssertTrue(writes.isEmpty)
        let deletes = await gateway.deletes
        XCTAssertTrue(deletes.isEmpty)
        let target = try await store.record(id: targetID)
        XCTAssertNil(target)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Metadata failure / unknown effects

    func testMetadataFailureCompensatesSecretAndNeverAdmitsMetadata() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let targetID = UUID()
        // A conversation owner must exist in the original schema. This save
        // therefore fails the real foreign-key constraint after the secret
        // write, exercising the metadata-failure compensation path.
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let secret = Data("synthetic-metadata-failure".utf8)

        do {
            _ = try await vault.capture(
                secret, kind: .genericToken, owner: .conversation(UUID()),
                label: "Missing conversation", id: targetID)
            XCTFail("metadata failure must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .captureMetadataFailedSecretRemoved(targetID))
        }

        let record = try await store.record(id: targetID)
        XCTAssertNil(record)
        let expectedReference = reference(account: account(for: targetID))
        let deletes = await gateway.deletes
        XCTAssertEqual(deletes, [expectedReference])
        let remainingValue = await gateway.value(for: expectedReference)
        XCTAssertNil(remainingValue)
        // The successful compensation finalized the durable claim row.
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCompensationDeleteFailureIsTypedAndRetryable() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let targetID = UUID()
        let gateway = TestGateway()
        await gateway.setDeleteFaultAll(.effectUnknown)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let secret = Data("synthetic-orphan".utf8)

        do {
            _ = try await vault.capture(
                secret, kind: .genericToken, owner: .conversation(UUID()),
                label: "Missing conversation", id: targetID)
            XCTFail("unclean compensation must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .captureCleanupIncomplete(targetID))
        }

        let expectedReference = reference(account: account(for: targetID))
        let orphan = await gateway.value(for: expectedReference)
        XCTAssertEqual(orphan, secret)
        let record = try await store.record(id: targetID)
        XCTAssertNil(record)
        // Recovery: the failed compensation keeps the durable intent in the
        // ORIGINAL queue. Retry does not require a caller-retained id.
        let generation = try await readQueueGeneration(
            manager: manager, account: account(for: targetID))
        XCTAssertNotNil(generation)

        await gateway.setDeleteFaultAll(nil)
        try await vault.discardUncommittedSecret(id: targetID)
        let cleaned = await gateway.value(for: expectedReference)
        XCTAssertNil(cleaned)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testUnknownWriteOutcomeIsCompensatedBeforeMetadata() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let targetID = UUID()
        let gateway = TestGateway()
        await gateway.setWriteFault(.effectUnknown)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)

        do {
            _ = try await vault.capture(
                Data("synthetic-unknown".utf8), kind: .genericToken, owner: .vault,
                label: "Unknown write", id: targetID)
            XCTFail("unknown write must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .gatewayWriteEffectUnknownCompensated(targetID))
        }
        let record = try await store.record(id: targetID)
        XCTAssertNil(record)
        let expectedReference = reference(account: account(for: targetID))
        let deletes = await gateway.deletes
        XCTAssertEqual(deletes, [expectedReference])
        let remainingValue = await gateway.value(for: expectedReference)
        XCTAssertNil(remainingValue)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testUnknownWriteWithFailedCompensationLeavesExplicitBlockingEvidence() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let targetID = UUID()
        let gateway = TestGateway()
        await gateway.setWriteFault(.effectUnknown)
        await gateway.setDeleteFaultAll(.effectUnknown)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)

        do {
            _ = try await vault.capture(
                Data("synthetic-unknown-orphan".utf8), kind: .genericToken,
                owner: .vault, label: "Unknown write", id: targetID)
            XCTFail("unclean unknown write must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .captureCleanupIncomplete(targetID))
        }
        let record = try await store.record(id: targetID)
        XCTAssertNil(record)
        let expectedReference = reference(account: account(for: targetID))
        let orphan = await gateway.value(for: expectedReference)
        XCTAssertNotNil(orphan)
        // The blocking evidence is the DURABLE queue row itself, not only
        // the caller-retained handle id.
        let pending = try await store.pendingDeletions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.keychainAccount, account(for: targetID))
    }

    func testAbsentAndRejectedGatewaysFailBeforeMetadata() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)

        await gateway.setWriteFault(.unavailable)
        do {
            _ = try await vault.capture(
                Data("synthetic-a".utf8), kind: .genericToken, owner: .vault,
                label: "No gateway", id: UUID())
            XCTFail("absent gateway must fail closed")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .gatewayFailure(
                operation: .write, kind: .unavailable))
        }

        await gateway.setWriteFault(.rejected)
        do {
            _ = try await vault.capture(
                Data("synthetic-b".utf8), kind: .genericToken, owner: .vault,
                label: "Rejected", id: UUID())
            XCTFail("rejected gateway must not admit metadata")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .gatewayFailure(
                operation: .write, kind: .rejected))
        }

        let deletes = await gateway.deletes
        XCTAssertTrue(deletes.isEmpty, "no effect => no compensation")
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)
        // A provably no-effect write (pre-queue rejection ONLY, CV-R4)
        // releases the pre-write claim, so no ghost intent blocks the
        // account later.
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - CV-R4: dispatcherUnresponsive classification

    /// The ACTUAL mailbox watchdog emits `dispatcherUnresponsive` for tickets
    /// ALREADY in `.claimed` state (SecretGatewayMailbox.swift lines
    /// 923..934: `callerSettledExecutionOutstanding`, permit/effect-unknown
    /// retained). The claimed write may therefore have landed. The vault must
    /// treat it as `.effectUnknown`: it ATTEMPTS the compensation and — when
    /// the compensation cannot complete — KEEPS the durable cleanup intent
    /// instead of releasing the claim as a "known no effect". This is the
    /// CV-R4 regression test against parent06, which classified this error as
    /// `.rejected` and released the claim with NO delete attempt.
    func testClaimedWatchdogUnresponsiveKeepsDurableIntentUnlikePreQueueRejection() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let targetID = UUID()
        let gateway = TestGateway()
        await gateway.setWriteFault(.claimedWatchdog)
        // Compensation cannot complete either: quiescence is unprovable.
        await gateway.setDeleteFaultAll(.effectUnknown)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let secret = Data("synthetic-claimed-watchdog".utf8)

        do {
            _ = try await vault.capture(
                secret, kind: .genericToken, owner: .vault,
                label: "Claimed watchdog", id: targetID)
            XCTFail("an ambiguous claimed error must not report success")
        } catch let error as AndroidCredentialVaultError {
            // The effectUnknown path (compensation attempted and failed),
            // NOT the `.gatewayFailure(kind: .rejected)` parent06 produced.
            XCTAssertEqual(error, .captureCleanupIncomplete(targetID))
        }
        let expectedReference = reference(account: account(for: targetID))
        // The compensation WAS attempted (parent06 never attempted a delete
        // for this error).
        let deletes = await gateway.deletes
        XCTAssertEqual(deletes, [expectedReference])
        // The durable intent REMAINS: the error alone released nothing.
        let pending = try await store.pendingDeletions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.keychainAccount, account(for: targetID))
        let record = try await store.record(id: targetID)
        XCTAssertNil(record)

        // And the durable row actually recovers the account once the gateway
        // settles for real: the service drain cleans the landed claimed
        // write's secret with no caller-retained id.
        await gateway.setWriteFault(nil)
        await gateway.setDeleteFaultAll(nil)
        let report = await vault.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 1)
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.remaining, 0)
        let cleaned = await gateway.value(for: expectedReference)
        XCTAssertNil(cleaned)
    }

    /// The same claimed-watchdog error WITH a compensation that DOES
    /// complete: the traced production ordering (frozen Kotlin store's single
    /// shared I/O executor + per-record lock; dispatcher validates native
    /// isLive before the UNDISPATCHED store launch and `runChild` awaits the
    /// actual store effect before completing callers) makes the compensating
    /// delete's authoritative completion real quiescence for that record's
    /// lane. The claim may then — and only then — be finalized. The final
    /// gateway authority remains the pending qualifier (job-cd5…).
    func testWatchdogUnresponsiveCompensationSuccessFinalizesClaim() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let targetID = UUID()
        let gateway = TestGateway()
        await gateway.setWriteFault(.claimedWatchdog)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let secret = Data("synthetic-watchdog-compensated".utf8)

        do {
            _ = try await vault.capture(
                secret, kind: .genericToken, owner: .vault,
                label: "Watchdog compensated", id: targetID)
            XCTFail("ambiguous claimed write must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .gatewayWriteEffectUnknownCompensated(targetID))
        }
        let expectedReference = reference(account: account(for: targetID))
        let value = await gateway.value(for: expectedReference)
        XCTAssertNil(value, "the landed claimed write was compensated")
        let deletes = await gateway.deletes
        XCTAssertEqual(deletes, [expectedReference])
        // Compensation TRUTH (not the error classification alone) finalized
        // the claim: the queue is empty and nothing later deletes the
        // account's row without a fresh revalidated observation.
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let record = try await store.record(id: targetID)
        XCTAssertNil(record)
    }

    // MARK: - Persistence / reopen

    func testMetadataAndCanonicalReferenceSurviveDatabaseReopen() async throws {
        let (directory, manager) = try makeFileDatabase()
        let gateway = TestGateway()
        let identity1 = try makeIdentity()
        let vault = try makeVault(
            manager: manager, identity: identity1, gateway: gateway)
        let store = await vault.records
        let targetID = UUID()
        let secret = Data("synthetic-reopen-secret".utf8)

        try await manager.migrate()
        _ = try await vault.capture(
            secret, kind: .sshPrivateKey, owner: .vault,
            label: "Reopen", id: targetID)
        let original = try unwrapRecord(try await store.record(id: targetID))
        let expectedReference = reference(account: original.keychainAccount)

        // Retirement fence before the physical handle goes away: the prior
        // context's RAM ownership ends only after its operations settled
        // (they have — the capture returned). The durable queue is empty
        // because the success path finalized the claim.
        try await vault.retireRuntimeOwnership()
        try await manager.close()

        // A reopened manager belongs to a NEWER typed lifecycle epoch under
        // the SAME full root+token (the in-process mirror of a process
        // restart; RB1's typed host epoch advances per real generation).
        let reopened = try DatabaseManager(
            path: directory.appendingPathComponent("db.sqlite"))
        try await reopened.migrate()
        let identity2 = try XCTUnwrap(RuntimeOwnerIdentity(
            root: identity1.root, token: identity1.token, epoch: 2))
        let reopenedVault = try AndroidCredentialVault.joinRuntimeOwnership(
            database: reopened,
            identity: identity2,
            ownedWork: TestOwnedWork(),
            gateway: gateway)
        let persisted = try unwrapRecord(
            try await reopenedVault.records.record(id: targetID))
        XCTAssertEqual(persisted.keychainAccount, original.keychainAccount)
        XCTAssertEqual(persisted.kind, .sshPrivateKey)
        let value = try await reopenedVault.resolveForApprovedUse(
            CredentialHandle(id: targetID))
        XCTAssertEqual(value, secret)
        let reads = await gateway.reads
        XCTAssertEqual(reads, [expectedReference])

        // A successful capture leaves nothing durable; the restart drain must
        // therefore observe zero intent rows (the claim was finalized).
        let report = await reopenedVault.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 0)
        XCTAssertEqual(report.completed, 0)
        XCTAssertEqual(report.clearedObsolete, 0)
        XCTAssertEqual(report.remaining, 0)
        let resolvedAgain = try await reopenedVault.resolveForApprovedUse(
            CredentialHandle(id: targetID))
        XCTAssertEqual(resolvedAgain, secret)

        try await reopened.close()
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Mutation / status / sync honesty

    func testReplaceSecretKeepsHandleAndNormalizesLegacySyncMetadata() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let targetID = UUID()
        _ = try await vault.capture(
            Data("synthetic-old".utf8), kind: .websitePassword, owner: .vault,
            label: "Legacy", id: targetID)

        var legacy = try unwrapRecord(try await store.record(id: targetID))
        legacy.synchronizable = true
        legacy.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.save(legacy)

        let replacement = Data("synthetic-new".utf8)
        try await vault.replaceSecret(
            CredentialHandle(id: targetID), secret: replacement)
        let current = try unwrapRecord(try await store.record(id: targetID))
        XCTAssertFalse(current.synchronizable)
        XCTAssertGreaterThan(current.updatedAt, legacy.updatedAt)
        XCTAssertEqual(current.keychainAccount, legacy.keychainAccount)

        let resolved = try await vault.resolveForApprovedUse(
            CredentialHandle(id: targetID))
        XCTAssertEqual(resolved, replacement)
    }

    func testUpdateLabelAndPromoteToVaultKeepStableIdentity() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: TestGateway())
        let conversationID = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await SQLiteConversationStore(database: manager).saveConversation(
            ConversationRecord(
                id: conversationID, title: "Credential owner",
                createdAt: date, updatedAt: date))
        let targetID = UUID()
        _ = try await vault.capture(
            Data("synthetic-owner-secret".utf8), kind: .vncPassword,
            owner: .conversation(conversationID), label: "Before", id: targetID)

        try await vault.updateLabel(
            CredentialHandle(id: targetID), label: "After")
        var record = try unwrapRecord(try await store.record(id: targetID))
        XCTAssertEqual(record.label, "After")
        XCTAssertEqual(record.owner, .conversation(conversationID))
        XCTAssertEqual(record.keychainAccount, account(for: targetID))

        try await vault.promoteToVault(CredentialHandle(id: targetID))
        record = try unwrapRecord(try await store.record(id: targetID))
        XCTAssertEqual(record.owner, .vault)
        XCTAssertEqual(record.keychainAccount, account(for: targetID))

        let status = try await vault.status(CredentialHandle(id: targetID))
        XCTAssertEqual(status, .syncUnavailable)
        XCTAssertFalse(status.isSyncUsable)
        XCTAssertFalse(AndroidCredentialVault.savedCredentialSyncAvailable)
    }

    func testRegisterExistingRefusesSyncBeforeMetadataAndNormalizesLocalRecord() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: TestGateway())
        let accountName = "floe.provider.synthetic-\(UUID().uuidString)"

        try await vault.registerExisting(
            account: accountName, kind: .providerAPIKey,
            label: "Synthetic provider", synchronizable: false)
        let records = try await store.records(owner: .vault)
        let record = try XCTUnwrap(records.first(where: {
            $0.keychainAccount == accountName
        }))
        XCTAssertFalse(record.synchronizable)
        XCTAssertEqual(record.kind, .providerAPIKey)
        XCTAssertEqual(reference(account: record.keychainAccount).count, 71)
        // The registration claim is finalized: no durable row remains.
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)

        do {
            try await vault.registerExisting(
                account: "floe.provider.sync-\(UUID().uuidString)",
                kind: .providerAPIKey, label: "Sync", synchronizable: true)
            XCTFail("sync registration must be refused before metadata")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .syncUnavailable)
        }
        let after = try await store.records(owner: .vault)
        XCTAssertEqual(after.count, 1)
    }

    // MARK: - Deletion / durable queue

    func testRegisterExistingRefusesAccountWithPendingDeletion() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let targetID = UUID()
        _ = try await vault.capture(
            Data("synthetic-register-pending".utf8), kind: .genericToken,
            owner: .vault, label: "Delete first", id: targetID)
        await gateway.setDeleteFaultAll(.effectUnknown)
        let outcome = try await vault.delete(CredentialHandle(id: targetID))
        XCTAssertEqual(outcome.secretCleanup, .pendingDurableQueue)

        do {
            try await vault.registerExisting(
                account: account(for: targetID), kind: .genericToken,
                label: "Must not register", synchronizable: false)
            XCTFail("registration must refuse an account with a pending deletion")
        } catch let error as AndroidCredentialVaultError {
            if case .referenceCleanupPending = error {
                // expected
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)
        let pending = try await store.pendingDeletions()
        XCTAssertEqual(pending.count, 1)
    }

    func testDeleteRemovesMetadataSecretAndQueueRow() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let targetID = UUID()
        _ = try await vault.capture(
            Data("synthetic-delete".utf8), kind: .genericToken, owner: .vault,
            label: "Delete", id: targetID)
        let record = try unwrapRecord(try await store.record(id: targetID))

        let outcome = try await vault.delete(CredentialHandle(id: targetID))
        XCTAssertTrue(outcome.metadataExisted)
        XCTAssertEqual(outcome.secretCleanup, .completed)
        let deleted = try await store.record(id: targetID)
        XCTAssertNil(deleted)
        let expectedReference = reference(account: record.keychainAccount)
        let value = await gateway.value(for: expectedReference)
        XCTAssertNil(value)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)

        do {
            _ = try await vault.resolveForApprovedUse(
                CredentialHandle(id: targetID))
            XCTFail("a deleted handle must not resolve")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .credentialNotFound(targetID))
        }
    }

    func testDeleteGatewayFailureRetainsDurableQueueForRestartRetry() async throws {
        let (directory, manager) = try makeFileDatabase()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let identity1 = try makeIdentity()
        let vault = try makeVault(
            manager: manager, identity: identity1, gateway: gateway)
        let targetID = UUID()
        let secret = Data("synthetic-delete-retry".utf8)
        try await manager.migrate()
        _ = try await vault.capture(
            secret, kind: .genericToken, owner: .vault,
            label: "Retry", id: targetID)
        let record = try unwrapRecord(try await store.record(id: targetID))
        let expectedReference = reference(account: record.keychainAccount)
        await gateway.setDeleteFaultAll(.effectUnknown)

        let outcome = try await vault.delete(CredentialHandle(id: targetID))
        XCTAssertTrue(outcome.metadataExisted)
        XCTAssertEqual(outcome.secretCleanup, .pendingDurableQueue)
        let pending = try await store.pendingDeletions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.keychainAccount, record.keychainAccount)
        let lastError = try await manager.reader { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT last_error FROM credential_deletion_queue
                    WHERE keychain_account = ?
                    """,
                arguments: [record.keychainAccount])
        }
        XCTAssertEqual(lastError, "gateway deletion outcome unknown")
        XCTAssertFalse(lastError?.contains("synthetic-delete-retry") ?? false)

        // Retirement fence + closed handle + newer epoch = restart mirror.
        try await vault.retireRuntimeOwnership()
        try await manager.close()

        let reopened = try DatabaseManager(
            path: directory.appendingPathComponent("db.sqlite"))
        try await reopened.migrate()
        let restartedGateway = TestGateway()
        await restartedGateway.seed(reference: expectedReference, value: secret)
        let identity2 = try XCTUnwrap(RuntimeOwnerIdentity(
            root: identity1.root, token: identity1.token, epoch: 2))
        let restartedVault = try AndroidCredentialVault.joinRuntimeOwnership(
            database: reopened,
            identity: identity2,
            ownedWork: TestOwnedWork(),
            gateway: restartedGateway)
        let report = await restartedVault.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 1)
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.clearedObsolete, 0)
        XCTAssertEqual(report.remaining, 0)
        let remainingValue = await restartedGateway.value(for: expectedReference)
        XCTAssertNil(remainingValue)
        let remainingQueue = try await restartedVault.records.pendingDeletions()
        XCTAssertTrue(remainingQueue.isEmpty)

        try await reopened.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testPartialDrainFailureKeepsOnlyFailedRow() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let firstID = UUID()
        let secondID = UUID()
        _ = try await vault.capture(
            Data("synthetic-first".utf8), kind: .genericToken, owner: .vault,
            label: "First", id: firstID)
        _ = try await vault.capture(
            Data("synthetic-second".utf8), kind: .genericToken, owner: .vault,
            label: "Second", id: secondID)
        let firstRecord = try unwrapRecord(try await store.record(id: firstID))
        let secondRecord = try unwrapRecord(try await store.record(id: secondID))
        let firstReference = reference(account: firstRecord.keychainAccount)
        let secondReference = reference(account: secondRecord.keychainAccount)
        try await store.delete(id: firstID)
        try await store.delete(id: secondID)
        await gateway.setDeleteFault(.effectUnknown, for: firstReference)

        let report = await vault.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 2)
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.clearedObsolete, 0)
        XCTAssertEqual(report.skippedConcurrent, 0)
        XCTAssertEqual(report.truncatedBudget, false)
        XCTAssertNil(report.ownedWorkAdmissionRejected)
        XCTAssertEqual(report.remaining, 1)
        let firstValue = await gateway.value(for: firstReference)
        XCTAssertNotNil(firstValue)
        let secondValue = await gateway.value(for: secondReference)
        XCTAssertNil(secondValue)

        await gateway.setDeleteFault(nil, for: firstReference)
        let retry = await vault.drainDeletionQueue()
        XCTAssertEqual(retry.pendingAtStart, 1)
        XCTAssertEqual(retry.completed, 1)
        XCTAssertEqual(retry.failed, 0)
        XCTAssertEqual(retry.remaining, 0)
        let cleanedFirst = await gateway.value(for: firstReference)
        XCTAssertNil(cleanedFirst)
    }

    func testCaptureRefusesToWriteToReferenceWithPendingDeletionCleanup() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let targetID = UUID()
        let originalSecret = Data("synthetic-original".utf8)
        _ = try await vault.capture(
            originalSecret, kind: .genericToken, owner: .vault,
            label: "Original", id: targetID)
        let record = try unwrapRecord(try await store.record(id: targetID))
        let expectedReference = reference(account: record.keychainAccount)
        await gateway.setDeleteFaultAll(.effectUnknown)

        let outcome = try await vault.delete(CredentialHandle(id: targetID))
        XCTAssertEqual(outcome.secretCleanup, .pendingDurableQueue)
        let pending = try await store.pendingDeletions()
        XCTAssertEqual(pending.count, 1)

        let replacement = Data("synthetic-replacement".utf8)
        do {
            _ = try await vault.capture(
                replacement, kind: .genericToken, owner: .vault,
                label: "Replacement", id: targetID)
            XCTFail("capture must not write through a pending deletion row")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .referenceCleanupPending(targetID))
        }
        let writesAfterRefusal = await gateway.writes
        XCTAssertEqual(writesAfterRefusal, [expectedReference])
        let oldValue = await gateway.value(for: expectedReference)
        XCTAssertEqual(oldValue, originalSecret)

        await gateway.setDeleteFaultAll(nil)
        _ = try await vault.capture(
            replacement, kind: .genericToken, owner: .vault,
            label: "Replacement", id: targetID)
        let newValue = await gateway.value(for: expectedReference)
        XCTAssertEqual(newValue, replacement)
        let remaining = try await store.pendingDeletions()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Reentrancy / cancellation / races

    func testConcurrentSameHandleMutationIsRejectedAndLateResultCannotResurrect() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let targetID = UUID()
        _ = try await vault.capture(
            Data("synthetic-before".utf8), kind: .genericToken, owner: .vault,
            label: "Before", id: targetID)
        await gateway.setSuspendWrites(true)
        await gateway.resetWriteSignal()

        let replacement = Data("synthetic-after".utf8)
        let replaceTask = Task {
            try await vault.replaceSecret(
                CredentialHandle(id: targetID), secret: replacement)
        }
        await gateway.waitForWriteStart()

        do {
            _ = try await vault.delete(CredentialHandle(id: targetID))
            XCTFail("same-handle delete must be rejected while replace is in flight")
        } catch let error as AndroidCredentialVaultError {
            // The handle gate is now SHARED through the coordinator; same-
            // handle contention keeps the parent's immediate rejection.
            XCTAssertEqual(error, .operationInFlight(targetID))
        }

        await gateway.resumeWrites()
        try await replaceTask.value
        let record = try unwrapRecord(try await store.record(id: targetID))
        XCTAssertEqual(record.id, targetID)
        let resolved = try await vault.resolveForApprovedUse(
            CredentialHandle(id: targetID))
        XCTAssertEqual(resolved, replacement)
    }

    /// CV-R1 lifetime correction (meaningful change, guard coverage
    /// preserved): same-ACCOUNT contention is now resolved by the shared
    /// coordinator's FIFO lease wait — the conflicting registration is
    /// SERIALIZED behind the live capture and then lands idempotently
    /// (metadata already exists), instead of being refused by one wrapper's
    /// private RAM gate that a second vault could bypass. The parent test
    /// name is retained for cross-round diff stability; the body now proves
    /// the corrected supported semantics.
    func testAccountLevelGuardRejectsConflictingRegistrationDuringCapture() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        // A SECOND WRAPPER over the same admitted context: the parent's
        // per-actor gates could not see each other (CV-R1); the shared
        // coordinator's lease does.
        let vault2 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let targetID = UUID()
        await gateway.setSuspendWrites(true)
        await gateway.resetWriteSignal()

        let captureTask = Task {
            try await vault1.capture(
                Data("synthetic-account-guard".utf8), kind: .genericToken,
                owner: .vault, label: "Guarded", id: targetID)
        }
        await gateway.waitForWriteStart()

        let registrationSettled = expectation(description: "registration settles")
        // Hoisted out of the sending closure: the XCTest helper is `self`-
        // isolated and must not be captured by the detached task.
        let conflictAccount = account(for: targetID)
        let registerTask = Task {
            try await vault2.registerExisting(
                account: conflictAccount, kind: .genericToken,
                label: "Conflicting registration", synchronizable: false)
            registrationSettled.fulfill()
        }
        // Give the registration a scheduling slice: it must be QUEUED behind
        // the live capture lease, never racing past it with a parallel claim
        // or save.
        await Task.yield()

        await gateway.resumeWrites()
        _ = try await captureTask.value
        await fulfillment(of: [registrationSettled], timeout: 30.0)
        try await registerTask.value

        let record = try unwrapRecord(try await store.record(id: targetID))
        XCTAssertEqual(record.keychainAccount, account(for: targetID))
        let records = try await store.records(owner: .vault)
        XCTAssertEqual(
            records.filter { $0.keychainAccount == account(for: targetID) }.count, 1,
            "serialization must never create a duplicate")
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let finalSummary = await vault1.ownedOperationSummary
        XCTAssertEqual(finalSummary.accounts, 0)
        XCTAssertEqual(finalSummary.waiting, 0)
    }

    func testCancelledCaptureCompensatesOrReportsIncompleteCleanup() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let targetID = UUID()
        await gateway.setSuspendWrites(true)

        let captureTask = Task {
            try await vault.capture(
                Data("synthetic-cancelled".utf8), kind: .genericToken,
                owner: .vault, label: "Cancelled", id: targetID)
        }
        await gateway.waitForWriteStart()
        captureTask.cancel()
        await gateway.resumeWrites()

        do {
            _ = try await captureTask.value
            XCTFail("a cancelled capture must not report success")
        } catch let error as AndroidCredentialVaultError {
            switch error {
            case .gatewayWriteEffectUnknownCompensated(let id),
                 .captureCancelledSecretRemoved(let id):
                XCTAssertEqual(id, targetID)
            default:
                XCTFail("unexpected cancellation outcome: \(error)")
            }
        }
        let record = try await store.record(id: targetID)
        XCTAssertNil(record)
        let expectedReference = reference(account: account(for: targetID))
        let value = await gateway.value(for: expectedReference)
        XCTAssertNil(value)
        // The completed compensation finalized the durable claim.
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Crash-recovery decision table

    /// Death after the gateway write (or a compensation failure): the durable
    /// claim row alone — no caller-retained UUID — recovers the account after
    /// a process restart.
    func testRestartReschedulesClaimedCaptureWithoutCallerRetainedId() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        await gateway.setWriteFault(.effectUnknown)
        await gateway.setDeleteFaultAll(.effectUnknown)
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let targetID = UUID()

        do {
            _ = try await vault1.capture(
                Data("synthetic-crash-window".utf8), kind: .genericToken,
                owner: .vault, label: "Crash window", id: targetID)
            XCTFail("compensation failure must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .captureCleanupIncomplete(targetID))
        }
        let accountName = account(for: targetID)
        let generation = try await readQueueGeneration(manager: manager, account: accountName)
        XCTAssertNotNil(generation)

        // Simulate the restart: retire the SETTLED prior context (the
        // retirement fence — nothing live remains), then admit a fresh vault
        // actor over the SAME one migrated DatabaseManager. Recovery needs
        // only durable state: the new coordinator has NO RAM knowledge of
        // the prior owner, which is exactly the crash semantics, and the
        // durable queue row is the authority (no caller-retained UUID).
        try await vault1.retireRuntimeOwnership()
        await gateway.setWriteFault(nil)
        await gateway.setDeleteFaultAll(nil)
        let vault2 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let report = await vault2.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 1)
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.clearedObsolete, 0)
        XCTAssertEqual(report.remaining, 0)
        let orphan = await gateway.value(for: reference(account: accountName))
        XCTAssertNil(orphan)
        let record = try await store.record(id: targetID)
        XCTAssertNil(record)

        // The account is free again for a real capture.
        _ = try await vault2.capture(
            Data("synthetic-after-restart".utf8), kind: .genericToken,
            owner: .vault, label: "After restart", id: targetID)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    /// Death between the metadata commit and claim finalization: the restart
    /// drain must clear the obsolete intent WITHOUT deleting the live secret
    /// (Main's staged capture-vs-delete finding).
    func testRestartDrainPreservesCommittedSecretWhenDeathPrecedesFinalization() async throws {
        let manager = try await migratedManager()
        let gateway = TestGateway()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let targetID = UUID()
        let secret = Data("synthetic-committed-residual".utf8)
        _ = try await vault1.capture(
            secret, kind: .genericToken, owner: .vault,
            label: "Committed", id: targetID)
        let accountName = account(for: targetID)
        let expectedReference = reference(account: accountName)

        // Stage the crash cut-point "after metadata, before queue clear": the
        // committed credential plus its still-claiming row (same columns the
        // original trigger writes).
        try await insertIntentRow(
            manager: manager, account: accountName,
            enqueuedAt: "2026-01-01 00:00:00")

        try await vault1.retireRuntimeOwnership()
        let vault2 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let report = await vault2.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 1)
        XCTAssertEqual(report.completed, 0)
        XCTAssertEqual(report.clearedObsolete, 1)
        XCTAssertEqual(report.remaining, 0)
        let deletes = await gateway.deletes
        XCTAssertTrue(deletes.isEmpty, "live metadata must never be secret-deleted")
        let value = await gateway.value(for: expectedReference)
        XCTAssertEqual(value, secret)
        let resolved = try await vault2.resolveForApprovedUse(CredentialHandle(id: targetID))
        XCTAssertEqual(resolved, secret)
    }

    /// A metadata-save error whose readback cannot prove absence keeps BOTH
    /// the secret and the durable intent (captureMetadataUncertain). After a
    /// restart the decision table resolves the truth: a referenced credential
    /// survives with its secret; an uncommitted one is cleaned completely.
    func testMetadataUncertainKeepsDurableIntentAndRestartResolvesTruth() async throws {
        let (directory, manager) = try makeFileDatabase()
        try await manager.migrate()
        let gateway = TestGateway(onWrite: { _ in
            // Death-after-write proxy: the metadata store goes away while the
            // capture is between its gateway write and its save readback.
            try? await manager.close()
        })
        let identity1 = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity1, gateway: gateway)
        let targetID = UUID()
        let secret = Data("synthetic-uncertain".utf8)

        do {
            _ = try await vault1.capture(
                secret, kind: .genericToken, owner: .vault,
                label: "Uncertain", id: targetID)
            XCTFail("an unverifiable save must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .captureMetadataUncertain(targetID))
        }

        try await vault1.retireRuntimeOwnership()
        let reopened = try DatabaseManager(
            path: directory.appendingPathComponent("db.sqlite"))
        try await reopened.migrate()
        let accountName = account(for: targetID)
        let identity2 = try XCTUnwrap(RuntimeOwnerIdentity(
            root: identity1.root, token: identity1.token, epoch: 2))
        let vault2 = try AndroidCredentialVault.joinRuntimeOwnership(
            database: reopened,
            identity: identity2,
            ownedWork: TestOwnedWork(),
            gateway: gateway)
        let report = await vault2.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 1)
        // The save never reached SQLite: the row has no live metadata, so the
        // orphan secret is cleaned and the account is released.
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.clearedObsolete, 0)
        XCTAssertEqual(report.remaining, 0)
        let record = try await vault2.records.record(id: targetID)
        XCTAssertNil(record)
        let value = await gateway.value(for: reference(account: accountName))
        XCTAssertNil(value)

        // The decision-table invariant on the other side of the coin: if a
        // committed row HAD existed, the same drain would have preserved the
        // secret instead (covered by the finalization-residual test above).
        _ = try await vault2.capture(
            Data("synthetic-uncertain-retry".utf8), kind: .genericToken,
            owner: .vault, label: "Retry", id: targetID)

        try await reopened.close()
        try FileManager.default.removeItem(at: directory)
    }

    /// Cancellation after the write with a FAILED compensation: the durable
    /// intent persists and restart finishes the cleanup without the id.
    func testCancelledCaptureAfterWriteCompensationFailureRetainsDurableIntent() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        await gateway.setSuspendWrites(true)
        await gateway.setDeleteFaultAll(.effectUnknown)
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let targetID = UUID()

        let captureTask = Task {
            try await vault1.capture(
                Data("synthetic-cancel-unclean".utf8), kind: .genericToken,
                owner: .vault, label: "Cancel unclean", id: targetID)
        }
        await gateway.waitForWriteStart()
        captureTask.cancel()
        await gateway.resumeWrites()

        do {
            _ = try await captureTask.value
            XCTFail("a cancelled capture must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .captureCleanupIncomplete(targetID))
        }
        let accountName = account(for: targetID)
        let pending = try await store.pendingDeletions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.keychainAccount, accountName)

        await gateway.setDeleteFaultAll(nil)
        try await vault1.retireRuntimeOwnership()
        let vault2 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let report = await vault2.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 1)
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.remaining, 0)
        // The intentional write-suspension gate covers ONLY the cancelled
        // first capture. `resumeWrites()` releases the gates that already
        // exist; it does not disable the gate, so it must be reset before the
        // retry or the retry would park in a NEW suspended write with no
        // releaser (test-fixture deadlock, not a production path).
        await gateway.setSuspendWrites(false)
        _ = try await vault2.capture(
            Data("synthetic-cancel-retry".utf8), kind: .genericToken,
            owner: .vault, label: "Retry", id: targetID)
        let after = try await store.pendingDeletions()
        XCTAssertTrue(after.isEmpty)
    }

    /// A provably-no-effect write (pre-queue rejected/unavailable ONLY —
    /// CV-R4) releases the claim generation itself: no gateway delete is
    /// attempted and the account is immediately reusable.
    func testCaptureWriteRejectedReleasesClaimWithoutGatewayDelete() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        await gateway.setWriteFault(.rejected)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let targetID = UUID()

        do {
            _ = try await vault.capture(
                Data("synthetic-rejected".utf8), kind: .genericToken,
                owner: .vault, label: "Rejected", id: targetID)
            XCTFail("rejected write must fail typed")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .gatewayFailure(operation: .write, kind: .rejected))
        }
        let deletes = await gateway.deletes
        XCTAssertTrue(deletes.isEmpty)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)

        await gateway.setWriteFault(nil)
        _ = try await vault.capture(
            Data("synthetic-rejected-retry".utf8), kind: .genericToken,
            owner: .vault, label: "Retry", id: targetID)
        let record = try await store.record(id: targetID)
        XCTAssertNotNil(record)
    }

    // MARK: - Trigger/cascade/generation races (staged semantics)

    /// After the drain atomically clears an obsolete live-reference intent, a
    /// native cascade delete MUST re-enqueue a valid row (the original
    /// trigger uses INSERT OR IGNORE, which cannot update a row that still
    /// exists — the atomic obsolete clear is what restores the enqueue
    /// path).
    func testCascadeDeleteAfterObsoleteClearReEnqueuesValidIntent() async throws {
        let manager = try await migratedManager()
        let gateway = TestGateway()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let targetID = UUID()
        let secret = Data("synthetic-cascade".utf8)
        _ = try await vault1.capture(
            secret, kind: .genericToken, owner: .vault,
            label: "Cascade", id: targetID)
        let accountName = account(for: targetID)
        let expectedReference = reference(account: accountName)

        // Stage the residual: committed metadata + stale claim generation.
        try await insertIntentRow(
            manager: manager, account: accountName, enqueuedAt: "2026-01-01 00:00:00")

        // The live check + clear happen in ONE writer transaction, so no
        // cascade can interleave between them.
        try await vault1.retireRuntimeOwnership()
        let vault2 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let firstDrain = await vault2.drainDeletionQueue()
        XCTAssertEqual(firstDrain.clearedObsolete, 1)
        XCTAssertEqual(firstDrain.completed, 0)
        var deletes = await gateway.deletes
        XCTAssertTrue(deletes.isEmpty)

        // The later real delete's trigger now finds NO row and enqueues.
        let outcome = try await vault2.delete(CredentialHandle(id: targetID))
        XCTAssertEqual(outcome.secretCleanup, .completed)
        deletes = await gateway.deletes
        XCTAssertEqual(deletes, [expectedReference])
        let pending = try await vault2.records.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let value = await gateway.value(for: expectedReference)
        XCTAssertNil(value)
    }

    /// A durable row whose account is revalidated by a cascade delete (the
    /// trigger's INSERT OR IGNORE keeps the existing generation) still leads
    /// to the authoritative cleanup: nothing is silently erased, the secret
    /// is removed exactly once and the row completes.
    func testStaleIntentRevalidatedByCascadeDeleteIsCompletedNotErased() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let targetID = UUID()
        let secret = Data("synthetic-revalidated".utf8)
        _ = try await vault.capture(
            secret, kind: .genericToken, owner: .vault,
            label: "Revalidated", id: targetID)
        let accountName = account(for: targetID)
        try await insertIntentRow(
            manager: manager, account: accountName, enqueuedAt: "2026-01-01 00:00:00")

        // Cascade delete with the stale row present: the trigger is ignored,
        // the row survives (verified generation), the delete drain then
        // observes no live metadata and cleans it up.
        let outcome = try await vault.delete(CredentialHandle(id: targetID))
        XCTAssertEqual(outcome.secretCleanup, .completed)
        let generation = try await readQueueGeneration(manager: manager, account: accountName)
        XCTAssertNil(generation)
        let deletes = await gateway.deletes
        XCTAssertEqual(deletes, [reference(account: accountName)])
        let value = await gateway.value(for: reference(account: accountName))
        XCTAssertNil(value)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Pending-account refusal

    func testCaptureAndRegisterRefusedWhileAccountIntentPending() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        await gateway.setDeleteFaultAll(.effectUnknown)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let targetID = UUID()
        let accountName = account(for: targetID)

        // A durable orphan intent with NO metadata (crash-before-finalize).
        try await insertIntentRow(
            manager: manager, account: accountName, enqueuedAt: "2026-02-02 02:02:02")
        let originalGeneration = try await readQueueGeneration(
            manager: manager, account: accountName)

        do {
            _ = try await vault.capture(
                Data("synthetic-around-pending".utf8), kind: .genericToken,
                owner: .vault, label: "Must refuse", id: targetID)
            XCTFail("capture must not write around a pending cleanup")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .referenceCleanupPending(targetID))
        }
        do {
            try await vault.registerExisting(
                account: accountName, kind: .genericToken,
                label: "Must refuse too", synchronizable: false)
            XCTFail("registration must not write around a pending cleanup")
        } catch let error as AndroidCredentialVaultError {
            if case .referenceCleanupPending = error {
                // expected
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
        let writes = await gateway.writes
        XCTAssertTrue(writes.isEmpty)
        let generationAfter = try await readQueueGeneration(
            manager: manager, account: accountName)
        XCTAssertEqual(generationAfter, originalGeneration,
                       "a refused capture/register must not rewrite the durable row")
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)

        // Once the intent completes, both paths may proceed.
        await gateway.setDeleteFaultAll(nil)
        try await vault.registerExisting(
            account: accountName, kind: .genericToken,
            label: "Now allowed", synchronizable: false)
        let registered = try await store.records(owner: .vault)
        XCTAssertEqual(registered.count, 1)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Bounded queries / batch continuation

    /// 35 durable rows with 3 persistently failing deletes: bounded KEYSET
    /// batches in deterministic order attempt every row exactly once per
    /// call, counts are exact against SQL, the failed rows persist for the
    /// service-owned retry, and a second call finishes them. The parent's
    /// OFFSET assumption is gone (CV-R3); later rows are never starved
    /// behind a failing front because the cursor advances past every visited
    /// row within the same call.
    func testBoundedDrainBatchesCoverAllRowsExactlyOnceWithExactCounts() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)

        let total = 35
        let failingCount = 3
        let failingReferences = Set((0..<failingCount).map { index in
            reference(account: String(format: "credential.batch-%02d", index))
        })
        for index in 0..<total {
            try await insertIntentRow(
                manager: manager,
                account: String(format: "credential.batch-%02d", index),
                enqueuedAt: "2026-03-03 03:03:03")
        }
        // Fault ONLY the first three references; everything else cleans up.
        await gateway.setDeleteFaultAll(nil)
        for faulted in failingReferences {
            await gateway.setDeleteFault(.effectUnknown, for: faulted)
        }

        let report = await vault.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, total)
        XCTAssertEqual(report.completed, total - failingCount)
        XCTAssertEqual(report.failed, failingCount)
        XCTAssertEqual(report.clearedObsolete, 0)
        XCTAssertEqual(report.skippedConcurrent, 0)
        XCTAssertEqual(report.truncatedBudget, false)
        XCTAssertEqual(report.remaining, failingCount)

        // Deterministic single attempt per row: each reference's delete was
        // attempted exactly once (failed rows retried only in the NEXT call).
        let deletes = await gateway.deletes
        XCTAssertEqual(deletes.count, total)
        for faulted in failingReferences {
            XCTAssertEqual(deletes.filter { $0 == faulted }.count, 1)
        }

        let pending = try await store.pendingDeletions()
        XCTAssertEqual(pending.count, failingCount)

        for faulted in failingReferences {
            await gateway.setDeleteFault(nil, for: faulted)
        }
        let retry = await vault.drainDeletionQueue()
        XCTAssertEqual(retry.pendingAtStart, failingCount)
        XCTAssertEqual(retry.completed, failingCount)
        XCTAssertEqual(retry.failed, 0)
        XCTAssertEqual(retry.remaining, 0)
    }

    /// The capture/replace/register pending-preflight is TARGETED per
    /// account: it neither drains nor deletes other accounts' rows.
    func testTargetedPendingCheckDoesNotDrainOtherAccounts() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let keptID = UUID()
        let liveID = UUID()
        _ = try await vault.capture(
            Data("synthetic-kept".utf8), kind: .genericToken, owner: .vault,
            label: "Kept", id: keptID)
        _ = try await vault.capture(
            Data("synthetic-live".utf8), kind: .genericToken, owner: .vault,
            label: "Live", id: liveID)
        await gateway.setDeleteFaultAll(.effectUnknown)
        _ = try await vault.delete(CredentialHandle(id: keptID))
        let keptPending = try await store.pendingDeletions()
        XCTAssertEqual(keptPending.count, 1)
        let deletesAtStart = await gateway.deletes
        XCTAssertEqual(Set(deletesAtStart), [reference(account: account(for: keptID))])

        // Replace on the unaffected live credential must succeed WITHOUT
        // draining (or attempting a delete for) the other account's row.
        try await vault.replaceSecret(
            CredentialHandle(id: liveID), secret: Data("synthetic-live-new".utf8))
        let deletesAfterReplace = await gateway.deletes
        XCTAssertEqual(deletesAfterReplace, deletesAtStart)

        // A fresh capture likewise only claims its own account.
        _ = try await vault.capture(
            Data("synthetic-third".utf8), kind: .genericToken, owner: .vault,
            label: "Third", id: UUID())
        let deletesAfterCapture = await gateway.deletes
        XCTAssertEqual(deletesAfterCapture, deletesAtStart)
        let stillPending = try await store.pendingDeletions()
        XCTAssertEqual(stillPending.count, 1)
        XCTAssertEqual(stillPending.first?.keychainAccount, account(for: keptID))
    }

    // MARK: - Default gateway / construction integrity

    /// The default gateway parameter is a REAL forwarder to the frozen
    /// fail-closed registry: no registration => typed `.unavailable` with
    /// the claim released; after registration the SAME vault instance passes
    /// through live (no init-time snapshot, no memory fallback). The
    /// owned-work port is the synthetic double here; the production default
    /// forwards to the REAL shared `RuntimeOwnedWorkRegistry` whose attach
    /// is gated by the RB1 lifecycle admission (pinned separately below by
    /// the refusal tests).
    func testDefaultGatewayParameterForwardsToFailClosedRegistry() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let registry = SecretGatewayRegistry.shared
        // Test hygiene: leave the global registry exactly as found
        // (setUp/tearDown also enforce this).

        let vault = try AndroidCredentialVault.joinRuntimeOwnership(
            database: manager,
            identity: try makeIdentity(),
            ownedWork: TestOwnedWork())
        let targetID = UUID()

        do {
            _ = try await vault.capture(
                Data("synthetic-default".utf8), kind: .genericToken,
                owner: .vault, label: "Default gateway", id: targetID)
            XCTFail("an unregistered registry must fail closed")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .gatewayFailure(
                operation: .write, kind: .unavailable))
        }
        // The claim released on the provable no-effect; metadata never
        // admitted.
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let record = try await store.record(id: targetID)
        XCTAssertNil(record)

        // Register a synthetic test spy behind the real registry; the default
        // forwarder reads the registry dynamically (passthrough is live).
        let spy = RegistryProbeGateway()
        registry.register(spy)
        XCTAssertTrue(registry.isRegistered)
        let handle = try await vault.capture(
            Data("synthetic-default-after".utf8), kind: .genericToken,
            owner: .vault, label: "Default after register", id: targetID)
        let writes = await spy.writtenReferences
        XCTAssertEqual(writes, [reference(account: account(for: targetID))])
        let resolved = try await vault.resolveForApprovedUse(handle)
        XCTAssertEqual(resolved, Data("synthetic-default-after".utf8))

        registry.unregister()
        // Fail-closed again after unregister.
        do {
            _ = try await vault.resolveForApprovedUse(handle)
            XCTFail("unregistering must restore the fail-closed state")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .gatewayFailure(
                operation: .read, kind: .unavailable))
        }
    }

    /// Construction cannot point metadata at one database and the durable
    /// cleanup queue at another: the vault takes ONLY the DatabaseManager
    /// plus the trusted identity, creates THE original store itself and
    /// exports it; a second vault WRAPPER admitted over the same manager and
    /// the same identity acts on the same queue/metadata AND the same
    /// coordinator gates. A different full owner or a cross-root manager
    /// reuse fails closed at admission (CV-R1 constructor requirement).
    func testVaultExportsItsOwnStoreInstanceOverTheSameDatabase() async throws {
        let manager = try await migratedManager()
        let gateway = TestGateway()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let exportedStore = await vault1.records
        let targetID = UUID()
        let secret = Data("synthetic-one-db".utf8)
        _ = try await vault1.capture(
            secret, kind: .genericToken, owner: .vault,
            label: "One DB", id: targetID)

        // Metadata is visible through the exported original store instance.
        let record = try await exportedStore.record(id: targetID)
        XCTAssertNotNil(record)

        // The queue work of a second admitted wrapper over the same manager
        // observes the same database: stage a residual claim for the live
        // account; vault2's bounded drain finds it via the manager's queue
        // and vault2's exported store finds the metadata — same one DB.
        try await insertIntentRow(
            manager: manager, account: account(for: targetID),
            enqueuedAt: "2026-04-04 04:04:04")
        let vault2 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let report = await vault2.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 1)
        XCTAssertEqual(report.clearedObsolete, 1)
        XCTAssertEqual(report.completed, 0)
        let pending = try await vault2.records.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let stillLive = try await vault2.records.record(id: targetID)
        XCTAssertNotNil(stillLive)
        let value = await gateway.value(for: reference(account: account(for: targetID)))
        XCTAssertEqual(value, secret, "same-DB construction must never split queue from metadata")

        // And the API shape proves the mismatch is impossible by
        // construction: no initializer accepts an externally-created store,
        // and the stamped clock still flows through admission.
        let stampedVault = try AndroidCredentialVault.joinRuntimeOwnership(
            database: manager,
            identity: identity,
            ownedWork: TestOwnedWork(),
            gateway: gateway,
            now: { Date(timeIntervalSince1970: 1_777_000_000) })
        let stampID = UUID()
        _ = try await stampedVault.capture(
            Data("synthetic-stamped".utf8), kind: .genericToken, owner: .vault,
            label: "Stamped", id: stampID)
        let stamped = try await vault2.records.record(id: stampID)
        XCTAssertEqual(stamped?.updatedAt, Date(timeIntervalSince1970: 1_777_000_000))

        // CV-R1 admission fail-closed: a DIFFERENT full owner cannot take
        // over the same root while the context is installed…
        let otherOwner = try makeIdentity(
            rootPath: identity.root.path,
            token: "ffffffffffffffffffffffffffffffff")
        do {
            _ = try AndroidCredentialVault.joinRuntimeOwnership(
                database: manager, identity: otherOwner, ownedWork: TestOwnedWork())
            XCTFail("a different owner over the same root must fail closed")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownershipAdmissionRejected(.ownerMismatch))
        }
        // …and the same DatabaseManager can never join a FOREIGN root
        // context (separate RAM gates over one physical DB is exactly the
        // CV-R1 bug; the factory makes it unrepresentable).
        let foreignRoot = try makeIdentity()
        do {
            _ = try AndroidCredentialVault.joinRuntimeOwnership(
                database: manager, identity: foreignRoot, ownedWork: TestOwnedWork())
            XCTFail("the same DatabaseManager must never join two coordinators")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownershipAdmissionRejected(.lifecycleConflict))
        }
    }

    /// Public discard requires durable OWNED-queue proof: an unregistered
    /// reference (no intent row) is refused outright, while the real crash
    /// residue (durable row, no metadata) is cleaned conditionally.
    func testDiscardUncommittedSecretRefusesRefWithoutDurableIntent() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let strangerID = UUID()
        let expectedReference = reference(account: account(for: strangerID))
        await gateway.seed(reference: expectedReference,
                           value: Data("synthetic-arbitrary-ref".utf8))

        do {
            try await vault.discardUncommittedSecret(id: strangerID)
            XCTFail("discard must not delete a ref without durable owned-queue proof")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .durableCleanupIntentMissing(strangerID))
        }
        let seededStillThere = await gateway.value(for: expectedReference)
        XCTAssertNotNil(seededStillThere)

        // With the durable intent present (the capture-failure reality), the
        // same discard succeeds and finalizes the verified generation.
        try await insertIntentRow(
            manager: manager, account: account(for: strangerID),
            enqueuedAt: "2026-05-05 05:05:05")
        try await vault.discardUncommittedSecret(id: strangerID)
        let cleaned = await gateway.value(for: expectedReference)
        XCTAssertNil(cleaned)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Secret hygiene

    func testNoSecretBytesAppearInCardsMetadataOrTypedErrors() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let secret = Data("unique-secret-marker-\(UUID().uuidString)".utf8)
        let targetID = UUID()
        _ = try await vault.capture(
            secret, kind: .providerAPIKey, owner: .vault,
            label: "Provider key", id: targetID)

        let secretText = String(decoding: secret, as: UTF8.self)
        let cards = try await store.cards()
        let card = try XCTUnwrap(cards.first)
        let cardText = String(
            data: try JSONEncoder().encode(card), encoding: .utf8) ?? ""
        XCTAssertFalse(cardText.contains(secretText))
        XCTAssertFalse(card.reference.contains(secretText))

        let record = try unwrapRecord(try await store.record(id: targetID))
        let recordText = String(
            data: try JSONEncoder().encode(record), encoding: .utf8) ?? ""
        XCTAssertFalse(recordText.contains(secretText))
        XCTAssertFalse(record.label.contains(secretText))
        XCTAssertFalse((record.origin ?? "").contains(secretText))

        // A failed capture leaves a durable claim row; it must carry only the
        // original metadata columns, never secret bytes.
        await gateway.setWriteFault(.effectUnknown)
        await gateway.setDeleteFaultAll(.effectUnknown)
        let failedID = UUID()
        do {
            _ = try await vault.capture(
                secret, kind: .providerAPIKey, owner: .vault,
                label: "Failure", id: failedID)
            XCTFail("expected a typed failure")
        } catch {
            let description = String(describing: error)
            XCTAssertFalse(description.contains(secretText))
            XCTAssertFalse(description.contains(record.keychainAccount))
        }
        let pending = try await store.pendingDeletions()
        XCTAssertFalse(pending.contains(where: {
            $0.keychainAccount.contains(secretText)
        }))
        let rowDump = try await manager.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT keychain_account, synchronizable, enqueued_at, last_error
                FROM credential_deletion_queue
                """).map { row -> String in
                let accountValue: String = row["keychain_account"]
                let syncValue: Int = row["synchronizable"]
                let enqueuedValue: String = row["enqueued_at"]
                let errorValue: String? = row["last_error"]
                return "\(accountValue)|\(syncValue)|\(enqueuedValue)|\(errorValue ?? "")"
            }
        }
        XCTAssertFalse(rowDump.contains(where: { $0.contains(secretText) }))
    }

    // MARK: - Owned-operation lifetime / shared coordinator (CV-R1)

    /// Two wrappers over the SAME admitted context share the coordinator's
    /// handle gate: a live replace on wrapper 1 blocks wrapper 2's same-
    /// handle delete with the typed rejection — the cross-instance version of
    /// the parent's same-instance guard (a second vault no longer has
    /// "wholly separate RAM gates").
    func testTwoWrappersOverSharedContextShareHandleGates() async throws {
        let manager = try await migratedManager()
        let gateway = TestGateway()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let vault2 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let targetID = UUID()
        _ = try await vault1.capture(
            Data("synthetic-shared-gate".utf8), kind: .genericToken,
            owner: .vault, label: "Shared", id: targetID)
        await gateway.setSuspendWrites(true)
        await gateway.resetWriteSignal()

        let replaceTask = Task {
            try await vault1.replaceSecret(
                CredentialHandle(id: targetID),
                secret: Data("synthetic-shared-new".utf8))
        }
        await gateway.waitForWriteStart()

        do {
            _ = try await vault2.delete(CredentialHandle(id: targetID))
            XCTFail("the shared coordinator must reject same-handle contention across wrappers")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .operationInFlight(targetID))
        }

        await gateway.resumeWrites()
        try await replaceTask.value
        let resolved = try await vault2.resolveForApprovedUse(CredentialHandle(id: targetID))
        XCTAssertEqual(resolved, Data("synthetic-shared-new".utf8))
    }

    /// CV-R1 PRIMARY regression: a LIVE capture's claim is never drained as
    /// a crash orphan — including the same-second case Main's counterexample
    /// describes (the skip logic is lease-driven and deliberately
    /// timestamp-independent per CV-R2). While capture 1 holds its account
    /// lease and awaits a suspended write, a SECOND wrapper's global drain
    /// must SKIP the in-flight claim: no gateway delete is attempted, the
    /// claim row survives, and the report is honest. After the owner
    /// settles, its own row is finalized and a fresh drain sees nothing.
    func testLiveCaptureClaimIsNeverDrainedAsOrphanSameSecond() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let vault2 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let targetID = UUID()
        let accountName = account(for: targetID)
        let expectedReference = reference(account: accountName)

        // Settle one full lifecycle first so the NEXT claim lands in the
        // same coarse wall-clock second as its preceding row removal (the
        // rows here carry datetime('now')).
        _ = try await vault1.capture(
            Data("synthetic-first-pass".utf8), kind: .genericToken,
            owner: .vault, label: "First pass", id: targetID)
        _ = try await vault1.delete(CredentialHandle(id: targetID))
        let cleared = try await store.pendingDeletions()
        XCTAssertTrue(cleared.isEmpty)

        // Start a NEW capture and suspend its write: the durable claim row
        // exists, metadata does NOT, and the operation is LIVE.
        await gateway.setSuspendWrites(true)
        await gateway.resetWriteSignal()
        let deletesBeforeDrain = await gateway.deletes
        let captureTask = Task {
            try await vault1.capture(
                Data("synthetic-live-claim".utf8), kind: .genericToken,
                owner: .vault, label: "Live claim", id: targetID)
        }
        await gateway.waitForWriteStart()

        let report = await vault2.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 1)
        XCTAssertEqual(report.completed, 0)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.clearedObsolete, 0)
        XCTAssertEqual(report.skippedConcurrent, 1,
                       "the claim is CURRENTLY OWNED — CV-R1")
        XCTAssertEqual(report.truncatedBudget, false)
        let deletesAfterDrain = await gateway.deletes
        XCTAssertEqual(deletesAfterDrain, deletesBeforeDrain,
                       "a live claim's secret must never be drained away")
        let rowSurvived = try await readQueueGeneration(
            manager: manager, account: accountName)
        XCTAssertNotNil(rowSurvived, "the live claim row must survive the skipped drain")

        // Resume: the owner completes and finalizes its OWN row.
        await gateway.resumeWrites()
        _ = try await captureTask.value
        let record = try unwrapRecord(try await store.record(id: targetID))
        XCTAssertEqual(record.keychainAccount, accountName)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let value = await gateway.value(for: expectedReference)
        XCTAssertEqual(value, Data("synthetic-live-claim".utf8))
        let afterReport = await vault2.drainDeletionQueue()
        XCTAssertEqual(afterReport.pendingAtStart, 0)
        XCTAssertEqual(afterReport.remaining, 0)
    }

    /// The inverse direction (CV-R1): while a recovery drain owns an account
    /// and awaits its gateway delete, another wrapper's mutation on the same
    /// account is serialized behind the drain (FIFO lease) and never races
    /// with it; the drain's cleanup completes exactly once and the capture
    /// then proceeds normally.
    func testMutationWaitsBehindLiveDrainAndCannotRaceThePendingDelete() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let vault2 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let targetID = UUID()
        let accountName = account(for: targetID)

        // Durable UNOWNED orphan (crash residue) for the account.
        try await insertIntentRow(
            manager: manager, account: accountName, enqueuedAt: "2026-09-09 09:09:09")
        await gateway.setSuspendDeletes(true)
        await gateway.resetDeleteSignal()

        let drainTask = Task {
            await vault1.drainDeletionQueue()
        }
        await gateway.waitForDeleteStart()

        // A capture for the SAME account now waits behind the drain's live
        // lease; it cannot mint a claim or a secret write meanwhile.
        let captureTask = Task {
            try await vault2.capture(
                Data("synthetic-behind-drain".utf8), kind: .genericToken,
                owner: .vault, label: "Behind drain", id: targetID)
        }
        await Task.yield()
        let writesDuringDrain = await gateway.writes
        XCTAssertTrue(writesDuringDrain.isEmpty,
                      "the waiting capture must not have touched the gateway")

        await gateway.resumeDeletes()
        let report = await drainTask.value
        XCTAssertEqual(report.pendingAtStart, 1)
        XCTAssertEqual(report.completed, 1)
        _ = try await captureTask.value

        // Drain settled first; the capture then proceeded normally.
        let record = try unwrapRecord(try await store.record(id: targetID))
        XCTAssertEqual(record.keychainAccount, accountName)
        let value = await gateway.value(for: reference(account: accountName))
        XCTAssertEqual(value, Data("synthetic-behind-drain".utf8))
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let summary = await vault1.ownedOperationSummary
        XCTAssertEqual(summary.accounts, 0)
        XCTAssertEqual(summary.waiting, 0)
    }

    /// The real registry receipt is held until ACTUAL operation completion,
    /// never released merely because the caller cancelled: while the capture
    /// awaits a suspended write and then performs its post-write
    /// compensation, the owned-work count stays 1; after the operation has
    /// fully settled (secret removed, claim finalized) it returns to 0. No
    /// timer exists anywhere that could make this happen earlier.
    func testReceiptHeldUntilRealCompletionNotOnCallerCancellation() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let ownedWork = TestOwnedWork()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(),
            ownedWork: ownedWork, gateway: gateway)
        let targetID = UUID()
        await gateway.setSuspendWrites(true)
        await gateway.resetWriteSignal()

        let captureTask = Task {
            try await vault.capture(
                Data("synthetic-receipt-lifetime".utf8), kind: .genericToken,
                owner: .vault, label: "Receipt", id: targetID)
        }
        await gateway.waitForWriteStart()
        XCTAssertEqual(ownedWork.liveCount, 1, "the owned operation is live")
        captureTask.cancel()
        // Cancellation ALONE changes nothing: the write is still suspended
        // inside the awaited effect, so the receipt AND the lease stay.
        XCTAssertEqual(ownedWork.liveCount, 1,
                       "a caller cancel must not detach an effect that can still land")
        let midSummary = await vault.ownedOperationSummary
        XCTAssertEqual(midSummary.accounts, 1, "no timeout release exists")
        await gateway.resumeWrites()
        do {
            _ = try await captureTask.value
            XCTFail("cancelled capture must not report success")
        } catch let error as AndroidCredentialVaultError {
            if case .captureCancelledSecretRemoved = error {
                // expected (or compensated below, depending on scheduling)
            } else if case .gatewayWriteEffectUnknownCompensated = error {
                // also honest: the resumed write threw cancellation inside
            } else {
                XCTFail("unexpected cancelled-capture error: \(error)")
            }
        }
        XCTAssertEqual(ownedWork.liveCount, 0, "settled = detached")
        let finalSummary = await vault.ownedOperationSummary
        XCTAssertEqual(finalSummary.accounts, 0)
        XCTAssertEqual(finalSummary.handles, 0)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let value = await gateway.value(for: reference(account: account(for: targetID)))
        XCTAssertNil(value, "the cancellation compensation completed before settle")
    }

    /// A waiter cancelled while QUEUED behind a live owner: the wait is
    /// removed by exact waiter identity, the live owner is undisturbed (its
    /// lease and receipt stay), the owner settles normally, and no phantom
    /// ownership or receipt leaks. Proves cancellation handling spans the
    /// queue entry itself (CV-R1 "including cancellation").
    func testLeaseWaiterCancellationDoesNotDisturbLiveOwner() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let ownedWork = TestOwnedWork()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, ownedWork: ownedWork, gateway: gateway)
        let vault2 = try makeVault(
            manager: manager, identity: identity, ownedWork: ownedWork, gateway: gateway)
        let targetID = UUID()
        await gateway.setSuspendWrites(true)
        await gateway.resetWriteSignal()

        let captureTask = Task {
            try await vault1.capture(
                Data("synthetic-owner".utf8), kind: .genericToken,
                owner: .vault, label: "Owner", id: targetID)
        }
        await gateway.waitForWriteStart()

        let waiterAccount = account(for: targetID)
        let waiterTask = Task {
            try await vault2.registerExisting(
                account: waiterAccount, kind: .genericToken,
                label: "Waiter", synchronizable: false)
        }
        await Task.yield()
        waiterTask.cancel()
        // ALL outcomes are honest and deterministic-safe: cancelled while
        // queued, or (if cancellation raced a fast grant) a settled
        // idempotent registration. Either way the owner must be undisturbed
        // and no phantom ownership may leak.
        do {
            try await waiterTask.value
        } catch is CancellationError {
            // expected for a queued cancellation
        } catch {
            XCTFail("waiter must cancel or settle, got \(error)")
        }

        // The live owner is completely undisturbed by the waiter's cancel.
        XCTAssertEqual(ownedWork.liveCount, 1, "owner still awaiting its effect")
        await gateway.resumeWrites()
        _ = try await captureTask.value
        XCTAssertEqual(ownedWork.liveCount, 0)
        let summary = await vault1.ownedOperationSummary
        XCTAssertEqual(summary.accounts, 0, "no phantom lease leaked by the waiter")
        XCTAssertEqual(summary.waiting, 0, "no phantom waiter leaked")
        let ownerRecord = try await store.record(id: targetID)
        XCTAssertNotNil(ownerRecord, "the live owner's capture committed normally")
    }

    /// The REAL owned-work port refuses an operation BEFORE any durable side
    /// effect: with the actual RB1 lifecycle policy simulated (attach
    /// rejected — store not ready / stop requested), capture throws the typed
    /// admission error and leaves NO claim row, NO gateway write and NO
    /// lease/receipt behind.
    func testOwnedWorkAttachRefusedFailsClosedBeforeEffects() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let ownedWork = TestOwnedWork()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(),
            ownedWork: ownedWork, gateway: gateway)
        let targetID = UUID()

        ownedWork.setForcedRejection(.alreadyDraining)
        do {
            _ = try await vault.capture(
                Data("synthetic-refused".utf8), kind: .genericToken,
                owner: .vault, label: "Refused", id: targetID)
            XCTFail("the lifecycle refusal must fail the operation closed")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownedWorkAdmissionRejected(.alreadyDraining))
        }
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty, "refusal precedes the durable claim")
        let writes = await gateway.writes
        XCTAssertTrue(writes.isEmpty)
        let record = try await store.record(id: targetID)
        XCTAssertNil(record)
        XCTAssertEqual(ownedWork.liveCount, 0, "the lease released with no receipt")
        let summary = await vault.ownedOperationSummary
        XCTAssertEqual(summary.accounts, 0)

        // The account stays clean: with the port reopened, the real capture
        // works normally.
        _ = try await vault.capture(
            Data("synthetic-refused-retry".utf8), kind: .genericToken,
            owner: .vault, label: "Retry", id: targetID)
        let after = try await store.pendingDeletions()
        XCTAssertTrue(after.isEmpty)
    }

    /// The startup/global drain performs ZERO side effects when the REAL
    /// owned-work registry refuses its attach: the honest report names the
    /// code, counts stay at zero, and the durable rows are exactly preserved
    /// for the next service-owned drain (the queue, not the refusal, remains
    /// the recovery authority).
    func testGlobalDrainAttachRefusedPerformsNoEffects() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let ownedWork = TestOwnedWork()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(),
            ownedWork: ownedWork, gateway: gateway)
        try await insertIntentRow(
            manager: manager, account: "credential.refused-a",
            enqueuedAt: "2026-12-01 00:00:00")
        try await insertIntentRow(
            manager: manager, account: "credential.refused-b",
            enqueuedAt: "2026-12-01 00:00:00")

        ownedWork.setForcedRejection(.notInstalled)
        let refused = await vault.drainDeletionQueue()
        XCTAssertEqual(refused.ownedWorkAdmissionRejected, .notInstalled)
        XCTAssertEqual(refused.pendingAtStart, 0)
        XCTAssertEqual(refused.completed, 0)
        XCTAssertEqual(refused.failed, 0)
        XCTAssertEqual(refused.clearedObsolete, 0)
        XCTAssertEqual(refused.skippedConcurrent, 0)
        let deletesAfterRefusal = await gateway.deletes
        XCTAssertTrue(deletesAfterRefusal.isEmpty)
        let preserved = try await store.pendingDeletions()
        XCTAssertEqual(preserved.count, 2, "the durable rows ARE the retry state")

        let done = await vault.drainDeletionQueue()
        XCTAssertEqual(done.pendingAtStart, 2)
        XCTAssertEqual(done.completed, 2)
        XCTAssertEqual(done.remaining, 0)
    }

    /// The retirement fence is a real fence, not a timer: retiring the RAM
    /// context WHILE an operation is live is refused; only after the
    /// operation has actually settled does retirement (and a new same-epoch
    /// admission for a restarted context inside one process) succeed.
    func testRetirementRefusesWhileOwnedOperationLiveThenSucceeds() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let targetID = UUID()
        await gateway.setSuspendWrites(true)
        await gateway.resetWriteSignal()
        let captureTask = Task {
            try await vault1.capture(
                Data("synthetic-retire-fence".utf8), kind: .genericToken,
                owner: .vault, label: "Fence", id: targetID)
        }
        await gateway.waitForWriteStart()

        // A newer epoch may NOT take over while owned work lives (RB1 stop
        // fence mirror).
        let identity2 = try XCTUnwrap(RuntimeOwnerIdentity(
            root: identity.root, token: identity.token, epoch: 2))
        do {
            _ = try AndroidCredentialVault.joinRuntimeOwnership(
                database: manager, identity: identity2, ownedWork: TestOwnedWork())
            XCTFail("re-admission while owned work is live must fail closed")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownershipAdmissionRejected(.rebindWhileOwned))
        }
        do {
            try await vault1.retireRuntimeOwnership()
            XCTFail("retirement must refuse while an owned operation is live")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownershipRetirementBlocked)
        }

        await gateway.resumeWrites()
        _ = try await captureTask.value
        try await vault1.retireRuntimeOwnership()

        // The durable queue stayed the truth throughout; a fresh in-process
        // context for the same root re-admits and reads it.
        let vault2 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let report = await vault2.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, 0)
        let record = try await store.record(id: targetID)
        XCTAssertNotNil(record)
    }

    // MARK: - CV-R2: same-second queue truth

    /// CV-R2 stale side-effect exclusion: the decision transaction must find
    /// the OBSERVED row still present with the expected tuple before any
    /// gateway delete. Here a second row (Y) of the same batch vanishes
    /// during the first row's (X) suspended delete; when the drain reaches
    /// Y's stale observation it must SKIP the effect entirely — Y's secret
    /// is never gateway-deleted on the vanished row, the counts are honest,
    /// and the final exact `remaining` reflects reality.
    func testStaleObservedRowRemovedUnderFlightIsNeverGatewayDeleted() async throws {
        let manager = try await migratedManager()
        let gateway = TestGateway()
        let ownedWork = TestOwnedWork()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), ownedWork: ownedWork,
            gateway: gateway)
        let accountX = "credential.stale-x"
        let accountY = "credential.stale-y"
        let referenceX = reference(account: accountX)
        let referenceY = reference(account: accountY)
        await gateway.seed(reference: referenceY, value: Data("synthetic-stale-y".utf8))
        try await insertIntentRow(
            manager: manager, account: accountX, enqueuedAt: "2026-11-11 11:11:11")
        try await insertIntentRow(
            manager: manager, account: accountY, enqueuedAt: "2026-11-11 11:11:11")
        await gateway.setSuspendNextDelete(true)
        await gateway.resetDeleteSignal()

        let drainTask = Task {
            await vault.drainDeletionQueue()
        }
        await gateway.waitForDeleteStart()
        // X's delete is in flight; Y's row is removed under the already
        // fetched batch (staged uncoordinated removal — the supported
        // writers are lease-serialized, which the CV-R1 tests pin).
        try await rawDeleteQueueRow(manager: manager, account: accountY)
        await gateway.resumeDeletes()
        let report = await drainTask.value

        XCTAssertEqual(report.pendingAtStart, 2)
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.skippedConcurrent, 1,
                       "Y's stale observation must skip, never delete")
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.remaining, 0)
        let deletes = await gateway.deletes
        XCTAssertEqual(deletes, [referenceX],
                       "the vanished row's reference was never gateway-deleted")
        let yValue = await gateway.value(for: referenceY)
        XCTAssertEqual(yValue, Data("synthetic-stale-y".utf8),
                       "no secret loss on a stale observation (CV-R2)")
        XCTAssertEqual(ownedWork.liveCount, 0, "the drain settled its receipt")
    }

    /// CV-R2 finalization guard: a failed-operation release of its own claim
    /// may ONLY erase the row while the account's metadata truth still
    /// matches "absent". The test stages a bypass re-registration between the
    /// claim and a provable no-effect rejection; the release must then LEAVE
    /// the row (it became a legitimate obsolete intent for live metadata),
    /// and the decision table later clears it WITHOUT touching the secret.
    func testStaleReleaseCannotEraseIntentForLiveMetadata() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let targetID = UUID()
        let accountName = account(for: targetID)
        // Bypass hook: while the capture's rejected write runs, another
        // writer re-registers live metadata for the same account (staged:
        // this is exactly the window where a naive tuple DELETE would erase
        // a new intent).
        let gateway = TestGateway(onWrite: { _ in
            try? await store.save(CredentialRecord(
                id: UUID(), kind: .genericToken, owner: .vault,
                label: "Bypass re-registration", keychainAccount: accountName))
        })
        await gateway.setWriteFault(.rejected)
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)

        do {
            _ = try await vault.capture(
                Data("synthetic-stale-release".utf8), kind: .genericToken,
                owner: .vault, label: "Guard", id: targetID)
            XCTFail("rejection must fail the capture")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .gatewayFailure(operation: .write, kind: .rejected))
        }

        // The release guard ran: live metadata exists, so the claim row is
        // preserved (a stale finalizer can never erase the now-legitimate
        // intent even though it matches the tuple).
        let pendingAfterRefusal = try await store.pendingDeletions()
        XCTAssertEqual(pendingAfterRefusal.count, 1)

        // The decision table resolves the truth on the next drain: live
        // metadata → obsolete intent cleared, secret NEVER deleted.
        await gateway.setWriteFault(nil)
        let report = await vault.drainDeletionQueue()
        XCTAssertEqual(report.clearedObsolete, 1)
        XCTAssertEqual(report.completed, 0)
        let deletes = await gateway.deletes
        XCTAssertTrue(deletes.isEmpty)
        let remaining = try await store.pendingDeletions()
        XCTAssertTrue(remaining.isEmpty)
        let bypassRecords = try await store.records()
        XCTAssertEqual(bypassRecords.count, 1, "the live credential survives")
    }

    /// CV-R2 same-second A/B: a settled operation's finalization can never
    /// re-fire; the NEXT operation's finalize acts only on the row ITS lease
    /// minted (tuple + guard). Register-after-cleanup-incomplete in the same
    /// wall-clock second (guaranteed here because all rows run inside one
    // second of real time; the correctness asserted is independent of that)
    /// ends with exactly the new intent's truth: the durable row completed
    /// once, the metadata is live, and nothing from the settled failed
    /// capture erases the later row or its effect.
    func testSettledOperationCannotReFinalizeSameSecondNewIntent() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let targetID = UUID()
        let accountName = account(for: targetID)
        let expectedReference = reference(account: accountName)
        await gateway.seed(reference: expectedReference,
                           value: Data("synthetic-preexisting".utf8))

        // 1. A capture fails unclean: durable row (account, T1) + landed
        //    secret; the operation SETTLES (lease released, receipt
        //    detached) with the row intentionally retained.
        await gateway.setWriteFault(.effectUnknown)
        await gateway.setDeleteFaultAll(.effectUnknown)
        do {
            _ = try await vault.capture(
                Data("synthetic-settled-stale".utf8), kind: .genericToken,
                owner: .vault, label: "Unclean", id: targetID)
            XCTFail("unclean capture must fail")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .captureCleanupIncomplete(targetID))
        }
        await gateway.setWriteFault(nil)
        await gateway.setDeleteFaultAll(nil)
        let settledSummary = await vault.ownedOperationSummary
        XCTAssertEqual(settledSummary.accounts, 0,
                       "the failed capture fully settled its ownership")

        // 2. Register the account in the SAME second: the targeted cleanup
        //    under the NEW lease completes the durable row (T1 — its secret
        //    is deleted), then a fresh claim (T2, possibly equal wall clock)
        //    protects metadata commit and finalizes only ITS row.
        try await vault.registerExisting(
            account: accountName, kind: .genericToken,
            label: "Same-second register", synchronizable: false)
        let successfulDeletes = await gateway.successfulDeletes
        XCTAssertEqual(successfulDeletes, [expectedReference],
                       "exactly one authoritative cleanup for the account")
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty,
                      "no residual row from either generation survives")
        let records = try await store.records(owner: .vault)
        XCTAssertEqual(
            records.filter { $0.keychainAccount == accountName }.count, 1)

        // 3. The account is now a committed credential whose old secret was
        //    legitimately removed; a re-supplied write works, and the queue
        //    stays the single durable truth.
        try await vault.replaceSecret(
            CredentialHandle(id: try XCTUnwrap(
                records.first(where: { $0.keychainAccount == accountName })).id),
            secret: Data("synthetic-resupplied".utf8))
        let resupplied = await gateway.value(for: expectedReference)
        XCTAssertEqual(resupplied, Data("synthetic-resupplied".utf8))
    }

    // MARK: - CV-R3: keyset fairness / strict budget

    /// A failing front does NOT starve later rows: within ONE call the
    /// cursor advances past failed/skipped rows, so the unvisited rows AFTER
    /// the failing front still complete (with OFFSET the old code re-fetched
    /// and miscounted under exactly these removals). Counts are exact.
    func testFairKeysetLaterRowsNotStarvedBehindFailedFront() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)

        let total = 20
        let frontFailures = 2
        for index in 0..<total {
            try await insertIntentRow(
                manager: manager,
                account: String(format: "credential.fair-%02d", index),
                enqueuedAt: "2026-10-01 10:01:01")
        }
        for index in 0..<frontFailures {
            await gateway.setDeleteFault(
                .effectUnknown,
                for: reference(account: String(format: "credential.fair-%02d", index)))
        }

        let report = await vault.drainDeletionQueue()
        XCTAssertEqual(report.pendingAtStart, total)
        XCTAssertEqual(report.failed, frontFailures)
        XCTAssertEqual(report.completed, total - frontFailures,
                       "rows behind the failing front complete in the SAME call")
        XCTAssertEqual(report.skippedConcurrent, 0)
        XCTAssertEqual(report.truncatedBudget, false)
        XCTAssertEqual(report.remaining, frontFailures)
        let pending = try await store.pendingDeletions()
        XCTAssertEqual(pending.count, frontFailures)

        for index in 0..<frontFailures {
            await gateway.setDeleteFault(nil,
                for: reference(account: String(format: "credential.fair-%02d", index)))
        }
        let retry = await vault.drainDeletionQueue()
        XCTAssertEqual(retry.completed, frontFailures)
        XCTAssertEqual(retry.remaining, 0)
    }

    /// Strict work budget under CONCURRENT enqueue: rows enqueued behind the
    /// cursor DURING the call are honestly NOT attempted beyond the budget;
    /// the report says `truncatedBudget`, the final `remaining` is the exact
    /// SQL count of what the next service drain owns. No unbounded
    /// traversal, no exactly-once claim over an unbounded queue.
    func testStrictBudgetUnderConcurrentEnqueueTruncatesHonestly() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)

        let initial = 16     // exactly one full batch → budget ceil(16/16)+2 = 3
        for index in 0..<initial {
            try await insertIntentRow(
                manager: manager,
                account: String(format: "credential.batch-%02d", index),
                enqueuedAt: "2026-10-10 10:10:10")
        }
        // The injected rows sort strictly after the cursor's stored position
        // (later second), so they are reachable only in LATER passes —
        // which the budget stops.
        let injected = 40
        await gateway.setSuspendNextDelete(true)
        await gateway.resetDeleteSignal()
        let drainTask = Task {
            await vault.drainDeletionQueue()
        }
        await gateway.waitForDeleteStart()
        for index in 0..<injected {
            try await insertIntentRow(
                manager: manager,
                account: String(format: "credential.budget-%02d", index),
                enqueuedAt: "2026-10-11 11:11:11")
        }
        await gateway.resumeDeletes()
        let report = await drainTask.value

        let visited = initial + injected   // 56 rows exist when passes 2/3 run
        XCTAssertEqual(report.pendingAtStart, initial)
        XCTAssertEqual(report.truncatedBudget, true,
                       "the strict budget stopped the traversal — say so")
        // Deterministic capacity: 3 passes × 16 rows visited at most.
        let attempted = report.completed + report.failed + report.clearedObsolete
            + report.skippedConcurrent
        XCTAssertEqual(attempted, 48, "exactly the bounded capacity was visited")
        XCTAssertEqual(report.remaining, visited - 48)
        let stillPending = try await store.pendingDeletions()
        XCTAssertEqual(stillPending.count, visited - 48,
                       "the durable rows ARE the honest retry state")

        // The next service-owned drain finishes the rest.
        let second = await vault.drainDeletionQueue()
        XCTAssertEqual(second.pendingAtStart, visited - 48)
        XCTAssertEqual(second.completed, visited - 48)
        XCTAssertEqual(second.remaining, 0)
        let final = try await store.pendingDeletions()
        XCTAssertTrue(final.isEmpty)
    }

    /// Concurrent removal + cascade re-insert during a bounded drain: a
    /// settled generation's row being removed and a NEW intent re-appearing
    /// behind the cursor is handled by the keyset honestly — the stale
    /// observation skips (revalidated row-exists guard), the fresh row is
    /// visited in a later pass, and each account's reference is
    /// gateway-deleted exactly once.
    func testConcurrentRemovalAndReinsertionVisitsFreshIntentOnce() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let vault = try makeVault(
            manager: manager, identity: try makeIdentity(), gateway: gateway)
        let accountA = "credential.race-a"
        let accountB = "credential.race-b"
        let referenceA = reference(account: accountA)
        let referenceB = reference(account: accountB)
        await gateway.seed(reference: referenceA, value: Data("synthetic-race-a".utf8))
        await gateway.seed(reference: referenceB, value: Data("synthetic-race-b".utf8))
        try await insertIntentRow(
            manager: manager, account: accountA, enqueuedAt: "2026-10-05 10:05:05")
        try await insertIntentRow(
            manager: manager, account: accountB, enqueuedAt: "2026-10-05 10:05:05")
        await gateway.setSuspendNextDelete(true)
        await gateway.resetDeleteSignal()

        let drainTask = Task {
            await vault.drainDeletionQueue()
        }
        await gateway.waitForDeleteStart()
        // During A's in-flight delete: B's stale row vanishes and a NEWER
        // intent for B appears behind the cursor (later second — exactly
        // what the cascade trigger would write next to the stale row).
        try await rawDeleteQueueRow(manager: manager, account: accountB)
        try await insertIntentRow(
            manager: manager, account: accountB, enqueuedAt: "2026-10-06 10:06:06")
        await gateway.resumeDeletes()
        let report = await drainTask.value

        XCTAssertEqual(report.pendingAtStart, 2)
        XCTAssertEqual(report.completed, 2, "A then the fresh B row")
        // The observed STALE B row is honestly reported as skipped under the
        // revalidation guard (it vanished during A's in-flight delete); it is
        // never gateway-deleted. The fresh intent is reached in the later
        // pass and completed exactly once.
        XCTAssertEqual(report.skippedConcurrent, 1,
                       "the vanished stale observation is skipped, not deleted")
        XCTAssertEqual(report.truncatedBudget, false)
        XCTAssertEqual(report.remaining, 0)
        let deletes = await gateway.deletes
        XCTAssertEqual(deletes.filter { $0 == referenceA }.count, 1)
        XCTAssertEqual(deletes.filter { $0 == referenceB }.count, 1,
                       "the newer B intent is cleaned exactly once")
        let valueA = await gateway.value(for: referenceA)
        let valueB = await gateway.value(for: referenceB)
        XCTAssertNil(valueA)
        XCTAssertNil(valueB, "the newer intent's canonical ref cleanup was true, not lost")
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    /// The original cascade FINALIZATION race at the real trigger: while a
    /// cleanup-required row's gateway delete is in flight, the account's
    /// metadata becomes live again (staged through the EXPORTED store — the
    /// window Main proved, where a cascade/new registration replaces the
    /// truth under a pending finalizer). The FINALIZE transaction's
    /// metadata-live guard must DEFER the row instead of erasing a
    /// legitimate newer intent: the observed delete completed (the canonical
    /// ref is account-unique), the row survives with its truth changed, and
    /// the next decision-table pass clears it as obsolete WITHOUT a second
    /// secret delete.
    func testOriginalCascadeFinalizationRaceDefersObsoleteRow() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, gateway: gateway)
        let accountName = "credential.cascade-final"
        let expectedReference = reference(account: accountName)

        // Durable unowned intent with a seeded residue secret.
        await gateway.seed(reference: expectedReference,
                           value: Data("synthetic-residue".utf8))
        try await insertIntentRow(
            manager: manager, account: accountName, enqueuedAt: "2026-10-20 10:20:20")
        await gateway.setSuspendNextDelete(true)
        await gateway.resetDeleteSignal()
        let drainTask = Task {
            await vault1.drainDeletionQueue()
        }
        await gateway.waitForDeleteStart()

        // Staged window: the metadata becomes live again WHILE the drain's
        // gateway delete is still in flight (direct exported-store save;
        // supported vault writers would be serialized behind the lease —
        // proven by the CV-R1 tests instead).
        let newID = UUID()
        try await store.save(CredentialRecord(
            id: newID, kind: .genericToken, owner: .vault,
            label: "Re-registered mid-delete", keychainAccount: accountName))

        await gateway.resumeDeletes()
        let firstReport = await drainTask.value
        // The delete effect was achieved; the finalize GUARD deferred the
        // row (metadata is live now) — the report is honest on both counts.
        XCTAssertEqual(firstReport.completed, 1)
        XCTAssertEqual(firstReport.remaining, 1,
                       "the newer legitimate intent is NOT erased by the finalizer")
        let deletes = await gateway.deletes
        XCTAssertEqual(deletes, [expectedReference])
        let rowSurvives = try await readQueueGeneration(
            manager: manager, account: accountName)
        XCTAssertNotNil(rowSurvives)

        // The next drain applies the decision table: live metadata → the
        // obsolete intent is cleared and NO secret is touched.
        let second = await vault1.drainDeletionQueue()
        XCTAssertEqual(second.clearedObsolete, 1)
        XCTAssertEqual(second.remaining, 0)
        let deletesAfter = await gateway.deletes
        XCTAssertEqual(deletesAfter, [expectedReference],
                       "no second secret delete on the deferred row")
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let record = try await store.record(id: newID)
        XCTAssertNotNil(record, "the re-registered metadata survives throughout")
    }

    // MARK: - CV-R4 actual-mailbox physical lifetime (real SecretRequestMailbox)

    /// Controlled business clock for the ONE shared mailbox. Mirrors the
    /// mailbox suite's own test clock; production never installs one.
    private final class MailboxTestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 1_000
        var now: UInt64 {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func advance(_ milliseconds: UInt64) {
            lock.lock(); value += milliseconds; lock.unlock()
        }
    }

    /// Bounded polling wait for an observable mailbox/actor state. The test
    /// never fabricates progress: it waits for the REAL transition.
    private func waitFor(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not observed within the bounded wait", file: file, line: line)
    }

    private func mailboxIntStat(_ key: String) -> Int {
        guard let data = SecretRequestMailbox.shared.statsJSON().data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? NSNumber else {
            return -1
        }
        return value.intValue
    }

    /// Bind the REAL mailbox as the production gateway seam and return the
    /// vault created over the DEFAULT forwarder (no synthetic gateway): the
    /// attempt-time observer must be the actual `MailboxSecretGateway`.
    private func makeRealMailboxVault(
        manager: DatabaseManager,
        identity: RuntimeOwnerIdentity,
        ownedWork: TestOwnedWork
    ) throws -> (vault: AndroidCredentialVault, clock: MailboxTestClock) {
        let clock = MailboxTestClock()
        let mailbox = SecretRequestMailbox.shared
        mailbox.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        mailbox.configureForTesting(
            clock: { clock.now },
            heartbeatStaleMillis: 60_000,
            watchdogStaleMillis: 50,
            watchdogTickMillis: 5,
            backendProgressWindowMillis: 10_000)
        XCTAssertEqual(mailbox.bind(epoch: 1), 0)
        SecretGatewayRegistry.shared.register(MailboxSecretGateway.shared)
        let vault = try AndroidCredentialVault.joinRuntimeOwnership(
            database: manager, identity: identity, ownedWork: ownedWork)
        return (vault, clock)
    }

    private func releaseRealMailbox() {
        SecretGatewayRegistry.shared.unregister()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
    }

    /// CV-R4 ACTUAL mailbox regression (Main follow-up, 2026-10-20): a real
    /// claimed write, the watchdog settling the CALLER while the store
    /// execution is still blocked, and a real LATE completion. The vault must
    /// NOT release the account lease or registry receipt on the caller error:
    /// it awaits the individual physical terminal, then performs the
    /// compensating delete through the same observed seam and finalizes the
    /// durable claim only on the delete's own committed truth.
    func testObservedClaimedWatchdogRetainsOwnerUntilRealPhysicalSettlement() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let ownedWork = TestOwnedWork()
        let identity = try makeIdentity()
        let targetID = UUID()
        let accountName = account(for: targetID)
        let mailbox = SecretRequestMailbox.shared
        let (vault, clock) = try makeRealMailboxVault(
            manager: manager, identity: identity, ownedWork: ownedWork)
        defer { releaseRealMailbox() }

        let captureTask = Task {
            try await vault.capture(
                Data("synthetic-real-mailbox".utf8), kind: .genericToken,
                owner: .vault, label: "Real mailbox", id: targetID)
        }
        // The test plays the frozen dispatcher's poller: claim the REAL write.
        let writeClaim = mailbox.awaitClaim(timeoutMillis: 5_000)
        XCTAssertGreaterThan(writeClaim, 0, "the observed write reached the queue")
        XCTAssertEqual(mailbox.physicalSnapshot(claim: writeClaim), .claimedOutstanding)

        // The watchdog settles the CALLER while the store execution is
        // blocked (the claimed ticket keeps its individual physical record).
        clock.advance(10_000)
        await waitFor { self.mailboxIntStat("callerSettledOutstanding") == 1 }
        XCTAssertEqual(mailbox.physicalSnapshot(claim: writeClaim), .claimedOutstanding)

        // The caller was resumed but NOTHING may be released while the real
        // execution is outstanding.
        XCTAssertEqual(ownedWork.liveCount, 1,
                       "the registry receipt is retained across the watchdog resume")
        let midSummary = await vault.ownedOperationSummary
        XCTAssertEqual(midSummary.accounts, 1, "the account lease is retained")
        let midRow = try await readQueueGeneration(manager: manager, account: accountName)
        XCTAssertNotNil(midRow, "the durable claim row is not released by the caller error")
        do {
            try await vault.retireRuntimeOwnership()
            XCTFail("retirement must refuse while the physical owner is live")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownershipRetirementBlocked)
        }
        let identity2 = try XCTUnwrap(RuntimeOwnerIdentity(
            root: identity.root, token: identity.token, epoch: 2))
        do {
            _ = try AndroidCredentialVault.joinRuntimeOwnership(
                database: manager, identity: identity2, ownedWork: TestOwnedWork())
            XCTFail("a newer epoch must not rebind while the physical owner is live")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownershipAdmissionRejected(.rebindWhileOwned))
        }

        // LATE actual write completion: the store committed the write.
        XCTAssertEqual(
            mailbox.complete(claim: writeClaim, status: 3, value: nil, valueLen: 0), -103)
        // The vault now compensates through the observed seam; the test
        // holds that delete as the in-flight store execution.
        let deleteClaim = mailbox.awaitClaim(timeoutMillis: 5_000)
        XCTAssertGreaterThan(deleteClaim, 0, "the compensating delete is observed")
        XCTAssertEqual(mailbox.physicalSnapshot(claim: deleteClaim), .claimedOutstanding)
        // LATE actual delete completion: quiescence for this record's lane.
        XCTAssertEqual(
            mailbox.complete(claim: deleteClaim, status: 4, value: nil, valueLen: 0), 0)

        do {
            _ = try await captureTask.value
            XCTFail("an ambiguous claimed write must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .gatewayWriteEffectUnknownCompensated(targetID))
        }
        XCTAssertEqual(ownedWork.liveCount, 0, "settlement released the receipt exactly once")
        let finalSummary = await vault.ownedOperationSummary
        XCTAssertEqual(finalSummary.accounts, 0)
        let row = try await readQueueGeneration(manager: manager, account: accountName)
        XCTAssertNil(row, "compensation truth finalized the durable claim")
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let settledRecord = try await store.record(id: targetID)
        XCTAssertNil(settledRecord)
        // Both individual records were consumed by the owner (bounded ledger).
        XCTAssertEqual(mailbox.physicalSnapshot(claim: writeClaim), .notRecorded)
        XCTAssertEqual(mailbox.physicalSnapshot(claim: deleteClaim), .notRecorded)
    }

    /// CV-R4 cancellation during the compensation: the caller is cancelled
    /// while the compensating delete is still executing. The vault must NOT
    /// settle (a caller cancel is never settlement) — it PARKS an explicit
    /// long-lived pending owner that keeps the account lease, the registry
    /// receipt and the exact witness. Only the service-owned reconciliation
    /// settles it, exactly once, after the real late completion.
    func testCancelledObservedCompensationParksOwnerThenReconcilesExactlyOnce() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let ownedWork = TestOwnedWork()
        let identity = try makeIdentity()
        let targetID = UUID()
        let accountName = account(for: targetID)
        let mailbox = SecretRequestMailbox.shared
        let (vault, clock) = try makeRealMailboxVault(
            manager: manager, identity: identity, ownedWork: ownedWork)
        defer { releaseRealMailbox() }

        let captureTask = Task {
            try await vault.capture(
                Data("synthetic-parked-owner".utf8), kind: .genericToken,
                owner: .vault, label: "Parked", id: targetID)
        }
        let writeClaim = mailbox.awaitClaim(timeoutMillis: 5_000)
        XCTAssertGreaterThan(writeClaim, 0)
        clock.advance(10_000)
        await waitFor { self.mailboxIntStat("callerSettledOutstanding") == 1 }
        XCTAssertEqual(
            mailbox.complete(claim: writeClaim, status: 3, value: nil, valueLen: 0), -103)
        let deleteClaim = mailbox.awaitClaim(timeoutMillis: 5_000)
        XCTAssertGreaterThan(deleteClaim, 0)
        XCTAssertEqual(mailbox.physicalSnapshot(claim: deleteClaim), .claimedOutstanding)

        // Cancel the caller while the compensating delete is still executing.
        captureTask.cancel()
        do {
            _ = try await captureTask.value
            XCTFail("a cancelled capture must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .captureCleanupIncomplete(targetID))
        }
        // The explicit pending owner is parked: lease + receipt retained, the
        // durable row still the recovery authority, and BOTH physical records
        // still the authority for settlement (nothing was manufactured).
        XCTAssertEqual(ownedWork.liveCount, 1,
                       "the parked owner retains the registry receipt")
        let parkedSummary = await vault.ownedOperationSummary
        XCTAssertEqual(parkedSummary.accounts, 1, "the account lease stays with the owner")
        let parkedRow = try await readQueueGeneration(manager: manager, account: accountName)
        XCTAssertNotNil(parkedRow)
        XCTAssertEqual(mailbox.physicalSnapshot(claim: writeClaim), .settled(status: 3))
        XCTAssertEqual(mailbox.physicalSnapshot(claim: deleteClaim), .claimedOutstanding)
        do {
            try await vault.retireRuntimeOwnership()
            XCTFail("retirement must refuse while a parked physical owner is live")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownershipRetirementBlocked)
        }
        let identity2 = try XCTUnwrap(RuntimeOwnerIdentity(
            root: identity.root, token: identity.token, epoch: 2))
        do {
            _ = try AndroidCredentialVault.joinRuntimeOwnership(
                database: manager, identity: identity2, ownedWork: TestOwnedWork())
            XCTFail("a newer epoch must not rebind over a parked owner")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownershipAdmissionRejected(.rebindWhileOwned))
        }

        // LATE actual delete completion arrives exactly once.
        XCTAssertEqual(
            mailbox.complete(claim: deleteClaim, status: 4, value: nil, valueLen: 0), -103)
        // Service-owned reconciliation settles ONLY on that real truth.
        let reconciled = await vault.reconcilePendingPhysicalOwners()
        XCTAssertEqual(reconciled, 1)
        XCTAssertEqual(ownedWork.liveCount, 0, "exactly-once settlement detached the receipt")
        let finalSummary = await vault.ownedOperationSummary
        XCTAssertEqual(finalSummary.accounts, 0)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let settledRecord = try await store.record(id: targetID)
        XCTAssertNil(settledRecord)
        XCTAssertEqual(mailbox.physicalSnapshot(claim: writeClaim), .notRecorded)
        XCTAssertEqual(mailbox.physicalSnapshot(claim: deleteClaim), .notRecorded)
        // A second reconciliation is a no-op (no duplicate settle/receipt).
        let again = await vault.reconcilePendingPhysicalOwners()
        XCTAssertEqual(again, 0)
        XCTAssertEqual(ownedWork.liveCount, 0)
    }

    /// CV-R1 cancellation/registration repair: cancellation landing BETWEEN
    /// the initial `Task.isCancelled` check and the waiter registration (the
    /// exact window the parent left open) must NOT enqueue the cancelled
    /// caller behind the live owner. The owner stays completely undisturbed
    /// and no waiter/lease leaks.
    func testAcquireAccountCancelBeforeRegistrationNeverQueuesBehindLiveOwner() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let gateway = TestGateway()
        let ownedWork = TestOwnedWork()
        let identity = try makeIdentity()
        let vault1 = try makeVault(
            manager: manager, identity: identity, ownedWork: ownedWork, gateway: gateway)
        let vault2 = try makeVault(
            manager: manager, identity: identity, ownedWork: ownedWork, gateway: gateway)
        let ownerID = UUID()
        await gateway.setSuspendWrites(true)
        await gateway.resetWriteSignal()

        let captureTask = Task {
            try await vault1.capture(
                Data("synthetic-registration-race".utf8), kind: .genericToken,
                owner: .vault, label: "Owner", id: ownerID)
        }
        await gateway.waitForWriteStart()

        // Deterministic schedule: the interposer runs at the exact race
        // window and cancels the CURRENT (waiter) task.
        let waiterID = UUID()
        let waiterAccount = account(for: waiterID)
        await vault2.setAcquireRegistrationInterposerForTesting { account in
            guard account == waiterAccount else { return }
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let waiterTask = Task {
            try await vault2.registerExisting(
                account: waiterAccount, kind: .genericToken,
                label: "Cancelled waiter", synchronizable: false)
        }
        do {
            _ = try await waiterTask.value
            XCTFail("the cancelled waiter must exit, never queue behind the owner")
        } catch is CancellationError {
            // expected: cancelledWhileWaiting mapped onto CancellationError
        } catch {
            XCTFail("unexpected waiter error")
        }
        await vault2.setAcquireRegistrationInterposerForTesting(nil)

        // The live owner is completely undisturbed and no phantom waiter or
        // ownership leaked (the parent defect would still be queued here).
        XCTAssertEqual(ownedWork.liveCount, 1, "the owner still awaits its effect")
        let midSummary = await vault1.ownedOperationSummary
        XCTAssertEqual(midSummary.accounts, 1)
        XCTAssertEqual(midSummary.waiting, 0, "no cancelled waiter may remain queued")

        await gateway.resumeWrites()
        _ = try await captureTask.value
        XCTAssertEqual(ownedWork.liveCount, 0)
        let finalSummary = await vault1.ownedOperationSummary
        XCTAssertEqual(finalSummary.accounts, 0)
        XCTAssertEqual(finalSummary.waiting, 0)
        let record = try await store.record(id: ownerID)
        XCTAssertNotNil(record, "the live owner's capture committed normally")
        // The account is fully reusable (the cancelled waiter left nothing):
        // a fresh registration for the SAME account lands normally. The
        // record id is minted by the store, so look it up by its account.
        _ = try await vault2.registerExisting(
            account: account(for: waiterID), kind: .genericToken,
            label: "Retry waiter", synchronizable: false)
        let waiterRecords = try await store.records(owner: .vault)
        XCTAssertEqual(
            waiterRecords.filter { $0.keychainAccount == account(for: waiterID) }.count,
            1, "the retried registration is admitted exactly once after the cancelled waiter")
    }

    // MARK: - CV-MAIN findings (2026-10-20)

    /// CV-MAIN-NOTRECORDED: an honest `.notRecorded` is NOT physical
    /// terminal proof. The mailbox ledger is reset while the real execution
    /// is still unknown: the vault must QUARANTINE the exact witness +
    /// account lease + registry receipt (Root retirement/rebind still
    /// refuse, no fake cleanup completed) instead of releasing the owner on
    /// absence. The durable row remains the recovery authority.
    func testUnobservedPhysicalTruthQuarantinesOwnerInsteadOfReleasing() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let ownedWork = TestOwnedWork()
        let identity = try makeIdentity()
        let targetID = UUID()
        let accountName = account(for: targetID)
        let mailbox = SecretRequestMailbox.shared
        let (vault, clock) = try makeRealMailboxVault(
            manager: manager, identity: identity, ownedWork: ownedWork)
        defer { releaseRealMailbox() }

        let captureTask = Task {
            try await vault.capture(
                Data("synthetic-unobserved".utf8), kind: .genericToken,
                owner: .vault, label: "Unobserved", id: targetID)
        }
        let writeClaim = mailbox.awaitClaim(timeoutMillis: 5_000)
        XCTAssertGreaterThan(writeClaim, 0)
        clock.advance(10_000)
        await waitFor { self.mailboxIntStat("callerSettledOutstanding") == 1 }

        // The ledger is lost while the real execution is unknown: the honest
        // subscription result is `.notRecorded` (non-evidence).
        mailbox.resetForTesting()

        do {
            _ = try await captureTask.value
            XCTFail("unobserved physical truth must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .captureCleanupIncomplete(targetID))
        }
        // QUARANTINED, not settled: the receipt, the lease and the durable
        // row all remain with the exact witness.
        XCTAssertEqual(ownedWork.liveCount, 1,
                       "absence of a physical record is not settlement")
        let summary = await vault.ownedOperationSummary
        XCTAssertEqual(summary.accounts, 1, "the account lease stays quarantined")
        let row = try await readQueueGeneration(manager: manager, account: accountName)
        XCTAssertNotNil(row, "the durable row remains the recovery authority")
        XCTAssertEqual(mailbox.physicalSnapshot(claim: writeClaim), .notRecorded)
        do {
            try await vault.retireRuntimeOwnership()
            XCTFail("retirement must refuse while ownership is unknown")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownershipRetirementBlocked)
        }
        let identity2 = try XCTUnwrap(RuntimeOwnerIdentity(
            root: identity.root, token: identity.token, epoch: 2))
        do {
            _ = try AndroidCredentialVault.joinRuntimeOwnership(
                database: manager, identity: identity2, ownedWork: TestOwnedWork())
            XCTFail("a newer epoch must not rebind over unknown ownership")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .ownershipAdmissionRejected(.rebindWhileOwned))
        }
        // Reconciliation cannot manufacture a terminal either: the owner is
        // retained and no fake cleanup finalizes the row.
        let reconciled = await vault.reconcilePendingPhysicalOwners()
        XCTAssertEqual(reconciled, 0, "non-evidence never settles the owner")
        XCTAssertEqual(ownedWork.liveCount, 1)
        let stillQuarantined = await vault.ownedOperationSummary
        XCTAssertEqual(stillQuarantined.accounts, 1)
        let pending = try await store.pendingDeletions()
        XCTAssertEqual(pending.count, 1, "the durable row is preserved, not finalized")
        let again = await vault.reconcilePendingPhysicalOwners()
        XCTAssertEqual(again, 0)
    }

    /// Deterministic reservation/arrival observation for the controlled
    /// two-reconciler overlap: records every reservation attempt and lets the
    /// test await BOTH arrivals without any fixed sleep.
    private final class ReconciliationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [String] = []
        private var granted = 0
        private var denied = 0

        func record(account: String, acquired: Bool) {
            lock.lock()
            attempts.append(account)
            if acquired { granted += 1 } else { denied += 1 }
            lock.unlock()
        }

        var snapshot: (attempts: Int, granted: Int, denied: Int) {
            lock.lock(); defer { lock.unlock() }
            return (attempts.count, granted, denied)
        }
    }

    /// CV-MAIN-RECONCILE-REENTRANCY: two vault actors share ONE coordinator
    /// and reconcile the SAME parked owner concurrently. The shared
    /// reservation must be taken BEFORE any await/effect: exactly ONE
    /// compensation delete is enqueued, exactly one reconciler settles, and a
    /// stale second delete can never arrive after the SAME canonical account
    /// is reused by a newer owner/registration.
    func testConcurrentTwoReconcilersSingleflightExactlyOneCompensation() async throws {
        let manager = try await migratedManager()
        let store = CredentialStore(database: manager)
        let ownedWork = TestOwnedWork()
        let identity = try makeIdentity()
        let targetID = UUID()
        let accountName = account(for: targetID)
        let mailbox = SecretRequestMailbox.shared
        let (vault1, clock) = try makeRealMailboxVault(
            manager: manager, identity: identity, ownedWork: ownedWork)
        defer { releaseRealMailbox() }
        // A SECOND facade over the same trusted context shares the coordinator.
        let vault2 = try AndroidCredentialVault.joinRuntimeOwnership(
            database: manager, identity: identity, ownedWork: ownedWork)

        let captureTask = Task {
            try await vault1.capture(
                Data("synthetic-singleflight".utf8), kind: .genericToken,
                owner: .vault, label: "Singleflight", id: targetID)
        }
        let writeClaim = mailbox.awaitClaim(timeoutMillis: 5_000)
        XCTAssertGreaterThan(writeClaim, 0)
        clock.advance(10_000)
        await waitFor { self.mailboxIntStat("callerSettledOutstanding") == 1 }
        // Cancel while the write terminal is still unknown: the owner parks
        // with NO compensation initiated yet (the exact reentrancy window).
        captureTask.cancel()
        do {
            _ = try await captureTask.value
            XCTFail("a cancelled capture must not report success")
        } catch let error as AndroidCredentialVaultError {
            XCTAssertEqual(error, .captureCleanupIncomplete(targetID))
        }
        XCTAssertEqual(ownedWork.liveCount, 1)
        XCTAssertEqual(mailbox.physicalSnapshot(claim: writeClaim), .claimedOutstanding)

        // DETERMINISTIC arrival evidence: the probe observes every
        // reservation attempt for the SAME parked owner. Wait until BOTH
        // reconcilers have actually reached the reservation call (no fixed
        // sleep), then require exactly one grant and one denial — the losing
        // reconciler must have performed no effect.
        let probe = ReconciliationProbe()
        await vault1.setReconciliationProbeForTesting { account, acquired in
            probe.record(account: account, acquired: acquired)
        }
        async let first = vault1.reconcilePendingPhysicalOwners()
        async let second = vault2.reconcilePendingPhysicalOwners()
        await waitFor { probe.snapshot.attempts >= 2 }
        let arrival = probe.snapshot
        XCTAssertEqual(arrival.attempts, 2,
                       "both reconcilers reached the shared reservation")
        XCTAssertEqual(arrival.granted, 1,
                       "exactly one exact-owner reservation was granted")
        XCTAssertEqual(arrival.denied, 1,
                       "the second reconciler performed no effect")
        XCTAssertEqual(ownedWork.liveCount, 1, "still the same single owner")
        await vault1.setReconciliationProbeForTesting(nil)
        // The one reserved reconciler sees the real terminal and must issue
        // exactly ONE compensation delete.
        XCTAssertEqual(
            mailbox.complete(claim: writeClaim, status: 3, value: nil, valueLen: 0), -103)
        let deleteClaim = mailbox.awaitClaim(timeoutMillis: 5_000)
        XCTAssertGreaterThan(deleteClaim, 0, "the single compensation delete was enqueued")
        // No second old delete may exist while the first one is held.
        XCTAssertEqual(mailbox.awaitClaim(timeoutMillis: 150), 0,
                       "exactly one compensation enqueue, never two")
        XCTAssertEqual(
            mailbox.complete(claim: deleteClaim, status: 4, value: nil, valueLen: 0), 0)

        let results = await (first, second)
        XCTAssertEqual(results.0 + results.1, 1,
                       "exactly one reconciler settles the owner")
        XCTAssertEqual(ownedWork.liveCount, 0)
        let settledSummary = await vault1.ownedOperationSummary
        XCTAssertEqual(settledSummary.accounts, 0)
        let row = try await readQueueGeneration(manager: manager, account: accountName)
        XCTAssertNil(row)
        let pending = try await store.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)

        // The SAME canonical account is reused (the cancelled capture never
        // committed metadata), so a stale old delete would hit the NEW secret:
        // the next capture must succeed on the identical account and no late
        // compensation may appear afterwards.
        XCTAssertEqual(account(for: targetID), accountName,
                       "the successor targets the same canonical account")
        let preSuccessorRecord = try await store.record(id: targetID)
        XCTAssertNil(preSuccessorRecord,
                     "the cancelled capture never committed metadata")
        let successorTask = Task {
            try await vault2.capture(
                Data("synthetic-same-account-successor".utf8), kind: .genericToken,
                owner: .vault, label: "Same account successor", id: targetID)
        }
        let successorWrite = mailbox.awaitClaim(timeoutMillis: 5_000)
        XCTAssertGreaterThan(successorWrite, 0)
        XCTAssertNotEqual(successorWrite, deleteClaim)
        XCTAssertEqual(
            mailbox.complete(claim: successorWrite, status: 3, value: nil, valueLen: 0), 0)
        let successorHandle = try await successorTask.value
        XCTAssertEqual(successorHandle.id, targetID)
        let successorRecord = try await store.record(id: targetID)
        XCTAssertNotNil(successorRecord, "the successor's metadata committed normally")
        XCTAssertEqual(successorRecord?.keychainAccount, accountName,
                       "the successor reused the SAME canonical account")
        XCTAssertEqual(mailbox.awaitClaim(timeoutMillis: 150), 0,
                       "no stale old delete may follow the same-account successor")
        let finalPending = try await store.pendingDeletions()
        XCTAssertTrue(finalPending.isEmpty,
                      "no stale compensation row remains for the reused account")
    }
}


/// Minimal synthetic gateway spy used ONLY to prove the default forwarder's
/// registry passthrough. It is never a production registration path.
private actor RegistryProbeGateway: AndroidSecretGateway {
    private var storage: [String: Data] = [:]
    private(set) var writtenReferences: [String] = []

    func read(reference: String) async throws -> Data? { storage[reference] }
    func write(reference: String, value: Data) async throws {
        writtenReferences.append(reference)
        storage[reference] = value
    }
    func delete(reference: String) async throws { storage[reference] = nil }
}
